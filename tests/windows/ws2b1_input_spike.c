/* WS2b.1 spike (Windows plan rev 2.21; UNREGISTERED until the WS2b.1 green): does native input sent
 * through WebView2's DevTools protocol reach the page as TRUSTED events (isTrusted === true)?
 * Built with the shim itself and run on the Win11 VM by
 * `bash tests/windows/build-on-windows.sh ws2b1-input-spike-win` (driven from Linux by
 * tests/e2e/win_trusted_input_matrix.py).
 *
 * Production entry points only: zb_automation_set_script (the real src/automation_script/automation.js,
 * so the document guard's __zbAutomation.documentToken exists) before zb_app_run; then, from this thread
 * while zb_app_run runs the loop on its own thread, zb_native_click / _key / _text / _move / _scroll /
 * _pointer for the input, and zb_automation_eval_json to read what the page saw. The pages are the GTK
 * native-input fixtures (tests/fixtures/automation/input.html, scroll.html), whose capture-phase
 * listeners log every event with its isTrusted.
 *
 * The matrix (plan WS2b.1), one "ok"/"FAIL" line per check:
 *   click (and the move before it), pointer cache, focus, key, text, contenteditable whose beforeinput
 *   cancel the page honors, partial typing at a deadline, deadline abandonment (a job held past its
 *   deadline is never dispatched), a stale document token refused before sending, navigation during
 *   guarded typing, scroll (wheel), pointer move (hover).
 * Mutant (plan WS2b.1): dispatch through a page-side synthetic dispatchEvent -> isTrusted is false and
 * every trusted check is red.
 *
 * RED today: the Windows shim defines no zb_native_* function, so this exe does not link. Exit 0 only
 * when every check passes. */

#include "spike_common.h"

/* The shim's Windows-only test seam (declared as tests/windows/ws3_shim_test.c does): the UI side waits
 * this long before it commits to running a job. */
void zb_automation_debug_hold_dispatch_ms(unsigned int ms);

#define WAIT_MS 5000

static char input_uri[2048];
static char input_nav_uri[2100];
static char scroll_uri[2048];
static volatile LONG run_rc = -1;

static DWORD WINAPI loop_main(LPVOID unused) {
  (void)unused;
  InterlockedExchange(&run_rc, zb_app_run(input_uri, 0, 0));
  return 0;
}

/* The viewport centre of the element `selector` matches, in CSS px. */
static int centre(const char *selector, double *x, double *y) {
  char why[512];
  char *got = eval(NULL,
                   "const r = document.querySelector(arg).getBoundingClientRect();"
                   "return (r.left + r.width / 2) + ',' + (r.top + r.height / 2);",
                   selector, why, sizeof why);
  int ok = got != NULL && sscanf(got, "%lf,%lf", x, y) == 2;
  if (!ok) {
    printf("note centre(%s): %s\n", selector, why);
  }
  if (got != NULL) {
    zb_automation_free(got);
  }
  return ok;
}

static void page(const char *body) {
  char why[512];
  char *got = eval(NULL, body, NULL, why, sizeof why);
  if (got == NULL) {
    printf("note page setup failed: %s\n", why);
  } else {
    zb_automation_free(got);
  }
}

static void note_rc(const char *what, int rc, char *err) {
  if (rc != ZB_AUTO_OK) {
    printf("note %s: rc=%d err=%s\n", what, rc, err != NULL ? err : "(none)");
  }
  if (err != NULL) {
    zb_automation_free(err);
  }
}

static int click_at(const char *selector, const char *expected_doc, unsigned int timeout_ms, double *x, double *y) {
  if (!centre(selector, x, y)) {
    return ZB_AUTO_ERR_INTERNAL;
  }
  char *err = NULL;
  int rc = zb_native_click(0, *x, *y, 1, expected_doc, timeout_ms, &err);
  note_rc("zb_native_click", rc, err);
  return rc;
}

/* "every logged <prefix> event is trusted, and there is at least one" */
static const char kAllTrusted[] =
    "const l = window.trustLog.filter(e => e.startsWith(arg));"
    "return String(l.length > 0 && l.every(e => e.endsWith(':true')));";
