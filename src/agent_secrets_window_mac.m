/* Native macOS Secrets window for the Claude Agent drawer. The window is an
 * AppKit-owned product surface, never a web view or automation window. */
#import <AppKit/AppKit.h>

#include "agent_drawer_mac.h"
#include "agent_helper_mac.h"
#include "agent_secrets_mac.h"
#include "agent_spawn_posix.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern int zb_mac_drawer_e2e_enabled(void);
extern void zb_drawer_agent_status(unsigned int window_id, const char *state, const char *reason);

static const NSUInteger ZBMacLoginLineMax = 4096;
static const NSUInteger ZBMacLoginTokenMax = 512;
static const char *const ZBMacLoginTestService = "dev.zigbrowser.ClaudeAgentLoginTest";
static NSString *const ZBMacFirstRunSetupText =
    @"Setting up the Claude Agent (first time, about a minute)...";
static const char *const ZBMacPythonBoot =
    "import runpy,sys;sys.path.insert(0,sys.argv.pop(1));"
    "runpy.run_module('zb_agent_host',run_name='__main__',alter_sys=True)";

static void zb_close_login_fd(int *fd) {
  if (*fd >= 0) close(*fd);
  *fd = -1;
}

/* The login helper owns fd 4, so every pipe source must be above it before
 * posix_spawn file actions are assembled. */
static int zb_login_pipe(int fds[2]) {
  if (pipe(fds) != 0) return errno;
  for (int i = 0; i < 2; ++i) {
    if (fds[i] <= 4) {
      int moved = fcntl(fds[i], F_DUPFD_CLOEXEC, 5);
      if (moved < 0) {
        int saved = errno;
        close(fds[0]);
        close(fds[1]);
        fds[0] = fds[1] = -1;
        return saved;
      }
      close(fds[i]);
      fds[i] = moved;
    } else {
      int flags = fcntl(fds[i], F_GETFD);
      if (flags < 0 || fcntl(fds[i], F_SETFD, flags | FD_CLOEXEC) != 0) {
        int saved = errno;
        close(fds[0]);
        close(fds[1]);
        fds[0] = fds[1] = -1;
        return saved;
      }
    }
  }
  return 0;
}

static void zb_wipe_data(NSMutableData *data) {
  if (data.length > 0) memset_s(data.mutableBytes, data.length, 0, data.length);
  [data setLength:0];
}

static BOOL zb_write_secrets_snapshot(NSWindow *window, NSString *path) {
  if (window == nil || path.length == 0 || !path.isAbsolutePath) return NO;
  NSView *view = window.contentView.superview ?: window.contentView;
  if (view == nil || NSIsEmptyRect(view.bounds)) return NO;
  [window displayIfNeeded];
  [view layoutSubtreeIfNeeded];

  NSBitmapImageRep *cached = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
  if (cached == nil) return NO;
  [view cacheDisplayInRect:view.bounds toBitmapImageRep:cached];
  NSInteger width = cached.pixelsWide;
  NSInteger height = cached.pixelsHigh;
  if (width <= 0 || height <= 0 || cached.CGImage == NULL) return NO;

  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  if (colorSpace == NULL) return NO;
  CGContextRef context = CGBitmapContextCreate(NULL, (size_t)width, (size_t)height,
                                               8, 0, colorSpace,
                                               (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(colorSpace);
  if (context == NULL) return NO;

  [window.effectiveAppearance performAsCurrentDrawingAppearance:^{
    NSColor *color = [window.backgroundColor ?: NSColor.windowBackgroundColor
        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGContextSetRGBFillColor(context, color.redComponent, color.greenComponent,
                             color.blueComponent, 1.0);
  }];
  CGContextFillRect(context, CGRectMake(0, 0, width, height));
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), cached.CGImage);
  CGImageRef composite = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  if (composite == NULL) return NO;
  NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:composite];
  CGImageRelease(composite);
  NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return png != nil && [png writeToFile:path options:NSDataWritingAtomic error:nil];
}

@interface ZBMacSecretsWindowController : NSWindowController <NSWindowDelegate>
@property(nonatomic, weak) NSWindow *browserWindow;
@property(nonatomic, strong) NSSecureTextField *tokenField;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *clearButton;
@property(nonatomic, strong) NSButton *signInButton;
@property(nonatomic, strong) NSButton *saveButton;
@property(nonatomic, strong) NSButton *continueButton;
@property(nonatomic, strong) NSButton *cancelButton;
@property(nonatomic, strong) NSSecureTextField *codeField;
@property(nonatomic, strong) NSStackView *codeControls;
@property(nonatomic, strong) NSProgressIndicator *progress;
@property(nonatomic, assign) BOOL loginActive;
@property(nonatomic, assign) BOOL loginDone;
@property(nonatomic, assign) BOOL tokenEOF;
@property(nonatomic, assign) BOOL loginFailed;
@property(nonatomic, assign) BOOL setupActive;
@property(nonatomic, assign) BOOL clearWasEnabled;
@property(nonatomic, assign) pid_t loginPid;
@property(nonatomic, assign) pid_t netPid;
@property(nonatomic, assign) int loginInput;
@property(nonatomic, assign) int netInput;
@property(nonatomic, assign) uint64_t inputSequence;
@property(nonatomic, assign) uint64_t outputSequence;
@property(nonatomic, assign) NSUInteger loginEpoch;
@property(nonatomic, assign) NSUInteger setupEpoch;
@property(nonatomic, strong) NSMutableData *capturedToken;
@property(nonatomic, copy) NSString *home;
@property(nonatomic, copy) NSString *python;
@property(nonatomic, copy) NSString *packageDirectory;
- (instancetype)initWithBrowserWindow:(NSWindow *)parent;
- (void)presentForBrowserWindow:(NSWindow *)parent;
@end

