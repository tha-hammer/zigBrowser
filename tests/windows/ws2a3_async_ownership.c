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
 * the 3 s hold; that one assertion is the only FAIL line.
 * WS2a.3c (plan WS2a.3: "an immediate quit wakes waiters and cancels queued jobs"), each in a fresh child
 * process of this executable (`--ws2a3c-init-failure`, `--ws2a3c-immediate-quit <index.html>`), because a run
 * that ends its loop ends it for the whole process. These run first, before this process's own loop:
 *   - ONE named assertion: a caller already waiting for the loop when zb_app_run fails before its loop (here
 *     an invalid UTF-8 URI) is answered NO_LOOP at once, with no result, and so is every later call;
 *   - closing the window as soon as it exists (before or while the WebView starts) answers the waiting caller
 *     NO_LOOP at once, frees its job, and ends zb_app_run.
 *   3c red and mutant (no loop end on the early-failure paths of run_core): the waiter sits out its whole
 *   8 s deadline and answers TIMEOUT, so that one assertion is the only FAIL line.
 * WS2a.3d (header: "on timeout ... a navigate/reload stops its own load (never a newer one)"), through a loopback
 * HTTP server in this process (late answers: /slow and a reload of /reload 2.5 s, /slowscript 1.5 s; /stall never):
 *   - a navigate that times out (800 ms) stops its own load: the page stays on App Index A;
 *   - a reload that times out stops its own load: the page stays on Reload One;
 *   - overlap (seam zb_automation_debug_abandon_at_start holds the abandoned handling until the next
 *     NavigationStarting): a navigate to /slowscript times out; its late page commits while an image (/stall) keeps
 *     it loading, and its inline script starts a page-initiated navigation to /newer. The abandoned handling then
 *     runs inside that newer navigation's start, which must go on and commit (Newer Page);
 *   - a newer routed navigate after them loads normally (App Page B);
 *   - in a child process (--ws2a3d-timeout-close): a navigate times out while its abandoned handling is held, the
 *     window is closed at once, and live jobs return to the baseline (the routed navigation's hold is released at
 *     shutdown).
 *   Red (no abandoned handling, no shutdown release): the navigate, reload and timeout-close rows FAIL. Mutants:
 *   no Stop() -> the navigate and reload rows; ownership guard dropped -> the overlap row only; no shutdown
 *   release -> the timeout-close row only. Exit 0 only when every check passes. */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "webkit_shim.h"

/* The shim's WS2a.3 test seams that webkit_shim.h does not declare (src/webview2_shim.cpp). */
void zb_automation_debug_complete_hold_ms(unsigned int ms);
void zb_automation_debug_step_hold_ms(unsigned int ms);
int zb_automation_debug_late_dispatches(void);
void zb_automation_debug_abandon_at_start(int on);

enum { kDeadlineMs = 300, kWaiterGraceMs = 250, kSlackMs = 300, kHoldMs = 3000, kStepHoldMs = 1200 };
/* WS2a.3c: the early caller's deadline, how soon "at once" is, and how long a child may run. */
enum { kEarlyMs = 8000, kAtOnceMs = 2000, kChildMs = 60000 };

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

/* WS2a.3d: one routed navigate (url) or reload (url NULL), its code and how long it took. */
static int navigate(const char *url, unsigned int timeout_ms, char *why, size_t cap, ULONGLONG *took_ms) {
  char *err = NULL;
  const ULONGLONG start = GetTickCount64();
  const int rc = url != NULL ? zb_automation_navigate(0, url, timeout_ms, &err) : zb_automation_reload(0, timeout_ms, &err);
  *took_ms = GetTickCount64() - start;
  snprintf(why, cap, "%s", err != NULL ? err : "(null)");
  zb_automation_free(err);
  return rc;
}

