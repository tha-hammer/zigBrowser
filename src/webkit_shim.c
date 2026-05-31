#include "webkit_shim.h"

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <glib-unix.h>
#include <glib/gstdio.h>
#include <unistd.h>

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>

typedef struct {
  GtkWidget *window;
  WebKitWebView *view;
  WebKitWebContext *context;

  char *uri;
  char *out_path;
  int want_screenshot;
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
} ZbPage;

static void on_load_changed(WebKitWebView *view, WebKitLoadEvent load_event, gpointer user_data);
static gboolean on_load_failed(WebKitWebView *view, WebKitLoadEvent load_event, const char *uri,
                               GError *error, gpointer user_data);
static void on_snapshot_ready(GObject *source, GAsyncResult *result, gpointer user_data);
static void on_destroy(GtkWidget *window, gpointer user_data);
static gboolean on_timeout(gpointer user_data);
static gboolean on_unix_signal(gpointer user_data);
static void on_title_ready(GObject *source, GAsyncResult *result, gpointer user_data);

static void page_disconnect_signals(ZbPage *page) {
  if (page->view != NULL) {
    if (page->sig_load_changed != 0) {
      g_signal_handler_disconnect(page->view, page->sig_load_changed);
      page->sig_load_changed = 0;
    }
    if (page->sig_load_failed != 0) {
      g_signal_handler_disconnect(page->view, page->sig_load_failed);
      page->sig_load_failed = 0;
    }
  }

  if (page->window != NULL && page->sig_destroy != 0) {
    g_signal_handler_disconnect(page->window, page->sig_destroy);
    page->sig_destroy = 0;
  }
}

static void page_remove_sources(ZbPage *page) {
  if (page->timeout_source_id != 0) {
    g_source_remove(page->timeout_source_id);
    page->timeout_source_id = 0;
  }
  if (page->sigint_source_id != 0) {
    g_source_remove(page->sigint_source_id);
    page->sigint_source_id = 0;
  }
  if (page->sigterm_source_id != 0) {
    g_source_remove(page->sigterm_source_id);
    page->sigterm_source_id = 0;
  }
}

static void page_cancel_async(ZbPage *page) {
  if (page->cancellable != NULL) {
    g_cancellable_cancel(page->cancellable);
  }
}

static void page_set_load_error(ZbPage *page, GError *error) {
  if (error == NULL) {
    return;
  }

  page->load_error_domain = error->domain;
  page->load_error_code = error->code;

  g_free(page->load_error_message);
  page->load_error_message = g_strdup(error->message != NULL ? error->message : "(unknown)");
}

static void page_report_load_error(const ZbPage *page) {
  if (page->load_error_message != NULL) {
    fprintf(stderr, "load failed: domain=%d code=%d message=%s\n", page->load_error_domain,
            page->load_error_code, page->load_error_message);
  } else {
    fprintf(stderr, "load failed\n");
  }
}

static void page_print_title(ZbPage *page) {
  if (!page->print_title || page->title_printed) {
    return;
  }

  const char *title = webkit_web_view_get_title(page->view);
  if (title == NULL) {
    title = "";
  }
  printf("TITLE\t%s\n", title);
  fflush(stdout);
  page->title_printed = 1;
}

static void page_start_title_eval(ZbPage *page) {
  if (!page->print_title || page->title_printed || page->title_eval_inflight) {
    return;
  }
  page->title_eval_inflight = 1;
  webkit_web_view_evaluate_javascript(page->view, "document.title", -1, NULL, NULL,
                                      page->cancellable, on_title_ready, page);
}

static int page_is_success_terminal(const ZbPage *page) {
  return page->finished && !page->failed && !page->cancelled && !page->timed_out;
}

