/* The Secrets window (chat-drawer plan D11, slice S4; see
 * agent_secrets_window.h). Native GTK only: no WebView, no web content, no
 * JavaScript. Text the user types is read once on Save, the entry is
 * cleared at once, and the token is never put into a label, a row or a log.
 * The status line shows fixed sentences only. */

#include "agent_secrets_window.h"

#include "agent_drawer.h" /* zb_emit_protocol_row */
#include "agent_secrets.h"

#include <string.h>

/* src/agent_secrets.zig (C exports, Linux only). Each takes the token's
 * bytes without a terminator and never keeps them. */
int zb_secrets_valid_token(const char *text, size_t len);
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
  GtkWidget *window;
  GtkWidget *entry;
  GtkWidget *save;
  GtkWidget *remove;
  GtkWidget *status;
  GtkWidget *file_box; /* the warning and "Save to a private file instead" */
  GtkWidget *file_button;
  /* A token the Secret Service did not take, kept only until the user
   * chooses the private file or closes the window (then wiped). */
  char *pending;
  int busy;
  int configured;
  guint generation; /* bumped when the window closes: late callbacks are dropped */
} Secrets;

static Secrets secrets;

void zb_secrets_window_configure(const ZbSecretsConfig *config) {
  secrets.config = *config;
  g_free(secrets.agent_home);
  secrets.agent_home = g_strdup(config->agent_home != NULL ? config->agent_home : "");
  secrets.config.agent_home = secrets.agent_home;
}

void zb_secrets_window_setup(int store, const char *agent_home, int e2e_protocol) {
  ZbSecretsConfig config = {e2e_protocol, store == ZB_SECRET_STORE_FILE ? ZB_SECRET_STORE_FILE : ZB_SECRET_STORE_SERVICE,
                            agent_home, NULL, NULL};
  zb_secrets_window_configure(&config);
  secrets.configured = 1;
}

int zb_secrets_window_configured(void) { return secrets.configured; }

int zb_secrets_window_store(void) { return secrets.config.store; }

const char *zb_secrets_window_home(void) { return secrets.agent_home; }

int zb_secrets_window_open(void) { return secrets.window != NULL; }

/* --- rows and state -------------------------------------------------------- */

