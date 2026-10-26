/* Product scroll proof for the native Mac drawer.
 *
 * Repeated real panel appends must leave the newest bubble wholly visible.
 * A streamed bubble that grows while the user is already at the bottom must
 * continue following the bottom after AppKit has recalculated its height. */
#import "agent_drawer_mac.h"
#import "agent_helper.h"

#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

int zb_agent_helper_configured(void) { return 0; }
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
int zb_drawer_card_press(uint64_t card, int control, int own) {
  (void)card;
  (void)control;
  (void)own;
  return 0;
}
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

static void fail(NSString *message) {
  fprintf(stderr, "FAIL agent-drawer-mac-scroll: %s\n", message.UTF8String);
  exit(1);
}

static void collect(NSView *view, NSMutableArray<NSView *> *views) {
  [views addObject:view];
  for (NSView *child in view.subviews) collect(child, views);
}

static void settle(NSView *panel) {
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:0.08];
  do {
    [panel layoutSubtreeIfNeeded];
    [panel.window displayIfNeeded];
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                           beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
  } while ([until timeIntervalSinceNow] > 0);
  [panel layoutSubtreeIfNeeded];
}

static NSArray<NSTextView *> *messages(NSView *panel) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect(panel, views);
  NSMutableArray<NSTextView *> *result = [NSMutableArray array];
  for (NSView *view in views) {
    if ([view isKindOfClass:NSTextView.class] && !((NSTextView *)view).editable) {
      [result addObject:(NSTextView *)view];
    }
  }
  return result;
}

static NSScrollView *message_scroll(NSView *panel, NSTextView *message) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect(panel, views);
  for (NSView *view in views) {
    if (![view isKindOfClass:NSScrollView.class]) continue;
    NSScrollView *candidate = (NSScrollView *)view;
    NSView *ancestor = message;
    while (ancestor != nil && ancestor != candidate.documentView) ancestor = ancestor.superview;
    if (ancestor == candidate.documentView) return candidate;
  }
  return nil;
}

static BOOL newest_fully_visible(NSView *panel, NSString **detail) {
  NSArray<NSTextView *> *all = messages(panel);
  NSTextView *newest = all.lastObject;
  NSScrollView *scroll = newest != nil ? message_scroll(panel, newest) : nil;
  NSView *bubble = newest.superview;
  if (newest == nil || scroll == nil || bubble == nil) {
    if (detail != NULL) *detail = @"message list was not found";
    return NO;
  }
  NSRect bubbleRect = [scroll.documentView convertRect:bubble.bounds fromView:bubble];
  NSRect visible = scroll.documentVisibleRect;
  BOOL inside = NSMinY(bubbleRect) >= NSMinY(visible) - 0.5 &&
                NSMaxY(bubbleRect) <= NSMaxY(visible) + 0.5;
  if (!inside && detail != NULL) {
    *detail = [NSString stringWithFormat:@"newest=%@ visible=%@",
                                          NSStringFromRect(bubbleRect), NSStringFromRect(visible)];
  }
  return inside;
}

static void render(NSView *panel, NSString *path) {
  [panel displayIfNeeded];
  NSBitmapImageRep *bitmap = [panel bitmapImageRepForCachingDisplayInRect:panel.bounds];
  [panel cacheDisplayInRect:panel.bounds toBitmapImageRep:bitmap];
  NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  if (png == nil || ![png writeToFile:path atomically:YES]) fail(@"could not write PNG");
  printf("PNG\t%s\n", path.fileSystemRepresentation);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 2 || argv[1][0] != '/') fail(@"usage: scroll-test /absolute/output.png");
    [NSApplication sharedApplication];
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(100, 100, 900, 320)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];
    NSView *panel = zb_mac_drawer_panel_create(NSMakeRect(0, 0, 900, 320), 91, NULL, NULL);
    window.contentView = panel;
    [window makeKeyAndOrderFront:nil];
    for (NSUInteger index = 1; index <= 8; index++) {
      NSString *text = [NSString stringWithFormat:@"Message %lu: newest content must remain fully visible.",
                                                   (unsigned long)index];
      zb_mac_drawer_panel_append(panel, index % 2 == 0 ? "assistant" : "user", text.UTF8String);
      settle(panel);
      NSString *detail = nil;
      if (!newest_fully_visible(panel, &detail)) {
        fail([NSString stringWithFormat:@"append %lu clipped the newest bubble: %@",
                                            (unsigned long)index, detail]);
      }
    }

    const char *start = "Streaming reply";
    zb_drawer_agent_delta(91, "scroll", start, strlen(start));
    settle(panel);
    NSString *detail = nil;
    if (!newest_fully_visible(panel, &detail)) fail([@"stream start was clipped: " stringByAppendingString:detail]);
    NSString *growth = [@" — this update adds enough text to wrap across several lines while the reader remains "
                         @"at the bottom, so the complete growing bubble must stay visible after layout. "
                         @"The final sentence is the newest streamed content." copy];
    zb_drawer_agent_delta(91, "scroll", growth.UTF8String,
                          [growth lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    settle(panel);
    detail = nil;
    if (!newest_fully_visible(panel, &detail)) fail([@"stream growth clipped the newest bubble: " stringByAppendingString:detail]);

    render(panel, [NSString stringWithUTF8String:argv[1]]);
    [window orderOut:nil];
    puts("PASS agent-drawer-mac-scroll append-and-stream-follow-newest");
  }
  return 0;
}
