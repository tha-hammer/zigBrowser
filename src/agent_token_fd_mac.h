/* MS5.3 seam (macOS plan rev 14 item 7): the stored Claude token goes to exactly one file descriptor, the
 * helper's fd 3, and nowhere else. Non-GLib; built only into macOS binaries. */
#ifndef ZB_AGENT_TOKEN_FD_MAC_H
#define ZB_AGENT_TOKEN_FD_MAC_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Beyond ZbKeychainResult (agent_secrets_mac.h): the token was found but could not be written to fd. */
#define ZB_MAC_FD_WRITE_FAILED 3
#define ZB_MAC_HELPER_SPAWN_FAILED 4

/* Production lookup: the default login Keychain only. Writes ALL token bytes to
 * `fd`, then wipes and frees the Keychain copy. No path, password, token or
 * error string can cross this API. */
int zb_mac_token_to_fd(int fd, const char *service, const char *account);

/* Disposable-keychain variant for platform tests only. out_err is NULL on
 * success, otherwise a malloc'd fixed message that never contains the token. */
int zb_mac_token_to_fd_for_test(int fd, const char *keychain_path, const char *unlock_password,
                                const char *service, const char *account, char **out_err);

/* Product helper boundary. Creates a private Unix socketpair, fills it from the
 * default Keychain, and spawns argv with the read endpoint explicitly mapped to
 * fd 3. stdin_fd/stdout_fd follow zb_agent_spawn_group_io; the child receives
 * only 0, 1, 2 and 3 on Darwin. The token is never an argv/env/file value. */
int zb_mac_helper_spawn_fd3(const char *const *argv, const char *const *envp,
                            int stdin_fd, int stdout_fd, const char *service,
                            const char *account, pid_t *out_pid);

/* Same product handoff, but sourcing the token from a disposable Keychain. */
int zb_mac_helper_spawn_fd3_for_test(const char *const *argv, const char *const *envp,
                                     int stdin_fd, int stdout_fd,
                                     const char *keychain_path, const char *unlock_password,
                                     const char *service, const char *account,
                                     pid_t *out_pid, char **out_err);

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_TOKEN_FD_MAC_H */
