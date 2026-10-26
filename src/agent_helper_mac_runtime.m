/* Native macOS owner for netd and the Claude Agent chat helper. The browser
 * keeps the token in the login Keychain and hands it to the helper only on fd
 * 3; this file owns the remaining process lifetime and NDJSON session flow. */
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

#include "agent_helper_mac.h"
#include "agent_home_lock.h"
#include "agent_image.h"
#include "agent_spawn_posix.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern void zb_drawer_agent_status(unsigned int window_id, const char *state, const char *reason);
extern void zb_drawer_agent_message(unsigned int window_id, const char *role,
                                    const char *text, size_t length);
extern void zb_drawer_agent_delta(unsigned int window_id, const char *session,
                                  const char *text, size_t length);
extern void zb_drawer_agent_end(unsigned int window_id);
extern void zb_drawer_agent_tool_call(unsigned int window_id, const char *session,
                                      int64_t prompt_id, const char *request_id,
                                      size_t request_id_length, const char *tool,
                                      size_t tool_length, const char *arguments,
                                      size_t arguments_length);
extern int zb_mac_drawer_e2e_enabled(void);

typedef NS_ENUM(NSInteger, ZBMacHelperState) {
  ZBMacHelperIdle,
  ZBMacHelperStartingNet,
  ZBMacHelperStartingChat,
  ZBMacHelperReady,
  ZBMacHelperStopping,
};

static const NSUInteger ZBMacHelperLineMax = 1024 * 1024;
static const char *const ZBMacPythonBoot =
    "import runpy,sys;sys.path.insert(0,sys.argv.pop(1));"
    "runpy.run_module('zb_agent_host',run_name='__main__',alter_sys=True)";

static NSData *zb_read_private_action(const char *path) {
  if (path == NULL || path[0] != '/') return nil;
  int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
  if (fd < 0) return nil;
  struct stat st;
  if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid() ||
      (st.st_mode & 077) != 0 || st.st_size <= 0 || st.st_size > 65536) {
    close(fd);
    return nil;
  }
  NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
  size_t used = 0;
  while (used < data.length) {
    ssize_t count = read(fd, (unsigned char *)data.mutableBytes + used,
                         data.length - used);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) {
      close(fd);
      return nil;
    }
    used += (size_t)count;
  }
  unsigned char extra = 0;
  ssize_t tail;
  do {
    tail = read(fd, &extra, 1);
  } while (tail < 0 && errno == EINTR);
  close(fd);
  return tail == 0 ? data : nil;
}

static void zb_close_fd(int *fd) {
  if (*fd >= 0) close(*fd);
  *fd = -1;
}

static int zb_pipe_above_three(int fds[2]) {
  if (pipe(fds) != 0) return errno;
  for (int i = 0; i < 2; ++i) {
    if (fds[i] <= 3) {
      int moved = fcntl(fds[i], F_DUPFD_CLOEXEC, 4);
      if (moved < 0) {
        int saved = errno;
        close(fds[0]);
        close(fds[1]);
        fds[0] = fds[1] = -1;
        return saved;
      }
      close(fds[i]);
      fds[i] = moved;
    } else {
      int flags = fcntl(fds[i], F_GETFD);
      if (flags < 0 || fcntl(fds[i], F_SETFD, flags | FD_CLOEXEC) != 0) {
        int saved = errno;
        close(fds[0]);
        close(fds[1]);
        fds[0] = fds[1] = -1;
        return saved;
      }
    }
  }
  return 0;
}

static void zb_terminate_owned_group(pid_t *pid) {
  pid_t child = *pid;
  *pid = -1;
  if (child <= 1 || child == getpid() || child == getpgrp()) return;
  if (getpgid(child) == child) (void)kill(-child, SIGTERM);
  (void)waitpid(child, NULL, WNOHANG);
}

