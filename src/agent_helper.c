/* The chat helper's process side (chat-drawer plan D7, D7b, S3.2-S3.4, S3.12;
 * rev 16 §3c.2; S3b). See agent_helper.h. GTK main thread only.
 *
 * States: idle -> (lock, netd, token) -> starting -> ready; then crashed
 * (restart on the next Send after the 1, 2, 4, 8 s backoff), or unavailable
 * (no sandbox, no network: no restart). Every stdout line is validated in
 * agent_frames.zig first; a rejected frame is never shown, and three restart
 * the helper. The token is written once to the pipe at the helper's fd 3,
 * then wiped; it is never logged. */

#define _GNU_SOURCE /* pipe2 */
#include "agent_helper.h"

#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <signal.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "agent_host.h"
#include "agent_secrets.h"
#include "agent_secrets_window.h"

/* agent_frames.zig */
typedef struct {
  int kind;
  const char *session;
  size_t session_len;
  const char *text;
  size_t text_len;
  const char *code;
  size_t code_len;
  int is_error;
} ZbAgentFrame;
enum { ZB_FRAME_READY, ZB_FRAME_SESSION_OPENED, ZB_FRAME_DELTA, ZB_FRAME_MESSAGE, ZB_FRAME_TOOL_CALL,
       ZB_FRAME_RESULT, ZB_FRAME_ERROR, ZB_FRAME_SESSION_ENDED };
void zb_agent_frames_reset(void);
int zb_agent_frames_open_session(const char *session, unsigned int window);
void zb_agent_frames_close_session(const char *session);
int zb_agent_frames_validate(const char *line, size_t len, ZbAgentFrame *out);
const char *zb_agent_frames_reason(int code);
char *zb_agent_out_hello(void);
char *zb_agent_out_open_session(unsigned int window, unsigned int k);
char *zb_agent_out_prompt(const char *session, const char *text, size_t len);
char *zb_agent_out_session(int kind, const char *session);
char *zb_agent_out_shutdown(void);
void zb_agent_out_free(char *frame);
int zb_agent_config_changed(const char *home);

#define ZB_MAX_FRAME (256 * 1024)
#define ZB_REJECTIONS_RESTART 3
#define ZB_SHUTDOWN_MS 2000
#define ZB_TERM_MS 1000

#define ZB_TEXT_NETWORK "Agent network unavailable"
#define ZB_TEXT_SANDBOX "Agent sandbox unavailable"
#define ZB_TEXT_LOCKED "Agent unavailable: another zigBrowser is using the agent home"
#define ZB_TEXT_NO_TOKEN "Add a Claude token in the window that opened" /* S4.1 */
#define ZB_TEXT_TOO_LONG "Message too long (64 KiB at most)"
#define ZB_TEXT_REMOVED "The token was removed: the agent stopped" /* S4.2 */
#define ZB_TEXT_CONFIG "Agent configuration changed: run zigBrowser --agent-setup again" /* S3.10 */
/* S5.3 (rev 16.14): one fixed sentence per error code; a frame's message is never shown. */
#define ZB_TEXT_AUTH "Claude rejected the saved token. Open Account to replace it."
#define ZB_TEXT_OVERLOADED "Claude is busy; try again shortly."
#define ZB_TEXT_OVERFLOW "Agent output overflow"
/* S5.6 (rev 16.20.2): a reply still running this long after its text passed the
 * drawer's reply_text_max is interrupted with ZB_TEXT_OVERFLOW. */
#define ZB_OVERFLOW_S 10
size_t zb_drawer_reply_text_max(void);
#define ZB_TEXT_AGENT_ERROR "Agent error"

enum { H_IDLE, H_WAIT_NET, H_WAIT_TOKEN, H_STARTING, H_READY, H_CRASHED, H_UNAVAILABLE, H_STOPPING };

typedef struct {
  unsigned int win;
  unsigned int k;   /* sessions opened so far in this window */
  char session[48]; /* s-<win>-<k> while open */
  int open, busy;
  int confirmed; /* the helper answered session_opened */
  int checking;  /* a new session's config check runs (its prompt waits in pending) */
  int stopping;  /* Stop sent `interrupt`: the prompt's frames until its result are dropped */
  /* S5.6: the running reply's delta bytes, its overflow timer (0: none), and whether
   * that timer interrupted it (its end then shows ZB_TEXT_OVERFLOW). */
  size_t reply_bytes;
  guint overflow_timer;
  int overflowed;
  GPtrArray *pending; /* prompts (char *) waiting for a ready helper */
} ZbWin;

