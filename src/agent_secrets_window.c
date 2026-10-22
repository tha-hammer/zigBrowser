/* The Secrets window (chat-drawer plan D11, slice S4; see
 * agent_secrets_window.h). Native GTK only: no WebView, no web content, no
 * JavaScript. Text the user types is read once on Save, the entry is
 * cleared at once, and the token is never put into a label, a row or a log.
 * The status line shows fixed sentences only. */

#include "agent_secrets_window.h"

#include "agent_drawer.h" /* zb_emit_protocol_row */
#include "agent_helper.h" /* zb_agent_helper_token_removed */
#include "agent_login.h"   /* Sign in with Claude.ai (S6b1) */
#include "agent_auth_window.h" /* its auth window (S6b2) */
#include "agent_secrets.h"

#include <stdio.h>
#include <string.h>

/* src/agent_secrets.zig (C exports, Linux only). Each takes the token's
 * bytes without a terminator and never keeps them. */
/* 1 when the paste, trimmed of surrounding ASCII whitespace, is a setup
 * token (^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$): it is text[*start..] for
 * *token_len bytes. 0 otherwise. */
int zb_secrets_token_from_paste(const char *text, size_t len, size_t *start, size_t *token_len);
/* 0 on success. Creates secrets/ (0700) if needed, then writes the token
 * to a fresh 0600 file and renames it into place. */
int zb_secrets_store_file(const char *agent_home, const char *token, size_t len);
/* 0 when the file is gone (or was never there). */
int zb_secrets_remove_file(const char *agent_home);
/* 1 when a token file is present (a valid one, by loadFile's rules). */
int zb_secrets_file_present(const char *agent_home);

#define TEXT_TITLE "Claude Agent account"
#define TEXT_PASTE "Paste a long-lived token (from \"claude setup-token\")"
#define TEXT_EMPTY "No token is stored."
#define TEXT_SERVICE "Connected. The token is stored in the system keyring."
#define TEXT_FILE "Connected. The token is stored in a private file."
#define TEXT_REJECTED "That doesn't look like a token."
#define TEXT_NO_KEYRING "No system keyring is available. Nothing was stored."
#define TEXT_FILE_WARNING "The token will be stored unencrypted on disk, readable only by you."
#define TEXT_FILE_BUTTON "Save to a private file instead"
#define TEXT_WORKING "Saving..."
#define TEXT_FAILED "The token could not be saved."
#define TEXT_REMOVE_FAILED "The token could not be removed."
/* Sign in with Claude.ai (plan S6b1, rev 16.18.3): fixed sentences only. */
#define TEXT_SIGNIN_BUTTON "Sign _in with Claude.ai"
#define TEXT_SIGNING "Signing in..."
#define TEXT_NEED_CODE "Paste the code from the sign-in page."
#define TEXT_SIGNED_SERVICE "Signed in. The token is stored in the system keyring."
#define TEXT_SIGNED_FILE "Signed in. The token is stored in a private file."
#define TEXT_BAD_CODE "That doesn't look like a sign-in code."
#define TEXT_SIGNIN_FAILED "Sign-in failed."
#define TEXT_SIGNIN_CANCELLED "Sign-in cancelled."
/* The reason line under "Sign-in failed." (rev 16.18.9): one fixed sentence per ending. */
#define TEXT_REASON_EXCHANGE "Claude.ai could not be reached, or it did not accept the code. Try again."
#define TEXT_REASON_TIMEOUT "The sign-in took too long. Try again."
#define TEXT_REASON_CLI "The Claude CLI stopped before it gave a token. Try again."
#define TEXT_REASON_NETWORK "The sign-in's network could not start. Try again."
#define TEXT_REASON_OTHER "Something unexpected happened during sign-in. Try again."
#define TEXT_LINK "Open this link in your browser to sign in:"
#define TEXT_COPY_LINK "Copy link"
/* The Navigation approval drop-down (S8 decision 16, rev 16.20.58): the store's one writer. */
#define TEXT_NAV_LABEL "_Navigation approval:"
#define TEXT_NAV_UNREADABLE "Navigation approval setting is unreadable; asking for every navigation."
#define TEXT_NAV_REFUSED "The navigation approval setting could not be saved."

/* agent_tools.zig: the store (0 yes, 1 no, 2 conditional). */
int zb_agent_navapproval_read(const char *home, int *unreadable);
int zb_agent_navapproval_write(const char *home, int value);
static const char *const nav_values[] = {"yes", "no", "conditional"};

typedef enum {
  STATE_EMPTY,
  STATE_SERVICE,
  STATE_FILE,
  STATE_NO_KEYRING,
  STATE_REJECTED,
} State;

static const char *const state_rows[] = {"empty", "connected-secret-service", "connected-file", "no-keyring",
                                         "rejected"};

