/* MS5.2 — RED-FIRST, DRIVEN: the macOS Keychain ONBOARDING seam (validate a Claude setup-token, then store it
 * through the reviewed Keychain backend). The macOS analog of the Linux validate+store that `configureAgentSecrets`
 * does on libsecret — which today is a no-op on macOS (src/app.zig:396 `if (comptime os != .linux) return;`), so
 * no macOS path validates+stores a token at all. This closes that: the ONLY way a token reaches the Keychain is a
 * valid setup-token.
 *
 * Driven per RoseCat R1-R4: every row calls the real `zb_agent_onboard_token` and reads the result back through the
 * Keychain (store/lookup), never a source-text check. Headless over ssh against DISPOSABLE temp keychains only (the
 * login keychain refuses SecItem with errSecInteractionNotAllowed -25308 — the MS5 Keychain-headless finding).
 * Canary tokens only, never a real credential.
 *
 * Contract under test (to mirror src/agent_secrets_shape.zig:18-35 — ^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$, total
 * 35..512 chars):
 *   zb_agent_onboard_token(keychain_path, unlock_pw, service, account, token, out_err)
 *     -> 0  the token is a valid setup-token: stored for (service, account); lookup roundtrips it
 *     -> 1  the token is NOT a valid setup-token: REFUSED, and NOTHING is stored (lookup stays ABSENT)
 *     -> 2  the keychain was unavailable (backend error)
 *
 * RED now: `zb_agent_onboard_token` is absent (link error). Build (on each Mac, both arches) exactly like the
 * keychain seam case: `xcrun clang -fobjc-arc -Wno-deprecated-declarations -I src -framework Security
 * -framework Foundation tests/mac/keychain_onboard_test.m src/agent_secrets_mac.m <onboard impl> -o kc_onboard`.
 * UNREGISTERED (its own file; registered in build.zig only at the green). */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "agent_secrets_mac.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

/* The seam under test — declared here so the red needs no new shared header until the green. */
extern int zb_agent_onboard_token(const char *keychain_path, const char *unlock_password,
                                  const char *service, const char *account, const char *token, char **out_err);

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

/* The committed NO-VALIDATION mutant: an onboarding that stores whatever it is handed, skipping the shape check.
 * It proves the invalid rows below actually exercise validation — a bad token fed to THIS lands in the keychain. */
static int mutant_onboard_no_validation(const char *path, const char *pw, const char *svc, const char *acct,
                                        const char *token, char **out_err) {
  return zb_keychain_store(path, pw, svc, acct, token, out_err);  // no shape gate -> stores anything
}

/* Assert onboarding REFUSES `token` (bad shape) and stores NOTHING for a fresh (svc, acct). */
static void expect_refused_and_absent(const char *path, const char *pw, const char *svc, const char *acct,
                                      const char *token, const char *what) {
  char *err = NULL, *tok = NULL;
  int r = zb_agent_onboard_token(path, pw, svc, acct, token, &err);
  if (r != 1) fail(what);  // must report bad-shape refusal, not OK and not unavailable
  free(err); err = NULL;
  int look = zb_keychain_lookup(path, pw, svc, acct, &tok, &err);
  if (look != ZB_KC_ABSENT) fail(what);  // and absolutely nothing may have been stored
  if (tok) { zb_keychain_free(tok); tok = NULL; }
  free(err);
}

int main(void) {
  @autoreleasepool {
    int pid = getpid();
    char tpath[256];
    snprintf(tpath, sizeof tpath, "/tmp/zb-ms5-onboardT-%d.keychain", pid);
    const char *pw = "zb-temp-pw";
    const char *SVC = "dev.zigbrowser.ClaudeAgentToken.test";
    const char *ACCT = "default";
    /* A FAKE setup-token: matches ^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$ (body = 23 chars) but is a canary. */
    const char *VALID = "sk-ant-oat01-ZBCANARYtoken0000000000";

    SecKeychainRef T = mk(tpath, pw);
    if (T == NULL) { fprintf(stderr, "FAIL\tms5-keychain-onboard\n  create disposable keychain failed\n"); return 1; }

    char *err = NULL, *tok = NULL;

    // absent before onboarding.
    if (zb_keychain_lookup(tpath, pw, SVC, ACCT, &tok, &err) != ZB_KC_ABSENT) fail("lookup before onboard not ABSENT");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;

    // (1) a VALID setup-token is validated and stored; lookup roundtrips the exact token.
    if (zb_agent_onboard_token(tpath, pw, SVC, ACCT, VALID, &err) != 0) fail(err ? err : "valid token not onboarded");
    free(err); err = NULL;
    if (zb_keychain_lookup(tpath, pw, SVC, ACCT, &tok, &err) != ZB_KC_OK || tok == NULL || strcmp(tok, VALID) != 0)
      fail("onboarded token did not roundtrip through the keychain");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;

    // (2) every NOT-a-setup-token is REFUSED and stores NOTHING (each into a fresh account, starting absent).
    expect_refused_and_absent(tpath, pw, SVC, "inv-empty", "", "empty token was not refused / was stored");
    expect_refused_and_absent(tpath, pw, SVC, "inv-apikey", "sk-ant-api03-0123456789abcdef0123456789",
                              "an API key (wrong prefix) was not refused / was stored");
    expect_refused_and_absent(tpath, pw, SVC, "inv-short", "sk-ant-oat01-short",
                              "a too-short body was not refused / was stored");
    expect_refused_and_absent(tpath, pw, SVC, "inv-space", "sk-ant-oat01-ZBCANARY token 0000000000",
                              "inner whitespace was not refused / was stored");

    // (3) committed NO-VALIDATION mutant: fed a bad token it DOES store (so the invalid rows above are real).
    const char *BAD = "sk-ant-api03-not-a-setup-token";
    if (mutant_onboard_no_validation(tpath, pw, SVC, "mutant-acct", BAD, &err) != ZB_KC_OK)
      fail(err ? err : "the no-validation mutant could not even store (test setup broken)");
    free(err); err = NULL;
    if (zb_keychain_lookup(tpath, pw, SVC, "mutant-acct", &tok, &err) != ZB_KC_OK || tok == NULL || strcmp(tok, BAD) != 0)
      fail("the no-validation mutant did NOT store the bad token — it fails to model a dropped shape check");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;

    SecKeychainDelete(T);
    if (T) CFRelease(T);
    unlink(tpath);

    if (failures) { fprintf(stderr, "FAIL\tms5-keychain-onboard\n"); return 1; }
    printf("PASS\tms5-keychain-onboard\n");
    return 0;
  }
}

#pragma clang diagnostic pop
