#import "agent_drawer_mac.h"

#import <dispatch/dispatch.h>
#import <math.h>
#import <stdint.h>

#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The helper is optional until an agent home is provisioned on macOS.  Its
 * first declarations must carry weak_import; agent_helper.h then supplies the
 * shared ABI and missing-runtime text used by the Linux drawer too. */
extern int zb_agent_helper_configured(void) __attribute__((weak_import));
extern void zb_agent_helper_send(unsigned int window_id, const char *text) __attribute__((weak_import));
#import "agent_helper.h"

extern int zb_drawer_card_press(uint64_t card, int control, int own);
extern void zb_agent_tools_call(unsigned int win, const char *session,
                                int64_t prompt_id, const char *id, size_t id_len,
                                const char *tool, size_t tool_len,
                                const char *args, size_t args_len)
    __attribute__((weak_import));
extern int zb_mac_drawer_e2e_enabled(void);
extern unsigned int zb_drawer_demo_messages(void) __attribute__((weak_import));

enum {
  ZB_CARD_APPROVE = 1,
  ZB_CARD_DENY = 2,
  ZB_CARD_APPROVED = 1,
  ZB_CARD_DENIED = 2,
  ZB_CARD_LOST = 3,
};

@class ZBMacDrawerPanel;

@interface ZBMacFlippedView : NSView
@end

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
@property(nonatomic, strong) NSScrollView *inputScroll;
@property(nonatomic, strong) NSLayoutConstraint *inputHeightConstraint;
@property(nonatomic, strong) NSMutableString *streamText;
@property(nonatomic, strong) ZBMacMessageBubble *streamBubble;
@property(nonatomic, assign) BOOL streamFull;
@property(nonatomic, assign) NSUInteger scrollGeneration;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, ZBMacApprovalCard *> *cards;
@property(nonatomic, assign) BOOL setupRunning;
@property(nonatomic, assign) BOOL acceptanceStarted;
@property(nonatomic, assign) BOOL acceptanceSent;
@property(nonatomic, assign) BOOL acceptanceReply;
@property(nonatomic, assign) BOOL acceptanceWaitForReply;
@property(nonatomic, assign) BOOL acceptanceExitScheduled;
@property(nonatomic, copy) NSString *acceptancePrompt;
@property(nonatomic, copy) NSString *acceptanceTokenPath;
@property(nonatomic, copy) NSString *lastFailureReason;
- (void)addMessageView:(NSView *)view role:(NSString *)role;
- (void)appendRole:(NSString *)role text:(NSString *)text;
- (void)appendDelta:(NSString *)text;
- (void)finishStreamWithText:(NSString *)text;
- (void)finishStreamAsShown;
- (BOOL)isFollowingNewestMessage;
- (void)scheduleScrollToNewestMessage;
- (void)showCard:(uint64_t)card
            verb:(NSString *)verb
           bound:(unsigned int)bound
             url:(NSString *)url
          origin:(NSString *)origin;
- (void)endCard:(uint64_t)card ending:(NSString *)ending;
- (void)requestMinimize;
- (void)sendInput;
- (void)updateInputHeight;
- (void)startFirstRunSetup;
- (void)runOwnerAcceptanceIfRequested;
- (void)markOwnerAcceptanceReply;
- (void)scheduleOwnerAcceptanceExit;
@end

static NSHashTable<ZBMacDrawerPanel *> *zb_mac_drawer_panels;
static NSTask *zb_mac_agent_setup_task;
static NSMutableArray *zb_mac_agent_setup_waiters;

static NSString *zb_mac_agent_setup_error_line(NSData *data, NSError *launch_error) {
  NSString *text = data.length > 0
      ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
      : nil;
  __block NSString *last = nil;
  [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
    (void)stop;
    NSString *trimmed = [line stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length > 0) last = trimmed;
  }];
  if (last.length > 0) return last;
  if (launch_error.localizedDescription.length > 0) return launch_error.localizedDescription;
  return @"Claude Agent setup failed.";
}