typedef struct {
  ZbSecretsConfig config;
  char *agent_home;
  /* --agent-secret-store: -1 when not given, else a ZbSecretStore. */
  int explicit_store;
  /* This session's click on "Save to a private file instead" (D11: the
   * explicit choice selects the file store; the file then persists it). */
  int file_choice;
  GtkWidget *window;
  GtkWidget *entry;
  GtkWidget *save;
  GtkWidget *remove;
  GtkWidget *status;
  /* Under the status line after a failed sign-in (rev 16.18.9): why it failed. */
  GtkWidget *reason;
  int reason_shown;
  GtkWidget *file_box; /* the warning and "Save to a private file instead" */
  GtkWidget *file_button;
  /* Sign in with Claude.ai: the button, the code entry and its Send code
   * button (shown only while the sign-in waits for a code), and Cancel. */
  GtkWidget *signin;
  GtkWidget *code_box;
  GtkWidget *code;
  GtkWidget *send_code;
  GtkWidget *cancel;
  /* The sign-in link (rev 16.18.4): the authorize URL, selectable, and Copy link. */
  GtkWidget *link_box;
  GtkWidget *link;
  GtkWidget *copy_link;
  GtkWindow *parent; /* the transient parent whose delete-event we watch (weak) */
  /* The Navigation approval drop-down (Yes, No, Conditional) and its note line. */
  GtkWidget *nav;
  GtkWidget *nav_note;
  int nav_showing; /* the drop-down is being set to the store's value: no write */
  char *link_url;
  /* The token being stored came from a sign-in: its row and sentences. */
  int signin_store;
  /* Remove applies to the current state (a token is stored). */
  int can_remove;
  /* A sign-in this window started has not ended yet (its own flag: agent_login.c
   * still counts as running while it tears down after the ending). */
  int signin_active;
  /* A token the Secret Service did not take, kept only until the user
   * chooses the private file or closes the window (then wiped). It belongs
   * to the current epoch: no older answer may touch it. */
  char *pending;
  /* An operation (the opening lookup, Save, Remove) is in flight: Save,
   * Remove and the entry wait for it. */
  int busy;
  /* Remove: the store that was active when it started (its failure rule),
   * and whether its file deletion, done at the click, succeeded. */
  int removing_store;
  int removed_file;
  int configured;
  /* Bumped when any operation starts and when the window closes. An answer
   * carries the epoch it was started in; any other epoch's answer changes
   * nothing (RoseCat 5648). */
  guint epoch;
} Secrets;

static Secrets secrets;

/* src/agent_secrets.zig: the active store (explicit -1 for no flag). */
int zb_secrets_effective_store(int explicit_store, int session_file_choice, const char *agent_home);
/* 0 with the delays filled in, -1 for a bad value. */
int zb_secrets_parse_test_delay(const char *text, unsigned *lookup_ms, unsigned *store_ms, unsigned *clear_ms,
                                unsigned *preclear_ms);

#define TEST_DELAY_ENV "ZIGBROWSER_AGENT_SECRETS_TEST_DELAY"

static void on_fetch_observed(int result);

void zb_secrets_window_configure(const ZbSecretsConfig *config) {
  secrets.config = *config;
  g_free(secrets.agent_home);
  secrets.agent_home = g_strdup(config->agent_home != NULL ? config->agent_home : "");
  secrets.config.agent_home = secrets.agent_home;
  secrets.explicit_store = config->store;
}

void zb_secrets_window_setup(int store, const char *agent_home, int e2e_protocol) {
  ZbSecretsConfig config = {e2e_protocol, ZB_SECRET_STORE_SERVICE, agent_home, NULL, NULL};
  zb_secrets_window_configure(&config);
  secrets.explicit_store = store == ZB_SECRET_STORE_FILE || store == ZB_SECRET_STORE_SERVICE ? store : -1;
  secrets.configured = 1;
  zb_secrets_set_fetch_observer(e2e_protocol ? on_fetch_observed : NULL);
  const char *delay = e2e_protocol ? g_getenv(TEST_DELAY_ENV) : NULL;
  if (delay != NULL) {
    unsigned lookup_ms = 0, store_ms = 0, clear_ms = 0, preclear_ms = 0;
    if (zb_secrets_parse_test_delay(delay, &lookup_ms, &store_ms, &clear_ms, &preclear_ms) == 0) {
      zb_secrets_set_test_delay(lookup_ms, store_ms, clear_ms, preclear_ms);
    } else {
      fprintf(stderr, "zigBrowser: agent: bad " TEST_DELAY_ENV "\n");
    }
  }
}

int zb_secrets_window_configured(void) { return secrets.configured; }

int zb_secrets_window_store(void) {
  return zb_secrets_effective_store(secrets.explicit_store, secrets.file_choice,
                                    secrets.agent_home != NULL ? secrets.agent_home : "");
}

const char *zb_secrets_window_home(void) { return secrets.agent_home; }

int zb_secrets_window_open(void) { return secrets.window != NULL; }

/* --- rows and state -------------------------------------------------------- */

static void secrets_row(const char *kind, const char *a, const char *b) {
  const char *fields[] = {kind, a, b};
  zb_emit_protocol_row(secrets.config.e2e_protocol, "SECRETS", fields, b != NULL ? 3 : 2);
}

/* `SECRETS fetch begin` when a token fetch starts and `SECRETS fetch <result>`
 * when it answers (e2e only): with `SECRETS remove click`, a test can see that a
 * Remove fell between the two (RoseCat 5821). */
static void on_fetch_observed(int result) {
  static const char *const words[] = {"ok", "absent", "unavailable", "refused"};
  secrets_row("fetch", result >= 0 && result <= 3 ? words[result] : "begin", NULL);
}

static void wipe_pending(void) {
  if (secrets.pending != NULL) {
    explicit_bzero(secrets.pending, strlen(secrets.pending));
    g_free(secrets.pending);
    secrets.pending = NULL;
  }
}

/* The status line shows fixed sentences only; `SECRETS text` reports each one,
 * so a test can scan the window's text for the token. */
static void set_status_text(const char *text) {
  gtk_label_set_text(GTK_LABEL(secrets.status), text);
  secrets_row("text", text, NULL);
}

