#include "agent_helper_mac.h"

#include "agent_token_fd_mac.h"

#define ZB_MAC_AGENT_TEST_TOKEN_SERVICE "dev.zigbrowser.MS63ProductTest"

int zb_mac_agent_helper_spawn_fd3(const char *const *argv, const char *const *envp,
                                  int stdin_fd, int stdout_fd, pid_t *out_pid) {
  return zb_mac_helper_spawn_fd3(argv, envp, stdin_fd, stdout_fd,
                                 ZB_MAC_AGENT_TOKEN_SERVICE,
                                 ZB_MAC_AGENT_TOKEN_ACCOUNT, out_pid);
}

int zb_mac_agent_helper_spawn_fd3_for_test(
    const char *const *argv, const char *const *envp,
    int stdin_fd, int stdout_fd,
    const char *keychain_path, const char *unlock_password,
    pid_t *out_pid, char **out_err) {
  return zb_mac_helper_spawn_fd3_for_test(
      argv, envp, stdin_fd, stdout_fd, keychain_path, unlock_password,
      ZB_MAC_AGENT_TEST_TOKEN_SERVICE, ZB_MAC_AGENT_TOKEN_ACCOUNT, out_pid, out_err);
}
