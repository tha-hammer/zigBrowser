/* Shared helpers for the Windows C spikes that link the WebView2 shim and drive its production ABI from
 * a second thread while zb_app_run runs the loop (WS2b.1 tests/windows/ws2b1_input_spike.c; the same
 * shape as WS2a.0's ws2a0_world_spike.c). Header-only: each spike is one translation unit.
 *
 * Output contract (parsed by tests/windows/spike_driver.py): one line per check, "ok   <name>" or
 * "FAIL <name>[: detail]", then "SPIKE <passes> ok, <failures> failed". */
#ifndef ZB_SPIKE_COMMON_H
#define ZB_SPIKE_COMMON_H

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

static int spike_failures = 0;
static int spike_passes = 0;

static int check(int ok, const char *what, const char *detail) {
  if (ok) {
    spike_passes += 1;
    printf("ok   %s\n", what);
  } else {
    spike_failures += 1;
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

/* The whole file (NUL-terminated, malloc'd) or NULL. */
static char *read_file(const char *path, size_t *out_len) {
  FILE *f = fopen(path, "rb");
  if (f == NULL) {
    return NULL;
  }
  char *buf = NULL;
  size_t len = 0;
  if (fseek(f, 0, SEEK_END) == 0) {
    long end = ftell(f);
    if (end > 0 && fseek(f, 0, SEEK_SET) == 0 && (buf = (char *)malloc((size_t)end + 1)) != NULL) {
      len = fread(buf, 1, (size_t)end, f);
      buf[len] = '\0';
    }
  }
  fclose(f);
  if (buf != NULL && len == 0) {
    free(buf);
    buf = NULL;
  }
  if (out_len != NULL) {
    *out_len = len;
  }
  return buf;
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

/* 1 when `body` in `world` returns exactly `want`; `why` says what it returned otherwise. */
static int eval_equals(const char *world, const char *body, const char *arg, const char *want, char *why,
                       size_t why_cap) {
  char *got = eval(world, body, arg, why, why_cap);
  int ok = got != NULL && strcmp(got, want) == 0;
  if (got != NULL) {
    zb_automation_free(got);
  }
  return ok;
}

static int eval_is(const char *world, const char *body, const char *arg, const char *want, const char *what) {
  char why[512];
  int ok = eval_equals(world, body, arg, want, why, sizeof why);
  return check(ok, what, ok ? NULL : why);
}

/* Polls until `body` in `world` returns `want` (input delivery, navigation, readiness), up to `ms`;
 * `why` keeps the last answer. */
static int wait_for(const char *world, const char *body, const char *arg, const char *want, DWORD ms, char *why,
                    size_t why_cap) {
  ULONGLONG end = GetTickCount64() + ms;
  for (;;) {
    if (eval_equals(world, body, arg, want, why, why_cap)) {
      return 1;
    }
    if (GetTickCount64() >= end) {
      return 0;
    }
    Sleep(100);
  }
}

static int wait_is(const char *world, const char *body, const char *arg, const char *want, DWORD ms,
                   const char *what) {
  char why[512];
  int ok = wait_for(world, body, arg, want, ms, why, sizeof why);
  return check(ok, what, ok ? NULL : why);
}

/* Ends zb_app_run by closing its window; checks the loop thread returns ZB_EXIT_SUCCESS. */
static void close_and_join(HANDLE thread, volatile LONG *run_rc) {
  HWND hwnd = FindWindowA("zigBrowserWebView2Host", NULL);
  if (hwnd != NULL) {
    PostMessageA(hwnd, WM_CLOSE, 0, 0);
  }
  check(WaitForSingleObject(thread, 30000) == WAIT_OBJECT_0, "closing the window ends zb_app_run", NULL);
  CloseHandle(thread);
  check(InterlockedCompareExchange(run_rc, 0, 0) == ZB_EXIT_SUCCESS, "zb_app_run returns success", NULL);
}

static int spike_summary(void) {
  printf("SPIKE %d ok, %d failed\n", spike_passes, spike_failures);
  return spike_failures == 0 ? 0 : 1;
}

#endif