/* One helper process's pipe reader (stdout or stderr). Every pending read
 * holds a reference; once its process is forgotten the reader is dead, and a
 * late completion only drops its reference: it parses nothing, rearms
 * nothing, and never touches the next process's buffers (RoseCat 5682). */
typedef struct {
  int refs;
  int live;
  int frames; /* stdout parses frames; stderr is drained and discarded */
  GInputStream *stream;
  GCancellable *cancel;
  GString *line;
  int dropping;
  char buf[16384];
} ZbReader;

static struct {
  int configured, e2e;
  char **argv, **envp;
  char *home, *unavailable, *bubble, *refusal;
  int state;
  GSubprocess *proc;
  pid_t pid;
  GOutputStream *in;
  GCancellable *cancel;
  ZbReader *out, *err;
  GHashTable *wins; /* win id -> ZbWin* */
  unsigned int restarts;
  gint64 crashed_at;
  guint restart_timer;
  int rejections, restart_now, stopping;
  /* The token was removed (S4.2): this helper is being stopped on purpose; once it
   * has exited the agent is idle, and a prompt sent meanwhile starts it afresh. */
  pid_t removing;
  /* Bumped by every removal: a token fetch carries the generation it began in, and an
   * answer from an older one is wiped unused (RoseCat 5813). */
  unsigned int token_gen;
  /* While unavailable (no sandbox, no network, a refused seam): what every
   * later Send shows again. */
  const char *down_reason, *down_text;
  ZbChildSetup setup;
} zb_helper = {.state = H_IDLE};

static void start(void);

/* No sandbox, no network or a refused seam: no helper runs in this browser. */
static void go_down(const char *reason, const char *text) {
  zb_helper.state = H_UNAVAILABLE;
  zb_helper.removing = 0; /* a removal under way ends here too */
  zb_helper.down_reason = reason;
  zb_helper.down_text = text;
  zb_drawer_agent_status(0, "unavailable", reason);
  zb_drawer_agent_message(0, "system", text, strlen(text));
}

static ZbWin *win_get(unsigned int win) {
  if (zb_helper.wins == NULL) {
    zb_helper.wins = g_hash_table_new(g_direct_hash, g_direct_equal);
  }
  ZbWin *w = g_hash_table_lookup(zb_helper.wins, GUINT_TO_POINTER(win));
  if (w == NULL) {
    w = g_new0(ZbWin, 1);
    w->win = win;
    w->pending = g_ptr_array_new_with_free_func(g_free);
    g_hash_table_insert(zb_helper.wins, GUINT_TO_POINTER(win), w);
  }
  return w;
}

static ZbWin *win_of_session(const char *session, size_t len) {
  if (zb_helper.wins == NULL || session == NULL) {
    return NULL;
  }
  GHashTableIter it;
  gpointer key, value;
  g_hash_table_iter_init(&it, zb_helper.wins);
  while (g_hash_table_iter_next(&it, &key, &value)) {
    ZbWin *w = value;
    if (w->open && strlen(w->session) == len && memcmp(w->session, session, len) == 0) {
      return w;
    }
  }
  return NULL;
}

/* Every window that is waiting for the agent: tell it, drop what it queued. */
static void fail_waiting(const char *state, const char *reason, const char *text) {
  if (zb_helper.wins == NULL) {
    return;
  }
  GHashTableIter it;
  gpointer key, value;
  g_hash_table_iter_init(&it, zb_helper.wins);
  while (g_hash_table_iter_next(&it, &key, &value)) {
    ZbWin *w = value;
    if (w->pending->len > 0 || w->busy) {
      g_ptr_array_set_size(w->pending, 0);
      w->busy = 0;
      zb_drawer_agent_status(w->win, state, reason);
      zb_drawer_agent_message(w->win, "system", text, strlen(text));
    }
  }
}

static void write_frame(char *frame) {
  if (frame == NULL) {
    return;
  }
  if (zb_helper.in != NULL) {
    /* Small frames on a pipe the helper reads in a thread of its own. */
    g_output_stream_write_all(zb_helper.in, frame, strlen(frame), NULL, NULL, NULL);
  }
  zb_agent_out_free(frame);
}

static void overflow_reset(ZbWin *w) {
  if (w->overflow_timer != 0) {
    g_source_remove(w->overflow_timer);
    w->overflow_timer = 0;
  }
  w->reply_bytes = 0;
  w->overflowed = 0;
}

/* The reply is still running ZB_OVERFLOW_S after it passed the cap: interrupt it,
 * as Stop does; its end shows ZB_TEXT_OVERFLOW. */
