/* The one-shot sign-in (see agent_login.h). */
#define _GNU_SOURCE /* pipe2 */
#include "agent_login.h"

#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <gio/gunixinputstream.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "agent_host.h"

/* src/agent_login.zig */
void *zb_login_validator_new(void);
void zb_login_validator_free(void *validator);
int zb_login_validate(void *validator, const char *line, size_t len, int *kind, char *text, size_t cap);
int zb_login_code_valid(const char *code, size_t len);
int zb_login_encode(int kind, long long seq, const char *code, size_t code_len, char *out, size_t cap);
/* src/agent_secrets.zig: the setup-token shape, after trimming. */
int zb_secrets_token_from_paste(const char *text, size_t len, size_t *start, size_t *token_len);

enum { KIND_AUTH_URL = 1, KIND_NEED_CODE = 2, KIND_DONE = 3, KIND_ERROR = 4 };
enum { ENCODE_START = 0, ENCODE_CODE = 1, ENCODE_CANCEL = 2 };

#define NETD_READY_LINE "netd ready"
#define NETD_READY_MS 5000
#define CANCEL_GRACE_MS 3000
#define MAX_FRAME (8 * 1024)
#define MAX_TOKEN 512

static struct {
  char **netd_argv, **netd_envp, *login_dir, **launch_argv, **launch_envp;
  int configured;

  int running;
  int ended; /* the one ending event was sent */
  ZbLoginListener listener;
  void *data;

  ZbChildSetup netd_setup, helper_setup;
  GPid netd_pid;
  int netd_stdin;
  GIOChannel *netd_out;
  GString *netd_line;
  guint netd_watch, netd_timeout, netd_child;
  int netd_ready;

  GSubprocess *helper;
  GOutputStream *helper_in;
  GIOChannel *helper_out;
  GString *helper_line;
  guint helper_watch;
  int helper_exited;
  int token_fd;
  void *validator;
  long long seq;
  guint kill_timeout;
} lg = {.netd_stdin = -1, .token_fd = -1};

static char **copy_strv(const char *const *v) { return v != NULL ? g_strdupv((char **)v) : NULL; }

void zb_login_configure(const char *const *netd_argv, const char *const *netd_envp, const char *login_dir,
                        const char *const *launch_argv, const char *const *launch_envp) {
  g_strfreev(lg.netd_argv);
  g_strfreev(lg.netd_envp);
  g_strfreev(lg.launch_argv);
  g_strfreev(lg.launch_envp);
  g_free(lg.login_dir);
  lg.netd_argv = copy_strv(netd_argv);
  lg.netd_envp = copy_strv(netd_envp);
  lg.launch_argv = copy_strv(launch_argv);
  lg.launch_envp = copy_strv(launch_envp);
  lg.login_dir = g_strdup(login_dir);
  lg.configured = lg.netd_argv != NULL && lg.launch_argv != NULL;
}

int zb_login_configured(void) { return lg.configured; }

int zb_login_running(void) { return lg.running; }

/* --- the ending, and the teardown that follows it -------------------------- */

static void maybe_finished(void);

/* Exactly one ending event per sign-in. */
static void end(ZbLoginEvent event, const char *detail) {
  if (lg.ended) {
    return;
  }
  lg.ended = 1;
  if (lg.listener != NULL) {
    lg.listener(event, detail, lg.data);
  }
}

static void stop_netd(void) {
  if (lg.netd_timeout != 0) {
    g_source_remove(lg.netd_timeout);
    lg.netd_timeout = 0;
  }
  if (lg.netd_stdin >= 0) {
    close(lg.netd_stdin); /* EOF: the login netd removes its sockets and directory, then exits */
    lg.netd_stdin = -1;
  }
}

static void close_token_fd(void) {
  if (lg.token_fd >= 0) {
    close(lg.token_fd);
    lg.token_fd = -1;
  }
}

static void stop_reading_helper(void) {
  if (lg.helper_watch != 0) {
    g_source_remove(lg.helper_watch);
    lg.helper_watch = 0;
  }
  if (lg.helper_out != NULL) {
    g_io_channel_shutdown(lg.helper_out, FALSE, NULL);
    g_io_channel_unref(lg.helper_out);
    lg.helper_out = NULL;
  }
}

static gboolean on_kill_timeout(gpointer unused) {
  (void)unused;
  lg.kill_timeout = 0;
  if (lg.helper != NULL && !lg.helper_exited) {
    g_subprocess_force_exit(lg.helper);
  }
  return G_SOURCE_REMOVE;
}

