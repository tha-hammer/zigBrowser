#ifndef ZB_WEBKIT_SHIM_H
#define ZB_WEBKIT_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

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
  ZB_EXIT_RUNTIME_MISSING = 9,
  ZB_EXIT_WEBVIEW_INIT_FAILED = 10,
  ZB_EXIT_CANCELLED = 130,
};

int zb_run_open(const char *uri, int print_title);
int zb_app_run(const char *uri, int print_title, int e2e_protocol);
int zb_run_screenshot(const char *uri, const char *out_path, int print_title);
void zb_version_line(char *buf, size_t len);

void zb_reload(ZbWindow *win, int bypass_cache);
ZbWindow *zb_window_new(ZbApp *app, void *native_view);

/* --- Automation bridge: server thread -> GTK main thread ---
 *
 * Blocking calls made from a non-GTK thread (the automation server thread).
 * Each call returns exactly one ZB_AUTO_* code. */
enum {
  ZB_AUTO_OK = 0,
  ZB_AUTO_ERR_TIMEOUT = 1,    /* deadline passed; job never ran or result abandoned */
  ZB_AUTO_ERR_NO_WINDOW = 2,  /* window not registered / not alive */
  ZB_AUTO_ERR_JS = 3,         /* JS threw or promise rejected; *out_err = message */
  ZB_AUTO_ERR_NAV_FAILED = 4, /* load-failed; *out_err = message */
  ZB_AUTO_ERR_NO_LOOP = 5,    /* GTK main loop has ended */
  ZB_AUTO_ERR_INTERNAL = 6,   /* bad args, or async op called on the GTK thread */
  ZB_AUTO_ERR_CANCELLED = 7,  /* window destroyed while the job was in flight */
};

typedef void (*ZbMainJobFn)(void *ctx);

/* Run fn(ctx) on the thread that owns the default GMainContext and block until it
 * returns. If the deadline passes before fn starts, fn is never run and ctx is
 * never touched again (ZB_AUTO_ERR_TIMEOUT). Once fn has started it runs to
 * completion and the call waits for it. Called on the owning thread, fn runs
 * inline. */
int zb_main_invoke_sync(ZbMainJobFn fn, void *ctx, unsigned int timeout_ms);

/* Loop lifecycle, driven by zb_app_run around gtk_main(): 1 = running, 0 = ended.
 * Ending wakes every waiter with ZB_AUTO_ERR_NO_LOOP. Before the first mark,
 * submissions queue and wait (the server starts before zb_app_run). */
void zb_automation_loop_mark(int running);

/* Track-B owned exports; hard-linked into the Zig binary. */
int zb_policy_decide(const char *base, const char *candidate, int dtype);
int zb_ipc_dispatch(const char *cmd, const char *args_json, const char **out_result,
                    const char **out_err);

#ifdef __cplusplus
}
#endif

#endif
