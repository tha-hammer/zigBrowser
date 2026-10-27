/* Product proof for first-run setup from the native drawer.
 *
 * The test executable doubles as the setup child: when relaunched with
 * --agent-setup it records that exact invocation and exits successfully.  The
 * parent drives a real ZBMacDrawerPanel Send with no configured helper and
 * requires visible progress, one shared setup task, completion, and no
 * terminal instruction. */
#import "agent_drawer_mac.h"
#import "agent_helper.h"

#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

static int helperSends;
static NSString *helperText;

int zb_agent_helper_configured(void) {
  const char *marker = getenv("ZB_FIRST_RUN_MARKER");
  return marker != NULL && access(marker, F_OK) == 0;
}
int zb_mac_drawer_e2e_enabled(void) { return 0; }
unsigned int zb_drawer_demo_messages(void) { return 0; }
void zb_agent_helper_send(unsigned int window_id, const char *text) {
  (void)window_id;
  helperSends++;
  helperText = text != NULL ? [NSString stringWithUTF8String:text] : nil;
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
  fprintf(stderr, "FAIL agent-drawer-mac-first-run: %s\n", message);
  exit(1);
}

static void collect_views(NSView *view, NSMutableArray<NSView *> *out) {
  [out addObject:view];
  for (NSView *child in view.subviews) collect_views(child, out);
}

static BOOL has_text(NSView *panel, NSString *text) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect_views(panel, views);
  for (NSView *view in views) {
    if ([view isKindOfClass:[NSTextView class]] &&
        [((NSTextView *)view).string isEqualToString:text]) return YES;
  }
  return NO;
}

static NSTextView *input_view(NSView *panel) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect_views(panel, views);
  for (NSView *view in views) {
    if ([view isKindOfClass:[NSTextView class]] && ((NSTextView *)view).editable) {
      return (NSTextView *)view;
    }
  }
  return nil;
}

static NSTextField *status_view(NSView *panel) {
  NSMutableArray<NSView *> *views = [NSMutableArray array];
  collect_views(panel, views);
  for (NSView *view in views) {
    if ([view isKindOfClass:[NSTextField class]] &&
        [((NSTextField *)view).stringValue isEqualToString:@"Not connected"]) {
      return (NSTextField *)view;
    }
  }
  return nil;
}

static void pump_until(BOOL (^done)(void), NSTimeInterval seconds) {
  NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
  while (!done() && [limit timeIntervalSinceNow] > 0) {
    @autoreleasepool {
      [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
  }
}

int main(int argc, char **argv) {
  const char *marker = getenv("ZB_FIRST_RUN_MARKER");
  if (argc == 2 && strcmp(argv[1], "--agent-setup") == 0) {
    if (marker == NULL) return 91;
    FILE *stream = fopen(marker, "a");
    if (stream == NULL) return 92;
    fputs("--agent-setup\n", stream);
    fclose(stream);
    return 0;
  }

  @autoreleasepool {
    if (marker == NULL || marker[0] != '/') fail("ZB_FIRST_RUN_MARKER must be absolute");
    unlink(marker);
    [NSApplication sharedApplication];
    NSView *panel = zb_mac_drawer_panel_create(NSMakeRect(0, 0, 760, 420), 1, NULL, NULL);
    NSTextView *input = input_view(panel);
    NSTextField *status = status_view(panel);
    if (input == nil || status == nil) fail("drawer controls are missing");
    input.string = @"hello";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [panel performSelector:@selector(sendInput)];
#pragma clang diagnostic pop

    if (![status.stringValue isEqualToString:@"Setting up the Claude Agent..."] ||
        !has_text(panel, @"Setting up the Claude Agent...")) {
      fail("Send did not show first-run setup progress");
    }
    __block BOOL joined = NO;
    __block BOOL joinSucceeded = NO;
    zb_mac_agent_setup_start_or_join(^(BOOL success, NSString *errorLine) {
      (void)errorLine;
      joinSucceeded = success;
      joined = YES;
    });
    pump_until(^BOOL { return access(marker, F_OK) == 0; }, 5.0);
    if (access(marker, F_OK) != 0) fail("Send did not relaunch this app with --agent-setup");
    pump_until(^BOOL { return helperSends == 1; }, 5.0);
    pump_until(^BOOL { return joined; }, 5.0);
    if (![status.stringValue isEqualToString:@"Starting…"] ||
        !has_text(panel, @"Claude Agent setup is complete.")) {
      fail("successful setup did not resume visibly");
    }
    if (helperSends != 1 || ![helperText isEqualToString:@"hello"])
      fail("successful setup did not resume the pending Send");
    if (!joined || !joinSucceeded) fail("second setup caller did not join the running task");
    NSString *invocations = [NSString stringWithContentsOfFile:
        [NSString stringWithUTF8String:marker] encoding:NSUTF8StringEncoding error:nil];
    if (![invocations isEqualToString:@"--agent-setup\n"])
      fail("shared setup coordinator launched more than one task");
    if (has_text(panel, @ZB_AGENT_TEXT_RUNTIME)) fail("drawer still tells the user to run a terminal command");
    puts("PASS agent-drawer-mac-first-run Send launches setup and shows progress");
  }
  return 0;
}
