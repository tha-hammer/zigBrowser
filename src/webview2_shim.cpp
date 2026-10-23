#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <dwmapi.h>  // WS5.3: DwmFlush — step the fold animation on the compositor's vsync (plan:1539)
#include <richedit.h>  // WS5.4: the inert message bubble is a read-only, plain-text RichEdit
#include <objbase.h>
#include <shlobj.h>
#include <wrl.h>
#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>
#pragma comment(lib, "dwmapi.lib")

#include <ctype.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <deque>
#include <functional>
#include <iterator>
#include <memory>
#include <vector>
#include <string>

#include "webkit_shim.h"
#include "cdp_json.hpp"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

constexpr wchar_t kWindowClassName[] = L"zigBrowserWebView2Host";
// WS5.5b-2: the e2e multi-window spawn's EXTRA drawer windows use this dedicated class. Its WndProc is
// DefWindowProcW, so WM_DESTROY does NOT PostQuitMessage (the primary class does) — destroying an extra
// window must never quit the whole process.
constexpr wchar_t kDrawerExtraClassName[] = L"zigBrowserDrawerExtra";
constexpr int kWebView2LoadFailDomain = 2;
constexpr UINT_PTR kNavigationTimerId = 1;
constexpr UINT_PTR kFoldTimerId = 2;  // WS5.3: drives the drawer's fold (minimize) animation
constexpr int kFoldBtnSize = 28;      // WS5.3: the "-" minimize control's edge length (chrome)
constexpr int kFoldBtnMargin = 8;     // WS5.3: its inset from the open drawer's top-right corner
constexpr UINT kNavigationTimeoutMs = 15000;
// WS3: wakes the UI thread to run the queued jobs (the queue, not the message, owns them).
constexpr UINT WM_ZB_JOB = WM_APP + 1;
constexpr UINT WM_ZB_ABANDONED = WM_APP + 2; // WS2a.3d: a waiter gave up on a started job (g_abandoned)

// Portable drawer geometry types (src/agent_drawer.zig). Declared BEFORE AppState, which embeds them. Rect
// matches Zig's `extern struct { x, y, w, h: c_int }`; Ratios matches `extern struct { x, y: f64 }`.
extern "C" {
struct ZbDrawerGeomRect { int x, y, w, h; };
struct ZbDrawerRatios { double x, y; };
}

// WS5.5b-2 (RoseCat 5a204f3/bdc8202): an APP-OWNED record for each e2e extra drawer window. The ownership
// retire-once logic is the PORTABLE zb_drawer_retire_extra (driven directly by the Zig property test); this
// struct is its C ABI — a pointer-sized handle + a one-byte live flag (matches agent_drawer.zig ExtraRecord).
// `live` is retired on the real WM_DESTROY path, so bulk teardown acts only on still-live records and an early
// close never pre-removes the record.
struct ExtraWindow {
  uintptr_t hwnd;
  unsigned char live;
};

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
  // WS2a.1 (UI thread only): the routed navigate/reload waiting for its own NavigationCompleted (holds a job
  // reference), its NavigationId once NavigationStarting reports it, and the jobs waiting for the first load.
  struct Job *nav_job = nullptr;
  UINT64 nav_id = 0;
  bool nav_id_known = false;
  // WS2a.3d: the routed navigation's own (first) NavigationStarting has been seen; nav_id_known says whether its
  // NavigationId could be read there. current_nav_* is the navigation the page is on now (routed or not), valid
  // only when the latest NavigationStarting's id could be read.
  bool nav_start_seen = false;
  UINT64 current_nav_id = 0;
  bool current_nav_known = false;
  std::vector<std::function<void(AppState *)>> first_load_waiters;
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
  // WS5.5 e2e-only multi-window seam (ZIGBROWSER_AGENT_DRAWER_WINDOWS = N): the process mounts N per-window
  // drawers so the live count peaks at N then drops to 0; the global `live` row is emitted at shutdown. Set only
  // under --e2e-protocol; windows_seam_set gates the row so ordinary single-window runs never emit it.
  int windows_seam = 1;
  bool windows_seam_set = false;
  HWND drawer_panel = nullptr;
  HWND drawer_icon = nullptr;
  HWND drawer_min = nullptr;  // WS5.3: the visible "-" (minimize/fold) control on the open drawer (top-right)
  HWND drawer_bubble = nullptr;  // WS5.4: the inert message bubble (read-only, plain-text RichEdit) on the panel
  std::vector<ExtraWindow> extra_windows;  // WS5.5b-2: app-owned records for the e2e extra drawer windows
  // WS5.5b-2 e2e-only seams. extra_fail ("panel"|"icon") forces the matching control CreateWindowExW in an
  // extra window to fail, so the partial-window cleanup path is driven. extra_close_one closes ONE extra early
  // and emits an intermediate live count, so a live test sees the count fall by exactly one.
  const char *extra_fail = nullptr;
  bool extra_close_one = false;
  // WS5 e2e-only control-factory failure seam (ZIGBROWSER_AGENT_DRAWER_FAIL = "panel"|"icon"): forces a
  // CreateWindowExW failure branch for the test. Null unless --e2e-protocol AND the env is set.
  const char *force_drawer_fail = nullptr;
  // WS5.2 e2e-only drag seam (ZIGBROWSER_AGENT_DRAWER_DRAG = "dx,dy"): DRIVES the real icon input path (posts
  // synthetic mouse messages to the icon's own window procedure), it does not substitute for it. e2e-only.
  const char *drag_seam = nullptr;
  // WS5.7 e2e-only DPI seam (ZIGBROWSER_AGENT_DRAWER_DPI = a percent, e.g. "150"): overrides the real monitor
  // DPI for a deterministic test. PRODUCTION never consults this — it uses GetDpiForWindow. Set only under
  // --e2e-protocol; null otherwise.
  const char *dpi_seam = nullptr;
  // WS5.4 e2e-only bubble seam (ZIGBROWSER_AGENT_DRAWER_RTF): the literal text to render in the inert bubble. It
  // is set verbatim via WM_SETTEXT (never EM_STREAMIN/SF_RTF), so RTF markup and URLs stay literal. e2e-only.
  const char *rtf_seam = nullptr;
  // WS5.7 the window's current per-monitor DPI: seeded from GetDpiForWindow on first use, then kept current by
  // the WM_DPICHANGED handler. 0 until seeded. This is the production sizing authority.
  int dpi_current = 0;
  // WS5.7 e2e-only causal mutant (ZIGBROWSER_AGENT_DRAWER_DPICHANGE_IGNORE = "1"): makes the WM_DPICHANGED
  // handler do nothing, so a test can prove the handler is what re-sizes the icon on a DPI change. e2e-only.
  bool dpichange_ignore = false;
  // WS5.3 e2e-only fold seam (ZIGBROWSER_AGENT_DRAWER_FOLD, exactly "1"): starts the REAL fold animation at
  // mount so the test can observe it. e2e-only.
  bool fold_seam = false;
  // WS5.3 e2e-only fold-FAILURE causal seam (ZIGBROWSER_AGENT_DRAWER_FOLD_FAIL = "timer"|"move"|"delay"): forces
  // the matching fail-closed branch so a test can drive it — SetTimer treated as failed, the animated MoveWindow
  // treated as failed, or the first tick forced past the deadline with no genuine midpoint. Null in normal runs.
  const char *fold_fail = nullptr;
  // WS5.7 e2e-only causal seam (ZIGBROWSER_AGENT_DRAWER_HITTEST_FAIL = "1"): forces the icon WM_NCHITTEST
  // geometry read to be treated as failed, so a test can prove the unreadable-geometry branch REFUSES the hit
  // (HTNOWHERE) instead of forwarding it to the page. e2e-only.
  bool hittest_read_fail = false;
  // WS5.3 fold (minimize) animation state: a kFoldTimerId-driven transition of the open panel down into the
  // icon over `fold_ms`, each frame from the portable lerp/ease. `fold_mid` captures the real mid-transition
  // frame (read back off the panel HWND); the terminal tick emits the `fold` observation (mid frame +
  // configured `fold_ms`) and leaves the drawer folded (closed, icon shown). The live test times the
  // wall-clock elapsed itself (RoseCat 05f2549: "measure the default elapsed transition").
  bool folding = false;
  ULONGLONG fold_start_ms = 0;
  unsigned int fold_ms = 180;
  ZbDrawerGeomRect fold_from = {};
  ZbDrawerGeomRect fold_to = {};
  ZbDrawerGeomRect fold_mid = {};
  bool fold_mid_captured = false;
  bool fold_kill_tried = false;  // WS5.3: one-shot so the e2e "kill" seam fails only the FIRST cancel per fold
  // WS5.2 icon position + drag/subclass state. `icon_ratios`/`has_icon_ratios` is the icon's current position
  // as portable ratios (seeded from the persisted profile via zb_drawer_start_ratios, updated on every user
  // move); mount and resize place the real icon HWND from it (not the default). `icon_proc` is the STATIC's
  // original window procedure (subclassed for mouse drag + arrow keys). Drag state tracks the press origin.
  ZbDrawerRatios icon_ratios = {};
  bool has_icon_ratios = false;
  WNDPROC icon_proc = nullptr;
  WNDPROC min_proc = nullptr;  // WS5.3: the subclassed "-" control's original proc
  bool icon_dragging = false;
  int icon_down_x = 0, icon_down_y = 0;
  ZbDrawerGeomRect icon_down_rect = {};
};

// The portable drawer geometry functions (src/agent_drawer.zig, exported for Windows). The Rect/Ratios types
// are declared above (AppState embeds them). No geometry math in C++.
extern "C" {
void zb_drawer_panel_rect(int width, int height, ZbDrawerGeomRect *out);
void zb_drawer_place(const void *ratios, int width, int height, ZbDrawerGeomRect *out);
void zb_drawer_clamp(ZbDrawerGeomRect *r, int width, int height);
void zb_drawer_ratios_of(const ZbDrawerGeomRect *r, int width, int height, ZbDrawerRatios *out);
int zb_drawer_classify(double dx, double dy);  // 0 = click, 1 = drag
void zb_drawer_remember(const ZbDrawerRatios *ratios);
void zb_drawer_key_move(ZbDrawerGeomRect *r, int dx, int dy, int big, int width, int height);
int zb_drawer_start_ratios(ZbDrawerRatios *out);  // 1 + out set: a persisted position; 0: use the default
void zb_drawer_lerp(const ZbDrawerGeomRect *a, const ZbDrawerGeomRect *b, double t, ZbDrawerGeomRect *out);
double zb_drawer_ease(double t);
unsigned int zb_drawer_anim_ms_from_env(const char *text);  // ZIGBROWSER_AGENT_ANIM_MS override, else 180
int zb_drawer_icon_size_for_dpi(int dpi);                  // WS5.7 production: 56*dpi/96 half-up (GetDpiForWindow)
int zb_drawer_icon_size_from_dpi_env(const char *text);    // WS5.7 e2e seam: the DPI percent env, else 56
int zb_drawer_inside_icon(int dx, int dy, int radius);     // WS5.7 exact circular hit-test (1 inside, 0 outside)
int zb_drawer_window_count_from_env(const char *text);     // WS5.5 e2e seam: strict 1..8, else 0 (seam off)
int zb_drawer_extra_windows(int seam);                     // WS5.5b-2: extra windows beyond the primary (seam-1)
int zb_drawer_retire_extra(ExtraWindow *records, size_t count, uintptr_t hwnd);  // WS5.5b-2: retire-once (1 => decrement)
// WS5.5b-2 (RoseCat 35ff63f #1): the portable post-controller decision. Given the gate flags it returns how
// many EXTRA drawer windows to spawn (so the live count peaks at the seam) and whether to drive the primary's
// normal close. It is tested directly over every gate combination (tests/windows/agent_drawer_props_test.zig),
// so the C++ owns no gate/count logic — only this ONE call site. Layout mirrors the Zig extern struct
// (c_int spawn_count; u8 close_primary).
struct AfterController { int spawn_count; unsigned char close_primary; };
AfterController zb_drawer_after_controller(int seam, int e2e, int drawer, int windows_seam_set);
// WS5.5b-2 (RoseCat 2dcf84e / R3(d)): the portable drawer live-count state machine. The shim OWNS no count
// transition logic — it calls inc when a full drawer registers and dec when a retired window's WM_DESTROY fires;
// the transitions (live++, running peak, never-below-zero dec) are driven in agent_drawer_props_test.zig. Layout
// mirrors the Zig extern struct (c_int live; c_int peak).
struct DrawerLive { int live; int peak; };
int zb_drawer_live_inc(DrawerLive *s);   // full drawer registers: live++, peak tracks the max; returns new live
int zb_drawer_live_dec(DrawerLive *s);   // retired window: live-- (never below 0); returns new live
}

// WS5 shim functions (declared in webkit_shim.h), defined here for the Windows backend.
static std::atomic<int> g_agent_drawer_enabled{0};
// WS5.5b-2 (R3(d)): the live-count state is the portable DrawerLive, mutated ONLY through the Zig transitions
// (zb_drawer_live_inc/dec). All drawer-window lifecycle runs on the single UI/message-loop thread.
static DrawerLive g_drawer_live_state{0, 0};
extern "C" void zb_app_set_agent_drawer(int enabled) { g_agent_drawer_enabled.store(enabled != 0); }
extern "C" int zb_app_get_agent_drawer(void) { return g_agent_drawer_enabled.load(); }
extern "C" int zb_drawer_debug_live_count(void) { return g_drawer_live_state.live; }
extern "C" int zb_drawer_debug_live_peak(void) { return g_drawer_live_state.peak; }  // WS5.5 peak accessor

// WS5.5: register one more live drawer through the portable counter (live++, running peak).
static void drawer_live_inc() { zb_drawer_live_inc(&g_drawer_live_state); }

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

