#import "agent_drawer_mac.h"

#import <AppKit/AppKit.h>
#import <math.h>
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
const char *zb_agent_helper_home(void) { return NULL; }
void zb_agent_helper_send(unsigned int window_id, const char *text) {
  (void)window_id;
  (void)text;
}
void zb_mac_secrets_window_open(NSWindow *parent) { (void)parent; }
int zb_mac_secrets_window_acceptance_store(NSWindow *parent, const char *token) {
  (void)parent;
  (void)token;
  return 0;
}
int zb_mac_secrets_window_acceptance_clear_if_matches(const char *token) {
  (void)token;
  return 0;
}
int zb_mac_drawer_e2e_enabled(void) { return 0; }
unsigned int zb_drawer_demo_messages(void) { return 0; }
void zb_agent_tools_call(unsigned int window_id, const char *session,
                         int64_t prompt_id, const char *request_id,
                         size_t request_id_length, const char *tool,
                         size_t tool_length, const char *arguments,
                         size_t arguments_length) {
  (void)window_id;
  (void)session;
  (void)prompt_id;
  (void)request_id;
  (void)request_id_length;
  (void)tool;
  (void)tool_length;
  (void)arguments;
  (void)arguments_length;
}

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

static void settle(NSView *panel) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.15];
  do {
    [panel layoutSubtreeIfNeeded];
    [panel.window displayIfNeeded];
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  } while ([until timeIntervalSinceNow] > 0);
  [panel layoutSubtreeIfNeeded];
}

static NSView *ancestor_of_class(NSView *view, Class kind) {
  for (NSView *current = view; current != nil; current = current.superview) {
    if ([current isKindOfClass:kind]) return current;
  }
  return nil;
}

static NSScrollView *scroll_containing(NSView *panel, NSView *descendant) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect_views(panel, views);
  for (NSView *view in views) {
    if (![view isKindOfClass:NSScrollView.class]) continue;
    NSScrollView *candidate = (NSScrollView *)view;
    for (NSView *current = descendant; current != nil; current = current.superview) {
      if (current == candidate.documentView) return candidate;
    }
  }
  return nil;
}

static NSTextView *message_named(NSView *panel, NSString *text) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect_views(panel, views);
  for (NSView *view in views) {
    if ([view isKindOfClass:NSTextView.class] &&
        [((NSTextView *)view).string isEqualToString:text]) return (NSTextView *)view;
  }
  return nil;
}

static NSTextField *label_named(NSView *panel, NSString *text) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect_views(panel, views);
  for (NSView *view in views) {
    if ([view isKindOfClass:NSTextField.class] &&
        [((NSTextField *)view).stringValue isEqualToString:text]) return (NSTextField *)view;
  }
  return nil;
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
    if (!has_text(panel, @"Claude wants to open https://example.test/path in window 88.") ||
        !has_text(panel, @"From: https://origin.test")) fail("navigate card did not show its bounded request");
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

    NSWindow *layoutWindow = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(100, 100, 640, 320)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];
    NSView *layoutPanel = zb_mac_drawer_panel_create(NSMakeRect(0, 0, 640, 320), 303, NULL, NULL);
    layoutWindow.contentView = layoutPanel;
    [layoutWindow makeKeyAndOrderFront:nil];
    NSString *lastMessage = nil;
    for (NSUInteger index = 1; index <= 8; index++) {
      lastMessage = [NSString stringWithFormat:
          @"Assistant message %lu fills the list before the approval appears.",
          (unsigned long)index];
      zb_mac_drawer_panel_append(layoutPanel, "assistant", lastMessage.UTF8String);
    }
    NSString *origin = @"http://127.0.0.1:59256/a/very/long/path/that/must/truncate/in/the/middle";
    NSString *title = @"Claude wants to type_text in window 1.";
    NSString *originText = [@"From: " stringByAppendingString:origin];
    zb_drawer_card_show(303, 303, "type_text", 1, "{}", 2, NULL, origin.UTF8String);
    settle(layoutPanel);

    NSButton *layoutApprove = buttons_named(layoutPanel, @"Approve").lastObject;
    NSButton *layoutDeny = buttons_named(layoutPanel, @"Deny").lastObject;
    Class cardClass = NSClassFromString(@"ZBMacApprovalCard");
    NSView *cardView = cardClass != Nil ? ancestor_of_class(layoutApprove, cardClass) : nil;
    NSView *row = cardView.superview;
    NSStackView *list = [row.superview isKindOfClass:NSStackView.class]
        ? (NSStackView *)row.superview : nil;
    NSScrollView *scroll = scroll_containing(layoutPanel, cardView);
    NSTextView *lastText = message_named(layoutPanel, lastMessage);
    NSView *assistantBubble = lastText.superview;
    if (layoutApprove == nil || layoutDeny == nil || cardView == nil || list == nil ||
        scroll == nil || assistantBubble == nil) fail("approval layout views were not found");

    CGFloat cardWidth = NSWidth(cardView.bounds);
    CGFloat listWidth = NSWidth(list.bounds);
    if (cardWidth < listWidth * 0.70) {
      fail([NSString stringWithFormat:@"approval card width %.1f is below 70%% of list width %.1f",
                                        cardWidth, listWidth].UTF8String);
    }
    if (fabs(cardWidth - NSWidth(assistantBubble.bounds)) > 2.0) {
      fail("approval card does not use the assistant bubble width");
    }

    NSRect visible = scroll.documentVisibleRect;
    NSRect approveRect = [scroll.documentView convertRect:layoutApprove.bounds fromView:layoutApprove];
    NSRect denyRect = [scroll.documentView convertRect:layoutDeny.bounds fromView:layoutDeny];
    NSRect tolerance = NSInsetRect(visible, -0.5, -0.5);
    if (!NSContainsRect(tolerance, approveRect)) fail("Approve is outside the visible message rectangle");
    if (!NSContainsRect(tolerance, denyRect)) fail("Deny is outside the visible message rectangle");
    if (NSMidX(approveRect) >= NSMidX(denyRect)) fail("Approve is not to the left of Deny");

    NSTextField *titleLabel = label_named(cardView, title);
    NSTextField *originLabel = label_named(cardView, originText);
    if (titleLabel == nil || originLabel == nil) fail("title and origin are not separate card lines");
    if (titleLabel.maximumNumberOfLines != 1 || originLabel.maximumNumberOfLines != 1) {
      fail("title or origin is allowed to wrap");
    }
    if (originLabel.lineBreakMode != NSLineBreakByTruncatingMiddle) {
      fail("long origin does not truncate in the middle");
    }
    NSStackView *content = [layoutApprove.superview.superview isKindOfClass:NSStackView.class]
        ? (NSStackView *)layoutApprove.superview.superview : nil;
    if (content == nil || [content.arrangedSubviews indexOfObject:titleLabel] == NSNotFound ||
        [content.arrangedSubviews indexOfObject:originLabel] == NSNotFound ||
        [content.arrangedSubviews indexOfObject:layoutApprove.superview] == NSNotFound ||
        [content.arrangedSubviews indexOfObject:titleLabel] >= [content.arrangedSubviews indexOfObject:originLabel] ||
        [content.arrangedSubviews indexOfObject:originLabel] >= [content.arrangedSubviews indexOfObject:layoutApprove.superview]) {
      fail("card text and action row are not vertically ordered");
    }
    [layoutWindow orderOut:nil];
    puts("PASS agent-drawer-mac-approval exact-card-minters");
  }
  return 0;
}