/* WS2a.3d: a loopback HTTP server. GET /slow answers "Slow Page" kSlowMs late; GET /reload answers "Reload One"
 * at once the first time and "Reload Two" kSlowMs late every later time; GET /slowscript answers kScriptMs late
 * with "Slow Script", a page that keeps loading (an image from /stall) while its inline script navigates to
 * /newer; GET /newer answers "Newer Page" at once; GET /stall never answers (held kStallMs); anything else is 404
 * at once. A late answer is not sent if the browser closed the connection first (counted as dropped). */
enum { kSlowMs = 2500, kScriptMs = 1500, kStallMs = 15000, kNavDeadlineMs = 800 };
static unsigned short slow_port = 0;
static volatile LONG reload_hits = 0;
static volatile LONG slow_dropped = 0;
static volatile LONG slow_served = 0;

/* Waits up to ms for the browser to close the connection; 1 if it did. */
static int closed_within(SOCKET s, int ms) {
  fd_set readable;
  FD_ZERO(&readable);
  FD_SET(s, &readable);
  struct timeval wait = {ms / 1000, (ms % 1000) * 1000};
  char peek;
  return select(0, &readable, NULL, NULL, &wait) == 1 && recv(s, &peek, 1, MSG_PEEK) <= 0;
}

static DWORD WINAPI slow_conn(LPVOID arg) {
  SOCKET s = (SOCKET)(UINT_PTR)arg;
  char req[4096];
  int got = 0;
  while (got < (int)sizeof req - 1) {
    const int n = recv(s, req + got, (int)sizeof req - 1 - got, 0);
    if (n <= 0) {
      break;
    }
    got += n;
    req[got] = '\0';
    if (strstr(req, "\r\n\r\n") != NULL) {
      break;
    }
  }
  req[got] = '\0';
  char body[512];
  int body_len = -1;
  int late_ms = 0;
  if (strncmp(req, "GET /slow ", 10) == 0) {
    body_len = snprintf(body, sizeof body, "<!doctype html><title>Slow Page</title><p>slow</p>");
    late_ms = kSlowMs;
  } else if (strncmp(req, "GET /reload ", 12) == 0) {
    const int again = InterlockedIncrement(&reload_hits) > 1;
    body_len = snprintf(body, sizeof body, "<!doctype html><title>%s</title><p>reload</p>",
                        again ? "Reload Two" : "Reload One");
    late_ms = again ? kSlowMs : 0;
  } else if (strncmp(req, "GET /slowscript ", 16) == 0) {
    body_len = snprintf(body, sizeof body,
                        "<!doctype html><title>Slow Script</title><img src=\"/stall\">"
                        "<script>location.href = '/newer';</script>");
    late_ms = kScriptMs;
  } else if (strncmp(req, "GET /newer ", 11) == 0) {
    body_len = snprintf(body, sizeof body, "<!doctype html><title>Newer Page</title><p>newer</p>");
  } else if (strncmp(req, "GET /stall ", 11) == 0) {
    closed_within(s, kStallMs); /* never answered: keeps the page that asked for it loading */
    closesocket(s);
    return 0;
  }
  if (late_ms > 0 && closed_within(s, late_ms)) {
    InterlockedIncrement(&slow_dropped); /* the browser closed first: it stopped this load */
    closesocket(s);
    return 0;
  }
  char resp[1024];
  const int len = body_len >= 0
                      ? snprintf(resp, sizeof resp,
                                 "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCache-Control: no-store\r\n"
                                 "Connection: close\r\nContent-Length: %d\r\n\r\n%s",
                                 body_len, body)
                      : snprintf(resp, sizeof resp, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
  if (send(s, resp, len, 0) == len && late_ms > 0) {
    InterlockedIncrement(&slow_served);
  }
  shutdown(s, SD_SEND);
  closesocket(s);
  return 0;
}

static DWORD WINAPI slow_accept(LPVOID arg) {
  SOCKET listener = (SOCKET)(UINT_PTR)arg;
  for (;;) {
    SOCKET s = accept(listener, NULL, NULL);
    if (s == INVALID_SOCKET) {
      return 0;
    }
    HANDLE t = CreateThread(NULL, 0, slow_conn, (LPVOID)(UINT_PTR)s, 0, NULL);
    if (t == NULL) {
      closesocket(s);
    } else {
      CloseHandle(t);
    }
  }
}

static int slow_server_start(void) {
  WSADATA wsa;
  if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
    return 0;
  }
  SOCKET listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  struct sockaddr_in addr;
  int addr_len = sizeof addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  if (listener == INVALID_SOCKET || bind(listener, (struct sockaddr *)&addr, sizeof addr) != 0 ||
      listen(listener, 16) != 0 || getsockname(listener, (struct sockaddr *)&addr, &addr_len) != 0) {
    return 0;
  }
  slow_port = ntohs(addr.sin_port);
  HANDLE t = CreateThread(NULL, 0, slow_accept, (LPVOID)(UINT_PTR)listener, 0, NULL);
  if (t == NULL) {
    return 0;
  }
  CloseHandle(t);
  return 1;
}

