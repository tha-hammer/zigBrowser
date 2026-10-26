/* AppKit host for the native Agent Drawer.
 *
 * The host is deliberately small: one content view owns the WKWebView and the
 * docked panel, and portable drawer geometry remains in agent_drawer.zig.
 * State is associated with the NSWindow so replacing a crashed WKWebView does
 * not replace the drawer or its open state. */

#import "agent_drawer_mac.h"

#import <objc/runtime.h>

#include <math.h>
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
int zb_drawer_classify(double dx, double dy);
void zb_drawer_place(const void *ratios, int width, int height,
                     ZbMacDrawerRect *out);
void zb_drawer_clamp(ZbMacDrawerRect *rect, int width, int height);
void zb_drawer_lerp(const ZbMacDrawerRect *from, const ZbMacDrawerRect *to,
                    double progress, ZbMacDrawerRect *out);
double zb_drawer_ease(double progress);
unsigned int zb_drawer_anim_ms(void);

typedef struct {
  double x, y;
} ZbMacDrawerRatios;

void zb_drawer_ratios_of(const ZbMacDrawerRect *rect, int width, int height,
                         ZbMacDrawerRatios *out);
int zb_drawer_start_ratios(ZbMacDrawerRatios *out);
void zb_drawer_remember(const ZbMacDrawerRatios *ratios);

/* Internal shim seam. It keeps every debug-only action behind --e2e-protocol. */
int zb_mac_drawer_e2e_enabled(void);
void zb_mac_drawer_debug_open_window(void);
void zb_mac_e2e_snapshot_window(NSWindow *window, unsigned int window_id);

/* The panel is landing independently. A weak import lets the host compile and
 * show its dock now; the real panel is used automatically once linked. */
extern NSView *zb_mac_drawer_panel_create(NSRect frame,
                                           unsigned int window_id,
                                           void (*on_minimize)(void *ctx),
                                           void *ctx) __attribute__((weak_import));
extern void zb_mac_drawer_panel_focus_input(NSView *panel)
    __attribute__((weak_import));
extern void zb_mac_drawer_panel_e2e_send(NSView *panel, const char *utf8_text)
    __attribute__((weak_import));
extern void zb_mac_drawer_panel_append(NSView *panel, const char *role,
                                       const char *utf8_text)
    __attribute__((weak_import));
extern void zb_agent_tools_window_opened(unsigned int window_id)
    __attribute__((weak_import));
extern void zb_agent_tools_window_closed(unsigned int window_id)
    __attribute__((weak_import));
extern void zb_agent_tools_drawer_showing(unsigned int window_id, int shown)
    __attribute__((weak_import));
extern void zb_mac_agent_tools_e2e_start(unsigned int window_id)
    __attribute__((weak_import));

@class ZBMacDrawerState;
@class ZBMacDrawerIcon;
@class ZBMacDrawerMenuTarget;

@interface ZBMacDrawerHostView : NSView
@property(nonatomic, weak) ZBMacDrawerState *drawerState;
@end

@interface ZBMacDrawerState : NSObject
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, strong) ZBMacDrawerHostView *host;
@property(nonatomic, strong) NSView *page;
@property(nonatomic, strong) NSView *panel;
@property(nonatomic, strong) ZBMacDrawerIcon *icon;
@property(nonatomic, strong) NSView *foldView;
@property(nonatomic, strong) NSTimer *foldTimer;
@property(nonatomic, assign, getter=isOpen) BOOL open;
@property(nonatomic, assign, getter=isFolding) BOOL folding;
@property(nonatomic, assign) uint32_t identifier;
@property(nonatomic, copy) NSString *pendingRowKind;
@property(nonatomic, copy) NSString *pendingIconKind;
@property(nonatomic, assign) BOOL hasRatios;
@property(nonatomic, assign) ZbMacDrawerRatios ratios;
@property(nonatomic, assign) ZbMacDrawerRect iconRect;
@property(nonatomic, assign) ZbMacDrawerRect foldFrom;
@property(nonatomic, assign) ZbMacDrawerRect foldTo;
@property(nonatomic, assign) ZbMacDrawerRect foldReported;
@property(nonatomic, assign) BOOL foldReportedValid;
@property(nonatomic, assign) BOOL debugMinusClicked;
@property(nonatomic, assign) NSTimeInterval foldStarted;
@property(nonatomic, assign) NSUInteger foldFrames;
@property(nonatomic, strong) id closeObserver;
- (void)layoutViews;
- (void)applyIconFrame;
- (void)beginFold;
- (void)cancelFold;
@end

