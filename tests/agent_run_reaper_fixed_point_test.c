/* MS6.5.1 red (plan rev 27, "Clean fixed point" row). PURE Linux decision logic — the kill is the injected
 * killsig, so NO real signal is ever sent; still run under
 *   unshare --user --map-root-user --pid --fork --mount-proc
 * per the standing rule. UNREGISTERED: not wired into build.zig until it is green.
 *
 * Causal oracle: a marked process forks AFTER pass one's gather and before its parent is killed, so it is absent
 * from that pass's pid list. A correct census->kill->fresh-census FIXED POINT must re-census and kill the forked
 * child before it can declare the run clean. The no-recensus mutant (one gather+sweep) kills only the first pid
 * and declares clean while the child survives — this test catches exactly that.
 *
 * The fake `scan` returns successive GENERATIONS, one per gather:
 *   gen 0 -> {1001}            (the original marked process)
 *   gen 1 -> {1002}            (the child it forked after pass-one's gather)
 *   gen 2+ -> {}               (empty: the complete final census)
 * The fake `killsig` records every SIGKILL target and reports the target gone (ESRCH) on the sig==0 liveness
 * probe, so each killed pid lands in the engine's `killed` list without any real signal or sleep. */
#include "agent_run_reaper.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

static int failures = 0, total = 0;
static void check(int ok, const char *m) { total++; printf("  %s %s\n", ok ? "ok" : "FAIL", m); if (!ok) failures++; }

/* ---- generational scan ---- */
#define PID_A 1001
#define PID_B 1002
static const pid_t GEN[][1] = {{PID_A}, {PID_B}};
static int g_gen = 0; /* advances once per GATHER (on the fill call) */

static int gen_count(int gen) { return (gen >= 0 && gen < (int)(sizeof GEN / sizeof GEN[0])) ? 1 : 0; }

static int fake_scan(void *buf, int bytes) {
  if (buf == NULL) return gen_count(g_gen); /* sizing: current generation's count, no advance */
  const int n = gen_count(g_gen);
  if (n > 0) {
    if (bytes < (int)sizeof(pid_t)) return -1; /* buffer too small: a scan error */
    ((pid_t *)buf)[0] = GEN[g_gen][0];
  }
  g_gen++; /* fill consumes this generation */
  return n;
}

/* ---- fake inspect/killsig/dir_ok ---- */
static pid_t g_killed[64];
static int g_killed_n = 0;

static void fake_inspect(pid_t pid, const char *dir, struct zb_reaper_id *out, void *ctx) {
  (void)pid;
  (void)dir;
  (void)ctx;
  out->matches = 1;
  out->have_bsd = 1;
  out->uid = getuid();
  out->start_sec = 42; /* stable across the two inspects, so same_proc() holds */
  out->start_usec = 7;
}

static int fake_killsig(pid_t pid, int sig, void *ctx) {
  (void)ctx;
  if (sig == 0) return ESRCH; /* liveness probe: report gone, so the SIGKILL counts as killed with no sleep */
  if (sig == SIGKILL) {
    if (g_killed_n < (int)(sizeof g_killed / sizeof g_killed[0])) g_killed[g_killed_n] = pid;
    g_killed_n++;
    return 0;
  }
  return 0;
}

static int fake_dir_ok(void *ctx) { (void)ctx; return 1; }

static int was_killed(pid_t pid) {
  for (int i = 0; i < g_killed_n; i++)
    if (g_killed[i] == pid) return 1;
  return 0;
}

int main(void) {
  struct zb_reaper_ops ops = {fake_inspect, fake_killsig, fake_dir_ok, NULL};
  int clean = -1, passes = -1, overflow = -1;
  const int rc = zb_reaper_fixed_point(fake_scan, &ops, "/run/zigbrowser-agent-2-00112233445566ff", 16, &clean,
                                       &passes, &overflow);

  printf("fixed_point rc=%d clean=%d passes=%d overflow=%d killed=%d [", rc, clean, passes, overflow, g_killed_n);
  for (int i = 0; i < g_killed_n; i++) printf("%s%d", i ? " " : "", (int)g_killed[i]);
  printf("]\n");

  check(rc == 0, "fixed_point returns 0 (no error)");
  check(overflow == 0, "no overflow");
  /* The causal catch: the process that forked after pass one (PID_B) MUST be killed before clean is declared. */
  check(was_killed(PID_A), "the original marked process (1001) was killed");
  check(was_killed(PID_B), "the fork-after-pass-one child (1002) was killed (re-census caught it)");
  check(clean == 1, "clean is declared");
  check(passes >= 3, "it took at least three passes (kill A, kill B, empty final census)");

  if (failures == 0) { printf("PASS fixed-point %d checks\n", total); return 0; }
  printf("FAIL fixed-point %d of %d check(s) failed\n", failures, total);
  return 1;
}
