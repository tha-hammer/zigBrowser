#include "webkit_shim.h"

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <glib-unix.h>
#include <glib/gstdio.h>
#include <unistd.h>

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ZB_SIGINT_DEADLINE_S 3

enum {
  ZB_DECISION_USE = 0,
  ZB_DECISION_IGNORE = 1,
  ZB_DECISION_OPEN_SUBWINDOW = 2,

  ZB_DTYPE_NAVIGATION = 0,
  ZB_DTYPE_NEW_WINDOW = 1,
  ZB_DTYPE_RESPONSE = 2,
};

typedef struct {
  GtkWidget *window;
  WebKitWebView *view;
  WebKitWebContext *context;

  char *uri;
  char *out_path;
  int print_title;

  int finished;
  int failed;
  int cancelled;
  int timed_out;

  int load_error_domain;
  int load_error_code;
  char *load_error_message;

  GCancellable *cancellable;
  guint timeout_source_id;

  gulong sig_load_changed;
  gulong sig_load_failed;
  gulong sig_destroy;

  guint sigint_source_id;
  guint sigterm_source_id;
  int title_eval_inflight;
  int snapshot_after_title;

  int title_printed;
  int exit_code;
} ZbShot;

struct ZbWindow {
  GtkWidget *gtk_window;
  WebKitWebView *view;
  WebKitUserContentManager *ucm;
  WebKitWebContext *context;
  char *current_uri;
  char *seed_uri;
  int load_superseded;
  int seed_pending;

  int finished;
  int failed;
  int cancelled;
  int timed_out;
  int load_error_domain;
  int load_error_code;
  char *load_error_message;
  int suppress_success_emit;
  int pending_nav_emit;
  char *pending_nav_uri;

  GCancellable *cancellable;
  guint timeout_source_id;
  guint pending_nav_fallback_source_id;

  gulong sig_load_changed;
  gulong sig_load_failed;
  gulong sig_title_notify;
  gulong sig_decide_policy;
  gulong sig_create;
  gulong sig_destroy;

  int is_child;
  struct ZbApp *app;

  /* Automation bridge (GTK thread only). */
  unsigned int auto_load_gen;  /* bumped per automation navigate/reload */
  int auto_first_load_done;    /* first load reached FINISHED or failed */
  gulong sig_uri_notify;
};

struct ZbApp {
  ZbWindow *windows[ZB_MAX_WINDOWS];
  int n_windows;
  char *app_base;
  int e2e_protocol;
  int print_title;
  int exit_code;
  char *pending_subwindow_seed_uri;

  guint sigint_source_id;
  guint sigterm_source_id;
  guint sighup_source_id;
  guint sigint_deadline_source_id;
};

static gboolean on_window_timeout(gpointer user_data);
static gboolean on_ipc_message_received(WebKitUserContentManager *ucm,
                                        JSCValue *value,
                                        WebKitScriptMessageReply *reply,
                                        gpointer user_data);
static void on_window_title_notify(WebKitWebView *view, GParamSpec *pspec,
                                   gpointer user_data);
static gboolean on_window_nav_fallback(gpointer user_data);
static GtkWidget *on_window_create(WebKitWebView *parent_view,
                                   WebKitNavigationAction *navigation,
                                   gpointer user_data);
static gboolean on_signal_force_quit(gpointer user_data);
static void request_app_shutdown(ZbApp *app, int with_deadline);
static void terminate_window_web_process(ZbWindow *win);

/* Automation bridge hooks (defined with the bridge, called on the GTK thread). */
static void auto_install_script(ZbWindow *win);
static void auto_publish_primary(ZbApp *app);
static void auto_window_destroyed(ZbWindow *win);
static void auto_load_event(ZbWindow *win, WebKitLoadEvent event, const char *uri);
static int auto_load_failed(ZbWindow *win, const char *uri, const GError *error);
static void auto_nav_blocked(ZbWindow *win, const char *candidate);
static int auto_window_owns_load_deadline(ZbWindow *win);
static void auto_uri_changed(ZbWindow *win, const char *uri);
static void auto_first_load_done(ZbWindow *win);
static void on_window_uri_notify(WebKitWebView *view, GParamSpec *pspec,
                                 gpointer user_data);

static void emit_safe_field(const char *text) {
  const char *p = text != NULL ? text : "";
  for (; *p != '\0'; ++p) {
    if (*p == '\t' || *p == '\n' || *p == '\r') {
      fputc(' ', stdout);
    } else {
      fputc(*p, stdout);
    }
  }
}

static void emit_protocol1(const ZbApp *app, const char *tag, const char *a) {
  if (app == NULL || !app->e2e_protocol) {
    return;
  }

  fputs(tag, stdout);
  fputc('\t', stdout);
  emit_safe_field(a);
  fputc('\n', stdout);
  fflush(stdout);
}

static void emit_protocol2(const ZbApp *app, const char *tag, const char *a,
                           const char *b) {
  if (app == NULL || !app->e2e_protocol) {
    return;
  }

  fputs(tag, stdout);
  fputc('\t', stdout);
  emit_safe_field(a);
  fputc('\t', stdout);
  emit_safe_field(b);
  fputc('\n', stdout);
  fflush(stdout);
}

static void emit_protocol3(const ZbApp *app, const char *tag, const char *a,
                           const char *b, const char *c) {
  if (app == NULL || !app->e2e_protocol) {
    return;
  }

  fputs(tag, stdout);
  fputc('\t', stdout);
  emit_safe_field(a);
  fputc('\t', stdout);
  emit_safe_field(b);
  fputc('\t', stdout);
  emit_safe_field(c);
  fputc('\n', stdout);
  fflush(stdout);
}

static void emit_load_fail(const ZbWindow *win, const char *uri, int domain,
                           int code) {
  if (win == NULL) {
    return;
  }

  char domain_buf[32];
  char code_buf[32];
  g_snprintf(domain_buf, sizeof(domain_buf), "%d", domain);
  g_snprintf(code_buf, sizeof(code_buf), "%d", code);
  emit_protocol3(win->app, "LOAD_FAIL", uri != NULL ? uri : "", domain_buf,
                 code_buf);
}

static void terminate_window_web_process(ZbWindow *win) {
  if (win == NULL || win->view == NULL) {
    return;
  }
  webkit_web_view_terminate_web_process(win->view);
}

static int is_cancelled_network_error(const GError *error) {
  return error != NULL && error->domain == WEBKIT_NETWORK_ERROR &&
         error->code == WEBKIT_NETWORK_ERROR_CANCELLED;
}

static void remove_source(guint *source_id) {
  if (source_id != NULL && *source_id != 0) {
    if (g_main_context_find_source_by_id(NULL, *source_id) != NULL) {
      g_source_remove(*source_id);
    }
    *source_id = 0;
  }
}

static ZbWindow *app_find_window_by_view(ZbApp *app, WebKitWebView *view) {
  if (app == NULL || view == NULL) {
    return NULL;
  }

  for (int i = 0; i < app->n_windows; i++) {
    if (app->windows[i] != NULL && app->windows[i]->view == view) {
      return app->windows[i];
    }
  }
  return NULL;
}

static void window_clear_pending_nav(ZbWindow *win) {
  if (win == NULL) {
    return;
  }

  win->pending_nav_emit = 0;
  remove_source(&win->pending_nav_fallback_source_id);
  g_free(win->pending_nav_uri);
  win->pending_nav_uri = NULL;
}

static void window_emit_main_success(ZbWindow *win, const char *uri,
                                     const char *title) {
  if (win == NULL || win->app == NULL) {
    return;
  }

  const char *safe_uri = uri != NULL ? uri : "";
  const char *safe_title = title != NULL ? title : "";
  if (win->app->print_title) {
    printf("TITLE\t%s\n", safe_title);
    fflush(stdout);
  }
  emit_protocol2(win->app, "NAV", safe_uri, safe_title);
  window_clear_pending_nav(win);
}

static void window_set_load_error(ZbWindow *win, GError *error) {
  if (win == NULL) {
    return;
  }

  g_free(win->load_error_message);
  win->load_error_message = NULL;
  win->load_error_domain = 0;
  win->load_error_code = 0;

  if (error == NULL) {
    return;
  }

  win->load_error_domain = error->domain;
  win->load_error_code = error->code;
  win->load_error_message = g_strdup(error->message != NULL ? error->message : "");
}

static void window_reset_load_state(ZbWindow *win) {
  if (win == NULL) {
    return;
  }

  win->finished = 0;
  win->failed = 0;
  win->timed_out = 0;
  win->cancelled = 0;
  window_set_load_error(win, NULL);
  window_clear_pending_nav(win);
  remove_source(&win->timeout_source_id);

  if (win->cancellable != NULL) {
    g_object_unref(win->cancellable);
    win->cancellable = NULL;
  }
  win->cancellable = g_cancellable_new();

  win->timeout_source_id = g_timeout_add(15000, on_window_timeout, win);
}

static void app_emit_wincount(const ZbApp *app) {
  if (app == NULL) {
    return;
  }

  char count_buf[32];
  g_snprintf(count_buf, sizeof(count_buf), "%d", app->n_windows);
  emit_protocol1(app, "WINCOUNT", count_buf);
}

static void app_remove_window(ZbApp *app, ZbWindow *win) {
  if (app == NULL || win == NULL) {
    return;
  }

  int idx = -1;
  for (int i = 0; i < app->n_windows; i++) {
    if (app->windows[i] == win) {
      idx = i;
      break;
    }
  }

  if (idx >= 0) {
    for (int i = idx; i < app->n_windows - 1; i++) {
      app->windows[i] = app->windows[i + 1];
    }
    app->windows[app->n_windows - 1] = NULL;
    app->n_windows--;
    app_emit_wincount(app);
    auto_publish_primary(app);
  }

  if (app->n_windows == 0 && gtk_main_level() > 0) {
    gtk_main_quit();
  }
}

static void window_free(ZbWindow *win) {
  if (win == NULL) {
    return;
  }

  remove_source(&win->timeout_source_id);
  remove_source(&win->pending_nav_fallback_source_id);

  if (win->cancellable != NULL) {
    g_object_unref(win->cancellable);
    win->cancellable = NULL;
  }

  if (win->context != NULL) {
    g_object_unref(win->context);
    win->context = NULL;
  }

  if (win->ucm != NULL) {
    g_object_unref(win->ucm);
    win->ucm = NULL;
  }

  g_free(win->current_uri);
  g_free(win->seed_uri);
  g_free(win->pending_nav_uri);
  g_free(win->load_error_message);
  g_free(win);
}

static gboolean parse_json_string_field(const char *json, const char *field,
                                        char **out_value) {
  char key[64];
  g_snprintf(key, sizeof(key), "\"%s\"", field);

  const char *p = strstr(json, key);
  if (p == NULL) {
    return FALSE;
  }
  p += strlen(key);

  while (*p != '\0' && g_ascii_isspace(*p)) {
    p++;
  }
  if (*p != ':') {
    return FALSE;
  }
  p++;

  while (*p != '\0' && g_ascii_isspace(*p)) {
    p++;
  }
  if (*p != '"') {
    return FALSE;
  }
  p++;

  GString *acc = g_string_new("");
  while (*p != '\0') {
    if (*p == '\\' && *(p + 1) != '\0') {
      p++;
      g_string_append_c(acc, *p);
      p++;
      continue;
    }
    if (*p == '"') {
      *out_value = g_string_free(acc, FALSE);
      return TRUE;
    }
    g_string_append_c(acc, *p);
    p++;
  }

  g_string_free(acc, TRUE);
  return FALSE;
}

static gboolean parse_json_value_field(const char *json, const char *field,
                                       char **out_value) {
  char key[64];
  g_snprintf(key, sizeof(key), "\"%s\"", field);

  const char *p = strstr(json, key);
  if (p == NULL) {
    return FALSE;
  }
  p += strlen(key);

  while (*p != '\0' && g_ascii_isspace(*p)) {
    p++;
  }
  if (*p != ':') {
    return FALSE;
  }
  p++;

  while (*p != '\0' && g_ascii_isspace(*p)) {
    p++;
  }
  if (*p == '\0') {
    return FALSE;
  }

  const char *start = p;
  if (*p == '{' || *p == '[') {
    char open = *p;
    char close = open == '{' ? '}' : ']';
    int depth = 0;
    int in_string = 0;

    while (*p != '\0') {
      char ch = *p;
      if (ch == '"' && (p == start || *(p - 1) != '\\')) {
        in_string = !in_string;
      } else if (!in_string) {
        if (ch == open) {
          depth++;
        } else if (ch == close) {
          depth--;
          if (depth == 0) {
            p++;
            break;
          }
        }
      }
      p++;
    }
  } else if (*p == '"') {
    p++;
    while (*p != '\0') {
      if (*p == '"' && *(p - 1) != '\\') {
        p++;
        break;
      }
      p++;
    }
  } else {
    while (*p != '\0' && *p != ',' && *p != '}') {
      p++;
    }
  }

  if (p <= start) {
    return FALSE;
  }

  const char *end = p;
  while (end > start && g_ascii_isspace(*(end - 1))) {
    end--;
  }

  *out_value = g_strndup(start, (gsize)(end - start));
  return TRUE;
}

static const char *policy_uri_from_decision(WebKitPolicyDecision *decision,
                                            WebKitPolicyDecisionType type) {
  if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION ||
      type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
    WebKitNavigationPolicyDecision *nav_decision =
        WEBKIT_NAVIGATION_POLICY_DECISION(decision);
    WebKitNavigationAction *action =
        webkit_navigation_policy_decision_get_navigation_action(nav_decision);
    if (action == NULL) {
      return NULL;
    }

    WebKitURIRequest *request = webkit_navigation_action_get_request(action);
    return request != NULL ? webkit_uri_request_get_uri(request) : NULL;
  }

  if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
    WebKitResponsePolicyDecision *resp_decision =
        WEBKIT_RESPONSE_POLICY_DECISION(decision);
    WebKitURIRequest *request =
        webkit_response_policy_decision_get_request(resp_decision);
    return request != NULL ? webkit_uri_request_get_uri(request) : NULL;
  }

  return NULL;
}

static int map_decision_type(WebKitPolicyDecisionType type) {
  switch (type) {
    case WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION:
      return ZB_DTYPE_NAVIGATION;
    case WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION:
      return ZB_DTYPE_NEW_WINDOW;
    case WEBKIT_POLICY_DECISION_TYPE_RESPONSE:
      return ZB_DTYPE_RESPONSE;
    default:
      return -1;
  }
}

