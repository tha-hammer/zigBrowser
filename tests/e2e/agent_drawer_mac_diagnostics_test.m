/* Product e2e for the private native Mac drawer diagnostics log.
 *
 * Only visible status/error diagnostics belong in this log. Conversation
 * bodies and token-shaped strings must never be persisted. */
#import "agent_drawer_mac.h"
#import "agent_helper.h"

#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

void zb_drawer_agent_status(unsigned int window_id, const char *state,
                            const char *reason);
typedef void (*ZBToolFailureFn)(unsigned int, const char *, size_t,
                                const char *, size_t);

static char agent_home[PATH_MAX];

int zb_agent_helper_configured(void) { return 1; }
const char *zb_agent_helper_home(void) { return agent_home; }
void zb_agent_helper_send(unsigned int window_id, const char *text) {
  (void)window_id;
  (void)text;
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
int zb_mac_drawer_e2e_enabled(void) { return 0; }
unsigned int zb_drawer_demo_messages(void) { return 0; }
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

static void fail(NSString *message) {
  fprintf(stderr, "FAIL agent-drawer-mac-diagnostics: %s\n", message.UTF8String);
  exit(1);
}

static NSString *read_log(NSString *path) {
  NSError *error = nil;
  NSString *text = [NSString stringWithContentsOfFile:path
                                             encoding:NSUTF8StringEncoding
                                                error:&error];
  if (text == nil) fail([NSString stringWithFormat:@"drawer.log missing after agent error: %@", error]);
  return text;
}

static void require_contains(NSString *text, NSString *needle, NSString *what) {
  if ([text rangeOfString:needle].location == NSNotFound) fail(what);
}

int main(void) {
  @autoreleasepool {
    char template[] = "/tmp/zb-drawer-diagnostics-XXXXXX";
    char *made = mkdtemp(template);
    if (made == NULL || strlen(made) >= sizeof(agent_home)) fail(@"mkdtemp failed");
    strcpy(agent_home, made);
    NSString *home = [NSString stringWithUTF8String:agent_home];
    NSString *log = [home stringByAppendingPathComponent:@"state/drawer.log"];
    NSString *rotated = [log stringByAppendingString:@".1"];

    [NSApplication sharedApplication];
    NSView *panel = zb_mac_drawer_panel_create(NSMakeRect(0, 0, 760, 420),
                                                77, NULL, NULL);
    if (panel == nil) fail(@"create returned nil");

    zb_drawer_agent_status(77, "unavailable", "auth-failed");
    NSString *contents = read_log(log);
    require_contains(contents, @"\tERROR\tClaude rejected the saved token.",
                     @"agent error was not logged as ERROR");

    zb_mac_drawer_panel_append(panel, "status", "network status sk-ant-FAKE_token-123");
    zb_mac_drawer_panel_append(panel, "user", "PRIVATE USER sk-ant-USERSECRET");
    zb_mac_drawer_panel_append(panel, "assistant", "PRIVATE ASSISTANT sk-ant-ASSTSECRET");
    ZBToolFailureFn tool_failure = (ZBToolFailureFn)dlsym(RTLD_DEFAULT,
                                                          "zb_drawer_agent_tool_failure");
    if (tool_failure == NULL) fail(@"tool-failure diagnostics bridge missing");
    const char *tool = "navigate";
    const char *tool_error = "failed with sk-ant-TOOL_secret";
    tool_failure(77, tool, strlen(tool), tool_error, strlen(tool_error));

    contents = read_log(log);
    require_contains(contents, @"\tSTATUS\tnetwork status [REDACTED]",
                     @"status line or token redaction missing");
    require_contains(contents, @"\tERROR\ttool=navigate failed with [REDACTED]",
                     @"tool failure did not retain its tool name");
    if ([contents containsString:@"sk-ant-"] || [contents containsString:@"PRIVATE USER"] ||
        [contents containsString:@"PRIVATE ASSISTANT"]) {
      fail(@"conversation text or a token-shaped string reached drawer.log");
    }
    NSRegularExpression *stamp = [NSRegularExpression
        regularExpressionWithPattern:@"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\t"
                               options:NSRegularExpressionAnchorsMatchLines error:nil];
    if ([stamp numberOfMatchesInString:contents options:0
                                 range:NSMakeRange(0, contents.length)] < 3) {
      fail(@"diagnostic lines lack UTC timestamps");
    }
    struct stat st;
    if (lstat(log.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode) ||
        (st.st_mode & 0777) != 0600) fail(@"drawer.log is not a regular 0600 file");

    NSMutableData *full = [NSMutableData dataWithLength:1024 * 1024];
    memset(full.mutableBytes, 'x', full.length);
    if (![full writeToFile:log atomically:NO]) fail(@"could not seed rotation boundary");
    chmod(log.fileSystemRepresentation, 0600);
    zb_mac_drawer_panel_append(panel, "status", "after rotation");
    contents = read_log(log);
    require_contains(contents, @"\tSTATUS\tafter rotation\n", @"post-rotation line missing");
    if (lstat(rotated.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode) ||
        st.st_size != 1024 * 1024) fail(@"one-megabyte log was not rotated to drawer.log.1");

    [[NSFileManager defaultManager] removeItemAtPath:home error:nil];
    puts("PASS agent-drawer-mac-diagnostics private-redacted-rotating-log");
  }
  return 0;
}
