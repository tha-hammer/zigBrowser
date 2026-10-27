/* The native Secrets window's Sign in button drives the installed login helper
 * with the offline setup-token fake, stores only in a disposable Keychain under
 * the test service, and never renders the token. */
#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>

#include "agent_drawer_mac.h"
#include "agent_helper_mac.h"
#include "agent_secrets_mac.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define TEST_SERVICE "dev.zigbrowser.ClaudeAgentLoginTest"
#define TEST_ACCOUNT "default"

static NSURL *openedURL;
static int readyCalls;

int zb_mac_drawer_e2e_enabled(void) { return 1; }
void zb_agent_helper_stop(void) {}
void zb_mac_agent_setup_start_or_join(ZBMacAgentSetupCompletion completion) {
  completion(NO, @"unexpected setup request");
}
void zb_drawer_agent_status(unsigned int windowId, const char *state, const char *reason) {
  (void)windowId;
  (void)reason;
  if (state != NULL && strcmp(state, "ready") == 0) readyCalls++;
}

static BOOL capture_open_url(id receiver, SEL selector, NSURL *url) {
  (void)receiver;
  (void)selector;
  openedURL = url;
  return YES;
}

static NSButton *button_named(NSView *view, NSString *title) {
  if ([view isKindOfClass:NSButton.class] && [((NSButton *)view).title isEqualToString:title]) {
    return (NSButton *)view;
  }
  for (NSView *child in view.subviews) {
    NSButton *found = button_named(child, title);
    if (found != nil) return found;
  }
  return nil;
}

static NSTextField *field_labeled(NSView *view, NSString *label) {
  if ([view isKindOfClass:NSTextField.class] &&
      [[(NSTextField *)view accessibilityLabel] isEqualToString:label]) {
    return (NSTextField *)view;
  }
  for (NSView *child in view.subviews) {
    NSTextField *found = field_labeled(child, label);
    if (found != nil) return found;
  }
  return nil;
}

static NSWindow *secrets_window(void) {
  for (NSWindow *window in NSApp.windows) {
    if ([window.title isEqualToString:@"Claude Agent account"]) return window;
  }
  return nil;
}

static BOOL visible_text_contains(NSView *view, NSString *needle) {
  if ([view isKindOfClass:NSTextField.class] &&
      [((NSTextField *)view).stringValue containsString:needle]) return YES;
  for (NSView *child in view.subviews) {
    if (visible_text_contains(child, needle)) return YES;
  }
  return NO;
}

static void pump(double seconds) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while ([until timeIntervalSinceNow] > 0) {
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
  }
}

static NSString *authorize_state(NSURL *url) {
  NSURLComponents *parts = url != nil ? [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO] : nil;
  for (NSURLQueryItem *item in parts.queryItems) {
    if ([item.name isEqualToString:@"state"] && item.value.length > 0) return item.value;
  }
  return nil;
}

static int fail(const char *message) {
  fprintf(stderr, "FAIL\tmac-secrets-login-product\t%s\n", message);
  return 1;
}

