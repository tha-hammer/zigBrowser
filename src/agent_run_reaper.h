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

/* 1 iff `dir` is acceptable as a sweep's run dir: an app-owned, per-run marker, NOT a broad ancestor whose
 * children are the user's real processes (RoseCat a2fd8af #2). Requires an ABSOLUTE, CANONICAL path (no "//",
 * "/./", "/../"), at least two path components, and a LAST component beginning "zigbrowser-agent-" — the format
 * agent_net.sockdirPath creates. So "/", "/tmp", "/Users/<user>", "$HOME", a relative or non-canonical path, and
 * any dir the app did not create are all rejected. Pure, so it is unit-tested on Linux. The sweep realpath()s the
 * dir first and this runs on the RESOLVED path; realpath failing is itself a refusal, with no raw-string fallback. */
int zb_reaper_run_dir_ok(const char *dir);

#ifdef __APPLE__
/* macOS libproc, no private SPI. Both realpath() the run dir and REFUSE unless zb_reaper_run_dir_ok accepts the
 * resolved path (realpath failure = refusal, no fallback), then enumerate every process (proc_listallpids,
 * count-returning, grown + retried if the buffer filled) and gather each one's cwd/exe/open-file vnode paths plus
 * its uid and start time. Both skip pid <= 1, ourselves, and any pid not of our uid: a signal is never
 * kill(-1)/kill(0)/suicide and never reaches another user's process. `*out_overflow` is set to 1 when more
 * survivors matched than the cap (the lists are then truncated, not silently complete).
 *
 * zb_reaper_census: REPORT ONLY — the survivor pids, NO signal (the warning's "show details" and a safe dry run).
 *
 * zb_reaper_sweep: the census, then SIGKILL each survivor only after RE-gathering its markers, uid AND start time
 * immediately before the signal — a vanished pid, a changed identity (reused pid) or a changed marker is skipped,
 * never killed. kill()'s return is checked (ESRCH = already gone). out_killed = gone within a short grace;
 * out_survivors = matched but still alive after it. Returns 0, or an errno (EINVAL = refused run dir). */
int zb_reaper_census(const char *run_dir, int *out_pids, int cap, int *out_n, int *out_overflow);
int zb_reaper_sweep(const char *run_dir, int *out_killed_pids, int killed_cap, int *out_killed_n,
                    int *out_survivor_pids, int survivor_cap, int *out_survivor_n, int *out_overflow);
#endif

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_RUN_REAPER_H */