@interface ZBMacAgentHelper : NSObject
@property(nonatomic, assign) ZBMacHelperState state;
@property(nonatomic, assign) pid_t netPid;
@property(nonatomic, assign) pid_t helperPid;
@property(nonatomic, assign) int netInput;
@property(nonatomic, assign) int netOutput;
@property(nonatomic, assign) int helperInput;
@property(nonatomic, assign) uint64_t outputSequence;
@property(nonatomic, assign) uint64_t inputSequence;
@property(nonatomic, assign) uint64_t promptSequence;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableArray<NSString *> *> *pending;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *windowSessions;
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *sessionWindows;
@property(nonatomic, strong) NSMutableSet<NSString *> *confirmedSessions;
@property(nonatomic, copy) NSString *home;
@property(nonatomic, copy) NSString *python;
@property(nonatomic, copy) NSString *packageDirectory;
@property(nonatomic, strong) NSArray<NSDictionary *> *e2eToolSteps;
@property(nonatomic, assign) NSUInteger e2eToolIndex;
@property(nonatomic, assign) unsigned int e2eToolWindow;
@property(nonatomic, copy) NSString *e2eToolSession;
+ (instancetype)shared;
- (BOOL)isConfigured;
- (void)sendWindow:(unsigned int)windowId text:(NSString *)text;
- (void)postToolResultForWindow:(unsigned int)windowId session:(NSString *)session
                             id:(NSString *)toolId ok:(BOOL)ok body:(NSData *)body;
- (void)startE2EToolsForWindow:(unsigned int)windowId;
- (void)runNextE2ETool;
- (void)stop;
@end

@implementation ZBMacAgentHelper

+ (instancetype)shared {
  static ZBMacAgentHelper *helper;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    helper = [[self alloc] init];
  });
  return helper;
}

- (instancetype)init {
  self = [super init];
  if (self == nil) return nil;
  _state = ZBMacHelperIdle;
  _netPid = -1;
  _helperPid = -1;
  _netInput = -1;
  _netOutput = -1;
  _helperInput = -1;
  _pending = [NSMutableDictionary dictionary];
  _windowSessions = [NSMutableDictionary dictionary];
  _sessionWindows = [NSMutableDictionary dictionary];
  _confirmedSessions = [NSMutableSet set];

  NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
  NSString *base = environment[@"XDG_DATA_HOME"];
  if (base.length == 0) base = [NSHomeDirectory() stringByAppendingPathComponent:@".local/share"];
  _home = [[base stringByAppendingPathComponent:@"zigbrowser/agent-home"] copy];
  _packageDirectory = [[[NSBundle mainBundle].bundlePath
      stringByAppendingPathComponent:@"Contents/Frameworks/agent-host"] copy];
  _python = [[_packageDirectory
      stringByAppendingPathComponent:@"Python.framework/Versions/3.12/bin/python3.12"] copy];

  [NSNotificationCenter.defaultCenter
      addObserver:self selector:@selector(applicationWillTerminate:)
             name:NSApplicationWillTerminateNotification object:nil];
  return self;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  [self stop];
}

- (BOOL)isConfigured {
  NSFileManager *files = NSFileManager.defaultManager;
  BOOL directory = NO;
  NSString *current = [self.home stringByAppendingPathComponent:@"current"];
  NSString *hostMain = [self.home stringByAppendingPathComponent:@"runtime/host/zb_agent_host/__main__.py"];
  NSString *manifest = [self.home stringByAppendingPathComponent:@"runtime/net.json"];
  return [files isExecutableFileAtPath:self.python] &&
         [files fileExistsAtPath:current] &&
         [files fileExistsAtPath:hostMain isDirectory:&directory] && !directory &&
         [files fileExistsAtPath:manifest isDirectory:&directory] && !directory;
}

- (void)reportUnavailable:(unsigned int)windowId message:(NSString *)message {
  zb_drawer_agent_status(windowId, "unavailable", "runtime");
  const char *utf8 = message.UTF8String ?: "Claude Agent is unavailable.";
  zb_drawer_agent_message(windowId, "system", utf8, strlen(utf8));
}