static ZBMacSecretsWindowController *zbSecretsController;

static int zb_mac_product_token_matches(const char *token) {
  if (token == NULL) return 0;
  char *stored = NULL;
  char *error = NULL;
  int result = zb_keychain_lookup(NULL, NULL, ZB_MAC_AGENT_TOKEN_SERVICE,
                                  ZB_MAC_AGENT_TOKEN_ACCOUNT, &stored, &error);
  int matches = result == ZB_KC_OK && stored != NULL && strcmp(stored, token) == 0;
  zb_keychain_free(stored);
  free(error);
  return matches;
}

static NSTextField *zb_label(NSString *text, BOOL secondary) {
  NSTextField *label = [NSTextField labelWithString:text];
  label.selectable = YES;
  label.maximumNumberOfLines = 0;
  label.lineBreakMode = NSLineBreakByWordWrapping;
  if (secondary) label.textColor = NSColor.secondaryLabelColor;
  return label;
}

@implementation ZBMacSecretsWindowController

- (instancetype)initWithBrowserWindow:(NSWindow *)parent {
  NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 540, 410)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self = [super initWithWindow:window];
  if (self == nil) return nil;

  window.title = @"Claude Agent account";
  window.releasedWhenClosed = NO;
  window.delegate = self;

  NSTextField *heading = zb_label(@"Connect the Claude Agent", NO);
  heading.font = [NSFont boldSystemFontOfSize:18.0];

  NSTextField *signinHelp = zb_label(
      @"Sign in in your browser. ZigBrowser completes the Claude CLI login and saves the credential for you.", YES);
  _signInButton = [NSButton buttonWithTitle:@"Sign in with Claude.ai"
                                      target:self
                                      action:@selector(signIn:)];
  _signInButton.bezelStyle = NSBezelStyleRounded;

  _progress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
  _progress.style = NSProgressIndicatorStyleSpinning;
  _progress.controlSize = NSControlSizeSmall;
  _progress.displayedWhenStopped = NO;

  _codeField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
  _codeField.placeholderString = @"Paste the authorization code";
  _codeField.accessibilityLabel = @"Claude sign-in code";
  _continueButton = [NSButton buttonWithTitle:@"Continue" target:self action:@selector(sendCode:)];
  _continueButton.bezelStyle = NSBezelStyleRounded;
  _cancelButton = [NSButton buttonWithTitle:@"Cancel sign-in" target:self action:@selector(cancelSignIn:)];
  _cancelButton.bezelStyle = NSBezelStyleRounded;
  _codeControls = [NSStackView stackViewWithViews:@[_codeField, _continueButton, _cancelButton]];
  _codeControls.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  _codeControls.spacing = 8.0;
  _codeControls.hidden = YES;

  NSTextField *tokenLabel = zb_label(@"Long-lived token", NO);
  _tokenField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
  _tokenField.placeholderString = @"sk-ant-oat01-…";
  _tokenField.accessibilityLabel = @"Long-lived Claude token";

  _saveButton = [NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)];
  _clearButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clear:)];
  NSButton *close = [NSButton buttonWithTitle:@"Close" target:window action:@selector(performClose:)];
  NSStackView *buttons = [NSStackView stackViewWithViews:@[_clearButton, close, _saveButton]];
  buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  buttons.spacing = 8.0;

  _statusLabel = zb_label(@"Checking the login Keychain…", YES);
  _statusLabel.accessibilityLabel = @"Credential status";

  NSStackView *content = [NSStackView stackViewWithViews:@[
    heading, signinHelp, _signInButton, _progress, _codeControls,
    tokenLabel, _tokenField, _statusLabel, buttons,
  ]];
  content.orientation = NSUserInterfaceLayoutOrientationVertical;
  content.alignment = NSLayoutAttributeLeading;
  content.spacing = 10.0;
  content.translatesAutoresizingMaskIntoConstraints = NO;
  window.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
  [window.contentView addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor constant:24.0],
    [content.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor constant:-24.0],
    [content.topAnchor constraintEqualToAnchor:window.contentView.topAnchor constant:24.0],
    [content.bottomAnchor constraintLessThanOrEqualToAnchor:window.contentView.bottomAnchor constant:-24.0],
    [_tokenField.widthAnchor constraintEqualToAnchor:content.widthAnchor],
    [_codeField.widthAnchor constraintGreaterThanOrEqualToConstant:260.0],
    [_statusLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
    [signinHelp.widthAnchor constraintEqualToAnchor:content.widthAnchor],
  ]];

  _loginPid = -1;
  _netPid = -1;
  _loginInput = -1;
  _netInput = -1;

  [self presentForBrowserWindow:parent];
  return self;
}

