#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <objbase.h>
#include <shlobj.h>
#include <wrl.h>
#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <atomic>
#include <deque>
#include <functional>
#include <vector>
#include <string>

#include "webkit_shim.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

constexpr wchar_t kWindowClassName[] = L"zigBrowserWebView2Host";
constexpr int kWebView2LoadFailDomain = 2;
constexpr UINT_PTR kNavigationTimerId = 1;
constexpr UINT kNavigationTimeoutMs = 15000;
// WS3: wakes the UI thread to run the queued jobs (the queue, not the message, owns them).
constexpr UINT WM_ZB_JOB = WM_APP + 1;

struct AppState {
  HWND hwnd = nullptr;
  HINSTANCE instance = nullptr;
  std::wstring uri;
  bool print_title = false;
  bool e2e_protocol = false;
  // WS1/6c771ff: an INERT e2e-only seam to force one screenshot-failure branch (watchdog/navigate/
  // docscript) so the live branch tests can select each deterministically. Null unless --e2e-protocol AND
  // ZB_E2E_FORCE_SCREENSHOT_FAIL is set; never consulted in normal runs.
  const char *force_screenshot_fail = nullptr;
  int exit_code = ZB_EXIT_SUCCESS;
  bool navigation_completed = false;
  bool screenshot = false;
  std::wstring out_path;

  ComPtr<ICoreWebView2Environment> environment;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> webview;

  // WS5 (OD-W6): the native Win32 agent drawer. `agent_drawer_on` mirrors the Zig switch
  // (zb_app_get_agent_drawer, set by webkit.applyAgentDrawer before zb_app_run). `drawer_open` is the
  // e2e-only startup-open seam (ZIGBROWSER_AGENT_DRAWER_OPEN, honoured only under --e2e-protocol). The
  // panel docks below the page and the floating "S" icon sits above it; geometry comes from the portable
  // zb_drawer_* logic (src/agent_drawer.zig) — no geometry math in C++.
  bool agent_drawer_on = false;
  bool drawer_open = false;
  bool drawer_mounted = false;
  int win_id = 1;
  HWND drawer_panel = nullptr;
  HWND drawer_icon = nullptr;
};

// The portable drawer geometry (src/agent_drawer.zig, exported for Windows). Rect matches Zig's
// `extern struct { x, y, w, h: c_int }`.
extern "C" {
struct ZbDrawerGeomRect { int x, y, w, h; };
void zb_drawer_panel_rect(int width, int height, ZbDrawerGeomRect *out);
void zb_drawer_place(const void *ratios, int width, int height, ZbDrawerGeomRect *out);
}

// WS5 shim functions (declared in webkit_shim.h), defined here for the Windows backend.
static std::atomic<int> g_agent_drawer_enabled{0};
static std::atomic<int> g_drawer_live{0};
extern "C" void zb_app_set_agent_drawer(int enabled) { g_agent_drawer_enabled.store(enabled != 0); }
extern "C" int zb_app_get_agent_drawer(void) { return g_agent_drawer_enabled.load(); }
extern "C" int zb_drawer_debug_live_count(void) { return g_drawer_live.load(); }

void emit_safe_field(const char *text) {
  const char *p = text != nullptr ? text : "";
  for (; *p != '\0'; ++p) {
    if (*p == '\t' || *p == '\n' || *p == '\r') {
      fputc(' ', stdout);
    } else {
      fputc(*p, stdout);
    }
  }
}

void emit_protocol2(const AppState *app, const char *tag, const char *a,
                    const char *b) {
  if (app == nullptr || !app->e2e_protocol) {
    return;
  }

  fputs(tag, stdout);
  fputc('\t', stdout);
  emit_safe_field(a);
  fputc('\t', stdout);
  emit_safe_field(b);
  fputc('\n', stdout);
  fflush(stdout);
}

void emit_protocol3(const AppState *app, const char *tag, const char *a,
                    const char *b, const char *c) {
  if (app == nullptr || !app->e2e_protocol) {
    return;
  }

  fputs(tag, stdout);
  fputc('\t', stdout);
  emit_safe_field(a);
  fputc('\t', stdout);
  emit_safe_field(b);
  fputc('\t', stdout);
  emit_safe_field(c);
  fputc('\n', stdout);
  fflush(stdout);
}

size_t skip_ws(const std::string &json, size_t pos) {
  while (pos < json.size() &&
         isspace(static_cast<unsigned char>(json[pos])) != 0) {
    pos++;
  }
  return pos;
}

bool find_field_value(const std::string &json, const char *field,
                      size_t *out_pos) {
  const std::string key = std::string("\"") + field + "\"";
  size_t pos = json.find(key);
  if (pos == std::string::npos) {
    return false;
  }

  pos = skip_ws(json, pos + key.size());
  if (pos >= json.size() || json[pos] != ':') {
    return false;
  }

  *out_pos = skip_ws(json, pos + 1);
  return *out_pos < json.size();
}

bool parse_json_string_at(const std::string &json, size_t pos,
                          std::string *out_value, size_t *out_end) {
  if (pos >= json.size() || json[pos] != '"') {
    return false;
  }

  std::string value;
  pos++;
  while (pos < json.size()) {
    char ch = json[pos++];
    if (ch == '"') {
      if (out_value != nullptr) {
        *out_value = value;
      }
      if (out_end != nullptr) {
        *out_end = pos;
      }
      return true;
    }
    if (ch == '\\' && pos < json.size()) {
      char escaped = json[pos++];
      switch (escaped) {
      case '"':
      case '\\':
      case '/':
        value.push_back(escaped);
        break;
      case 'b':
        value.push_back('\b');
        break;
      case 'f':
        value.push_back('\f');
        break;
      case 'n':
        value.push_back('\n');
        break;
      case 'r':
        value.push_back('\r');
        break;
      case 't':
        value.push_back('\t');
        break;
      default:
        value.push_back(escaped);
        break;
      }
      continue;
    }
    value.push_back(ch);
  }

  return false;
}

bool parse_json_string_field(const std::string &json, const char *field,
                             std::string *out_value) {
  size_t pos = 0;
  return find_field_value(json, field, &pos) &&
         parse_json_string_at(json, pos, out_value, nullptr);
}

bool parse_json_number_field(const std::string &json, const char *field,
                             long long *out_value) {
  size_t pos = 0;
  if (!find_field_value(json, field, &pos)) {
    return false;
  }

  const char *start = json.c_str() + pos;
  char *end = nullptr;
  long long value = strtoll(start, &end, 10);
  if (end == start) {
    return false;
  }

  *out_value = value;
  return true;
}

bool parse_json_value_field(const std::string &json, const char *field,
                            std::string *out_value) {
  size_t pos = 0;
  if (!find_field_value(json, field, &pos)) {
    return false;
  }

  const size_t start = pos;
  if (json[pos] == '{' || json[pos] == '[') {
    const char open = json[pos];
    const char close = open == '{' ? '}' : ']';
    int depth = 0;
    bool in_string = false;
    bool escaped = false;

    while (pos < json.size()) {
      const char ch = json[pos++];
      if (in_string) {
        if (escaped) {
          escaped = false;
        } else if (ch == '\\') {
          escaped = true;
        } else if (ch == '"') {
          in_string = false;
        }
        continue;
      }

      if (ch == '"') {
        in_string = true;
      } else if (ch == open) {
        depth++;
      } else if (ch == close) {
        depth--;
        if (depth == 0) {
          break;
        }
      }
    }
  } else if (json[pos] == '"') {
    if (!parse_json_string_at(json, pos, nullptr, &pos)) {
      return false;
    }
  } else {
    while (pos < json.size() && json[pos] != ',' && json[pos] != '}') {
      pos++;
    }
  }

  if (pos <= start) {
    return false;
  }

  size_t end = pos;
  while (end > start && isspace(static_cast<unsigned char>(json[end - 1])) != 0) {
    end--;
  }

  *out_value = json.substr(start, end - start);
  return true;
}

