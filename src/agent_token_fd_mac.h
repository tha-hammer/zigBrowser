/* MS5.3 seam (macOS plan rev 14 item 7): the stored Claude token goes to exactly one file descriptor, the
 * helper's fd 3, and nowhere else. Non-GLib; built only into macOS binaries. */
#ifndef ZB_AGENT_TOKEN_FD_MAC_H
#define ZB_AGENT_TOKEN_FD_MAC_H

#ifdef __cplusplus
extern "C" {
#endif

/* Beyond ZbKeychainResult (agent_secrets_mac.h): the token was found but could not be written to fd. */
#define ZB_MAC_FD_WRITE_FAILED 3

/* Looks up (service, account) with zb_keychain_lookup(keychain_path, unlock_password, ...), writes ALL of
 * the token to `fd` (looping over short writes and EINTR, with SIGPIPE off for that fd), then wipes and
 * frees its copy. Returns ZB_KC_OK, ZB_KC_ABSENT, ZB_KC_UNAVAILABLE or ZB_MAC_FD_WRITE_FAILED. out_err: NULL
 * on success, else a malloc'd fixed message (never the token) the caller frees with free(); may be NULL. */
int zb_mac_token_to_fd(int fd, const char *keychain_path, const char *unlock_password, const char *service,
                       const char *account, char **out_err);

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_TOKEN_FD_MAC_H */
