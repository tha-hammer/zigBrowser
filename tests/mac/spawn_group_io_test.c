/* BlackRobin 7108 seam 1 (JadeBeacon 7143; BlueBeaver 7109): zb_agent_spawn_group_io, the sibling of
 * zb_agent_spawn_group that wires the child's stdin and stdout to the browser's pipe ends, so the browser can read
 * netd's ready line and hold netd's stdin open (netd exits on stdin EOF). Run by tests/mac/ms5_spawn_io_gate.sh on
 * BOTH Macs. This binary is both the browser stand-in and (argv[1] == "child") the spawned child.
 *
 * Cases:
 *  1. pipes: the parent plants an INHERITABLE fd, makes two pipes (FD_CLOEXEC on all four ends) and spawns the
 *     child with stdin and stdout on them. The child reports "FDS <its open fds>" and "PGLEADER <0|1>"; it must hold
 *     EXACTLY 0 1 2 (no planted fd, no pipe end) and lead its own group. One line written to its stdin comes back
 *     as "ECHO <line>". Closing the parent's stdin write end makes the child exit within 2 s.
 *  2. inherit: stdin_fd = -1 keeps the parent's stdin; the child still holds exactly 0 1 2.
 *  3. refusals: a stream fd in 0..2 (stdin_fd 1, stdout_fd 0, stdin_fd 2) is EINVAL and spawns nothing.
 *  4. same fd (RoseCat 7150): one duplex socket as BOTH stdin and stdout works (the header allows it): exactly
 *     0 1 2, a line round-trips, and SHUT_WR on the parent's end makes the child exit.
 * The fd census scans every fd below the child's RLIMIT_NOFILE soft limit, and the parent raises that limit
 * and plants a second inheritable fd at 300 (RoseCat 7150), so a leak above 255 cannot pass; the child reports
 * its scan bound ("SCAN <n>") and the parent checks it covers the high plant. Every read is bounded by poll(). */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <poll.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* The guarded production stop: signals only our own child that leads its own group (else EINVAL/ECHILD/EPERM, no
 * signal), then reaps it (03b2bee, d8f5e76). This test never calls kill() itself (RoseCat 7250 #1). */
int zb_agent_kill_group(pid_t pid);

/* Weak, so the red fails by behaviour ("missing"), not at link time. */
extern int zb_agent_spawn_group_io(const char *const *argv, const char *const *envp, int stdin_fd, int stdout_fd,
                                   pid_t *out_pid) __attribute__((weak_import));

static int failures = 0;
static void fail(const char *msg) { printf("  FAIL %s\n", msg); failures++; }
static void ok(const char *msg) { printf("  ok   %s\n", msg); }

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

#define HIGH_PLANT 300

static int child_main(int echo) {
  char fds[512] = "FDS";
  struct rlimit rl;
  int bound = 65536;
  if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur < (rlim_t)bound)
    bound = (int)rl.rlim_cur;
  for (int fd = 0; fd < bound; fd++) {
    if (fcntl(fd, F_GETFD) != -1) {
      char n[16];
      snprintf(n, sizeof n, " %d", fd);
      strncat(fds, n, sizeof fds - strlen(fds) - 1);
    }
  }
  printf("%s\nSCAN %d\nPGLEADER %d\n", fds, bound, getpgrp() == getpid());
  fflush(stdout);
  if (!echo) return 0;
  if (getenv("ZB_SPAWN_IO_CHILD_HANG") != NULL) {
    /* Test knob (tests/kill_group/spawn_io_no_stray_signal.sh): ignore stdin EOF and linger 30 s, so the parent's
     * failure path ("the child did not exit") is really taken (it outlasts the 10 s echo read and the 2 s exit
     * deadline). Never set by the Mac gates. */
    sleep(30);
    return 0;
  }
  char line[256];
  if (fgets(line, sizeof line, stdin) != NULL) {
    printf("ECHO %s", line);
    fflush(stdout);
  }
  while (fgets(line, sizeof line, stdin) != NULL) {}  /* until stdin EOF, like netd */
  return 0;
}

static int read_line(int fd, char *buf, size_t cap, double secs) {
  size_t n = 0;
  double until = now() + secs;
  while (n + 1 < cap) {
    double left = until - now();
    if (left <= 0) break;
    struct pollfd p = {fd, POLLIN, 0};
    int pr = poll(&p, 1, (int)(left * 1000) + 1);
    if (pr == 0) break;  /* silence: a local, diagnosable failure, not the leg timeout */
    if (pr < 0) { if (errno == EINTR) continue; break; }
    char c;
    ssize_t r = read(fd, &c, 1);
    if (r == 1) {
      if (c == '\n') break;
      buf[n++] = c;
    } else if (r == 0) {
      break;
    } else if (errno != EINTR) {
      break;
    }
  }
  buf[n] = 0;
  return (int)n;
}

