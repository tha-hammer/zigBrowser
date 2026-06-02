#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <WebView2.h>

#include <stdio.h>

#include "webkit_shim.h"

namespace {

bool webview2_runtime_version(char *buf, size_t len) {
  if (buf == nullptr || len == 0) {
    return false;
  }

  LPWSTR wide_version = nullptr;
  HRESULT hr = GetAvailableCoreWebView2BrowserVersionString(nullptr, &wide_version);
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

} // namespace

extern "C" int zb_app_run(const char *uri, int print_title, int e2e_protocol) {
  (void)uri;
  (void)print_title;
  (void)e2e_protocol;

  char version[128] = {0};
  if (!webview2_runtime_version(version, sizeof(version))) {
    return ZB_EXIT_RUNTIME_MISSING;
  }

  return ZB_EXIT_WEBVIEW_INIT_FAILED;
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