@interface ZBMacDrawerIcon : NSButton
@property(nonatomic, weak) ZBMacDrawerState *drawerState;
@end

static const void *const kZBMacDrawerStateKey = &kZBMacDrawerStateKey;
static BOOL g_zb_mac_drawer_enabled = NO;
static NSString *g_zb_mac_drawer_status = nil;
static ZBMacDrawerMenuTarget *g_zb_mac_drawer_menu_target = nil;
static NSMenuItem *g_zb_mac_drawer_menu_item = nil;
static id g_zb_mac_drawer_key_monitor = nil;

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

static ZbMacDrawerRect zb_mac_rect(NSRect rect) {
  return (ZbMacDrawerRect){
      .x = (int)lround(NSMinX(rect)),
      .y = (int)lround(NSMinY(rect)),
      .w = (int)lround(NSWidth(rect)),
      .h = (int)lround(NSHeight(rect)),
  };
}

static BOOL zb_mac_fold_debug_enabled(void) {
  const char *value = getenv("ZB_DEBUG_DRAWER_FOLD");
  return zb_mac_drawer_e2e_enabled() && value != NULL &&
         strcmp(value, "1") == 0;
}

static NSButton *zb_mac_find_minus(NSView *view) {
  if ([view isKindOfClass:NSButton.class]) {
    NSButton *button = (NSButton *)view;
    if ([button.title isEqualToString:@"−"] &&
        [button.accessibilityLabel isEqualToString:@"Minimize Claude Agent"]) {
      return button;
    }
  }
  for (NSView *child in view.subviews) {
    NSButton *found = zb_mac_find_minus(child);
    if (found != nil) return found;
  }
  return nil;
}

static ZBMacDrawerState *zb_state(NSWindow *window) {
  return window != nil
             ? objc_getAssociatedObject(window, kZBMacDrawerStateKey)
             : nil;
}

static NSWindow *zb_mac_drawer_menu_window(void) {
  if (zb_state(NSApp.keyWindow) != nil) {
    return NSApp.keyWindow;
  }
  if (zb_state(NSApp.mainWindow) != nil) {
    return NSApp.mainWindow;
  }
  for (NSWindow *window in NSApp.orderedWindows) {
    if (zb_state(window) != nil) {
      return window;
    }
  }
  return nil;
}

@interface ZBMacDrawerMenuTarget : NSObject
- (void)toggleDrawer:(id)sender;
@end

@implementation ZBMacDrawerMenuTarget

- (void)toggleDrawer:(id)sender {
  (void)sender;
  NSWindow *window = zb_mac_drawer_menu_window();
  if (window != nil) {
    zb_mac_drawer_set_open(window, !zb_mac_drawer_is_open(window));
  }
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
  if (menuItem == g_zb_mac_drawer_menu_item) {
    menuItem.state = zb_mac_drawer_is_open(zb_mac_drawer_menu_window())
                         ? NSControlStateValueOn
                         : NSControlStateValueOff;
  }
  return YES;
}

@end

static void zb_mac_drawer_ensure_menu(void) {
  if (g_zb_mac_drawer_menu_item != nil) {
    return;
  }
  NSMenu *main_menu = NSApp.mainMenu;
  if (main_menu == nil) {
    main_menu = [[NSMenu alloc] initWithTitle:@"Main"];
    NSString *name = NSProcessInfo.processInfo.processName;
    NSMenuItem *app_root = [[NSMenuItem alloc] initWithTitle:name
                                                     action:nil
                                              keyEquivalent:@""];
    NSMenu *app_menu = [[NSMenu alloc] initWithTitle:name];
    NSString *quit_title = [@"Quit " stringByAppendingString:name];
    [app_menu addItemWithTitle:quit_title
                        action:@selector(terminate:)
                 keyEquivalent:@"q"];
    app_root.submenu = app_menu;
    [main_menu addItem:app_root];
    NSApp.mainMenu = main_menu;
  }

  NSMenuItem *view_root = [main_menu itemWithTitle:@"View"];
  if (view_root == nil) {
    view_root = [[NSMenuItem alloc] initWithTitle:@"View"
                                          action:nil
                                   keyEquivalent:@""];
    view_root.submenu = [[NSMenu alloc] initWithTitle:@"View"];
    [main_menu addItem:view_root];
  } else if (view_root.submenu == nil) {
    view_root.submenu = [[NSMenu alloc] initWithTitle:@"View"];
  }

  g_zb_mac_drawer_menu_target = [[ZBMacDrawerMenuTarget alloc] init];
  g_zb_mac_drawer_menu_item =
      [[NSMenuItem alloc] initWithTitle:@"Agent Drawer"
                                action:@selector(toggleDrawer:)
                         keyEquivalent:@""];
  g_zb_mac_drawer_menu_item.target = g_zb_mac_drawer_menu_target;
  [view_root.submenu addItem:g_zb_mac_drawer_menu_item];
}

