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
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static int failures = 0;
static void fail(const char *msg) { fprintf(stderr, "  %s\n", msg); failures++; }

static int dev_token_file_enabled = 0;
int zb_mac_unsandboxed_dev(void) { return dev_token_file_enabled; }

int zb_mac_agent_token_load(const char *agent_home,
                            const char *keychain_path, const char *unlock_password,
                            const char *service, const char *account,
                            char **out_token, char **out_err);
int zb_mac_agent_token_save(const char *agent_home,
                            const char *keychain_path, const char *unlock_password,
                            const char *service, const char *account,
                            const char *token, char **out_err);
int zb_mac_agent_token_allow(const char *agent_home,
                             const char *keychain_path, const char *unlock_password,
                             const char *service, const char *account, char **out_err);
int zb_mac_agent_token_remove(const char *agent_home,
                              const char *keychain_path, const char *unlock_password,
                              const char *service, const char *account, char **out_err);

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

static int exact_error(const char *error) {
  return error != NULL && strcmp(error, "token file has unsafe permissions") == 0;
}

static int no_temp_entries(const char *path, const char *allowed) {
  DIR *dir = opendir(path);
  if (dir == NULL) return 0;
  int clean = 1;
  struct dirent *entry;
  while ((entry = readdir(dir)) != NULL) {
    if (strcmp(entry->d_name, ".") != 0 && strcmp(entry->d_name, "..") != 0 &&
        strcmp(entry->d_name, allowed) != 0) clean = 0;
  }
  closedir(dir);
  return clean;
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
    const char *MIGRATE_SVC = "dev.zigbrowser.MigrateToken.test";
    const char *FILE_SVC = "dev.zigbrowser.FileToken.test";
    const char *ACCT = "default", *ACCT2 = "second-account";
    const char *canary = "zb-canary-TOKEN-7f3a", *canary2 = "zb-canary-TOKEN-second-c91e";
    const char *VALID = "sk-ant-oat01-FILETOKEN0123456789abcdefghijklmnop";

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

    // Development builds use one owner-only file and never depend on an ad-hoc code signature.
    char home[256], secrets[320], token_path[384], canary_path[384];
    snprintf(home, sizeof home, "/tmp/zb-ms5-dev-home-%d", pid);
    snprintf(secrets, sizeof secrets, "%s/secrets", home);
    snprintf(token_path, sizeof token_path, "%s/claude_token", secrets);
    snprintf(canary_path, sizeof canary_path, "%s/not-the-token", home);
    if (mkdir(home, 0700) != 0) fail("setup: create private development agent home");
    dev_token_file_enabled = 1;

    int result = zb_mac_agent_token_save(home, tpath, pw, FILE_SVC, ACCT, VALID, &err);
    if (result != ZB_KC_OK) fail(err ? err : "development token file save failed");
    free(err); err = NULL;
    struct stat secrets_info, token_info;
    if (lstat(secrets, &secrets_info) != 0 || !S_ISDIR(secrets_info.st_mode) ||
        (secrets_info.st_mode & 0777) != 0700 || secrets_info.st_uid != geteuid())
      fail("development secrets directory is not owned mode 0700");
    if (lstat(token_path, &token_info) != 0 || !S_ISREG(token_info.st_mode) ||
        (token_info.st_mode & 0777) != 0600 || token_info.st_uid != geteuid())
      fail("development token file is not owned mode 0600");
    if (!no_temp_entries(secrets, "claude_token")) fail("atomic save left a temporary file behind");
    result = zb_mac_agent_token_load(home, tpath, pw, FILE_SVC, ACCT, &tok, &err);
    if (result != ZB_KC_OK || tok == NULL || strcmp(tok, VALID) != 0)
      fail("development token did not survive file reload");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;

    result = zb_mac_agent_token_remove(home, tpath, pw, FILE_SVC, ACCT, &err);
    if (result != ZB_KC_OK || lstat(token_path, &token_info) == 0 || errno != ENOENT)
      fail("development sign-out did not delete the token file");
    free(err); err = NULL;

    // A v7-style Keychain item is detected without reading its value. Allow performs the one migration read,
    // persists the file, and removes the old item so later launches never touch Keychain.
    if (zb_keychain_store(tpath, pw, MIGRATE_SVC, ACCT, VALID, &err) != ZB_KC_OK)
      fail(err ? err : "setup: store migration Keychain item");
    free(err); err = NULL;
    result = zb_mac_agent_token_load(home, tpath, pw, MIGRATE_SVC, ACCT, &tok, &err);
    if (result != ZB_KC_PERMISSION || tok != NULL) fail("migration candidate did not require explicit Allow");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    result = zb_mac_agent_token_allow(home, tpath, pw, MIGRATE_SVC, ACCT, &err);
    if (result != ZB_KC_OK) fail(err ? err : "explicit Allow did not migrate the token");
    free(err); err = NULL;
    result = zb_keychain_lookup(tpath, pw, MIGRATE_SVC, ACCT, &tok, &err);
    if (result != ZB_KC_ABSENT || tok != NULL) fail("migration left the old Keychain item behind");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    result = zb_mac_agent_token_load(home, tpath, pw, MIGRATE_SVC, ACCT, &tok, &err);
    if (result != ZB_KC_OK || tok == NULL || strcmp(tok, VALID) != 0)
      fail("migrated token did not load from the private file");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    (void)zb_mac_agent_token_remove(home, tpath, pw, MIGRATE_SVC, ACCT, &err);
    free(err); err = NULL;

    // Unsafe file metadata is rejected before open; neither a wide file nor a symlink may be consumed.
    int unsafe = open(token_path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (unsafe < 0 || write(unsafe, VALID, strlen(VALID)) != (ssize_t)strlen(VALID))
      fail("setup: create wide token file");
    if (unsafe >= 0) close(unsafe);
    result = zb_mac_agent_token_load(home, tpath, pw, FILE_SVC, ACCT, &tok, &err);
    if (result != ZB_KC_UNAVAILABLE || tok != NULL || !exact_error(err))
      fail("wide token file was not refused with the safe error");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    unlink(token_path);

    int canary_fd = open(canary_path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (canary_fd < 0 || write(canary_fd, VALID, strlen(VALID)) != (ssize_t)strlen(VALID))
      fail("setup: create symlink canary");
    if (canary_fd >= 0) close(canary_fd);
    if (symlink("../not-the-token", token_path) != 0) fail("setup: create token symlink");
    result = zb_mac_agent_token_load(home, tpath, pw, FILE_SVC, ACCT, &tok, &err);
    if (result != ZB_KC_UNAVAILABLE || tok != NULL || !exact_error(err))
      fail("token symlink was not refused with the safe error");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    unlink(token_path);
    unlink(canary_path);

    if (chmod(secrets, 0755) != 0) fail("setup: widen secrets directory");
    result = zb_mac_agent_token_load(home, tpath, pw, FILE_SVC, ACCT, &tok, &err);
    if (result != ZB_KC_UNAVAILABLE || tok != NULL || !exact_error(err))
      fail("wide secrets directory was not refused with the safe error");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    chmod(secrets, 0700);

    // A release build remains exactly Keychain-backed and creates no token file.
    dev_token_file_enabled = 0;
    result = zb_mac_agent_token_save(home, tpath, pw, FILE_SVC, ACCT, VALID, &err);
    if (result != ZB_KC_OK || lstat(token_path, &token_info) == 0)
      fail("release token save did not remain Keychain-only");
    free(err); err = NULL;
    result = zb_mac_agent_token_load(home, tpath, pw, FILE_SVC, ACCT, &tok, &err);
    if (result != ZB_KC_OK || tok == NULL || strcmp(tok, VALID) != 0)
      fail("release token did not load from Keychain");
    if (tok) { zb_keychain_free(tok); tok = NULL; } free(err); err = NULL;
    result = zb_mac_agent_token_remove(home, tpath, pw, FILE_SVC, ACCT, &err);
    if (result != ZB_KC_OK) fail("release token remove did not remain Keychain-backed");
    free(err); err = NULL;
    rmdir(secrets);
    rmdir(home);

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
