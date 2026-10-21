/* MS6.5.1 red (RoseCat 3ec386e — the false-Clean race). PURE Linux decision logic — the kill is the injected
 * killsig, NO real signal; run under unshare --user --map-root-user --pid --fork --mount-proc. UNREGISTERED
 * until green.
 *
 * The hole: in sweep mode zb_reaper_engine inspects a matched candidate a second time just before the SIGKILL
 * (agent_run_reaper.c:153) and `continue`s — silently, into NEITHER `killed` NOR `surv` — when that candidate
 * vanished, changed identity, or changed uid (:154), or when its first identity was unavailable (:146). The
 * fixed point then sees kn==0 && sn==0 and declares Clean WITHOUT a fresh census, even though a matched process
 * was never resolved and a child may have appeared.
 *
 * RoseCat's exact reproducer: the parent 1001 changes its start time between the two pre-kill inspects (so it is
 * dropped unresolved), and the child 1002 appears only in generation 1. Against the buggy engine the fixed point
 * returns clean=1 at passes=1 and NEVER gathers generation 1, so 1002 is missed. A correct engine must report
 * the unresolved drop distinctly so the fixed point takes another census pass (or returns Survivors) — never
 * Clean — and 1002 is caught on the next pass. */
#include "agent_run_reaper.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>

static int failures = 0, total = 0;
static void check(int ok, const char *m) { total++; printf("  %s %s\n", ok ? "ok" : "FAIL", m); if (!ok) failures++; }

/* ---- generational scan: gen 0 -> {1001}, gen 1 -> {1002}, gen 2+ -> {} ---- */
#define PID_PARENT 1001
#define PID_CHILD 1002
static const pid_t GEN[][1] = {{PID_PARENT}, {PID_CHILD}};
static int g_gen = 0;

static int gen_count(int gen) { return (gen >= 0 && gen < (int)(sizeof GEN / sizeof GEN[0])) ? 1 : 0; }

static int fake_scan(void *buf, int bytes) {
  if (buf == NULL) return gen_count(g_gen);
  const int n = gen_count(g_gen);
  if (n > 0) {
    if (bytes < (int)sizeof(pid_t)) return -1;
    ((pid_t *)buf)[0] = GEN[g_gen][0];
  }
  g_gen++;
  return n;
}

/* ---- inspect: 1001's start time FLIPS between its two inspects in a pass; 1002 is stable ---- */
static int g_insp_parent = 0;

static void fake_inspect(pid_t pid, const char *dir, struct zb_reaper_id *out, void *ctx) {
  (void)dir;
  (void)ctx;
  out->matches = 1;
  out->have_bsd = 1;
  out->uid = getuid();
  out->start_usec = 0;
  if (pid == PID_PARENT) {
    g_insp_parent++;
    out->start_sec = (g_insp_parent == 1) ? 100 : 200; /* id0 vs the pre-kill id1: identity changed */
  } else {
    out->start_sec = 500; /* 1002: stable across both inspects -> safely killable */
  }
}

static pid_t g_killed[64];
static int g_killed_n = 0;

static int fake_killsig(pid_t pid, int sig, void *ctx) {
  (void)ctx;
  if (sig == 0) return ESRCH;
  if (sig == SIGKILL) {
    if (g_killed_n < (int)(sizeof g_killed / sizeof g_killed[0])) g_killed[g_killed_n] = pid;
    g_killed_n++;
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
  /* The causal catch: 1001's unresolved identity flip must NOT be read as an empty census; the fixed point must
   * take another pass, gather generation 1, and kill the child 1002 before it can declare Clean. */
  check(passes >= 2, "the unresolved identity flip forced at least a second census pass");
  check(was_killed(PID_CHILD), "the child 1002 (generation 1) was killed — not missed by a false Clean");
  check(!(clean == 1 && !was_killed(PID_CHILD)), "never Clean while a matched candidate was left unresolved/missed");

  if (failures == 0) { printf("PASS false-clean %d checks\n", total); return 0; }
  printf("FAIL false-clean %d of %d check(s) failed\n", failures, total);
  return 1;
}
