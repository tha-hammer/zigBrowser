#ifndef ZB_WEBKIT_SHIM_H
#define ZB_WEBKIT_SHIM_H

#include <stddef.h>
#include <stdint.h>

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
  ZB_AUTO_ERR_DOC_CHANGED = 8, /* native input: the page is no longer the expected document */
  ZB_AUTO_ERR_BAD_FILE = 9,    /* set files: a path is not a readable regular file, or too many */
  ZB_AUTO_ERR_FILES_UNCONFIRMED = 10, /* set files: chosen, but the page did not confirm in time */
  ZB_AUTO_ERR_TOO_LARGE = 11,  /* screenshot: the encoded PNG exceeds the limit */
  ZB_AUTO_ERR_DIALOG_OPEN = 12, /* a page dialog is open on the window (see zb_automation_list_dialogs) */
  ZB_AUTO_ERR_NO_DIALOG = 13,   /* respond: the window has no open dialog */
  ZB_AUTO_ERR_DIALOG_DISMISSED = 14, /* navigate: the beforeunload prompt was dismissed; the page stays */
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

/* WebKit hardware-acceleration policy for every window (and the
 * screenshot view) created from now on: ZB_HW_POLICY_WEBKIT (the default:
 * leave WebKit's own choice), _NEVER or _ALWAYS. Call before zb_app_run
 * or zb_run_screenshot. The getter returns the current setting. */
#define ZB_HW_POLICY_NEVER 0
#define ZB_HW_POLICY_ALWAYS 1
#define ZB_HW_POLICY_WEBKIT 2
void zb_app_set_hw_policy(int policy);
int zb_app_get_hw_policy(void);

/* Test hook: the hardware-acceleration policy WebKit holds for window
 * `id`, as ZB_HW_POLICY_NEVER or _ALWAYS (ZB_HW_POLICY_ON_DEMAND for
 * WebKit's deprecated on-demand), -1 without that window or loop. */
#define ZB_HW_POLICY_ON_DEMAND 3
int zb_automation_debug_hw_policy(unsigned int id, unsigned int timeout_ms);
/* Test hook: the policy a fresh WebKitSettings holds (WebKit's own
 * default), in the same codes; -1 without the loop. */
int zb_automation_debug_webkit_default_hw_policy(unsigned int timeout_ms);

/* How long WebKit must keep a window's web process unresponsive before
 * stderr says "zigBrowser: window N: page not responding for Ns" (once,
 * then "page responding again" once when it answers). page.health uses the
 * same debounce (health_debounce_ms in automation_server.zig). */
#define ZB_UNRESPONSIVE_DEBOUNCE_MS 2000

/* Media Source Extensions for every window, popups included, and the
 * screenshot view created from now on: 1 on (the default), 0 off. Off sets
 * WebKitSettings "enable-mediasource" FALSE and, because WebKitGTK 2.54
 * ignores that setting, hides the MSE constructors from page script in
 * every frame. Call before zb_app_run or zb_run_screenshot. The getter
 * returns the current setting. */
void zb_app_set_media_source(int enabled);
int zb_app_get_media_source(void);

/* The Claude Agent drawer (src/agent_drawer.c): 1 gives every browsing
 * window created from now on, popups included, the floating "S" icon over
 * its page (the screenshot view never gets it); 0, the default, leaves each
 * window exactly GtkWindow -> WebKitWebView. Call before zb_app_run. */
void zb_app_set_agent_drawer(int enabled);
int zb_app_get_agent_drawer(void);

/* Test hook: window `id`'s media source: 1 on (setting on, no hiding
 * script), 0 off (setting off and the hiding script installed), 2 when the
 * two disagree, -1 without that window or loop. */
int zb_automation_debug_media_source(unsigned int id, unsigned int timeout_ms);

/* Isolated script world shared by the injected automation script and evals. */
#define ZB_AUTOMATION_WORLD "zigbrowser-automation"

/* Install `source` (automation.js) at document start, top frame, in
 * ZB_AUTOMATION_WORLD, for the main window and every child window. Call before
 * zb_app_run. The source is copied; NULL disables injection. */
void zb_automation_set_script(const char *source, size_t len);

/* Window ids (N23): every window gets an id when it is created, stable for
 * its life and never reused within an app run; the first (primary) window
 * is 1. The ops below take an id; 0 means the original primary (id 1), which
 * they wait for before it exists and report gone (NO_WINDOW) once it closed:
 * they never fall back to another window. */

/* The id of the index-th live window in creation order, or 0. Snapshot. */
uint32_t zb_automation_window_id_at(int index);
/* Changes whenever window ids restart (each app run's start and end), so
 * per-id state kept by callers can tell one run's window 1 from the next. */