std::string json_quote(const char *text) {
  std::string out = "\"";
  const char *p = text != nullptr ? text : "";
  for (; *p != '\0'; ++p) {
    switch (*p) {
    case '"':
      out += "\\\"";
      break;
    case '\\':
      out += "\\\\";
      break;
    case '\n':
      out += "\\n";
      break;
    case '\r':
      out += "\\r";
      break;
    case '\t':
      out += "\\t";
      break;
    default:
      out.push_back(*p);
      break;
    }
  }
  out.push_back('"');
  return out;
}

std::wstring utf8_to_wide(const char *text) {
  if (text == nullptr || text[0] == '\0') {
    return std::wstring();
  }

  const int needed =
      MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, nullptr, 0);
  if (needed <= 0) {
    return std::wstring();
  }

  std::wstring out(static_cast<size_t>(needed - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, out.data(),
                      needed);
  return out;
}

std::string wide_to_utf8(const wchar_t *text) {
  if (text == nullptr || text[0] == L'\0') {
    return std::string();
  }

  const int needed =
      WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr, nullptr);
  if (needed <= 0) {
    return std::string();
  }

  std::string out(static_cast<size_t>(needed - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), needed, nullptr,
                      nullptr);
  return out;
}

bool webview2_runtime_version(char *buf, size_t len) {
  if (buf == nullptr || len == 0) {
    return false;
  }

  LPWSTR wide_version = nullptr;
  HRESULT hr =
      GetAvailableCoreWebView2BrowserVersionString(nullptr, &wide_version);
  if (FAILED(hr) || wide_version == nullptr || wide_version[0] == L'\0') {
    if (wide_version != nullptr) {
      CoTaskMemFree(wide_version);
    }
    return false;
  }

  int written = WideCharToMultiByte(CP_UTF8, 0, wide_version, -1, buf,
                                    static_cast<int>(len), nullptr, nullptr);
  CoTaskMemFree(wide_version);
  return written > 0;
}

void log_hresult(const char *stage, HRESULT hr) {
  fprintf(stderr, "%s failed: HRESULT=0x%08lx\n", stage,
          static_cast<unsigned long>(hr));
  fflush(stderr);
}

void log_last_error(const char *stage) {
  fprintf(stderr, "%s failed: GetLastError=%lu\n", stage,
          static_cast<unsigned long>(GetLastError()));
  fflush(stderr);
}

// ---- WS3: configuration set before zb_app_run, read when the environment is made ----

std::wstring g_user_data_folder; // <dir>\WebView2; empty = WebView2's default
volatile LONG g_hw_policy = ZB_HW_POLICY_WEBKIT;
volatile LONG g_media_source = 1;

// The GTK script, byte for byte (webkit_shim.c zb_media_source_hide_js).
constexpr wchar_t kMediaSourceHideJs[] =
    L"for (const name of ['MediaSource', 'ManagedMediaSource', 'SourceBuffer', "
    L"'SourceBufferList', 'ManagedSourceBuffer']) { try { delete globalThis[name]; } catch (e) {} }";

char *dup_c(const std::string &text) {
  char *p = static_cast<char *>(malloc(text.size() + 1));
  if (p != nullptr) {
    memcpy(p, text.c_str(), text.size() + 1);
  }
  return p;
}

int fail_with(char **out_err, const char *text) {
  if (out_err != nullptr) {
    *out_err = dup_c(text);
  }
  return ZB_AUTO_ERR_INTERNAL;
}

// ---- WS3: a call from another thread, run on the UI thread that owns the WebView ----
// States (RoseCat 6504): QUEUED -> RUNNING (the UI side's atomic claim, the moment the job
// starts) -> COMPLETING -> DONE (the one completion: whoever moves RUNNING -> COMPLETING writes
// the answer, then DONE and the event). The waiter whose deadline passes moves QUEUED or RUNNING
// to ABANDONED: an abandoned job that had not started never runs, and a late answer is
// dropped. A started job sits in the in-flight list until its completion, so loop end answers
// it ZB_AUTO_ERR_NO_LOOP even while WebView2 still holds its callback. References: the
// waiter's, the UI side's (the queue's, then the in-flight list's), and one per pending
// WebView2 callback, so a callback after loop end finds the job alive and changes nothing.
// Jobs wait in the queue until the WebView exists; when the loop ends, every queued and
// in-flight job, and every later call, is ZB_AUTO_ERR_NO_LOOP. Before zb_app_run a call waits
// for the loop up to its deadline.

constexpr LONG kQueued = 0;
constexpr LONG kRunning = 1;
constexpr LONG kCompleting = 2;
constexpr LONG kDone = 3;
constexpr LONG kAbandoned = 4;

struct Job {
  volatile LONG refs = 2;
  volatile LONG state = kQueued;
  HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::function<void(Job *, AppState *)> run; // ends with exactly one job_finish
  int code = ZB_AUTO_ERR_INTERNAL;            // the answer, written only by the completion
  std::string json;
  std::string err;
};

SRWLOCK g_jobs_lock = SRWLOCK_INIT;
std::deque<Job *> g_jobs;     // under g_jobs_lock: not started yet
std::vector<Job *> g_running; // under g_jobs_lock: started, not completed
HWND g_job_hwnd = nullptr;    // under g_jobs_lock: the loop's window while it runs
bool g_loop_ended = false;    // under g_jobs_lock
DWORD g_loop_thread = 0;
HANDLE g_loop_started = CreateEventW(nullptr, TRUE, FALSE, nullptr);

// Test seams (ws3_shim_test.c; inert at 0): the UI side waits this long before it commits to
// running a job; and WebView2's cookie-read completion is parked until the test runs it.
volatile LONG g_debug_hold_ms = 0;
volatile LONG g_debug_park = 0;
SRWLOCK g_parked_lock = SRWLOCK_INIT;
std::vector<std::function<void()>> g_parked; // under g_parked_lock

void job_hold(Job *job) { InterlockedIncrement(&job->refs); }

void job_release(Job *job) {
  if (InterlockedDecrement(&job->refs) == 0) {
    if (job->done != nullptr) {
      CloseHandle(job->done);
    }
    delete job;
  }
}

// The one completion of a started job; false when it was abandoned or completed already.
bool job_complete(Job *job, int code, std::string json = {}, std::string err = {}) {
  if (InterlockedCompareExchange(&job->state, kCompleting, kRunning) != kRunning) {
    return false;
  }
  job->code = code;
  job->json = std::move(json);
  job->err = std::move(err);
  InterlockedExchange(&job->state, kDone);
  SetEvent(job->done);
  return true;
}

// The UI side's end of a started job: its completion (if still wanted), and the in-flight
// list's reference, unless loop end took the list already.
void job_finish(Job *job, int code, std::string json = {}, std::string err = {}) {
  job_complete(job, code, std::move(json), std::move(err));
  AcquireSRWLockExclusive(&g_jobs_lock);
  auto it = std::find(g_running.begin(), g_running.end(), job);
  const bool listed = it != g_running.end();
  if (listed) {
    g_running.erase(it);
  }
  ReleaseSRWLockExclusive(&g_jobs_lock);
  if (listed) {
    job_release(job);
  }
}

// A WebView2 completion: job_finish, then the callback's own reference. Parked instead while
// the test seam asks.
void callback_done(Job *job, int code, std::string json = {}, std::string err = {}) {
  auto finish = [job, code, json = std::move(json), err = std::move(err)]() mutable {
    job_finish(job, code, std::move(json), std::move(err));
    job_release(job);
  };
  if (InterlockedCompareExchange(&g_debug_park, 0, 0) != 0) {
    AcquireSRWLockExclusive(&g_parked_lock);
    g_parked.push_back(std::move(finish));
    ReleaseSRWLockExclusive(&g_parked_lock);
    return;
  }
  finish();
}

Job *job_take() {
  AcquireSRWLockExclusive(&g_jobs_lock);
  Job *job = nullptr;
  if (!g_jobs.empty()) {
    job = g_jobs.front();
    g_jobs.pop_front();
  }
  ReleaseSRWLockExclusive(&g_jobs_lock);
  return job;
}

