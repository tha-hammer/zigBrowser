/* MS5.3/MS6.3 product test executable.
 *
 * Parent mode stores a random token in a disposable Keychain, then calls the
 * product macOS helper boundary. That boundary must read the Keychain item,
 * place an unnamed Unix socket endpoint on the spawned helper's fd 3, and
 * preserve no ambient descriptor. Child mode reopens /dev/fd/3 exactly as the
 * Claude CLI does, verifies a SHA-256 supplied by the parent, and proves the
 * raw token is absent from its argv and environment. No token bytes are
 * printed or written to a regular file by this test.
 */
#include "agent_secrets_mac.h"

#include <CommonCrypto/CommonDigest.h>
#include <Security/Security.h>
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* Weak so the committed red reaches one stable product assertion instead of
 * failing at link time before the test can identify the missing boundary. */
extern int zb_mac_helper_spawn_fd3_for_test(
    const char *const *argv, const char *const *envp, int stdin_fd, int stdout_fd,
    const char *keychain_path, const char *unlock_password,
    const char *service, const char *account, pid_t *out_pid, char **out_err)
    __attribute__((weak_import));

static void sha256_hex(const unsigned char *data, size_t length, char out[CC_SHA256_DIGEST_LENGTH * 2 + 1]) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data, (CC_LONG)length, digest);
  for (size_t i = 0; i < sizeof digest; ++i) snprintf(out + i * 2, 3, "%02x", digest[i]);
  out[CC_SHA256_DIGEST_LENGTH * 2] = '\0';
}

static int vector_has(char *const *items, const char *token, size_t token_len) {
  for (; items != NULL && *items != NULL; ++items) {
    size_t len = strlen(*items);
    if (len >= token_len && memmem(*items, len, token, token_len) != NULL) return 1;
  }
  return 0;
}

static int child_main(int argc, char **argv) {
  if (argc != 3 || strlen(argv[2]) != CC_SHA256_DIGEST_LENGTH * 2) {
    printf("FD3-REOPEN-FAILED bad-child-arguments\n");
    return 2;
  }
  if (getenv("CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR") == NULL ||
      strcmp(getenv("CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"), "3") != 0) {
    printf("FD3-REOPEN-FAILED descriptor-environment\n");
    return 1;
  }
  int fd = open("/dev/fd/3", O_RDONLY);
  if (fd < 0) {
    printf("FD3-REOPEN-FAILED errno=%d\n", errno);
    return 1;
  }
  char token[1025];
  size_t length = 0;
  while (length < sizeof token - 1) {
    ssize_t got = read(fd, token + length, sizeof token - 1 - length);
    if (got < 0 && errno == EINTR) continue;
    if (got <= 0) break;
    length += (size_t)got;
  }
  close(fd);
  token[length] = '\0';
  if (length == 0 || vector_has(argv, token, length) || vector_has(*_NSGetEnviron(), token, length)) {
    explicit_bzero(token, sizeof token);
    printf("FD3-REOPEN-FAILED token-in-argv-or-env\n");
    return 1;
  }
  char digest[CC_SHA256_DIGEST_LENGTH * 2 + 1];
  sha256_hex((const unsigned char *)token, length, digest);
  explicit_bzero(token, sizeof token);
  if (strcmp(digest, argv[2]) != 0) {
    printf("FD3-REOPEN-FAILED digest-mismatch\n");
    return 1;
  }
  printf("FD3-REOPEN-OK bytes=%zu sha256=%s\n", length, digest);
  return 0;
}

static char *read_all(int fd, size_t *out_length) {
  size_t cap = 1024, length = 0;
  char *text = malloc(cap);
  if (text == NULL) return NULL;
  for (;;) {
    if (length + 1 == cap) {
      cap *= 2;
      char *grown = realloc(text, cap);
      if (grown == NULL) { free(text); return NULL; }
      text = grown;
    }
    ssize_t got = read(fd, text + length, cap - length - 1);
    if (got < 0 && errno == EINTR) continue;
    if (got <= 0) break;
    length += (size_t)got;
  }
  text[length] = '\0';
  *out_length = length;
  return text;
}

static int regular_file_has(const char *path, const char *token, size_t token_len) {
  struct stat st;
  if (lstat(path, &st) != 0 || !S_ISREG(st.st_mode)) return 0;
  int fd = open(path, O_RDONLY | O_NOFOLLOW);
  if (fd < 0) return 0;
  size_t length = 0;
  char *text = read_all(fd, &length);
  close(fd);
  int found = text != NULL && length >= token_len && memmem(text, length, token, token_len) != NULL;
  if (text != NULL) { explicit_bzero(text, length); free(text); }
  return found;
}

