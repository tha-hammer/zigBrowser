/* Product layout proof for the native Mac drawer.
 *
 * This mounts the real panel in a 1200x320 AppKit window, lays it out, renders
 * the result to the requested PNG, and then checks the same geometry the owner
 * sees: a full-width top header, scrolling middle, and full-width bottom
 * composer with Sign in and minimize in their specified positions. */
#import "agent_drawer_mac.h"
#import "agent_helper.h"

#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>

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
  fprintf(stderr, "FAIL agent-drawer-mac-layout: %s\n", message.UTF8String);
  exit(1);
}

static void collect(NSView *view, NSMutableArray<NSView *> *views) {
  [views addObject:view];
  for (NSView *child in view.subviews) collect(child, views);
}

static NSButton *button(NSArray<NSView *> *views, NSString *title) {
  for (NSView *view in views) {
    if ([view isKindOfClass:NSButton.class] &&
        [((NSButton *)view).title isEqualToString:title]) return (NSButton *)view;
  }
  return nil;
}

static NSTextField *label(NSArray<NSView *> *views, NSString *text) {
  for (NSView *view in views) {
    if ([view isKindOfClass:NSTextField.class] &&
        [((NSTextField *)view).stringValue isEqualToString:text]) return (NSTextField *)view;
  }
  return nil;
}

static NSTextView *composer(NSArray<NSView *> *views) {
  for (NSView *view in views) {
    if ([view isKindOfClass:NSTextView.class] && ((NSTextView *)view).editable) {
      return (NSTextView *)view;
    }
  }
  return nil;
}

static NSRect in_panel(NSView *view, NSView *panel) {
  return [panel convertRect:view.bounds fromView:view];
}

static void render(NSView *panel, NSString *path) {
  [panel displayIfNeeded];
  NSBitmapImageRep *bitmap = [panel bitmapImageRepForCachingDisplayInRect:panel.bounds];
  if (bitmap == nil) fail(@"could not allocate panel bitmap");
  [panel cacheDisplayInRect:panel.bounds toBitmapImageRep:bitmap];
  NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  if (png == nil || ![png writeToFile:path atomically:YES]) fail(@"could not write panel PNG");
  printf("PNG\t%s\n", path.fileSystemRepresentation);
  fflush(stdout);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 2 || argv[1][0] != '/') fail(@"usage: layout-test /absolute/output.png");
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];

    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(100, 100, 1200, 320)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    NSView *panel = zb_mac_drawer_panel_create(NSMakeRect(0, 0, 1200, 320),
                                                1, NULL, NULL);
    window.contentView = panel;
    [window makeKeyAndOrderFront:nil];
    zb_mac_drawer_panel_append(panel, "assistant", "The drawer is ready to help with this page.");
    zb_mac_drawer_panel_append(panel, "status", "Messages stay selectable and copyable.");
    [panel setNeedsLayout:YES];
    [panel layoutSubtreeIfNeeded];
    [window displayIfNeeded];
    render(panel, [NSString stringWithUTF8String:argv[1]]);

    NSMutableArray<NSView *> *views = [NSMutableArray array];
    collect(panel, views);
    NSTextField *title = label(views, @"Claude Agent");
    NSTextField *status = label(views, @"Not connected");
    NSButton *signin = button(views, @"Sign in");
    NSButton *minus = button(views, @"−");
    NSButton *send = button(views, @"Send");
    NSTextView *input = composer(views);
    if (title == nil || status == nil || signin == nil || minus == nil || send == nil || input == nil) {
      fail(@"missing Claude Agent, status, Sign in, minimize, Send, or composer");
    }
    if (signin.hidden || signin.superview.hidden) fail(@"Sign in is hidden while Not connected");

    NSView *header = title.superview;
    NSScrollView *input_scroll = input.enclosingScrollView;
    NSView *input_row = input_scroll.superview;
    NSRect header_frame = in_panel(header, panel);
    NSRect input_frame = in_panel(input_scroll, panel);
    NSRect input_row_frame = in_panel(input_row, panel);
    NSRect send_frame = in_panel(send, panel);
    NSRect minus_frame = in_panel(minus, panel);
    NSRect signin_frame = in_panel(signin, panel);
    if (NSWidth(header_frame) < 1198 || NSMinX(header_frame) > 1 ||
        NSMaxY(header_frame) < 319) {
      fail([NSString stringWithFormat:@"header is not full-width at top: %@",
                                          NSStringFromRect(header_frame)]);
    }
    if (NSWidth(input_row_frame) < 1198 || NSMinX(input_row_frame) > 1 ||
        NSMinY(input_row_frame) > 1) {
      fail([NSString stringWithFormat:@"input row is not full-width at bottom: %@",
                                          NSStringFromRect(input_row_frame)]);
    }
    if (NSHeight(input_frame) < 62 || NSHeight(input_frame) > 125) {
      fail([NSString stringWithFormat:@"input is not three-to-six lines tall: %@",
                                          NSStringFromRect(input_frame)]);
    }
    if (NSWidth(input_frame) < 1000 || NSMaxX(input_frame) >= NSMinX(send_frame) ||
        NSMaxX(send_frame) > 1192 || NSMidY(send_frame) < NSMinY(input_frame) ||
        NSMidY(send_frame) > NSMaxY(input_frame)) {
      fail([NSString stringWithFormat:@"Send is not right of the full-width input: input=%@ send=%@",
                                          NSStringFromRect(input_frame), NSStringFromRect(send_frame)]);
    }
    if (NSMaxX(minus_frame) < 1192 || NSMinX(minus_frame) <= NSMaxX(signin_frame)) {
      fail([NSString stringWithFormat:@"minimize is not the rightmost header control: sign-in=%@ minus=%@",
                                          NSStringFromRect(signin_frame), NSStringFromRect(minus_frame)]);
    }

    for (NSView *view in views) {
      if ([view isKindOfClass:NSTextView.class] && !((NSTextView *)view).editable &&
          (!((NSTextView *)view).selectable || ((NSTextView *)view).richText)) {
        fail(@"message text is not selectable inert text");
      }
    }
    [window orderOut:nil];
    puts("PASS agent-drawer-mac-layout top-header-scroll-middle-wide-composer");
  }
  return 0;
}