- (BOOL)testKeychainPath:(const char **)path password:(const char **)password
                 service:(const char **)service {
  const char *candidate = getenv("ZB_DEBUG_MAC_AGENT_KEYCHAIN");
  const char *secret = getenv("ZB_DEBUG_MAC_AGENT_KEYCHAIN_PASSWORD");
  BOOL selected = zb_mac_drawer_e2e_enabled() && candidate != NULL && candidate[0] == '/' &&
                  secret != NULL && secret[0] != '\0';
  if (path != NULL) *path = selected ? candidate : NULL;
  if (password != NULL) *password = selected ? secret : NULL;
  if (service != NULL) *service = selected ? ZBMacLoginTestService : ZB_MAC_AGENT_TOKEN_SERVICE;
  return selected;
}

- (void)refreshStatus {
  char *token = NULL;
  char *error = NULL;
  int result = zb_keychain_lookup(NULL, NULL, ZB_MAC_AGENT_TOKEN_SERVICE,
                                  ZB_MAC_AGENT_TOKEN_ACCOUNT, &token, &error);
  if (result == ZB_KC_OK && token != NULL) {
    self.statusLabel.stringValue = @"Connected. A token is stored in your login Keychain.";
    self.clearButton.enabled = YES;
  } else if (result == ZB_KC_ABSENT) {
    self.statusLabel.stringValue = @"No token is stored.";
    self.clearButton.enabled = NO;
  } else {
    self.statusLabel.stringValue = @"The login Keychain is unavailable.";
    self.clearButton.enabled = NO;
  }
  zb_keychain_free(token);
  free(error);
}

- (void)setSigningIn:(BOOL)running needsCode:(BOOL)needsCode {
  self.signInButton.enabled = !running && self.loginPid <= 1 && self.netPid <= 1;
  self.tokenField.enabled = !running;
  self.saveButton.enabled = !running;
  self.clearButton.enabled = !running && self.clearButton.enabled;
  self.codeControls.hidden = !running || !needsCode;
  self.cancelButton.hidden = !running;
  if (running) [self.progress startAnimation:nil];
  else [self.progress stopAnimation:nil];
  if (needsCode) [self.codeField becomeFirstResponder];
}

- (void)scheduleSnapshotFromEnvironment:(NSString *)name status:(NSString *)status {
  if (!zb_mac_drawer_e2e_enabled()) return;
  NSString *path = NSProcessInfo.processInfo.environment[name];
  if (path.length == 0 || !path.isAbsolutePath) return;
  __weak ZBMacSecretsWindowController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    ZBMacSecretsWindowController *strongSelf = weakSelf;
    if (strongSelf != nil && [strongSelf.statusLabel.stringValue isEqualToString:status])
      (void)zb_write_secrets_snapshot(strongSelf.window, path);
  });
}

- (void)configureAgentPaths {
  NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
  NSString *base = environment[@"XDG_DATA_HOME"];
  if (base.length == 0) base = [NSHomeDirectory() stringByAppendingPathComponent:@".local/share"];
  self.home = [base stringByAppendingPathComponent:@"zigbrowser/agent-home"];
  NSString *debugPackage = zb_mac_drawer_e2e_enabled() ? environment[@"ZB_DEBUG_MAC_AGENT_HOST"] : nil;
  self.packageDirectory = debugPackage.length > 0 ? debugPackage :
      [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Frameworks/agent-host"] copy];
  self.python = [self.packageDirectory
      stringByAppendingPathComponent:@"Python.framework/Versions/3.12/bin/python3.12"];
}

- (BOOL)packageReady {
  NSFileManager *files = NSFileManager.defaultManager;
  BOOL directory = NO;
  NSString *netd = [self.packageDirectory stringByAppendingPathComponent:@"zb_agent_host/netd.py"];
  BOOL ready = [files isExecutableFileAtPath:self.python] &&
      [files fileExistsAtPath:netd isDirectory:&directory] && !directory;
  const char *fake = zb_mac_drawer_e2e_enabled() ? getenv("ZIGBROWSER_AGENT_CLAUDE_CLI") : NULL;
  if (fake != NULL && (fake[0] != '/' || access(fake, X_OK) != 0)) ready = NO;
  return ready;
}

- (BOOL)agentHomeReady {
  NSFileManager *files = NSFileManager.defaultManager;
  BOOL directory = NO;
  NSArray<NSString *> *required = @[
    [self.home stringByAppendingPathComponent:@"runtime/host/zb_agent_host/__main__.py"],
    [self.home stringByAppendingPathComponent:@"runtime/net-login.json"],
  ];
  for (NSString *path in required) {
    if (![files fileExistsAtPath:path isDirectory:&directory] || directory) return NO;
  }
  return YES;
}

- (void)beginLogin {
  zb_agent_helper_stop();
  self.loginEpoch++;
  self.loginActive = YES;
  self.loginDone = NO;
  self.tokenEOF = NO;
  self.loginFailed = NO;
  self.capturedToken = nil;
  self.statusLabel.stringValue = @"Starting secure Claude sign-in…";
  [self setSigningIn:YES needsCode:NO];
  [self startLoginNetwork:self.loginEpoch];
}

- (BOOL)writeLoginFrame:(NSDictionary *)fields {
  if (self.loginInput < 0) return NO;
  NSMutableDictionary *frame = [fields mutableCopy];
  frame[@"v"] = @1;
  frame[@"seq"] = @(++self.outputSequence);
  NSData *json = [NSJSONSerialization dataWithJSONObject:frame options:0 error:nil];
  if (json == nil || json.length > ZBMacLoginLineMax) return NO;
  NSMutableData *line = [json mutableCopy];
  const unsigned char newline = '\n';
  [line appendBytes:&newline length:1];
  const unsigned char *bytes = line.bytes;
  NSUInteger used = 0;
  while (used < line.length) {
    ssize_t written = write(self.loginInput, bytes + used, line.length - used);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) return NO;
    used += (NSUInteger)written;
  }
  return YES;
}

