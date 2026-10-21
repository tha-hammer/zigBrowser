/* MS6.5 run-survivor reaper (the user's decision 2026-10-21; RoseCat a2fd8af/f907e95/3da2862/c09d439). See
 * agent_run_reaper.h. The pure classification, the run-dir grammar, the fd-based pin, the pid-list gather and the
 * decision engine are PORTABLE and unit-tested on Linux with injected fakes (the kill intercepted). Only the
 * macOS libproc + real kill wrappers at the bottom must run on a Mac. */
#include "agent_run_reaper.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* ---- pure classification ---- */

int zb_reaper_path_under(const char *path, const char *dir) {
  if (path == NULL || dir == NULL) return 0;
  size_t dl = strlen(dir);
  while (dl > 1 && dir[dl - 1] == '/') dl--; /* ignore trailing slashes on the run dir */
  if (dl < 2) return 0;                      /* root "/" and empty are never run markers: fail closed */
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

/* basename == "zigbrowser-agent-" <pid: 1+ decimal digits> "-" <exactly 16 lowercase hex>, nothing after. */
static int name_is_sockdir(const char *base) {
  static const char sig[] = "zigbrowser-agent-";
  if (strncmp(base, sig, sizeof(sig) - 1) != 0) return 0;
  const char *p = base + (sizeof(sig) - 1);
  if (*p < '0' || *p > '9') return 0;
  while (*p >= '0' && *p <= '9') p++;
  if (*p != '-') return 0;
  p++;
  for (int i = 0; i < 16; i++) {
    const char c = p[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0;
  }
  return p[16] == '\0';
}

int zb_reaper_run_dir_ok(const char *dir) {
  if (dir == NULL || dir[0] != '/') return 0;
  const size_t n = strlen(dir);
  int slashes = 0;
  for (size_t i = 0; i < n; i++) {
    if (dir[i] != '/') continue;
    slashes++;
    if (dir[i + 1] == '/') return 0;
    if (dir[i + 1] == '.') {
      const char c2 = dir[i + 2];
      if (c2 == '\0' || c2 == '/') return 0;
      if (c2 == '.' && (dir[i + 3] == '\0' || dir[i + 3] == '/')) return 0;
    }
  }
  if (slashes < 2) return 0;
  const char *base = strrchr(dir, '/');
  if (base == NULL) return 0;
  return name_is_sockdir(base + 1);
}

/* ---- the fd-based pinned identity ---- */

int zb_reaper_dir_id_eq(const struct zb_reaper_dir_id *a, const struct zb_reaper_dir_id *b) {
  return a->dev == b->dev && a->ino == b->ino && a->uid == b->uid && a->mode == b->mode;
}

int zb_reaper_pin_fd(int dir_fd, struct zb_reaper_dir_id *out) {
  if (dir_fd < 0 || out == NULL) return EINVAL;
  struct stat f;
  if (fstat(dir_fd, &f) != 0) return EINVAL;
  if (!S_ISDIR(f.st_mode) || f.st_uid != getuid() || (f.st_mode & 0777) != 0700) return EINVAL;
  out->dev = f.st_dev;
  out->ino = f.st_ino;
  out->uid = f.st_uid;
  out->mode = (unsigned)f.st_mode;
  return 0;
}

int zb_reaper_dir_fd_ok(int dir_fd, const struct zb_reaper_dir_id *pinned) {
  if (dir_fd < 0 || pinned == NULL) return 0;
  struct stat f; /* fstat ONLY: never a pathname stat, so a swapped path / symlink-to-the-held-inode cannot fool it */
  if (fstat(dir_fd, &f) != 0) return 0;
  struct zb_reaper_dir_id now = {f.st_dev, f.st_ino, f.st_uid, (unsigned)f.st_mode};
  return S_ISDIR(f.st_mode) && f.st_uid == getuid() && (f.st_mode & 0777) == 0700 &&
         zb_reaper_dir_id_eq(&now, pinned);
}

/* ---- the injectable decision engine (portable) ---- */

static void collect(int *arr, int cap, int *nn, int *overflow, pid_t pid) {
  /* A match with nowhere to go (null array/count) or past the cap is UNREPRESENTABLE: flag overflow so the
   * result is never counted clean (RoseCat f907e95 #6, 9dfc9c7 #4). overflow is guaranteed non-null by the
   * engine's contract check. */
  if (arr == NULL || nn == NULL || *nn >= cap) {
    *overflow = 1;
    return;
  }
  arr[(*nn)++] = (int)pid;
}

static int same_proc(const struct zb_reaper_id *a, const struct zb_reaper_id *b) {
  return a->have_bsd && b->have_bsd && a->uid == b->uid &&
         a->start_sec == b->start_sec && a->start_usec == b->start_usec;
}

static int engine_gone(const struct zb_reaper_ops *ops, pid_t pid, int grace_ms) {
  if (pid <= 1) return 1;
  for (int waited = 0;; waited += 10) {
    if (ops->killsig(pid, 0, ops->ctx) == ESRCH) return 1;
    if (waited >= grace_ms) return 0;
    struct timespec ts = {0, 10 * 1000 * 1000};
    nanosleep(&ts, NULL);
  }
}

int zb_reaper_engine(const struct zb_reaper_ops *ops, const pid_t *pids, int npids, const char *dir,
                     int kill_them, int *killed, int kcap, int *kn, int *surv, int scap, int *sn, int *overflow,
                     int *unresolved) {
  if (overflow == NULL) return EINVAL; /* truncation must be reportable */
  if (ops == NULL || ops->inspect == NULL || ops->killsig == NULL || ops->dir_ok == NULL) return EINVAL;
  if (dir == NULL) return EINVAL;
  if (npids < 0 || (npids > 0 && pids == NULL)) return EINVAL;
  if (kcap < 0 || scap < 0) return EINVAL;
  *overflow = 0;
  if (kn) *kn = 0;
  if (sn) *sn = 0;
  if (unresolved) *unresolved = 0;
  const pid_t self = getpid();
  const uid_t myuid = getuid();
  for (int i = 0; i < npids; i++) {
    const pid_t pid = pids[i];
    if (pid <= 1 || pid == self) continue; /* never 0/1/self: kill(-1)/kill(0)/suicide */
    struct zb_reaper_id id0;
    ops->inspect(pid, dir, &id0, ops->ctx);
    if (!id0.matches || id0.uid != myuid) continue; /* not a survivor of this run, or not ours: silent */
    if (!id0.have_bsd) {
      /* A match of our uid whose identity is UNAVAILABLE. In census it is dropped as before; in a sweep it is a
       * candidate we cannot safely act on and is NOT proven gone -> report it UNRESOLVED, never clean. */
      if (kill_them && unresolved) (*unresolved)++;
      continue;
    }
    if (!kill_them) {
      collect(surv, scap, sn, overflow, pid);
      continue;
    }
    if (pid <= 1 || pid == self) continue; /* belt before the signal */
    struct zb_reaper_id id1;
    ops->inspect(pid, dir, &id1, ops->ctx);
    if (!id1.matches || id1.uid != myuid || !same_proc(&id0, &id1)) {
      /* Matched at id0 but vanished/reused/changed identity or uid at the pre-kill inspect: send NO signal, but
       * it is NOT proven gone -> UNRESOLVED, so the caller must re-census (or report Survivors), never clean. */
      if (unresolved) (*unresolved)++;
      continue;
    }
    /* The pinned dir changed under us: send NO signal, and the whole run is now unsafe to classify — flag it
     * not-clean (overflow) and STOP, so the caller can never report a clean cleanup (RoseCat 175efb8 #2). */
    if (!ops->dir_ok(ops->ctx)) { *overflow = 1; break; }
    const int e = ops->killsig(pid, SIGKILL, ops->ctx);
    if (e != 0 && e != ESRCH) { /* EPERM etc: NOT killed -> survivor */
      collect(surv, scap, sn, overflow, pid);
      continue;
    }
    if (engine_gone(ops, pid, 500)) collect(killed, kcap, kn, overflow, pid);
    else collect(surv, scap, sn, overflow, pid);
  }
  return 0;
}

int zb_reaper_gather(int (*scan)(void *buf, int bytes), pid_t **out, int *out_n) {
  if (scan == NULL || out == NULL || out_n == NULL) return EINVAL;
  const int est = scan(NULL, 0); /* an estimated COUNT */
  if (est < 0) return -2;        /* sizing error: NOT a proven-empty set */
  int cap = est;
  pid_t *pids = NULL;
  for (int attempt = 0; attempt < 5; attempt++) {
    cap += 64; /* slack for pids spawned during the scan */
    pid_t *grown = (pid_t *)realloc(pids, (size_t)cap * sizeof(pid_t));
    if (grown == NULL) { free(pids); return -2; }
    pids = grown;
    const int n = scan(pids, cap * (int)sizeof(pid_t)); /* the COUNT, not bytes */
    if (n < 0) { free(pids); return -2; }               /* scan error */
    if (n < cap) { *out = pids; *out_n = n; return 0; }  /* complete (n == 0 is a proven empty set) */
  }
  free(pids);
  return -1; /* still full after the retries: INCOMPLETE */
}

int zb_reaper_run_full(int (*scan)(void *buf, int bytes), const struct zb_reaper_ops *ops, const char *dir,
                       int kill_them, int *killed, int kcap, int *kn, int *surv, int scap, int *sn, int *overflow,
                       int *unresolved) {
  if (scan == NULL || ops == NULL || dir == NULL || overflow == NULL) return EINVAL;
  *overflow = 0;
  if (kn) *kn = 0;
  if (sn) *sn = 0;
  if (unresolved) *unresolved = 0;
  pid_t *pids = NULL;
  int n = 0;
  const int g = zb_reaper_gather(scan, &pids, &n);
  if (g == EINVAL) return EINVAL;
  if (g == -1) { *overflow = 1; return EOVERFLOW; } /* incomplete scan: not clean */
  if (g == -2) { *overflow = 1; return EIO; }       /* scan failure: not clean */
  const int rc = zb_reaper_engine(ops, pids, n, dir, kill_them, killed, kcap, kn, surv, scap, sn, overflow, unresolved);
  free(pids);
  return rc;
}

int zb_reaper_fixed_point(int (*scan)(void *buf, int bytes), const struct zb_reaper_ops *ops, const char *dir,
                          int max_passes, int *clean, int *passes, int *overflow) {
  if (scan == NULL || ops == NULL || dir == NULL || clean == NULL || passes == NULL || overflow == NULL)
    return EINVAL;
  if (max_passes < 1) return EINVAL;
  *clean = 0;
  *passes = 0;
  *overflow = 0;
  /* The bounded census->kill->fresh-census FIXED POINT. Each pass gathers afresh and sweeps; CLEAN is declared
   * only when a pass matches ZERO pids (kn == 0 && sn == 0), with NO unresolved matches and no overflow — the
   * complete, EMPTY final census. A pass that killed someone (kn > 0), left a survivor (sn > 0), or could not
   * resolve a matched candidate (unresolved > 0 — e.g. its identity flipped at the pre-kill inspect) re-censuses
   * on the next pass, because a marked process may have forked a child after this pass's gather and an unresolved
   * match is NOT proven gone. Any incomplete/overflow/scan error, or exhausting max_passes, is NOT clean (the
   * caller keeps the run in Survivors with its authority). */
  enum { CAP = 256 };
  for (int p = 0; p < max_passes; p++) {
    int killed[CAP], surv[CAP], kn = 0, sn = 0, ov = 0, unres = 0;
    const int rc = zb_reaper_run_full(scan, ops, dir, 1, killed, CAP, &kn, surv, CAP, &sn, &ov, &unres);
    (*passes)++;
    if (rc == EOVERFLOW || rc == EIO) { *overflow = 1; return 0; }        /* incomplete/scan error: not clean */
    if (rc != 0) return rc;                                              /* EINVAL etc: propagate */
    if (ov) { *overflow = 1; return 0; }                                 /* a list overflowed its cap: not clean */
    if (kn == 0 && sn == 0 && unres == 0) { *clean = 1; return 0; }      /* complete EMPTY final census: clean */
    /* kn>0, sn>0, and/or unres>0: matches or unresolved candidates remained; re-census on the next pass. */
  }
  return 0; /* max_passes exhausted without an empty census: *clean stays 0 (Survivors) */
}

/* ---- macOS production wrappers (libproc + real kill; Mac-only) ---- */

#ifdef __APPLE__
#include <libproc.h>
#include <limits.h>
#include <sys/proc_info.h>

struct reaper_ctx {
  int fd;
  const struct zb_reaper_dir_id *pinned;
};

static void reaper_inspect_real(pid_t pid, const char *dir, struct zb_reaper_id *out, void *ctx) {
  (void)ctx;
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
  int m = (got > 0) ? got / (int)sizeof(struct proc_fdinfo) : 0;
  for (int i = 0; i < m && !out->matches; i++) {
    if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
    struct vnode_fdinfowithpath vi;
    if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, sizeof vi) == (int)sizeof vi)
      if (zb_reaper_path_under(vi.pvip.vip_path, dir)) out->matches = 1;
  }
  free(fds);
}

