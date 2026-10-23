/* WS2a.3 (Windows plan rev 2.21; UNREGISTERED until the WS2a.3 green): the UI-thread marshal's waits are
 * bounded. A caller whose deadline passes while its job's completion is still being written (COMPLETING)
 * gives up within its deadline plus the waiter grace (250 ms) with ZB_AUTO_ERR_TIMEOUT; it never waits
 * for the completion without a bound (plan WS2 "Deadlines": no INFINITE wait remains in the marshal).
 * Built with the shim itself and run on the Win11 VM by
 * `bash tests/windows/build-on-windows.sh ws2a3-async-ownership-win` (driven from Linux by
 * tests/e2e/win_async_ownership_test.py).
 *
 * Production entry points: zb_app_run on its own thread, zb_automation_get_title from this thread. Test seams,
 * compiled into this executable's shim ONLY (build.zig sets ZB_WS2A3_SEAMS on this step alone; the product
 * build omits them, tests/windows/ws2a3_seam_gating_test.py): zb_automation_debug_complete_hold_ms holds a
 * completion after it claimed its job and before it writes the answer; zb_automation_debug_live_jobs counts
 * allocated jobs.
 *
 * Checks, one line each ("ok   <name>" or "FAIL <name>: ..."):
 *   - the fixture loads, and an ordinary call answers at once (OK);
 *   - ONE named assertion: with the completion held 3 s, a 300 ms call answers TIMEOUT, with no result,
 *     within 300 + 250 ms (+ 300 ms slack) and not before its deadline;
 *   - the held job is released once its completion ends (live jobs back to the baseline: no leak);
 *   - the loop still answers afterwards.
 * WS2a.3b (seams: zb_automation_debug_strings_live, _waiter_grace, _step_hold_ms, _late_dispatches):
 *   - a result string and an error string are each issued once and freed once (strings live back to 0);
 *   - a late completion the waiter still sees (waiter grace) is reported once and its string freed once;
 *   - ONE named assertion: an automation-world eval whose caller gave up after the first CDP step starts no
 *     further step (late dispatches 0), returns no string, and releases its job.
 *   Red (the 3b leg before the green) and mutant (plan WS2a.3: drop the generation guard, i.e. the chain's
 *   "job still RUNNING" check in cdp_job_call): the chain dispatches createIsolatedWorld and Runtime.evaluate
 *   for the abandoned job (late dispatches 2), so that one assertion is the only FAIL line.
 *
 * 3a red and mutant (plan WS2a.3: restore the INFINITE wait): job_submit waits for a
 * COMPLETING job with WaitForSingleObject(job->done, INFINITE), so the call answers OK with "App Index A" after
 * the 3 s hold; that one assertion is the only FAIL line. Exit 0 only when every check passes. */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "webkit_shim.h"

/* The shim's WS2a.3 test seams that webkit_shim.h does not declare (src/webview2_shim.cpp). */
void zb_automation_debug_complete_hold_ms(unsigned int ms);
void zb_automation_debug_step_hold_ms(unsigned int ms);
int zb_automation_debug_late_dispatches(void);

enum { kDeadlineMs = 300, kWaiterGraceMs = 250, kSlackMs = 300, kHoldMs = 3000, kStepHoldMs = 1200 };

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

