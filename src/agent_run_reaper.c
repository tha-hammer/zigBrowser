/* MS6.5 run-survivor classification (the user's decision 2026-10-21). See agent_run_reaper.h. The macOS libproc
 * sweep + the guarded kill that use these land with the both-Mac hard-gate case. */
#include "agent_run_reaper.h"

#include <string.h>

int zb_reaper_path_under(const char *path, const char *dir) {
  if (path == NULL || dir == NULL) return 0;
  size_t dl = strlen(dir);
  while (dl > 1 && dir[dl - 1] == '/') dl--; /* ignore trailing slashes on the run dir */
  /* Root ("/") and empty are NEVER run markers: matching them would sweep the whole system. Fail closed. */
  if (dl < 2) return 0;
  if (strncmp(path, dir, dl) != 0) return 0;
  const char c = path[dl];
  return c == '\0' || c == '/'; /* exactly the dir, or a child across a whole path component */
}

int zb_reaper_classify(const char *cwd, const char *exe, const char *const *fd_paths, int nfds,
                       const char *run_dir) {
  if (zb_reaper_path_under(cwd, run_dir)) return 1;
  if (zb_reaper_path_under(exe, run_dir)) return 1;
  for (int i = 0; i < nfds; i++) {
    if (fd_paths != NULL && zb_reaper_path_under(fd_paths[i], run_dir)) return 1;
  }
  return 0;
}

int zb_reaper_run_dir_ok(const char *dir) {
  if (dir == NULL || dir[0] != '/') return 0; /* absolute only */
  size_t n = strlen(dir);
  int slashes = 0;
  for (size_t i = 0; i < n; i++) {
    if (dir[i] != '/') continue;
    slashes++;
    if (dir[i + 1] == '/') return 0; /* "//" is not canonical */
    if (dir[i + 1] == '.') {
      const char c2 = dir[i + 2];
      if (c2 == '\0' || c2 == '/') return 0;                                /* a "/." component */
      if (c2 == '.' && (dir[i + 3] == '\0' || dir[i + 3] == '/')) return 0; /* a "/.." component */
    }
  }
  if (slashes < 2) return 0; /* a parent plus the run component: never a child of root */
  const char *base = strrchr(dir, '/');
  if (base == NULL) return 0;
  base++;
  static const char sig[] = "zigbrowser-agent-"; /* agent_net.sockdirPath's format: the app's own run dir */
  return strncmp(base, sig, sizeof(sig) - 1) == 0;
}

#ifdef __APPLE__
#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* A pid's identity for kill-time re-validation: whether it still matches the run dir, plus the fields a reused
 * pid would change (uid, start time). A gather failure leaves matches=0 and have_bsd=0 — fail closed. */
struct reaper_id {
  int matches;
  int have_bsd;
  uid_t uid;
  uint64_t start_sec;
  uint64_t start_usec;
};

static void reaper_inspect(pid_t pid, const char *dir, struct reaper_id *out) {
  out->matches = 0;
  out->have_bsd = 0;
  out->uid = (uid_t)-1;
  out->start_sec = 0;
  out->start_usec = 0;
  struct proc_bsdinfo bsd;
  if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof bsd) == (int)sizeof bsd) {
    out->have_bsd = 1;
    out->uid = bsd.pbi_uid;
    out->start_sec = bsd.pbi_start_tvsec;
    out->start_usec = bsd.pbi_start_tvusec;
  }
  char exe[PROC_PIDPATHINFO_MAXSIZE];
  const char *exep = (proc_pidpath(pid, exe, sizeof exe) > 0) ? exe : NULL;
  struct proc_vnodepathinfo vpi;
  const char *cwd = NULL;
  if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof vpi) == (int)sizeof vpi) cwd = vpi.pvi_cdir.vip_path;
  if (zb_reaper_classify(cwd, exep, NULL, 0, dir)) { out->matches = 1; return; }

  int bufsz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
  if (bufsz <= 0) return;
  struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc((size_t)bufsz);
  if (fds == NULL) return;
  int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bufsz);
  int n = (got > 0) ? got / (int)sizeof(struct proc_fdinfo) : 0;
  for (int i = 0; i < n && !out->matches; i++) {
    if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
    struct vnode_fdinfowithpath vi;
    if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, sizeof vi) == (int)sizeof vi)
      if (zb_reaper_path_under(vi.pvip.vip_path, dir)) out->matches = 1;
  }
  free(fds);
}

/* Same running process? Both inspectable, and uid + start time unchanged (a reused pid differs). */
static int reaper_same_proc(const struct reaper_id *a, const struct reaper_id *b) {
  return a->have_bsd && b->have_bsd && a->uid == b->uid &&
         a->start_sec == b->start_sec && a->start_usec == b->start_usec;
}

/* Is `pid` gone? kill(pid, 0) == ESRCH. A SIGKILLed detached process becomes a zombie reparented to launchd,
 * which reaps it in a few ms, so poll briefly (bounded). pid <= 1 is reported gone without a syscall (belt). */