/* WS2a.3c: one title read on its own thread, timed to the tick it returned. */
struct early_call {
  int rc;
  char got[256];
  ULONGLONG took;
  ULONGLONG ended;
};

static DWORD WINAPI early_title(LPVOID arg) {
  struct early_call *call = (struct early_call *)arg;
  call->rc = title(kEarlyMs, call->got, sizeof call->got, &call->took);
  call->ended = GetTickCount64();
  return 0;
}

/* The child's own host window (EnumWindows over this process only; never another process's window). */
struct own_window {
  DWORD pid;
  HWND hwnd;
};

static BOOL CALLBACK find_own_window(HWND hwnd, LPARAM arg) {
  struct own_window *want = (struct own_window *)arg;
  DWORD pid = 0;
  char cls[64];
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == want->pid && GetClassNameA(hwnd, cls, sizeof cls) > 0 && strcmp(cls, "zigBrowserWebView2Host") == 0) {
    want->hwnd = hwnd;
    return FALSE;
  }
  return TRUE;
}

/* Child: a caller waits for the loop; zb_app_run then fails before its loop (invalid UTF-8 URI). */
static int init_failure_child(void) {
  struct early_call call = {0};
  HANDLE waiter = CreateThread(NULL, 0, early_title, &call, 0, NULL);
  if (waiter == NULL) {
    printf("ws2a3c child: CreateThread failed\n");
    return 3;
  }
  Sleep(300); /* the call is now waiting for the loop */
  const ULONGLONG failed_at = GetTickCount64();
  const int run = zb_app_run("\xff\xfe-not-utf8", 0, 0);
  const int joined = WaitForSingleObject(waiter, kEarlyMs + 5000) == WAIT_OBJECT_0;
  CloseHandle(waiter);
  char later[256];
  ULONGLONG later_took = 0;
  const int later_rc = title(3000, later, sizeof later, &later_took);
  const ULONGLONG woke = joined && call.ended > failed_at ? call.ended - failed_at : 0;
  printf("ws2a3c child: zb_app_run=%d (want %d); waiter rc=%d result=%s woke %llums after the failure (want %d "
         "within %dms); later call rc=%d result=%s took=%llums\n",
         run, ZB_EXIT_WEBVIEW_INIT_FAILED, call.rc, joined ? call.got : "(still waiting)", woke, ZB_AUTO_ERR_NO_LOOP,
         kAtOnceMs, later_rc, later, later_took);
  fflush(stdout);
  return run == ZB_EXIT_WEBVIEW_INIT_FAILED && joined && call.rc == ZB_AUTO_ERR_NO_LOOP &&
                 strcmp(call.got, "(null)") == 0 && woke < kAtOnceMs && later_rc == ZB_AUTO_ERR_NO_LOOP &&
                 strcmp(later, "(null)") == 0 && later_took < kAtOnceMs
             ? 0
             : 1;
}

