/* Test-only driver loaded into the installed zigBrowser process.
 *
 * It proves Cmd+V travels through NSApp.mainMenu to two real first responders:
 * the Secrets NSSecureTextField and the drawer's ZBMacInputTextView.  It never
 * reads the existing pasteboard.  It replaces it with one fixed dummy string.
 */
#import <AppKit/AppKit.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSString *const kDummy = @"zb-dummy-cmd-v-paste";

static NSButton *find_button(NSView *view, NSString *title) {
  if ([view isKindOfClass:NSButton.class]) {
    NSButton *button = (NSButton *)view;
    if ([button.title isEqualToString:title]) return button;
  }
  for (NSView *child in view.subviews) {
    NSButton *button = find_button(child, title);
    if (button != nil) return button;
  }
  return nil;
}

static NSSecureTextField *find_secure_field(NSView *view) {
  if ([view isKindOfClass:NSSecureTextField.class] &&
      [view.accessibilityLabel isEqualToString:@"Long-lived Claude token"]) {
    return (NSSecureTextField *)view;
  }
  for (NSView *child in view.subviews) {
    NSSecureTextField *field = find_secure_field(child);
    if (field != nil) return field;
  }
  return nil;
}

static NSTextView *find_drawer_input(NSView *view) {
  if ([NSStringFromClass(view.class) isEqualToString:@"ZBMacInputTextView"]) {
    return (NSTextView *)view;
  }
  for (NSView *child in view.subviews) {
    NSTextView *input = find_drawer_input(child);
    if (input != nil) return input;
  }
  return nil;
}

static BOOL menu_item_matches(NSMenu *menu, NSString *title, SEL action,
                              NSString *key, NSEventModifierFlags modifiers) {
  NSMenuItem *item = [menu itemWithTitle:title];
  if (item == nil || item.action != action || item.target != nil ||
      ![item.keyEquivalent isEqualToString:key]) {
    return NO;
  }
  if (key.length == 0) return YES;
  NSEventModifierFlags actual = item.keyEquivalentModifierMask &
      NSEventModifierFlagDeviceIndependentFlagsMask;
  return actual == modifiers;
}

static BOOL standard_menus_are_live(void) {
  NSMenu *main = NSApp.mainMenu;
  NSMenuItem *edit_root = [main itemWithTitle:@"Edit"];
  NSMenuItem *window_root = [main itemWithTitle:@"Window"];
  if (main == nil || edit_root == nil || [main indexOfItem:edit_root] != 1 ||
      edit_root.submenu == nil || window_root.submenu == nil ||
      NSApp.windowsMenu != window_root.submenu) {
    return NO;
  }
  NSMenu *edit = edit_root.submenu;
  const NSEventModifierFlags command = NSEventModifierFlagCommand;
  return menu_item_matches(edit, @"Undo", @selector(undo:), @"z", command) &&
      menu_item_matches(edit, @"Redo", @selector(redo:), @"z",
                        command | NSEventModifierFlagShift) &&
      menu_item_matches(edit, @"Cut", @selector(cut:), @"x", command) &&
      menu_item_matches(edit, @"Copy", @selector(copy:), @"c", command) &&
      menu_item_matches(edit, @"Paste", @selector(paste:), @"v", command) &&
      menu_item_matches(edit, @"Paste and Match Style",
                        @selector(pasteAsPlainText:), @"v",
                        command | NSEventModifierFlagOption |
                            NSEventModifierFlagShift) &&
      menu_item_matches(edit, @"Delete", @selector(delete:), @"", 0) &&
      menu_item_matches(edit, @"Select All", @selector(selectAll:), @"a",
                        command);
}

static void set_dummy_pasteboard(void) {
  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  [pasteboard setString:kDummy forType:NSPasteboardTypeString];
}

static void send_command_v(NSWindow *window) {
  [window makeKeyAndOrderFront:nil];
  NSEvent *event = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                    location:NSZeroPoint
                               modifierFlags:NSEventModifierFlagCommand
                                   timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:window.windowNumber
                                     context:nil
                                  characters:@"v"
                 charactersIgnoringModifiers:@"v"
                                   isARepeat:NO
                                     keyCode:9];
  [NSApp sendEvent:event];
}

static BOOL capture_view(NSView *view, NSString *path) {
  if (view == nil || path.length == 0 || !path.isAbsolutePath) return NO;
  NSRect bounds = view.bounds;
  if (NSIsEmptyRect(bounds)) return NO;
  [view layoutSubtreeIfNeeded];
  [view displayIfNeeded];
  NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:bounds];
  if (bitmap == nil) return NO;
  [view cacheDisplayInRect:bounds toBitmapImageRep:bitmap];
  NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG
                                      properties:@{}];
  return png != nil && [png writeToFile:path options:NSDataWritingAtomic error:nil];
}

static void finish_test(NSWindow *browser, BOOL menus, BOOL secrets) {
  NSTextView *input = find_drawer_input(browser.contentView);
  if (input == nil) {
    printf("EDIT_PASTE_TEST\tmenu=%d\tsecrets=%d\tdrawer=0\tpng=0\n",
           menus ? 1 : 0, secrets ? 1 : 0);
    fflush(stdout);
    return;
  }
  input.string = @"";
  [browser makeFirstResponder:input];
  set_dummy_pasteboard();
  send_command_v(browser);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    BOOL drawer = [input.string isEqualToString:kDummy];
    const char *raw_path = getenv("ZB_EDIT_PASTE_PNG");
    NSString *path = raw_path != NULL ? [NSString stringWithUTF8String:raw_path] : nil;
    BOOL png = capture_view(browser.contentView, path);
    printf("EDIT_PASTE_TEST\tmenu=%d\tsecrets=%d\tdrawer=%d\tpng=%d\n",
           menus ? 1 : 0, secrets ? 1 : 0, drawer ? 1 : 0, png ? 1 : 0);
    fflush(stdout);
  });
}

static void run_secrets_paste(NSWindow *browser, BOOL menus, NSUInteger attempt) {
  NSWindow *secrets_window = nil;
  for (NSWindow *window in NSApp.windows) {
    if ([window.title isEqualToString:@"Claude Agent account"] && window.visible) {
      secrets_window = window;
      break;
    }
  }
  if (secrets_window == nil) {
    if (attempt < 100) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), ^{
        run_secrets_paste(browser, menus, attempt + 1);
      });
    }
    return;
  }
  NSSecureTextField *field = find_secure_field(secrets_window.contentView);
  if (field == nil) return;
  field.stringValue = @"";
  [secrets_window makeFirstResponder:field];
  set_dummy_pasteboard();
  send_command_v(secrets_window);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
    BOOL secrets = [field.stringValue isEqualToString:kDummy];
    [secrets_window orderOut:nil];
    finish_test(browser, menus, secrets);
  });
}

static void begin_test(NSUInteger attempt) {
  NSWindow *browser = nil;
  NSButton *sign_in = nil;
  for (NSWindow *window in NSApp.windows) {
    NSButton *button = find_button(window.contentView, @"Sign in");
    if (button != nil) {
      browser = window;
      sign_in = button;
      break;
    }
  }
  if (browser == nil || sign_in == nil) {
    if (attempt < 100) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), ^{ begin_test(attempt + 1); });
    }
    return;
  }
  BOOL menus = standard_menus_are_live();
  [sign_in performClick:nil];
  run_secrets_paste(browser, menus, 0);
}

__attribute__((constructor)) static void install_test_driver(void) {
  @autoreleasepool {
    if (![NSProcessInfo.processInfo.processName isEqualToString:@"zigBrowser"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{ begin_test(0); });
  }
}
