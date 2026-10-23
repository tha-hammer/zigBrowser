#include "webkit_shim.h"
#include "zb_test_hook_gate.h"  // hook 16: the pure data-store decision (tests/hook16_decision_test.zig)

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>  // MS4/MS3.1: SHA-256 for the profile-dir identity digest

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
// Thread-safe mirror of the --e2e-protocol flag: zb_auto_test_hooks_enabled() derefs g_active_app (AppKit,
// main-thread-only), so off-main callers (zb_job_new/unref run on server threads) read this atomic instead,
// set ONCE on the main thread in -initWithURI... (RoseCat 6767 #3).
static atomic_int zb_auto_e2e_enabled = 0;
// MS2c (RoseCat 6508 #6): the window snapshot is a lock-backed cache. The main thread republishes it on
// every window state change (create/remove/health tick); page.list/page.health read it under the lock and
// NEVER dispatch to the main queue, so a backed-up/hung main queue cannot stall them.
static NSString *g_window_snapshot = nil;
static pthread_mutex_t g_window_snapshot_lock = PTHREAD_MUTEX_INITIALIZER;
static void zb_publish_window_snapshot(void);  // defined below; called from the window lifecycle + health tick
// MS3.2 backend-flag config (set at startup by webkit.applyBackendFlag, before any window is created).
static int g_media_source_enabled = 1;        // 0 = disable window.MediaSource (MSE off) in every new webView
static int g_hw_policy = ZB_HW_POLICY_WEBKIT;  // stored for read-back; macOS WKWebView manages HW accel itself
// MS3.1 profile persistence (set by zb_app_set_profile_dir at startup). On macOS 14+ a profile dir maps to an
// isolated persistent WKWebsiteDataStore (dataStoreForIdentifier, keyed by a UUID derived from the path); on
// macOS 13 it falls back to the default (shared) store (user decision 2026-10-20). The store is resolved
// LAZILY at the first webView (so the e2e availability seam can read g_active_app's e2e flag, which is unset
// at profile-dir time). g_profile_data_store nil = default store.
static NSString *g_profile_dir = nil;
static WKWebsiteDataStore *g_profile_data_store = nil;
static BOOL g_profile_resolved = NO;
static void zb_resolve_profile_store(void);  // defined below; called lazily from newConfiguredWebView
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
@property(nonatomic, assign) uint32_t nextWindowId;  // MS2c: monotonic STABLE window ids, never reused
- (instancetype)initWithURI:(NSString *)uri printTitle:(BOOL)printTitle e2eProtocol:(BOOL)e2eProtocol;
- (ZBWindowHost *)createWindowWithWebView:(WKWebView *)webView child:(BOOL)child uri:(NSString *)uri opener:(ZBWindowHost *)opener;
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
@property(nonatomic, assign) BOOL nativeCloseFired;  // e2e-only ZB_DEBUG_NATIVE_CLOSE_ON_TITLE: one shot per window
// MS2b.2 page dialogs. At most one open dialog per window; it is NEVER answered by default — the
// captured WKUIDelegate completion handler is held until zb_automation_respond_dialog answers it (or the
// window closes). kind: 0 none, 1 alert, 2 confirm, 3 prompt, 4 beforeunload. Touched only on the main
// thread (the WKUIDelegate callbacks and the dialog ABI's main-queue hop).
@property(nonatomic, assign) int pendingDialogKind;
@property(nonatomic, copy) NSString *pendingDialogMessage;
@property(nonatomic, copy) NSString *pendingDialogDefault;  // prompts only
@property(nonatomic, copy) void (^pendingAlertCompletion)(void);
@property(nonatomic, copy) void (^pendingConfirmCompletion)(BOOL);
@property(nonatomic, copy) void (^pendingPromptCompletion)(NSString *);
// MS2c page.health: a JS-ping responsiveness watchdog (WKWebView exposes no public is-responsive signal,
// and the private SPI is ruled out). A repeating main-thread timer pings the web process; a ping left
// unanswered across a tick marks the window unresponsive (unresponsiveSinceUs != 0, incident bumped once
// per stretch), cleared when a ping replies. Touched only on the main thread (timer + the list ABI's
// main-queue hop), monotonic microseconds via systemUptime.
@property(nonatomic, assign) uint32_t windowId;  // MS2c: this window's STABLE id (assigned once, never reused)
@property(nonatomic, assign) uint64_t loadSerial;  // MS4.1a: increments on each load-commit (approval-grant revalidation)
@property(nonatomic, assign) uint32_t openerId;  // MS2c: the window (id) whose page opened this popup; 0 = none
@property(nonatomic, assign) uint32_t processGroup;  // MS2c: conservative WebContent-process family (= root opener's id); inherited at creation so it survives a middle window closing
// MS2c crash parity: the web process ended since the last page load ("crashed"); nil while alive. The
// window shows a STATIC crash document and keeps its committed URL; it never auto-reloads. Cleared only
// on a real commit (the next successful navigation), not by the crash document's own load.
@property(nonatomic, copy) NSString *terminatedReason;
@property(nonatomic, assign) BOOL showingCrashDoc;
@property(nonatomic, assign) BOOL kvoObserving;  // MS2c #6: whether this host currently observes its webView's title/URL/loading
@property(nonatomic, strong) NSTimer *healthTimer;
@property(nonatomic, assign) int64_t unresponsiveSinceUs;  // 0 while responsive
@property(nonatomic, assign) uint32_t incident;            // count of unresponsive stretches (recover identity)
@property(nonatomic, assign) BOOL pingOutstanding;
@property(nonatomic, assign) int64_t pingSentUs;
- (instancetype)initWithApp:(ZBAppHost *)app webView:(WKWebView *)webView child:(BOOL)child;
- (void)startHealthWatchdog;
- (void)healthTick;
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
  atomic_store(&zb_auto_e2e_enabled, e2eProtocol ? 1 : 0);  // set on the main thread; read off-main by the job counters
  _exitCode = ZB_EXIT_SUCCESS;
  _appBase = derive_app_base(uri);
  _windows = [NSMutableArray array];
  return self;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
  (void)sender;
  return NO;
}

- (ZBWindowHost *)createWindowWithWebView:(WKWebView *)webView child:(BOOL)child uri:(NSString *)uri opener:(ZBWindowHost *)opener {
  if (self.windows.count >= ZB_MAX_WINDOWS) {
    fprintf(stderr, "window cap reached (%d); refusing new sub-window\n", ZB_MAX_WINDOWS);
    return nil;
  }

  ZBWindowHost *host = [[ZBWindowHost alloc] initWithApp:self webView:webView child:child];
  if (host == nil) {
    return nil;
  }
  host.windowId = ++self.nextWindowId;  // STABLE id, assigned once; the first window (primary) is 1
  host.processGroup = host.windowId;  // default: its own family root
  if (opener != nil) {  // set the opener's id + inherited family group BEFORE the snapshot publish below,
    host.openerId = opener.windowId;        // so a popup never appears in page.list without its opener
    host.processGroup = opener.processGroup;
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

  [host startHealthWatchdog];  // MS2c page.health responsiveness ping
  if (uri.length > 0) {
    [host loadURI:uri];
  }
  zb_publish_window_snapshot();  // MS2c #6: the new window is visible to page.list/health at once
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
  zb_publish_window_snapshot();  // MS2c #6: the removed window leaves page.list/health at once
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

static int zb_auto_test_synth_crash(void);  // defined with the other e2e hooks below; used by didFinish
static const char *zb_auto_test_native_close_title(void);  // e2e hook (defined below); used by the title KVO
static long zb_auto_test_health_reply_hold_ms(void);  // e2e hook (defined below); used by healthTick
static BOOL zb_auto_test_health_tick_suspended(void);  // e2e hook (defined below); used by healthTick
static char *zb_auto_dup_tracked(const char *s);  // part B: strdup + account a caller-returned string (defined below)
static void zb_auto_free_tracked(char *p);         // part B: free + account a caller-returned string (defined below)

// MS2c #6: KVO context for a webView's observable fields; a change republishes the window snapshot so
// page.list/page.health reflect title/url/loading promptly without polling the main queue.
static void *ZBWebViewKVOContext = &ZBWebViewKVOContext;

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
  [self zbStartObserving];  // MS2c #6: track title/url/loading into the snapshot

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
  if (!g_media_source_enabled) {  // MS3.2 --media-source off: remove MSE (window.MediaSource) at document
    // start so sites fall back to plain media (the Instagram MSE-deadlock mitigation; WKWebView has no
    // public MSE preference, so a user script is the public-API mechanism).
    WKUserScript *noMSE = [[WKUserScript alloc] initWithSource:
        @"try{window.MediaSource=undefined;window.WebKitMediaSource=undefined;}catch(e){}"
                                               injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                            forMainFrameOnly:NO];
    [configuration.userContentController addUserScript:noMSE];
  }
  zb_resolve_profile_store();  // MS3.1: resolve the profile store once, now that g_active_app/e2e is set
  if (g_profile_data_store != nil) configuration.websiteDataStore = g_profile_data_store;  // MS3.1 profile-scoped store
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

// MS2c page.health: monotonic microseconds (systemUptime is monotonic since boot).
static int64_t zb_now_us(void) { return (int64_t)([[NSProcessInfo processInfo] systemUptime] * 1e6); }

- (void)startHealthWatchdog {
  self.pingOutstanding = NO;
  self.unresponsiveSinceUs = 0;
  self.incident = 0;
  __weak ZBWindowHost *weakSelf = self;
  self.healthTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
    (void)t;
    ZBWindowHost *s = weakSelf;
    if (s == nil) return;
    [s healthTick];
  }];
}