static void install_ipc_handler(ZbWindow *win) {
  if (win == NULL || win->ucm == NULL) {
    return;
  }

  webkit_user_content_manager_unregister_script_message_handler(win->ucm,
                                                                "zbHost");
  gboolean ok =
      webkit_user_content_manager_register_script_message_handler_with_reply(
          win->ucm, "zbHost", NULL);
  if (!ok) {
    fprintf(stderr, "failed registering zbHost handler\n");
    return;
  }

  g_signal_connect_data(win->ucm,
                        "script-message-with-reply-received::zbHost",
                        G_CALLBACK(on_ipc_message_received), win, NULL, 0);
}

static gboolean on_ipc_message_received(WebKitUserContentManager *ucm,
                                        JSCValue *value,
                                        WebKitScriptMessageReply *reply,
                                        gpointer user_data) {
  (void)ucm;
  ZbWindow *win = (ZbWindow *)user_data;
  if (win == NULL || reply == NULL) {
    return FALSE;
  }

  if (value == NULL || !jsc_value_is_string(value)) {
    webkit_script_message_reply_return_error_message(
        reply, "zbHost: message must be a JSON string");
    emit_protocol2(win->app, "IPCERR", "invalid",
                   "zbHost: message must be a JSON string");
    return TRUE;
  }

  char *message = jsc_value_to_string(value);
  if (message == NULL) {
    webkit_script_message_reply_return_error_message(
        reply, "zbHost: message must be a JSON string");
    emit_protocol2(win->app, "IPCERR", "invalid",
                   "zbHost: message must be a JSON string");
    return TRUE;
  }

  char *cmd = NULL;
  char *args_json = NULL;
  if (!parse_json_string_field(message, "cmd", &cmd)) {
    webkit_script_message_reply_return_error_message(reply, "BadArgs");
    emit_protocol2(win->app, "IPCERR", "invalid", "BadArgs");
    g_free(message);
    return TRUE;
  }
  if (!parse_json_value_field(message, "args", &args_json)) {
    args_json = g_strdup("{}");
  }

  const char *result_json = NULL;
  const char *err_text = NULL;
  int rc = zb_ipc_dispatch(cmd, args_json, &result_json, &err_text);
  if (rc == 0 && result_json != NULL) {
    JSCContext *ctx = jsc_value_get_context(value);
    JSCValue *reply_value = jsc_value_new_from_json(ctx, result_json);
    webkit_script_message_reply_return_value(reply, reply_value);
    g_object_unref(reply_value);
    emit_protocol2(win->app, "IPC", cmd, result_json);
  } else {
    const char *msg = err_text != NULL ? err_text : "UnknownCommand";
    webkit_script_message_reply_return_error_message(reply, msg);
    emit_protocol2(win->app, "IPCERR", cmd, msg);
  }

  g_free(args_json);
  g_free(cmd);
  g_free(message);
  return TRUE;
}

static GtkWidget *on_window_create(WebKitWebView *parent_view,
                                   WebKitNavigationAction *navigation,
                                   gpointer user_data) {
  (void)navigation;
  ZbApp *app = (ZbApp *)user_data;
  if (app == NULL || app->n_windows >= ZB_MAX_WINDOWS) {
    g_warning("create denied: window cap reached");
    return NULL;
  }

  WebKitWebView *child =
      WEBKIT_WEB_VIEW(webkit_web_view_new_with_related_view(parent_view));
  if (child == NULL) {
    return NULL;
  }

  ZbWindow *child_win = zb_window_new(app, child);
  if (child_win == NULL) {
    return NULL;
  }

  if (app->pending_subwindow_seed_uri != NULL) {
    g_free(child_win->seed_uri);
    child_win->seed_uri = g_strdup(app->pending_subwindow_seed_uri);
    child_win->seed_pending = 1;
    g_free(app->pending_subwindow_seed_uri);
    app->pending_subwindow_seed_uri = NULL;
  }

  return GTK_WIDGET(child_win->view);
}

static gboolean on_window_timeout(gpointer user_data) {
  ZbWindow *win = (ZbWindow *)user_data;
  if (win == NULL) {
    return G_SOURCE_REMOVE;
  }
  if (win->finished || win->failed || win->cancelled || win->timed_out) {
    return G_SOURCE_REMOVE;
  }

  win->timed_out = 1;
  win->failed = 1;
  win->cancelled = 1;
  win->load_superseded = 1;
  win->suppress_success_emit = 1;
  win->load_error_domain = G_IO_ERROR;
  win->load_error_code = G_IO_ERROR_TIMED_OUT;
  g_free(win->load_error_message);
  win->load_error_message = g_strdup("Timed out");
  char *timed_out_uri = g_strdup(webkit_web_view_get_uri(win->view));

  if (win->cancellable != NULL) {
    g_cancellable_cancel(win->cancellable);
  }
  terminate_window_web_process(win);
  webkit_web_view_stop_loading(win->view);

  emit_load_fail(win, timed_out_uri, win->load_error_domain,
                 win->load_error_code);
  GError timeout_error = {G_IO_ERROR, G_IO_ERROR_TIMED_OUT, (char *)"load timed out"};
  auto_load_failed(win, timed_out_uri, &timeout_error);
  auto_first_load_done(win);
  g_free(timed_out_uri);
  return G_SOURCE_REMOVE;
}

static gboolean on_window_nav_fallback(gpointer user_data) {
  ZbWindow *win = (ZbWindow *)user_data;
  if (win == NULL) {
    return G_SOURCE_REMOVE;
  }
  if (!win->pending_nav_emit) {
    return G_SOURCE_REMOVE;
  }

  const char *title = webkit_web_view_get_title(win->view);
  window_emit_main_success(win, win->pending_nav_uri,
                           title != NULL ? title : "");
  return G_SOURCE_REMOVE;
}

static void on_window_title_notify(WebKitWebView *view, GParamSpec *pspec,
                                   gpointer user_data) {
  (void)pspec;
  ZbWindow *win = (ZbWindow *)user_data;
  if (win == NULL || !win->pending_nav_emit) {
    return;
  }

  const char *title = webkit_web_view_get_title(view);
  if (title == NULL || title[0] == '\0') {
    return;
  }
  window_emit_main_success(win, win->pending_nav_uri, title);
}

static void on_window_destroy(GtkWidget *widget, gpointer user_data) {
  (void)widget;
  ZbWindow *win = (ZbWindow *)user_data;
  if (win == NULL) {
    return;
  }

  if (win->view != NULL) {
    if (!win->finished && !win->failed && !win->timed_out && win->app != NULL) {
      win->cancelled = 1;
      win->app->exit_code = ZB_EXIT_CANCELLED;
    }
    if (win->cancellable != NULL) {
      g_cancellable_cancel(win->cancellable);
    }
    terminate_window_web_process(win);
    webkit_web_view_stop_loading(win->view);

    if (win->sig_load_changed != 0) {
      g_signal_handler_disconnect(win->view, win->sig_load_changed);
      win->sig_load_changed = 0;
    }
    if (win->sig_load_failed != 0) {
      g_signal_handler_disconnect(win->view, win->sig_load_failed);
      win->sig_load_failed = 0;
    }
    if (win->sig_title_notify != 0) {
      g_signal_handler_disconnect(win->view, win->sig_title_notify);
      win->sig_title_notify = 0;
    }
    if (win->sig_decide_policy != 0) {
      g_signal_handler_disconnect(win->view, win->sig_decide_policy);
      win->sig_decide_policy = 0;
    }
    if (win->sig_create != 0) {
      g_signal_handler_disconnect(win->view, win->sig_create);
      win->sig_create = 0;
    }
    if (win->sig_uri_notify != 0) {
      g_signal_handler_disconnect(win->view, win->sig_uri_notify);
      win->sig_uri_notify = 0;
    }
  }

  if (win->ucm != NULL) {
    g_signal_handlers_disconnect_by_data(win->ucm, win);
  }

  win->gtk_window = NULL;
  auto_window_destroyed(win);
  app_remove_window(win->app, win);
  window_free(win);
}

static gboolean on_window_load_failed(WebKitWebView *view,
                                      WebKitLoadEvent load_event,
                                      const char *uri,
                                      GError *error,
                                      gpointer user_data) {
  (void)view;
  (void)load_event;

  ZbWindow *win = (ZbWindow *)user_data;
  if (win == NULL) {
    return FALSE;
  }

  remove_source(&win->timeout_source_id);

  /* An automation-driven load that fails gets no WebKit error page: that
   * page loads asynchronously and would displace the client's next command. */
  int automation_load = auto_load_failed(win, uri, error);
  if (!is_cancelled_network_error(error)) {
    auto_first_load_done(win);
  }

  if (win->load_superseded && is_cancelled_network_error(error)) {
    return TRUE;
  }

  win->failed = 1;
  win->suppress_success_emit = 1;
  window_set_load_error(win, error);

  emit_load_fail(win, uri, win->load_error_domain, win->load_error_code);
  return automation_load ? TRUE : FALSE;
}

static void on_window_load_changed(WebKitWebView *view,
                                   WebKitLoadEvent load_event,
                                   gpointer user_data) {
  ZbWindow *win = (ZbWindow *)user_data;
  if (win == NULL) {
    return;
  }

  auto_load_event(win, load_event, webkit_web_view_get_uri(view));
  if (load_event == WEBKIT_LOAD_FINISHED) {
    auto_first_load_done(win);
  }

  switch (load_event) {
    case WEBKIT_LOAD_STARTED:
      window_reset_load_state(win);
      if (auto_window_owns_load_deadline(win)) {
        remove_source(&win->timeout_source_id);
      }
      break;
    case WEBKIT_LOAD_COMMITTED:
      win->load_superseded = 0;
      break;
    case WEBKIT_LOAD_FINISHED: {
      if (win->load_superseded) {
        return;
      }

      win->finished = 1;
      remove_source(&win->timeout_source_id);

      if (win->failed || win->cancelled || win->timed_out ||
          win->suppress_success_emit) {
        return;
      }

      const char *uri = webkit_web_view_get_uri(view);
      const char *title = webkit_web_view_get_title(view);

      g_free(win->current_uri);
      win->current_uri = g_strdup(uri != NULL ? uri : "");

      if (win->is_child) {
        emit_protocol1(win->app, "SUBWIN", uri);
      } else {
        if (title != NULL && title[0] != '\0') {
          window_emit_main_success(win, uri, title);
        } else {
          win->pending_nav_emit = 1;
          g_free(win->pending_nav_uri);
          win->pending_nav_uri = g_strdup(uri != NULL ? uri : "");
          remove_source(&win->pending_nav_fallback_source_id);
          win->pending_nav_fallback_source_id =
              g_timeout_add(75, on_window_nav_fallback, win);
        }
      }
      break;
    }
    default:
      break;
  }
}

static gboolean on_window_decide_policy(WebKitWebView *view,
                                        WebKitPolicyDecision *decision,
                                        WebKitPolicyDecisionType type,
                                        gpointer user_data) {
  ZbApp *app = (ZbApp *)user_data;
  if (app == NULL) {
    return FALSE;
  }
  ZbWindow *win = app_find_window_by_view(app, view);

  int dtype = map_decision_type(type);
  if (dtype < 0) {
    return FALSE;
  }

  const char *candidate = policy_uri_from_decision(decision, type);
  if (candidate == NULL) {
    webkit_policy_decision_ignore(decision);
    emit_protocol1(app, "BLOCKED", "(null)");
    return TRUE;
  }

  if (win != NULL && win->seed_pending && win->is_child &&
      dtype == ZB_DTYPE_NAVIGATION) {
    win->seed_pending = 0;
    webkit_policy_decision_use(decision);
    return TRUE;
  }

  int action = zb_policy_decide(app->app_base, candidate, dtype);
  if (action == ZB_DECISION_USE) {
    if (win != NULL &&
        (dtype == ZB_DTYPE_NAVIGATION || dtype == ZB_DTYPE_NEW_WINDOW)) {
      win->suppress_success_emit = 0;
    }
    webkit_policy_decision_use(decision);
    return TRUE;
  }

  if (action == ZB_DECISION_OPEN_SUBWINDOW) {
    if (dtype == ZB_DTYPE_NEW_WINDOW) {
      g_free(app->pending_subwindow_seed_uri);
      app->pending_subwindow_seed_uri = g_strdup(candidate);
      webkit_policy_decision_use(decision);
      return TRUE;
    }

    g_warning("open_in_subwindow returned for non-new-window decision; blocking");
    webkit_policy_decision_ignore(decision);
    emit_protocol1(app, "BLOCKED", candidate);
    return TRUE;
  }

  webkit_policy_decision_ignore(decision);
  emit_protocol1(app, "BLOCKED", candidate);
  if (win != NULL && dtype == ZB_DTYPE_NAVIGATION) {
    auto_nav_blocked(win, candidate);
  }
  return TRUE;
}

ZbWindow *zb_window_new(ZbApp *app, void *native_view) {
  /* Seam passes a type-erased native view pointer; GTK backend casts locally. */
  WebKitWebView *view = (WebKitWebView *)native_view;
  if (app == NULL || view == NULL) {
    return NULL;
  }

  if (app->n_windows >= ZB_MAX_WINDOWS) {
    g_warning("window cap reached (%d); refusing new sub-window", ZB_MAX_WINDOWS);
    return NULL;
  }

  ZbWindow *win = g_new0(ZbWindow, 1);
  win->app = app;
  win->view = view;
  win->is_child = app->n_windows > 0;

  win->context = webkit_web_view_get_context(view);
  if (win->context != NULL) {
    g_object_ref(win->context);
  }

  win->ucm = webkit_web_view_get_user_content_manager(view);
  if (win->ucm != NULL) {
    g_object_ref(win->ucm);
  }

  win->gtk_window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(win->gtk_window), 1024, 768);
  gtk_window_set_title(GTK_WINDOW(win->gtk_window), "zigBrowser");
  gtk_container_add(GTK_CONTAINER(win->gtk_window), GTK_WIDGET(view));

  WebKitSettings *settings = webkit_web_view_get_settings(view);
  if (settings != NULL) {
    webkit_settings_set_javascript_can_open_windows_automatically(settings, TRUE);
    webkit_settings_set_hardware_acceleration_policy(
        settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);
  }

  win->sig_load_changed =
      g_signal_connect_data(view, "load-changed", G_CALLBACK(on_window_load_changed),
                            win, NULL, 0);
  win->sig_load_failed =
      g_signal_connect_data(view, "load-failed", G_CALLBACK(on_window_load_failed),
                            win, NULL, 0);
  win->sig_title_notify =
      g_signal_connect_data(view, "notify::title",
                            G_CALLBACK(on_window_title_notify), win, NULL, 0);
  win->sig_decide_policy = g_signal_connect_data(
      view, "decide-policy", G_CALLBACK(on_window_decide_policy), app, NULL, 0);
  win->sig_create =
      g_signal_connect_data(view, "create", G_CALLBACK(on_window_create), app,
                            NULL, 0);
  win->sig_uri_notify =
      g_signal_connect_data(view, "notify::uri",
                            G_CALLBACK(on_window_uri_notify), win, NULL, 0);
  win->sig_destroy = g_signal_connect_data(win->gtk_window, "destroy",
                                           G_CALLBACK(on_window_destroy), win,
                                           NULL, 0);

  install_ipc_handler(win);
  auto_install_script(win);

  app->windows[app->n_windows++] = win;
  app_emit_wincount(app);
  auto_publish_primary(app);
  gtk_widget_show_all(win->gtk_window);
  return win;
}