uint32_t zb_automation_run_generation(void);
/* Whether window `id` is open now (snapshot). */
int zb_automation_window_alive(uint32_t id);
/* Every live window as a JSON array, the original primary first:
 * [{"id":n,"url":"...","title":"...","primary":bool,"opener":n|0,
 *   "responsive":bool,"unresponsive_ms":n,"loading":bool,
 *   "dialog_open":bool,"crashed":"<reason>"|null}, ...]
 * (opener: the window whose page opened it, 0 for none; responsive:
 * WebKit's "is-web-process-responsive", and unresponsive_ms how long it has
 * been false without a break). One consistent snapshot taken on the GTK
 * thread, which a frozen web process does not block. Free with
 * zb_automation_free. */
int zb_automation_list_windows(unsigned int timeout_ms, char **out_json);
/* Destroy window `id` and return once it is gone (NO_WINDOW if there is no
 * such window). Closing a window ends its web process only when no other
 * live window shares it: a popup and its opener are related views in one
 * process, so closing the popup leaves the opener's page as it was. A
 * page's own window.close() closes a window a script opened, the same way. */
int zb_automation_close_window(uint32_t id, unsigned int timeout_ms);
/* page.recover (watchdog slice 2): end window ids[0]'s web process, wait
 * until WebKit reports it ended, forget the native pointer of each listed
 * window whose page it ran, and load each of those again from the URL it
 * showed. `ids` (1..ZB_MAX_WINDOWS) are the windows at risk, ids[0] first.
 * On success *out_json is [{"id":n,"url":"...","ended":bool,
 * "reloaded":bool}, ...] in `ids` order (free with zb_automation_free).
 * NO_WINDOW if ids[0] is gone; TIMEOUT if the process did not end in time
 * (nothing is reloaded then). stderr says "web process ended by
 * page.recover" for each window it ended. */
int zb_automation_recover_windows(const uint32_t *ids, int n, unsigned int timeout_ms, char **out_json);

/* Ops below: win is a window id (0 = the original primary, waited for until
 * the deadline before it exists, ZB_AUTO_ERR_NO_WINDOW once it closed); any
 * other id that is not alive is ZB_AUTO_ERR_NO_WINDOW at once. Every op except navigate (and the
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
int zb_automation_eval_json(uint32_t win, const char *function_body,
                            const char *arg_json, const char *world,
                            unsigned int timeout_ms, char **out_result,
                            char **out_err);

/* Load `url` and wait for its load to finish. A load error or a navigation
 * blocked by policy returns ZB_AUTO_ERR_NAV_FAILED and sets *out_err.
 * Page dialogs: a window that already shows a dialog is ZB_AUTO_ERR_DIALOG_OPEN
 * at once (nothing loads). A beforeunload prompt the load raises is handled
 * by `before_unload`: FAIL returns ZB_AUTO_ERR_DIALOG_OPEN as soon as it
 * opens and leaves it open (a person or zb_automation_respond_dialog answers
 * it; leaving then continues this navigation); ACCEPT leaves the page and
 * waits for the load; DISMISS stays (ZB_AUTO_ERR_DIALOG_DISMISSED). Any other
 * dialog that opens on the window during the load is ZB_AUTO_ERR_DIALOG_OPEN.
 * zb_automation_navigate and zb_automation_reload use FAIL. */
enum {
  ZB_BEFORE_UNLOAD_FAIL = 0,
  ZB_BEFORE_UNLOAD_ACCEPT = 1,
  ZB_BEFORE_UNLOAD_DISMISS = 2,
};
int zb_automation_navigate(uint32_t win, const char *url, unsigned int timeout_ms,
                           char **out_err);
int zb_automation_navigate_guarded(uint32_t win, const char *url, int before_unload,
                                   unsigned int timeout_ms, char **out_err);
int zb_automation_reload(uint32_t win, unsigned int timeout_ms, char **out_err);

/* Page dialogs (alert, confirm, prompt, beforeunload). Each window keeps at
 * most one open dialog; it is never answered by default: it stays open, as a
 * native dialog a person can answer, until that or
 * zb_automation_respond_dialog closes it. Closing the window dismisses it.
 * They do not wait for any page load (a dialog can block one).
 * list: every open dialog, the original primary's first, as
 * [{"window":n,"type":"alert|confirm|prompt|beforeunload","message":"...",
 *   "default_text":"..."}] (default_text: prompts only). Free with
 * zb_automation_free.
 * respond: answers window `win`'s dialog (0 = the original primary):
 * accept = OK / Leave, else Cancel / Stay; `text` (NULL = the prompt's
 * default) is a prompt's answer when accepted. ZB_AUTO_ERR_NO_WINDOW,
 * ZB_AUTO_ERR_NO_DIALOG. */
