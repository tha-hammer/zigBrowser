/* MS6.5 reaper decision engine + gather, proven on Linux with the kill INTERCEPTED before the OS (RoseCat
 * f907e95 #1/#3/#6). No real signal is ever sent: fake_killsig records calls and returns a controlled errno.
 * The causal oracles: a stable match is killed; a changed-identity / vanished / wrong-uid / pid<=1 / self pid
 * gets NO signal; EPERM is a survivor; ESRCH is gone. gather interprets the scan return as a COUNT (not bytes)
 * and reports a persistently-full buffer as INCOMPLETE. Overflow past a small cap is reported, never clean. */
#include "agent_run_reaper.h"

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int failures = 0;
static int total = 0;
static void check(int ok, const char *msg) { total++; printf("  %s %s\n", ok ? "ok" : "FAIL", msg); if (!ok) failures++; }

/* ---- fake process table + intercepted kill (engine) ---- */
#define MAXP 24
static struct fp {
  pid_t pid;
  int matches[2];   /* match result on the 1st (scan) and 2nd (pre-kill) inspect */
  int have_bsd;
  uid_t uid;
  uid_t uid2;       /* uid reported on the 2nd inspect (0 = same as uid): models a reused pid */
  uint64_t start[2];
  int killret;      /* errno fake_killsig returns for SIGKILL (0 = sent) */
  int gone;         /* after a SIGKILL, does sig-0 report ESRCH? */
  int inspect_calls;
  int sigkills;     /* recorded SIGKILLs aimed at this pid */
} T[MAXP];
static int TN;

static int find(pid_t pid) { for (int i = 0; i < TN; i++) if (T[i].pid == pid) return i; return -1; }

static void fake_inspect(pid_t pid, const char *dir, struct zb_reaper_id *out, void *ctx) {
  (void)dir; (void)ctx;
  memset(out, 0, sizeof *out);
  int i = find(pid);
  if (i < 0) return; /* unknown pid: no match, no bsd */
  int call = T[i].inspect_calls == 0 ? 0 : 1;
  T[i].inspect_calls++;
  out->matches = T[i].matches[call];
  out->have_bsd = T[i].have_bsd;
  out->uid = (call == 1 && T[i].uid2 != 0) ? T[i].uid2 : T[i].uid;
  out->start_sec = T[i].start[call];
  out->start_usec = 0;
}

static int fake_killsig(pid_t pid, int sig, void *ctx) {
  (void)ctx;
  int i = find(pid);
  if (i < 0) return ESRCH;
  if (sig == 0) return (T[i].gone && T[i].sigkills > 0) ? ESRCH : 0;
  T[i].sigkills++; /* a SIGKILL was aimed here (recorded, not sent to the OS) */
  return T[i].killret;
}

static int sigkills_for(pid_t pid) { int i = find(pid); return i < 0 ? -1 : T[i].sigkills; }
static int in_list(const int *a, int n, pid_t pid) { for (int i = 0; i < n; i++) if (a[i] == (int)pid) return 1; return 0; }

/* fake dir_ok: returns 1 for the first `dir_ok_budget` calls, then 0 — models the pinned dir changing mid-run. */
static int dir_ok_budget;
static int fake_dir_ok(void *ctx) { (void)ctx; if (dir_ok_budget > 0) { dir_ok_budget--; return 1; } return 0; }

static void reset(void) { memset(T, 0, sizeof T); TN = 0; dir_ok_budget = 1 << 30; }
static void add(pid_t pid, int m1, int m2, uid_t uid, uint64_t s1, uint64_t s2, int killret, int gone) {
  T[TN].pid = pid; T[TN].matches[0] = m1; T[TN].matches[1] = m2; T[TN].have_bsd = 1;
  T[TN].uid = uid; T[TN].start[0] = s1; T[TN].start[1] = s2; T[TN].killret = killret; T[TN].gone = gone;
  T[TN].inspect_calls = 0; T[TN].sigkills = 0; TN++;
}