static void page_quit_main_loop(void) {
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

static void page_start_snapshot(ZbPage *page) {
  webkit_web_view_get_snapshot(page->view, WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT,
                               WEBKIT_SNAPSHOT_OPTIONS_NONE, page->cancellable,
                               on_snapshot_ready, page);
}

static void page_resolve_and_close(ZbPage *page, int exit_code) {
  page->exit_code = exit_code;
  if (page->window != NULL) {
    GtkWidget *window = page->window;
    page->window = NULL;
    gtk_widget_destroy(window);
    return;
  }
  page_quit_main_loop();
}

static void page_teardown(ZbPage *page) {
  page_cancel_async(page);
  page_remove_sources(page);
  page_disconnect_signals(page);

  if (page->window != NULL) {
    gtk_widget_destroy(page->window);
    page->window = NULL;
  }

  if (page->cancellable != NULL) {
    g_object_unref(page->cancellable);
    page->cancellable = NULL;
  }

  if (page->context != NULL) {
    g_object_unref(page->context);
    page->context = NULL;
  }

  g_free(page->uri);
  page->uri = NULL;

  g_free(page->out_path);
  page->out_path = NULL;

  g_free(page->load_error_message);
  page->load_error_message = NULL;
}

static int run_with_webkit(const char *uri, const char *out_path, int print_title, int want_screenshot) {
  const char *display = g_getenv("DISPLAY");
  if (display == NULL || display[0] == '\0') {
    fprintf(stderr, "DISPLAY is required (set DISPLAY or run under Xvfb).\n");
    return ZB_EXIT_DISPLAY_UNAVAILABLE;
  }

  if (!gtk_init_check(NULL, NULL)) {
    fprintf(stderr, "gtk_init_check failed for DISPLAY=%s\n", display);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  ZbPage page;
  memset(&page, 0, sizeof(page));

  page.uri = g_strdup(uri);
  page.out_path = out_path != NULL ? g_strdup(out_path) : NULL;
  page.want_screenshot = want_screenshot;
  page.print_title = print_title;
  page.exit_code = ZB_EXIT_SUCCESS;

  page.context = webkit_web_context_new();
  if (page.context == NULL) {
    fprintf(stderr, "failed to create WebKitWebContext\n");
    page_teardown(&page);
    return ZB_EXIT_GTK_INIT_FAILED;
  }

  page.view = WEBKIT_WEB_VIEW(webkit_web_view_new_with_context(page.context));
  page.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(page.window), 1024, 768);
  gtk_window_set_title(GTK_WINDOW(page.window), "zigBrowser");
  gtk_container_add(GTK_CONTAINER(page.window), GTK_WIDGET(page.view));

  page.cancellable = g_cancellable_new();

  page.sig_load_changed = g_signal_connect_data(page.view, "load-changed",
                                                G_CALLBACK(on_load_changed), &page, NULL, 0);
  page.sig_load_failed = g_signal_connect_data(page.view, "load-failed",
                                               G_CALLBACK(on_load_failed), &page, NULL, 0);
  page.sig_destroy = g_signal_connect_data(page.window, "destroy", G_CALLBACK(on_destroy),
                                           &page, NULL, 0);

  page.timeout_source_id = g_timeout_add(15000, on_timeout, &page);
  page.sigint_source_id = g_unix_signal_add(SIGINT, on_unix_signal, &page);
  page.sigterm_source_id = g_unix_signal_add(SIGTERM, on_unix_signal, &page);

  gtk_widget_show_all(page.window);
  webkit_web_view_load_uri(page.view, page.uri);

  gtk_main();

  const int result = page.exit_code;
  page_teardown(&page);
  return result;
}

static void on_load_changed(WebKitWebView *view, WebKitLoadEvent load_event, gpointer user_data) {
  (void)view;
  ZbPage *page = (ZbPage *)user_data;

  if (load_event != WEBKIT_LOAD_FINISHED) {
    return;
  }

  page->finished = 1;
  if (page->want_screenshot && !page->failed) {
    WebKitWebResource *main_res = webkit_web_view_get_main_resource(page->view);
    WebKitURIResponse *response = main_res != NULL ? webkit_web_resource_get_response(main_res) : NULL;
    if (response == NULL) {
      page->failed = 1;
      if (page->load_error_message == NULL) {
        page->load_error_message = g_strdup("main resource response missing at FINISHED");
      }
    }
  }

  if (!page_is_success_terminal(page)) {
    if (page->timed_out) {
      page_resolve_and_close(page, ZB_EXIT_TIMEOUT);
      return;
    }
    if (page->cancelled) {
      page_resolve_and_close(page, ZB_EXIT_CANCELLED);
      return;
    }
    if (page->failed) {
      page_report_load_error(page);
      page_resolve_and_close(page, ZB_EXIT_LOAD_FAILED);
      return;
    }
    page_resolve_and_close(page, ZB_EXIT_LOAD_FAILED);
    return;
  }

  if (page->print_title) {
    page_start_title_eval(page);
  }

  if (page->want_screenshot) {
    if (page->print_title && !page->title_printed) {
      page->snapshot_after_title = 1;
      return;
    }
    page_start_snapshot(page);
    return;
  }

  if (page->timeout_source_id != 0) {
    g_source_remove(page->timeout_source_id);
    page->timeout_source_id = 0;
  }
  page->exit_code = ZB_EXIT_SUCCESS;
}

static gboolean on_load_failed(WebKitWebView *view, WebKitLoadEvent load_event, const char *uri,
                               GError *error, gpointer user_data) {
  (void)view;
  (void)load_event;
  (void)uri;

  ZbPage *page = (ZbPage *)user_data;
  page->failed = 1;
  page_set_load_error(page, error);

  if (page->want_screenshot) {
    return TRUE;
  }

  return FALSE;
}

static void on_snapshot_ready(GObject *source, GAsyncResult *result, gpointer user_data) {
  ZbPage *page = (ZbPage *)user_data;
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
    page_resolve_and_close(page, ZB_EXIT_SNAPSHOT_FAILED);
    return;
  }

  int write_code = write_snapshot_atomically(surface, page->out_path);
  cairo_surface_destroy(surface);

  if (write_code != ZB_EXIT_SUCCESS) {
    page_resolve_and_close(page, write_code);
    return;
  }

  page_resolve_and_close(page, ZB_EXIT_SUCCESS);
}