- (void)failAll:(NSString *)message {
  NSArray<NSNumber *> *windows = self.pending.allKeys;
  for (NSNumber *window in windows) {
    [self reportUnavailable:window.unsignedIntValue message:message];
  }
  [self.pending removeAllObjects];
  [self stop];
  self.state = ZBMacHelperIdle;
}

- (void)sendWindow:(unsigned int)windowId text:(NSString *)text {
  NSAssert(NSThread.isMainThread, @"macOS Agent sends must originate on the AppKit thread");
  if (![self isConfigured]) {
    [self reportUnavailable:windowId message:@"Claude Agent runtime is not set up yet."];
    return;
  }
  NSNumber *key = @(windowId);
  NSMutableArray<NSString *> *queue = self.pending[key];
  if (queue == nil) {
    queue = [NSMutableArray array];
    self.pending[key] = queue;
  }
  [queue addObject:text];
  if (self.state == ZBMacHelperIdle) {
    [self startNetworkForWindow:windowId];
  } else if (self.state == ZBMacHelperReady) {
    [self flushWindow:windowId];
  }
}

- (void)startNetworkForWindow:(unsigned int)windowId {
  if (zb_agent_home_lock(self.home.fileSystemRepresentation) != 0) {
    [self failAll:@"Claude Agent is already open in another browser."];
    return;
  }
  int input[2] = {-1, -1};
  int output[2] = {-1, -1};
  if (zb_pipe_above_three(input) != 0 || zb_pipe_above_three(output) != 0) {
    zb_close_fd(&input[0]);
    zb_close_fd(&input[1]);
    zb_close_fd(&output[0]);
    zb_close_fd(&output[1]);
    [self failAll:@"Claude Agent networking could not start."];
    return;
  }

  NSString *script = [self.packageDirectory stringByAppendingPathComponent:@"zb_agent_host/netd.py"];
  NSString *manifest = [self.home stringByAppendingPathComponent:@"runtime/net.json"];
  const char *const argv[] = {
    self.python.fileSystemRepresentation, "-I", "-S", script.fileSystemRepresentation,
    "--net-manifest", manifest.fileSystemRepresentation, NULL,
  };
  const char *const envp[] = {
    "PATH=/usr/bin:/bin", "LANG=C.UTF-8", "PYTHONDONTWRITEBYTECODE=1", NULL,
  };
  pid_t pid = -1;
  int spawnError = zb_agent_spawn_group_io(argv, envp, input[0], output[1], &pid);
  zb_close_fd(&input[0]);
  zb_close_fd(&output[1]);
  if (spawnError != 0 || pid <= 1) {
    zb_close_fd(&input[1]);
    zb_close_fd(&output[0]);
    [self failAll:@"Claude Agent networking could not start."];
    return;
  }
  self.netPid = pid;
  self.netInput = input[1];
  self.netOutput = output[0];
  self.state = ZBMacHelperStartingNet;
  zb_drawer_agent_status(windowId, "starting", "-");

  int readyFD = self.netOutput;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    char line[160];
    size_t used = 0;
    while (used + 1 < sizeof line) {
      ssize_t got = read(readyFD, line + used, 1);
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) break;
      if (line[used++] == '\n') break;
    }
    line[used] = '\0';
    NSString *ready = [[NSString alloc] initWithBytes:line length:used encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self networkReadyLine:ready pid:pid];
    });
  });
}

- (void)networkReadyLine:(NSString *)line pid:(pid_t)pid {
  if (self.state != ZBMacHelperStartingNet || self.netPid != pid) return;
  NSString *prefix = @"netd ready 127.0.0.1:";
  if (![line hasPrefix:prefix] || ![line hasSuffix:@"\n"]) {
    [self failAll:@"Claude Agent networking is unavailable."];
    return;
  }
  NSString *portText = [line substringWithRange:NSMakeRange(prefix.length, line.length - prefix.length - 1)];
  NSScanner *scanner = [NSScanner scannerWithString:portText];
  NSInteger port = 0;
  if (![scanner scanInteger:&port] || !scanner.isAtEnd || port < 1 || port > 65535 ||
      [portText hasPrefix:@"0"]) {
    [self failAll:@"Claude Agent networking is unavailable."];
    return;
  }
  [self startChatOnPort:(NSUInteger)port];
}

