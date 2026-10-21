/* MS6.5.1 (plan rev 27 "Clean fixed point"; RoseCat 3ec386e / 7417). PURE Linux decision logic — the kill is the
 * injected killsig, NO real signal; run under unshare --user --map-root-user --pid --fork --mount-proc.
 *
 * Scenarios over zb_reaper_fixed_point with fake ops (kill intercepted):
 *   S1 fork-after-gather   -> a marked process forks a child AFTER pass one's gather; the loop must re-census and
 *                             kill the child before declaring Clean (the bounded census->kill->fresh-census fixed
 *                             point).
 *   S3 scan error          -> a gather/scan error (run_full EIO) is NOT a clean empty set (overflow, Survivors).
 *   S4 persistent survivor -> an un-killable match (killsig EPERM) persists every pass; max-pass exhaustion is
 *                             NOT clean.
 * (The matched-but-unidentifiable have_bsd=0/uid=-1 false-Clean case is the dedicated
 *  tests/agent_run_reaper_unreadable_test.c.) */
#include "agent_run_reaper.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <sys/types.h>
#include <unistd.h>

static int failures = 0, total = 0;
static void check(int ok, const char *m) { total++; printf("  %s %s\n", ok ? "ok" : "FAIL", m); if (!ok) failures++; }

/* ---- scenario knobs (reset per scenario) ---- */
static const pid_t *g_gens[4]; /* generational scan: each gen is one pid, or NULL for an empty gen */
static int g_ngens;
static int g_gen;
static pid_t g_persist;  /* when > 0: every gather returns exactly {g_persist} (no advance) */
static int g_scan_error; /* when set: the scan reports an error -> gather -2 */
static pid_t g_eperm;    /* this pid's SIGKILL returns EPERM (an un-killable survivor) */

static pid_t g_killed[64];
static int g_killed_n;

static void reset(void) {
  g_ngens = 0; g_gen = 0; g_persist = 0; g_scan_error = 0; g_eperm = 0; g_killed_n = 0;
  for (int i = 0; i < 4; i++) g_gens[i] = NULL;
}

static int fake_scan(void *buf, int bytes) {
  if (g_scan_error) return -1; /* sizing and fill both error -> gather returns -2 */
  pid_t pid = 0;
  if (g_persist > 0) {
    pid = g_persist; /* every gather sees the same pid; no advance */
  } else {
    if (g_gen >= g_ngens || g_gens[g_gen] == NULL) { if (buf != NULL) g_gen++; return 0; }
    pid = g_gens[g_gen][0];
  }
  if (buf == NULL) return 1; /* sizing */
  if (bytes < (int)sizeof(pid_t)) return -1;
  ((pid_t *)buf)[0] = pid;
  if (g_persist == 0) g_gen++; /* fill consumes this generation */
  return 1;
}

static void fake_inspect(pid_t pid, const char *dir, struct zb_reaper_id *out, void *ctx) {
  (void)pid;
  (void)dir;
  (void)ctx;
  out->matches = 1;
  out->have_bsd = 1;
  out->uid = getuid();
  out->start_sec = 500; /* stable across both inspects -> same_proc holds */
  out->start_usec = 0;
}

static int fake_killsig(pid_t pid, int sig, void *ctx) {
  (void)ctx;
  if (sig == 0) return ESRCH;
  if (sig == SIGKILL) {
    if (g_killed_n < (int)(sizeof g_killed / sizeof g_killed[0])) g_killed[g_killed_n] = pid;
    g_killed_n++;
    if (pid == g_eperm) return EPERM; /* un-killable survivor */
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
  const char *dir = "/run/zigbrowser-agent-2-00112233445566ff";
  int clean, passes, overflow, rc;

  /* S1: fork-after-gather -> re-census catches the child before Clean */
  reset();
  static const pid_t g0[1] = {1001}, g1[1] = {1002};
  g_gens[0] = g0; g_gens[1] = g1; g_gens[2] = NULL; g_ngens = 3;
  clean = passes = overflow = -1;
  rc = zb_reaper_fixed_point(fake_scan, &ops, dir, 16, &clean, &passes, &overflow);
  printf("S1 rc=%d clean=%d passes=%d overflow=%d killed=%d\n", rc, clean, passes, overflow, g_killed_n);
  check(rc == 0 && overflow == 0, "S1: no error/overflow");
  check(was_killed(1001) && was_killed(1002), "S1: both the marked process and its fork-after-gather child are killed");
  check(clean == 1 && passes >= 3, "S1: Clean only after an empty final census (>= 3 passes)");

  /* S3: a scan/gather error is not a clean empty set */
  reset();
  g_scan_error = 1;
  clean = passes = overflow = -1;
  rc = zb_reaper_fixed_point(fake_scan, &ops, dir, 8, &clean, &passes, &overflow);
  printf("S3 rc=%d clean=%d passes=%d overflow=%d\n", rc, clean, passes, overflow);
  check(rc == 0 && overflow == 1 && clean == 0, "S3: a scan error is NOT clean (overflow set, Survivors)");

  /* S4: a persistent un-killable survivor (EPERM) -> max-pass exhaustion is not Clean */
  reset();
  g_persist = 1001; g_eperm = 1001;
  clean = passes = overflow = -1;
  rc = zb_reaper_fixed_point(fake_scan, &ops, dir, 4, &clean, &passes, &overflow);
  printf("S4 rc=%d clean=%d passes=%d overflow=%d killed=%d\n", rc, clean, passes, overflow, g_killed_n);
  check(rc == 0 && clean == 0 && passes == 4, "S4: a persistent un-killable survivor exhausts the cap -> NOT Clean");

  if (failures == 0) { printf("PASS fixed-point %d checks\n", total); return 0; }
  printf("FAIL fixed-point %d of %d check(s) failed\n", failures, total);
  return 1;
}
