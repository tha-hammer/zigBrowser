/* zb_agent_kill_group signals ONLY our own child's own process group (RoseCat 7172 #3, 7182; the 2026-10-21 logouts:
 * a pid of 1 that reaches killpg is kill(-1), every process the user owns). Run by tests/kill_group/run_linux.sh
 * (inside a user+PID namespace) and tests/mac/ms5_kill_group_gate.sh (both Macs).
 *
 * Every killpg/kill from src/agent_spawn_posix.c goes to tests/kill_group/kill_group_fake.c, which refuses all of them
 * except a SIGKILL to the one leader pid this test allowlists. So no case, red or green, can send a real signal
 * anywhere but to a child group this test spawned itself. The test never calls kill() itself (on Linux --wrap would
 * route it to the fake): it sees death through pipe EOF and reaping through waitpid.
 *
 * zb_agent_kill_group(pid) returns 0 when it signalled (or found exited) and reaped our own group leader, else:
 * - EINVAL: pid <= 1, our own pid, or our own process group (no signal);
 * - ECHILD: not our child (no signal);
 * - EPERM: our child, but not the leader of its own group (no signal, not reaped).
 * Its leader check must hold for an exited, unreaped leader whose group still has a live member (macOS getpgid
 * fails with ESRCH on a zombie; measured on both Macs). */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Declared here, not from the header: the red runs against the old void declaration. */
int zb_agent_kill_group(pid_t pid);
int zb_agent_spawn_group_io(const char *const *argv, const char *const *envp, int stdin_fd, int stdout_fd,
                            pid_t *out_pid);
void zb_fake_allow(pid_t pid);
void zb_fake_reset(void);
int zb_fake_calls(void);
int zb_fake_forwarded(void);
pid_t zb_fake_last_target(void);
int zb_fake_last_was_pg(void);

static int failures = 0;
static void check(int ok, const char *label) {
  printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
  if (!ok) failures++;
}

static void sleep_ms(int ms) {
  struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
  while (nanosleep(&t, &t) != 0 && errno == EINTR) {}
}

/* Waits up to `ms` for EOF on fd (every writer gone), draining whatever arrives. */
static int eof_within(int fd, int ms) {
  char buf[256];
  for (int waited = 0; waited <= ms; waited += 50) {
    struct pollfd p = {fd, POLLIN, 0};
    int r = poll(&p, 1, 50);
    if (r > 0) {
      ssize_t n = read(fd, buf, sizeof buf);
      if (n == 0) return 1;
      if (n < 0 && errno != EINTR && errno != EAGAIN) return 0;
    }
  }
  return 0;
}

static int read_line(int fd, char *buf, size_t cap, int ms) {
  size_t n = 0;
  for (int waited = 0; waited <= ms && n + 1 < cap;) {
    struct pollfd p = {fd, POLLIN, 0};
    int r = poll(&p, 1, 50);
    if (r <= 0) { waited += 50; continue; }
    char c;
    if (read(fd, &c, 1) != 1) break;
    if (c == '\n') break;
    buf[n++] = c;
  }
  buf[n] = 0;
  return (int)n;
}

static void block_until_eof(int fd) {
  char c;
  while (read(fd, &c, 1) > 0 || errno == EINTR) {}
}

/* Child modes (argv[1]); stdin and stdout are the test's pipes. */
static int child_main(const char *mode) {
  if (strcmp(mode, "exit") == 0) return 0;
  pid_t member = fork();
  if (member == 0) { block_until_eof(0); _exit(0); }  /* same group as the leader; holds stdout too */
  printf("ready %d\n", (int)member);
  fflush(stdout);
  if (strcmp(mode, "zombie-leader") == 0) return 0;  /* the member outlives its leader */
  block_until_eof(0);
  return 0;
}

struct spawned { pid_t pid; int in_w, out_r; };

static int spawn(const char *self, const char *mode, struct spawned *s) {
  int in_p[2], out_p[2];
  if (pipe(in_p) != 0 || pipe(out_p) != 0) return -1;
  for (int i = 0; i < 2; i++) { fcntl(in_p[i], F_SETFD, FD_CLOEXEC); fcntl(out_p[i], F_SETFD, FD_CLOEXEC); }
  const char *argv[] = {self, mode, NULL};
  const char *envp[] = {"PATH=/usr/bin:/bin", NULL};
  int err = zb_agent_spawn_group_io(argv, envp, in_p[0], out_p[1], &s->pid);
  close(in_p[0]);
  close(out_p[1]);
  s->in_w = in_p[1];
  s->out_r = out_p[0];
  return err;
}

static int reaped(pid_t pid) {
  int st;
  return waitpid(pid, &st, WNOHANG) < 0 && errno == ECHILD;
}

static void refused(pid_t pid, int want, const char *label) {
  zb_fake_reset();
  int rc = zb_agent_kill_group(pid);
  char m[300];
  snprintf(m, sizeof m, "%s: refused with %s and no killpg/kill at all (rc %d, %d call(s), last target %d)", label,
           want == EINVAL ? "EINVAL" : want == ECHILD ? "ECHILD" : "EPERM", rc, zb_fake_calls(),
           (int)zb_fake_last_target());
  check(rc == want && zb_fake_calls() == 0, m);
}