/* ---- fake scan (gather) ---- */
static int scan_mode; /* 0 = fill `scan_fill`; 1 = always full; 2 = empty; 3 = error */
static int scan_fill;
static int fake_scan(void *buf, int bytes) {
  if (scan_mode == 3) return -1; /* sizing/scan error */
  if (buf == NULL) return 16;    /* estimate */
  int capn = bytes / (int)sizeof(pid_t);
  if (scan_mode == 2) return 0;
  pid_t *p = (pid_t *)buf;
  if (scan_mode == 1) { for (int i = 0; i < capn; i++) p[i] = 1000 + i; return capn; } /* full: count == cap */
  int k = scan_fill < capn ? scan_fill : capn;
  for (int i = 0; i < k; i++) p[i] = 2000 + i;
  return k; /* a COUNT < cap */
}

int main(void) {
  const uid_t me = getuid();
  const pid_t self = getpid();
  struct zb_reaper_ops ops = {fake_inspect, fake_killsig, fake_dir_ok, NULL};
  int killed[8], surv[8], kn, sn, ov;

  /* sweep over every oracle at once */
  reset();
  add(1000, 1, 1, me, 5, 5, 0, 1);          /* A: stable match -> killed */
  add(1001, 1, 1, me, 5, 9, 0, 1);          /* B: changed start time -> skip */
  add(1002, 1, 0, me, 5, 5, 0, 1);          /* C: vanished on re-inspect -> skip */
  add(1003, 1, 1, me + 1, 5, 5, 0, 1);      /* D: wrong uid on both inspects -> skip */
  add(1004, 1, 1, me, 5, 5, EPERM, 1);      /* E: EPERM -> survivor, exactly one signal */
  add(1005, 1, 1, me, 5, 5, ESRCH, 1);      /* F: ESRCH on SIGKILL -> gone, exactly one signal */
  add(1, 1, 1, me, 5, 5, 0, 1);             /* G: pid 1 -> never signalled */
  add(self, 1, 1, me, 5, 5, 0, 1);          /* H: ourselves -> never signalled */
  add(1006, 1, 1, me, 5, 5, 0, 1);          /* I: uid CHANGES between inspects (reused pid) -> skip */
  T[find(1006)].uid2 = me + 1;
  kn = sn = ov = 0;
  zb_reaper_engine(&ops, (pid_t[]){1000, 1001, 1002, 1003, 1004, 1005, 1, self, 1006}, 9, "/run/x", 1,
                   killed, 8, &kn, surv, 8, &sn, &ov);
  check(in_list(killed, kn, 1000) && sigkills_for(1000) == 1, "A stable match is killed (one signal)");
  check(!in_list(killed, kn, 1001) && !in_list(surv, sn, 1001) && sigkills_for(1001) == 0, "B changed start time: no signal");
  check(!in_list(killed, kn, 1002) && sigkills_for(1002) == 0, "C vanished: no signal");
  check(!in_list(killed, kn, 1003) && sigkills_for(1003) == 0, "D wrong uid: no signal");
  check(in_list(surv, sn, 1004) && !in_list(killed, kn, 1004) && sigkills_for(1004) == 1, "E EPERM: survivor, EXACTLY one signal");
  check(in_list(killed, kn, 1005) && sigkills_for(1005) == 1, "F ESRCH on SIGKILL: gone, EXACTLY one signal");
  check(sigkills_for(1) == 0, "G pid 1 is never signalled");
  check(sigkills_for(self) == 0, "H self is never signalled");
  check(!in_list(killed, kn, 1006) && !in_list(surv, sn, 1006) && sigkills_for(1006) == 0, "I changed uid between inspects: no signal");
  check(ov == 0, "no overflow for this set");

  /* census sends NO signal */
  reset();
  add(1000, 1, 1, me, 5, 5, 0, 1);
  add(1001, 1, 1, me, 5, 5, 0, 1);
  kn = sn = ov = 0;
  zb_reaper_engine(&ops, (pid_t[]){1000, 1001}, 2, "/run/x", 0, killed, 8, &kn, surv, 8, &sn, &ov);
  check(sn == 2 && in_list(surv, sn, 1000) && in_list(surv, sn, 1001), "census lists both matches");
  check(sigkills_for(1000) == 0 && sigkills_for(1001) == 0, "census sends NO signal");

  /* overflow: cap 1, two matches */
  reset();
  add(1000, 1, 1, me, 5, 5, 0, 1);
  add(1001, 1, 1, me, 5, 5, 0, 1);
  kn = sn = ov = 0;
  zb_reaper_engine(&ops, (pid_t[]){1000, 1001}, 2, "/run/x", 1, killed, 1, &kn, surv, 8, &sn, &ov);
  check(ov == 1 && kn == 1, "overflow past a small cap is reported, list truncated");

  /* gather: count (not bytes), incomplete, empty */
  pid_t *pids = NULL; int gn = 0;
  scan_mode = 0; scan_fill = 3; pids = NULL; gn = 0;
  check(zb_reaper_gather(fake_scan, &pids, &gn) == 0 && gn == 3 && pids && pids[0] == 2000,
        "gather reads the scan return as a COUNT (3), not bytes");
  free(pids);
  scan_mode = 1; pids = NULL; gn = 0;
  check(zb_reaper_gather(fake_scan, &pids, &gn) == -1, "gather reports a persistently-full buffer as INCOMPLETE");
  scan_mode = 2; scan_fill = 0; pids = NULL; gn = 0;
  check(zb_reaper_gather(fake_scan, &pids, &gn) == 0 && gn == 0, "gather treats a successful zero-pid scan as a proven empty set");
  free(pids);
  scan_mode = 3; pids = NULL; gn = 0;
  check(zb_reaper_gather(fake_scan, &pids, &gn) == -2, "gather reports a scan error (NOT a clean empty set)");

  /* collect with no output array: an unrepresentable match must flag overflow, never silently drop */
  reset();
  add(1000, 1, 1, me, 5, 5, 0, 1);
  ov = 0;
  zb_reaper_engine(&ops, (pid_t[]){1000}, 1, "/run/x", 0, NULL, 0, NULL, NULL, 0, NULL, &ov);
  check(ov == 1, "a match with a null output array is flagged overflow (never silently clean)");

  /* the output contract: a null overflow pointer is refused, so truncation can never go unreported */
  reset();
  add(1000, 1, 1, me, 5, 5, 0, 1);
  check(zb_reaper_engine(&ops, (pid_t[]){1000}, 1, "/run/x", 1, killed, 8, &kn, surv, 8, &sn, NULL) == EINVAL,
        "engine refuses a null overflow pointer (output contract)");

  /* run_full: a scan failure/incomplete must map to a NON-ZERO return, never a clean empty result */
  int k2[8], s2[8], kn2, sn2, ov2, r;
  scan_mode = 3;
  reset();
  kn2 = sn2 = ov2 = 0;
  r = zb_reaper_run_full(fake_scan, &ops, "/run/x", 1, k2, 8, &kn2, s2, 8, &sn2, &ov2);
  check(r == EIO && ov2 == 1, "run_full: a scan error returns EIO + overflow (not clean empty)");
  scan_mode = 1;
  reset();
  kn2 = sn2 = ov2 = 0;
  r = zb_reaper_run_full(fake_scan, &ops, "/run/x", 1, k2, 8, &kn2, s2, 8, &sn2, &ov2);
  check(r == EOVERFLOW && ov2 == 1, "run_full: an incomplete scan returns EOVERFLOW + overflow");
  scan_mode = 0;
  scan_fill = 1;
  reset();
  add(2000, 1, 1, me, 5, 5, 0, 1); /* the pid fake_scan fills (2000) is a stable match */
  kn2 = sn2 = ov2 = 0;
  r = zb_reaper_run_full(fake_scan, &ops, "/run/x", 1, k2, 8, &kn2, s2, 8, &sn2, &ov2);
  check(r == 0 && in_list(k2, kn2, 2000) && ov2 == 0, "run_full: a normal scan runs the engine (match killed, clean)");

  /* per-kill dir_ok: the pinned dir goes invalid after the first kill -> the rest get NO signal (c09d439 #2) */
  scan_mode = 0;
  reset();
  add(1000, 1, 1, me, 5, 5, 0, 1);
  add(1001, 1, 1, me, 5, 5, 0, 1);
  dir_ok_budget = 1; /* only the first kill's revalidation passes */
  kn = sn = ov = 0;
  zb_reaper_engine(&ops, (pid_t[]){1000, 1001}, 2, "/run/x", 1, killed, 8, &kn, surv, 8, &sn, &ov);
  check(sigkills_for(1000) == 1 && in_list(killed, kn, 1000), "per-kill dir_ok: the first match is killed");
  check(sigkills_for(1001) == 0 && !in_list(killed, kn, 1001) && !in_list(surv, sn, 1001),
        "per-kill dir_ok: once the dir goes invalid, the next match gets NO signal");
  check(ov == 1, "per-kill dir_ok: an invalidated pin flags overflow (the run is NOT clean, RoseCat 175efb8 #2)");

  /* the full input contract: EINVAL, never a crash or a false success */
  reset();
  {
    pid_t one[] = {1000};
    struct zb_reaper_ops ni = {NULL, fake_killsig, fake_dir_ok, NULL};
    struct zb_reaper_ops nk = {fake_inspect, NULL, fake_dir_ok, NULL};
    struct zb_reaper_ops nd = {fake_inspect, fake_killsig, NULL, NULL};
    check(zb_reaper_engine(NULL, one, 1, "/d", 1, killed, 8, &kn, surv, 8, &sn, &ov) == EINVAL, "engine: null ops");
    check(zb_reaper_engine(&ni, one, 1, "/d", 1, killed, 8, &kn, surv, 8, &sn, &ov) == EINVAL, "engine: null inspect");
    check(zb_reaper_engine(&nk, one, 1, "/d", 1, killed, 8, &kn, surv, 8, &sn, &ov) == EINVAL, "engine: null killsig");
    check(zb_reaper_engine(&nd, one, 1, "/d", 1, killed, 8, &kn, surv, 8, &sn, &ov) == EINVAL, "engine: null dir_ok");
    check(zb_reaper_engine(&ops, NULL, 1, "/d", 1, killed, 8, &kn, surv, 8, &sn, &ov) == EINVAL, "engine: null pids, npids>0");
    check(zb_reaper_engine(&ops, one, -1, "/d", 1, killed, 8, &kn, surv, 8, &sn, &ov) == EINVAL, "engine: negative npids");
    check(zb_reaper_engine(&ops, one, 1, NULL, 1, killed, 8, &kn, surv, 8, &sn, &ov) == EINVAL, "engine: null dir");
    check(zb_reaper_engine(&ops, one, 1, "/d", 1, killed, -1, &kn, surv, 8, &sn, &ov) == EINVAL, "engine: negative kcap");
    check(zb_reaper_engine(&ops, one, 1, "/d", 1, killed, 8, &kn, surv, -1, &sn, &ov) == EINVAL, "engine: negative scap");
    check(zb_reaper_engine(&ops, one, 1, "/d", 1, killed, 8, &kn, surv, 8, &sn, NULL) == EINVAL, "engine: null overflow");
    pid_t *pp = NULL;
    int nn = 0;
    check(zb_reaper_gather(NULL, &pp, &nn) == EINVAL, "gather: null scan");
    check(zb_reaper_gather(fake_scan, NULL, &nn) == EINVAL, "gather: null out");
    check(zb_reaper_gather(fake_scan, &pp, NULL) == EINVAL, "gather: null out_n");
    check(zb_reaper_run_full(NULL, &ops, "/d", 1, killed, 8, &kn, surv, 8, &sn, &ov) == EINVAL, "run_full: null scan");
    check(zb_reaper_run_full(fake_scan, NULL, "/d", 1, killed, 8, &kn, surv, 8, &sn, &ov) == EINVAL, "run_full: null ops");
    check(zb_reaper_run_full(fake_scan, &ops, NULL, 1, killed, 8, &kn, surv, 8, &sn, &ov) == EINVAL, "run_full: null dir");
    check(zb_reaper_run_full(fake_scan, &ops, "/d", 1, killed, 8, &kn, surv, 8, &sn, NULL) == EINVAL, "run_full: null overflow");
  }

  if (failures == 0) { printf("PASS ms6-5-reaper-engine %d checks\n", total); return 0; }
  printf("FAIL ms6-5-reaper-engine %d of %d check(s) failed\n", failures, total);
  return 1;
}
