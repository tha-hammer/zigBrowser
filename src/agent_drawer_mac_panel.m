#import "agent_drawer_mac.h"

#import <dispatch/dispatch.h>
#import <math.h>
#import <stdint.h>

/* The helper is optional until an agent home is provisioned on macOS.  Its
 * first declarations must carry weak_import; agent_helper.h then supplies the
 * shared ABI and missing-runtime text used by the Linux drawer too. */
extern int zb_agent_helper_configured(void) __attribute__((weak_import));
extern void zb_agent_helper_send(unsigned int window_id, const char *text) __attribute__((weak_import));
#import "agent_helper.h"

extern int zb_drawer_card_press(uint64_t card, int control, int own);

enum {
  ZB_CARD_APPROVE = 1,
  ZB_CARD_DENY = 2,
  ZB_CARD_APPROVED = 1,
  ZB_CARD_DENIED = 2,
  ZB_CARD_LOST = 3,
};

@class ZBMacDrawerPanel;

@interface ZBMacInputTextView : NSTextView
@property(nonatomic, weak) ZBMacDrawerPanel *drawerPanel;
@end

@interface ZBMacMessageBubble : NSView
@property(nonatomic, readonly) NSTextView *textView;
- (instancetype)initWithRole:(NSString *)role text:(NSString *)text;
- (void)setPlainText:(NSString *)text;
@end

@interface ZBMacApprovalCard : NSView
@property(nonatomic, assign) uint64_t cardId;
@property(nonatomic, strong) NSStackView *buttonRow;
@property(nonatomic, strong) NSButton *approveButton;
@property(nonatomic, strong) NSButton *denyButton;
@property(nonatomic, strong) NSTextField *outcome;
- (void)settle:(NSString *)text;
@end

@interface ZBMacDrawerPanel : NSView
@property(nonatomic, assign) unsigned int browserWindowId;
@property(nonatomic, assign) void (*minimizeCallback)(void *context);
@property(nonatomic, assign) void *minimizeContext;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *setupButton;
@property(nonatomic, strong) NSScrollView *messageScroll;
@property(nonatomic, strong) NSStackView *messageStack;
@property(nonatomic, strong) ZBMacInputTextView *input;
@property(nonatomic, strong) NSMutableString *streamText;
@property(nonatomic, strong) ZBMacMessageBubble *streamBubble;
@property(nonatomic, assign) BOOL streamFull;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, ZBMacApprovalCard *> *cards;
- (void)addMessageView:(NSView *)view role:(NSString *)role;
- (void)appendRole:(NSString *)role text:(NSString *)text;
- (void)appendDelta:(NSString *)text;
- (void)finishStreamWithText:(NSString *)text;
- (void)finishStreamAsShown;
- (void)showCard:(uint64_t)card
            verb:(NSString *)verb
           bound:(unsigned int)bound
             url:(NSString *)url
          origin:(NSString *)origin;
- (void)endCard:(uint64_t)card ending:(NSString *)ending;
- (void)requestMinimize;
- (void)sendInput;
@end

static NSHashTable<ZBMacDrawerPanel *> *zb_mac_drawer_panels;

static void zb_mac_on_main(dispatch_block_t block) {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

static NSString *zb_mac_string(const char *text) {
  if (text == NULL) return @"";
  NSString *value = [[NSString alloc] initWithUTF8String:text];
  return value != nil ? value : @"\uFFFD";
}

static NSString *zb_mac_string_n(const char *text, size_t length) {
  if (text == NULL || length == 0) return @"";
  NSString *value = [[NSString alloc] initWithBytes:text length:length encoding:NSUTF8StringEncoding];
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
  zb_mac_configure_plain_text(_textView);
  [self setPlainText:text];
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

- (void)setPlainText:(NSString *)text {
  self.textView.string = text != nil ? text : @"";
  [self setNeedsLayout:YES];
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

@implementation ZBMacApprovalCard
- (void)settle:(NSString *)text {
  self.approveButton.enabled = NO;
  self.denyButton.enabled = NO;
  self.buttonRow.hidden = YES;
  self.outcome.stringValue = text != nil ? text : @"";
  self.outcome.hidden = NO;
}

- (void)approve:(id)sender {
  int result = zb_drawer_card_press(self.cardId, ZB_CARD_APPROVE, sender == self.approveButton);
  if (result == ZB_CARD_APPROVED) {
    [self settle:@"Approved. Waiting for the page…"];
  } else if (result == ZB_CARD_LOST) {
    [self settle:@"This approval is no longer pending."];
  }
}

- (void)deny:(id)sender {
  int result = zb_drawer_card_press(self.cardId, ZB_CARD_DENY, sender == self.denyButton);
  if (result == ZB_CARD_DENIED) {
    [self settle:@"Denied. Nothing was opened."];
  } else if (result == ZB_CARD_LOST) {
    [self settle:@"This approval is no longer pending."];
  }
}
@end

@implementation ZBMacDrawerPanel

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self == nil) return nil;

  self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.wantsLayer = YES;
  self.layer.backgroundColor = [NSColor colorWithSRGBRed:0.957 green:0.945 blue:0.914 alpha:1.0].CGColor;
  self.streamText = [NSMutableString string];
  self.cards = [NSMutableDictionary dictionary];

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
    zb_agent_helper_send(self.browserWindowId, text.UTF8String);
    return;
  }

  self.statusLabel.stringValue = @"Unavailable";
  self.setupButton.hidden = NO;
  [self appendRole:@"status" text:@ZB_AGENT_TEXT_RUNTIME];
}

