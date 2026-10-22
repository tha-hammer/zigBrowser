/* The macOS Keychain Secrets window (MS7.5): an AppKit NSWindow with a password field and four buttons — Save,
 * Remove, Sign in, Cancel — wired to the Keychain token seam (agent_secrets_mac.h / the onboarding seam). Like the
 * Linux GtkWindow secrets window it is NOT a ZbWindow: no WebView, not in the window registry, and unreachable from
 * the automation socket or any page.
 *
 * The window's PORTABLE logic — validate+store on Save, clear on Remove, the login flow on Sign in / Cancel, and
 * the status line that never shows the token — lives in agent_secrets_window_mac.zig and is exercised by the
 * portable driven logic test (tests/agent_secrets_window_mac_logic_test.zig). THIS header is only the C entry point
 * the AppKit drawer calls to open the window; the real AppKit shell is proven in the compiled two-Mac gate.
 *
 * Shared seam ownership: JadeBeacon owns this window + the Keychain wiring; the drawer (BlueBeaver) calls only this
 * one function. Name/signature proposed on topic ms7-keychain-secrets; adjust here if the drawer needs otherwise. */
#ifndef ZB_AGENT_SECRETS_WINDOW_MAC_H
#define ZB_AGENT_SECRETS_WINDOW_MAC_H

#ifdef __cplusplus
extern "C" {
#endif

/* Open (or focus, if already open) the macOS Keychain Secrets window, owned by the app, non-modal. window_id is the
 * drawer's bound window (for ownership/positioning), or 0 for an app-level window. Returns 0 on success, non-zero if
 * the window could not be shown. AppKit main thread only. */
int zb_secrets_window_open(unsigned long long window_id);

#ifdef __cplusplus
}
#endif

#endif /* ZB_AGENT_SECRETS_WINDOW_MAC_H */
