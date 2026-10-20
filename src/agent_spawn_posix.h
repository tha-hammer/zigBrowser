/* macOS plan rev 14 item 5: start a child as the leader of its own process group (POSIX, no GLib), so the
 * whole group can be killed at once: by the browser on its exit paths, and by setup's own parent watch
 * (zb_agent_host/parent_watch.py) when the browser is SIGKILLed and runs no exit path. */
#ifndef ZB_AGENT_SPAWN_POSIX_H
#define ZB_AGENT_SPAWN_POSIX_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* posix_spawn(argv[0], argv, envp) with POSIX_SPAWN_SETPGROUP (pgroup 0: the child leads a new group).
 * argv[0] is an absolute path (no PATH search). 0 and *out_pid on success, else the errno. */
int zb_agent_spawn_group(const char *const *argv, const char *const *envp, pid_t *out_pid);

/* SIGKILL the whole group led by `pid`, then reap `pid`. */
void zb_agent_kill_group(pid_t pid);

/* Wait for `pid` (EINTR retried): its exit status as waitpid reports it, or -1. */
int zb_agent_wait(pid_t pid);

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_SPAWN_POSIX_H */
