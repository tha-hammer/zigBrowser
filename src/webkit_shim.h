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

/* Persistent profile. Call before zb_app_run. Creates `dir` (0700, with
 * parents) and makes the main window and its children use a WebKitWebContext
 * whose website data lives in <dir>/data, cache in <dir>/cache, and cookies in
 * <dir>/cookies.sqlite. NULL or "" restores the default context. Returns
 * ZB_AUTO_OK, or ZB_AUTO_ERR_INTERNAL with *out_err set (free with
 * zb_automation_free) when the directory cannot be created. */
int zb_app_set_profile_dir(const char *dir, char **out_err);

/* Isolated script world shared by the injected automation script and evals. */
#define ZB_AUTOMATION_WORLD "zigbrowser-automation"

/* Install `source` (automation.js) at document start, top frame, in
 * ZB_AUTOMATION_WORLD, for the main window and every child window. Call before
 * zb_app_run. The source is copied; NULL disables injection. */
void zb_automation_set_script(const char *source, size_t len);

/* Primary window (the first live window), or NULL before zb_app_run creates it
 * and after the last window closes. Thread-safe snapshot; the ops below
 * re-validate the pointer on the GTK thread. */
ZbWindow *zb_automation_main_window(void);

/* Ops below: win == NULL targets the primary window and waits for it to exist
 * until the deadline (ZB_AUTO_ERR_NO_WINDOW). Every op except navigate also
 * waits until the primary window's first load has finished or failed
 * (ZB_AUTO_ERR_TIMEOUT), so commands sent during startup see the start page.
 * On timeout, an in-flight eval is cancelled and a navigate/reload stops its
 * own load (never a newer one). Every input string is copied
 * before the call queues work. *out_* strings are heap-allocated by the shim
 * (free with zb_automation_free) and are set only when the call says so.
 * *out_err is diagnostic text and may contain page data. */

/* Run `function_body` as the body of an async JS function in `world`
 * (NULL = page world) and wait for its promise. The function sees one
 * variable, `arg`, holding the string `arg_json` (NULL -> "null"); command
 * data must travel through `arg`, never through the body. On ZB_AUTO_OK
 * *out_result is the returned string verbatim, or the JSON encoding of a
 * non-string value ("null" for undefined). ZB_AUTO_ERR_JS sets *out_err. */
int zb_automation_eval_json(ZbWindow *win, const char *function_body,
                            const char *arg_json, const char *world,
                            unsigned int timeout_ms, char **out_result,
                            char **out_err);

/* Load `url` and wait for its load to finish. A load error or a navigation
 * blocked by policy returns ZB_AUTO_ERR_NAV_FAILED and sets *out_err. */
int zb_automation_navigate(ZbWindow *win, const char *url, unsigned int timeout_ms,
                           char **out_err);
int zb_automation_reload(ZbWindow *win, unsigned int timeout_ms, char **out_err);

/* Current URI (WebKit's committed URI) / document.title; "" when none. */
int zb_automation_get_url(ZbWindow *win, unsigned int timeout_ms, char **out_url);
int zb_automation_get_title(ZbWindow *win, unsigned int timeout_ms, char **out_title);

void zb_automation_free(char *p);

/* Diagnostics: bridge jobs currently allocated (0 once all work is released). */
int zb_automation_debug_live_jobs(void);

/* Track-B owned exports; hard-linked into the Zig binary. */
int zb_policy_decide(const char *base, const char *candidate, int dtype);
int zb_ipc_dispatch(const char *cmd, const char *args_json, const char **out_result,
                    const char **out_err);

#ifdef __cplusplus
}
#endif

#endif