static void zb_mac_agent_setup_finish(BOOL success, NSString *error_line) {
  NSArray *waiters = [zb_mac_agent_setup_waiters copy] ?: @[];
  zb_mac_agent_setup_waiters = nil;
  zb_mac_agent_setup_task = nil;
  for (ZBMacAgentSetupCompletion completion in waiters) completion(success, error_line);
}

void zb_mac_agent_setup_start_or_join(ZBMacAgentSetupCompletion completion) {
  if (![NSThread isMainThread] || completion == nil) return;
  if (zb_mac_agent_setup_waiters == nil) zb_mac_agent_setup_waiters = [NSMutableArray array];
  [zb_mac_agent_setup_waiters addObject:[completion copy]];
  if (zb_mac_agent_setup_task != nil) return;

  NSString *executable = NSBundle.mainBundle.executablePath;
  if (executable.length == 0) {
    zb_mac_agent_setup_finish(NO, @"Claude Agent setup could not start.");
    return;
  }
  NSTask *task = [[NSTask alloc] init];
  NSPipe *errors = [NSPipe pipe];
  task.executableURL = [NSURL fileURLWithPath:executable];
  task.arguments = @[@"--agent-setup"];
  task.standardInput = NSFileHandle.fileHandleWithNullDevice;
  task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  task.standardError = errors;
  zb_mac_agent_setup_task = task;
  NSError *launch_error = nil;
  if (![task launchAndReturnError:&launch_error]) {
    zb_mac_agent_setup_finish(NO, zb_mac_agent_setup_error_line(nil, launch_error));
    return;
  }

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSData *error_data = [errors.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    BOOL success = task.terminationReason == NSTaskTerminationReasonExit &&
                   task.terminationStatus == 0;
    NSString *line = success ? nil : zb_mac_agent_setup_error_line(error_data, nil);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (zb_mac_agent_setup_task == task) zb_mac_agent_setup_finish(success, line);
    });
  });
}

static NSMutableData *zb_mac_read_private_file(NSString *path, size_t limit) {
  if (path.length == 0 || !path.isAbsolutePath) return nil;
  int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0) return nil;
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid() ||
      (st.st_mode & 077) != 0 || st.st_size <= 0 || (uint64_t)st.st_size > limit) {
    close(fd);
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
  size_t used = 0;
  while (used < data.length) {
    ssize_t count = read(fd, (unsigned char *)data.mutableBytes + used, data.length - used);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      close(fd);
      return nil;
    }
    used += (size_t)count;
  }
  unsigned char extra;
  ssize_t tail;
  do {
    tail = read(fd, &extra, 1);
  } while (tail < 0 && errno == EINTR);
  close(fd);
  return tail == 0 ? data : nil;
}

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
  if ([role isEqualToString:@"assistant"]) {
    return [NSColor colorWithName:@"ZBAssistantBubble"
                  dynamicProvider:^NSColor *(NSAppearance *appearance) {
      NSString *match = [appearance bestMatchFromAppearancesWithNames:
          @[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]];
      return [match isEqualToString:NSAppearanceNameDarkAqua]
                 ? [NSColor colorWithSRGBRed:0.165 green:0.165 blue:0.180 alpha:1.0]
                 : NSColor.whiteColor;
    }];
  }
  return [NSColor colorWithName:@"ZBStatusBubble"
                dynamicProvider:^NSColor *(NSAppearance *appearance) {
    NSString *match = [appearance bestMatchFromAppearancesWithNames:
        @[NSAppearanceNameDarkAqua, NSAppearanceNameAqua]];
    return [match isEqualToString:NSAppearanceNameDarkAqua]
               ? [NSColor colorWithSRGBRed:0.225 green:0.210 blue:0.180 alpha:1.0]
               : [NSColor colorWithSRGBRed:0.925 green:0.906 blue:0.863 alpha:1.0];
  }];
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

@implementation ZBMacFlippedView
- (BOOL)isFlipped { return YES; }
@end

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