- (void)healthTick {
  if (zb_auto_test_health_tick_suspended()) return;  // e2e-only: freeze the periodic republish so a dialog
                                                      // open/respond snapshot can only come from its handler
  if (self.pingOutstanding) {
    // The ping issued last tick has not replied within a full interval: the web process is unresponsive.
    if (self.unresponsiveSinceUs == 0) { self.unresponsiveSinceUs = self.pingSentUs; self.incident += 1; }
    zb_publish_window_snapshot();  // MS2c #6: refresh (unresponsive_ms grows; newly-unresponsive shows)
    return;  // leave the ping outstanding; don't pile on
  }
  WKWebView *view = self.webView;
  if (view == nil) return;
  self.pingOutstanding = YES;
  self.pingSentUs = zb_now_us();
  __weak ZBWindowHost *weakSelf = self;
  WKWebView *pinged = view;  // the view this ping was issued on
  [view evaluateJavaScript:@"0" completionHandler:^(id v, NSError *e) {
    (void)v; (void)e;  // any reply (even an error) means the web process answered -> responsive
    void (^apply)(void) = ^{
      ZBWindowHost *s = weakSelf;
      // Identity gate (RoseCat 6551 #2): a late reply from a REPLACED/abandoned view must never clear the
      // fresh view's in-flight ping or falsely mark the replacement responsive.
      if (s == nil || s.webView != pinged) return;
      s.pingOutstanding = NO;
      s.unresponsiveSinceUs = 0;
      zb_publish_window_snapshot();  // MS2c #6: responsive restored + current url/title/loading
    };
    long hold_ms = zb_auto_test_health_reply_hold_ms();  // e2e-only: defer the reply to prove the gate
    if (hold_ms > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)hold_ms * NSEC_PER_MSEC), dispatch_get_main_queue(), apply);
    else apply();
  }];
  zb_publish_window_snapshot();  // MS2c #6: every tick refreshes url/title/loading/crashed/dialog_open
}

- (void)close {
  [self.healthTimer invalidate];
  self.healthTimer = nil;
  [self zbStopObserving];  // MS2c #6: remove KVO before the webView is torn down
  // Never release a held WKWebView dialog completion uncalled (WebKit raises NSException): answer any
  // open dialog with its default (confirm->Cancel, prompt->null, alert->resume) as closing the window does.
  if (self.pendingDialogKind != 0) [self zbRespondDialogAccept:NO text:nil];
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

// MS4.1a: a page committed a load (the macOS analog of WEBKIT_LOAD_COMMITTED). Bump the per-window
// load_serial so a grant minted before this navigation is revoked at revalidation, and refresh the snapshot.
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
  (void)webView;
  if (navigation != nil && navigation != self.currentNav) return;  // ignore a superseded navigation's late commit
  self.loadSerial += 1;
  zb_publish_window_snapshot();
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
  if (navigation != nil && navigation != self.currentNav) {
    return;  // stale: a superseded navigation's late finish must not touch the current state
  }
  self.finishedOrFailed = YES;
  // MS2c crash parity: a real commit clears the crashed state; the crash document's own load keeps it
  // (it is not a recovery — the window stays on the static crash page, never auto-reloaded).
  if (self.showingCrashDoc) {
    self.showingCrashDoc = NO;
  } else {
    self.terminatedReason = nil;
  }
  if (navigation != nil && navigation == self.routedNav) {
    self.routedOutcome = 1;  // success for THIS routed navigation
  }
  [self.timeoutTimer invalidate];
  self.timeoutTimer = nil;
  zb_publish_window_snapshot();  // MS2c #6: a real commit refreshes url/title and clears crashed at once (all windows)

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

  // e2e crash-presentation red: after a real (non-crash-doc) load, optionally synthesize the web
  // process termination once (the production handler below is public and unchanged).
  if (self.terminatedReason == nil && !self.child && zb_auto_test_synth_crash()) {
    __weak ZBWindowHost *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBWindowHost *s = weakSelf;
      if (s != nil) [s webViewWebContentProcessDidTerminate:s.webView];
    });
  }
}

// MS2c crash parity: the window's web process ended (crash / OOM / termination). Mark it crashed, keep
// the committed URL, show a STATIC crash document, and NEVER auto-reload (parity with Linux). The crashed
// flag clears only on a later real commit (didFinishNavigation above). Public WKNavigationDelegate method.
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
  self.terminatedReason = @"crashed";  // WKWebView's public callback gives no reason; report the generic one
  fprintf(stderr, "web content process terminated: window-%u\n", (unsigned)self.windowId);  // MS2c: per-window native diagnostic
  fflush(stderr);
  NSString *committed = webView.URL.absoluteString;
  NSURL *base = (committed.length > 0) ? [NSURL URLWithString:committed] : nil;
  self.showingCrashDoc = YES;  // the next didFinish is the crash doc's own load, not a recovery
  [webView loadHTMLString:@"<!doctype html><html><head><meta charset=\"utf-8\"><title>zb-crash</title></head>"
                           @"<body>The web page stopped and its process ended.</body></html>"
                  baseURL:base];  // baseURL keeps the committed URL; no reload of the live page
  zb_publish_window_snapshot();  // MS2c #6: crashed=true visible to page.list/health at once
}

// MS2c view-replacement recovery (PUBLIC API only — no process kill, no SPI): swap in a FRESH WKWebView,
// keeping this window's stable id / opener / process group, re-wire the delegates and the automation
// script handler, restart the health watchdog, and reload the committed URL. For a crashed window the dead
// web process is already gone; for a frozen one the old (hung) process is abandoned, not killed — the
// window still comes back usable. Returns the reloaded URL, or nil if there was no committed URL to
// restore. Main thread only.
- (NSString *)recoverByReplacingWebView {
  NSString *committed = self.webView.URL.absoluteString;
  if (committed.length == 0) committed = self.requestedURI;
  if (committed.length == 0) return nil;

  WKWebView *fresh = [ZBWindowHost newConfiguredWebView];
  if (fresh == nil) return nil;

  // Answer any dialog held open on the OLD view BEFORE abandoning it: releasing a WKWebView with an
  // uncalled JS-panel completion raises an NSException (RoseCat 6551 #1), and after the swap close/dealloc
  // would skip it (pendingDialogKind would be 0). Default answer, exactly as -close does.
  // Answer any dialog held open on the OLD view BEFORE abandoning it: releasing a WKWebView with an
  // uncalled JS-panel completion raises an NSException (RoseCat 6551 #1), and after the swap close/dealloc
  // would skip it (pendingDialogKind would be 0). Default answer, exactly as -close does.
  if (self.pendingDialogKind != 0) [self zbRespondDialogAccept:NO text:nil];

  // Detach the old (dead/hung) webView so ARC can free it once the window stops referencing it.
  [self.healthTimer invalidate];
  self.healthTimer = nil;
  [self zbStopObserving];  // MS2c #6: remove KVO from the old webView before swapping
  WKWebView *old = self.webView;
  [old.configuration.userContentController removeScriptMessageHandlerForName:@"zbHost"];
  old.navigationDelegate = nil;
  old.UIDelegate = nil;

  // Attach the fresh webView to the SAME window.
  fresh.navigationDelegate = self;
  fresh.UIDelegate = self;
  [fresh.configuration.userContentController removeScriptMessageHandlerForName:@"zbHost"];
  [fresh.configuration.userContentController addScriptMessageHandlerWithReply:self contentWorld:WKContentWorld.pageWorld name:@"zbHost"];
  self.webView = fresh;
  [self zbStartObserving];  // MS2c #6: observe the fresh webView
  self.window.contentView = fresh;

  // Clear crash state; the held dialog (if any) was already answered above. startHealthWatchdog resets the
  // ping/unresponsive/incident counters.
  self.terminatedReason = nil;
  self.showingCrashDoc = NO;
  [self startHealthWatchdog];

  [self loadURI:committed];
  return committed;
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
    [self.app createWindowWithWebView:nil child:YES uri:candidate opener:nil];  // policy-opened subwindow: no tracked opener (unchanged)
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
  // opener:self — the shim sets the popup's stable opener id + inherited process group inside
  // createWindowWithWebView, BEFORE it publishes the snapshot, so page.list never shows the popup openerless.
  ZBWindowHost *child = [self.app createWindowWithWebView:childView child:YES uri:nil opener:self];
  return child.webView;
}

// MS2c: a page called window.close(). Honor it for a POPUP with the same teardown as an automation
// page.close (so the opener survives, DOM intact); never for the primary (browsers ignore window.close()
// on the main window). Deferred to the main queue so we never tear the webView down inside its own
// UI-delegate callback; the registry check drops a double-close.
- (void)webViewDidClose:(WKWebView *)webView {
  (void)webView;
  ZBAppHost *app = self.app;
  if (app == nil || self == app.mainWindow) return;
  ZBWindowHost *host = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (![app.windows containsObject:host]) return;  // already removed
    [host close];
    [app removeWindow:host];
  });
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

// --- MS2b.2 page dialogs (WKUIDelegate) ---
// WKWebView surfaces alert/confirm/prompt through these WKUIDelegate methods; without them JS gets the
// default answer and no dialog is shown. We CAPTURE each as the window's one pending dialog and hold its
// completion handler — the page's JS turn stays blocked until zb_automation_respond_dialog answers it,
// so automation can observe and answer it (never auto-answered). A second dialog arriving while one is
// open is answered with its default immediately (JS is single-threaded, so this is defensive).

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
  (void)webView; (void)frame;
  if (self.pendingDialogKind != 0) { completionHandler(); return; }
  self.pendingDialogKind = 1;
  self.pendingDialogMessage = message ?: @"";
  self.pendingDialogDefault = nil;
  self.pendingAlertCompletion = completionHandler;
  zb_publish_window_snapshot();  // RoseCat 6556: dialog_open reflects at once, not on the next 500ms tick
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
  (void)webView; (void)frame;
  if (self.pendingDialogKind != 0) { completionHandler(NO); return; }
  self.pendingDialogKind = 2;
  self.pendingDialogMessage = message ?: @"";
  self.pendingDialogDefault = nil;
  self.pendingConfirmCompletion = completionHandler;
  zb_publish_window_snapshot();  // RoseCat 6556: dialog_open reflects at once, not on the next 500ms tick
}

- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt
    defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame
    completionHandler:(void (^)(NSString *))completionHandler {
  (void)webView; (void)frame;
  if (self.pendingDialogKind != 0) { completionHandler(nil); return; }
  self.pendingDialogKind = 3;
  self.pendingDialogMessage = prompt ?: @"";
  self.pendingDialogDefault = defaultText ?: @"";
  self.pendingPromptCompletion = completionHandler;
  zb_publish_window_snapshot();  // RoseCat 6556: dialog_open reflects at once, not on the next 500ms tick
}

