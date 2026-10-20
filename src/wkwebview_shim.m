#include "webkit_shim.h"

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const int ZB_DECISION_USE = 0;
static const int ZB_DECISION_IGNORE = 1;
static const int ZB_DECISION_OPEN_SUBWINDOW = 2;

static const int ZB_DTYPE_NAVIGATION = 0;
static const int ZB_DTYPE_NEW_WINDOW = 1;
static const int ZB_DTYPE_RESPONSE = 2;

static const int ZB_WK_LOAD_FAIL_DOMAIN = 3;
static const NSTimeInterval ZB_NAVIGATION_TIMEOUT_SECONDS = 15.0;

@class ZBAppHost;
@class ZBWindowHost;

struct ZbApp {
  void *host;
};

struct ZbWindow {
  void *host;
};

static ZBAppHost *g_active_app = nil;
static NSString *zb_auto_script = nil;  // MS2a automation.js (set by zb_automation_set_script)
static void handle_signal(int signo);

static void emit_safe_field(const char *text) {
  const char *p = text != NULL ? text : "";
  for (; *p != '\0'; ++p) {
    if (*p == '\t' || *p == '\n' || *p == '\r') {
      fputc(' ', stdout);
    } else {
      fputc(*p, stdout);
    }
  }
}

static void emit_protocol1(BOOL enabled, const char *tag, const char *a) {
  if (!enabled) {
    return;
  }
  fputs(tag, stdout);
  fputc('\t', stdout);
  emit_safe_field(a);
  fputc('\n', stdout);
  fflush(stdout);
}

static void emit_protocol2(BOOL enabled, const char *tag, const char *a,
                           const char *b) {
  if (!enabled) {
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

static void emit_protocol3(BOOL enabled, const char *tag, const char *a,
                           const char *b, const char *c) {
  if (!enabled) {
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

static NSString *string_from_c(const char *text) {
  if (text == NULL) {
    return @"";
  }
  NSString *value = [NSString stringWithUTF8String:text];
  return value != nil ? value : @"";
}

static const char *utf8_or_empty(NSString *text) {
  return text != nil ? text.UTF8String : "";
}

static NSInteger snapshot_settle_ms_from_env(void) {
  const char *raw = getenv("ZB_SNAPSHOT_SETTLE_MS");
  if (raw == NULL || raw[0] == '\0') {
    return 0;
  }

  char *end = NULL;
  long value = strtol(raw, &end, 10);
  if (end == raw || *end != '\0' || value <= 0) {
    return 0;
  }
  return (NSInteger)value;
}

static NSString *json_string_from_object(id object) {
  id value = object != nil ? object : @{};
  if (![NSJSONSerialization isValidJSONObject:value] &&
      ![value isKindOfClass:[NSString class]] &&
      ![value isKindOfClass:[NSNumber class]] &&
      ![value isKindOfClass:[NSNull class]]) {
    return nil;
  }

  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:value
                                                 options:NSJSONWritingFragmentsAllowed
                                                   error:&error];
  if (data == nil || error != nil) {
    return nil;
  }
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

static id object_from_json_string(NSString *json) {
  if (json.length == 0) {
    return nil;
  }

  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) {
    return nil;
  }

  NSError *error = nil;
  id value = [NSJSONSerialization JSONObjectWithData:data
                                             options:NSJSONReadingFragmentsAllowed
                                               error:&error];
  return error == nil ? value : nil;
}

static NSDictionary *dictionary_from_message_body(id body) {
  if ([body isKindOfClass:[NSDictionary class]]) {
    return (NSDictionary *)body;
  }
  if (![body isKindOfClass:[NSString class]]) {
    return nil;
  }

  NSData *data = [(NSString *)body dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) {
    return nil;
  }

  NSError *error = nil;
  id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
  if (error != nil || ![value isKindOfClass:[NSDictionary class]]) {
    return nil;
  }
  return (NSDictionary *)value;
}

static NSString *derive_app_base(NSString *uri_text) {
  if (uri_text.length == 0) {
    return @"";
  }

  NSURL *url = [NSURL URLWithString:uri_text];
  if (url == nil) {
    return uri_text;
  }

  if ([url isFileURL]) {
    NSURL *dir = [url URLByDeletingLastPathComponent];
    NSString *absolute = dir.absoluteString;
    if ([absolute hasSuffix:@"/"]) {
      return absolute;
    }
    return [absolute stringByAppendingString:@"/"];
  }

  NSString *absolute = url.absoluteString;
  NSRange slash = [absolute rangeOfString:@"/" options:NSBackwardsSearch];
  if (slash.location == NSNotFound) {
    return absolute;
  }
  return [absolute substringToIndex:slash.location + 1];
}

static void stop_nsapp_run_loop(void) {
  [NSApp stop:nil];
  NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                      location:NSZeroPoint
                                 modifierFlags:0
                                     timestamp:0
                                  windowNumber:0
                                       context:nil
                                       subtype:0
                                         data1:0
                                         data2:0];
  [NSApp postEvent:event atStart:NO];
}

@interface ZBAppHost : NSObject <NSApplicationDelegate>
@property(nonatomic, assign) BOOL printTitle;
@property(nonatomic, assign) BOOL e2eProtocol;
@property(nonatomic, assign) int exitCode;
@property(nonatomic, copy) NSString *appBase;
@property(nonatomic, strong) NSMutableArray<ZBWindowHost *> *windows;
@property(nonatomic, assign) ZBWindowHost *mainWindow;
- (instancetype)initWithURI:(NSString *)uri printTitle:(BOOL)printTitle e2eProtocol:(BOOL)e2eProtocol;
- (ZBWindowHost *)createWindowWithWebView:(WKWebView *)webView child:(BOOL)child uri:(NSString *)uri;
- (void)removeWindow:(ZBWindowHost *)window;
- (void)emitWindowCount;
- (void)emitLoadFailForURI:(NSString *)uri code:(NSInteger)code;
- (void)requestExit:(int)code;
- (void)reloadMainWindowBypassingCache:(BOOL)bypassCache;
@end

static void handle_signal(int signo) {
  ZBAppHost *app = g_active_app;
  if (app == nil) {
    _exit(signo == SIGINT ? ZB_EXIT_CANCELLED : ZB_EXIT_SUCCESS);
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    if (signo == SIGHUP) {
      [app reloadMainWindowBypassingCache:NO];
    } else {
      [app requestExit:ZB_EXIT_CANCELLED];
    }
  });
}

@interface ZBWindowHost : NSObject <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply>
@property(nonatomic, assign) ZBAppHost *app;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, assign) ZbWindow *cWindow;
@property(nonatomic, assign) BOOL child;
@property(nonatomic, assign) BOOL finishedOrFailed;
@property(nonatomic, strong) NSTimer *timeoutTimer;
@property(nonatomic, copy) NSString *requestedURI;
- (instancetype)initWithApp:(ZBAppHost *)app webView:(WKWebView *)webView child:(BOOL)child;
- (void)loadURI:(NSString *)uri;
- (void)reloadBypassingCache:(BOOL)bypassCache;
- (NSString *)failingURIForWebView:(WKWebView *)webView error:(NSError *)error;
- (void)close;
@end

