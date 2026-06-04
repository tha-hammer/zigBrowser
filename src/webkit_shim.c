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
  }

  if (win->ucm != NULL) {
    g_signal_handlers_disconnect_by_data(win->ucm, win);
  }

  win->gtk_window = NULL;
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

  if (win->load_superseded && is_cancelled_network_error(error)) {
    return TRUE;
  }

  win->failed = 1;
  win->suppress_success_emit = 1;
  window_set_load_error(win, error);

  emit_load_fail(win, uri, win->load_error_domain, win->load_error_code);
  return FALSE;
}

static void on_window_load_changed(WebKitWebView *view,
                                   WebKitLoadEvent load_event,
                                   gpointer user_data) {
  ZbWindow *win = (ZbWindow *)user_data;
  if (win == NULL) {
    return;
  }

  switch (load_event) {
    case WEBKIT_LOAD_STARTED:
      window_reset_load_state(win);
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
  win->sig_destroy = g_signal_connect_data(win->gtk_window, "destroy",
                                           G_CALLBACK(on_window_destroy), win,
                                           NULL, 0);

  install_ipc_handler(win);

  app->windows[app->n_windows++] = win;
  app_emit_wincount(app);
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

int zb_app_run(const char *uri, int print_title, int e2e_protocol) {
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

  WebKitUserContentManager *ucm = webkit_user_content_manager_new();
  if (ucm == NULL) {
    fprintf(stderr, "failed to create WebKitUserContentManager\n");
    g_free(app.app_base);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  WebKitWebView *main_view =
      WEBKIT_WEB_VIEW(webkit_web_view_new_with_user_content_manager(ucm));
  g_object_unref(ucm); /* C14.11: constructor retained a reference */

  if (main_view == NULL) {
    fprintf(stderr, "failed to create WebKitWebView\n");
    g_free(app.app_base);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  ZbWindow *main_window = zb_window_new(&app, main_view);
  if (main_window == NULL) {
    g_free(app.app_base);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  app.sigint_source_id = g_unix_signal_add(SIGINT, on_signal_int, &app);
  app.sigterm_source_id = g_unix_signal_add(SIGTERM, on_signal_term, &app);
  app.sighup_source_id = g_unix_signal_add(SIGHUP, on_signal_hup, &app);

  webkit_web_view_load_uri(main_window->view, uri);
  gtk_main();

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

  shot.view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(shot.context));
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