void zb_reload(ZbWindow *win, int bypass_cache) {
  if (win == NULL || win->view == NULL) {
    return;
  }

  win->load_superseded = 1;
  win->suppress_success_emit = 0;
  window_clear_pending_nav(win);

  if (win->cancellable != NULL) {
    g_cancellable_cancel(win->cancellable);
  }

  webkit_web_view_stop_loading(win->view);

  if (bypass_cache) {
    webkit_web_view_reload_bypass_cache(win->view);
  } else {
    webkit_web_view_reload(win->view);
  }
}

static char *derive_app_base(const char *uri) {
  if (uri == NULL) {
    return g_strdup("");
  }

  if (g_str_has_prefix(uri, "file://")) {
    GError *error = NULL;
    char *filename = g_filename_from_uri(uri, NULL, &error);
    if (filename == NULL) {
      if (error != NULL) {
        g_error_free(error);
      }
      return g_strdup(uri);
    }

    char *canon = g_canonicalize_filename(filename, NULL);
    char *dir = g_path_get_dirname(canon);
    char *dir_uri = g_filename_to_uri(dir, NULL, &error);

    g_free(filename);
    g_free(canon);
    g_free(dir);

    if (dir_uri == NULL) {
      if (error != NULL) {
        g_error_free(error);
      }
      return g_strdup(uri);
    }

    if (g_str_has_suffix(dir_uri, "/")) {
      return dir_uri;
    }

    char *with_slash = g_strdup_printf("%s/", dir_uri);
    g_free(dir_uri);
    return with_slash;
  }

  const char *last_slash = strrchr(uri, '/');
  if (last_slash == NULL) {
    return g_strdup(uri);
  }

  return g_strndup(uri, (gsize)(last_slash - uri + 1));
}

static gboolean on_signal_int(gpointer user_data) {
  ZbApp *app = (ZbApp *)user_data;
  if (app == NULL) {
    return G_SOURCE_REMOVE;
  }

  app->exit_code = ZB_EXIT_CANCELLED;
  request_app_shutdown(app, 1);
  return G_SOURCE_REMOVE;
}

static gboolean on_signal_term(gpointer user_data) {
  ZbApp *app = (ZbApp *)user_data;
  if (app == NULL) {
    return G_SOURCE_REMOVE;
  }

  app->exit_code = ZB_EXIT_CANCELLED;
  request_app_shutdown(app, 0);
  return G_SOURCE_REMOVE;
}

static void request_app_shutdown(ZbApp *app, int with_deadline) {
  if (app == NULL) {
    return;
  }

  if (with_deadline && app->sigint_deadline_source_id == 0) {
    app->sigint_deadline_source_id =
        g_timeout_add_seconds(ZB_SIGINT_DEADLINE_S, on_signal_force_quit, app);
  }

  ZbWindow *copy[ZB_MAX_WINDOWS];
  int n = app->n_windows;
  for (int i = 0; i < n; i++) {
    copy[i] = app->windows[i];
  }

  for (int i = 0; i < n; i++) {
    if (copy[i] != NULL && copy[i]->gtk_window != NULL) {
      if (copy[i]->cancellable != NULL) {
        g_cancellable_cancel(copy[i]->cancellable);
      }
      if (copy[i]->view != NULL) {
        terminate_window_web_process(copy[i]);
        webkit_web_view_stop_loading(copy[i]->view);
      }
      GtkWidget *w = copy[i]->gtk_window;
      copy[i]->gtk_window = NULL;
      gtk_widget_destroy(w);
    }
  }

  if (gtk_main_level() > 0) {
    gtk_main_quit();
  }
}

static gboolean on_signal_force_quit(gpointer user_data) {
  ZbApp *app = (ZbApp *)user_data;
  if (app != NULL) {
    app->sigint_deadline_source_id = 0;
  }
  _exit(ZB_EXIT_CANCELLED);
}

static gboolean on_signal_hup(gpointer user_data) {
  ZbApp *app = (ZbApp *)user_data;
  if (app == NULL || app->n_windows <= 0 || app->windows[0] == NULL) {
    return G_SOURCE_CONTINUE;
  }

  zb_reload(app->windows[0], 0);
  return G_SOURCE_CONTINUE;
}

/* ---- Automation bridge: server-thread -> GTK main-thread hand-off ----
 *
 * A job is refcounted: the waiter holds one ref, the queued GSource holds one,
 * and an in-flight async op holds one. The state machine below, guarded by
 * zb_auto_mutex, guarantees each job completes exactly once and that a job
 * whose waiter gave up is never started (PENDING -> CANCELLED) or has its late
 * result dropped (RUNNING -> ABANDONED). */

enum {
  ZB_LOOP_PENDING = 0,
  ZB_LOOP_RUNNING = 1,
  ZB_LOOP_ENDED = 2,
};

enum {
  ZB_JOB_PENDING = 0,
  ZB_JOB_RUNNING,
  ZB_JOB_DONE,
  ZB_JOB_CANCELLED,
  ZB_JOB_ABANDONED,
};

typedef struct ZbAutoJob ZbAutoJob;
typedef void (*ZbAutoStartFn)(ZbAutoJob *job);

struct ZbAutoJob {
  gint refcount;
  int state; /* guarded by zb_auto_mutex */
  int is_async;
  int code;
  char *result;
  char *err;
  ZbAutoStartFn start;
  ZbMainJobFn fn;
  void *ctx;

  /* Async page ops. Inputs are owned copies; `target` is touched only on the
   * GTK thread and is cleared when the window is destroyed. */
  ZbWindow *requested;
  ZbWindow *target;
  char *body;
  char *arg;
  char *world;
  char *url;
  GCancellable *cancellable;
  int op;
  SoupCookie *cookie;   /* add */
  double x, y;          /* native click */
  int button;
  int modifiers;        /* native key */
  int releases;         /* native key/text: key releases sent */
  GList *cookie_queue;  /* delete: matching cookies still to delete */
  int load_armed;    /* saw LOAD_STARTED for `url` */
  int load_displaced; /* another URI committed over this load */
  int same_document; /* `url` differs from the page only by fragment */
  unsigned int load_gen;
};

static GMutex zb_auto_mutex;
static GCond zb_auto_cond;
static int zb_auto_loop_state = ZB_LOOP_PENDING;
/* Sources attached for the GTK thread and not yet dispatched; guarded by
 * zb_auto_mutex. Each entry owns one source ref. Ending the loop destroys
 * them so their job refs are released. */
static GList *zb_auto_queued;
static gint zb_auto_live_jobs;

int zb_automation_debug_live_jobs(void) {
  return g_atomic_int_get(&zb_auto_live_jobs);
}

static ZbAutoJob *auto_job_new(ZbAutoStartFn start, int is_async) {
  g_atomic_int_inc(&zb_auto_live_jobs);
  ZbAutoJob *job = g_new0(ZbAutoJob, 1);
  job->refcount = 1;
  job->state = ZB_JOB_PENDING;
  job->start = start;
  job->is_async = is_async;
  return job;
}

static ZbAutoJob *auto_job_ref(ZbAutoJob *job) {
  g_atomic_int_inc(&job->refcount);
  return job;
}

static void auto_job_unref(gpointer data) {
  ZbAutoJob *job = (ZbAutoJob *)data;
  if (job == NULL || !g_atomic_int_dec_and_test(&job->refcount)) {
    return;
  }
  g_free(job->result);
  g_free(job->err);
  g_free(job->body);
  g_free(job->arg);
  g_free(job->world);
  g_free(job->url);
  if (job->cancellable != NULL) {
    g_object_unref(job->cancellable);
  }
  if (job->cookie != NULL) {
    soup_cookie_free(job->cookie);
  }
  g_list_free_full(job->cookie_queue, (GDestroyNotify)soup_cookie_free);
  g_free(job);
  g_atomic_int_add(&zb_auto_live_jobs, -1);
}

/* WebKit async calls hold a job ref until their callback runs. The count lets
 * zb_app_run drain cancelled callbacks after the loop ends, so every job is
 * released. GTK thread only. */
static gint zb_auto_async_pending;

static ZbAutoJob *auto_async_ref(ZbAutoJob *job) {
  zb_auto_async_pending++;
  return auto_job_ref(job);
}

static void auto_async_release(ZbAutoJob *job) {
  zb_auto_async_pending--;
  auto_job_unref(job);
}

/* GTK thread. Records the outcome once and wakes waiters; takes ownership of
 * result/err and frees them if the waiter already gave up. */
static void auto_job_complete(ZbAutoJob *job, int code, char *result, char *err) {
  g_mutex_lock(&zb_auto_mutex);
  if (job->state == ZB_JOB_RUNNING) {
    job->code = code;
    job->result = result;
    job->err = err;
    job->state = ZB_JOB_DONE;
    result = NULL;
    err = NULL;
  }
  g_cond_broadcast(&zb_auto_cond);
  g_mutex_unlock(&zb_auto_mutex);
  g_free(result);
  g_free(err);
}

static int auto_loop_ended_locked(void);

/* Dispatch side of auto_queue_on_gtk: drop the queued entry for the source
 * being dispatched. Called with zb_auto_mutex held. */
static void auto_forget_current_source_locked(void) {
  GSource *source = g_main_current_source();
  GList *link = g_list_find(zb_auto_queued, source);
  if (link != NULL) {
    zb_auto_queued = g_list_delete_link(zb_auto_queued, link);
    g_source_unref(source);
  }
}

static gboolean auto_job_dispatch(gpointer data) {
  ZbAutoJob *job = (ZbAutoJob *)data;
  g_mutex_lock(&zb_auto_mutex);
  auto_forget_current_source_locked();
  if (job->state == ZB_JOB_PENDING && auto_loop_ended_locked()) {
    job->state = ZB_JOB_CANCELLED;
    g_cond_broadcast(&zb_auto_cond);
  }
  if (job->state != ZB_JOB_PENDING) {
    g_mutex_unlock(&zb_auto_mutex);
    return G_SOURCE_REMOVE;
  }
  job->state = ZB_JOB_RUNNING;
  g_mutex_unlock(&zb_auto_mutex);

  job->start(job);
  return G_SOURCE_REMOVE;
}

static int auto_loop_ended_locked(void) {
  return zb_auto_loop_state == ZB_LOOP_ENDED;
}

/* Queue the job on the default main context. An explicit idle source is used
 * instead of g_main_context_invoke, which would run the job on the calling
 * thread whenever no thread currently owns the default context. */
static int auto_queue_on_gtk(GSourceFunc fn, ZbAutoJob *job) {
  g_mutex_lock(&zb_auto_mutex);
  if (auto_loop_ended_locked()) {
    g_mutex_unlock(&zb_auto_mutex);
    return ZB_AUTO_ERR_NO_LOOP;
  }

  GSource *source = g_idle_source_new();
  g_source_set_priority(source, G_PRIORITY_DEFAULT);
  g_source_set_callback(source, fn, auto_job_ref(job), auto_job_unref);
  g_source_attach(source, g_main_context_default());
  zb_auto_queued = g_list_prepend(zb_auto_queued, source);
  g_mutex_unlock(&zb_auto_mutex);
  return ZB_AUTO_OK;
}

static int auto_job_submit(ZbAutoJob *job) {
  return auto_queue_on_gtk(auto_job_dispatch, job);
}

/* Waiter thread. Returns the job's code, or TIMEOUT / NO_LOOP after moving the
 * job to CANCELLED (never started) or ABANDONED (async op in flight). A sync
 * job that has already started is waited out regardless of the deadline. */
static int auto_job_wait(ZbAutoJob *job, gint64 deadline_us) {
  int code = ZB_AUTO_OK;
  g_mutex_lock(&zb_auto_mutex);
  for (;;) {
    if (job->state == ZB_JOB_DONE) {
      code = job->code;
      break;
    }

    int give_up = 0;
    int give_up_code = ZB_AUTO_ERR_TIMEOUT;
    if (auto_loop_ended_locked()) {
      give_up = 1;
      give_up_code = ZB_AUTO_ERR_NO_LOOP;
    } else if (deadline_us == G_MAXINT64) {
      g_cond_wait(&zb_auto_cond, &zb_auto_mutex);
      continue;
    } else if (!g_cond_wait_until(&zb_auto_cond, &zb_auto_mutex, deadline_us)) {
      give_up = job->state != ZB_JOB_DONE;
    }

    if (!give_up) {
      continue;
    }
    if (job->state == ZB_JOB_PENDING || job->state == ZB_JOB_CANCELLED) {
      job->state = ZB_JOB_CANCELLED;
      code = give_up_code;
      break;
    }
    if (job->state == ZB_JOB_RUNNING && job->is_async) {
      job->state = ZB_JOB_ABANDONED;
      code = give_up_code;
      break;
    }
    /* Sync job mid-run on the GTK thread: it finishes promptly. */
    deadline_us = G_MAXINT64;
  }
  g_mutex_unlock(&zb_auto_mutex);
  return code;
}

static gint64 auto_deadline(unsigned int timeout_ms) {
  return g_get_monotonic_time() + (gint64)timeout_ms * G_TIME_SPAN_MILLISECOND;
}

static int auto_on_gtk_thread(void) {
  return g_main_context_is_owner(g_main_context_default());
}

static void auto_start_invoke(ZbAutoJob *job) {
  job->fn(job->ctx);
  auto_job_complete(job, ZB_AUTO_OK, NULL, NULL);
}

int zb_main_invoke_sync(ZbMainJobFn fn, void *ctx, unsigned int timeout_ms) {
  if (fn == NULL) {
    return ZB_AUTO_ERR_INTERNAL;
  }

  g_mutex_lock(&zb_auto_mutex);
  int ended = auto_loop_ended_locked();
  g_mutex_unlock(&zb_auto_mutex);
  if (ended) {
    return ZB_AUTO_ERR_NO_LOOP;
  }

  if (auto_on_gtk_thread()) {
    fn(ctx);
    return ZB_AUTO_OK;
  }

  ZbAutoJob *job = auto_job_new(auto_start_invoke, 0);
  job->fn = fn;
  job->ctx = ctx;
  gint64 deadline = auto_deadline(timeout_ms);
  int code = auto_job_submit(job);
  if (code == ZB_AUTO_OK) {
    code = auto_job_wait(job, deadline);
  }
  auto_job_unref(job);
  return code;
}