- (void)startChatOnPort:(NSUInteger)port {
  int input[2] = {-1, -1};
  int output[2] = {-1, -1};
  if (zb_pipe_above_three(input) != 0 || zb_pipe_above_three(output) != 0) {
    zb_close_fd(&input[0]);
    zb_close_fd(&input[1]);
    zb_close_fd(&output[0]);
    zb_close_fd(&output[1]);
    [self failAll:@"Claude Agent could not start."];
    return;
  }
  NSString *host = [self.home stringByAppendingPathComponent:@"runtime/host"];
  NSString *portText = [NSString stringWithFormat:@"%lu", (unsigned long)port];
  const char *const argv[] = {
    self.python.fileSystemRepresentation, "-I", "-c", ZBMacPythonBoot,
    host.fileSystemRepresentation, "launch", "--home", self.home.fileSystemRepresentation,
    "--python", self.python.fileSystemRepresentation, "--egress-port",
    portText.UTF8String, NULL,
  };
  NSString *homeEnv = [@"HOME=" stringByAppendingString:self.home];
  NSString *tmpEnv = [@"TMPDIR=" stringByAppendingString:
      [self.home stringByAppendingPathComponent:@"scratchpad/tmp"]];
  const char *const envp[] = {
    "PATH=/usr/bin:/bin", "LANG=C.UTF-8", "PYTHONDONTWRITEBYTECODE=1",
    homeEnv.UTF8String, tmpEnv.UTF8String, NULL,
  };
  pid_t pid = -1;
  int result = zb_mac_agent_helper_spawn_fd3(argv, envp, input[0], output[1], &pid);
  zb_close_fd(&input[0]);
  zb_close_fd(&output[1]);
  if (result != 0 || pid <= 1) {
    zb_close_fd(&input[1]);
    zb_close_fd(&output[0]);
    [self failAll:result == 1 ? @"Open Account and save a Claude token first."
                              : @"Claude Agent could not start."];
    return;
  }
  (void)fcntl(input[1], F_SETNOSIGPIPE, 1);
  self.helperPid = pid;
  self.helperInput = input[1];
  self.state = ZBMacHelperStartingChat;
  self.inputSequence = 0;
  self.outputSequence = 0;
  [self readHelperFD:output[0] pid:pid];
}

- (void)readHelperFD:(int)fd pid:(pid_t)pid {
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSMutableData *pending = [NSMutableData data];
    unsigned char bytes[4096];
    BOOL malformed = NO;
    for (;;) {
      ssize_t got = read(fd, bytes, sizeof bytes);
      if (got < 0 && errno == EINTR) continue;
      if (got <= 0) break;
      [pending appendBytes:bytes length:(NSUInteger)got];
      if (pending.length > ZBMacHelperLineMax) {
        malformed = YES;
        break;
      }
      for (;;) {
        const unsigned char *all = pending.bytes;
        NSUInteger newline = NSNotFound;
        for (NSUInteger i = 0; i < pending.length; ++i) {
          if (all[i] == '\n') {
            newline = i;
            break;
          }
        }
        if (newline == NSNotFound) break;
        NSData *line = [pending subdataWithRange:NSMakeRange(0, newline)];
        [pending replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
        NSError *error = nil;
        id object = [NSJSONSerialization JSONObjectWithData:line options:0 error:&error];
        if (![object isKindOfClass:NSDictionary.class] || error != nil) {
          malformed = YES;
          break;
        }
        NSDictionary *frame = object;
        dispatch_async(dispatch_get_main_queue(), ^{ [self receiveFrame:frame pid:pid]; });
      }
      if (malformed) break;
    }
    close(fd);
    dispatch_async(dispatch_get_main_queue(), ^{
      [self helperEnded:pid malformed:malformed];
    });
  });
}

