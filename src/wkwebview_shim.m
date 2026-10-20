#include "webkit_shim.h"

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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
// Associated-object tag marking a WKNavigation that a routed (automation) navigation started. A load
// failure is suppressed (no app-exit) ONLY for a tagged navigation — scoped by navigation IDENTITY,
// so a superseded routed nav's late failure is swallowed while an unrelated user/page-initiated
// navigation failure in the same window still exits (RoseCat 6227.2 #4, identity not a per-window bit).
// The tag lives on the WKNavigation and is freed with it (no set to prune, no leak).
static const void *const kZBRoutedNavKey = &kZBRoutedNavKey;
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
// Routed (automation) navigation tracking. routedNav is the in-flight WKNavigation a routed
// page.navigate/reload started; routedOutcome is 0 pending / 1 success / 2 failure for THAT
// navigation (identity-matched, so a stale completion from an older navigation cannot satisfy a new
// wait — RoseCat 6227.2). While routedNav is set, a load failure for it reports navigation_failed and
// must NOT exit the app (unlike a user-initiated load failure).
@property(nonatomic, strong) WKNavigation *routedNav;
@property(nonatomic, assign) int routedOutcome;
// The latest navigation this window STARTED (set in didStartProvisionalNavigation). A finish/failure
// callback for anything other than currentNav is STALE (a superseded navigation) and must not touch
// finishedOrFailed, the timeout timer, or the outcome — otherwise a late stale callback corrupts the
// navigation now in flight (RoseCat 33b0827: identity-check BEFORE mutating current state).
@property(nonatomic, strong) WKNavigation *currentNav;
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
  self.currentNav = [self.webView loadRequest:[NSURLRequest requestWithURL:url]];  // pin synchronously
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
  self.currentNav = bypassCache ? [self.webView reloadFromOrigin] : [self.webView reload];  // pin synchronously
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

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
  (void)webView;
  self.currentNav = navigation;  // the latest-started navigation is the current one
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  if (navigation != nil && navigation != self.currentNav) {
    return;  // stale: a superseded navigation's late finish must not touch the current state
  }
  self.finishedOrFailed = YES;
  if (navigation != nil && navigation == self.routedNav) {
    self.routedOutcome = 1;  // success for THIS routed navigation
  }
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
  [self handleLoadFailureForWebView:webView navigation:navigation error:error];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
  [self handleLoadFailureForWebView:webView navigation:navigation error:error];
}

