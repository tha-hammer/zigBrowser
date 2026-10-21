/* MS6.5 run-survivor reaper (the user's decision 2026-10-21; RoseCat a2fd8af/f907e95). See agent_run_reaper.h.
 * The pure classification, the run-dir grammar, the pid-list gather and the decision engine are PORTABLE and
 * unit-tested on Linux with injected fakes (the kill intercepted before the OS). Only the macOS libproc + real
 * kill wrappers at the bottom must run on a Mac. */
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
  if (*p < '0' || *p > '9') return 0; /* at least one pid digit */
  while (*p >= '0' && *p <= '9') p++;
  if (*p != '-') return 0;
  p++;
  for (int i = 0; i < 16; i++) {
    const char c = p[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0; /* lowercase hex only */
  }
  return p[16] == '\0';
}

int zb_reaper_run_dir_ok(const char *dir) {
  if (dir == NULL || dir[0] != '/') return 0; /* absolute only */
  const size_t n = strlen(dir);
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
  return name_is_sockdir(base + 1);
}

/* ---- the injectable decision engine (portable) ---- */

static void collect(int *arr, int cap, int *nn, int *overflow, pid_t pid) {
  /* A match with nowhere to go (null array/count) or past the cap is UNREPRESENTABLE: flag overflow so the
   * result is never counted clean (RoseCat f907e95 #6, 9dfc9c7 #4). */
  if (arr == NULL || nn == NULL || *nn >= cap) {
    if (overflow) *overflow = 1;
    return;
  }
  arr[(*nn)++] = (int)pid;
}

static int same_proc(const struct zb_reaper_id *a, const struct zb_reaper_id *b) {
  return a->have_bsd && b->have_bsd && a->uid == b->uid &&
         a->start_sec == b->start_sec && a->start_usec == b->start_usec;
}

static int engine_gone(const struct zb_reaper_ops *ops, pid_t pid, int grace_ms) {
  if (pid <= 1) return 1; /* belt: never probe a bad pid */
  for (int waited = 0;; waited += 10) {
    if (ops->killsig(pid, 0, ops->ctx) == ESRCH) return 1; /* ESRCH = gone */
    if (waited >= grace_ms) return 0;
    struct timespec ts = {0, 10 * 1000 * 1000};
    nanosleep(&ts, NULL);
  }
}

int zb_reaper_engine(const struct zb_reaper_ops *ops, const pid_t *pids, int npids, const char *dir,
                     int kill_them, int *killed, int kcap, int *kn, int *surv, int scap, int *sn, int *overflow) {
  if (overflow == NULL) return EINVAL; /* output contract: a truncation/unrepresentable match MUST be reportable */
  *overflow = 0;
  if (kn) *kn = 0;
  if (sn) *sn = 0;
  const pid_t self = getpid();
  const uid_t myuid = getuid();
  for (int i = 0; i < npids; i++) {
    const pid_t pid = pids[i];
    if (pid <= 1 || pid == self) continue; /* never 0/1/self: kill(-1)/kill(0)/suicide */
    struct zb_reaper_id id0;
    ops->inspect(pid, dir, &id0, ops->ctx);
    if (!id0.matches || !id0.have_bsd || id0.uid != myuid) continue; /* must match, be inspectable, be ours */
    if (!kill_them) {
      collect(surv, scap, sn, overflow, pid);
      continue;
    }
    if (pid <= 1 || pid == self) continue; /* belt before the signal */
    struct zb_reaper_id id1;
    ops->inspect(pid, dir, &id1, ops->ctx);
    if (!id1.matches || id1.uid != myuid || !same_proc(&id0, &id1)) continue; /* vanished/reused/changed: skip */
    const int e = ops->killsig(pid, SIGKILL, ops->ctx);
    if (e != 0 && e != ESRCH) { /* EPERM etc: NOT killed -> survivor */
      collect(surv, scap, sn, overflow, pid);
      continue;
    }
    if (engine_gone(ops, pid, 500)) collect(killed, kcap, kn, overflow, pid); /* ESRCH/gone */
    else collect(surv, scap, sn, overflow, pid);
  }
  return 0;
}

int zb_reaper_gather(int (*scan)(void *buf, int bytes), pid_t **out, int *out_n) {
  const int est = scan(NULL, 0); /* an estimated COUNT */
  if (est < 0) return -2;        /* sizing error: NOT a proven-empty set */
  int cap = est;
  pid_t *pids = NULL;
  for (int attempt = 0; attempt < 5; attempt++) {
    cap += 64; /* slack for pids spawned during the scan */
    pid_t *grown = (pid_t *)realloc(pids, (size_t)cap * sizeof(pid_t));
    if (grown == NULL) { free(pids); return -2; } /* allocation failure: NOT clean */
    pids = grown;
    const int n = scan(pids, cap * (int)sizeof(pid_t)); /* the COUNT of pids filled, NOT bytes */
    if (n < 0) { free(pids); return -2; }               /* scan error: NOT clean */
    if (n < cap) { *out = pids; *out_n = n; return 0; } /* buffer not full: complete (n == 0 is a proven empty set) */
    /* n >= cap: the buffer filled exactly and may be truncated -> grow and retry */
  }
  free(pids);
  return -1; /* still full after the retries: INCOMPLETE, never report a clean result */
}