// Answer this window's open dialog on the main thread: alert -> resume; confirm -> accept bool; prompt ->
// the given text when accepted (null = its default), nil when dismissed. Returns NO if none is open.
- (BOOL)zbRespondDialogAccept:(BOOL)accept text:(NSString *)text {
  int kind = self.pendingDialogKind;
  if (kind == 0) return NO;
  NSString *def = self.pendingDialogDefault;
  self.pendingDialogKind = 0;
  self.pendingDialogMessage = nil;
  self.pendingDialogDefault = nil;
  if (kind == 1) {
    void (^c)(void) = self.pendingAlertCompletion; self.pendingAlertCompletion = nil; if (c) c();
  } else if (kind == 2) {
    void (^c)(BOOL) = self.pendingConfirmCompletion; self.pendingConfirmCompletion = nil; if (c) c(accept ? YES : NO);
  } else if (kind == 3) {
    void (^c)(NSString *) = self.pendingPromptCompletion; self.pendingPromptCompletion = nil;
    if (c) c(accept ? (text != nil ? text : (def != nil ? def : @"")) : nil);
  }
  zb_publish_window_snapshot();  // RoseCat 6556: dialog_open clears at once, not on the next 500ms tick
  return YES;
}

// A page dialog open on this window blocks its web process, so a command that needs page script must
// fail fast with DIALOG_OPEN instead of hanging (url, which reads no script, stays exempt).
- (BOOL)zbHasOpenDialog {
  return self.pendingDialogKind != 0;
}

// MS2c #6: observe the webView's title/URL/loading; a change republishes the snapshot. Add/remove are
// balanced by the kvoObserving flag so a double close/swap never over-removes (which would crash).
- (void)zbStartObserving {
  if (self.kvoObserving || self.webView == nil) return;
  for (NSString *kp in @[ @"title", @"URL", @"loading" ])
    [self.webView addObserver:self forKeyPath:kp options:0 context:ZBWebViewKVOContext];
  self.kvoObserving = YES;
}

- (void)zbStopObserving {
  if (!self.kvoObserving || self.webView == nil) return;
  for (NSString *kp in @[ @"title", @"URL", @"loading" ])
    [self.webView removeObserver:self forKeyPath:kp context:ZBWebViewKVOContext];
  self.kvoObserving = NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
  if (context == ZBWebViewKVOContext) {
    zb_publish_window_snapshot();  // title/url/loading changed -> refresh page.list/health
    if ([keyPath isEqualToString:@"title"]) [self zbTestNativeCloseIfTitled];
    return;
  }
  [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

// e2e-only (ZB_DEBUG_NATIVE_CLOSE_ON_TITLE, 4pa.58 MS2c.6 red): when this window's page title becomes the
// hook's exact value, print NATIVE_CLOSE <id> and close the NSWindow through -[NSWindow performClose:], the
// AppKit path a click on its red close button takes. Deferred to the main queue so the window never closes
// inside this KVO callback. Inert without --e2e-protocol.
- (void)zbTestNativeCloseIfTitled {
  const char *want = zb_auto_test_native_close_title();
  if (want == NULL || self.nativeCloseFired) return;
  NSString *wantTitle = [NSString stringWithUTF8String:want];
  if (wantTitle == nil || ![self.webView.title isEqualToString:wantTitle]) return;
  self.nativeCloseFired = YES;
  __weak ZBWindowHost *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    ZBWindowHost *s = weakSelf;
    if (s == nil || s.window == nil) return;
    char id_buf[32];
    snprintf(id_buf, sizeof(id_buf), "%u", (unsigned)s.windowId);
    emit_protocol1(s.app.e2eProtocol, "NATIVE_CLOSE", id_buf);
    [s.window performClose:nil];
  });
}

- (void)dealloc {
  // Safety net if -close did not run: a held WKWebView completion must never be released uncalled.
  if (self.pendingDialogKind != 0) [self zbRespondDialogAccept:NO text:nil];
  [self zbStopObserving];  // MS2c #6: never leave a KVO registration dangling past dealloc
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
  if (win == 0) return app.mainWindow;  // the "primary" alias
  // STABLE id lookup: a window keeps its id for life, so closing one never renumbers the others
  // (MS2c follow-up). The id is NOT an array index.
  for (ZBWindowHost *h in app.windows) {
    if (h.windowId == win) return h;
  }
  return nil;
}

void zb_automation_free(char *p) {
  zb_auto_free_tracked(p);
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
  int progress;  // guarded by mu: code points (keyDown/keyUp pairs) fully dispatched so far
  char *result;  // owned; moved out by the waiter on DONE
  char *err;     // owned; freed with the job
} ZBAutoJob;

static atomic_int zb_auto_live_jobs = 0;
static atomic_uint zb_auto_waiter_grace_ms = 0;  // test hook: waiter wakes late so a late completion wins
// MS2a.3 part B: caller-returned C strings currently alive (handed to a job's result/err or an *out param,
// to be freed via zb_automation_free / zb_job_unref / the abandon path). Every such string is allocated via
// zb_auto_dup_tracked and freed via zb_auto_free_tracked; the balance must return to 0 after each op drains.
static atomic_int zb_auto_strings_live = 0;
// MS2a.3 part C (RoseCat 6767 lifecycle): set once the app run loop is ending. A readiness poll that sees it
// finishes its queued job with NO_LOOP and unrefs, so a block the stopped loop can no longer run is drained
// (zb_auto_on_loop_ended) and its ref released — live jobs reach 0 instead of leaking.
static atomic_int zb_auto_loop_ended = 0;
// Count of readiness-poll jobs the app-ended drain cancelled via the no-loop (no-work) path (RoseCat 41c683a #3).
static atomic_int zb_auto_loop_cancels = 0;
// Count of ACTUAL readiness work executions (RoseCat da7ae1c): proves the drain cancels without running work.
static atomic_int zb_auto_work_runs = 0;

int zb_automation_debug_live_jobs(void) { return atomic_load(&zb_auto_live_jobs); }
void zb_automation_debug_waiter_grace(unsigned int ms) { atomic_store(&zb_auto_waiter_grace_ms, ms); }
// Part B direct oracle (RoseCat 6798 #2): the live count of accounted caller-returned C strings. A plain
// accessor (not gated) so a unit/ctypes oracle can assert the balance is 0 at rest and after each free.
int zb_automation_debug_strings_live(void) { return atomic_load(&zb_auto_strings_live); }

// strdup + account the string as a live caller-returned allocation (part B). Emits the balance under
// --e2e-protocol (atomic, off-main safe) so a socket e2e can assert it returns to 0.
static char *zb_auto_dup_tracked(const char *s) {
  char *c = strdup(s != NULL ? s : "");
  if (c != NULL) {
    int n = atomic_fetch_add(&zb_auto_strings_live, 1) + 1;
    if (atomic_load(&zb_auto_e2e_enabled)) { fprintf(stderr, "zb-str-live=%d\n", n); fflush(stderr); }
  }
  return c;
}

// free a caller-returned string and account it (part B). Used at every free site of job->result/err / *out.
static void zb_auto_free_tracked(char *p) {
  if (p != NULL) {
    int n = atomic_fetch_sub(&zb_auto_strings_live, 1) - 1;
    if (atomic_load(&zb_auto_e2e_enabled)) { fprintf(stderr, "zb-str-live=%d\n", n); fflush(stderr); }
  }
  free(p);
}

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

// Bounded non-negative integer parse (strtol with a full-string + range check, like
// snapshot_settle_ms_from_env); -1 on any malformed/negative input. Used by the test hooks instead of
// atoi, which silently accepts trailing garbage and cannot report failure (RoseCat 6433 parser nit).
static long zb_parse_nonneg(const char *s) {
  if (s == NULL || s[0] == '\0') return -1;
  char *end = NULL;
  long v = strtol(s, &end, 10);
  if (end == s || *end != '\0' || v < 0) return -1;
  return v;
}

static void zb_auto_test_dispatch_hold(void) {
  if (!zb_auto_test_hooks_enabled()) return;
  const char *h = getenv("ZB_DEBUG_DISPATCH_HOLD_MS");
  if (h == NULL) return;
  long ms = strtol(h, NULL, 10);
  if (ms <= 0) return;
  if (ms > 60000) ms = 60000;  // clamp: bound the test hold so (ms * 1000) us cannot overflow
  fprintf(stderr, "zb-dispatch-hold-active\n");  // observed hold-start barrier (RoseCat 6556): the main queue is now wedged
  fflush(stderr);
  usleep((useconds_t)(ms * 1000));
}

// Test-only (ZB_DEBUG_HEALTH_REPLY_HOLD_MS): defer each health-ping reply by this many ms, so a reply from
// a view that recovery has replaced lands AFTER the swap — exercising healthTick's identity gate. Inert
// without --e2e-protocol. Read on the main thread, where g_active_app is stable.
static long zb_auto_test_health_reply_hold_ms(void) {
  if (!zb_auto_test_hooks_enabled()) return 0;
  long ms = zb_parse_nonneg(getenv("ZB_DEBUG_HEALTH_REPLY_HOLD_MS"));
  if (ms <= 0) return 0;
  if (ms > 60000) ms = 60000;
  static int consumed = 0;  // one-shot (main thread): hold ONLY the first ping reply, so a recovery can
  if (consumed) return 0;   // replace the view before it lands; later pings (incl. the fresh view's) apply normally
  consumed = 1;
  return ms;
}

// Test-only (ZB_DEBUG_HEALTH_TICK_SUSPEND): freeze the periodic 500 ms health tick so it never republishes
// the window snapshot. With the tick suspended, a dialog open/respond snapshot can ONLY come from the
// dialog handler's own zb_publish_window_snapshot(), making the "reflect at once" regression deterministic
// (RoseCat ec36aee SHOULD — otherwise a tick can republish between dialog.get and the page.health read and
// mask a missing-handler-publish mutant). Inert without --e2e-protocol.
static BOOL zb_auto_test_health_tick_suspended(void) {
  if (!zb_auto_test_hooks_enabled()) return NO;
  const char *v = getenv("ZB_DEBUG_HEALTH_TICK_SUSPEND");
  return v != NULL && v[0] == '1';
}

// Test-only (ZB_DEBUG_ACK_HANG): the per-pair FIFO ack (issued AFTER the keyUp, while INFLIGHT) never
// resolves, modelling a frozen/dead web process that never acknowledges. The ABI must still return
// bounded at its deadline (the ack is INFLIGHT, abandonable) with the keyUp already delivered (no stuck
// key) — proving DISPATCHING no longer spans an unbounded async (RoseCat 6455). Gated on --e2e-protocol.
static int zb_auto_test_ack_hang(void) {
  if (!zb_auto_test_hooks_enabled()) return 0;
  const char *v = getenv("ZB_DEBUG_ACK_HANG");
  return v != NULL && v[0] != '0' && v[0] != '\0';
}