- (void)didChangeText {
  [super didChangeText];
  [self.drawerPanel updateInputHeight];
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

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window == nil || self.acceptanceStarted || !zb_mac_drawer_e2e_enabled()) return;
  const char *raw = getenv("ZB_DEBUG_OWNER_ACCEPTANCE_FILE");
  if (raw == NULL || raw[0] == '\0') return;
  self.acceptanceStarted = YES;
  dispatch_async(dispatch_get_main_queue(), ^{ [self runOwnerAcceptanceIfRequested]; });
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self == nil) return nil;

  self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.wantsLayer = YES;
  self.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
  self.streamText = [NSMutableString string];
  self.cards = [NSMutableDictionary dictionary];

  NSStackView *header = [[NSStackView alloc] initWithFrame:NSZeroRect];
  header.translatesAutoresizingMaskIntoConstraints = NO;
  header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  header.alignment = NSLayoutAttributeCenterY;
  header.spacing = 8.0;
  header.edgeInsets = NSEdgeInsetsMake(7.0, 10.0, 7.0, 8.0);
  NSTextField *title = [NSTextField labelWithString:@"Claude Agent"];
  title.font = [NSFont boldSystemFontOfSize:14.0];
  title.selectable = YES;
  self.statusLabel = [NSTextField labelWithString:@"Not connected"];
  self.statusLabel.textColor = NSColor.secondaryLabelColor;
  self.statusLabel.selectable = YES;
  [self.statusLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                             forOrientation:NSLayoutConstraintOrientationHorizontal];
  self.setupButton = [NSButton buttonWithTitle:@"Sign in" target:self action:@selector(openSecrets:)];
  self.setupButton.bezelStyle = NSBezelStyleRounded;
  self.setupButton.hidden = NO;
  self.setupButton.accessibilityLabel = @"Sign in to Claude";
  NSView *headerSpacer = [[NSView alloc] initWithFrame:NSZeroRect];
  [headerSpacer setContentHuggingPriority:1
                          forOrientation:NSLayoutConstraintOrientationHorizontal];
  [headerSpacer setContentCompressionResistancePriority:1
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSButton *minus = [NSButton buttonWithTitle:@"−" target:self action:@selector(minimize:)];
  minus.bezelStyle = NSBezelStyleTexturedRounded;
  minus.accessibilityLabel = @"Minimize Claude Agent";
  [minus setContentHuggingPriority:NSLayoutPriorityRequired
                    forOrientation:NSLayoutConstraintOrientationHorizontal];
  [minus setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSButton *send = [NSButton buttonWithTitle:@"Send" target:self action:@selector(send:)];
  send.bezelStyle = NSBezelStyleRounded;
  [header addArrangedSubview:title];
  [header addArrangedSubview:self.statusLabel];
  [header addArrangedSubview:self.setupButton];
  [header addArrangedSubview:headerSpacer];
  [header addArrangedSubview:minus];
  [self addSubview:header];

  NSBox *headerRule = [[NSBox alloc] initWithFrame:NSZeroRect];
  headerRule.translatesAutoresizingMaskIntoConstraints = NO;
  headerRule.boxType = NSBoxSeparator;
  [self addSubview:headerRule];

  self.messageScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  self.messageScroll.translatesAutoresizingMaskIntoConstraints = NO;
  self.messageScroll.hasVerticalScroller = YES;
  self.messageScroll.hasHorizontalScroller = NO;
  self.messageScroll.autohidesScrollers = YES;
  self.messageScroll.borderType = NSNoBorder;
  self.messageScroll.drawsBackground = NO;
  NSView *messageDocument = [[ZBMacFlippedView alloc] initWithFrame:NSMakeRect(0.0, 0.0, frame.size.width, 1.0)];
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
    [messageDocument.heightAnchor constraintGreaterThanOrEqualToAnchor:self.messageScroll.contentView.heightAnchor],
    [self.messageStack.leadingAnchor constraintEqualToAnchor:messageDocument.leadingAnchor],
    [self.messageStack.trailingAnchor constraintEqualToAnchor:messageDocument.trailingAnchor],
    [self.messageStack.topAnchor constraintEqualToAnchor:messageDocument.topAnchor],
    [self.messageStack.bottomAnchor constraintEqualToAnchor:messageDocument.bottomAnchor],
  ]];
  [self addSubview:self.messageScroll];
  [self.messageScroll setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                forOrientation:NSLayoutConstraintOrientationVertical];
  [self.messageScroll setContentCompressionResistancePriority:1
                                               forOrientation:NSLayoutConstraintOrientationVertical];

  NSBox *inputRule = [[NSBox alloc] initWithFrame:NSZeroRect];
  inputRule.translatesAutoresizingMaskIntoConstraints = NO;
  inputRule.boxType = NSBoxSeparator;
  [self addSubview:inputRule];

  NSView *inputRow = [[NSView alloc] initWithFrame:NSZeroRect];
  inputRow.translatesAutoresizingMaskIntoConstraints = NO;
  self.inputScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  self.inputScroll.translatesAutoresizingMaskIntoConstraints = NO;
  self.inputScroll.hasVerticalScroller = YES;
  self.inputScroll.hasHorizontalScroller = NO;
  self.inputScroll.autohidesScrollers = YES;
  self.inputScroll.borderType = NSBezelBorder;
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
  self.inputScroll.documentView = self.input;
  self.inputHeightConstraint = [self.inputScroll.heightAnchor constraintEqualToConstant:68.0];
  self.inputHeightConstraint.active = YES;
  send.translatesAutoresizingMaskIntoConstraints = NO;
  [inputRow addSubview:self.inputScroll];
  [inputRow addSubview:send];
  [self.inputScroll setContentHuggingPriority:1
                               forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self.inputScroll setContentCompressionResistancePriority:1
                                            forOrientation:NSLayoutConstraintOrientationHorizontal];
  [send setContentHuggingPriority:NSLayoutPriorityRequired
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  [send setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
  [NSLayoutConstraint activateConstraints:@[
    [self.inputScroll.leadingAnchor constraintEqualToAnchor:inputRow.leadingAnchor constant:10.0],
    [self.inputScroll.topAnchor constraintEqualToAnchor:inputRow.topAnchor constant:8.0],
    [self.inputScroll.bottomAnchor constraintEqualToAnchor:inputRow.bottomAnchor constant:-8.0],
    [send.leadingAnchor constraintEqualToAnchor:self.inputScroll.trailingAnchor constant:8.0],
    /* NSButton's alignment rect excludes its bezel shadow. Keep the visible
     * frame, not merely the alignment rect, inside the drawer edge. */
    [send.trailingAnchor constraintEqualToAnchor:inputRow.trailingAnchor constant:-18.0],
    [send.centerYAnchor constraintEqualToAnchor:self.inputScroll.centerYAnchor],
  ]];
  [self addSubview:inputRow];
  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [header.topAnchor constraintEqualToAnchor:self.topAnchor],
    [header.heightAnchor constraintEqualToConstant:44.0],
    [headerRule.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [headerRule.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [headerRule.topAnchor constraintEqualToAnchor:header.bottomAnchor],
    [headerRule.heightAnchor constraintEqualToConstant:1.0],
    [inputRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [inputRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [inputRow.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    [inputRule.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [inputRule.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [inputRule.bottomAnchor constraintEqualToAnchor:inputRow.topAnchor],
    [inputRule.heightAnchor constraintEqualToConstant:1.0],
    [self.messageScroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [self.messageScroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [self.messageScroll.topAnchor constraintEqualToAnchor:headerRule.bottomAnchor],
    [self.messageScroll.bottomAnchor constraintEqualToAnchor:inputRule.topAnchor],
  ]];
  [self updateInputHeight];
  return self;
}

- (void)layout {
  [super layout];
  [self updateInputHeight];
}

- (void)updateInputHeight {
  if (self.input == nil || self.inputScroll == nil || self.inputHeightConstraint == nil) return;
  CGFloat line = ceil([self.input.layoutManager defaultLineHeightForFont:self.input.font]);
  CGFloat padding = self.input.textContainerInset.height * 2.0 + 6.0;
  CGFloat minimum = ceil(line * 3.0 + padding);
  CGFloat maximum = ceil(line * 6.0 + padding);
  CGFloat width = MAX(1.0, NSWidth(self.inputScroll.contentView.bounds));
  self.input.textContainer.containerSize = NSMakeSize(width, CGFLOAT_MAX);
  [self.input.layoutManager ensureLayoutForTextContainer:self.input.textContainer];
  CGFloat used = [self.input.layoutManager usedRectForTextContainer:self.input.textContainer].size.height;
  CGFloat wanted = MIN(maximum, MAX(minimum, ceil(used + padding)));
  if (fabs(self.inputHeightConstraint.constant - wanted) >= 0.5) {
    self.inputHeightConstraint.constant = wanted;
    [self setNeedsLayout:YES];
  }
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
  [self updateInputHeight];
  if (zb_agent_helper_configured != NULL && zb_agent_helper_send != NULL && zb_agent_helper_configured()) {
    zb_agent_helper_send(self.browserWindowId, text.UTF8String);
    return;
  }

  [self startFirstRunSetup];
}

- (void)runOwnerAcceptanceIfRequested {
  if (!zb_mac_drawer_e2e_enabled()) return;
  const char *raw = getenv("ZB_DEBUG_OWNER_ACCEPTANCE_FILE");
  NSString *path = raw != NULL ? [NSString stringWithUTF8String:raw] : nil;
  NSMutableData *manifest = zb_mac_read_private_file(path, 16 * 1024);
  if (manifest == nil) return;
  NSError *error = nil;
  id parsed = [NSJSONSerialization JSONObjectWithData:manifest options:0 error:&error];
  if (error != nil || ![parsed isKindOfClass:NSDictionary.class]) return;
  NSDictionary *action = parsed;
  NSNumber *version = action[@"version"];
  NSString *tokenPath = action[@"token_file"];
  NSString *prompt = action[@"prompt"];
  NSNumber *expectReply = action[@"expect_reply"];
  if (![version isKindOfClass:NSNumber.class] || version.integerValue != 1 ||
      ![tokenPath isKindOfClass:NSString.class] ||
      ![prompt isKindOfClass:NSString.class] || prompt.length == 0 || prompt.length > 65536 ||
      ![expectReply isKindOfClass:NSNumber.class]) return;
  NSMutableData *tokenData = zb_mac_read_private_file(tokenPath, 512);
  if (tokenData == nil) return;
  NSMutableData *terminated = [NSMutableData dataWithData:tokenData];
  const unsigned char nul = 0;
  [terminated appendBytes:&nul length:1];

  [self openSecrets:nil];
  if (!zb_mac_secrets_window_acceptance_store(self.window, terminated.bytes)) {
    memset_s(terminated.mutableBytes, terminated.length, 0, terminated.length);
    memset_s(tokenData.mutableBytes, tokenData.length, 0, tokenData.length);
    return;
  }
  memset_s(terminated.mutableBytes, terminated.length, 0, terminated.length);
  memset_s(tokenData.mutableBytes, tokenData.length, 0, tokenData.length);
  self.acceptanceWaitForReply = expectReply.boolValue;
  self.acceptancePrompt = prompt;
  self.acceptanceTokenPath = tokenPath;
  self.input.string = prompt;
  [self sendInput];
  if (self.acceptanceSent && !self.acceptanceWaitForReply) [self scheduleOwnerAcceptanceExit];
}

- (void)startFirstRunSetup {
  if (self.setupRunning) return;
  self.setupRunning = YES;
  self.setupButton.hidden = YES;
  self.statusLabel.stringValue = @"Setting up…";
  [self appendRole:@"status" text:@"Setting up Claude Agent…"];

  __weak ZBMacDrawerPanel *weakSelf = self;
  zb_mac_agent_setup_start_or_join(^(BOOL success, NSString *error_line) {
    ZBMacDrawerPanel *strongSelf = weakSelf;
    if (strongSelf == nil || !strongSelf.setupRunning) return;
    strongSelf.setupRunning = NO;
    if (success) {
      strongSelf.statusLabel.stringValue = @"Setup complete";
      [strongSelf appendRole:@"status"
                         text:@"Claude Agent setup is complete. Restart zigBrowser to start chatting."];
    } else {
      strongSelf.statusLabel.stringValue = @"Setup failed";
      strongSelf.setupButton.hidden = NO;
      [strongSelf appendRole:@"status"
                         text:error_line.length > 0 ? error_line : @"Claude Agent setup failed."];
    }
  });
}

- (void)appendRole:(NSString *)role text:(NSString *)text {
  NSString *shownRole = [role isEqualToString:@"user"] || [role isEqualToString:@"assistant"] ? role : @"status";
  ZBMacMessageBubble *bubble = [[ZBMacMessageBubble alloc] initWithRole:shownRole text:text];
  [self addMessageView:bubble role:shownRole];
  if (!self.acceptanceSent && [shownRole isEqualToString:@"user"] &&
      self.acceptancePrompt != nil && [text isEqualToString:self.acceptancePrompt]) {
    self.acceptanceSent = YES;
    puts("OWNER_ACCEPTANCE\tmessage-sent\tuser-bubble");
    fflush(stdout);
  }
}

- (void)markOwnerAcceptanceReply {
  if (!self.acceptanceSent || self.acceptanceReply) return;
  self.acceptanceReply = YES;
  puts("OWNER_ACCEPTANCE\treply-bubble\tassistant");
  fflush(stdout);
  if (self.acceptanceWaitForReply) [self scheduleOwnerAcceptanceExit];
}

- (void)scheduleOwnerAcceptanceExit {
  if (self.acceptanceExitScheduled || !zb_mac_drawer_e2e_enabled()) return;
  self.acceptanceExitScheduled = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)),
                 dispatch_get_main_queue(), ^{
    NSMutableData *tokenData = zb_mac_read_private_file(self.acceptanceTokenPath, 512);
    if (tokenData != nil) {
      NSMutableData *terminated = [NSMutableData dataWithData:tokenData];
      const unsigned char nul = 0;
      [terminated appendBytes:&nul length:1];
      zb_mac_secrets_window_acceptance_clear_if_matches(terminated.bytes);
      memset_s(terminated.mutableBytes, terminated.length, 0, terminated.length);
      memset_s(tokenData.mutableBytes, tokenData.length, 0, tokenData.length);
    }
    self.acceptanceTokenPath = nil;
    [NSApp terminate:nil];
  });
}

- (BOOL)isFollowingNewestMessage {
  NSView *document = self.messageScroll.documentView;
  if (document == nil) return YES;
  NSView *row = self.messageStack.arrangedSubviews.lastObject;
  NSView *newest = row.subviews.lastObject ?: row;
  if (newest == nil) return YES;
  NSRect visible = self.messageScroll.documentVisibleRect;
  NSRect newestRect = [document convertRect:newest.bounds fromView:newest];
  /* The stack intentionally has bottom padding. A reader is following when
   * the newest bubble is visible, even if that decorative padding is not. */
  return NSMaxY(visible) >= NSMaxY(newestRect) - 2.0;
}

- (void)scheduleScrollToNewestMessage {
  NSUInteger generation = ++self.scrollGeneration;
  __weak ZBMacDrawerPanel *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    ZBMacDrawerPanel *strongSelf = weakSelf;
    if (strongSelf == nil || strongSelf.scrollGeneration != generation) return;
    NSView *document = strongSelf.messageScroll.documentView;
    NSView *newestRow = strongSelf.messageStack.arrangedSubviews.lastObject;
    NSView *newest = newestRow.subviews.lastObject ?: newestRow;
    if (document == nil || newestRow == nil || newest == nil) return;
    /* The bubble's own layout changes its height constraint after measuring
     * wrapped text. Give that inner pass a chance to settle before the stack
     * and document recompute their bounds, then scroll using final geometry. */
    for (NSUInteger pass = 0; pass < 2; pass++) {
      [newest setNeedsLayout:YES];
      [newest layoutSubtreeIfNeeded];
      [newestRow setNeedsLayout:YES];
      [newestRow layoutSubtreeIfNeeded];
      [strongSelf.messageStack setNeedsLayout:YES];
      [strongSelf.messageStack layoutSubtreeIfNeeded];
      [document setNeedsLayout:YES];
      [document layoutSubtreeIfNeeded];
      [strongSelf setNeedsLayout:YES];
      [strongSelf layoutSubtreeIfNeeded];
    }
    /* NSStackView propagates a changed arranged-subview height at the end of
     * this run-loop turn. Scroll on the next turn, after that propagation,
     * rather than targeting the old one-line row frame. */
    dispatch_async(dispatch_get_main_queue(), ^{
      ZBMacDrawerPanel *readySelf = weakSelf;
      if (readySelf == nil || readySelf.scrollGeneration != generation) return;
      NSView *readyDocument = readySelf.messageScroll.documentView;
      NSView *readyRow = readySelf.messageStack.arrangedSubviews.lastObject;
      NSView *readyNewest = readyRow.subviews.lastObject ?: readyRow;
      if (readyDocument == nil || readyRow == nil || readyNewest == nil) return;
      [readySelf layoutSubtreeIfNeeded];
      [readyDocument layoutSubtreeIfNeeded];
      [readySelf.messageStack layoutSubtreeIfNeeded];
      NSRect target = [readyDocument convertRect:readyNewest.bounds fromView:readyNewest];
      [readyDocument scrollRectToVisible:target];
      [readySelf.messageScroll reflectScrolledClipView:readySelf.messageScroll.contentView];
    });
  });
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
  [self scheduleScrollToNewestMessage];
}

- (void)appendDelta:(NSString *)text {
  if (self.streamFull) return;
  BOOL follow = self.streamBubble == nil || [self isFollowingNewestMessage];
  if (self.streamBubble == nil) {
    self.streamBubble = [[ZBMacMessageBubble alloc] initWithRole:@"assistant" text:@""];
    [self addMessageView:self.streamBubble role:@"assistant"];
  }
  [self.streamText appendString:text];
  [self.streamBubble setPlainText:self.streamText];
  if (follow) [self scheduleScrollToNewestMessage];
}

- (void)finishStreamWithText:(NSString *)text {
  BOOL follow = [self isFollowingNewestMessage];
  if (self.streamBubble == nil) {
    [self appendRole:@"assistant" text:text];
  } else {
    [self.streamBubble setPlainText:text];
    if (follow) [self scheduleScrollToNewestMessage];
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
  cardView.outcome.selectable = YES;
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
  unsigned int demo = zb_drawer_demo_messages != NULL ? zb_drawer_demo_messages() : 0;
  if (window_id == 1 && demo != 0 && zb_mac_drawer_e2e_enabled()) {
    for (unsigned int index = 1; index <= demo; index++) {
      NSString *text = [NSString stringWithFormat:@"Message %u: visual scroll proof.", index];
      [panel appendRole:index % 2 == 0 ? @"assistant" : @"user" text:text];
    }
  }
  return panel;
}

void zb_mac_drawer_panel_focus_input(NSView *panel) {
  NSCAssert([NSThread isMainThread], @"The AppKit drawer must be focused on the main thread");
  if (![panel isKindOfClass:[ZBMacDrawerPanel class]]) return;
  ZBMacDrawerPanel *drawer = (ZBMacDrawerPanel *)panel;
  [drawer.window makeFirstResponder:drawer.input];
}

void zb_mac_drawer_panel_e2e_send(NSView *panel, const char *utf8_text) {
  NSCAssert([NSThread isMainThread], @"The AppKit drawer must be driven on the main thread");
  if (![panel isKindOfClass:[ZBMacDrawerPanel class]] || utf8_text == NULL) return;
  ZBMacDrawerPanel *drawer = (ZBMacDrawerPanel *)panel;
  drawer.input.string = zb_mac_string(utf8_text);
  [drawer sendInput];
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

static NSString *zb_mac_failure_text(NSString *state, NSString *reason) {
  if (![state isEqualToString:@"unavailable"] && ![state isEqualToString:@"crashed"]) return nil;
  if ([reason isEqualToString:@"cli-not-found"] || [reason isEqualToString:@"runtime-missing"]) {
    return @ZB_AGENT_TEXT_RUNTIME;
  }
  if ([reason isEqualToString:@"auth"] || [reason isEqualToString:@"auth-failed"]) {
    return @"Claude rejected the saved token. Open Account to replace it.";
  }
  if ([reason isEqualToString:@"rate-limited"] || [reason isEqualToString:@"overloaded"]) {
    return @"Claude is busy; try again shortly.";
  }
  return nil;
}

void zb_drawer_agent_status(unsigned int windowId, const char *state, const char *reason) {
  NSString *stateText = zb_mac_string(state);
  NSString *reasonText = zb_mac_string(reason);
  NSString *failureText = zb_mac_failure_text(stateText, reasonText);
  for (ZBMacDrawerPanel *panel in zb_mac_panel_snapshot()) {
    if (windowId != 0 && panel.browserWindowId != windowId) continue;
    panel.statusLabel.stringValue = zb_mac_status_text(stateText, reasonText);
    panel.setupButton.hidden = [stateText isEqualToString:@"starting"] ||
                               [stateText isEqualToString:@"ready"] ||
                               [stateText isEqualToString:@"busy"];
    if (failureText != nil && ![panel.lastFailureReason isEqualToString:reasonText]) {
      if (panel.streamBubble != nil) [panel finishStreamAsShown];
      [panel appendRole:@"status" text:failureText];
      panel.lastFailureReason = reasonText;
    } else if (failureText == nil &&
               ([stateText isEqualToString:@"starting"] ||
                [stateText isEqualToString:@"ready"] ||
                [stateText isEqualToString:@"busy"])) {
      panel.lastFailureReason = nil;
    }
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
      if (messageText.length != 0) [panel markOwnerAcceptanceReply];
      continue;
    }
    if (panel.streamBubble != nil) [panel finishStreamAsShown];
    [panel appendRole:roleText text:messageText];
    if ([roleText isEqualToString:@"assistant"] && messageText.length != 0) {
      [panel markOwnerAcceptanceReply];
    }
  }
}

void zb_drawer_agent_delta(unsigned int windowId, const char *session, const char *text, size_t length) {
  (void)session;
  ZBMacDrawerPanel *panel = zb_mac_panel_for_window(windowId);
  if (panel != nil) {
    NSString *delta = zb_mac_string_n(text, length);
    [panel appendDelta:delta];
    if (delta.length != 0) [panel markOwnerAcceptanceReply];
  }
}

void zb_drawer_post_system(unsigned int windowId, const char *text, size_t length) {
  NSString *message = zb_mac_string_n(text, length);
  zb_mac_on_main(^{
    ZBMacDrawerPanel *panel = zb_mac_panel_for_window(windowId);
    if (panel != nil) [panel appendRole:@"status" text:message];
  });
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
  BOOL follow = [panel isFollowingNewestMessage];
  [panel.streamText appendString:@"\n[output truncated]"];
  panel.streamFull = YES;
  [panel.streamBubble setPlainText:panel.streamText];
  if (follow) [panel scheduleScrollToNewestMessage];
}

void zb_drawer_agent_end(unsigned int windowId) {
  ZBMacDrawerPanel *panel = zb_mac_panel_for_window(windowId);
  if (panel != nil) [panel finishStreamAsShown];
}

void zb_drawer_agent_tool_call(unsigned int windowId, const char *session,
                               int64_t promptId, const char *requestId,
                               size_t requestIdLength, const char *tool,
                               size_t toolLength, const char *arguments,
                               size_t argumentsLength) {
  if (session == NULL || session[0] == '\0' || requestId == NULL ||
      requestIdLength == 0 || tool == NULL || toolLength == 0 ||
      (arguments == NULL && argumentsLength != 0)) return;

  NSString *sessionText = [zb_mac_string(session) copy];
  NSData *requestData = [NSData dataWithBytes:requestId length:requestIdLength];
  NSData *toolData = [NSData dataWithBytes:tool length:toolLength];
  NSData *argumentsData = argumentsLength == 0
                              ? [NSData data]
                              : [NSData dataWithBytes:arguments length:argumentsLength];
  zb_mac_on_main(^{
    if (zb_agent_tools_call == NULL) return;
    zb_agent_tools_call(windowId, sessionText.UTF8String, promptId,
                        requestData.bytes, requestData.length, toolData.bytes,
                        toolData.length, argumentsData.bytes,
                        argumentsData.length);
  });
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