static gboolean on_overflow(gpointer data) {
  ZbWin *w = zb_helper.wins != NULL ? g_hash_table_lookup(zb_helper.wins, data) : NULL;
  if (w == NULL) {
    return G_SOURCE_REMOVE;
  }
  w->overflow_timer = 0;
  if (w->open && w->busy && !w->stopping && zb_helper.state == H_READY) {
    w->overflowed = 1;
    w->stopping = 1;
    write_frame(zb_agent_out_session(0, w->session));
  }
  return G_SOURCE_REMOVE;
}

/* A ready helper: open the window's session if needed, then send its next
 * prompt. One prompt runs per session (the helper answers a second one with
 * `busy`): the rest wait here until the running one's `result`. */
static void flush(ZbWin *w) {
  if (zb_helper.state != H_READY || w->pending->len == 0 || w->busy || w->checking) {
    return;
  }
  if (!w->open) {
    w->k += 1;
    g_snprintf(w->session, sizeof w->session, "s-%u-%u", w->win, w->k);
    if (zb_agent_frames_open_session(w->session, w->win) != 0) {
      return;
    }
    w->open = 1;
    w->confirmed = 0;
    write_frame(zb_agent_out_open_session(w->win, w->k));
  }
  while (w->pending->len > 0 && !w->busy) {
    char *text = g_ptr_array_steal_index(w->pending, 0);
    char *frame = zb_agent_out_prompt(w->session, text, strlen(text));
    g_free(text);
    if (frame == NULL) {
      zb_drawer_agent_message(w->win, "error", ZB_TEXT_TOO_LONG, strlen(ZB_TEXT_TOO_LONG));
      continue;
    }
    write_frame(frame);
    w->busy = 1;
    w->stopping = 0; /* a stopped prompt that ended without its result (error, crash) */
    overflow_reset(w);
    zb_drawer_agent_status(w->win, "busy", "-");
  }
}

static void flush_all(void) {
  if (zb_helper.wins == NULL) {
    return;
  }
  GHashTableIter it;
  gpointer key, value;
  g_hash_table_iter_init(&it, zb_helper.wins);
  while (g_hash_table_iter_next(&it, &key, &value)) {
    flush(value);
  }
}

/* --- one helper frame -------------------------------------------------------- */

static const char *error_text(const char *code, size_t len) {
  if (len == 4 && memcmp(code, "auth", 4) == 0) return ZB_TEXT_AUTH;
  if (len == 10 && memcmp(code, "overloaded", 10) == 0) return ZB_TEXT_OVERLOADED;
  if (len == 8 && memcmp(code, "overflow", 8) == 0) return ZB_TEXT_OVERFLOW;
  return ZB_TEXT_AGENT_ERROR;
}

static void on_frame(const ZbAgentFrame *f) {
  ZbWin *w = win_of_session(f->session, f->session_len);
  unsigned int win = w != NULL ? w->win : 0;
  switch (f->kind) {
  case ZB_FRAME_READY:
    zb_helper.state = H_READY;
    zb_drawer_agent_status(0, "ready", "-");
    write_frame(zb_agent_out_hello());
    flush_all();
    break;
  case ZB_FRAME_DELTA:
    if (w != NULL && !w->stopping) {
      zb_drawer_agent_delta(win, w->session, f->text, f->text_len);
      w->reply_bytes += f->text_len;
      if (w->reply_bytes >= zb_drawer_reply_text_max() && w->overflow_timer == 0) {
        w->overflow_timer = g_timeout_add_seconds(ZB_OVERFLOW_S, on_overflow, GUINT_TO_POINTER(w->win));
      }
    }
    break;
  case ZB_FRAME_MESSAGE:
    if (w != NULL && !w->stopping) {
      zb_drawer_agent_message(win, "assistant", f->text, f->text_len);
    }
    break;
  case ZB_FRAME_RESULT:
    zb_helper.restarts = 0;
    if (w != NULL) {
      if (w->stopping && w->overflowed) { /* the overflow's interrupt ended it (S5.6) */
        w->stopping = 0;
        zb_drawer_agent_message(win, "error", ZB_TEXT_OVERFLOW, strlen(ZB_TEXT_OVERFLOW));
      } else if (w->stopping) { /* the interrupted prompt's end */
        w->stopping = 0;
        zb_drawer_agent_stopped(win);
      }
      overflow_reset(w);
      w->busy = 0;
      zb_drawer_agent_status(win, "ready", "-");
      flush(w);
    }
    break;
  case ZB_FRAME_ERROR:
    if (f->session != NULL && w == NULL) {
      break; /* its window closed: the session's error goes nowhere (RoseCat 5699) */
    }
    if (w != NULL && !w->busy) {
      break; /* no prompt runs: a second ending frame of an ended prompt shows nothing (rev 16.15) */
    }
    { /* win 0: a helper-wide error */
      const char *text = w != NULL && w->overflowed ? ZB_TEXT_OVERFLOW : error_text(f->code, f->code_len);
      zb_drawer_agent_message(win, "error", text, strlen(text));
    }
    if (w != NULL) { /* a session's error ends its prompt (chat's _prompt) */
      if (!w->confirmed) { /* it never opened: the next prompt opens a new one */
        zb_agent_frames_close_session(w->session);
        w->open = 0;
      }
      w->busy = 0;
      zb_drawer_agent_status(win, "ready", "-");
      flush(w);
    }
    break;
  case ZB_FRAME_SESSION_ENDED:
    if (w != NULL) {
      w->open = 0;
      w->busy = 0;
    }
    break;
  case ZB_FRAME_SESSION_OPENED:
    if (w != NULL) {
      w->confirmed = 1;
    }
    break;
  default: /* tool_call: no tool exists before S7 */
    break;
  }
}

