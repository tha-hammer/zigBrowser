/* macOS plan rev 14 item 5: see agent_spawn_posix.h. */
#include "agent_spawn_posix.h"

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>

int zb_agent_spawn_group(const char *const *argv, const char *const *envp, pid_t *out_pid) {
  posix_spawnattr_t attr;
  int err = posix_spawnattr_init(&attr);
  if (err != 0) {
    return err;
  }
  err = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
  if (err == 0) {
    err = posix_spawnattr_setpgroup(&attr, 0);
  }
  pid_t pid = -1;
  if (err == 0) {
    err = posix_spawn(&pid, argv[0], NULL, &attr, (char *const *)argv, (char *const *)envp);
  }
  posix_spawnattr_destroy(&attr);
  if (err == 0 && out_pid != NULL) {
    *out_pid = pid;
  }
  return err;
}

int zb_agent_spawn_group_io(const char *const *argv, const char *const *envp, int stdin_fd, int stdout_fd,
                            pid_t *out_pid) {
  if ((stdin_fd != -1 && stdin_fd <= 2) || (stdout_fd != -1 && stdout_fd <= 2)) return EINVAL;
  posix_spawn_file_actions_t acts;
  posix_spawnattr_t attr;
  int err = posix_spawn_file_actions_init(&acts);
  if (err != 0) return err;
  err = posix_spawnattr_init(&attr);
  if (err != 0) {
    posix_spawn_file_actions_destroy(&acts);
    return err;
  }
  short flags = POSIX_SPAWN_SETPGROUP;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
  flags |= POSIX_SPAWN_CLOEXEC_DEFAULT; /* Darwin: the child keeps only what the file actions name */
#endif
  err = posix_spawnattr_setflags(&attr, flags);
  if (err == 0) err = posix_spawnattr_setpgroup(&attr, 0);
  /* Each stream: dup2 the given end onto it (both ends are above 2, so neither dup2 clobbers the other's source),
   * then close the original; or, for -1, keep the caller's own stream. */
  if (err == 0) err = stdin_fd >= 0 ? posix_spawn_file_actions_adddup2(&acts, stdin_fd, 0) : 0;
  if (err == 0 && stdin_fd >= 0) err = posix_spawn_file_actions_addclose(&acts, stdin_fd);
  if (err == 0) err = stdout_fd >= 0 ? posix_spawn_file_actions_adddup2(&acts, stdout_fd, 1) : 0;
  if (err == 0 && stdout_fd >= 0 && stdout_fd != stdin_fd) err = posix_spawn_file_actions_addclose(&acts, stdout_fd);
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
  /* Under CLOEXEC_DEFAULT an inherited stream must be named too, or it is closed: stderr always, and stdin or
   * stdout when the caller passed -1 for it. */
  if (err == 0 && stdin_fd < 0) err = posix_spawn_file_actions_addinherit_np(&acts, 0);
  if (err == 0 && stdout_fd < 0) err = posix_spawn_file_actions_addinherit_np(&acts, 1);
  if (err == 0) err = posix_spawn_file_actions_addinherit_np(&acts, 2);
#endif
  pid_t pid = -1;
  if (err == 0) err = posix_spawn(&pid, argv[0], &acts, &attr, (char *const *)argv, (char *const *)envp);
  posix_spawnattr_destroy(&attr);
  posix_spawn_file_actions_destroy(&acts);
  if (err == 0 && out_pid != NULL) *out_pid = pid;
  return err;
}

void zb_agent_kill_group(pid_t pid) {
  if (pid <= 0) {
    return;
  }
  (void)killpg(pid, SIGKILL);
  (void)zb_agent_wait(pid);
}

int zb_agent_wait(pid_t pid) {
  int status = 0;
  for (;;) {
    pid_t r = waitpid(pid, &status, 0);
    if (r == pid) {
      return status;
    }
    if (r < 0 && errno == EINTR) {
      continue;
    }
    return -1;
  }
}