/* Child: a caller waits; the window is closed as soon as it exists. */
static int immediate_quit_child(void) {
  struct early_call call = {0};
  HANDLE waiter = CreateThread(NULL, 0, early_title, &call, 0, NULL);
  HANDLE loop = waiter != NULL ? CreateThread(NULL, 0, loop_main, NULL, 0, NULL) : NULL;
  if (loop == NULL) {
    printf("ws2a3c child: CreateThread failed\n");
    return 3;
  }
  struct own_window own = {GetCurrentProcessId(), NULL};
  const ULONGLONG give_up = GetTickCount64() + 20000;
  while (own.hwnd == NULL && GetTickCount64() < give_up) {
    EnumWindows(find_own_window, (LPARAM)&own);
    if (own.hwnd == NULL) {
      Sleep(5);
    }
  }
  const ULONGLONG closed_at = GetTickCount64();
  if (own.hwnd != NULL) {
    PostMessageA(own.hwnd, WM_CLOSE, 0, 0);
  }
  const int ended = WaitForSingleObject(loop, 20000) == WAIT_OBJECT_0;
  const int joined = WaitForSingleObject(waiter, kEarlyMs + 5000) == WAIT_OBJECT_0;
  CloseHandle(loop);
  CloseHandle(waiter);
  const int live = zb_automation_debug_live_jobs();
  const ULONGLONG woke = joined && call.ended > closed_at ? call.ended - closed_at : 0;
  printf("ws2a3c child: window %s; zb_app_run %s rc=%ld; waiter rc=%d result=%s woke %llums after the close (want %d "
         "within %dms); live jobs %d\n",
         own.hwnd != NULL ? "closed" : "never appeared", ended ? "ended" : "still running",
         (long)InterlockedCompareExchange(&run_rc, 0, 0), call.rc, joined ? call.got : "(still waiting)", woke,
         ZB_AUTO_ERR_NO_LOOP, kAtOnceMs, live);
  fflush(stdout);
  return own.hwnd != NULL && ended && joined && call.rc == ZB_AUTO_ERR_NO_LOOP && strcmp(call.got, "(null)") == 0 &&
                 woke < kAtOnceMs && live == 0
             ? 0
             : 1;
}

/* Child (WS2a.3d): a navigate times out while its abandoned handling is held (seam), and the window is closed at
 * once; shutdown must release every job (the routed navigation's hold included). */
static int timeout_close_child(void) {
  HANDLE loop = CreateThread(NULL, 0, loop_main, NULL, 0, NULL);
  if (loop == NULL) {
    printf("ws2a3d child: CreateThread failed\n");
    return 3;
  }
  char got[256];
  char err[256];
  char url[128];
  ULONGLONG took = 0;
  const int loaded = title(30000, got, sizeof got, &took) == ZB_AUTO_OK && strcmp(got, "App Index A") == 0;
  const int baseline = zb_automation_debug_live_jobs();
  const int served = loaded && slow_server_start();
  int rc = -1;
  if (served) {
    snprintf(url, sizeof url, "http://127.0.0.1:%u/slow", (unsigned)slow_port);
    zb_automation_debug_abandon_at_start(1); /* shutdown wins: the abandoned handling never runs */
    rc = navigate(url, kNavDeadlineMs, err, sizeof err, &took);
  }
  struct own_window own = {GetCurrentProcessId(), NULL};
  EnumWindows(find_own_window, (LPARAM)&own);
  if (own.hwnd != NULL) {
    PostMessageA(own.hwnd, WM_CLOSE, 0, 0);
  }
  const int ended = WaitForSingleObject(loop, 20000) == WAIT_OBJECT_0;
  CloseHandle(loop);
  const int live = zb_automation_debug_live_jobs();
  printf("ws2a3d child: first load %s; server %s; navigate rc=%d (want TIMEOUT=%d); window %s; zb_app_run %s; "
         "live jobs %d (baseline %d)\n",
         loaded ? "ok" : "FAILED", served ? "up" : "down", rc, ZB_AUTO_ERR_TIMEOUT,
         own.hwnd != NULL ? "closed" : "not found", ended ? "ended" : "still running", live, baseline);
  fflush(stdout);
  return loaded && served && rc == ZB_AUTO_ERR_TIMEOUT && own.hwnd != NULL && ended && live == baseline ? 0 : 1;
}