static void update_sensitivity(void);

static void set_state(State state, const char *text) {
  set_status_text(text);
  gtk_widget_set_visible(secrets.file_box, state == STATE_NO_KEYRING && secrets.pending != NULL);
  secrets.can_remove = state == STATE_SERVICE || state == STATE_FILE;
  update_sensitivity();
  secrets_row("status", state_rows[state], NULL);
}

/* `SECRETS login <state>` (D7b, rev 16.18.3). */
static void login_row(const char *state) { secrets_row("login", state, NULL); }

/* The fixed reason for a sign-in's error ending (rev 16.18.9); NULL for `store`,
 * which has its own sentences, and for `cancelled`. Never the CLI's text. */
static const char *reason_for(const char *code) {
  if (code == NULL || strcmp(code, "cli") == 0) {
    return TEXT_REASON_CLI;
  }
  if (strcmp(code, "exchange") == 0) {
    return TEXT_REASON_EXCHANGE;
  }
  if (strcmp(code, "timeout") == 0) {
    return TEXT_REASON_TIMEOUT;
  }
  if (strcmp(code, "network") == 0) {
    return TEXT_REASON_NETWORK;
  }
  if (strcmp(code, "store") == 0 || strcmp(code, "cancelled") == 0) {
    return NULL;
  }
  return TEXT_REASON_OTHER; /* shape, protocol */
}

/* Shows `text` on the reason line, or hides it (NULL); each change writes
 * `SECRETS reason <sentence>` or `SECRETS reason -`. */
static void set_reason(const char *text) {
  if (secrets.window == NULL || (text == NULL && !secrets.reason_shown)) {
    return;
  }
  if (text != NULL) {
    gtk_label_set_text(GTK_LABEL(secrets.reason), text);
  }
  gtk_widget_set_visible(secrets.reason, text != NULL);
  secrets.reason_shown = text != NULL;
  secrets_row("reason", text != NULL ? text : "-", NULL);
}

/* One credential change at a time (rev 16.18.6, RoseCat 6024): a sign-in, from
 * Sign in until its token's store answered, locks the entry, Save, Remove and the
 * file choice; a manual operation in flight locks Sign in. */
static int signing_in(void) { return secrets.signin_active || secrets.signin_store; }

/* `SECRETS sensitive <control> <0|1>` (e2e only): a complete census of the
 * credential controls' sensitivity as GTK holds it, all five in a fixed order,
 * at every recomputation (rev 16.18.8; RoseCat 6055, 6122). */
static void report_sensitivity(void) {
  static const char *const names[] = {"entry", "save", "remove", "file", "signin"};
  GtkWidget *widgets[] = {secrets.entry, secrets.save, secrets.remove, secrets.file_button, secrets.signin};
  for (int i = 0; i < 5; ++i) {
    secrets_row("sensitive", names[i], gtk_widget_get_sensitive(widgets[i]) ? "1" : "0");
  }
}

static void update_sensitivity(void) {
  if (secrets.window == NULL) {
    return;
  }
  int locked = secrets.busy || signing_in();
  gtk_widget_set_sensitive(secrets.save, !locked);
  gtk_widget_set_sensitive(secrets.entry, !locked);
  gtk_widget_set_sensitive(secrets.file_button, !locked);
  gtk_widget_set_sensitive(secrets.remove, secrets.can_remove && !locked);
  gtk_widget_set_sensitive(secrets.signin, !locked && zb_login_configured());
  report_sensitivity();
}

static void set_busy(int busy) {
  secrets.busy = busy;
  update_sensitivity();
}

/* Starts an asynchronous operation: a new epoch, and the controls wait. */
static gpointer begin_operation(void) {
  secrets.epoch++;
  set_busy(1);
  return GUINT_TO_POINTER(secrets.epoch);
}

/* Whether an answer belongs to the operation in flight in this window. */
static int current(gpointer epoch) { return secrets.window != NULL && GPOINTER_TO_UINT(epoch) == secrets.epoch; }

static void notify_changed(int has_token) {
  if (secrets.config.changed != NULL) {
    secrets.config.changed(has_token, secrets.config.data);
  }
}

/* --- the current state, when the window opens ------------------------------ */

static void on_lookup(ZbSecretsResult result, char *token, gpointer epoch) {
  zb_secrets_free(token); /* only whether one exists matters here */
  if (!current(epoch)) {
    return;
  }
  set_busy(0);
  if (result == ZB_SECRETS_OK) {
    set_state(STATE_SERVICE, TEXT_SERVICE);
  } else if (result == ZB_SECRETS_ABSENT) {
    set_state(STATE_EMPTY, TEXT_EMPTY);
  } else {
    set_state(STATE_NO_KEYRING, TEXT_NO_KEYRING);
  }
}

static void show_current_state(void) {
  if (zb_secrets_window_store() == ZB_SECRET_STORE_FILE) {
    int present = zb_secrets_file_present(secrets.agent_home);
    set_state(present ? STATE_FILE : STATE_EMPTY, present ? TEXT_FILE : TEXT_EMPTY);
    return;
  }
  zb_secrets_service_lookup_async(on_lookup, begin_operation());
}

/* --- Save ------------------------------------------------------------------- */