static void cloexec(int fd) { fcntl(fd, F_SETFD, FD_CLOEXEC); }

/* Stops a child of this test that missed its deadline, never by a raw signal: only the guarded
 * zb_agent_kill_group may signal, and only our own child leading its own group. A child it refuses (a broken spawn
 * left it outside its own group) is only waited for, up to 5 s, and reported if it still runs: never signalled. */
static void stop_child(pid_t child, const char *label) {
  if (child <= 1) return;
  if (zb_agent_kill_group(child) == 0) return;  /* killed and reaped */
  double until = now() + 5;
  int st;
  while (now() < until) {
    pid_t w = waitpid(child, &st, WNOHANG);
    if (w == child || (w < 0 && errno == ECHILD)) return;
    usleep(20000);
  }
  char m[200];
  snprintf(m, sizeof m, "%s: child %d still runs after the guarded stop (refused or failed); left alone, never "
           "signalled raw", label, (int)child);
  fail(m);
}

/* Waits up to `secs` for our child to exit (reaping it); 1 if it did. */
static int exited_within(pid_t child, double secs) {
  double until = now() + secs;
  int st;
  pid_t w = 0;
  while (now() < until && (w = waitpid(child, &st, WNOHANG)) == 0) usleep(20000);
  return w == child;
}

/* Reads the child's "FDS ..." and "SCAN <n>" lines: exactly 0 1 2, over a scan that covers the high plant. */
static void expect_census(int fd, const char *label) {
  char line[512], scan[64], m[700];
  read_line(fd, line, sizeof line, 10);
  read_line(fd, scan, sizeof scan, 10);
  int bound = strncmp(scan, "SCAN ", 5) == 0 ? atoi(scan + 5) : 0;
  snprintf(m, sizeof m, "%s: the child holds exactly 0 1 2 over fds 0..%d (got '%s')", label, bound - 1, line);
  if (strcmp(line, "FDS 0 1 2") == 0 && bound > HIGH_PLANT) ok(m);
  else fail(m);
}

