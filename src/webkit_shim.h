#ifndef ZB_WEBKIT_SHIM_H
#define ZB_WEBKIT_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct _GtkWidget GtkWidget;
typedef struct _WebKitWebView WebKitWebView;
typedef struct _WebKitWebContext WebKitWebContext;
typedef struct _WebKitUserContentManager WebKitUserContentManager;
typedef struct _WebKitScriptMessageReply WebKitScriptMessageReply;

#define ZB_MAX_WINDOWS 16

typedef struct ZbApp ZbApp;
typedef struct ZbWindow ZbWindow;

enum {
  ZB_EXIT_SUCCESS = 0,
  ZB_EXIT_USAGE = 1,
  ZB_EXIT_INVALID_URI = 2,
  ZB_EXIT_DISPLAY_UNAVAILABLE = 3,
  ZB_EXIT_GTK_INIT_FAILED = 4,
  ZB_EXIT_LOAD_FAILED = 5,
  ZB_EXIT_SNAPSHOT_FAILED = 6,
  ZB_EXIT_WRITE_FAILED = 7,
  ZB_EXIT_TIMEOUT = 8,
  ZB_EXIT_CANCELLED = 130,
};

int zb_run_open(const char *uri, int print_title);
int zb_app_run(const char *uri, int print_title, int e2e_protocol);
int zb_run_screenshot(const char *uri, const char *out_path, int print_title);
void zb_version_line(char *buf, size_t len);

void zb_reload(ZbWindow *win, int bypass_cache);
ZbWindow *zb_window_new(ZbApp *app, WebKitWebView *view);

/* Track-B owned exports; if unavailable at link/runtime the shim fails closed. */
int zb_policy_decide(const char *base, const char *candidate, int dtype);
int zb_ipc_dispatch(const char *cmd, const char *args_json, const char **out_result,
                    const char **out_err);

#ifdef __cplusplus
}
#endif

#endif