static void store_in_file(const char *token) {
  int signin = secrets.signin_store;
  secrets.signin_store = 0;
  if (zb_secrets_store_file(secrets.agent_home, token, strlen(token)) == 0) {
    set_state(STATE_FILE, signin ? TEXT_SIGNED_FILE : TEXT_FILE);
    if (signin) {
      login_row("done");
    }
    notify_changed(1);
  } else {
    set_state(STATE_EMPTY, TEXT_FAILED);
    if (signin) {
      login_row("error-store");
    }
  }
}

static void on_service_stored(ZbSecretsResult result, gpointer epoch) {
  if (!current(epoch)) {
    return; /* an older window's or operation's answer: this one's token is not its to wipe */
  }
  set_busy(0);
  int signin = secrets.signin_store;
  if (result == ZB_SECRETS_OK) {
    secrets.signin_store = 0;
    wipe_pending();
    set_state(STATE_SERVICE, signin ? TEXT_SIGNED_SERVICE : TEXT_SERVICE);
    if (signin) {
      login_row("done");
    }
    notify_changed(1);
  } else {
    /* No silent fallback: keep the token only for the explicit file choice
     * (a signed-in token too: its store failed, so the sign-in did). */
    /* error-store is the sign-in's one, final ending (rev 16.18.6): the file
     * choice that stays offered is an ordinary Save of the kept token. */
    secrets.signin_store = 0;
    set_state(STATE_NO_KEYRING, TEXT_NO_KEYRING);
    if (signin) {
      login_row("error-store");
    }
  }
}

static void on_save(GtkWidget *button, gpointer unused) {
  (void)button;
  (void)unused;
  if (secrets.busy || signing_in()) {
    return;
  }
  /* Read once, then clear the entry at once, whatever happens next. */
  char *pasted = g_strdup(gtk_entry_get_text(GTK_ENTRY(secrets.entry)));
  gtk_entry_set_text(GTK_ENTRY(secrets.entry), "");
  wipe_pending();
  size_t start = 0, len = 0;
  int ok = zb_secrets_token_from_paste(pasted, strlen(pasted), &start, &len);
  /* Only the trimmed token is kept; the paste is wiped either way. */
  char *token = ok ? g_strndup(pasted + start, len) : NULL;
  explicit_bzero(pasted, strlen(pasted));
  g_free(pasted);
  if (!ok) {
    set_state(STATE_REJECTED, TEXT_REJECTED);
    return;
  }
  if (zb_secrets_window_store() == ZB_SECRET_STORE_FILE) {
    store_in_file(token);
    explicit_bzero(token, strlen(token));
    g_free(token);
    return;
  }
  secrets.pending = token; /* wiped on success, on close, or after the file choice */
  gpointer epoch = begin_operation();
  set_status_text(TEXT_WORKING);
  zb_secrets_service_store_async(token, on_service_stored, epoch);
}

static void on_save_to_file(GtkWidget *button, gpointer unused) {
  (void)button;
  (void)unused;
  if (secrets.busy || signing_in() || secrets.pending == NULL) {
    return;
  }
  secrets.file_choice = 1; /* the explicit choice: the file is now the active store */
  store_in_file(secrets.pending);
  wipe_pending();
  gtk_widget_set_visible(secrets.file_box, FALSE);
}

/* --- Sign in with Claude.ai (S6b1) -------------------------------------------- */

/* The sign-in's controls follow its state; the window may be gone (closing it
 * cancels the sign-in), and then only the row is written. */
static void signin_controls(int running, int need_code) {
  if (!running) {
    g_free(secrets.link_url);
    secrets.link_url = NULL;
  }
  if (secrets.window == NULL) {
    return;
  }
  gtk_widget_set_visible(secrets.link_box, running && secrets.link_url != NULL);
  update_sensitivity();
  gtk_widget_set_visible(secrets.cancel, running);
  gtk_widget_set_visible(secrets.code_box, running && need_code);
  if (running && need_code) {
    gtk_widget_grab_focus(secrets.code);
  }
}

/* The token from the login helper's fd 4: stored like a pasted one, in the
 * active store. It is wiped by agent_login.c after this returns. */
static void store_signed_in(const char *token) {
  secrets.signin_store = 1;
  if (zb_secrets_window_store() == ZB_SECRET_STORE_FILE || secrets.window == NULL) {
    if (secrets.window == NULL) {
      /* Nowhere to show a keyring failure: only the explicit store is used. */
      if (zb_secrets_window_store() != ZB_SECRET_STORE_FILE) {
        secrets.signin_store = 0;
        login_row("error-store");
        return;
      }
    }
    store_in_file(token);
    return;
  }
  wipe_pending();
  secrets.pending = g_strdup(token); /* wiped on success, on close, or after the file choice */
  gpointer epoch = begin_operation();
  set_status_text(TEXT_WORKING);
  zb_secrets_service_store_async(secrets.pending, on_service_stored, epoch);
}

/* The auth window captured this sign-in's callback (S6b2): its `<code>#<state>` goes to the
 * helper, as a pasted code does. */
static void on_auth_captured(const char *code, void *unused) {
  (void)unused;
  if (zb_login_send_code(code) == 0 && secrets.window != NULL) {
    set_status_text(TEXT_SIGNING);
    gtk_widget_set_visible(secrets.code_box, FALSE);
  }
}

