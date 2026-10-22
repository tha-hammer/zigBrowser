// MS7 compiled two-Mac hard gate (RoseCat c6b2b32): the in-process PROBE. TEST-ONLY: built by
// tests/mac/ms7_appkit_case.py on the Mac and injected (DYLD_INSERT_LIBRARIES) into the real zigBrowser, started with a
// throwaway HOME and profile, a local file: page and no credential. It is never linked into the app.
// After the app has initialized it records, as JSON (ZB_MS7_PROBE_OUT), what tests/mac/ms7_appkit_check.py judges:
//   - the loaded classes: ZbBubbleView's superclass, instance methods and each IMP's image; the shim's and the
//     executable's category lists; any method of a watched AppKit class whose IMP lies outside the system images;
//   - every main-menu item whose action is copy:, its path, key equivalent, modifiers and whether its target is nil;
//   - for each bubble posted through the production zb_drawer_mac_post: a real ZbBubbleView made first responder,
//     a selection, a real Cmd+C NSEvent through -[NSApplication sendEvent:], and the pasteboard's exact bytes;
//   - the page fallback: the WKWebView first responder, its text selected, the same Cmd+C;
//   - the approval card, when the real chain presents one (absent until MS8 wires it on macOS).
// It restores the user's pasteboard, then terminates the app. A watchdog writes an error report and exits after
// 120 s, so the leg never hangs on the probe.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <stdlib.h>
#include <string.h>
#include <sys/utsname.h>
#include <unistd.h>

static NSMutableDictionary *g_report;
static NSMutableArray *g_errors;
static volatile int g_done = 0;

static NSString *image_of(const void *address) {
  Dl_info info;
  if (address != NULL && dladdr(address, &info) && info.dli_fname != NULL) {
    return [NSString stringWithUTF8String:info.dli_fname];
  }
  return @"?";
}

static void spin(double seconds) {
  [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static NSString *hex_of(NSData *data) {
  if (data == nil) {
    return @"";
  }
  NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 2];
  const unsigned char *bytes = data.bytes;
  for (NSUInteger i = 0; i < data.length; i++) {
    [out appendFormat:@"%02x", bytes[i]];
  }
  return out;
}

static NSDictionary *category_counts(NSString *path) {
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    if (![[NSString stringWithUTF8String:_dyld_get_image_name(i)] isEqualToString:path]) {
      continue;
    }
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
    unsigned long catlist = 0, nlcatlist = 0, size = 0;
    const char *segments[] = {"__DATA_CONST", "__DATA"};
    for (int s = 0; s < 2; s++) {
      size = 0;
      if (getsectiondata(header, segments[s], "__objc_catlist", &size) != NULL) {
        catlist += size / sizeof(void *);
      }
      size = 0;
      if (getsectiondata(header, segments[s], "__objc_nlcatlist", &size) != NULL) {
        nlcatlist += size / sizeof(void *);
      }
    }
    return @{@"catlist" : @(catlist), @"nlcatlist" : @(nlcatlist)};
  }
  [g_errors addObject:[NSString stringWithFormat:@"image not loaded: %@", path]];
  return @{@"catlist" : @(-1), @"nlcatlist" : @(-1)};
}

static NSString *executable_image(void) {
  for (uint32_t i = 0; i < _dyld_image_count(); i++) {
    if (_dyld_get_image_header(i)->filetype == MH_EXECUTE) {
      return [NSString stringWithUTF8String:_dyld_get_image_name(i)];
    }
  }
  return nil;
}