@implementation ZBAppHost
- (instancetype)initWithURI:(NSString *)uri printTitle:(BOOL)printTitle e2eProtocol:(BOOL)e2eProtocol {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  _printTitle = printTitle;
  _e2eProtocol = e2eProtocol;
  _exitCode = ZB_EXIT_SUCCESS;
  _appBase = derive_app_base(uri);
  _windows = [NSMutableArray array];
  return self;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  (void)sender;
  return NO;
}

- (ZBWindowHost *)createWindowWithWebView:(WKWebView *)webView child:(BOOL)child uri:(NSString *)uri {
  if (self.windows.count >= ZB_MAX_WINDOWS) {
    fprintf(stderr, "window cap reached (%d); refusing new sub-window\n", ZB_MAX_WINDOWS);
    return nil;
  }

  ZBWindowHost *host = [[ZBWindowHost alloc] initWithApp:self webView:webView child:child];
  if (host == nil) {
    return nil;
  }

  ZbWindow *c_window = calloc(1, sizeof(ZbWindow));
  if (c_window == NULL) {
    return nil;
  }
  c_window->host = (__bridge void *)host;
  host.cWindow = c_window;

  [self.windows addObject:host];
  if (!child) {
    self.mainWindow = host;
  }
  [self emitWindowCount];
  [host.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];

  if (uri.length > 0) {
    [host loadURI:uri];
  }
  return host;
}

- (void)removeWindow:(ZBWindowHost *)window {
  if (window == nil) {
    return;
  }
  [self.windows removeObject:window];
  if (self.mainWindow == window) {
    self.mainWindow = nil;
  }
  [self emitWindowCount];
  if (self.windows.count == 0) {
    [self requestExit:self.exitCode];
  }
}

- (void)emitWindowCount {
  char count_buf[32];
  snprintf(count_buf, sizeof(count_buf), "%lu", (unsigned long)self.windows.count);
  emit_protocol1(self.e2eProtocol, "WINCOUNT", count_buf);
}

- (void)emitLoadFailForURI:(NSString *)uri code:(NSInteger)code {
  char domain_buf[32];
  char code_buf[32];
  snprintf(domain_buf, sizeof(domain_buf), "%d", ZB_WK_LOAD_FAIL_DOMAIN);
  snprintf(code_buf, sizeof(code_buf), "%ld", (long)code);
  emit_protocol3(self.e2eProtocol, "LOAD_FAIL", utf8_or_empty(uri), domain_buf, code_buf);
}