// Test-only (ZB_DEBUG_PAIR_HOLD_MS): during native typing, pause on the main thread AFTER the per-pair
// ownership transition (reclaim: INFLIGHT -> DISPATCHING) and BEFORE the next pair's keyDown is sent, so
// a red can let the command deadline fall exactly inside that window. Because the transition is atomic
// and the job is DISPATCHING during the hold, zb_job_wait blocks past the deadline, so BOTH pairs are
// delivered within the owned window before the waiter can return — the command then ends in
// action_timeout (the deadline passed during the owned hold) but with data.sent_chars == every pair,
// proving no pair is abandoned and no late event lands in the check->send gap. A check-then-act mutant
// leaves the job INFLIGHT during the hold, so the waiter abandons mid-hold (sent_chars == 1) and the
// next pair lands after give-up: the red then fails (RoseCat 6397.1/6481). Gated on --e2e-protocol.
static void zb_auto_test_pair_hold(void) {
  if (!zb_auto_test_hooks_enabled()) return;
  long ms = zb_parse_nonneg(getenv("ZB_DEBUG_PAIR_HOLD_MS"));
  if (ms <= 0) return;
  if (ms > 60000) ms = 60000;  // clamp, like the dispatch-hold hook
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

// Test-only (ZB_DEBUG_TYPE_DELAY_MS): delay between per-character key events during native typing, so a
// red with a short command timeout deterministically ABANDONS mid-text and proves partial typing
// (sent_chars = code points dispatched). 0/unset = no delay. Gated on --e2e-protocol.
static unsigned int zb_auto_test_type_delay_ms(void) {
  if (!zb_auto_test_hooks_enabled()) return 0;
  long ms = zb_parse_nonneg(getenv("ZB_DEBUG_TYPE_DELAY_MS"));
  if (ms <= 0) return 0;
  if (ms > 60000) ms = 60000;  // clamp, like the dispatch-hold hook
  return (unsigned int)ms;
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

// Test-only (ZB_DEBUG_SYNTH_CRASH): one-shot — after the first real page load, synthesize the web
// process termination callback (webViewWebContentProcessDidTerminate) for the primary window, so a red
// can exercise the crash-presentation path without actually killing a WebContent process (which on a
// shared host cannot be targeted safely with public API). The production handler is unchanged and public;
// this only invokes it. Gated on --e2e-protocol.
static int zb_auto_test_synth_crash(void) {
  if (!zb_auto_test_hooks_enabled()) return 0;
  static atomic_int consumed = 0;
  const char *v = getenv("ZB_DEBUG_SYNTH_CRASH");
  if (v == NULL || v[0] == '0' || v[0] == '\0') return 0;
  return atomic_exchange(&consumed, 1) == 0;  // one-shot: true exactly once
}

// Test-only (ZB_DEBUG_NATIVE_CLOSE_ON_TITLE, 4pa.58): the page title that makes a window close itself
// through -[NSWindow performClose:] (see zbTestNativeCloseIfTitled), so a red can drive the native close
// control without Accessibility/TCC. NULL when unset or without --e2e-protocol. Main thread only.
static const char *zb_auto_test_native_close_title(void) {
  if (!zb_auto_test_hooks_enabled()) return NULL;
  const char *v = getenv("ZB_DEBUG_NATIVE_CLOSE_ON_TITLE");
  return (v != NULL && v[0] != '\0') ? v : NULL;
}

// Test-only (ZB_DEBUG_COOKIE_DELAY_MS, 4pa.56): hold every WKHTTPCookieStore completion this many ms before
// it is handled, so a red can prove a cookie call returns at its deadline when WebKit answers late (the
// socket-drivable form of the GTK zb_automation_debug_cookie_delay seam). -1 when unset, malformed or
// without --e2e-protocol. Main thread only (the store completions run there).
static long zb_auto_test_cookie_delay_ms(void) {
  if (!zb_auto_test_hooks_enabled()) return -1;
  return zb_parse_nonneg(getenv("ZB_DEBUG_COOKIE_DELAY_MS"));
}

// Test-only (ZB_DEBUG_EPHEMERAL_DATA_STORE, hook 16): every window uses ONE non-persistent WKWebsiteDataStore
// instead of the default store or the --profile-dir store (dataStoreForIdentifier). Both of those live in WebKit's
// own location under the account Library, outside any e2e run directory; an ephemeral store writes no website data
// to disk, so a Mac e2e run leaves nothing outside its run root (SilverRidge fe4542e). Inert without
// --e2e-protocol: the decision is zb_hook16_select_store (zb_test_hook_gate.h), probed without AppKit or any WebKit
// store by tests/hook16_decision_test.zig (SilverRidge 8721b6d). Main thread only (read from newConfiguredWebView).
static BOOL zb_auto_test_ephemeral_store(void) {
  return zb_hook16_select_store(zb_auto_test_hooks_enabled()) == ZB_STORE_EPHEMERAL;
}

// Run a cookie-store completion now, or after the e2e-only delay above (printing zb-cookie-delay-hit).
static void zb_cookie_after_test_delay(void (^handle)(void)) {
  long ms = zb_auto_test_cookie_delay_ms();
  if (ms <= 0) { handle(); return; }
  fprintf(stderr, "zb-cookie-delay-hit=%ld\n", ms);
  fflush(stderr);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC), dispatch_get_main_queue(), handle);
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
  if (strncmp(v, "after:", 6) == 0) { long k = zb_parse_nonneg(v + 6); return k >= 0 && n > k; }
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
  int live_after_add = atomic_fetch_add(&zb_auto_live_jobs, 1) + 1;
  if (atomic_load(&zb_auto_e2e_enabled)) { fprintf(stderr, "zb-live-jobs=%d\n", live_after_add); fflush(stderr); }  // e2e-only (atomic, off-main safe): observe the live-job count (MS2a.3 baseline)
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
  zb_auto_free_tracked(job->result);
  zb_auto_free_tracked(job->err);
  free(job);
  int live_after_sub = atomic_fetch_sub(&zb_auto_live_jobs, 1) - 1;
  if (atomic_load(&zb_auto_e2e_enabled)) { fprintf(stderr, "zb-live-jobs=%d\n", live_after_sub); fflush(stderr); }  // e2e-only (atomic, off-main safe): observe the live-job count (MS2a.3 baseline)
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

// Still INFLIGHT (not yet DONE/ABANDONED)? A post-submit watch (e.g. the eval dialog-watch) checks this
// to stop once the submission's own completion has finished the job.
static int zb_job_is_inflight(ZBAutoJob *job) {
  pthread_mutex_lock(&job->mu);
  int ok = (job->state == ZB_JOB_INFLIGHT);
  pthread_mutex_unlock(&job->mu);
  return ok;
}

// Re-own the job for the NEXT side-effect step of a multi-step op: INFLIGHT -> DISPATCHING. Returns 0 if
// the waiter already abandoned (timed out while INFLIGHT). A caller that gets 1 holds the job through
// DISPATCHING, where zb_job_wait blocks WITHOUT a deadline, so the step's side effect (e.g. a keyDown/
// keyUp pair) cannot be interrupted by a concurrent timeout — the check-then-act race is closed because
// ownership transfers atomically under the mutex, not by a check followed by an unguarded send
// (RoseCat 6397.1 / 6433.1). No broadcast: a waiter mid-timedwait sees DISPATCHING on its next check and
// re-waits without a deadline, exactly as after zb_job_claim_dispatch.
static int zb_job_reclaim_dispatch(ZBAutoJob *job) {
  pthread_mutex_lock(&job->mu);
  int ok = (job->state == ZB_JOB_INFLIGHT);
  if (ok) job->state = ZB_JOB_DISPATCHING;
  pthread_mutex_unlock(&job->mu);
  return ok;
}

// Record progress (fully-dispatched code points) in the heap job under the mutex, so a timed-out waiter
// reads a value published under the same lock rather than a stack slot written concurrently off-lock
// (RoseCat 6397 C memory-model note). Written only while the job is owned (DISPATCHING).
static void zb_job_set_progress(ZBAutoJob *job, int n) {
  pthread_mutex_lock(&job->mu);
  job->progress = n;
  pthread_mutex_unlock(&job->mu);
}

static int zb_job_progress(ZBAutoJob *job) {
  pthread_mutex_lock(&job->mu);
  int n = job->progress;
  pthread_mutex_unlock(&job->mu);
  return n;
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
    zb_auto_free_tracked(result);
    zb_auto_free_tracked(err);
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
    if (atomic_load(&zb_auto_loop_ended)) {  // app loop ending: finish this queued job NOW (no late dispatch)
      poll = nil;
      if (zb_job_claim_dispatch(job)) {
        zb_job_complete(job, ZB_AUTO_ERR_NO_LOOP, NULL, NULL);  // cancel path: NO work() runs here
        // Observable (RoseCat 41c683a #3): the drain ran this queued block and cancelled it via the no-loop
        // path, so no WebKit work executed after quit. e2e-gated stderr (atomic, off-main safe) so the
        // immediate-quit test can assert the drain cancelled a live job (not that it timed out or ran work).
        int n = atomic_fetch_add(&zb_auto_loop_cancels, 1) + 1;
        if (atomic_load(&zb_auto_e2e_enabled)) { fprintf(stderr, "zb-loop-cancel=%d\n", n); fflush(stderr); }
      }
      zb_job_unref(job);
      return;
    }
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
      // Count every ACTUAL execution of this readiness work, at the block's entry (RoseCat da7ae1c): the
      // app-ended drain must cancel a queued job via the no-loop path WITHOUT running work. zb-loop-cancel
      // only proves the branch was entered; this proves no work ran. A mutant that calls work() in the
      // loop-ended branch (then discards the result) still invokes THIS block, so it increments here and the
      // immediate-quit test's "work count unchanged across quit" oracle reds. e2e-gated, atomic, off-main safe.
      int w = atomic_fetch_add(&zb_auto_work_runs, 1) + 1;
      if (atomic_load(&zb_auto_e2e_enabled)) { fprintf(stderr, "zb-work-runs=%d\n", w); fflush(stderr); }
      // title reads the page's live document (blocked by an open dialog); url reads no page script.
      if (want_title && [host zbHasOpenDialog]) return ZB_AUTO_ERR_DIALOG_OPEN;
      NSString *value = want_title ? (host.webView.title ?: @"")
                                    : (host.webView.URL.absoluteString ?: @"");
      const char *utf8 = value.UTF8String;
      *result = zb_auto_dup_tracked(utf8);
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

// MS2b.2: every open page dialog as JSON [{window, type, message, default_text?}], the primary window's
// first — the shape automation_*_port.parseDialogs expects. Reads per-window dialog state on the main
// thread (the held dialog blocks the web process, not the main run loop, so this hop is prompt). No page
// script, so it works WHILE a dialog is open.
int zb_automation_list_dialogs(unsigned int timeout_ms, char **out_json) {
  if (out_json != NULL) *out_json = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  // Heap-job model (not a raw semaphore): if the waiter times out first, the job is CANCELLED and the
  // main block's claim fails, so no result is built or leaked; the result is owned by the job and moved
  // out only on DONE (RoseCat 6469: owned result lifetime, no late strdup leak).
  ZBAutoJob *job = zb_job_new();
  if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
  zb_job_ref(job);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }  // waiter abandoned: build nothing
    char *result = NULL;
    @autoreleasepool {
      NSMutableArray<NSDictionary *> *arr = [NSMutableArray array];
      ZBAppHost *app = g_active_app;
      if (app != nil) {
        NSArray<ZBWindowHost *> *hosts = app.windows != nil ? app.windows
                                       : (app.mainWindow != nil ? @[ app.mainWindow ] : @[]);
        [hosts enumerateObjectsUsingBlock:^(ZBWindowHost *h, NSUInteger idx, BOOL *stop) {
          (void)stop;
          if (h == nil || h.pendingDialogKind == 0) return;
          NSString *type = h.pendingDialogKind == 1 ? @"alert"
                         : h.pendingDialogKind == 2 ? @"confirm"
                         : h.pendingDialogKind == 3 ? @"prompt" : @"beforeunload";
          NSMutableDictionary *d = [@{ @"window": @(idx + 1), @"type": type,
                                       @"message": (h.pendingDialogMessage ?: @"") } mutableCopy];
          if (h.pendingDialogKind == 3) d[@"default_text"] = h.pendingDialogDefault ?: @"";
          [arr addObject:d];
        }];
      }
      NSData *data = [NSJSONSerialization dataWithJSONObject:arr options:0 error:NULL];
      NSString *s = data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
      const char *utf8 = s.UTF8String;
      result = zb_auto_dup_tracked(utf8);
    }
    zb_job_complete(job, ZB_AUTO_OK, result, NULL);  // job owns `result`; freed by complete if abandoned
    zb_job_unref(job);
  });
  int rc = zb_job_wait(job, timeout_ms);
  if (rc == ZB_AUTO_OK && out_json != NULL) { *out_json = job->result; job->result = NULL; }  // sole reader on DONE
  zb_job_unref(job);
  return rc;
}

