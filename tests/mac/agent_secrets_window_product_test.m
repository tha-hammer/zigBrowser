#import <AppKit/AppKit.h>

#include "agent_drawer_mac.h"
#include "agent_secrets_mac.h"

#include <stdio.h>
#include <stdlib.h>

/* This product test links the real AppKit window with an in-memory credential
 * backend. Pair 2 only drives creation and presentation; later pairs drive the
 * buttons without ever touching a user's login Keychain. */
int zb_keychain_lookup(const char *path, const char *password, const char *service,
                       const char *account, char **out_token, char **out_err) {
  (void)path; (void)password; (void)service; (void)account;
  if (out_token != NULL) *out_token = NULL;
  if (out_err != NULL) *out_err = NULL;
  return ZB_KC_ABSENT;
}

int zb_keychain_clear(const char *path, const char *password, const char *service,
                      const char *account, char **out_err) {
  (void)path; (void)password; (void)service; (void)account;
  if (out_err != NULL) *out_err = NULL;
  return ZB_KC_OK;
}

int zb_agent_onboard_token(const char *path, const char *password, const char *service,
                           const char *account, const char *token, char **out_err) {
  (void)path; (void)password; (void)service; (void)account; (void)token;
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
    if (secure_field(window.contentView) == nil) return fail("long-lived token entry is not secure");
    if (button_named(window.contentView, @"Sign in with Claude.ai") == nil) return fail("Claude.ai sign-in action is missing");
    if (button_named(window.contentView, @"Save") == nil) return fail("Save action is missing");
    if (button_named(window.contentView, @"Clear") == nil) return fail("Clear action is missing");

    zb_mac_secrets_window_open(parent);
    NSUInteger count = 0;
    for (NSWindow *candidate in NSApp.windows) {
      if ([candidate.title isEqualToString:@"Claude Agent account"]) count++;
    }
    if (count != 1) return fail("opening twice did not focus the one Secrets window");

    [window close];
    [parent close];
    printf("PASS\tmac-secrets-window-product\topen-controls\n");
    fprintf(stderr, "PASS\tmac-secrets-window-product\topen-controls\n");
    return 0;
  }
}
