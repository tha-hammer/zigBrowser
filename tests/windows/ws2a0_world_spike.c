/* WS2a.0 spike (Windows plan rev 2.21; UNREGISTERED until the WS2a.0 green): does WebView2 give the
 * automation script a private CDP world that the page cannot see, and does it survive navigation?
 * Built with the shim itself and run on the Win11 VM by
 * `bash tests/windows/build-on-windows.sh ws2a0-world-spike-win` (driven from Linux by
 * tests/e2e/win_private_world_spike.py).
 *
 * Production entry points only: zb_automation_set_script (installs the script at document start in
 * ZB_AUTOMATION_WORLD) before zb_app_run, then zb_automation_eval_json with world NULL (the page's main
 * world) or ZB_AUTOMATION_WORLD, from this thread while zb_app_run runs the loop on its own thread.
 *
 * Checks, one line each ("ok   <name>" or "FAIL <name> ..."):
 *   - the fixture loads (page-world readyState "complete");
 *   - page world: typeof window.__zbAutomation is "undefined" (the page cannot see the script's global);
 *   - automation world: it is "object", and the world shares the page's DOM (document.title);
 *   - a global the page defines is invisible in the automation world;
 *   - after the page navigates to page-b, both hold again (the world survives navigation).
 * Mutant (plan WS2a.0): install the script in the main world -> the page-world check is red.
 *
 * RED today: the Windows shim defines neither zb_automation_set_script nor zb_automation_eval_json (no
 * CDP route exists), so this exe does not link. Exit 0 only when every check passes. */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "webkit_shim.h"

/* The shim answers page IPC through the app's dispatcher; nothing here sends page IPC. */
int zb_ipc_dispatch(const char *cmd, const char *args_json, const char **out_result,
                    const char **out_err) {
  (void)cmd;
  (void)args_json;
  *out_result = NULL;
  *out_err = "UnknownCommand";
  return 1;
}

static const char kWorldScript[] = "window.__zbAutomation = { marker: 'zb-world' };";

static int failures = 0;
static int passes = 0;
static char index_uri[2048];
static char page_b_uri[2048];
static volatile LONG run_rc = -1;

static int check(int ok, const char *what, const char *detail) {
  if (ok) {
    passes += 1;
    printf("ok   %s\n", what);
  } else {
    failures += 1;
    printf("FAIL %s%s%s\n", what, detail != NULL ? ": " : "", detail != NULL ? detail : "");
  }
  fflush(stdout);
  return ok;
}

/* file:///C:/... for an existing file path. */
static int file_uri(const char *path, char *out, size_t cap) {
  char full[MAX_PATH];
  DWORD n = GetFullPathNameA(path, MAX_PATH, full, NULL);
  if (n == 0 || n >= MAX_PATH || GetFileAttributesA(full) == INVALID_FILE_ATTRIBUTES) {
    return 0;
  }
  for (char *p = full; *p; p++) {
    if (*p == '\\') {
      *p = '/';
    }
  }
  return snprintf(out, cap, "file:///%s", full) < (int)cap;
}

/* One eval; returns the result string (caller frees with zb_automation_free) or NULL, and writes the
 * code + error text into `why`. */
static char *eval(const char *world, const char *body, const char *arg, char *why, size_t why_cap) {
  char *out = NULL;
  char *err = NULL;
  int rc = zb_automation_eval_json(0, body, arg, world, 10000, &out, &err);
  if (rc != ZB_AUTO_OK) {
    snprintf(why, why_cap, "rc=%d err=%s", rc, err != NULL ? err : "(none)");
    if (out != NULL) {
      zb_automation_free(out);
    }
    out = NULL;
  } else if (out == NULL) {
    snprintf(why, why_cap, "rc=0 but no result");
  } else {
    snprintf(why, why_cap, "got %s", out);
  }
  if (err != NULL) {
    zb_automation_free(err);
  }
  return out;
}

static int eval_is(const char *world, const char *body, const char *arg, const char *want, const char *what) {
  char why[512];
  char *got = eval(world, body, arg, why, sizeof why);
  int ok = got != NULL && strcmp(got, want) == 0;
  if (got != NULL) {
    zb_automation_free(got);
  }
  return check(ok, what, ok ? NULL : why);
}