- (void)scheduleKillForPid:(pid_t)pid login:(BOOL)isLogin {
  if (pid <= 1) return;
  __weak ZBMacSecretsWindowController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    ZBMacSecretsWindowController *strongSelf = weakSelf;
    if (strongSelf == nil) return;
    pid_t current = isLogin ? strongSelf.loginPid : strongSelf.netPid;
    /* An unreaped child cannot have its pid reused. Signal only the exact group
     * leader this controller spawned; the dedicated waiter does the reap. */
    if (current == pid && pid > 1 && pid != getpid() && pid != getpgrp() && getpgid(pid) == pid) {
      (void)kill(-pid, SIGKILL);
    }
  });
}

- (void)stopLoginProcesses {
  pid_t login = self.loginPid;
  pid_t net = self.netPid;
  zb_close_login_fd(&_loginInput);
  zb_close_login_fd(&_netInput);
  [self scheduleKillForPid:login login:YES];
  [self scheduleKillForPid:net login:NO];
}

- (void)failLoginWithText:(NSString *)text {
  if (self.loginFailed) return;
  self.loginFailed = YES;
  self.loginActive = NO;
  self.loginDone = NO;
  self.tokenEOF = NO;
  self.codeField.stringValue = @"";
  self.codeControls.hidden = YES;
  [self.progress stopAnimation:nil];
  self.tokenField.enabled = YES;
  self.saveButton.enabled = YES;
  self.clearButton.enabled = self.clearWasEnabled;
  self.statusLabel.stringValue = text;
  zb_wipe_data(self.capturedToken);
  self.capturedToken = nil;
  [self stopLoginProcesses];
}

- (BOOL)validAuthorizeURL:(NSURL *)url {
  if (url == nil || ![url.scheme isEqualToString:@"https"] || url.user != nil ||
      url.password != nil || url.port != nil || url.fragment != nil) return NO;
  return ([url.host isEqualToString:@"claude.com"] &&
          [url.path isEqualToString:@"/cai/oauth/authorize"]) ||
         ([url.host isEqualToString:@"platform.claude.com"] &&
          [url.path isEqualToString:@"/oauth/authorize"]);
}

- (void)finishLoginIfReady {
  if (!self.loginActive || !self.loginDone || !self.tokenEOF) return;
  if (self.capturedToken.length == 0 || self.capturedToken.length > ZBMacLoginTokenMax) {
    [self failLoginWithText:@"Claude sign-in did not return a valid credential."];
    return;
  }

  size_t length = self.capturedToken.length;
  char *token = calloc(length + 1, 1);
  if (token == NULL) {
    [self failLoginWithText:@"The Claude credential could not be saved."];
    return;
  }
  memcpy(token, self.capturedToken.bytes, length);
  const char *path = NULL;
  const char *password = NULL;
  const char *service = NULL;
  BOOL testTarget = [self testKeychainPath:&path password:&password service:&service];
  char *error = NULL;
  int result = zb_agent_onboard_token(path, password, service,
                                      ZB_MAC_AGENT_TOKEN_ACCOUNT, token, &error);
  memset_s(token, length + 1, 0, length + 1);
  free(token);
  free(error);
  zb_wipe_data(self.capturedToken);
  self.capturedToken = nil;
  if (result != ZB_KC_OK) {
    [self failLoginWithText:result == ZB_KC_ABSENT
        ? @"Claude sign-in did not return a valid credential."
        : @"The Claude credential could not be saved in your login Keychain."];
    return;
  }

  self.loginActive = NO;
  self.loginFailed = NO;
  self.codeField.stringValue = @"";
  self.codeControls.hidden = YES;
  [self.progress stopAnimation:nil];
  zb_close_login_fd(&_loginInput);
  zb_close_login_fd(&_netInput);
  if (testTarget) {
    self.statusLabel.stringValue = @"Connected. A token is stored in your login Keychain.";
    self.clearButton.enabled = YES;
  } else {
    [self refreshStatus];
  }
  zb_agent_helper_stop();
  zb_drawer_agent_status(0, "ready", "-");
}