- (void)handleLoadFailureForWebView:(WKWebView *)webView navigation:(WKNavigation *)navigation error:(NSError *)error {
  if (navigation != nil && navigation != self.currentNav) {
    return;  // stale: a superseded navigation's late failure must not touch the current state/timer/exit
  }
  if (self.finishedOrFailed && error.code == NSURLErrorCancelled) {
    return;
  }
  self.finishedOrFailed = YES;
  [self.timeoutTimer invalidate];
  self.timeoutTimer = nil;
  // A routed (automation) navigation that fails is reported to the caller as navigation_failed and
  // must NOT bring the whole browser down — the session stays usable on its previous document
  // (RoseCat 6227.2). Only a user-initiated load failure exits.
  // Scoped by navigation identity: a tagged (routed) navigation never exits the browser. The CURRENT
  // routed navigation reports navigation_failed; a superseded routed navigation's late failure is
  // swallowed. An untagged navigation (user/page-initiated/initial load) falls through to the exit path.
  if (navigation != nil && objc_getAssociatedObject(navigation, kZBRoutedNavKey) != nil) {
    if (navigation == self.routedNav) {
      self.routedOutcome = 2;
    }
    return;
  }
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

// --- Bridge job ownership: PENDING -> PREFLIGHT -> DISPATCHING -> INFLIGHT -> DONE (RoseCat 6287) ----
// Each ABI call that runs WKWebView work on the main thread owns a heap job. The phases linearize every
// SUBMITTED side effect before the ABI returns, so a concurrent timeout can never (a) dispatch after
// abandonment, (b) skip a submission mid-flight, (c) write freed memory, or (d) report success to a
// retired op:
//   PENDING      queued on the main queue; nothing has run.
//   PREFLIGHT    optional async readiness/guard work (e.g. the finishedOrFailed poll). At the deadline
//                the waiter may CANCEL it; a preflight step that sees that does nothing.
//   DISPATCHING  claimed for submission (PENDING/PREFLIGHT -> DISPATCHING under the lock). While
//                DISPATCHING the waiter MUST wait, even past its deadline, so the Cocoa/WebKit
//                submission that follows cannot be skipped by a concurrent timeout.
//   INFLIGHT     the submission happened; an async completion is pending. At the deadline the waiter
//                may ABANDON (the completion is then discarded).
//   DONE         completed; the outcome lives in the heap job (never the caller stack).
// A pthread mutex+cond (not a dispatch_semaphore) carries the wait: dispatch objects are ARC-managed
// under -fobjc-arc and freeing a malloc-backed strong field is UB (RoseCat 6301); pthread primitives
// are plain C, destroyed explicitly before free.
enum {
  ZB_JOB_PENDING = 0,
  ZB_JOB_PREFLIGHT,
  ZB_JOB_DISPATCHING,
  ZB_JOB_INFLIGHT,
  ZB_JOB_DONE,
  ZB_JOB_CANCELLED,
  ZB_JOB_ABANDONED,
};

typedef struct ZBAutoJob {
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int state;     // guarded by mu
  int refcount;  // guarded by mu
  int code;      // valid once state == DONE
  char *result;  // owned; moved out by the waiter on DONE
  char *err;     // owned; freed with the job
} ZBAutoJob;

static atomic_int zb_auto_live_jobs = 0;
static atomic_uint zb_auto_waiter_grace_ms = 0;  // test hook: waiter wakes late so a late completion wins

int zb_automation_debug_live_jobs(void) { return atomic_load(&zb_auto_live_jobs); }
void zb_automation_debug_waiter_grace(unsigned int ms) { atomic_store(&zb_auto_waiter_grace_ms, ms); }

// Test-only, inert unless ZB_DEBUG_DISPATCH_HOLD_MS is set (an e2e test can set it at launch; the C
// debug ABI is not reachable over the automation socket). When set, a DISPATCHING claim pauses on the
// main thread for that long, between zb_job_claim_dispatch and the WebKit submission, so a red can
// expire the waiter exactly in that window and prove the ABI still cannot return until the submission
// linearizes (RoseCat 6298 race red). No-op in normal runs (one getenv while unset).
// All ZB_DEBUG_* test hooks below are honored ONLY under --e2e-protocol (the app's e2e/dev flag), so an
// ambient environment variable alone cannot change production behavior (RoseCat: hooks must be inert
// without the e2e flag). Read on the main thread, where g_active_app is stable.
static int zb_auto_test_hooks_enabled(void) {
  return g_active_app != nil && g_active_app.e2eProtocol;
}

static void zb_auto_test_dispatch_hold(void) {
  if (!zb_auto_test_hooks_enabled()) return;
  const char *h = getenv("ZB_DEBUG_DISPATCH_HOLD_MS");
  if (h == NULL) return;
  long ms = strtol(h, NULL, 10);
  if (ms <= 0) return;
  if (ms > 60000) ms = 60000;  // clamp: bound the test hold so (ms * 1000) us cannot overflow
  usleep((useconds_t)(ms * 1000));
}

// Test-only (ZB_DEBUG_REFUSE_NEXT_NAV): one-shot — the next routed navigation's start is treated as
// refused (as if loadRequest returned nil), so a red can exercise the refused-start branch (RoseCat
// 38d121a #3: a refused start must leave the old document settled and not suppress later failures).
static int zb_auto_test_refuse_next_nav(void) {
  if (!zb_auto_test_hooks_enabled()) return 0;
  static atomic_int consumed = 0;
  if (atomic_load(&consumed)) return 0;
  const char *v = getenv("ZB_DEBUG_REFUSE_NEXT_NAV");
  if (v == NULL || v[0] == '0' || v[0] == '\0') return 0;
  return atomic_exchange(&consumed, 1) == 0;  // one-shot: true exactly once
}

// Test-only (ZB_DEBUG_ACK_FAIL): the native-click FIFO ack eval throws, so its completion returns an
// error, letting a red prove an ack error maps to a failure and not OK (RoseCat 6253.3).
static int zb_auto_test_ack_fail(void) {
  if (!zb_auto_test_hooks_enabled()) return 0;
  const char *v = getenv("ZB_DEBUG_ACK_FAIL");
  return v != NULL && v[0] != '0' && v[0] != '\0';
}

// Test-only (ZB_DEBUG_SYNTH_STALE = "finish"|"fail"): one-shot — on the first routed navigation that
// SUPERSEDES a previous one, synthesize a stale delegate callback (didFinish / didFailProvisional) for
// the OLD navigation, in the submit->didStart window of the new one. The currentNav identity guard must
// ignore it (RoseCat 6358 stale-callback reds). 0 = off, 1 = finish, 2 = fail.
static int zb_auto_test_synth_stale(void) {
  if (!zb_auto_test_hooks_enabled()) return 0;
  static atomic_int consumed = 0;
  const char *v = getenv("ZB_DEBUG_SYNTH_STALE");
  if (v == NULL || v[0] == '\0') return 0;
  int mode = (strcmp(v, "fail") == 0) ? 2 : (strcmp(v, "finish") == 0 ? 1 : 0);
  if (mode == 0) return 0;
  if (atomic_exchange(&consumed, 1) != 0) return 0;  // one-shot
  return mode;
}

// Test-only (ZB_DEBUG_STALE_TOKEN): the native-click documentToken guard reads a fabricated stale token
// (a real mismatch) WITHOUT reloading the page, so locate still succeeds and only the guard sees a
// changed document — the production DOC_CHANGED path with no engine-reload masking (RoseCat option b).
static int zb_auto_test_stale_token(void) {
  if (!zb_auto_test_hooks_enabled()) return 0;
  const char *v = getenv("ZB_DEBUG_STALE_TOKEN");
  if (v == NULL || v[0] == '0' || v[0] == '\0') return 0;
  static atomic_int reads = 0;
  int n = atomic_fetch_add(&reads, 1) + 1;  // 1-based index of this documentToken read
  // "after:N" -> stale only after N reads, so the PREFLIGHT guard passes and a later per-character
  // RECHECK fails (isolates the per-char recheck, 6361.1). Any other truthy value -> always stale.
  if (strncmp(v, "after:", 6) == 0) return n > atoi(v + 6);
  return 1;
}

static ZBAutoJob *zb_job_new(void) {
  ZBAutoJob *job = calloc(1, sizeof(ZBAutoJob));
  if (job == NULL) return NULL;  // callers map NULL -> ZB_AUTO_ERR_INTERNAL
  pthread_mutex_init(&job->mu, NULL);
  pthread_cond_init(&job->cv, NULL);
  job->state = ZB_JOB_PENDING;
  job->refcount = 1;
  job->code = ZB_AUTO_ERR_TIMEOUT;
  atomic_fetch_add(&zb_auto_live_jobs, 1);
  return job;
}

static void zb_job_ref(ZBAutoJob *job) {
  pthread_mutex_lock(&job->mu);
  job->refcount++;
  pthread_mutex_unlock(&job->mu);
}

static void zb_job_unref(ZBAutoJob *job) {
  if (job == NULL) return;
  pthread_mutex_lock(&job->mu);
  int rc = --job->refcount;
  pthread_mutex_unlock(&job->mu);
  if (rc != 0) return;
  // refcount 0: no waiter or callback can still reference the job. Destroy the primitives, then free.
  pthread_cond_destroy(&job->cv);
  pthread_mutex_destroy(&job->mu);
  free(job->result);
  free(job->err);
  free(job);
  atomic_fetch_sub(&zb_auto_live_jobs, 1);
}

// First main-thread run: PENDING -> PREFLIGHT. Returns 0 if the waiter already cancelled (do nothing).
static int zb_job_enter_preflight(ZBAutoJob *job) {
  pthread_mutex_lock(&job->mu);
  int ok = (job->state == ZB_JOB_PENDING);
  if (ok) job->state = ZB_JOB_PREFLIGHT;
  pthread_mutex_unlock(&job->mu);
  return ok;
}

// A preflight step still owned by the waiter? False once the waiter cancelled/abandoned it.
static int zb_job_in_preflight(ZBAutoJob *job) {
  pthread_mutex_lock(&job->mu);
  int ok = (job->state == ZB_JOB_PREFLIGHT);
  pthread_mutex_unlock(&job->mu);
  return ok;
}

// Still INFLIGHT (not yet DONE and not ABANDONED by a timed-out waiter)? A multi-step async side effect
// (e.g. per-character typing) checks this before each further step, so it stops delivering once the
// caller has abandoned.
static int zb_job_is_inflight(ZBAutoJob *job) {
  pthread_mutex_lock(&job->mu);
  int ok = (job->state == ZB_JOB_INFLIGHT);
  pthread_mutex_unlock(&job->mu);
  return ok;
}

// Claim the job for submission: PENDING/PREFLIGHT -> DISPATCHING. Returns 0 if the waiter abandoned.
// The caller MUST then either submit and call zb_job_inflight()/zb_job_complete(), so the waiter that
// is forced to wait during DISPATCHING is released.
static int zb_job_claim_dispatch(ZBAutoJob *job) {
  pthread_mutex_lock(&job->mu);
  int ok = (job->state == ZB_JOB_PENDING || job->state == ZB_JOB_PREFLIGHT);
  if (ok) job->state = ZB_JOB_DISPATCHING;
  pthread_mutex_unlock(&job->mu);
  return ok;
}

// Submission returned (the Cocoa/WebKit call was issued): DISPATCHING -> INFLIGHT; release the waiter.
static void zb_job_inflight(ZBAutoJob *job) {
  pthread_mutex_lock(&job->mu);
  if (job->state == ZB_JOB_DISPATCHING) job->state = ZB_JOB_INFLIGHT;
  pthread_cond_broadcast(&job->cv);
  pthread_mutex_unlock(&job->mu);
}

// Record the outcome once, only while the job is still owned (DISPATCHING or INFLIGHT), and wake the
// waiter. Takes ownership of result/err and frees them if the waiter already abandoned, so a late
// completion neither writes freed memory nor reports success to a retired op.
static void zb_job_complete(ZBAutoJob *job, int code, char *result, char *err) {
  pthread_mutex_lock(&job->mu);
  int recorded = (job->state == ZB_JOB_DISPATCHING || job->state == ZB_JOB_INFLIGHT);
  if (recorded) {
    job->code = code;
    job->result = result;
    job->err = err;
    job->state = ZB_JOB_DONE;
    pthread_cond_broadcast(&job->cv);
  }
  pthread_mutex_unlock(&job->mu);
  if (!recorded) {
    free(result);
    free(err);
  }
}

static void zb_abs_deadline(struct timespec *ts, unsigned int ms) {
  clock_gettime(CLOCK_REALTIME, ts);  // pthread_cond_timedwait uses CLOCK_REALTIME by default
  ts->tv_sec += (time_t)(ms / 1000);
  ts->tv_nsec += (long)(ms % 1000) * 1000000L;
  if (ts->tv_nsec >= 1000000000L) {
    ts->tv_sec += 1;
    ts->tv_nsec -= 1000000000L;
  }
}

// Waiter (calling thread). Waits for DONE until the deadline. While DISPATCHING it waits WITHOUT a
// deadline (the submission is linearizing and must complete first). On a real timeout it moves the job
// to CANCELLED (never submitted) or ABANDONED (INFLIGHT). Returns the job code; on DONE the caller then
// reads/moves job->result as the sole reader.
static int zb_job_wait(ZBAutoJob *job, unsigned int timeout_ms) {
  struct timespec deadline;
  zb_abs_deadline(&deadline, timeout_ms);
  int graced = 0;
  pthread_mutex_lock(&job->mu);
  for (;;) {
    if (job->state == ZB_JOB_DONE) break;
    if (job->state == ZB_JOB_DISPATCHING) {
      pthread_cond_wait(&job->cv, &job->mu);  // submission in progress: wait past the deadline
      continue;
    }
    int rc = pthread_cond_timedwait(&job->cv, &job->mu, &deadline);
    if (job->state == ZB_JOB_DONE || job->state == ZB_JOB_DISPATCHING) continue;
    if (rc == ETIMEDOUT) {
      unsigned int grace = atomic_load(&zb_auto_waiter_grace_ms);
      if (grace > 0 && !graced && job->state == ZB_JOB_INFLIGHT) {
        // Test hook: wake late so an in-flight completion can win the race before we abandon.
        graced = 1;
        zb_abs_deadline(&deadline, grace);
        continue;
      }
      job->state = (job->state == ZB_JOB_PENDING || job->state == ZB_JOB_PREFLIGHT)
                       ? ZB_JOB_CANCELLED
                       : ZB_JOB_ABANDONED;
      break;
    }
    // spurious wakeup with the job not yet terminal: loop (the absolute deadline still bounds us).
  }
  int code = (job->state == ZB_JOB_DONE) ? job->code : ZB_AUTO_ERR_TIMEOUT;
  pthread_mutex_unlock(&job->mu);
  return code;
}

// Run `work(host, &result)` on the main thread once the window's current load has settled
// (finishedOrFailed), bounded by timeout_ms, under job ownership. `work` is a SYNCHRONOUS read: the job
// goes PENDING -> PREFLIGHT (the readiness poll) -> DISPATCHING -> DONE in one main-thread step, so a
// concurrent timeout either cancels the preflight (work never runs) or the waiter abandons before the
// result is read — never a write to the caller's stack after it returned (RoseCat 6227.1, zb_auto_await).
static int zb_auto_run_when_ready(uint32_t win, unsigned int timeout_ms, char **out_result,
                                  int (^work)(ZBWindowHost *host, char **out)) {
  if (out_result != NULL) *out_result = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  ZBAutoJob *job = zb_job_new();
  if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(double)timeout_ms / 1000.0];
  zb_job_ref(job);
  __block BOOL entered = NO;
  __block void (^poll)(void) = nil;
  poll = ^{
    if (!entered) {
      entered = YES;
      if (!zb_job_enter_preflight(job)) { poll = nil; zb_job_unref(job); return; }
    } else if (!zb_job_in_preflight(job)) {
      poll = nil; zb_job_unref(job); return;
    }
    ZBWindowHost *host = zb_auto_window_for_id(win);
    if (host == nil) {
      poll = nil;
      if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL);
      zb_job_unref(job);
      return;
    }
    if (!host.finishedOrFailed) {
      if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
        poll = nil;
        if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_TIMEOUT, NULL, NULL);
        zb_job_unref(job);
        return;
      }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), poll);
      return;
    }
    poll = nil;
    if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }  // waiter abandoned: do not read
    char *result = NULL;
    int code = work(host, &result);
    zb_job_complete(job, code, result, NULL);  // synchronous: DISPATCHING -> DONE
    zb_job_unref(job);
  };
  dispatch_async(dispatch_get_main_queue(), poll);
  int rc = zb_job_wait(job, timeout_ms);
  if (rc == ZB_AUTO_OK && out_result != NULL) {
    *out_result = job->result;
    job->result = NULL;
  }
  zb_job_unref(job);
  return rc;
}