static const char kLogged[] = "return JSON.stringify(window.trustLog.filter(e => e.startsWith(arg)));";

static void input_page_checks(void) {
  double x = 0, y = 0;
  char why[512];

  /* click, and the pointer motion the contract sends before it */
  page("window.trustLog = []; window.moveLog = []; return 'ok';");
  int rc = click_at("#nativebtn", NULL, 10000, &x, &y);
  check(rc == ZB_AUTO_OK, "click: zb_native_click returns OK", NULL);
  wait_is(NULL, kLogged, "click:", "[\"click:nativebtn:true\"]", WAIT_MS, "click: one trusted click on the button");
  wait_is(NULL, kAllTrusted, "mousemove:nativebtn:", "true", WAIT_MS, "click: the move before it is trusted, on the button");
  double px = -1, py = -1;
  int have = zb_native_pointer(0, &px, &py);
  snprintf(why, sizeof why, "have=%d at %.1f,%.1f want %.1f,%.1f", have, px, py, x, y);
  check(have == 1 && px > x - 0.5 && px < x + 0.5 && py > y - 0.5 && py < y + 0.5,
        "pointer: zb_native_pointer reports the click point", why);

  /* focus: a trusted click focuses the input, with a trusted focus event */
  page("window.__focusTrusted = 'none'; const i = document.getElementById('nativein'); i.value = '';"
       "i.addEventListener('focus', e => { window.__focusTrusted = String(e.isTrusted); }, { once: true });"
       "window.trustLog = []; return 'ok';");
  click_at("#nativein", NULL, 10000, &x, &y);
  wait_is(NULL, "return document.activeElement ? document.activeElement.id : '';", NULL, "nativein", WAIT_MS,
          "focus: a trusted click focuses the input");
  wait_is(NULL, "return window.__focusTrusted;", NULL, "true", WAIT_MS, "focus: the focus event is trusted");

  /* key */
  page("window.trustLog = []; return 'ok';");
  char *err = NULL;
  int releases = -1;
  rc = zb_native_key(0, "a", 0, NULL, 10000, &releases, &err);
  note_rc("zb_native_key", rc, err);
  snprintf(why, sizeof why, "rc=%d releases=%d", rc, releases);
  check(rc == ZB_AUTO_OK && releases == 1, "key: zb_native_key returns OK with one release", why);
  wait_is(NULL, "return document.getElementById('nativein').value;", NULL, "a", WAIT_MS,
          "key: the key types into the focused input");
  wait_is(NULL, kAllTrusted, "keydown:nativein:", "true", WAIT_MS, "key: its keydown is trusted");

  /* text */
  page("document.getElementById('nativein').value = ''; window.trustLog = []; return 'ok';");
  err = NULL;
  int chars = -1;
  releases = -1;
  rc = zb_native_text(0, "Hi!", NULL, 10000, &releases, &chars, &err);
  note_rc("zb_native_text", rc, err);
  snprintf(why, sizeof why, "rc=%d chars=%d releases=%d", rc, chars, releases);
  check(rc == ZB_AUTO_OK && chars == 3, "text: zb_native_text returns OK with all 3 characters", why);
  wait_is(NULL, "return document.getElementById('nativein').value;", NULL, "Hi!", WAIT_MS,
          "text: the input holds exactly the text");
  wait_is(NULL, kAllTrusted, "keydown:nativein:", "true", WAIT_MS, "text: every keydown is trusted");

  /* contenteditable whose beforeinput cancel the page honors (the Draft.js shape of X's post box) */
  click_at("#draft", NULL, 10000, &x, &y);
  page("window.draftModel = ''; document.getElementById('draft').textContent = ''; window.draftBeforeInputs = 0;"
       "window.draftTrustedBeforeInputs = 0; window.draftInputs = 0; return 'ok';");
  err = NULL;
  rc = zb_native_text(0, "Real", NULL, 10000, NULL, &chars, &err);
  note_rc("zb_native_text (draft)", rc, err);
  check(rc == ZB_AUTO_OK, "contenteditable: zb_native_text returns OK", NULL);
  wait_is(NULL, "return window.draftModel;", NULL, "Real", WAIT_MS, "contenteditable: the editor's model got the text");
  wait_is(NULL, "return String(window.draftTrustedBeforeInputs) + '/' + String(window.draftBeforeInputs);", NULL,
          "4/4", WAIT_MS, "contenteditable: one trusted beforeinput per character");
  eval_is(NULL, "return document.getElementById('draft').textContent + '|' + String(window.draftInputs);", NULL,
          "Real|0", "contenteditable: the cancelled beforeinput is honored (no browser insert, no input event)");

  /* partial typing: the deadline is checked between characters */
  click_at("#nativein", NULL, 10000, &x, &y);
  page("document.getElementById('nativein').value = ''; return 'ok';");
  char longtext[201];
  memset(longtext, 'x', 200);
  longtext[200] = '\0';
  err = NULL;
  chars = -1;
  rc = zb_native_text(0, longtext, NULL, 200, NULL, &chars, &err);
  note_rc("zb_native_text (partial)", rc, err);
  snprintf(why, sizeof why, "rc=%d chars=%d", rc, chars);
  check(rc == ZB_AUTO_ERR_TIMEOUT && chars > 0 && chars < 200,
        "partial typing: a deadline mid-text times out after some characters", why);
  Sleep(1500); /* anything still queued would land now */
  char want[16];
  snprintf(want, sizeof want, "%d", chars);
  eval_is(NULL, "return String(document.getElementById('nativein').value.length);", NULL, want,
          "partial typing: the page holds exactly the characters reported, none after the return");

  /* deadline abandonment: the UI side is held past the caller's deadline; the click never runs */
  page("window.trustLog = []; return 'ok';");
  if (centre("#nativebtn", &x, &y)) {
    zb_automation_debug_hold_dispatch_ms(1500);
    ULONGLONG start = GetTickCount64();
    err = NULL;
    rc = zb_native_click(0, x, y, 1, NULL, 300, &err);
    ULONGLONG took = GetTickCount64() - start;
    note_rc("zb_native_click (held)", rc, err);
    snprintf(why, sizeof why, "rc=%d after %llu ms", rc, (unsigned long long)took);
    check(rc == ZB_AUTO_ERR_TIMEOUT && took < 1200, "deadline: a held native click times out at its deadline", why);
    Sleep(2000); /* the hold ends; the UI side finds the job abandoned */
    zb_automation_debug_hold_dispatch_ms(0);
    eval_is(NULL, kLogged, "click:", "[]", "deadline: an abandoned native click is never dispatched");
  } else {
    check(0, "deadline: a held native click times out at its deadline", "no button centre");
  }

  /* the document guard: a stale token is refused before anything is sent */
  page("window.trustLog = []; return 'ok';");
  rc = click_at("#nativebtn", "stale-document-token", 10000, &x, &y);
  check(rc == ZB_AUTO_ERR_DOC_CHANGED, "guard: a stale document token is refused (DOC_CHANGED)", NULL);
  Sleep(500);
  eval_is(NULL, kLogged, "click:", "[]", "guard: nothing was sent to the page");

  /* navigation during guarded typing: typing stops at the document change; the new document gets none */
  click_at("#nativein", NULL, 10000, &x, &y);
  char *token = eval(ZB_AUTOMATION_WORLD, "return String(window.__zbAutomation.documentToken);", NULL, why, sizeof why);
  if (check(token != NULL && strcmp(token, "undefined") != 0, "guard: the document has an automation token", why)) {
    char *nav = eval(NULL, "setTimeout(() => { location.href = arg; }, 150); return 'navigating';", input_nav_uri, why,
                     sizeof why);
    if (nav != NULL) {
      zb_automation_free(nav);
    }
    char longer[301];
    memset(longer, 'y', 300);
    longer[300] = '\0';
    err = NULL;
    chars = -1;
    rc = zb_native_text(0, longer, token, 20000, NULL, &chars, &err);
    note_rc("zb_native_text (navigating)", rc, err);
    snprintf(why, sizeof why, "rc=%d chars=%d", rc, chars);
    check(rc == ZB_AUTO_ERR_DOC_CHANGED && chars < 300,
          "navigation during input: guarded typing stops with DOC_CHANGED", why);
    wait_is(NULL, "return document.readyState === 'complete' ? location.search : '';", NULL, "?nav=2", 30000,
            "navigation during input: the new document loads");
    Sleep(500);
    eval_is(NULL, kLogged, "keydown:", "[]", "navigation during input: the new document gets no keystroke");
    zb_automation_free(token);
  }
}