- (BOOL)writeFrame:(NSDictionary *)fields {
  if (self.helperInput < 0) return NO;
  NSMutableDictionary *frame = [fields mutableCopy];
  frame[@"v"] = @1;
  frame[@"seq"] = @(++self.outputSequence);
  NSError *error = nil;
  NSData *json = [NSJSONSerialization dataWithJSONObject:frame options:0 error:&error];
  if (json == nil || error != nil || json.length > 65536) return NO;
  NSMutableData *line = [json mutableCopy];
  const unsigned char newline = '\n';
  [line appendBytes:&newline length:1];
  const unsigned char *bytes = line.bytes;
  NSUInteger written = 0;
  while (written < line.length) {
    ssize_t count = write(self.helperInput, bytes + written, line.length - written);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) return NO;
    written += (NSUInteger)count;
  }
  return YES;
}

- (void)receiveFrame:(NSDictionary *)frame pid:(pid_t)pid {
  BOOL e2eFrame = pid == 0 && self.e2eToolSteps != nil;
  if ((!e2eFrame && pid != self.helperPid) || self.state == ZBMacHelperStopping) return;
  NSNumber *version = frame[@"v"];
  NSNumber *sequence = frame[@"seq"];
  NSString *type = frame[@"type"];
  if (![version isKindOfClass:NSNumber.class] || version.integerValue != 1 ||
      ![sequence isKindOfClass:NSNumber.class] || sequence.unsignedLongLongValue != self.inputSequence + 1 ||
      ![type isKindOfClass:NSString.class]) {
    [self failAll:@"Claude Agent sent an invalid response."];
    return;
  }
  self.inputSequence = sequence.unsignedLongLongValue;
  if ([type isEqualToString:@"ready"]) {
    self.state = ZBMacHelperReady;
    NSDictionary *hello = @{
      @"type": @"hello", @"agent_home": self.home,
      @"workspace": [self.home stringByAppendingPathComponent:@"workspace"],
      @"scratchpad": [self.home stringByAppendingPathComponent:@"scratchpad"],
      @"route": @"R1",
    };
    if (![self writeFrame:hello]) {
      [self failAll:@"Claude Agent could not receive a request."];
      return;
    }
    zb_drawer_agent_status(0, "ready", "-");
    for (NSNumber *window in self.pending.allKeys) [self flushWindow:window.unsignedIntValue];
    return;
  }

  NSString *session = frame[@"session"];
  NSNumber *window = [session isKindOfClass:NSString.class] ? self.sessionWindows[session] : nil;
  if ([type isEqualToString:@"session_opened"] && window != nil) {
    [self.confirmedSessions addObject:session];
    [self flushWindow:window.unsignedIntValue];
    return;
  }
  if (window == nil) return;
  unsigned int windowId = window.unsignedIntValue;
  NSString *text = frame[@"text"];
  if ([type isEqualToString:@"assistant_delta"] && [text isKindOfClass:NSString.class]) {
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    zb_drawer_agent_delta(windowId, session.UTF8String, utf8.bytes, utf8.length);
  } else if ([type isEqualToString:@"assistant_message"] && [text isKindOfClass:NSString.class]) {
    NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
    zb_drawer_agent_message(windowId, "assistant", utf8.bytes, utf8.length);
  } else if ([type isEqualToString:@"tool_call"]) {
    NSString *toolId = frame[@"id"];
    NSString *tool = frame[@"tool"];
    NSDictionary *arguments = frame[@"args"];
    NSNumber *promptId = frame[@"prompt_id"];
    if (![toolId isKindOfClass:NSString.class] || toolId.length == 0 || toolId.length > 128 ||
        ![tool isKindOfClass:NSString.class] || tool.length == 0 || tool.length > 128 ||
        ![arguments isKindOfClass:NSDictionary.class] ||
        ![promptId isKindOfClass:NSNumber.class] || promptId.longLongValue < 1) {
      [self failAll:@"Claude Agent sent an invalid tool request."];
      return;
    }
    NSData *idData = [toolId dataUsingEncoding:NSUTF8StringEncoding];
    NSData *toolData = [tool dataUsingEncoding:NSUTF8StringEncoding];
    NSData *argumentData = [NSJSONSerialization dataWithJSONObject:arguments options:0 error:nil];
    if (idData == nil || toolData == nil || argumentData == nil || argumentData.length > 65536) {
      [self failAll:@"Claude Agent sent an invalid tool request."];
      return;
    }
    zb_drawer_agent_tool_call(windowId, session.UTF8String,
                              promptId.longLongValue, idData.bytes,
                              idData.length, toolData.bytes, toolData.length,
                              argumentData.bytes, argumentData.length);
  } else if ([type isEqualToString:@"result"]) {
    zb_drawer_agent_end(windowId);
    zb_drawer_agent_status(windowId, "ready", "-");
    [self flushWindow:windowId];
  } else if ([type isEqualToString:@"error"]) {
    NSString *message = [frame[@"message"] isKindOfClass:NSString.class]
        ? frame[@"message"] : @"Claude Agent could not answer.";
    NSData *utf8 = [message dataUsingEncoding:NSUTF8StringEncoding];
    zb_drawer_agent_message(windowId, "error", utf8.bytes, utf8.length);
    zb_drawer_agent_status(windowId, "ready", "-");
  } else if ([type isEqualToString:@"session_ended"]) {
    [self.confirmedSessions removeObject:session];
    [self.sessionWindows removeObjectForKey:session];
    [self.windowSessions removeObjectForKey:window];
  }
}