static int zb_auto_get_string(uint32_t win, unsigned int timeout_ms, char **out, BOOL want_title) {
  @autoreleasepool {
    return zb_auto_run_when_ready(win, timeout_ms, out, ^int(ZBWindowHost *host, char **result) {
      NSString *value = want_title ? (host.webView.title ?: @"")
                                    : (host.webView.URL.absoluteString ?: @"");
      const char *utf8 = value.UTF8String;
      *result = strdup(utf8 != NULL ? utf8 : "");
      return ZB_AUTO_OK;
    });
  }
}

int zb_automation_get_url(uint32_t win, unsigned int timeout_ms, char **out_url) {
  return zb_auto_get_string(win, timeout_ms, out_url, NO);
}

int zb_automation_get_title(uint32_t win, unsigned int timeout_ms, char **out_title) {
  return zb_auto_get_string(win, timeout_ms, out_title, YES);
}

// Start a routed navigation on the main thread and wait for ITS outcome. `start(host)` performs the
// loadRequest/reload and returns the WKNavigation it created (nil = refused). Phase model: PENDING ->
// DISPATCHING (claim + submit) -> INFLIGHT (poll the per-navigation outcome) -> DONE. The submission
// linearizes before the ABI returns, so a blocked main queue cannot dispatch the load after the caller
// timed out. A load failure for THIS navigation returns navigation_failed and does NOT exit the browser
// (RoseCat 6227.1/6227.2); the outcome is matched by WKNavigation identity so a stale completion from an
// older navigation cannot satisfy this wait.
static int zb_auto_routed_nav(uint32_t win, unsigned int timeout_ms, WKNavigation *(^start)(ZBWindowHost *host)) {
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  ZBAutoJob *job = zb_job_new();
  if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(double)timeout_ms / 1000.0];
  zb_job_ref(job);
  __block BOOL started = NO;
  __block void (^poll)(void) = nil;
  poll = ^{
    ZBWindowHost *host = zb_auto_window_for_id(win);
    if (!started) {
      if (!zb_job_claim_dispatch(job)) { poll = nil; zb_job_unref(job); return; }  // waiter cancelled first
      if (host == nil) { poll = nil; zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
      // Submit FIRST; only on a real (non-nil) navigation do we invalidate the watchdog and clear the
      // settled state. A refused start leaves the old document settled, so a later url/title/eval does
      // not wait to timeout (RoseCat 6227.2 #3).
      WKNavigation *oldNav = host.currentNav;  // the superseded navigation (for the stale-callback red)
      WKNavigation *nav = zb_auto_test_refuse_next_nav() ? nil : start(host);
      if (nav == nil) { poll = nil; zb_job_complete(job, ZB_AUTO_ERR_NAV_FAILED, NULL, NULL); zb_job_unref(job); return; }
      objc_setAssociatedObject(nav, kZBRoutedNavKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);  // identity tag
      // A refused start never reaches here, so it never suppresses a later user-navigation failure.
      [host.timeoutTimer invalidate];
      host.timeoutTimer = nil;  // no user-load watchdog on a routed nav -> never self-exits
      host.finishedOrFailed = NO;
      host.routedOutcome = 0;
      host.routedNav = nav;
      host.currentNav = nav;  // pin SYNCHRONOUSLY with the submit: before WebKit delivers this nav's
                              // didStart, an old-nav callback must already fail the identity guard
                              // (closes the submit->didStart stale-callback race, RoseCat 6348)
      // Test hook: now that currentNav is the new nav, synthesize a STALE callback for the superseded
      // navigation in this exact window; the identity guard must ignore it (no spurious NAV row / no
      // state mutation / no exit). Inert without --e2e-protocol.
      int synth = (oldNav != nil) ? zb_auto_test_synth_stale() : 0;
      if (synth == 1) {
        [host webView:host.webView didFinishNavigation:oldNav];
      } else if (synth == 2) {
        [host webView:host.webView didFailProvisionalNavigation:oldNav
                                                        withError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];
      }
      started = YES;
      zb_job_inflight(job);  // submission issued: DISPATCHING -> INFLIGHT, release the waiter
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), poll);
      return;
    }
    if (host == nil) { poll = nil; zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
    if (host.routedOutcome == 1) { poll = nil; zb_job_complete(job, ZB_AUTO_OK, NULL, NULL); zb_job_unref(job); return; }
    if (host.routedOutcome == 2) { poll = nil; zb_job_complete(job, ZB_AUTO_ERR_NAV_FAILED, NULL, NULL); zb_job_unref(job); return; }
    if ([[NSDate date] compare:deadline] != NSOrderedAscending) { poll = nil; zb_job_complete(job, ZB_AUTO_ERR_TIMEOUT, NULL, NULL); zb_job_unref(job); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), poll);
  };
  dispatch_async(dispatch_get_main_queue(), poll);
  int rc = zb_job_wait(job, timeout_ms);
  zb_job_unref(job);
  return rc;
}