// Four data fields (e.g. the WS5.3 `fold` row: win, kind, rect, duration), each tab-safe.
void emit_protocol4(const AppState *app, const char *tag, const char *a,
                    const char *b, const char *c, const char *d) {
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
  fputc('\t', stdout);
  emit_safe_field(d);
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

#ifdef ZB_WS2A3_SEAMS
// WS2a.3b test seam (the slice executable only): caller-returned strings currently live (dup_c +1,
// zb_automation_free -1).
volatile LONG g_strings_live = 0;
#endif

char *dup_c(const std::string &text) {
  char *p = static_cast<char *>(malloc(text.size() + 1));
  if (p != nullptr) {
    memcpy(p, text.c_str(), text.size() + 1);
#ifdef ZB_WS2A3_SEAMS
    InterlockedIncrement(&g_strings_live);
#endif
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
std::vector<Job *> g_abandoned; // under g_jobs_lock: started jobs a waiter gave up on (WS2a.3d), one ref each
HWND g_job_hwnd = nullptr;    // under g_jobs_lock: the loop's window while it runs
bool g_loop_ended = false;    // under g_jobs_lock
DWORD g_loop_thread = 0;
HANDLE g_loop_started = CreateEventW(nullptr, TRUE, FALSE, nullptr);

// Test seams (ws3_shim_test.c; inert at 0): the UI side waits this long before it commits to
// running a job; and WebView2's cookie-read completion is parked until the test runs it.
volatile LONG g_debug_hold_ms = 0;
volatile LONG g_debug_park = 0;
#ifdef ZB_WS2A3_SEAMS
// WS2a.3 test seams, compiled ONLY into the ws2a3-async-ownership-win slice executable (build.zig sets
// ZB_WS2A3_SEAMS there and nowhere else; tests/windows/ws2a3_seam_gating_test.py pins both builds): a
// completion sleeps this long after it has claimed its job (COMPLETING) and before the answer is written;
// and the number of jobs allocated.
volatile LONG g_debug_complete_hold_ms = 0;
volatile LONG g_live_jobs = 0;
// WS2a.3b: a CDP step's answer is held this long on the UI thread before the chain decides whether to go on;
// a waiter whose deadline passed sleeps this long once more before giving up (header:
// zb_automation_debug_waiter_grace); CDP steps started for a job that is no longer RUNNING. (The caller-string
// counter, g_strings_live, sits beside dup_c.)
volatile LONG g_debug_step_hold_ms = 0;
volatile LONG g_debug_waiter_grace_ms = 0;
volatile LONG g_late_dispatches = 0;
// WS2a.3d: while set, abandoned started jobs are handled at the next NavigationStarting (after it records its
// NavigationId) instead of at once, so a newer navigation can start first (zb_automation_debug_abandon_at_start).
volatile LONG g_debug_abandon_at_start = 0;
#endif
SRWLOCK g_parked_lock = SRWLOCK_INIT;
std::vector<std::function<void()>> g_parked; // under g_parked_lock

void job_hold(Job *job) { InterlockedIncrement(&job->refs); }

void job_release(Job *job) {
  if (InterlockedDecrement(&job->refs) == 0) {
    if (job->done != nullptr) {
      CloseHandle(job->done);
    }
    delete job;
#ifdef ZB_WS2A3_SEAMS
    InterlockedDecrement(&g_live_jobs);
#endif
  }
}

// The one completion of a started job; false when it was abandoned or completed already.
bool job_complete(Job *job, int code, std::string json = {}, std::string err = {}) {
  if (InterlockedCompareExchange(&job->state, kCompleting, kRunning) != kRunning) {
    return false;
  }
#ifdef ZB_WS2A3_SEAMS
  const LONG hold = InterlockedCompareExchange(&g_debug_complete_hold_ms, 0, 0);
  if (hold > 0) {
    Sleep(static_cast<DWORD>(hold));
  }
#endif
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
  AcquireSRWLockExclusive(&g_jobs_lock);
  std::vector<Job *> abandoned;
  abandoned.swap(g_abandoned);
  ReleaseSRWLockExclusive(&g_jobs_lock);
  for (Job *job : abandoned) {
    job_release(job);
  }
  // WS2a.3c: a caller still waiting for the loop to start (a run that failed before loop_begin) wakes now,
  // finds the loop ended and answers ZB_AUTO_ERR_NO_LOOP, as does every later call.
  SetEvent(g_loop_started);
}

// WS2a.3d (caller side): a started job was abandoned; the UI thread stops what it started (stop_abandoned).
void job_abandoned(Job *job) {
  AcquireSRWLockExclusive(&g_jobs_lock);
  if (!g_loop_ended && g_job_hwnd != nullptr) {
    job_hold(job);
    g_abandoned.push_back(job);
    PostMessageW(g_job_hwnd, WM_ZB_ABANDONED, 0, 0);
  }
  ReleaseSRWLockExclusive(&g_jobs_lock);
}

// Plan WS2 "Deadlines": how long a waiter whose deadline passed waits for a completion already being written.
constexpr DWORD kWaiterGraceMs = 250;

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
#ifdef ZB_WS2A3_SEAMS
  InterlockedIncrement(&g_live_jobs);
#endif
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
#ifdef ZB_WS2A3_SEAMS
    const LONG waiter_grace = InterlockedCompareExchange(&g_debug_waiter_grace_ms, 0, 0);
    if (waiter_grace > 0) {
      Sleep(static_cast<DWORD>(waiter_grace));
    }
#endif
    // The deadline passed: abandon the job before it starts, or its result while it runs.
    if (InterlockedCompareExchange(&job->state, kAbandoned, kQueued) == kQueued) {
      job_release(job);
      return ZB_AUTO_ERR_TIMEOUT;
    }
    if (InterlockedCompareExchange(&job->state, kAbandoned, kRunning) == kRunning) {
      job_abandoned(job); // WS2a.3d: a timed-out navigate/reload stops its own load
      job_release(job);
      return ZB_AUTO_ERR_TIMEOUT;
    }
    // COMPLETING: its answer is being written. Wait for it at most the waiter grace, never without a bound;
    // past that the call is a TIMEOUT and the completion's own reference frees the answer with the job.
    if (WaitForSingleObject(job->done, kWaiterGraceMs) != WAIT_OBJECT_0) {
      job_release(job);
      return ZB_AUTO_ERR_TIMEOUT;
    }
  }
  const int code = job->code;
  if (code == ZB_AUTO_OK && out_json != nullptr) {
    *out_json = dup_c(job->json); // "" stays "": an empty answer is still an answer
  }
  if (code != ZB_AUTO_OK && out_err != nullptr && !job->err.empty()) {
    *out_err = dup_c(job->err);
  }
  job_release(job);
  return code;
}

// ---- WS2a.0: CDP calls on the UI thread (the one CDP wrapper; WS2b's native input builds on it) ----

using CdpDone = std::function<void(int code, std::string text)>;
using CdpThen = std::function<void(Job *, AppState *, std::string result_json)>;

// The one error table: a CDP answer -> a ZB_AUTO_* code, and its text (the result JSON, or why it failed).
// An answer that is a CDP error object ({"code":<int>,"message":"..."}) is an error whatever the HRESULT.
int cdp_error_code(const std::string &method, HRESULT hr, const std::string &json, std::string *text) {
  long long cdp_code = 0;
  std::string message;
  const bool cdp_error = cdp_json_int(json, {"code"}, &cdp_code) && cdp_json_string(json, {"message"}, &message);
  if (SUCCEEDED(hr) && !cdp_error) {
    *text = json;
    return ZB_AUTO_OK;
  }
  char buf[96];
  if (cdp_error) {
    snprintf(buf, sizeof buf, " (cdp %lld)", cdp_code);
    *text = "cdp " + method + ": " + message + buf;
  } else {
    snprintf(buf, sizeof buf, " failed (hr 0x%08lx)", static_cast<unsigned long>(hr));
    *text = "cdp " + method + buf;
  }
  return ZB_AUTO_ERR_INTERNAL;
}

// UI thread only. Calls one CDP method on app->webview; never blocks. `done` runs exactly once, on the
// UI thread: (ZB_AUTO_OK, result JSON) or (ZB_AUTO_ERR_INTERNAL, why).
void cdp_call(AppState *app, const char *method, const std::string &params_json, CdpDone done) {
  const std::string name = method != nullptr ? method : "";
  if (app == nullptr || !app->webview) {
    return done(ZB_AUTO_ERR_INTERNAL, "cdp " + name + ": no WebView");
  }
  const std::wstring wmethod = utf8_to_wide(name.c_str());
  const std::wstring wparams = utf8_to_wide(params_json.empty() ? "{}" : params_json.c_str());
  if (wmethod.empty() || wparams.empty()) {
    return done(ZB_AUTO_ERR_INTERNAL, "cdp " + name + ": method or params are not valid UTF-8");
  }
  auto once = std::make_shared<CdpDone>(std::move(done));
  const HRESULT hr = app->webview->CallDevToolsProtocolMethod(
      wmethod.c_str(), wparams.c_str(),
      Callback<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler>(
          [once, name](HRESULT error, LPCWSTR json_wide) -> HRESULT {
            std::string text;
            const int code = cdp_error_code(name, error, wide_to_utf8(json_wide), &text);
            (*once)(code, std::move(text));
            return S_OK;
          })
          .Get());
  if (FAILED(hr)) { // no callback will come
    std::string text;
    (*once)(cdp_error_code(name, hr, std::string(), &text), std::move(text));
  }
}

// One step of a job: holds the job's callback reference across the call. An error finishes the job with
// the wrapper's code (or `error_code` when not 0) and text; success runs `then` (which chains another step or
// job_finish), or finishes OK with the result JSON when `then` is empty. A job already answered (abandoned,
// or loop end) runs no further step.
void cdp_job_call(Job *job, AppState *app, const char *method, const std::string &params_json,
                  CdpThen then = nullptr, int error_code = 0) {
#ifdef ZB_WS2A3_SEAMS
  if (InterlockedCompareExchange(&job->state, 0, 0) != kRunning) {
    InterlockedIncrement(&g_late_dispatches);
  }
#endif
  job_hold(job);
  cdp_call(app, method, params_json, [job, app, then = std::move(then), error_code](int code, std::string text) {
#ifdef ZB_WS2A3_SEAMS
    const LONG step_hold = InterlockedCompareExchange(&g_debug_step_hold_ms, 0, 0);
    if (step_hold > 0) {
      Sleep(static_cast<DWORD>(step_hold));
    }
#endif
    if (code != ZB_AUTO_OK && error_code != 0) {
      code = error_code;
    }
    if (code != ZB_AUTO_OK || !then || InterlockedCompareExchange(&job->state, 0, 0) != kRunning) {
      return callback_done(job, code, code == ZB_AUTO_OK ? std::move(text) : std::string(),
                           code == ZB_AUTO_OK ? std::string() : std::move(text));
    }
    then(job, app, std::move(text));
    job_release(job); // this step's reference
  });
}

// ---- WS2a.0: the automation script's private world (ZB_AUTOMATION_WORLD) and evals ----

SRWLOCK g_script_lock = SRWLOCK_INIT;
std::string g_automation_script; // under g_script_lock; set before zb_app_run; empty = no injection

// The body runs as an async function of `arg` (the arg_json STRING); the answer is the returned string
// verbatim, else its JSON encoding ("null" for undefined), as on GTK.
std::string eval_expression(const std::string &body, const std::string &arg) {
  return "(async () => { const __zbR = await (async function (arg) {\n" + body + "\n})(" + cdp_json_quote(arg) +
         "); if (typeof __zbR === 'string') return __zbR; const __zbJ = JSON.stringify(__zbR); "
         "return __zbJ === undefined ? 'null' : __zbJ; })()";
}

std::string evaluate_params(const std::string &expression, bool in_context, long long context_id) {
  std::string params = "{\"expression\":" + cdp_json_quote(expression) + ",\"awaitPromise\":true,\"returnByValue\":true";
  if (in_context) {
    params += ",\"contextId\":" + std::to_string(context_id);
  }
  return params + "}";
}

// Runtime.evaluate's answer -> the job's answer.
void finish_evaluate(Job *job, const std::string &json) {
  if (cdp_json_has(json, {"exceptionDetails"})) {
    std::string why;
    if (!cdp_json_string(json, {"exceptionDetails", "exception", "description"}, &why) &&
        !cdp_json_string(json, {"exceptionDetails", "text"}, &why)) {
      why = "the script threw";
    }
    return job_finish(job, ZB_AUTO_ERR_JS, {}, why);
  }
  std::string value;
  if (!cdp_json_string(json, {"result", "value"}, &value)) {
    return job_finish(job, ZB_AUTO_ERR_INTERNAL, {}, "cdp Runtime.evaluate: no string result");
  }
  job_finish(job, ZB_AUTO_OK, value);
}

// UI thread: Runtime.evaluate of `expression` in the page's main world, or (in_world) in the main frame's
// isolated world `world_name` (Page.createIsolatedWorld returns its context for this document); `then` gets
// the evaluate answer. Every failure on the way answers the job `fail_code`. Used by zb_automation_eval_json
// and by the native-input document guard (WS2b.1).
void world_evaluate(Job *job, AppState *app, bool in_world, const std::string &world_name,
                    const std::string &expression, CdpThen then, int fail_code) {
  if (!in_world) {
    return cdp_job_call(job, app, "Runtime.evaluate", evaluate_params(expression, false, 0), std::move(then),
                        fail_code);
  }
  cdp_job_call(
      job, app, "Page.getFrameTree", "{}",
      [world_name, expression, then = std::move(then), fail_code](Job *j, AppState *a, std::string tree) {
        std::string frame;
        if (!cdp_json_string(tree, {"frameTree", "frame", "id"}, &frame)) {
          return job_finish(j, fail_code, {}, "cdp Page.getFrameTree: no main frame id");
        }
        const std::string params =
            "{\"frameId\":" + cdp_json_quote(frame) + ",\"worldName\":" + cdp_json_quote(world_name) + "}";
        cdp_job_call(
            j, a, "Page.createIsolatedWorld", params,
            [expression, then, fail_code](Job *j2, AppState *a2, std::string made) {
              long long context = 0;
              if (!cdp_json_int(made, {"executionContextId"}, &context)) {
                return job_finish(j2, fail_code, {}, "cdp Page.createIsolatedWorld: no executionContextId");
              }
              cdp_job_call(j2, a2, "Runtime.evaluate", evaluate_params(expression, true, context), then, fail_code);
            },
            fail_code);
      },
      fail_code);
}

// ---- WS2a.1: routed navigation and the first load ----

// UI thread: runs `step` now when the window's first load has finished, else once it has. A job the waiter
// gave up on meanwhile is finished without running (it leaves the in-flight list). If the first load fails
// the browser quits, and loop end answers the waiting jobs ZB_AUTO_ERR_NO_LOOP.
void after_first_load(Job *job, AppState *app, std::function<void(Job *, AppState *)> step) {
  if (app->navigation_completed) {
    return step(job, app);
  }
  job_hold(job);
  app->first_load_waiters.push_back([job, step = std::move(step)](AppState *a) {
    if (InterlockedCompareExchange(&job->state, 0, 0) == kRunning) {
      step(job, a);
    } else {
      job_finish(job, ZB_AUTO_ERR_TIMEOUT);
    }
    job_release(job);
  });
}

void run_first_load_waiters(AppState *app) {
  std::vector<std::function<void(AppState *)>> waiters;
  waiters.swap(app->first_load_waiters);
  for (auto &waiter : waiters) {
    waiter(app);
  }
}

// UI thread: answers the routed navigation that is waiting, if `id` is its NavigationId.
void finish_navigation(AppState *app, UINT64 id, BOOL ok, COREWEBVIEW2_WEB_ERROR_STATUS status) {
  Job *job = app->nav_job;
  if (job == nullptr || !app->nav_id_known || id != app->nav_id) {
    return;
  }
  app->nav_job = nullptr;
  if (ok) {
    job_finish(job, ZB_AUTO_OK);
  } else {
    char why[64];
    snprintf(why, sizeof why, "navigation failed (web error status %d)", static_cast<int>(status));
    job_finish(job, ZB_AUTO_ERR_NAV_FAILED, {}, why);
  }
  job_release(job);
}

// UI thread: starts a routed navigation (`go` calls Navigate or Reload); the job is answered by its own
// NavigationCompleted. A routed navigation still waiting is replaced (its caller has given up by now: the
// server runs one command per window at a time).
void start_navigation(Job *job, AppState *app, const std::function<HRESULT(ICoreWebView2 *)> &go) {
  if (Job *old = app->nav_job) {
    app->nav_job = nullptr;
    job_finish(old, ZB_AUTO_ERR_CANCELLED);
    job_release(old);
  }
  job_hold(job);
  app->nav_job = job;
  app->nav_start_seen = false;
  app->nav_id_known = false;
  const HRESULT hr = go(app->webview.Get());
  if (FAILED(hr) && app->nav_job == job) {
    app->nav_job = nullptr;
    char why[64];
    snprintf(why, sizeof why, "navigation did not start (hr 0x%08lx)", static_cast<unsigned long>(hr));
    job_finish(job, ZB_AUTO_ERR_NAV_FAILED, {}, why);
    job_release(job);
  }
}

// WS2a.3d (UI thread): for each started job a waiter gave up on, a routed navigation it still owns is dropped,
// and its load is stopped only while it is still the page's navigation: before its own NavigationStarting, or
// when that start's id and the current one are both known and equal. A newer navigation (routed or
// page-initiated) goes on, and an unreadable id fails closed (no stop).
void stop_abandoned(AppState *app) {
  AcquireSRWLockExclusive(&g_jobs_lock);
  std::vector<Job *> abandoned;
  abandoned.swap(g_abandoned);
  ReleaseSRWLockExclusive(&g_jobs_lock);
  for (Job *job : abandoned) {
    if (app != nullptr && app->nav_job == job) {
      app->nav_job = nullptr;
      const bool own = !app->nav_start_seen ||
                       (app->nav_id_known && app->current_nav_known && app->current_nav_id == app->nav_id);
      if (own && app->webview) {
        app->webview->Stop();
      }
      job_finish(job, ZB_AUTO_ERR_TIMEOUT); // the waiter has gone: this only leaves the in-flight list
      job_release(job);                    // the routed navigation's hold
    }
    job_release(job); // g_abandoned's hold
  }
}

// WS2a.3d (UI thread, at shutdown): the routed navigation still waiting gives back its hold, exactly once (a
// NavigationCompleted that answered it already cleared nav_job; loop_end then answers its caller if still there).
void release_nav_job(AppState *app) {
  if (Job *job = app->nav_job) {
    app->nav_job = nullptr;
    job_finish(job, ZB_AUTO_ERR_NO_LOOP);
    job_release(job);
  }
}

// ---- WS2b.1: native (trusted) input as CDP Input.dispatch* events, on the WS2a.0 wrapper ----

struct InputEvent {
  const char *method;
  std::string params;
};
using InputEvents = std::vector<InputEvent>;

// UI thread: sends `events` in order from `next`, then runs `sent`. The first event goes out only while the
// waiter still wants the job; once one went out the rest follow, so a press is never left without its
// release. A CDP error stops the events and answers the job.
void send_input(Job *job, AppState *app, std::shared_ptr<const InputEvents> events, size_t next,
                std::function<void(Job *, AppState *)> sent) {
  if (next == 0 && InterlockedCompareExchange(&job->state, 0, 0) != kRunning) {
    return job_finish(job, ZB_AUTO_ERR_TIMEOUT); // abandoned: nothing is sent
  }
  if (next == events->size()) {
    return sent(job, app);
  }
  const InputEvent &event = (*events)[next];
  job_hold(job);
  cdp_call(app, event.method, event.params, [job, app, events, next, sent](int code, std::string text) {
    if (code != ZB_AUTO_OK) {
      return callback_done(job, code, {}, std::move(text));
    }
    send_input(job, app, events, next + 1, sent);
    job_release(job); // this event's reference
  });
}

constexpr char kDocumentTokenExpression[] =
    "globalThis.__zbAutomation ? globalThis.__zbAutomation.documentToken : null";

// UI thread, after the window's first load: the document guard when `guarded` (the automation world's
// __zbAutomation.documentToken must equal `expected_doc`; anything else, a failed read included, is
// ZB_AUTO_ERR_DOC_CHANGED with nothing sent), focus for keys (as GTK focuses the view), then the events.
// Unlike GTK the guard's answer and the first event are two CDP calls, so a navigation that commits
// between them is not refused by this call's guard; the next guarded call refuses it.
void native_input(Job *job, AppState *app, bool guarded, const std::string &expected_doc, bool focus,
                  std::shared_ptr<const InputEvents> events, std::function<void(Job *, AppState *)> sent) {
  after_first_load(job, app, [guarded, expected_doc, focus, events, sent](Job *j, AppState *a) {
    auto send = [focus, events, sent](Job *j2, AppState *a2) {
      if (focus && a2->controller) {
        a2->controller->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC); // in-process; best effort
      }
      send_input(j2, a2, events, 0, sent);
    };
    if (!guarded) {
      return send(j, a);
    }
    world_evaluate(
        j, a, true, ZB_AUTOMATION_WORLD, kDocumentTokenExpression,
        [expected_doc, send](Job *j2, AppState *a2, std::string json) {
          std::string token;
          if (!cdp_json_string(json, {"result", "value"}, &token) || token != expected_doc) {
            return job_finish(j2, ZB_AUTO_ERR_DOC_CHANGED, {}, "the page is no longer the expected document");
          }
          send(j2, a2);
        },
        ZB_AUTO_ERR_DOC_CHANGED);
  });
}

