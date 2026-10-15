/* The Claude Agent's token store (chat-drawer plan D11, slice S4).
 *
 * The token lives either in the Secret Service (libsecret, loaded with
 * dlopen: there are no libsecret dev headers on the build host) or, only
 * when chosen explicitly, in the 0600 file agent-home/secrets/claude-token.
 * There is never a silent fallback from one to the other. The token is
 * handed only to the Claude helper (on its fd 3), never logged, never shown.
 *
 * Every Secret Service call blocks on D-Bus, so each one runs on a worker
 * thread (GTask) and reports back on the GTK main context. */
#ifndef ZB_AGENT_SECRETS_H
#define ZB_AGENT_SECRETS_H

#include <glib.h>

typedef enum {
  ZB_SECRETS_OK = 0,
  /* libsecret could not be loaded, or the Secret Service did not answer:
   * the caller offers the explicit private-file choice, and stores nothing. */
  ZB_SECRETS_UNAVAILABLE = 1,
  /* No token is stored (a lookup only). */
  ZB_SECRETS_ABSENT = 2,
} ZbSecretsResult;

typedef void (*ZbSecretsDone)(ZbSecretsResult result, gpointer data);
/* `token` is owned by the callee; release it with zb_secrets_free. NULL
 * unless result is ZB_SECRETS_OK. */
typedef void (*ZbSecretsLookupDone)(ZbSecretsResult result, char *token, gpointer data);

/* The token is copied (and the copy wiped after use). */
void zb_secrets_service_store_async(const char *token, ZbSecretsDone done, gpointer data);
void zb_secrets_service_clear_async(ZbSecretsDone done, gpointer data);
void zb_secrets_service_lookup_async(ZbSecretsLookupDone done, gpointer data);

/* Wipes, then frees, a token returned by a lookup or a fetch. NULL is fine. */
void zb_secrets_free(char *token);

/* The one way the browser reads the stored token (S4a; BlackRobin 5614): for
 * the Send that needs it, and for the helper's fd 3 (S3b, agent_helper.c). */
typedef enum {
  ZB_TOKEN_OK = 0,
  ZB_TOKEN_ABSENT = 1,
  /* The Secret Service did not answer, or libsecret could not be loaded. */
  ZB_TOKEN_UNAVAILABLE = 2,
  /* The file store's token file broke a rule (one stderr line names which). */
  ZB_TOKEN_REFUSED = 3,
} ZbTokenResult;

typedef void (*ZbTokenDone)(ZbTokenResult result, char *token, void *data);

/* `store`: 0 the Secret Service (the default), 1 the file store
 * (`--agent-secret-store file`, agent-home/secrets/claude-token). The read
 * runs on a worker thread; `done` runs later on the GTK main context, never
 * before this returns. `token` is NUL-terminated and NULL unless
 * ZB_TOKEN_OK; `done` owns it and releases it with zb_secrets_free. */
void zb_agent_token_fetch(int store, const char *agent_home, ZbTokenDone done, void *data);

/* The e2e-only answer delays (ZIGBROWSER_AGENT_SECRETS_TEST_DELAY, set by
 * the Secrets window's setup with --e2e-protocol): each Secret Service
 * answer is held back this many milliseconds after the call. */
void zb_secrets_set_test_delay(unsigned lookup_ms, unsigned store_ms, unsigned clear_ms);

#endif