// MS2b.2: answer window `win`'s open dialog (0 = primary). accept = OK/Leave, else Cancel/Stay; `text`
// answers an accepted prompt (NULL = its default). NO_DIALOG when the window has none.
int zb_automation_respond_dialog(uint32_t win, int accept, const char *text, unsigned int timeout_ms) {
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  NSString *answer = text != NULL ? [NSString stringWithUTF8String:text] : nil;
  // Heap-job model: if the waiter timed out (e.g. a held main queue), the job is CANCELLED and the
  // claim below fails, so the dialog is NEVER answered late — no dispatch after abandon (RoseCat 6469).
  ZBAutoJob *job = zb_job_new();
  if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
  zb_job_ref(job);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }  // waiter abandoned: do NOT answer the dialog
    ZBWindowHost *host = zb_auto_window_for_id(win);
    int code = (host != nil && [host zbRespondDialogAccept:(accept != 0) text:answer]) ? ZB_AUTO_OK : ZB_AUTO_ERR_NO_DIALOG;
    zb_job_complete(job, code, NULL, NULL);
    zb_job_unref(job);
  });
  int rc = zb_job_wait(job, timeout_ms);
  zb_job_unref(job);
  return rc;
}

// MS2c: every open window as JSON [{id,url,title,primary,opener,dialog_open,responsive,unresponsive_ms,
// loading,process_group,incident,crashed?}], the primary first — the shape automation_macos_port.parseWindows
// expects. Window id is the STABLE monotonic windowId (never a registry index, never reused; mirrors
// zb_auto_window_for_id); opener is the stable id of the window that opened this one, kept even after the
// opener closes (never retargeted to a surviving window). loading is the real per-window WKWebView load
// state; process_group is the conservative WebContent-process family (the root opener's id, inherited at
// creation) that recover's at_risk set is built from. Heap-job claim/cancel model, so a timed-out caller
// builds/leaks nothing (RoseCat 6469 shape). No page script: works with a dialog open.
// MS2c (RoseCat 6508 #6): rebuild the per-window snapshot and publish it under the lock. MAIN THREAD only
// (reads h.webView etc.); called on every window state change and on each health tick. page.list/page.health
// then read the published JSON without ever marshalling to the main queue.
static void zb_publish_window_snapshot(void) {
  char *json = NULL;
  @autoreleasepool {
    NSMutableArray<NSDictionary *> *arr = [NSMutableArray array];
    ZBAppHost *app = g_active_app;
    if (app != nil) {
      NSArray<ZBWindowHost *> *hosts = app.windows != nil ? app.windows
                                     : (app.mainWindow != nil ? @[ app.mainWindow ] : @[]);
      for (ZBWindowHost *h in hosts) {
        if (h == nil) continue;
        NSString *url = h.webView.URL.absoluteString ?: @"";
        NSString *title = h.webView.title ?: @"";
        BOOL responsive = (h.unresponsiveSinceUs == 0);
        int64_t unresp_ms = responsive ? 0 : (zb_now_us() - h.unresponsiveSinceUs) / 1000;
        NSMutableDictionary *w = [@{ @"id": @(h.windowId),
                          @"url": url,
                          @"title": title,
                          @"primary": (h == app.mainWindow) ? @YES : @NO,  // @YES/@NO -> JSON true/false (a bare @(int) serializes 0/1)
                          @"opener": @(h.openerId),
                          @"dialog_open": (h.pendingDialogKind != 0) ? @YES : @NO,
                          @"responsive": responsive ? @YES : @NO,       // MS2c page.health (watchdog)
                          @"unresponsive_ms": @(unresp_ms),
                          @"loading": (h.webView != nil && h.webView.loading) ? @YES : @NO,  // MS2c: real per-window load state (page.health)
                          @"process_group": @(h.processGroup),           // MS2c: crash blast-radius family (recover at_risk)
                          @"load_serial": @(h.loadSerial),               // MS4.1a: per-window load-commit counter (grant revalidation)
                          @"incident": @(h.incident) } mutableCopy];
        if (h.terminatedReason != nil) w[@"crashed"] = h.terminatedReason;  // MS2c crash parity
        [arr addObject:w];
      }
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:arr options:0 error:NULL];
    NSString *s = data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
    json = strdup(s.UTF8String != NULL ? s.UTF8String : "[]");
  }
  pthread_mutex_lock(&g_window_snapshot_lock);
  g_window_snapshot = (json != NULL) ? [NSString stringWithUTF8String:json] : @"[]";
  pthread_mutex_unlock(&g_window_snapshot_lock);
  free(json);
}

// page.list/page.health answer from the lock-backed snapshot. No main-queue marshal, no wait: a backed-up
// or hung main queue cannot stall these out-of-band reads (RoseCat 6508 #6; plan :822-824). `timeout_ms`
// is unused (nothing to wait on).
int zb_automation_list_windows(unsigned int timeout_ms, char **out_json) {
  (void)timeout_ms;
  if (out_json == NULL) return ZB_AUTO_ERR_INTERNAL;
  *out_json = NULL;
  char *copy = NULL;
  @autoreleasepool {
    pthread_mutex_lock(&g_window_snapshot_lock);
    NSString *snap = g_window_snapshot;
    const char *utf8 = (snap != nil && snap.UTF8String != NULL) ? snap.UTF8String : "[]";
    copy = zb_auto_dup_tracked(utf8);
    pthread_mutex_unlock(&g_window_snapshot_lock);
  }
  if (copy == NULL) return ZB_AUTO_ERR_INTERNAL;
  *out_json = copy;
  return ZB_AUTO_OK;
}

// MS2c: close window `id` (a popup) and return once it is destroyed. The PRIMARY window cannot be closed
// (NO_WINDOW), matching the shared contract (automation_windows_test). NO_WINDOW for an unknown id. Heap-
// job claim/cancel model, so a timed-out caller never destroys a window late.
int zb_automation_close_window(uint32_t id, unsigned int timeout_ms) {
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  ZBAutoJob *job = zb_job_new();
  if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
  zb_job_ref(job);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }  // waiter abandoned: don't close late
    ZBAppHost *app = g_active_app;
    ZBWindowHost *host = zb_auto_window_for_id(id);
    int code;
    if (host == nil || app == nil) {
      code = ZB_AUTO_ERR_NO_WINDOW;
    } else if (host == app.mainWindow) {
      code = ZB_AUTO_ERR_NO_WINDOW;  // the primary window cannot be closed by automation
    } else {
      [host close];              // tears down delegates, health timer, answers any held dialog, orders out
      [app removeWindow:host];   // drop from the registry; ARC frees the window
      code = ZB_AUTO_OK;
    }
    zb_job_complete(job, code, NULL, NULL);
    zb_job_unref(job);
  });
  int rc = zb_job_wait(job, timeout_ms);
  zb_job_unref(job);
  return rc;
}