static void secrets_row(const char *kind, const char *a, const char *b) {
  const char *fields[] = {kind, a, b};
  zb_emit_protocol_row(secrets.config.e2e_protocol, "SECRETS", fields, b != NULL ? 3 : 2);
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

static void set_state(State state, const char *text) {
  set_status_text(text);
  gtk_widget_set_visible(secrets.file_box, state == STATE_NO_KEYRING && secrets.pending != NULL);
  gtk_widget_set_sensitive(secrets.remove, state == STATE_SERVICE || state == STATE_FILE);
  secrets_row("status", state_rows[state], NULL);
}

static void set_busy(int busy) {
  secrets.busy = busy;
  gtk_widget_set_sensitive(secrets.save, !busy);
  gtk_widget_set_sensitive(secrets.entry, !busy);
  gtk_widget_set_sensitive(secrets.file_button, !busy);
}

static void notify_changed(int has_token) {
  if (secrets.config.changed != NULL) {
    secrets.config.changed(has_token, secrets.config.data);
  }
}

/* A callback from a worker thread for a window that has since closed is
 * dropped: `data` carries the generation it was started in. */
static int current(gpointer data) { return secrets.window != NULL && GPOINTER_TO_UINT(data) == secrets.generation; }

/* --- the current state, when the window opens ------------------------------ */

static void on_lookup(ZbSecretsResult result, char *token, gpointer data) {
  zb_secrets_free(token); /* only whether one exists matters here */
  if (!current(data)) {
    return;
  }
  if (result == ZB_SECRETS_OK) {
    set_state(STATE_SERVICE, TEXT_SERVICE);
  } else if (result == ZB_SECRETS_ABSENT) {
    set_state(STATE_EMPTY, TEXT_EMPTY);
  } else {
    set_state(STATE_NO_KEYRING, TEXT_NO_KEYRING);
  }
}

static void show_current_state(void) {
  if (secrets.config.store == ZB_SECRET_STORE_FILE) {
    int present = zb_secrets_file_present(secrets.agent_home);
    set_state(present ? STATE_FILE : STATE_EMPTY, present ? TEXT_FILE : TEXT_EMPTY);
    return;
  }
  zb_secrets_service_lookup_async(on_lookup, GUINT_TO_POINTER(secrets.generation));
}

/* --- Save ------------------------------------------------------------------- */

static void store_in_file(const char *token) {
  if (zb_secrets_store_file(secrets.agent_home, token, strlen(token)) == 0) {
    set_state(STATE_FILE, TEXT_FILE);
    notify_changed(1);
  } else {
    set_state(STATE_EMPTY, TEXT_FAILED);
  }
}

static void on_service_stored(ZbSecretsResult result, gpointer data) {
  if (!current(data)) {
    wipe_pending();
    return;
  }
  set_busy(0);
  if (result == ZB_SECRETS_OK) {
    wipe_pending();
    set_state(STATE_SERVICE, TEXT_SERVICE);
    notify_changed(1);
  } else {
    /* No silent fallback: keep the token only for the explicit file choice. */
    set_state(STATE_NO_KEYRING, TEXT_NO_KEYRING);
  }
}

static void on_save(GtkWidget *button, gpointer unused) {
  (void)button;
  (void)unused;
  if (secrets.busy) {
    return;
  }
  /* Read once, then clear the entry at once, whatever happens next. */
  char *token = g_strdup(gtk_entry_get_text(GTK_ENTRY(secrets.entry)));
  gtk_entry_set_text(GTK_ENTRY(secrets.entry), "");
  wipe_pending();
  if (!zb_secrets_valid_token(token, strlen(token))) {
    explicit_bzero(token, strlen(token));
    g_free(token);
    set_state(STATE_REJECTED, TEXT_REJECTED);
    return;
  }
  if (secrets.config.store == ZB_SECRET_STORE_FILE) {
    store_in_file(token);
    explicit_bzero(token, strlen(token));
    g_free(token);
    return;
  }
  secrets.pending = token; /* wiped on success, on close, or after the file choice */
  set_busy(1);
  set_status_text(TEXT_WORKING);
  zb_secrets_service_store_async(token, on_service_stored, GUINT_TO_POINTER(secrets.generation));
}

static void on_save_to_file(GtkWidget *button, gpointer unused) {
  (void)button;
  (void)unused;
  if (secrets.busy || secrets.pending == NULL) {
    return;
  }
  store_in_file(secrets.pending);
  wipe_pending();
  gtk_widget_set_visible(secrets.file_box, FALSE);
}

/* --- Remove ----------------------------------------------------------------- */

static void on_service_cleared(ZbSecretsResult result, gpointer data) {
  if (!current(data)) {
    return;
  }
  set_busy(0);
  int file_gone = zb_secrets_remove_file(secrets.agent_home) == 0;
  if (result == ZB_SECRETS_OK && file_gone) {
    set_state(STATE_EMPTY, TEXT_EMPTY);
    notify_changed(0);
  } else {
    set_status_text(TEXT_REMOVE_FAILED);
  }
}

static void on_remove(GtkWidget *button, gpointer unused) {
  (void)button;
  (void)unused;
  if (secrets.busy) {
    return;
  }
  wipe_pending();
  if (secrets.config.store == ZB_SECRET_STORE_FILE) {
    if (zb_secrets_remove_file(secrets.agent_home) == 0) {
      set_state(STATE_EMPTY, TEXT_EMPTY);
      notify_changed(0);
    } else {
      set_status_text(TEXT_REMOVE_FAILED);
    }
    return;
  }
  set_busy(1);
  zb_secrets_service_clear_async(on_service_cleared, GUINT_TO_POINTER(secrets.generation));
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

static gboolean report_rects(gpointer unused) {
  (void)unused;
  if (secrets.window != NULL && secrets.config.e2e_protocol) {
    report_rect("entry", secrets.entry);
    report_rect("save", secrets.save);
    report_rect("remove", secrets.remove);
    report_rect("file", secrets.file_button);
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
  secrets.generation++;
  secrets.window = NULL;
  secrets.busy = 0;
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

  secrets.status = gtk_label_new(TEXT_EMPTY);
  gtk_label_set_xalign(GTK_LABEL(secrets.status), 0);
  gtk_label_set_line_wrap(GTK_LABEL(secrets.status), TRUE);
  gtk_box_pack_start(GTK_BOX(box), secrets.status, FALSE, FALSE, 0);

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
  g_signal_connect(window, "destroy", G_CALLBACK(on_destroy), NULL);
  g_signal_connect_after(box, "size-allocate", G_CALLBACK(on_allocated), NULL);
  g_signal_connect(window, "configure-event", G_CALLBACK(on_configure), NULL);
  g_signal_connect_after(secrets.file_box, "map", G_CALLBACK(on_file_box_mapped), NULL);

  gtk_widget_show_all(box);
  gtk_widget_set_no_show_all(secrets.file_box, TRUE);
  gtk_widget_hide(secrets.file_box);
  gtk_widget_set_sensitive(secrets.remove, FALSE);
  gtk_window_set_default(GTK_WINDOW(window), secrets.save);

  GString *types = g_string_new(NULL);
  collect_types(window, types);
  secrets_row("tree", types->str, NULL);
  g_string_free(types, TRUE);
  return window;
}

void zb_secrets_window_present(GtkWindow *transient_for) {
  if (secrets.window == NULL) {
    secrets.window = build();
  }
  if (!secrets.busy) {
    show_current_state();
  }
  if (transient_for != NULL) {
    gtk_window_set_transient_for(GTK_WINDOW(secrets.window), transient_for);
  }
  gtk_window_present(GTK_WINDOW(secrets.window));
  gtk_widget_grab_focus(secrets.entry);
}