// Caller side of one native op: copies the inputs; `after` (may be empty) runs on the UI thread once every
// event went out, before the job is answered OK.
int native_submit(uint32_t win, const char *expected_doc, bool focus, unsigned int timeout_ms, InputEvents events,
                  std::function<void()> after, char **out_err) {
  const bool guarded = expected_doc != nullptr;
  const std::string expected = guarded ? expected_doc : "";
  auto shared = std::make_shared<const InputEvents>(std::move(events));
  return job_submit(
      win, timeout_ms,
      [guarded, expected, focus, shared, after](Job *job, AppState *app) {
        native_input(job, app, guarded, expected, focus, shared, [after](Job *j, AppState *) {
          if (after) {
            after();
          }
          job_finish(j, ZB_AUTO_OK);
        });
      },
      nullptr, out_err);
}

// The last pointer position a native move or click dispatched (zb_native_pointer).
SRWLOCK g_pointer_lock = SRWLOCK_INIT;
bool g_pointer_known = false; // under g_pointer_lock
double g_pointer_x = 0;       // under g_pointer_lock
double g_pointer_y = 0;       // under g_pointer_lock

void remember_pointer(double x, double y) {
  AcquireSRWLockExclusive(&g_pointer_lock);
  g_pointer_known = true;
  g_pointer_x = x;
  g_pointer_y = y;
  ReleaseSRWLockExclusive(&g_pointer_lock);
}

std::string json_number(double v) {
  char buf[32];
  snprintf(buf, sizeof buf, "%.17g", v);
  return buf;
}

// Input.dispatchMouseEvent params; `clicks` 0 leaves clickCount out.
std::string mouse_params(const char *type, double x, double y, const char *button, int buttons, int clicks) {
  std::string params = std::string("{\"type\":\"") + type + "\",\"x\":" + json_number(x) + ",\"y\":" + json_number(y) +
                       ",\"button\":\"" + button + "\",\"buttons\":" + std::to_string(buttons);
  if (clicks > 0) {
    params += ",\"clickCount\":" + std::to_string(clicks);
  }
  return params + "}";
}

// GDK button numbers (the ABI's: 1 = left) -> the CDP button and its `buttons` bit.
struct MouseButton {
  int number;
  const char *name;
  int bit;
};
constexpr MouseButton kMouseButtons[] = {{1, "left", 1}, {2, "middle", 4}, {3, "right", 2}};

// One key as CDP sends it: the DOM key, its code, the Windows virtual-key code (0: none) and the text a press
// inserts ("" none).
struct KeySpec {
  std::string key;
  std::string code;
  int vk = 0;
  std::string text;
};

// The DOM key names GTK's zb_named_keys accepts (src/webkit_shim.c), plus F1..F12 and single characters.
struct NamedKey {
  const char *name;
  const char *key;
  const char *code;
  int vk;
  const char *text;
};
constexpr NamedKey kNamedKeys[] = {
    {"Enter", "Enter", "Enter", VK_RETURN, "\r"},
    {"Tab", "Tab", "Tab", VK_TAB, ""},
    {"Escape", "Escape", "Escape", VK_ESCAPE, ""},
    {"Backspace", "Backspace", "Backspace", VK_BACK, ""},
    {"Delete", "Delete", "Delete", VK_DELETE, ""},
    {"Insert", "Insert", "Insert", VK_INSERT, ""},
    {"ArrowLeft", "ArrowLeft", "ArrowLeft", VK_LEFT, ""},
    {"ArrowRight", "ArrowRight", "ArrowRight", VK_RIGHT, ""},
    {"ArrowUp", "ArrowUp", "ArrowUp", VK_UP, ""},
    {"ArrowDown", "ArrowDown", "ArrowDown", VK_DOWN, ""},
    {"Home", "Home", "Home", VK_HOME, ""},
    {"End", "End", "End", VK_END, ""},
    {"PageUp", "PageUp", "PageUp", VK_PRIOR, ""},
    {"PageDown", "PageDown", "PageDown", VK_NEXT, ""},
    {"Space", " ", "Space", VK_SPACE, " "},
    {"Shift", "Shift", "ShiftLeft", VK_SHIFT, ""},
    {"Control", "Control", "ControlLeft", VK_CONTROL, ""},
    {"Alt", "Alt", "AltLeft", VK_MENU, ""},
    {"Meta", "Meta", "MetaLeft", VK_LWIN, ""},
};

// ZB_NATIVE_MOD_* in GTK's press order, with the CDP modifier bit (Alt 1, Ctrl 2, Meta 4, Shift 8) and key.
struct ModifierKey {
  int zb;
  int cdp;
  const char *key;
  const char *code;
  int vk;
};
constexpr ModifierKey kModifierKeys[] = {
    {ZB_NATIVE_MOD_SHIFT, 8, "Shift", "ShiftLeft", VK_SHIFT},
    {ZB_NATIVE_MOD_CONTROL, 2, "Control", "ControlLeft", VK_CONTROL},
    {ZB_NATIVE_MOD_ALT, 1, "Alt", "AltLeft", VK_MENU},
    {ZB_NATIVE_MOD_META, 4, "Meta", "MetaLeft", VK_LWIN},
};
constexpr int kCdpShift = 8;

// The byte length of the UTF-8 code point at `i` (the text was validated already).
size_t utf8_char_len(const std::string &text, size_t i) {
  const unsigned char lead = static_cast<unsigned char>(text[i]);
  const size_t len = lead < 0x80 ? 1 : (lead >> 5) == 0x6 ? 2 : (lead >> 4) == 0xE ? 3 : 4;
  return i + len <= text.size() ? len : text.size() - i; // no std::min: the MSVC SDK's min macro
}

