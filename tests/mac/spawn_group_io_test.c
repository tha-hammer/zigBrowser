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
 *  3. refusals: a stream fd in 0..2 (stdin_fd 1, stdout_fd 0, stdin_fd 2) is EINVAL and spawns nothing. */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

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

static int child_main(int echo) {
  char fds[512] = "FDS";
  for (int fd = 0; fd < 256; fd++) {
    if (fcntl(fd, F_GETFD) != -1) {
      char n[8];
      snprintf(n, sizeof n, " %d", fd);
      strncat(fds, n, sizeof fds - strlen(fds) - 1);
    }
  }
  printf("%s\nPGLEADER %d\n", fds, getpgrp() == getpid());
  fflush(stdout);
  if (!echo) return 0;
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
  while (n + 1 < cap && now() < until) {
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

int main(int argc, char **argv) {
  if (argc >= 2 && strcmp(argv[1], "child") == 0) return child_main(argc >= 3 && strcmp(argv[2], "echo") == 0);
  if (zb_agent_spawn_group_io == NULL) {
    printf("FAIL\tms5-spawn-io\tzb_agent_spawn_group_io is missing (7108 seam 1)\n");
    return 1;
  }
  char self[1024];
  if (realpath(argv[0], self) == NULL) { printf("FAIL\tms5-spawn-io\trealpath\n"); return 1; }
  const char *envp[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};

  /* 1. pipes */
  int planted = open("/dev/null", O_RDONLY);  /* inheritable on purpose: CLOEXEC_DEFAULT must still drop it */
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
    read_line(out_p[0], line, sizeof line, 10);
    if (strcmp(line, "FDS 0 1 2") == 0) ok("pipes: the child holds exactly 0 1 2 (no planted fd, no pipe end)");
    else { char m[600]; snprintf(m, sizeof m, "pipes: the child holds exactly 0 1 2 (got '%s')", line); fail(m); }
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
    else { fail("pipes: closing the parent's stdin end makes the child exit within 2 s"); kill(-child, SIGKILL); waitpid(child, NULL, 0); }
  }
  close(out_p[0]);
  close(planted);

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
    char line[512];
    read_line(out2[0], line, sizeof line, 10);
    if (strcmp(line, "FDS 0 1 2") == 0) ok("inherit: stdin -1 keeps the parent's stdin; still exactly 0 1 2");
    else { char m[600]; snprintf(m, sizeof m, "inherit: still exactly 0 1 2 (got '%s')", line); fail(m); }
    waitpid(child, NULL, 0);
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
    else { fail(m); if (child > 0) { kill(-child, SIGKILL); waitpid(child, NULL, 0); } }
  }

  if (failures == 0) {
    printf("PASS\tms5-spawn-io\t3 cases\n");
    return 0;
  }
  printf("FAIL\tms5-spawn-io\t%d failure(s)\n", failures);
  return 1;
}