static void zb_mac_drawer_ensure_shortcuts(void) {
  if (g_zb_mac_drawer_key_monitor != nil) {
    return;
  }
  g_zb_mac_drawer_key_monitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                  handler:^NSEvent *(NSEvent *event) {
    NSEventModifierFlags modifiers =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL escape = event.keyCode == 53 && modifiers == 0;
    BOOL command_shift_space =
        event.keyCode == 49 &&
        modifiers == (NSEventModifierFlagCommand | NSEventModifierFlagShift);
    if (!escape && !command_shift_space) {
      return event;
    }
    NSWindow *window = event.window != nil ? event.window : NSApp.keyWindow;
    if (zb_state(window) == nil || !zb_mac_drawer_is_open(window)) {
      return event;
    }
    zb_mac_drawer_set_open(window, 0);
    return nil;
  }];
}

static void zb_mac_drawer_minimize(void *context) {
  ZBMacDrawerState *state = (__bridge ZBMacDrawerState *)context;
  if (state.window != nil) {
    zb_mac_drawer_set_open(state.window, 0);
  }
}

static NSView *zb_make_panel(NSRect frame, ZBMacDrawerState *state) {
  if (zb_mac_drawer_panel_create != NULL) {
    return zb_mac_drawer_panel_create(frame, state.identifier,
                                      zb_mac_drawer_minimize,
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


@implementation ZBMacDrawerIcon

- (void)mouseDown:(NSEvent *)event {
  ZBMacDrawerState *state = self.drawerState;
  NSWindow *window = state.window;
  if (state == nil || window == nil || event.type != NSEventTypeLeftMouseDown) {
    return;
  }

  NSPoint press = event.locationInWindow;
  ZbMacDrawerRect start = state.iconRect;
  BOOL dragging = NO;
  NSEventMask mask = NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp;
  for (;;) {
    NSEvent *next = [window nextEventMatchingMask:mask
                                       untilDate:[NSDate dateWithTimeIntervalSinceNow:2]
                                          inMode:NSEventTrackingRunLoopMode
                                         dequeue:YES];
    if (next == nil) {
      return;
    }
    NSPoint location = next.locationInWindow;
    if (next.windowNumber == 0) {
      location = [window convertPointFromScreen:location];
    }
    double dx = location.x - press.x;
    double dy = press.y - location.y;
    if (!dragging && zb_drawer_classify(dx, dy) == 1) {
      dragging = YES;
    }
    if (dragging) {
      ZbMacDrawerRect moved = start;
      moved.x += (int)dx;
      moved.y += (int)dy;
      zb_drawer_clamp(&moved, (int)NSWidth(state.host.bounds),
                      (int)NSHeight(state.host.bounds));
      state.iconRect = moved;
      [state applyIconFrame];
    }
    if (next.type == NSEventTypeLeftMouseUp) {
      if (dragging) {
        ZbMacDrawerRect icon_rect = state.iconRect;
        ZbMacDrawerRatios ratios = {0};
        zb_drawer_ratios_of(&icon_rect, (int)NSWidth(state.host.bounds),
                            (int)NSHeight(state.host.bounds), &ratios);
        state.ratios = ratios;
        state.hasRatios = YES;
        zb_drawer_remember(&ratios);
        state.pendingIconKind = @"moved";
        [state.host setNeedsLayout:YES];
        [state.host layoutSubtreeIfNeeded];
        const char *debug = getenv("ZB_DEBUG_DRAWER_ICON");
        if (state.identifier == 1 && zb_mac_drawer_e2e_enabled() &&
            debug != NULL && strcmp(debug, "drag") == 0) {
          zb_mac_drawer_debug_open_window();
        }
      } else {
        state.pendingRowKind = @"open";
        zb_mac_drawer_set_open(window, 1);
      }
      return;
    }
  }
}

@end


@implementation ZBMacDrawerState

- (void)applyIconFrame {
  ZbMacDrawerRect frame = {0};
  zb_drawer_appkit_frame(&_iconRect, (int)NSWidth(self.host.bounds),
                         (int)NSHeight(self.host.bounds), &frame);
  self.icon.frame = zb_nsrect(frame);
}

- (void)updateFoldTarget {
  int width = (int)NSWidth(self.host.bounds);
  int height = (int)NSHeight(self.host.bounds);
  zb_drawer_place(self.hasRatios ? &_ratios : NULL, width, height, &_iconRect);
  [self applyIconFrame];
  self.foldTo = zb_mac_rect(self.icon.frame);
}

- (void)cancelFold {
  [self.foldTimer invalidate];
  self.foldTimer = nil;
  self.folding = NO;
  self.foldView.hidden = YES;
}

- (void)advanceFold:(NSTimer *)timer {
  if (timer != self.foldTimer || !self.folding) return;
  [self updateFoldTarget];
  NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - self.foldStarted;
  unsigned int duration = zb_drawer_anim_ms();
  double progress = duration == 0 ? 1.0 : elapsed * 1000.0 / duration;
  ZbMacDrawerRect frame = {0};
  zb_drawer_lerp(&_foldFrom, &_foldTo, zb_drawer_ease(progress), &frame);
  self.foldFrames += 1;
  self.foldView.frame = zb_nsrect(frame);
  if (zb_mac_fold_debug_enabled() &&
      (!self.foldReportedValid ||
       memcmp(&_foldReported, &frame, sizeof(frame)) != 0)) {
    self.foldReported = frame;
    self.foldReportedValid = YES;
    printf("DRAWER\t%u\tfold\t%lu\t%d,%d,%d,%d\ticon=hidden\tpanel=hidden\n",
           self.identifier, (unsigned long)self.foldFrames, frame.x, frame.y,
           frame.w, frame.h);
    fflush(stdout);
  }
  if (progress < 1.0) return;

  NSUInteger elapsed_ms = (NSUInteger)lround(elapsed * 1000.0);
  [self.foldTimer invalidate];
  self.foldTimer = nil;
  self.folding = NO;
  self.foldView.hidden = YES;
  self.panel.hidden = YES;
  self.icon.hidden = NO;
  [self.icon.window makeFirstResponder:self.icon];
  if (zb_mac_fold_debug_enabled()) {
    printf("DRAWER\t%u\tanim\t%lu\t%lu\t%d,%d,%d,%d\t%d,%d,%d,%d\n",
           self.identifier, (unsigned long)self.foldFrames,
           (unsigned long)elapsed_ms, self.foldFrom.x, self.foldFrom.y,
           self.foldFrom.w, self.foldFrom.h, self.foldTo.x, self.foldTo.y,
           self.foldTo.w, self.foldTo.h);
    printf("DRAWER\t%u\tminimized\t%d,%d,%d,%d\tpanel=hidden\ticon=visible\n",
           self.identifier, self.foldTo.x, self.foldTo.y, self.foldTo.w,
           self.foldTo.h);
    fflush(stdout);
  }
}

- (void)beginFold {
  if (!self.open || self.folding) return;
  self.foldFrom = zb_mac_rect(self.panel.frame);
  [self updateFoldTarget];
  self.foldFrames = 0;
  self.foldReportedValid = NO;
  self.foldStarted = NSProcessInfo.processInfo.systemUptime;
  if (zb_mac_fold_debug_enabled()) {
    printf("DRAWER\t%u\tfold-start\t%d,%d,%d,%d\t%d,%d,%d,%d\tpanel=visible\ticon=hidden\tminus=%s\n",
           self.identifier, self.foldFrom.x, self.foldFrom.y, self.foldFrom.w,
           self.foldFrom.h, self.foldTo.x, self.foldTo.y, self.foldTo.w,
           self.foldTo.h, self.debugMinusClicked ? "clicked" : "not-clicked");
    fflush(stdout);
  }
  self.debugMinusClicked = NO;
  self.open = NO;
  self.folding = YES;
  self.panel.hidden = YES;
  self.foldView.frame = zb_nsrect(self.foldFrom);
  self.foldView.hidden = NO;
  self.icon.hidden = YES;
  if (zb_agent_tools_drawer_showing != NULL) {
    zb_agent_tools_drawer_showing(self.identifier, 0);
  }
  if (self.window == zb_mac_drawer_menu_window()) {
    g_zb_mac_drawer_menu_item.state = NSControlStateValueOff;
  }
  [self.host setNeedsLayout:YES];
  [self.host layoutSubtreeIfNeeded];
  self.foldTimer = [NSTimer timerWithTimeInterval:1.0 / 60.0
                                           target:self
                                         selector:@selector(advanceFold:)
                                         userInfo:nil
                                          repeats:YES];
  [NSRunLoop.mainRunLoop addTimer:self.foldTimer forMode:NSRunLoopCommonModes];
}

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

  zb_drawer_place(self.hasRatios ? &_ratios : NULL, width, height, &_iconRect);
  [self applyIconFrame];
  self.icon.hidden = self.open || self.folding;

  NSString *kind = self.pendingRowKind;
  if (kind != nil && zb_mac_drawer_e2e_enabled()) {
    self.pendingRowKind = nil;
    printf("DRAWER\t%u\t%s\tpage=%d,%d,%d,%d\tpanel=%d,%d,%d,%d\n",
           self.identifier, kind.UTF8String, page_frame.x, page_frame.y,
           page_frame.w, page_frame.h, panel_frame.x, panel_frame.y,
           panel_frame.w, panel_frame.h);
    fflush(stdout);
  }

  NSString *icon_kind = self.pendingIconKind;
  if (icon_kind != nil && zb_mac_drawer_e2e_enabled()) {
    self.pendingIconKind = nil;
    printf("DRAWER\t%u\t%s\t%d,%d,%d,%d\n", self.identifier,
           icon_kind.UTF8String, self.iconRect.x, self.iconRect.y,
           self.iconRect.w, self.iconRect.h);
    fflush(stdout);
  }
}

@end


void zb_mac_drawer_attach(NSWindow *window, NSView *webview,
                          unsigned int window_id) {
  if (!g_zb_mac_drawer_enabled || window == nil || webview == nil ||
      window_id == 0) {
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
  state.identifier = window_id;
  ZbMacDrawerRatios start_ratios = {0};
  state.hasRatios = zb_drawer_start_ratios(&start_ratios) != 0;
  state.ratios = start_ratios;

  NSRect bounds = window.contentView != nil ? window.contentView.bounds
                                             : NSMakeRect(0, 0, 0, 0);
  ZBMacDrawerHostView *host =
      [[ZBMacDrawerHostView alloc] initWithFrame:bounds];
  host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  host.drawerState = state;
  state.host = host;
  state.panel = zb_make_panel(NSZeroRect, state);
  state.panel.translatesAutoresizingMaskIntoConstraints = NO;
  state.panel.hidden = YES;
  NSView *fold_view = [[NSView alloc] initWithFrame:NSZeroRect];
  fold_view.wantsLayer = YES;
  fold_view.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
  fold_view.layer.cornerRadius = 12;
  fold_view.layer.borderWidth = 1;
  fold_view.layer.borderColor = NSColor.separatorColor.CGColor;
  fold_view.hidden = YES;
  state.foldView = fold_view;
  ZBMacDrawerIcon *icon = [[ZBMacDrawerIcon alloc] initWithFrame:NSZeroRect];
  icon.drawerState = state;
  icon.title = @"S";
  icon.bordered = NO;
  icon.font = [NSFont boldSystemFontOfSize:24];
  icon.contentTintColor = NSColor.whiteColor;
  icon.wantsLayer = YES;
  icon.layer.backgroundColor =
      [NSColor colorWithRed:0.851 green:0.467 blue:0.341 alpha:1].CGColor;
  icon.layer.cornerRadius = 28;
  icon.toolTip = @"Open Claude Agent";
  [icon setAccessibilityLabel:@"Open Claude Agent"];
  state.icon = icon;
  BOOL status_shown = NO;
  if (g_zb_mac_drawer_status != nil && zb_mac_drawer_panel_append != NULL) {
    zb_mac_drawer_panel_append(state.panel, "status",
                               g_zb_mac_drawer_status.UTF8String);
    status_shown = YES;
  }

  [webview removeFromSuperview];
  [host addSubview:webview];
  [host addSubview:state.panel positioned:NSWindowAbove relativeTo:webview];
  [host addSubview:fold_view positioned:NSWindowAbove relativeTo:state.panel];
  [host addSubview:icon positioned:NSWindowAbove relativeTo:fold_view];
  objc_setAssociatedObject(window, kZBMacDrawerStateKey, state,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (zb_agent_tools_window_opened != NULL) {
    zb_agent_tools_window_opened(state.identifier);
  }
  __weak ZBMacDrawerState *weak_close_state = state;
  state.closeObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowWillCloseNotification
                  object:window
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *notification) {
    (void)notification;
    ZBMacDrawerState *strong_state = weak_close_state;
    if (strong_state == nil) return;
    [strong_state cancelFold];
    if (zb_agent_tools_window_closed != NULL) {
      zb_agent_tools_window_closed(strong_state.identifier);
    }
    if (strong_state.closeObserver != nil) {
      [NSNotificationCenter.defaultCenter removeObserver:strong_state.closeObserver];
      strong_state.closeObserver = nil;
    }
  }];
  window.contentView = host;
  [window setContentSize:bounds.size];
  [host setNeedsLayout:YES];
  [host layoutSubtreeIfNeeded];
  zb_mac_drawer_ensure_menu();
  zb_mac_drawer_ensure_shortcuts();

  const char *shortcut_debug = getenv("ZB_DEBUG_DRAWER_SHORTCUTS");
  if (state.identifier == 1 && zb_mac_drawer_e2e_enabled() &&
      shortcut_debug != NULL && strcmp(shortcut_debug, "1") == 0) {
    __weak ZBMacDrawerState *weak_state = state;
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBMacDrawerState *strong_state = weak_state;
      NSWindow *strong_window = strong_state.window;
      if (strong_state == nil || strong_window == nil) {
        return;
      }
      zb_mac_drawer_set_open(strong_window, 1);
      printf("DRAWER\t%u\tshortcut-open-escape\t%d\n",
             strong_state.identifier, zb_mac_drawer_is_open(strong_window));
      NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
      NSEvent *escape = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                         location:NSZeroPoint
                                    modifierFlags:0
                                        timestamp:now
                                     windowNumber:strong_window.windowNumber
                                          context:nil
                                       characters:@"\x1b"
                      charactersIgnoringModifiers:@"\x1b"
                                         isARepeat:NO
                                           keyCode:53];
      [NSApp sendEvent:escape];
      printf("DRAWER\t%u\tshortcut-escape\t%d\n", strong_state.identifier,
             zb_mac_drawer_is_open(strong_window));

      zb_mac_drawer_set_open(strong_window, 1);
      printf("DRAWER\t%u\tshortcut-open-command-shift-space\t%d\n",
             strong_state.identifier, zb_mac_drawer_is_open(strong_window));
      NSEventModifierFlags modifiers =
          NSEventModifierFlagCommand | NSEventModifierFlagShift;
      NSEvent *space = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                        location:NSZeroPoint
                                   modifierFlags:modifiers
                                       timestamp:now + 0.01
                                    windowNumber:strong_window.windowNumber
                                         context:nil
                                      characters:@" "
                     charactersIgnoringModifiers:@" "
                                        isARepeat:NO
                                          keyCode:49];
      [NSApp sendEvent:space];
      printf("DRAWER\t%u\tshortcut-command-shift-space\t%d\n",
             strong_state.identifier, zb_mac_drawer_is_open(strong_window));
      fflush(stdout);
    });
  }

  const char *menu_debug = getenv("ZB_DEBUG_DRAWER_MENU");
  if (state.identifier == 1 && zb_mac_drawer_e2e_enabled() &&
      menu_debug != NULL && strcmp(menu_debug, "1") == 0) {
    __weak ZBMacDrawerState *weak_state = state;
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBMacDrawerState *strong_state = weak_state;
      NSMenuItem *item = g_zb_mac_drawer_menu_item;
      if (strong_state == nil || strong_state.window == nil || item == nil) {
        return;
      }
      printf("DRAWER\t%u\tmenu\tView > %s\n", strong_state.identifier,
             item.title.UTF8String);
      [NSApp sendAction:item.action to:item.target from:item];
      printf("DRAWER\t%u\tmenu-open\t%d\n", strong_state.identifier,
             zb_mac_drawer_is_open(strong_state.window));
      [NSApp sendAction:item.action to:item.target from:item];
      printf("DRAWER\t%u\tmenu-close\t%d\n", strong_state.identifier,
             zb_mac_drawer_is_open(strong_state.window));
      fflush(stdout);
    });
  }

  const char *icon_debug = getenv("ZB_DEBUG_DRAWER_ICON");
  if (zb_mac_drawer_e2e_enabled() && icon_debug != NULL &&
      (strcmp(icon_debug, "click") == 0 || strcmp(icon_debug, "drag") == 0)) {
    state.pendingIconKind = @"icon";
    [host setNeedsLayout:YES];
    [host layoutSubtreeIfNeeded];
    if (state.identifier == 1) {
      __weak ZBMacDrawerState *weak_state = state;
      dispatch_async(dispatch_get_main_queue(), ^{
        ZBMacDrawerState *strong_state = weak_state;
        if (strong_state == nil || strong_state.window == nil) {
          return;
        }
        NSRect frame = strong_state.icon.frame;
        NSPoint start = NSMakePoint(NSMidX(frame), NSMidY(frame));
        BOOL drag = strcmp(icon_debug, "drag") == 0;
        NSPoint finish = drag ? NSMakePoint(start.x - 300, start.y + 200) : start;
        NSPoint screen_finish = [strong_state.window convertPointToScreen:finish];
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                          location:screen_finish
                                     modifierFlags:0
                                         timestamp:now + 0.02
                                      windowNumber:0
                                           context:nil
                                       eventNumber:2
                                        clickCount:1
                                          pressure:0];
        [NSApp postEvent:up atStart:YES];
        if (drag) {
          NSEvent *moved = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                              location:screen_finish
                                         modifierFlags:0
                                             timestamp:now + 0.01
                                          windowNumber:0
                                               context:nil
                                           eventNumber:1
                                            clickCount:1
                                              pressure:1];
          [NSApp postEvent:moved atStart:YES];
        }
        NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                                           location:start
                                      modifierFlags:0
                                          timestamp:now
                                       windowNumber:strong_state.window.windowNumber
                                            context:nil
                                        eventNumber:0
                                         clickCount:1
                                           pressure:1];
        [strong_state.window sendEvent:down];
      });
    }
  }

  if (state.identifier == 1 && zb_mac_fold_debug_enabled()) {
    __weak ZBMacDrawerState *weak_state = state;
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBMacDrawerState *strong_state = weak_state;
      if (strong_state == nil || strong_state.window == nil) return;
      zb_mac_drawer_set_open(strong_state.window, 1);
      dispatch_async(dispatch_get_main_queue(), ^{
        ZBMacDrawerState *ready_state = weak_state;
        if (ready_state == nil || ready_state.window == nil) return;
        NSButton *minus = zb_mac_find_minus(ready_state.panel);
        if (minus == nil) return;
        ready_state.debugMinusClicked = YES;
        [minus performClick:nil];
      });
    });
  }

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
  zb_mac_e2e_snapshot_window(window, state.identifier);
}