static void reader_stop_out(void);
static void on_line(const char *line, size_t len) {
  ZbAgentFrame f;
  int code = zb_agent_frames_validate(line, len, &f);
  if (code == 0) {
    on_frame(&f);
    return;
  }
  g_printerr("zigBrowser: agent: rejected frame (%s)\n", zb_agent_frames_reason(code));
  if (++zb_helper.rejections == ZB_REJECTIONS_RESTART && zb_helper.pid > 0) {
    zb_helper.restart_now = 1;
    kill(-zb_helper.pid, SIGKILL);
    /* Nothing more of this helper is read: what it left in the pipe must not
     * count against it, or against the next one. */
    reader_stop_out();
  }
}

static void reader_unref(ZbReader *r) {
  if (--r->refs > 0) {
    return;
  }
  g_object_unref(r->stream);
  g_object_unref(r->cancel);
  g_string_free(r->line, TRUE);
  g_free(r);
}

static void reader_arm(ZbReader *r);

/* stdout: NDJSON frames, each validated (on_line). stderr: drained and kept
 * nowhere, never logged (plan D7 rev 16.7: its redacted log comes with S5.7). */
static void on_read(GObject *source, GAsyncResult *res, gpointer data) {
  ZbReader *r = data;
  gssize n = g_input_stream_read_finish(G_INPUT_STREAM(source), res, NULL);
  if (!r->live || n <= 0) { /* an old process's late answer, EOF or cancel */
    reader_unref(r);
    return;
  }
  for (gssize i = 0; r->frames && i < n && r->live; ++i) {
    char c = r->buf[i];
    if (c != '\n') {
      if (r->line->len <= ZB_MAX_FRAME) {
        g_string_append_c(r->line, c);
      } else {
        r->dropping = 1;
      }
      continue;
    }
    /* Over the cap: rejected without being parsed (D7, "dropped"). */
    on_line(r->line->str, r->dropping ? ZB_MAX_FRAME + 1 : r->line->len);
    g_string_truncate(r->line, 0);
    r->dropping = 0;
  }
  if (r->live) {
    reader_arm(r); /* the pending read keeps this reference */
  } else {
    reader_unref(r); /* a frame above ended this process */
  }
}

static void reader_arm(ZbReader *r) {
  /* Below input and redraw (S5.6): a helper that floods the pipe never holds up
   * the drawer's fold or the page; the full pipe slows the helper instead. */
  g_input_stream_read_async(r->stream, r->buf, sizeof r->buf, G_PRIORITY_DEFAULT_IDLE, r->cancel, on_read, r);
}

static ZbReader *reader_start(GInputStream *stream, int frames) {
  ZbReader *r = g_new0(ZbReader, 1);
  r->refs = 2; /* the process's, and the first pending read's */
  r->live = 1;
  r->frames = frames;
  r->stream = g_object_ref(stream);
  r->cancel = g_cancellable_new();
  r->line = g_string_new(NULL);
  reader_arm(r);
  return r;
}

static void reader_stop(ZbReader **slot) {
  ZbReader *r = *slot;
  if (r == NULL) {
    return;
  }
  *slot = NULL;
  r->live = 0;
  g_cancellable_cancel(r->cancel);
  reader_unref(r);
}

static void reader_stop_out(void) { reader_stop(&zb_helper.out); }

/* --- exit and restart ------------------------------------------------------- */