void zb_automation_loop_mark(int running) {
  g_mutex_lock(&zb_auto_mutex);
  zb_auto_loop_state = running ? ZB_LOOP_RUNNING : ZB_LOOP_ENDED;
  GList *queued = NULL;
  if (!running) {
    queued = zb_auto_queued;
    zb_auto_queued = NULL;
  }
  g_cond_broadcast(&zb_auto_cond);
  g_mutex_unlock(&zb_auto_mutex);

  /* Outside the lock: destroy notifies drop job refs. Waiters see ENDED and
   * give up on their own. */
  for (GList *link = queued; link != NULL; link = link->next) {
    GSource *source = (GSource *)link->data;
    g_source_destroy(source);
    g_source_unref(source);
  }
  g_list_free(queued);
}

/* ---- Automation bridge: windows, script injection, page ops ---- */

enum {
  ZB_OP_INVOKE = 0,
  ZB_OP_EVAL,
  ZB_OP_NAVIGATE,
  ZB_OP_RELOAD,
  ZB_OP_URL,
  ZB_OP_COOKIES_GET,
  ZB_OP_COOKIES_ADD,
  ZB_OP_COOKIES_DELETE,
  ZB_OP_NATIVE_CLICK,
  ZB_OP_NATIVE_KEY,
  ZB_OP_NATIVE_TEXT,
};

#define ZB_AUTO_SCRIPT_KEY "zb-automation-script"

static char *zb_auto_script_source; /* set before zb_app_run */
static ZbApp *zb_auto_app;          /* GTK thread only */
/* Snapshot of the live windows in app order (index 0 = primary) and whether
 * each one's first load has ended; guarded by zb_auto_mutex, published by the
 * GTK thread whenever a window is added, removed or finishes its first load. */
static ZbWindow *zb_auto_pub_windows[ZB_MAX_WINDOWS];
static int zb_auto_pub_ready[ZB_MAX_WINDOWS];
static int zb_auto_pub_count;
static GList *zb_auto_inflight;     /* GTK thread only; holds one ref per job */

void zb_automation_set_script(const char *source, size_t len) {
  g_free(zb_auto_script_source);
  zb_auto_script_source = source != NULL ? g_strndup(source, len) : NULL;
}

/* Child views built with webkit_web_view_new_with_related_view share their
 * parent's content manager, so the marker keeps the script installed once. */
static void auto_install_script(ZbWindow *win) {
  if (zb_auto_script_source == NULL || win->ucm == NULL ||
      g_object_get_data(G_OBJECT(win->ucm), ZB_AUTO_SCRIPT_KEY) != NULL) {
    return;
  }

  WebKitUserScript *script = webkit_user_script_new_for_world(
      zb_auto_script_source, WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
      WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START, ZB_AUTOMATION_WORLD, NULL,
      NULL);
  webkit_user_content_manager_add_script(win->ucm, script);
  webkit_user_script_unref(script);
  g_object_set_data(G_OBJECT(win->ucm), ZB_AUTO_SCRIPT_KEY, GINT_TO_POINTER(1));
}

/* GTK thread: publish the primary window and whether its first load has
 * ended, for waiters on the server thread. */
static void auto_publish_primary(ZbApp *app) {
  int count = app != NULL ? app->n_windows : 0;
  g_mutex_lock(&zb_auto_mutex);
  zb_auto_pub_count = 0;
  for (int i = 0; i < count && i < ZB_MAX_WINDOWS; i++) {
    ZbWindow *win = app->windows[i];
    if (win == NULL) {
      continue;
    }
    zb_auto_pub_windows[zb_auto_pub_count] = win;
    zb_auto_pub_ready[zb_auto_pub_count] = win->auto_first_load_done;
    zb_auto_pub_count++;
  }
  g_cond_broadcast(&zb_auto_cond);
  g_mutex_unlock(&zb_auto_mutex);
}

static void auto_first_load_done(ZbWindow *win) {
  if (win->auto_first_load_done) {
    return;
  }
  win->auto_first_load_done = 1;
  auto_publish_primary(win->app);
}

ZbWindow *zb_automation_window_at(int index) {
  g_mutex_lock(&zb_auto_mutex);
  ZbWindow *win = index >= 0 && index < zb_auto_pub_count ? zb_auto_pub_windows[index] : NULL;
  g_mutex_unlock(&zb_auto_mutex);
  return win;
}

ZbWindow *zb_automation_main_window(void) {
  g_mutex_lock(&zb_auto_mutex);
  ZbWindow *win = zb_auto_pub_count > 0 ? zb_auto_pub_windows[0] : NULL;
  g_mutex_unlock(&zb_auto_mutex);
  return win;
}

/* GTK thread: map a requested window (NULL = primary) to a live window. */
static ZbWindow *auto_resolve_window(ZbWindow *requested) {
  ZbApp *app = zb_auto_app;
  if (app == NULL) {
    return NULL;
  }
  for (int i = 0; i < app->n_windows; i++) {
    ZbWindow *win = app->windows[i];
    if (win != NULL && win->view != NULL &&
        (requested == NULL ? i == 0 : win == requested)) {
      return win;
    }
  }
  return NULL;
}

static void auto_track(ZbAutoJob *job, ZbWindow *win) {
  job->target = win;
  zb_auto_inflight = g_list_prepend(zb_auto_inflight, auto_job_ref(job));
}

static void auto_untrack(ZbAutoJob *job) {
  GList *link = g_list_find(zb_auto_inflight, job);
  if (link != NULL) {
    zb_auto_inflight = g_list_delete_link(zb_auto_inflight, link);
    auto_job_unref(job);
  }
}

/* GTK thread: complete tracked jobs on `win` whose op matches `pred`. */
static void auto_complete_tracked(ZbWindow *win, int (*pred)(const ZbAutoJob *),
                                  int code, const char *message) {
  GList *link = zb_auto_inflight;
  while (link != NULL) {
    GList *next = link->next;
    ZbAutoJob *job = (ZbAutoJob *)link->data;
    if (job->target == win && pred(job)) {
      job->target = NULL;
      auto_job_complete(job, code, NULL,
                        message != NULL ? g_strdup(message) : NULL);
      zb_auto_inflight = g_list_delete_link(zb_auto_inflight, link);
      auto_job_unref(job);
    }
    link = next;
  }
}

static int auto_is_any(const ZbAutoJob *job) {
  (void)job;
  return 1;
}

static int auto_is_load(const ZbAutoJob *job) {
  return job->op == ZB_OP_NAVIGATE || job->op == ZB_OP_RELOAD;
}

/* URI in a comparable form: scheme-normalized (default port dropped, empty
 * path -> "/"), scheme and host lower-cased. NULL when unparsable. */
static char *auto_canonical_uri(const char *uri, int drop_fragment) {
  GUri *parsed = g_uri_parse(uri, G_URI_FLAGS_ENCODED | G_URI_FLAGS_SCHEME_NORMALIZE, NULL);
  if (parsed == NULL) {
    return NULL;
  }
  char *scheme = g_ascii_strdown(g_uri_get_scheme(parsed), -1);
  const char *raw_host = g_uri_get_host(parsed);
  char *host = raw_host != NULL ? g_ascii_strdown(raw_host, -1) : NULL;
  char *out = g_uri_join(G_URI_FLAGS_ENCODED, scheme, g_uri_get_userinfo(parsed),
                         host, g_uri_get_port(parsed), g_uri_get_path(parsed),
                         g_uri_get_query(parsed),
                         drop_fragment ? NULL : g_uri_get_fragment(parsed));
  g_free(scheme);
  g_free(host);
  g_uri_unref(parsed);
  return out;
}

static int auto_uri_equal(const char *a, const char *b, int drop_fragment) {
  if (a == NULL || b == NULL) {
    return 0;
  }
  char *ca = auto_canonical_uri(a, drop_fragment);
  char *cb = auto_canonical_uri(b, drop_fragment);
  int same = ca != NULL && cb != NULL ? strcmp(ca, cb) == 0 : strcmp(a, b) == 0;
  g_free(ca);
  g_free(cb);
  return same;
}

static int auto_same_uri(const char *a, const char *b) {
  return auto_uri_equal(a, b, 0);
}

/* GTK thread: a tracked automation load owns the deadline for this window's
 * current load, replacing the legacy fixed load timer. */
static int auto_window_owns_load_deadline(ZbWindow *win) {
  for (GList *link = zb_auto_inflight; link != NULL; link = link->next) {
    ZbAutoJob *job = (ZbAutoJob *)link->data;
    if (job->target == win && auto_is_load(job) && !job->load_displaced) {
      return 1;
    }
  }
  return 0;
}

/* Same-document (fragment-only) navigations fire no load events; the URI
 * change completes them. */
static void auto_uri_changed(ZbWindow *win, const char *uri) {
  GList *link = zb_auto_inflight;
  while (link != NULL) {
    GList *next = link->next;
    ZbAutoJob *job = (ZbAutoJob *)link->data;
    if (job->target == win && job->op == ZB_OP_NAVIGATE && job->same_document &&
        auto_same_uri(job->url, uri)) {
      job->target = NULL;
      auto_job_complete(job, ZB_AUTO_OK, NULL, NULL);
      zb_auto_inflight = g_list_delete_link(zb_auto_inflight, link);
      auto_job_unref(job);
    }
    link = next;
  }
}

static void on_window_uri_notify(WebKitWebView *view, GParamSpec *pspec,
                                 gpointer user_data) {
  (void)pspec;
  ZbWindow *win = (ZbWindow *)user_data;
  if (win != NULL) {
    auto_uri_changed(win, webkit_web_view_get_uri(view));
  }
}

static void auto_window_destroyed(ZbWindow *win) {
  for (GList *link = zb_auto_inflight; link != NULL; link = link->next) {
    ZbAutoJob *job = (ZbAutoJob *)link->data;
    if (job->target == win && job->cancellable != NULL) {
      g_cancellable_cancel(job->cancellable);
    }
  }
  auto_complete_tracked(win, auto_is_any, ZB_AUTO_ERR_CANCELLED,
                        "window destroyed");
}

/* A load job follows its own URI: LOAD_STARTED or COMMITTED for that URI arms
 * it, REDIRECTED moves it, a commit of any other URI disarms it (the load was
 * displaced, e.g. by WebKit's error page for an earlier failure), and only
 * FINISHED for its URI on an armed job completes it. */
static void auto_load_event(ZbWindow *win, WebKitLoadEvent event, const char *uri) {
  GList *link = zb_auto_inflight;
  while (link != NULL) {
    GList *next = link->next;
    ZbAutoJob *job = (ZbAutoJob *)link->data;
    if (job->target != win || !auto_is_load(job)) {
      link = next;
      continue;
    }

    int same = auto_same_uri(job->url, uri);
    if (event == WEBKIT_LOAD_STARTED && same) {
      job->load_armed = 1;
    } else if (event == WEBKIT_LOAD_REDIRECTED && job->load_armed) {
      g_free(job->url);
      job->url = g_strdup(uri);
    } else if (event == WEBKIT_LOAD_COMMITTED) {
      /* STARTED may still report the previous URI (e.g. for a request WebKit
       * rewrites), so the commit of our URI also arms the job. */
      job->load_armed = same;
      job->load_displaced = !same;
    } else if (event == WEBKIT_LOAD_FINISHED && same && job->load_armed) {
      job->target = NULL;
      auto_job_complete(job, ZB_AUTO_OK, NULL, NULL);
      zb_auto_inflight = g_list_delete_link(zb_auto_inflight, link);
      auto_job_unref(job);
    }
    link = next;
  }
}

/* Fails load jobs for `uri` (a failure can precede any event that would arm
 * the job); returns whether any matched. */
static int auto_load_failed(ZbWindow *win, const char *uri, const GError *error) {
  int matched = 0;
  GList *link = zb_auto_inflight;
  while (link != NULL) {
    GList *next = link->next;
    ZbAutoJob *job = (ZbAutoJob *)link->data;
    if (job->target == win && auto_is_load(job) && !job->load_displaced &&
        auto_same_uri(job->url, uri)) {
      const char *message = is_cancelled_network_error(error)
                                ? "navigation interrupted by another load"
                                : (error != NULL && error->message != NULL
                                       ? error->message
                                       : "load failed");
      job->target = NULL;
      auto_job_complete(job, ZB_AUTO_ERR_NAV_FAILED, NULL, g_strdup(message));
      zb_auto_inflight = g_list_delete_link(zb_auto_inflight, link);
      auto_job_unref(job);
      matched = 1;
    }
    link = next;
  }
  return matched;
}

static void auto_nav_blocked(ZbWindow *win, const char *candidate) {
  GList *link = zb_auto_inflight;
  while (link != NULL) {
    GList *next = link->next;
    ZbAutoJob *job = (ZbAutoJob *)link->data;
    if (job->target == win && job->op == ZB_OP_NAVIGATE &&
        g_strcmp0(job->url, candidate) == 0) {
      job->target = NULL;
      auto_job_complete(job, ZB_AUTO_ERR_NAV_FAILED, NULL,
                        g_strdup("navigation blocked by policy"));
      zb_auto_inflight = g_list_delete_link(zb_auto_inflight, link);
      auto_job_unref(job);
    }
    link = next;
  }
}

/* GTK thread, after the waiter gave up (TIMEOUT / NO_LOOP). Eval: cancel the
 * JS call (its callback then untracks). Load: stop the load only while it is
 * still this window's newest automation load and nothing else committed over
 * it, then untrack. Cancelling here, not on the server thread, keeps WebKit's
 * "cancelled" handlers on the GTK thread. */
static gboolean auto_abandon_dispatch(gpointer data) {
  ZbAutoJob *job = (ZbAutoJob *)data;
  g_mutex_lock(&zb_auto_mutex);
  auto_forget_current_source_locked();
  g_mutex_unlock(&zb_auto_mutex);

  if (job->cancellable != NULL) {
    g_cancellable_cancel(job->cancellable);
  }
  ZbWindow *win = job->target;
  if (win != NULL && auto_is_load(job)) {
    if (!job->load_displaced && job->load_gen == win->auto_load_gen &&
        win->view != NULL && webkit_web_view_is_loading(win->view)) {
      win->load_superseded = 1;
      webkit_web_view_stop_loading(win->view);
    }
    job->target = NULL;
    auto_untrack(job);
  }
  return G_SOURCE_REMOVE;
}

static void on_auto_eval_done(GObject *object, GAsyncResult *result,
                              gpointer user_data) {
  ZbAutoJob *job = (ZbAutoJob *)user_data;
  GError *error = NULL;
  JSCValue *value = webkit_web_view_call_async_javascript_function_finish(
      WEBKIT_WEB_VIEW(object), result, &error);
  auto_untrack(job);

  if (value == NULL) {
    int code = g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)
                   ? ZB_AUTO_ERR_CANCELLED
                   : ZB_AUTO_ERR_JS;
    auto_job_complete(job, code, NULL,
                      g_strdup(error != NULL ? error->message : "eval failed"));
    g_clear_error(&error);
  } else {
    char *out = NULL;
    if (jsc_value_is_string(value)) {
      out = jsc_value_to_string(value);
    } else if (!jsc_value_is_undefined(value)) {
      out = jsc_value_to_json(value, 0);
    }
    g_object_unref(value);
    auto_job_complete(job, ZB_AUTO_OK, out != NULL ? out : g_strdup("null"),
                      NULL);
  }
  auto_async_release(job);
}