static int reaper_killsig_real(pid_t pid, int sig, void *ctx) { (void)ctx; return kill(pid, sig) == 0 ? 0 : errno; }
static int reaper_scan_real(void *buf, int bytes) { return proc_listallpids(buf, bytes); }

static int reaper_dir_ok_real(void *ctx) {
  const struct reaper_ctx *c = (const struct reaper_ctx *)ctx;
  return zb_reaper_dir_fd_ok(c->fd, c->pinned); /* fstat the HELD fd: no pathname, no symlink follow */
}

static int reaper_public(int run_dir_fd, const struct zb_reaper_dir_id *pinned, int kill_them, int *killed,
                         int kcap, int *kn, int *surv, int scap, int *sn, int *overflow) {
  if (overflow == NULL) return EINVAL;
  *overflow = 0;
  if (kn) *kn = 0;
  if (sn) *sn = 0;
  if (run_dir_fd < 0 || pinned == NULL) return EINVAL;
  if (!zb_reaper_dir_fd_ok(run_dir_fd, pinned)) return EINVAL; /* the held fd must still be the pinned dir */
  char dir[PATH_MAX];
  if (fcntl(run_dir_fd, F_GETPATH, dir) != 0) return EINVAL;   /* the held inode's CURRENT path (swap-immune) */
  if (!zb_reaper_run_dir_ok(dir)) return EINVAL;
  struct reaper_ctx rc = {run_dir_fd, pinned};
  struct zb_reaper_ops ops = {reaper_inspect_real, reaper_killsig_real, reaper_dir_ok_real, &rc};
  return zb_reaper_run_full(reaper_scan_real, &ops, dir, kill_them, killed, kcap, kn, surv, scap, sn, overflow,
                            NULL); /* unresolved: unused here; the Linux fixed point is the clean-decider */
}

int zb_reaper_census(int run_dir_fd, const struct zb_reaper_dir_id *pinned, int *out_pids, int cap, int *out_n,
                     int *out_overflow) {
  return reaper_public(run_dir_fd, pinned, 0, NULL, 0, NULL, out_pids, cap, out_n, out_overflow);
}

int zb_reaper_sweep(int run_dir_fd, const struct zb_reaper_dir_id *pinned, int *out_killed_pids, int killed_cap,
                    int *out_killed_n, int *out_survivor_pids, int survivor_cap, int *out_survivor_n,
                    int *out_overflow) {
  return reaper_public(run_dir_fd, pinned, 1, out_killed_pids, killed_cap, out_killed_n,
                       out_survivor_pids, survivor_cap, out_survivor_n, out_overflow);
}
#endif /* __APPLE__ */