int main(int argc, char **argv) {
  if (argc >= 2 && strcmp(argv[1], "child") == 0) return child_main(argc >= 3 && strcmp(argv[2], "echo") == 0);
  if (zb_agent_spawn_group_io == NULL) {
    printf("FAIL\tms5-spawn-io\tzb_agent_spawn_group_io is missing (7108 seam 1)\n");
    return 1;
  }
  char self[1024];
  if (realpath(argv[0], self) == NULL) { printf("FAIL\tms5-spawn-io\trealpath\n"); return 1; }
  const char *envp[] = {"PATH=/usr/bin:/bin", "LANG=C",
                        getenv("ZB_SPAWN_IO_CHILD_HANG") != NULL ? "ZB_SPAWN_IO_CHILD_HANG=1" : NULL, NULL};

  /* Raise the soft fd limit above the high plant (the child inherits it, so its census reaches it). */
  struct rlimit rl;
  if (getrlimit(RLIMIT_NOFILE, &rl) != 0) { printf("FAIL\tms5-spawn-io\tgetrlimit\n"); return 1; }
  if (rl.rlim_cur != RLIM_INFINITY && rl.rlim_cur < 1024) {
    rl.rlim_cur = (rl.rlim_max == RLIM_INFINITY || rl.rlim_max >= 1024) ? 1024 : rl.rlim_max;
    if (setrlimit(RLIMIT_NOFILE, &rl) != 0) { printf("FAIL\tms5-spawn-io\tsetrlimit\n"); return 1; }
  }
  /* 1. pipes */
  int planted = open("/dev/null", O_RDONLY);  /* inheritable on purpose: CLOEXEC_DEFAULT must still drop it */
  int planted_high = planted >= 0 ? fcntl(planted, F_DUPFD, HIGH_PLANT) : -1;  /* inheritable, above 255 */
  if (planted_high != HIGH_PLANT) { printf("FAIL\tms5-spawn-io\tcannot plant fd %d\n", HIGH_PLANT); return 1; }
  int in_p[2], out_p[2];
  if (planted < 0 || pipe(in_p) != 0 || pipe(out_p) != 0) { printf("FAIL\tms5-spawn-io\tsetup\n"); return 1; }
  for (int i = 0; i < 2; i++) { cloexec(in_p[i]); cloexec(out_p[i]); }
  const char *argv_echo[] = {self, "child", "echo", NULL};
  pid_t child = -1;
  int r = zb_agent_spawn_group_io(argv_echo, envp, in_p[0], out_p[1], &child);
  close(in_p[0]);
  close(out_p[1]);
  if (r != 0 || child <= 0) {
    fail("pipes: the spawn starts the child");
  } else {
    char line[512];
    expect_census(out_p[0], "pipes (no planted fd, no pipe end)");
    read_line(out_p[0], line, sizeof line, 10);
    if (strcmp(line, "PGLEADER 1") == 0 && getpgid(child) == child) ok("pipes: the child leads its own group");
    else fail("pipes: the child leads its own group");
    if (write(in_p[1], "hello\n", 6) != 6) fail("pipes: write to the child's stdin");
    read_line(out_p[0], line, sizeof line, 10);
    if (strcmp(line, "ECHO hello") == 0) ok("pipes: a stdin line round-trips through the child");
    else fail("pipes: a stdin line round-trips through the child");
    close(in_p[1]);  /* the browser's clean stop: stdin EOF */
    int status = 0;
    pid_t w = 0;
    double until = now() + 2;
    while (now() < until && (w = waitpid(child, &status, WNOHANG)) == 0) usleep(20000);
    if (w == child) ok("pipes: closing the parent's stdin end makes the child exit within 2 s");
    else {
      fail("pipes: closing the parent's stdin end makes the child exit within 2 s");
      stop_child(child, "pipes");
    }
  }
  close(out_p[0]);

  /* 2. inherit (-1): the parent's own stdin stays the child's stdin */
  int out2[2];
  if (pipe(out2) != 0) { printf("FAIL\tms5-spawn-io\tsetup 2\n"); return 1; }
  cloexec(out2[0]); cloexec(out2[1]);
  const char *argv_fds[] = {self, "child", NULL};
  child = -1;
  r = zb_agent_spawn_group_io(argv_fds, envp, -1, out2[1], &child);
  close(out2[1]);
  if (r != 0 || child <= 0) {
    fail("inherit: the spawn starts the child");
  } else {
    expect_census(out2[0], "inherit (stdin -1 keeps the parent's stdin)");
    if (!exited_within(child, 5)) stop_child(child, "inherit");
  }
  close(out2[0]);

  /* 3. refusals */
  const int bad[][2] = {{1, -1}, {-1, 0}, {2, -1}, {-1, 2}};
  for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++) {
    child = -1;
    r = zb_agent_spawn_group_io(argv_fds, envp, bad[i][0], bad[i][1], &child);
    char m[200];
    snprintf(m, sizeof m, "refusal: stdin_fd %d stdout_fd %d is EINVAL and spawns nothing", bad[i][0], bad[i][1]);
    if (r == EINVAL && child == -1) ok(m);
    else {
      fail(m);
      if (child > 0) stop_child(child, "refusal");
    }
  }

  /* 4. same fd: one duplex socket is both stdin and stdout */
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) { printf("FAIL\tms5-spawn-io\tsetup 4\n"); return 1; }
  cloexec(sv[0]); cloexec(sv[1]);
  child = -1;
  r = zb_agent_spawn_group_io(argv_echo, envp, sv[1], sv[1], &child);
  close(sv[1]);
  if (r != 0 || child <= 0) {
    char m[200];
    snprintf(m, sizeof m, "same fd: one duplex socket as stdin and stdout starts the child (got %d %s)", r,
             strerror(r));
    fail(m);
  } else {
    char line[512];
    expect_census(sv[0], "same fd");
    read_line(sv[0], line, sizeof line, 10);  /* PGLEADER */
    if (write(sv[0], "dup\n", 4) != 4) fail("same fd: write to the child's stdin");
    read_line(sv[0], line, sizeof line, 10);
    if (strcmp(line, "ECHO dup") == 0) ok("same fd: a line round-trips over the one socket");
    else fail("same fd: a line round-trips over the one socket");
    shutdown(sv[0], SHUT_WR);
    int status = 0;
    pid_t w = 0;
    double until = now() + 2;
    while (now() < until && (w = waitpid(child, &status, WNOHANG)) == 0) usleep(20000);
    if (w == child) ok("same fd: SHUT_WR on the parent's end makes the child exit within 2 s");
    else {
      fail("same fd: SHUT_WR on the parent's end makes the child exit within 2 s");
      stop_child(child, "same fd");
    }
  }
  close(sv[0]);
  close(planted);
  close(planted_high);

  if (failures == 0) {
    printf("PASS\tms5-spawn-io\t4 cases\n");
    return 0;
  }
  printf("FAIL\tms5-spawn-io\t%d failure(s)\n", failures);
  return 1;
}