void zb_mac_drawer_set_open(NSWindow *window, int open) {
  ZBMacDrawerState *state = zb_state(window);
  if (state == nil) {
    return;
  }
  BOOL wanted = open != 0;
  if (!wanted) {
    if (state.open) [state beginFold];
    return;
  }
  if (state.open && !state.folding) {
    if (zb_mac_drawer_panel_focus_input != NULL) {
      zb_mac_drawer_panel_focus_input(state.panel);
    }
    return;
  }
  if (state.folding) [state cancelFold];
  state.open = YES;
  state.icon.hidden = YES;
  if (zb_agent_tools_drawer_showing != NULL) {
    zb_agent_tools_drawer_showing(state.identifier, 1);
  }
  if (window == zb_mac_drawer_menu_window()) {
    g_zb_mac_drawer_menu_item.state = NSControlStateValueOn;
  }
  [state.host setNeedsLayout:YES];
  [state.host layoutSubtreeIfNeeded];
  if (zb_mac_drawer_panel_focus_input != NULL) {
    zb_mac_drawer_panel_focus_input(state.panel);
  }
  if (zb_mac_drawer_e2e_enabled() && zb_mac_agent_tools_e2e_start != NULL) {
    zb_mac_agent_tools_e2e_start(state.identifier);
  }
}

int zb_mac_drawer_is_open(NSWindow *window) {
  ZBMacDrawerState *state = zb_state(window);
  return state != nil && state.open ? 1 : 0;
}