/* Polls until `body` in `world` returns `want` (navigation/readiness), up to `ms`. */
static int wait_for(const char *world, const char *body, const char *arg, const char *want, DWORD ms) {
  ULONGLONG end = GetTickCount64() + ms;
  while (GetTickCount64() < end) {
    char why[512];
    char *got = eval(world, body, arg, why, sizeof why);
    int ok = got != NULL && strcmp(got, want) == 0;
    if (got != NULL) {
      zb_automation_free(got);
    }
    if (ok) {
      return 1;
    }
    Sleep(200);
  }
  return 0;
}

static DWORD WINAPI loop_main(LPVOID unused) {
  (void)unused;
  InterlockedExchange(&run_rc, zb_app_run(index_uri, 0, 0));
  return 0;
}

static void world_checks(const char *phase) {
  char name[128];
  snprintf(name, sizeof name, "%s: page world cannot see the automation global", phase);
  eval_is(NULL, "return typeof window.__zbAutomation;", NULL, "undefined", name);
  snprintf(name, sizeof name, "%s: automation world sees its own global", phase);
  eval_is(ZB_AUTOMATION_WORLD, "return typeof window.__zbAutomation;", NULL, "object", name);
  snprintf(name, sizeof name, "%s: automation world global is the injected one", phase);
  eval_is(ZB_AUTOMATION_WORLD, "return window.__zbAutomation.marker;", NULL, "zb-world", name);
  snprintf(name, sizeof name, "%s: page defines a global", phase);
  eval_is(NULL, "window.__zbPageOnly = 1; return typeof window.__zbPageOnly;", NULL, "number", name);
  snprintf(name, sizeof name, "%s: automation world cannot see the page global", phase);
  eval_is(ZB_AUTOMATION_WORLD, "return typeof window.__zbPageOnly;", NULL, "undefined", name);
}

int main(int argc, char **argv) {
  if (!check(argc == 3, "usage: ws2a0-world-spike <index.html> <page-b.html>", NULL)) {
    return 1;
  }
  if (!check(file_uri(argv[1], index_uri, sizeof index_uri) && file_uri(argv[2], page_b_uri, sizeof page_b_uri),
             "fixture files exist", argv[1])) {
    return 1;
  }

  zb_automation_set_script(kWorldScript, strlen(kWorldScript));
  HANDLE thread = CreateThread(NULL, 0, loop_main, NULL, 0, NULL);
  if (!check(thread != NULL, "zb_app_run starts on its own thread", NULL)) {
    return 1;
  }

  if (check(wait_for(NULL, "return document.readyState;", NULL, "complete", 30000), "the fixture loads", index_uri)) {
    eval_is(ZB_AUTOMATION_WORLD, "return document.title;", NULL, "App Index A",
            "automation world shares the page DOM (title)");
    world_checks("first page");

    char why[512];
    char *nav = eval(NULL, "location.href = arg; return 'navigating';", page_b_uri, why, sizeof why);
    check(nav != NULL, "page navigates to page-b", nav != NULL ? NULL : why);
    if (nav != NULL) {
      zb_automation_free(nav);
    }
    if (check(wait_for(NULL, "return document.readyState === 'complete' ? document.title : '';", NULL,
                       "App Page B", 30000),
              "page-b loads", page_b_uri)) {
      world_checks("after navigation");
      eval_is(ZB_AUTOMATION_WORLD, "return document.title;", NULL, "App Page B",
              "after navigation: automation world shares the new DOM");
    }
  }

  HWND hwnd = FindWindowA("zigBrowserWebView2Host", NULL);
  if (hwnd != NULL) {
    PostMessageA(hwnd, WM_CLOSE, 0, 0);
  }
  check(WaitForSingleObject(thread, 30000) == WAIT_OBJECT_0, "closing the window ends zb_app_run", NULL);
  CloseHandle(thread);
  check(InterlockedCompareExchange(&run_rc, 0, 0) == ZB_EXIT_SUCCESS, "zb_app_run returns success", NULL);

  printf("SPIKE %d ok, %d failed\n", passes, failures);
  return failures == 0 ? 0 : 1;
}