/* One eval; *rc, the result or error text (freed here with zb_automation_free), and the time taken. */
static int eval(const char *world, const char *body, unsigned int timeout_ms, char *got, size_t cap, ULONGLONG *took_ms) {
  char *out = NULL;
  char *err = NULL;
  const ULONGLONG start = GetTickCount64();
  const int rc = zb_automation_eval_json(0, body, NULL, world, timeout_ms, &out, &err);
  *took_ms = GetTickCount64() - start;
  snprintf(got, cap, "out=%s err=%s", out != NULL ? out : "(null)", err != NULL ? err : "(null)");
  zb_automation_free(out);
  zb_automation_free(err);
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
    /* ONE assertion: TIMEOUT, no result, and the elapsed bound together. */
    check(rc == ZB_AUTO_ERR_TIMEOUT && strcmp(got, "(null)") == 0 && took >= kDeadlineMs &&
              took < kDeadlineMs + kWaiterGraceMs + kSlackMs,
          "a call whose completion is held gives up within deadline + waiter grace (TIMEOUT, no result)", why);

    const int drained = wait_live_jobs(baseline, kHoldMs + 3000);
    snprintf(why, sizeof why, "live jobs %d (want %d)", zb_automation_debug_live_jobs(), baseline);
    check(drained, "the held job is released once its completion ends (no leak)", why);
    rc = title(5000, got, sizeof got, &took);
    snprintf(why, sizeof why, "rc=%d title=%s", rc, got);
    check(rc == ZB_AUTO_OK && strcmp(got, "App Index A") == 0, "the loop still answers afterwards", why);

    /* WS2a.3b: strings are freed exactly once, and a late completion dispatches nothing more. */
    const int strings0 = zb_automation_debug_strings_live();
    snprintf(why, sizeof why, "strings live %d", strings0);
    check(strings0 == 0, "no caller string is live between calls", why);

    rc = eval(NULL, "return 'ok-' + (1 + 1);", 5000, got, sizeof got, &took);
    snprintf(why, sizeof why, "rc=%d %s strings live %d", rc, got, zb_automation_debug_strings_live());
    check(rc == ZB_AUTO_OK && strstr(got, "out=ok-2 ") == got && zb_automation_debug_strings_live() == strings0,
          "a result string is issued once and freed once", why);
    rc = eval(NULL, "throw new Error('boom');", 5000, got, sizeof got, &took);
    snprintf(why, sizeof why, "rc=%d %s strings live %d", rc, got, zb_automation_debug_strings_live());
    check(rc == ZB_AUTO_ERR_JS && strstr(got, "boom") != NULL && zb_automation_debug_strings_live() == strings0,
          "an error string is issued once and freed once", why);

    /* The waiter sleeps past its deadline (waiter grace seam) while the 800 ms promise settles, so the late
     * completion is what it reports: one string, freed once. */
    zb_automation_debug_waiter_grace(1500);
    rc = eval(NULL, "await new Promise((r) => setTimeout(r, 800)); return 'late';", kDeadlineMs, got, sizeof got, &took);
    zb_automation_debug_waiter_grace(0);
    snprintf(why, sizeof why, "rc=%d %s took=%llums strings live %d", rc, got, took, zb_automation_debug_strings_live());
    check(rc == ZB_AUTO_OK && strstr(got, "out=late ") == got && zb_automation_debug_strings_live() == strings0,
          "a late completion the waiter still sees is reported once and its string freed once", why);

    /* An automation-world eval is three CDP steps (getFrameTree, createIsolatedWorld, evaluate). Each step's
     * answer is held 1.2 s, so the 300 ms caller gives up after the first; the chain must then start no
     * further step, and the late answer must reach no caller (no string issued). ONE named assertion. */
    const int late0 = zb_automation_debug_late_dispatches();
    const int jobs0 = zb_automation_debug_live_jobs();
    zb_automation_debug_step_hold_ms(kStepHoldMs);
    rc = eval(ZB_AUTOMATION_WORLD, "return 'never';", kDeadlineMs, got, sizeof got, &took);
    Sleep(kStepHoldMs * 3 + 1000); /* every step the chain might still start has answered by now */
    zb_automation_debug_step_hold_ms(0);
    wait_live_jobs(jobs0, 3000);
    const int late = zb_automation_debug_late_dispatches() - late0;
    snprintf(why, sizeof why, "rc=%d %s late dispatches %d strings live %d (want %d) live jobs %d (want %d)", rc,
             got, late, zb_automation_debug_strings_live(), strings0, zb_automation_debug_live_jobs(), jobs0);
    check(rc == ZB_AUTO_ERR_TIMEOUT && strcmp(got, "out=(null) err=(null)") == 0 && late == 0 &&
              zb_automation_debug_strings_live() == strings0 && zb_automation_debug_live_jobs() == jobs0,
          "a late completion after a timeout dispatches nothing more and returns no string", why);
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
