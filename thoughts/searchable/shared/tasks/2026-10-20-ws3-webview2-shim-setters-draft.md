---
date: 2026-10-20
author: BlackRobin (cc_1)
status: LANDED 2026-10-20 — red cfd218b, green 15fb6ee (proved on win11-m8). The code below is the draft; src/webview2_shim.cpp is the source of truth.
for: AzureRidge (WS3, 2ffe031 red `cross-check-ws3-win`), RoseCat (review)
plan: thoughts/searchable/shared/plans/2026-10-19-windows-launch-tdd-plan.md, WS3 coordination rev 2.4 ("BlackRobin: native C setters + the cookie manager/store, landed before the arms")
---

# WS3 step 2: the seven `webview2_shim.cpp` symbols, drafted

## Landed (2026-10-20): what changed from this draft

- **Red `cfd218b`:** `tests/windows/ws3_shim_test.c` (38 checks, linked with the shim) and the
  Windows-only step `ws3-shim-test-win`, run on the VM by
  `bash tests/windows/build-on-windows.sh ws3-shim-test-win`. On HEAD the link fails: the
  symbols are undefined.
- **Green `15fb6ee`:** 38 ok, 0 failed on win11-m8, MSVC. Three mutants are killed, each by
  exactly one check: no user data folder, delete ignores the domain, and loop end leaving the
  loop open. A fourth, ignoring IsSession, survives as equivalent: WebView2 already reports a
  session cookie's Expires as -1.
- **Design change:** jobs live in a queue under an SRW lock, and `WM_ZB_JOB` only wakes the
  UI thread. So loop end answers every queued job with NO_LOOP even if a posted message is
  dropped. A job abandoned before it starts never runs, and a call made on the UI thread is
  INTERNAL.
- **Bug fixed from this draft:** `co_string(cookie->get_Name(&text), text)` read `text` before
  the getter wrote it, because C++ argument order is unspecified. That is a use-after-free:
  each field got the previous field's freed string. It is now `cookie_text`: call the getter,
  copy the string, free it.
- **Open points:** point 2 is confirmed (a session cookie reads back with -1). New: WebView2
  caps a cookie's lifetime at **400 days** (RFC 6265bis), and GTK does not. Points 1, 3 and 5
  stand. The GPU arguments' and the MSE script's effect in a page wait for the WS3 e2es.

## Why this is a draft, not a commit

`cross-check-ws3-win` only checks names. It reads `webview2_shim.cpp` as text, and passes once each `zb_*` symbol is defined there. It never compiles the shim.

The shim can't be compiled on this Linux box. It needs the WebView2 SDK headers (`WebView2.h`, `WebView2EnvironmentOptions.h`) and `wrl.h`, and neither zig's mingw headers nor this machine have them.

If I committed this code now, the cross-check would go green while the real Windows build could still fail to compile. So under the orchestrator's rule it is drafted here and queued:
- It lands once it compiles against the SDK (the Win11 VM, or the coming Windows toolchain).
- It must pass WS3's own reds there: `win_profile_persist_test.py`, `win_config_flags_test.py` and `win_cookie_test.py`.
- Until then the cross-check stays red, as AzureRidge designed it.

What I reviewed without a build:
- Every signature below matches `src/webkit_shim.h:81-114, 246, 276-286` exactly.
- Every call site in `src/automation_wv2_cookie_port.zig` and `src/webview2_config.zig` passes `win` 0 and frees with `zb_automation_free`.
- The return codes are the `ZB_AUTO_*` enum.

## The seven symbols, and the getters

| Symbol | Behaviour on WebView2 |
|---|---|
| `zb_app_set_profile_dir(dir, out_err)` | Makes `<abs dir>\WebView2` (with its parents) and keeps it as the user data folder. `NULL` or `""` restores WebView2's default. A folder that can't be made, or a file in its place, gives `ZB_AUTO_ERR_INTERNAL` with `*out_err`. Call before `zb_app_run`. |
| `zb_app_set_hw_policy(p)` / `zb_app_get_hw_policy()` | `NEVER` passes `AdditionalBrowserArguments "--disable-gpu"`; `ALWAYS` passes `"--ignore-gpu-blocklist"` (force GPU on); `WEBKIT` (auto) passes nothing. Read when the environment is made. |
| `zb_app_set_media_source(on)` / `zb_app_get_media_source()` | Off adds the GTK script (`webkit_shim.c:4942-4945`, byte for byte) to the document-created script. That runs before page script in every top-level document and child frame. |
| `zb_automation_free(p)` | `free(p)`. Every string the shim hands out is `malloc`ed. |
| `zb_cookies_get_all(win, url, timeout_ms, out_json, out_err)` | `ICoreWebView2CookieManager::GetCookies(url or L"")`. The JSON is byte-compatible with GTK's `auto_cookies_json` (`webkit_shim.c:3178-3204`). |
| `zb_cookies_add(win, cookie, timeout_ms, out_err)` | `CreateCookie` + `put_*` + `AddOrUpdateCookie`. `expires` outside `[-1, ZB_COOKIE_MAX_EXPIRES]` gives `ZB_AUTO_ERR_INTERNAL`. |
| `zb_cookies_delete(win, name, domain, timeout_ms, out_err)` | `GetCookies(L"")`, then `DeleteCookie` on each cookie with that name and domain (leading dot ignored; `NULL` = every domain). Deleting nothing is not an error. |