int zb_automation_navigate_guarded(uint32_t win, const char *url, int before_unload,
                                   unsigned int timeout_ms, char **out_err) {
  // before_unload (accept/dismiss/fail) governs how a beforeunload PROMPT is answered. WKWebView does
  // not surface beforeunload prompts without a dialog (WKUIDelegate) handler; that handler — and the
  // enforcement of this policy through it — lands with the dialog slice (MS2b.2). FAIL (the engine
  // default) is the no-prompt path and is exact here; accept/dismiss become distinguishable only once
  // the dialog handler exists. A documented split of the contract (RoseCat 6227.3), not a silent
  // conflation: a routed navigate that would raise a beforeunload prompt is not yet exercised.
  (void)before_unload;
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  @autoreleasepool {
    NSString *url_text = url != NULL ? [NSString stringWithUTF8String:url] : nil;
    NSURL *nsurl = url_text != nil ? [NSURL URLWithString:url_text] : nil;
    if (nsurl == nil) return ZB_AUTO_ERR_NAV_FAILED;
    return zb_auto_routed_nav(win, timeout_ms, ^WKNavigation *(ZBWindowHost *host) {
      return [host.webView loadRequest:[NSURLRequest requestWithURL:nsurl]];
    });
  }
}

int zb_automation_navigate(uint32_t win, const char *url, unsigned int timeout_ms, char **out_err) {
  return zb_automation_navigate_guarded(win, url, ZB_BEFORE_UNLOAD_FAIL, timeout_ms, out_err);
}