static void forget_process(void) {
  if (zb_helper.cancel != NULL) {
    g_cancellable_cancel(zb_helper.cancel);
    g_clear_object(&zb_helper.cancel);
  }
  zb_helper.in = NULL;
  reader_stop(&zb_helper.out);
  reader_stop(&zb_helper.err);
  g_clear_object(&zb_helper.proc);
  zb_helper.pid = 0;
  if (zb_helper.wins != NULL) {
    GHashTableIter it;
    gpointer key, value;
    g_hash_table_iter_init(&it, zb_helper.wins);
    while (g_hash_table_iter_next(&it, &key, &value)) {
      ZbWin *w = value;
      w->open = 0; /* the helper's sessions, and their prompts, died with it */
      w->busy = 0;
    }
  }
}

/* A removed token's helper is gone: idle, and a prompt sent meanwhile starts afresh
 * (its token fetch finds none, so the Secrets window opens). */
static void removal_done(void) {
  zb_helper.removing = 0;
  zb_helper.restart_now = 0;
  zb_helper.state = H_IDLE;
  zb_drawer_agent_status(0, "stopped", "-");
  if (zb_helper.wins == NULL) {
    return;
  }
  GHashTableIter it;
  gpointer key, value;
  g_hash_table_iter_init(&it, zb_helper.wins);
  while (g_hash_table_iter_next(&it, &key, &value)) {
    if (((ZbWin *)value)->pending->len > 0) {
      start();
      return;
    }
  }
}

/* The removal's ladder, without blocking the main loop: shutdown was sent, then
 * SIGTERM after ZB_SHUTDOWN_MS, then SIGKILL after ZB_TERM_MS more. */
static gboolean on_removal_kill(gpointer data) {
  pid_t pid = GPOINTER_TO_INT(data);
  if (zb_helper.removing == pid && zb_helper.pid == pid) {
    kill(-pid, SIGKILL);
  }
  return G_SOURCE_REMOVE;
}

static gboolean on_removal_term(gpointer data) {
  pid_t pid = GPOINTER_TO_INT(data);
  if (zb_helper.removing == pid && zb_helper.pid == pid) {
    kill(-pid, SIGTERM);
    g_timeout_add(ZB_TERM_MS, on_removal_kill, data);
  }
  return G_SOURCE_REMOVE;
}

static void on_helper_exit(GObject *source, GAsyncResult *res, gpointer data) {
  (void)data;
  GSubprocess *proc = G_SUBPROCESS(source);
  if (!g_subprocess_wait_finish(proc, res, NULL) || proc != zb_helper.proc) {
    return; /* cancelled at quit, or an older helper */
  }
  int exited = g_subprocess_get_if_exited(proc);
  int value = exited ? g_subprocess_get_exit_status(proc) : g_subprocess_get_term_sig(proc);
  forget_process();
  if (zb_helper.removing != 0) {
    removal_done();
    return;
  }
  if (zb_helper.stopping) {
    return;
  }
  if (zb_helper.restart_now) {
    zb_helper.restart_now = 0;
    zb_helper.state = H_IDLE;
    start();
    return;
  }
  char reason[32], text[96];
  if (exited && value == 3) {
    go_down("sandbox", ZB_TEXT_SANDBOX);
    return;
  }
  g_snprintf(reason, sizeof reason, "%s-%d", exited ? "exit" : "signal", value);
  g_snprintf(text, sizeof text, "Agent stopped (%s %d). Send to restart.", exited ? "exit" : "signal", value);
  zb_helper.state = H_CRASHED;
  zb_helper.crashed_at = g_get_monotonic_time();
  zb_drawer_agent_status(0, "crashed", reason);
  zb_drawer_agent_message(0, "system", text, strlen(text));
  if (zb_helper.wins != NULL) {
    GHashTableIter it;
    gpointer key, value_ptr;
    g_hash_table_iter_init(&it, zb_helper.wins);
    while (g_hash_table_iter_next(&it, &key, &value_ptr)) {
      ((ZbWin *)value_ptr)->busy = 0;
    }
  }
}

static gboolean on_restart_due(gpointer data) {
  (void)data;
  zb_helper.restart_timer = 0;
  if (zb_helper.state == H_CRASHED) {
    zb_helper.restarts += 1;
    zb_helper.state = H_IDLE;
    start();
  }
  return G_SOURCE_REMOVE;
}

/* After a crash: restart now if the backoff has passed, else when it does. */
static void restart_after_backoff(void) {
  if (zb_helper.restart_timer != 0) {
    return;
  }
  guint backoff = 1000u << MIN(zb_helper.restarts, 3u);
  gint64 elapsed = (g_get_monotonic_time() - zb_helper.crashed_at) / 1000;
  guint wait = elapsed >= (gint64)backoff ? 0 : (guint)(backoff - elapsed);
  zb_helper.restart_timer = g_timeout_add(wait, on_restart_due, NULL);
}