- (void)flushWindow:(unsigned int)windowId {
  if (self.state != ZBMacHelperReady) return;
  NSNumber *window = @(windowId);
  NSMutableArray<NSString *> *queue = self.pending[window];
  if (queue.count == 0) return;
  NSString *session = self.windowSessions[window];
  if (session == nil) {
    session = [NSString stringWithFormat:@"s-%u-1", windowId];
    self.windowSessions[window] = session;
    self.sessionWindows[session] = window;
    if (![self writeFrame:@{
          @"type": @"open_session", @"session": session,
          @"window_id": [NSString stringWithFormat:@"window-%u", windowId],
        }]) {
      [self failAll:@"Claude Agent could not receive a request."];
    }
    return;
  }
  if (![self.confirmedSessions containsObject:session]) return;
  NSString *text = queue.firstObject;
  [queue removeObjectAtIndex:0];
  if (![self writeFrame:@{
        @"type": @"prompt", @"session": session,
        @"prompt_id": @(++self.promptSequence), @"text": text,
      }]) {
    [self failAll:@"Claude Agent could not receive a request."];
    return;
  }
  zb_drawer_agent_status(windowId, "busy", "-");
}

- (void)postToolResultForWindow:(unsigned int)windowId session:(NSString *)session
                             id:(NSString *)toolId ok:(BOOL)ok body:(NSData *)body {
  if (self.e2eToolSteps != nil && windowId == self.e2eToolWindow &&
      [session isEqualToString:self.e2eToolSession] &&
      self.e2eToolIndex < self.e2eToolSteps.count) {
    NSDictionary *step = self.e2eToolSteps[self.e2eToolIndex];
    if (![toolId isEqualToString:step[@"id"]]) return;
    NSString *encoded = [body base64EncodedStringWithOptions:0];
    printf("MAC_AGENT_TOOL\t%s\t%d\t%s\n", toolId.UTF8String,
           ok ? 1 : 0, encoded.UTF8String);
    fflush(stdout);
    self.e2eToolIndex += 1;
    if (self.e2eToolIndex < self.e2eToolSteps.count) {
      dispatch_async(dispatch_get_main_queue(), ^{ [self runNextE2ETool]; });
    } else {
      [self.sessionWindows removeObjectForKey:self.e2eToolSession];
      [self.windowSessions removeObjectForKey:@(self.e2eToolWindow)];
      self.e2eToolSteps = nil;
      self.e2eToolSession = nil;
    }
    return;
  }
  if (self.state != ZBMacHelperReady ||
      ![self.windowSessions[@(windowId)] isEqualToString:session] || toolId.length == 0) return;
  NSMutableDictionary *frame = [@{
    @"type": @"tool_result", @"session": session, @"id": toolId, @"ok": @(ok),
  } mutableCopy];
  if (ok) {
    id content = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (![content isKindOfClass:NSArray.class]) {
      frame[@"ok"] = @NO;
      frame[@"error"] = @"the browser sent a bad answer";
    } else {
      frame[@"content"] = content;
    }
  } else {
    NSString *message = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
    frame[@"error"] = message.length != 0 ? message : @"tool failed";
  }
  if (![self writeFrame:frame]) [self failAll:@"Claude Agent could not receive a tool result."];
}