// UI thread: runs every queued job once the WebView exists.
void drain_jobs(AppState *app) {
  if (app == nullptr || !app->webview) {
    return;
  }
  while (Job *job = job_take()) {
    const LONG hold = InterlockedCompareExchange(&g_debug_hold_ms, 0, 0);
    if (hold > 0) {
      Sleep(static_cast<DWORD>(hold));
    }
    if (InterlockedCompareExchange(&job->state, kRunning, kQueued) != kQueued) {
      job_release(job); // abandoned before it started: never run
      continue;
    }
    AcquireSRWLockExclusive(&g_jobs_lock);
    g_running.push_back(job); // the queue's reference moves to the in-flight list
    ReleaseSRWLockExclusive(&g_jobs_lock);
    job->run(job, app);
  }
}

void loop_begin(AppState *app) {
  AcquireSRWLockExclusive(&g_jobs_lock);
  g_job_hwnd = app->hwnd;
  g_loop_ended = false;
  g_loop_thread = GetCurrentThreadId();
  ReleaseSRWLockExclusive(&g_jobs_lock);
  SetEvent(g_loop_started);
}

void loop_end() {
  AcquireSRWLockExclusive(&g_jobs_lock);
  g_loop_ended = true;
  g_job_hwnd = nullptr;
  std::deque<Job *> queued;
  std::vector<Job *> running;
  queued.swap(g_jobs);
  running.swap(g_running);
  ReleaseSRWLockExclusive(&g_jobs_lock);
  for (Job *job : queued) {
    if (InterlockedCompareExchange(&job->state, kRunning, kQueued) == kQueued) {
      job_complete(job, ZB_AUTO_ERR_NO_LOOP);
    }
    job_release(job);
  }
  for (Job *job : running) { // its WebView2 callback, if it ever comes, changes nothing
    job_complete(job, ZB_AUTO_ERR_NO_LOOP);
    job_release(job);
  }
}

// Caller side: `run` already holds copies of the inputs.
int job_submit(uint32_t win, unsigned int timeout_ms, std::function<void(Job *, AppState *)> run,
               char **out_json, char **out_err) {
  if (out_json != nullptr) {
    *out_json = nullptr;
  }
  if (out_err != nullptr) {
    *out_err = nullptr;
  }
  if (win != 0) {
    return ZB_AUTO_ERR_NO_WINDOW; // the Windows shell has one window
  }
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  if (WaitForSingleObject(g_loop_started, timeout_ms) != WAIT_OBJECT_0) {
    return ZB_AUTO_ERR_TIMEOUT;
  }
  if (GetCurrentThreadId() == g_loop_thread) {
    return fail_with(out_err, "called on the UI thread");
  }
  Job *job = new Job();
  job->run = std::move(run);
  AcquireSRWLockExclusive(&g_jobs_lock);
  const bool queued = !g_loop_ended && g_job_hwnd != nullptr;
  if (queued) {
    g_jobs.push_back(job);
    PostMessageW(g_job_hwnd, WM_ZB_JOB, 0, 0);
  }
  ReleaseSRWLockExclusive(&g_jobs_lock);
  if (!queued) {
    InterlockedDecrement(&job->refs); // the queue never held it
    job_release(job);
    return ZB_AUTO_ERR_NO_LOOP;
  }
  const ULONGLONG now = GetTickCount64();
  const DWORD left = now >= deadline ? 0 : static_cast<DWORD>(deadline - now);
  if (WaitForSingleObject(job->done, left) != WAIT_OBJECT_0) {
    // The deadline passed: abandon the job before it starts, or its result while it runs.
    if (InterlockedCompareExchange(&job->state, kAbandoned, kQueued) == kQueued ||
        InterlockedCompareExchange(&job->state, kAbandoned, kRunning) == kRunning) {
      job_release(job);
      return ZB_AUTO_ERR_TIMEOUT;
    }
    WaitForSingleObject(job->done, INFINITE); // completing now: its answer is being written
  }
  const int code = job->code;
  if (code == ZB_AUTO_OK && out_json != nullptr && !job->json.empty()) {
    *out_json = dup_c(job->json);
  }
  if (code != ZB_AUTO_OK && out_err != nullptr && !job->err.empty()) {
    *out_err = dup_c(job->err);
  }
  job_release(job);
  return code;
}

// ---- WS3: the cookie store (the WebView's profile) ----

ComPtr<ICoreWebView2CookieManager> cookie_manager(AppState *app) {
  ComPtr<ICoreWebView2_2> webview2;
  ComPtr<ICoreWebView2CookieManager> manager;
  if (app->webview && SUCCEEDED(app->webview.As(&webview2)) && webview2) {
    webview2->get_CookieManager(&manager);
  }
  return manager;
}

// A JSON string with every control character escaped.
void json_append(std::string &out, const std::string &text) {
  out.push_back('"');
  for (unsigned char c : text) {
    if (c == '"' || c == '\\') {
      out.push_back('\\');
      out.push_back(static_cast<char>(c));
    } else if (c < 0x20) {
      char buf[8];
      snprintf(buf, sizeof(buf), "\\u%04x", c);
      out += buf;
    } else {
      out.push_back(static_cast<char>(c));
    }
  }
  out.push_back('"');
}

// One string property of a cookie: the getter runs first, then its CoTaskMem string is
// copied and freed (never read before the getter has written it).
std::string cookie_text(ICoreWebView2Cookie *cookie,
                        HRESULT (STDMETHODCALLTYPE ICoreWebView2Cookie::*get)(LPWSTR *)) {
  LPWSTR wide = nullptr;
  const HRESULT hr = (cookie->*get)(&wide);
  std::string text = SUCCEEDED(hr) && wide != nullptr ? wide_to_utf8(wide) : std::string();
  CoTaskMemFree(wide);
  return text;
}

const char *same_site_name(COREWEBVIEW2_COOKIE_SAME_SITE_KIND kind) {
  switch (kind) {
  case COREWEBVIEW2_COOKIE_SAME_SITE_KIND_LAX:
    return "Lax";
  case COREWEBVIEW2_COOKIE_SAME_SITE_KIND_STRICT:
    return "Strict";
  default:
    return "None";
  }
}

// The GTK shim's auto_cookies_json format, key for key.
std::string cookies_json(ICoreWebView2CookieList *list) {
  std::string out = "[";
  UINT count = 0;
  if (list != nullptr) {
    list->get_Count(&count);
  }
  for (UINT i = 0; i < count; ++i) {
    ComPtr<ICoreWebView2Cookie> cookie;
    if (FAILED(list->GetValueAtIndex(i, &cookie)) || !cookie) {
      continue;
    }
    double expires = -1;
    BOOL http_only = FALSE;
    BOOL secure = FALSE;
    BOOL session = TRUE;
    COREWEBVIEW2_COOKIE_SAME_SITE_KIND same_site = COREWEBVIEW2_COOKIE_SAME_SITE_KIND_NONE;
    if (out.size() > 1) {
      out.push_back(',');
    }
    out += "{\"name\":";
    json_append(out, cookie_text(cookie.Get(), &ICoreWebView2Cookie::get_Name));
    out += ",\"value\":";
    json_append(out, cookie_text(cookie.Get(), &ICoreWebView2Cookie::get_Value));
    out += ",\"domain\":";
    json_append(out, cookie_text(cookie.Get(), &ICoreWebView2Cookie::get_Domain));
    out += ",\"path\":";
    json_append(out, cookie_text(cookie.Get(), &ICoreWebView2Cookie::get_Path));
    cookie->get_IsSession(&session);
    cookie->get_Expires(&expires);
    cookie->get_IsHttpOnly(&http_only);
    cookie->get_IsSecure(&secure);
    cookie->get_SameSite(&same_site);
    char tail[160];
    snprintf(tail, sizeof(tail), ",\"expires\":%lld,\"httpOnly\":%s,\"secure\":%s,\"sameSite\":\"%s\"}",
             session ? -1LL : static_cast<long long>(expires), http_only ? "true" : "false",
             secure ? "true" : "false", same_site_name(same_site));
    out += tail;
  }
  out.push_back(']');
  return out;
}

