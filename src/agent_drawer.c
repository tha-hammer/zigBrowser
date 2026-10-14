/* The Claude Agent drawer's GTK glue (chat-drawer plan D1-D4; see
 * agent_drawer.h). Slice S1: the overlay, the floating "S" icon (click,
 * drag, keyboard, persistence) and an empty drawer panel it opens. */

#include "agent_drawer.h"
#include "webkit_shim.h"

#include <math.h>
#include <string.h>

/* src/agent_drawer.zig */
typedef struct {
  int x, y, w, h;
} ZbDrawerRect;
typedef struct {
  double x, y;
} ZbDrawerRatios;
int zb_drawer_classify(double dx, double dy);
void zb_drawer_place(const ZbDrawerRatios *ratios, int width, int height, ZbDrawerRect *out);
void zb_drawer_ratios_of(const ZbDrawerRect *r, int width, int height, ZbDrawerRatios *out);
void zb_drawer_clamp(ZbDrawerRect *r, int width, int height);
void zb_drawer_key_move(ZbDrawerRect *r, int dx, int dy, int big, int width, int height);
void zb_drawer_panel_rect(int width, int height, ZbDrawerRect *out);
int zb_drawer_start_ratios(ZbDrawerRatios *out);
void zb_drawer_remember(const ZbDrawerRatios *ratios);

enum { ZB_GESTURE_DRAG = 1 };

static gint zb_agent_drawer_enabled = 0;

void zb_app_set_agent_drawer(int enabled) { g_atomic_int_set(&zb_agent_drawer_enabled, enabled != 0); }

int zb_app_get_agent_drawer(void) { return g_atomic_int_get(&zb_agent_drawer_enabled); }

struct ZbDrawer {
  guint32 win_id;
  int e2e;
  GtkWidget *toplevel;
  GtkWidget *overlay;
  GtkWidget *icon;
  GtkWidget *panel;
  int open;
  /* The content area the icon was last placed in. */
  int width, height;
  /* This window's own icon position (D4): none until the user moves it
   * here or a start position exists; then kept as ratios across resizes. */
  int has_ratios;
  ZbDrawerRatios ratios;
  ZbDrawerRect icon_rect; /* content coordinates */
  int reported_valid;
  ZbDrawerRect reported; /* the last `icon` row */
  /* A pointer gesture on the icon. */
  int pressing, dragging;
  double press_x, press_y; /* root coordinates */
  ZbDrawerRect press_rect;
};

static const char *zb_drawer_css =
    "#zb-agent-icon { background-image: none; background-color: #d97757; color: #ffffff;"
    " border: none; border-radius: 28px; box-shadow: none; padding: 0;"
    " font-weight: bold; font-size: 24px; min-width: 56px; min-height: 56px; }"
    "#zb-agent-icon:focus { outline: 2px solid #ffffff; outline-offset: -4px; }"
    "#zb-agent-drawer { background-color: #f4f1ea; border-top: 1px solid #c8c2b4; }";

static void install_css_once(void) {
  static gsize done = 0;
  if (g_once_init_enter(&done)) {
    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_data(provider, zb_drawer_css, -1, NULL);
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), GTK_STYLE_PROVIDER(provider),
                                              GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(provider);
    g_once_init_leave(&done, 1);
  }
}

/* --- rows --------------------------------------------------------------- */

/* Where the content area's 0,0 is on the root window. */
static void content_origin(ZbDrawer *d, int *ox, int *oy) {
  *ox = 0;
  *oy = 0;
  GdkWindow *window = gtk_widget_get_window(d->toplevel);
  if (window != NULL) {
    gdk_window_get_origin(window, ox, oy);
  }
  int tx = 0, ty = 0;
  if (gtk_widget_translate_coordinates(d->overlay, d->toplevel, 0, 0, &tx, &ty)) {
    *ox += tx;
    *oy += ty;
  }
}

static void drawer_row(ZbDrawer *d, const char *kind, const char *value) {
  char win[16];
  g_snprintf(win, sizeof win, "%u", d->win_id);
  const char *fields[] = {win, kind, value};
  zb_emit_protocol_row(d->e2e, "DRAWER", fields, 3);
}

static void drawer_rect_row(ZbDrawer *d, const char *kind, const ZbDrawerRect *r) {
  int ox, oy;
  content_origin(d, &ox, &oy);
  char rect[64];
  g_snprintf(rect, sizeof rect, "%d,%d,%d,%d", ox + r->x, oy + r->y, r->w, r->h);
  drawer_row(d, kind, rect);
}

