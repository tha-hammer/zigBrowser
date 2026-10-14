#ifndef ZB_AGENT_DRAWER_H
#define ZB_AGENT_DRAWER_H

/* The Claude Agent drawer's GTK glue (chat-drawer plan D1-D4). Native GTK
 * widgets only: no web content, no JavaScript, nothing a page or the
 * automation socket can reach. The geometry and persistence are pure Zig
 * (src/agent_drawer.zig, the zb_drawer_* functions declared in
 * agent_drawer.c). GTK thread only. */

#include <gtk/gtk.h>

typedef struct ZbDrawer ZbDrawer;

/* Wraps `view` in a GtkOverlay that becomes `toplevel`'s child, with the
 * floating "S" icon above the page and the (hidden) drawer panel. Called by
 * zb_window_new instead of adding the view directly, once that window has
 * passed its guards, and only when zb_app_get_agent_drawer() is on.
 * `win_id`: the window's automation id, used in its DRAWER rows;
 * `e2e_protocol`: whether those rows are written. */
ZbDrawer *zb_drawer_attach(GtkWidget *toplevel, GtkWidget *view, guint32 win_id, int e2e_protocol);

/* The window is being destroyed (its "destroy" handler, before its
 * children go): disconnects every handler and frees the drawer. NULL is
 * fine. */
void zb_drawer_detach(ZbDrawer *drawer);

/* Provided by webkit_shim.c: one tab-separated --e2e-protocol row, each
 * field sanitized like every other row; nothing when `enabled` is 0. */
void zb_emit_protocol_row(int enabled, const char *tag, const char *const *fields, int n_fields);

#endif