static void scroll_page_checks(void) {
  char why[512];
  char *nav = eval(NULL, "setTimeout(() => { location.href = arg; }, 50); return 'navigating';", scroll_uri, why,
                   sizeof why);
  if (nav != NULL) {
    zb_automation_free(nav);
  }
  if (!wait_is(NULL, "return document.readyState === 'complete' ? document.title : '';", NULL, "Scroll Fixture", 30000,
               "the scroll fixture loads")) {
    return;
  }

  /* scroll: one real wheel event scrolls the page */
  char *err = NULL;
  int rc = zb_native_scroll(0, 200, 200, 0, 600, NULL, 10000, &err);
  note_rc("zb_native_scroll", rc, err);
  check(rc == ZB_AUTO_OK, "scroll: zb_native_scroll returns OK", NULL);
  wait_is(NULL,
          "const w = window.__scroll.wheels; return String(w.length > 0 && w.every(t => t === true));", NULL, "true",
          WAIT_MS, "scroll: the wheel events are trusted");
  wait_is(NULL, "return String(window.scrollY > 0);", NULL, "true", WAIT_MS, "scroll: the page scrolled");

  /* pointer move: a trusted move reaches the hover target */
  double x = 0, y = 0;
  if (centre("#menu", &x, &y)) {
    err = NULL;
    rc = zb_native_move(0, x, y, NULL, 10000, &err);
    note_rc("zb_native_move", rc, err);
    check(rc == ZB_AUTO_OK, "move: zb_native_move returns OK", NULL);
    wait_is(NULL, "return String(window.__scroll.hovers.indexOf('mousemove:true') >= 0);", NULL, "true", WAIT_MS,
            "move: a trusted mousemove reaches the hover target");
    eval_is(NULL, "return String(window.__scroll.hovers.every(h => h.endsWith(':true')));", NULL, "true",
            "move: every hover event is trusted");
    double px = -1, py = -1;
    int have = zb_native_pointer(0, &px, &py);
    snprintf(why, sizeof why, "have=%d at %.1f,%.1f want %.1f,%.1f", have, px, py, x, y);
    check(have == 1 && px > x - 0.5 && px < x + 0.5 && py > y - 0.5 && py < y + 0.5,
          "move: zb_native_pointer reports the move point", why);
  } else {
    check(0, "move: zb_native_move returns OK", "no #menu centre");
  }
}