/* The icon is shown at icon_rect: one `icon` row per new position. */
static void report_icon(ZbDrawer *d) {
  if (d->open || d->pressing || !gtk_widget_get_mapped(d->icon)) {
    return;
  }
  if (d->reported_valid && memcmp(&d->reported, &d->icon_rect, sizeof d->reported) == 0) {
    return;
  }
  d->reported = d->icon_rect;
  d->reported_valid = 1;
  drawer_rect_row(d, "icon", &d->icon_rect);
}

/* --- placement ------------------------------------------------------------ */

static void content_size(ZbDrawer *d, int *width, int *height) {
  GtkAllocation a;
  gtk_widget_get_allocation(d->overlay, &a);
  *width = a.width;
  *height = a.height;
}

/* The overlay places its children here (GtkOverlay::get-child-position): the
 * icon exactly at icon_rect, so its input region is the icon and nothing
 * else (D3); the panel at the bottom. */
static gboolean on_child_position(GtkOverlay *overlay, GtkWidget *child, GdkRectangle *out, gpointer data) {
  (void)overlay;
  ZbDrawer *d = data;
  int width, height;
  content_size(d, &width, &height);
  ZbDrawerRect r;
  if (child == d->icon) {
    if ((width != d->width || height != d->height) && !d->pressing) {
      d->width = width;
      d->height = height;
      zb_drawer_place(d->has_ratios ? &d->ratios : NULL, width, height, &d->icon_rect);
    }
    r = d->icon_rect;
  } else if (child == d->panel) {
    zb_drawer_panel_rect(width, height, &r);
  } else {
    return FALSE;
  }
  out->x = r.x;
  out->y = r.y;
  out->width = r.w;
  out->height = r.h;
  return TRUE;
}

static void on_overlay_allocated(GtkWidget *widget, GdkRectangle *allocation, gpointer data) {
  (void)widget;
  (void)allocation;
  report_icon(data);
}

static void on_icon_mapped(GtkWidget *widget, gpointer data) {
  (void)widget;
  report_icon(data);
}

/* A user move (drag or arrow key) to `r`: this window keeps it, new windows
 * and the next launch start there (D4). */
static void move_icon(ZbDrawer *d, const ZbDrawerRect *r) {
  d->icon_rect = *r;
  zb_drawer_ratios_of(&d->icon_rect, d->width, d->height, &d->ratios);
  d->has_ratios = 1;
  zb_drawer_remember(&d->ratios);
  gtk_widget_queue_resize(d->icon);
  report_icon(d);
}

/* --- open ------------------------------------------------------------------ */

static void drawer_open(ZbDrawer *d) {
  if (d->open) {
    return;
  }
  d->open = 1;
  gtk_widget_hide(d->icon);
  gtk_widget_show(d->panel);
  ZbDrawerRect r;
  zb_drawer_panel_rect(d->width, d->height, &r);
  drawer_rect_row(d, "open", &r);
}

/* --- icon input -------------------------------------------------------------
 * A press, at most 6 px of movement and a release is a click (it opens the
 * drawer); more is a drag that moves the icon (agent_drawer.zig). */

static gboolean on_icon_press(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)widget;
  ZbDrawer *d = data;
  if (event->button != GDK_BUTTON_PRIMARY || event->type != GDK_BUTTON_PRESS) {
    return TRUE;
  }
  d->pressing = 1;
  d->dragging = 0;
  d->press_x = event->x_root;
  d->press_y = event->y_root;
  d->press_rect = d->icon_rect;
  return TRUE;
}

static gboolean on_icon_motion(GtkWidget *widget, GdkEventMotion *event, gpointer data) {
  (void)widget;
  ZbDrawer *d = data;
  if (!d->pressing) {
    return FALSE;
  }
  double dx = event->x_root - d->press_x;
  double dy = event->y_root - d->press_y;
  if (!d->dragging && zb_drawer_classify(dx, dy) == ZB_GESTURE_DRAG) {
    d->dragging = 1;
  }
  if (d->dragging) {
    ZbDrawerRect r = d->press_rect;
    r.x += (int)lround(dx);
    r.y += (int)lround(dy);
    zb_drawer_clamp(&r, d->width, d->height);
    d->icon_rect = r;
    gtk_widget_queue_resize(d->icon);
  }
  return TRUE;
}

static gboolean on_icon_release(GtkWidget *widget, GdkEventButton *event, gpointer data) {
  (void)widget;
  ZbDrawer *d = data;
  if (event->button != GDK_BUTTON_PRIMARY || !d->pressing) {
    return TRUE;
  }
  d->pressing = 0;
  if (d->dragging) {
    d->dragging = 0;
    ZbDrawerRect r = d->icon_rect;
    move_icon(d, &r);
  } else {
    drawer_open(d);
  }
  return TRUE;
}