static void census(void) {
  Class bubble = objc_getClass("ZbBubbleView");
  Class host = objc_getClass("ZBAppHost");
  NSString *shim = host != Nil ? [NSString stringWithUTF8String:class_getImageName(host)] : nil;
  NSString *exe = executable_image();
  if (shim != nil) {
    g_report[@"shim_image"] = shim;
  }
  if (exe != nil) {
    g_report[@"exe_image"] = exe;
  }
  NSMutableDictionary *classes = [NSMutableDictionary dictionary];
  if (bubble != Nil) {
    unsigned int n = 0;
    Method *methods = class_copyMethodList(bubble, &n);
    NSMutableArray *list = [NSMutableArray array];
    for (unsigned int i = 0; i < n; i++) {
      [list addObject:@{
        @"sel" : NSStringFromSelector(method_getName(methods[i])),
        @"image" : image_of((const void *)method_getImplementation(methods[i]))
      }];
    }
    free(methods);
    Class superclass = class_getSuperclass(bubble);
    classes[@"ZbBubbleView"] = @{
      @"super" : superclass != Nil ? NSStringFromClass(superclass) : @"",
      @"image" : [NSString stringWithUTF8String:class_getImageName(bubble)],
      @"methods" : list
    };
  }
  g_report[@"classes"] = classes;
  NSMutableDictionary *cats = [NSMutableDictionary dictionary];
  if (shim != nil) {
    cats[shim] = category_counts(shim);
  }
  if (exe != nil) {
    cats[exe] = category_counts(exe);
  }
  g_report[@"catlists"] = cats;
  NSArray *watched = @[ @"NSTextView", @"NSText", @"NSView", @"NSResponder", @"NSMenuItem", @"NSMenu", @"NSApplication",
                        @"NSWindow", @"NSPasteboard" ];
  NSMutableArray *foreign = [NSMutableArray array];
  NSMutableDictionary *counts = [NSMutableDictionary dictionary];
  for (NSString *name in watched) {
    Class cls = objc_getClass(name.UTF8String);
    unsigned int n = 0;
    Method *methods = cls != Nil ? class_copyMethodList(cls, &n) : NULL;
    counts[name] = @(n);
    for (unsigned int i = 0; i < n; i++) {
      NSString *image = image_of((const void *)method_getImplementation(methods[i]));
      if (![image hasPrefix:@"/System/Library/"] && ![image hasPrefix:@"/usr/lib/"]) {
        [foreign addObject:@{@"class" : name, @"sel" : NSStringFromSelector(method_getName(methods[i])), @"image" : image}];
      }
    }
    free(methods);
  }
  g_report[@"watched"] = watched;
  g_report[@"watched_counts"] = counts;
  g_report[@"foreign_imps"] = foreign;
}

static void copy_items_in(NSMenu *menu, NSArray *path, NSMutableArray *out) {
  for (NSMenuItem *item in menu.itemArray) {
    NSArray *here = [path arrayByAddingObject:item.title ?: @""];
    if (item.action == @selector(copy:)) {
      NSMutableArray *mods = [NSMutableArray array];
      NSEventModifierFlags flags = item.keyEquivalentModifierMask;
      if (flags & NSEventModifierFlagCommand) [mods addObject:@"command"];
      if (flags & NSEventModifierFlagShift) [mods addObject:@"shift"];
      if (flags & NSEventModifierFlagOption) [mods addObject:@"option"];
      if (flags & NSEventModifierFlagControl) [mods addObject:@"control"];
      [out addObject:@{
        @"path" : [here subarrayWithRange:NSMakeRange(1, here.count - 1)],
        @"key" : item.keyEquivalent ?: @"",
        @"modifiers" : mods,
        @"target_nil" : @(item.target == nil)
      }];
    }
    if (item.submenu != nil) {
      copy_items_in(item.submenu, here, out);
    }
  }
}

static void send_command_c(NSWindow *window) {
  NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                    location:NSZeroPoint
                               modifierFlags:NSEventModifierFlagCommand
                                   timestamp:[[NSProcessInfo processInfo] systemUptime]
                                windowNumber:window.windowNumber
                                     context:nil
                                  characters:@"c"
                 charactersIgnoringModifiers:@"c"
                                   isARepeat:NO
                                     keyCode:8];
  [NSApp sendEvent:event];
}

static NSString *responder_name(NSWindow *window) {
  NSResponder *r = window.firstResponder;
  return r != nil ? NSStringFromClass([r class]) : @"";
}

static void find_views(NSView *view, Class cls, NSMutableArray *out) {
  if ([view isKindOfClass:cls]) {
    [out addObject:view];
  }
  for (NSView *sub in view.subviews) {
    find_views(sub, cls, out);
  }
}

