/* MS6.5.1 red (RoseCat 413e3c5 — the first-inspection unreadable false-Clean, production-faithful). PURE Linux
 * decision logic — injected killsig, NO real signal; run under unshare --user --map-root-user --pid --fork
 * --mount-proc. UNREGISTERED until green.
 *
 * The real macOS inspector (reaper_inspect_real) sets have_bsd=0 AND uid=(uid_t)-1 when PROC_PIDTBSDINFO fails,
 * while still matching the run (cwd/exe/open-file under the run dir). The engine's gate order rejects a foreign
 * uid (id0.uid != myuid, agent_run_reaper.c:148) BEFORE the !have_bsd unresolved branch (:149), so a matched
 * candidate with uid=(uint)-1 is dropped SILENTLY — into neither killed, surv, nor unresolved. The fixed point
 * then reads kn==0 && sn==0 && unresolved==0 as an empty census and declares Clean, even though a matched
 * process it could not identify is still there.
 *
 * This injects exactly that: a persistent matched candidate whose every inspect has have_bsd=0 and
 * uid=(uid_t)-1. A correct engine must classify it UNRESOLVED (identity unavailable => uid unknowable => cannot
 * prove it foreign or gone), so the fixed point never declares Clean and ends Survivors at the pass cap. It is
 * never signalled. */
#include "agent_run_reaper.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>

static int failures = 0, total = 0;
static void check(int ok, const char *m) { total++; printf("  %s %s\n", ok ? "ok" : "FAIL", m); if (!ok) failures++; }

#define PID_UNREADABLE 7001

static int fake_scan(void *buf, int bytes) {
  if (buf == NULL) return 1; /* sizing: one pid, every gather (persistent) */
  if (bytes < (int)sizeof(pid_t)) return -1;
  ((pid_t *)buf)[0] = PID_UNREADABLE;
  return 1;
}

static void fake_inspect(pid_t pid, const char *dir, struct zb_reaper_id *out, void *ctx) {
  (void)pid;
  (void)dir;
  (void)ctx;
  out->matches = 1;         /* it matches the run (cwd/exe/fd under the run dir) */
  out->have_bsd = 0;        /* ... but PROC_PIDTBSDINFO failed */
  out->uid = (uid_t)-1;     /* exactly what reaper_inspect_real sets on that failure */
  out->start_sec = 0;
  out->start_usec = 0;
}

static int g_signals = 0;
static int fake_killsig(pid_t pid, int sig, void *ctx) {
  (void)pid;
  (void)ctx;
  if (sig == 0) return ESRCH;
  if (sig == SIGKILL) g_signals++;
  return 0;
}

static int fake_dir_ok(void *ctx) { (void)ctx; return 1; }

int main(void) {
  struct zb_reaper_ops ops = {fake_inspect, fake_killsig, fake_dir_ok, NULL};
  int clean = -1, passes = -1, overflow = -1;
  const int rc = zb_reaper_fixed_point(fake_scan, &ops, "/run/zigbrowser-agent-2-00112233445566ff", 4, &clean,
                                       &passes, &overflow);

  printf("fixed_point rc=%d clean=%d passes=%d overflow=%d signals=%d\n", rc, clean, passes, overflow, g_signals);

  check(rc == 0, "fixed_point returns 0");
  /* The causal catch: a matched-but-unidentifiable candidate (have_bsd=0, uid=-1) must be UNRESOLVED, never an
   * empty census -> never Clean. */
  check(clean == 0, "an unidentifiable (have_bsd=0, uid=-1) match is UNRESOLVED -> NEVER Clean");
  check(passes == 4, "it ran to the pass cap (persistently unresolvable) -> Survivors");
  check(g_signals == 0, "the unidentifiable candidate is NEVER signalled");

  if (failures == 0) { printf("PASS unreadable %d checks\n", total); return 0; }
  printf("FAIL unreadable %d of %d check(s) failed\n", failures, total);
  return 1;
}