static gboolean on_icon_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget;
  ZbDrawer *d = data;
  int dx = 0, dy = 0;
  switch (event->keyval) {
  case GDK_KEY_Return:
  case GDK_KEY_KP_Enter:
  case GDK_KEY_ISO_Enter:
  case GDK_KEY_space:
  case GDK_KEY_KP_Space:
    drawer_open(d);
    return TRUE;
  case GDK_KEY_Left:
  case GDK_KEY_KP_Left:
    dx = -1;
    break;
  case GDK_KEY_Right:
  case GDK_KEY_KP_Right:
    dx = 1;
    break;
  case GDK_KEY_Up:
  case GDK_KEY_KP_Up:
    dy = -1;
    break;
  case GDK_KEY_Down:
  case GDK_KEY_KP_Down:
    dy = 1;
    break;
  default:
    return FALSE;
  }
  ZbDrawerRect r = d->icon_rect;
  zb_drawer_key_move(&r, dx, dy, (event->state & GDK_SHIFT_MASK) != 0, d->width, d->height);
  move_icon(d, &r);
  return TRUE;
}

static gboolean on_icon_focus_in(GtkWidget *widget, GdkEventFocus *event, gpointer data) {
  (void)widget;
  (void)event;
  drawer_row(data, "focus", "icon");
  return FALSE;
}

/* --- lifecycle --------------------------------------------------------------- */

ZbDrawer *zb_drawer_attach(GtkWidget *toplevel, GtkWidget *view, guint32 win_id, int e2e_protocol) {
  install_css_once();
  ZbDrawer *d = g_new0(ZbDrawer, 1);
  d->win_id = win_id;
  d->e2e = e2e_protocol;
  d->toplevel = toplevel;
  d->has_ratios = zb_drawer_start_ratios(&d->ratios);

  d->overlay = gtk_overlay_new();
  gtk_container_add(GTK_CONTAINER(d->overlay), view);

  d->icon = gtk_button_new_with_label("S");
  gtk_widget_set_name(d->icon, "zb-agent-icon");
  gtk_widget_set_tooltip_text(d->icon, "Open Claude Agent");
  gtk_widget_set_can_focus(d->icon, TRUE);
  gtk_widget_set_halign(d->icon, GTK_ALIGN_START);
  gtk_widget_set_valign(d->icon, GTK_ALIGN_START);
  gtk_widget_add_events(d->icon, GDK_BUTTON_MOTION_MASK | GDK_POINTER_MOTION_MASK);
  AtkObject *a11y = gtk_widget_get_accessible(d->icon);
  if (a11y != NULL) {
    atk_object_set_name(a11y, "Open Claude Agent");
  }
  gtk_overlay_add_overlay(GTK_OVERLAY(d->overlay), d->icon);

  d->panel = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
  gtk_widget_set_name(d->panel, "zb-agent-drawer");
  gtk_widget_set_no_show_all(d->panel, TRUE);
  gtk_overlay_add_overlay(GTK_OVERLAY(d->overlay), d->panel);

  g_signal_connect(d->overlay, "get-child-position", G_CALLBACK(on_child_position), d);
  g_signal_connect_after(d->overlay, "size-allocate", G_CALLBACK(on_overlay_allocated), d);
  g_signal_connect_after(d->icon, "map", G_CALLBACK(on_icon_mapped), d);
  g_signal_connect(d->icon, "button-press-event", G_CALLBACK(on_icon_press), d);
  g_signal_connect(d->icon, "motion-notify-event", G_CALLBACK(on_icon_motion), d);
  g_signal_connect(d->icon, "button-release-event", G_CALLBACK(on_icon_release), d);
  g_signal_connect(d->icon, "key-press-event", G_CALLBACK(on_icon_key), d);
  g_signal_connect(d->icon, "focus-in-event", G_CALLBACK(on_icon_focus_in), d);

  gtk_container_add(GTK_CONTAINER(toplevel), d->overlay);
  /* The page keeps the window's keyboard focus, as without the drawer; the
   * icon is reached with Tab (D4). */
  gtk_window_set_focus(GTK_WINDOW(toplevel), view);
  return d;
}

void zb_drawer_detach(ZbDrawer *d) {
  if (d == NULL) {
    return;
  }
  g_signal_handlers_disconnect_by_data(d->overlay, d);
  g_signal_handlers_disconnect_by_data(d->icon, d);
  g_free(d);
}
