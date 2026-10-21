/* MS6.5 (the user's decision 2026-10-21): the run-survivor reaper on real macOS. A detached escaper
 * (setsid + double-fork) whose cwd is under the run dir is found by the census and SIGKILLed by the sweep; a
 * decoy outside the run dir is neither found nor killed; a marker-scrubbing escaper (chdir "/") is the accepted
 * residual the census cannot see. Public libproc only; the sweep's guard (pid>1, not self, same uid, marker
 * re-checked before the signal) means it can only reach the escaper it positively identified.
 *
 * Run by tests/mac/ms6_5_reaper_gate.sh on both arches. Every process this test starts is cleaned up. */
#include "agent_run_reaper.h"
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures = 0;
static void check(int ok, const char *msg) { printf("  %s %s\n", ok ? "ok" : "FAIL", msg); if (!ok) failures++; }

/* detached (setsid + double-fork); grandchild chdir(dir) then holds; returns the grandchild pid via a pipe. */
static pid_t spawn_detached(const char *dir) {
  int p[2];
  if (pipe(p) != 0) return -1;
  pid_t c = fork();
  if (c == 0) {
    close(p[0]);
    setsid();
    pid_t g = fork();
    if (g == 0) {
      if (chdir(dir) != 0) _exit(3);
      pid_t me = getpid();
      (void)write(p[1], &me, sizeof me);
      close(p[1]);
      sleep(120);
      _exit(0);
    }
    _exit(0);
  }
  close(p[1]);
  pid_t g = -1;
  (void)read(p[0], &g, sizeof g);
  close(p[0]);
  waitpid(c, NULL, 0);
  return g;
}

static pid_t spawn_child(const char *dir) { /* our direct child (decoy) */
  pid_t c = fork();
  if (c == 0) { (void)chdir(dir); sleep(120); _exit(0); }
  return c;
}

static int in_list(int *a, int n, pid_t pid) { for (int i = 0; i < n; i++) if (a[i] == pid) return 1; return 0; }
static int alive(pid_t pid) { return kill(pid, 0) == 0; }

int main(void) {
  char tmpl[] = "/tmp/zb-reaper-gate-XXXXXX";
  char *run = mkdtemp(tmpl);
  if (!run) { printf("FAIL mkdtemp\n"); return 2; }

  pid_t esc = spawn_detached(run);           /* matches: cwd under the run dir, detached */
  pid_t decoy = spawn_child("/tmp");         /* no match: cwd /tmp */
  pid_t scrub = spawn_detached("/");         /* scrubbed: cwd "/" -> census cannot see it (accepted residual) */
  printf("run_dir=%s escaper=%d decoy=%d scrubber=%d self=%d\n", run, esc, decoy, scrub, getpid());
  sleep(1);

  int cen[512]; int cn = 0;
  zb_reaper_census(run, cen, 512, &cn);
  check(in_list(cen, cn, esc), "census finds the escaper");
  check(!in_list(cen, cn, decoy), "census does NOT find the decoy");
  check(!in_list(cen, cn, scrub), "census does NOT find the marker-scrubber (accepted residual)");

  int killed[512], surv[512], kn = 0, sn = 0;
  zb_reaper_sweep(run, killed, 512, &kn, surv, 512, &sn);
  check(in_list(killed, kn, esc), "sweep KILLED the escaper");
  check(!alive(esc), "the escaper is gone");
  check(!in_list(killed, kn, decoy) && !in_list(surv, sn, decoy), "sweep did not touch the decoy");
  check(alive(decoy), "the decoy is still alive");
  check(!in_list(killed, kn, scrub), "sweep did not kill the scrubber (it was never identified)");

  /* clean up everything we started */
  if (decoy > 1) { kill(decoy, SIGKILL); waitpid(decoy, NULL, 0); }
  if (scrub > 1) kill(scrub, SIGKILL);
  if (esc > 1) kill(esc, SIGKILL);
  rmdir(run);

  if (failures == 0) printf("PASS ms6-5-reaper %d checks\n", 8);
  else printf("FAIL ms6-5-reaper %d check(s) failed\n", failures);
  return failures == 0 ? 0 : 1;
}
