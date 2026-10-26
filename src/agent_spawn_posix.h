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

/* Like zb_agent_spawn_group, but the child's stdin and stdout are the given pipe ends (BlackRobin 7108 seam 1;
 * JadeBeacon 7143): the browser reads netd's ready line and holds netd's stdin open (netd exits on stdin EOF).
 * stdin_fd / stdout_fd: -1 inherits that stream from the caller; otherwise it must be above 2 (a fd in 0..2 is
 * EINVAL, so one dup2 can never clobber the other's source). Both may be the same fd (one duplex socket). On
 * Darwin (POSIX_SPAWN_CLOEXEC_DEFAULT) the child holds EXACTLY fds 0, 1 and 2: every other fd of the browser,
 * inheritable or not, is closed in the child.
 * 0 and *out_pid on success, else the errno. */
int zb_agent_spawn_group_io(const char *const *argv, const char *const *envp, int stdin_fd, int stdout_fd,
                            pid_t *out_pid);

/* Darwin helper spawn: like zb_agent_spawn_group_io, with token_fd mapped to
 * descriptor 3. The stdio source descriptors must not be 3 or token_fd. */
int zb_agent_spawn_group_io_fd3(const char *const *argv, const char *const *envp,
                                int stdin_fd, int stdout_fd, int token_fd, pid_t *out_pid);

/* SIGKILL the whole group led by `pid`, then reap `pid`; 0 when done. Only our own child (alive or an unreaped
 * zombie) that leads its own group is ever signalled (RoseCat 7172, 7182; killpg(1) is kill(-1)):
 * EINVAL for pid <= 1, our own pid or our own group; ECHILD when `pid` is not our child; EPERM when it is our child
 * but not its group's leader. None of these sends a signal or reaps. If killpg itself fails while the leader is still
 * alive, its errno is returned at once and the leader is not reaped (never an unbounded wait); a zombie-only group
 * (Darwin's killpg gives EPERM) is reaped and 0 returned. */
int zb_agent_kill_group(pid_t pid);

/* Wait for `pid` (EINTR retried): its exit status as waitpid reports it, or -1. */
int zb_agent_wait(pid_t pid);

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_SPAWN_POSIX_H */
