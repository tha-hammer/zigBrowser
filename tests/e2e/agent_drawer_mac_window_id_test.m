#import "agent_drawer_mac.h"

#import <AppKit/AppKit.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>

static unsigned int sent_window_id;
static char sent_text[64];

int zb_agent_helper_configured(void) { return 1; }

void zb_agent_helper_send(unsigned int window_id, const char *text) {
  sent_window_id = window_id;
  snprintf(sent_text, sizeof sent_text, "%s", text != NULL ? text : "");
}

void zb_mac_secrets_window_open(NSWindow *parent) { (void)parent; }

static void fail(const char *message) {
  fprintf(stderr, "FAIL agent-drawer-mac-window-id: %s\n", message);
  exit(1);
}

static void collect_views(NSView *view, NSMutableArray<NSView *> *out) {
  [out addObject:view];
  for (NSView *child in view.subviews) collect_views(child, out);
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp finishLaunching];

    const unsigned int stable_id = 0x10203040u;
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 760, 420)
                  styleMask:NSWindowStyleMaskTitled
                    backing:NSBackingStoreBuffered
                      defer:NO];
    NSView *panel = zb_mac_drawer_panel_create(
        NSMakeRect(0, 0, 760, 420), stable_id, NULL, NULL);
    if (panel == nil) fail("create returned nil");
    window.contentView = panel;
    [panel layoutSubtreeIfNeeded];

    NSMutableArray<NSView *> *views = [NSMutableArray array];
    collect_views(panel, views);
    NSTextView *input = nil;
    NSButton *send = nil;
    for (NSView *view in views) {
      if ([view isKindOfClass:[NSTextView class]] &&
          ((NSTextView *)view).editable) {
        input = (NSTextView *)view;
      }
      if ([view isKindOfClass:[NSButton class]] &&
          [((NSButton *)view).title isEqualToString:@"Send"]) {
        send = (NSButton *)view;
      }
    }
    if (input == nil || send == nil) fail("composer controls missing");
    if ((unsigned int)window.windowNumber == stable_id) {
      fail("test control: AppKit window number equals stable id");
    }

    input.string = @"route this window";
    [send performClick:nil];
    if (sent_window_id != stable_id) {
      fprintf(stderr,
              "FAIL agent-drawer-mac-window-id: helper received %u, want %u\n",
              sent_window_id, stable_id);
      return 1;
    }
    if (strcmp(sent_text, "route this window") != 0) {
      fail("helper did not receive the composer text");
    }

    [window orderOut:nil];
    puts("PASS agent-drawer-mac-window-id stable host id reaches helper send");
  }
  return 0;
}