- (void)startE2EToolsForWindow:(unsigned int)windowId {
  if (!zb_mac_drawer_e2e_enabled() || self.e2eToolSteps != nil) return;
  NSData *data = zb_read_private_action(getenv("ZB_DEBUG_MAC_AGENT_TOOLS_FILE"));
  if (data == nil) return;
  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![parsed isKindOfClass:NSDictionary.class]) return;
  NSDictionary *action = parsed;
  NSNumber *version = action[@"version"];
  NSArray *steps = action[@"steps"];
  if (![version isKindOfClass:NSNumber.class] || version.integerValue != 1 ||
      ![steps isKindOfClass:NSArray.class] || steps.count == 0 || steps.count > 8) return;
  for (id item in steps) {
    if (![item isKindOfClass:NSDictionary.class]) return;
    NSDictionary *step = item;
    NSString *toolId = step[@"id"];
    NSString *tool = step[@"tool"];
    NSDictionary *arguments = step[@"args"];
    if (![toolId isKindOfClass:NSString.class] || toolId.length == 0 || toolId.length > 128 ||
        ![tool isKindOfClass:NSString.class] || tool.length == 0 || tool.length > 128 ||
        ![arguments isKindOfClass:NSDictionary.class]) return;
  }
  self.e2eToolSteps = [steps copy];
  self.e2eToolIndex = 0;
  self.e2eToolWindow = windowId;
  self.e2eToolSession = [NSString stringWithFormat:@"e2e-tools-%u", windowId];
  self.inputSequence = 0;
  self.sessionWindows[self.e2eToolSession] = @(windowId);
  self.windowSessions[@(windowId)] = self.e2eToolSession;
  [self runNextE2ETool];
}

- (void)runNextE2ETool {
  if (self.e2eToolSteps == nil || self.e2eToolIndex >= self.e2eToolSteps.count) return;
  NSDictionary *step = self.e2eToolSteps[self.e2eToolIndex];
  NSString *toolId = step[@"id"];
  NSString *tool = step[@"tool"];
  NSDictionary *frame = @{
    @"v": @1,
    @"seq": @(self.inputSequence + 1),
    @"type": @"tool_call",
    @"session": self.e2eToolSession,
    @"prompt_id": @1,
    @"id": toolId,
    @"tool": tool,
    @"args": step[@"args"],
  };
  [self receiveFrame:frame pid:0];
}

- (void)helperEnded:(pid_t)pid malformed:(BOOL)malformed {
  if (pid != self.helperPid) return;
  self.helperPid = -1;
  zb_close_fd(&_helperInput);
  if (self.state == ZBMacHelperStopping) return;
  [self failAll:malformed ? @"Claude Agent sent an invalid response."
                          : @"Claude Agent stopped unexpectedly."];
}

- (void)stop {
  if (self.state == ZBMacHelperStopping) return;
  self.state = ZBMacHelperStopping;
  if (self.helperInput >= 0) (void)[self writeFrame:@{@"type": @"shutdown"}];
  zb_close_fd(&_helperInput);
  zb_close_fd(&_netInput);
  zb_close_fd(&_netOutput);
  zb_terminate_owned_group(&_helperPid);
  zb_terminate_owned_group(&_netPid);
  [self.pending removeAllObjects];
  [self.windowSessions removeAllObjects];
  [self.sessionWindows removeAllObjects];
  [self.confirmedSessions removeAllObjects];
  self.state = ZBMacHelperIdle;
}