int zb_automation_list_dialogs(unsigned int timeout_ms, char **out_json);
int zb_automation_respond_dialog(uint32_t win, int accept, const char *text,
                                 unsigned int timeout_ms);

/* Current URI (WebKit's committed URI) / document.title; "" when none. */
int zb_automation_get_url(uint32_t win, unsigned int timeout_ms, char **out_url);
int zb_automation_get_title(uint32_t win, unsigned int timeout_ms, char **out_title);

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
int zb_cookies_get_all(uint32_t win, const char *url, unsigned int timeout_ms,
                       char **out_json, char **out_err);
/* Adds or replaces the cookie (all fields are copied before queuing).
 * expires outside [-1, ZB_COOKIE_MAX_EXPIRES] is ZB_AUTO_ERR_INTERNAL. */
int zb_cookies_add(uint32_t win, const ZbCookie *cookie, unsigned int timeout_ms,
                   char **out_err);
/* Deletes every cookie called `name` on `domain` (leading dot ignored);
 * domain NULL = on every domain. Deleting nothing is not an error. */
int zb_cookies_delete(uint32_t win, const char *name, const char *domain,
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

/* expected_doc (optional): __zbAutomation.documentToken of the document the
 * input is meant for. When given, the GTK-thread job reads the current token
 * and, in the same callback with no return to the main loop, either refuses
 * with ZB_AUTO_ERR_DOC_CHANGED (nothing sent) or delivers the events. */

/* One pointer-motion event to (x, y), no click (for humanized paths). */
/* Set a file input's files through WebKit's file chooser: run
 * `function_body` (bound `arg` = arg_json) in the automation world; the
 * automation.js op it runs clicks the input, and the chooser that opens is
 * answered with `paths` (absolute, readable regular files, checked first:
 * ZB_AUTO_ERR_BAD_FILE, nothing run). Returns the op's JSON answer; when the
 * op refuses, nothing was clicked. Several paths for a single-file input:
 * the chooser is cancelled and ZB_AUTO_ERR_BAD_FILE. A deadline that passes
 * after the files were chosen is ZB_AUTO_ERR_FILES_UNCONFIRMED (they were
 * applied once; never repeat the call). */
int zb_set_input_files(uint32_t win, const char *function_body, const char *arg_json,
                       const char *const *paths, int n_paths, unsigned int timeout_ms,
                       char **out_result, char **out_err);
/* PNG of `win`'s viewport (full_page: the whole document), at most
 * `max_bytes` encoded (ZB_AUTO_ERR_TOO_LARGE otherwise, nothing returned).
 * On OK *out_png (free with zb_automation_free) holds *out_len bytes. */
int zb_screenshot_png(uint32_t win, int full_page, size_t max_bytes, unsigned int timeout_ms,
                      unsigned char **out_png, size_t *out_len, int *out_width,
                      int *out_height, char **out_err);

/* One real smooth-scroll (wheel) event at viewport CSS px (x, y), scrolling
 * by (delta_x, delta_y) CSS px (positive = right/down; exact at page zoom
 * 1). Guarded like zb_native_move; returns once dispatched (the caller
 * acknowledges the page's trusted wheel event). */
int zb_native_scroll(uint32_t win, double x, double y, double delta_x, double delta_y,
                     const char *expected_doc, unsigned int timeout_ms, char **out_err);
int zb_native_move(uint32_t win, double x, double y, const char *expected_doc,
                   unsigned int timeout_ms, char **out_err);

/* Last pointer position actually dispatched to `win` (NULL = primary) by a
 * native move or click; returns 0 if none. Kept per window, cleared with it.
 * Thread-safe. */
int zb_native_pointer(uint32_t win, double *out_x, double *out_y);

/* Pointer motion to (x, y), then press and release of `button` (1 = left). */
int zb_native_click(uint32_t win, double x, double y, int button,
                    const char *expected_doc, unsigned int timeout_ms, char **out_err);
/* Press and release one key: `key` is a DOM key name ("Enter", "Tab",
 * "ArrowLeft", "a", ...); `modifiers` (ZB_NATIVE_MOD_*) are pressed before
 * the key and released after it. ZB_AUTO_ERR_INTERNAL for unknown keys.
 * *out_releases (optional) receives the number of key releases sent, so a
 * caller can wait for that many keyup events to reach the page. */
int zb_native_key(uint32_t win, const char *key, int modifiers,
                  const char *expected_doc, unsigned int timeout_ms, int *out_releases,
                  char **out_err);
/* Press and release a key for each character of UTF-8 `text` (Shift added
 * where the keymap needs it; '\n' is Return). Each character is its own
 * GTK-thread step and the deadline is checked between them: on TIMEOUT the
 * text is partially typed; *out_chars (optional) counts the code points fully
 * sent, *out_releases the key releases, so a caller can resume or report the
 * partial effect instead of retrying the whole text. With expected_doc,
 * every character is guarded: DOC_CHANGED stops before the next one. */
int zb_native_text(uint32_t win, const char *text, const char *expected_doc,
                   unsigned int timeout_ms, int *out_releases, int *out_chars,
                   char **out_err);

/* Diagnostics: bridge jobs currently allocated (0 once all work is released). */
int zb_automation_debug_live_jobs(void);
/* Test hook: hold every started cookie operation for `ms` before it reaches
 * WebKit, so a test can make a job time out while in flight (0 = off). */
void zb_automation_debug_cookie_delay(unsigned int ms);
/* Test hook: how many cookie ops have entered that held (RUNNING) state. */
int zb_automation_debug_cookie_delay_hits(void);
/* Test hook: hold a matched native-input guard verdict for `ms` before the
 * commit-to-dispatch decision (0 = off), and count how often that happened. */
void zb_automation_debug_native_guard_hold(unsigned int ms);
int zb_automation_debug_native_guard_hold_hits(void);
/* Test hook: destroy `win`'s toplevel on the GTK thread (as a user closing
 * it would), so a test can make another window the primary. */
int zb_automation_debug_destroy_window(uint32_t win, unsigned int timeout_ms);
/* Test hook: destroy `win`'s toplevel from its own motion-notify handler,
 * i.e. synchronously inside the next pointer event dispatched to it. */
int zb_automation_debug_close_on_motion(uint32_t win, unsigned int timeout_ms);
/* Test hook: pointer-cache writes dropped because the window had gone. */
int zb_automation_debug_pointer_lost(void);
/* Test hook: cancel (and count) file choosers no set-files job claimed,
 * instead of opening the default dialog. */
void zb_automation_debug_files_unmatched(int cancel);
int zb_automation_debug_files_unmatched_hits(void);
/* Test hooks: sleep `ms` before each PNG chunk is written (0 = off); count
 * encodes stopped because their caller had given up. */
void zb_automation_debug_png_write_hold(unsigned int ms);
int zb_automation_debug_png_stopped(void);
/* Test hooks: keep encoding after the caller gave up (only the absolute
 * deadline stops it), and count deadline stops; page script run between
 * the full-page measure and the capture, and count captures refused by
 * their own size. */
void zb_automation_debug_png_ignore_abandon(int on);
int zb_automation_debug_png_deadline_stops(void);
void zb_automation_debug_shot_after_measure(const char *page_js);
/* Test hook: a waiter whose deadline passed sleeps `ms` once more before
 * giving up, so a late completion is what it reports (0 = off). */
void zb_automation_debug_waiter_grace(unsigned int ms);
/* Test hooks (N23): GTK-side page work started per window id (ids <= 64);
 * set the next window id to hand out (on the GTK thread). */
int zb_automation_debug_window_work(uint32_t id);
int zb_automation_debug_next_window_id(uint64_t next, unsigned int timeout_ms);
int zb_automation_debug_shot_postcapture_refusals(void);
/* Test hooks: choosers cancelled because their job's caller had given up;
 * block the GTK thread for `ms` at set-files stage 1 (job start, before
 * its op is sent) or 2 (chooser, before the commit decision); 0 = off. */
int zb_automation_debug_files_late_cancels(void);
void zb_automation_debug_files_hold(int stage, unsigned int ms);
/* Test hook: page-world script each set-files job runs after it is armed
 * and before its op (NULL = off). */
void zb_automation_debug_files_preclick(const char *page_js);
/* Test hook: like close_on_motion, from the view's key-press handler. */
int zb_automation_debug_close_on_key(uint32_t win, unsigned int timeout_ms);
/* Test hooks: answer a navigate policy's beforeunload prompt `ms` after it
 * opens instead of on the next main-loop iteration (0 = off), and count
 * the prompts a policy took. */
void zb_automation_debug_dialog_policy_hold(unsigned int ms);
int zb_automation_debug_dialog_policy_scheduled(void);
/* Test hook: page script run after a guarded native input job is tracked
 * and before its document guard runs (NULL = off). */
void zb_automation_debug_native_preguard(const char *page_js);
/* Test hook: key events not sent because their window was destroyed. */
int zb_automation_debug_native_skipped(void);

/* Track-B owned exports; hard-linked into the Zig binary. */
int zb_policy_decide(const char *base, const char *candidate, int dtype);
int zb_ipc_dispatch(const char *cmd, const char *args_json, const char **out_result,
                    const char **out_err);

#ifdef __cplusplus
}
#endif

#endif