/* After an ending: the helper is told to stop (its stdin closes), and is killed
 * if it has not exited within the grace time. */
static void wind_down(void) {
  if (lg.helper_in != NULL) {
    g_output_stream_close(lg.helper_in, NULL, NULL);
    lg.helper_in = NULL;
  }
  if (lg.helper != NULL && !lg.helper_exited && lg.kill_timeout == 0) {
    lg.kill_timeout = g_timeout_add(CANCEL_GRACE_MS, on_kill_timeout, NULL);
  }
  if (lg.helper == NULL) {
    stop_netd();
  }
  maybe_finished();
}

/* The sign-in is over once its ending was sent and both children are gone. */
static void maybe_finished(void) {
  if (!lg.ended || (lg.helper != NULL && !lg.helper_exited) || lg.netd_pid > 0) {
    return;
  }
  stop_reading_helper();
  close_token_fd();
  if (lg.kill_timeout != 0) {
    g_source_remove(lg.kill_timeout);
    lg.kill_timeout = 0;
  }
  g_clear_object(&lg.helper);
  zb_login_validator_free(lg.validator);
  lg.validator = NULL;
  lg.running = 0;
}

static void fail(const char *word) {
  end(ZB_LOGIN_EV_ERROR, word);
  wind_down();
}

/* --- the login helper -------------------------------------------------------- */

static int send_frame(int kind, const char *code) {
  char buf[MAX_FRAME];
  if (lg.helper_in == NULL ||
      zb_login_encode(kind, ++lg.seq, code, code != NULL ? strlen(code) : 0, buf, sizeof buf) != 0) {
    return -1;
  }
  gsize written = 0;
  int ok = g_output_stream_write_all(lg.helper_in, buf, strlen(buf), &written, NULL, NULL) &&
           g_output_stream_flush(lg.helper_in, NULL, NULL);
  memset(buf, 0, sizeof buf);
  return ok ? 0 : -1;
}

/* After `done`: the helper wrote the token to fd 4 and closed it before it sent
 * `done`, so the bytes and the EOF are already there. */
static char *read_token(void) {
  char buf[MAX_TOKEN + 2];
  size_t len = 0;
  int eof = 0;
  while (!eof && len < sizeof buf) {
    struct pollfd p = {lg.token_fd, POLLIN, 0};
    if (poll(&p, 1, 2000) <= 0) {
      break;
    }
    ssize_t n = read(lg.token_fd, buf + len, sizeof buf - len);
    if (n < 0 && errno == EINTR) {
      continue;
    }
    if (n <= 0) {
      eof = n == 0;
      break;
    }
    len += (size_t)n;
  }
  close_token_fd();
  size_t start = 0, token_len = 0;
  char *token = NULL;
  if (eof && len <= MAX_TOKEN && zb_secrets_token_from_paste(buf, len, &start, &token_len) &&
      start == 0 && token_len == len) {
    token = g_strndup(buf, len);
  }
  memset(buf, 0, sizeof buf);
  return token;
}

static void on_frame(const char *line, size_t len) {
  int kind = 0;
  char text[4097];
  if (zb_login_validate(lg.validator, line, len, &kind, text, sizeof text) != 0) {
    g_printerr("zigBrowser: agent: sign-in: a login helper frame was refused\n");
    fail("protocol");
    return;
  }
  switch (kind) {
  case KIND_AUTH_URL:
    if (lg.listener != NULL) {
      lg.listener(ZB_LOGIN_EV_AUTH_URL, text, lg.data);
    }
    break;
  case KIND_NEED_CODE:
    if (lg.listener != NULL) {
      lg.listener(ZB_LOGIN_EV_NEED_CODE, NULL, lg.data);
    }
    break;
  case KIND_DONE: {
    char *token = read_token();
    if (token == NULL) {
      fail("shape");
      break;
    }
    end(ZB_LOGIN_EV_DONE, token);
    memset(token, 0, strlen(token));
    g_free(token);
    wind_down();
    break;
  }
  case KIND_ERROR:
    if (strcmp(text, "cancelled") == 0) {
      end(ZB_LOGIN_EV_CANCELLED, NULL);
      wind_down();
    } else {
      fail(text);
    }
    break;
  }
}

