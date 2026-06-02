#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <objbase.h>
#include <wrl.h>
#include <WebView2.h>

#include <stdio.h>

#include <string>

#include "webkit_shim.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

constexpr wchar_t kWindowClassName[] = L"zigBrowserWebView2Host";
constexpr int kWebView2LoadFailDomain = 2;

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
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);

  const ATOM atom = RegisterClassExW(&wc);
  if (atom == 0 && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return false;
  }

  HWND hwnd = CreateWindowExW(0, kWindowClassName, L"zigBrowser",
                              WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
                              CW_USEDEFAULT, 1024, 768, nullptr, nullptr,
                              app->instance, app);
  if (hwnd == nullptr) {
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

  const HRESULT hr = app->webview->Navigate(app->uri.c_str());
  if (FAILED(hr)) {
    request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
  }
}

HRESULT install_document_script_and_navigate(AppState *app) {
  if (app == nullptr || !app->webview) {
    return E_POINTER;
  }

  // M3 only needs the document-created hook live; M4/M5 wire the host IPC body.
  static constexpr wchar_t script[] =
      L"window.__zigBrowserBackend = 'webview2';";
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
      script, script_handler.Get());
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
              request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
              return S_OK;
            }

            app->controller = controller;
            HRESULT hr = app->controller->get_CoreWebView2(&app->webview);
            if (FAILED(hr) || !app->webview) {
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

            hr = install_document_script_and_navigate(app);
            if (FAILED(hr)) {
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
              request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
              return S_OK;
            }

            app->environment = environment;
            HRESULT hr = create_controller(app);
            if (FAILED(hr)) {
              request_quit(app, ZB_EXIT_WEBVIEW_INIT_FAILED);
            }
            return S_OK;
          });

  return CreateCoreWebView2EnvironmentWithOptions(nullptr, nullptr, nullptr,
                                                 env_handler.Get());
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
    return ZB_EXIT_WEBVIEW_INIT_FAILED;
  }

  AppState app;
  app.instance = GetModuleHandleW(nullptr);
  app.uri = utf8_to_wide(uri);
  app.print_title = print_title != 0;
  app.e2e_protocol = e2e_protocol != 0;

  int rc = ZB_EXIT_SUCCESS;
  if (app.uri.empty() || !create_host_window(&app)) {
    rc = ZB_EXIT_WEBVIEW_INIT_FAILED;
  } else {
    HRESULT hr = create_environment(&app);
    if (FAILED(hr)) {
      rc = ZB_EXIT_WEBVIEW_INIT_FAILED;
    } else {
      rc = run_message_loop(&app);
    }
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
