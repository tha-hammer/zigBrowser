/* MS6.5 (rev 19, the user's decision 2026-10-21): best-effort cleanup of an agent run's leftover processes with
 * PUBLIC APIs only (no sandbox_check, no private SPI). A detached escaper (double-fork + setsid) is accepted,
 * cleaned up here, and any survivor surfaces a drawer warning. See the plan MS6.5.
 *
 * Kill-safety (RoseCat a2fd8af/f907e95/3da2862/c09d439): the run dir is pinned at CREATION by a no-follow dir fd
 * held for the run's life; the reaper revalidates that fd (fstat, never a pathname stat — so no symlink follow)
 * IMMEDIATELY BEFORE EACH destructive signal; and every input is contract-checked. The decision engine is a
 * PORTABLE function over injected primitives (scan/inspect/killsig/dir_ok), unit-tested on Linux with the kill
 * intercepted; only the macOS libproc + real kill wrappers must run on a Mac. */
#ifndef ZB_AGENT_RUN_REAPER_H
#define ZB_AGENT_RUN_REAPER_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- pure classification (portable) ---- */

/* 1 iff `path` is `dir` or lies strictly inside it, by WHOLE components (`/a/b/x` and `/a/b` are under `/a/b`,
 * `/a/bc` is not). Trailing slashes on dir ignored. Null/empty path or dir, and dir "/" are refused. */
int zb_reaper_path_under(const char *path, const char *dir);

/* 1 iff a process with this cwd/exe/`nfds` open-file paths is a survivor of the run rooted at `run_dir`. */
int zb_reaper_classify(const char *cwd, const char *exe, const char *const *fd_paths, int nfds,
                       const char *run_dir);

/* 1 iff `dir`'s basename is EXACTLY the sockdirPath grammar `zigbrowser-agent-<pid>-<16 lowercase hex>` and dir
 * is absolute, canonical (no "//", "/./", "/../"), at least two components deep. Rejects "/", "/tmp",
 * "/Users/<user>", "$HOME", a loose prefix, uppercase hex, a wrong-length suffix. Pure (name only). */
int zb_reaper_run_dir_ok(const char *dir);

/* ---- the creation-pinned run-dir identity (fd-based; no pathname stat, so no symlink follow) ---- */

struct zb_reaper_dir_id {
  dev_t dev;
  ino_t ino;
  uid_t uid;
  unsigned mode;
};
int zb_reaper_dir_id_eq(const struct zb_reaper_dir_id *a, const struct zb_reaper_dir_id *b);

/* Capture the pinned identity from a HELD no-follow dir fd (opened once, at run-dir creation, with
 * O_DIRECTORY|O_NOFOLLOW): fstat it and require a directory, this uid, mode 0700. Returns 0 and fills *out, or
 * EINVAL. The caller holds the fd for the run's whole life; the reaper never re-opens by name. */
int zb_reaper_pin_fd(int dir_fd, struct zb_reaper_dir_id *out);

/* 1 iff the HELD fd still fstats to exactly `pinned` (dir, this uid, 0700, same dev/ino). This is the per-kill
 * revalidation — fstat only, never a pathname stat, so a swapped path or a symlink-to-the-held-inode cannot
 * fool it (RoseCat c09d439 #2/#3). */
int zb_reaper_dir_fd_ok(int dir_fd, const struct zb_reaper_dir_id *pinned);

/* ---- the injectable decision engine (portable; the Linux kill-safety proof) ---- */

struct zb_reaper_id {
  int matches;
  int have_bsd;
  uid_t uid;
  uint64_t start_sec;
  uint64_t start_usec;
};

/* Production wires libproc + real kill + the fd revalidation; tests wire fakes that record and never touch the
 * OS. `killsig` returns 0 or the errno. `dir_ok` is re-checked immediately before EACH SIGKILL; when it returns
 * 0 the engine sends NO signal (the pinned dir is gone/changed). All three callbacks are required. */
struct zb_reaper_ops {
  void (*inspect)(pid_t pid, const char *dir, struct zb_reaper_id *out, void *ctx);
  int (*killsig)(pid_t pid, int sig, void *ctx);
  int (*dir_ok)(void *ctx);
  void *ctx;
};

/* Build the pid list via the injected `scan` (proc_listallpids-shaped: fill buf of `bytes`, RETURN THE COUNT of
 * pids — not bytes — or < 0 on error). Returns 0 and fills *out (malloc'd, caller frees) + *out_n (which may be
 * 0, a proven empty set); -1 when the buffer stayed full through the retries (INCOMPLETE); -2 on a sizing/scan/
 * allocation error (NOT a clean empty set); EINVAL on a null argument. */
int zb_reaper_gather(int (*scan)(void *buf, int bytes), pid_t **out, int *out_n);

/* The decision engine over `pids[0..npids)` against the resolved `dir`. Skips pid <= 1, ourselves, and any pid
 * not of our uid. census (kill_them=0): list matching pids, NO signal. sweep (kill_them=1): re-inspect each
 * match, revalidate the pinned dir (ops->dir_ok) and skip a vanished / reused / wrong-uid / dir-changed pid,
 * then SIGKILL; a killsig errno other than ESRCH is a survivor, ESRCH is gone. `*overflow` is set when a list
 * overflows its cap (never clean). Returns 0, or EINVAL on a contract violation (null ops/callbacks/overflow,
 * null pids with npids > 0, negative npids/caps). */
int zb_reaper_engine(const struct zb_reaper_ops *ops, const pid_t *pids, int npids, const char *dir,
                     int kill_them, int *killed, int kcap, int *kn, int *surv, int scap, int *sn, int *overflow);

/* gather (via the injected scan) + the engine. A failed scan maps to a NON-ZERO return, never a clean empty
 * result: EOVERFLOW (incomplete) or EIO (sizing/scan/alloc error), both also setting *overflow; else the
 * engine's result. EINVAL on a null scan/ops/dir/overflow. */
int zb_reaper_run_full(int (*scan)(void *buf, int bytes), const struct zb_reaper_ops *ops, const char *dir,
                       int kill_them, int *killed, int kcap, int *kn, int *surv, int scap, int *sn, int *overflow);

#ifdef __APPLE__
/* Production: `run_dir_fd` is the no-follow dir fd the caller opened at run-dir creation and holds for the run;
 * `pinned` is zb_reaper_pin_fd's identity from it. The reaper revalidates the fd (never a pathname), derives the
 * dir's current path from the fd, and runs the engine (libproc inspect + real kill + per-kill fd revalidation).
 * `*out_overflow` (required) is set when the scan was incomplete or a list overflowed. Returns 0, EINVAL
 * (bad fd/pin/args), EOVERFLOW (incomplete scan) or EIO (scan error). */
int zb_reaper_census(int run_dir_fd, const struct zb_reaper_dir_id *pinned, int *out_pids, int cap, int *out_n,
                     int *out_overflow);
int zb_reaper_sweep(int run_dir_fd, const struct zb_reaper_dir_id *pinned, int *out_killed_pids, int killed_cap,
                    int *out_killed_n, int *out_survivor_pids, int survivor_cap, int *out_survivor_n,
                    int *out_overflow);
#endif

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_RUN_REAPER_H */