static void on_login_event(ZbLoginEvent event, const char *detail, void *unused) {
  (void)unused;
  switch (event) {
  case ZB_LOGIN_EV_STARTING:
    secrets.signin_active = 1;
    login_row("starting");
    signin_controls(1, 0);
    if (secrets.window != NULL) {
      set_status_text(TEXT_SIGNING);
    }
    break;
  case ZB_LOGIN_EV_AUTH_URL:
    /* The link the user opens in their own browser, the fallback (S6b1); and the auth window on
     * the same URL (S6b2, rev 16.18.18), which the app's authorizeUrl already accepted. */
    g_free(secrets.link_url);
    secrets.link_url = g_strdup(detail);
    if (secrets.window != NULL) {
      gtk_label_set_text(GTK_LABEL(secrets.link), secrets.link_url);
      gtk_widget_set_visible(secrets.link_box, TRUE);
    }
    zb_auth_window_open(detail, secrets.config.e2e_protocol, on_auth_captured, NULL);
    break;
  case ZB_LOGIN_EV_NEED_CODE:
    login_row("need-code");
    signin_controls(1, 1);
    if (secrets.window != NULL) {
      set_status_text(TEXT_NEED_CODE);
    }
    break;
  case ZB_LOGIN_EV_DONE:
    zb_auth_window_close();
    secrets.signin_active = 0;
    secrets.signin_store = 1; /* locked until the store answers */
    signin_controls(0, 0);
    store_signed_in(detail);
    break;
  case ZB_LOGIN_EV_ERROR: {
    zb_auth_window_close();
    char row[32];
    g_snprintf(row, sizeof row, "error-%s", detail != NULL ? detail : "cli");
    secrets.signin_active = 0;
    login_row(row);
    signin_controls(0, 0);
    if (secrets.window != NULL) {
      set_status_text(TEXT_SIGNIN_FAILED);
      const char *why = reason_for(detail);
      if (why != NULL) {
        set_reason(why);
      }
    }
    break;
  }
  case ZB_LOGIN_EV_CANCELLED:
    zb_auth_window_close();
    secrets.signin_active = 0;
    login_row("cancelled");
    signin_controls(0, 0);
    if (secrets.window != NULL) {
      set_status_text(TEXT_SIGNIN_CANCELLED);
    }
    break;
  }
}

static void on_signin(GtkWidget *button, gpointer unused) {
  (void)button;
  (void)unused;
  if (secrets.busy || signing_in() || zb_login_running()) {
    return; /* one credential change at a time; a sign-in still tearing down is waited out */
  }
  set_reason(NULL);
  if (zb_login_start(on_login_event, NULL) != 0) {
    set_status_text(TEXT_SIGNIN_FAILED);
  }
}

static void on_send_code(GtkWidget *button, gpointer unused) {
  (void)button;
  (void)unused;
  /* Read once, then clear the entry at once; surrounding whitespace is a
   * paste's, never the code's. */
  char *pasted = g_strdup(gtk_entry_get_text(GTK_ENTRY(secrets.code)));
  gtk_entry_set_text(GTK_ENTRY(secrets.code), "");
  char *code = g_strstrip(pasted);
  if (zb_login_send_code(code) != 0) {
    set_status_text(TEXT_BAD_CODE);
  } else {
    set_status_text(TEXT_SIGNING);
    gtk_widget_set_visible(secrets.code_box, FALSE);
  }
  explicit_bzero(pasted, strlen(pasted));
  g_free(pasted);
}

static void on_copy_link(GtkWidget *button, gpointer unused) {
  (void)button;
  (void)unused;
  if (secrets.link_url != NULL) {
    gtk_clipboard_set_text(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD), secrets.link_url, -1);
  }
}

static void on_cancel(GtkWidget *button, gpointer unused) {
  (void)button;
  (void)unused;
  zb_login_cancel();
}

/* --- Remove: both stores ------------------------------------------------------ */

/* Remove clears the keyring item and deletes the file (RoseCat 5648, 5649).
 * Both effects belong to the operation, not the window: the file goes at
 * the click and the keyring clear runs to its end even if the window closes
 * meanwhile (RoseCat 5663); only the report back is the window's. Success
 * needs the file gone and the keyring cleared; a keyring that cannot be
 * reached also counts when the file was the active store (no keyring is why
 * the file store exists). Otherwise "The token could not be removed." */
static void on_cleared(ZbSecretsResult result, gpointer epoch) {
  if (!current(epoch)) {
    return;
  }
  set_busy(0);
  int keyring_done = result == ZB_SECRETS_OK ||
                     (result == ZB_SECRETS_UNAVAILABLE && secrets.removing_store == ZB_SECRET_STORE_FILE);
  if (secrets.removed_file && keyring_done) {
    set_state(STATE_EMPTY, TEXT_EMPTY);
    notify_changed(0);
  } else {
    set_status_text(TEXT_REMOVE_FAILED);
  }
}

static void on_remove(GtkWidget *button, gpointer unused) {
  (void)button;
  (void)unused;
  if (secrets.busy || signing_in()) {
    return;
  }
  wipe_pending();
  secrets_row("remove", "click", NULL);
  secrets.removing_store = zb_secrets_window_store();
  secrets.removed_file = zb_secrets_remove_file(secrets.agent_home) == 0;
  if (secrets.removed_file) {
    secrets.file_choice = 0; /* nothing is left for this session's file choice to select */
  }
  zb_secrets_service_clear_async(on_cleared, begin_operation());
  /* The helper read the token once at its start: it stops now (every session ends,
   * so each Claude CLI exits), and the next Send starts afresh with whatever is then
   * stored (plan S4.2). Like the removal, this is the operation's, not the window's:
   * it happens at the click, even if the window closes before the keyring answers. */
  zb_agent_helper_token_removed();
}