int zb_automation_reload(uint32_t win, unsigned int timeout_ms, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  @autoreleasepool {
    return zb_auto_routed_nav(win, timeout_ms, ^WKNavigation *(ZBWindowHost *host) {
      return [host.webView reload];
    });
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
    // NULL/empty -> the page world. +[WKContentWorld worldWithName:] is a WebKit call: the FIRST one
    // runs InitializeWebKit2() under a call_once, which TRAPS (EXC_BREAKPOINT) off the main thread.
    // So it is resolved INSIDE the main-queue block below (after readiness), never on this calling
    // thread — otherwise it races the main thread's startup webView creation and can win the init.
    NSString *world_name = (world != NULL && world[0] != '\0') ? [NSString stringWithUTF8String:world] : nil;

    ZBAutoJob *job = zb_job_new();
    if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(double)timeout_ms / 1000.0];
    zb_job_ref(job);  // one ref for the whole main-queue work chain (released at its single terminal)
    __block BOOL entered = NO;
    __block void (^poll)(void) = nil;
    poll = ^{
      // First main-thread run: PENDING->PREFLIGHT. If the waiter already cancelled (e.g. a blocked main
      // queue let its deadline pass first), do nothing. Re-dispatches re-check we are still in PREFLIGHT.
      if (!entered) {
        entered = YES;
        if (!zb_job_enter_preflight(job)) { poll = nil; zb_job_unref(job); return; }
      } else if (!zb_job_in_preflight(job)) {
        poll = nil; zb_job_unref(job); return;  // waiter cancelled mid-poll: stop (poll=nil breaks the byref cycle)
      }
      ZBWindowHost *host = zb_auto_window_for_id(win);
      if (host == nil) {
        poll = nil;
        if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL);
        zb_job_unref(job);
        return;
      }
      if (!host.finishedOrFailed) {
        if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
          poll = nil;
          if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_TIMEOUT, NULL, NULL);
          zb_job_unref(job);
          return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), poll);
        return;
      }
      poll = nil;  // ready: claim for submission (PREFLIGHT->DISPATCHING), then run the async eval.
      if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }  // waiter abandoned: no submission
      zb_auto_test_dispatch_hold();  // test-only wedge: prove the waiter cannot return while DISPATCHING
      // Resolve the content world on the main thread (first worldWithName can init WebKit2).
      WKContentWorld *content_world = world_name != nil
          ? [WKContentWorld worldWithName:world_name]
          : WKContentWorld.pageWorld;
      [host.webView callAsyncJavaScript:body
                              arguments:@{ @"arg": arg }
                                inFrame:nil
                         inContentWorld:content_world
                      completionHandler:^(id value, NSError *error) {
        if (error != nil) {
          const char *m = error.localizedDescription.UTF8String;
          zb_job_complete(job, ZB_AUTO_ERR_JS, NULL, strdup(m != NULL ? m : "evaluation failed"));
        } else {
          zb_job_complete(job, ZB_AUTO_OK, zb_auto_result_string(value), NULL);
        }
        zb_job_unref(job);
      }];
      zb_job_inflight(job);  // submission issued on the main thread: DISPATCHING -> INFLIGHT, release waiter
    };
    // Dispatch `poll` DIRECTLY (not wrapped): dispatch_async Block_copies it now, retaining the
    // captured body/arg/world_name for the whole re-dispatch chain. A wrapper that merely calls poll()
    // would leave poll an un-copied stack block whose captures are lost on the first re-dispatch.
    dispatch_async(dispatch_get_main_queue(), poll);
    int rc = zb_job_wait(job, timeout_ms);
    if (rc == ZB_AUTO_OK || rc == ZB_AUTO_ERR_JS) {
      if (out_result != NULL) { *out_result = job->result; job->result = NULL; }
      if (out_err != NULL) { *out_err = job->err; job->err = NULL; }
    }
    zb_job_unref(job);  // the caller's ref
    return rc;
  }
}

// MS2b native click. Synthesize a TRUSTED NSEvent mouse down/up at the element's viewport CSS px
// (x, y) and deliver it in-process through -[NSWindow sendEvent:] (the spike proved event.isTrusted
// on both arches, scratchpad/ms2/spike_nsclick.m) — NO system CGEventPost, NO TCC, NO private API.
// Coordinates: the engine passes viewport CSS px (origin top-left, y down); an unflipped NSView has
// its origin bottom-left, so y is flipped to the view's space (isFlipped views need no flip) before
// convertPoint:toView:nil.
//
// Phase model (RoseCat 6287): PREFLIGHT runs the readiness poll and, when expected_doc is given, the
// documentToken guard (an automation-world eval mirroring webkit_shim.c:3745) — a mismatch returns
// DOC_CHANGED and delivers NOTHING (6253.2). DISPATCHING delivers the sendEvent; INFLIGHT is the
// FIFO-ordered ack eval (issued AFTER mouse-up, so the web process processes it only after the click
// dispatched on the single UI->web IPC connection). The ack's evaluateJavaScript ERROR maps to a
// failure, never OK (6253.3): a terminated/unresponsive web process cannot acknowledge a click.
// `button` is left-only for now (right/middle land with the matrix).
int zb_native_click(uint32_t win, double x, double y, int button,
                    const char *expected_doc, unsigned int timeout_ms, char **out_err) {
  (void)button;
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;  // deadlock guard
  @autoreleasepool {
    NSString *expected = expected_doc != NULL ? [NSString stringWithUTF8String:expected_doc] : nil;
    ZBAutoJob *job = zb_job_new();
    if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(double)timeout_ms / 1000.0];
    zb_job_ref(job);
    __block BOOL entered = NO;
    // DISPATCHING + INFLIGHT: claim, synthesize + deliver the click, then FIFO-ack. Declared first so
    // the (optional) doc-guard completion can invoke it. Holds no extra ref; the ack completion (or an
    // early failure branch) performs the single chain unref.
    __block void (^deliver)(ZBWindowHost *host) = nil;
    deliver = ^(ZBWindowHost *host) {
      if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }  // waiter abandoned: no sendEvent
      NSWindow *window = host.window;
      WKWebView *view = host.webView;
      if (window == nil || view == nil) { zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
      CGFloat hgt = view.bounds.size.height;
      NSPoint vp = view.isFlipped ? NSMakePoint(x, y) : NSMakePoint(x, hgt - y);
      NSPoint loc = [view convertPoint:vp toView:nil];
      NSInteger wn = window.windowNumber;
      NSTimeInterval tstamp = [[NSProcessInfo processInfo] systemUptime];
      NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:loc modifierFlags:0
                                        timestamp:tstamp windowNumber:wn context:nil eventNumber:0
                                       clickCount:1 pressure:1.0];
      NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:loc modifierFlags:0
                                      timestamp:tstamp windowNumber:wn context:nil eventNumber:0
                                     clickCount:1 pressure:0.0];
      [window sendEvent:down];
      [window sendEvent:up];
      NSString *ackJS = zb_auto_test_ack_fail() ? @"throw new Error('zb-test-ack-fail');" : @"0";
      [view evaluateJavaScript:ackJS completionHandler:^(id value, NSError *error) {
        (void)value;
        zb_job_complete(job, error != nil ? ZB_AUTO_ERR_JS : ZB_AUTO_OK, NULL, NULL);  // ack error -> failure
        zb_job_unref(job);
      }];
      zb_job_inflight(job);  // sendEvent + ack issued on the main thread: DISPATCHING -> INFLIGHT
    };
    __block void (^poll)(void) = nil;
    poll = ^{
      if (!entered) {
        entered = YES;
        if (!zb_job_enter_preflight(job)) { poll = nil; deliver = nil; zb_job_unref(job); return; }
      } else if (!zb_job_in_preflight(job)) {
        poll = nil; deliver = nil; zb_job_unref(job); return;
      }
      ZBWindowHost *host = zb_auto_window_for_id(win);
      if (host == nil) { poll = nil; deliver = nil; if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
      if (!host.finishedOrFailed) {
        if ([[NSDate date] compare:deadline] != NSOrderedAscending) { poll = nil; deliver = nil; if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_TIMEOUT, NULL, NULL); zb_job_unref(job); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), poll);
        return;
      }
      poll = nil;  // ready
      if (expected == nil) {
        void (^d)(ZBWindowHost *) = deliver; deliver = nil; d(host);  // no guard: deliver straight away
        return;
      }
      // Doc guard: read the current automation-world documentToken and compare to expected; still in
      // PREFLIGHT, so the waiter may cancel during this eval. Mirrors webkit_shim.c:3745.
      WKContentWorld *autoWorld = [WKContentWorld worldWithName:@ZB_AUTOMATION_WORLD];
      [host.webView callAsyncJavaScript:@"return globalThis.__zbAutomation ? globalThis.__zbAutomation.documentToken : null;"
                              arguments:@{}
                                inFrame:nil
                         inContentWorld:autoWorld
                      completionHandler:^(id value, NSError *error) {
        if (!zb_job_in_preflight(job)) { deliver = nil; zb_job_unref(job); return; }  // waiter cancelled
        if (error != nil) { deliver = nil; if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_JS, NULL, NULL); zb_job_unref(job); return; }
        NSString *token = [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
        if (zb_auto_test_stale_token()) token = @"zb-debug-stale-token";  // force a mismatch (no reload)
        if (token == nil || ![token isEqualToString:expected]) {
          deliver = nil;
          if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_DOC_CHANGED, NULL, NULL);
          zb_job_unref(job);
          return;
        }
        ZBWindowHost *h2 = zb_auto_window_for_id(win);
        if (h2 == nil) { deliver = nil; if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
        void (^d)(ZBWindowHost *) = deliver; deliver = nil; d(h2);
      }];
    };
    dispatch_async(dispatch_get_main_queue(), poll);
    int rc = zb_job_wait(job, timeout_ms);
    zb_job_unref(job);
    return rc;
  }
}

