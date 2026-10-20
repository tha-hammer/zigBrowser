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

#include <deque>
#include <functional>
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
  int exit_code = ZB_EXIT_SUCCESS;
  bool navigation_completed = false;

  ComPtr<ICoreWebView2Environment> environment;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> webview;
};

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
// The waiter and the queue each hold a reference. The job is answered at most once
// (state 0 waiting -> 1 answered); a waiter whose deadline passes abandons it (0 -> 2), so a
// late answer is dropped and an abandoned job that has not started never runs. Jobs wait in
// the queue until the WebView exists; when the loop ends, every queued job, and every later
// call, is ZB_AUTO_ERR_NO_LOOP. Before zb_app_run a call waits for the loop up to its deadline.

struct Job {
  volatile LONG refs = 2;
  volatile LONG state = 0;
  HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::function<void(Job *, AppState *)> run; // ends with exactly one job_answer
  int code = ZB_AUTO_ERR_INTERNAL;
  std::string json;
  std::string err;
};

SRWLOCK g_jobs_lock = SRWLOCK_INIT;
std::deque<Job *> g_jobs;  // under g_jobs_lock
HWND g_job_hwnd = nullptr; // under g_jobs_lock: the loop's window while it runs
bool g_loop_ended = false; // under g_jobs_lock
DWORD g_loop_thread = 0;
HANDLE g_loop_started = CreateEventW(nullptr, TRUE, FALSE, nullptr);

void job_release(Job *job) {
  if (InterlockedDecrement(&job->refs) == 0) {
    if (job->done != nullptr) {
      CloseHandle(job->done);
    }
    delete job;
  }
}

// UI side, once per job: the answer reaches a waiter that has not given up.
void job_answer(Job *job, int code, std::string json = {}, std::string err = {}) {
  job->code = code; // read by the waiter only after the event, i.e. after a 0 -> 1 win
  job->json = std::move(json);
  job->err = std::move(err);
  if (InterlockedCompareExchange(&job->state, 1, 0) == 0) {
    SetEvent(job->done);
  }
  job_release(job);
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
    if (InterlockedCompareExchange(&job->state, 0, 0) == 2) {
      job_release(job); // abandoned before it started: never run
      continue;
    }
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
  std::deque<Job *> left;
  left.swap(g_jobs);
  ReleaseSRWLockExclusive(&g_jobs_lock);
  for (Job *job : left) {
    job_answer(job, ZB_AUTO_ERR_NO_LOOP);
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
  if (WaitForSingleObject(job->done, left) != WAIT_OBJECT_0 &&
      InterlockedCompareExchange(&job->state, 2, 0) == 0) {
    job_release(job); // abandoned: a late answer is dropped
    return ZB_AUTO_ERR_TIMEOUT;
  }
  WaitForSingleObject(job->done, INFINITE); // answered, the race with the deadline included
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

void resize_controller(AppState *app) {
  if (app == nullptr || !app->controller || app->hwnd == nullptr) {
    return;
  }

  RECT bounds = {};
  GetClientRect(app->hwnd, &bounds);
  app->controller->put_Bounds(bounds);
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
      request_quit(app, ZB_EXIT_TIMEOUT);
      return 0;
    }
    break;
  case WM_DESTROY:
    if (app != nullptr) {
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
    request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
    return;
  }

  SetTimer(app->hwnd, kNavigationTimerId, kNavigationTimeoutMs, nullptr);
  const HRESULT hr = app->webview->Navigate(app->uri.c_str());
  if (FAILED(hr)) {
    KillTimer(app->hwnd, kNavigationTimerId);
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
              request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
              return S_OK;
            }

            navigate(app);
            return S_OK;
          });

  return app->webview->AddScriptToExecuteOnDocumentCreated(
      script.c_str(), script_handler.Get());
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
                        request_quit(app, ZB_EXIT_LOAD_FAILED);
                        return S_OK;
                      }

                      emit_navigation_success(app);
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

extern "C" int zb_app_run(const char *uri, int print_title, int e2e_protocol) {
  char version[128] = {0};
  if (!webview2_runtime_version(version, sizeof(version))) {
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

extern "C" int zb_run_screenshot(const char *uri, const char *out_path,
                                  int print_title) {
  (void)uri;
  (void)out_path;
  (void)print_title;
  return ZB_EXIT_SNAPSHOT_FAILED;
}

extern "C" void zb_version_line(char *buf, size_t len) {
  if (buf == nullptr || len == 0) {
    return;
  }

  char version[128] = {0};
  if (webview2_runtime_version(version, sizeof(version))) {
    snprintf(buf, len, "zigBrowser (WebView2 %s)", version);
  } else {
    snprintf(buf, len, "zigBrowser (WebView2 unavailable)");
  }
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
          return job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "no cookie manager");
        }
        const HRESULT hr = manager->GetCookies(
            uri.c_str(), Callback<ICoreWebView2GetCookiesCompletedHandler>(
                             [job](HRESULT result, ICoreWebView2CookieList *list) -> HRESULT {
                               if (FAILED(result)) {
                                 job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store read failed");
                               } else {
                                 job_answer(job, ZB_AUTO_OK, cookies_json(list));
                               }
                               return S_OK;
                             })
                             .Get());
        if (FAILED(hr)) {
          job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store read failed");
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
          return job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store write failed");
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
          return job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store write failed");
        }
        job_answer(job, ZB_AUTO_OK);
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
          return job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "no cookie manager");
        }
        const HRESULT hr = manager->GetCookies(
            L"", Callback<ICoreWebView2GetCookiesCompletedHandler>(
                     [job, manager, want_name, any_domain, want_domain](
                         HRESULT result, ICoreWebView2CookieList *list) -> HRESULT {
                       if (FAILED(result)) {
                         job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store delete failed");
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
                           job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store delete failed");
                           return S_OK;
                         }
                       }
                       job_answer(job, ZB_AUTO_OK); // deleting nothing is not an error
                       return S_OK;
                     })
                     .Get());
        if (FAILED(hr)) {
          job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store delete failed");
        }
      },
      nullptr, out_err);
}