static int reaper_gone_within(pid_t pid, int grace_ms) {
  if (pid <= 1) return 1;
  for (int waited = 0;; waited += 10) {
    if (kill(pid, 0) != 0 && errno == ESRCH) return 1;
    if (waited >= grace_ms) return 0;
    struct timespec ts = {0, 10 * 1000 * 1000};
    nanosleep(&ts, NULL);
  }
}

/* proc_listallpids returns the COUNT of pids filled (RoseCat a2fd8af #1), not bytes. Grow + retry (bounded) when
 * the buffer filled exactly, so a full buffer never silently truncates the scan. Caller frees *out. */
static int reaper_listpids(pid_t **out) {
  int cap = proc_listallpids(NULL, 0);
  if (cap <= 0) return 0;
  pid_t *pids = NULL;
  for (int attempt = 0; attempt < 5; attempt++) {
    cap += 64; /* slack for pids spawned during the scan */
    pid_t *grown = (pid_t *)realloc(pids, (size_t)cap * sizeof(pid_t));
    if (grown == NULL) { free(pids); return 0; }
    pids = grown;
    int n = proc_listallpids(pids, cap * (int)sizeof(pid_t)); /* the count, not bytes */
    if (n <= 0) { free(pids); return 0; }
    if (n < cap) { *out = pids; return n; } /* buffer not full -> we have them all */
  }
  *out = pids; /* bounded give-up: the per-pid guards below still hold */
  return cap;
}

static int reaper_collect(int *arr, int cap, int *nn, int *overflow, pid_t pid) {
  if (arr == NULL || nn == NULL) return 0;
  if (*nn < cap) { arr[(*nn)++] = (int)pid; return 1; }
  if (overflow) *overflow = 1; /* RoseCat a2fd8af #6: report, never silently truncate */
  return 0;
}

static int reaper_enumerate(const char *run_dir, int kill_them, int *killed, int kcap, int *kn,
                            int *surv, int scap, int *sn, int *overflow) {
  if (kn) *kn = 0;
  if (sn) *sn = 0;
  if (overflow) *overflow = 0;

  /* The kernel reports cwd/exe/fd paths fully RESOLVED; resolve the run dir too, and FAIL CLOSED if that fails or
   * the resolved dir is not an app-owned per-run marker. NO raw-string fallback (RoseCat a2fd8af #2). */
  if (run_dir == NULL) return EINVAL;
  char resolved[PATH_MAX];
  if (realpath(run_dir, resolved) == NULL) return EINVAL;
  if (!zb_reaper_run_dir_ok(resolved)) return EINVAL;

  pid_t *pids = NULL;
  int n = reaper_listpids(&pids);
  if (n <= 0) return 0;

  const pid_t self = getpid();
  const uid_t myuid = getuid();
  for (int i = 0; i < n; i++) {
    const pid_t pid = pids[i];
    if (pid <= 1 || pid == self) continue; /* never 0/1/self: kill(-1)/kill(0)/suicide */
    struct reaper_id id0;
    reaper_inspect(pid, resolved, &id0);
    if (!id0.matches || !id0.have_bsd || id0.uid != myuid) continue; /* must match, be inspectable, be ours */
    if (!kill_them) {
      reaper_collect(surv, scap, sn, overflow, pid);
      continue;
    }
    /* RE-VALIDATE immediately before the signal: a survivor can exit and its pid be reused (RoseCat a2fd8af #3). */
    if (pid <= 1 || pid == self) continue;
    struct reaper_id id1;
    reaper_inspect(pid, resolved, &id1);
    if (!id1.matches || id1.uid != myuid || !reaper_same_proc(&id0, &id1)) continue; /* vanished/reused/changed */
    const int kr = kill(pid, SIGKILL);
    if (kr != 0 && errno != ESRCH) { /* unexpected (e.g. EPERM): NOT killed -> survivor */
      reaper_collect(surv, scap, sn, overflow, pid);
      continue;
    }
    if (reaper_gone_within(pid, 500)) reaper_collect(killed, kcap, kn, overflow, pid);
    else reaper_collect(surv, scap, sn, overflow, pid);
  }
  free(pids);
  return 0;
}

int zb_reaper_census(const char *run_dir, int *out_pids, int cap, int *out_n, int *out_overflow) {
  return reaper_enumerate(run_dir, 0, NULL, 0, NULL, out_pids, cap, out_n, out_overflow);
}

int zb_reaper_sweep(const char *run_dir, int *out_killed_pids, int killed_cap, int *out_killed_n,
                    int *out_survivor_pids, int survivor_cap, int *out_survivor_n, int *out_overflow) {
  return reaper_enumerate(run_dir, 1, out_killed_pids, killed_cap, out_killed_n,
                          out_survivor_pids, survivor_cap, out_survivor_n, out_overflow);
}
#endif /* __APPLE__ */