- (void)tokenReaderEnded:(NSMutableData *)token invalid:(BOOL)invalid
                   pid:(pid_t)pid epoch:(NSUInteger)epoch {
  (void)pid;
  if (epoch != self.loginEpoch || !self.loginActive) {
    zb_wipe_data(token);
    return;
  }
  if (invalid) {
    zb_wipe_data(token);
    [self failLoginWithText:@"Claude sign-in returned an invalid credential."];
    return;
  }
  self.capturedToken = token;
  self.tokenEOF = YES;
  [self finishLoginIfReady];
}

- (void)receiveLoginFrame:(NSDictionary *)frame pid:(pid_t)pid epoch:(NSUInteger)epoch {
  (void)pid;
  if (epoch != self.loginEpoch || !self.loginActive) return;
  NSNumber *version = frame[@"v"];
  NSNumber *sequence = frame[@"seq"];
  NSString *type = frame[@"type"];
  if (![version isKindOfClass:NSNumber.class] || version.integerValue != 1 ||
      ![sequence isKindOfClass:NSNumber.class] ||
      sequence.unsignedLongLongValue != self.inputSequence + 1 ||
      ![type isKindOfClass:NSString.class]) {
    [self failLoginWithText:@"Claude sign-in returned an invalid response."];
    return;
  }
  self.inputSequence = sequence.unsignedLongLongValue;
  if ([type isEqualToString:@"auth_url"]) {
    NSString *text = frame[@"url"];
    NSURL *url = [text isKindOfClass:NSString.class] ? [NSURL URLWithString:text] : nil;
    if (![self validAuthorizeURL:url] || ![NSWorkspace.sharedWorkspace openURL:url]) {
      [self failLoginWithText:@"The Claude authorization page could not be opened."];
      return;
    }
    self.statusLabel.stringValue = @"Finish signing in in your browser.";
  } else if ([type isEqualToString:@"need_code"]) {
    self.statusLabel.stringValue = @"Paste the authorization code from your browser.";
    [self setSigningIn:YES needsCode:YES];
    [self scheduleSnapshotFromEnvironment:@"ZB_DEBUG_MAC_SECRETS_CODE_PNG"
                                   status:self.statusLabel.stringValue];
  } else if ([type isEqualToString:@"done"]) {
    self.loginDone = YES;
    [self finishLoginIfReady];
  } else if ([type isEqualToString:@"error"]) {
    NSString *code = frame[@"code"];
    [self failLoginWithText:[code isEqualToString:@"cancelled"]
        ? @"Claude sign-in was cancelled."
        : @"Claude sign-in could not be completed."];
  } else {
    [self failLoginWithText:@"Claude sign-in returned an invalid response."];
  }
}

- (void)readLoginOutput:(int)output token:(int)tokenFD pid:(pid_t)pid epoch:(NSUInteger)epoch {
  __weak ZBMacSecretsWindowController *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSMutableData *pending = [NSMutableData data];
    unsigned char bytes[1024];
    BOOL malformed = NO;
    for (;;) {
      ssize_t got = read(output, bytes, sizeof bytes);
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) break;
      [pending appendBytes:bytes length:(NSUInteger)got];
      if (pending.length > ZBMacLoginLineMax) { malformed = YES; break; }
      for (;;) {
        const unsigned char *all = pending.bytes;
        NSUInteger newline = NSNotFound;
        for (NSUInteger i = 0; i < pending.length; ++i) {
          if (all[i] == '\n') { newline = i; break; }
        }
        if (newline == NSNotFound) break;
        NSData *line = [pending subdataWithRange:NSMakeRange(0, newline)];
        [pending replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
        id parsed = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if (![parsed isKindOfClass:NSDictionary.class]) { malformed = YES; break; }
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf receiveLoginFrame:parsed pid:pid epoch:epoch];
        });
      }
      if (malformed) break;
    }
    close(output);
    if (pending.length != 0) malformed = YES;
    if (malformed) dispatch_async(dispatch_get_main_queue(), ^{
      ZBMacSecretsWindowController *strongSelf = weakSelf;
      if (strongSelf.loginActive && strongSelf.loginEpoch == epoch)
        [strongSelf failLoginWithText:@"Claude sign-in returned an invalid response."];
    });
  });

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSMutableData *token = [NSMutableData data];
    unsigned char bytes[256];
    BOOL invalid = NO;
    for (;;) {
      ssize_t got = read(tokenFD, bytes, sizeof bytes);
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) break;
      if (token.length + (NSUInteger)got > ZBMacLoginTokenMax) {
        invalid = YES;
        break;
      }
      [token appendBytes:bytes length:(NSUInteger)got];
    }
    memset_s(bytes, sizeof bytes, 0, sizeof bytes);
    close(tokenFD);
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf tokenReaderEnded:token invalid:invalid pid:pid epoch:epoch];
    });
  });

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    int status = zb_agent_wait(pid);
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBMacSecretsWindowController *strongSelf = weakSelf;
      if (strongSelf.loginPid != pid) return;
      strongSelf.loginPid = -1;
      if (strongSelf.loginActive && !strongSelf.loginDone && status != 0)
        [strongSelf failLoginWithText:@"Claude sign-in could not be completed."];
      else if (!strongSelf.loginActive && strongSelf.netPid <= 1)
        strongSelf.signInButton.enabled = YES;
    });
  });
}

