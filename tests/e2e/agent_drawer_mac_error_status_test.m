/* Product e2e for visible macOS agent failures.
 *
 * A helper failure must become a plain, selectable status line in the drawer;
 * changing only the header leaves the conversation looking hung. */
#import "agent_drawer_mac.h"
#import "agent_helper.h"

#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>

void zb_drawer_agent_status(unsigned int window_id, const char *state,
                            const char *reason);

int zb_agent_helper_configured(void) { return 1; }
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

static void fail(const char *message) {
  fprintf(stderr, "FAIL agent-drawer-mac-error-status: %s\n", message);
  exit(1);
}

static void collect_views(NSView *view, NSMutableArray<NSView *> *out) {
  [out addObject:view];
  for (NSView *child in view.subviews) collect_views(child, out);
}

static NSUInteger text_count(NSView *panel, NSString *text) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect_views(panel, views);
  NSUInteger count = 0;
  for (NSView *view in views) {
    if ([view isKindOfClass:[NSTextView class]] &&
        [((NSTextView *)view).string isEqualToString:text]) count += 1;
  }
  return count;
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSView *panel = zb_mac_drawer_panel_create(NSMakeRect(0, 0, 760, 420),
                                                77, NULL, NULL);
    if (panel == nil) fail("create returned nil");

    zb_drawer_agent_status(78, "unavailable", "cli-not-found");
    if (text_count(panel, @ZB_AGENT_TEXT_RUNTIME) != 0) {
      fail("another window's failure reached this drawer");
    }

    zb_drawer_agent_status(77, "unavailable", "cli-not-found");
    if (text_count(panel, @ZB_AGENT_TEXT_RUNTIME) != 1) {
      fail("CLI-not-found status line missing");
    }

    NSString *auth = @"Claude rejected the saved token. Open Account to replace it.";
    zb_drawer_agent_status(77, "unavailable", "auth");
    if (text_count(panel, auth) != 1) fail("authentication status line missing");

    NSString *limited = @"Claude is busy; try again shortly.";
    zb_drawer_agent_status(77, "unavailable", "rate-limited");
    zb_drawer_agent_status(77, "unavailable", "rate-limited");
    if (text_count(panel, limited) != 1) fail("rate-limit status was missing or repeated");

    puts("PASS agent-drawer-mac-error-status visible-terminal-failures");
  }
  return 0;
}