static void on_destroy(GtkWidget *window, gpointer user_data) {
  (void)window;
  ZbPage *page = (ZbPage *)user_data;

  if (page->finished && !page->failed && !page->timed_out && !page->cancelled &&
      page->exit_code == ZB_EXIT_SUCCESS) {
    page->exit_code = ZB_EXIT_SUCCESS;
  }

  page_cancel_async(page);
  page_remove_sources(page);
  page_disconnect_signals(page);
  page->window = NULL;
  page_quit_main_loop();
}

static gboolean on_timeout(gpointer user_data) {
  ZbPage *page = (ZbPage *)user_data;

  page->timed_out = 1;
  page->exit_code = ZB_EXIT_TIMEOUT;

  page_cancel_async(page);
  if (page->view != NULL) {
    webkit_web_view_stop_loading(page->view);
  }

  if (page->window != NULL) {
    GtkWidget *window = page->window;
    page->window = NULL;
    gtk_widget_destroy(window);
  }

  return G_SOURCE_REMOVE;
}

static gboolean on_unix_signal(gpointer user_data) {
  ZbPage *page = (ZbPage *)user_data;

  page->cancelled = 1;
  page->exit_code = ZB_EXIT_CANCELLED;

  page_cancel_async(page);
  if (page->view != NULL) {
    webkit_web_view_stop_loading(page->view);
  }

  if (page->window != NULL) {
    GtkWidget *window = page->window;
    page->window = NULL;
    gtk_widget_destroy(window);
  } else {
    page_quit_main_loop();
  }

  return G_SOURCE_REMOVE;
}

static void on_title_ready(GObject *source, GAsyncResult *result, gpointer user_data) {
  ZbPage *page = (ZbPage *)user_data;
  (void)source;
  GError *error = NULL;
  JSCValue *value = webkit_web_view_evaluate_javascript_finish(page->view, result, &error);

  page->title_eval_inflight = 0;

  if (error != NULL) {
    g_error_free(error);
  } else if (value != NULL) {
    char *title_text = jsc_value_to_string(value);
    if (title_text != NULL) {
      printf("TITLE\t%s\n", title_text);
      fflush(stdout);
      page->title_printed = 1;
      g_free(title_text);
    }
    g_object_unref(value);
  }

  if (page->print_title && !page->title_printed) {
    page_print_title(page);
  }

  if (page->snapshot_after_title) {
    page->snapshot_after_title = 0;
    if (page_is_success_terminal(page)) {
      page_start_snapshot(page);
    } else {
      page_resolve_and_close(page, page->timed_out ? ZB_EXIT_TIMEOUT
                                                   : page->cancelled ? ZB_EXIT_CANCELLED
                                                                     : ZB_EXIT_LOAD_FAILED);
    }
  }
}

int zb_run_open(const char *uri, int print_title) {
  return run_with_webkit(uri, NULL, print_title, 0);
}

int zb_run_screenshot(const char *uri, const char *out_path, int print_title) {
  return run_with_webkit(uri, out_path, print_title, 1);
}

void zb_version_line(char *buf, size_t len) {
  if (buf == NULL || len == 0) {
    return;
  }

  g_snprintf(buf, len, "zigBrowser — WebKitGTK %u.%u.%u, GTK %u.%u.%u",
             webkit_get_major_version(), webkit_get_minor_version(), webkit_get_micro_version(),
             gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version());
}
