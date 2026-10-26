#import <AppKit/AppKit.h>

#include "agent_drawer_mac.h"
#include "agent_secrets_mac.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* This product test links the real AppKit window with an in-memory credential
 * backend, so its real controls are driven without touching a user's Keychain. */
static int stored;
static int onboard_calls;
static int clear_calls;
static int production_target;
static char stored_token[513];

static void observe_target(const char *path, const char *password, const char *service, const char *account) {
  production_target = path == NULL && password == NULL && service != NULL && account != NULL &&
      strcmp(service, "dev.zigbrowser.ClaudeAgentToken") == 0 && strcmp(account, "default") == 0;
}

int zb_keychain_lookup(const char *path, const char *password, const char *service,
                       const char *account, char **out_token, char **out_err) {
  observe_target(path, password, service, account);
  if (out_token != NULL) *out_token = stored ? strdup(stored_token) : NULL;
  if (out_err != NULL) *out_err = NULL;
  return stored ? ZB_KC_OK : ZB_KC_ABSENT;
}

int zb_keychain_clear(const char *path, const char *password, const char *service,
                      const char *account, char **out_err) {
  observe_target(path, password, service, account);
  clear_calls++;
  stored = 0;
  stored_token[0] = '\0';
  if (out_err != NULL) *out_err = NULL;
  return ZB_KC_OK;
}

int zb_agent_onboard_token(const char *path, const char *password, const char *service,
                           const char *account, const char *token, char **out_err) {
  observe_target(path, password, service, account);
  onboard_calls++;
  stored = 1;
  snprintf(stored_token, sizeof stored_token, "%s", token != NULL ? token : "");
  if (out_err != NULL) *out_err = NULL;
  return ZB_KC_OK;
}

void zb_keychain_free(char *token) { free(token); }

static NSButton *button_named(NSView *view, NSString *title) {
  if ([view isKindOfClass:[NSButton class]] && [((NSButton *)view).title isEqualToString:title]) {
    return (NSButton *)view;
  }
  for (NSView *child in view.subviews) {
    NSButton *found = button_named(child, title);
    if (found != nil) return found;
  }
  return nil;
}

static NSSecureTextField *secure_field(NSView *view) {
  if ([view isKindOfClass:[NSSecureTextField class]]) return (NSSecureTextField *)view;
  for (NSView *child in view.subviews) {
    NSSecureTextField *found = secure_field(child);
    if (found != nil) return found;
  }
  return nil;
}

static NSTextField *status_field(NSView *view) {
  if ([view isKindOfClass:[NSTextField class]] &&
      [[(NSTextField *)view accessibilityLabel] isEqualToString:@"Credential status"]) {
    return (NSTextField *)view;
  }
  for (NSView *child in view.subviews) {
    NSTextField *found = status_field(child);
    if (found != nil) return found;
  }
  return nil;
}

static BOOL visible_text_contains(NSView *view, NSString *needle) {
  if ([view isKindOfClass:[NSTextField class]] &&
      [((NSTextField *)view).stringValue containsString:needle]) return YES;
  for (NSView *child in view.subviews) {
    if (visible_text_contains(child, needle)) return YES;
  }
  return NO;
}

static NSWindow *secrets_window(void) {
  for (NSWindow *window in NSApp.windows) {
    if ([window.title isEqualToString:@"Claude Agent account"]) return window;
  }
  return nil;
}

static int fail(const char *message) {
  fprintf(stderr, "FAIL\tmac-secrets-window-product\t%s\n", message);
  return 1;
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSWindow *parent = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(40, 40, 640, 480)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];

    zb_mac_secrets_window_open(parent);
    NSWindow *window = secrets_window();
    if (window == nil) return fail("shared drawer entry did not create the Secrets window");
    if (![parent.childWindows containsObject:window]) return fail("Secrets window is not owned by its browser window");
    NSSecureTextField *token = secure_field(window.contentView);
    NSTextField *status = status_field(window.contentView);
    if (token == nil) return fail("long-lived token entry is not secure");
    if (status == nil) return fail("credential status is missing");
    if (button_named(window.contentView, @"Sign in with Claude.ai") == nil) return fail("Claude.ai sign-in action is missing");
    NSButton *save = button_named(window.contentView, @"Save");
    NSButton *clear = button_named(window.contentView, @"Clear");
    if (save == nil) return fail("Save action is missing");
    if (clear == nil) return fail("Clear action is missing");

    zb_mac_secrets_window_open(parent);
    NSUInteger count = 0;
    for (NSWindow *candidate in NSApp.windows) {
      if ([candidate.title isEqualToString:@"Claude Agent account"]) count++;
    }
    if (count != 1) return fail("opening twice did not focus the one Secrets window");

    NSString *canary = @"sk-ant-oat01-ZBCANARYtoken0000000000";
    token.stringValue = canary;
    [save performClick:nil];
    if (onboard_calls != 1 || !stored) return fail("Save did not call validated onboarding exactly once");
    if (strcmp(stored_token, canary.UTF8String) != 0) return fail("Save did not store the entered token exactly");
    if (!production_target) return fail("Save did not use the production login-Keychain target");
    if (token.stringValue.length != 0) return fail("Save did not clear the secure field");
    if (![status.stringValue isEqualToString:@"Connected. A token is stored in your login Keychain."])
      return fail("Save did not show the stored-credential status");
    if (visible_text_contains(window.contentView, canary)) return fail("the token appeared in visible window text");

    [clear performClick:nil];
    if (clear_calls != 1 || stored) return fail("Clear did not remove the stored credential exactly once");
    if (![status.stringValue isEqualToString:@"No token is stored."])
      return fail("Clear did not restore the empty credential status");

    [window close];
    [parent close];
    printf("PASS\tmac-secrets-window-product\tsave-clear\n");
    fprintf(stderr, "PASS\tmac-secrets-window-product\tsave-clear\n");
    return 0;
  }
}
