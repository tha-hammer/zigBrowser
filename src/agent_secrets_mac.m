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
 * CFReleases it), or an OSStatus on failure. A NULL path means the default keychain: *out_kc stays NULL and
 * SecItem uses the default search list. */
static OSStatus zb_kc_open(const char *keychain_path, const char *unlock_password, SecKeychainRef *out_kc) {
  *out_kc = NULL;
  if (keychain_path == NULL) return errSecSuccess;  // default keychain
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