/* --- start: lock, netd, token, spawn ---------------------------------------- */

static void helper_child_setup(gpointer data) {
  setpgid(0, 0); /* its own group: the stop signals reach it and nothing else */
  zb_agent_die_with_browser(data);
}

static void spawn_with(char *token) {
  int fds[2];
  if (pipe2(fds, O_CLOEXEC) != 0) {
    zb_secrets_free(token);
    zb_helper.state = H_IDLE;
    fail_waiting("crashed", "exit-1", "Agent could not start");
    return;
  }
  GSubprocessLauncher *launcher = g_subprocess_launcher_new(
      G_SUBPROCESS_FLAGS_STDIN_PIPE | G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_PIPE);
  g_subprocess_launcher_set_environ(launcher, zb_helper.envp);
  g_subprocess_launcher_take_fd(launcher, fds[0], 3);
  zb_helper.setup.parent = getpid();
  zb_helper.setup.policy = zb_spawn_policy_linux(0);
  g_subprocess_launcher_set_child_setup(launcher, helper_child_setup, &zb_helper.setup, NULL);
  GError *error = NULL;
  GSubprocess *proc = g_subprocess_launcher_spawnv(launcher, (const char *const *)zb_helper.argv, &error);
  g_object_unref(launcher); /* closes our copy of the read end */
  if (proc == NULL) {
    g_printerr("zigBrowser: agent: cannot start the helper: %s\n", error != NULL ? error->message : "?");
    g_clear_error(&error);
    close(fds[1]);
    zb_secrets_free(token);
    zb_helper.state = H_IDLE;
    fail_waiting("unavailable", "runtime-missing", ZB_AGENT_TEXT_RUNTIME);
    return;
  }
  /* The token: written once, the pipe closed, our copy wiped (zb_secrets_free). */
  size_t len = strlen(token), done = 0;
  while (done < len) {
    ssize_t n = write(fds[1], token + done, len - done);
    if (n < 0 && errno == EINTR) {
      continue;
    }
    if (n <= 0) {
      break;
    }
    done += (size_t)n;
  }
  close(fds[1]);
  zb_secrets_free(token);

  zb_helper.proc = proc;
  zb_helper.pid = (pid_t)g_ascii_strtoll(g_subprocess_get_identifier(proc), NULL, 10);
  zb_helper.in = g_subprocess_get_stdin_pipe(proc);
  zb_helper.cancel = g_cancellable_new();
  zb_helper.rejections = 0;
  zb_helper.state = H_STARTING;
  zb_agent_frames_reset();
  zb_helper.out = reader_start(g_subprocess_get_stdout_pipe(proc), 1);
  zb_helper.err = reader_start(g_subprocess_get_stderr_pipe(proc), 0);
  g_subprocess_wait_async(proc, zb_helper.cancel, on_helper_exit, NULL);
}

static void on_token(ZbTokenResult result, char *token, void *data) {
  if (GPOINTER_TO_UINT(data) != zb_helper.token_gen || zb_helper.state != H_WAIT_TOKEN) {
    zb_secrets_free(token);
    return;
  }
  if (result != ZB_TOKEN_OK || token == NULL) {
    zb_secrets_free(token);
    zb_helper.state = H_IDLE; /* the next Send asks again */
    fail_waiting("unavailable", "no-token", ZB_TEXT_NO_TOKEN);
    return;
  }
  spawn_with(token);
}

static void fetch_token(void) {
  zb_helper.state = H_WAIT_TOKEN;
  zb_agent_token_fetch(zb_secrets_window_store(), zb_helper.home, on_token, GUINT_TO_POINTER(zb_helper.token_gen));
}

static void on_net_ready(void *data) {
  (void)data;
  if (zb_helper.state == H_WAIT_NET) {
    fetch_token();
  }
}

/* netd failed or exited: no helper runs without it, and none restarts (§3c.2). */
static void on_net_unavailable(void *data) {
  (void)data;
  if (zb_helper.pid > 0) {
    zb_helper.stopping = 1;
    kill(-zb_helper.pid, SIGKILL);
    waitpid(zb_helper.pid, NULL, 0);
    forget_process();
    zb_helper.stopping = 0;
  }
  go_down("network", ZB_TEXT_NETWORK);
}

static void start(void) {
  switch (zb_agent_home_lock(zb_helper.home)) {
  case 0:
    break;
  case -2: /* another browser owns the home; the next Send tries again (S3.12) */
    fail_waiting("unavailable", "home-locked", ZB_TEXT_LOCKED);
    return;
  default:
    fail_waiting("unavailable", "home-locked", ZB_TEXT_LOCKED);
    return;
  }
  zb_drawer_agent_status(0, "starting", "-");
  switch (zb_agent_net_ensure()) {
  case ZB_AGENT_NET_READY:
    fetch_token();
    break;
  case ZB_AGENT_NET_STARTING:
    zb_helper.state = H_WAIT_NET;
    break;
  default:
    on_net_unavailable(NULL);
    break;
  }
}