/* --- where things are (e2e rows) --------------------------------------------- */

/* `SECRETS rect <name> <x,y,w,h>` in root coordinates, for each control a
 * test drives with real X input; a hidden control is reported as 0,0,0,0. */
static void report_rect(const char *name, GtkWidget *widget) {
  char rect[64] = "0,0,0,0";
  GdkWindow *gdk = gtk_widget_get_window(secrets.window);
  if (gdk != NULL && gtk_widget_get_mapped(widget)) {
    int ox = 0, oy = 0, x = 0, y = 0;
    gdk_window_get_origin(gdk, &ox, &oy);
    gtk_widget_translate_coordinates(widget, secrets.window, 0, 0, &x, &y);
    GtkAllocation a;
    gtk_widget_get_allocation(widget, &a);
    g_snprintf(rect, sizeof rect, "%d,%d,%d,%d", ox + x, oy + y, a.width, a.height);
  }
  secrets_row("rect", name, rect);
}

/* The drop-down's note: hidden, or one fixed sentence (its `SECRETS text` row). */
static void nav_note(const char *text) {
  if (text == NULL) {
    gtk_widget_hide(secrets.nav_note);
    return;
  }
  gtk_label_set_text(GTK_LABEL(secrets.nav_note), text);
  gtk_widget_show(secrets.nav_note);
  secrets_row("text", text, NULL);
}

/* The drop-down's own selection, read back from the control (RoseCat 7fcfadf). */
static const char *nav_selected(void) {
  int active = gtk_combo_box_get_active(GTK_COMBO_BOX(secrets.nav));
  return active >= 0 && active <= 2 ? nav_values[active] : "yes";
}

/* The drop-down shows the store (a fresh, fail-closed read), as each opening of the window
 * finds it and after a refused write; setting it writes nothing. Its row names the selection
 * read back from the control. */
static void show_navapproval(void) {
  int unreadable = 0;
  int value = zb_agent_navapproval_read(secrets.agent_home != NULL ? secrets.agent_home : "", &unreadable);
  if (value < 0 || value > 2) {
    value = 0;
    unreadable = 1;
  }
  secrets.nav_showing = 1;
  gtk_combo_box_set_active(GTK_COMBO_BOX(secrets.nav), value);
  secrets.nav_showing = 0;
  nav_note(unreadable ? TEXT_NAV_UNREADABLE : NULL);
  secrets_row("navapproval", nav_selected(), unreadable ? "unreadable" : "ok");
}

/* The user chose a value: the control's one write. */
static void on_nav_changed(GtkComboBox *box, gpointer unused) {
  (void)unused;
  int value = gtk_combo_box_get_active(box);
  if (secrets.nav_showing || value < 0 || value > 2) {
    return;
  }
  if (zb_agent_navapproval_write(secrets.agent_home != NULL ? secrets.agent_home : "", value) != 0) {
    /* Refused (plan rev 16.20.58): the drop-down shows the stored value again, and the
     * refusal stays the window's last line. */
    secrets_row("navapproval-refused", nav_values[value], NULL);
    show_navapproval();
    nav_note(TEXT_NAV_REFUSED);
    return;
  }
  nav_note(NULL);
  secrets_row("navapproval", nav_selected(), "ok");
}

static gboolean report_rects(gpointer unused) {
  (void)unused;
  if (secrets.window != NULL && secrets.config.e2e_protocol) {
    report_rect("entry", secrets.entry);
    report_rect("save", secrets.save);
    report_rect("remove", secrets.remove);
    report_rect("file", secrets.file_button);
    report_rect("signin", secrets.signin);
    report_rect("code", secrets.code);
    report_rect("send-code", secrets.send_code);
    report_rect("cancel", secrets.cancel);
    report_rect("copy-link", secrets.copy_link);
    report_rect("navapproval", secrets.nav);
  }
  return G_SOURCE_REMOVE;
}

/* After any layout change, once the new allocation is in place. */
static void on_allocated(GtkWidget *widget, GdkRectangle *allocation, gpointer unused) {
  (void)widget;
  (void)allocation;
  (void)unused;
  g_idle_add(report_rects, NULL);
}

static gboolean on_configure(GtkWidget *widget, GdkEvent *event, gpointer unused) {
  (void)widget;
  (void)event;
  (void)unused;
  g_idle_add(report_rects, NULL);
  return FALSE;
}

/* --- the window ------------------------------------------------------------- */

static void collect_types(GtkWidget *widget, GString *out) {
  if (out->len > 0) {
    g_string_append_c(out, ',');
  }
  g_string_append(out, G_OBJECT_TYPE_NAME(widget));
  if (GTK_IS_CONTAINER(widget)) {
    GList *children = gtk_container_get_children(GTK_CONTAINER(widget));
    for (GList *l = children; l != NULL; l = l->next) {
      collect_types(GTK_WIDGET(l->data), out);
    }
    g_list_free(children);
  }
}

static void on_destroy(GtkWidget *window, gpointer unused) {
  (void)window;
  (void)unused;
  wipe_pending();
  secrets.epoch++;
  secrets.window = NULL;
  secrets.reason = NULL;
  secrets.reason_shown = 0;
  secrets.busy = 0;
  secrets.signin_store = 0;
  zb_login_cancel(); /* closing the window cancels a running sign-in */
  zb_auth_window_close();
}

static void on_file_box_mapped(GtkWidget *widget, gpointer unused) {
  (void)widget;
  (void)unused;
  g_idle_add(report_rects, NULL);
}