// MS2c view-replacement recovery: for each id, swap in a fresh WKWebView keeping the stable id and reload
// the committed URL (public API; no process kill, no SPI). Emits [{id,url,ended,reloaded}, ...] in `ids`
// order: `ended` = the window was crashed (its web process already gone); `reloaded` = a committed URL was
// restored. Heap-job claim/cancel, so a timed-out caller leaves nothing dangling. Main-thread work.
int zb_automation_recover_windows(const uint32_t *ids, int n, unsigned int timeout_ms, char **out_json) {
  if (out_json != NULL) *out_json = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  if (ids == NULL || n <= 0) return ZB_AUTO_ERR_INTERNAL;
  uint32_t *ids_copy = malloc((size_t)n * sizeof(uint32_t));  // the block owns this (freed inside it)
  if (ids_copy == NULL) return ZB_AUTO_ERR_INTERNAL;
  memcpy(ids_copy, ids, (size_t)n * sizeof(uint32_t));
  ZBAutoJob *job = zb_job_new();
  if (job == NULL) { free(ids_copy); return ZB_AUTO_ERR_INTERNAL; }
  zb_job_ref(job);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!zb_job_claim_dispatch(job)) { free(ids_copy); zb_job_unref(job); return; }  // waiter abandoned
    char *result = NULL;
    @autoreleasepool {
      NSMutableArray<NSDictionary *> *arr = [NSMutableArray array];
      for (int i = 0; i < n; i++) {
        uint32_t wid = ids_copy[i];
        ZBWindowHost *host = zb_auto_window_for_id(wid);
        NSString *url = @"";
        BOOL ended = NO, reloaded = NO;
        if (host != nil) {
          ended = (host.terminatedReason != nil);  // a crashed window's process is already gone
          NSString *u = [host recoverByReplacingWebView];
          if (u != nil) { url = u; reloaded = YES; }
        }
        [arr addObject:@{ @"id": @(wid), @"url": url,
                          @"ended": ended ? @YES : @NO, @"reloaded": reloaded ? @YES : @NO }];
      }
      NSData *data = [NSJSONSerialization dataWithJSONObject:arr options:0 error:NULL];
      NSString *s = data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
      const char *utf8 = s.UTF8String;
      result = zb_auto_dup_tracked(utf8);
    }
    free(ids_copy);
    zb_job_complete(job, ZB_AUTO_OK, result, NULL);
    zb_job_unref(job);
  });
  int rc = zb_job_wait(job, timeout_ms);
  if (rc == ZB_AUTO_OK && out_json != NULL) { *out_json = job->result; job->result = NULL; }
  zb_job_unref(job);
  return rc;
}

// ---- MS3 cookies (WKHTTPCookieStore) ----
// The cookie store is the primary window's WKWebView data store (the profile's). All ops run on the main
// thread via the heap-job model; the WKHTTPCookieStore callbacks are async, so the job holds one extra ref
// across the callback (released at its single terminal). Cookie VALUES never appear in error text or logs.

static WKHTTPCookieStore *zb_cookie_store(void) {
  ZBAppHost *app = g_active_app;
  ZBWindowHost *w = (app != nil) ? app.mainWindow : nil;
  if (w == nil || w.webView == nil) return nil;
  return w.webView.configuration.websiteDataStore.httpCookieStore;
}

static NSDictionary *zb_cookie_to_dict(NSHTTPCookie *ck) {
  long long expires = -1;  // session cookie
  if (ck.expiresDate != nil) expires = (long long)llround(ck.expiresDate.timeIntervalSince1970);
  NSMutableDictionary *d = [@{ @"name": ck.name ?: @"",
                               @"value": ck.value ?: @"",
                               @"domain": ck.domain ?: @"",
                               @"path": ck.path ?: @"/",
                               @"expires": @(expires),
                               @"httpOnly": ck.HTTPOnly ? @YES : @NO,
                               @"secure": ck.secure ? @YES : @NO } mutableCopy];
  if (@available(macOS 10.15, *)) {
    NSString *p = ck.sameSitePolicy;
    if ([p isEqualToString:NSHTTPCookieSameSiteLax]) d[@"sameSite"] = @"Lax";
    else if ([p isEqualToString:NSHTTPCookieSameSiteStrict]) d[@"sameSite"] = @"Strict";
  }
  return d;
}

// Would `ck` be sent to `url`? Domain (leading dot = domain cookie), path prefix, and the secure flag.
static BOOL zb_cookie_matches_url(NSHTTPCookie *ck, NSURL *url) {
  NSString *host = url.host ?: @"";
  NSString *cd = ck.domain ?: @"";
  BOOL domain_ok;
  if ([cd hasPrefix:@"."]) {
    NSString *bare = [cd substringFromIndex:1];
    domain_ok = [host caseInsensitiveCompare:bare] == NSOrderedSame ||
                [host hasSuffix:[@"." stringByAppendingString:bare]];
  } else {
    domain_ok = [host caseInsensitiveCompare:cd] == NSOrderedSame;
  }
  if (!domain_ok) return NO;
  NSString *path = url.path.length > 0 ? url.path : @"/";
  if (![path hasPrefix:(ck.path ?: @"/")]) return NO;
  if (ck.secure && ![url.scheme isEqualToString:@"https"]) return NO;
  return YES;
}

int zb_cookies_get_all(uint32_t win, const char *url, unsigned int timeout_ms, char **out_json, char **out_err) {
  (void)win;  // always the primary window's (profile's) store
  if (out_json != NULL) *out_json = NULL;
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  NSString *url_str = (url != NULL && url[0] != '\0') ? [NSString stringWithUTF8String:url] : nil;
  ZBAutoJob *job = zb_job_new();
  if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
  zb_job_ref(job);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }  // waiter abandoned
    WKHTTPCookieStore *store = zb_cookie_store();
    if (store == nil) { zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
    NSURL *filter = (url_str != nil) ? [NSURL URLWithString:url_str] : nil;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) { zb_cookie_after_test_delay(^{
      char *result = NULL;
      @autoreleasepool {
        NSMutableArray<NSDictionary *> *arr = [NSMutableArray array];
        for (NSHTTPCookie *ck in cookies) {
          if (filter != nil && !zb_cookie_matches_url(ck, filter)) continue;
          [arr addObject:zb_cookie_to_dict(ck)];
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:arr options:0 error:NULL];
        NSString *s = data != nil ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
        result = zb_auto_dup_tracked(s.UTF8String);
      }
      zb_job_complete(job, ZB_AUTO_OK, result, NULL);
      zb_job_unref(job);
    }); }];
  });
  int rc = zb_job_wait(job, timeout_ms);
  if (rc == ZB_AUTO_OK && out_json != NULL) { *out_json = job->result; job->result = NULL; }
  zb_job_unref(job);
  return rc;
}

int zb_cookies_add(uint32_t win, const ZbCookie *cookie, unsigned int timeout_ms, char **out_err) {
  (void)win;
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  if (cookie == NULL) return ZB_AUTO_ERR_INTERNAL;
  if (cookie->expires < -1 || cookie->expires > ZB_COOKIE_MAX_EXPIRES) return ZB_AUTO_ERR_INTERNAL;
  // Copy every field before queuing (the caller's ZbCookie is borrowed).
  NSString *name = [NSString stringWithUTF8String:(cookie->name ?: "")];
  NSString *value = [NSString stringWithUTF8String:(cookie->value ?: "")];
  NSString *domain = [NSString stringWithUTF8String:(cookie->domain ?: "")];
  NSString *path = [NSString stringWithUTF8String:(cookie->path ?: "/")];
  long long expires = cookie->expires;
  BOOL http_only = cookie->http_only != 0;
  BOOL secure = cookie->secure != 0;
  int same_site = cookie->same_site;
  ZBAutoJob *job = zb_job_new();
  if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
  zb_job_ref(job);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }
    WKHTTPCookieStore *store = zb_cookie_store();
    if (store == nil) { zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
    NSMutableDictionary *props = [@{ NSHTTPCookieName: name,
                                     NSHTTPCookieValue: value,
                                     NSHTTPCookieDomain: domain,
                                     NSHTTPCookiePath: path } mutableCopy];
    if (expires >= 0) props[NSHTTPCookieExpires] = [NSDate dateWithTimeIntervalSince1970:(double)expires];
    if (secure) props[NSHTTPCookieSecure] = @"TRUE";
    if (http_only) props[@"HttpOnly"] = @"YES";  // not a public key, but honored by NSHTTPCookie
    if (@available(macOS 10.15, *)) {
      if (same_site == ZB_COOKIE_SAME_SITE_LAX) props[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteLax;
      else if (same_site == ZB_COOKIE_SAME_SITE_STRICT) props[NSHTTPCookieSameSitePolicy] = NSHTTPCookieSameSiteStrict;
    }
    NSHTTPCookie *ck = [NSHTTPCookie cookieWithProperties:props];
    if (ck == nil) { zb_job_complete(job, ZB_AUTO_ERR_INTERNAL, NULL, NULL); zb_job_unref(job); return; }
    [store setCookie:ck completionHandler:^{ zb_cookie_after_test_delay(^{
      zb_job_complete(job, ZB_AUTO_OK, NULL, NULL);
      zb_job_unref(job);
    }); }];
  });
  int rc = zb_job_wait(job, timeout_ms);
  zb_job_unref(job);
  return rc;
}

