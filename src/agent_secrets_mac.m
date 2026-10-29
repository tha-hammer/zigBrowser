/* macOS Keychain backend of the Claude Agent's token store (MS5.2); see agent_secrets_mac.h.
 *
 * Generic-password items via SecItem over a legacy file keychain. SecKeychain* is deprecated since 10.10 but
 * functional on macOS 15 and is the only headless-testable path (the data-protection keychain needs code
 * signing + a keychain-access-group entitlement, which is MS9); the deprecation is silenced locally. */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "agent_secrets_mac.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"  // SecKeychain* (legacy file keychain), see header

extern int zb_mac_unsandboxed_dev(void) __attribute__((weak_import));

static const char *const ZBMacTokenDirectory = "secrets";
static const char *const ZBMacTokenFile = "claude_token";
static const char *const ZBMacUnsafeTokenFile = "token file has unsafe permissions";

static int zb_setup_token_slice(const char *text, const char **out_start, size_t *out_len);

int zb_mac_agent_token_file_enabled(void) {
  return zb_mac_unsandboxed_dev != NULL && zb_mac_unsandboxed_dev() != 0;
}

static char *zb_kc_errf(OSStatus st, const char *what) {
  char buf[128];
  snprintf(buf, sizeof buf, "keychain %s failed: OSStatus %d", what, (int)st);
  return strdup(buf);
}

static void zb_token_error(char **out_err, const char *message) {
  if (out_err != NULL) *out_err = strdup(message);
}

enum {
  ZB_TOKEN_PATH_OK = 0,
  ZB_TOKEN_PATH_ABSENT = 1,
  ZB_TOKEN_PATH_UNSAFE = 2,
};

