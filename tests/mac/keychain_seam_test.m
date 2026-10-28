/* MS5.2 — the macOS Keychain token seam (agent_secrets_mac.m), driven headless against DISPOSABLE temp
 * keychains (the login keychain refuses SecItem over ssh with errSecInteractionNotAllowed -25308).
 * Compiled with agent_secrets_mac.m by tests/mac/ms5_gate.sh. Canary tokens only, never a real credential.
 *
 * Proves (RoseCat 38a9f37):
 *  - absent-before-store; store+lookup roundtrip; overwrite replaces only the target value;
 *  - COMPOSITE IDENTITY: changing only account, or only service, is a different item (#2);
 *  - ISOLATION: overwrite/clear touch ONLY the target item — same-service and diff-service neighbors in
 *    the target keychain survive, and a COLLIDING (service,account) item in a SECOND keychain survives (#2);
 *  - ACL DENIAL: a saved item trusted to another identity fails closed as PERMISSION without authentication UI;
 *  - DEFAULT PINNING: a production NULL op pins to the login keychain, NOT the search list — a disposable
 *    keychain (which SecKeychainCreate adds to the search list) must NOT satisfy a NULL lookup (#1). */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "agent_secrets_mac.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static int failures = 0;
static void fail(const char *msg) { fprintf(stderr, "  %s\n", msg); failures++; }

static SecKeychainRef mk(const char *path, const char *pw) {
  SecKeychainRef kc = NULL;
  if (SecKeychainCreate(path, (UInt32)strlen(pw), pw, false, NULL, &kc) != errSecSuccess || kc == NULL) return NULL;
  SecKeychainUnlock(kc, (UInt32)strlen(pw), pw, true);
  return kc;
}

