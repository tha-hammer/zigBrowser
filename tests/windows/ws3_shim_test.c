/* WS3 step 2 (Windows launch plan, WS3 coordination rev 2.4): the seven zb_* symbols
 * webview2_shim.cpp gives the Windows config arm and cookie port, linked and run on Windows.
 * Built with the shim itself and run by `zig build ws3-shim-test-win` (-Dtarget=x86_64-windows-msvc,
 * on the Win11 VM through tests/windows/build-on-windows.sh).
 *
 * Without a loop: the policy setters and getters, the profile directory (made with its
 * WebView2 folder; a file in its place is an error), zb_automation_free, and the cookie calls'
 * argument checks, NO_WINDOW and TIMEOUT. With a real zb_app_run loop on its own thread: a
 * session and a persistent cookie round trip through ICoreWebView2CookieManager, delete by
 * name and domain, the user data folder in use (<dir>\WebView2\EBWebView), and after the
 * window closes, NO_LOOP.
 *
 * Exit 0 when every check passes, 1 otherwise; each check prints one line. */

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <shellapi.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

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

static int failures = 0;

static int check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  fflush(stdout);
  if (!ok) {
    failures += 1;
  }
  return ok;
}

static int is_dir(const char *path) {
  const DWORD attrs = GetFileAttributesA(path);
  return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

static int contains(const char *text, const char *needle) {
  return text != NULL && strstr(text, needle) != NULL;
}

static char base[MAX_PATH];

static void join(char *out, const char *rel) { snprintf(out, MAX_PATH, "%s\\%s", base, rel); }

static void policies(void) {
  check(zb_app_get_hw_policy() == ZB_HW_POLICY_WEBKIT, "hw policy: WebKit's own choice by default");
  zb_app_set_hw_policy(ZB_HW_POLICY_NEVER);
  check(zb_app_get_hw_policy() == ZB_HW_POLICY_NEVER, "hw policy: never");
  zb_app_set_hw_policy(ZB_HW_POLICY_ALWAYS);
  check(zb_app_get_hw_policy() == ZB_HW_POLICY_ALWAYS, "hw policy: always");
  zb_app_set_hw_policy(7);
  check(zb_app_get_hw_policy() == ZB_HW_POLICY_WEBKIT, "hw policy: an unknown value is WebKit's choice");
  check(zb_app_get_media_source() == 1, "media source: on by default");
  zb_app_set_media_source(0);
  check(zb_app_get_media_source() == 0, "media source: off");
  zb_app_set_media_source(5);
  check(zb_app_get_media_source() == 1, "media source: any nonzero is on");
  zb_automation_free(NULL);
  zb_automation_free((char *)malloc(8));
  check(1, "zb_automation_free takes NULL and a malloc'ed string");
}

static void profile_dir(void) {
  char dir[MAX_PATH], folder[MAX_PATH], file[MAX_PATH];
  char *err = NULL;
  join(dir, "made\\deep");
  int rc = zb_app_set_profile_dir(dir, &err);
  snprintf(folder, sizeof(folder), "%s\\WebView2", dir);
  check(rc == ZB_AUTO_OK && err == NULL, "profile dir: a new nested directory is accepted");
  check(is_dir(folder), "profile dir: <dir>\\WebView2 exists, with its parents");
  rc = zb_app_set_profile_dir(dir, &err);
  check(rc == ZB_AUTO_OK && err == NULL, "profile dir: an existing one is accepted again");

  join(dir, "blocked");
  CreateDirectoryA(dir, NULL);
  snprintf(file, sizeof(file), "%s\\WebView2", dir);
  HANDLE h = CreateFileA(file, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  CloseHandle(h);
  rc = zb_app_set_profile_dir(dir, &err);
  check(rc == ZB_AUTO_ERR_INTERNAL && err != NULL && err[0] != '\0',
        "profile dir: a file where <dir>\\WebView2 goes is an error, with its text");
  zb_automation_free(err);
  err = NULL;
  check(zb_app_set_profile_dir(NULL, &err) == ZB_AUTO_OK && err == NULL, "profile dir: NULL restores the default");
  check(zb_app_set_profile_dir("", &err) == ZB_AUTO_OK && err == NULL, "profile dir: \"\" restores the default");
}

static ZbCookie cookie(const char *name, const char *value, long long expires) {
  ZbCookie c = {name, value, "example.test", "/", expires, 0, 0, ZB_COOKIE_SAME_SITE_LAX};
  return c;
}

static void cookies_without_loop(void) {
  char *json = NULL, *err = NULL;
  check(zb_cookies_get_all(1, NULL, 100, &json, &err) == ZB_AUTO_ERR_NO_WINDOW && json == NULL,
        "cookies: a window other than 0 is NO_WINDOW");
  const ULONGLONG start = GetTickCount64();
  const int rc = zb_cookies_get_all(0, NULL, 300, &json, &err);
  const ULONGLONG took = GetTickCount64() - start;
  check(rc == ZB_AUTO_ERR_TIMEOUT && json == NULL, "cookies: before the loop starts, the deadline passes (TIMEOUT)");
  check(took >= 250 && took < 5000, "cookies: the call waited about its deadline");

  ZbCookie c = cookie("zbk", "v", -2);
  check(zb_cookies_add(0, &c, 100, &err) == ZB_AUTO_ERR_INTERNAL && err != NULL, "cookies: expires below -1 is refused");
  zb_automation_free(err);
  err = NULL;
  c.expires = ZB_COOKIE_MAX_EXPIRES + 1;
  check(zb_cookies_add(0, &c, 100, &err) == ZB_AUTO_ERR_INTERNAL && err != NULL, "cookies: expires past 9999 is refused");
  zb_automation_free(err);
  err = NULL;
  c = cookie(NULL, "v", -1);
  check(zb_cookies_add(0, &c, 100, &err) == ZB_AUTO_ERR_INTERNAL, "cookies: a cookie with no name is refused");
  zb_automation_free(err);
  err = NULL;
  check(zb_cookies_delete(0, "", NULL, 100, &err) == ZB_AUTO_ERR_INTERNAL, "cookies: delete needs a name");
  zb_automation_free(err);
}

static int run_rc = -1;

static DWORD WINAPI loop_main(LPVOID unused) {
  (void)unused;
  run_rc = zb_app_run("about:blank", 0, 0);
  return 0;
}

static void with_loop(void) {
  char dir[MAX_PATH], ebwebview[MAX_PATH];
  char *json = NULL, *err = NULL;
  join(dir, "profile");
  check(zb_app_set_profile_dir(dir, &err) == ZB_AUTO_OK, "loop: the profile directory is set");
  HANDLE thread = CreateThread(NULL, 0, loop_main, NULL, 0, NULL);
  if (!check(thread != NULL, "loop: zb_app_run starts on its own thread")) {
    return;
  }

  ZbCookie session = cookie("zbk", "v1", -1);
  /* 30 days out: Chromium (WebView2) caps a cookie's lifetime at 400 days, GTK does not. */
  const long long expiry = (long long)time(NULL) + 30LL * 86400;
  char expiry_field[64];
  snprintf(expiry_field, sizeof(expiry_field), "\"expires\":%lld,", expiry);
  ZbCookie lasting = cookie("zbp", "v2", expiry);
  int rc = zb_cookies_add(0, &session, 60000, &err);
  if (!check(rc == ZB_AUTO_OK && err == NULL, "loop: a session cookie is added (the call waits for the WebView)")) {
    printf("     rc=%d err=%s run_rc=%d\n", rc, err != NULL ? err : "(none)", run_rc);
  }
  check(zb_cookies_add(0, &lasting, 10000, &err) == ZB_AUTO_OK, "loop: a persistent cookie is added");
  ZbCookie elsewhere = cookie("zbk", "v3", -1);
  elsewhere.domain = "other.test";
  check(zb_cookies_add(0, &elsewhere, 10000, &err) == ZB_AUTO_OK, "loop: the same name on another domain is added");
  rc = zb_cookies_get_all(0, "https://example.test/", 10000, &json, &err);
  check(rc == ZB_AUTO_OK && json != NULL, "loop: the cookies for https://example.test/ are read");
  printf("     %s\n", json != NULL ? json : "(none)");
  check(contains(json, "{\"name\":\"zbk\",\"value\":\"v1\",\"domain\":\"example.test\",\"path\":\"/\",\"expires\":-1,"),
        "loop: the session cookie reads back with expires -1");
  check(contains(json, "\"name\":\"zbp\",\"value\":\"v2\"") && contains(json, expiry_field),
        "loop: the persistent cookie reads back with its expiry");
  check(contains(json, "\"sameSite\":\"Lax\""), "loop: SameSite reads back");
  zb_automation_free(json);
  json = NULL;

  check(zb_cookies_delete(0, "zbk", ".example.test", 10000, &err) == ZB_AUTO_OK, "loop: delete by name and domain (leading dot ignored)");
  check(zb_cookies_delete(0, "nothing-here", NULL, 10000, &err) == ZB_AUTO_OK, "loop: deleting nothing is not an error");
  rc = zb_cookies_get_all(0, NULL, 10000, &json, &err);
  check(rc == ZB_AUTO_OK && !contains(json, "\"name\":\"zbk\",\"value\":\"v1\"") && contains(json, "\"name\":\"zbp\"") &&
            contains(json, "\"name\":\"zbk\",\"value\":\"v3\",\"domain\":\"other.test\""),
        "loop: only that name on that domain is gone (url NULL = the whole store)");
  zb_automation_free(json);
  json = NULL;

  snprintf(ebwebview, sizeof(ebwebview), "%s\\WebView2\\EBWebView", dir);
  check(is_dir(ebwebview), "loop: WebView2 keeps its data in <dir>\\WebView2");

  HWND hwnd = FindWindowA("zigBrowserWebView2Host", NULL);
  check(hwnd != NULL, "loop: the host window exists");
  if (hwnd != NULL) {
    PostMessageA(hwnd, WM_CLOSE, 0, 0);
  }
  check(WaitForSingleObject(thread, 30000) == WAIT_OBJECT_0, "loop: closing the window ends zb_app_run");
  check(run_rc == ZB_EXIT_SUCCESS, "loop: zb_app_run returns success");
  CloseHandle(thread);
  rc = zb_cookies_get_all(0, NULL, 1000, &json, &err);
  check(rc == ZB_AUTO_ERR_NO_LOOP && json == NULL, "loop: after the loop ends, a call is NO_LOOP");
}

static void remove_tree(void) {
  char from[MAX_PATH + 2] = {0};
  snprintf(from, MAX_PATH, "%s", base); /* double-NUL terminated */
  SHFILEOPSTRUCTA op = {0};
  op.wFunc = FO_DELETE;
  op.pFrom = from;
  op.fFlags = FOF_NO_UI;
  for (int i = 0; i < 10 && is_dir(base); ++i) { /* WebView2's processes let go of the folder late */
    SHFileOperationA(&op);
    if (is_dir(base)) {
      Sleep(500);
    }
  }
}

int main(void) {
  char tmp[MAX_PATH];
  GetTempPathA(sizeof(tmp), tmp);
  snprintf(base, sizeof(base), "%szb-ws3-shim-%lu", tmp, (unsigned long)GetCurrentProcessId());
  CreateDirectoryA(base, NULL);
  policies();
  profile_dir();
  cookies_without_loop();
  with_loop();
  remove_tree();
  printf("%d failed\n", failures);
  return failures == 0 ? 0 : 1;
}