int main(int argc, char **argv) {
  if (argc != 4) return fail("usage: test <private-root> <agent-host-runtime> <fake-cli>");
  @autoreleasepool {
    NSString *root = [NSString stringWithUTF8String:argv[1]];
    NSString *runtime = [NSString stringWithUTF8String:argv[2]];
    NSString *fake = [NSString stringWithUTF8String:argv[3]];
    if (root == nil || runtime == nil || fake == nil) return fail("non-UTF8 argument");

    NSString *keychain = [root stringByAppendingPathComponent:@"login-test.keychain-db"];
    const char *password = "zb-login-disposable";
    SecKeychainRef keychainRef = NULL;
    if (SecKeychainCreate(keychain.fileSystemRepresentation, (UInt32)strlen(password), password,
                          false, NULL, &keychainRef) != errSecSuccess || keychainRef == NULL) {
      return fail("could not create the disposable Keychain");
    }

    setenv("XDG_DATA_HOME", root.fileSystemRepresentation, 1);
    setenv("ZB_DEBUG_MAC_AGENT_HOST", runtime.fileSystemRepresentation, 1);
    setenv("ZIGBROWSER_AGENT_CLAUDE_CLI", fake.fileSystemRepresentation, 1);
    setenv("ZB_DEBUG_MAC_AGENT_KEYCHAIN", keychain.fileSystemRepresentation, 1);
    setenv("ZB_DEBUG_MAC_AGENT_KEYCHAIN_PASSWORD", password, 1);

    NSString *home = [root stringByAppendingPathComponent:@"zigbrowser/agent-home"];
    NSString *fakeDir = [home stringByAppendingPathComponent:@"scratchpad/.zb-fake-setup-token"];
    [NSFileManager.defaultManager createDirectoryAtPath:fakeDir
                            withIntermediateDirectories:YES
                                             attributes:@{NSFilePosixPermissions: @0700}
                                                  error:nil];
    NSString *canary = @"sk-ant-oat01-ZBCANARY-login-0123456789abcdef";
    [[canary stringByAppendingString:@"\n"] writeToFile:[fakeDir stringByAppendingPathComponent:@"token"]
                                               atomically:YES encoding:NSASCIIStringEncoding error:nil];

    Method open = class_getInstanceMethod(NSWorkspace.class, @selector(openURL:));
    if (open == NULL) return fail("NSWorkspace openURL: is unavailable");
    method_setImplementation(open, (IMP)capture_open_url);

    [NSApplication sharedApplication];
    NSWindow *parent = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(40, 40, 640, 480)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered defer:NO];
    parent.releasedWhenClosed = NO;
    zb_mac_secrets_window_open(parent);
    NSWindow *window = secrets_window();
    NSButton *signIn = window != nil ? button_named(window.contentView, @"Sign in with Claude.ai") : nil;
    NSTextField *status = window != nil ? field_labeled(window.contentView, @"Credential status") : nil;
    if (signIn == nil || status == nil) return fail("the real Sign in controls are missing");
    [signIn performClick:nil];

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30.0];
    BOOL sentCode = NO;
    while ([deadline timeIntervalSinceNow] > 0) {
      pump(0.05);
      if (openedURL != nil && [openedURL.host isEqualToString:@"claude.ai"] &&
          [openedURL.path isEqualToString:@"/login"]) {
        return fail("Sign in still opens the manual login page instead of running setup-token");
      }
      if (!sentCode) {
        NSString *state = authorize_state(openedURL);
        NSTextField *code = field_labeled(window.contentView, @"Claude sign-in code");
        NSButton *send = button_named(window.contentView, @"Continue");
        if (state.length > 0 && code != nil && send != nil && !code.hidden) {
          code.stringValue = [NSString stringWithFormat:@"fakecode-0123#%@", state];
          [send performClick:nil];
          sentCode = YES;
        }
      }
      if ([status.stringValue isEqualToString:@"Connected. A token is stored in your login Keychain."]) break;
    }

    if (![status.stringValue isEqualToString:@"Connected. A token is stored in your login Keychain."])
      return fail("Sign in did not finish connected");
    if (!sentCode) return fail("the setup-token authorization code was never submitted");
    if (readyCalls != 1) return fail("the drawer was not moved to its ready state exactly once");
    if (visible_text_contains(window.contentView, canary)) return fail("the token appeared in visible window text");

    char *stored = NULL;
    char *error = NULL;
    int result = zb_keychain_lookup(keychain.fileSystemRepresentation, password,
                                    TEST_SERVICE, TEST_ACCOUNT, &stored, &error);
    BOOL exact = result == ZB_KC_OK && stored != NULL && strcmp(stored, canary.UTF8String) == 0;
    zb_keychain_free(stored);
    free(error);
    if (!exact) return fail("the fake setup-token token is not in the test Keychain item");

    stored = NULL;
    error = NULL;
    result = zb_keychain_lookup(keychain.fileSystemRepresentation, password,
                                ZB_MAC_AGENT_TOKEN_SERVICE, ZB_MAC_AGENT_TOKEN_ACCOUNT, &stored, &error);
    zb_keychain_free(stored);
    free(error);
    if (result != ZB_KC_ABSENT) return fail("the test touched the product Keychain service");

    [window close];
    [parent close];
    error = NULL;
    zb_keychain_clear(keychain.fileSystemRepresentation, password, TEST_SERVICE, TEST_ACCOUNT, &error);
    free(error);
    SecKeychainDelete(keychainRef);
    CFRelease(keychainRef);
    fprintf(stderr, "PASS\tmac-secrets-login-product\tfake-cli-keychain\n");
    return 0;
  }
}
