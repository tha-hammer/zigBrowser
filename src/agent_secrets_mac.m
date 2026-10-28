/* macOS Keychain backend of the Claude Agent's token store (MS5.2); see agent_secrets_mac.h.
 *
 * Generic-password items via SecItem over a legacy file keychain. SecKeychain* is deprecated since 10.10 but
 * functional on macOS 15 and is the only headless-testable path (the data-protection keychain needs code
 * signing + a keychain-access-group entitlement, which is MS9); the deprecation is silenced locally. */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "agent_secrets_mac.h"
#include <string.h>
#include <stdlib.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"  // SecKeychain* (legacy file keychain), see header

static char *zb_kc_errf(OSStatus st, const char *what) {
  char buf[128];
  snprintf(buf, sizeof buf, "keychain %s failed: OSStatus %d", what, (int)st);
  return strdup(buf);
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

int zb_keychain_lookup(const char *keychain_path, const char *unlock_password,
                       const char *service, const char *account, char **out_token, char **out_err) {
  if (out_token != NULL) *out_token = NULL;
  if (out_err != NULL) *out_err = NULL;
  @autoreleasepool {
    SecKeychainRef kc = NULL;
    OSStatus st = zb_kc_open(keychain_path, unlock_password, &kc);
    if (st != errSecSuccess) { if (out_err) *out_err = zb_kc_errf(st, "open"); return ZB_KC_UNAVAILABLE; }

    NSMutableDictionary *look = zb_kc_query(service, account);
    if (kc != NULL) look[(__bridge id)kSecMatchSearchList] = @[(__bridge id)kc];
    /* Drawer Send is never an authentication-UI boundary.  In particular, an
     * ad-hoc development build must not put a password prompt on the owner's
     * screen when its cdhash is not on an existing item's ACL.  Account owns
     * the interactive credential flow; a background lookup fails closed. */
    look[(__bridge id)kSecUseAuthenticationUI] = (__bridge id)kSecUseAuthenticationUIFail;
    look[(__bridge id)kSecReturnData] = @YES;
    look[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef out = NULL;
    st = SecItemCopyMatching((__bridge CFDictionaryRef)look, &out);
    if (kc) CFRelease(kc);
    if (st == errSecItemNotFound) return ZB_KC_ABSENT;
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