/* What a window's queued prompt needs from the helper's state. */
static void dispatch(ZbWin *w) {
  switch (zb_helper.state) {
  case H_READY:
    flush(w);
    return;
  case H_CRASHED:
    restart_after_backoff();
    return;
  case H_IDLE:
    start();
    return;
  default: /* starting: sent once ready */
    return;
  }
}

/* A new session first re-hashes `.claude` against the manifest --agent-setup
 * wrote (plan section 2, S3.10): a change made outside the sandbox refuses
 * it, and nothing starts. The tree can be hundreds of MB, so the hashing runs
 * on a worker thread; the window's prompt waits in `pending` meanwhile. */
static void config_check_thread(GTask *task, gpointer source, gpointer data, GCancellable *cancel) {
  (void)source;
  (void)cancel;
  g_task_return_int(task, zb_agent_config_changed(data));
}

static void on_config_checked(GObject *source, GAsyncResult *res, gpointer data) {
  (void)source;
  unsigned int win = GPOINTER_TO_UINT(data);
  gssize changed = g_task_propagate_int(G_TASK(res), NULL);
  ZbWin *w = zb_helper.wins != NULL ? g_hash_table_lookup(zb_helper.wins, GUINT_TO_POINTER(win)) : NULL;
  if (w == NULL) { /* the window closed meanwhile */
    return;
  }
  w->checking = 0;
  if (changed != 0) {
    g_ptr_array_set_size(w->pending, 0);
    zb_drawer_agent_status(win, "unavailable", "config-changed");
    zb_drawer_agent_message(win, "system", ZB_TEXT_CONFIG, strlen(ZB_TEXT_CONFIG));
    return;
  }
  if (zb_helper.state == H_UNAVAILABLE) { /* went down meanwhile */
    g_ptr_array_set_size(w->pending, 0);
    zb_drawer_agent_status(win, "unavailable", zb_helper.down_reason);
    zb_drawer_agent_message(win, "system", zb_helper.down_text, strlen(zb_helper.down_text));
    return;
  }
  if (w->pending->len > 0) {
    dispatch(w);
  }
}

static void check_config(ZbWin *w) {
  w->checking = 1;
  GTask *task = g_task_new(NULL, NULL, on_config_checked, GUINT_TO_POINTER(w->win));
  g_task_set_task_data(task, g_strdup(zb_helper.home), g_free);
  g_task_run_in_thread(task, config_check_thread);
  g_object_unref(task);
}

/* --- the API ------------------------------------------------------------------ */

void zb_agent_helper_configure(const char *const *argv, const char *const *envp, const char *home,
                               const char *unavailable, const char *bubble, const char *refusal,
                               int e2e_protocol) {
  if (zb_helper.configured) {
    return;
  }
  zb_helper.configured = 1;
  zb_helper.argv = g_strdupv((char **)argv);
  zb_helper.envp = g_strdupv((char **)envp);
  zb_helper.home = g_strdup(home);
  zb_helper.unavailable = g_strdup(unavailable);
  zb_helper.bubble = g_strdup(bubble);
  zb_helper.refusal = g_strdup(refusal);
  zb_helper.e2e = e2e_protocol;
  zb_agent_net_set_listener(on_net_unavailable, NULL);
  zb_agent_net_set_ready_listener(on_net_ready, NULL);
}

int zb_agent_helper_configured(void) { return zb_helper.configured; }

void zb_agent_helper_send(unsigned int win, const char *text) {
  if (!zb_helper.configured) {
    return;
  }
  if (zb_helper.unavailable != NULL) {
    zb_drawer_agent_status(win, "unavailable", zb_helper.unavailable);
    zb_drawer_agent_message(win, "system", zb_helper.bubble, strlen(zb_helper.bubble));
    return;
  }
  if (zb_helper.refusal != NULL) {
    g_printerr("%s\n", zb_helper.refusal);
    g_clear_pointer(&zb_helper.refusal, g_free);
    go_down("-", "Agent unavailable: a test seam was refused");
    return;
  }
  ZbWin *w = win_get(win);
  if (zb_helper.state == H_UNAVAILABLE) {
    zb_drawer_agent_status(win, "unavailable", zb_helper.down_reason);
    zb_drawer_agent_message(win, "system", zb_helper.down_text, strlen(zb_helper.down_text));
    return;
  }
  g_ptr_array_add(w->pending, g_strdup(text));
  if (w->checking) { /* sent once the running check passes */
    return;
  }
  if (!w->open && w->pending->len == 1) {
    /* The home's lock first: a browser refused it reads nothing of the home,
     * `.claude` included (S3.12). Taking a held lock again is a no-op. */
    if (zb_agent_home_lock(zb_helper.home) != 0) {
      g_ptr_array_set_size(w->pending, 0);
      zb_drawer_agent_status(win, "unavailable", "home-locked");
      zb_drawer_agent_message(win, "system", ZB_TEXT_LOCKED, strlen(ZB_TEXT_LOCKED));
      return;
    }
    check_config(w);
    return;
  }
  dispatch(w);
}

