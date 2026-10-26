#import "agent_drawer_mac.h"
#import "agent_helper.h"

#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>

void zb_mac_drawer_panel_bind_window_id(NSView *panel, unsigned int window_id);

int zb_agent_helper_configured(void) { return 0; }
void zb_agent_helper_send(unsigned int window_id, const char *text) {
  (void)window_id;
  (void)text;
}
void zb_mac_secrets_window_open(NSWindow *parent) { (void)parent; }

static void fail(const char *message) {
  fprintf(stderr, "FAIL agent-drawer-mac-stream: %s\n", message);
  exit(1);
}

static void collect_text_views(NSView *view, NSMutableArray<NSTextView *> *out) {
  if ([view isKindOfClass:[NSTextView class]]) [out addObject:(NSTextView *)view];
  for (NSView *child in view.subviews) collect_text_views(child, out);
}

static NSArray<NSString *> *messages(NSView *panel) {
  NSMutableArray<NSTextView *> *views = [NSMutableArray array];
  collect_text_views(panel, views);
  NSMutableArray<NSString *> *result = [NSMutableArray array];
  for (NSTextView *view in views) {
    if (!view.editable) [result addObject:view.string];
  }
  return result;
}

static void require_messages(NSView *panel, NSArray<NSString *> *expected, const char *step) {
  NSArray<NSString *> *actual = messages(panel);
  if (![actual isEqualToArray:expected]) {
    fprintf(stderr, "FAIL agent-drawer-mac-stream: %s got %s\n", step, actual.description.UTF8String);
    exit(1);
  }
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSView *panel = zb_mac_drawer_panel_create(NSMakeRect(0, 0, 760, 420), NULL, NULL);
    if (panel == nil) fail("create returned nil");
    zb_mac_drawer_panel_bind_window_id(panel, 77);

    zb_drawer_agent_delta(78, "other", "wrong", 5);
    require_messages(panel, @[], "a different window changed this drawer");

    zb_drawer_agent_delta(77, "reply", "Hel", 3);
    require_messages(panel, @[@"Hel"], "first delta did not create one live assistant bubble");
    zb_drawer_agent_delta(77, "reply", "lo", 2);
    require_messages(panel, @[@"Hello"], "second delta did not extend the same bubble");

    zb_drawer_agent_message(77, "assistant", "Hello!", 6);
    require_messages(panel, @[@"Hello!"], "final message did not replace the live text");
    zb_drawer_agent_end(77);

    zb_drawer_agent_delta(77, "next", "Again", 5);
    zb_drawer_agent_stopped(77);
    require_messages(panel, @[@"Hello!", @"Again (stopped)"], "stopped reply was not settled");

    zb_drawer_agent_delta(77, "capped", "clip", 4);
    zb_drawer_agent_capped(77);
    zb_drawer_agent_delta(77, "capped", " ignored", 8);
    zb_drawer_agent_message(77, "assistant", "replacement", 11);
    require_messages(panel,
                     @[@"Hello!", @"Again (stopped)", @"clip\n[output truncated]"],
                     "capped reply changed after becoming final");

    puts("PASS agent-drawer-mac-stream live-callback-routing");
  }
  return 0;
}