std::string bare_domain(const std::string &domain) {
  return !domain.empty() && domain[0] == '.' ? domain.substr(1) : domain;
}

void request_quit(AppState *app, int exit_code) {
  if (app != nullptr) {
    app->exit_code = exit_code;
  }
  PostQuitMessage(exit_code);
}

// In screenshot mode a failure must never be silent. Open mode keeps its existing e2e-gated
// reporting (emit_load_fail only prints under --e2e-protocol), but --screenshot prints one
// diagnostic line on every failure path before it quits, so a nonzero exit is always explained.
void screenshot_diag(AppState *app, const char *reason) {
  if (app != nullptr && app->screenshot) {
    fprintf(stderr, "zigBrowser: screenshot: %s\n", reason);
    fflush(stderr);
  }
}

void close_webview(AppState *app) {
  if (app == nullptr) {
    return;
  }

  if (app->hwnd != nullptr) {
    KillTimer(app->hwnd, kNavigationTimerId);
  }
  if (app->controller) {
    app->controller->Close();
  }
  app->webview.Reset();
  app->controller.Reset();
  app->environment.Reset();
}

// WS5: lay out the page (WebView2) and the native drawer within the client area. When the drawer is open the
// panel docks full-width at the bottom (zb_drawer_panel_rect) and the page fills the region above it, so
// page_h + panel_h == client_h; when closed the page fills the client and the "S" icon shows at its rect
// (zb_drawer_place). No geometry math here — all rects come from the portable Zig logic.
void resize_controller(AppState *app) {
  if (app == nullptr || !app->controller || app->hwnd == nullptr) {
    return;
  }
  RECT cr = {};
  GetClientRect(app->hwnd, &cr);
  const int cw = cr.right - cr.left;
  const int ch = cr.bottom - cr.top;

  if (app->agent_drawer_on && app->drawer_mounted && app->drawer_open) {
    ZbDrawerGeomRect panel = {};
    zb_drawer_panel_rect(cw, ch, &panel);
    RECT page = {0, 0, cw, panel.y};  // the page fills the region above the docked panel
    app->controller->put_Bounds(page);
    if (app->drawer_panel) {
      MoveWindow(app->drawer_panel, panel.x, panel.y, panel.w, panel.h, TRUE);
      ShowWindow(app->drawer_panel, SW_SHOW);
    }
    if (app->drawer_icon) {
      ShowWindow(app->drawer_icon, SW_HIDE);  // the icon hides while the drawer is open (D4)
    }
    return;
  }

  RECT bounds = cr;
  app->controller->put_Bounds(bounds);
  if (app->drawer_panel) {
    ShowWindow(app->drawer_panel, SW_HIDE);
  }
  if (app->agent_drawer_on && app->drawer_mounted && app->drawer_icon) {
    ZbDrawerGeomRect icon = {};
    zb_drawer_place(nullptr, cw, ch, &icon);
    MoveWindow(app->drawer_icon, icon.x, icon.y, icon.w, icon.h, TRUE);
    ShowWindow(app->drawer_icon, SW_SHOW);
  }
}

// WS5: mount the native Win32 drawer once the window + controller exist. Creates the native panel + "S"
// icon child controls (OD-W6), emits the same DRAWER census row NAMES as the GTK backend (tree, icon, and
// open when opened), and lays the drawer out. e2e census rows are gated by --e2e-protocol inside emit_*.
void mount_drawer(AppState *app) {
  if (app == nullptr || !app->agent_drawer_on || app->drawer_mounted || app->hwnd == nullptr) {
    return;
  }
  app->drawer_mounted = true;
  RECT cr = {};
  GetClientRect(app->hwnd, &cr);
  const int cw = cr.right - cr.left;
  const int ch = cr.bottom - cr.top;

  ZbDrawerGeomRect icon = {};
  zb_drawer_place(nullptr, cw, ch, &icon);
  // Native Win32 controls (OD-W6): a docked panel and the floating "S" icon, children of the host window.
  app->drawer_panel = CreateWindowExW(0, L"STATIC", L"", WS_CHILD, 0, 0, 0, 0,
                                      app->hwnd, nullptr, app->instance, nullptr);
  app->drawer_icon = CreateWindowExW(0, L"STATIC", L"S", WS_CHILD | SS_CENTER,
                                     icon.x, icon.y, icon.w, icon.h, app->hwnd, nullptr, app->instance, nullptr);
  g_drawer_live.fetch_add(1, std::memory_order_relaxed);

  char win[16];
  snprintf(win, sizeof win, "%d", app->win_id);
  emit_protocol3(app, "DRAWER", win, "tree", "host,page,icon,panel");
  char rect[64];
  snprintf(rect, sizeof rect, "%d,%d,%d,%d", icon.x, icon.y, icon.w, icon.h);
  emit_protocol3(app, "DRAWER", win, "icon", rect);
  if (app->drawer_open) {
    ZbDrawerGeomRect panel = {};
    zb_drawer_panel_rect(cw, ch, &panel);
    snprintf(rect, sizeof rect, "%d,%d,%d,%d", panel.x, panel.y, panel.w, panel.h);
    emit_protocol3(app, "DRAWER", win, "open", rect);
  }
  resize_controller(app);  // dock the page / place the icon
}

void emit_load_fail(AppState *app, COREWEBVIEW2_WEB_ERROR_STATUS status) {
  char domain_buf[32];
  char code_buf[32];
  snprintf(domain_buf, sizeof(domain_buf), "%d", kWebView2LoadFailDomain);
  snprintf(code_buf, sizeof(code_buf), "%d", static_cast<int>(status));
  const std::string uri = wide_to_utf8(app != nullptr ? app->uri.c_str() : L"");
  emit_protocol3(app, "LOAD_FAIL", uri.c_str(), domain_buf, code_buf);
}

void emit_navigation_success(AppState *app) {
  if (app == nullptr || !app->webview) {
    return;
  }

  LPWSTR title_wide = nullptr;
  app->webview->get_DocumentTitle(&title_wide);
  const std::string title = wide_to_utf8(title_wide);
  if (title_wide != nullptr) {
    CoTaskMemFree(title_wide);
  }

  if (app->print_title) {
    printf("TITLE\t");
    emit_safe_field(title.c_str());
    fputc('\n', stdout);
    fflush(stdout);
  }

  const std::string uri = wide_to_utf8(app->uri.c_str());
  emit_protocol2(app, "NAV", uri.c_str(), title.c_str());
}

void handle_web_message(AppState *app,
                        ICoreWebView2WebMessageReceivedEventArgs *args) {
  if (app == nullptr || !app->webview || args == nullptr) {
    return;
  }

  LPWSTR message_wide = nullptr;
  HRESULT hr = args->TryGetWebMessageAsString(&message_wide);
  if (FAILED(hr) || message_wide == nullptr) {
    emit_protocol2(app, "IPCERR", "invalid", "BadArgs");
    return;
  }

  const std::string message = wide_to_utf8(message_wide);
  CoTaskMemFree(message_wide);

  long long id = 0;
  std::string cmd;
  std::string args_json;
  if (!parse_json_number_field(message, "id", &id) ||
      !parse_json_string_field(message, "cmd", &cmd)) {
    emit_protocol2(app, "IPCERR", "invalid", "BadArgs");
    return;
  }

  if (!parse_json_value_field(message, "args", &args_json)) {
    args_json = "{}";
  }

  const char *result_json = nullptr;
  const char *err_text = nullptr;
  const int rc =
      zb_ipc_dispatch(cmd.c_str(), args_json.c_str(), &result_json, &err_text);

  std::string reply = "{\"id\":" + std::to_string(id);
  if (rc == 0 && result_json != nullptr) {
    emit_protocol2(app, "IPC", cmd.c_str(), result_json);
    reply += ",\"result\":";
    reply += result_json;
  } else {
    const char *msg = err_text != nullptr ? err_text : "UnknownCommand";
    emit_protocol2(app, "IPCERR", cmd.c_str(), msg);
    reply += ",\"error\":";
    reply += json_quote(msg);
  }
  reply.push_back('}');

  const std::wstring reply_wide = utf8_to_wide(reply.c_str());
  if (!reply_wide.empty()) {
    app->webview->PostWebMessageAsString(reply_wide.c_str());
  }
}

LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam,
                             LPARAM lparam) {
  AppState *app =
      reinterpret_cast<AppState *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

  switch (msg) {
  case WM_NCCREATE: {
    auto *create = reinterpret_cast<CREATESTRUCTW *>(lparam);
    app = reinterpret_cast<AppState *>(create->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
    if (app != nullptr) {
      app->hwnd = hwnd;
    }
    return TRUE;
  }
  case WM_SIZE:
    resize_controller(app);
    return 0;
  case WM_ZB_JOB:
    drain_jobs(app);
    return 0;
  case WM_TIMER:
    if (app != nullptr && wparam == kNavigationTimerId &&
        !app->navigation_completed) {
      app->navigation_completed = true;
      KillTimer(hwnd, kNavigationTimerId);
      if (app->webview) {
        app->webview->Stop();
      }
      emit_load_fail(app, COREWEBVIEW2_WEB_ERROR_STATUS_TIMEOUT);
      screenshot_diag(app, "navigation timed out before the page loaded");
      request_quit(app, ZB_EXIT_TIMEOUT);
      return 0;
    }
    break;
  case WM_DESTROY:
    if (app != nullptr) {
      if (app->drawer_mounted) {
        // WS5: the child panel/icon are destroyed with the host window; account the live drawer going away
        // (zb_drawer_debug_live_count reaches 0 after every window closes — WS5.5).
        g_drawer_live.fetch_sub(1, std::memory_order_relaxed);
        app->drawer_mounted = false;
        app->drawer_panel = nullptr;
        app->drawer_icon = nullptr;
      }
      app->hwnd = nullptr;
    }
    PostQuitMessage(app != nullptr ? app->exit_code : ZB_EXIT_SUCCESS);
    return 0;
  default:
    return DefWindowProcW(hwnd, msg, wparam, lparam);
  }
}

bool create_host_window(AppState *app) {
  if (app == nullptr) {
    return false;
  }

  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = window_proc;
  wc.hInstance = app->instance;
  wc.lpszClassName = kWindowClassName;
  wc.hCursor =
      LoadCursorW(static_cast<HINSTANCE>(nullptr), MAKEINTRESOURCEW(32512));
  wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);

  const ATOM atom = RegisterClassExW(&wc);
  if (atom == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    log_last_error("RegisterClassExW");
    return false;
  }

  HWND hwnd = CreateWindowExW(0, kWindowClassName, L"zigBrowser",
                              WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
                              CW_USEDEFAULT, 1024, 768, nullptr, nullptr,
                              app->instance, app);
  if (hwnd == nullptr) {
    log_last_error("CreateWindowExW");
    return false;
  }

  ShowWindow(hwnd, SW_SHOWNORMAL);
  UpdateWindow(hwnd);
  return true;
}

void navigate(AppState *app) {
  if (app == nullptr || !app->webview) {
    screenshot_diag(app, "no WebView available to navigate");
    request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
    return;
  }

  // WS1/6c771ff inert e2e seam: deterministically drive one failure branch for the live branch tests.
  // 'navigate'  -> the synchronous Navigate-failure branch; 'docscript' -> the doc-script-failure branch
  // (same exact diagnostics as the real paths); 'watchdog' -> arm the timer but do NOT navigate, so the
  // REAL watchdog branch (WM_TIMER) fires after the timeout. Only under --e2e-protocol.
  if (app->e2e_protocol && app->force_screenshot_fail != nullptr) {
    const char *f = app->force_screenshot_fail;
    if (strcmp(f, "navigate") == 0) {
      screenshot_diag(app, "ICoreWebView2::Navigate failed to start");
      request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
      return;
    }
    if (strcmp(f, "docscript") == 0) {
      screenshot_diag(app, "AddScriptToExecuteOnDocumentCreated failed");
      request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
      return;
    }
    if (strcmp(f, "watchdog") == 0) {
      SetTimer(app->hwnd, kNavigationTimerId, kNavigationTimeoutMs, nullptr);
      return;  // never navigate: the real WM_TIMER watchdog branch fires after kNavigationTimeoutMs
    }
  }

  SetTimer(app->hwnd, kNavigationTimerId, kNavigationTimeoutMs, nullptr);
  const HRESULT hr = app->webview->Navigate(app->uri.c_str());
  if (FAILED(hr)) {
    KillTimer(app->hwnd, kNavigationTimerId);
    screenshot_diag(app, "ICoreWebView2::Navigate failed to start");
    request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
  }
}

HRESULT install_document_script_and_navigate(AppState *app) {
  if (app == nullptr || !app->webview) {
    return E_POINTER;
  }

  // M3 only needs the document-created hook live; M4/M5 wire the host IPC body.
  // WS3: with Media Source off, the GTK script hides the MSE constructors before page
  // script, in every top-level document and child frame.
  std::wstring script = L"window.__zigBrowserBackend = 'webview2';";
  if (InterlockedCompareExchange(&g_media_source, 0, 0) == 0) {
    script += kMediaSourceHideJs;
  }
  auto script_handler =
      Callback<ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler>(
          [app](HRESULT error_code, LPCWSTR script_id) -> HRESULT {
            (void)script_id;
            if (FAILED(error_code)) {
              screenshot_diag(app, "AddScriptToExecuteOnDocumentCreated failed");
              request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
              return S_OK;
            }

            navigate(app);
            return S_OK;
          });

  return app->webview->AddScriptToExecuteOnDocumentCreated(
      script.c_str(), script_handler.Get());
}

// Writes an IStream's whole content (the in-memory PNG CapturePreview produced) to `path`.
// Returns true on success; every failure prints its specific reason to stderr so an exit is
// never silent.
bool write_stream_to_file(IStream *stream, const std::wstring &path) {
  if (stream == nullptr) {
    fprintf(stderr, "zigBrowser: screenshot: null capture stream\n");
    fflush(stderr);
    return false;
  }
  // The stream's LOGICAL length (what CapturePreview actually wrote), not GlobalSize, which reports
  // the HGLOBAL's allocation and can include slack past the PNG's IEND.
  STATSTG stat = {};
  HRESULT hr = stream->Stat(&stat, STATFLAG_NONAME);
  if (FAILED(hr)) {
    fprintf(stderr, "zigBrowser: screenshot: IStream::Stat failed (HRESULT=0x%08lx)\n",
            static_cast<unsigned long>(hr));
    fflush(stderr);
    return false;
  }
  const ULONGLONG logical = stat.cbSize.QuadPart;
  if (logical == 0 || logical > 0xFFFFFFFFULL) {
    fprintf(stderr, "zigBrowser: screenshot: unexpected capture size (%llu bytes)\n",
            static_cast<unsigned long long>(logical));
    fflush(stderr);
    return false;
  }
  HGLOBAL hg = nullptr;
  hr = GetHGlobalFromStream(stream, &hg);
  if (FAILED(hr) || hg == nullptr) {
    fprintf(stderr, "zigBrowser: screenshot: GetHGlobalFromStream failed (HRESULT=0x%08lx)\n",
            static_cast<unsigned long>(hr));
    fflush(stderr);
    return false;
  }
  void *data = GlobalLock(hg);
  if (data == nullptr) {
    fprintf(stderr, "zigBrowser: screenshot: GlobalLock failed\n");
    fflush(stderr);
    return false;
  }
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    log_last_error("CreateFileW(screenshot output)");
    GlobalUnlock(hg);
    return false;
  }
  DWORD written = 0;
  const BOOL ok = WriteFile(file, data, static_cast<DWORD>(logical), &written, nullptr);
  if (!ok) {
    log_last_error("WriteFile(screenshot output)");
  }
  CloseHandle(file);
  GlobalUnlock(hg);
  if (!ok || written != logical) {
    if (ok) {
      fprintf(stderr, "zigBrowser: screenshot: short write (%lu of %llu bytes)\n", written,
              static_cast<unsigned long long>(logical));
      fflush(stderr);
    }
    DeleteFileW(path.c_str()); // never leave a partial/corrupt PNG behind
    return false;
  }
  return true;
}

