/* MS5.3 seam (macOS plan rev 14 item 7): see agent_token_fd_mac.h. */
#include "agent_token_fd_mac.h"

#include "agent_secrets_mac.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static void set_err(char **out_err, const char *text) {
  if (out_err != NULL) {
    *out_err = strdup(text);
  }
}

int zb_mac_token_to_fd(int fd, const char *keychain_path, const char *unlock_password, const char *service,
                       const char *account, char **out_err) {
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
