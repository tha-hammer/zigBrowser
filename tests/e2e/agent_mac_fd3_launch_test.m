/* Product contract for the macOS Claude helper launch.
 *
 * The production-shaped launcher must source a token from the Keychain and
 * give it to the helper on fd 3 only.  The disposable-keychain entry exists
 * solely so this native test never reads or changes the login Keychain. */
#import <Foundation/Foundation.h>
#import <Security/Security.h>

#include "agent_secrets_mac.h"
#include "agent_spawn_posix.h"
#include "agent_token_fd_mac.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

extern char **environ;

static const char *const service = "dev.zigbrowser.AgentFd3ProductTest";
static const char *const account = "default";
static const char *const password = "zb-disposable-keychain";
static const char *const canary = "sk-ant-oat01-agentfd3productcanary_0123456789";

static int fail(const char *message) {
  fprintf(stderr, "FAIL agent-mac-fd3-launch: %s\n", message);
  return 1;
}

static int contains_canary(const char *text) {
  return text != NULL && strstr(text, canary) != NULL;
}

static int child_main(int argc, char **argv) {
  if (argc != 2 || strcmp(argv[1], "--fd3-child") != 0) return fail("bad child argv");
  for (int i = 0; i < argc; ++i) if (contains_canary(argv[i])) return fail("token appeared in argv");
  for (char **entry = environ; entry != NULL && *entry != NULL; ++entry)
    if (contains_canary(*entry)) return fail("token appeared in environment");

  struct stat st;
  if (fstat(3, &st) != 0 || !S_ISSOCK(st.st_mode)) return fail("fd 3 is not the private token socket");
  for (int fd = 4; fd < 64; ++fd) {
    errno = 0;
    if (fcntl(fd, F_GETFD) >= 0 || errno != EBADF) return fail("an unrelated descriptor reached the helper");
  }

  char token[1024];
  size_t used = 0;
  while (used < sizeof token - 1) {
    ssize_t n = read(3, token + used, sizeof token - 1 - used);
    if (n < 0 && errno == EINTR) continue;
    if (n < 0) return fail("fd 3 read failed");
    if (n == 0) break;
    used += (size_t)n;
  }
  token[used] = '\0';
  if (strcmp(token, canary) != 0) return fail("fd 3 did not contain the exact Keychain token");
  memset_s(token, sizeof token, 0, sizeof token);
  puts("PASS agent-mac-fd3-launch Keychain token reached child fd 3 only");
  return 0;
}

int main(int argc, char **argv) {
  if (argc > 1) return child_main(argc, argv);
  @autoreleasepool {
    char self[PATH_MAX];
    if (realpath(argv[0], self) == NULL) return fail("realpath failed");

    char root[] = "/tmp/zb-agent-fd3-product-XXXXXX";
    if (mkdtemp(root) == NULL) return fail("mkdtemp failed");
    char keychain[PATH_MAX];
    if (snprintf(keychain, sizeof keychain, "%s/test.keychain-db", root) >= (int)sizeof keychain)
      return fail("keychain path overflow");

    SecKeychainRef kc = NULL;
    OSStatus sec = SecKeychainCreate(keychain, (UInt32)strlen(password), password, false, NULL, &kc);
    if (sec != errSecSuccess || kc == NULL) return fail("disposable Keychain creation failed");

    char *error = NULL;
    if (zb_keychain_store(keychain, password, service, account, canary, &error) != ZB_KC_OK) {
      free(error);
      CFRelease(kc);
      return fail("disposable Keychain store failed");
    }
    free(error);

    int output[2];
    if (pipe(output) != 0) {
      CFRelease(kc);
      return fail("output pipe failed");
    }
    const char *const child_argv[] = {self, "--fd3-child", NULL};
    const char *const child_env[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
    pid_t pid = -1;
    error = NULL;
    int rc = zb_mac_helper_spawn_fd3_for_test(child_argv, child_env, -1, output[1],
                                               keychain, password, service, account, &pid, &error);
    close(output[1]);
    if (rc != ZB_KC_OK || pid <= 1) {
      free(error);
      close(output[0]);
      CFRelease(kc);
      return fail("product helper launch failed");
    }
    free(error);

    char report[512];
    ssize_t got = read(output[0], report, sizeof report - 1);
    close(output[0]);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    if (got < 0) got = 0;
    report[got] = '\0';

    (void)SecKeychainDelete(kc);
    CFRelease(kc);
    (void)unlink(keychain);
    (void)rmdir(root);

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return fail("helper child did not exit cleanly");
    if (contains_canary(report)) return fail("token appeared in child output");
    if (strcmp(report, "PASS agent-mac-fd3-launch Keychain token reached child fd 3 only\n") != 0)
      return fail("unexpected child report");
    fputs(report, stdout);
    return 0;
  }
}

#pragma clang diagnostic pop
