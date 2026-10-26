/* macOS Agent drawer process launch. The higher-level helper/session owner
 * supplies argv, environment and pipes; this boundary owns the Keychain-to-fd
 * 3 handoff used for every native drawer launch. */
#ifndef ZB_AGENT_HELPER_MAC_H
#define ZB_AGENT_HELPER_MAC_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZB_MAC_AGENT_TOKEN_SERVICE "dev.zigbrowser.ClaudeAgentToken"
#define ZB_MAC_AGENT_TOKEN_ACCOUNT "default"

/* Production drawer launch. Reads only the fixed login-Keychain item and
 * returns the spawned process-group leader through out_pid. */
int zb_mac_agent_helper_spawn_fd3(const char *const *argv, const char *const *envp,
                                  int stdin_fd, int stdout_fd, pid_t *out_pid);

/* Product-test entry. It selects the disposable test Keychain item; argv,
 * environment, descriptor mapping and process-group spawn are unchanged. */
int zb_mac_agent_helper_spawn_fd3_for_test(
    const char *const *argv, const char *const *envp,
    int stdin_fd, int stdout_fd,
    const char *keychain_path, const char *unlock_password,
    pid_t *out_pid, char **out_err);

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_HELPER_MAC_H */