// The --screenshot path: CapturePreview the loaded page into an in-memory PNG, write it to
// app->out_path, then quit. Every failure path prints a specific stderr line and returns a
// precise exit code, so a silent ZB_EXIT_SNAPSHOT_FAILED can never happen again.
void capture_screenshot(AppState *app) {
  if (app == nullptr || !app->webview) {
    fprintf(stderr, "zigBrowser: screenshot: no WebView to capture\n");
    fflush(stderr);
    request_quit(app, ZB_EXIT_SNAPSHOT_FAILED);
    return;
  }
  if (app->out_path.empty()) {
    fprintf(stderr, "zigBrowser: screenshot: no output path\n");
    fflush(stderr);
    request_quit(app, ZB_EXIT_WRITE_FAILED);
    return;
  }
  ComPtr<IStream> stream;
  HRESULT hr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
  if (FAILED(hr) || !stream) {
    fprintf(stderr, "zigBrowser: screenshot: CreateStreamOnHGlobal failed (HRESULT=0x%08lx)\n",
            static_cast<unsigned long>(hr));
    fflush(stderr);
    request_quit(app, ZB_EXIT_SNAPSHOT_FAILED);
    return;
  }
  hr = app->webview->CapturePreview(
      COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG, stream.Get(),
      Callback<ICoreWebView2CapturePreviewCompletedHandler>(
          [app, stream](HRESULT result) -> HRESULT {
            if (FAILED(result)) {
              log_hresult("CapturePreview", result);
              request_quit(app, ZB_EXIT_SNAPSHOT_FAILED);
              return S_OK;
            }
            if (!write_stream_to_file(stream.Get(), app->out_path)) {
              request_quit(app, ZB_EXIT_WRITE_FAILED);
              return S_OK;
            }
            request_quit(app, ZB_EXIT_SUCCESS);
            return S_OK;
          })
          .Get());
  if (FAILED(hr)) {
    log_hresult("CapturePreview start", hr);
    request_quit(app, ZB_EXIT_SNAPSHOT_FAILED);
  }
}

HRESULT create_controller(AppState *app) {
  if (app == nullptr || !app->environment || app->hwnd == nullptr) {
    return E_FAIL;
  }

  auto controller_handler =
      Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
          [app](HRESULT result, ICoreWebView2Controller *controller)
              -> HRESULT {
            if (FAILED(result) || controller == nullptr) {
              log_hresult("CreateCoreWebView2Controller", result);
              request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
              return S_OK;
            }

            app->controller = controller;
            HRESULT hr = app->controller->get_CoreWebView2(&app->webview);
            if (FAILED(hr) || !app->webview) {
              log_hresult("get_CoreWebView2", hr);
              request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
              return S_OK;
            }

            resize_controller(app);
            app->controller->put_IsVisible(TRUE);
            mount_drawer(app);  // WS5: mount the native drawer once the page is live (no-op unless on)

            ComPtr<ICoreWebView2Settings> settings;
            if (SUCCEEDED(app->webview->get_Settings(&settings)) && settings) {
              settings->put_IsScriptEnabled(TRUE);
              settings->put_AreDefaultScriptDialogsEnabled(TRUE);
            }

            EventRegistrationToken nav_token = {};
            app->webview->add_NavigationCompleted(
                Callback<ICoreWebView2NavigationCompletedEventHandler>(
                    [app](ICoreWebView2 *sender,
                          ICoreWebView2NavigationCompletedEventArgs *args)
                        -> HRESULT {
                      (void)sender;

                      BOOL is_success = FALSE;
                      if (args != nullptr) {
                        args->get_IsSuccess(&is_success);
                      }

                      app->navigation_completed = true;
                      if (app->hwnd != nullptr) {
                        KillTimer(app->hwnd, kNavigationTimerId);
                      }
                      if (!is_success) {
                        COREWEBVIEW2_WEB_ERROR_STATUS status =
                            COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
                        if (args != nullptr) {
                          args->get_WebErrorStatus(&status);
                        }
                        emit_load_fail(app, status);
                        screenshot_diag(app, "navigation failed; the page did not load");
                        request_quit(app, ZB_EXIT_LOAD_FAILED);
                        return S_OK;
                      }

                      emit_navigation_success(app);
                      if (app->screenshot) {
                        capture_screenshot(app);
                      }
                      return S_OK;
                    })
                    .Get(),
                &nav_token);

            EventRegistrationToken web_message_token = {};
            app->webview->add_WebMessageReceived(
                Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                    [app](ICoreWebView2 *sender,
                          ICoreWebView2WebMessageReceivedEventArgs *args)
                        -> HRESULT {
                      (void)sender;
                      handle_web_message(app, args);
                      return S_OK;
                    })
                    .Get(),
                &web_message_token);

            drain_jobs(app); // the calls that waited for the WebView

            hr = install_document_script_and_navigate(app);
            if (FAILED(hr)) {
              log_hresult("AddScriptToExecuteOnDocumentCreated", hr);
              request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
            }
            return S_OK;
          });

  return app->environment->CreateCoreWebView2Controller(
      app->hwnd, controller_handler.Get());
}

HRESULT create_environment(AppState *app) {
  auto env_handler =
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [app](HRESULT result, ICoreWebView2Environment *environment)
              -> HRESULT {
            if (FAILED(result) || environment == nullptr) {
              log_hresult("CreateCoreWebView2EnvironmentWithOptions callback",
                          result);
              request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
              return S_OK;
            }

            app->environment = environment;
            HRESULT hr = create_controller(app);
            if (FAILED(hr)) {
              log_hresult("CreateCoreWebView2Controller start", hr);
              request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
            }
            return S_OK;
          });

  // WS3: the profile's user data folder and the hardware-acceleration policy.
  auto options = Microsoft::WRL::Make<CoreWebView2EnvironmentOptions>();
  const LONG hw = InterlockedCompareExchange(&g_hw_policy, 0, 0);
  if (hw == ZB_HW_POLICY_NEVER) {
    options->put_AdditionalBrowserArguments(L"--disable-gpu");
  } else if (hw == ZB_HW_POLICY_ALWAYS) {
    options->put_AdditionalBrowserArguments(L"--ignore-gpu-blocklist");
  }
  return CreateCoreWebView2EnvironmentWithOptions(
      nullptr, g_user_data_folder.empty() ? nullptr : g_user_data_folder.c_str(),
      options.Get(), env_handler.Get());
}

int run_message_loop(AppState *app) {
  MSG msg = {};
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  return app != nullptr ? app->exit_code : static_cast<int>(msg.wParam);
}

} // namespace

