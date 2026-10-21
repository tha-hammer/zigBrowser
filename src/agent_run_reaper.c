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

#ifdef __APPLE__
#include <errno.h>
#include <libproc.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

/* Does `pid` have cwd/exe/an open file under `run_dir`? Fills `*out_uid` for the caller's same-uid guard. Any
 * libproc gather that fails is treated as "unknown" (never a match), so a process we cannot inspect is left
 * alone — fail closed against over-killing. */
static int reaper_pid_matches(pid_t pid, const char *run_dir, uid_t *out_uid) {
  if (out_uid) {
    struct proc_bsdinfo bsd;
    *out_uid = (uid_t)-1;
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof bsd) == (int)sizeof bsd) *out_uid = bsd.pbi_uid;
  }
  char exe[PROC_PIDPATHINFO_MAXSIZE];
  const char *exep = (proc_pidpath(pid, exe, sizeof exe) > 0) ? exe : NULL;
  struct proc_vnodepathinfo vpi;
  const char *cwd = NULL;
  if (proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, sizeof vpi) == (int)sizeof vpi) cwd = vpi.pvi_cdir.vip_path;
  if (zb_reaper_classify(cwd, exep, NULL, 0, run_dir)) return 1;

  int bufsz = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
  if (bufsz <= 0) return 0;
  struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc((size_t)bufsz);
  if (fds == NULL) return 0;
  int got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, bufsz);
  int n = (got > 0) ? got / (int)sizeof(struct proc_fdinfo) : 0;
  int match = 0;
  for (int i = 0; i < n && !match; i++) {
    if (fds[i].proc_fdtype != PROX_FDTYPE_VNODE) continue;
    struct vnode_fdinfowithpath vi;
    if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDVNODEPATHINFO, &vi, sizeof vi) == (int)sizeof vi)
      if (zb_reaper_path_under(vi.pvip.vip_path, run_dir)) match = 1;
  }
  free(fds);
  return match;
}

/* Is `pid` gone? kill(pid, 0) == ESRCH. A SIGKILLed detached process becomes a zombie reparented to launchd,
 * which reaps it in a few ms, so poll briefly (bounded) rather than report a live survivor. */
static int reaper_gone_within(pid_t pid, int grace_ms) {
  for (int waited = 0;; waited += 10) {
    if (kill(pid, 0) != 0 && errno == ESRCH) return 1;
    if (waited >= grace_ms) return 0;
    struct timespec ts = {0, 10 * 1000 * 1000};
    nanosleep(&ts, NULL);
  }
}

static int reaper_enumerate(const char *run_dir, int kill_them, int *killed, int kcap, int *kn,
                            int *surv, int scap, int *sn) {
  if (kn) *kn = 0;
  if (sn) *sn = 0;
  if (run_dir == NULL || run_dir[0] == '\0') return 0; /* refused: sweep nothing */

  /* The kernel reports cwd/exe/fd paths fully RESOLVED (macOS /tmp -> /private/tmp, /var -> /private/var), so the
   * run dir must be resolved too or nothing matches. If it no longer exists (realpath fails), fall back to the
   * given string — best-effort against a survivor still holding a since-deleted run dir. */
  char resolved[PATH_MAX];
  const char *dir = (realpath(run_dir, resolved) != NULL) ? resolved : run_dir;

  int cap = proc_listallpids(NULL, 0);
  if (cap <= 0) return 0;
  cap += 64; /* slack for pids spawned during the scan */
  pid_t *pids = (pid_t *)malloc((size_t)cap * sizeof(pid_t));
  if (pids == NULL) return ENOMEM;
  int bytes = proc_listallpids(pids, cap * (int)sizeof(pid_t));
  int n = (bytes > 0) ? bytes / (int)sizeof(pid_t) : 0;

  const pid_t self = getpid();
  const uid_t myuid = getuid();
  for (int i = 0; i < n; i++) {
    const pid_t pid = pids[i];
    if (pid <= 1 || pid == self) continue; /* never 0/1/self: kill(-1)/kill(0)/suicide */
    uid_t uid = (uid_t)-1;
    if (!reaper_pid_matches(pid, dir, &uid) || uid != myuid) continue;
    if (!kill_them) {
      if (surv && sn && *sn < scap) surv[(*sn)++] = pid;
      continue;
    }
    /* RE-CHECK the marker and uid immediately before the signal (the pid could have exited and been reused). */
    uid_t uid2 = (uid_t)-1;
    if (pid <= 1 || pid == self) continue;
    if (!reaper_pid_matches(pid, dir, &uid2) || uid2 != myuid) continue;
    (void)kill(pid, SIGKILL);
    if (reaper_gone_within(pid, 500)) {
      if (killed && kn && *kn < kcap) killed[(*kn)++] = pid;
    } else {
      if (surv && sn && *sn < scap) surv[(*sn)++] = pid;
    }
  }
  free(pids);
  return 0;
}

int zb_reaper_census(const char *run_dir, int *out_pids, int cap, int *out_n) {
  return reaper_enumerate(run_dir, 0, NULL, 0, NULL, out_pids, cap, out_n);
}

int zb_reaper_sweep(const char *run_dir, int *out_killed_pids, int killed_cap, int *out_killed_n,
                    int *out_survivor_pids, int survivor_cap, int *out_survivor_n) {
  return reaper_enumerate(run_dir, 1, out_killed_pids, killed_cap, out_killed_n,
                          out_survivor_pids, survivor_cap, out_survivor_n);
}
#endif /* __APPLE__ */