- (void)startLoginOnPort:(NSUInteger)port epoch:(NSUInteger)epoch {
  if (!self.loginActive || epoch != self.loginEpoch) return;
  int input[2] = {-1, -1};
  int output[2] = {-1, -1};
  int token[2] = {-1, -1};
  if (zb_login_pipe(input) != 0 || zb_login_pipe(output) != 0 || zb_login_pipe(token) != 0) {
    zb_close_login_fd(&input[0]); zb_close_login_fd(&input[1]);
    zb_close_login_fd(&output[0]); zb_close_login_fd(&output[1]);
    zb_close_login_fd(&token[0]); zb_close_login_fd(&token[1]);
    [self failLoginWithText:@"Claude sign-in could not start."];
    return;
  }

  NSString *host = [self.home stringByAppendingPathComponent:@"runtime/host"];
  NSString *portText = [NSString stringWithFormat:@"%lu", (unsigned long)port];
  const char *fake = zb_mac_drawer_e2e_enabled() ? getenv("ZIGBROWSER_AGENT_CLAUDE_CLI") : NULL;
  const char *argv[20] = {
    self.python.fileSystemRepresentation, "-I", "-c", ZBMacPythonBoot,
    host.fileSystemRepresentation, "launch", "--home", self.home.fileSystemRepresentation,
    "--python", self.python.fileSystemRepresentation, "--command", "login",
    "--egress-port", portText.UTF8String, NULL,
  };
  if (fake != NULL && fake[0] == '/') {
    argv[14] = "--e2e-claude-cli";
    argv[15] = fake;
    argv[16] = NULL;
  }
  NSString *homeEnv = [@"HOME=" stringByAppendingString:self.home];
  NSString *tmpEnv = [@"TMPDIR=" stringByAppendingString:
      [self.home stringByAppendingPathComponent:@"scratchpad/tmp"]];
  const char *const envp[] = {
    "PATH=/usr/bin:/bin", "LANG=C.UTF-8", "PYTHONDONTWRITEBYTECODE=1",
    homeEnv.UTF8String, tmpEnv.UTF8String, NULL,
  };
  pid_t pid = -1;
  int result = zb_agent_spawn_group_io_fd4(argv, envp, input[0], output[1], token[1], &pid);
  zb_close_login_fd(&input[0]);
  zb_close_login_fd(&output[1]);
  zb_close_login_fd(&token[1]);
  if (result != 0 || pid <= 1) {
    zb_close_login_fd(&input[1]);
    zb_close_login_fd(&output[0]);
    zb_close_login_fd(&token[0]);
    [self failLoginWithText:@"Claude sign-in could not start."];
    return;
  }
  (void)fcntl(input[1], F_SETNOSIGPIPE, 1);
  self.loginPid = pid;
  self.loginInput = input[1];
  self.inputSequence = 0;
  self.outputSequence = 0;
  [self readLoginOutput:output[0] token:token[0] pid:pid epoch:epoch];
  if (![self writeLoginFrame:@{@"type": @"start"}])
    [self failLoginWithText:@"Claude sign-in could not start."];
}

- (void)networkReadyLine:(NSString *)line epoch:(NSUInteger)epoch {
  if (!self.loginActive || epoch != self.loginEpoch) return;
  NSString *prefix = @"netd ready 127.0.0.1:";
  if (![line hasPrefix:prefix] || ![line hasSuffix:@"\n"]) {
    [self failLoginWithText:@"Claude sign-in networking is unavailable."];
    return;
  }
  NSString *portText = [line substringWithRange:NSMakeRange(prefix.length, line.length - prefix.length - 1)];
  NSScanner *scanner = [NSScanner scannerWithString:portText];
  NSInteger port = 0;
  if (![scanner scanInteger:&port] || !scanner.isAtEnd || port < 1 || port > 65535 ||
      [portText hasPrefix:@"0"]) {
    [self failLoginWithText:@"Claude sign-in networking is unavailable."];
    return;
  }
  [self startLoginOnPort:(NSUInteger)port epoch:epoch];
}