static gboolean on_helper_output(GIOChannel *channel, GIOCondition cond, gpointer unused) {
  (void)unused;
  char buf[4096];
  ssize_t n = (cond & G_IO_IN) ? read(g_io_channel_unix_get_fd(channel), buf, sizeof buf) : 0;
  if (n < 0 && (errno == EINTR || errno == EAGAIN)) {
    return G_SOURCE_CONTINUE;
  }
  if (n <= 0) {
    lg.helper_watch = 0;
    return G_SOURCE_REMOVE; /* EOF: its exit is reported by the wait */
  }
  for (ssize_t i = 0; i < n && !lg.ended; ++i) {
    if (buf[i] != '\n') {
      if (lg.helper_line->len > MAX_FRAME) {
        fail("protocol");
        break;
      }
      g_string_append_c(lg.helper_line, buf[i]);
      continue;
    }
    on_frame(lg.helper_line->str, lg.helper_line->len);
    g_string_truncate(lg.helper_line, 0);
  }
  return G_SOURCE_CONTINUE;
}

static void on_helper_exit(GObject *source, GAsyncResult *result, gpointer unused) {
  (void)unused;
  g_subprocess_wait_finish(G_SUBPROCESS(source), result, NULL);
  lg.helper_exited = 1;
  if (!lg.ended) {
    /* It ended without an ending frame (or before reading the cancel). */
    end(ZB_LOGIN_EV_ERROR, "cli");
  }
  if (lg.kill_timeout != 0) {
    g_source_remove(lg.kill_timeout);
    lg.kill_timeout = 0;
  }
  stop_netd();
  maybe_finished();
}

static void helper_child_setup(gpointer data) {
  setpgid(0, 0);
  zb_agent_die_with_browser(data);
}

static void spawn_helper(void) {
  int fds[2];
  if (pipe2(fds, O_CLOEXEC) != 0) {
    fail("cli");
    return;
  }
  GSubprocessLauncher *launcher = g_subprocess_launcher_new(
      G_SUBPROCESS_FLAGS_STDIN_PIPE | G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE);
  g_subprocess_launcher_set_environ(launcher, lg.launch_envp);
  g_subprocess_launcher_take_fd(launcher, fds[1], 4); /* the token: login -> app only */
  lg.helper_setup.parent = getpid();
  lg.helper_setup.policy = zb_spawn_policy_linux(0);
  g_subprocess_launcher_set_child_setup(launcher, helper_child_setup, &lg.helper_setup, NULL);
  GError *error = NULL;
  lg.helper = g_subprocess_launcher_spawnv(launcher, (const char *const *)lg.launch_argv, &error);
  g_object_unref(launcher); /* closes our copy of the write end */
  if (lg.helper == NULL) {
    g_printerr("zigBrowser: agent: cannot start the sign-in: %s\n", error != NULL ? error->message : "?");
    g_clear_error(&error);
    close(fds[0]);
    fail("cli");
    return;
  }
  lg.token_fd = fds[0];
  lg.helper_exited = 0;
  lg.helper_in = g_subprocess_get_stdin_pipe(lg.helper);
  int out_fd = g_unix_input_stream_get_fd(G_UNIX_INPUT_STREAM(g_subprocess_get_stdout_pipe(lg.helper)));
  lg.helper_out = g_io_channel_unix_new(out_fd);
  lg.helper_line = lg.helper_line != NULL ? lg.helper_line : g_string_new(NULL);
  g_string_truncate(lg.helper_line, 0);
  lg.helper_watch = g_io_add_watch(lg.helper_out, G_IO_IN | G_IO_HUP | G_IO_ERR, on_helper_output, NULL);
  g_subprocess_wait_async(lg.helper, NULL, on_helper_exit, NULL);
  if (send_frame(ENCODE_START, NULL) != 0) {
    fail("cli");
  }
}

/* --- the login netd ---------------------------------------------------------- */

static gboolean on_netd_output(GIOChannel *channel, GIOCondition cond, gpointer unused) {
  (void)unused;
  char buf[256];
  ssize_t n = (cond & G_IO_IN) ? read(g_io_channel_unix_get_fd(channel), buf, sizeof buf) : 0;
  if (n < 0 && (errno == EINTR || errno == EAGAIN)) {
    return G_SOURCE_CONTINUE;
  }
  if (n <= 0) {
    lg.netd_watch = 0;
    return G_SOURCE_REMOVE;
  }
  for (ssize_t i = 0; i < n; ++i) {
    if (buf[i] != '\n') {
      if (lg.netd_line->len < 64) {
        g_string_append_c(lg.netd_line, buf[i]);
      }
      continue;
    }
    if (!lg.netd_ready && strcmp(lg.netd_line->str, NETD_READY_LINE) == 0) {
      lg.netd_ready = 1;
      if (lg.netd_timeout != 0) {
        g_source_remove(lg.netd_timeout);
        lg.netd_timeout = 0;
      }
      if (!lg.ended) {
        spawn_helper();
      }
    }
    g_string_truncate(lg.netd_line, 0);
  }
  return G_SOURCE_CONTINUE;
}