static void auto_start_eval(ZbAutoJob *job) {
  ZbWindow *win = auto_resolve_window(job->requested);
  if (win == NULL) {
    auto_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, g_strdup("no such window"));
    return;
  }

  GVariantDict dict;
  g_variant_dict_init(&dict, NULL);
  g_variant_dict_insert(&dict, "arg", "s", job->arg);
  GVariant *args = g_variant_ref_sink(g_variant_dict_end(&dict));

  auto_track(job, win);
  webkit_web_view_call_async_javascript_function(
      win->view, job->body, -1, args, job->world, NULL, job->cancellable,
      on_auto_eval_done, auto_async_ref(job));
  g_variant_unref(args); /* arguments are transfer-none */
}

/* Mirrors zb_reload: mark the in-flight load superseded so its cancellation
 * and FINISHED are ignored, then start the new load. */
static void auto_start_load(ZbAutoJob *job) {
  ZbWindow *win = auto_resolve_window(job->requested);
  if (win == NULL) {
    auto_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, g_strdup("no such window"));
    return;
  }

  auto_track(job, win);
  job->load_gen = ++win->auto_load_gen;
  const char *current = webkit_web_view_get_uri(win->view);
  job->same_document = job->op == ZB_OP_NAVIGATE && current != NULL &&
                       !auto_same_uri(job->url, current) &&
                       auto_uri_equal(job->url, current, 1) &&
                       strchr(job->url, '#') != NULL;
  if (job->same_document) {
    webkit_web_view_load_uri(win->view, job->url);
    return;
  }

  win->load_superseded = 1;
  win->suppress_success_emit = 0;
  window_clear_pending_nav(win);
  if (win->cancellable != NULL) {
    g_cancellable_cancel(win->cancellable);
  }
  webkit_web_view_stop_loading(win->view);

  if (job->op == ZB_OP_NAVIGATE) {
    webkit_web_view_load_uri(win->view, job->url);
  } else {
    job->url = g_strdup(webkit_web_view_get_uri(win->view));
    webkit_web_view_reload(win->view);
  }
}

static void auto_start_get(ZbAutoJob *job) {
  ZbWindow *win = auto_resolve_window(job->requested);
  if (win == NULL) {
    auto_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, g_strdup("no such window"));
    return;
  }

  const char *value = webkit_web_view_get_uri(win->view);
  auto_job_complete(job, ZB_AUTO_OK, g_strdup(value != NULL ? value : ""), NULL);
}

/* Wait until the primary window exists and, when `need_ready`, its first
 * load has ended, so commands sent while the start page is still loading do
 * not run against the empty initial document. */
/* Index of `win` in the published snapshot (NULL = primary), or -1. */
static int auto_pub_index_locked(ZbWindow *win) {
  if (win == NULL) {
    return zb_auto_pub_count > 0 ? 0 : -1;
  }
  for (int i = 0; i < zb_auto_pub_count; i++) {
    if (zb_auto_pub_windows[i] == win) {
      return i;
    }
  }
  return -1;
}

/* Wait until the target window exists and, when `need_ready`, its own first
 * load has ended, so commands sent while a page is still loading do not run
 * against its empty initial document. NULL waits for the primary window to
 * appear; an explicit window that is not alive is NO_WINDOW at once. */
static int auto_wait_for_window(ZbWindow *target, gint64 deadline_us, int need_ready) {
  int code = ZB_AUTO_OK;
  g_mutex_lock(&zb_auto_mutex);
  for (;;) {
    int index = auto_pub_index_locked(target);
    if (auto_loop_ended_locked()) {
      code = ZB_AUTO_ERR_NO_LOOP;
      break;
    }
    if (index < 0 && target != NULL) {
      code = ZB_AUTO_ERR_NO_WINDOW;
      break;
    }
    if (index >= 0 && (!need_ready || zb_auto_pub_ready[index])) {
      break;
    }
    if (!g_cond_wait_until(&zb_auto_cond, &zb_auto_mutex, deadline_us)) {
      index = auto_pub_index_locked(target);
      if (index < 0) {
        code = ZB_AUTO_ERR_NO_WINDOW;
        break;
      }
      if (need_ready && !zb_auto_pub_ready[index]) {
        code = ZB_AUTO_ERR_TIMEOUT;
        break;
      }
      break;
    }
  }
  if (code == ZB_AUTO_OK && auto_loop_ended_locked()) {
    code = ZB_AUTO_ERR_NO_LOOP;
  }
  g_mutex_unlock(&zb_auto_mutex);
  return code;
}

/* Waiter side shared by every page op. Moves the job's outputs to the
 * caller when the job finished, whatever its code. */
static int auto_run_op(ZbAutoJob *job, ZbWindow *win, unsigned int timeout_ms,
                       char **out_result, char **out_err) {
  if (out_result != NULL) {
    *out_result = NULL;
  }
  if (out_err != NULL) {
    *out_err = NULL;
  }
  if (auto_on_gtk_thread()) {
    return ZB_AUTO_ERR_INTERNAL;
  }

  gint64 deadline = auto_deadline(timeout_ms);
  int need_ready = job->op != ZB_OP_NAVIGATE && job->op != ZB_OP_COOKIES_GET &&
                   job->op != ZB_OP_COOKIES_ADD && job->op != ZB_OP_COOKIES_DELETE;
  int code = auto_wait_for_window(win, deadline, need_ready);
  if (code != ZB_AUTO_OK) {
    return code;
  }

  job->requested = win;
  code = auto_job_submit(job);
  if (code == ZB_AUTO_OK) {
    code = auto_job_wait(job, deadline);
  }

  g_mutex_lock(&zb_auto_mutex);
  int done = job->state == ZB_JOB_DONE;
  if (done && out_result != NULL) {
    *out_result = job->result;
    job->result = NULL;
  }
  if (done && out_err != NULL) {
    *out_err = job->err;
    job->err = NULL;
  }
  g_mutex_unlock(&zb_auto_mutex);

  if (!done && job->is_async) {
    auto_queue_on_gtk(auto_abandon_dispatch, job);
  }
  return code;
}

static void auto_start_cookies(ZbAutoJob *job);
static void auto_start_native(ZbAutoJob *job);

static ZbAutoJob *auto_op_new(int op) {
  if (op == ZB_OP_NATIVE_CLICK || op == ZB_OP_NATIVE_KEY || op == ZB_OP_NATIVE_TEXT) {
    ZbAutoJob *job = auto_job_new(auto_start_native, 0);
    job->op = op;
    return job;
  }
  int is_cookie = op == ZB_OP_COOKIES_GET || op == ZB_OP_COOKIES_ADD ||
                  op == ZB_OP_COOKIES_DELETE;
  int is_async = op == ZB_OP_EVAL || op == ZB_OP_NAVIGATE || op == ZB_OP_RELOAD ||
                 is_cookie;
  ZbAutoStartFn start = op == ZB_OP_EVAL ? auto_start_eval
                        : is_cookie     ? auto_start_cookies
                        : is_async      ? auto_start_load
                                        : auto_start_get;
  ZbAutoJob *job = auto_job_new(start, is_async);
  job->op = op;
  if (is_async) {
    job->cancellable = g_cancellable_new();
  }
  return job;
}

int zb_automation_eval_json(ZbWindow *win, const char *function_body,
                            const char *arg_json, const char *world,
                            unsigned int timeout_ms, char **out_result,
                            char **out_err) {
  if (function_body == NULL) {
    return ZB_AUTO_ERR_INTERNAL;
  }
  ZbAutoJob *job = auto_op_new(ZB_OP_EVAL);
  job->body = g_strdup(function_body);
  job->arg = g_strdup(arg_json != NULL ? arg_json : "null");
  job->world = g_strdup(world);
  int code = auto_run_op(job, win, timeout_ms, out_result, out_err);
  auto_job_unref(job);
  return code;
}

int zb_automation_navigate(ZbWindow *win, const char *url, unsigned int timeout_ms,
                           char **out_err) {
  if (url == NULL) {
    return ZB_AUTO_ERR_INTERNAL;
  }
  ZbAutoJob *job = auto_op_new(ZB_OP_NAVIGATE);
  job->url = g_strdup(url);
  int code = auto_run_op(job, win, timeout_ms, NULL, out_err);
  auto_job_unref(job);
  return code;
}

int zb_automation_reload(ZbWindow *win, unsigned int timeout_ms, char **out_err) {
  ZbAutoJob *job = auto_op_new(ZB_OP_RELOAD);
  int code = auto_run_op(job, win, timeout_ms, NULL, out_err);
  auto_job_unref(job);
  return code;
}

int zb_automation_get_url(ZbWindow *win, unsigned int timeout_ms, char **out_url) {
  ZbAutoJob *job = auto_op_new(ZB_OP_URL);
  int code = auto_run_op(job, win, timeout_ms, out_url, NULL);
  auto_job_unref(job);
  return code;
}

/* Reads document.title in the isolated world: webkit_web_view_get_title lags
 * the DOM and is often still empty when the load finishes. */
int zb_automation_get_title(ZbWindow *win, unsigned int timeout_ms, char **out_title) {
  return zb_automation_eval_json(win, "return document.title || '';", NULL,
                                 ZB_AUTOMATION_WORLD, timeout_ms, out_title, NULL);
}

void zb_automation_free(char *p) {
  g_free(p);
}

/* ---- Cookie store ----
 * Jobs run on the GTK thread against the primary window's context (the
 * profile context when one is set). Messages never include cookie values. */

static WebKitCookieManager *auto_cookie_manager(ZbAutoJob *job) {
  ZbWindow *win = auto_resolve_window(job->requested);
  if (win == NULL || win->view == NULL) {
    return NULL;
  }
  return webkit_web_context_get_cookie_manager(webkit_web_view_get_context(win->view));
}

/* Completes a cookie job and drops its in-flight tracking. */
static void auto_cookie_finish(ZbAutoJob *job, int code, char *result, char *err) {
  job->target = NULL;
  auto_untrack(job);
  auto_job_complete(job, code, result, err);
}

static int auto_cookie_cancelled(GError *error) {
  return g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
}

static void auto_cookie_fail(ZbAutoJob *job, GError *error, const char *what) {
  int code = auto_cookie_cancelled(error) ? ZB_AUTO_ERR_CANCELLED : ZB_AUTO_ERR_INTERNAL;
  auto_cookie_finish(job, code, NULL, g_strdup(what));
}

/* JSON string literal; invalid UTF-8 is repaired, control characters and
 * quotes are escaped. */
static void auto_json_string(GString *out, const char *text) {
  char *valid = g_utf8_make_valid(text != NULL ? text : "", -1);
  g_string_append_c(out, '"');
  for (const unsigned char *p = (const unsigned char *)valid; *p != '\0'; p++) {
    if (*p == '"' || *p == '\\') {
      g_string_append_c(out, '\\');
      g_string_append_c(out, (char)*p);
    } else if (*p < 0x20) {
      g_string_append_printf(out, "\\u%04x", *p);
    } else {
      g_string_append_c(out, (char)*p);
    }
  }
  g_string_append_c(out, '"');
  g_free(valid);
}

static const char *auto_same_site_name(SoupSameSitePolicy policy) {
  switch (policy) {
    case SOUP_SAME_SITE_POLICY_LAX:
      return "Lax";
    case SOUP_SAME_SITE_POLICY_STRICT:
      return "Strict";
    default:
      return "None";
  }
}

static char *auto_cookies_json(GList *cookies) {
  GString *out = g_string_new("[");
  for (GList *link = cookies; link != NULL; link = link->next) {
    SoupCookie *cookie = (SoupCookie *)link->data;
    if (link != cookies) {
      g_string_append_c(out, ',');
    }
    GDateTime *expires = soup_cookie_get_expires(cookie);
    g_string_append(out, "{\"name\":");
    auto_json_string(out, soup_cookie_get_name(cookie));
    g_string_append(out, ",\"value\":");
    auto_json_string(out, soup_cookie_get_value(cookie));
    g_string_append(out, ",\"domain\":");
    auto_json_string(out, soup_cookie_get_domain(cookie));
    g_string_append(out, ",\"path\":");
    auto_json_string(out, soup_cookie_get_path(cookie));
    g_string_append_printf(out,
                           ",\"expires\":%" G_GINT64_FORMAT
                           ",\"httpOnly\":%s,\"secure\":%s,\"sameSite\":\"%s\"}",
                           expires != NULL ? g_date_time_to_unix(expires) : (gint64)-1,
                           soup_cookie_get_http_only(cookie) ? "true" : "false",
                           soup_cookie_get_secure(cookie) ? "true" : "false",
                           auto_same_site_name(soup_cookie_get_same_site_policy(cookie)));
  }
  g_string_append_c(out, ']');
  return g_string_free(out, FALSE);
}

static void on_auto_cookies_got(GObject *object, GAsyncResult *result, gpointer user_data) {
  ZbAutoJob *job = (ZbAutoJob *)user_data;
  WebKitCookieManager *manager = WEBKIT_COOKIE_MANAGER(object);
  GError *error = NULL;
  GList *cookies = job->url != NULL
                       ? webkit_cookie_manager_get_cookies_finish(manager, result, &error)
                       : webkit_cookie_manager_get_all_cookies_finish(manager, result, &error);
  if (error != NULL) {
    auto_cookie_fail(job, error, "cookie store read failed");
    g_error_free(error);
  } else {
    auto_cookie_finish(job, ZB_AUTO_OK, auto_cookies_json(cookies), NULL);
  }
  g_list_free_full(cookies, (GDestroyNotify)soup_cookie_free);
  auto_async_release(job);
}

static void on_auto_cookie_added(GObject *object, GAsyncResult *result, gpointer user_data) {
  ZbAutoJob *job = (ZbAutoJob *)user_data;
  GError *error = NULL;
  if (webkit_cookie_manager_add_cookie_finish(WEBKIT_COOKIE_MANAGER(object), result, &error)) {
    auto_cookie_finish(job, ZB_AUTO_OK, NULL, NULL);
  } else {
    auto_cookie_fail(job, error, "cookie store write failed");
    g_clear_error(&error);
  }
  auto_async_release(job);
}

static void auto_cookie_delete_next(ZbAutoJob *job, WebKitCookieManager *manager);

