/* WS2a.3 (Windows plan rev 2.21; UNREGISTERED until the WS2a.3 green): the UI-thread marshal's waits are
 * bounded. A caller whose deadline passes while its job's completion is still being written (COMPLETING)
 * gives up within its deadline plus the waiter grace (250 ms) with ZB_AUTO_ERR_TIMEOUT; it never waits
 * for the completion without a bound (plan WS2 "Deadlines": no INFINITE wait remains in the marshal).
 * Built with the shim itself and run on the Win11 VM by
 * `bash tests/windows/build-on-windows.sh ws2a3-async-ownership-win` (driven from Linux by
 * tests/e2e/win_async_ownership_test.py).
 *
 * Production entry points: zb_app_run on its own thread, zb_automation_get_title from this thread. Test seams
 * (webview2_shim.cpp, inert at 0): zb_automation_debug_complete_hold_ms holds a completion after it claimed
 * its job and before it writes the answer; zb_automation_debug_live_jobs counts allocated jobs.
 *
 * Checks, one line each ("ok   <name>" or "FAIL <name>: ..."):
 *   - the fixture loads, and an ordinary call answers at once (OK);
 *   - with the completion held 3 s, a 300 ms call answers TIMEOUT, with no result, within 300 + 250 ms
 *     (+ 300 ms slack) and not before its deadline;
 *   - the held job is released once its completion ends (live jobs back to the baseline: no leak);
 *   - the loop still answers afterwards.
 * Mutant (plan WS2a.3): restore the INFINITE wait -> the call answers only after the 3 s hold -> red.
 *
 * RED today: job_submit waits for a COMPLETING job with WaitForSingleObject(job->done, INFINITE), so the call
 * answers OK after the hold. Exit 0 only when every check passes. */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "webkit_shim.h"

/* The shim's WS2a.3 test seam (src/webview2_shim.cpp; not in webkit_shim.h). */
void zb_automation_debug_complete_hold_ms(unsigned int ms);

enum { kDeadlineMs = 300, kWaiterGraceMs = 250, kSlackMs = 300, kHoldMs = 3000 };

int zb_ipc_dispatch(const char *cmd, const char *args_json, const char **out_result,
                    const char **out_err) {
  (void)cmd;
  (void)args_json;
  *out_result = NULL;
  *out_err = "UnknownCommand";
  return 1;
}

static int failures = 0;
static int passes = 0;
static char index_uri[2048];
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

static DWORD WINAPI loop_main(LPVOID unused) {
  (void)unused;
  InterlockedExchange(&run_rc, zb_app_run(index_uri, 0, 0));
  return 0;
}

/* One title read: its code, the result (NULL or the title), and how long it took. */
static int title(unsigned int timeout_ms, char *got, size_t cap, ULONGLONG *took_ms) {
  char *out = NULL;
  const ULONGLONG start = GetTickCount64();
  const int rc = zb_automation_get_title(0, timeout_ms, &out);
  *took_ms = GetTickCount64() - start;
  snprintf(got, cap, "%s", out != NULL ? out : "(null)");
  zb_automation_free(out);
  return rc;
}

static int wait_live_jobs(int want, DWORD ms) {
  const ULONGLONG end = GetTickCount64() + ms;
  while (GetTickCount64() < end) {
    if (zb_automation_debug_live_jobs() == want) {
      return 1;
    }
    Sleep(50);
  }
  return zb_automation_debug_live_jobs() == want;
}

int main(int argc, char **argv) {
  char why[256];
  char got[512];
  ULONGLONG took = 0;
  if (!check(argc == 2, "usage: ws2a3-async-ownership <index.html>", NULL) ||
      !check(file_uri(argv[1], index_uri, sizeof index_uri), "fixture file exists", argv[1])) {
    return 1;
  }
  HANDLE thread = CreateThread(NULL, 0, loop_main, NULL, 0, NULL);
  if (!check(thread != NULL, "zb_app_run starts on its own thread", NULL)) {
    return 1;
  }

  /* The fixture has loaded once the title reads back (get_title waits for the first load). */
  int rc = title(30000, got, sizeof got, &took);
  snprintf(why, sizeof why, "rc=%d title=%s", rc, got);
  if (check(rc == ZB_AUTO_OK && strcmp(got, "App Index A") == 0, "the fixture loads", why)) {
    rc = title(5000, got, sizeof got, &took);
    snprintf(why, sizeof why, "rc=%d took=%llums", rc, took);
    check(rc == ZB_AUTO_OK && took < 1000, "an ordinary call answers at once", why);
    const int baseline = zb_automation_debug_live_jobs();
    snprintf(why, sizeof why, "live jobs %d", baseline);
    check(baseline == 0, "no job is live between calls", why);

    zb_automation_debug_complete_hold_ms(kHoldMs);
    rc = title(kDeadlineMs, got, sizeof got, &took);
    zb_automation_debug_complete_hold_ms(0);
    snprintf(why, sizeof why, "rc=%d took=%llums result=%s (want TIMEOUT=%d within %d..%dms)", rc, took, got,
             ZB_AUTO_ERR_TIMEOUT, kDeadlineMs, kDeadlineMs + kWaiterGraceMs + kSlackMs);
    check(rc == ZB_AUTO_ERR_TIMEOUT && took >= kDeadlineMs && took < kDeadlineMs + kWaiterGraceMs + kSlackMs,
          "a call whose completion is held gives up within deadline + waiter grace (TIMEOUT)", why);
    check(strcmp(got, "(null)") == 0, "the timed-out call returns no result", got);

    const int drained = wait_live_jobs(baseline, kHoldMs + 3000);
    snprintf(why, sizeof why, "live jobs %d (want %d)", zb_automation_debug_live_jobs(), baseline);
    check(drained, "the held job is released once its completion ends (no leak)", why);
    rc = title(5000, got, sizeof got, &took);
    snprintf(why, sizeof why, "rc=%d title=%s", rc, got);
    check(rc == ZB_AUTO_OK && strcmp(got, "App Index A") == 0, "the loop still answers afterwards", why);
  }

  HWND hwnd = FindWindowA("zigBrowserWebView2Host", NULL);
  if (hwnd != NULL) {
    PostMessageA(hwnd, WM_CLOSE, 0, 0);
  }
  check(WaitForSingleObject(thread, 30000) == WAIT_OBJECT_0, "closing the window ends zb_app_run", NULL);
  CloseHandle(thread);
  check(InterlockedCompareExchange(&run_rc, 0, 0) == ZB_EXIT_SUCCESS, "zb_app_run returns success", NULL);

  printf("WS2A3 %d ok, %d failed\n", passes, failures);
  return failures == 0 ? 0 : 1;
}
