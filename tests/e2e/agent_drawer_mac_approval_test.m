#import "agent_drawer_mac.h"

#import <AppKit/AppKit.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>

void zb_drawer_card_show(unsigned int main_window, uint64_t card, const char *verb,
                         unsigned int bound_window, const char *params, size_t params_length,
                         const char *url, const char *origin);
void zb_drawer_card_end(uint64_t card, const char *ending);

static uint64_t pressed_cards[4];
static int pressed_controls[4];
static int pressed_owners[4];
static int pressed_count;

int zb_agent_helper_configured(void) { return 0; }
void zb_agent_helper_send(unsigned int window_id, const char *text) {
  (void)window_id;
  (void)text;
}
void zb_mac_secrets_window_open(NSWindow *parent) { (void)parent; }

int zb_drawer_card_press(uint64_t card, int control, int own) {
  if (pressed_count < 4) {
    pressed_cards[pressed_count] = card;
    pressed_controls[pressed_count] = control;
    pressed_owners[pressed_count] = own;
  }
  pressed_count += 1;
  return control == 1 ? 1 : control == 2 ? 2 : 0;
}

static void fail(const char *message) {
  fprintf(stderr, "FAIL agent-drawer-mac-approval: %s\n", message);
  exit(1);
}

static void collect_views(NSView *view, NSMutableArray<NSView *> *out) {
  [out addObject:view];
  for (NSView *child in view.subviews) collect_views(child, out);
}

static NSArray<NSButton *> *buttons_named(NSView *panel, NSString *title) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect_views(panel, views);
  NSMutableArray<NSButton *> *buttons = [NSMutableArray array];
  for (NSView *view in views) {
    if ([view isKindOfClass:[NSButton class]] && [((NSButton *)view).title isEqualToString:title]) {
      [buttons addObject:(NSButton *)view];
    }
  }
  return buttons;
}

static BOOL has_text(NSView *panel, NSString *text) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect_views(panel, views);
  for (NSView *view in views) {
    if ([view isKindOfClass:[NSTextView class]] && [((NSTextView *)view).string isEqualToString:text]) return YES;
    if ([view isKindOfClass:[NSTextField class]] && [((NSTextField *)view).stringValue isEqualToString:text]) return YES;
  }
  return NO;
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSView *panel = zb_mac_drawer_panel_create(NSMakeRect(0, 0, 760, 420), 77, NULL, NULL);
    if (panel == nil) fail("create returned nil");

    zb_drawer_card_show(78, 100, "navigate", 88, "{}", 2, "https://wrong.example", "wrong");
    if (buttons_named(panel, @"Approve").count != 0) fail("another window's card reached this drawer");

    zb_drawer_card_show(77, 101, "navigate", 88, "{}", 2,
                        "https://example.test/path", "https://origin.test");
    zb_drawer_card_show(77, 202, "reload", 99, "{}", 2, NULL, "");
    NSArray<NSButton *> *approve = buttons_named(panel, @"Approve");
    NSArray<NSButton *> *deny = buttons_named(panel, @"Deny");
    if (approve.count != 2 || deny.count != 2) fail("approval controls were not rendered per card");
    if (!has_text(panel, @"Claude wants to open https://example.test/path in window 88.\nFrom: https://origin.test")) {
      fail("navigate card did not show its bounded request");
    }
    if (!has_text(panel, @"Claude wants to reload window 99.")) fail("reload card summary missing");

    [approve[0] performClick:nil];
    [deny[1] performClick:nil];
    if (pressed_count != 2) fail("card controls did not call the bridge exactly once");
    if (pressed_cards[0] != 101 || pressed_controls[0] != 1 || pressed_owners[0] != 1) {
      fail("Approve did not mint its own exact card");
    }
    if (pressed_cards[1] != 202 || pressed_controls[1] != 2 || pressed_owners[1] != 1) {
      fail("Deny did not mint its own exact card");
    }
    if (approve[0].enabled || deny[0].enabled || approve[1].enabled || deny[1].enabled) {
      fail("settled card controls remained enabled");
    }
    if (!has_text(panel, @"Approved. Waiting for the page…")) fail("approved outcome missing");
    if (!has_text(panel, @"Denied. Nothing was opened.")) fail("denied outcome missing");

    zb_drawer_card_end(101, "done");
    if (!has_text(panel, @"Done.")) fail("card ending did not replace the pending outcome");
    puts("PASS agent-drawer-mac-approval exact-card-minters");
  }
  return 0;
}