int main(int argc, char **argv) {
  if (argc >= 2) return child_main(argv[1]);
  alarm(120);  /* a hang is a failure, never a stuck gate */
  char self[1024];
  if (realpath(argv[0], self) == NULL) { printf("FAIL\tkill-group\trealpath\n"); return 1; }

  /* 0. The canary: prove the fake intercepts the code under test before any case can reach a wrong pid. A child
   * leader of ours whose stdin is already closed (so it exits by itself) is passed WITHOUT an allowlist entry: the
   * code under test signals it (old and new code both), and that call must land in the fake. Zero calls means the
   * --wrap / interposition is not active: stop here, before pid 1 is ever passed. */
  {
    struct spawned c;
    if (spawn(self, "exit", &c) != 0) { printf("FAIL\tkill-group\tspawn canary\n"); return 1; }
    close(c.in_w);
    sleep_ms(300);
    zb_fake_reset();
    (void)zb_agent_kill_group(c.pid);
    int intercepted = zb_fake_calls() >= 1;
    close(c.out_r);
    int cst;
    while (waitpid(c.pid, &cst, WNOHANG) < 0 && errno == EINTR) {}
    if (!intercepted) {
      printf("FAIL\tkill-group\tthe signal fake is NOT intercepting agent_spawn_posix.c: aborting before any case\n");
      return 1;
    }
    printf("  ok   canary: the fake intercepts the code under test\n");
  }

  /* 1. pids that mean "every process", "my group" or "me" */
  refused(0, EINVAL, "pid 0");
  refused(1, EINVAL, "pid 1 (killpg(1) is kill(-1))");
  refused(-1, EINVAL, "pid -1");
  refused(getpid(), EINVAL, "our own pid");
  refused(getpgrp(), EINVAL, "our own process group");

  /* 2. a real process that is not our child */
  refused(getppid(), ECHILD, "our parent (a real pid, not our child)");

  /* 3. our live child that does not lead its own group (a plain fork: it is in OUR group) */
  int p[2];
  if (pipe(p) != 0) { printf("FAIL\tkill-group\tpipe\n"); return 1; }
  pid_t plain = fork();
  if (plain == 0) {
    close(p[1]);
    struct pollfd w = {p[0], POLLIN, 0};
    poll(&w, 1, 5000);  /* exits on EOF, or by itself after 5 s (so an unguarded wait cannot hang the red) */
    _exit(0);
  }
  close(p[0]);
  refused(plain, EPERM, "our live child that is not its own group's leader");
  close(p[1]);
  int st;
  while (waitpid(plain, &st, 0) < 0 && errno == EINTR) {}

  /* 4. our own group leader with a live member: one real SIGKILL to that group, then the leader is reaped */
  struct spawned s;
  char line[64];
  if (spawn(self, "leader", &s) != 0) { printf("FAIL\tkill-group\tspawn leader\n"); return 1; }
  read_line(s.out_r, line, sizeof line, 5000);
  zb_fake_reset();
  zb_fake_allow(s.pid);
  int rc = zb_agent_kill_group(s.pid);
  check(rc == 0 && zb_fake_forwarded() == 1 && zb_fake_calls() == 1 && zb_fake_last_was_pg() &&
            zb_fake_last_target() == s.pid,
        "our leader: exactly one killpg(leader, SIGKILL), returns 0");
  check(eof_within(s.out_r, 3000), "our leader: the whole group is gone (the member too)");
  check(reaped(s.pid), "our leader: reaped");
  close(s.in_w);
  close(s.out_r);

  /* 5. our leader already exited (an unreaped zombie) while a member of its group lives on */
  if (spawn(self, "zombie-leader", &s) != 0) { printf("FAIL\tkill-group\tspawn zombie-leader\n"); return 1; }
  read_line(s.out_r, line, sizeof line, 5000);
  sleep_ms(300);  /* the leader has exited by now; it stays a zombie until we reap it */
  zb_fake_reset();
  zb_fake_allow(s.pid);
  rc = zb_agent_kill_group(s.pid);
  check(rc == 0 && zb_fake_forwarded() == 1 && zb_fake_last_was_pg() && zb_fake_last_target() == s.pid,
        "zombie leader with a live member: killpg(leader) still sent, returns 0");
  check(eof_within(s.out_r, 3000), "zombie leader: the surviving member is gone");
  check(reaped(s.pid), "zombie leader: reaped");
  close(s.in_w);
  close(s.out_r);

  /* 6. our leader exited, nothing else left: reaped, returns 0 */
  if (spawn(self, "exit", &s) != 0) { printf("FAIL\tkill-group\tspawn exit\n"); return 1; }
  sleep_ms(300);
  zb_fake_reset();
  zb_fake_allow(s.pid);
  rc = zb_agent_kill_group(s.pid);
  check(rc == 0 && reaped(s.pid), "an exited leader alone: returns 0 and is reaped");
  close(s.in_w);
  close(s.out_r);

  if (failures == 0) { printf("PASS\tkill-group\t6 cases\n"); return 0; }
  printf("FAIL\tkill-group\t%d failure(s)\n", failures);
  return 1;
}