// MS2b.1b native key + text. zb_native_key / zb_native_text synthesize TRUSTED NSEvent key events
// (NSEventTypeKeyDown/Up) and deliver them in-process via -[NSWindow sendEvent:] — proven to produce
// isTrusted keydown + character insertion in a focused field (scratchpad/ms2/spike_nskey.m). They run
// on the same phase model + documentToken guard as nativeClick (shared driver zb_auto_native_input).

// DOM-key modifier bits (page_port: bit0 Shift, bit1 Control, bit2 Alt/Option, bit3 Meta/Command).
static NSEventModifierFlags zb_ns_mod_flags(int modifiers) {
  NSEventModifierFlags f = 0;
  if (modifiers & 0x01) f |= NSEventModifierFlagShift;
  if (modifiers & 0x02) f |= NSEventModifierFlagControl;
  if (modifiers & 0x04) f |= NSEventModifierFlagOption;
  if (modifiers & 0x08) f |= NSEventModifierFlagCommand;
  return f;
}

typedef enum { ZB_KEY_CHAR, ZB_KEY_NAMED, ZB_KEY_MODIFIER } ZBKeyKind;

// Map a DOM key name to how to synthesize it. CHAR: a printable code point (characters drive insertion
// and e.key; keyCode best-effort 0). NAMED: a key with its function-key/control unicode + US keyCode,
// sent as keyDown/keyUp. MODIFIER: Shift/Control/Alt/Meta, sent as flagsChanged (no keyDown). Covers the
// whole router.native_key_names set (RoseCat 6361.3). Returns NO for an unknown multi-char name.
static BOOL zb_dom_key_to_ns(NSString *name, ZBKeyKind *kind, unsigned short *kc, NSString **chars,
                             NSEventModifierFlags *modFlag) {
  static NSDictionary<NSString *, NSArray *> *named = nil;
  static NSDictionary<NSString *, NSArray *> *mods = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    named = @{
      @"Enter": @[@36, @"\r"], @"Tab": @[@48, @"\t"], @"Backspace": @[@51, @"\x08"],
      @"Escape": @[@53, @"\x1b"], @"Space": @[@49, @" "],
      @"Delete": @[@117, [NSString stringWithFormat:@"%C", (unichar)NSDeleteFunctionKey]],  // forward delete
      @"Insert": @[@114, [NSString stringWithFormat:@"%C", (unichar)NSInsertFunctionKey]],
      @"Home": @[@115, [NSString stringWithFormat:@"%C", (unichar)NSHomeFunctionKey]],
      @"End": @[@119, [NSString stringWithFormat:@"%C", (unichar)NSEndFunctionKey]],
      @"PageUp": @[@116, [NSString stringWithFormat:@"%C", (unichar)NSPageUpFunctionKey]],
      @"PageDown": @[@121, [NSString stringWithFormat:@"%C", (unichar)NSPageDownFunctionKey]],
      @"ArrowLeft": @[@123, [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey]],
      @"ArrowRight": @[@124, [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey]],
      @"ArrowDown": @[@125, [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey]],
      @"ArrowUp": @[@126, [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey]],
      @"F1": @[@122, [NSString stringWithFormat:@"%C", (unichar)NSF1FunctionKey]],
      @"F2": @[@120, [NSString stringWithFormat:@"%C", (unichar)NSF2FunctionKey]],
      @"F3": @[@99, [NSString stringWithFormat:@"%C", (unichar)NSF3FunctionKey]],
      @"F4": @[@118, [NSString stringWithFormat:@"%C", (unichar)NSF4FunctionKey]],
      @"F5": @[@96, [NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey]],
      @"F6": @[@97, [NSString stringWithFormat:@"%C", (unichar)NSF6FunctionKey]],
      @"F7": @[@98, [NSString stringWithFormat:@"%C", (unichar)NSF7FunctionKey]],
      @"F8": @[@100, [NSString stringWithFormat:@"%C", (unichar)NSF8FunctionKey]],
      @"F9": @[@101, [NSString stringWithFormat:@"%C", (unichar)NSF9FunctionKey]],
      @"F10": @[@109, [NSString stringWithFormat:@"%C", (unichar)NSF10FunctionKey]],
      @"F11": @[@103, [NSString stringWithFormat:@"%C", (unichar)NSF11FunctionKey]],
      @"F12": @[@111, [NSString stringWithFormat:@"%C", (unichar)NSF12FunctionKey]],
    };
    mods = @{
      @"Shift": @[@56, @(NSEventModifierFlagShift)], @"Control": @[@59, @(NSEventModifierFlagControl)],
      @"Alt": @[@58, @(NSEventModifierFlagOption)], @"Meta": @[@55, @(NSEventModifierFlagCommand)],
    };
  });
  NSArray *m = mods[name];
  if (m != nil) { *kind = ZB_KEY_MODIFIER; *kc = (unsigned short)[m[0] intValue]; *chars = @""; *modFlag = (NSEventModifierFlags)[m[1] unsignedLongLongValue]; return YES; }
  NSArray *e = named[name];
  if (e != nil) { *kind = ZB_KEY_NAMED; *kc = (unsigned short)[e[0] intValue]; *chars = e[1]; *modFlag = 0; return YES; }
  // A single Unicode code point (1 BMP unit, or a surrogate pair) is a printable key.
  if (name.length == 1 || (name.length == 2 && CFStringIsSurrogateHighCharacter([name characterAtIndex:0]))) {
    *kind = ZB_KEY_CHAR; *kc = 0; *chars = name; *modFlag = 0; return YES;
  }
  return NO;
}

