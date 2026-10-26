/* AppKit host for the native Agent Drawer.
 *
 * The host is deliberately small: one content view owns the WKWebView and the
 * docked panel, and portable drawer geometry remains in agent_drawer.zig.
 * State is associated with the NSWindow so replacing a crashed WKWebView does
 * not replace the drawer or its open state. */

#import "agent_drawer_mac.h"

#import <objc/runtime.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  int x, y, w, h;
} ZbMacDrawerRect;

void zb_drawer_page_rect(int width, int height, int open, ZbMacDrawerRect *out);
void zb_drawer_appkit_frame(const ZbMacDrawerRect *rect, int width, int height,
                            ZbMacDrawerRect *out);

/* Internal shim seam. It keeps every debug-only action behind --e2e-protocol. */
int zb_mac_drawer_e2e_enabled(void);

/* The panel is landing independently. A weak import lets the host compile and
 * show its dock now; the real panel is used automatically once linked. */
extern NSView *zb_mac_drawer_panel_create(NSRect frame,
                                           void (*on_minimize)(void *ctx),
                                           void *ctx) __attribute__((weak_import));
extern void zb_mac_drawer_panel_focus_input(NSView *panel)
    __attribute__((weak_import));
extern void zb_mac_drawer_panel_e2e_send(NSView *panel, const char *utf8_text)
    __attribute__((weak_import));
extern void zb_mac_drawer_panel_append(NSView *panel, const char *role,
                                       const char *utf8_text)
    __attribute__((weak_import));

@class ZBMacDrawerState;

@interface ZBMacDrawerHostView : NSView
@property(nonatomic, weak) ZBMacDrawerState *drawerState;
@end

@interface ZBMacDrawerState : NSObject
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, strong) ZBMacDrawerHostView *host;
@property(nonatomic, strong) NSView *page;
@property(nonatomic, strong) NSView *panel;
@property(nonatomic, assign, getter=isOpen) BOOL open;
@property(nonatomic, assign) uint32_t identifier;
@property(nonatomic, copy) NSString *pendingRowKind;
- (void)layoutViews;
@end

static const void *const kZBMacDrawerStateKey = &kZBMacDrawerStateKey;
static uint32_t g_zb_mac_drawer_next_identifier = 0;
static BOOL g_zb_mac_drawer_enabled = NO;
static NSString *g_zb_mac_drawer_status = nil;

void zb_app_set_agent_drawer(int enabled) {
  g_zb_mac_drawer_enabled = enabled != 0;
}

int zb_app_get_agent_drawer(void) {
  return g_zb_mac_drawer_enabled ? 1 : 0;
}

void zb_app_set_agent_drawer_status(const char *status) {
  @autoreleasepool {
    if (status == NULL) {
      g_zb_mac_drawer_status = nil;
      return;
    }
    NSString *value = [NSString stringWithUTF8String:status];
    g_zb_mac_drawer_status = value != nil ? [value copy] : nil;
  }
}

static NSRect zb_nsrect(ZbMacDrawerRect rect) {
  return NSMakeRect((CGFloat)rect.x, (CGFloat)rect.y, (CGFloat)rect.w,
                    (CGFloat)rect.h);
}

static ZBMacDrawerState *zb_state(NSWindow *window) {
  return window != nil
             ? objc_getAssociatedObject(window, kZBMacDrawerStateKey)
             : nil;
}

static void zb_mac_drawer_minimize(void *context) {
  ZBMacDrawerState *state = (__bridge ZBMacDrawerState *)context;
  if (state.window != nil) {
    zb_mac_drawer_set_open(state.window, 0);
  }
}

static NSView *zb_make_panel(NSRect frame, ZBMacDrawerState *state) {
  if (zb_mac_drawer_panel_create != NULL) {
    return zb_mac_drawer_panel_create(frame, zb_mac_drawer_minimize,
                                      (__bridge void *)state);
  }
  return [[NSView alloc] initWithFrame:frame];
}

@implementation ZBMacDrawerHostView

- (void)layout {
  [super layout];
  [self.drawerState layoutViews];
}

@end


@implementation ZBMacDrawerState

- (void)layoutViews {
  NSRect bounds = self.host.bounds;
  int width = (int)NSWidth(bounds);
  int height = (int)NSHeight(bounds);

  ZbMacDrawerRect page_top = {0};
  ZbMacDrawerRect page_frame = {0};
  zb_drawer_page_rect(width, height, self.open ? 1 : 0, &page_top);
  zb_drawer_appkit_frame(&page_top, width, height, &page_frame);

  ZbMacDrawerRect panel_top = {
      .x = 0,
      .y = page_top.h,
      .w = width,
      .h = height - page_top.h,
  };
  ZbMacDrawerRect panel_frame = {0};
  zb_drawer_appkit_frame(&panel_top, width, height, &panel_frame);

  self.page.frame = zb_nsrect(page_frame);
  self.panel.frame = zb_nsrect(panel_frame);
  self.panel.hidden = !self.open;

  NSString *kind = self.pendingRowKind;
  if (kind != nil && zb_mac_drawer_e2e_enabled()) {
    self.pendingRowKind = nil;
    printf("DRAWER\t%u\t%s\tpage=%d,%d,%d,%d\tpanel=%d,%d,%d,%d\n",
           self.identifier, kind.UTF8String, page_frame.x, page_frame.y,
           page_frame.w, page_frame.h, panel_frame.x, panel_frame.y,
           panel_frame.w, panel_frame.h);
    fflush(stdout);
  }
}