int main(int argc, char **argv) {
  if (!check(argc == 4, "usage: ws2b1-input-spike <input.html> <scroll.html> <automation.js>", NULL)) {
    return 1;
  }
  if (!check(file_uri(argv[1], input_uri, sizeof input_uri) && file_uri(argv[2], scroll_uri, sizeof scroll_uri),
             "fixture files exist", argv[1])) {
    return 1;
  }
  snprintf(input_nav_uri, sizeof input_nav_uri, "%s?nav=2", input_uri);
  size_t script_len = 0;
  char *script = read_file(argv[3], &script_len);
  if (!check(script != NULL, "automation.js is readable", argv[3])) {
    return 1;
  }
  zb_automation_set_script(script, script_len);
  free(script);

  HANDLE thread = CreateThread(NULL, 0, loop_main, NULL, 0, NULL);
  if (!check(thread != NULL, "zb_app_run starts on its own thread", NULL)) {
    return 1;
  }
  /* about:blank is "complete" too, so wait for the fixture's own title. */
  if (wait_is(NULL, "return document.readyState === 'complete' ? document.title : '';", NULL,
              "Automation Input Fixture", 30000, "the input fixture loads")) {
    input_page_checks();
    scroll_page_checks();
  }
  close_and_join(thread, &run_rc);
  return spike_summary();
}
