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

#ifdef __APPLE__
/* macOS libproc, no private SPI. Both enumerate every process (proc_listallpids) and gather each one's cwd, exe
 * and open-file vnode paths (proc_pidinfo / proc_pidpath / proc_pidfdinfo), classifying with zb_reaper_classify.
 * A refused run_dir ("" or "/") matches nothing. Both skip pid <= 1, ourselves, and any pid not of our uid, so a
 * signal is never kill(-1)/kill(0)/suicide and never reaches another user's process.
 *
 * zb_reaper_census: REPORT ONLY — fill out_pids/out_n with the survivor pids, send NO signal. This is the drawer
 * warning's "show details" source and a safe dry run.
 *
 * zb_reaper_sweep: the census, then SIGKILL each survivor — but only after RE-gathering its markers immediately
 * before the signal (a survivor can exit and its pid be reused; a no-longer-matching or vanished pid is skipped,
 * never killed). out_killed = reaped within a short grace; out_survivors = matched but still alive after it.
 * Returns 0, or an errno on a setup failure. */
int zb_reaper_census(const char *run_dir, int *out_pids, int cap, int *out_n);
int zb_reaper_sweep(const char *run_dir, int *out_killed_pids, int killed_cap, int *out_killed_n,
                    int *out_survivor_pids, int survivor_cap, int *out_survivor_n);
#endif

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_RUN_REAPER_H */
