/* MS5.2 — the macOS Keychain token seam (agent_secrets_mac.m), driven headless against a DISPOSABLE
 * temp keychain (the login keychain refuses SecItem over ssh with errSecInteractionNotAllowed -25308).
 * Compiled with agent_secrets_mac.m by tests/mac/ms5_gate.sh. Uses a canary token, never a real credential.
 *
 * Asserts: absent-before-store; store+lookup roundtrip; overwrite replaces the value; clear makes it absent;
 * and that a wrong (service, account) does not see the token. */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "agent_secrets_mac.h"
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static int failures = 0;
static void fail(const char *msg) { fprintf(stderr, "  %s\n", msg); failures++; }

int main(void) {
  @autoreleasepool {
    char path[256]; snprintf(path, sizeof path, "/tmp/zb-ms5-kc-%d.keychain", getpid());
    const char *pw = "zb-temp-pw";
    const char *svc = "dev.zigbrowser.ClaudeAgentToken.test";
    const char *acct = "default";
    const char *canary = "zb-canary-TOKEN-7f3a";
    const char *canary2 = "zb-canary-TOKEN-second-c91e";

    // The test owns the disposable keychain: create + unlock it, so the seam needs no GUI (headless).
    SecKeychainRef kc = NULL;
    OSStatus sc = SecKeychainCreate(path, (UInt32)strlen(pw), pw, false, NULL, &kc);
    if (sc != errSecSuccess) { fprintf(stderr, "FAIL\tms5-keychain-seam\n  SecKeychainCreate failed: %d\n", (int)sc); return 1; }
    SecKeychainUnlock(kc, (UInt32)strlen(pw), pw, true);
    if (kc) CFRelease(kc);

    char *err = NULL, *tok = NULL;

    // 1) absent before any store.
    if (zb_keychain_lookup(path, pw, svc, acct, &tok, &err) != ZB_KC_ABSENT)
      fail("lookup before store was not ABSENT");
    if (tok) { fail("lookup before store returned a token"); zb_keychain_free(tok); tok = NULL; }

    // 2) store + roundtrip.
    if (zb_keychain_store(path, pw, svc, acct, canary, &err) != ZB_KC_OK)
      fail(err ? err : "store failed");
    free(err); err = NULL;
    if (zb_keychain_lookup(path, pw, svc, acct, &tok, &err) != ZB_KC_OK || tok == NULL || strcmp(tok, canary) != 0)
      fail("store+lookup did not roundtrip the canary");
    zb_keychain_free(tok); tok = NULL;

    // 3) a different (service, account) must NOT see it.
    if (zb_keychain_lookup(path, pw, "dev.zigbrowser.OtherService", acct, &tok, &err) != ZB_KC_ABSENT)
      fail("a different service saw the token");
    if (tok) { zb_keychain_free(tok); tok = NULL; }

    // 4) overwrite replaces the value (not a second item).
    if (zb_keychain_store(path, pw, svc, acct, canary2, &err) != ZB_KC_OK)
      fail(err ? err : "overwrite store failed");
    free(err); err = NULL;
    if (zb_keychain_lookup(path, pw, svc, acct, &tok, &err) != ZB_KC_OK || tok == NULL || strcmp(tok, canary2) != 0)
      fail("overwrite did not replace the value with the second canary");
    zb_keychain_free(tok); tok = NULL;

    // 5) clear makes it absent.
    if (zb_keychain_clear(path, pw, svc, acct, &err) != ZB_KC_OK)
      fail(err ? err : "clear failed");
    free(err); err = NULL;
    if (zb_keychain_lookup(path, pw, svc, acct, &tok, &err) != ZB_KC_ABSENT)
      fail("lookup after clear was not ABSENT");
    if (tok) { fail("lookup after clear returned a token"); zb_keychain_free(tok); tok = NULL; }

    // cleanup the disposable keychain.
    SecKeychainRef del = NULL;
    if (SecKeychainOpen(path, &del) == errSecSuccess && del) { SecKeychainDelete(del); CFRelease(del); }
    unlink(path);

    if (failures) { fprintf(stderr, "FAIL\tms5-keychain-seam\n"); return 1; }
    printf("PASS\tms5-keychain-seam\n");
    return 0;
  }
}

#pragma clang diagnostic pop