- (void)appendRole:(NSString *)role text:(NSString *)text {
  NSString *shownRole = [role isEqualToString:@"user"] || [role isEqualToString:@"assistant"] ? role : @"status";
  ZBMacMessageBubble *bubble = [[ZBMacMessageBubble alloc] initWithRole:shownRole text:text];
  [self addMessageView:bubble role:shownRole];
}

- (void)addMessageView:(NSView *)view role:(NSString *)role {
  NSView *row = [[NSView alloc] initWithFrame:NSZeroRect];
  row.translatesAutoresizingMaskIntoConstraints = NO;
  [row addSubview:view];
  [NSLayoutConstraint activateConstraints:@[
    [view.topAnchor constraintEqualToAnchor:row.topAnchor],
    [view.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    [view.widthAnchor constraintLessThanOrEqualToAnchor:row.widthAnchor multiplier:0.82],
    [view.widthAnchor constraintGreaterThanOrEqualToConstant:120.0],
  ]];
  if ([role isEqualToString:@"user"]) {
    [view.trailingAnchor constraintEqualToAnchor:row.trailingAnchor].active = YES;
    [view.leadingAnchor constraintGreaterThanOrEqualToAnchor:row.leadingAnchor].active = YES;
  } else {
    [view.leadingAnchor constraintEqualToAnchor:row.leadingAnchor].active = YES;
    [view.trailingAnchor constraintLessThanOrEqualToAnchor:row.trailingAnchor].active = YES;
  }
  [self.messageStack addArrangedSubview:row];
  [row.widthAnchor constraintEqualToAnchor:self.messageStack.widthAnchor constant:-20.0].active = YES;
  [self.messageStack layoutSubtreeIfNeeded];
  NSView *document = self.messageScroll.documentView;
  if (document != nil) [document scrollPoint:NSMakePoint(0.0, MAX(0.0, NSMaxY(document.bounds)))];
}

- (void)appendDelta:(NSString *)text {
  if (self.streamFull) return;
  if (self.streamBubble == nil) {
    self.streamBubble = [[ZBMacMessageBubble alloc] initWithRole:@"assistant" text:@""];
    [self addMessageView:self.streamBubble role:@"assistant"];
  }
  [self.streamText appendString:text];
  [self.streamBubble setPlainText:self.streamText];
}

- (void)finishStreamWithText:(NSString *)text {
  if (self.streamBubble == nil) {
    [self appendRole:@"assistant" text:text];
  } else {
    [self.streamBubble setPlainText:text];
  }
  self.streamBubble = nil;
  self.streamFull = NO;
  [self.streamText setString:@""];
}

- (void)finishStreamAsShown {
  if (self.streamBubble != nil) [self finishStreamWithText:[self.streamText copy]];
}

- (void)showCard:(uint64_t)card
            verb:(NSString *)verb
           bound:(unsigned int)bound
             url:(NSString *)url
          origin:(NSString *)origin {
  NSNumber *key = @(card);
  if (self.cards[key] != nil) return;

  NSString *summary;
  if ([verb isEqualToString:@"navigate"]) {
    summary = [NSString stringWithFormat:@"Claude wants to open %@ in window %u.",
                                         url.length != 0 ? url : @"a link", bound];
  } else if ([verb isEqualToString:@"reload"]) {
    summary = [NSString stringWithFormat:@"Claude wants to reload window %u.", bound];
  } else {
    summary = [NSString stringWithFormat:@"Claude wants to %@ in window %u.",
                                         verb.length != 0 ? verb : @"use the page", bound];
  }
  if (origin.length != 0) summary = [summary stringByAppendingFormat:@"\nFrom: %@", origin];

  ZBMacApprovalCard *cardView = [[ZBMacApprovalCard alloc] initWithFrame:NSZeroRect];
  cardView.translatesAutoresizingMaskIntoConstraints = NO;
  cardView.cardId = card;
  cardView.wantsLayer = YES;
  cardView.layer.backgroundColor = [NSColor colorWithSRGBRed:1.0 green:0.961 blue:0.840 alpha:1.0].CGColor;
  cardView.layer.cornerRadius = 10.0;

  NSStackView *content = [[NSStackView alloc] initWithFrame:NSZeroRect];
  content.translatesAutoresizingMaskIntoConstraints = NO;
  content.orientation = NSUserInterfaceLayoutOrientationVertical;
  content.alignment = NSLayoutAttributeLeading;
  content.spacing = 8.0;
  content.edgeInsets = NSEdgeInsetsMake(8.0, 8.0, 8.0, 8.0);
  [cardView addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:cardView.leadingAnchor],
    [content.trailingAnchor constraintEqualToAnchor:cardView.trailingAnchor],
    [content.topAnchor constraintEqualToAnchor:cardView.topAnchor],
    [content.bottomAnchor constraintEqualToAnchor:cardView.bottomAnchor],
  ]];

  ZBMacMessageBubble *message = [[ZBMacMessageBubble alloc] initWithRole:@"status" text:summary];
  message.layer.backgroundColor = NSColor.clearColor.CGColor;
  [content addArrangedSubview:message];
  [message.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-16.0].active = YES;

  cardView.buttonRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
  cardView.buttonRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  cardView.buttonRow.spacing = 8.0;
  cardView.approveButton = [NSButton buttonWithTitle:@"Approve" target:cardView action:@selector(approve:)];
  cardView.denyButton = [NSButton buttonWithTitle:@"Deny" target:cardView action:@selector(deny:)];
  cardView.approveButton.bezelStyle = NSBezelStyleRounded;
  cardView.denyButton.bezelStyle = NSBezelStyleRounded;
  [cardView.buttonRow addArrangedSubview:cardView.approveButton];
  [cardView.buttonRow addArrangedSubview:cardView.denyButton];
  [content addArrangedSubview:cardView.buttonRow];

  cardView.outcome = [NSTextField labelWithString:@""];
  cardView.outcome.textColor = NSColor.secondaryLabelColor;
  cardView.outcome.hidden = YES;
  [content addArrangedSubview:cardView.outcome];

  self.cards[key] = cardView;
  [self addMessageView:cardView role:@"status"];
}