/* Runs this executable again as a WS2a.3c child (its lines go to the same stdout) and checks it exits 0.
 * A child still running after kChildMs is this test's own process: it is terminated and reported. */
static void child_check(const char *flag, const char *fixture, const char *what) {
  char exe[MAX_PATH];
  char cmd[3 * MAX_PATH];
  char why[128];
  STARTUPINFOA si;
  PROCESS_INFORMATION pi;
  DWORD n = GetModuleFileNameA(NULL, exe, MAX_PATH);
  if (n == 0 || n >= MAX_PATH ||
      (fixture != NULL ? snprintf(cmd, sizeof cmd, "\"%s\" %s \"%s\"", exe, flag, fixture)
                       : snprintf(cmd, sizeof cmd, "\"%s\" %s", exe, flag)) >= (int)sizeof cmd) {
    check(0, what, "cannot build the child command line");
    return;
  }
  memset(&si, 0, sizeof si);
  si.cb = sizeof si;
  si.dwFlags = STARTF_USESTDHANDLES;
  si.hStdInput = NULL;
  si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
  si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
  SetHandleInformation(si.hStdOutput, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  SetHandleInformation(si.hStdError, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
  fflush(stdout);
  if (!CreateProcessA(exe, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
    snprintf(why, sizeof why, "CreateProcess failed (%lu)", GetLastError());
    check(0, what, why);
    return;
  }
  CloseHandle(pi.hThread);
  DWORD code = 0;
  if (WaitForSingleObject(pi.hProcess, kChildMs) != WAIT_OBJECT_0) {
    TerminateProcess(pi.hProcess, 99);
    WaitForSingleObject(pi.hProcess, 10000);
    snprintf(why, sizeof why, "the child ran past %dms and was terminated", kChildMs);
    check(0, what, why);
  } else {
    GetExitCodeProcess(pi.hProcess, &code);
    snprintf(why, sizeof why, "child exit %lu (see the ws2a3c child line above)", code);
    check(code == 0, what, why);
  }
  CloseHandle(pi.hProcess);
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
  if (argc == 2 && strcmp(argv[1], "--ws2a3c-init-failure") == 0) {
    return init_failure_child();
  }
  if (argc == 3 && strcmp(argv[1], "--ws2a3c-immediate-quit") == 0) {
    return file_uri(argv[2], index_uri, sizeof index_uri) ? immediate_quit_child() : 3;
  }
  if (argc == 3 && strcmp(argv[1], "--ws2a3d-timeout-close") == 0) {
    return file_uri(argv[2], index_uri, sizeof index_uri) ? timeout_close_child() : 3;
  }
  if (!check(argc == 2, "usage: ws2a3-async-ownership <index.html>", NULL) ||
      !check(file_uri(argv[1], index_uri, sizeof index_uri), "fixture file exists", argv[1])) {
    return 1;
  }

  /* WS2a.3c first, each in a fresh child process (this process's own loop has not started yet). */
  child_check("--ws2a3c-init-failure", NULL,
              "a caller waiting for the loop is answered NO_LOOP at once when zb_app_run fails before its loop");
  child_check("--ws2a3c-immediate-quit", argv[1],
              "an immediate quit wakes the waiting caller with NO_LOOP, frees its job and ends zb_app_run");
  child_check("--ws2a3d-timeout-close", argv[1],
              "a timed-out navigation then an immediate close frees every job (live jobs back to the baseline)");
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

    /* WS2a.3d: a navigate/reload that times out stops its own load (never a newer one). */
    if (check(slow_server_start(), "the loopback slow server starts", NULL)) {
      char url[128];
      char err[256];
      ULONGLONG took2 = 0;
      snprintf(url, sizeof url, "http://127.0.0.1:%u/slow", (unsigned)slow_port);
      rc = navigate(url, kNavDeadlineMs, err, sizeof err, &took);
      Sleep(kSlowMs + 1500); /* past the late answer */
      int trc = title(5000, got, sizeof got, &took2);
      snprintf(why, sizeof why,
               "navigate rc=%d took=%llums (want TIMEOUT=%d); then title rc=%d %s (want App Index A); late answers "
               "dropped %ld served %ld",
               rc, took, ZB_AUTO_ERR_TIMEOUT, trc, got, (long)slow_dropped, (long)slow_served);
      check(rc == ZB_AUTO_ERR_TIMEOUT && trc == ZB_AUTO_OK && strcmp(got, "App Index A") == 0,
            "a navigate that times out stops its own load (the page stays, the late answer never shows)", why);

      snprintf(url, sizeof url, "http://127.0.0.1:%u/reload", (unsigned)slow_port);
      const int nrc = navigate(url, 10000, err, sizeof err, &took);
      const int t1 = title(5000, got, sizeof got, &took2);
      const int first = nrc == ZB_AUTO_OK && t1 == ZB_AUTO_OK && strcmp(got, "Reload One") == 0;
      rc = navigate(NULL, kNavDeadlineMs, err, sizeof err, &took);
      Sleep(kSlowMs + 1500);
      trc = title(5000, got, sizeof got, &took2);
      snprintf(why, sizeof why,
               "first load %s (navigate rc=%d); reload rc=%d took=%llums (want TIMEOUT=%d); then title rc=%d %s (want "
               "Reload One); late answers dropped %ld served %ld",
               first ? "Reload One" : "FAILED", nrc, rc, took, ZB_AUTO_ERR_TIMEOUT, trc, got, (long)slow_dropped,
               (long)slow_served);
      check(first && rc == ZB_AUTO_ERR_TIMEOUT && trc == ZB_AUTO_OK && strcmp(got, "Reload One") == 0,
            "a reload that times out stops its own load (the page stays, the late answer never shows)", why);

      /* Overlap: the abandoned handling is held until the next NavigationStarting, which is the page-initiated
       * /newer started by the late /slowscript page while it is still loading. */
      snprintf(url, sizeof url, "http://127.0.0.1:%u/slowscript", (unsigned)slow_port);
      zb_automation_debug_abandon_at_start(1);
      rc = navigate(url, kNavDeadlineMs, err, sizeof err, &took);
      Sleep(kScriptMs + 2500); /* past the late page, its script, and /newer */
      trc = title(5000, got, sizeof got, &took2);
      zb_automation_debug_abandon_at_start(0);
      snprintf(why, sizeof why, "navigate rc=%d took=%llums (want TIMEOUT=%d); then title rc=%d %s (want Newer Page)",
               rc, took, ZB_AUTO_ERR_TIMEOUT, trc, got);
      check(rc == ZB_AUTO_ERR_TIMEOUT && trc == ZB_AUTO_OK && strcmp(got, "Newer Page") == 0,
            "a page-initiated newer navigation that starts before the abandoned load is handled goes on and commits",
            why);

      char page_b[2048];
      const char *slash = strrchr(index_uri, '/');
      snprintf(page_b, sizeof page_b, "%.*s/page-b.html", (int)(slash != NULL ? slash - index_uri : 0), index_uri);
      rc = navigate(page_b, 10000, err, sizeof err, &took);
      trc = title(5000, got, sizeof got, &took2);
      snprintf(why, sizeof why, "navigate rc=%d err=%s; title rc=%d %s (want App Page B)", rc, err, trc, got);
      check(rc == ZB_AUTO_OK && trc == ZB_AUTO_OK && strcmp(got, "App Page B") == 0,
            "a newer navigate after a timed-out one loads normally", why);
    }
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