int zb_reaper_run_full(int (*scan)(void *buf, int bytes), const struct zb_reaper_ops *ops, const char *dir,
                       int kill_them, int *killed, int kcap, int *kn, int *surv, int scap, int *sn, int *overflow) {
  if (overflow == NULL) return EINVAL; /* output contract (RoseCat 3da2862 #3) */
  *overflow = 0;
  if (kn) *kn = 0;
  if (sn) *sn = 0;
  pid_t *pids = NULL;
  int n = 0;
  const int g = zb_reaper_gather(scan, &pids, &n);
  if (g == -1) { *overflow = 1; return EOVERFLOW; } /* incomplete scan: not clean */
  if (g == -2) { *overflow = 1; return EIO; }       /* scan failure: not clean (RoseCat 9dfc9c7 #1) */
  const int rc = zb_reaper_engine(ops, pids, n, dir, kill_them, killed, kcap, kn, surv, scap, sn, overflow);
  free(pids);
  return rc;
}

int zb_reaper_dir_id_eq(const struct zb_reaper_dir_id *a, const struct zb_reaper_dir_id *b) {
  return a->dev == b->dev && a->ino == b->ino && a->uid == b->uid && a->mode == b->mode;
}

/* Pin the resolved run dir by a NO-FOLLOW dir fd (RoseCat 9dfc9c7 #2, 3da2862): it must be a directory, this
 * uid's, mode 0700, pass the grammar, and the fd and the path must agree on (dev, ino) — so a symlink / path
 * swap between realpath and use is caught. Returns the held fd (>= 0, caller closes) and fills *id, or -1.
 * Portable (open/fstat/stat only), so it is unit-tested on Linux with a real path swap. */
int zb_reaper_pin_dir(const char *resolved, struct zb_reaper_dir_id *id) {
  if (resolved == NULL || id == NULL || !zb_reaper_run_dir_ok(resolved)) return -1;
  int fd = open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -1;
  struct stat f, p;
  if (fstat(fd, &f) != 0 || stat(resolved, &p) != 0 || !S_ISDIR(f.st_mode) || f.st_uid != getuid() ||
      (f.st_mode & 0777) != 0700 || f.st_dev != p.st_dev || f.st_ino != p.st_ino) {
    close(fd);
    return -1;
  }
  id->dev = f.st_dev;
  id->ino = f.st_ino;
  id->uid = f.st_uid;
  id->mode = (unsigned)f.st_mode;
  return fd;
}

/* The held fd and the path still agree on the pinned identity? (the no-swap check, run BEFORE and after the
 * scan). A path swapped to a different inode, or a changed dir identity, returns 0. */
int zb_reaper_dir_still_pinned(int fd, const char *resolved, const struct zb_reaper_dir_id *id) {
  struct stat fs, ps;
  if (fd < 0 || resolved == NULL || id == NULL) return 0;
  if (fstat(fd, &fs) != 0 || stat(resolved, &ps) != 0) return 0;
  struct zb_reaper_dir_id now = {fs.st_dev, fs.st_ino, fs.st_uid, (unsigned)fs.st_mode};
  return zb_reaper_dir_id_eq(&now, id) && ps.st_dev == id->dev && ps.st_ino == id->ino;
}

/* ---- macOS production wrappers (libproc + real kill; Mac-only) ---- */

#ifdef __APPLE__
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <sys/proc_info.h>
#include <sys/stat.h>

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

static int reaper_public(const char *run_dir, int kill_them, int *killed, int kcap, int *kn,
                         int *surv, int scap, int *sn, int *overflow) {
  if (overflow == NULL) return EINVAL; /* output contract: truncation must be reportable (RoseCat 3da2862 #3) */
  *overflow = 0;
  if (kn) *kn = 0;
  if (sn) *sn = 0;
  if (run_dir == NULL) return EINVAL;
  char resolved[PATH_MAX];
  if (realpath(run_dir, resolved) == NULL) return EINVAL; /* fail closed, no raw-string fallback */
  struct zb_reaper_dir_id id;
  const int fd = zb_reaper_pin_dir(resolved, &id); /* open + validate the pinned dir BEFORE anything else */
  if (fd < 0) return EINVAL;
  /* re-check the pathname STILL names the pinned dir immediately BEFORE the scan/inspect/SIGKILL (RoseCat
   * 3da2862 #2) — not only after. */
  if (!zb_reaper_dir_still_pinned(fd, resolved, &id)) { close(fd); return EINVAL; }

  struct zb_reaper_ops ops = {reaper_inspect_real, reaper_killsig_real, NULL};
  int rc = zb_reaper_run_full(reaper_scan_real, &ops, resolved, kill_them, killed, kcap, kn, surv, scap, sn, overflow);
  if (!zb_reaper_dir_still_pinned(fd, resolved, &id)) { /* a swap during the run: result is not clean */
    *overflow = 1;
    if (rc == 0) rc = EINVAL;
  }
  close(fd);
  return rc;
}

int zb_reaper_census(const char *run_dir, int *out_pids, int cap, int *out_n, int *out_overflow) {
  return reaper_public(run_dir, 0, NULL, 0, NULL, out_pids, cap, out_n, out_overflow);
}

int zb_reaper_sweep(const char *run_dir, int *out_killed_pids, int killed_cap, int *out_killed_n,
                    int *out_survivor_pids, int survivor_cap, int *out_survivor_n, int *out_overflow) {
  return reaper_public(run_dir, 1, out_killed_pids, killed_cap, out_killed_n,
                       out_survivor_pids, survivor_cap, out_survivor_n, out_overflow);
}
#endif /* __APPLE__ */