// The shared core behind both entry points. `screenshot` adds the CapturePreview-on-load path
// (writes `out_path` then quits); otherwise it is the interactive open. In screenshot mode every
// navigation, timeout, start and capture failure names its reason on stderr (screenshot_diag /
// capture_screenshot). WS1.4: the runtime-missing path prints the documented, pinned diagnostic and exits
// ZB_EXIT_RUNTIME_MISSING (9); tests/windows/ws1_run_test.py WS14MissingRuntime asserts the exact text.
static int run_core(const char *uri, int print_title, int e2e_protocol, bool screenshot,
                    const char *out_path) {
  char version[128] = {0};
  if (!webview2_runtime_version(version, sizeof(version))) {
    // WS1.4 pinned message (exact, on STDERR — never stdout), then exit 9.
    fprintf(stderr, "zigBrowser: the Microsoft Edge WebView2 Runtime is not installed\n");
    fflush(stderr);
    return ZB_EXIT_RUNTIME_MISSING;
  }

  const HRESULT com_hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (FAILED(com_hr)) {
    log_hresult("CoInitializeEx", com_hr);
    return ZB_EXIT_WEBVIEW_INIT_FAILED;
  }

  AppState app;
  app.instance = GetModuleHandleW(nullptr);
  app.uri = utf8_to_wide(uri);
  app.print_title = print_title != 0;
  app.e2e_protocol = e2e_protocol != 0;
  if (app.e2e_protocol) {
    app.force_screenshot_fail = getenv("ZB_E2E_FORCE_SCREENSHOT_FAIL");  // inert e2e branch-selection seam
  }
  // WS5: the agent drawer is on iff webkit.applyAgentDrawer set the flag (before zb_app_run); screenshot
  // mode never mounts a drawer. The startup-open seam is e2e-only (a sibling of the demo seed).
  app.agent_drawer_on = (zb_app_get_agent_drawer() != 0) && !screenshot;
  if (app.agent_drawer_on && app.e2e_protocol) {
    const char *open_env = getenv("ZIGBROWSER_AGENT_DRAWER_OPEN");
    app.drawer_open = open_env != nullptr && open_env[0] != '\0' && !(open_env[0] == '0' && open_env[1] == '\0');
  }
  app.screenshot = screenshot;
  if (screenshot && out_path != nullptr) {
    app.out_path = utf8_to_wide(out_path);
  }

  int rc = ZB_EXIT_SUCCESS;
  if (app.uri.empty() || !create_host_window(&app)) {
    if (app.uri.empty()) {
      fprintf(stderr, "utf8_to_wide(uri) failed\n");
      fflush(stderr);
    }
    rc = ZB_EXIT_WEBVIEW_INIT_FAILED;
  } else {
    loop_begin(&app);
    HRESULT hr = create_environment(&app);
    if (FAILED(hr)) {
      log_hresult("CreateCoreWebView2EnvironmentWithOptions start", hr);
      rc = ZB_EXIT_WEBVIEW_INIT_FAILED;
    } else {
      rc = run_message_loop(&app);
    }
    loop_end();
  }

  close_webview(&app);
  if (app.hwnd != nullptr) {
    DestroyWindow(app.hwnd);
    app.hwnd = nullptr;
  }
  CoUninitialize();
  return rc;
}

extern "C" int zb_app_run(const char *uri, int print_title, int e2e_protocol) {
  return run_core(uri, print_title, e2e_protocol, false, nullptr);
}

extern "C" int zb_run_screenshot(const char *uri, const char *out_path,
                                  int print_title, int e2e_protocol) {
  if (out_path == nullptr || out_path[0] == '\0') {
    fprintf(stderr, "zigBrowser: screenshot: no output path given\n");
    fflush(stderr);
    return ZB_EXIT_WRITE_FAILED;
  }
  // 52a5aba fix: forward e2e_protocol (was hard-coded 0) so run_core caches it on the AppState and
  // the ZB_E2E_FORCE_SCREENSHOT_FAIL seam — which gates on app->e2e_protocol — can actually fire.
  return run_core(uri, print_title, e2e_protocol, true, out_path);
}

extern "C" void zb_version_line(char *buf, size_t len) {
  if (buf == nullptr || len == 0) {
    return;
  }

  char version[128] = {0};
  if (!webview2_runtime_version(version, sizeof(version))) {
    snprintf(buf, len, "zigBrowser (WebView2 unavailable)");
    buf[len - 1] = '\0';
    return;
  }

  // WS1.5: report WHAT ACTUALLY RAN — the WebView2 runtime version, the OS build and the EXECUTING
  // architecture. Win32 entry points are resolved via GetProcAddress (no Win10-SDK header dependency).
  // FAIL CLOSED (RoseCat 4cd6a14): if a lookup or call fails we emit an explicit "unavailable" token —
  // NEVER an invented default (no fabricated 10.0.0 or x86_64), so the field reflects what was actually
  // read. Form: "zigBrowser (WebView2 <ver>; Windows 10.0.<build>; <arch>)" (ws1_run_test WS15BuildInfo).
  char os_field[64];
  {
    struct ZbRtlOsVersionInfoW {
      unsigned long dwOSVersionInfoSize, dwMajorVersion, dwMinorVersion, dwBuildNumber, dwPlatformId;
      wchar_t szCSDVersion[128];
    } vi;
    memset(&vi, 0, sizeof(vi));
    vi.dwOSVersionInfoSize = sizeof(vi);
    typedef long(__stdcall * RtlGetVersion_t)(ZbRtlOsVersionInfoW *);
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    RtlGetVersion_t rgv =
        ntdll ? reinterpret_cast<RtlGetVersion_t>(GetProcAddress(ntdll, "RtlGetVersion")) : nullptr;
    if (rgv != nullptr && rgv(&vi) == 0) {
      snprintf(os_field, sizeof(os_field), "Windows %lu.%lu.%lu",
               vi.dwMajorVersion, vi.dwMinorVersion, vi.dwBuildNumber);
    } else {
      snprintf(os_field, sizeof(os_field), "Windows unavailable");  // fail closed, never a fabricated 10.0.0
    }
    os_field[sizeof(os_field) - 1] = '\0';
  }

  // Executing arch from IsWow64Process2: nativeMachine ARM64 while this (x64) process runs => emulation.
  // Only claim a concrete arch when the call SUCCEEDS; otherwise "unavailable" (never a fabricated x86_64).
  const char *arch = "unavailable";
  {
    typedef int(__stdcall * IsWow64Process2_t)(HANDLE, unsigned short *, unsigned short *);
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    IsWow64Process2_t iw =
        k32 ? reinterpret_cast<IsWow64Process2_t>(GetProcAddress(k32, "IsWow64Process2")) : nullptr;
    if (iw != nullptr) {
      unsigned short proc_machine = 0, native_machine = 0;
      if (iw(GetCurrentProcess(), &proc_machine, &native_machine)) {
        arch = (native_machine == 0xAA64) ? "x86_64-on-arm64" : "x86_64";  // ARM64 native => emulated x64
      }
    }
  }

  snprintf(buf, len, "zigBrowser (WebView2 %s; %s; %s)", version, os_field, arch);
  buf[len - 1] = '\0';
}

// ---- WS3: the config setters and the cookie store (webkit_shim.h) ----

extern "C" int zb_app_set_profile_dir(const char *dir, char **out_err) {
  if (out_err != nullptr) {
    *out_err = nullptr;
  }
  if (dir == nullptr || dir[0] == '\0') {
    g_user_data_folder.clear();
    return ZB_AUTO_OK;
  }
  const std::wstring wide = utf8_to_wide(dir);
  const DWORD need = wide.empty() ? 0 : GetFullPathNameW(wide.c_str(), 0, nullptr, nullptr);
  if (need == 0) {
    return fail_with(out_err, "the profile directory is not a valid path");
  }
  std::wstring full(need, L'\0');
  const DWORD got = GetFullPathNameW(wide.c_str(), need, &full[0], nullptr);
  if (got == 0 || got >= need) {
    return fail_with(out_err, "the profile directory is not a valid path");
  }
  full.resize(got);
  const std::wstring folder = full + L"\\WebView2"; // WS3.1: nothing beside the exe
  const int made = SHCreateDirectoryExW(nullptr, folder.c_str(), nullptr);
  const DWORD attrs = GetFileAttributesW(folder.c_str());
  if ((made != ERROR_SUCCESS && made != ERROR_ALREADY_EXISTS && made != ERROR_FILE_EXISTS) ||
      attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0) {
    return fail_with(out_err, "the profile directory cannot be created");
  }
  g_user_data_folder = folder;
  return ZB_AUTO_OK;
}

extern "C" void zb_app_set_hw_policy(int policy) {
  InterlockedExchange(&g_hw_policy, policy == ZB_HW_POLICY_NEVER || policy == ZB_HW_POLICY_ALWAYS
                                        ? policy
                                        : ZB_HW_POLICY_WEBKIT);
}