- (void)requestExit:(int)code {
  self.exitCode = code;
  NSArray<ZBWindowHost *> *copy = [self.windows copy];
  for (ZBWindowHost *window in copy) {
    [window close];
  }
  stop_nsapp_run_loop();
}

- (void)reloadMainWindowBypassingCache:(BOOL)bypassCache {
  [self.mainWindow reloadBypassingCache:bypassCache];
}
@end

@implementation ZBWindowHost
- (instancetype)initWithApp:(ZBAppHost *)app webView:(WKWebView *)webView child:(BOOL)child {
  self = [super init];
  if (self == nil) {
    return nil;
  }

  _app = app;
  _child = child;
  _webView = webView != nil ? webView : [ZBWindowHost newConfiguredWebView];
  if (_webView == nil) {
    return nil;
  }

  _webView.navigationDelegate = self;
  _webView.UIDelegate = self;
  [_webView.configuration.userContentController removeScriptMessageHandlerForName:@"zbHost"];
  [_webView.configuration.userContentController addScriptMessageHandlerWithReply:self contentWorld:WKContentWorld.pageWorld name:@"zbHost"];

  NSRect frame = NSMakeRect(120, 120, 1024, 768);
  NSUInteger style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                     NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
  _window = [[NSWindow alloc] initWithContentRect:frame
                                        styleMask:style
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  _window.releasedWhenClosed = NO;
  _window.title = @"zigBrowser";
  _window.contentView = _webView;
  return self;
}

+ (WKWebView *)newConfiguredWebView {
  WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
  configuration.preferences.javaScriptCanOpenWindowsAutomatically = YES;
  configuration.userContentController = [[WKUserContentController alloc] init];
  NSString *script = @"window.__zigBrowserBackend = 'wkwebview';";
  WKUserScript *userScript = [[WKUserScript alloc] initWithSource:script
                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                 forMainFrameOnly:NO];
  [configuration.userContentController addUserScript:userScript];
  // MS2a: automation.js (set by zb_automation_set_script before zb_app_run) is injected into the
  // named automation content world, where handle_body reads globalThis.__zbAutomation.
  if (zb_auto_script != nil) {
    WKContentWorld *autoWorld = [WKContentWorld worldWithName:@ZB_AUTOMATION_WORLD];
    WKUserScript *autoUserScript = [[WKUserScript alloc] initWithSource:zb_auto_script
                                                         injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                      forMainFrameOnly:NO
                                                        inContentWorld:autoWorld];
    [configuration.userContentController addUserScript:autoUserScript];
  }
  return [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768) configuration:configuration];
}

- (void)loadURI:(NSString *)uri {
  self.finishedOrFailed = NO;
  self.requestedURI = uri ?: @"";
  [self.timeoutTimer invalidate];
  self.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:ZB_NAVIGATION_TIMEOUT_SECONDS
                                                       target:self
                                                     selector:@selector(onNavigationTimeout:)
                                                     userInfo:nil
                                                      repeats:NO];
  NSURL *url = [NSURL URLWithString:uri];
  if (url == nil) {
    [self.timeoutTimer invalidate];
    [self.app emitLoadFailForURI:uri code:NSURLErrorBadURL];
    [self.app requestExit:ZB_EXIT_LOAD_FAILED];
    return;
  }
  [self.webView loadRequest:[NSURLRequest requestWithURL:url]];
}

- (void)reloadBypassingCache:(BOOL)bypassCache {
  self.finishedOrFailed = NO;
  self.requestedURI = self.webView.URL.absoluteString ?: self.requestedURI ?: @"";
  [self.timeoutTimer invalidate];
  self.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:ZB_NAVIGATION_TIMEOUT_SECONDS
                                                       target:self
                                                     selector:@selector(onNavigationTimeout:)
                                                     userInfo:nil
                                                      repeats:NO];
  if (bypassCache) {
    [self.webView reloadFromOrigin:nil];
  } else {
    [self.webView reload:nil];
  }
}

- (void)close {
  [self.timeoutTimer invalidate];
  self.timeoutTimer = nil;
  [self.webView.configuration.userContentController removeScriptMessageHandlerForName:@"zbHost"];
  self.webView.navigationDelegate = nil;
  self.webView.UIDelegate = nil;
  [self.webView stopLoading:nil];
  self.window.contentView = nil;
  [self.window orderOut:nil];
  if (self.cWindow != NULL) {
    self.cWindow->host = NULL;
    free(self.cWindow);
    self.cWindow = NULL;
  }
}