static int zb_token_open_secrets(const char *agent_home, int create,
                                 int *out_fd, char **out_err) {
  *out_fd = -1;
  if (agent_home == NULL || agent_home[0] != '/') {
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_TOKEN_PATH_UNSAFE;
  }
  int home_fd = open(agent_home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (home_fd < 0) {
    if (!create && errno == ENOENT) return ZB_TOKEN_PATH_ABSENT;
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_TOKEN_PATH_UNSAFE;
  }
  struct stat home_info;
  if (fstat(home_fd, &home_info) != 0 || !S_ISDIR(home_info.st_mode) ||
      home_info.st_uid != geteuid()) {
    close(home_fd);
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_TOKEN_PATH_UNSAFE;
  }
  if (create && mkdirat(home_fd, ZBMacTokenDirectory, 0700) != 0 && errno != EEXIST) {
    close(home_fd);
    zb_token_error(out_err, "token file could not be saved");
    return ZB_TOKEN_PATH_UNSAFE;
  }
  struct stat before;
  if (fstatat(home_fd, ZBMacTokenDirectory, &before, AT_SYMLINK_NOFOLLOW) != 0) {
    int saved = errno;
    close(home_fd);
    if (!create && saved == ENOENT) return ZB_TOKEN_PATH_ABSENT;
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_TOKEN_PATH_UNSAFE;
  }
  if (!S_ISDIR(before.st_mode) || before.st_uid != geteuid() ||
      (before.st_mode & 0777) != 0700) {
    close(home_fd);
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_TOKEN_PATH_UNSAFE;
  }
  int dir_fd = openat(home_fd, ZBMacTokenDirectory,
                      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  close(home_fd);
  if (dir_fd < 0) {
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_TOKEN_PATH_UNSAFE;
  }
  struct stat after;
  if (fstat(dir_fd, &after) != 0 || before.st_dev != after.st_dev ||
      before.st_ino != after.st_ino || !S_ISDIR(after.st_mode) ||
      after.st_uid != geteuid() || (after.st_mode & 0777) != 0700) {
    close(dir_fd);
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_TOKEN_PATH_UNSAFE;
  }
  *out_fd = dir_fd;
  return ZB_TOKEN_PATH_OK;
}

static int zb_token_existing_info(int dir_fd, struct stat *out, char **out_err) {
  if (fstatat(dir_fd, ZBMacTokenFile, out, AT_SYMLINK_NOFOLLOW) != 0) {
    if (errno == ENOENT) return ZB_TOKEN_PATH_ABSENT;
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_TOKEN_PATH_UNSAFE;
  }
  if (!S_ISREG(out->st_mode) || out->st_uid != geteuid() || out->st_nlink != 1 ||
      (out->st_mode & 0777) != 0600) {
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_TOKEN_PATH_UNSAFE;
  }
  return ZB_TOKEN_PATH_OK;
}

static int zb_token_file_load(const char *agent_home, char **out_token, char **out_err) {
  if (out_token != NULL) *out_token = NULL;
  int dir_fd = -1;
  int path_result = zb_token_open_secrets(agent_home, 0, &dir_fd, out_err);
  if (path_result == ZB_TOKEN_PATH_ABSENT) return ZB_KC_ABSENT;
  if (path_result != ZB_TOKEN_PATH_OK) return ZB_KC_UNAVAILABLE;
  struct stat before;
  path_result = zb_token_existing_info(dir_fd, &before, out_err);
  if (path_result == ZB_TOKEN_PATH_ABSENT) {
    close(dir_fd);
    return ZB_KC_ABSENT;
  }
  if (path_result != ZB_TOKEN_PATH_OK || before.st_size <= 0 || before.st_size > 512) {
    close(dir_fd);
    if (path_result == ZB_TOKEN_PATH_OK) zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_KC_UNAVAILABLE;
  }
  int fd = openat(dir_fd, ZBMacTokenFile, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) {
    close(dir_fd);
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_KC_UNAVAILABLE;
  }
  struct stat after;
  if (fstat(fd, &after) != 0 || before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
      !S_ISREG(after.st_mode) || after.st_uid != geteuid() || after.st_nlink != 1 ||
      (after.st_mode & 0777) != 0600 || after.st_size != before.st_size) {
    close(fd);
    close(dir_fd);
    zb_token_error(out_err, ZBMacUnsafeTokenFile);
    return ZB_KC_UNAVAILABLE;
  }
  size_t length = (size_t)after.st_size;
  char *token = calloc(length + 1, 1);
  if (token == NULL) {
    close(fd);
    close(dir_fd);
    zb_token_error(out_err, "token file could not be read");
    return ZB_KC_UNAVAILABLE;
  }
  size_t used = 0;
  while (used < length) {
    ssize_t count = read(fd, token + used, length - used);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) break;
    used += (size_t)count;
  }
  unsigned char extra = 0;
  ssize_t tail;
  do { tail = read(fd, &extra, 1); } while (tail < 0 && errno == EINTR);
  close(fd);
  close(dir_fd);
  if (used != length || tail != 0) {
    memset_s(token, length, 0, length);
    free(token);
    zb_token_error(out_err, "token file could not be read");
    return ZB_KC_UNAVAILABLE;
  }
  const char *start = NULL;
  size_t token_length = 0;
  if (!zb_setup_token_slice(token, &start, &token_length) || start != token || token_length != length) {
    memset_s(token, length, 0, length);
    free(token);
    zb_token_error(out_err, "token file is invalid");
    return ZB_KC_UNAVAILABLE;
  }
  if (out_token != NULL) *out_token = token;
  else zb_keychain_free(token);
  return ZB_KC_OK;
}

static int zb_token_file_store(const char *agent_home, const char *token,
                               size_t length, char **out_err) {
  int dir_fd = -1;
  int path_result = zb_token_open_secrets(agent_home, 1, &dir_fd, out_err);
  if (path_result != ZB_TOKEN_PATH_OK) return ZB_KC_UNAVAILABLE;
  struct stat existing;
  path_result = zb_token_existing_info(dir_fd, &existing, out_err);
  if (path_result == ZB_TOKEN_PATH_UNSAFE) {
    close(dir_fd);
    return ZB_KC_UNAVAILABLE;
  }
  char temporary[96];
  int temp_fd = -1;
  for (unsigned attempt = 0; attempt < 32 && temp_fd < 0; ++attempt) {
    snprintf(temporary, sizeof temporary, ".claude_token.tmp.%ld.%08x",
             (long)getpid(), arc4random());
    temp_fd = openat(dir_fd, temporary,
                     O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (temp_fd < 0 && errno != EEXIST) break;
  }
  if (temp_fd < 0) {
    close(dir_fd);
    zb_token_error(out_err, "token file could not be saved");
    return ZB_KC_UNAVAILABLE;
  }
  int failed = fchmod(temp_fd, 0600) != 0;
  size_t used = 0;
  while (!failed && used < length) {
    ssize_t count = write(temp_fd, token + used, length - used);
    if (count < 0 && errno == EINTR) continue;
    if (count <= 0) { failed = 1; break; }
    used += (size_t)count;
  }
  if (!failed && fsync(temp_fd) != 0) failed = 1;
  if (close(temp_fd) != 0) failed = 1;
  if (!failed && renameat(dir_fd, temporary, dir_fd, ZBMacTokenFile) != 0) failed = 1;
  if (!failed && fsync(dir_fd) != 0) failed = 1;
  if (failed) (void)unlinkat(dir_fd, temporary, 0);
  close(dir_fd);
  if (failed) {
    zb_token_error(out_err, "token file could not be saved");
    return ZB_KC_UNAVAILABLE;
  }
  return ZB_KC_OK;
}

static int zb_token_file_remove(const char *agent_home, char **out_err) {
  int dir_fd = -1;
  int path_result = zb_token_open_secrets(agent_home, 0, &dir_fd, out_err);
  if (path_result == ZB_TOKEN_PATH_ABSENT) return ZB_KC_OK;
  if (path_result != ZB_TOKEN_PATH_OK) return ZB_KC_UNAVAILABLE;
  struct stat existing;
  path_result = zb_token_existing_info(dir_fd, &existing, out_err);
  if (path_result == ZB_TOKEN_PATH_ABSENT) {
    close(dir_fd);
    return ZB_KC_OK;
  }
  if (path_result != ZB_TOKEN_PATH_OK || unlinkat(dir_fd, ZBMacTokenFile, 0) != 0 ||
      fsync(dir_fd) != 0) {
    close(dir_fd);
    if (path_result == ZB_TOKEN_PATH_OK && out_err != NULL && *out_err == NULL)
      zb_token_error(out_err, "token file could not be removed");
    return ZB_KC_UNAVAILABLE;
  }
  close(dir_fd);
  return ZB_KC_OK;
}

/* Open + (optionally) unlock the keychain named by path. Returns errSecSuccess with *out_kc set (the caller
 * CFReleases it), or an OSStatus on failure. A NULL path means the DEFAULT (login) keychain: it is resolved
 * to a concrete ref via SecKeychainCopyDefault and pinned, so every SecItem op is confined to that one
 * keychain — NOT the multi-keychain default SEARCH LIST, which could return/update/delete a colliding
 * (service, account) item in another searched keychain (RoseCat 38a9f37 #1). */
static OSStatus zb_kc_open(const char *keychain_path, const char *unlock_password, SecKeychainRef *out_kc) {
  *out_kc = NULL;
  if (keychain_path == NULL) {
    SecKeychainRef def = NULL;
    OSStatus st = SecKeychainCopyDefault(&def);
    if (st != errSecSuccess || def == NULL) return st == errSecSuccess ? errSecNoSuchKeychain : st;
    *out_kc = def;
    return errSecSuccess;
  }
  SecKeychainRef kc = NULL;
  OSStatus st = SecKeychainOpen(keychain_path, &kc);
  if (st != errSecSuccess || kc == NULL) return st == errSecSuccess ? errSecNoSuchKeychain : st;
  if (unlock_password != NULL) {
    st = SecKeychainUnlock(kc, (UInt32)strlen(unlock_password), unlock_password, true);
    if (st != errSecSuccess) { CFRelease(kc); return st; }
  }
  *out_kc = kc;
  return errSecSuccess;
}

static NSMutableDictionary *zb_kc_query(const char *service, const char *account) {
  NSMutableDictionary *q = [NSMutableDictionary dictionary];
  q[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
  q[(__bridge id)kSecAttrService] = [NSString stringWithUTF8String:service ?: ""];
  q[(__bridge id)kSecAttrAccount] = [NSString stringWithUTF8String:account ?: ""];
  return q;
}

/* kSecUseAuthenticationUIFail covers modern authentication policy, but a
 * legacy login-keychain ACL can instead request Keychain Services UI when a
 * development build has a new ad-hoc designated requirement.  Disable that
 * older UI boundary around the synchronous lookup as well, then restore the
 * process setting exactly.  Account remains the only interactive boundary. */
static OSStatus zb_kc_copy_matching_without_ui(CFDictionaryRef query, CFTypeRef *out) {
  Boolean allowed = false;
  OSStatus st = SecKeychainGetUserInteractionAllowed(&allowed);
  if (st != errSecSuccess) return st;
  if (allowed) {
    st = SecKeychainSetUserInteractionAllowed(false);
    if (st != errSecSuccess) return st;
  }
  st = SecItemCopyMatching(query, out);
  if (allowed) {
    OSStatus restore = SecKeychainSetUserInteractionAllowed(true);
    if (st == errSecSuccess && restore != errSecSuccess) {
      if (out != NULL && *out != NULL) {
        CFRelease(*out);
        *out = NULL;
      }
      st = restore;
    }
  }
  return st;
}

static int zb_ascii_space(unsigned char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
}

/* The long-lived value printed by `claude setup-token`: the same product rule as
 * agent_secrets_shape.zig, kept here because that Zig export is Linux-only. */
static int zb_setup_token_slice(const char *text, const char **out_start, size_t *out_len) {
  static const char prefix[] = "sk-ant-oat01-";
  if (text == NULL) return 0;
  const char *start = text;
  const char *end = text + strlen(text);
  while (start < end && zb_ascii_space((unsigned char)*start)) start++;
  while (end > start && zb_ascii_space((unsigned char)end[-1])) end--;
  size_t len = (size_t)(end - start);
  if (len < 35 || len > 512 || memcmp(start, prefix, sizeof prefix - 1) != 0) return 0;
  for (const char *p = start + sizeof prefix - 1; p < end; ++p) {
    unsigned char c = (unsigned char)*p;
    if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) {
      return 0;
    }
  }
  *out_start = start;
  *out_len = len;
  return 1;
}

/* The production onboarding boundary: refuse malformed values before SecItem sees
 * them, trim paste-only ASCII whitespace, and store only the validated token. */
int zb_agent_onboard_token(const char *keychain_path, const char *unlock_password,
                           const char *service, const char *account, const char *token, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  const char *start = NULL;
  size_t len = 0;
  if (!zb_setup_token_slice(token, &start, &len)) return 1;

  char *clean = malloc(len + 1);
  if (clean == NULL) {
    if (out_err != NULL) *out_err = strdup("keychain store failed: out of memory");
    return ZB_KC_UNAVAILABLE;
  }
  memcpy(clean, start, len);
  clean[len] = '\0';
  int result = zb_keychain_store(keychain_path, unlock_password, service, account, clean, out_err);
  memset_s(clean, len, 0, len);
  free(clean);
  return result;
}

int zb_keychain_store(const char *keychain_path, const char *unlock_password,
                      const char *service, const char *account, const char *token, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  @autoreleasepool {
    SecKeychainRef kc = NULL;
    OSStatus st = zb_kc_open(keychain_path, unlock_password, &kc);
    if (st != errSecSuccess) { if (out_err) *out_err = zb_kc_errf(st, "open"); return ZB_KC_UNAVAILABLE; }

    NSData *val = [NSData dataWithBytes:(token ?: "") length:(token ? strlen(token) : 0)];
    NSMutableDictionary *add = zb_kc_query(service, account);
    if (kc != NULL) add[(__bridge id)kSecUseKeychain] = (__bridge id)kc;
    add[(__bridge id)kSecValueData] = val;
    st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (st == errSecDuplicateItem) {
      // Overwrite: update just the value on the existing item (match keychain so we don't touch another's).
      NSMutableDictionary *match = zb_kc_query(service, account);
      if (kc != NULL) match[(__bridge id)kSecMatchSearchList] = @[(__bridge id)kc];
      st = SecItemUpdate((__bridge CFDictionaryRef)match,
                         (__bridge CFDictionaryRef)@{ (__bridge id)kSecValueData: val });
    }
    if (kc) CFRelease(kc);
    if (st != errSecSuccess) { if (out_err) *out_err = zb_kc_errf(st, "store"); return ZB_KC_UNAVAILABLE; }
    return ZB_KC_OK;
  }
}

static int zb_keychain_lookup_impl(const char *keychain_path, const char *unlock_password,
                                   const char *service, const char *account,
                                   int interactive, char **out_token, char **out_err) {
  if (out_token != NULL) *out_token = NULL;
  if (out_err != NULL) *out_err = NULL;
  @autoreleasepool {
    SecKeychainRef kc = NULL;
    OSStatus st = zb_kc_open(keychain_path, unlock_password, &kc);
    if (st != errSecSuccess) { if (out_err) *out_err = zb_kc_errf(st, "open"); return ZB_KC_UNAVAILABLE; }

    NSMutableDictionary *look = zb_kc_query(service, account);
    if (kc != NULL) look[(__bridge id)kSecMatchSearchList] = @[(__bridge id)kc];
    /* Drawer Send is never an authentication-UI boundary. The sole exception
     * is the explicit Allow action, which enters here with interactive=true. */
    look[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)(interactive
        ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail);
    look[(__bridge id)kSecReturnData] = @YES;
    look[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef out = NULL;
    st = interactive
        ? SecItemCopyMatching((__bridge CFDictionaryRef)look, &out)
        : zb_kc_copy_matching_without_ui((__bridge CFDictionaryRef)look, &out);
    if (kc) CFRelease(kc);
    if (st == errSecItemNotFound) return ZB_KC_ABSENT;
    /* Legacy item ACLs report either status when authentication UI is
     * disabled: login Keychains commonly use errSecInteractionNotAllowed,
     * while macOS 15 file Keychains use errSecAuthFailed. The keychain was
     * already opened and unlocked above, so errSecAuthFailed here is the
     * item's recoverable code-identity mismatch, not a bad keychain password. */
    if (st == errSecInteractionNotAllowed || st == errSecAuthFailed) {
      if (out_err) *out_err = zb_kc_errf(st, "lookup");
      return ZB_KC_PERMISSION;
    }
    if (st != errSecSuccess || out == NULL) { if (out_err) *out_err = zb_kc_errf(st, "lookup"); return ZB_KC_UNAVAILABLE; }

    NSData *data = (__bridge_transfer NSData *)out;
    if (out_token != NULL) {
      char *buf = malloc(data.length + 1);
      if (buf == NULL) { if (out_err) *out_err = strdup("keychain lookup: out of memory"); return ZB_KC_UNAVAILABLE; }
      memcpy(buf, data.bytes, data.length);
      buf[data.length] = '\0';
      *out_token = buf;
    }
    return ZB_KC_OK;
  }
}

int zb_keychain_lookup(const char *keychain_path, const char *unlock_password,
                       const char *service, const char *account, char **out_token, char **out_err) {
  return zb_keychain_lookup_impl(keychain_path, unlock_password, service, account,
                                 0, out_token, out_err);
}

int zb_keychain_lookup_interactive(const char *keychain_path, const char *unlock_password,
                                   const char *service, const char *account,
                                   char **out_token, char **out_err) {
  return zb_keychain_lookup_impl(keychain_path, unlock_password, service, account,
                                 1, out_token, out_err);
}

/* Metadata-only migration probe. It never asks SecItem for token bytes and
 * never enables authentication UI. A denied metadata query still proves the
 * named item exists and therefore requires the explicit Allow action. */
static int zb_keychain_item_present(const char *keychain_path, const char *unlock_password,
                                    const char *service, const char *account, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  @autoreleasepool {
    SecKeychainRef kc = NULL;
    OSStatus st = zb_kc_open(keychain_path, unlock_password, &kc);
    if (st != errSecSuccess) {
      if (out_err) *out_err = zb_kc_errf(st, "open");
      return ZB_KC_UNAVAILABLE;
    }
    NSMutableDictionary *query = zb_kc_query(service, account);
    if (kc != NULL) query[(__bridge id)kSecMatchSearchList] = @[(__bridge id)kc];
    query[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUIFail;
    query[(__bridge id)kSecReturnAttributes] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef attributes = NULL;
    st = zb_kc_copy_matching_without_ui((__bridge CFDictionaryRef)query, &attributes);
    if (kc) CFRelease(kc);
    if (attributes != NULL) CFRelease(attributes);
    if (st == errSecSuccess || st == errSecInteractionNotAllowed || st == errSecAuthFailed)
      return ZB_KC_OK;
    if (st == errSecItemNotFound) return ZB_KC_ABSENT;
    if (out_err) *out_err = zb_kc_errf(st, "lookup");
    return ZB_KC_UNAVAILABLE;
  }
}

int zb_mac_agent_token_load(const char *agent_home,
                            const char *keychain_path, const char *unlock_password,
                            const char *service, const char *account,
                            char **out_token, char **out_err) {
  if (!zb_mac_agent_token_file_enabled())
    return zb_keychain_lookup(keychain_path, unlock_password, service, account,
                              out_token, out_err);
  int result = zb_token_file_load(agent_home, out_token, out_err);
  if (result != ZB_KC_ABSENT) return result;
  char *presence_error = NULL;
  result = zb_keychain_item_present(keychain_path, unlock_password, service, account,
                                    &presence_error);
  if (result == ZB_KC_OK) {
    free(presence_error);
    return ZB_KC_PERMISSION;
  }
  if (out_err != NULL) *out_err = presence_error;
  else free(presence_error);
  return result;
}

int zb_mac_agent_token_save(const char *agent_home,
                            const char *keychain_path, const char *unlock_password,
                            const char *service, const char *account,
                            const char *token, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  if (!zb_mac_agent_token_file_enabled())
    return zb_agent_onboard_token(keychain_path, unlock_password, service, account,
                                  token, out_err);
  const char *start = NULL;
  size_t length = 0;
  if (!zb_setup_token_slice(token, &start, &length)) return ZB_KC_ABSENT;
  char *clean = malloc(length + 1);
  if (clean == NULL) {
    zb_token_error(out_err, "token file could not be saved");
    return ZB_KC_UNAVAILABLE;
  }
  memcpy(clean, start, length);
  clean[length] = '\0';
  int result = zb_token_file_store(agent_home, clean, length, out_err);
  memset_s(clean, length, 0, length);
  free(clean);
  return result;
}

int zb_mac_agent_token_allow(const char *agent_home,
                             const char *keychain_path, const char *unlock_password,
                             const char *service, const char *account, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  char *token = NULL;
  char *lookup_error = NULL;
  int result = zb_keychain_lookup_interactive(keychain_path, unlock_password, service, account,
                                               &token, &lookup_error);
  if (result != ZB_KC_OK || !zb_mac_agent_token_file_enabled()) {
    zb_keychain_free(token);
    if (out_err != NULL) *out_err = lookup_error;
    else free(lookup_error);
    return result;
  }
  free(lookup_error);
  const char *start = NULL;
  size_t length = 0;
  if (token == NULL || !zb_setup_token_slice(token, &start, &length) || start != token) {
    zb_keychain_free(token);
    return ZB_KC_UNAVAILABLE;
  }
  result = zb_token_file_store(agent_home, token, length, out_err);
  if (result == ZB_KC_OK) {
    char *clear_error = NULL;
    int cleared = zb_keychain_clear(keychain_path, unlock_password, service, account, &clear_error);
    if (cleared != ZB_KC_OK) {
      char *remove_error = NULL;
      (void)zb_token_file_remove(agent_home, &remove_error);
      free(remove_error);
      if (out_err != NULL && *out_err == NULL) *out_err = clear_error;
      else free(clear_error);
      result = cleared;
    } else {
      free(clear_error);
    }
  }
  zb_keychain_free(token);
  return result;
}

int zb_mac_agent_token_remove(const char *agent_home,
                              const char *keychain_path, const char *unlock_password,
                              const char *service, const char *account, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  if (zb_mac_agent_token_file_enabled()) return zb_token_file_remove(agent_home, out_err);
  return zb_keychain_clear(keychain_path, unlock_password, service, account, out_err);
}

int zb_keychain_clear(const char *keychain_path, const char *unlock_password,
                      const char *service, const char *account, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  @autoreleasepool {
    SecKeychainRef kc = NULL;
    OSStatus st = zb_kc_open(keychain_path, unlock_password, &kc);
    if (st != errSecSuccess) { if (out_err) *out_err = zb_kc_errf(st, "open"); return ZB_KC_UNAVAILABLE; }

    NSMutableDictionary *del = zb_kc_query(service, account);
    if (kc != NULL) del[(__bridge id)kSecMatchSearchList] = @[(__bridge id)kc];
    st = SecItemDelete((__bridge CFDictionaryRef)del);
    if (kc) CFRelease(kc);
    if (st != errSecSuccess && st != errSecItemNotFound) { if (out_err) *out_err = zb_kc_errf(st, "clear"); return ZB_KC_UNAVAILABLE; }
    return ZB_KC_OK;
  }
}

void zb_keychain_free(char *token) {
  if (token == NULL) return;
  size_t n = strlen(token);
  if (n > 0) memset_s(token, n, 0, n);  // wipe before free so the token doesn't linger in freed memory
  free(token);
}

#pragma clang diagnostic pop