static void on_auto_cookie_deleted(GObject *object, GAsyncResult *result, gpointer user_data) {
  ZbAutoJob *job = (ZbAutoJob *)user_data;
  WebKitCookieManager *manager = WEBKIT_COOKIE_MANAGER(object);
  GError *error = NULL;
  if (!webkit_cookie_manager_delete_cookie_finish(manager, result, &error)) {
    auto_cookie_fail(job, error, "cookie store delete failed");
    g_clear_error(&error);
  } else {
    auto_cookie_delete_next(job, manager);
  }
  auto_async_release(job);
}

/* Deletes the queued cookies one at a time; completes when none are left. */
static void auto_cookie_delete_next(ZbAutoJob *job, WebKitCookieManager *manager) {
  if (job->cookie_queue == NULL) {
    auto_cookie_finish(job, ZB_AUTO_OK, NULL, NULL);
    return;
  }
  if (g_cancellable_is_cancelled(job->cancellable)) {
    auto_cookie_finish(job, ZB_AUTO_ERR_CANCELLED, NULL, g_strdup("cancelled"));
    return;
  }
  GList *head = job->cookie_queue;
  job->cookie_queue = g_list_remove_link(job->cookie_queue, head);
  SoupCookie *cookie = (SoupCookie *)head->data;
  g_list_free(head);
  webkit_cookie_manager_delete_cookie(manager, cookie, job->cancellable,
                                      on_auto_cookie_deleted, auto_async_ref(job));
  soup_cookie_free(cookie);
}

static int auto_cookie_domain_matches(const char *domain, const char *wanted) {
  if (wanted == NULL) {
    return 1;
  }
  const char *a = domain != NULL && domain[0] == '.' ? domain + 1 : domain;
  const char *b = wanted[0] == '.' ? wanted + 1 : wanted;
  return a != NULL && g_ascii_strcasecmp(a, b) == 0;
}

static void on_auto_cookies_listed_for_delete(GObject *object, GAsyncResult *result,
                                              gpointer user_data) {
  ZbAutoJob *job = (ZbAutoJob *)user_data;
  WebKitCookieManager *manager = WEBKIT_COOKIE_MANAGER(object);
  GError *error = NULL;
  GList *cookies = webkit_cookie_manager_get_all_cookies_finish(manager, result, &error);
  if (error != NULL) {
    auto_cookie_fail(job, error, "cookie store read failed");
    g_error_free(error);
    auto_async_release(job);
    return;
  }

  for (GList *link = cookies; link != NULL; link = link->next) {
    SoupCookie *cookie = (SoupCookie *)link->data;
    if (g_strcmp0(soup_cookie_get_name(cookie), job->body) == 0 &&
        auto_cookie_domain_matches(soup_cookie_get_domain(cookie), job->world)) {
      job->cookie_queue = g_list_prepend(job->cookie_queue, soup_cookie_copy(cookie));
    }
  }
  g_list_free_full(cookies, (GDestroyNotify)soup_cookie_free);
  auto_cookie_delete_next(job, manager);
  auto_async_release(job);
}

static gint zb_auto_debug_cookie_delay_ms;

void zb_automation_debug_cookie_delay(unsigned int ms) {
  g_atomic_int_set(&zb_auto_debug_cookie_delay_ms, (gint)ms);
}

static void auto_issue_cookie_op(ZbAutoJob *job, WebKitCookieManager *manager);

/* Test hook path: the job is RUNNING and tracked while held; if its waiter
 * gave up meanwhile (cancellable cancelled) it finishes without touching
 * WebKit. */
static gboolean auto_cookie_delay_fired(gpointer data) {
  ZbAutoJob *job = (ZbAutoJob *)data;
  WebKitCookieManager *manager = auto_cookie_manager(job);
  if (g_cancellable_is_cancelled(job->cancellable) || manager == NULL) {
    auto_cookie_finish(job, ZB_AUTO_ERR_CANCELLED, NULL, g_strdup("cancelled"));
  } else {
    auto_issue_cookie_op(job, manager);
  }
  auto_async_release(job);
  return G_SOURCE_REMOVE;
}

static void auto_start_cookies(ZbAutoJob *job) {
  WebKitCookieManager *manager = auto_cookie_manager(job);
  if (manager == NULL) {
    auto_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, g_strdup("no such window"));
    return;
  }
  /* Tracked like eval/load jobs: closing the window cancels and completes it. */
  auto_track(job, auto_resolve_window(job->requested));

  guint delay = (guint)g_atomic_int_get(&zb_auto_debug_cookie_delay_ms);
  if (delay > 0) {
    g_timeout_add(delay, auto_cookie_delay_fired, auto_async_ref(job));
    return;
  }
  auto_issue_cookie_op(job, manager);
}

static void auto_issue_cookie_op(ZbAutoJob *job, WebKitCookieManager *manager) {
  switch (job->op) {
    case ZB_OP_COOKIES_GET:
      if (job->url != NULL) {
        webkit_cookie_manager_get_cookies(manager, job->url, job->cancellable,
                                          on_auto_cookies_got, auto_async_ref(job));
      } else {
        webkit_cookie_manager_get_all_cookies(manager, job->cancellable,
                                              on_auto_cookies_got, auto_async_ref(job));
      }
      break;
    case ZB_OP_COOKIES_ADD:
      webkit_cookie_manager_add_cookie(manager, job->cookie, job->cancellable,
                                       on_auto_cookie_added, auto_async_ref(job));
      break;
    default:
      webkit_cookie_manager_get_all_cookies(manager, job->cancellable,
                                            on_auto_cookies_listed_for_delete,
                                            auto_async_ref(job));
      break;
  }
}

/* ---- Native (trusted) input ----
 * Events go through gtk_main_do_event like real input from the display:
 * pointer events to the view's own GdkWindow, key events to the toplevel,
 * which forwards them to the focused view. The whole sequence runs in one
 * GTK-thread dispatch (a sync job). */

static guint32 auto_event_time(void) {
  return (guint32)(g_get_monotonic_time() / 1000);
}

/* Give the view keyboard focus, and the toplevel a focus-in: under Xvfb
 * there is no window manager to activate the window. */
static void auto_native_focus(ZbWindow *win) {
  GtkWidget *view = GTK_WIDGET(win->view);
  if (!gtk_widget_has_focus(view)) {
    gtk_widget_grab_focus(view);
  }
  GtkWidget *toplevel = gtk_widget_get_toplevel(view);
  GdkWindow *window = gtk_widget_get_window(toplevel);
  if (window != NULL && !gtk_window_has_toplevel_focus(GTK_WINDOW(toplevel))) {
    GdkEvent *focus = gdk_event_new(GDK_FOCUS_CHANGE);
    focus->focus_change.window = g_object_ref(window);
    focus->focus_change.send_event = TRUE;
    focus->focus_change.in = TRUE;
    gdk_event_set_device(focus, gdk_seat_get_keyboard(
                                    gdk_display_get_default_seat(gdk_window_get_display(window))));
    gtk_widget_send_focus_change(toplevel, focus);
    gdk_event_free(focus);
  }
}

static GdkSeat *auto_seat(GdkWindow *window) {
  return gdk_display_get_default_seat(gdk_window_get_display(window));
}

static void auto_native_pointer(GdkWindow *window, GdkEventType type, double x, double y,
                                int button, GdkModifierType state) {
  GdkEvent *event = gdk_event_new(type);
  double root_x = x;
  double root_y = y;
  int ox = 0;
  int oy = 0;
  gdk_window_get_origin(window, &ox, &oy);
  root_x += ox;
  root_y += oy;
  if (type == GDK_MOTION_NOTIFY) {
    event->motion.window = g_object_ref(window);
    event->motion.time = auto_event_time();
    event->motion.x = x;
    event->motion.y = y;
    event->motion.x_root = root_x;
    event->motion.y_root = root_y;
    event->motion.state = state;
  } else {
    event->button.window = g_object_ref(window);
    event->button.time = auto_event_time();
    event->button.x = x;
    event->button.y = y;
    event->button.x_root = root_x;
    event->button.y_root = root_y;
    event->button.button = (guint)button;
    event->button.state = state;
  }
  gdk_event_set_device(event, gdk_seat_get_pointer(auto_seat(window)));
  gtk_main_do_event(event);
  gdk_event_free(event);
}

static GdkModifierType auto_button_mask(int button) {
  switch (button) {
    case 2:
      return GDK_BUTTON2_MASK;
    case 3:
      return GDK_BUTTON3_MASK;
    default:
      return GDK_BUTTON1_MASK;
  }
}

static void auto_native_click(ZbAutoJob *job, ZbWindow *win) {
  GdkWindow *window = gtk_widget_get_window(GTK_WIDGET(win->view));
  if (window == NULL) {
    auto_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, g_strdup("view not realized"));
    return;
  }
  auto_native_focus(win);
  auto_native_pointer(window, GDK_MOTION_NOTIFY, job->x, job->y, 0, 0);
  auto_native_pointer(window, GDK_BUTTON_PRESS, job->x, job->y, job->button, 0);
  auto_native_pointer(window, GDK_BUTTON_RELEASE, job->x, job->y, job->button,
                      auto_button_mask(job->button));
  auto_job_complete(job, ZB_AUTO_OK, NULL, NULL);
}

typedef struct {
  const char *name;
  guint keyval;
} ZbNamedKey;

static const ZbNamedKey zb_named_keys[] = {
    {"Enter", GDK_KEY_Return},       {"Tab", GDK_KEY_Tab},
    {"Escape", GDK_KEY_Escape},      {"Backspace", GDK_KEY_BackSpace},
    {"Delete", GDK_KEY_Delete},      {"Insert", GDK_KEY_Insert},
    {"ArrowLeft", GDK_KEY_Left},     {"ArrowRight", GDK_KEY_Right},
    {"ArrowUp", GDK_KEY_Up},         {"ArrowDown", GDK_KEY_Down},
    {"Home", GDK_KEY_Home},          {"End", GDK_KEY_End},
    {"PageUp", GDK_KEY_Page_Up},     {"PageDown", GDK_KEY_Page_Down},
    {"Space", GDK_KEY_space},        {"Shift", GDK_KEY_Shift_L},
    {"Control", GDK_KEY_Control_L},  {"Alt", GDK_KEY_Alt_L},
    {"Meta", GDK_KEY_Meta_L},
};

/* DOM key name -> GDK keyval (0 when unknown). */
static guint auto_keyval_for(const char *key) {
  for (gsize i = 0; i < G_N_ELEMENTS(zb_named_keys); i++) {
    if (strcmp(key, zb_named_keys[i].name) == 0) {
      return zb_named_keys[i].keyval;
    }
  }
  if (key[0] == 'F' && key[1] >= '1' && key[1] <= '9') {
    int n = atoi(key + 1);
    if (n >= 1 && n <= 12) {
      return GDK_KEY_F1 + (guint)(n - 1);
    }
  }
  if (g_utf8_validate(key, -1, NULL) && g_utf8_strlen(key, -1) == 1) {
    gunichar ch = g_utf8_get_char(key);
    return ch == '\n' ? GDK_KEY_Return : gdk_unicode_to_keyval(ch);
  }
  return 0;
}

static gboolean auto_is_modifier_keyval(guint keyval) {
  return keyval == GDK_KEY_Shift_L || keyval == GDK_KEY_Control_L ||
         keyval == GDK_KEY_Alt_L || keyval == GDK_KEY_Meta_L;
}

static void auto_native_key_event(GdkWindow *window, GdkEventType type, guint keyval,
                                  GdkModifierType state) {
  GdkEvent *event = gdk_event_new(type);
  event->key.window = g_object_ref(window);
  event->key.time = auto_event_time();
  event->key.state = state;
  event->key.keyval = keyval;
  event->key.is_modifier = auto_is_modifier_keyval(keyval);

  GdkKeymapKey *keys = NULL;
  gint n_keys = 0;
  GdkKeymap *keymap = gdk_keymap_get_for_display(gdk_window_get_display(window));
  if (gdk_keymap_get_entries_for_keyval(keymap, keyval, &keys, &n_keys) && n_keys > 0) {
    event->key.hardware_keycode = (guint16)keys[0].keycode;
    event->key.group = (guint8)keys[0].group;
  }
  g_free(keys);

  gunichar ch = gdk_keyval_to_unicode(keyval);
  char utf8[8] = {0};
  if (ch != 0 && !g_unichar_iscntrl(ch)) {
    g_unichar_to_utf8(ch, utf8);
  }
  event->key.string = g_strdup(utf8);
  event->key.length = (gint)strlen(utf8);
  gdk_event_set_device(event, gdk_seat_get_keyboard(auto_seat(window)));
  gtk_main_do_event(event);
  gdk_event_free(event);
}

static const struct {
  int bit;
  guint keyval;
  GdkModifierType mask;
} zb_native_modifiers[] = {
    {ZB_NATIVE_MOD_SHIFT, GDK_KEY_Shift_L, GDK_SHIFT_MASK},
    {ZB_NATIVE_MOD_CONTROL, GDK_KEY_Control_L, GDK_CONTROL_MASK},
    {ZB_NATIVE_MOD_ALT, GDK_KEY_Alt_L, GDK_MOD1_MASK},
    {ZB_NATIVE_MOD_META, GDK_KEY_Meta_L, GDK_META_MASK},
};

/* Modifiers down (accumulating state), the key down and up, modifiers up in
 * reverse order. Shift turns a letter into its upper-case keyval, as a
 * keyboard would. */
static int auto_native_press(GdkWindow *window, guint keyval, int modifiers) {
  int releases = 1;
  GdkModifierType state = 0;
  for (gsize i = 0; i < G_N_ELEMENTS(zb_native_modifiers); i++) {
    if (modifiers & zb_native_modifiers[i].bit) {
      auto_native_key_event(window, GDK_KEY_PRESS, zb_native_modifiers[i].keyval, state);
      state |= zb_native_modifiers[i].mask;
    }
  }
  if (state & GDK_SHIFT_MASK) {
    keyval = gdk_keyval_to_upper(keyval);
  }
  auto_native_key_event(window, GDK_KEY_PRESS, keyval, state);
  auto_native_key_event(window, GDK_KEY_RELEASE, keyval, state);
  for (gsize i = G_N_ELEMENTS(zb_native_modifiers); i > 0; i--) {
    if (modifiers & zb_native_modifiers[i - 1].bit) {
      state &= ~zb_native_modifiers[i - 1].mask;
      auto_native_key_event(window, GDK_KEY_RELEASE, zb_native_modifiers[i - 1].keyval, state);
      releases++;
    }
  }
  return releases;
}

/* Whether typing `keyval` needs Shift on the current keymap (level 1). */
static int auto_keyval_needs_shift(GdkWindow *window, guint keyval) {
  GdkKeymapKey *keys = NULL;
  gint n_keys = 0;
  int shift = 0;
  GdkKeymap *keymap = gdk_keymap_get_for_display(gdk_window_get_display(window));
  if (gdk_keymap_get_entries_for_keyval(keymap, keyval, &keys, &n_keys) && n_keys > 0) {
    shift = keys[0].level == 1;
  }
  g_free(keys);
  return shift;
}

