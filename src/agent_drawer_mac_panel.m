#import "agent_drawer_mac.h"

#import <math.h>

/* The helper is optional until an agent home is provisioned on macOS.  Its
 * first declarations must carry weak_import; agent_helper.h then supplies the
 * shared ABI and missing-runtime text used by the Linux drawer too. */
extern int zb_agent_helper_configured(void) __attribute__((weak_import));
extern void zb_agent_helper_send(unsigned int window_id, const char *text) __attribute__((weak_import));
#import "agent_helper.h"

@class ZBMacDrawerPanel;

@interface ZBMacInputTextView : NSTextView
@property(nonatomic, weak) ZBMacDrawerPanel *drawerPanel;
@end

@interface ZBMacMessageBubble : NSView
@property(nonatomic, readonly) NSTextView *textView;
- (instancetype)initWithRole:(NSString *)role text:(NSString *)text;
@end

@interface ZBMacDrawerPanel : NSView
@property(nonatomic, assign) void (*minimizeCallback)(void *context);
@property(nonatomic, assign) void *minimizeContext;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *setupButton;
@property(nonatomic, strong) NSScrollView *messageScroll;
@property(nonatomic, strong) NSStackView *messageStack;
@property(nonatomic, strong) ZBMacInputTextView *input;
- (void)appendRole:(NSString *)role text:(NSString *)text;
- (void)requestMinimize;
- (void)sendInput;
@end

static NSString *zb_mac_string(const char *text) {
  if (text == NULL) return @"";
  NSString *value = [[NSString alloc] initWithUTF8String:text];
  return value != nil ? value : @"\uFFFD";
}

static NSColor *zb_mac_bubble_color(NSString *role) {
  if ([role isEqualToString:@"user"]) {
    return [NSColor colorWithSRGBRed:0.851 green:0.467 blue:0.341 alpha:1.0];
  }
  if ([role isEqualToString:@"assistant"]) return NSColor.textBackgroundColor;
  return [NSColor colorWithSRGBRed:0.925 green:0.906 blue:0.863 alpha:1.0];
}

static void zb_mac_configure_plain_text(NSTextView *view) {
  view.richText = NO;
  view.importsGraphics = NO;
  view.usesFontPanel = NO;
  view.usesRuler = NO;
  view.automaticQuoteSubstitutionEnabled = NO;
  view.automaticDashSubstitutionEnabled = NO;
  view.automaticTextReplacementEnabled = NO;
  view.automaticSpellingCorrectionEnabled = NO;
  view.continuousSpellCheckingEnabled = NO;
  view.grammarCheckingEnabled = NO;
  view.linkTextAttributes = @{};
}

@implementation ZBMacInputTextView
- (void)keyDown:(NSEvent *)event {
  BOOL enter = event.keyCode == 36 || event.keyCode == 76 ||
               [event.charactersIgnoringModifiers isEqualToString:@"\r"] ||
               [event.charactersIgnoringModifiers isEqualToString:@"\n"];
  if (enter && (event.modifierFlags & NSEventModifierFlagShift) == 0) {
    [self.drawerPanel sendInput];
    return;
  }
  [super keyDown:event];
}

- (void)cancelOperation:(id)sender {
  (void)sender;
  [self.drawerPanel requestMinimize];
}
@end

@implementation ZBMacMessageBubble {
  NSLayoutConstraint *_heightConstraint;
}