- (void)startLoginNetwork:(NSUInteger)epoch {
  int input[2] = {-1, -1};
  int output[2] = {-1, -1};
  if (zb_login_pipe(input) != 0 || zb_login_pipe(output) != 0) {
    zb_close_login_fd(&input[0]); zb_close_login_fd(&input[1]);
    zb_close_login_fd(&output[0]); zb_close_login_fd(&output[1]);
    [self failLoginWithText:@"Claude sign-in networking could not start."];
    return;
  }
  NSString *script = [self.packageDirectory stringByAppendingPathComponent:@"zb_agent_host/netd.py"];
  NSString *manifest = [self.home stringByAppendingPathComponent:@"runtime/net-login.json"];
  const char *const argv[] = {
    self.python.fileSystemRepresentation, "-I", "-S", script.fileSystemRepresentation,
    "--net-manifest", manifest.fileSystemRepresentation, NULL,
  };
  const char *const envp[] = {
    "PATH=/usr/bin:/bin", "LANG=C.UTF-8", "PYTHONDONTWRITEBYTECODE=1", NULL,
  };
  pid_t pid = -1;
  int result = zb_agent_spawn_group_io(argv, envp, input[0], output[1], &pid);
  zb_close_login_fd(&input[0]);
  zb_close_login_fd(&output[1]);
  if (result != 0 || pid <= 1) {
    zb_close_login_fd(&input[1]);
    zb_close_login_fd(&output[0]);
    [self failLoginWithText:@"Claude sign-in networking could not start."];
    return;
  }
  self.netPid = pid;
  self.netInput = input[1];
  int readyFD = output[0];
  __weak ZBMacSecretsWindowController *weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    char line[160];
    size_t used = 0;
    while (used + 1 < sizeof line) {
      ssize_t got = read(readyFD, line + used, 1);
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) break;
      if (line[used++] == '\n') break;
    }
    line[used] = '\0';
    NSString *ready = [[NSString alloc] initWithBytes:line length:used encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf networkReadyLine:ready epoch:epoch]; });
    unsigned char discard[512];
    while (read(readyFD, discard, sizeof discard) > 0) {}
    close(readyFD);
  });
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    (void)zb_agent_wait(pid);
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBMacSecretsWindowController *strongSelf = weakSelf;
      if (strongSelf.netPid != pid) return;
      strongSelf.netPid = -1;
      if (strongSelf.loginActive && strongSelf.loginPid <= 1)
        [strongSelf failLoginWithText:@"Claude sign-in networking stopped."];
      else if (!strongSelf.loginActive && strongSelf.loginPid <= 1)
        strongSelf.signInButton.enabled = YES;
    });
  });
}

- (void)presentForBrowserWindow:(NSWindow *)parent {
  if (self.browserWindow != parent) {
    if (self.browserWindow != nil) [self.browserWindow removeChildWindow:self.window];
    self.browserWindow = parent;
    if (parent != nil) [parent addChildWindow:self.window ordered:NSWindowAbove];
  }
  if (!self.loginActive && !self.setupActive) [self refreshStatus];
  if (parent == nil) [self.window center];
  [self showWindow:nil];
  [self.window makeKeyAndOrderFront:nil];
  if (!self.loginActive && !self.setupActive) [self.tokenField becomeFirstResponder];
}

- (void)signIn:(id)sender {
  (void)sender;
  if (self.setupActive || self.loginActive || self.loginPid > 1 || self.netPid > 1) return;
  [self configureAgentPaths];
  if (![self packageReady]) {
    self.statusLabel.stringValue = @"Claude Agent setup could not start.";
    return;
  }
  self.clearWasEnabled = self.clearButton.enabled;
  if ([self agentHomeReady]) {
    [self beginLogin];
    return;
  }

  self.setupActive = YES;
  NSUInteger epoch = ++self.setupEpoch;
  self.statusLabel.stringValue = ZBMacFirstRunSetupText;
  [self setSigningIn:YES needsCode:NO];
  [self scheduleSnapshotFromEnvironment:@"ZB_DEBUG_MAC_SECRETS_SETUP_PNG"
                                 status:ZBMacFirstRunSetupText];
  __weak ZBMacSecretsWindowController *weakSelf = self;
  zb_mac_agent_setup_start_or_join(^(BOOL success, NSString *errorLine) {
    ZBMacSecretsWindowController *strongSelf = weakSelf;
    if (strongSelf == nil || !strongSelf.setupActive || strongSelf.setupEpoch != epoch) return;
    strongSelf.setupActive = NO;
    if (!success || ![strongSelf agentHomeReady]) {
      [strongSelf setSigningIn:NO needsCode:NO];
      strongSelf.clearButton.enabled = strongSelf.clearWasEnabled;
      strongSelf.statusLabel.stringValue = errorLine.length > 0
          ? errorLine : @"Claude Agent setup failed.";
      return;
    }
    [strongSelf beginLogin];
  });
}