static void auto_start_native(ZbAutoJob *job) {
  ZbWindow *win = auto_resolve_window(job->requested);
  if (win == NULL) {
    auto_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, g_strdup("no such window"));
    return;
  }
  if (job->op == ZB_OP_NATIVE_CLICK) {
    auto_native_click(job, win);
    return;
  }

  GtkWidget *toplevel = gtk_widget_get_toplevel(GTK_WIDGET(win->view));
  GdkWindow *window = gtk_widget_get_window(toplevel);
  if (window == NULL) {
    auto_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, g_strdup("window not realized"));
    return;
  }
  auto_native_focus(win);

  if (job->op == ZB_OP_NATIVE_KEY) {
    guint keyval = auto_keyval_for(job->body);
    if (keyval == 0) {
      auto_job_complete(job, ZB_AUTO_ERR_INTERNAL, NULL, g_strdup("unknown key"));
      return;
    }
    job->releases = auto_native_press(window, keyval, job->modifiers);
  } else {
    for (const char *p = job->body; *p != '\0'; p = g_utf8_next_char(p)) {
      gunichar ch = g_utf8_get_char(p);
      guint keyval = ch == '\n' ? GDK_KEY_Return : gdk_unicode_to_keyval(ch);
      int shift = keyval != GDK_KEY_Return && auto_keyval_needs_shift(window, keyval);
      /* Pass the lower-case keyval with Shift so the press matches a
       * keyboard; auto_native_press upper-cases it again. */
      job->releases += auto_native_press(window, shift ? gdk_keyval_to_lower(keyval) : keyval,
                                         shift ? ZB_NATIVE_MOD_SHIFT : 0);
    }
  }
  auto_job_complete(job, ZB_AUTO_OK, NULL, NULL);
}

int zb_native_click(ZbWindow *win, double x, double y, int button,
                    unsigned int timeout_ms, char **out_err) {
  ZbAutoJob *job = auto_op_new(ZB_OP_NATIVE_CLICK);
  job->x = x;
  job->y = y;
  job->button = button > 0 ? button : 1;
  int code = auto_run_op(job, win, timeout_ms, NULL, out_err);
  auto_job_unref(job);
  return code;
}

/* Runs a native key/text job and reports how many key releases it sent. */
static int auto_run_native_keys(ZbAutoJob *job, ZbWindow *win, unsigned int timeout_ms,
                                int *out_releases, char **out_err) {
  if (out_releases != NULL) {
    *out_releases = 0;
  }
  int code = auto_run_op(job, win, timeout_ms, NULL, out_err);
  g_mutex_lock(&zb_auto_mutex);
  if (code == ZB_AUTO_OK && out_releases != NULL) {
    *out_releases = job->releases;
  }
  g_mutex_unlock(&zb_auto_mutex);
  auto_job_unref(job);
  return code;
}

int zb_native_key(ZbWindow *win, const char *key, int modifiers,
                  unsigned int timeout_ms, int *out_releases, char **out_err) {
  if (key == NULL || key[0] == '\0') {
    return ZB_AUTO_ERR_INTERNAL;
  }
  ZbAutoJob *job = auto_op_new(ZB_OP_NATIVE_KEY);
  job->body = g_strdup(key);
  job->modifiers = modifiers;
  return auto_run_native_keys(job, win, timeout_ms, out_releases, out_err);
}

/* One small GTK-thread job per character, with the deadline checked between
 * characters: long text can neither overrun the deadline nor hold the GTK
 * thread. On TIMEOUT the text is partially typed; *out_releases counts the
 * releases actually sent. */
int zb_native_text(ZbWindow *win, const char *text, unsigned int timeout_ms,
                   int *out_releases, char **out_err) {
  if (out_releases != NULL) {
    *out_releases = 0;
  }
  if (out_err != NULL) {
    *out_err = NULL;
  }
  if (text == NULL || !g_utf8_validate(text, -1, NULL)) {
    return ZB_AUTO_ERR_INTERNAL;
  }

  gint64 deadline = auto_deadline(timeout_ms);
  int total = 0;
  for (const char *p = text; *p != '\0'; p = g_utf8_next_char(p)) {
    gint64 remaining_us = deadline - g_get_monotonic_time();
    if (remaining_us <= 0) {
      if (out_releases != NULL) {
        *out_releases = total;
      }
      return ZB_AUTO_ERR_TIMEOUT;
    }
    ZbAutoJob *job = auto_op_new(ZB_OP_NATIVE_TEXT);
    job->body = g_strndup(p, (gsize)(g_utf8_next_char(p) - p));
    int releases = 0;
    int code = auto_run_native_keys(job, win, (unsigned int)((remaining_us + 999) / 1000),
                                    &releases, out_err);
    total += releases;
    if (code != ZB_AUTO_OK) {
      if (out_releases != NULL) {
        *out_releases = total;
      }
      return code;
    }
  }
  if (out_releases != NULL) {
    *out_releases = total;
  }
  return ZB_AUTO_OK;
}

int zb_cookies_get_all(ZbWindow *win, const char *url, unsigned int timeout_ms,
                       char **out_json, char **out_err) {
  ZbAutoJob *job = auto_op_new(ZB_OP_COOKIES_GET);
  job->url = g_strdup(url);
  int code = auto_run_op(job, win, timeout_ms, out_json, out_err);
  auto_job_unref(job);
  return code;
}

static SoupSameSitePolicy auto_same_site_policy(int same_site) {
  switch (same_site) {
    case ZB_COOKIE_SAME_SITE_LAX:
      return SOUP_SAME_SITE_POLICY_LAX;
    case ZB_COOKIE_SAME_SITE_STRICT:
      return SOUP_SAME_SITE_POLICY_STRICT;
    default:
      return SOUP_SAME_SITE_POLICY_NONE;
  }
}

int zb_cookies_add(ZbWindow *win, const ZbCookie *cookie, unsigned int timeout_ms,
                   char **out_err) {
  if (out_err != NULL) {
    *out_err = NULL;
  }
  if (cookie == NULL || cookie->name == NULL || cookie->value == NULL ||
      cookie->domain == NULL || cookie->domain[0] == '\0') {
    return ZB_AUTO_ERR_INTERNAL;
  }

  /* GDateTime ends at 9999-12-31T23:59:59Z; never weaken an unrepresentable
   * expiry into a session cookie. */
  if (cookie->expires < -1 || cookie->expires > ZB_COOKIE_MAX_EXPIRES) {
    if (out_err != NULL) {
      *out_err = g_strdup("cookie expiry out of range");
    }
    return ZB_AUTO_ERR_INTERNAL;
  }
  GDateTime *expires = NULL;
  if (cookie->expires >= 0) {
    expires = g_date_time_new_from_unix_utc(cookie->expires);
    if (expires == NULL) {
      if (out_err != NULL) {
        *out_err = g_strdup("cookie expiry out of range");
      }
      return ZB_AUTO_ERR_INTERNAL;
    }
  }

  ZbAutoJob *job = auto_op_new(ZB_OP_COOKIES_ADD);
  job->cookie = soup_cookie_new(cookie->name, cookie->value, cookie->domain,
                                cookie->path != NULL && cookie->path[0] != '\0' ? cookie->path : "/",
                                -1);
  if (expires != NULL) {
    soup_cookie_set_expires(job->cookie, expires);
    g_date_time_unref(expires);
  }
  soup_cookie_set_http_only(job->cookie, cookie->http_only != 0);
  soup_cookie_set_secure(job->cookie, cookie->secure != 0);
  if (cookie->same_site != ZB_COOKIE_SAME_SITE_UNSET) {
    soup_cookie_set_same_site_policy(job->cookie, auto_same_site_policy(cookie->same_site));
  }
  int code = auto_run_op(job, win, timeout_ms, NULL, out_err);
  auto_job_unref(job);
  return code;
}

int zb_cookies_delete(ZbWindow *win, const char *name, const char *domain,
                      unsigned int timeout_ms, char **out_err) {
  if (out_err != NULL) {
    *out_err = NULL;
  }
  if (name == NULL) {
    return ZB_AUTO_ERR_INTERNAL;
  }
  ZbAutoJob *job = auto_op_new(ZB_OP_COOKIES_DELETE);
  job->body = g_strdup(name);
  job->world = g_strdup(domain);
  int code = auto_run_op(job, win, timeout_ms, NULL, out_err);
  auto_job_unref(job);
  return code;
}

static char *zb_profile_dir; /* set before zb_app_run */

int zb_app_set_profile_dir(const char *dir, char **out_err) {
  if (out_err != NULL) {
    *out_err = NULL;
  }
  g_free(zb_profile_dir);
  zb_profile_dir = NULL;
  if (dir == NULL || dir[0] == '\0') {
    return ZB_AUTO_OK;
  }

  /* WebKit needs absolute data directories; relative paths resolve
   * against the current directory. */
  char *absolute = g_canonicalize_filename(dir, NULL);
  if (g_mkdir_with_parents(absolute, 0700) != 0 || g_chmod(absolute, 0700) != 0) {
    int saved = errno;
    if (out_err != NULL) {
      *out_err = g_strdup_printf("cannot create profile directory %s: %s",
                                 absolute, g_strerror(saved));
    }
    g_free(absolute);
    return ZB_AUTO_ERR_INTERNAL;
  }
  zb_profile_dir = absolute;
  return ZB_AUTO_OK;
}

/* The default context, or a new one whose website data, cache and cookies
 * persist under the profile directory. Returns a new reference. */