static GtkWidget *build(void) {
  GtkWidget *window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(window), TEXT_TITLE);
  gtk_window_set_default_size(GTK_WINDOW(window), 460, -1);
  gtk_window_set_resizable(GTK_WINDOW(window), FALSE);

  GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
  gtk_container_set_border_width(GTK_CONTAINER(box), 16);
  gtk_container_add(GTK_CONTAINER(window), box);

  GtkWidget *label = gtk_label_new(TEXT_PASTE);
  gtk_label_set_xalign(GTK_LABEL(label), 0);
  gtk_box_pack_start(GTK_BOX(box), label, FALSE, FALSE, 0);

  secrets.entry = gtk_entry_new();
  gtk_entry_set_visibility(GTK_ENTRY(secrets.entry), FALSE);
  gtk_entry_set_input_purpose(GTK_ENTRY(secrets.entry), GTK_INPUT_PURPOSE_PASSWORD);
  gtk_entry_set_max_length(GTK_ENTRY(secrets.entry), 4096);
  gtk_entry_set_activates_default(GTK_ENTRY(secrets.entry), TRUE);
  gtk_box_pack_start(GTK_BOX(box), secrets.entry, FALSE, FALSE, 0);

  GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  secrets.save = gtk_button_new_with_label("Save");
  secrets.remove = gtk_button_new_with_label("Remove");
  gtk_box_pack_end(GTK_BOX(buttons), secrets.save, FALSE, FALSE, 0);
  gtk_box_pack_end(GTK_BOX(buttons), secrets.remove, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(box), buttons, FALSE, FALSE, 0);
  gtk_widget_set_can_default(secrets.save, TRUE);

  /* Sign in with Claude.ai: Alt+I is its mnemonic (S6.1's no-rows case uses it). */
  GtkWidget *signin_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  secrets.signin = gtk_button_new_with_mnemonic(TEXT_SIGNIN_BUTTON);
  secrets.cancel = gtk_button_new_with_mnemonic("_Cancel"); /* Alt+C, as Sign in has Alt+I */
  gtk_box_pack_start(GTK_BOX(signin_row), secrets.signin, FALSE, FALSE, 0);
  gtk_box_pack_end(GTK_BOX(signin_row), secrets.cancel, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(box), signin_row, FALSE, FALSE, 0);

  secrets.link_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
  GtkWidget *link_label = gtk_label_new(TEXT_LINK);
  gtk_label_set_xalign(GTK_LABEL(link_label), 0);
  GtkWidget *link_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  secrets.link = gtk_label_new(NULL);
  gtk_label_set_selectable(GTK_LABEL(secrets.link), TRUE);
  gtk_label_set_ellipsize(GTK_LABEL(secrets.link), PANGO_ELLIPSIZE_MIDDLE);
  gtk_label_set_xalign(GTK_LABEL(secrets.link), 0);
  secrets.copy_link = gtk_button_new_with_label(TEXT_COPY_LINK);
  gtk_box_pack_start(GTK_BOX(link_row), secrets.link, TRUE, TRUE, 0);
  gtk_box_pack_end(GTK_BOX(link_row), secrets.copy_link, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(secrets.link_box), link_label, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(secrets.link_box), link_row, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(box), secrets.link_box, FALSE, FALSE, 0);

  secrets.code_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  secrets.code = gtk_entry_new();
  gtk_entry_set_visibility(GTK_ENTRY(secrets.code), FALSE);
  gtk_entry_set_input_purpose(GTK_ENTRY(secrets.code), GTK_INPUT_PURPOSE_PASSWORD);
  gtk_entry_set_max_length(GTK_ENTRY(secrets.code), 1024);
  secrets.send_code = gtk_button_new_with_label("Send code");
  gtk_box_pack_start(GTK_BOX(secrets.code_box), secrets.code, TRUE, TRUE, 0);
  gtk_box_pack_end(GTK_BOX(secrets.code_box), secrets.send_code, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(box), secrets.code_box, FALSE, FALSE, 0);

  secrets.status = gtk_label_new(TEXT_EMPTY);
  gtk_label_set_xalign(GTK_LABEL(secrets.status), 0);
  gtk_label_set_line_wrap(GTK_LABEL(secrets.status), TRUE);
  gtk_box_pack_start(GTK_BOX(box), secrets.status, FALSE, FALSE, 0);

  secrets.reason = gtk_label_new(NULL);
  gtk_label_set_xalign(GTK_LABEL(secrets.reason), 0);
  gtk_label_set_line_wrap(GTK_LABEL(secrets.reason), TRUE);
  gtk_box_pack_start(GTK_BOX(box), secrets.reason, FALSE, FALSE, 0);

  /* Navigation approval (S8 decision 16): Yes, No, Conditional, in that order. */
  GtkWidget *nav_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
  GtkWidget *nav_label = gtk_label_new_with_mnemonic(TEXT_NAV_LABEL);
  secrets.nav = gtk_combo_box_text_new();
  gtk_combo_box_text_append(GTK_COMBO_BOX_TEXT(secrets.nav), "yes", "Yes");
  gtk_combo_box_text_append(GTK_COMBO_BOX_TEXT(secrets.nav), "no", "No");
  gtk_combo_box_text_append(GTK_COMBO_BOX_TEXT(secrets.nav), "conditional", "Conditional");
  gtk_label_set_mnemonic_widget(GTK_LABEL(nav_label), secrets.nav);
  gtk_box_pack_start(GTK_BOX(nav_row), nav_label, FALSE, FALSE, 0);
  gtk_box_pack_end(GTK_BOX(nav_row), secrets.nav, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(box), nav_row, FALSE, FALSE, 0);
  secrets.nav_note = gtk_label_new(NULL);
  gtk_label_set_xalign(GTK_LABEL(secrets.nav_note), 0);
  gtk_label_set_line_wrap(GTK_LABEL(secrets.nav_note), TRUE);
  gtk_box_pack_start(GTK_BOX(box), secrets.nav_note, FALSE, FALSE, 0);

  secrets.file_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
  GtkWidget *warning = gtk_label_new(TEXT_FILE_WARNING);
  gtk_label_set_xalign(GTK_LABEL(warning), 0);
  gtk_label_set_line_wrap(GTK_LABEL(warning), TRUE);
  secrets.file_button = gtk_button_new_with_label(TEXT_FILE_BUTTON);
  gtk_box_pack_start(GTK_BOX(secrets.file_box), warning, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(secrets.file_box), secrets.file_button, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(box), secrets.file_box, FALSE, FALSE, 0);

  g_signal_connect(secrets.save, "clicked", G_CALLBACK(on_save), NULL);
  g_signal_connect(secrets.remove, "clicked", G_CALLBACK(on_remove), NULL);
  g_signal_connect(secrets.file_button, "clicked", G_CALLBACK(on_save_to_file), NULL);
  g_signal_connect(secrets.signin, "clicked", G_CALLBACK(on_signin), NULL);
  g_signal_connect(secrets.send_code, "clicked", G_CALLBACK(on_send_code), NULL);
  g_signal_connect(secrets.code, "activate", G_CALLBACK(on_send_code), NULL);
  g_signal_connect(secrets.cancel, "clicked", G_CALLBACK(on_cancel), NULL);
  g_signal_connect(secrets.copy_link, "clicked", G_CALLBACK(on_copy_link), NULL);
  g_signal_connect(secrets.nav, "changed", G_CALLBACK(on_nav_changed), NULL);
  g_signal_connect(window, "destroy", G_CALLBACK(on_destroy), NULL);
  g_signal_connect_after(box, "size-allocate", G_CALLBACK(on_allocated), NULL);
  g_signal_connect(window, "configure-event", G_CALLBACK(on_configure), NULL);
  g_signal_connect_after(secrets.file_box, "map", G_CALLBACK(on_file_box_mapped), NULL);

  gtk_widget_show_all(box);
  gtk_widget_set_no_show_all(secrets.file_box, TRUE);
  gtk_widget_hide(secrets.file_box);
  gtk_widget_set_no_show_all(secrets.reason, TRUE);
  gtk_widget_hide(secrets.reason);
  gtk_widget_set_no_show_all(secrets.link_box, TRUE);
  gtk_widget_hide(secrets.link_box);
  gtk_widget_set_no_show_all(secrets.nav_note, TRUE);
  gtk_widget_hide(secrets.nav_note);
  gtk_widget_set_no_show_all(secrets.code_box, TRUE);
  gtk_widget_set_no_show_all(secrets.cancel, TRUE);
  gtk_widget_hide(secrets.code_box);
  gtk_widget_hide(secrets.cancel);
  update_sensitivity();
  gtk_widget_set_sensitive(secrets.remove, FALSE);
  gtk_window_set_default(GTK_WINDOW(window), secrets.save);

  GString *types = g_string_new(NULL);
  collect_types(window, types);
  secrets_row("tree", types->str, NULL);
  g_string_free(types, TRUE);
  return window;
}