// One character (UTF-8, one code point) as a key: '\n' is Enter; otherwise the key and text are the character,
// and the current keyboard layout (VkKeyScanW) gives its virtual key and whether it needs Shift.
KeySpec char_key(const std::string &ch, bool *needs_shift) {
  *needs_shift = false;
  if (ch == "\n") {
    return KeySpec{"Enter", "Enter", VK_RETURN, "\r"};
  }
  KeySpec spec{ch, "", 0, ch};
  const std::wstring wide = utf8_to_wide(ch.c_str());
  if (wide.size() == 1) {
    const SHORT scan = VkKeyScanW(wide[0]);
    if (scan != -1) {
      spec.vk = LOBYTE(scan);
      *needs_shift = (HIBYTE(scan) & 1) != 0;
    }
  }
  if (spec.vk >= 'A' && spec.vk <= 'Z') {
    spec.code = std::string("Key") + static_cast<char>(spec.vk);
  } else if (spec.vk >= '0' && spec.vk <= '9') {
    spec.code = std::string("Digit") + static_cast<char>(spec.vk);
  }
  return spec;
}

// A DOM key name -> its key; false when unknown (GTK's auto_keyval_for accepts the same names).
bool key_for(const char *name, KeySpec *out) {
  for (const NamedKey &k : kNamedKeys) {
    if (strcmp(name, k.name) == 0) {
      *out = KeySpec{k.key, k.code, k.vk, k.text};
      return true;
    }
  }
  // F1..F12, exactly ("F1x" and "F13" are not keys).
  if (name[0] == 'F' && name[1] >= '1' && name[1] <= '9') {
    int n = name[1] - '0';
    if (name[2] != '\0') {
      n = name[2] >= '0' && name[2] <= '9' && name[3] == '\0' ? n * 10 + (name[2] - '0') : 0;
    }
    if (n < 1 || n > 12) {
      return false;
    }
    *out = KeySpec{name, name, VK_F1 + n - 1, ""};
    return true;
  }
  const std::string text = name;
  if (text.empty() || utf8_to_wide(name).empty() || utf8_char_len(text, 0) != text.size()) {
    return false;
  }
  bool unused = false;
  *out = char_key(text, &unused);
  return true;
}

std::string key_params(const char *type, const std::string &key, const std::string &code, int vk,
                       const std::string &text, int modifiers) {
  std::string params = std::string("{\"type\":\"") + type + "\",\"modifiers\":" + std::to_string(modifiers) +
                       ",\"key\":" + cdp_json_quote(key);
  if (!code.empty()) {
    params += ",\"code\":" + cdp_json_quote(code);
  }
  if (vk != 0) {
    params += ",\"windowsVirtualKeyCode\":" + std::to_string(vk) + ",\"nativeVirtualKeyCode\":" + std::to_string(vk);
  }
  if (!text.empty()) {
    params += ",\"text\":" + cdp_json_quote(text) + ",\"unmodifiedText\":" + cdp_json_quote(text);
  }
  return params + "}";
}