- (void)sendCode:(id)sender {
  (void)sender;
  if (!self.loginActive) return;
  NSString *code = [self.codeField.stringValue
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  self.codeField.stringValue = @"";
  NSData *ascii = [code dataUsingEncoding:NSASCIIStringEncoding];
  if (ascii == nil || ascii.length < 3 || ascii.length > 512 || [code rangeOfString:@"#"].location == NSNotFound) {
    self.statusLabel.stringValue = @"That authorization code is not valid.";
    return;
  }
  if (![self writeLoginFrame:@{@"type": @"code", @"code": code}]) {
    [self failLoginWithText:@"The authorization code could not be sent."];
    return;
  }
  self.codeControls.hidden = YES;
  self.statusLabel.stringValue = @"Completing Claude sign-in…";
}

- (void)cancelSignIn:(id)sender {
  (void)sender;
  if (!self.loginActive) return;
  (void)[self writeLoginFrame:@{@"type": @"cancel"}];
  [self failLoginWithText:@"Claude sign-in was cancelled."];
}

- (void)save:(id)sender {
  (void)sender;
  NSString *pasted = self.tokenField.stringValue ?: @"";
  self.tokenField.stringValue = @"";
  const char *token = pasted.UTF8String;
  char *error = NULL;
  int result = zb_agent_onboard_token(NULL, NULL, ZB_MAC_AGENT_TOKEN_SERVICE,
                                      ZB_MAC_AGENT_TOKEN_ACCOUNT,
                                      token != NULL ? token : "", &error);
  if (result == ZB_KC_OK) {
    [self refreshStatus];
    zb_agent_helper_stop();
  } else if (result == ZB_KC_ABSENT) {
    self.statusLabel.stringValue = @"That doesn’t look like a long-lived token.";
  } else {
    self.statusLabel.stringValue = @"The token could not be saved in your login Keychain.";
  }
  free(error);
}

- (void)clear:(id)sender {
  (void)sender;
  char *error = NULL;
  int result = zb_keychain_clear(NULL, NULL, ZB_MAC_AGENT_TOKEN_SERVICE,
                                 ZB_MAC_AGENT_TOKEN_ACCOUNT, &error);
  if (result == ZB_KC_OK) {
    [self refreshStatus];
    zb_agent_helper_stop();
  } else {
    self.statusLabel.stringValue = @"The token could not be removed from your login Keychain.";
  }
  free(error);
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
  if (self.setupActive) {
    self.setupActive = NO;
    self.setupEpoch++;
  }
  if (self.loginActive) {
    (void)[self writeLoginFrame:@{@"type": @"cancel"}];
    [self failLoginWithText:@"Claude sign-in was cancelled."];
  } else {
    [self stopLoginProcesses];
  }
  if (self.browserWindow != nil) [self.browserWindow removeChildWindow:self.window];
  if (zbSecretsController == self) zbSecretsController = nil;
}

@end

void zb_mac_secrets_window_open(NSWindow *parent) {
  if (![NSThread isMainThread]) {
    dispatch_async(dispatch_get_main_queue(), ^{ zb_mac_secrets_window_open(parent); });
    return;
  }
  if (zbSecretsController == nil) {
    zbSecretsController = [[ZBMacSecretsWindowController alloc] initWithBrowserWindow:parent];
  } else {
    [zbSecretsController presentForBrowserWindow:parent];
  }
}

int zb_mac_secrets_window_acceptance_store(NSWindow *parent, const char *token) {
  if (!zb_mac_drawer_e2e_enabled() || !NSThread.isMainThread || token == NULL) return 0;
  zb_mac_secrets_window_open(parent);
  if (zbSecretsController == nil || !zbSecretsController.window.visible ||
      ![zbSecretsController.window.title isEqualToString:@"Claude Agent account"]) return 0;
  puts("OWNER_ACCEPTANCE\tsecrets-open\tClaude Agent account");
  fflush(stdout);

  NSString *value = [NSString stringWithUTF8String:token];
  if (value == nil) return 0;
  zbSecretsController.tokenField.stringValue = value;
  [zbSecretsController save:nil];
  if (![zbSecretsController.statusLabel.stringValue
          isEqualToString:@"Connected. A token is stored in your login Keychain."] ||
      !zbSecretsController.clearButton.enabled || !zb_mac_product_token_matches(token)) return 0;
  puts("OWNER_ACCEPTANCE\tcredential-stored\tconnected");
  fflush(stdout);
  return 1;
}

int zb_mac_secrets_window_acceptance_clear_if_matches(const char *token) {
  if (!zb_mac_drawer_e2e_enabled() || !NSThread.isMainThread ||
      !zb_mac_product_token_matches(token)) return 0;

  char *error = NULL;
  int result = zb_keychain_clear(NULL, NULL, ZB_MAC_AGENT_TOKEN_SERVICE,
                                 ZB_MAC_AGENT_TOKEN_ACCOUNT, &error);
  free(error);
  if (result != ZB_KC_OK) return 0;

  char *stored = NULL;
  error = NULL;
  result = zb_keychain_lookup(NULL, NULL, ZB_MAC_AGENT_TOKEN_SERVICE,
                              ZB_MAC_AGENT_TOKEN_ACCOUNT, &stored, &error);
  zb_keychain_free(stored);
  free(error);
  if (result != ZB_KC_ABSENT) return 0;

  puts("OWNER_ACCEPTANCE\tcredential-cleared\texact");
  fflush(stdout);
  return 1;
}

/* Compatibility with the older standalone Mac Secrets header. The drawer's
 * NSWindow-bearing entry above is the shared contract used by current product code. */
int zb_secrets_window_mac_show(unsigned long long window_id) {
  (void)window_id;
  zb_mac_secrets_window_open(nil);
  return 0;
}