- (void)endCard:(uint64_t)card ending:(NSString *)ending {
  ZBMacApprovalCard *cardView = self.cards[@(card)];
  if (cardView == nil) return;
  NSString *words = [ending isEqualToString:@"done"] ? @"Done."
                    : [ending isEqualToString:@"failed"] ? @"Approved, but the browser could not do it."
                    : [ending isEqualToString:@"denied"] ? @"Denied. Nothing was opened."
                    : [ending isEqualToString:@"expired"] ? @"Not approved in time. Nothing was opened."
                    : [ending isEqualToString:@"changed"] ? @"The page changed after approval. Nothing was opened."
                    : [ending isEqualToString:@"crashed"] ? @"The page crashed. Nothing was opened."
                    : @"Cancelled: its window closed. Nothing was opened.";
  [cardView settle:words];
  [self.cards removeObjectForKey:@(card)];
}
@end

static NSArray<ZBMacDrawerPanel *> *zb_mac_panel_snapshot(void) {
  return zb_mac_drawer_panels != nil ? zb_mac_drawer_panels.allObjects : @[];
}

static ZBMacDrawerPanel *zb_mac_panel_for_window(unsigned int windowId) {
  for (ZBMacDrawerPanel *panel in zb_mac_panel_snapshot()) {
    if (panel.browserWindowId == windowId) return panel;
  }
  return nil;
}

