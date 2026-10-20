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