@end

int zb_agent_helper_configured(void) {
  __block BOOL configured = NO;
  if (NSThread.isMainThread) {
    configured = ZBMacAgentHelper.shared.isConfigured;
  } else {
    dispatch_sync(dispatch_get_main_queue(), ^{
      configured = ZBMacAgentHelper.shared.isConfigured;
    });
  }
  return configured ? 1 : 0;
}

void zb_agent_helper_send(unsigned int window_id, const char *text) {
  NSString *message = text != NULL ? [NSString stringWithUTF8String:text] : nil;
  if (message.length == 0) return;
  dispatch_block_t send = ^{
    [ZBMacAgentHelper.shared sendWindow:window_id text:message];
  };
  if (NSThread.isMainThread) send(); else dispatch_async(dispatch_get_main_queue(), send);
}

void zb_agent_helper_stop(void) {
  if (NSThread.isMainThread) {
    [ZBMacAgentHelper.shared stop];
  } else {
    dispatch_sync(dispatch_get_main_queue(), ^{ [ZBMacAgentHelper.shared stop]; });
  }
}

void zb_mac_agent_tools_e2e_start(unsigned int window_id) {
  dispatch_block_t start = ^{
    [ZBMacAgentHelper.shared startE2EToolsForWindow:window_id];
  };
  if (NSThread.isMainThread) start(); else dispatch_async(dispatch_get_main_queue(), start);
}

const char *zb_agent_helper_home(void) {
  return ZBMacAgentHelper.shared.home.fileSystemRepresentation;
}

void zb_agent_helper_post_tool_result(unsigned int window_id, const char *session,
                                      const char *tool_id, size_t tool_id_len, int ok,
                                      const char *body, size_t body_len) {
  NSString *sessionText = session != NULL ? [NSString stringWithUTF8String:session] : nil;
  NSString *idText = tool_id != NULL
      ? [[NSString alloc] initWithBytes:tool_id length:tool_id_len encoding:NSUTF8StringEncoding] : nil;
  NSData *bodyData = body != NULL ? [NSData dataWithBytes:body length:body_len] : NSData.data;
  if (sessionText == nil || idText == nil) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    [ZBMacAgentHelper.shared postToolResultForWindow:window_id session:sessionText
                                                  id:idText ok:ok != 0 body:bodyData];
  });
}

int zb_agent_image_fit(const unsigned char *png, size_t len, size_t max_b64,
                       char **out_b64, const char **out_mime) {
  if (out_b64 == NULL || out_mime == NULL) return ZB_IMAGE_FIT_UNREADABLE;
  *out_b64 = NULL;
  *out_mime = NULL;
  static const unsigned char signature[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
  static const unsigned char iend[12] = {0, 0, 0, 0, 'I', 'E', 'N', 'D', 0xae, 0x42, 0x60, 0x82};
  if (png == NULL || len < sizeof signature + sizeof iend ||
      memcmp(png, signature, sizeof signature) != 0 ||
      memcmp(png + len - sizeof iend, iend, sizeof iend) != 0) return ZB_IMAGE_FIT_UNREADABLE;
  @autoreleasepool {
    NSData *data = [NSData dataWithBytes:png length:len];
    if ([NSBitmapImageRep imageRepWithData:data] == nil) return ZB_IMAGE_FIT_UNREADABLE;
    if (((len + 2) / 3) * 4 > max_b64) return ZB_IMAGE_FIT_TOO_LARGE;
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    *out_b64 = strdup(encoded.UTF8String);
    if (*out_b64 == NULL) return ZB_IMAGE_FIT_TOO_LARGE;
    *out_mime = "image/png";
    return ZB_IMAGE_FIT_OK;
  }
}

void zb_agent_image_free(void *b64) {
  free(b64);
}