int zb_cookies_delete(uint32_t win, const char *name, const char *domain, unsigned int timeout_ms, char **out_err) {
  (void)win;
  if (out_err != NULL) *out_err = NULL;
  if ([NSThread isMainThread]) return ZB_AUTO_ERR_INTERNAL;
  if (name == NULL) return ZB_AUTO_ERR_INTERNAL;
  NSString *want_name = [NSString stringWithUTF8String:name];
  NSString *want_domain = (domain != NULL && domain[0] != '\0') ? [NSString stringWithUTF8String:domain] : nil;
  ZBAutoJob *job = zb_job_new();
  if (job == NULL) return ZB_AUTO_ERR_INTERNAL;
  zb_job_ref(job);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }
    WKHTTPCookieStore *store = zb_cookie_store();
    if (store == nil) { zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) { zb_cookie_after_test_delay(^{
      NSMutableArray<NSHTTPCookie *> *doomed = [NSMutableArray array];
      for (NSHTTPCookie *ck in cookies) {
        if (![ck.name isEqualToString:want_name]) continue;
        if (want_domain != nil) {
          NSString *a = [want_domain hasPrefix:@"."] ? [want_domain substringFromIndex:1] : want_domain;
          NSString *b = [ck.domain hasPrefix:@"."] ? [ck.domain substringFromIndex:1] : (ck.domain ?: @"");
          if ([a caseInsensitiveCompare:b] != NSOrderedSame) continue;
        }
        [doomed addObject:ck];
      }
      if (doomed.count == 0) {  // deleting nothing is not an error
        zb_job_complete(job, ZB_AUTO_OK, NULL, NULL);
        zb_job_unref(job);
        return;
      }
      __block NSUInteger remaining = doomed.count;  // decremented only on the (serial) main queue
      for (NSHTTPCookie *ck in doomed) {
        [store deleteCookie:ck completionHandler:^{
          if (--remaining == 0) {
            zb_job_complete(job, ZB_AUTO_OK, NULL, NULL);
            zb_job_unref(job);
          }
        }];
      }
    }); }];
  });
  int rc = zb_job_wait(job, timeout_ms);
  zb_job_unref(job);
  return rc;
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
  // before_unload is UNSUPPORTED on macOS and cannot be honored through public API (MS2b.2 probe,
  // 2026-10-20): WKWebView surfaces NO beforeunload prompt to any WKUIDelegate method (even with a user
  // gesture), so there is no prompt to accept/dismiss and no way to return the shared contract's
  // DialogOpen-and-leave-prompt-open for FAIL — a navigate away from a page with a beforeunload handler
  // just loads here. The Zig port rejects accept/dismiss as error.Unsupported; FAIL reaches here and
  // proceeds. A documented cross-platform divergence (plan :339/:732), pending the private-API decision.
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
  return zb_auto_dup_tracked(utf8);
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
      poll = nil;  // ready
      // A page dialog open on this window blocks its web process; eval would hang, so fail fast.
      if ([host zbHasOpenDialog]) {
        if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_DIALOG_OPEN, NULL, NULL);
        zb_job_unref(job);
        return;
      }
      // claim for submission (PREFLIGHT->DISPATCHING), then run the async eval.
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
          zb_job_complete(job, ZB_AUTO_ERR_JS, NULL, zb_auto_dup_tracked(m != NULL ? m : "evaluation failed"));
        } else {
          zb_job_complete(job, ZB_AUTO_OK, zb_auto_result_string(value), NULL);
        }
        zb_job_unref(job);
      }];
      zb_job_inflight(job);  // submission issued on the main thread: DISPATCHING -> INFLIGHT, release waiter
      // Dialog-watch: if the script opens a page dialog, its completion can never come back (the web
      // process blocks in the dialog), so this eval would hang until its deadline and wedge the serial
      // socket. Watch for a dialog appearing while INFLIGHT and finish the eval promptly with
      // DIALOG_OPEN (the held completion later no-ops on the DONE job). Its own ref outlives the watch.
      zb_job_ref(job);
      __block void (^dlgwatch)(void) = nil;
      dlgwatch = ^{
        if (!zb_job_is_inflight(job)) { dlgwatch = nil; zb_job_unref(job); return; }  // eval already settled
        ZBWindowHost *h = zb_auto_window_for_id(win);
        if (h != nil && [h zbHasOpenDialog]) { zb_job_complete(job, ZB_AUTO_ERR_DIALOG_OPEN, NULL, NULL); dlgwatch = nil; zb_job_unref(job); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), dlgwatch);
      };
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_MSEC)), dispatch_get_main_queue(), dlgwatch);
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
      if ([host zbHasOpenDialog]) {  // an open dialog blocks the web process: fail fast, no input
        deliver = nil;
        if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_DIALOG_OPEN, NULL, NULL);
        zb_job_unref(job);
        return;
      }
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

// Deliver `events` as consecutive keyDown/keyUp PAIRS (two events each; a modifier key is a
// flagsChanged press/release pair). Each pair is ONE indivisible side-effect step: both of its events
// are sent while the job is DISPATCHING — a window in which zb_job_wait blocks without a deadline — so a
// concurrent timeout can never split a keyDown from its keyUp (no stuck-down key) nor deliver an event
// after the waiter gave up (RoseCat 6397.1/6397.2). After the pair's input is processed it is FIFO-acked
// by a round trip (synthetic keys otherwise drop/coalesce through the input method); when `expected` is
// non-nil the ack doubles as a per-code-point documentToken RECHECK (RoseCat 6361.1) — a pair that
// navigated the page stops the sequence with DOC_CHANGED before the next pair enters the replacement
// document. Progress is the count of pairs fully dispatched (= code points), published in the heap job
// under the mutex. Called in DISPATCHING (claim already done); owns the chain ref: completes + unrefs
// exactly once. Precondition: events.count is even (whole pairs).
static void zb_deliver_events_paced(NSWindow *window, WKWebView *view, ZBAutoJob *job, NSString *expected,
                                    NSArray<NSEvent *> *events) {
  NSUInteger nPairs = events.count / 2;
  if (nPairs == 0) {
    [view evaluateJavaScript:@"0" completionHandler:^(id v, NSError *e) { (void)v; zb_job_complete(job, e != nil ? ZB_AUTO_ERR_JS : ZB_AUTO_OK, NULL, NULL); zb_job_unref(job); }];
    zb_job_inflight(job);
    return;
  }
  WKContentWorld *autoWorld = (expected != nil) ? [WKContentWorld worldWithName:@ZB_AUTOMATION_WORLD] : nil;
  // Precondition on entry to deliverPair(p): the job is DISPATCHING (p == 0 from the deliver block's
  // claim; p > 0 from the reclaim in `advance`). The keyDown/keyUp pair is delivered as a GUARANTEED
  // next-main-queue dispatch — keyDown this turn, keyUp the next — with NO WebView callback in between,
  // so the span DISPATCHING covers is bounded by the main run loop, never by the web process (the
  // separate turn also lets the input method process the keyDown before the keyUp, which same-turn
  // delivery coalesces). Only AFTER both events are sent does the job go INFLIGHT, and only then is the
  // FIFO ack / documentToken recheck issued — a WebView round trip the deadline MAY abandon. So a frozen
  // web process times the ack out (bounded return) and never leaves a key stuck down, since the keyUp
  // was already delivered before INFLIGHT (RoseCat 6455: DISPATCHING must not span an unbounded async).
  __block void (^deliverPair)(NSUInteger) = nil;
  deliverPair = ^(NSUInteger p) {
    NSUInteger base = p * 2;
    void (^afterAck)(NSString *, NSError *) = ^(NSString *tok, NSError *e) {  // INFLIGHT: deadline may have abandoned
      if (e != nil) { deliverPair = nil; zb_job_complete(job, ZB_AUTO_ERR_JS, NULL, NULL); zb_job_unref(job); return; }
      if (expected != nil) {  // per-code-point documentToken recheck (after the pair's input is processed)
        NSString *t = tok;
        if (zb_auto_test_stale_token()) t = @"zb-debug-stale-token";
        if (t == nil || ![t isEqualToString:expected]) { deliverPair = nil; zb_job_complete(job, ZB_AUTO_ERR_DOC_CHANGED, NULL, NULL); zb_job_unref(job); return; }
      }
      if (p + 1 >= nPairs) { deliverPair = nil; zb_job_complete(job, ZB_AUTO_OK, NULL, NULL); zb_job_unref(job); return; }
      unsigned int delay = zb_auto_test_type_delay_ms();  // test-only inter-pair delay
      void (^advance)(void) = ^{
        if (deliverPair == nil) return;
        // Re-own atomically before the next pair's first send: if the waiter abandoned (timed out while
        // INFLIGHT, possibly during the delay or a hung ack) this returns 0 and we stop WITHOUT sending.
        if (!zb_job_reclaim_dispatch(job)) { deliverPair = nil; zb_job_unref(job); return; }
        zb_auto_test_pair_hold();  // e2e: hold INSIDE the owned (DISPATCHING) window; the waiter must not abandon here
        deliverPair(p + 1);
      };
      if (delay > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_MSEC), dispatch_get_main_queue(), advance);
      else advance();
    };
    // keyUp on the next main-queue turn, STILL DISPATCHING; then INFLIGHT, then the abandonable ack.
    void (^upStep)(void) = ^{
      [window sendEvent:events[base + 1]];     // keyUp / flags-release
      zb_job_set_progress(job, (int)(p + 1));  // this code point is fully dispatched (both events sent)
      zb_job_inflight(job);                    // DISPATCHING -> INFLIGHT: the pair is delivered; release the waiter
      if (zb_auto_test_ack_hang()) {
        // e2e: model a frozen/dead web process whose ack NEVER arrives. Issue no ack and never run
        // afterAck; the job stays INFLIGHT, so the deadline abandons it and the ABI returns bounded — the
        // keyUp was already delivered (no stuck key). Release the chain ref now (afterAck won't). OS-
        // independent: no reliance on JS that some WebKit versions resolve/throw early.
        deliverPair = nil;
        zb_job_unref(job);
        return;
      }
      if (expected != nil) {
        [view callAsyncJavaScript:@"return globalThis.__zbAutomation ? globalThis.__zbAutomation.documentToken : null;"
                        arguments:@{} inFrame:nil inContentWorld:autoWorld
                completionHandler:^(id v, NSError *e2) { afterAck([v isKindOfClass:[NSString class]] ? (NSString *)v : nil, e2); }];
      } else {
        [view evaluateJavaScript:@"0" completionHandler:^(id v, NSError *e2) { (void)v; afterAck(nil, e2); }];
      }
    };
    [window sendEvent:events[base]];           // keyDown / flags-press (DISPATCHING)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(16 * NSEC_PER_MSEC)), dispatch_get_main_queue(), upStep);
  };
  deliverPair(0);
}

// Shared phase-model driver: run the readiness poll + (optional) documentToken guard in PREFLIGHT, then
// call deliver(host, job) once ready and the guard passes. `deliver` OWNS the chain ref from that point
// (it must zb_job_claim_dispatch, do the side effect, zb_job_inflight, FIFO-ack -> zb_job_complete, and
// zb_job_unref). The driver handles every non-deliver terminal itself. Mirrors zb_native_click.
static int zb_auto_native_input(uint32_t win, NSString *expected, unsigned int timeout_ms,
                                int *out_progress, void (^deliver)(ZBWindowHost *host, ZBAutoJob *job)) {
  if (out_progress != NULL) *out_progress = 0;
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
    if ([host zbHasOpenDialog]) {  // an open dialog blocks the web process: fail fast, no input
      dlv = nil;
      if (zb_job_claim_dispatch(job)) zb_job_complete(job, ZB_AUTO_ERR_DIALOG_OPEN, NULL, NULL);
      zb_job_unref(job);
      return;
    }
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
  // Published under job->mu by zb_job_set_progress; read here under the same lock, after the waiter has
  // settled (DONE or ABANDONED), so a partial-timeout reports exactly the code points fully dispatched.
  if (out_progress != NULL) *out_progress = zb_job_progress(job);
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
    int releases = 0;
    int rc = zb_auto_native_input(win, expected, timeout_ms, &releases, ^(ZBWindowHost *host, ZBAutoJob *job) {
      if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }
      NSWindow *window = host.window;
      WKWebView *view = host.webView;
      if (window == nil || view == nil) { zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
      NSMutableArray<NSEvent *> *events = [NSMutableArray array];
      zb_build_key_events(window, kind, kc, chars, modFlag, flags, events);
      zb_deliver_events_paced(window, view, job, nil, events);  // no per-key recheck (a single key may intentionally navigate, e.g. Enter)
    });
    if (out_releases != NULL) *out_releases = releases;  // keyDown/keyUp pairs acknowledged (= 1 for a key)
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
    int sent = 0;
    int rc = zb_auto_native_input(win, expected, timeout_ms, &sent, ^(ZBWindowHost *host, ZBAutoJob *job) {
      if (!zb_job_claim_dispatch(job)) { zb_job_unref(job); return; }
      NSWindow *window = host.window;
      WKWebView *view = host.webView;
      if (window == nil || view == nil) { zb_job_complete(job, ZB_AUTO_ERR_NO_WINDOW, NULL, NULL); zb_job_unref(job); return; }
      NSMutableArray<NSEvent *> *events = [NSMutableArray array];
      for (NSString *cp in cps) zb_build_key_events(window, ZB_KEY_CHAR, 0, cp, 0, 0, events);
      // Each code point is one keyDown/keyUp pair; deliver_events_paced publishes the count of pairs
      // fully dispatched, so a mid-text timeout or document change leaves `sent` at exactly the code
      // points that landed before it stopped (never a half pair).
      zb_deliver_events_paced(window, view, job, expected, events);  // per-char documentToken recheck (6361.1)
    });
    if (out_chars != NULL) *out_chars = sent;
    if (out_releases != NULL) *out_releases = sent;
    return rc;
  }
}