Error text never carries a cookie value.

## The UI-thread marshal (WS2's design, built here first)

WebView2 objects belong to the UI (STA) thread. The automation server calls from its own thread. So each cookie call becomes a `Job`:
- It is posted to the host window as `WM_ZB_JOB`, and the caller waits with a deadline (`WaitForSingleObject`).
- Ownership is the WS2 / macOS MS2 contract:
  - inputs are copied before posting;
  - the job is answered exactly once (an interlocked state: waiting → answered, or waiting → abandoned);
  - a timed-out waiter abandons it, so a late completion is dropped, never written to freed memory;
  - two references (the waiter and the UI side) free it.
- A job that arrives before the WebView exists waits in `pending` and runs when the controller is ready.
- When the loop ends, every pending job, and every later call, gets `ZB_AUTO_ERR_NO_LOOP`.
- A call made before `zb_app_run` waits up to its deadline for the loop to start. This is GTK's rule (`webkit_shim.h:70-72`).
- `win` other than 0 is `ZB_AUTO_ERR_NO_WINDOW`: the Windows shell has one window.

## The draft code

Includes to add: `<shlobj.h>` (`SHCreateDirectoryExW`; shell32 is already linked), `<WebView2EnvironmentOptions.h>`, `<functional>`, `<deque>`, `<string.h>`.