static WebKitWebContext *app_create_web_context(void) {
  if (zb_profile_dir == NULL) {
    return g_object_ref(webkit_web_context_get_default());
  }

  char *data_dir = g_build_filename(zb_profile_dir, "data", NULL);
  char *cache_dir = g_build_filename(zb_profile_dir, "cache", NULL);
  char *cookie_file = g_build_filename(zb_profile_dir, "cookies.sqlite", NULL);
  WebKitWebsiteDataManager *manager = webkit_website_data_manager_new(
      "base-data-directory", data_dir, "base-cache-directory", cache_dir, NULL);
  WebKitWebContext *context = webkit_web_context_new_with_website_data_manager(manager);
  g_object_unref(manager);
  webkit_cookie_manager_set_persistent_storage(
      webkit_web_context_get_cookie_manager(context), cookie_file,
      WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
  g_free(data_dir);
  g_free(cache_dir);
  g_free(cookie_file);
  return context;
}

static int app_run(const char *uri, int print_title, int e2e_protocol);

/* The loop has ended: every tracked in-flight job completes with NO_LOOP and
 * its WebKit work is cancelled, before teardown terminates web processes
 * (which would otherwise complete some of them with incidental errors). */
static void auto_fail_inflight_on_loop_end(void) {
  for (GList *link = zb_auto_inflight; link != NULL; link = link->next) {
    ZbAutoJob *job = (ZbAutoJob *)link->data;
    if (job->cancellable != NULL) {
      g_cancellable_cancel(job->cancellable);
    }
  }
  while (zb_auto_inflight != NULL) {
    ZbAutoJob *job = (ZbAutoJob *)zb_auto_inflight->data;
    zb_auto_inflight = g_list_delete_link(zb_auto_inflight, zb_auto_inflight);
    job->target = NULL;
    auto_job_complete(job, ZB_AUTO_ERR_NO_LOOP, NULL, g_strdup("main loop ended"));
    auto_job_unref(job);
  }
}

/* After the loop ends and the windows are destroyed (which cancels their
 * in-flight jobs), let WebKit deliver the cancelled callbacks so their job
 * refs are released. Bounded: at most one second. */
static void auto_drain_async(void) {
  gint64 deadline = g_get_monotonic_time() + G_TIME_SPAN_SECOND;
  while (zb_auto_async_pending > 0 && g_get_monotonic_time() < deadline) {
    if (!g_main_context_iteration(NULL, FALSE)) {
      g_usleep(1000);
    }
  }
}

/* Every exit, including early init failures, ends the automation loop so a
 * server thread waiting on a job is released before server shutdown. */
int zb_app_run(const char *uri, int print_title, int e2e_protocol) {
  int code = app_run(uri, print_title, e2e_protocol);
  zb_automation_loop_mark(0);
  return code;
}

static int app_run(const char *uri, int print_title, int e2e_protocol) {
  const char *display = g_getenv("DISPLAY");
  if (display == NULL || display[0] == '\0') {
    fprintf(stderr, "DISPLAY is required (set DISPLAY or run under Xvfb).\n");
    return ZB_EXIT_DISPLAY_UNAVAILABLE;
  }

  if (!gtk_init_check(NULL, NULL)) {
    fprintf(stderr, "gtk_init_check failed for DISPLAY=%s\n", display);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  ZbApp app;
  memset(&app, 0, sizeof(app));
  app.print_title = print_title != 0;
  app.e2e_protocol = e2e_protocol != 0;
  app.exit_code = ZB_EXIT_SUCCESS;
  app.app_base = derive_app_base(uri);

  WebKitWebContext *web_context = app_create_web_context();
  WebKitCookieManager *cookie_mgr =
      webkit_web_context_get_cookie_manager(web_context);
  webkit_cookie_manager_set_accept_policy(
      cookie_mgr, WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS);

  WebKitUserContentManager *ucm = webkit_user_content_manager_new();
  if (ucm == NULL) {
    fprintf(stderr, "failed to create WebKitUserContentManager\n");
    g_object_unref(web_context);
    g_free(app.app_base);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  WebKitWebView *main_view = WEBKIT_WEB_VIEW(
      g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", web_context,
                   "user-content-manager", ucm, NULL));
  g_object_unref(ucm); /* C14.11: constructor retained a reference */
  g_object_unref(web_context); /* the view (and each ZbWindow) holds its own */

  if (main_view == NULL) {
    fprintf(stderr, "failed to create WebKitWebView\n");
    g_free(app.app_base);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  zb_auto_app = &app;
  ZbWindow *main_window = zb_window_new(&app, main_view);
  if (main_window == NULL) {
    zb_auto_app = NULL;
    g_free(app.app_base);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  app.sigint_source_id = g_unix_signal_add(SIGINT, on_signal_int, &app);
  app.sigterm_source_id = g_unix_signal_add(SIGTERM, on_signal_term, &app);
  app.sighup_source_id = g_unix_signal_add(SIGHUP, on_signal_hup, &app);

  webkit_web_view_load_uri(main_window->view, uri);
  zb_automation_loop_mark(1);
  gtk_main();
  zb_automation_loop_mark(0);
  auto_fail_inflight_on_loop_end();

  remove_source(&app.sigint_source_id);
  remove_source(&app.sigterm_source_id);
  remove_source(&app.sighup_source_id);
  remove_source(&app.sigint_deadline_source_id);

  if (app.n_windows > 0) {
    ZbWindow *copy[ZB_MAX_WINDOWS];
    int n = app.n_windows;
    for (int i = 0; i < n; i++) {
      copy[i] = app.windows[i];
    }

    for (int i = 0; i < n; i++) {
      if (copy[i] != NULL && copy[i]->gtk_window != NULL) {
        terminate_window_web_process(copy[i]);
        GtkWidget *w = copy[i]->gtk_window;
        copy[i]->gtk_window = NULL;
        gtk_widget_destroy(w);
      }
    }
  }

  auto_drain_async();
  zb_auto_app = NULL;
  auto_publish_primary(NULL);
  g_free(app.app_base);
  g_free(app.pending_subwindow_seed_uri);
  app.app_base = NULL;
  return app.exit_code;
}

int zb_run_open(const char *uri, int print_title) {
  return zb_app_run(uri, print_title, 0);
}

static void shot_disconnect_signals(ZbShot *shot) {
  if (shot->view != NULL) {
    if (shot->sig_load_changed != 0) {
      g_signal_handler_disconnect(shot->view, shot->sig_load_changed);
      shot->sig_load_changed = 0;
    }
    if (shot->sig_load_failed != 0) {
      g_signal_handler_disconnect(shot->view, shot->sig_load_failed);
      shot->sig_load_failed = 0;
    }
  }

  if (shot->window != NULL && shot->sig_destroy != 0) {
    g_signal_handler_disconnect(shot->window, shot->sig_destroy);
    shot->sig_destroy = 0;
  }
}

static void shot_remove_sources(ZbShot *shot) {
  remove_source(&shot->timeout_source_id);
  remove_source(&shot->sigint_source_id);
  remove_source(&shot->sigterm_source_id);
}

static void shot_cancel_async(ZbShot *shot) {
  if (shot->cancellable != NULL) {
    g_cancellable_cancel(shot->cancellable);
  }
}

static void shot_set_load_error(ZbShot *shot, GError *error) {
  if (error == NULL) {
    return;
  }

  shot->load_error_domain = error->domain;
  shot->load_error_code = error->code;

  g_free(shot->load_error_message);
  shot->load_error_message = g_strdup(error->message != NULL ? error->message : "(unknown)");
}

static void shot_report_load_error(const ZbShot *shot) {
  if (shot->load_error_message != NULL) {
    fprintf(stderr, "load failed: domain=%d code=%d message=%s\n", shot->load_error_domain,
            shot->load_error_code, shot->load_error_message);
  } else {
    fprintf(stderr, "load failed\n");
  }
}

static void shot_print_title(ZbShot *shot) {
  if (!shot->print_title || shot->title_printed) {
    return;
  }

  const char *title = webkit_web_view_get_title(shot->view);
  if (title == NULL) {
    title = "";
  }
  printf("TITLE\t%s\n", title);
  fflush(stdout);
  shot->title_printed = 1;
}

static void shot_start_title_eval(ZbShot *shot,
                                  void (*on_title_ready)(GObject *, GAsyncResult *,
                                                         gpointer)) {
  if (!shot->print_title || shot->title_printed || shot->title_eval_inflight) {
    return;
  }
  shot->title_eval_inflight = 1;
  webkit_web_view_evaluate_javascript(shot->view, "document.title", -1, NULL, NULL,
                                      shot->cancellable, on_title_ready, shot);
}

static int shot_is_success_terminal(const ZbShot *shot) {
  return shot->finished && !shot->failed && !shot->cancelled && !shot->timed_out;
}

static void shot_quit_main_loop(void) {
  if (gtk_main_level() > 0) {
    gtk_main_quit();
  }
}

static int write_snapshot_atomically(cairo_surface_t *surface, const char *out_path) {
  char *dir = g_path_get_dirname(out_path);
  char *base = g_path_get_basename(out_path);
  char *tmp_path = g_strdup_printf("%s/.%s.tmpXXXXXX", dir, base);

  int fd = g_mkstemp(tmp_path);
  if (fd < 0) {
    fprintf(stderr, "failed creating temp file for PNG: %s\n", strerror(errno));
    g_free(tmp_path);
    g_free(base);
    g_free(dir);
    return ZB_EXIT_WRITE_FAILED;
  }
  close(fd);

  cairo_status_t status = cairo_surface_write_to_png(surface, tmp_path);
  if (status != CAIRO_STATUS_SUCCESS) {
    fprintf(stderr, "failed writing PNG: %s\n", cairo_status_to_string(status));
    g_unlink(tmp_path);
    g_free(tmp_path);
    g_free(base);
    g_free(dir);
    return ZB_EXIT_WRITE_FAILED;
  }

  if (g_rename(tmp_path, out_path) != 0) {
    fprintf(stderr, "failed atomic rename to %s: %s\n", out_path, strerror(errno));
    g_unlink(tmp_path);
    g_free(tmp_path);
    g_free(base);
    g_free(dir);
    return ZB_EXIT_WRITE_FAILED;
  }

  g_free(tmp_path);
  g_free(base);
  g_free(dir);
  return ZB_EXIT_SUCCESS;
}

static void shot_resolve_and_close(ZbShot *shot, int exit_code) {
  shot->exit_code = exit_code;
  if (shot->window != NULL) {
    GtkWidget *window = shot->window;
    shot->window = NULL;
    gtk_widget_destroy(window);
    return;
  }
  shot_quit_main_loop();
}

static void shot_teardown(ZbShot *shot) {
  shot_cancel_async(shot);
  shot_remove_sources(shot);
  shot_disconnect_signals(shot);

  if (shot->window != NULL) {
    gtk_widget_destroy(shot->window);
    shot->window = NULL;
  }

  if (shot->cancellable != NULL) {
    g_object_unref(shot->cancellable);
    shot->cancellable = NULL;
  }

  if (shot->context != NULL) {
    g_object_unref(shot->context);
    shot->context = NULL;
  }

  g_free(shot->uri);
  g_free(shot->out_path);
  g_free(shot->load_error_message);
  shot->uri = NULL;
  shot->out_path = NULL;
  shot->load_error_message = NULL;
}

static void on_shot_snapshot_ready(GObject *source, GAsyncResult *result,
                                   gpointer user_data) {
  ZbShot *shot = (ZbShot *)user_data;
  GError *error = NULL;

  cairo_surface_t *surface =
      webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(source), result, &error);
  if (surface == NULL) {
    if (error != NULL) {
      fprintf(stderr, "snapshot failed: %s\n", error->message);
      g_error_free(error);
    } else {
      fprintf(stderr, "snapshot failed\n");
    }
    shot_resolve_and_close(shot, ZB_EXIT_SNAPSHOT_FAILED);
    return;
  }

  int write_code = write_snapshot_atomically(surface, shot->out_path);
  cairo_surface_destroy(surface);

  if (write_code != ZB_EXIT_SUCCESS) {
    shot_resolve_and_close(shot, write_code);
    return;
  }

  shot_resolve_and_close(shot, ZB_EXIT_SUCCESS);
}

static void on_shot_title_ready(GObject *source, GAsyncResult *result,
                                gpointer user_data) {
  ZbShot *shot = (ZbShot *)user_data;
  (void)source;
  GError *error = NULL;
  JSCValue *value = webkit_web_view_evaluate_javascript_finish(shot->view, result, &error);

  shot->title_eval_inflight = 0;

  if (error != NULL) {
    g_error_free(error);
  } else if (value != NULL) {
    char *title_text = jsc_value_to_string(value);
    if (title_text != NULL) {
      printf("TITLE\t%s\n", title_text);
      fflush(stdout);
      shot->title_printed = 1;
      g_free(title_text);
    }
    g_object_unref(value);
  }

  if (shot->print_title && !shot->title_printed) {
    shot_print_title(shot);
  }

  if (shot->snapshot_after_title) {
    shot->snapshot_after_title = 0;
    if (shot_is_success_terminal(shot)) {
      webkit_web_view_get_snapshot(shot->view, WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT,
                                   WEBKIT_SNAPSHOT_OPTIONS_NONE, shot->cancellable,
                                   on_shot_snapshot_ready, shot);
    } else {
      shot_resolve_and_close(shot, shot->timed_out ? ZB_EXIT_TIMEOUT
                                                   : shot->cancelled ? ZB_EXIT_CANCELLED
                                                                     : ZB_EXIT_LOAD_FAILED);
    }
  }
}

static void on_shot_load_changed(WebKitWebView *view, WebKitLoadEvent load_event,
                                 gpointer user_data) {
  (void)view;
  ZbShot *shot = (ZbShot *)user_data;

  if (load_event != WEBKIT_LOAD_FINISHED) {
    return;
  }

  shot->finished = 1;
  if (!shot_is_success_terminal(shot)) {
    if (shot->timed_out) {
      shot_resolve_and_close(shot, ZB_EXIT_TIMEOUT);
      return;
    }
    if (shot->cancelled) {
      shot_resolve_and_close(shot, ZB_EXIT_CANCELLED);
      return;
    }
    if (shot->failed) {
      shot_report_load_error(shot);
      shot_resolve_and_close(shot, ZB_EXIT_LOAD_FAILED);
      return;
    }
    shot_resolve_and_close(shot, ZB_EXIT_LOAD_FAILED);
    return;
  }

  if (shot->print_title) {
    shot_start_title_eval(shot, on_shot_title_ready);
  }

  if (shot->print_title && !shot->title_printed) {
    shot->snapshot_after_title = 1;
    return;
  }

  webkit_web_view_get_snapshot(shot->view, WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT,
                               WEBKIT_SNAPSHOT_OPTIONS_NONE, shot->cancellable,
                               on_shot_snapshot_ready, shot);
}

static gboolean on_shot_load_failed(WebKitWebView *view, WebKitLoadEvent load_event,
                                    const char *uri, GError *error,
                                    gpointer user_data) {
  (void)view;
  (void)load_event;
  (void)uri;

  ZbShot *shot = (ZbShot *)user_data;
  shot->failed = 1;
  shot_set_load_error(shot, error);
  return TRUE;
}

static void on_shot_destroy(GtkWidget *window, gpointer user_data) {
  (void)window;
  ZbShot *shot = (ZbShot *)user_data;

  shot_cancel_async(shot);
  shot_remove_sources(shot);
  shot_disconnect_signals(shot);
  shot->window = NULL;
  shot_quit_main_loop();
}

static gboolean on_shot_timeout(gpointer user_data) {
  ZbShot *shot = (ZbShot *)user_data;

  shot->timed_out = 1;
  shot->exit_code = ZB_EXIT_TIMEOUT;

  shot_cancel_async(shot);
  if (shot->view != NULL) {
    webkit_web_view_stop_loading(shot->view);
  }

  if (shot->window != NULL) {
    GtkWidget *window = shot->window;
    shot->window = NULL;
    gtk_widget_destroy(window);
  }

  return G_SOURCE_REMOVE;
}

static gboolean on_shot_signal(gpointer user_data) {
  ZbShot *shot = (ZbShot *)user_data;

  shot->cancelled = 1;
  shot->exit_code = ZB_EXIT_CANCELLED;

  shot_cancel_async(shot);
  if (shot->view != NULL) {
    webkit_web_view_stop_loading(shot->view);
  }

  if (shot->window != NULL) {
    GtkWidget *window = shot->window;
    shot->window = NULL;
    gtk_widget_destroy(window);
  } else {
    shot_quit_main_loop();
  }

  return G_SOURCE_REMOVE;
}

static int run_screenshot_internal(const char *uri, const char *out_path,
                                   int print_title) {
  const char *display = g_getenv("DISPLAY");
  if (display == NULL || display[0] == '\0') {
    fprintf(stderr, "DISPLAY is required (set DISPLAY or run under Xvfb).\n");
    return ZB_EXIT_DISPLAY_UNAVAILABLE;
  }

  if (!gtk_init_check(NULL, NULL)) {
    fprintf(stderr, "gtk_init_check failed for DISPLAY=%s\n", display);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  ZbShot shot;
  memset(&shot, 0, sizeof(shot));
  shot.uri = g_strdup(uri);
  shot.out_path = out_path != NULL ? g_strdup(out_path) : NULL;
  shot.print_title = print_title;
  shot.exit_code = ZB_EXIT_SUCCESS;

  shot.context = webkit_web_context_new();
  if (shot.context == NULL) {
    fprintf(stderr, "failed to create WebKitWebContext\n");
    shot_teardown(&shot);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  WebKitCookieManager *shot_cookie_mgr =
      webkit_web_context_get_cookie_manager(shot.context);
  webkit_cookie_manager_set_accept_policy(
      shot_cookie_mgr, WEBKIT_COOKIE_POLICY_ACCEPT_ALWAYS);

  shot.view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(shot.context));
  WebKitSettings *shot_settings = webkit_web_view_get_settings(shot.view);
  if (shot_settings != NULL) {
    webkit_settings_set_hardware_acceleration_policy(
        shot_settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);
  }

  shot.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(shot.window), 1024, 768);
  gtk_window_set_title(GTK_WINDOW(shot.window), "zigBrowser");
  gtk_container_add(GTK_CONTAINER(shot.window), GTK_WIDGET(shot.view));

  shot.cancellable = g_cancellable_new();
  shot.sig_load_changed =
      g_signal_connect_data(shot.view, "load-changed", G_CALLBACK(on_shot_load_changed),
                            &shot, NULL, 0);
  shot.sig_load_failed =
      g_signal_connect_data(shot.view, "load-failed", G_CALLBACK(on_shot_load_failed),
                            &shot, NULL, 0);
  shot.sig_destroy = g_signal_connect_data(shot.window, "destroy",
                                           G_CALLBACK(on_shot_destroy), &shot,
                                           NULL, 0);

  shot.timeout_source_id = g_timeout_add(15000, on_shot_timeout, &shot);
  shot.sigint_source_id = g_unix_signal_add(SIGINT, on_shot_signal, &shot);
  shot.sigterm_source_id = g_unix_signal_add(SIGTERM, on_shot_signal, &shot);

  gtk_widget_show_all(shot.window);
  webkit_web_view_load_uri(shot.view, shot.uri);

  gtk_main();

  const int rc = shot.exit_code;
  shot_teardown(&shot);
  return rc;
}

int zb_run_screenshot(const char *uri, const char *out_path, int print_title) {
  return run_screenshot_internal(uri, out_path, print_title);
}

void zb_version_line(char *buf, size_t len) {
  if (buf == NULL || len == 0) {
    return;
  }

  g_snprintf(buf, len, "zigBrowser — WebKitGTK %u.%u.%u, GTK %u.%u.%u",
             webkit_get_major_version(), webkit_get_minor_version(),
             webkit_get_micro_version(), gtk_get_major_version(),
             gtk_get_minor_version(), gtk_get_micro_version());
}