// Append the NSEvent(s) for one key to `out`: keyDown+keyUp for a char/named key (distinct timestamps),
// or flagsChanged press+release for a modifier-only key. `flags` are extra held modifiers.
static void zb_build_key_events(NSWindow *window, ZBKeyKind kind, unsigned short kc, NSString *chars,
                                NSEventModifierFlags modFlag, NSEventModifierFlags flags,
                                NSMutableArray<NSEvent *> *out) {
  NSInteger wn = window.windowNumber;
  NSTimeInterval ts = [[NSProcessInfo processInfo] systemUptime];
  if (kind == ZB_KEY_MODIFIER) {
    [out addObject:[NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:(flags | modFlag)
                                   timestamp:ts windowNumber:wn context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:kc]];
    [out addObject:[NSEvent keyEventWithType:NSEventTypeFlagsChanged location:NSZeroPoint modifierFlags:flags
                                   timestamp:ts + 0.01 windowNumber:wn context:nil characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:kc]];
    return;
  }
  [out addObject:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags
                                 timestamp:ts windowNumber:wn context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:kc]];
  [out addObject:[NSEvent keyEventWithType:NSEventTypeKeyUp location:NSZeroPoint modifierFlags:flags
                                 timestamp:ts + 0.01 windowNumber:wn context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:kc]];
}

// Deliver `events` one at a time, each FIFO-acked by a round-trip, so a synthetic event is processed
// (and its keydown/keyup/input dispatched) before the next is sent — rapid back-to-back synthetic keys
// otherwise drop/coalesce through the input method. When `expected` is non-nil, the ack doubles as a
// per-event documentToken RECHECK (RoseCat 6361.1): if an event navigated the page, the next event is
// NOT sent into the replacement document — the sequence stops with DOC_CHANGED. Called in DISPATCHING;
// goes INFLIGHT after the first send; a waiter that abandons mid-sequence stops delivery (onProgress
// reports events dispatched). Owns the chain ref: completes + unrefs exactly once.
static void zb_deliver_events_paced(NSWindow *window, WKWebView *view, ZBAutoJob *job, NSString *expected,
                                    NSArray<NSEvent *> *events, void (^onProgress)(NSUInteger delivered)) {
  if (events.count == 0) {
    [view evaluateJavaScript:@"0" completionHandler:^(id v, NSError *e) { (void)v; zb_job_complete(job, e != nil ? ZB_AUTO_ERR_JS : ZB_AUTO_OK, NULL, NULL); zb_job_unref(job); }];
    zb_job_inflight(job);
    return;
  }
  WKContentWorld *autoWorld = (expected != nil) ? [WKContentWorld worldWithName:@ZB_AUTOMATION_WORLD] : nil;
  __block void (^step)(NSUInteger) = nil;
  step = ^(NSUInteger idx) {
    [window sendEvent:events[idx]];
    if (onProgress != nil) onProgress(idx + 1);
    void (^onAck)(NSString *, NSError *) = ^(NSString *tok, NSError *e) {
      if (e != nil) { step = nil; zb_job_complete(job, ZB_AUTO_ERR_JS, NULL, NULL); zb_job_unref(job); return; }
      if (expected != nil) {  // per-event documentToken recheck
        NSString *t = tok;
        if (zb_auto_test_stale_token()) t = @"zb-debug-stale-token";
        if (t == nil || ![t isEqualToString:expected]) { step = nil; zb_job_complete(job, ZB_AUTO_ERR_DOC_CHANGED, NULL, NULL); zb_job_unref(job); return; }
      }
      if (idx + 1 >= events.count) { step = nil; zb_job_complete(job, ZB_AUTO_OK, NULL, NULL); zb_job_unref(job); return; }
      if (!zb_job_is_inflight(job)) { step = nil; zb_job_unref(job); return; }  // waiter abandoned: stop
      step(idx + 1);
    };
    if (expected != nil) {
      [view callAsyncJavaScript:@"return globalThis.__zbAutomation ? globalThis.__zbAutomation.documentToken : null;"
                      arguments:@{}
                        inFrame:nil
                 inContentWorld:autoWorld
              completionHandler:^(id v, NSError *e) { onAck([v isKindOfClass:[NSString class]] ? (NSString *)v : nil, e); }];
    } else {
      [view evaluateJavaScript:@"0" completionHandler:^(id v, NSError *e) { (void)v; onAck(nil, e); }];
    }
  };
  step(0);
  zb_job_inflight(job);
}

