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
  /* It exists. The ONLY observation that may call it non-running is a confirmed zombie 'Z'. Any ps anomaly
   * (popen fail, read error, nonzero/failed pclose, empty/short output) is live/unknown, never dead
   * (RoseCat 7052 #2). */
  char cmd[64], buf[16] = {0};
  snprintf(cmd, sizeof cmd, "/bin/ps -o stat= -p %d", (int)pid);
  FILE *p = popen(cmd, "r");
  if (p == NULL) return 1;                               /* cannot observe -> live/unknown */
  size_t n = fread(buf, 1, sizeof buf - 1, p);
  int rerr = ferror(p);
  int st = pclose(p);
  if (rerr || st == -1) return 1;                        /* read / pclose anomaly -> live/unknown */
  return (n > 0 && buf[0] == 'Z') ? 0 : 1;               /* ONLY a confirmed zombie is non-running */
}

static int read_file(const char *path, char *buf, size_t cap) {
  FILE *f = fopen(path, "r");
  if (f == NULL) return 0;
  size_t n = fread(buf, 1, cap - 1, f);
  fclose(f);
  buf[n] = 0;
  return (int)n;
}

static pid_t start_browser(const char *python, const char *stub, const char *ready, const char *pub_delay, pid_t *setup) {
  int p[2];
  if (pipe(p) != 0) return -1;
  pid_t browser = fork();
  if (browser == 0) {
    close(p[0]);
    char me[32];
    snprintf(me, sizeof me, "%d", (int)getpid());
    const char *argv[] = {python, stub, me, ready, pub_delay, NULL};
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

#define ESCAPEE_TTL_S 20  /* must match ms6_5_escape_stub.py's bounded self-exit */

/* Trusted reap, run on EVERY exit path (RoseCat 7043 #1,#2; 7052 #1,#3). Closes the read-then-unlink race by
 * LOOPING: it keeps re-reading <ready> until it learns the escapee pid (then SIGKILLs it and confirms it is
 * gone), OR the escapee's self-TTL window elapses (so a late-published escapee has exited on its own). It does
 * NOT unlink <ready> until that holds, so an escapee that renames into <ready> after a first read cannot slip
 * through. Returns the escapee pid it learned (or -1), via *out; the function's return is 1 on a cleanup error
 * (any unlink/rmdir failure other than ENOENT), else 0 (7052 #3). */
static int trusted_reap(const char *dir, const char *ready, pid_t setup, pid_t *out) {
  if (setup > 0) kill(-setup, SIGKILL);  /* force-kill setup's group (parent_watch normally already did) */
  char buf[64];
  pid_t escapee = -1;
  double deadline = now() + ESCAPEE_TTL_S + 3.0;
  while (now() < deadline) {
    if (escapee <= 0 && read_file(ready, buf, sizeof buf) > 0) escapee = (pid_t)atoi(buf);
    if (escapee > 0) {
      kill(escapee, SIGKILL);
      if (!alive(escapee)) break;  /* confirmed gone */
    }
    usleep(50000);
  }
  if (out != NULL) *out = escapee;  /* -1 means never published; then the TTL window guarantees it self-exited */

  int err = 0;
  char esc[520];
  snprintf(esc, sizeof esc, "%s.esc", ready);
  if (unlink(ready) != 0 && errno != ENOENT) err = 1;
  if (unlink(esc) != 0 && errno != ENOENT) err = 1;
  if (rmdir(dir) != 0 && errno != ENOENT) err = 1;
  return err;
}

int main(int argc, char **argv) {
  if (zb_agent_spawn_group == NULL) {
    printf("FAIL\tms6-5-orphan\tzb_agent_spawn_group is missing (rev 14 item 5)\n");
    return 1;
  }
  if (argc < 3) { printf("FAIL\tms6-5-orphan\tusage: ms6_5_orphan_test <escape_stub.py> <python3> [wait_secs] [publish_delay_s]\n"); return 1; }
  /* Optional knobs for the deterministic late-publish test (RoseCat 7052 #1): a short readiness wait plus a
   * publish delay makes the test body time out BEFORE the escapee detaches, so trusted_reap — not the body —
   * must reap it. Defaults: wait 20 s, publish immediately. */
  double wait_secs = (argc > 3) ? atof(argv[3]) : 20.0;
  const char *pub_delay = (argc > 4) ? argv[4] : "0";
  char dir[] = "/tmp/zb-ms65-XXXXXX";
  if (mkdtemp(dir) == NULL) { printf("FAIL\tms6-5-orphan\tmkdtemp\n"); return 1; }
  char ready[512], buf[64];
  snprintf(ready, sizeof ready, "%s/ready", dir);

  pid_t setup = -1, escapee = -1, esc_pgid = -1, reaped = -1;
  pid_t browser = start_browser(argv[2], argv[1], ready, pub_delay, &setup);
  if (browser <= 0 || setup <= 0) {
    fail("the spawn did not start setup");
    if (browser > 0) { kill(browser, SIGKILL); waitpid(browser, NULL, 0); }
    goto finish;
  }

  if (!wait_ready(ready, buf, sizeof buf, wait_secs)) {
    /* A deliberately short wait (late-publish test) lands here: NOT the main assertion. trusted_reap below must
     * still leave zero survivors, which the gate asserts after we return. */
    fail("the escaping hook never detached in the readiness window");
    kill(browser, SIGKILL); waitpid(browser, NULL, 0);
    goto finish;
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
  if (trusted_reap(dir, ready, setup, &reaped))
    fail("cleanup error: a run file/dir could not be removed (not ENOENT)");
  /* Zero-survivor proof (RoseCat 7052 #1): on return, whatever escapee trusted_reap learned must be gone. */
  if (reaped > 0 && alive(reaped))
    fail("an escapee was still alive after trusted_reap returned");
  if (failures == 0) { printf("PASS\tms6-5-orphan\tsetsid+double-fork hook reaped\n"); return 0; }
  printf("FAIL\tms6-5-orphan\t%d failure(s) (EXPECTED RED on the main run: killpg cannot reach a launchd-reparented escapee; a tree-walk cannot close this — a non-escapable containment or the VM fallback is required, plan :285/:1619)\n", failures);
  return 1;
}
