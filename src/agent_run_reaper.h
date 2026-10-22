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
 * match, revalidate the pinned dir (ops->dir_ok) and SIGKILL; a killsig errno other than ESRCH is a survivor,
 * ESRCH is gone. `*overflow` is set when a list overflows its cap (never clean). `*unresolved` (nullable, sweep
 * only) COUNTS matched candidates of our uid that could NOT be safely acted upon — identity unavailable at the
 * first inspect, or vanished/reused/changed-identity/changed-uid at the pre-kill inspect. These are NOT proven
 * gone, so they are reported here DISTINCTLY from both `killed` and `surv` (RoseCat 3ec386e): a caller must never
 * read kn==0 && sn==0 with unresolved>0 as a clean, empty census. Returns 0, or EINVAL on a contract violation
 * (null ops/callbacks/overflow, null pids with npids > 0, negative npids/caps). */
int zb_reaper_engine(const struct zb_reaper_ops *ops, const pid_t *pids, int npids, const char *dir,
                     int kill_them, int *killed, int kcap, int *kn, int *surv, int scap, int *sn, int *overflow,
                     int *unresolved);

/* gather (via the injected scan) + the engine. A failed scan maps to a NON-ZERO return, never a clean empty
 * result: EOVERFLOW (incomplete) or EIO (sizing/scan/alloc error), both also setting *overflow; else the
 * engine's result. `*unresolved` (nullable) is passed through from the engine. EINVAL on a null scan/ops/dir/
 * overflow. */
int zb_reaper_run_full(int (*scan)(void *buf, int bytes), const struct zb_reaper_ops *ops, const char *dir,
                       int kill_them, int *killed, int kcap, int *kn, int *surv, int scap, int *sn, int *overflow,
                       int *unresolved);

/* MS6.5.1 (plan rev 27, "Clean fixed point"): a bounded census->kill->fresh-census FIXED POINT. One gather+sweep
 * cannot prove a run clean — a marked process can fork AFTER the gather and before its parent is killed, so it is
 * absent from that pass's list. This repeats gather+engine(kill) until a pass that matches ZERO pids with no
 * overflow (the complete, EMPTY final census), bounded by `max_passes`. Sets *clean=1 ONLY on that empty final
 * census; a pass-cap hit, or ANY incomplete/overflow/engine error on the way, yields *clean=0 (Survivors) and
 * never a clean result. *passes = passes performed. Same injected scan/ops as run_full; the kill is the injected
 * killsig, so the Linux decision proof never sends a real signal. EINVAL on a null argument. */
int zb_reaper_fixed_point(int (*scan)(void *buf, int bytes), const struct zb_reaper_ops *ops, const char *dir,
                          int max_passes, int *clean, int *passes, int *overflow);

/* ---- the run ledger: per-entry creation-provenance decision (portable; Linux-testable with real dirs) ---- */

/* The outcome of deciding one recorded ledger entry against the real filesystem. A directory is ever swept ONLY
 * on ZB_LEDGER_SWEEP; every other outcome is census/quarantine/warn — NEVER a signal (MS6.5.1 provenance). */
enum {
  ZB_LEDGER_SWEEP = 1,       /* an ACTIVE entry whose basename reopens to a dir matching `rec` exactly */
  ZB_LEDGER_GONE = 0,        /* the basename does not exist (ENOENT): nothing to recover, drop the entry */
  ZB_LEDGER_MISMATCH = -1,   /* reopened a non-dir / symlink, or fstat (dev,ino,uid,mode) != `rec`: NEVER sweep */
  ZB_LEDGER_NOT_ACTIVE = -2, /* the entry's lifecycle state is not `active` (e.g. `left`/stale): NEVER sweep */
  ZB_LEDGER_EINVAL = -3      /* a bad argument */
};

/* Decide one recorded ledger entry against the real filesystem, no-follow and fstat-only (no pathname stat, so
 * no symlink follow). `runtime_fd`: the held `O_DIRECTORY|O_NOFOLLOW` fd of the app-owned runtime dir. `basename`:
 * the entry's recorded run-dir basename (reopened RELATIVE to `runtime_fd`). `rec`: the recorded
 * (dev,ino,uid,mode). `active`: 1 iff the entry's lifecycle state is `active`. The run dir is swept ONLY when an
 * ACTIVE entry's basename reopens (`openat` `O_DIRECTORY|O_NOFOLLOW`) to a 0700 this-uid dir whose fstat matches
 * `rec` exactly — a swapped `(dev,ino)`, a symlink, a changed mode/uid, or a non-`active` state is NEVER swept.
 * Pure decision — it never sends a signal. Returns a ZB_LEDGER_* value. */
int zb_reaper_ledger_entry_state(int runtime_fd, const char *basename, const struct zb_reaper_dir_id *rec,
                                 int active);

/* C2 crash-cut classifier (MS6.5.1 crash-cut table). At startup recovery, does the run dir named `basename` still
 * hold its reserved `run.marker`? The dir is reopened no-follow (the single-component grammar is enforced first),
 * then `run.marker` is opened no-follow RELATIVE to that dir fd. A crash in the Clean teardown after
 * `unlinkat(run.marker)` but before `rmdir` leaves a provenance-valid, empty, MARKER-LESS dir; recovery must
 * recognise that durable teardown phase and finish `rmdir`+entry-remove idempotently, never signal, and never
 * raise a permanent incident. Pure classification — it never signals or mutates. */
enum {
  ZB_RUN_MARKER_PRESENT = 1,  /* run.marker present: a real run — classify/census normally */
  ZB_RUN_MARKER_TEARDOWN = 0, /* run.marker ENOENT: the durable teardown phase (C2) — finish rmdir+remove, no signal */
  ZB_RUN_MARKER_ERR = -1      /* bad fd/args/grammar, or a non-ENOENT error: fail closed */
};
int zb_reaper_run_marker_state(int runtime_fd, const char *basename);

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