// Shared phase-model driver: run the readiness poll + (optional) documentToken guard in PREFLIGHT, then
// call deliver(host, job) once ready and the guard passes. `deliver` OWNS the chain ref from that point
// (it must zb_job_claim_dispatch, do the side effect, zb_job_inflight, FIFO-ack -> zb_job_complete, and
// zb_job_unref). The driver handles every non-deliver terminal itself. Mirrors zb_native_click.
static int zb_auto_native_input(uint32_t win, NSString *expected, unsigned int timeout_ms,
                                void (^deliver)(ZBWindowHost *host, ZBAutoJob *job)) {
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  ZBAutoJob *job = zb_job_new();
  if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:(double)timeout_ms / 1000.0];
  zb_job_ref(job);
  __block BOOL entered = NO;
  __block void (^dlv)(ZBWindowHost *, ZBAutoJob *) = [deliver copy];
  __block void (^poll)(void) = nil;
  poll = ^{
    if (!entered) {
      entered = YES;
      if (!zb_job_enter_preflight(job)) { poll = nil; dlv = nil; zb_job_unref(job); return; }
    } else if (!zb_job_in_preflight(job)) {
      poll = nil; dlv = nil; zb_job_unref(job); return;
    }
    ZBWindowHost *host = zb_auto_window_for_id(win);
    if (host == nil) { poll = nil; dlv = nil; if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
    if (!host.finishedOrFailed) {
      if ([[NSDate date] compare:deadline] != NSOrderedAscending) { poll = nil; dlv = nil; if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_TIMEOUT, NULL, NULL); zb_job_unref(job); return; }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), poll);
      return;
    }
    poll = nil;  // ready
    if (expected == nil) { void (^d)(ZBWindowHost *, ZBAutoJob *) = dlv; dlv = nil; d(host, job); return; }
    WKContentWorld *autoWorld = [WKContentWorld worldWithName:@ZB_AUTOMATION_WORLD];
    [host.webView callAsyncJavaScript:@"return globalThis.__zbAutomation ? globalThis.__zbAutomation.documentToken : null;"
                            arguments:@{}
                              inFrame:nil
                       inContentWorld:autoWorld
                    completionHandler:^(id value, NSError *error) {
      if (!zb_job_in_preflight(job)) { dlv = nil; zb_job_unref(job); return; }
      if (error != nil) { dlv = nil; if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_JS, NULL, NULL); zb_job_unref(job); return; }
      NSString *token = [value isKindOfClass:[NSString class]] ? (NSString *)value : nil;
      if (zb_auto_test_stale_token()) token = @"zb-debug-stale-token";
      if (token == nil || ![token isEqualToString:expected]) { dlv = nil; if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_DOC_CHANGED, NULL, NULL); zb_job_unref(job); return; }
      ZBWindowHost *h2 = zb_auto_window_for_id(win);
      if (h2 == nil) { dlv = nil; if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
      void (^d)(ZBWindowHost *, ZBAutoJob *) = dlv; dlv = nil; d(h2, job);
    }];
  };
  dispatch_async(dispatch_get_main_queue(), poll);
  int rc = zb_job_wait(job, timeout_ms);
  zb_job_unref(job);
  return rc;
}

int zb_native_key(uint32_t win, const char *key, int modifiers, const char *expected_doc,
                  unsigned int timeout_ms, int *out_releases, char **out_err) {
  if (out_releases != NULL) *out_releases = 0;
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  @autoreleasepool {
    NSString *name = key != NULL ? [NSString stringWithUTF8String:key] : nil;
    ZBKeyKind kind;
    unsigned short kc = 0;
    NSString *chars = nil;
    NSEventModifierFlags modFlag = 0;
    if (name == nil || !zb_dom_key_to_ns(name, &kind, &kc, &chars, &modFlag)) return ZB_AUTO_ERR_INTERNAL;  // unknown key
    NSEventModifierFlags flags = zb_ns_mod_flags(modifiers);
    NSString *expected = expected_doc != NULL ? [NSString stringWithUTF8String:expected_doc] : nil;
    __block int releases = 0;
    int rc = zb_auto_native_input(win, expected, timeout_ms, ^(ZBWindowHost *host, ZBAutoJob *job) {
      if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }
      NSWindow *window = host.window;
      WKWebView *view = host.webView;
      if (window == nil || view == nil) { zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
      NSMutableArray<NSEvent *> *events = [NSMutableArray array];
      zb_build_key_events(window, kind, kc, chars, modFlag, flags, events);
      zb_deliver_events_paced(window, view, job, nil, events, ^(NSUInteger d) { releases = (int)(d / 2); });  // no per-key recheck (a single key may intentionally navigate, e.g. Enter)
    });
    if (out_releases != NULL) *out_releases = releases;
    return rc;
  }
}

int zb_native_text(uint32_t win, const char *text, const char *expected_doc, unsigned int timeout_ms,
                   int *out_releases, int *out_chars, char **out_err) {
  if (out_releases != NULL) *out_releases = 0;
  if (out_chars != NULL) *out_chars = 0;
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  if (text == NULL) return ZB_AUTO_ERR_INTERNAL;
  @autoreleasepool {
    NSString *str = [NSString stringWithUTF8String:text];
    if (str == nil) return ZB_AUTO_ERR_INTERNAL;
    NSString *expected = expected_doc != NULL ? [NSString stringWithUTF8String:expected_doc] : nil;
    // One substring per Unicode CODE POINT (not grapheme cluster), so sent_chars counts code points
    // (RoseCat 6361.2); a surrogate pair is one code point.
    NSMutableArray<NSString *> *cps = [NSMutableArray array];
    NSUInteger i = 0;
    while (i < str.length) {
      unichar c = [str characterAtIndex:i];
      NSUInteger len = (CFStringIsSurrogateHighCharacter(c) && i + 1 < str.length) ? 2 : 1;
      NSString *cp = [str substringWithRange:NSMakeRange(i, len)];
      [cps addObject:[cp isEqualToString:@"\n"] ? @"\r" : cp];  // newline -> Return
      i += len;
    }
    __block int sent = 0;
    int rc = zb_auto_native_input(win, expected, timeout_ms, ^(ZBWindowHost *host, ZBAutoJob *job) {
      if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }
      NSWindow *window = host.window;
      WKWebView *view = host.webView;
      if (window == nil || view == nil) { zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
      NSMutableArray<NSEvent *> *events = [NSMutableArray array];
      for (NSString *cp in cps) zb_build_key_events(window, ZB_KEY_CHAR, 0, cp, 0, 0, events);
      // Each code point is one keyDown/keyUp pair -> every completed pair (an even delivered count) is a
      // typed code point; a mid-text abandon leaves `sent` at the code points fully dispatched.
      zb_deliver_events_paced(window, view, job, expected, events, ^(NSUInteger d) { sent = (int)(d / 2); });  // per-char documentToken recheck (6361.1)
    });
    if (out_chars != NULL) *out_chars = sent;
    if (out_releases != NULL) *out_releases = sent;
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