// MS3.1: a deterministic UUID from the profile path (SHA-256 of the normalized path -> first 16 bytes,
// RFC4122 v4 version/variant bits set so dataStoreForIdentifier accepts it). Same path -> same UUID -> same store.
static NSUUID *zb_uuid_from_path(NSString *path) {
  // A collision-resistant digest of the NORMALIZED path (RoseCat 6608 #1): SHA-256, first 16 bytes, with
  // the RFC4122 v4 version/variant bits set so dataStoreForIdentifier accepts it. Same path -> same UUID.
  const char *s = path.UTF8String ?: "";
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(s, (CC_LONG)strlen(s), digest);
  uuid_t b;
  memcpy(b, digest, 16);
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  return [[NSUUID alloc] initWithUUIDBytes:b];
}

// MS3.1: whether per-profile isolated persistence (dataStoreForIdentifier) is available. macOS 14+, minus
// the e2e-only ZB_DEBUG_FORCE_PRE_MACOS14 seam that forces the macOS-13 fallback on a newer host for test.
static BOOL zb_profile_identifier_available(void) {
  if (zb_auto_test_hooks_enabled()) {
    const char *v = getenv("ZB_DEBUG_FORCE_PRE_MACOS14");
    if (v != NULL && v[0] == '1') return NO;
  }
  if (@available(macOS 14.0, *)) return YES;
  return NO;
}

// MS3.1: record the profile path (the identity seed). The actual store is resolved lazily (see
// zb_resolve_profile_store, called from newConfiguredWebView). dir NULL/empty = default store. No directory
// is created (the store lives in WebKit's managed location). Always OK on macOS.
int zb_app_set_profile_dir(const char *dir, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  g_profile_data_store = nil;
  g_profile_resolved = NO;
  g_profile_dir = nil;
  if (dir == NULL || dir[0] == '\0') return ZB_AUTO_OK;
  NSString *path = [NSString stringWithUTF8String:dir];
  if (path == nil) {  // not valid UTF-8: FAIL CLOSED (never silently fall back to the shared store — RoseCat 6608 #1)
    // This error is a caller-returned C string freed via zb_automation_free (app.zig applyProfileDir), so it
    // MUST be accounted like every other returned string — a plain strdup would decrement the balance on free
    // with no matching increment, driving the ownership counter negative (RoseCat 6798 #2).
    if (out_err != NULL) *out_err = zb_auto_dup_tracked("--profile-dir is not valid UTF-8");
    return ZB_AUTO_ERR_INTERNAL;
  }
  // RoseCat 6625: bind a RELATIVE --profile-dir to the STARTUP CWD before the digest. The CLI accepts a
  // relative spelling (cli.zig), and Linux resolves it to a concrete directory; without binding, the same
  // spelling from two CWDs would share one managed store (an isolation leak) and an absolute spelling would
  // split from its equivalent relative spelling. ~ expansion is lexical (NSHomeDirectory, no filesystem
  // access); the CWD read is the process's startup working directory.
  NSString *expanded = [path stringByExpandingTildeInPath];
  if (![expanded isAbsolutePath]) {
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    expanded = [cwd stringByAppendingPathComponent:expanded];
  }
  // Collapse "." / ".." LEXICALLY only — no symlink resolution, no existence dependency (RoseCat 6625):
  // fileURLWithPath:isDirectory: does not touch the filesystem, and URLByStandardizingPath is purely lexical.
  NSString *norm = [[NSURL fileURLWithPath:expanded isDirectory:NO] URLByStandardizingPath].path;
  g_profile_dir = norm ?: expanded;  // a stable, CWD-bound, lexically-normalized profile identity
  return ZB_AUTO_OK;
}

// MS3.1: resolve the profile store once, at the first webView — macOS 14+ -> an isolated persistent store
// keyed by the path; macOS 13 (or the forced seam) -> the default (shared) store, with one stderr line that
// isolation needs macOS 14. Runs with g_active_app set, so the e2e availability seam is readable.
static void zb_resolve_profile_store(void) {
  if (g_profile_resolved) return;
  if (zb_auto_test_ephemeral_store()) {  // e2e-only hook 16: nothing on disk, with or without --profile-dir
    g_profile_resolved = YES;
    g_profile_data_store = [WKWebsiteDataStore nonPersistentDataStore];
    fprintf(stderr, "zb-data-store=ephemeral\n");
    fflush(stderr);
    return;
  }
  if (g_profile_dir == nil) return;
  g_profile_resolved = YES;
  if (zb_profile_identifier_available()) {
    if (@available(macOS 14.0, *)) {
      g_profile_data_store = [WKWebsiteDataStore dataStoreForIdentifier:zb_uuid_from_path(g_profile_dir)];
    }
  } else {
    fprintf(stderr, "zigBrowser: per-profile isolation needs macOS 14; --profile-dir uses the shared default store on this macOS\n");
  }
}

// MS3.2 backend-flag startup setters/getters. Called from webkit.applyBackendFlag before zb_app_run;
// void setters (no error channel — the supported/unsupported decision is upstream in backendFlagDecision).
void zb_app_set_media_source(int enabled) { g_media_source_enabled = enabled ? 1 : 0; }
int zb_app_get_media_source(void) { return g_media_source_enabled; }
void zb_app_set_hw_policy(int policy) { g_hw_policy = policy; }
int zb_app_get_hw_policy(void) { return g_hw_policy; }

// MS2a.3 part C (RoseCat 6767): the app run loop is ending. Mark it so readiness polls finish their queued
// jobs with NO_LOOP, then DRAIN the pending main-queue blocks (bounded) so each queued block runs that branch
// and unrefs — a block the stopped loop can no longer run is released here, so live jobs reach 0 (not leak).
// No force-unref (each block unrefs itself), so no double-unref.
static void zb_auto_on_loop_ended(void) {
  atomic_store(&zb_auto_loop_ended, 1);
  for (int i = 0; i < 200 && atomic_load(&zb_auto_live_jobs) > 0; i++) {
    @autoreleasepool { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true); }
  }
}

// Test-only (ZB_DEBUG_QUIT_AFTER_MS, inert without --e2e-protocol): after N ms end the run loop with work in
// flight, so the immediate-quit test can prove the waiter wakes (NO_LOOP), no post-quit dispatch, live jobs 0.
// The hook ONLY stops and wakes the loop — it does NOT drain. Draining is the PRODUCTION path's job
// (zb_auto_on_loop_ended after [application run] returns), so a test that would pass only because the hook
// drained is impossible: delete the production drain and the waiter never wakes -> the test reds (RoseCat
// 41c683a #1).
static void *zb_auto_test_quit_thread(void *arg) {
  unsigned int ms = (unsigned int)(uintptr_t)arg;
  usleep((useconds_t)ms * 1000);
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp stop:nil];  // end [application run]; the post-run production drain cancels + wakes the queued job
    NSEvent *wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                                  modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
    [NSApp postEvent:wake atStart:YES];  // force [NSApp run] to notice the stop promptly
  });
  return NULL;
}

static void zb_auto_test_schedule_quit(void) {
  if (!zb_auto_test_hooks_enabled()) return;  // main thread (called from zb_app_run): safe to read g_active_app
  const char *v = getenv("ZB_DEBUG_QUIT_AFTER_MS");
  if (v == NULL) return;
  long ms = strtol(v, NULL, 10);
  if (ms <= 0) return;
  if (ms > 60000) ms = 60000;
  pthread_t t;
  if (pthread_create(&t, NULL, zb_auto_test_quit_thread, (void *)(uintptr_t)ms) == 0) pthread_detach(t);
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
      zb_publish_window_snapshot();  // RoseCat 6556: a read after the app clears gets [], never a stale live snapshot
      return ZB_EXIT_WEBVIEW_INIT_FAILED;
    }
    ZBWindowHost *window_host = (__bridge ZBWindowHost *)window->host;
    [window_host loadURI:uri_text];

    zb_auto_test_schedule_quit();  // e2e-only: arm ZB_DEBUG_QUIT_AFTER_MS (immediate-quit test)
    [application run];
    zb_auto_on_loop_ended();  // app loop ended: drain queued jobs so their refs release (no leak)

    signal(SIGINT, SIG_DFL);
    signal(SIGTERM, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    g_active_app = nil;
    zb_publish_window_snapshot();  // RoseCat 6556: a read after the app clears gets [], never a stale live snapshot
    application.delegate = nil;
    return host.exitCode;
  }
}

int zb_run_open(const char *uri, int print_title) {
  return zb_app_run(uri, print_title, 0);
}

int zb_run_screenshot(const char *uri, const char *out_path, int print_title, int e2e_protocol) {
  (void)e2e_protocol;  // no forced-failure seam on the WKWebView capture path; the bit is Windows-only
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
  ZBWindowHost *window = [host createWindowWithWebView:webView child:host.windows.count > 0 uri:nil opener:nil];
  return window != nil ? window.cWindow : NULL;
}