// As GTK's auto_native_press: modifiers down (accumulating), the key down and up, modifiers up in reverse
// order; returns the key releases sent. A key that inserts text is a keyDown carrying it, else a rawKeyDown;
// with Control, Alt or Meta held it inserts nothing.
int press_key(InputEvents *out, KeySpec key, int zb_modifiers) {
  int cdp = 0;
  for (const ModifierKey &m : kModifierKeys) {
    if (zb_modifiers & m.zb) {
      cdp |= m.cdp;
      out->push_back({"Input.dispatchKeyEvent", key_params("rawKeyDown", m.key, m.code, m.vk, "", cdp)});
    }
  }
  if ((cdp & ~kCdpShift) != 0) {
    key.text.clear();
  }
  out->push_back({"Input.dispatchKeyEvent",
                  key_params(key.text.empty() ? "rawKeyDown" : "keyDown", key.key, key.code, key.vk, key.text, cdp)});
  out->push_back({"Input.dispatchKeyEvent", key_params("keyUp", key.key, key.code, key.vk, "", cdp)});
  int releases = 1;
  for (size_t i = std::size(kModifierKeys); i > 0; i--) {
    const ModifierKey &m = kModifierKeys[i - 1];
    if (zb_modifiers & m.zb) {
      cdp &= ~m.cdp;
      out->push_back({"Input.dispatchKeyEvent", key_params("keyUp", m.key, m.code, m.vk, "", cdp)});
      releases++;
    }
  }
  return releases;
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

// WS5.7: the icon's current edge length in px. PRODUCTION authority is the window's real per-monitor DPI
// (GetDpiForWindow); the e2e DPI seam (set only under --e2e-protocol) overrides it for a deterministic test.
// All scaling math is in the portable Zig logic (zb_drawer_icon_size_*). 0 DPI (a GetDpiForWindow failure)
// falls back to 96.
static int effective_icon_px(AppState *app) {
  if (app->dpi_seam != nullptr && app->dpi_seam[0] != '\0') {
    return zb_drawer_icon_size_from_dpi_env(app->dpi_seam);
  }
  if (app->dpi_current <= 0) {  // seed from the window's real per-monitor DPI on first use
    const UINT dpi = (app->hwnd != nullptr) ? GetDpiForWindow(app->hwnd) : 96;
    app->dpi_current = (dpi == 0) ? 96 : static_cast<int>(dpi);
  }
  return zb_drawer_icon_size_for_dpi(app->dpi_current);  // kept current by the WM_DPICHANGED handler
}

// WS5: lay out the page (WebView2) and the native drawer within the client area. When the drawer is open the
// panel docks full-width at the bottom (zb_drawer_panel_rect) and the page fills the region above it, so
// page_h + panel_h == client_h; when closed the page fills the client and the "S" icon shows at its rect
// (zb_drawer_place), sized to the current DPI. No geometry math here — all rects come from the portable logic.
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
    if (app->drawer_min) {  // WS5.3: the "-" control sits at the open panel's top-right corner
      MoveWindow(app->drawer_min, panel.x + panel.w - kFoldBtnSize - kFoldBtnMargin, panel.y + kFoldBtnMargin,
                 kFoldBtnSize, kFoldBtnSize, TRUE);
      ShowWindow(app->drawer_min, SW_SHOW);
    }
    if (app->drawer_bubble) {  // WS5.4: the bubble fills the panel below the "-" control (panel-relative coords)
      MoveWindow(app->drawer_bubble, kFoldBtnMargin, kFoldBtnMargin + kFoldBtnSize,
                 panel.w - 2 * kFoldBtnMargin, panel.h - 2 * kFoldBtnMargin - kFoldBtnSize, TRUE);
      ShowWindow(app->drawer_bubble, SW_SHOW);  // a child of the panel, so it hides with the panel when closed
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
  if (app->drawer_min) {
    ShowWindow(app->drawer_min, SW_HIDE);  // the "-" control is only present on the open drawer
  }
  if (app->agent_drawer_on && app->drawer_mounted && app->drawer_icon) {
    ZbDrawerGeomRect icon = {};
    // Place the icon at its stored ratios (the persisted / last-moved position), not always the default (WS5.2
    // "persists"; RoseCat 1cd82d8 #3). Size it to the current DPI (WS5.7).
    zb_drawer_place(app->has_icon_ratios ? &app->icon_ratios : nullptr, cw, ch, &icon);
    const int ipx = effective_icon_px(app);
    icon.w = ipx;
    icon.h = ipx;
    zb_drawer_clamp(&icon, cw, ch);  // keep the DPI-sized icon fully inside the client area
    MoveWindow(app->drawer_icon, icon.x, icon.y, icon.w, icon.h, TRUE);
    ShowWindow(app->drawer_icon, SW_SHOW);
  }
}

// WS5.2: apply a candidate icon rect — clamp it, move the REAL icon HWND, persist the new ratios, and (under
// --e2e-protocol) emit a `drag` row reflecting the ACTUAL placement. All geometry via the portable zb_drawer_*.
static void drawer_apply_icon(AppState *app, ZbDrawerGeomRect candidate) {
  if (app == nullptr || app->drawer_icon == nullptr || app->hwnd == nullptr) {
    return;
  }
  RECT cr = {};
  GetClientRect(app->hwnd, &cr);
  const int cw = cr.right - cr.left;
  const int ch = cr.bottom - cr.top;
  zb_drawer_clamp(&candidate, cw, ch);
  // Compute the PERSISTED-RATIO rect (the position the next window/restart restores), then move the real HWND
  // there. Only persist/emit after the move SUCCEEDS — a failed MoveWindow must not report a move (fail-closed).
  ZbDrawerRatios ratios = {};
  zb_drawer_ratios_of(&candidate, cw, ch, &ratios);
  ZbDrawerGeomRect placed = {};
  zb_drawer_place(&ratios, cw, ch, &placed);
  if (!MoveWindow(app->drawer_icon, placed.x, placed.y, placed.w, placed.h, TRUE)) {
    fprintf(stderr, "zigBrowser: agent-drawer icon move failed (error %lu)\n",
            static_cast<unsigned long>(GetLastError()));
    fflush(stderr);
    return;
  }
  app->icon_ratios = ratios;
  app->has_icon_ratios = true;
  zb_drawer_remember(&app->icon_ratios);  // the user move persists for new windows / restarts
  char win[16];
  snprintf(win, sizeof win, "%d", app->win_id);
  char rect[64];
  snprintf(rect, sizeof rect, "%d,%d,%d,%d", placed.x, placed.y, placed.w, placed.h);
  emit_protocol3(app, "DRAWER", win, "drag", rect);  // supplementary; the test reads the real icon HWND rect
}

// WS5.2: open the drawer from an icon gesture (a click or Enter/Space) — emit the open row and re-dock, once.
static void drawer_open_now(AppState *app) {
  if (app == nullptr || app->drawer_open) {
    return;
  }
  app->drawer_open = true;
  RECT cr = {};
  GetClientRect(app->hwnd, &cr);
  ZbDrawerGeomRect panel = {};
  zb_drawer_panel_rect(cr.right - cr.left, cr.bottom - cr.top, &panel);
  char win[16];
  snprintf(win, sizeof win, "%d", app->win_id);
  char rect[64];
  snprintf(rect, sizeof rect, "%d,%d,%d,%d", panel.x, panel.y, panel.w, panel.h);
  emit_protocol3(app, "DRAWER", win, "open", rect);
  resize_controller(app);
  if (app->drawer_min != nullptr) {
    SetFocus(app->drawer_min);  // WS5.3: the open drawer puts focus on "-", so Escape folds immediately
  }
}

// WS5.3: cancel the fold timer, checked WITH a confirm-retry (RoseCat e666b02 #1). Returns true once the timer
// is genuinely cancelled. The e2e "kill" seam makes the FIRST real cancel genuinely fail (the KillTimer call is
// skipped, so the timer really stays armed) — then the retry must actually cancel it, proving the retry policy
// rather than a fabricated error. If even the retry fails, the caller still clears `folding`, and the WM_TIMER
// fold branch is guarded by `folding`, so no later tick does fold work regardless.
static bool fold_kill_timer(AppState *app, HWND hwnd) {
  const bool force_first_fail = app->fold_fail != nullptr && strcmp(app->fold_fail, "kill") == 0
                                && !app->fold_kill_tried;
  app->fold_kill_tried = true;
  bool cancelled = force_first_fail ? false : (KillTimer(hwnd, kFoldTimerId) != 0);
  if (!cancelled) {
    fprintf(stderr, "zigBrowser: agent-drawer fold timer cancel failed: KillTimer (error %lu); retrying\n",
            force_first_fail ? (unsigned long)ERROR_INVALID_PARAMETER : (unsigned long)GetLastError());
    fflush(stderr);
    cancelled = (KillTimer(hwnd, kFoldTimerId) != 0);  // confirm cancellation before the caller clears state
    if (!cancelled) {
      fprintf(stderr, "zigBrowser: agent-drawer fold timer STILL armed after retry (error %lu); "
                      "folding cleared, later ticks are guarded\n", static_cast<unsigned long>(GetLastError()));
      fflush(stderr);
    }
  }
  return cancelled;
}

// WS5.3: abort an in-flight fold into a STABLE, usable OPEN drawer (RoseCat 70fd7f9 #2/#3) — cancel the timer,
// clear folding, and re-dock the still-open drawer. Emits NO fold row; `why` is already on stderr.
static void fold_abort_open(AppState *app, HWND hwnd) {
  fold_kill_timer(app, hwnd);
  app->folding = false;
  resize_controller(app);  // drawer_open is unchanged, so this re-docks the open drawer (panel + "-" visible)
}

// WS5.3: start the real fold (minimize) animation — the open panel transitions down INTO the icon's position
// over `fold_ms` (ZIGBROWSER_AGENT_ANIM_MS via Zig, else 180 ms), stepped on kFoldTimerId. Each tick moves the
// REAL panel HWND to lerp(open, icon, ease(t)) and paces to the compositor's vsync (DwmFlush, plan:1539); the
// mid frame is read back off that HWND (an independent measurement). Triggered by the visible "-" control
// (click / Escape / '-') and by the e2e fold seam.
static void drawer_fold_start(AppState *app) {
  if (app == nullptr || app->hwnd == nullptr || !app->drawer_open || app->folding) {
    return;
  }
  RECT cr = {};
  if (!GetClientRect(app->hwnd, &cr)) {  // fail closed: no fold, the drawer stays open and usable
    fprintf(stderr, "zigBrowser: agent-drawer fold not started: GetClientRect failed (error %lu)\n",
            static_cast<unsigned long>(GetLastError()));
    fflush(stderr);
    return;
  }
  const int cw = cr.right - cr.left;
  const int ch = cr.bottom - cr.top;
  zb_drawer_panel_rect(cw, ch, &app->fold_from);  // the open drawer rect (fold start)
  zb_drawer_place(app->has_icon_ratios ? &app->icon_ratios : nullptr, cw, ch, &app->fold_to);  // the icon (end)
  app->fold_ms = zb_drawer_anim_ms_from_env(getenv("ZIGBROWSER_AGENT_ANIM_MS"));
  app->fold_start_ms = GetTickCount64();
  app->fold_mid_captured = false;
  app->fold_kill_tried = false;  // each fold's cancel seam fires once
  // Arm the timer FIRST and verify it: a SetTimer failure must not wedge folding=true with no tick to clear it.
  // The e2e "timer" seam forces this failure branch.
  const bool force_timer_fail = app->fold_fail != nullptr && strcmp(app->fold_fail, "timer") == 0;
  const UINT_PTR armed = force_timer_fail ? 0 : SetTimer(app->hwnd, kFoldTimerId, 16, nullptr);
  if (armed == 0) {
    fprintf(stderr, "zigBrowser: agent-drawer fold not started: SetTimer failed (error %lu)\n",
            force_timer_fail ? (unsigned long)ERROR_INVALID_PARAMETER : (unsigned long)GetLastError());
    fflush(stderr);
    return;  // fail closed: NOT folding; the open drawer remains usable
  }
  app->folding = true;  // only once the timer is genuinely armed
}

// WS5.2: the "S" icon's window procedure (subclassed over the STATIC). REAL Win32 input: mouse capture + drag,
// and arrow-key moves (16/64 px with Shift), all classified/clamped/moved via the portable zb_drawer_* logic.
// A drag (> 6 px, zb_drawer_classify) moves the icon to its persisted-ratio position; a click (<= 6 px) opens
// the drawer. The e2e drag seam DRIVES this same procedure (it posts real mouse messages), never bypasses it.
static LRESULT CALLBACK icon_subclass_proc(HWND h, UINT msg, WPARAM wparam, LPARAM lparam) {
  AppState *app = reinterpret_cast<AppState *>(GetWindowLongPtrW(GetParent(h), GWLP_USERDATA));
  if (app != nullptr) {
    switch (msg) {
      case WM_NCHITTEST: {
        // WS5.7 exact circular hit-test on the REAL icon HWND: a screen point inside the icon's circle is
        // HTCLIENT; the square corners outside the circle are HTTRANSPARENT (not the icon). radius = half the
        // icon's current (DPI-scaled) width. The portable zb_drawer_inside_icon decides — no geometry here.
        RECT wr = {};
        if (app->hittest_read_fail || !GetWindowRect(h, &wr)) {
          // Fail closed (RoseCat 00b69e5): if we can't read the icon's rect we cannot bound the circle. HTNOWHERE
          // — NOT HTTRANSPARENT — so the unbounded hit is REFUSED and CONSUMED here, never forwarded to the page
          // below (HTTRANSPARENT would continue hit-testing underlying windows and route the click to the page).
          // The e2e ZIGBROWSER_AGENT_DRAWER_HITTEST_FAIL seam forces this branch.
          fprintf(stderr, "zigBrowser: agent-drawer icon hit-test read failed (error %lu); refusing the hit\n",
                  app->hittest_read_fail ? (unsigned long)ERROR_INVALID_PARAMETER : (unsigned long)GetLastError());
          fflush(stderr);
          return HTNOWHERE;  // consume with no action, no forward to the page
        }
        const int w = wr.right - wr.left;
        const int cx = wr.left + w / 2;
        const int cy = wr.top + (wr.bottom - wr.top) / 2;
        const int px = static_cast<short>(LOWORD(lparam));  // WM_NCHITTEST lparam is screen coords
        const int py = static_cast<short>(HIWORD(lparam));
        return (zb_drawer_inside_icon(px - cx, py - cy, w / 2) != 0) ? HTCLIENT : HTTRANSPARENT;
      }
      case WM_LBUTTONDOWN: {
        SetFocus(h);  // so subsequent arrow / Enter / Space keys reach the icon (WS5.2 keyboard)
        SetCapture(h);
        app->icon_dragging = true;
        app->icon_down_x = static_cast<short>(LOWORD(lparam));
        app->icon_down_y = static_cast<short>(HIWORD(lparam));
        RECT cr = {};
        GetClientRect(app->hwnd, &cr);
        zb_drawer_place(app->has_icon_ratios ? &app->icon_ratios : nullptr,
                        cr.right - cr.left, cr.bottom - cr.top, &app->icon_down_rect);
        return 0;
      }
      case WM_LBUTTONUP: {
        if (app->icon_dragging) {
          app->icon_dragging = false;
          ReleaseCapture();
          const int dx = static_cast<short>(LOWORD(lparam)) - app->icon_down_x;
          const int dy = static_cast<short>(HIWORD(lparam)) - app->icon_down_y;
          if (zb_drawer_classify(static_cast<double>(dx), static_cast<double>(dy)) != 0) {  // a drag
            ZbDrawerGeomRect cand = app->icon_down_rect;
            cand.x += dx;
            cand.y += dy;
            drawer_apply_icon(app, cand);
          } else {  // a click opens the drawer
            drawer_open_now(app);
          }
        }
        return 0;
      }
      case WM_KEYDOWN: {
        if (wparam == VK_RETURN || wparam == VK_SPACE) {  // Enter/Space on the focused icon opens the drawer
          drawer_open_now(app);
          return 0;
        }
        int kx = 0, ky = 0;
        if (wparam == VK_LEFT) kx = -1;
        else if (wparam == VK_RIGHT) kx = 1;
        else if (wparam == VK_UP) ky = -1;
        else if (wparam == VK_DOWN) ky = 1;
        if (kx != 0 || ky != 0) {
          RECT cr = {};
          GetClientRect(app->hwnd, &cr);
          const int cw = cr.right - cr.left;
          const int ch = cr.bottom - cr.top;
          ZbDrawerGeomRect cur = {};
          zb_drawer_place(app->has_icon_ratios ? &app->icon_ratios : nullptr, cw, ch, &cur);
          zb_drawer_key_move(&cur, kx, ky, (GetKeyState(VK_SHIFT) < 0) ? 1 : 0, cw, ch);
          drawer_apply_icon(app, cur);
          return 0;
        }
        break;
      }
      default:
        break;
    }
    if (app->icon_proc != nullptr) {
      return CallWindowProcW(app->icon_proc, h, msg, wparam, lparam);
    }
  }
  return DefWindowProcW(h, msg, wparam, lparam);
}

// WS5.3: the "-" minimize control's window procedure (subclassed over a STATIC on the open drawer). This is the
// REAL, user-reachable route to START the fold: a click folds; Escape or '-' on the focused control folds too
// (the open drawer puts focus here, so Escape works immediately). The icon is hidden while the drawer is open,
// so this control — not the icon — is the production fold trigger (RoseCat 02c39a4 #1).
static LRESULT CALLBACK min_subclass_proc(HWND h, UINT msg, WPARAM wparam, LPARAM lparam) {
  AppState *app = reinterpret_cast<AppState *>(GetWindowLongPtrW(GetParent(h), GWLP_USERDATA));
  if (app != nullptr) {
    switch (msg) {
      case WM_LBUTTONDOWN:
        SetFocus(h);  // so a subsequent Escape / '-' reaches the button
        return 0;
      case WM_LBUTTONUP:
        drawer_fold_start(app);
        return 0;
      case WM_KEYDOWN:
        if (wparam == VK_ESCAPE || wparam == VK_OEM_MINUS || wparam == VK_SUBTRACT) {  // Escape or '-' folds
          drawer_fold_start(app);
          return 0;
        }
        break;
      default:
        break;
    }
    if (app->min_proc != nullptr) {
      return CallWindowProcW(app->min_proc, h, msg, wparam, lparam);
    }
  }
  return DefWindowProcW(h, msg, wparam, lparam);
}

// WS5.2 drag-seam parse: one signed delta with a STRICT grammar — an optional leading '-', then 1..4 decimal
// digits, no leading/internal/trailing whitespace and no '+' sign; the value must lie in [-8000, 8000]
// (representable through MAKELPARAM's signed 16-bit coordinates with the icon-centre offset). Advances *pp past
// the digits on success; returns false on ANY deviation (RoseCat 3d294b0).
static bool parse_drag_delta(const char **pp, int *out) {
  const char *p = *pp;
  const bool neg = (*p == '-');
  if (neg) {
    ++p;
  }
  if (*p < '0' || *p > '9') {
    return false;  // need at least one digit; rejects '+', whitespace, empty
  }
  long v = 0;
  int digits = 0;
  while (*p >= '0' && *p <= '9') {
    if (++digits > 4) {
      return false;
    }
    v = v * 10 + (*p - '0');
    ++p;
  }
  v = neg ? -v : v;
  if (v < -8000 || v > 8000) {
    return false;
  }
  *out = static_cast<int>(v);
  *pp = p;
  return true;
}

// WS5: mount the native Win32 drawer once the window + controller exist. Creates the native panel + "S"
// icon child controls (OD-W6), emits the same DRAWER census row NAMES as the GTK backend (tree, icon, and
// open when opened), and lays the drawer out. e2e census rows are gated by --e2e-protocol inside emit_*.
void mount_drawer(AppState *app) {
  if (app == nullptr || !app->agent_drawer_on || app->drawer_mounted || app->hwnd == nullptr) {
    return;
  }
  RECT cr = {};
  GetClientRect(app->hwnd, &cr);
  const int cw = cr.right - cr.left;
  const int ch = cr.bottom - cr.top;

  // Seed the icon position from the persisted profile (WS5.2 "persists"): a new window/restart restores the
  // last user position, else the default. The real HWND is then created + placed at this rect.
  if (zb_drawer_start_ratios(&app->icon_ratios) != 0) {
    app->has_icon_ratios = true;
  }
  ZbDrawerGeomRect icon = {};
  zb_drawer_place(app->has_icon_ratios ? &app->icon_ratios : nullptr, cw, ch, &icon);
  const int icon_px = effective_icon_px(app);  // WS5.7: the DPI-scaled icon edge (real DPI, or the e2e seam)
  icon.w = icon_px;
  icon.h = icon_px;
  zb_drawer_clamp(&icon, cw, ch);  // keep the DPI-sized icon fully inside the client area
  // e2e-only control-factory failure seam (inert unless --e2e-protocol AND ZIGBROWSER_AGENT_DRAWER_FAIL is
  // "panel"/"icon"): forces the matching CreateWindowExW to be treated as failed, so the failure branches are
  // driveable by a test (RoseCat 7646). Never consulted in normal runs.
  const bool fail_panel = app->force_drawer_fail != nullptr && strcmp(app->force_drawer_fail, "panel") == 0;
  const bool fail_icon = app->force_drawer_fail != nullptr && strcmp(app->force_drawer_fail, "icon") == 0;
  const bool fail_bubble = app->force_drawer_fail != nullptr && strcmp(app->force_drawer_fail, "bubble") == 0;

  // Native Win32 controls (OD-W6). SEQUENTIAL create+check so a later success can't clobber the panel's
  // failure error, and the icon is never attempted after a panel failure (RoseCat 7646). Each error is
  // captured IMMEDIATELY after its own failed call. Fail closed: no mounted/live/rows without real controls.
  HWND panel_hwnd = fail_panel ? nullptr
                               : CreateWindowExW(0, L"STATIC", L"", WS_CHILD, 0, 0, 0, 0,
                                                 app->hwnd, nullptr, app->instance, nullptr);
  if (panel_hwnd == nullptr) {
    const unsigned long e = fail_panel ? (unsigned long)ERROR_INVALID_PARAMETER : (unsigned long)GetLastError();
    fprintf(stderr, "zigBrowser: agent-drawer panel control failed (error %lu); drawer not mounted\n", e);
    fflush(stderr);
    return;  // no icon attempt, no mounted/live/rows
  }
  HWND icon_hwnd = fail_icon ? nullptr
                             : CreateWindowExW(0, L"STATIC", L"S", WS_CHILD | SS_CENTER | SS_NOTIFY | WS_TABSTOP,
                                               icon.x, icon.y, icon.w, icon.h, app->hwnd, nullptr, app->instance, nullptr);
  if (icon_hwnd == nullptr) {
    const unsigned long e = fail_icon ? (unsigned long)ERROR_INVALID_PARAMETER : (unsigned long)GetLastError();
    fprintf(stderr, "zigBrowser: agent-drawer icon control failed (error %lu); drawer not mounted\n", e);
    fflush(stderr);
    DestroyWindow(panel_hwnd);  // destroy the exact panel we just created
    return;  // no mounted/live/rows
  }
  // Subclass the icon so it handles real mouse-drag + arrow-key input through the portable logic (WS5.2).
  // SetWindowLongPtrW returns the previous proc, or 0 on failure — disambiguate with GetLastError. Fail closed:
  // destroy both controls and do NOT mount/persist/emit if the subclass fails (RoseCat b1ea2ed #5).
  SetLastError(0);
  LONG_PTR prev_proc = SetWindowLongPtrW(icon_hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(icon_subclass_proc));
  if (prev_proc == 0 && GetLastError() != 0) {
    fprintf(stderr, "zigBrowser: agent-drawer icon subclass failed (error %lu); drawer not mounted\n",
            static_cast<unsigned long>(GetLastError()));
    fflush(stderr);
    DestroyWindow(icon_hwnd);
    DestroyWindow(panel_hwnd);
    return;  // no mounted/live/rows
  }
  // WS5.3: the visible "-" minimize control — the user-reachable production route that STARTS the fold (the icon
  // is hidden while the drawer is open). Created hidden; resize_controller shows/places it top-right of the open
  // panel. Fail closed: a create or subclass failure destroys all controls and does NOT mount (RoseCat 02c39a4 #1).
  HWND min_hwnd = CreateWindowExW(0, L"STATIC", L"-", WS_CHILD | SS_CENTER | SS_NOTIFY | WS_TABSTOP,
                                  0, 0, kFoldBtnSize, kFoldBtnSize, app->hwnd, nullptr, app->instance, nullptr);
  if (min_hwnd == nullptr) {
    fprintf(stderr, "zigBrowser: agent-drawer minimize control failed (error %lu); drawer not mounted\n",
            static_cast<unsigned long>(GetLastError()));
    fflush(stderr);
    DestroyWindow(icon_hwnd);
    DestroyWindow(panel_hwnd);
    return;  // no mounted/live/rows
  }
  SetLastError(0);
  LONG_PTR min_prev = SetWindowLongPtrW(min_hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(min_subclass_proc));
  if (min_prev == 0 && GetLastError() != 0) {
    fprintf(stderr, "zigBrowser: agent-drawer minimize subclass failed (error %lu); drawer not mounted\n",
            static_cast<unsigned long>(GetLastError()));
    fflush(stderr);
    DestroyWindow(min_hwnd);
    DestroyWindow(icon_hwnd);
    DestroyWindow(panel_hwnd);
    return;  // no mounted/live/rows
  }
  // WS5.4: the inert message bubble — a READ-ONLY, PLAIN-TEXT RichEdit child of the panel. EM_SETTEXTMODE
  // TM_PLAINTEXT (set while empty) keeps it plain, EM_AUTOURLDETECT stays OFF, and the text is set literally via
  // WM_SETTEXT — never EM_STREAMIN/SF_RTF — so RTF markup and URLs render as literal text with no link and no
  // OLE object. The bubble is the conversation SURFACE, not expendable chrome: a Msftedit load or CreateWindowExW
  // failure (or the e2e "bubble" seam) FAILS CLOSED — destroy every control and do NOT mount/emit/live-count, so
  // there is never a mounted conversation with no message surface (RoseCat 6774439).
  static HMODULE s_msftedit = LoadLibraryW(L"Msftedit.dll");  // provides MSFTEDIT_CLASS ("RICHEDIT50W")
  HWND bubble_hwnd = (fail_bubble || s_msftedit == nullptr)
                         ? nullptr
                         : CreateWindowExW(0, MSFTEDIT_CLASS, L"",
                                           WS_CHILD | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                                           0, 0, 0, 0, panel_hwnd, nullptr, app->instance, nullptr);
  if (bubble_hwnd == nullptr) {
    const unsigned long e = (fail_bubble || s_msftedit == nullptr) ? (unsigned long)ERROR_INVALID_PARAMETER
                                                                   : (unsigned long)GetLastError();
    // "bubble control failed …; drawer not mounted" matches the panel/icon diagnostic shape: the bubble is the
    // conversation surface, so this failure is as fatal to the mount as the panel/icon (RoseCat 6774439).
    fprintf(stderr, "zigBrowser: agent-drawer bubble control failed (error %lu); drawer not mounted\n", e);
    fflush(stderr);
    DestroyWindow(min_hwnd);
    DestroyWindow(icon_hwnd);
    DestroyWindow(panel_hwnd);
    return;  // no mounted/live/rows: never a conversation with no message surface
  }
  SendMessageW(bubble_hwnd, EM_SETTEXTMODE, TM_PLAINTEXT, 0);  // plain text, not RTF (while still empty)
  SendMessageW(bubble_hwnd, EM_AUTOURLDETECT, FALSE, 0);       // never linkify URLs
  if (app->rtf_seam != nullptr) {
    const std::wstring w = utf8_to_wide(app->rtf_seam);
    SetWindowTextW(bubble_hwnd, w.c_str());  // literal text; no RTF parsing, no auto-link
  }
  app->min_proc = reinterpret_cast<WNDPROC>(min_prev);
  app->drawer_min = min_hwnd;
  app->drawer_bubble = bubble_hwnd;
  app->icon_proc = reinterpret_cast<WNDPROC>(prev_proc);
  app->drawer_panel = panel_hwnd;
  app->drawer_icon = icon_hwnd;
  app->drawer_mounted = true;
  drawer_live_inc();  // WS5.5: live count + running peak

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
  // WS5.2 drag seam (e2e-only): DRIVE the real icon window procedure with synthetic mouse messages — a press at
  // the icon centre and a release at centre+(dx,dy) — so the PRODUCTION handler (icon_subclass_proc) classifies,
  // clamps, moves the real HWND and persists. The seam does not compute or move anything itself.
  if (app->drag_seam != nullptr && app->drag_seam[0] != '\0') {
    // Exact grammar: `-?<1..4 digits>,-?<1..4 digits>`, no leading/internal/trailing whitespace, no '+' sign,
    // each delta in [-8000, 8000] (representable through MAKELPARAM's signed 16-bit coords with the icon
    // centre). parse_drag_delta rejects everything else (RoseCat 3d294b0).
    int dx = 0, dy = 0;
    const char *p = app->drag_seam;
    if (parse_drag_delta(&p, &dx) && *p == ',' && (++p, parse_drag_delta(&p, &dy)) && *p == '\0') {
      const int cx = icon.w / 2;
      const int cy = icon.h / 2;
      SendMessageW(app->drawer_icon, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(cx, cy));
      SendMessageW(app->drawer_icon, WM_LBUTTONUP, 0, MAKELPARAM(cx + dx, cy + dy));
    }
  }
  resize_controller(app);  // dock the page / place the icon
  // WS5.3 fold seam (e2e-only): start the REAL fold animation once the open drawer is docked. drawer_fold_start
  // runs the kFoldTimerId state machine (lerp(open, icon, ease(t)) per tick on the real panel HWND) and emits
  // the terminal fold row itself. Only meaningful when the drawer is open (OPEN=1); inert otherwise.
  if (app->fold_seam) {
    drawer_fold_start(app);
  }
}

// WS5.5b-2 (RoseCat dffa0c7): the e2e multi-window spawn. Under the e2e WINDOWS seam, create the EXTRA drawer
// windows beyond the primary (the count comes from the portable zb_drawer_extra_windows, so the C++ keeps no
// count logic) so the live count peaks at N. Each extra is a REAL window with real drawer controls on its own
// dedicated class (DefWindowProcW — WM_DESTROY must not PostQuitMessage), accounted through the same
// drawer_live_inc path and emitting its own [tree, icon, open] rows with a distinct window id. They are torn
// down (and the live count decremented) at shutdown, before the global `live` row, so the final count is 0.
// e2e-only and seam-gated; ordinary single-window runs never enter here.
// WS5.5b-2 (RoseCat 5a204f3 #1): the extra windows' own window procedure. It NEVER PostQuitMessage (so one
// closing does not end the app), and it owns the decrement through the APP-OWNED record: on the REAL
// WM_DESTROY path it finds this HWND's record in app->extra_windows and, only if it is still live, retires it
// (live=false) and decrements EXACTLY ONCE. A second WM_DESTROY, a double teardown, or an uncounted partial
// window (no record) therefore cannot decrement. GWLP_USERDATA carries the AppState* (set only once the full
// structure exists). Both bulk teardown and an early single close go through DestroyWindow -> this same path.
LRESULT CALLBACK drawer_extra_window_proc(HWND h, UINT msg, WPARAM wparam, LPARAM lparam) {
  if (msg == WM_DESTROY) {
    AppState *app = reinterpret_cast<AppState *>(GetWindowLongPtrW(h, GWLP_USERDATA));
    if (app != nullptr && !app->extra_windows.empty() &&
        zb_drawer_retire_extra(app->extra_windows.data(), app->extra_windows.size(),
                               reinterpret_cast<uintptr_t>(h))) {
      // The portable ownership helper tombstoned exactly one LIVE record for this HWND, so decrement once.
      zb_drawer_live_dec(&g_drawer_live_state);
    }
  }
  return DefWindowProcW(h, msg, wparam, lparam);
}

// Emit one extra window's truthful [tree, icon, open] rows. The extra windows have NO WebView2 page, so the
// tree row is "host,icon,panel" — it does NOT claim a page that does not exist (RoseCat 6b324c8 #3).
static void emit_extra_drawer_rows(AppState *app, int wid, ZbDrawerGeomRect panel, int ix, int iy, int icon_px) {
  char win[16];
  snprintf(win, sizeof win, "%d", wid);
  emit_protocol3(app, "DRAWER", win, "tree", "host,icon,panel");
  char rect[64];
  snprintf(rect, sizeof rect, "%d,%d,%d,%d", ix, iy, icon_px, icon_px);
  emit_protocol3(app, "DRAWER", win, "icon", rect);
  snprintf(rect, sizeof rect, "%d,%d,%d,%d", panel.x, panel.y, panel.w, panel.h);
  emit_protocol3(app, "DRAWER", win, "open", rect);
}

// Spawn exactly `count` extra drawer windows. The gate/count decision lives in the portable
// zb_drawer_after_controller (the sole caller passes its spawn_count), so this function owns no gate logic;
// it needs only a primary window (app->hwnd) and a positive count.
void spawn_extra_drawer_windows(AppState *app, int count) {
  if (app == nullptr || app->hwnd == nullptr || count <= 0) {
    return;
  }
  static bool extra_class_registered = false;
  if (!extra_class_registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = drawer_extra_window_proc;  // non-quitting; owns the per-HWND decrement
    wc.hInstance = app->instance;
    wc.lpszClassName = kDrawerExtraClassName;
    wc.hCursor = LoadCursorW(static_cast<HINSTANCE>(nullptr), MAKEINTRESOURCEW(32512));
    wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    const ATOM atom = RegisterClassExW(&wc);
    if (atom == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      log_last_error("RegisterClassExW(drawer-extra)");
      return;
    }
    extra_class_registered = true;
  }
  const bool fail_panel = app->extra_fail != nullptr && strcmp(app->extra_fail, "panel") == 0;
  const bool fail_icon = app->extra_fail != nullptr && strcmp(app->extra_fail, "icon") == 0;
  const int icon_px = effective_icon_px(app);
  for (int i = 0; i < count; i++) {
    HWND w = CreateWindowExW(0, kDrawerExtraClassName, L"zigBrowser", WS_OVERLAPPEDWINDOW,
                             CW_USEDEFAULT, CW_USEDEFAULT, 1024, 768, nullptr, nullptr, app->instance, nullptr);
    if (w == nullptr) {
      log_last_error("CreateWindowExW(drawer-extra)");
      continue;  // best-effort: fewer windows -> lower peak -> the live oracle (peak == N) surfaces it
    }
    RECT cr;
    GetClientRect(w, &cr);
    const int cw = cr.right - cr.left;
    const int ch = cr.bottom - cr.top;
    ZbDrawerGeomRect panel = {};
    zb_drawer_panel_rect(cw, ch, &panel);
    const int ix = cw - icon_px - kFoldBtnMargin;
    const int iy = ch - icon_px - kFoldBtnMargin;
    // Both real drawer controls: the docked panel + the "S" icon. The e2e extra_fail seam forces either to
    // fail so the partial-window cleanup path is driven.
    HWND panel_h = fail_panel ? nullptr
        : CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE, panel.x, panel.y, panel.w, panel.h,
                          w, nullptr, app->instance, nullptr);
    HWND icon_h = fail_icon ? nullptr
        : CreateWindowExW(0, L"STATIC", L"S", WS_CHILD, ix, iy, icon_px, icon_px, w, nullptr, app->instance, nullptr);
    if (panel_h == nullptr || icon_h == nullptr) {
      // Partial window: destroy it (never counted, so its WM_DESTROY decrements nothing), emit no rows, count
      // nothing. DestroyWindow(w) tears down any child control it did manage to create (RoseCat 6b324c8 #2).
      DestroyWindow(w);
      continue;
    }
    // The FULL structure exists: record this HWND as a LIVE app-owned record and point its GWLP_USERDATA at
    // the AppState, THEN account it and emit its rows exactly once. The record (not a flag) is the counted
    // mark; the WndProc retires it on destroy.
    app->extra_windows.push_back(ExtraWindow{reinterpret_cast<uintptr_t>(w), 1});
    SetWindowLongPtrW(w, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(app));
    ShowWindow(w, SW_SHOWNORMAL);
    drawer_live_inc();  // WS5.5: this concurrent drawer raises the running live peak toward N
    emit_extra_drawer_rows(app, app->win_id + i + 1, panel, ix, iy, icon_px);
  }
  // WS5.5b-2 (#1) close-one-early seam: close a SINGLE still-live extra through DestroyWindow (the same path as
  // bulk teardown), WITHOUT pre-removing its record — its WM_DESTROY retires the app-owned record and
  // decrements exactly once. Emit the intermediate live count so a live test sees the count fall by one.
  if (app->extra_close_one) {
    for (auto &rec : app->extra_windows) {
      if (rec.live) {
        DestroyWindow(reinterpret_cast<HWND>(rec.hwnd));  // -> drawer_extra_window_proc retires + single decrement
        break;
      }
    }
    char win[16];
    snprintf(win, sizeof win, "%d", app->win_id);
    char peak_buf[16];
    snprintf(peak_buf, sizeof peak_buf, "%d", g_drawer_live_state.peak);
    char now_buf[16];
    snprintf(now_buf, sizeof now_buf, "%d", g_drawer_live_state.live);
    emit_protocol4(app, "DRAWER", win, "liveclose", peak_buf, now_buf);
  }
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
  case WM_ZB_ABANDONED:
#ifdef ZB_WS2A3_SEAMS
    if (InterlockedCompareExchange(&g_debug_abandon_at_start, 0, 0) != 0) {
      return 0; // the seam: held for the next NavigationStarting
    }
#endif
    stop_abandoned(app);
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
    if (app != nullptr && wparam == kFoldTimerId && app->folding) {
      // WS5.3 fold tick: advance t, move the REAL panel HWND to lerp(open, icon, ease(t)), read back the mid
      // frame off that HWND, and on completion emit the fold row once. Every Win32 result is checked and the
      // branch fails closed into a STABLE state with a fixed diagnostic — a move/read failure never goes on to
      // emit a successful fold, and a first tick already at/after the deadline is not accepted as a real
      // midpoint (RoseCat 02c39a4 #3). The e2e "move"/"delay" seams force those branches.
      const ULONGLONG now = GetTickCount64();
      const unsigned int span = app->fold_ms == 0 ? 1u : app->fold_ms;
      double t = static_cast<double>(now - app->fold_start_ms) / static_cast<double>(span);
      if (t < 0.0) t = 0.0;
      if (t > 1.0) t = 1.0;
      const bool force_delay = app->fold_fail != nullptr && strcmp(app->fold_fail, "delay") == 0;
      if (force_delay) {
        t = 1.0;  // simulate a first tick that arrives at/after the deadline — no genuine midpoint observed
      }
      ZbDrawerGeomRect frame = {};
      zb_drawer_lerp(&app->fold_from, &app->fold_to, zb_drawer_ease(t), &frame);
      const bool force_move_fail = app->fold_fail != nullptr && strcmp(app->fold_fail, "move") == 0;
      if (app->drawer_panel != nullptr) {
        const bool moved = !force_move_fail && MoveWindow(app->drawer_panel, frame.x, frame.y, frame.w, frame.h, TRUE);
        if (!moved) {  // fail closed: abort the fold, leave the drawer in its open, usable state, emit no row
          fprintf(stderr, "zigBrowser: agent-drawer fold aborted: MoveWindow failed (error %lu)\n",
                  force_move_fail ? (unsigned long)ERROR_INVALID_PARAMETER : (unsigned long)GetLastError());
          fflush(stderr);
          fold_abort_open(app, hwnd);
          return 0;
        }
        ShowWindow(app->drawer_panel, SW_SHOWNA);
        // WS5.3 (plan:1539): step the animation on the compositor's vsync. A DwmFlush failure fails closed.
        const bool force_dwm_fail = app->fold_fail != nullptr && strcmp(app->fold_fail, "dwmflush") == 0;
        const HRESULT dwm_hr = force_dwm_fail ? E_FAIL : DwmFlush();
        if (FAILED(dwm_hr)) {
          fprintf(stderr, "zigBrowser: agent-drawer fold aborted: DwmFlush failed (hr 0x%08lx)\n",
                  static_cast<unsigned long>(dwm_hr));
          fflush(stderr);
          fold_abort_open(app, hwnd);
          return 0;
        }
      }
      // Capture a GENUINE midpoint only strictly before the deadline (t < 1): a delayed first tick that is
      // already terminal never produces one, so no bogus mid is emitted. A required read failure FAILS CLOSED —
      // the whole fold aborts, so no later tick can fabricate a midpoint and emit a successful fold (70fd7f9 #2).
      if (!app->fold_mid_captured && t >= 0.5 && t < 1.0) {
        if (app->drawer_panel != nullptr) {  // independent read-back of the real panel HWND, mid-transition
          // Each read is independently forceable (RoseCat e666b02 #2): "readrect" fails GetWindowRect, "readstc"
          // fails ScreenToClient. Either failure aborts the whole fold permanently (no fabricated midpoint).
          const bool force_readrect = app->fold_fail != nullptr && strcmp(app->fold_fail, "readrect") == 0;
          const bool force_readstc = app->fold_fail != nullptr && strcmp(app->fold_fail, "readstc") == 0;
          RECT wr = {};
          POINT tl = {0, 0};
          bool read_ok = !force_readrect && GetWindowRect(app->drawer_panel, &wr);
          if (read_ok) {
            tl.x = wr.left;
            tl.y = wr.top;
            read_ok = !force_readstc && (ScreenToClient(hwnd, &tl) != 0);
          }
          if (!read_ok) {  // fail closed: abort, do not let a later tick fabricate a midpoint
            fprintf(stderr, "zigBrowser: agent-drawer fold aborted: midpoint read failed (error %lu)\n",
                    (force_readrect || force_readstc) ? (unsigned long)ERROR_INVALID_PARAMETER
                                                      : (unsigned long)GetLastError());
            fflush(stderr);
            fold_abort_open(app, hwnd);
            return 0;
          }
          app->fold_mid.x = tl.x;
          app->fold_mid.y = tl.y;
          app->fold_mid.w = wr.right - wr.left;
          app->fold_mid.h = wr.bottom - wr.top;
          app->fold_mid_captured = true;
        } else {
          app->fold_mid = frame;
          app->fold_mid_captured = true;
        }
      }
      if (t >= 1.0) {
        fold_kill_timer(app, hwnd);
        app->folding = false;
        app->drawer_open = false;
        if (app->drawer_panel != nullptr) {
          ShowWindow(app->drawer_panel, SW_HIDE);  // terminal folded state: the panel is minimized to the icon
        }
        resize_controller(app);  // re-dock the page now the drawer is folded away
        if (app->fold_mid_captured) {
          char win[16];
          snprintf(win, sizeof win, "%d", app->win_id);
          char rect[64];
          snprintf(rect, sizeof rect, "%d,%d,%d,%d",
                   app->fold_mid.x, app->fold_mid.y, app->fold_mid.w, app->fold_mid.h);
          char ms_buf[16];
          snprintf(ms_buf, sizeof ms_buf, "%u", app->fold_ms);
          emit_protocol4(app, "DRAWER", win, "fold", rect, ms_buf);
        } else {
          // Reached the stable folded state, but no genuine midpoint was ever observed (a delayed/degenerate
          // timer): suppress the fold row rather than claim a midpoint we did not measure. The live oracle,
          // which waits for `fold`, then fails this run instead of silently accepting it.
          fprintf(stderr, "zigBrowser: agent-drawer fold completed with no observed midpoint "
                          "(delayed timer); fold row suppressed\n");
          fflush(stderr);
        }
      }
      return 0;
    }
    break;
  case WM_DPICHANGED:
    // WS5.7: the window moved to a monitor with a different DPI. PRODUCTION re-size path (RoseCat 7a54253 #1):
    // adopt the new per-monitor DPI from the message and re-size + re-place the icon at it. LOWORD(wparam) is
    // the new DPI (X == Y for a window). The e2e ignore seam makes this a no-op so a test can prove the handler
    // is what re-sizes the icon. (A full app would also SetWindowPos to the suggested rect in lparam; the drawer
    // only owns its icon's size here.)
    if (app != nullptr && app->drawer_mounted && !app->dpichange_ignore) {
      const int new_dpi = static_cast<int>(LOWORD(wparam));
      if (new_dpi > 0) {
        app->dpi_current = new_dpi;
        resize_controller(app);  // re-sizes the icon via effective_icon_px at the new DPI
      }
    }
    return 0;
  case WM_DESTROY:
    if (app != nullptr) {
      if (app->drawer_mounted) {
        // WS5: the child panel/icon are destroyed with the host window; account the live drawer going away
        // (zb_drawer_debug_live_count reaches 0 after every window closes — WS5.5).
        zb_drawer_live_dec(&g_drawer_live_state);
        app->drawer_mounted = false;
        app->drawer_panel = nullptr;
        app->drawer_icon = nullptr;
        app->drawer_min = nullptr;
        app->drawer_bubble = nullptr;
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

// WS2a.0: the automation script (zb_automation_set_script) goes into its own CDP world, ZB_AUTOMATION_WORLD,
// at document start, before the first navigation; then the page-world document script and the navigation as
// before. Without a script nothing changes.
HRESULT install_automation_world_then_navigate(AppState *app) {
  AcquireSRWLockShared(&g_script_lock);
  const std::string script = g_automation_script;
  ReleaseSRWLockShared(&g_script_lock);
  if (script.empty()) {
    return install_document_script_and_navigate(app);
  }
  const std::string params =
      "{\"source\":" + cdp_json_quote(script) + ",\"worldName\":" + cdp_json_quote(ZB_AUTOMATION_WORLD) + "}";
  cdp_call(app, "Page.enable", "{}", [app, params](int enabled, std::string why) {
    if (enabled != ZB_AUTO_OK) {
      fprintf(stderr, "zigBrowser: automation world: %s\n", why.c_str());
      fflush(stderr);
      return request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
    }
    cdp_call(app, "Page.addScriptToEvaluateOnNewDocument", params, [app](int code, std::string text) {
      if (code != ZB_AUTO_OK) {
        fprintf(stderr, "zigBrowser: automation world: %s\n", text.c_str());
        fflush(stderr);
        return request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
      }
      const HRESULT next = install_document_script_and_navigate(app);
      if (FAILED(next)) {
        log_hresult("AddScriptToExecuteOnDocumentCreated", next);
        request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
      }
    });
  });
  return S_OK;
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
            // WS5.5b-2 (RoseCat 35ff63f #1): the SOLE post-controller decision call site. The portable
            // zb_drawer_after_controller owns the gate/count logic; here we only spawn its extras (so the live
            // count peaks at the seam) and, when it says so, drive the primary's normal WM_CLOSE. The close
            // runs AFTER the spawn so the peak is already reached, and it lets run_core exit cleanly and emit
            // the terminal `live <peak> <final>` row BEFORE the owned-Job backstop kill.
            const AfterController after = zb_drawer_after_controller(
                app->windows_seam, app->e2e_protocol ? 1 : 0, app->agent_drawer_on ? 1 : 0,
                app->windows_seam_set ? 1 : 0);
            spawn_extra_drawer_windows(app, after.spawn_count);
            if (after.close_primary) {
              PostMessageW(app->hwnd, WM_CLOSE, 0, 0);
            }

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
                      UINT64 nav_id = 0;
                      COREWEBVIEW2_WEB_ERROR_STATUS nav_status = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
                      if (args != nullptr) {
                        args->get_IsSuccess(&is_success);
                        args->get_NavigationId(&nav_id);
                        args->get_WebErrorStatus(&nav_status);
                      }
                      // WS2a.1: after the first load, a navigation answers only its routed job (if any): no
                      // NAV/TITLE rows, and a failed one does not end the browser.
                      if (app->navigation_completed) {
                        finish_navigation(app, nav_id, is_success, nav_status);
                        return S_OK;
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
                      run_first_load_waiters(app);
                      return S_OK;
                    })
                    .Get(),
                &nav_token);

            // WS2a.1: the NavigationId of the routed navigation just started (Navigate/Reload raise this
            // after they return), so its own NavigationCompleted answers it.
            EventRegistrationToken nav_start_token = {};
            app->webview->add_NavigationStarting(
                Callback<ICoreWebView2NavigationStartingEventHandler>(
                    [app](ICoreWebView2 *sender, ICoreWebView2NavigationStartingEventArgs *args) -> HRESULT {
                      (void)sender;
                      // WS2a.3d: every start replaces the current id (valid only if readable); the routed
                      // navigation binds only to its own, first, start event.
                      UINT64 started_id = 0;
                      const bool id_ok = args != nullptr && SUCCEEDED(args->get_NavigationId(&started_id));
                      app->current_nav_known = id_ok;
                      app->current_nav_id = id_ok ? started_id : 0;
                      if (app->nav_job != nullptr && !app->nav_start_seen) {
                        app->nav_start_seen = true;
                        app->nav_id_known = id_ok;
                        app->nav_id = id_ok ? started_id : 0;
                      }
#ifdef ZB_WS2A3_SEAMS
                      if (InterlockedCompareExchange(&g_debug_abandon_at_start, 0, 0) != 0) {
                        stop_abandoned(app); // the seam: abandoned jobs are handled here, after this start
                      }
#endif
                      return S_OK;
                    })
                    .Get(),
                &nav_start_token);

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

            hr = install_automation_world_then_navigate(app);
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
  // WS2a.3c: whichever path this run leaves by, its loop has ended for every caller; an early failure (no
  // runtime, COM, the URI, the window) never reaches loop_begin, and loop_end is safe to run twice.
  struct LoopEndOnExit {
    ~LoopEndOnExit() { loop_end(); }
  } loop_end_on_exit;
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
    app.force_drawer_fail = getenv("ZIGBROWSER_AGENT_DRAWER_FAIL");  // e2e-only control-factory failure seam
    app.drag_seam = getenv("ZIGBROWSER_AGENT_DRAWER_DRAG");          // WS5.2 e2e-only synthetic-drag seam
    const char *fold_env = getenv("ZIGBROWSER_AGENT_DRAWER_FOLD");   // WS5.3 e2e-only fold-observation seam
    app.fold_seam = fold_env != nullptr && strcmp(fold_env, "1") == 0;  // accept EXACTLY "1" (RoseCat 05f2549)
    app.fold_fail = getenv("ZIGBROWSER_AGENT_DRAWER_FOLD_FAIL");     // WS5.3 e2e-only fold fail-closed causal seam
    app.dpi_seam = getenv("ZIGBROWSER_AGENT_DRAWER_DPI");            // WS5.7 e2e-only DPI override (percent)
    app.rtf_seam = getenv("ZIGBROWSER_AGENT_DRAWER_RTF");            // WS5.4 e2e-only inert-bubble literal text
    const char *dpi_ignore = getenv("ZIGBROWSER_AGENT_DRAWER_DPICHANGE_IGNORE");  // WS5.7 e2e-only causal mutant
    app.dpichange_ignore = dpi_ignore != nullptr && strcmp(dpi_ignore, "1") == 0;
    const char *ht_fail = getenv("ZIGBROWSER_AGENT_DRAWER_HITTEST_FAIL");  // WS5.7 e2e-only hit-test read-fail seam
    app.hittest_read_fail = ht_fail != nullptr && strcmp(ht_fail, "1") == 0;
    // WS5.5 e2e-only multi-window count: STRICT parse in the portable Zig (1..8, else 0), never atoi — so
    // "2junk", " 2", "+2" or an empty value leave the seam OFF rather than silently enabling a partial run.
    const int n = zb_drawer_window_count_from_env(getenv("ZIGBROWSER_AGENT_DRAWER_WINDOWS"));
    if (n >= 1) { app.windows_seam = n; app.windows_seam_set = true; }
    // WS5.5b-2 e2e-only seams: force an extra window's panel/icon control to fail (drive partial cleanup), and
    // close one counted extra early (prove the live count falls by exactly one).
    app.extra_fail = getenv("ZIGBROWSER_AGENT_DRAWER_EXTRA_FAIL");
    const char *close_one = getenv("ZIGBROWSER_AGENT_DRAWER_EXTRA_CLOSE_ONE");
    app.extra_close_one = close_one != nullptr && strcmp(close_one, "1") == 0;
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
    release_nav_job(&app); // WS2a.3d: the routed navigation's hold, before loop end answers its caller
    loop_end();
  }

  // WS5.5b-2 (RoseCat 5a204f3 #1): tear down the e2e extra windows through the SAME path as an early close —
  // DestroyWindow routes WM_DESTROY to drawer_extra_window_proc, which retires the app-owned record and
  // decrements exactly once (never here). Teardown acts ONLY on records that are still LIVE, so an
  // already-closed extra (retired by its own WM_DESTROY) is not destroyed or decremented twice. The FINAL
  // count returns to 0 with no double-decrement; the running PEAK (already at N) is unaffected.
  for (auto &rec : app.extra_windows) {
    if (rec.live) DestroyWindow(reinterpret_cast<HWND>(rec.hwnd));
  }
  app.extra_windows.clear();

  // WS5.5: after the message loop (every window has closed, so the live count is back to 0), emit the global
  // live-count row on window 1 — the PEAK concurrent drawers and the FINAL count. e2e-only, and only under the
  // WINDOWS seam, so ordinary single-window runs never emit it.
  if (app.agent_drawer_on && app.e2e_protocol && app.windows_seam_set) {
    char win[16];
    snprintf(win, sizeof win, "%d", app.win_id);
    char peak_buf[16];
    snprintf(peak_buf, sizeof peak_buf, "%d", g_drawer_live_state.peak);
    char final_buf[16];
    snprintf(final_buf, sizeof final_buf, "%d", g_drawer_live_state.live);
    emit_protocol4(&app, "DRAWER", win, "live", peak_buf, final_buf);
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

extern "C" void zb_automation_free(char *p) {
#ifdef ZB_WS2A3_SEAMS
  if (p != nullptr) {
    InterlockedDecrement(&g_strings_live);
  }
#endif
  free(p);
}

extern "C" void zb_automation_set_script(const char *source, size_t len) {
  std::string copy = source != nullptr ? std::string(source, len) : std::string();
  AcquireSRWLockExclusive(&g_script_lock);
  g_automation_script.swap(copy);
  ReleaseSRWLockExclusive(&g_script_lock);
}

// WS2a.0: world NULL evaluates in the page's main world; any other world name is the named CDP isolated
// world of the main frame (Page.createIsolatedWorld returns its context for this document).
extern "C" int zb_automation_eval_json(uint32_t win, const char *function_body, const char *arg_json,
                                       const char *world, unsigned int timeout_ms, char **out_result,
                                       char **out_err) {
  if (function_body == nullptr) {
    if (out_result != nullptr) {
      *out_result = nullptr;
    }
    return fail_with(out_err, "no function body");
  }
  const std::string expression = eval_expression(function_body, arg_json != nullptr ? arg_json : "null");
  const bool in_world = world != nullptr;
  const std::string world_name = in_world ? world : "";
  return job_submit(
      win, timeout_ms,
      [expression, in_world, world_name](Job *job, AppState *app) {
        world_evaluate(job, app, in_world, world_name, expression,
                       [](Job *j, AppState *, std::string json) { finish_evaluate(j, json); }, ZB_AUTO_ERR_INTERNAL);
      },
      out_result, out_err);
}

// WS2a.1: load `url` (after the window's first load) and answer when that navigation completes. Only
// ZB_BEFORE_UNLOAD_FAIL: WebView2 beforeunload handling arrives with the dialog slice (WS2b.2); until then
// ACCEPT/DISMISS are refused. A blocked or failed load is ZB_AUTO_ERR_NAV_FAILED.
extern "C" int zb_automation_navigate_guarded(uint32_t win, const char *url, int before_unload,
                                              unsigned int timeout_ms, char **out_err) {
  if (out_err != nullptr) {
    *out_err = nullptr;
  }
  if (url == nullptr || url[0] == '\0') {
    return fail_with(out_err, "no url");
  }
  if (before_unload != ZB_BEFORE_UNLOAD_FAIL) {
    return fail_with(out_err, "beforeunload accept/dismiss is not supported on WebView2 yet");
  }
  const std::wstring target = utf8_to_wide(url);
  if (target.empty()) {
    return fail_with(out_err, "url is not valid UTF-8");
  }
  return job_submit(
      win, timeout_ms,
      [target](Job *job, AppState *app) {
        after_first_load(job, app, [target](Job *j, AppState *a) {
          start_navigation(j, a, [&target](ICoreWebView2 *webview) { return webview->Navigate(target.c_str()); });
        });
      },
      nullptr, out_err);
}

extern "C" int zb_automation_navigate(uint32_t win, const char *url, unsigned int timeout_ms, char **out_err) {
  return zb_automation_navigate_guarded(win, url, ZB_BEFORE_UNLOAD_FAIL, timeout_ms, out_err);
}

extern "C" int zb_automation_reload(uint32_t win, unsigned int timeout_ms, char **out_err) {
  return job_submit(
      win, timeout_ms,
      [](Job *job, AppState *app) {
        after_first_load(job, app, [](Job *j, AppState *a) {
          start_navigation(j, a, [](ICoreWebView2 *webview) { return webview->Reload(); });
        });
      },
      nullptr, out_err);
}

// WS2a.1: the committed URL (ICoreWebView2::get_Source) / document.title, after the first load; "" when none.
int read_page_string(uint32_t win, unsigned int timeout_ms, char **out, bool title) {
  return job_submit(
      win, timeout_ms,
      [title](Job *job, AppState *app) {
        after_first_load(job, app, [title](Job *j, AppState *a) {
          LPWSTR text = nullptr;
          const HRESULT hr = title ? a->webview->get_DocumentTitle(&text) : a->webview->get_Source(&text);
          std::string value = SUCCEEDED(hr) && text != nullptr ? wide_to_utf8(text) : std::string();
          if (text != nullptr) {
            CoTaskMemFree(text);
          }
          if (FAILED(hr)) {
            return job_finish(j, ZB_AUTO_ERR_INTERNAL, {}, title ? "get_DocumentTitle failed" : "get_Source failed");
          }
          job_finish(j, ZB_AUTO_OK, std::move(value));
        });
      },
      out, nullptr);
}

extern "C" int zb_automation_get_url(uint32_t win, unsigned int timeout_ms, char **out_url) {
  return read_page_string(win, timeout_ms, out_url, false);
}

extern "C" int zb_automation_get_title(uint32_t win, unsigned int timeout_ms, char **out_title) {
  return read_page_string(win, timeout_ms, out_title, true);
}

// WS2b.1: native (trusted) input (webkit_shim.h "Native (trusted) input") as CDP Input.dispatch* events. Each
// op waits for the window's first load; it returns once the page's renderer has taken every event.
extern "C" int zb_native_move(uint32_t win, double x, double y, const char *expected_doc, unsigned int timeout_ms,
                              char **out_err) {
  if (!std::isfinite(x) || !std::isfinite(y)) {
    return fail_with(out_err, "coordinates are not finite");
  }
  InputEvents events{{"Input.dispatchMouseEvent", mouse_params("mouseMoved", x, y, "none", 0, 0)}};
  return native_submit(win, expected_doc, false, timeout_ms, std::move(events), [x, y] { remember_pointer(x, y); },
                       out_err);
}

extern "C" int zb_native_click(uint32_t win, double x, double y, int button, const char *expected_doc,
                               unsigned int timeout_ms, char **out_err) {
  if (!std::isfinite(x) || !std::isfinite(y)) {
    return fail_with(out_err, "coordinates are not finite");
  }
  const int number = button > 0 ? button : 1;
  const MouseButton *pressed = nullptr;
  for (const MouseButton &b : kMouseButtons) {
    if (b.number == number) {
      pressed = &b;
    }
  }
  if (pressed == nullptr) {
    return fail_with(out_err, "unsupported mouse button");
  }
  InputEvents events{
      {"Input.dispatchMouseEvent", mouse_params("mouseMoved", x, y, "none", 0, 0)},
      {"Input.dispatchMouseEvent", mouse_params("mousePressed", x, y, pressed->name, pressed->bit, 1)},
      {"Input.dispatchMouseEvent", mouse_params("mouseReleased", x, y, pressed->name, 0, 1)},
  };
  return native_submit(win, expected_doc, false, timeout_ms, std::move(events), [x, y] { remember_pointer(x, y); },
                       out_err);
}

extern "C" int zb_native_scroll(uint32_t win, double x, double y, double delta_x, double delta_y,
                                const char *expected_doc, unsigned int timeout_ms, char **out_err) {
  if (!std::isfinite(x) || !std::isfinite(y) || !std::isfinite(delta_x) || !std::isfinite(delta_y)) {
    return fail_with(out_err, "coordinates are not finite");
  }
  const std::string params = "{\"type\":\"mouseWheel\",\"x\":" + json_number(x) + ",\"y\":" + json_number(y) +
                             ",\"deltaX\":" + json_number(delta_x) + ",\"deltaY\":" + json_number(delta_y) + "}";
  return native_submit(win, expected_doc, false, timeout_ms, InputEvents{{"Input.dispatchMouseEvent", params}},
                       nullptr, out_err);
}

extern "C" int zb_native_pointer(uint32_t win, double *out_x, double *out_y) {
  if (win != 0) {
    return 0; // the Windows shell has one window
  }
  AcquireSRWLockShared(&g_jobs_lock);
  const bool ended = g_loop_ended; // the window is gone with the loop, and its pointer with it
  ReleaseSRWLockShared(&g_jobs_lock);
  AcquireSRWLockShared(&g_pointer_lock);
  const bool known = g_pointer_known && !ended;
  if (known && out_x != nullptr) {
    *out_x = g_pointer_x;
  }
  if (known && out_y != nullptr) {
    *out_y = g_pointer_y;
  }
  ReleaseSRWLockShared(&g_pointer_lock);
  return known ? 1 : 0;
}

extern "C" int zb_native_key(uint32_t win, const char *key, int modifiers, const char *expected_doc,
                             unsigned int timeout_ms, int *out_releases, char **out_err) {
  if (out_releases != nullptr) {
    *out_releases = 0;
  }
  KeySpec spec;
  if (key == nullptr || !key_for(key, &spec)) {
    return fail_with(out_err, "unknown key");
  }
  // Shift turns a letter into its upper case, as a keyboard would (GTK's auto_native_press).
  if ((modifiers & ZB_NATIVE_MOD_SHIFT) != 0 && spec.key.size() == 1 && spec.key[0] >= 'a' && spec.key[0] <= 'z') {
    spec.key[0] = static_cast<char>(spec.key[0] - 'a' + 'A');
    spec.text = spec.key;
  }
  InputEvents events;
  const int releases = press_key(&events, spec, modifiers);
  const int code = native_submit(win, expected_doc, true, timeout_ms, std::move(events), nullptr, out_err);
  if (code == ZB_AUTO_OK && out_releases != nullptr) {
    *out_releases = releases;
  }
  return code;
}

// One job per character, the deadline checked before each (so the text can be partially typed, and
// *out_chars / *out_releases count exactly what went out). A character already submitted gets the waiter
// grace beyond the deadline to finish, so one that reached the page is never left uncounted.
extern "C" int zb_native_text(uint32_t win, const char *text, const char *expected_doc, unsigned int timeout_ms,
                              int *out_releases, int *out_chars, char **out_err) {
  if (out_releases != nullptr) {
    *out_releases = 0;
  }
  if (out_chars != nullptr) {
    *out_chars = 0;
  }
  if (out_err != nullptr) {
    *out_err = nullptr;
  }
  if (text == nullptr || (text[0] != '\0' && utf8_to_wide(text).empty())) {
    return fail_with(out_err, "text is not valid UTF-8");
  }
  const std::string all = text;
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  int releases = 0;
  int chars = 0;
  int code = ZB_AUTO_OK;
  for (size_t i = 0; i < all.size() && code == ZB_AUTO_OK;) {
    const ULONGLONG now = GetTickCount64();
    if (now >= deadline) {
      code = ZB_AUTO_ERR_TIMEOUT;
      break;
    }
    const size_t len = utf8_char_len(all, i);
    bool shift = false;
    const KeySpec spec = char_key(all.substr(i, len), &shift);
    InputEvents events;
    const int sent = press_key(&events, spec, shift ? ZB_NATIVE_MOD_SHIFT : 0);
    code = native_submit(win, expected_doc, true, static_cast<unsigned int>(deadline - now) + kWaiterGraceMs,
                         std::move(events), nullptr, out_err);
    if (code == ZB_AUTO_OK) {
      releases += sent;
      chars++;
      i += len;
    }
  }
  if (out_releases != nullptr) {
    *out_releases = releases;
  }
  if (out_chars != nullptr) {
    *out_chars = chars;
  }
  return code;
}

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

#ifdef ZB_WS2A3_SEAMS
// ---- WS2a.3 test seams (tests/windows/ws2a3_async_ownership.c; the slice executable only) ----

extern "C" void zb_automation_debug_complete_hold_ms(unsigned int ms) {
  InterlockedExchange(&g_debug_complete_hold_ms, static_cast<LONG>(ms));
}

extern "C" int zb_automation_debug_live_jobs(void) { return static_cast<int>(InterlockedCompareExchange(&g_live_jobs, 0, 0)); }

extern "C" void zb_automation_debug_step_hold_ms(unsigned int ms) {
  InterlockedExchange(&g_debug_step_hold_ms, static_cast<LONG>(ms));
}

extern "C" void zb_automation_debug_waiter_grace(unsigned int ms) {
  InterlockedExchange(&g_debug_waiter_grace_ms, static_cast<LONG>(ms));
}

extern "C" int zb_automation_debug_late_dispatches(void) {
  return static_cast<int>(InterlockedCompareExchange(&g_late_dispatches, 0, 0));
}

extern "C" void zb_automation_debug_abandon_at_start(int on) {
  InterlockedExchange(&g_debug_abandon_at_start, on != 0 ? 1 : 0);
}

extern "C" int zb_automation_debug_strings_live(void) {
  return static_cast<int>(InterlockedCompareExchange(&g_strings_live, 0, 0));
}
#endif

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
