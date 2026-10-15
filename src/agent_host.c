/* The Claude Agent helper's process side (see agent_host.h). */

#include "agent_host.h"

#include <glib.h>
#include <glib/gstdio.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/wait.h>
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

/* In the child, before exec: die with the browser. If the browser already
 * died between fork() and prctl(), the child was reparented and the death
 * signal would never come, so it exits at once instead. */
void zb_agent_die_with_browser(void *data) {
  const ZbChildSetup *setup = data;
  if (setup->delay_ms > 0) {
    usleep(setup->delay_ms * 1000u);
  }
  if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != setup->parent) {
    _exit(127);
  }
}

int zb_agent_run_sync(const char *const *argv, const char *const *envp, unsigned int spawn_delay_ms) {
  int wait_status = 0;
  GError *error = NULL;
  ZbChildSetup setup = {getpid(), spawn_delay_ms};
  if (!g_spawn_sync(NULL, (char **)argv, (char **)envp, G_SPAWN_DEFAULT, zb_agent_die_with_browser, &setup,
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

/* --- netd (plan rev 16.2 §3c.2) --------------------------------------------- */

/* Provided by webkit_shim.c (agent_drawer.h): one --e2e-protocol row. */
void zb_emit_protocol_row(int enabled, const char *tag, const char *const *fields, int n_fields);

#define ZB_NETD_READY_LINE "netd ready"
#define ZB_NETD_READY_MS 5000
#define ZB_NETD_STOP_MS 2000

static struct {
  int configured;
  char **argv, **envp;
  char *sockdir, *refusal;
  int e2e;
  int state;
  GPid pid;
  int stdin_fd;
  GIOChannel *out;
  guint out_watch, ready_timeout, child_watch;
  GString *line;
  void (*listener)(void *data);
  void *listener_data;
  void (*ready_listener)(void *data);
  void *ready_listener_data;
} zb_net = {.state = ZB_AGENT_NET_NOT_SET_UP, .stdin_fd = -1};

static void net_row(const char *state, const char *detail) {
  const char *fields[2] = {state, detail};
  zb_emit_protocol_row(zb_net.e2e, "AGENTNET", fields, detail != NULL ? 2 : 1);
}

static void net_unavailable(const char *reason) {
  if (zb_net.state == ZB_AGENT_NET_UNAVAILABLE) {
    return;
  }
  zb_net.state = ZB_AGENT_NET_UNAVAILABLE;
  net_row("unavailable", reason);
  if (zb_net.listener != NULL) {
    zb_net.listener(zb_net.listener_data);
  }
}

void zb_agent_net_configure(const char *const *argv, const char *const *envp, const char *sockdir,
                            const char *refusal, int e2e_protocol) {
  if (zb_net.configured) {
    return;
  }
  zb_net.configured = 1;
  zb_net.argv = g_strdupv((char **)argv);
  zb_net.envp = g_strdupv((char **)envp);
  zb_net.sockdir = g_strdup(sockdir);
  zb_net.refusal = g_strdup(refusal);
  zb_net.e2e = e2e_protocol;
  zb_net.state = ZB_AGENT_NET_IDLE;
}

void zb_agent_net_set_listener(void (*listener)(void *data), void *data) {
  zb_net.listener = listener;
  zb_net.listener_data = data;
}

void zb_agent_net_set_ready_listener(void (*listener)(void *data), void *data) {
  zb_net.ready_listener = listener;
  zb_net.ready_listener_data = data;
}

const char *zb_agent_net_dir(void) {
  return zb_net.state == ZB_AGENT_NET_READY ? zb_net.sockdir : NULL;
}

static void net_stop_reading(void) {
  if (zb_net.out_watch != 0) {
    g_source_remove(zb_net.out_watch);
    zb_net.out_watch = 0;
  }
  if (zb_net.out != NULL) {
    g_io_channel_shutdown(zb_net.out, FALSE, NULL);
    g_io_channel_unref(zb_net.out);
    zb_net.out = NULL;
  }
}

static gboolean on_netd_output(GIOChannel *channel, GIOCondition cond, gpointer data) {
  (void)channel;
  (void)data;
  char buf[256];
  ssize_t n = (cond & G_IO_IN) ? read(g_io_channel_unix_get_fd(zb_net.out), buf, sizeof buf) : 0;
  if (n < 0 && (errno == EINTR || errno == EAGAIN)) {
    return G_SOURCE_CONTINUE;
  }
  if (n <= 0) {
    zb_net.out_watch = 0;
    return G_SOURCE_REMOVE; /* EOF: netd is going; its exit is reported by the child watch */
  }
  for (ssize_t i = 0; i < n; ++i) {
    if (buf[i] != '\n') {
      if (zb_net.line->len < 64) {
        g_string_append_c(zb_net.line, buf[i]);
      }
      continue;
    }
    if (zb_net.state == ZB_AGENT_NET_STARTING && strcmp(zb_net.line->str, ZB_NETD_READY_LINE) == 0) {
      zb_net.state = ZB_AGENT_NET_READY;
      if (zb_net.ready_timeout != 0) {
        g_source_remove(zb_net.ready_timeout);
        zb_net.ready_timeout = 0;
      }
      net_row("ready", zb_net.sockdir);
      if (zb_net.ready_listener != NULL) {
        zb_net.ready_listener(zb_net.ready_listener_data);
      }
    }
    g_string_truncate(zb_net.line, 0);
  }
  return G_SOURCE_CONTINUE;
}

static gboolean on_netd_not_ready(gpointer data) {
  (void)data;
  zb_net.ready_timeout = 0;
  if (zb_net.state == ZB_AGENT_NET_STARTING && zb_net.pid > 0) {
    g_printerr("zigBrowser: agent: network helper not ready within %d s\n", ZB_NETD_READY_MS / 1000);
    kill(zb_net.pid, SIGKILL); /* its exit is reported by the child watch */
  }
  return G_SOURCE_REMOVE;
}

static void net_forget_child(void) {
  if (zb_net.stdin_fd >= 0) {
    close(zb_net.stdin_fd);
    zb_net.stdin_fd = -1;
  }
  net_stop_reading();
  if (zb_net.ready_timeout != 0) {
    g_source_remove(zb_net.ready_timeout);
    zb_net.ready_timeout = 0;
  }
  if (zb_net.pid > 0) {
    g_spawn_close_pid(zb_net.pid);
    zb_net.pid = 0;
  }
}

static void on_netd_exit(GPid pid, gint wait_status, gpointer data) {
  (void)pid;
  (void)data;
  zb_net.child_watch = 0;
  char status[32];
  if (WIFEXITED(wait_status)) {
    g_snprintf(status, sizeof status, "exit %d", WEXITSTATUS(wait_status));
  } else if (WIFSIGNALED(wait_status)) {
    g_snprintf(status, sizeof status, "signal %d", WTERMSIG(wait_status));
  } else {
    g_snprintf(status, sizeof status, "status %d", wait_status);
  }
  g_printerr("zigBrowser: agent: network helper exited (%s)\n", status);
  net_forget_child();
  net_unavailable("exited");
}

int zb_agent_net_ensure(void) {
  if (zb_net.state != ZB_AGENT_NET_IDLE) {
    return zb_net.state;
  }
  if (zb_net.refusal != NULL) {
    g_printerr("%s\n", zb_net.refusal);
    net_unavailable("refused");
    return zb_net.state;
  }
  ZbChildSetup setup = {getpid(), 0};
  int in_fd = -1, out_fd = -1;
  GError *error = NULL;
  /* CLOEXEC pipes: no later child inherits netd's stdin, so closing ours is its EOF. */
  if (!g_spawn_async_with_pipes(NULL, zb_net.argv, zb_net.envp, G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_CLOEXEC_PIPES,
                                zb_agent_die_with_browser, &setup, &zb_net.pid, &in_fd, &out_fd, NULL, &error)) {
    g_printerr("zigBrowser: agent: cannot start the network helper: %s\n", error != NULL ? error->message : "?");
    g_clear_error(&error);
    net_unavailable("spawn");
    return zb_net.state;
  }
  zb_net.stdin_fd = in_fd;
  zb_net.state = ZB_AGENT_NET_STARTING;
  net_row("starting", NULL);
  zb_net.line = zb_net.line != NULL ? zb_net.line : g_string_new(NULL);
  zb_net.out = g_io_channel_unix_new(out_fd);
  g_io_channel_set_close_on_unref(zb_net.out, TRUE);
  zb_net.out_watch = g_io_add_watch(zb_net.out, G_IO_IN | G_IO_HUP | G_IO_ERR, on_netd_output, NULL);
  zb_net.ready_timeout = g_timeout_add(ZB_NETD_READY_MS, on_netd_not_ready, NULL);
  zb_net.child_watch = g_child_watch_add(zb_net.pid, on_netd_exit, NULL);
  return zb_net.state;
}

void zb_agent_net_stop(void) {
  if (zb_net.pid <= 0) {
    return;
  }
  GPid pid = zb_net.pid;
  if (zb_net.child_watch != 0) {
    g_source_remove(zb_net.child_watch); /* the main loop is over: reap it here */
    zb_net.child_watch = 0;
  }
  if (zb_net.stdin_fd >= 0) {
    close(zb_net.stdin_fd); /* EOF: netd removes its sockets and directory, then exits */
    zb_net.stdin_fd = -1;
  }
  for (int waited = 0; waited < ZB_NETD_STOP_MS; waited += 20) {
    int st;
    pid_t r = waitpid(pid, &st, WNOHANG);
    if (r == pid || (r < 0 && errno == ECHILD)) {
      net_forget_child();
      return;
    }
    g_usleep(20 * 1000);
  }
  g_printerr("zigBrowser: agent: network helper did not stop within %d s\n", ZB_NETD_STOP_MS / 1000);
  kill(pid, SIGKILL);
  waitpid(pid, NULL, 0);
  net_forget_child();
}
