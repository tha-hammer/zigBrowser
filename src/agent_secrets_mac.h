/* The macOS Keychain backend of the Claude Agent's token store (MS5.2) — the macOS analog of the libsecret
 * backend in agent_secrets.c. A non-GLib ABI (BlueBeaver 6676): the macOS helper consumer and the
 * disposable-canary test both call it, and the token goes only to the helper's fd 3, never logged or shown.
 *
 * The item is a generic password keyed by (service, account) in a legacy file keychain (SecItem +
 * kSecUseKeychain / kSecMatchSearchList). Production targets the default (login) keychain; tests target a
 * disposable keychain they create and unlock, so the e2e needs no GUI (the login keychain refuses SecItem
 * headless with errSecInteractionNotAllowed -25308 — see the MS5 Keychain-headless finding). */
#ifndef ZB_AGENT_SECRETS_MAC_H
#define ZB_AGENT_SECRETS_MAC_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
  ZB_KC_OK = 0,
  /* A lookup found no item for (service, account). */
  ZB_KC_ABSENT = 1,
  /* The keychain could not be opened/unlocked, or a SecItem call failed (out_err names the OSStatus). */
  ZB_KC_UNAVAILABLE = 2,
} ZbKeychainResult;

/* keychain_path: NULL = the default (login) keychain (production); non-NULL = a specific file keychain (tests).
 * unlock_password: NULL = do not unlock (the default keychain is unlocked by the GUI session); non-NULL =
 *   unlock keychain_path with this password first (the test's disposable keychain).
 * out_err: set to NULL on success, else a malloc'd message the caller frees with free(); may be NULL to ignore. */

/* Store the token for (service, account), overwriting any existing item. */
int zb_keychain_store(const char *keychain_path, const char *unlock_password,
                      const char *service, const char *account, const char *token, char **out_err);

/* Look up the token for (service, account). On ZB_KC_OK, *out_token is a NUL-terminated buffer the caller
 * owns and must release with zb_keychain_free (it is wiped on free). *out_token is NULL otherwise. */
int zb_keychain_lookup(const char *keychain_path, const char *unlock_password,
                       const char *service, const char *account, char **out_token, char **out_err);

/* Delete the item for (service, account). ZB_KC_OK whether it existed or not. */
int zb_keychain_clear(const char *keychain_path, const char *unlock_password,
                      const char *service, const char *account, char **out_err);

/* Wipe (zero) then free a token returned by zb_keychain_lookup. NULL is fine. */
void zb_keychain_free(char *token);

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_SECRETS_MAC_H */