static int parent_main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s --parent <profile-or-none> <scratch>\n", argv[0]);
    return 2;
  }
  if (zb_mac_helper_spawn_fd3_for_test == NULL) {
    printf("FAIL\tms6-3-product-channel\tzb_mac_helper_spawn_fd3_for_test is missing\n");
    return 1;
  }
  const char *profile = argv[2], *scratch = argv[3];
  char keychain_path[1024];
  snprintf(keychain_path, sizeof keychain_path, "%s/ms63-%d.keychain", scratch, getpid());
  const char *password = "zb-ms63-disposable";
  const char *service = "dev.zigbrowser.MS63ProductTest";
  const char *account = "default";
  SecKeychainRef keychain = NULL;
  if (SecKeychainCreate(keychain_path, (UInt32)strlen(password), password, false, NULL, &keychain) != errSecSuccess) {
    printf("FAIL\tms6-3-product-channel\tdisposable Keychain creation failed\n");
    return 1;
  }

  char token[96];
  snprintf(token, sizeof token, "sk-ant-oat01-%08x%08x%08x%08x",
           arc4random(), arc4random(), arc4random(), arc4random());
  char *error = NULL;
  int result = zb_keychain_store(keychain_path, password, service, account, token, &error);
  if (result != ZB_KC_OK) {
    printf("FAIL\tms6-3-product-channel\tdisposable Keychain store failed\n");
    free(error);
    SecKeychainDelete(keychain); CFRelease(keychain);
    explicit_bzero(token, sizeof token);
    return 1;
  }
  free(error); error = NULL;
  char digest[CC_SHA256_DIGEST_LENGTH * 2 + 1];
  sha256_hex((const unsigned char *)token, strlen(token), digest);

  char self[4096];
  uint32_t self_len = sizeof self;
  if (_NSGetExecutablePath(self, &self_len) != 0) {
    printf("FAIL\tms6-3-product-channel\texecutable path unavailable\n");
    SecKeychainDelete(keychain); CFRelease(keychain);
    explicit_bzero(token, sizeof token);
    return 1;
  }
  char define[1200], home[1200], temp[1200];
  snprintf(define, sizeof define, "SCRATCHPAD=%s", scratch);
  snprintf(home, sizeof home, "HOME=%s", scratch);
  snprintf(temp, sizeof temp, "TMPDIR=%s", scratch);
  const char *envp[] = {
    "PATH=/usr/bin:/bin", "LANG=C", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR=3", home, temp, NULL,
  };
  const char *plain_argv[] = { self, "--child", digest, NULL };
  const char *sandbox_argv[] = {
    "/usr/bin/sandbox-exec", "-f", profile, "-D", define, self, "--child", digest, NULL,
  };
  const char *const *child_argv = strcmp(profile, "none") == 0 ? plain_argv : sandbox_argv;

  int output[2];
  if (pipe(output) != 0) {
    printf("FAIL\tms6-3-product-channel\toutput pipe failed\n");
    SecKeychainDelete(keychain); CFRelease(keychain);
    explicit_bzero(token, sizeof token);
    return 1;
  }
  pid_t pid = -1;
  result = zb_mac_helper_spawn_fd3_for_test(child_argv, envp, -1, output[1],
                                             keychain_path, password, service, account, &pid, &error);
  close(output[1]);
  size_t output_len = 0;
  char *child_output = read_all(output[0], &output_len);
  close(output[0]);
  int status = 0;
  if (pid > 1) waitpid(pid, &status, 0);

  int failed = 0;
  if (result != ZB_KC_OK || pid <= 1) {
    printf("FAIL\tms6-3-product-channel\tproduct helper spawn failed\n");
    failed = 1;
  }
  if (error != NULL && strstr(error, token) != NULL) {
    printf("FAIL\tms6-3-product-channel\ttoken appeared in error text\n");
    failed = 1;
  }
  if (child_output == NULL || (output_len >= strlen(token) && memmem(child_output, output_len, token, strlen(token)) != NULL)) {
    printf("FAIL\tms6-3-product-channel\ttoken appeared in child output\n");
    failed = 1;
  }
  if (strcmp(profile, "none") != 0 && regular_file_has(profile, token, strlen(token))) {
    printf("FAIL\tms6-3-product-channel\ttoken appeared in profile file\n");
    failed = 1;
  }

  int expect_denied = strstr(profile, "deny") != NULL;
  if (!failed && !expect_denied) {
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0 ||
        strstr(child_output, "FD3-REOPEN-OK") == NULL || strstr(child_output, digest) == NULL) {
      printf("FAIL\tms6-3-product-channel\tfd 3 did not reopen with the Keychain token\n");
      failed = 1;
    }
  } else if (!failed && expect_denied) {
    if (!WIFEXITED(status) || WEXITSTATUS(status) == 0 || strstr(child_output, "FD3-REOPEN-FAILED") == NULL) {
      printf("FAIL\tms6-3-product-channel\tdeny profile did not block fd 3 reopen\n");
      failed = 1;
    }
  }

  if (!failed) printf("PASS\tms6-3-product-channel\t%s\n", expect_denied ? "deny" : strcmp(profile, "none") == 0 ? "unsandboxed" : "sandboxed");
  free(error);
  if (child_output != NULL) free(child_output);
  SecKeychainDelete(keychain);
  CFRelease(keychain);
  explicit_bzero(token, sizeof token);
  return failed;
}

int main(int argc, char **argv) {
  if (argc >= 2 && strcmp(argv[1], "--child") == 0) return child_main(argc, argv);
  if (argc >= 2 && strcmp(argv[1], "--parent") == 0) return parent_main(argc, argv);
  fprintf(stderr, "usage: %s --parent|--child ...\n", argv[0]);
  return 2;
}

#pragma clang diagnostic pop