void zb_agent_helper_interrupt(unsigned int win) {
  ZbWin *w = zb_helper.wins != NULL ? g_hash_table_lookup(zb_helper.wins, GUINT_TO_POINTER(win)) : NULL;
  if (w == NULL || !w->open || !w->busy || w->stopping || zb_helper.state != H_READY) {
    return;
  }
  w->stopping = 1;
  write_frame(zb_agent_out_session(0, w->session));
}

void zb_agent_helper_token_removed(void) {
  if (!zb_helper.configured || zb_helper.state == H_UNAVAILABLE || zb_helper.state == H_STOPPING) {
    return;
  }
  if (zb_helper.restart_timer != 0) { /* a crashed helper would come back with the old token */
    g_source_remove(zb_helper.restart_timer);
    zb_helper.restart_timer = 0;
  }
  zb_helper.token_gen += 1; /* every fetch begun before now is stale */
  if (zb_helper.pid <= 0) {
    switch (zb_helper.state) {
    case H_WAIT_NET:   /* netd's ready no longer fetches: the state is idle */
    case H_WAIT_TOKEN: /* the fetch in flight answers into an older generation */
      fail_waiting("stopped", "-", ZB_TEXT_REMOVED); /* the waiting prompt, decided once */
      zb_helper.state = H_IDLE;
      zb_drawer_agent_status(0, "stopped", "-");
      break;
    case H_CRASHED:
      zb_helper.state = H_IDLE;
      break;
    default:
      break;
    }
    return;
  }
  /* What the windows were waiting for would have used the removed token. */
  fail_waiting("stopped", "-", ZB_TEXT_REMOVED);
  zb_helper.removing = zb_helper.pid;
  zb_helper.state = H_STOPPING;
  write_frame(zb_agent_out_shutdown()); /* chat ends every session, so each CLI exits */
  if (zb_helper.in != NULL) {
    g_output_stream_close(zb_helper.in, NULL, NULL);
  }
  g_timeout_add(ZB_SHUTDOWN_MS, on_removal_term, GINT_TO_POINTER(zb_helper.pid));
}

void zb_agent_helper_window_closed(unsigned int win) {
  ZbWin *w = zb_helper.wins != NULL ? g_hash_table_lookup(zb_helper.wins, GUINT_TO_POINTER(win)) : NULL;
  if (w == NULL) {
    return;
  }
  if (w->open && zb_helper.state == H_READY) {
    /* The validator keeps the session: the helper's session_ended (and a late
     * session_opened) are valid frames, and that session_ended closes it
     * (RoseCat 5681). With the window gone they are accepted and dropped. */
    write_frame(zb_agent_out_session(1, w->session));
  }
  overflow_reset(w);
  g_hash_table_remove(zb_helper.wins, GUINT_TO_POINTER(win));
  g_ptr_array_unref(w->pending);
  g_free(w);
}

static int reaped_within(pid_t pid, int ms) {
  for (int waited = 0; waited < ms; waited += 20) {
    pid_t r = waitpid(pid, NULL, WNOHANG);
    if (r == pid || (r < 0 && errno == ECHILD)) {
      return 1;
    }
    g_usleep(20 * 1000);
  }
  return 0;
}

void zb_agent_helper_stop(void) {
  if (zb_helper.pid <= 0) {
    return;
  }
  pid_t pid = zb_helper.pid;
  zb_helper.stopping = 1;
  write_frame(zb_agent_out_shutdown());
  if (zb_helper.in != NULL) {
    g_output_stream_close(zb_helper.in, NULL, NULL);
  }
  if (!reaped_within(pid, ZB_SHUTDOWN_MS)) {
    kill(-pid, SIGTERM);
    if (!reaped_within(pid, ZB_TERM_MS)) {
      kill(-pid, SIGKILL);
      waitpid(pid, NULL, 0);
    }
  }
  forget_process();
}
