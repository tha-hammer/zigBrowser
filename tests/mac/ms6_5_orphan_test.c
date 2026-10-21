/* MS6.5 (plan :1619) — NO SURVIVORS after kill -9 of the browser, INCLUDING a hook that double-forks and
 * setsid()s to escape setup's process group. zb_agent_spawn_group starts the escape stub as a group leader;
 * the stub arms parent_watch and launches a detached "hook" that leaves setup's group (ms6_5_escape_stub.py);
 * the browser is SIGKILLed; the escapee MUST be dead within 2 s. argv: <ms6_5_escape_stub.py> <python3>
 *
 * This is RED today: parent_watch reaps with killpg(setup's pgid), which a setsid'd survivor escapes. macOS has
 * no PID namespace, and the double-fork reparents the survivor to launchd, so it is no longer a descendant of
 * setup — a descendant-tree walk at the browser's death CANNOT close this (RoseCat 7043; research :134-136,
 * :207). Closing it needs a truly non-escapable containment with its own threat proof, else the VM fallback is
 * selected and Mac agent launch stays disabled (plan :285, :1619-1620). Kept OUT of the green ms6_gate.sh; run
 * via tests/mac/ms6_5_orphan_gate.sh. Every exit path reaps through trusted_reap and the escapee self-exits on a
 * bounded TTL, so a red run leaves nothing behind (the survivor is detached — reparented to launchd). */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern int zb_agent_spawn_group(const char *const *argv, const char *const *envp, pid_t *out_pid)
    __attribute__((weak_import));

static int failures = 0;
static void fail(const char *msg) { printf("  FAIL %s\n", msg); failures++; }

static double now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}

/* Fail-closed liveness (RoseCat 7043 #3): only ESRCH proves the process is gone. kill(pid,0)==0 means it
 * exists (confirm it is not a zombie); any other errno (EPERM/…) is treated as live/unknown, never "dead". */
static int alive(pid_t pid) {
  if (pid <= 0) return 0;
  if (kill(pid, 0) != 0) return (errno != ESRCH);  /* ESRCH -> gone; anything else -> assume live */
  char cmd[64], buf[16] = {0};
  snprintf(cmd, sizeof cmd, "/bin/ps -o stat= -p %d", (int)pid);
  FILE *p = popen(cmd, "r");
  if (p == NULL) return 1;
  size_t n = fread(buf, 1, sizeof buf - 1, p);
  pclose(p);
  return n > 0 && buf[0] != 'Z';
}

static int read_file(const char *path, char *buf, size_t cap) {
  FILE *f = fopen(path, "r");
  if (f == NULL) return 0;
  size_t n = fread(buf, 1, cap - 1, f);
  fclose(f);
  buf[n] = 0;
  return (int)n;
}

static pid_t start_browser(const char *python, const char *stub, const char *ready, pid_t *setup) {
  int p[2];
  if (pipe(p) != 0) return -1;
  pid_t browser = fork();
  if (browser == 0) {
    close(p[0]);
    char me[32];
    snprintf(me, sizeof me, "%d", (int)getpid());
    const char *argv[] = {python, stub, me, ready, NULL};
    const char *envp[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
    pid_t child = -1;
    int r = zb_agent_spawn_group(argv, envp, &child);
    if (write(p[1], &child, sizeof child) != sizeof child || r != 0) _exit(1);
    for (;;) pause();
  }
  close(p[1]);
  *setup = -1;
  if (read(p[0], setup, sizeof *setup) != sizeof *setup) *setup = -1;
  close(p[0]);
  return browser;
}

static int wait_ready(const char *ready, char *buf, size_t cap, double secs) {
  double until = now() + secs;
  while (now() < until) {
    if (read_file(ready, buf, cap) > 0) return 1;
    usleep(20000);
  }
  return 0;
}

/* Trusted reap, run on EVERY exit path (RoseCat 7043 #1,#2): learn the detached escapee from <ready> even if
 * readiness timed out and the test body never parsed it, SIGKILL it, kill anything left in setup's group, then
 * remove the KNOWN files + dir with no shell. The escapee's bounded self-TTL (ms6_5_escape_stub.py) is the
 * final guarantee that no branch — timeout or error — can leave an indefinite canary process. */
static void trusted_reap(const char *dir, const char *ready, pid_t setup) {
  char buf[64];
  if (read_file(ready, buf, sizeof buf) > 0) {
    pid_t e = (pid_t)atoi(buf);
    if (e > 0) kill(e, SIGKILL);
  }
  if (setup > 0) kill(-setup, SIGKILL);
  char esc[520];
  unlink(ready);
  snprintf(esc, sizeof esc, "%s.esc", ready);
  unlink(esc);
  rmdir(dir);
}

int main(int argc, char **argv) {
  if (zb_agent_spawn_group == NULL) {
    printf("FAIL\tms6-5-orphan\tzb_agent_spawn_group is missing (rev 14 item 5)\n");
    return 1;
  }
  if (argc != 3) { printf("FAIL\tms6-5-orphan\tusage: ms6_5_orphan_test <escape_stub.py> <python3>\n"); return 1; }
  char dir[] = "/tmp/zb-ms65-XXXXXX";
  if (mkdtemp(dir) == NULL) { printf("FAIL\tms6-5-orphan\tmkdtemp\n"); return 1; }
  char ready[512], buf[64];
  snprintf(ready, sizeof ready, "%s/ready", dir);

  pid_t setup = -1, escapee = -1, esc_pgid = -1;
  pid_t browser = start_browser(argv[2], argv[1], ready, &setup);
  if (browser <= 0 || setup <= 0) {
    fail("the spawn did not start setup");
    if (browser > 0) { kill(browser, SIGKILL); waitpid(browser, NULL, 0); }
    goto finish;
  }

  if (!wait_ready(ready, buf, sizeof buf, 20)) {
    fail("the escaping hook never detached");
    kill(browser, SIGKILL); waitpid(browser, NULL, 0);
    goto finish;  /* trusted_reap still reads a late <ready>; the escapee TTL bounds the rest */
  }
  escapee = (pid_t)atoi(buf);
  { char *sp = strchr(buf, ' '); esc_pgid = sp ? (pid_t)atoi(sp + 1) : -1; }

  /* Precondition: the hook really escaped setup's process group (else the test proves nothing). */
  if (escapee <= 0) fail("no escapee pid");
  if (esc_pgid == setup) fail("precondition: the hook did not actually escape setup's group (setsid failed?)");

  kill(browser, SIGKILL);
  waitpid(browser, NULL, 0);

  { double until = now() + 2.0;
    while (now() < until && alive(escapee)) usleep(20000); }
  if (alive(escapee))
    fail("a setsid+double-fork hook SURVIVED the browser's SIGKILL (killpg cannot reach it; macOS has no PID namespace)");

finish:
  trusted_reap(dir, ready, setup);
  if (failures == 0) { printf("PASS\tms6-5-orphan\tsetsid+double-fork hook reaped\n"); return 0; }
  printf("FAIL\tms6-5-orphan\t%d failure(s) (EXPECTED RED: killpg cannot reach a launchd-reparented escapee; a tree-walk cannot close this — a non-escapable containment or the VM fallback is required, plan :285/:1619)\n", failures);
  return 1;
}