- (void)onNavigationTimeout:(NSTimer *)timer {
  (void)timer;
  if (self.finishedOrFailed) {
    return;
  }
  self.finishedOrFailed = YES;
  NSString *uri = self.webView.URL.absoluteString ?: self.requestedURI ?: @"";
  [self.webView stopLoading:nil];
  [self.app emitLoadFailForURI:uri code:NSURLErrorTimedOut];
  [self.app requestExit:ZB_EXIT_TIMEOUT];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  (void)navigation;
  self.finishedOrFailed = YES;
  [self.timeoutTimer invalidate];
  self.timeoutTimer = nil;

  NSString *uri = webView.URL.absoluteString ?: @"";
  NSString *title = webView.title ?: @"";
  if (self.child) {
    emit_protocol1(self.app.e2eProtocol, "SUBWIN", utf8_or_empty(uri));
    return;
  }

  if (self.app.printTitle) {
    printf("TITLE\t");
    emit_safe_field(utf8_or_empty(title));
    fputc('\n', stdout);
    fflush(stdout);
  }
  emit_protocol2(self.app.e2eProtocol, "NAV", utf8_or_empty(uri), utf8_or_empty(title));
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  (void)navigation;
  [self handleLoadFailureForWebView:webView error:error];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  (void)navigation;
  [self handleLoadFailureForWebView:webView error:error];
}

- (void)handleLoadFailureForWebView:(WKWebView *)webView error:(NSError *)error {
  if (self.finishedOrFailed && error.code == NSURLErrorCancelled) {
    return;
  }
  self.finishedOrFailed = YES;
  [self.timeoutTimer invalidate];
  self.timeoutTimer = nil;
  NSString *uri = [self failingURIForWebView:webView error:error];
  NSInteger code = error != nil ? error.code : -1;
  [self.app emitLoadFailForURI:uri code:code];
  [self.app requestExit:ZB_EXIT_LOAD_FAILED];
}

- (NSString *)failingURIForWebView:(WKWebView *)webView error:(NSError *)error {
  id failingString = error.userInfo[NSURLErrorFailingURLStringErrorKey];
  if ([failingString isKindOfClass:[NSString class]] && [failingString length] > 0) {
    return (NSString *)failingString;
  }

  id failingURL = error.userInfo[NSURLErrorFailingURLErrorKey];
  if ([failingURL isKindOfClass:[NSURL class]]) {
    NSString *absolute = [(NSURL *)failingURL absoluteString];
    if (absolute.length > 0) {
      return absolute;
    }
  }

  NSString *current = webView.URL.absoluteString;
  if (current.length > 0) {
    return current;
  }

  return self.requestedURI ?: @"";
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                     decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  (void)webView;
  NSURL *url = navigationAction.request.URL;
  NSString *candidate = url.absoluteString ?: @"";
  int dtype = navigationAction.targetFrame == nil ? ZB_DTYPE_NEW_WINDOW : ZB_DTYPE_NAVIGATION;
  int action = zb_policy_decide(utf8_or_empty(self.app.appBase), utf8_or_empty(candidate), dtype);

  if (action == ZB_DECISION_USE) {
    decisionHandler(WKNavigationActionPolicyAllow);
    return;
  }

  if (action == ZB_DECISION_OPEN_SUBWINDOW && dtype == ZB_DTYPE_NEW_WINDOW) {
    decisionHandler(WKNavigationActionPolicyCancel);
    [self.app createWindowWithWebView:nil child:YES uri:candidate];
    return;
  }

  decisionHandler(WKNavigationActionPolicyCancel);
  emit_protocol1(self.app.e2eProtocol, "BLOCKED", utf8_or_empty(candidate));
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                      decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
  (void)webView;
  NSString *candidate = navigationResponse.response.URL.absoluteString ?: @"";
  int action = zb_policy_decide(utf8_or_empty(self.app.appBase), utf8_or_empty(candidate), ZB_DTYPE_RESPONSE);
  if (action == ZB_DECISION_USE) {
    decisionHandler(WKNavigationResponsePolicyAllow);
    return;
  }
  decisionHandler(WKNavigationResponsePolicyCancel);
  emit_protocol1(self.app.e2eProtocol, "BLOCKED", utf8_or_empty(candidate));
}

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures {
  (void)webView;
  (void)windowFeatures;
  NSString *candidate = navigationAction.request.URL.absoluteString ?: @"";
  int action = zb_policy_decide(utf8_or_empty(self.app.appBase), utf8_or_empty(candidate), ZB_DTYPE_NEW_WINDOW);
  if (action != ZB_DECISION_OPEN_SUBWINDOW) {
    emit_protocol1(self.app.e2eProtocol, "BLOCKED", utf8_or_empty(candidate));
    return nil;
  }

  WKWebView *childView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768)
                                           configuration:configuration];
  ZBWindowHost *child = [self.app createWindowWithWebView:childView child:YES uri:nil];
  return child.webView;
}

- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
                 replyHandler:(void (^)(id _Nullable reply, NSString *_Nullable errorMessage))replyHandler {
  (void)userContentController;
  NSDictionary *payload = dictionary_from_message_body(message.body);
  if (payload == nil) {
    emit_protocol2(self.app.e2eProtocol, "IPCERR", "invalid", "BadArgs");
    replyHandler(nil, @"BadArgs");
    return;
  }

  id cmd_value = payload[@"cmd"];
  if (![cmd_value isKindOfClass:[NSString class]] || [(NSString *)cmd_value length] == 0) {
    emit_protocol2(self.app.e2eProtocol, "IPCERR", "invalid", "BadArgs");
    replyHandler(nil, @"BadArgs");
    return;
  }

  NSString *cmd = (NSString *)cmd_value;
  id args_value = payload[@"args"] ?: @{};
  NSString *args_json = json_string_from_object(args_value);
  if (args_json == nil) {
    emit_protocol2(self.app.e2eProtocol, "IPCERR", utf8_or_empty(cmd), "BadArgs");
    replyHandler(nil, @"BadArgs");
    return;
  }

  const char *result_json = NULL;
  const char *err_text = NULL;
  int rc = zb_ipc_dispatch(utf8_or_empty(cmd), utf8_or_empty(args_json), &result_json, &err_text);
  if (rc == 0 && result_json != NULL) {
    NSString *result_text = string_from_c(result_json);
    emit_protocol2(self.app.e2eProtocol, "IPC", utf8_or_empty(cmd), utf8_or_empty(result_text));
    id result = object_from_json_string(result_text);
    replyHandler(result != nil ? result : result_text, nil);
    return;
  }

  NSString *error_text = string_from_c(err_text != NULL ? err_text : "UnknownCommand");
  emit_protocol2(self.app.e2eProtocol, "IPCERR", utf8_or_empty(cmd), utf8_or_empty(error_text));
  replyHandler(nil, error_text);
}
@end

@interface ZBSnapshotRunner : NSObject <WKNavigationDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, copy) NSString *uri;
@property(nonatomic, copy) NSString *outPath;
@property(nonatomic, assign) BOOL printTitle;
@property(nonatomic, assign) BOOL done;
@property(nonatomic, assign) int exitCode;
@property(nonatomic, assign) NSInteger settleMilliseconds;
@property(nonatomic, strong) NSTimer *timeoutTimer;
- (instancetype)initWithURI:(NSString *)uri outPath:(NSString *)outPath printTitle:(BOOL)printTitle;
- (int)run;
- (void)takeSnapshot;
@end

@implementation ZBSnapshotRunner
- (instancetype)initWithURI:(NSString *)uri outPath:(NSString *)outPath printTitle:(BOOL)printTitle {
  self = [super init];
  if (self == nil) {
    return nil;
  }
  _uri = [uri copy];
  _outPath = [outPath copy];
  _printTitle = printTitle;
  _exitCode = ZB_EXIT_SUCCESS;
  _settleMilliseconds = snapshot_settle_ms_from_env();
  return self;
}

- (int)run {
  WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
  self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768) configuration:configuration];
  if (self.webView == nil) {
    return ZB_EXIT_WEBVIEW_INIT_FAILED;
  }
  self.webView.navigationDelegate = self;

  NSRect frame = NSMakeRect(80, 80, 1024, 768);
  self.window = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:NSWindowStyleMaskTitled
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  self.window.releasedWhenClosed = NO;
  self.window.title = @"zigBrowser Snapshot";
  self.window.contentView = self.webView;
  [self.window orderFront:nil];

  NSURL *url = [NSURL URLWithString:self.uri];
  if (url == nil) {
    return ZB_EXIT_INVALID_URI;
  }

  self.timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:ZB_NAVIGATION_TIMEOUT_SECONDS
                                                       target:self
                                                     selector:@selector(onTimeout:)
                                                     userInfo:nil
                                                      repeats:NO];
  [self.webView loadRequest:[NSURLRequest requestWithURL:url]];

  while (!self.done) {
    @autoreleasepool {
      [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
  }

  [self.timeoutTimer invalidate];
  self.webView.navigationDelegate = nil;
  self.window.contentView = nil;
  [self.window orderOut:nil];
  return self.exitCode;
}

- (void)onTimeout:(NSTimer *)timer {
  (void)timer;
  [self.webView stopLoading:nil];
  self.exitCode = ZB_EXIT_TIMEOUT;
  self.done = YES;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  (void)navigation;
  [self.timeoutTimer invalidate];

  if (self.printTitle) {
    NSString *title = webView.title ?: @"";
    printf("TITLE\t");
    emit_safe_field(utf8_or_empty(title));
    fputc('\n', stdout);
    fflush(stdout);
  }

  if (self.settleMilliseconds > 0) {
    NSTimeInterval settleSeconds = (NSTimeInterval)self.settleMilliseconds / 1000.0;
    self.timeoutTimer =
        [NSTimer scheduledTimerWithTimeInterval:settleSeconds + ZB_NAVIGATION_TIMEOUT_SECONDS
                                         target:self
                                       selector:@selector(onTimeout:)
                                       userInfo:nil
                                        repeats:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settleSeconds * (double)NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     if (self.done) {
                       return;
                     }
                     [self.timeoutTimer invalidate];
                     self.timeoutTimer = nil;
                     [self takeSnapshot];
                   });
    return;
  }

  self.timeoutTimer = nil;
  [self takeSnapshot];
}

