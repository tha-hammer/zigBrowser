/* The Secrets window (chat-drawer plan D11, slice S4): a native GtkWindow,
 * not a ZbWindow. So it has no WebView, is not in the window registry, not
 * in page.list and not reachable from the automation socket or any page.
 *
 * It offers "Paste a long-lived token" (a password entry with Save and
 * Remove) and a status line that never shows any part of the token. The
 * entry is cleared on Save. With no answer from the Secret Service it
 * stores nothing and offers the explicit "Save to a private file instead"
 * (the 0600 file agent-home/secrets/claude-token), with a warning that the
 * token is then stored unencrypted. There is never a silent fallback.
 *
 * Rows (--e2e-protocol only): `SECRETS status <state>` on every state
 * change, `SECRETS text <the status sentence>` whenever the status line
 * changes, `SECRETS tree <GTK type names>` when the window is built, and
 * `SECRETS rect <entry|save|remove|file> <x,y,w,h>` after each layout, so
 * a test can drive the controls with real X input. */
#ifndef ZB_AGENT_SECRETS_WINDOW_H
#define ZB_AGENT_SECRETS_WINDOW_H

#include <gtk/gtk.h>

typedef enum {
  ZB_SECRET_STORE_SERVICE = 0, /* the default: the Secret Service (libsecret) */
  ZB_SECRET_STORE_FILE = 1,    /* --agent-secret-store file */
} ZbSecretStore;

typedef struct {
  int e2e_protocol;
  ZbSecretStore store;
  /* The agent home (the file store lives in its secrets/ directory). */
  const char *agent_home;
  /* After a successful Save or Remove: whether a token is now stored. */
  void (*changed)(int has_token, void *data);
  void *data;
} ZbSecretsConfig;

/* Copies `config`. Call once, on the GTK thread, before any present. */
void zb_secrets_window_configure(const ZbSecretsConfig *config);

/* app.zig's call (plain C types, no GTK header needed there): configures the
 * window for a provisioned agent home with `store` (ZbSecretStore). */
void zb_secrets_window_setup(int store, const char *agent_home, int e2e_protocol);

/* Whether a provisioned agent home was configured (the drawer's Send then
 * asks the store first), and its store and agent home. */
int zb_secrets_window_configured(void);
int zb_secrets_window_store(void);
const char *zb_secrets_window_home(void);

/* Shows the one Secrets window (building it the first time), above
 * `transient_for` when given, and reads the store's state again (one
 * `SECRETS status` row). GTK thread only. */
void zb_secrets_window_present(GtkWindow *transient_for);

/* Whether the Secrets window currently exists (for tests of the drawer). */
int zb_secrets_window_open(void);

#endif
