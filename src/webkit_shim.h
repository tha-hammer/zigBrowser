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
 * parents; a relative path resolves against the current directory) and makes the main window and its children use a WebKitWebContext
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
/* The index-th live window in creation order (0 = primary), or NULL. Same
 * snapshot semantics as zb_automation_main_window. */
ZbWindow *zb_automation_window_at(int index);

/* Ops below: win == NULL targets the primary window and waits for it to exist
 * until the deadline (ZB_AUTO_ERR_NO_WINDOW); an explicit window that is not
 * alive is ZB_AUTO_ERR_NO_WINDOW at once. Every op except navigate (and the
 * cookie ops) also waits until the target window's own first load has
 * finished or failed
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

/* --- Cookie store (the primary window's context, i.e. the profile) ---
 * Same blocking/threading/ownership rules as the ops above; they wait for the
 * primary window but not for its first load. Error text never contains
 * cookie values. */
enum {
  ZB_COOKIE_SAME_SITE_UNSET = 0,
  ZB_COOKIE_SAME_SITE_NONE = 1,
  ZB_COOKIE_SAME_SITE_LAX = 2,
  ZB_COOKIE_SAME_SITE_STRICT = 3,
};

/* Latest representable expiry (9999-12-31T23:59:59Z). */
#define ZB_COOKIE_MAX_EXPIRES 253402300799LL

typedef struct {
  const char *name;
  const char *value;
  const char *domain; /* "host" = host-only, ".host" = domain cookie */
  const char *path;
  long long expires;  /* unix seconds; -1 = session cookie */
  int http_only;
  int secure;
  int same_site;      /* ZB_COOKIE_SAME_SITE_* */
} ZbCookie;

/* *out_json: JSON array of {name, value, domain, path, expires, httpOnly,
 * secure, sameSite}. url NULL = every cookie in the store, else the cookies
 * that would be sent to `url`. */
int zb_cookies_get_all(ZbWindow *win, const char *url, unsigned int timeout_ms,
                       char **out_json, char **out_err);
/* Adds or replaces the cookie (all fields are copied before queuing).
 * expires outside [-1, ZB_COOKIE_MAX_EXPIRES] is ZB_AUTO_ERR_INTERNAL. */
int zb_cookies_add(ZbWindow *win, const ZbCookie *cookie, unsigned int timeout_ms,
                   char **out_err);
/* Deletes every cookie called `name` on `domain` (leading dot ignored);
 * domain NULL = on every domain. Deleting nothing is not an error. */
int zb_cookies_delete(ZbWindow *win, const char *name, const char *domain,
                      unsigned int timeout_ms, char **out_err);

/* --- Native (trusted) input ---
 * Real GDK events delivered to the window's WebKitWebView on the GTK thread,
 * so the page sees isTrusted === true. Coordinates are view (CSS viewport)
 * pixels. Ops wait for the primary window's first load like the page ops.
 * They return once the events are handed to WebKit, which delivers them to
 * the page asynchronously (mouse and key queues are not ordered against each
 * other); callers that need ordering wait for the page to see them, e.g. via
 * __zbAutomation.inputAck(). */
enum {
  ZB_NATIVE_MOD_SHIFT = 1,
  ZB_NATIVE_MOD_CONTROL = 2,
  ZB_NATIVE_MOD_ALT = 4,
  ZB_NATIVE_MOD_META = 8,
};

/* Pointer motion to (x, y), then press and release of `button` (1 = left). */
int zb_native_click(ZbWindow *win, double x, double y, int button,
                    unsigned int timeout_ms, char **out_err);
/* Press and release one key: `key` is a DOM key name ("Enter", "Tab",
 * "ArrowLeft", "a", ...); `modifiers` (ZB_NATIVE_MOD_*) are pressed before
 * the key and released after it. ZB_AUTO_ERR_INTERNAL for unknown keys.
 * *out_releases (optional) receives the number of key releases sent, so a
 * caller can wait for that many keyup events to reach the page. */
int zb_native_key(ZbWindow *win, const char *key, int modifiers,
                  unsigned int timeout_ms, int *out_releases, char **out_err);
/* Press and release a key for each character of UTF-8 `text` (Shift added
 * where the keymap needs it; '\n' is Return). Each character is its own
 * GTK-thread step and the deadline is checked between them: on TIMEOUT the
 * text is partially typed and *out_releases counts what was sent. */
int zb_native_text(ZbWindow *win, const char *text, unsigned int timeout_ms,
                   int *out_releases, char **out_err);

/* Diagnostics: bridge jobs currently allocated (0 once all work is released). */
int zb_automation_debug_live_jobs(void);
/* Test hook: hold every started cookie operation for `ms` before it reaches
 * WebKit, so a test can make a job time out while in flight (0 = off). */
void zb_automation_debug_cookie_delay(unsigned int ms);

/* Track-B owned exports; hard-linked into the Zig binary. */
int zb_policy_decide(const char *base, const char *candidate, int dtype);
int zb_ipc_dispatch(const char *cmd, const char *args_json, const char **out_result,
                    const char **out_err);

#ifdef __cplusplus
}
#endif

#endif
