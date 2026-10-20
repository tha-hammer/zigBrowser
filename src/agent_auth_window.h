/* The auth window (chat-drawer plan S6b2, rev 16.18 seam; rev 16.18.15-16.18.20 behaviour): a
 * portable seam. This GTK body (agent_auth_window.c) opens the helper's authorize URL in its own
 * ephemeral WebView, decides every main-frame navigation with agent_auth.decideNavigation (allow,
 * capture or block), refuses popups, and hands a captured `<code>#<state>` to `on_capture`; a later
 * WKWebView body satisfies the same header. Under --e2e-protocol it writes the AUTH rows (D7b). */
#ifndef ZB_AGENT_AUTH_WINDOW_H
#define ZB_AGENT_AUTH_WINDOW_H

/* `code` is `<code>#<state>`, valid only during the call. */
typedef void (*ZbAuthCaptured)(const char *code, void *data);

/* Opens the window on `authorize_url` (already accepted by the app's authorizeUrl). Reads
 * ZIGBROWSER_AGENT_AUTH_TEST first: a refused seam opens nothing, writes `AUTH blocked seam` and its
 * stderr line, and returns -1; an ignored one writes its stderr line and opens the window with no
 * proxy and the system trust. Returns 0 when the window is open. At most one window: a second open
 * replaces the first. */
int zb_auth_window_open(const char *authorize_url, int e2e_protocol, ZbAuthCaptured on_capture, void *data);

/* Closes the window, if open (the sign-in ended). Writes nothing. */
void zb_auth_window_close(void);

#endif