/* The parent's close button: take this window down before GTK unmaps the parent. */
static gboolean on_parent_delete(GtkWidget *parent, GdkEvent *event, gpointer unused) {
  (void)parent;
  (void)event;
  (void)unused;
  if (secrets.window != NULL) {
    gtk_widget_destroy(secrets.window);
  }
  return FALSE; /* the parent's own close goes on */
}

void zb_secrets_window_present(GtkWindow *transient_for) {
  if (secrets.window == NULL) {
    secrets.window = build();
  }
  if (!secrets.busy) {
    show_current_state();
  }
  show_navapproval();
  if (transient_for != NULL) {
    gtk_window_set_transient_for(GTK_WINDOW(secrets.window), transient_for);
    /* Never outlive the parent. Its close button (delete-event, before GTK unmaps it): this
     * window goes first, so no window manager sees a mapped transient whose parent is
     * already gone. Any other destroy of the parent (the app's quit): right after it, not
     * at process exit. Either way on_destroy cancels a running sign-in. */
    gtk_window_set_destroy_with_parent(GTK_WINDOW(secrets.window), TRUE);
    if (secrets.parent != transient_for) {
      if (secrets.parent != NULL) {
        g_signal_handlers_disconnect_by_func(secrets.parent, G_CALLBACK(on_parent_delete), NULL);
        g_object_remove_weak_pointer(G_OBJECT(secrets.parent), (gpointer *)&secrets.parent);
      }
      secrets.parent = transient_for;
      g_object_add_weak_pointer(G_OBJECT(secrets.parent), (gpointer *)&secrets.parent);
      g_signal_connect(secrets.parent, "delete-event", G_CALLBACK(on_parent_delete), NULL);
    }
  }
  gtk_window_present(GTK_WINDOW(secrets.window));
  gtk_widget_grab_focus(secrets.entry);
}