static NSWindow *drawer_window(NSView **drawer) {
  Class drawer_class = objc_getClass("ZbDrawerView");
  for (NSWindow *window in NSApp.windows) {
    if (drawer_class != Nil && [window.contentView isKindOfClass:drawer_class]) {
      *drawer = window.contentView;
      return window;
    }
  }
  return nil;
}

static void bubbles(NSString *dir) {
  NSView *drawer = nil;
  NSWindow *window = drawer_window(&drawer);
  NSMutableArray *rows = [NSMutableArray array];
  g_report[@"bubbles"] = rows;
  if (window == nil) {
    [g_errors addObject:@"no window holds a ZbDrawerView"];
    return;
  }
  void (*post)(void *, const char *, const char *, size_t) =
      (void (*)(void *, const char *, const char *, size_t))dlsym(RTLD_DEFAULT, "zb_drawer_mac_post");
  if (post == NULL) {
    [g_errors addObject:@"zb_drawer_mac_post is not exported"];
    return;
  }
  if ([drawer respondsToSelector:@selector(openDrawer)]) {
    [drawer performSelector:@selector(openDrawer)];
  }
  NSArray *labels = @[ @"small", @"boundary", @"large" ];
  NSMutableArray *before = [NSMutableArray array];
  find_views(drawer, objc_getClass("ZbBubbleView"), before);
  for (NSString *label in labels) {
    NSData *original = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:[label stringByAppendingString:@".bin"]]];
    if (original == nil) {
      [g_errors addObject:[NSString stringWithFormat:@"no original for %@", label]];
      return;
    }
    post((__bridge void *)drawer, "assistant", original.bytes, original.length);
  }
  [window makeKeyAndOrderFront:nil];
  [drawer layoutSubtreeIfNeeded];
  spin(0.5);
  NSMutableArray *after = [NSMutableArray array];
  find_views(drawer, objc_getClass("ZbBubbleView"), after);
  [after removeObjectsInArray:before];
  if (after.count != labels.count) {
    [g_errors addObject:[NSString stringWithFormat:@"posted %lu bubbles, found %lu", (unsigned long)labels.count,
                                                   (unsigned long)after.count]];
    return;
  }
  NSPasteboard *pb = [NSPasteboard generalPasteboard];
  for (NSUInteger i = 0; i < labels.count; i++) {
    NSTextView *bubble = after[i];
    for (NSString *selection in @[ @"whole", @"prefix" ]) {
      [pb clearContents];
      [pb setString:@"ms7-probe-sentinel" forType:NSPasteboardTypeString];
      BOOL took = [window makeFirstResponder:bubble];
      NSUInteger length = [selection isEqualToString:@"whole"] ? bubble.string.length : 5;
      [bubble setSelectedRange:NSMakeRange(0, length)];
      send_command_c(window);
      spin(0.3);
      [rows addObject:@{
        @"label" : labels[i],
        @"selection" : selection,
        @"first_responder" : took ? responder_name(window) : @"(refused)",
        @"via" : @"NSApplication sendEvent: Cmd+C",
        @"pasteboard_hex" : hex_of([pb dataForType:NSPasteboardTypeString]),
        @"contiguous" : @(![[bubble layoutManager] allowsNonContiguousLayout])
      }];
    }
  }
}

static void page(NSString *text) {
  NSView *drawer = nil;
  NSWindow *window = drawer_window(&drawer);
  NSMutableArray *webs = [NSMutableArray array];
  if (window != nil) {
    find_views(window.contentView, [WKWebView class], webs);
  }
  if (webs.count != 1) {
    g_report[@"page"] = @{@"error" : [NSString stringWithFormat:@"%lu web views", (unsigned long)webs.count]};
    return;
  }
  WKWebView *web = webs[0];
  __block BOOL selected = NO;
  __block NSNumber *handlers = nil;
  [web evaluateJavaScript:@"(function(){var r=document.createRange();r.selectNodeContents(document.getElementById('t'));"
                          @"var s=window.getSelection();s.removeAllRanges();s.addRange(r);"
                          @"return (window.webkit&&window.webkit.messageHandlers)?1:0;})()"
        completionHandler:^(id result, NSError *error) {
          selected = (error == nil);
          handlers = [result isKindOfClass:[NSNumber class]] ? result : @(-1);
        }];
  for (int i = 0; i < 50 && handlers == nil; i++) {
    spin(0.1);
  }
  NSPasteboard *pb = [NSPasteboard generalPasteboard];
  [pb clearContents];
  [pb setString:@"ms7-probe-sentinel" forType:NSPasteboardTypeString];
  BOOL took = [window makeFirstResponder:web];
  send_command_c(window);
  spin(1.5);  // WebKit writes the pasteboard from its web process
  g_report[@"page"] = @{
    @"selected" : @(selected),
    @"first_responder" : took ? responder_name(window) : @"(refused)",
    @"via" : @"NSApplication sendEvent: Cmd+C",
    @"pasteboard" : [pb stringForType:NSPasteboardTypeString] ?: @""
  };
  g_report[@"page_handlers"] = handlers ?: @(-1);
  (void)text;
}