static gboolean on_netd_not_ready(gpointer unused) {
  (void)unused;
  lg.netd_timeout = 0;
  if (!lg.netd_ready && lg.netd_pid > 0) {
    g_printerr("zigBrowser: agent: sign-in network not ready within %d s\n", NETD_READY_MS / 1000);
    kill(lg.netd_pid, SIGKILL);
  }
  return G_SOURCE_REMOVE;
}

static void on_netd_exit(GPid pid, gint wait_status, gpointer unused) {
  (void)wait_status;
  (void)unused;
  lg.netd_child = 0;
  if (lg.netd_watch != 0) {
    g_source_remove(lg.netd_watch);
    lg.netd_watch = 0;
  }
  if (lg.netd_out != NULL) {
    g_io_channel_shutdown(lg.netd_out, FALSE, NULL);
    g_io_channel_unref(lg.netd_out);
    lg.netd_out = NULL;
  }
  if (lg.netd_stdin >= 0) {
    close(lg.netd_stdin);
    lg.netd_stdin = -1;
  }
  g_spawn_close_pid(pid);
  lg.netd_pid = 0;
  if (!lg.ended) {
    /* The network went away before the sign-in ended. */
    g_printerr("zigBrowser: agent: sign-in network exited\n");
    end(ZB_LOGIN_EV_ERROR, "network");
    wind_down();
  }
  maybe_finished();
}

static int start_netd(void) {
  int in_fd = -1, out_fd = -1;
  GError *error = NULL;
  lg.netd_setup.parent = getpid();
  lg.netd_setup.policy = zb_spawn_policy_linux(0);
  if (!g_spawn_async_with_pipes(NULL, lg.netd_argv, lg.netd_envp, G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_CLOEXEC_PIPES,
                                zb_agent_die_with_browser, &lg.netd_setup, &lg.netd_pid, &in_fd, &out_fd, NULL,
                                &error)) {
    g_printerr("zigBrowser: agent: cannot start the sign-in network: %s\n", error != NULL ? error->message : "?");
    g_clear_error(&error);
    lg.netd_pid = 0;
    return -1;
  }
  lg.netd_stdin = in_fd;
  lg.netd_ready = 0;
  lg.netd_line = lg.netd_line != NULL ? lg.netd_line : g_string_new(NULL);
  g_string_truncate(lg.netd_line, 0);
  lg.netd_out = g_io_channel_unix_new(out_fd);
  g_io_channel_set_close_on_unref(lg.netd_out, TRUE);
  lg.netd_watch = g_io_add_watch(lg.netd_out, G_IO_IN | G_IO_HUP | G_IO_ERR, on_netd_output, NULL);
  lg.netd_timeout = g_timeout_add(NETD_READY_MS, on_netd_not_ready, NULL);
  lg.netd_child = g_child_watch_add(lg.netd_pid, on_netd_exit, NULL);
  return 0;
}

/* --- the API ----------------------------------------------------------------- */

int zb_login_start(ZbLoginListener listener, void *data) {
  if (!lg.configured || lg.running) {
    return -1;
  }
  lg.running = 1;
  lg.ended = 0;
  lg.listener = listener;
  lg.data = data;
  lg.seq = 0;
  lg.helper = NULL;
  lg.helper_exited = 0;
  lg.validator = zb_login_validator_new();
  if (listener != NULL) {
    listener(ZB_LOGIN_EV_STARTING, NULL, data);
  }
  if (lg.validator == NULL || start_netd() != 0) {
    end(ZB_LOGIN_EV_ERROR, "network");
    maybe_finished();
  }
  return 0;
}

int zb_login_send_code(const char *code) {
  if (!lg.running || lg.ended || code == NULL || !zb_login_code_valid(code, strlen(code))) {
    return -1;
  }
  return send_frame(ENCODE_CODE, code);
}

void zb_login_cancel(void) {
  if (!lg.running || lg.ended) {
    return;
  }
  if (lg.helper == NULL) {
    /* Still waiting for the network: nothing to tell. */
    end(ZB_LOGIN_EV_CANCELLED, NULL);
    stop_netd();
    maybe_finished();
    return;
  }
  /* The helper answers with `error cancelled`; one that does not is killed, and
   * the ending is still CANCELLED. */
  send_frame(ENCODE_CANCEL, NULL);
  end(ZB_LOGIN_EV_CANCELLED, NULL);
  wind_down();
}