NSView *zb_mac_drawer_panel_create(NSRect frame, unsigned int window_id,
                                   void (*on_minimize)(void *context), void *context) {
  NSCAssert([NSThread isMainThread], @"The AppKit drawer must be created on the main thread");
  if (zb_mac_drawer_panels == nil) zb_mac_drawer_panels = [NSHashTable weakObjectsHashTable];
  ZBMacDrawerPanel *panel = [[ZBMacDrawerPanel alloc] initWithFrame:frame];
  panel.browserWindowId = window_id;
  panel.minimizeCallback = on_minimize;
  panel.minimizeContext = context;
  [zb_mac_drawer_panels addObject:panel];
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

static NSString *zb_mac_status_text(NSString *state, NSString *reason) {
  if ([state isEqualToString:@"starting"]) return @"Starting…";
  if ([state isEqualToString:@"ready"]) return @"Ready";
  if ([state isEqualToString:@"busy"]) return @"Working…";
  if ([state isEqualToString:@"crashed"] || [state isEqualToString:@"stopped"]) return @"Stopped";
  if ([state isEqualToString:@"unavailable"]) return [reason isEqualToString:@"no-token"] ? @"No token" : @"Unavailable";
  return @"Not connected";
}

void zb_drawer_agent_status(unsigned int windowId, const char *state, const char *reason) {
  NSString *stateText = zb_mac_string(state);
  NSString *reasonText = zb_mac_string(reason);
  for (ZBMacDrawerPanel *panel in zb_mac_panel_snapshot()) {
    if (windowId != 0 && panel.browserWindowId != windowId) continue;
    panel.statusLabel.stringValue = zb_mac_status_text(stateText, reasonText);
    if ([reasonText isEqualToString:@"no-token"]) zb_mac_secrets_window_open(panel.window);
  }
}

void zb_drawer_agent_message(unsigned int windowId, const char *role, const char *text, size_t length) {
  NSString *roleText = zb_mac_string(role);
  NSString *messageText = zb_mac_string_n(text, length);
  for (ZBMacDrawerPanel *panel in zb_mac_panel_snapshot()) {
    if (windowId != 0 && panel.browserWindowId != windowId) continue;
    if (panel.streamBubble != nil && [roleText isEqualToString:@"assistant"]) {
      if (panel.streamFull) {
        [panel finishStreamAsShown];
      } else {
        [panel finishStreamWithText:messageText];
      }
      continue;
    }
    if (panel.streamBubble != nil) [panel finishStreamAsShown];
    [panel appendRole:roleText text:messageText];
  }
}

void zb_drawer_agent_delta(unsigned int windowId, const char *session, const char *text, size_t length) {
  (void)session;
  ZBMacDrawerPanel *panel = zb_mac_panel_for_window(windowId);
  if (panel != nil) [panel appendDelta:zb_mac_string_n(text, length)];
}

void zb_drawer_agent_stopped(unsigned int windowId) {
  ZBMacDrawerPanel *panel = zb_mac_panel_for_window(windowId);
  if (panel == nil) return;
  if (panel.streamBubble == nil) {
    [panel appendRole:@"assistant" text:@"(stopped)"];
    return;
  }
  NSString *space = panel.streamText.length != 0 && ![panel.streamText hasSuffix:@" "] ? @" " : @"";
  [panel finishStreamWithText:[NSString stringWithFormat:@"%@%@(stopped)", panel.streamText, space]];
}

void zb_drawer_agent_capped(unsigned int windowId) {
  ZBMacDrawerPanel *panel = zb_mac_panel_for_window(windowId);
  if (panel == nil || panel.streamBubble == nil || panel.streamFull) return;
  [panel.streamText appendString:@"\n[output truncated]"];
  panel.streamFull = YES;
  [panel.streamBubble setPlainText:panel.streamText];
}

void zb_drawer_agent_end(unsigned int windowId) {
  ZBMacDrawerPanel *panel = zb_mac_panel_for_window(windowId);
  if (panel != nil) [panel finishStreamAsShown];
}

void zb_drawer_card_show(unsigned int mainWindow, uint64_t card, const char *verb,
                         unsigned int boundWindow, const char *params, size_t paramsLength,
                         const char *url, const char *origin) {
  (void)params;
  (void)paramsLength;
  NSString *verbText = [zb_mac_string(verb) copy];
  NSString *urlText = [zb_mac_string(url) copy];
  NSString *originText = [zb_mac_string(origin) copy];
  zb_mac_on_main(^{
    ZBMacDrawerPanel *panel = zb_mac_panel_for_window(mainWindow);
    if (panel != nil) {
      [panel showCard:card verb:verbText bound:boundWindow url:urlText origin:originText];
    }
  });
}

void zb_drawer_card_end(uint64_t card, const char *ending) {
  NSString *endingText = [zb_mac_string(ending) copy];
  zb_mac_on_main(^{
    for (ZBMacDrawerPanel *panel in zb_mac_panel_snapshot()) {
      [panel endCard:card ending:endingText];
    }
  });
}

void zb_drawer_card_notify(const char *title, const char *body) {
  (void)title;
  (void)body;
  zb_mac_on_main(^{ [NSApp requestUserAttention:NSInformationalRequest]; });
}