- (void)takeSnapshot {
  WKWebView *webView = self.webView;
  WKSnapshotConfiguration *configuration = [[WKSnapshotConfiguration alloc] init];
  configuration.rect = webView.bounds;
  [webView takeSnapshotWithConfiguration:configuration
                       completionHandler:^(NSImage *_Nullable snapshotImage, NSError *_Nullable error) {
                         if (snapshotImage == nil || error != nil) {
                           self.exitCode = ZB_EXIT_SNAPSHOT_FAILED;
                           self.done = YES;
                           return;
                         }

                         CGImageRef cgImage = [snapshotImage CGImageForProposedRect:NULL context:nil hints:nil];
                         if (cgImage == NULL) {
                           self.exitCode = ZB_EXIT_SNAPSHOT_FAILED;
                           self.done = YES;
                           return;
                         }
                         NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
                         NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                         if (png == nil || ![png writeToFile:self.outPath atomically:YES]) {
                           self.exitCode = ZB_EXIT_WRITE_FAILED;
                         } else {
                           self.exitCode = ZB_EXIT_SUCCESS;
                         }
                         self.done = YES;
                       }];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  (void)webView;
  (void)navigation;
  (void)error;
  self.exitCode = ZB_EXIT_LOAD_FAILED;
  self.done = YES;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  (void)webView;
  (void)navigation;
  (void)error;
  self.exitCode = ZB_EXIT_LOAD_FAILED;
  self.done = YES;
}
@end

// --- MS2a: WKWebView routed-command port (zb_automation_* ABI, webkit_shim.h) ---
// The automation server calls these from its own (non-main) thread; each runs the WKWebView work on
// the main thread and BLOCKS the caller until done or timeout, via a dispatch_semaphore (the Cocoa
// analog of webkit_shim.c's g_cond bridge). Deadlock guard: a main-thread caller would
// dispatch_async+wait forever, so the main-thread guard answers ZB_AUTO_ERR_INTERNAL.

static ZBWindowHost *zb_auto_window_for_id(uint32_t win) {
  ZBAppHost *app = g_active_app;
  if (app == nil) return nil;
  if (win <= 1) return app.mainWindow;  // id 1 (and the 0 "primary" alias) is the main window
  if (app.windows != nil && (NSUInteger)(win - 1) < app.windows.count) return app.windows[win - 1];
  return nil;
}

void zb_automation_free(char *p) {
  free(p);
}

void zb_automation_set_script(const char *source, size_t len) {
  @autoreleasepool {
    zb_auto_script = (source != NULL && len > 0)
        ? [[NSString alloc] initWithBytes:source length:len encoding:NSUTF8StringEncoding]
        : nil;
  }
}

// Poll finishedOrFailed on the main thread (non-blocking) until the current load completes or the
// deadline; when it does, run onReady(host) on the main thread, then wake the caller. Deadlock
// guard: a main-thread caller would dispatch+wait on itself forever, so return ZB_AUTO_ERR_INTERNAL.
// Returns ZB_AUTO_OK (onReady ran), ZB_AUTO_ERR_NO_WINDOW, or ZB_AUTO_ERR_TIMEOUT.
static int zb_auto_await(uint32_t win, unsigned int timeout_ms, void (^onReady)(ZBWindowHost *host)) {
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  __block int rc = ZB_AUTO_ERR_TIMEOUT;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(double)timeout_ms / 1000.0];
  __block void (^poll)(void) = nil;
  poll = ^{
    ZBWindowHost *host = zb_auto_window_for_id(win);
    if (host == nil) {
      rc = ZB_AUTO_ERR_NO_WINDOW; poll = nil; dispatch_semaphore_signal(sem); return;
    }
    if (host.finishedOrFailed) {
      onReady(host); rc = ZB_AUTO_OK; poll = nil; dispatch_semaphore_signal(sem); return;
    }
    if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
      rc = ZB_AUTO_ERR_TIMEOUT; poll = nil; dispatch_semaphore_signal(sem); return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), poll);
  };
  dispatch_async(dispatch_get_main_queue(), poll);
  // Backstop longer than the poll deadline so the main-thread poll is the arbiter, never a hang.
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, ((int64_t)timeout_ms + 2000) * NSEC_PER_MSEC));
  return rc;
}

static int zb_auto_get_string(uint32_t win, unsigned int timeout_ms, char **out, BOOL want_title) {
  @autoreleasepool {
    __block char *result = NULL;
    int rc = zb_auto_await(win, timeout_ms, ^(ZBWindowHost *host) {
      NSString *value = want_title ? (host.webView.title ?: @"")
                                    : (host.webView.URL.absoluteString ?: @"");
      const char *utf8 = value.UTF8String;
      result = strdup(utf8 != NULL ? utf8 : "");
    });
    if (rc == ZB_AUTO_OK) {
      if (out != NULL) *out = result; else free(result);
    }
    return rc;
  }
}

