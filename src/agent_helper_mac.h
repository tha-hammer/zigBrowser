/* Native macOS Claude Agent process and session owner. */
#ifndef ZB_AGENT_HELPER_MAC_H
#define ZB_AGENT_HELPER_MAC_H

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZB_MAC_AGENT_TOKEN_SERVICE "dev.zigbrowser.ClaudeAgentToken"
#define ZB_MAC_AGENT_TOKEN_ACCOUNT "default"

int zb_mac_agent_helper_spawn_fd3(const char *const *argv, const char *const *envp,
                                  int stdin_fd, int stdout_fd, pid_t *out_pid);
int zb_mac_agent_helper_spawn_fd3_for_test(
    const char *const *argv, const char *const *envp,
    int stdin_fd, int stdout_fd,
    const char *keychain_path, const char *unlock_password,
    const char *service, const char *account,
    pid_t *out_pid, char **out_err);

int zb_agent_helper_configured(void);
void zb_agent_helper_send(unsigned int window_id, const char *text);
void zb_agent_helper_stop(void);

#ifdef __cplusplus
}
#endif

#endif

