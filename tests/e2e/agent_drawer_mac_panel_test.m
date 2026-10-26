#import "agent_drawer_mac.h"

#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static void fail(const char *message) {
  fprintf(stderr, "FAIL agent-drawer-mac-panel: %s\n", message);
  exit(1);
}

static void record_minimize(void *context) {
  int *count = context;
  *count += 1;
}

static void collect_views(NSView *view, NSMutableArray<NSView *> *out) {
  [out addObject:view];
  for (NSView *child in view.subviews) collect_views(child, out);
}

static NSButton *button_named(NSArray<NSView *> *views, NSString *title) {
  for (NSView *view in views) {
    if ([view isKindOfClass:[NSButton class]] && [((NSButton *)view).title isEqualToString:title]) {
      return (NSButton *)view;
    }
  }
  return nil;
}

static NSTextView *text_view_named(NSArray<NSView *> *views, NSString *text, BOOL editable) {
  for (NSView *view in views) {
    if (![view isKindOfClass:[NSTextView class]]) continue;
    NSTextView *candidate = (NSTextView *)view;
    if (candidate.editable == editable && [candidate.string isEqualToString:text]) return candidate;
  }
  return nil;
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    [NSApp activateIgnoringOtherApps:YES];
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 760, 420)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];
    int minimized = 0;
    NSView *panel = zb_mac_drawer_panel_create(NSMakeRect(0, 0, 760, 420), record_minimize, &minimized);
    if (panel == nil) fail("create returned nil");
    window.contentView = panel;
    [window makeKeyAndOrderFront:nil];
    NSDate *activationDeadline = [NSDate dateWithTimeIntervalSinceNow:0.25];
    while ([activationDeadline timeIntervalSinceNow] > 0) {
      NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                          untilDate:activationDeadline
                                             inMode:NSDefaultRunLoopMode
                                            dequeue:YES];
      if (event == nil) break;
      [NSApp sendEvent:event];
    }
    [NSApp updateWindows];
    [panel layoutSubtreeIfNeeded];

    zb_mac_drawer_panel_append(panel, "user", "<b>literal user</b>");
    zb_mac_drawer_panel_append(panel, "assistant", "assistant & plain");
    zb_mac_drawer_panel_append(panel, "status", "runtime status");
    [panel layoutSubtreeIfNeeded];

    NSMutableArray<NSView *> *views = [NSMutableArray array];
    collect_views(panel, views);
    if (button_named(views, @"−") == nil && button_named(views, @"-") == nil) fail("missing minimize button");
    if (button_named(views, @"Send") == nil) fail("missing Send button");

    BOOL title = NO;
    BOOL scroll = NO;
    NSTextView *input = nil;
    for (NSView *view in views) {
      if ([view isKindOfClass:[NSTextField class]] && [((NSTextField *)view).stringValue isEqualToString:@"Claude Agent"]) {
        title = YES;
      }
      if ([view isKindOfClass:[NSScrollView class]]) scroll = YES;
      if ([view isKindOfClass:[NSTextView class]] && ((NSTextView *)view).editable) input = (NSTextView *)view;
    }
    if (!title) fail("missing Claude Agent title");
    if (!scroll) fail("missing scrolling message list");
    if (input == nil) fail("missing multi-line input");

    NSTextView *message = text_view_named(views, @"<b>literal user</b>", NO);
    if (message == nil) fail("user message was not appended verbatim");
    if (!message.selectable || message.richText || message.importsGraphics) fail("message is not inert selectable plain text");
    if (text_view_named(views, @"assistant & plain", NO) == nil) fail("assistant message missing");
    if (text_view_named(views, @"runtime status", NO) == nil) fail("status message missing");

    [message setSelectedRange:NSMakeRange(0, 3)];
    if (![window makeFirstResponder:message]) fail("message could not become first responder");
    [NSPasteboard.generalPasteboard clearContents];
    // The application's Edit > Copy item invokes this standard responder action.
    [message copy:nil];
    if (![[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"<b>"]) {
      fail("Edit > Copy did not preserve original text");
    }

    zb_mac_drawer_panel_focus_input(panel);
    if (window.firstResponder != input) fail("focus_input did not focus the composer");
    if (minimized != 0) fail("panel minimized without a click");

    [window orderOut:nil];
    puts("PASS agent-drawer-mac-panel basic-view-and-messages");
  }
  return 0;
}