static void card(void) {
  NSView *drawer = nil;
  NSWindow *window = drawer_window(&drawer);
  NSMutableArray *cards = [NSMutableArray array];
  Class card_class = objc_getClass("ZbCardView");
  if (window != nil && card_class != Nil) {
    find_views(drawer, card_class, cards);
  }
  if (cards.count == 0) {
    // MS8 wires the real chain (tool_use -> broker -> card) on macOS; until then no card can appear, and the
    // checker's C rows fail.
    g_report[@"card"] = @{@"source" : @"absent"};
    return;
  }
  g_report[@"card"] = @{@"source" : @"present-but-unread", @"count" : @(cards.count)};
  [g_errors addObject:@"a card is present but the grant read is not wired (MS8)"];
}

static NSArray *save_pasteboard(void) {
  NSMutableArray *saved = [NSMutableArray array];
  for (NSPasteboardItem *item in [NSPasteboard generalPasteboard].pasteboardItems) {
    NSMutableDictionary *types = [NSMutableDictionary dictionary];
    for (NSPasteboardType type in item.types) {
      NSData *data = [item dataForType:type];
      if (data != nil) {
        types[type] = data;
      }
    }
    [saved addObject:types];
  }
  return saved;
}

static void restore_pasteboard(NSArray *saved) {
  NSPasteboard *pb = [NSPasteboard generalPasteboard];
  [pb clearContents];
  NSMutableArray *items = [NSMutableArray array];
  for (NSDictionary *types in saved) {
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    for (NSPasteboardType type in types) {
      [item setData:types[type] forType:type];
    }
    [items addObject:item];
  }
  if (items.count > 0) {
    [pb writeObjects:items];
  }
}

static void write_report(void) {
  const char *out = getenv("ZB_MS7_PROBE_OUT");
  if (out == NULL) {
    return;
  }
  g_report[@"errors"] = g_errors;
  NSData *json = [NSJSONSerialization dataWithJSONObject:g_report options:NSJSONWritingSortedKeys error:nil];
  [json writeToFile:[NSString stringWithUTF8String:out] atomically:YES];
}

__attribute__((constructor)) static void ms7_probe_start(void) {
  g_report = [NSMutableDictionary dictionary];
  g_errors = [NSMutableArray array];
  struct utsname name;
  uname(&name);
  g_report[@"arch"] = [NSString stringWithUTF8String:name.machine];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120 * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                   if (!g_done) {
                     [g_errors addObject:@"probe watchdog: no result within 120 s"];
                     write_report();
                     _exit(70);
                   }
                 });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    NSString *dir = [NSString stringWithUTF8String:getenv("ZB_MS7_PROBE_DIR") ?: "/nonexistent"];
    NSArray *saved = save_pasteboard();
    census();
    NSMutableArray *items = [NSMutableArray array];
    if (NSApp.mainMenu != nil) {
      copy_items_in(NSApp.mainMenu, @[ @"" ], items);
    }
    g_report[@"copy_items"] = items;
    bubbles(dir);
    page([NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"page.txt"]
                                   encoding:NSUTF8StringEncoding
                                      error:nil]);
    card();
    restore_pasteboard(saved);
    g_done = 1;
    write_report();
    [NSApp terminate:nil];
  });
}