/* Seed a generic password directly into keychain kc (test setup, not through the ABI). */
static int seed(SecKeychainRef kc, const char *svc, const char *acct, const char *val) {
  NSDictionary *d = @{ (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                       (__bridge id)kSecAttrService:@(svc), (__bridge id)kSecAttrAccount:@(acct),
                       (__bridge id)kSecValueData:[NSData dataWithBytes:val length:strlen(val)],
                       (__bridge id)kSecUseKeychain:(__bridge id)kc };
  return SecItemAdd((__bridge CFDictionaryRef)d, NULL) == errSecSuccess;
}

/* Seed an item whose ACL trusts another identity, never this test process. */
static int seed_foreign(SecKeychainRef kc, const char *svc, const char *acct, const char *val) {
  SecTrustedApplicationRef trusted = NULL;
  SecAccessRef access = NULL;
  SecKeychainItemRef item = NULL;
  OSStatus st = SecTrustedApplicationCreateFromPath("/bin/echo", &trusted);
  CFArrayRef trusted_apps = NULL;
  if (st == errSecSuccess) {
    const void *values[] = {trusted};
    trusted_apps = CFArrayCreate(NULL, values, 1, &kCFTypeArrayCallBacks);
    if (trusted_apps == NULL) st = errSecAllocate;
  }
  if (st == errSecSuccess)
    st = SecAccessCreate(CFSTR("zigBrowser foreign identity test"), trusted_apps, &access);
  SecKeychainAttribute attributes[] = {
    {kSecServiceItemAttr, (UInt32)strlen(svc), (void *)svc},
    {kSecAccountItemAttr, (UInt32)strlen(acct), (void *)acct},
  };
  SecKeychainAttributeList attribute_list = {2, attributes};
  if (st == errSecSuccess)
    st = SecKeychainItemCreateFromContent(kSecGenericPasswordItemClass, &attribute_list,
                                           (UInt32)strlen(val), val, kc, access, &item);
  if (item != NULL) CFRelease(item);
  if (access != NULL) CFRelease(access);
  if (trusted_apps != NULL) CFRelease(trusted_apps);
  if (trusted != NULL) CFRelease(trusted);
  return st == errSecSuccess;
}

/* Read a generic password directly from keychain kc; malloc'd NUL-terminated string, or NULL if absent. */
static char *peek(SecKeychainRef kc, const char *svc, const char *acct) {
  NSDictionary *q = @{ (__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,
                       (__bridge id)kSecAttrService:@(svc), (__bridge id)kSecAttrAccount:@(acct),
                       (__bridge id)kSecReturnData:@YES, (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitOne,
                       (__bridge id)kSecMatchSearchList:@[(__bridge id)kc] };
  CFTypeRef o = NULL;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &o) != errSecSuccess || o == NULL) return NULL;
  NSData *data = (__bridge_transfer NSData *)o;
  char *b = malloc(data.length + 1); memcpy(b, data.bytes, data.length); b[data.length] = '\0';
  return b;
}
static void expect_peek(SecKeychainRef kc, const char *svc, const char *acct, const char *want, const char *msg) {
  char *g = peek(kc, svc, acct);
  if (g == NULL || strcmp(g, want) != 0) fail(msg);
  free(g);
}

int main(void) {
  @autoreleasepool {
    int pid = getpid();
    char tpath[256], opath[256];
    snprintf(tpath, sizeof tpath, "/tmp/zb-ms5-kcT-%d.keychain", pid);
    snprintf(opath, sizeof opath, "/tmp/zb-ms5-kcO-%d.keychain", pid);
    const char *pw = "zb-temp-pw";
    const char *SVC = "dev.zigbrowser.ClaudeAgentToken.test";
    const char *SVC2 = "dev.zigbrowser.OtherService.test";
    const char *LOCKED_SVC = "dev.zigbrowser.ForeignIdentityToken.test";
    const char *ACCT = "default", *ACCT2 = "second-account";
    const char *canary = "zb-canary-TOKEN-7f3a", *canary2 = "zb-canary-TOKEN-second-c91e";

    SecKeychainRef T = mk(tpath, pw), O = mk(opath, pw);
    if (T == NULL || O == NULL) { fprintf(stderr, "FAIL\tms5-keychain-seam\n  create disposable keychains failed\n"); return 1; }

    // Neighbors that must SURVIVE all target ops: in T a same-service/diff-account and a diff-service/same-account
    // item; in a SECOND keychain O a COLLIDING (SVC,ACCT) item (proves target ops pin to T, not a search list).
    if (!seed(T, SVC, ACCT2, "neighbor-acct")) fail("setup: seed same-service/diff-account");
    if (!seed(T, SVC2, ACCT, "neighbor-svc")) fail("setup: seed diff-service/same-account");
    if (!seed(O, SVC, ACCT, "other-keychain")) fail("setup: seed colliding item in the other keychain");

    char *err = NULL, *tok = NULL;

    // absent before store.
    if (zb_keychain_lookup(tpath, pw, SVC, ACCT, &tok, &err) != ZB_KC_ABSENT) fail("lookup before store not ABSENT");
    if (tok) { zb_keychain_free(tok); tok = NULL; }
    free(err); err = NULL;

    // store + roundtrip.
    if (zb_keychain_store(tpath, pw, SVC, ACCT, canary, &err) != ZB_KC_OK) fail(err ? err : "store failed");
    free(err); err = NULL;
    if (zb_keychain_lookup(tpath, pw, SVC, ACCT, &tok, &err) != ZB_KC_OK || tok == NULL || strcmp(tok, canary) != 0)
      fail("store+lookup did not roundtrip the canary");
    zb_keychain_free(tok); tok = NULL; free(err); err = NULL;

    // composite identity: only-account and only-service differ -> distinct items.
    if (zb_keychain_lookup(tpath, pw, SVC, ACCT2, &tok, &err) != ZB_KC_OK || tok == NULL || strcmp(tok, "neighbor-acct") != 0)
      fail("same service / different account is not a distinct item");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    if (zb_keychain_lookup(tpath, pw, SVC2, ACCT, &tok, &err) != ZB_KC_OK || tok == NULL || strcmp(tok, "neighbor-svc") != 0)
      fail("different service / same account is not a distinct item");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;

    // overwrite replaces ONLY the target value; neighbors + other keychain untouched.
    if (zb_keychain_store(tpath, pw, SVC, ACCT, canary2, &err) != ZB_KC_OK) fail(err ? err : "overwrite store failed");
    free(err); err = NULL;
    if (zb_keychain_lookup(tpath, pw, SVC, ACCT, &tok, &err) != ZB_KC_OK || tok == NULL || strcmp(tok, canary2) != 0)
      fail("overwrite did not replace the value with the second canary");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    expect_peek(T, SVC, ACCT2, "neighbor-acct", "overwrite disturbed the same-service neighbor");
    expect_peek(T, SVC2, ACCT, "neighbor-svc", "overwrite disturbed the diff-service neighbor");
    expect_peek(O, SVC, ACCT, "other-keychain", "overwrite leaked into the other keychain");

    // clear deletes ONLY the target item; neighbors + other keychain survive (catches a broadened delete).
    if (zb_keychain_clear(tpath, pw, SVC, ACCT, &err) != ZB_KC_OK) fail(err ? err : "clear failed");
    free(err); err = NULL;
    if (zb_keychain_lookup(tpath, pw, SVC, ACCT, &tok, &err) != ZB_KC_ABSENT) fail("lookup after clear not ABSENT");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    expect_peek(T, SVC, ACCT2, "neighbor-acct", "clear removed the same-service neighbor");
    expect_peek(T, SVC2, ACCT, "neighbor-svc", "clear removed the diff-service neighbor");
    expect_peek(O, SVC, ACCT, "other-keychain", "clear reached into the other keychain");

    // A noninteractive drawer lookup of an item trusted to another code identity must expose the recoverable
    // permission state. It must not collapse the saved item into generic unavailability or show authentication UI.
    if (!seed_foreign(T, LOCKED_SVC, ACCT, "foreign-identity-canary")) {
      fail("setup: could not seed foreign-identity ACL item");
    } else {
      int r = zb_keychain_lookup(tpath, pw, LOCKED_SVC, ACCT, &tok, &err);
      if (r != ZB_KC_PERMISSION) {
        char detail[256];
        snprintf(detail, sizeof detail, "foreign-identity ACL returned %d (%s), want ZB_KC_PERMISSION",
                 r, err != NULL ? err : "no error");
        fail(detail);
      }
      if (tok != NULL) fail("foreign-identity ACL returned token bytes");
      if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    }

    // #1 DEFAULT PINNING: a production NULL op must pin to the login keychain, not the default SEARCH LIST.
    // Bait: keychain O still holds a colliding (SVC,ACCT)="other-keychain". Add O to the GLOBAL search list
    // but it is NOT the default keychain, so a buggy NULL op (no pin -> searches the list) finds O's item,
    // while a correctly default-pinned NULL op does not. The search list is saved and restored IMMEDIATELY
    // (linear, no early return between mutate and restore; the login keychain holds no such item).
    CFArrayRef origList = NULL;
    OSStatus ls = SecKeychainCopySearchList(&origList);
    if (ls != errSecSuccess || origList == NULL) {
      fail("setup: could not read the keychain search list for the NULL-pinning check");
    } else {
      NSMutableArray *withO = [NSMutableArray arrayWithArray:(__bridge NSArray *)origList];
      [withO addObject:(__bridge id)O];
      // Assert the bait was actually made searchable BEFORE running the discriminator: if the install
      // silently failed, the old buggy impl would pass (the bait was never searchable) — a false green.
      OSStatus si = SecKeychainSetSearchList((__bridge CFArrayRef)withO);
      if (si != errSecSuccess) {
        fail("setup: could not install the bait keychain into the search list — the NULL-pinning discriminator would be invalid");
      } else {
        int r = zb_keychain_lookup(NULL, NULL, SVC, ACCT, &tok, &err);
        OSStatus sr = SecKeychainSetSearchList(origList);  // restore the user's search list at once
        if (r == ZB_KC_OK && tok != NULL && strcmp(tok, "other-keychain") == 0)
          fail("NULL (login-keychain) lookup returned an item from a non-default search-list keychain — NULL is not pinned to the default keychain");
        if (sr != errSecSuccess)
          fail("could not restore the keychain search list after the NULL-pinning check — global Keychain state left changed");
        if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
      }
      CFRelease(origList);
    }

    SecKeychainDelete(T); SecKeychainDelete(O);  // also removes them from the search list
    if (T) CFRelease(T); if (O) CFRelease(O);
    unlink(tpath); unlink(opath);

    if (failures) { fprintf(stderr, "FAIL\tms5-keychain-seam\n"); return 1; }
    printf("PASS\tms5-keychain-seam\n");
    return 0;
  }
}

#pragma clang diagnostic pop