```cpp
// ---- inside namespace { ----

constexpr UINT WM_ZB_JOB = WM_APP + 1;

std::wstring g_user_data_folder;          // zb_app_set_profile_dir: <dir>\WebView2; empty = WebView2's default
volatile LONG g_hw_policy = ZB_HW_POLICY_WEBKIT;
volatile LONG g_media_source = 1;

// The GTK script, byte for byte (webkit_shim.c:4942-4945).
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

int fail_with(char **out_err, const char *text, int code = ZB_AUTO_ERR_INTERNAL) {
  if (out_err != nullptr) {
    *out_err = dup_c(text);
  }
  return code;
}

// JSON string for cookie text: every control character escaped (json_quote above leaves some raw).
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

std::string co_string(HRESULT hr, LPWSTR wide) {  // takes ownership of a CoTaskMem string
  std::string text = SUCCEEDED(hr) && wide != nullptr ? wide_to_utf8(wide) : std::string();
  CoTaskMemFree(wide);
  return text;
}

struct Job {
  volatile LONG refs = 2;   // the waiter and the UI side
  volatile LONG state = 0;  // 0 waiting, 1 answered, 2 abandoned
  HANDLE done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  std::function<void(Job *)> run;  // UI thread; ends with exactly one job_answer
  int code = ZB_AUTO_ERR_INTERNAL;
  std::string json, err;
};

void job_release(Job *job) {
  if (InterlockedDecrement(&job->refs) == 0) {
    if (job->done != nullptr) {
      CloseHandle(job->done);
    }
    delete job;
  }
}

// UI side, exactly once per job: the answer reaches a waiter that has not given up.
void job_answer(Job *job, int code, std::string json = {}, std::string err = {}) {
  job->code = code;  // the waiter reads these only after the event, i.e. after a 0 -> 1 win
  job->json = std::move(json);
  job->err = std::move(err);
  if (InterlockedCompareExchange(&job->state, 1, 0) == 0) {
    SetEvent(job->done);
  }
  job_release(job);
}

SRWLOCK g_app_lock = SRWLOCK_INIT;
AppState *g_app = nullptr;       // set while zb_app_run's loop runs
bool g_loop_ended = false;
HANDLE g_loop_started = CreateEventW(nullptr, TRUE, FALSE, nullptr);

// Caller side: copied inputs are already in `run`'s captures.
int job_submit(uint32_t win, unsigned int timeout_ms, std::function<void(Job *)> run,
               char **out_json, char **out_err) {
  if (out_json != nullptr) *out_json = nullptr;
  if (out_err != nullptr) *out_err = nullptr;
  if (win != 0) {
    return ZB_AUTO_ERR_NO_WINDOW;
  }
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  if (WaitForSingleObject(g_loop_started, timeout_ms) != WAIT_OBJECT_0) {
    return ZB_AUTO_ERR_TIMEOUT;
  }
  Job *job = new Job();
  job->run = std::move(run);
  AcquireSRWLockShared(&g_app_lock);
  const bool posted = !g_loop_ended && g_app != nullptr && g_app->hwnd != nullptr &&
                      PostMessageW(g_app->hwnd, WM_ZB_JOB, 0, reinterpret_cast<LPARAM>(job));
  ReleaseSRWLockShared(&g_app_lock);
  if (!posted) {
    InterlockedDecrement(&job->refs);  // the UI side never got it
    job_release(job);
    return ZB_AUTO_ERR_NO_LOOP;
  }
  const ULONGLONG now = GetTickCount64();
  const DWORD left = now >= deadline ? 0 : static_cast<DWORD>(deadline - now);
  if (WaitForSingleObject(job->done, left) != WAIT_OBJECT_0 &&
      InterlockedCompareExchange(&job->state, 2, 0) == 0) {
    job_release(job);  // abandoned: a late answer is dropped
    return ZB_AUTO_ERR_TIMEOUT;
  }
  WaitForSingleObject(job->done, INFINITE);  // answered (the race with the deadline included)
  const int code = job->code;
  if (code == ZB_AUTO_OK && out_json != nullptr && !job->json.empty()) *out_json = dup_c(job->json);
  if (code != ZB_AUTO_OK && out_err != nullptr && !job->err.empty()) *out_err = dup_c(job->err);
  job_release(job);
  return code;
}

ComPtr<ICoreWebView2CookieManager> cookie_manager(AppState *app) {
  ComPtr<ICoreWebView2_2> webview2;
  ComPtr<ICoreWebView2CookieManager> manager;
  if (app->webview && SUCCEEDED(app->webview.As(&webview2)) && webview2) {
    webview2->get_CookieManager(&manager);
  }
  return manager;
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

std::string cookies_json(ICoreWebView2CookieList *list) {
  std::string out = "[";
  UINT count = 0;
  if (list != nullptr) list->get_Count(&count);
  for (UINT i = 0; i < count; ++i) {
    ComPtr<ICoreWebView2Cookie> cookie;
    if (FAILED(list->GetValueAtIndex(i, &cookie)) || !cookie) continue;
    LPWSTR text = nullptr;
    double expires = -1;
    BOOL http_only = FALSE, secure = FALSE, session = TRUE;
    COREWEBVIEW2_COOKIE_SAME_SITE_KIND same_site = COREWEBVIEW2_COOKIE_SAME_SITE_KIND_NONE;
    if (out.size() > 1) out.push_back(',');
    out += "{\"name\":";
    json_append(out, co_string(cookie->get_Name(&text), text));
    out += ",\"value\":";
    json_append(out, co_string(cookie->get_Value(&text), text));
    out += ",\"domain\":";
    json_append(out, co_string(cookie->get_Domain(&text), text));
    out += ",\"path\":";
    json_append(out, co_string(cookie->get_Path(&text), text));
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

// ---- window_proc: a new case ----
//  case WM_ZB_JOB: {
//    Job *job = reinterpret_cast<Job *>(lparam);
//    if (app == nullptr) { job_answer(job, ZB_AUTO_ERR_NO_LOOP); return 0; }
//    if (!app->webview) { app->pending.push_back(job); return 0; }  // runs when the controller is ready
//    job->run(job);
//    return 0;
//  }
// AppState gains: std::deque<Job *> pending;
// create_controller's success path, after get_CoreWebView2: drain `pending` (run each).
// zb_app_run: after create_host_window, under the exclusive g_app_lock, g_app = &app, then
// SetEvent(g_loop_started). After run_message_loop: under the exclusive lock, g_loop_ended = true and
// g_app = nullptr; then answer every `pending` job, and any WM_ZB_JOB still in the queue
// (PeekMessageW with PM_REMOVE for WM_ZB_JOB), with ZB_AUTO_ERR_NO_LOOP.

// ---- create_environment: the profile and the GPU policy ----
//  auto options = Microsoft::WRL::Make<CoreWebView2EnvironmentOptions>();
//  const LONG hw = InterlockedCompareExchange(&g_hw_policy, 0, 0);
//  if (hw == ZB_HW_POLICY_NEVER) options->put_AdditionalBrowserArguments(L"--disable-gpu");
//  else if (hw == ZB_HW_POLICY_ALWAYS) options->put_AdditionalBrowserArguments(L"--ignore-gpu-blocklist");
//  return CreateCoreWebView2EnvironmentWithOptions(
//      nullptr, g_user_data_folder.empty() ? nullptr : g_user_data_folder.c_str(), options.Get(), env_handler.Get());

// ---- install_document_script_and_navigate: MSE off ----
//  std::wstring script = L"window.__zigBrowserBackend = 'webview2';";
//  if (InterlockedCompareExchange(&g_media_source, 1, 1) == 0) script += kMediaSourceHideJs;
//  return app->webview->AddScriptToExecuteOnDocumentCreated(script.c_str(), script_handler.Get());

} // namespace

extern "C" int zb_app_set_profile_dir(const char *dir, char **out_err) {
  if (out_err != nullptr) *out_err = nullptr;
  if (dir == nullptr || dir[0] == '\0') {
    g_user_data_folder.clear();
    return ZB_AUTO_OK;
  }
  const std::wstring wide = utf8_to_wide(dir);
  const DWORD need = wide.empty() ? 0 : GetFullPathNameW(wide.c_str(), 0, nullptr, nullptr);
  if (need == 0) return fail_with(out_err, "the profile directory is not a valid path");
  std::wstring full(need, L'\0');
  const DWORD got = GetFullPathNameW(wide.c_str(), need, &full[0], nullptr);
  if (got == 0 || got >= need) return fail_with(out_err, "the profile directory is not a valid path");
  full.resize(got);
  const std::wstring folder = full + L"\\WebView2";  // nothing next to the exe (WS3.1)
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
  InterlockedExchange(&g_hw_policy, policy == ZB_HW_POLICY_NEVER || policy == ZB_HW_POLICY_ALWAYS ? policy
                                                                                                 : ZB_HW_POLICY_WEBKIT);
}
extern "C" int zb_app_get_hw_policy(void) { return InterlockedCompareExchange(&g_hw_policy, 0, 0); }

extern "C" void zb_app_set_media_source(int enabled) { InterlockedExchange(&g_media_source, enabled != 0 ? 1 : 0); }
extern "C" int zb_app_get_media_source(void) { return InterlockedCompareExchange(&g_media_source, 0, 0); }

extern "C" void zb_automation_free(char *p) { free(p); }

extern "C" int zb_cookies_get_all(uint32_t win, const char *url, unsigned int timeout_ms,
                                  char **out_json, char **out_err) {
  const std::wstring uri = url != nullptr ? utf8_to_wide(url) : std::wstring();
  if (url != nullptr && url[0] != '\0' && uri.empty()) return fail_with(out_err, "the url is not valid UTF-8");
  return job_submit(win, timeout_ms, [uri](Job *job) {
    ComPtr<ICoreWebView2CookieManager> manager = cookie_manager(g_app);
    if (!manager) return job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "no cookie manager");
    HRESULT hr = manager->GetCookies(uri.c_str(), Callback<ICoreWebView2GetCookiesCompletedHandler>(
        [job](HRESULT result, ICoreWebView2CookieList *list) -> HRESULT {
          if (FAILED(result)) job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store read failed");
          else job_answer(job, ZB_AUTO_OK, cookies_json(list));
          return S_OK;
        }).Get());
    if (FAILED(hr)) job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store read failed");
  }, out_json, out_err);
}

extern "C" int zb_cookies_add(uint32_t win, const ZbCookie *cookie, unsigned int timeout_ms, char **out_err) {
  if (out_err != nullptr) *out_err = nullptr;
  if (cookie == nullptr || cookie->name == nullptr || cookie->value == nullptr || cookie->domain == nullptr) {
    return fail_with(out_err, "a cookie needs a name, a value and a domain");
  }
  if (cookie->expires < -1 || cookie->expires > ZB_COOKIE_MAX_EXPIRES) {
    return fail_with(out_err, "cookie expiry out of range");
  }
  struct Copy { std::wstring name, value, domain, path; long long expires; int http_only, secure, same_site; };
  const Copy c{utf8_to_wide(cookie->name), utf8_to_wide(cookie->value), utf8_to_wide(cookie->domain),
               utf8_to_wide(cookie->path != nullptr && cookie->path[0] != '\0' ? cookie->path : "/"),
               cookie->expires, cookie->http_only, cookie->secure, cookie->same_site};
  if (c.name.empty() || c.domain.empty()) return fail_with(out_err, "a cookie needs a name and a domain");
  return job_submit(win, timeout_ms, [c](Job *job) {
    ComPtr<ICoreWebView2CookieManager> manager = cookie_manager(g_app);
    ComPtr<ICoreWebView2Cookie> made;
    if (!manager || FAILED(manager->CreateCookie(c.name.c_str(), c.value.c_str(), c.domain.c_str(),
                                                 c.path.c_str(), &made)) || !made) {
      return job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store write failed");
    }
    if (c.expires >= 0) made->put_Expires(static_cast<double>(c.expires));  // else a session cookie
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
  }, nullptr, out_err);
}

extern "C" int zb_cookies_delete(uint32_t win, const char *name, const char *domain,
                                 unsigned int timeout_ms, char **out_err) {
  if (out_err != nullptr) *out_err = nullptr;
  if (name == nullptr || name[0] == '\0') return fail_with(out_err, "a cookie name is needed");
  const std::string want_name = name;
  const bool any_domain = domain == nullptr;
  const std::string want_domain = any_domain ? std::string() : bare_domain(domain);
  return job_submit(win, timeout_ms, [want_name, any_domain, want_domain](Job *job) {
    ComPtr<ICoreWebView2CookieManager> manager = cookie_manager(g_app);
    if (!manager) return job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "no cookie manager");
    HRESULT hr = manager->GetCookies(L"", Callback<ICoreWebView2GetCookiesCompletedHandler>(
        [job, manager, want_name, any_domain, want_domain](HRESULT result, ICoreWebView2CookieList *list) -> HRESULT {
          if (FAILED(result)) {
            job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store delete failed");
            return S_OK;
          }
          UINT count = 0;
          if (list != nullptr) list->get_Count(&count);
          for (UINT i = 0; i < count; ++i) {
            ComPtr<ICoreWebView2Cookie> cookie;
            LPWSTR text = nullptr;
            if (FAILED(list->GetValueAtIndex(i, &cookie)) || !cookie) continue;
            if (co_string(cookie->get_Name(&text), text) != want_name) continue;
            if (!any_domain && bare_domain(co_string(cookie->get_Domain(&text), text)) != want_domain) continue;
            if (FAILED(manager->DeleteCookie(cookie.Get()))) {
              job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store delete failed");
              return S_OK;
            }
          }
          job_answer(job, ZB_AUTO_OK);  // deleting nothing is not an error
          return S_OK;
        }).Get());
    if (FAILED(hr)) job_answer(job, ZB_AUTO_ERR_INTERNAL, {}, "cookie store delete failed");
  }, nullptr, out_err);
}
```

