/* Product e2e for the macOS permission round trip.
 *
 * A fake helper emits the same validated tool-call fields as the real helper.
 * The drawer must deliver them on AppKit's main thread, render the resulting
 * approval card, and return a Deny tool result to that helper. */
#import "agent_drawer_mac.h"

#import <AppKit/AppKit.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

void zb_drawer_agent_tool_call(unsigned int window_id, const char *session,
                               int64_t prompt_id, const char *request_id,
                               size_t request_id_length, const char *tool,
                               size_t tool_length, const char *arguments,
                               size_t arguments_length);
void zb_drawer_card_show(unsigned int main_window, uint64_t card,
                         const char *verb, unsigned int bound_window,
                         const char *params, size_t params_length,
                         const char *url, const char *origin);

static int routed;
static int denied;
static int result_ok = -1;
static char result_body[128];

int zb_agent_helper_configured(void) { return 1; }
void zb_agent_helper_send(unsigned int window_id, const char *text) {
  (void)window_id;
  (void)text;
}
void zb_mac_secrets_window_open(NSWindow *parent) { (void)parent; }

/* This is the real tool boundary called by the macOS drawer bridge.  The fake
 * helper's request is deliberately checked here before its card is shown. */
void zb_agent_tools_call(unsigned int window_id, const char *session,
                         int64_t prompt_id, const char *request_id,
                         size_t request_id_length, const char *tool,
                         size_t tool_length, const char *arguments,
                         size_t arguments_length) {
  if (![NSThread isMainThread]) return;
  if (window_id != 77 || strcmp(session, "fake-session") != 0 ||
      prompt_id != 9 || request_id_length != 6 ||
      memcmp(request_id, "call-1", 6) != 0 ||
      tool_length != strlen("mcp__zigbrowser__navigate") ||
      memcmp(tool, "mcp__zigbrowser__navigate", tool_length) != 0 ||
      arguments_length != strlen("{\"url\":\"https://deny.test/\"}") ||
      memcmp(arguments, "{\"url\":\"https://deny.test/\"}", arguments_length) != 0) return;
  routed += 1;
  zb_drawer_card_show(77, 401, "navigate", 77, arguments,
                      arguments_length, "https://deny.test/",
                      "https://origin.test");
}

static void fake_agent_tool_result(int ok, const char *body) {
  result_ok = ok;
  snprintf(result_body, sizeof result_body, "%s", body);
}

/* The accepted approval-card slice already binds this call to the portable
 * card press and agent_tools minters.  This test supplies their fake-agent
 * sink so the newly routed request can be observed end to end. */
int zb_drawer_card_press(uint64_t card, int control, int own) {
  if (card != 401 || control != 2 || own != 1) return 0;
  denied += 1;
  fake_agent_tool_result(0, "The navigation was denied.");
  return 2;
}

static void fail(const char *message) {
  fprintf(stderr, "FAIL agent-drawer-mac-permission: %s\n", message);
  exit(1);
}

static void collect_views(NSView *view, NSMutableArray<NSView *> *out) {
  [out addObject:view];
  for (NSView *child in view.subviews) collect_views(child, out);
}

static NSButton *button_named(NSView *panel, NSString *title) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect_views(panel, views);
  for (NSView *view in views) {
    if ([view isKindOfClass:[NSButton class]] &&
        [((NSButton *)view).title isEqualToString:title]) return (NSButton *)view;
  }
  return nil;
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSView *panel = zb_mac_drawer_panel_create(NSMakeRect(0, 0, 760, 420),
                                                77, NULL, NULL);
    if (panel == nil) fail("create returned nil");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      const char *args = "{\"url\":\"https://deny.test/\"}";
      zb_drawer_agent_tool_call(77, "fake-session", 9, "call-1", 6,
                                "mcp__zigbrowser__navigate",
                                strlen("mcp__zigbrowser__navigate"), args,
                                strlen(args));
    });

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    NSButton *deny_button = nil;
    while (deny_button == nil && [deadline timeIntervalSinceNow] > 0) {
      [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
      deny_button = button_named(panel, @"Deny");
    }
    if (routed != 1 || deny_button == nil) fail("permission request did not reach its drawer card");
    [deny_button performClick:nil];
    if (denied != 1 || result_ok != 0 ||
        strcmp(result_body, "The navigation was denied.") != 0) {
      fail("fake agent did not receive the exact denial");
    }
    puts("PASS agent-drawer-mac-permission helper-card-deny-roundtrip");
  }
  return 0;
}
