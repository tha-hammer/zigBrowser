/* macOS plan rev 14 item 5: see agent_spawn_posix.h. */
#include "agent_spawn_posix.h"

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif

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

static int spawn_group_io(const char *const *argv, const char *const *envp,
                          int stdin_fd, int stdout_fd, int token_fd, pid_t *out_pid) {
  if ((stdin_fd != -1 && stdin_fd <= 2) || (stdout_fd != -1 && stdout_fd <= 2)) return EINVAL;
  if (token_fd >= 0 && (token_fd <= 2 || stdin_fd == 3 || stdout_fd == 3 ||
                        token_fd == stdin_fd || token_fd == stdout_fd)) return EINVAL;
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
  /* Both dup2s first (both ends are above 2, so neither clobbers the other's source), then close each distinct
   * original once: one duplex fd may be both streams (RoseCat 7150). For -1, keep the caller's own stream. */
  if (err == 0 && stdin_fd >= 0) err = posix_spawn_file_actions_adddup2(&acts, stdin_fd, 0);
  if (err == 0 && stdout_fd >= 0) err = posix_spawn_file_actions_adddup2(&acts, stdout_fd, 1);
  if (err == 0 && token_fd >= 0 && token_fd != 3) err = posix_spawn_file_actions_adddup2(&acts, token_fd, 3);
  if (err == 0 && stdin_fd >= 0) err = posix_spawn_file_actions_addclose(&acts, stdin_fd);
  if (err == 0 && stdout_fd >= 0 && stdout_fd != stdin_fd) err = posix_spawn_file_actions_addclose(&acts, stdout_fd);
  if (err == 0 && token_fd > 3) err = posix_spawn_file_actions_addclose(&acts, token_fd);
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
  /* Under CLOEXEC_DEFAULT an inherited stream must be named too, or it is closed: stderr always, and stdin or
   * stdout when the caller passed -1 for it. */
  if (err == 0 && stdin_fd < 0) err = posix_spawn_file_actions_addinherit_np(&acts, 0);
  if (err == 0 && stdout_fd < 0) err = posix_spawn_file_actions_addinherit_np(&acts, 1);
  if (err == 0) err = posix_spawn_file_actions_addinherit_np(&acts, 2);
  if (err == 0 && token_fd == 3) err = posix_spawn_file_actions_addinherit_np(&acts, 3);
#endif
  pid_t pid = -1;
  if (err == 0) err = posix_spawn(&pid, argv[0], &acts, &attr, (char *const *)argv, (char *const *)envp);
  posix_spawnattr_destroy(&attr);
  posix_spawn_file_actions_destroy(&acts);
  if (err == 0 && out_pid != NULL) *out_pid = pid;
  return err;
}

int zb_agent_spawn_group_io(const char *const *argv, const char *const *envp, int stdin_fd, int stdout_fd,
                            pid_t *out_pid) {
  return spawn_group_io(argv, envp, stdin_fd, stdout_fd, -1, out_pid);
}

int zb_agent_spawn_group_io_fd3(const char *const *argv, const char *const *envp,
                                int stdin_fd, int stdout_fd, int token_fd, pid_t *out_pid) {
#ifdef __APPLE__
  return spawn_group_io(argv, envp, stdin_fd, stdout_fd, token_fd, out_pid);
#else
  (void)argv;
  (void)envp;
  (void)stdin_fd;
  (void)stdout_fd;
  (void)token_fd;
  (void)out_pid;
  return ENOTSUP;
#endif
}

/* `pid`'s parent, process group and whether it is a zombie, an unreaped zombie included; -1 if there is no such
 * process. Darwin reads the kernel's process table (sysctl kern.proc.pid: getpgid and getsid fail with ESRCH on a
 * zombie there, measured on both Macs); Linux reads /proc/<pid>/stat. */
static int parent_and_group(pid_t pid, pid_t *ppid, pid_t *pgid, int *zombie) {
#ifdef __APPLE__
  struct kinfo_proc kp;
  size_t len = sizeof kp;
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid};
  if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len != sizeof kp) {
    return -1;
  }
  *ppid = kp.kp_eproc.e_ppid;
  *pgid = kp.kp_eproc.e_pgid;
  *zombie = kp.kp_proc.p_stat == SZOMB;
  return 0;
#else
  char path[64], buf[512];
  snprintf(path, sizeof path, "/proc/%d/stat", (int)pid);
  FILE *f = fopen(path, "re");
  if (f == NULL) {
    return -1;
  }
  size_t n = fread(buf, 1, sizeof buf - 1, f);
  fclose(f);
  buf[n] = 0;
  char *close_paren = NULL;
  for (char *p = buf; *p; p++) {
    if (*p == ')') close_paren = p;  /* the command name may itself hold ')' */
  }
  char state = 0;
  int pp = 0, pg = 0;
  if (close_paren == NULL || sscanf(close_paren + 1, " %c %d %d", &state, &pp, &pg) != 3) {
    return -1;
  }
  *ppid = (pid_t)pp;
  *pgid = (pid_t)pg;
  *zombie = state == 'Z';
  return 0;
#endif
}

int zb_agent_kill_group(pid_t pid) {
  /* killpg(1) is kill(-1): every process the user owns (the 2026-10-21 logouts). Never 0, 1, a negative pid, us,
   * or our own group. */
  if (pid <= 1 || pid == getpid() || pid == getpgrp()) {
    return EINVAL;
  }
  /* Only our own child, alive or an unreaped zombie (its pid cannot be reused until we reap it), that leads its
   * own group (zb_agent_spawn_group's POSIX_SPAWN_SETPGROUP). Anything else is never signalled. */
  pid_t ppid = 0, pgid = 0;
  int zombie = 0;
  if (parent_and_group(pid, &ppid, &pgid, &zombie) != 0 || ppid != getpid()) {
    return ECHILD;
  }
  if (pgid != pid) {
    return EPERM;
  }
  if (killpg(pid, SIGKILL) != 0) {
    /* Darwin's killpg gives EPERM for a zombie-only group: nothing left to signal, so reap it. A LIVE leader we could
     * not signal is never waited for (that wait could block forever, RoseCat 7191): its errno comes back unreaped. */
    int err = errno;
    if (parent_and_group(pid, &ppid, &pgid, &zombie) != 0 || !zombie) {
      return err;
    }
  }
  (void)zb_agent_wait(pid);
  return 0;
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