- (instancetype)initWithRole:(NSString *)role text:(NSString *)text {
  self = [super initWithFrame:NSZeroRect];
  if (self == nil) return nil;

  self.translatesAutoresizingMaskIntoConstraints = NO;
  self.wantsLayer = YES;
  self.layer.backgroundColor = zb_mac_bubble_color(role).CGColor;
  self.layer.cornerRadius = 10.0;

  _textView = [[NSTextView alloc] initWithFrame:NSZeroRect];
  _textView.translatesAutoresizingMaskIntoConstraints = NO;
  _textView.editable = NO;
  _textView.selectable = YES;
  _textView.drawsBackground = NO;
  _textView.verticallyResizable = YES;
  _textView.horizontallyResizable = NO;
  _textView.textContainer.widthTracksTextView = YES;
  _textView.textContainer.heightTracksTextView = NO;
  _textView.textContainer.lineFragmentPadding = 0.0;
  _textView.textContainerInset = NSMakeSize(10.0, 7.0);
  _textView.font = [NSFont systemFontOfSize:13.0];
  _textView.textColor = [role isEqualToString:@"user"] ? NSColor.whiteColor : NSColor.labelColor;
  _textView.string = text != nil ? text : @"";
  zb_mac_configure_plain_text(_textView);
  [self addSubview:_textView];
  [NSLayoutConstraint activateConstraints:@[
    [_textView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_textView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_textView.topAnchor constraintEqualToAnchor:self.topAnchor],
    [_textView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
  ]];
  _heightConstraint = [self.heightAnchor constraintEqualToConstant:34.0];
  _heightConstraint.active = YES;
  return self;
}

- (void)layout {
  [super layout];
  CGFloat width = MAX(1.0, self.bounds.size.width - 20.0);
  self.textView.textContainer.containerSize = NSMakeSize(width, CGFLOAT_MAX);
  [self.textView.layoutManager ensureLayoutForTextContainer:self.textView.textContainer];
  CGFloat used = [self.textView.layoutManager usedRectForTextContainer:self.textView.textContainer].size.height;
  _heightConstraint.constant = MAX(34.0, ceil(used) + 14.0);
}
@end

@implementation ZBMacDrawerPanel

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self == nil) return nil;

  self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.wantsLayer = YES;
  self.layer.backgroundColor = [NSColor colorWithSRGBRed:0.957 green:0.945 blue:0.914 alpha:1.0].CGColor;

  NSStackView *root = [[NSStackView alloc] initWithFrame:NSZeroRect];
  root.translatesAutoresizingMaskIntoConstraints = NO;
  root.orientation = NSUserInterfaceLayoutOrientationVertical;
  root.alignment = NSLayoutAttributeLeading;
  root.spacing = 0.0;
  [self addSubview:root];
  [NSLayoutConstraint activateConstraints:@[
    [root.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [root.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [root.topAnchor constraintEqualToAnchor:self.topAnchor],
    [root.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
  ]];

  NSStackView *header = [[NSStackView alloc] initWithFrame:NSZeroRect];
  header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  header.alignment = NSLayoutAttributeCenterY;
  header.spacing = 8.0;
  header.edgeInsets = NSEdgeInsetsMake(7.0, 10.0, 7.0, 8.0);
  NSTextField *title = [NSTextField labelWithString:@"Claude Agent"];
  title.font = [NSFont boldSystemFontOfSize:14.0];
  self.statusLabel = [NSTextField labelWithString:@"Not connected"];
  self.statusLabel.textColor = NSColor.secondaryLabelColor;
  [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
  self.setupButton = [NSButton buttonWithTitle:@"Set Up" target:self action:@selector(openSecrets:)];
  self.setupButton.bezelStyle = NSBezelStyleRounded;
  self.setupButton.hidden = YES;
  NSButton *minus = [NSButton buttonWithTitle:@"−" target:self action:@selector(minimize:)];
  minus.bezelStyle = NSBezelStyleTexturedRounded;
  minus.accessibilityLabel = @"Minimize Claude Agent";
  NSButton *send = [NSButton buttonWithTitle:@"Send" target:self action:@selector(send:)];
  send.bezelStyle = NSBezelStyleRounded;
  [header addArrangedSubview:title];
  [header addArrangedSubview:self.statusLabel];
  [header addArrangedSubview:self.setupButton];
  [header addArrangedSubview:minus];
  [root addArrangedSubview:header];
  [header.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;

  NSBox *headerRule = [[NSBox alloc] initWithFrame:NSZeroRect];
  headerRule.boxType = NSBoxSeparator;
  [root addArrangedSubview:headerRule];
  [headerRule.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;

  self.messageScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  self.messageScroll.hasVerticalScroller = YES;
  self.messageScroll.hasHorizontalScroller = NO;
  self.messageScroll.autohidesScrollers = YES;
  self.messageScroll.borderType = NSNoBorder;
  self.messageScroll.drawsBackground = NO;
  NSView *messageDocument = [[NSView alloc] initWithFrame:NSMakeRect(0.0, 0.0, frame.size.width, 1.0)];
  messageDocument.translatesAutoresizingMaskIntoConstraints = NO;
  self.messageStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
  self.messageStack.translatesAutoresizingMaskIntoConstraints = NO;
  self.messageStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  self.messageStack.alignment = NSLayoutAttributeLeading;
  self.messageStack.spacing = 8.0;
  self.messageStack.edgeInsets = NSEdgeInsetsMake(10.0, 10.0, 10.0, 10.0);
  [messageDocument addSubview:self.messageStack];
  self.messageScroll.documentView = messageDocument;
  [NSLayoutConstraint activateConstraints:@[
    [messageDocument.widthAnchor constraintEqualToAnchor:self.messageScroll.contentView.widthAnchor],
    [self.messageStack.leadingAnchor constraintEqualToAnchor:messageDocument.leadingAnchor],
    [self.messageStack.trailingAnchor constraintEqualToAnchor:messageDocument.trailingAnchor],
    [self.messageStack.topAnchor constraintEqualToAnchor:messageDocument.topAnchor],
    [self.messageStack.bottomAnchor constraintEqualToAnchor:messageDocument.bottomAnchor],
  ]];
  [root addArrangedSubview:self.messageScroll];
  [self.messageScroll.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;
  [self.messageScroll setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                forOrientation:NSLayoutConstraintOrientationVertical];

  NSBox *inputRule = [[NSBox alloc] initWithFrame:NSZeroRect];
  inputRule.boxType = NSBoxSeparator;
  [root addArrangedSubview:inputRule];
  [inputRule.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;

  NSStackView *inputRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
  inputRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  inputRow.alignment = NSLayoutAttributeBottom;
  inputRow.spacing = 8.0;
  inputRow.edgeInsets = NSEdgeInsetsMake(8.0, 10.0, 8.0, 10.0);
  NSScrollView *inputScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  inputScroll.hasVerticalScroller = YES;
  inputScroll.hasHorizontalScroller = NO;
  inputScroll.autohidesScrollers = YES;
  inputScroll.borderType = NSBezelBorder;
  self.input = [[ZBMacInputTextView alloc] initWithFrame:NSZeroRect];
  self.input.drawerPanel = self;
  self.input.minSize = NSMakeSize(0.0, 44.0);
  self.input.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
  self.input.verticallyResizable = YES;
  self.input.horizontallyResizable = NO;
  self.input.autoresizingMask = NSViewWidthSizable;
  self.input.textContainer.widthTracksTextView = YES;
  self.input.textContainer.containerSize = NSMakeSize(0.0, CGFLOAT_MAX);
  self.input.textContainerInset = NSMakeSize(6.0, 6.0);
  self.input.font = [NSFont systemFontOfSize:13.0];
  zb_mac_configure_plain_text(self.input);
  self.input.allowsUndo = YES;
  inputScroll.documentView = self.input;
  [inputScroll.heightAnchor constraintEqualToConstant:68.0].active = YES;
  [inputRow addArrangedSubview:inputScroll];
  [inputRow addArrangedSubview:send];
  [inputScroll setContentHuggingPriority:NSLayoutPriorityDefaultLow
                          forOrientation:NSLayoutConstraintOrientationHorizontal];
  [root addArrangedSubview:inputRow];
  [inputRow.widthAnchor constraintEqualToAnchor:root.widthAnchor].active = YES;
  return self;
}

- (void)requestMinimize {
  if (self.minimizeCallback != NULL) self.minimizeCallback(self.minimizeContext);
}

- (void)minimize:(id)sender {
  (void)sender;
  [self requestMinimize];
}

- (void)openSecrets:(id)sender {
  (void)sender;
  zb_mac_secrets_window_open(self.window);
}

- (void)send:(id)sender {
  (void)sender;
  [self sendInput];
}

- (void)sendInput {
  NSString *text = [self.input.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (text.length == 0) return;

  [self appendRole:@"user" text:text];
  self.input.string = @"";
  if (zb_agent_helper_configured != NULL && zb_agent_helper_send != NULL && zb_agent_helper_configured()) {
    NSInteger number = self.window.windowNumber;
    zb_agent_helper_send(number > 0 ? (unsigned int)number : 0, text.UTF8String);
    return;
  }

  self.statusLabel.stringValue = @"Unavailable";
  self.setupButton.hidden = NO;
  [self appendRole:@"status" text:@ZB_AGENT_TEXT_RUNTIME];
}

- (void)appendRole:(NSString *)role text:(NSString *)text {
  NSString *shownRole = [role isEqualToString:@"user"] || [role isEqualToString:@"assistant"] ? role : @"status";
  ZBMacMessageBubble *bubble = [[ZBMacMessageBubble alloc] initWithRole:shownRole text:text];
  NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  [row addSubview:bubble];
  [NSLayoutConstraint activateConstraints:@[
    [bubble.topAnchor constraintEqualToAnchor:row.topAnchor],
    [bubble.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    [bubble.widthAnchor constraintLessThanOrEqualToAnchor:row.widthAnchor multiplier:0.82],
    [bubble.widthAnchor constraintGreaterThanOrEqualToConstant:120.0],
  ]];
  if ([shownRole isEqualToString:@"user"]) {
    [bubble.trailingAnchor constraintEqualToAnchor:row.trailingAnchor].active = YES;
    [bubble.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.leadingAnchor].active = YES;
  } else {
    [bubble.leadingAnchor constraintEqualToAnchor:row.leadingAnchor].active = YES;
    [bubble.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor].active = YES;
  }
  [self.messageStack addArrangedSubview:row];
  [row.widthAnchor constraintEqualToAnchor:self.messageStack.widthAnchor constant:-20.0].active = YES;
  [self.messageStack layoutSubtreeIfNeeded];
  NSView *document = self.messageScroll.documentView;
  if (document != nil) [document scrollPoint:NSMakePoint(0.0, MAX(0.0, NSMaxY(document.bounds)))];
}
@end

NSView *zb_mac_drawer_panel_create(NSRect frame, void (*on_minimize)(void *context), void *context) {
  NSCAssert([NSThread isMainThread], @"The AppKit drawer must be created on the main thread");
  ZBMacDrawerPanel *panel = [[ZBMacDrawerPanel alloc] initWithFrame:frame];
  panel.minimizeCallback = on_minimize;
  panel.minimizeContext = context;
  return panel;
}

void zb_mac_drawer_panel_focus_input(NSView *panel) {
  NSCAssert([NSThread isMainThread], @"The AppKit drawer must be focused on the main thread");
  if (![panel isKindOfClass:[ZBMacDrawerPanel class]]) return;
  ZBMacDrawerPanel *drawer = (ZBMacDrawerPanel *)panel;
  [drawer.window makeFirstResponder:drawer.input];
}

void zb_mac_drawer_panel_append(NSView *panel, const char *role, const char *utf8_text) {
  NSCAssert([NSThread isMainThread], @"The AppKit drawer must be updated on the main thread");
  if (![panel isKindOfClass:[ZBMacDrawerPanel class]]) return;
  [(ZBMacDrawerPanel *)panel appendRole:zb_mac_string(role) text:zb_mac_string(utf8_text)];
}
