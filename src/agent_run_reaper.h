/* MS6.5 (rev 19, the user's decision 2026-10-21): best-effort cleanup of an agent run's leftover processes with
 * PUBLIC APIs only (no sandbox_check, no private SPI). A detached escaper (double-fork + setsid) is accepted,
 * cleaned up here, and any survivor surfaces a drawer warning. See the plan MS6.5.
 *
 * The kill-safety-critical logic — which pids match, which get a signal, how a full/overflowing scan is
 * reported — is a PORTABLE decision engine over INJECTED primitives (scan/inspect/kill), so it is unit-tested on
 * Linux with fakes and the kill intercepted before the OS (RoseCat a2fd8af/f907e95). The macOS libproc + real
 * kill that back it in production (zb_reaper_census/sweep) are the only part that must run on a Mac. */
#ifndef ZB_AGENT_RUN_REAPER_H
#define ZB_AGENT_RUN_REAPER_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- pure classification (portable) ---- */

/* 1 iff `path` is `dir` or lies strictly inside it, compared by WHOLE components (`/a/b/x` and `/a/b` are under
 * `/a/b`, but `/a/bc` is not). Trailing slashes on dir ignored. Null/empty path or dir, and dir "/" are refused. */
int zb_reaper_path_under(const char *path, const char *dir);

/* 1 iff a process with this cwd/exe/`nfds` open-file paths is a survivor of the run rooted at `run_dir`. */
int zb_reaper_classify(const char *cwd, const char *exe, const char *const *fd_paths, int nfds,
                       const char *run_dir);

/* 1 iff `dir`'s basename is EXACTLY the sockdirPath grammar `zigbrowser-agent-<pid>-<16 lowercase hex>`
 * (RoseCat f907e95 #2), and `dir` is absolute, canonical (no "//", "/./", "/../") and at least two components
 * deep. Rejects "/", "/tmp", "/Users/<user>", "$HOME", a loose prefix, uppercase hex, a wrong-length suffix, and
 * any dir the app did not create. Pure (name only); the sweep ALSO stats the resolved dir for dir-type, this
 * uid's ownership and mode 0700 before trusting it. */
int zb_reaper_run_dir_ok(const char *dir);

/* ---- the injectable decision engine (portable; the Linux kill-safety proof) ---- */

/* A pid's identity for kill-time re-validation. A gather failure leaves matches=0/have_bsd=0 (fail closed). */
struct zb_reaper_id {
  int matches;
  int have_bsd;
  uid_t uid;
  uint64_t start_sec;
  uint64_t start_usec;
};

/* The primitives the engine drives. Production wires libproc + real kill; tests wire fakes that record and never
 * touch the OS. `killsig` returns 0 on success or the errno (so ESRCH/EPERM are visible without a global). */
struct zb_reaper_ops {
  void (*inspect)(pid_t pid, const char *dir, struct zb_reaper_id *out, void *ctx);
  int (*killsig)(pid_t pid, int sig, void *ctx);
  void *ctx;
};

/* Build the pid list via the injected `scan` (proc_listallpids-shaped: fill buf of `bytes`, RETURN THE COUNT of
 * pids — not bytes — or <= 0 on error). Grows + retries when the buffer fills exactly. Returns 0 and fills
 * *out (malloc'd, caller frees) + *out_n; -1 when the buffer stayed full through the retries (INCOMPLETE — the
 * caller must NOT report a clean result); -2 on empty/alloc error (RoseCat f907e95 #1). */
int zb_reaper_gather(int (*scan)(void *buf, int bytes), pid_t **out, int *out_n);

/* The decision engine over `pids[0..npids)` against the resolved `dir`. Skips pid <= 1, ourselves, and any pid
 * not of our uid. census (kill_them=0): list matching pids, NO signal. sweep (kill_them=1): re-inspect each match
 * immediately before SIGKILL and skip a vanished / reused (changed uid or start time) / no-longer-matching pid;
 * a killsig errno other than ESRCH counts the pid a survivor, ESRCH counts it gone. `*overflow` is set when a
 * list would exceed its cap (truncated — never a clean result). Returns 0. */
int zb_reaper_engine(const struct zb_reaper_ops *ops, const pid_t *pids, int npids, const char *dir,
                     int kill_them, int *killed, int kcap, int *kn, int *surv, int scap, int *sn, int *overflow);

/* gather (via the injected scan) + the engine, mapping a failed scan to a NON-ZERO return, never a clean empty
 * result (RoseCat 9dfc9c7 #1): EOVERFLOW when the scan was incomplete, EIO on a scan/alloc error (both also set
 * *overflow), else the engine's 0. The macOS wrappers call this after pinning the run dir; tests drive it with a
 * fake scan + fake ops to prove the wrapper-level causal reds. */
int zb_reaper_run_full(int (*scan)(void *buf, int bytes), const struct zb_reaper_ops *ops, const char *dir,
                       int kill_them, int *killed, int kcap, int *kn, int *surv, int scap, int *sn, int *overflow);

/* The creation-pinned run-dir identity (RoseCat 9dfc9c7 #2): compared from a no-follow dir fd's fstat, not a
 * pathname, so a swapped path is caught. */
struct zb_reaper_dir_id {
  dev_t dev;
  ino_t ino;
  uid_t uid;
  unsigned mode;
};
int zb_reaper_dir_id_eq(const struct zb_reaper_dir_id *a, const struct zb_reaper_dir_id *b);

/* Pin the resolved run dir by a NO-FOLLOW dir fd: it must be a directory, this uid's, mode 0700, pass
 * zb_reaper_run_dir_ok, and the fd and the path must agree on (dev, ino). Returns the held fd (>= 0, the caller
 * closes it) and fills *id, or -1 on any failure. Portable (open/fstat/stat), so it is unit-tested on Linux with
 * a real path swap. */
int zb_reaper_pin_dir(const char *resolved, struct zb_reaper_dir_id *id);

/* Do the held fd and the path still name the pinned dir (same identity, path still that inode)? Run immediately
 * BEFORE the scan/SIGKILL and again after, so a path swap is caught before any signal (RoseCat 3da2862 #2). */
int zb_reaper_dir_still_pinned(int fd, const char *resolved, const struct zb_reaper_dir_id *id);

#ifdef __APPLE__
/* Production: realpath() the run dir and REFUSE unless zb_reaper_run_dir_ok accepts it AND it stats as a dir
 * owned by this uid with mode 0700 (realpath failure = refusal, no fallback); then zb_reaper_gather over
 * proc_listallpids and zb_reaper_engine over libproc inspect + real kill. `*out_overflow` is set to 1 when the
 * scan was INCOMPLETE or a list overflowed — the caller must then treat the result as not-clean (warn/retry),
 * never clean. Returns 0, EINVAL (refused run dir), or EOVERFLOW (incomplete scan). */
int zb_reaper_census(const char *run_dir, int *out_pids, int cap, int *out_n, int *out_overflow);
int zb_reaper_sweep(const char *run_dir, int *out_killed_pids, int killed_cap, int *out_killed_n,
                    int *out_survivor_pids, int survivor_cap, int *out_survivor_n, int *out_overflow);
#endif

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_RUN_REAPER_H */