int zb_automation_get_url(uint32_t win, unsigned int timeout_ms, char **out_url) {
  return zb_auto_get_string(win, timeout_ms, out_url, NO);
}

int zb_automation_get_title(uint32_t win, unsigned int timeout_ms, char **out_title) {
  return zb_auto_get_string(win, timeout_ms, out_title, YES);
}

int zb_automation_navigate_guarded(uint32_t win, const char *url, int before_unload,
                                   unsigned int timeout_ms, char **out_err) {
  // MS2a.1: FAIL policy only; the fixtures raise no beforeunload prompt (full policy is a later
  // refinement). A failed load sets finishedOrFailed AND requests app exit (lifecycle), so MS2a.1
  // navigates only to valid URLs; distinguishing nav failure without exiting is a later step.
  (void)before_unload;
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  @autoreleasepool {
    NSString *url_text = url != NULL ? [NSString stringWithUTF8String:url] : nil;
    NSURL *nsurl = url_text != nil ? [NSURL URLWithString:url_text] : nil;
    if (nsurl == nil) return ZB_AUTO_ERR_NAV_FAILED;
    __block BOOL started = NO;
    dispatch_semaphore_t kick = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBWindowHost *host = zb_auto_window_for_id(win);
      if (host != nil) {
        host.finishedOrFailed = NO;  // clear before the load so the await waits for THIS navigation
        [host.webView loadRequest:[NSURLRequest requestWithURL:nsurl]];
        started = YES;
      }
      dispatch_semaphore_signal(kick);
    });
    dispatch_semaphore_wait(kick, dispatch_time(DISPATCH_TIME_NOW, (int64_t)5 * NSEC_PER_SEC));
    if (!started) return ZB_AUTO_ERR_NO_WINDOW;
    return zb_auto_await(win, timeout_ms, ^(ZBWindowHost *host) { (void)host; });
  }
}

int zb_automation_navigate(uint32_t win, const char *url, unsigned int timeout_ms, char **out_err) {
  return zb_automation_navigate_guarded(win, url, ZB_BEFORE_UNLOAD_FAIL, timeout_ms, out_err);
}

int zb_automation_reload(uint32_t win, unsigned int timeout_ms, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  @autoreleasepool {
    __block BOOL started = NO;
    dispatch_semaphore_t kick = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBWindowHost *host = zb_auto_window_for_id(win);
      if (host != nil) {
        host.finishedOrFailed = NO;
        [host.webView reload];
        started = YES;
      }
      dispatch_semaphore_signal(kick);
    });
    dispatch_semaphore_wait(kick, dispatch_time(DISPATCH_TIME_NOW, (int64_t)5 * NSEC_PER_SEC));
    if (!started) return ZB_AUTO_ERR_NO_WINDOW;
    return zb_auto_await(win, timeout_ms, ^(ZBWindowHost *host) { (void)host; });
  }
}

// Serialize a callAsyncJavaScript result to the ABI string: an NSString verbatim (handle_body
// returns JSON.stringify(...), already a string), else the JSON encoding of the value ("null" for
// nil/undefined), per webkit_shim.h.
static char *zb_auto_result_string(id value) {
  NSString *s = nil;
  if ([value isKindOfClass:[NSString class]]) {
    s = (NSString *)value;
  } else if (value == nil || value == [NSNull null]) {
    s = @"null";
  } else {
    NSData *data = [NSJSONSerialization isValidJSONObject:value]
        ? [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]
        : nil;
    s = data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"null";
  }
  const char *utf8 = s.UTF8String;
  return strdup(utf8 != NULL ? utf8 : "null");
}