@end


void zb_mac_drawer_attach(NSWindow *window, NSView *webview) {
  if (!g_zb_mac_drawer_enabled || window == nil || webview == nil) {
    return;
  }

  ZBMacDrawerState *state = zb_state(window);
  if (state != nil) {
    if (state.page != webview) {
      [state.page removeFromSuperview];
      state.page = webview;
      [state.host addSubview:webview
                  positioned:NSWindowBelow
                  relativeTo:state.panel];
      [state.host setNeedsLayout:YES];
      [state.host layoutSubtreeIfNeeded];
    }
    return;
  }

  state = [[ZBMacDrawerState alloc] init];
  state.window = window;
  state.page = webview;
  state.identifier = ++g_zb_mac_drawer_next_identifier;

  NSRect bounds = window.contentView != nil ? window.contentView.bounds
                                             : NSMakeRect(0, 0, 0, 0);
  ZBMacDrawerHostView *host =
      [[ZBMacDrawerHostView alloc] initWithFrame:bounds];
  host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  host.drawerState = state;
  state.host = host;
  state.panel = zb_make_panel(NSZeroRect, state);
  state.panel.hidden = YES;
  BOOL status_shown = NO;
  if (g_zb_mac_drawer_status != nil && zb_mac_drawer_panel_append != NULL) {
    zb_mac_drawer_panel_append(state.panel, "status",
                               g_zb_mac_drawer_status.UTF8String);
    status_shown = YES;
  }

  [webview removeFromSuperview];
  [host addSubview:webview];
  [host addSubview:state.panel positioned:NSWindowAbove relativeTo:webview];
  objc_setAssociatedObject(window, kZBMacDrawerStateKey, state,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  window.contentView = host;
  [host setNeedsLayout:YES];
  [host layoutSubtreeIfNeeded];

  if (status_shown && zb_mac_drawer_e2e_enabled()) {
    printf("DRAWER\t%u\tmsg\tsystem\t%s\n", state.identifier,
           g_zb_mac_drawer_status.UTF8String);
    fflush(stdout);
  }

  const char *agent_prompt = getenv("ZB_DEBUG_DRAWER_AGENT_SEND");
  if (zb_mac_drawer_e2e_enabled() && agent_prompt != NULL && agent_prompt[0] != '\0' &&
      zb_mac_drawer_panel_e2e_send != NULL) {
    NSString *prompt = [NSString stringWithUTF8String:agent_prompt];
    if (prompt == nil) prompt = @"";
    zb_mac_drawer_set_open(window, 1);
    __weak ZBMacDrawerState *weak_state = state;
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBMacDrawerState *strong_state = weak_state;
      if (strong_state == nil || strong_state.window == nil) return;
      zb_mac_drawer_panel_e2e_send(strong_state.panel, prompt.UTF8String);
    });
  }

  const char *debug = getenv("ZB_DEBUG_DRAWER_LAYOUT");
  if (zb_mac_drawer_e2e_enabled() && debug != NULL && strcmp(debug, "1") == 0) {
    state.pendingRowKind = @"open";
    zb_mac_drawer_set_open(window, 1);
    __weak ZBMacDrawerState *weak_state = state;
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBMacDrawerState *strong_state = weak_state;
      if (strong_state == nil || strong_state.window == nil) {
        return;
      }
      strong_state.pendingRowKind = @"resize";
      [strong_state.window setContentSize:NSMakeSize(800, 600)];
      [strong_state.host setNeedsLayout:YES];
      [strong_state.host layoutSubtreeIfNeeded];
    });
  }
}

void zb_mac_drawer_set_open(NSWindow *window, int open) {
  ZBMacDrawerState *state = zb_state(window);
  if (state == nil) {
    return;
  }
  BOOL wanted = open != 0;
  if (state.open == wanted) {
    if (wanted && zb_mac_drawer_panel_focus_input != NULL) {
      zb_mac_drawer_panel_focus_input(state.panel);
    }
    return;
  }
  state.open = wanted;
  [state.host setNeedsLayout:YES];
  [state.host layoutSubtreeIfNeeded];
  if (wanted && zb_mac_drawer_panel_focus_input != NULL) {
    zb_mac_drawer_panel_focus_input(state.panel);
  }
}

int zb_mac_drawer_is_open(NSWindow *window) {
  ZBMacDrawerState *state = zb_state(window);
  return state != nil && state.open ? 1 : 0;
}
