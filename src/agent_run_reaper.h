/* MS6.5 (rev 19, the user's decision 2026-10-21): best-effort cleanup of an agent run's leftover processes with
 * PUBLIC APIs only (no sandbox_check, no private SPI). A detached escaper (double-fork + setsid) is no longer a
 * hard gate; it is accepted, cleaned up here, and any survivor surfaces a drawer warning. See the plan MS6.5.
 *
 * A process is a "run survivor" when its cwd, its executable, or one of its open files is under that run's own
 * directory (the per-run sockdir / home; agent_net.sockdirPath). The classification below is the kill-safety
 * heart: it is pure and portable, so it is unit-tested on Linux; the macOS libproc scan + the guarded kill that
 * drive it (zb_reaper_sweep) are exercised by the both-Mac hard-gate case. */
#ifndef ZB_AGENT_RUN_REAPER_H
#define ZB_AGENT_RUN_REAPER_H

#ifdef __cplusplus
extern "C" {
#endif

/* 1 iff `path` is `dir` itself or lies strictly inside it, compared by WHOLE path components: `/run/abc/x` and
 * `/run/abc` are under `/run/abc`, but `/run/abcdef` is NOT. Trailing slashes on `dir` are ignored. Refuses a
 * null/empty path or dir, and refuses `dir` == "/" (root is never a run marker — it would match everything).
 * Both are compared as given; the caller passes the absolute, kernel-reported paths and the run dir. */
int zb_reaper_path_under(const char *path, const char *dir);

/* 1 iff a process with this `cwd`, `exe` and `nfds` open-file paths is a survivor of the run rooted at `run_dir`
 * (any one under it). Any of cwd/exe may be NULL (unknown). Pure; the marker set the plan fixes. */
int zb_reaper_classify(const char *cwd, const char *exe, const char *const *fd_paths, int nfds,
                       const char *run_dir);

/* The macOS libproc sweep that drives the classification above — zb_reaper_sweep: enumerate every process
 * (proc_listallpids), gather each one's cwd/exe/open-files (proc_pidinfo / proc_pidpath), and SIGKILL the
 * survivors under a strict guard (pid > 1, not ourselves, same uid, marker re-checked immediately before the
 * signal, ESRCH skipped) — lands with the both-Mac hard-gate case, where it is compiled and run on a Mac. */

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_RUN_REAPER_H */
