/* The macOS (AppKit) Claude Agent drawer: the contract between its parts, so they can be built in parallel.
 *   agent_drawer_mac_host.m   window integration: dock the panel under the page with the portable geometry
 *                             (zb_drawer_page_rect / zb_drawer_appkit_frame in agent_drawer.zig), the floating
 *                             "S" icon (click, drag, persisted position), View > Agent Drawer, Escape and
 *                             Cmd+Shift+Space to minimize, matching the Linux drawer (agent_drawer.c).
 *   agent_drawer_mac_panel.m  the docked panel: header with '-', scrolling message list (inert text, selectable
 *                             and copyable), input row; Send goes through the same agent_helper calls as
 *                             agent_drawer.c, and with no provisioned agent home it says the runtime is not set up.
 *   agent_secrets_window_mac.m  the Secrets window (sign in or paste a long-lived token), stored in the Keychain
 *                             through agent_secrets_mac.m.
 * Model output is only ever set as plain text, never parsed or rendered as markup. */
#ifndef ZB_AGENT_DRAWER_MAC_H
#define ZB_AGENT_DRAWER_MAC_H

#import <AppKit/AppKit.h>

/* Panel (agent_drawer_mac_panel.m). on_minimize is called for '-' and for Escape inside the panel. */
NSView *zb_mac_drawer_panel_create(NSRect frame, void (*on_minimize)(void *ctx), void *ctx);
void zb_mac_drawer_panel_focus_input(NSView *panel);
/* role is "user", "assistant" or "status"; text is UTF-8 and shown verbatim. */
void zb_mac_drawer_panel_append(NSView *panel, const char *role, const char *utf8_text);

/* Host (agent_drawer_mac_host.m). Called by wkwebview_shim.m once per browser window. */
void zb_mac_drawer_attach(NSWindow *window, NSView *webview);
void zb_mac_drawer_set_open(NSWindow *window, int open);
int zb_mac_drawer_is_open(NSWindow *window);

/* Secrets window (agent_secrets_window_mac.m). Opened from the drawer when no credential is stored. */
void zb_mac_secrets_window_open(NSWindow *parent);

#endif
