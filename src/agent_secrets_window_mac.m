/* Native macOS Secrets window for the Claude Agent drawer. The window is an
 * AppKit-owned product surface, never a web view or automation window. */
#import <AppKit/AppKit.h>

#include "agent_drawer_mac.h"
#include "agent_helper_mac.h"
#include "agent_secrets_mac.h"

#include <stdlib.h>

int zb_agent_onboard_token(const char *keychain_path, const char *unlock_password,
                           const char *service, const char *account, const char *token, char **out_err);

@interface ZBMacSecretsWindowController : NSWindowController <NSWindowDelegate>
@property(nonatomic, weak) NSWindow *browserWindow;
@property(nonatomic, strong) NSSecureTextField *tokenField;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *clearButton;
- (instancetype)initWithBrowserWindow:(NSWindow *)parent;
- (void)presentForBrowserWindow:(NSWindow *)parent;
@end

static ZBMacSecretsWindowController *zbSecretsController;

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
      initWithContentRect:NSMakeRect(0, 0, 540, 330)
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
      @"Sign in with Claude.ai, then create a long-lived token with “claude setup-token” and paste it below.", YES);
  NSButton *signin = [NSButton buttonWithTitle:@"Sign in with Claude.ai"
                                        target:self
                                        action:@selector(signIn:)];
  signin.bezelStyle = NSBezelStyleRounded;

  NSTextField *tokenLabel = zb_label(@"Long-lived token", NO);
  _tokenField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
  _tokenField.placeholderString = @"sk-ant-oat01-…";
  _tokenField.accessibilityLabel = @"Long-lived Claude token";

  NSButton *save = [NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)];
  save.keyEquivalent = @"\r";
  _clearButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clear:)];
  NSButton *close = [NSButton buttonWithTitle:@"Close" target:window action:@selector(performClose:)];
  NSStackView *buttons = [NSStackView stackViewWithViews:@[_clearButton, close, save]];
  buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  buttons.spacing = 8.0;

  _statusLabel = zb_label(@"Checking the login Keychain…", YES);
  _statusLabel.accessibilityLabel = @"Credential status";

  NSStackView *content = [NSStackView stackViewWithViews:@[
    heading, signinHelp, signin, tokenLabel, _tokenField, _statusLabel, buttons,
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
    [_statusLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
    [signinHelp.widthAnchor constraintEqualToAnchor:content.widthAnchor],
  ]];

  [self presentForBrowserWindow:parent];
  return self;
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

- (void)presentForBrowserWindow:(NSWindow *)parent {
  if (self.browserWindow != parent) {
    if (self.browserWindow != nil) [self.browserWindow removeChildWindow:self.window];
    self.browserWindow = parent;
    if (parent != nil) [parent addChildWindow:self.window ordered:NSWindowAbove];
  }
  [self refreshStatus];
  if (parent == nil) [self.window center];
  [self showWindow:nil];
  [self.window makeKeyAndOrderFront:nil];
  [self.tokenField becomeFirstResponder];
}

- (void)signIn:(id)sender {
  (void)sender;
  NSURL *url = [NSURL URLWithString:@"https://claude.ai/login"];
  if (url != nil && [NSWorkspace.sharedWorkspace openURL:url]) {
    self.statusLabel.stringValue = @"Claude.ai opened. After signing in, run “claude setup-token” and paste the token here.";
  } else {
    self.statusLabel.stringValue = @"Claude.ai could not be opened. Visit https://claude.ai/login in your browser.";
  }
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
  } else {
    self.statusLabel.stringValue = @"The token could not be removed from your login Keychain.";
  }
  free(error);
}

- (void)windowWillClose:(NSNotification *)notification {
  (void)notification;
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

/* Compatibility with the older standalone Mac Secrets header. The drawer's
 * NSWindow-bearing entry above is the shared contract used by current product code. */
int zb_secrets_window_mac_show(unsigned long long window_id) {
  (void)window_id;
  zb_mac_secrets_window_open(nil);
  return 0;
}