extern "C" int zb_app_get_hw_policy(void) { return InterlockedCompareExchange(&g_hw_policy, 0, 0); }

extern "C" void zb_app_set_media_source(int enabled) {
  InterlockedExchange(&g_media_source, enabled != 0 ? 1 : 0);
}

extern "C" int zb_app_get_media_source(void) { return InterlockedCompareExchange(&g_media_source, 0, 0); }

extern "C" void zb_automation_free(char *p) { free(p); }

extern "C" int zb_cookies_get_all(uint32_t win, const char *url, unsigned int timeout_ms,
                                  char **out_json, char **out_err) {
  const std::wstring uri = url != nullptr ? utf8_to_wide(url) : std::wstring();
  if (url != nullptr && url[0] != '\0' && uri.empty()) {
    if (out_json != nullptr) {
      *out_json = nullptr;
    }
    return fail_with(out_err, "the url is not valid UTF-8");
  }
  return job_submit(
      win, timeout_ms,
      [uri](Job *job, AppState *app) {
        ComPtr<ICoreWebView2CookieManager> manager = cookie_manager(app);
        if (!manager) {
          return job_finish(job, ZB_AUTO_ERR_INTERNAL, {}, "no cookie manager");
        }
        job_hold(job); // the callback's reference
        const HRESULT hr = manager->GetCookies(
            uri.c_str(), Callback<ICoreWebView2GetCookiesCompletedHandler>(
                             [job](HRESULT result, ICoreWebView2CookieList *list) -> HRESULT {
                               if (FAILED(result)) {
                                 callback_done(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store read failed");
                               } else {
                                 callback_done(job, ZB_AUTO_OK, cookies_json(list));
                               }
                               return S_OK;
                             })
                             .Get());
        if (FAILED(hr)) { // no callback will come
          job_release(job);
          job_finish(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store read failed");
        }
      },
      out_json, out_err);
}

extern "C" int zb_cookies_add(uint32_t win, const ZbCookie *cookie, unsigned int timeout_ms,
                              char **out_err) {
  if (out_err != nullptr) {
    *out_err = nullptr;
  }
  if (cookie == nullptr || cookie->name == nullptr || cookie->value == nullptr ||
      cookie->domain == nullptr) {
    return fail_with(out_err, "a cookie needs a name, a value and a domain");
  }
  if (cookie->expires < -1 || cookie->expires > ZB_COOKIE_MAX_EXPIRES) {
    return fail_with(out_err, "cookie expiry out of range");
  }
  struct Copy {
    std::wstring name, value, domain, path;
    long long expires;
    int http_only, secure, same_site;
  };
  const Copy c{utf8_to_wide(cookie->name),
               utf8_to_wide(cookie->value),
               utf8_to_wide(cookie->domain),
               utf8_to_wide(cookie->path != nullptr && cookie->path[0] != '\0' ? cookie->path : "/"),
               cookie->expires,
               cookie->http_only,
               cookie->secure,
               cookie->same_site};
  if (c.name.empty() || c.domain.empty()) {
    return fail_with(out_err, "a cookie needs a name and a domain");
  }
  return job_submit(
      win, timeout_ms,
      [c](Job *job, AppState *app) {
        ComPtr<ICoreWebView2CookieManager> manager = cookie_manager(app);
        ComPtr<ICoreWebView2Cookie> made;
        if (!manager ||
            FAILED(manager->CreateCookie(c.name.c_str(), c.value.c_str(), c.domain.c_str(),
                                         c.path.c_str(), &made)) ||
            !made) {
          return job_finish(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store write failed");
        }
        if (c.expires >= 0) {
          made->put_Expires(static_cast<double>(c.expires)); // else a session cookie
        }
        made->put_IsHttpOnly(c.http_only != 0 ? TRUE : FALSE);
        made->put_IsSecure(c.secure != 0 ? TRUE : FALSE);
        if (c.same_site != ZB_COOKIE_SAME_SITE_UNSET) {
          made->put_SameSite(c.same_site == ZB_COOKIE_SAME_SITE_STRICT ? COREWEBVIEW2_COOKIE_SAME_SITE_KIND_STRICT
                             : c.same_site == ZB_COOKIE_SAME_SITE_LAX  ? COREWEBVIEW2_COOKIE_SAME_SITE_KIND_LAX
                                                                       : COREWEBVIEW2_COOKIE_SAME_SITE_KIND_NONE);
        }
        if (FAILED(manager->AddOrUpdateCookie(made.Get()))) {
          return job_finish(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store write failed");
        }
        job_finish(job, ZB_AUTO_OK);
      },
      nullptr, out_err);
}

extern "C" int zb_cookies_delete(uint32_t win, const char *name, const char *domain,
                                 unsigned int timeout_ms, char **out_err) {
  if (out_err != nullptr) {
    *out_err = nullptr;
  }
  if (name == nullptr || name[0] == '\0') {
    return fail_with(out_err, "a cookie name is needed");
  }
  const std::string want_name = name;
  const bool any_domain = domain == nullptr;
  const std::string want_domain = any_domain ? std::string() : bare_domain(domain);
  return job_submit(
      win, timeout_ms,
      [want_name, any_domain, want_domain](Job *job, AppState *app) {
        ComPtr<ICoreWebView2CookieManager> manager = cookie_manager(app);
        if (!manager) {
          return job_finish(job, ZB_AUTO_ERR_INTERNAL, {}, "no cookie manager");
        }
        job_hold(job); // the callback's reference
        const HRESULT hr = manager->GetCookies(
            L"", Callback<ICoreWebView2GetCookiesCompletedHandler>(
                     [job, manager, want_name, any_domain, want_domain](
                         HRESULT result, ICoreWebView2CookieList *list) -> HRESULT {
                       if (FAILED(result)) {
                         callback_done(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store delete failed");
                         return S_OK;
                       }
                       UINT count = 0;
                       if (list != nullptr) {
                         list->get_Count(&count);
                       }
                       for (UINT i = 0; i < count; ++i) {
                         ComPtr<ICoreWebView2Cookie> cookie;
                         if (FAILED(list->GetValueAtIndex(i, &cookie)) || !cookie) {
                           continue;
                         }
                         if (cookie_text(cookie.Get(), &ICoreWebView2Cookie::get_Name) != want_name) {
                           continue;
                         }
                         if (!any_domain &&
                             bare_domain(cookie_text(cookie.Get(), &ICoreWebView2Cookie::get_Domain)) != want_domain) {
                           continue;
                         }
                         if (FAILED(manager->DeleteCookie(cookie.Get()))) {
                           callback_done(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store delete failed");
                           return S_OK;
                         }
                       }
                       callback_done(job, ZB_AUTO_OK); // deleting nothing is not an error
                       return S_OK;
                     })
                     .Get());
        if (FAILED(hr)) { // no callback will come
          job_release(job);
          job_finish(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store delete failed");
        }
      },
      nullptr, out_err);
}

// ---- WS3 test seams (tests/windows/ws3_shim_test.c only; inert until called) ----

extern "C" void zb_automation_debug_hold_dispatch_ms(unsigned int ms) {
  InterlockedExchange(&g_debug_hold_ms, static_cast<LONG>(ms));
}

extern "C" void zb_automation_debug_park_callbacks(int on) { InterlockedExchange(&g_debug_park, on != 0 ? 1 : 0); }

extern "C" int zb_automation_debug_parked_callbacks(void) {
  AcquireSRWLockShared(&g_parked_lock);
  const int count = static_cast<int>(g_parked.size());
  ReleaseSRWLockShared(&g_parked_lock);
  return count;
}

// Runs the parked completions on the calling thread (they touch only their jobs); returns how many.
extern "C" int zb_automation_debug_run_parked_callbacks(void) {
  std::vector<std::function<void()>> parked;
  AcquireSRWLockExclusive(&g_parked_lock);
  parked.swap(g_parked);
  ReleaseSRWLockExclusive(&g_parked_lock);
  for (auto &finish : parked) {
    finish();
  }
  return static_cast<int>(parked.size());
}