int zb_automation_eval_json(uint32_t win, const char *function_body, const char *arg_json,
                            const char *world, unsigned int timeout_ms, char **out_result,
                            char **out_err) {
  if (out_result != NULL) *out_result = NULL;
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;  // deadlock guard
  if (function_body == NULL) return ZB_AUTO_ERR_INTERNAL;
  @autoreleasepool {
    NSString *body = [NSString stringWithUTF8String:function_body];
    NSString *arg = [NSString stringWithUTF8String:(arg_json != NULL ? arg_json : "null")];
    // world == ZB_AUTOMATION_WORLD -> the named automation world (where __zbAutomation lives);
    // NULL/empty -> the page world.
    WKContentWorld *content_world = (world != NULL && world[0] != '\0')
        ? [WKContentWorld worldWithName:[NSString stringWithUTF8String:world]]
        : WKContentWorld.pageWorld;

    __block int rc = ZB_AUTO_ERR_TIMEOUT;
    __block char *result = NULL;
    __block char *errmsg = NULL;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(double)timeout_ms / 1000.0];
    __block void (^poll)(void) = nil;
    poll = ^{
      ZBWindowHost *host = zb_auto_window_for_id(win);
      if (host == nil) { rc = ZB_AUTO_ERR_NO_WINDOW; poll = nil; dispatch_semaphore_signal(sem); return; }
      if (!host.finishedOrFailed) {
        if ([[NSDate date] compare:deadline] != NSOrderedAscending) { rc = ZB_AUTO_ERR_TIMEOUT; poll = nil; dispatch_semaphore_signal(sem); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), poll);
        return;
      }
      poll = nil;  // ready: run the async eval; its completion handler signals.
      [host.webView callAsyncJavaScript:body
                              arguments:@{ @"arg": arg }
                                inFrame:nil
                         inContentWorld:content_world
                      completionHandler:^(id value, NSError *error) {
        if (error != nil) {
          rc = ZB_AUTO_ERR_JS;
          const char *m = error.localizedDescription.UTF8String;
          errmsg = strdup(m != NULL ? m : "evaluation failed");
        } else {
          result = zb_auto_result_string(value);
          rc = ZB_AUTO_OK;
        }
        dispatch_semaphore_signal(sem);
      }];
    };
    dispatch_async(dispatch_get_main_queue(), poll);
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, ((int64_t)timeout_ms + 2000) * NSEC_PER_MSEC));
    if (out_result != NULL) *out_result = result; else free(result);
    if (out_err != NULL) *out_err = errmsg; else free(errmsg);
    return rc;
  }
}

int zb_app_run(const char *uri, int print_title, int e2e_protocol) {
  @autoreleasepool {
    NSString *uri_text = string_from_c(uri);
    if (uri_text.length == 0) {
      return ZB_EXIT_INVALID_URI;
    }

    NSApplication *application = [NSApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyRegular];

    ZBAppHost *host = [[ZBAppHost alloc] initWithURI:uri_text
                                         printTitle:print_title != 0
                                        e2eProtocol:e2e_protocol != 0];
    if (host == nil) {
      return ZB_EXIT_WEBVIEW_INIT_FAILED;
    }
    application.delegate = host;

    ZbApp c_app;
    memset(&c_app, 0, sizeof(c_app));
    c_app.host = (__bridge void *)host;

    g_active_app = host;
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGHUP, handle_signal);

    ZbWindow *window = zb_window_new(&c_app, NULL);
    if (window == NULL) {
      g_active_app = nil;
      return ZB_EXIT_WEBVIEW_INIT_FAILED;
    }
    ZBWindowHost *window_host = (__bridge ZBWindowHost *)window->host;
    [window_host loadURI:uri_text];

    [application run];

    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    g_active_app = nil;
    application.delegate = nil;
    return host.exitCode;
  }
}

int zb_run_open(const char *uri, int print_title) {
  return zb_app_run(uri, print_title, 0);
}

int zb_run_screenshot(const char *uri, const char *out_path, int print_title) {
  @autoreleasepool {
    NSString *uri_text = string_from_c(uri);
    NSString *out_text = string_from_c(out_path);
    if (uri_text.length == 0 || out_text.length == 0) {
      return ZB_EXIT_USAGE;
    }
    [NSApplication sharedApplication];
    ZBSnapshotRunner *runner = [[ZBSnapshotRunner alloc] initWithURI:uri_text
                                                             outPath:out_text
                                                          printTitle:print_title != 0];
    return [runner run];
  }
}

void zb_version_line(char *buf, size_t len) {
  if (buf == NULL || len == 0) {
    return;
  }

  @autoreleasepool {
    NSBundle *bundle = [NSBundle bundleWithIdentifier:@"com.apple.WebKit"];
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (version.length == 0) {
      version = [bundle objectForInfoDictionaryKey:@"CFBundleVersion"];
    }
    if (version.length == 0) {
      version = @"unknown";
    }
    snprintf(buf, len, "zigBrowser %s (WKWebView %s)", version.UTF8String, version.UTF8String);
    buf[len - 1] = '\0';
  }
}

void zb_reload(ZbWindow *win, int bypass_cache) {
  if (win == NULL || win->host == NULL) {
    return;
  }
  ZBWindowHost *host = (__bridge ZBWindowHost *)win->host;
  [host reloadBypassingCache:bypass_cache != 0];
}

ZbWindow *zb_window_new(ZbApp *app, void *native_view) {
  if (app == NULL || app->host == NULL) {
    return NULL;
  }
  ZBAppHost *host = (__bridge ZBAppHost *)app->host;
  WKWebView *webView = native_view != NULL ? (__bridge WKWebView *)native_view : nil;
  ZBWindowHost *window = [host createWindowWithWebView:webView child:host.windows.count > 0 uri:nil];
  return window != nil ? window.cWindow : NULL;
}