## Open points, for review and for the first Windows build

1. **`--ignore-gpu-blocklist` for `always`.** The table says "force GPU on". That flag is Chromium's nearest; it overrides the blocklist, not a driver crash fallback. RoseCat or AzureRidge: confirm, or say "auto" is enough.
2. **Session cookies.** `zb_cookies_add` leaves `Expires` unset for `-1`, which makes a session cookie in WebView2. `get_all` reports `-1` when `IsSession` is set. Check this on the first build.
3. **Domain form.** WebView2 treats `.host` and `host` as different domains, so the domain string is passed through unchanged. This matches GTK's "host = host-only, .host = domain cookie" if WebView2's `CreateCookie` keeps the leading dot as a domain cookie. Pin it with `win_cookie_test.py`.
4. **No owner of `zb_automation_loop_mark` on Windows yet.** The draft uses its own started/ended state. When WS2 adds the marshal for the page ops, these jobs move onto that one queue.
5. **The 0700 rule.** POSIX modes have no Windows meaning. The folder lives under `%LOCALAPPDATA%` (WS3.1's default), whose ACL already limits it to the user. A user-given `--profile-dir` keeps whatever ACL its parent has.

## Queue

- **When:** the Windows toolchain, or a writable Win11 VM window. Tonight's VM rule is read-only.
- **Steps:** compile against the SDK; run WS3's three e2e reds; then commit to `src/webview2_shim.cpp` in its own slice (red → green), with `cross-check-ws3-win` registered by AzureRidge in the same green.
- **Mutants to run there:**
  - drop the user data folder: `win_profile_persist_test` goes red;
  - write the cookie to a second manager or profile: `win_cookie_test` goes red;
  - leave the MSE script out: `win_config_flags_test` goes red.
