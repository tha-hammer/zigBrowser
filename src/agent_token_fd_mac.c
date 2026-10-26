/* MS5.3 seam (macOS plan rev 14 item 7): see agent_token_fd_mac.h. */
#include "agent_token_fd_mac.h"

#include "agent_secrets_mac.h"
#include "agent_spawn_posix.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void set_err(char **out_err, const char *text) {
  if (out_err != NULL) {
    *out_err = strdup(text);
  }
}

int zb_mac_token_to_fd_for_test(int fd, const char *keychain_path, const char *unlock_password,
                                const char *service, const char *account, char **out_err) {
  if (out_err != NULL) {
    *out_err = NULL;
  }
  char *token = NULL;
  char *lookup_err = NULL;
  int result = zb_keychain_lookup(keychain_path, unlock_password, service, account, &token, &lookup_err);
  if (result != ZB_KC_OK) {
    zb_keychain_free(token);
    /* The lookup's text names an OSStatus, never a token. */
    if (out_err != NULL) {
      *out_err = lookup_err;
    } else {
      free(lookup_err);
    }
    return result;
  }
  free(lookup_err);

  /* A closed reader must fail this call, not kill the browser: no SIGPIPE on this descriptor. */
  (void)fcntl(fd, F_SETNOSIGPIPE, 1);
  size_t len = strlen(token), done = 0;
  int failed = 0;
  while (done < len) {
    ssize_t n = write(fd, token + done, len - done);
    if (n < 0 && errno == EINTR) {
      continue;
    }
    if (n <= 0) {
      failed = 1;
      break;
    }
    done += (size_t)n;
  }
  zb_keychain_free(token);
  if (failed) {
    set_err(out_err, "zigBrowser: agent: the token could not be handed to the helper");
    return ZB_MAC_FD_WRITE_FAILED;
  }
  return ZB_KC_OK;
}

int zb_mac_token_to_fd(int fd, const char *service, const char *account) {
  char *error = NULL;
  int result = zb_mac_token_to_fd_for_test(fd, NULL, NULL, service, account, &error);
  free(error);
  return result;
}

static void close_pair(int pair[2]) {
  if (pair[0] >= 0) close(pair[0]);
  if (pair[1] >= 0) close(pair[1]);
  pair[0] = pair[1] = -1;
}

static int helper_spawn_fd3(const char *const *argv, const char *const *envp,
                            int stdin_fd, int stdout_fd,
                            int use_test_keychain,
                            const char *keychain_path, const char *unlock_password,
                            const char *service, const char *account,
                            pid_t *out_pid, char **out_err) {
  if (out_err != NULL) *out_err = NULL;
  if (out_pid != NULL) *out_pid = -1;
  int token[2] = {-1, -1};
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, token) != 0) {
    set_err(out_err, "zigBrowser: agent: the token channel could not be created");
    return ZB_MAC_HELPER_SPAWN_FAILED;
  }
  for (size_t i = 0; i < 2; ++i) {
    int flags = fcntl(token[i], F_GETFD);
    if (flags < 0 || fcntl(token[i], F_SETFD, flags | FD_CLOEXEC) != 0) {
      close_pair(token);
      set_err(out_err, "zigBrowser: agent: the token channel could not be secured");
      return ZB_MAC_HELPER_SPAWN_FAILED;
    }
  }

  /* Valid onboarded tokens are at most 512 bytes, below a socket buffer. Fill
   * the channel before spawning so a missing/unavailable Keychain starts no
   * child and the token never enters a process-creation structure. */
  int result;
  if (use_test_keychain) {
    result = zb_mac_token_to_fd_for_test(token[0], keychain_path, unlock_password,
                                          service, account, out_err);
  } else {
    result = zb_mac_token_to_fd(token[0], service, account);
    if (result != ZB_KC_OK) {
      set_err(out_err, "zigBrowser: agent: the token is unavailable");
    }
  }
  (void)shutdown(token[0], SHUT_WR);
  close(token[0]);
  token[0] = -1;
  if (result != ZB_KC_OK) {
    close_pair(token);
    return result;
  }

  int spawn_error = zb_agent_spawn_group_io_fd3(argv, envp, stdin_fd, stdout_fd, token[1], out_pid);
  close(token[1]);
  token[1] = -1;
  if (spawn_error != 0) {
    if (out_pid != NULL) *out_pid = -1;
    set_err(out_err, "zigBrowser: agent: the sandboxed helper could not be started");
    return ZB_MAC_HELPER_SPAWN_FAILED;
  }
  return ZB_KC_OK;
}

int zb_mac_helper_spawn_fd3_for_test(const char *const *argv, const char *const *envp,
                                     int stdin_fd, int stdout_fd,
                                     const char *keychain_path, const char *unlock_password,
                                     const char *service, const char *account,
                                     pid_t *out_pid, char **out_err) {
  return helper_spawn_fd3(argv, envp, stdin_fd, stdout_fd, 1, keychain_path, unlock_password,
                          service, account, out_pid, out_err);
}

int zb_mac_helper_spawn_fd3(const char *const *argv, const char *const *envp,
                            int stdin_fd, int stdout_fd, const char *service,
                            const char *account, pid_t *out_pid) {
  char *error = NULL;
  int result = helper_spawn_fd3(argv, envp, stdin_fd, stdout_fd, 0, NULL, NULL,
                                service, account, out_pid, &error);
  free(error);
  return result;
}
