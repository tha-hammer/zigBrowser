/* The Claude Agent helper's process side (see agent_host.h). */

#include "agent_host.h"

#include <glib.h>
#include <glib/gstdio.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <unistd.h>

static int zb_agent_lock_fd = -1;

int zb_agent_home_lock(const char *home) {
  if (zb_agent_lock_fd >= 0) {
    return 0;
  }
  if (home == NULL || g_mkdir_with_parents(home, 0700) != 0) {
    return -1;
  }
  char *path = g_build_filename(home, ".zb-owner.lock", NULL);
  int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  g_free(path);
  if (fd < 0) {
    return -1;
  }
  if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
    int busy = errno == EWOULDBLOCK;
    close(fd);
    return busy ? -2 : -1;
  }
  zb_agent_lock_fd = fd;
  return 0;
}

typedef struct {
  pid_t parent;
  unsigned int delay_ms;
} ZbChildSetup;

/* In the child, before exec: die with the browser. If the browser already
 * died between fork() and prctl(), the child was reparented and the death
 * signal would never come, so it exits at once instead. */
static void die_with_browser(gpointer data) {
  const ZbChildSetup *setup = data;
  if (setup->delay_ms > 0) {
    usleep(setup->delay_ms * 1000u);
  }
  prctl(PR_SET_PDEATHSIG, SIGKILL);
  if (getppid() != setup->parent) {
    _exit(127);
  }
}

int zb_agent_run_sync(const char *const *argv, const char *const *envp, unsigned int spawn_delay_ms) {
  int wait_status = 0;
  GError *error = NULL;
  ZbChildSetup setup = {getpid(), spawn_delay_ms};
  if (!g_spawn_sync(NULL, (char **)argv, (char **)envp, G_SPAWN_DEFAULT, die_with_browser, &setup,
                    NULL, NULL, &wait_status, &error)) {
    g_printerr("zigBrowser: agent: cannot start %s: %s\n", argv[0], error != NULL ? error->message : "?");
    g_clear_error(&error);
    return -1;
  }
  if (WIFEXITED(wait_status)) {
    return WEXITSTATUS(wait_status);
  }
  if (WIFSIGNALED(wait_status)) {
    return 128 + WTERMSIG(wait_status);
  }
  return -1;
}
