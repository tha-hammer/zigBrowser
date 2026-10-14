/* The Claude Agent drawer's GTK glue (chat-drawer plan D1-D5; see
 * agent_drawer.h): the overlay over the page, the floating "S" icon (click,
 * drag, keyboard, persistence) and the drawer it opens: a header with '-',
 * a scrolling message list and an input row. '-', Escape and
 * Ctrl+Shift+Space minimize it into the icon's last position with a short
 * animation. Text is only ever set with gtk_label_set_text: model output
 * stays inert. No agent is connected yet (slice S2): Send answers "Agent
 * not available yet". */

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
void zb_drawer_lerp(const ZbDrawerRect *a, const ZbDrawerRect *b, double t, ZbDrawerRect *out);
double zb_drawer_ease(double t);
size_t zb_drawer_row_text_len(const char *text, size_t len);
unsigned int zb_drawer_demo_messages(void);
unsigned int zb_drawer_anim_ms(void);

enum { ZB_GESTURE_DRAG = 1 };
#define ZB_NO_AGENT_TEXT "Agent not available yet"

static gint zb_agent_drawer_enabled = 0;
static gint zb_drawer_live = 0;

void zb_app_set_agent_drawer(int enabled) { g_atomic_int_set(&zb_agent_drawer_enabled, enabled != 0); }

int zb_app_get_agent_drawer(void) { return g_atomic_int_get(&zb_agent_drawer_enabled); }

int zb_drawer_debug_live_count(void) { return g_atomic_int_get(&zb_drawer_live); }

struct ZbDrawer {
  guint32 win_id;
  int e2e;
  GtkWidget *toplevel;
  GtkWidget *overlay;
  GtkWidget *icon;
  GtkWidget *panel;
  /* Stands in for the panel while it folds into the icon (D5), so the real
   * panel is never squeezed below its minimum size. */
  GtkWidget *ghost;
  GtkWidget *minus;
  GtkWidget *scroller;
  GtkWidget *list;
  GtkWidget *unread;
  GtkWidget *input;
  GtkWidget *send;
  GtkWidget *stop;
  GtkAdjustment *vadj;
  int open;
  int report_open; /* the `open` and `minus` rows wait for the panel's allocation */
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
  /* The message list follows new messages while it is at the bottom. */
  int stick_bottom;
  int unread_shown;
  char scroll_reported[32];
  /* The minimize animation. */
  guint tick_id;
  gint64 anim_start;
  int anim_frames;
  ZbDrawerRect anim_from, anim_to, anim_rect;
  ZbDrawerRect fold_reported; /* the last `fold` row */
};

static const char *zb_drawer_css =
    "#zb-agent-icon { background-image: none; background-color: #d97757; color: #ffffff;"
    " border: none; border-radius: 28px; box-shadow: none; padding: 0;"
    " font-weight: bold; font-size: 24px; min-width: 56px; min-height: 56px; }"
    "#zb-agent-icon:focus { outline: 2px solid #ffffff; outline-offset: -4px; }"
    "#zb-agent-drawer, #zb-agent-ghost { background-color: #f4f1ea; border-top: 1px solid #c8c2b4; }"
    "#zb-agent-header { padding: 6px 8px; border-bottom: 1px solid #ddd6c8; }"
    "#zb-agent-title { font-weight: bold; }"
    "#zb-agent-status { color: #6b6457; }"
    "#zb-agent-minus { min-width: 32px; min-height: 28px; padding: 0; font-weight: bold; }"
    "#zb-agent-list, #zb-agent-list row { background-color: transparent; }"
    ".zb-msg { padding: 6px 10px; margin: 4px 10px; border-radius: 10px; }"
    ".zb-msg-user { background-color: #d97757; color: #ffffff; }"
    ".zb-msg-assistant { background-color: #ffffff; color: #1f1e1d; }"
    ".zb-msg-system { background-color: #ece7dc; color: #4a463e; font-style: italic; }"
    "#zb-agent-input-row { padding: 6px 8px; border-top: 1px solid #ddd6c8; }";

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

/* DRAWER <win> <kind> <fields...> */
static void drawer_row(ZbDrawer *d, const char *kind, const char *a, const char *b, const char *c) {
  char win[16];
  g_snprintf(win, sizeof win, "%u", d->win_id);
  const char *fields[] = {win, kind, a, b, c};
  int n = c != NULL ? 5 : b != NULL ? 4 : a != NULL ? 3 : 2;
  zb_emit_protocol_row(d->e2e, "DRAWER", fields, n);
}

/* "x,y,w,h" in root coordinates of a content-area rect. */
static void root_rect_text(ZbDrawer *d, const ZbDrawerRect *r, char *out, size_t size) {
  int ox, oy;
  content_origin(d, &ox, &oy);
  g_snprintf(out, size, "%d,%d,%d,%d", ox + r->x, oy + r->y, r->w, r->h);
}

static void drawer_rect_row(ZbDrawer *d, const char *kind, const ZbDrawerRect *r) {
  char rect[64];
  root_rect_text(d, r, rect, sizeof rect);
  drawer_row(d, kind, rect, NULL, NULL);
}

/* A widget's allocation as a content-area rect. */
static ZbDrawerRect widget_rect(ZbDrawer *d, GtkWidget *widget) {
  GtkAllocation a;
  gtk_widget_get_allocation(widget, &a);
  int x = 0, y = 0;
  gtk_widget_translate_coordinates(widget, d->overlay, 0, 0, &x, &y);
  ZbDrawerRect r = {x, y, a.width, a.height};
  return r;
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
 * else (D3); the panel at the bottom (D2); the stand-in where the animation
 * has it. */
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
  } else if (child == d->ghost) {
    r = d->anim_rect;
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

/* --- messages ------------------------------------------------------------- */

static void set_unread(ZbDrawer *d, int shown) {
  if (d->unread_shown == shown) {
    return;
  }
  d->unread_shown = shown;
  gtk_widget_set_visible(d->unread, shown);
  drawer_row(d, "unread", shown ? "shown" : "hidden", NULL, NULL);
}

static int list_at_bottom(GtkAdjustment *adj) {
  return gtk_adjustment_get_value(adj) >= gtk_adjustment_get_upper(adj) - gtk_adjustment_get_page_size(adj) - 1.0;
}

static void scroll_to_bottom(ZbDrawer *d) {
  gtk_adjustment_set_value(d->vadj, gtk_adjustment_get_upper(d->vadj) - gtk_adjustment_get_page_size(d->vadj));
}

/* `scroll bottom|<value>` whenever the open list's position changes. */
static void report_scroll(ZbDrawer *d) {
  if (!d->open || !gtk_widget_get_mapped(d->scroller)) {
    return;
  }
  char text[32];
  if (list_at_bottom(d->vadj)) {
    g_strlcpy(text, "bottom", sizeof text);
  } else {
    g_snprintf(text, sizeof text, "%.0f", gtk_adjustment_get_value(d->vadj));
  }
  if (strcmp(text, d->scroll_reported) != 0) {
    g_strlcpy(d->scroll_reported, text, sizeof d->scroll_reported);
    drawer_row(d, "scroll", text, NULL, NULL);
  }
}

/* The list grew or was resized: one at the bottom stays there. */
static void on_list_changed(GtkAdjustment *adj, gpointer data) {
  (void)adj;
  ZbDrawer *d = data;
  if (d->stick_bottom) {
    scroll_to_bottom(d);
  }
  report_scroll(d);
}

static void on_list_scrolled(GtkAdjustment *adj, gpointer data) {
  ZbDrawer *d = data;
  d->stick_bottom = list_at_bottom(adj);
  if (d->stick_bottom) {
    set_unread(d, 0);
  }
  report_scroll(d);
}

static void on_scroller_allocated(GtkWidget *widget, GdkRectangle *allocation, gpointer data) {
  (void)widget;
  (void)allocation;
  on_list_changed(NULL, data);
}

static void on_unread_clicked(GtkButton *button, gpointer data) {
  (void)button;
  scroll_to_bottom(data);
}

/* A finished bubble (`role`: user, assistant, system): inert text only. */
static void add_message(ZbDrawer *d, const char *role, const char *text) {
  GtkWidget *label = gtk_label_new(NULL);
  gtk_label_set_text(GTK_LABEL(label), text);
  gtk_label_set_line_wrap(GTK_LABEL(label), TRUE);
  gtk_label_set_line_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
  gtk_label_set_max_width_chars(GTK_LABEL(label), 80);
  gtk_label_set_xalign(GTK_LABEL(label), 0);
  gtk_widget_set_halign(label, strcmp(role, "user") == 0 ? GTK_ALIGN_END : GTK_ALIGN_START);
  GtkStyleContext *style = gtk_widget_get_style_context(label);
  gtk_style_context_add_class(style, "zb-msg");
  char *role_class = g_strdup_printf("zb-msg-%s", role);
  gtk_style_context_add_class(style, role_class);
  g_free(role_class);
  gtk_container_add(GTK_CONTAINER(d->list), label);
  gtk_widget_show_all(gtk_widget_get_parent(label)); /* its GtkListBoxRow */

  size_t len = strlen(text);
  size_t keep = zb_drawer_row_text_len(text, len);
  char *capped = keep < len ? g_strdup_printf("%.*s…", (int)keep, text) : g_strdup(text);
  drawer_row(d, "msg", role, capped, NULL);
  g_free(capped);
  if (d->open && !d->stick_bottom) {
    set_unread(d, 1);
  }
}

/* Send: the user's bubble, then, with no agent yet, a system bubble. */
static void send_input(ZbDrawer *d) {
  GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(d->input));
  GtkTextIter start, end;
  gtk_text_buffer_get_bounds(buffer, &start, &end);
  char *text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
  g_strstrip(text);
  if (text[0] != '\0') {
    add_message(d, "user", text);
    add_message(d, "system", ZB_NO_AGENT_TEXT);
    gtk_text_buffer_set_text(buffer, "", 0);
  }
  g_free(text);
}

static void on_send_clicked(GtkButton *button, gpointer data) {
  (void)button;
  send_input(data);
}

/* Enter sends; Shift+Enter is a newline. */
static gboolean on_input_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  (void)widget;
  if ((event->keyval == GDK_KEY_Return || event->keyval == GDK_KEY_KP_Enter || event->keyval == GDK_KEY_ISO_Enter) &&
      (event->state & GDK_SHIFT_MASK) == 0) {
    send_input(data);
    return TRUE;
  }
  return FALSE;
}

/* --- open and minimize ------------------------------------------------------ */

static void drawer_open(ZbDrawer *d) {
  if (d->open || d->tick_id != 0) {
    return;
  }
  d->open = 1;
  d->report_open = 1;
  d->stick_bottom = 1;
  d->scroll_reported[0] = '\0';
  gtk_widget_hide(d->icon);
  gtk_widget_show(d->panel);
  gtk_widget_grab_focus(d->input);
}

/* The panel has its place: report where it and its '-' are. */
static void on_panel_allocated(GtkWidget *widget, GdkRectangle *allocation, gpointer data) {
  (void)widget;
  (void)allocation;
  ZbDrawer *d = data;
  if (!d->report_open) {
    return;
  }
  d->report_open = 0;
  ZbDrawerRect panel = widget_rect(d, d->panel);
  ZbDrawerRect minus = widget_rect(d, d->minus);
  drawer_rect_row(d, "open", &panel);
  drawer_rect_row(d, "minus", &minus);
}

static gboolean on_anim_tick(GtkWidget *widget, GdkFrameClock *clock, gpointer data) {
  (void)widget;
  ZbDrawer *d = data;
  gint64 now = gdk_frame_clock_get_frame_time(clock);
  if (d->anim_start == 0) {
    d->anim_start = now;
  }
  double t = (double)(now - d->anim_start) / (zb_drawer_anim_ms() * 1000.0);
  /* The target follows the window: a resize re-targets the fold. */
  int width, height;
  content_size(d, &width, &height);
  zb_drawer_place(d->has_ratios ? &d->ratios : NULL, width, height, &d->anim_to);
  zb_drawer_lerp(&d->anim_from, &d->anim_to, zb_drawer_ease(t), &d->anim_rect);
  d->anim_frames++;
  if (t < 1.0) {
    gtk_widget_queue_resize(d->ghost);
    return G_SOURCE_CONTINUE;
  }

  d->tick_id = 0;
  d->open = 0;
  gtk_widget_hide(d->ghost);
  char frames[16], from[64], to[64];
  g_snprintf(frames, sizeof frames, "%d", d->anim_frames);
  root_rect_text(d, &d->anim_from, from, sizeof from);
  root_rect_text(d, &d->anim_to, to, sizeof to);
  drawer_row(d, "anim", frames, from, to);
  drawer_row(d, "minimized", to, NULL, NULL);
  d->width = width;
  d->height = height;
  d->icon_rect = d->anim_to;
  d->reported_valid = 0;
  gtk_widget_show(d->icon);
  gtk_widget_grab_focus(d->icon);
  return G_SOURCE_REMOVE;
}

/* The stand-in was drawn: `fold <frame> <rect>` for each new place it is
 * drawn at. Emitted here, not from the tick, so a stand-in that is not on
 * screen reports nothing (plan S2.2, rev 12). */
static gboolean on_ghost_draw(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)cr;
  ZbDrawer *d = data;
  ZbDrawerRect r = widget_rect(d, widget);
  if (memcmp(&r, &d->fold_reported, sizeof r) != 0) {
    d->fold_reported = r;
    char frame[16], rect[64];
    g_snprintf(frame, sizeof frame, "%d", d->anim_frames);
    root_rect_text(d, &r, rect, sizeof rect);
    drawer_row(d, "fold", frame, rect, NULL);
  }
  return FALSE;
}

/* Fold the drawer into the icon's last position (D5): 180 ms, ease-out. */
static void drawer_minimize(ZbDrawer *d) {
  if (!d->open || d->tick_id != 0) {
    return;
  }
  d->anim_from = widget_rect(d, d->panel);
  d->anim_rect = d->anim_from;
  d->anim_frames = 0;
  d->anim_start = 0;
  memset(&d->fold_reported, 0, sizeof d->fold_reported);
  gtk_widget_hide(d->panel);
  gtk_widget_show(d->ghost);
  d->tick_id = gtk_widget_add_tick_callback(d->overlay, on_anim_tick, d, NULL);
}

static void on_minus_clicked(GtkButton *button, gpointer data) {
  (void)button;
  drawer_minimize(data);
}

/* Window accelerators, seen before the page: Ctrl+Shift+Space toggles the
 * drawer; Escape inside the drawer minimizes it. */
static gboolean on_window_key(GtkWidget *widget, GdkEventKey *event, gpointer data) {
  ZbDrawer *d = data;
  guint mods = event->state & gtk_accelerator_get_default_mod_mask();
  if ((event->keyval == GDK_KEY_space || event->keyval == GDK_KEY_KP_Space) &&
      mods == (GDK_CONTROL_MASK | GDK_SHIFT_MASK)) {
    if (d->open) {
      drawer_minimize(d);
    } else {
      drawer_open(d);
    }
    return TRUE;
  }
  if (event->keyval == GDK_KEY_Escape && d->open) {
    GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(widget));
    if (focus != NULL && gtk_widget_is_ancestor(focus, d->panel)) {
      drawer_minimize(d);
      return TRUE;
    }
  }
  return FALSE;
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

/* --- focus rows -------------------------------------------------------------- */

static gboolean on_focus_in(GtkWidget *widget, GdkEventFocus *event, gpointer data) {
  (void)event;
  drawer_row(data, "focus", g_object_get_data(G_OBJECT(widget), "zb-focus-name"), NULL, NULL);
  return FALSE;
}

static void report_focus(ZbDrawer *d, GtkWidget *widget, const char *name) {
  g_object_set_data(G_OBJECT(widget), "zb-focus-name", (gpointer)name);
  g_signal_connect(widget, "focus-in-event", G_CALLBACK(on_focus_in), d);
}

/* A message row took the focus: the list has it. */
static void on_list_focus_child(GtkContainer *list, GtkWidget *child, gpointer data) {
  (void)list;
  if (child != NULL) {
    drawer_row(data, "focus", "list", NULL, NULL);
  }
}

/* --- building ------------------------------------------------------------------ */

static GtkWidget *named(GtkWidget *widget, const char *name, const char *accessible) {
  gtk_widget_set_name(widget, name);
  if (accessible != NULL) {
    AtkObject *a11y = gtk_widget_get_accessible(widget);
    if (a11y != NULL) {
      atk_object_set_name(a11y, accessible);
    }
  }
  return widget;
}

static void collect_types(GtkWidget *widget, gpointer data) {
  GString *types = data;
  if (types->len > 0) {
    g_string_append_c(types, ',');
  }
  g_string_append(types, G_OBJECT_TYPE_NAME(widget));
  if (GTK_IS_CONTAINER(widget)) {
    gtk_container_forall(GTK_CONTAINER(widget), collect_types, types);
  }
}

/* The drawer: header ("Claude Agent", status, '-'), the scrolling message
 * list, "New messages", and the input row (text, Send, Stop). */
static void build_panel(ZbDrawer *d) {
  d->panel = named(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0), "zb-agent-drawer", "Claude Agent");

  GtkWidget *header = named(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8), "zb-agent-header", NULL);
  GtkWidget *title = named(gtk_label_new("Claude Agent"), "zb-agent-title", NULL);
  gtk_label_set_xalign(GTK_LABEL(title), 0);
  GtkWidget *status = named(gtk_label_new("Not connected"), "zb-agent-status", NULL);
  gtk_widget_set_hexpand(status, TRUE);
  gtk_label_set_xalign(GTK_LABEL(status), 0);
  d->minus = named(gtk_button_new_with_label("-"), "zb-agent-minus", "Minimize Claude Agent");
  gtk_widget_set_tooltip_text(d->minus, "Minimize");
  gtk_box_pack_start(GTK_BOX(header), title, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(header), status, TRUE, TRUE, 0);
  gtk_box_pack_end(GTK_BOX(header), d->minus, FALSE, FALSE, 0);

  d->scroller = gtk_scrolled_window_new(NULL, NULL);
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(d->scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_widget_set_vexpand(d->scroller, TRUE);
  d->list = named(gtk_list_box_new(), "zb-agent-list", "Messages");
  gtk_list_box_set_selection_mode(GTK_LIST_BOX(d->list), GTK_SELECTION_NONE);
  gtk_container_add(GTK_CONTAINER(d->scroller), d->list);
  d->vadj = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(d->scroller));

  d->unread = named(gtk_button_new_with_label("↓ New messages"), "zb-agent-unread", NULL);
  gtk_widget_set_halign(d->unread, GTK_ALIGN_CENTER);
  gtk_widget_set_no_show_all(d->unread, TRUE);

  GtkWidget *row = named(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6), "zb-agent-input-row", NULL);
  GtkWidget *input_scroller = gtk_scrolled_window_new(NULL, NULL);
  gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(input_scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
  gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(input_scroller), 36);
  gtk_scrolled_window_set_max_content_height(GTK_SCROLLED_WINDOW(input_scroller), 120);
  gtk_scrolled_window_set_propagate_natural_height(GTK_SCROLLED_WINDOW(input_scroller), TRUE);
  gtk_widget_set_hexpand(input_scroller, TRUE);
  d->input = named(gtk_text_view_new(), "zb-agent-input", "Message Claude");
  gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(d->input), GTK_WRAP_WORD_CHAR);
  gtk_container_add(GTK_CONTAINER(input_scroller), d->input);
  d->send = named(gtk_button_new_with_label("Send"), "zb-agent-send", "Send");
  d->stop = named(gtk_button_new_with_label("Stop"), "zb-agent-stop", "Stop");
  gtk_widget_set_sensitive(d->stop, FALSE);
  gtk_widget_set_valign(d->send, GTK_ALIGN_END);
  gtk_widget_set_valign(d->stop, GTK_ALIGN_END);
  gtk_box_pack_start(GTK_BOX(row), input_scroller, TRUE, TRUE, 0);
  gtk_box_pack_start(GTK_BOX(row), d->send, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(row), d->stop, FALSE, FALSE, 0);

  gtk_box_pack_start(GTK_BOX(d->panel), header, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(d->panel), d->scroller, TRUE, TRUE, 0);
  gtk_box_pack_start(GTK_BOX(d->panel), d->unread, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(d->panel), row, FALSE, FALSE, 0);

  /* Every part is shown inside the panel; the panel itself stays hidden
   * until it is opened (the window's show_all must not show it). */
  gtk_widget_show_all(d->panel);
  gtk_widget_hide(d->panel);
  gtk_widget_set_no_show_all(d->panel, TRUE);

  report_focus(d, d->input, "input");
  report_focus(d, d->send, "send");
  report_focus(d, d->stop, "stop");
  report_focus(d, d->minus, "minus");
  g_signal_connect(d->list, "set-focus-child", G_CALLBACK(on_list_focus_child), d);
  g_signal_connect(d->minus, "clicked", G_CALLBACK(on_minus_clicked), d);
  g_signal_connect(d->send, "clicked", G_CALLBACK(on_send_clicked), d);
  g_signal_connect(d->unread, "clicked", G_CALLBACK(on_unread_clicked), d);
  g_signal_connect(d->input, "key-press-event", G_CALLBACK(on_input_key), d);
  g_signal_connect(d->vadj, "changed", G_CALLBACK(on_list_changed), d);
  g_signal_connect(d->vadj, "value-changed", G_CALLBACK(on_list_scrolled), d);
  g_signal_connect_after(d->scroller, "size-allocate", G_CALLBACK(on_scroller_allocated), d);
  g_signal_connect_after(d->panel, "size-allocate", G_CALLBACK(on_panel_allocated), d);

  GString *types = g_string_new(NULL);
  collect_types(d->panel, types);
  drawer_row(d, "tree", types->str, NULL, NULL);
  g_string_free(types, TRUE);
}

static void build_icon(ZbDrawer *d) {
  d->icon = named(gtk_button_new_with_label("S"), "zb-agent-icon", "Open Claude Agent");
  gtk_widget_set_tooltip_text(d->icon, "Open Claude Agent");
  gtk_widget_set_can_focus(d->icon, TRUE);
  gtk_widget_set_halign(d->icon, GTK_ALIGN_START);
  gtk_widget_set_valign(d->icon, GTK_ALIGN_START);
  gtk_widget_add_events(d->icon, GDK_BUTTON_MOTION_MASK | GDK_POINTER_MOTION_MASK);
  g_signal_connect_after(d->icon, "map", G_CALLBACK(on_icon_mapped), d);
  g_signal_connect(d->icon, "button-press-event", G_CALLBACK(on_icon_press), d);
  g_signal_connect(d->icon, "motion-notify-event", G_CALLBACK(on_icon_motion), d);
  g_signal_connect(d->icon, "button-release-event", G_CALLBACK(on_icon_release), d);
  g_signal_connect(d->icon, "key-press-event", G_CALLBACK(on_icon_key), d);
  report_focus(d, d->icon, "icon");
}

/* --- lifecycle --------------------------------------------------------------- */

ZbDrawer *zb_drawer_attach(GtkWidget *toplevel, GtkWidget *view, guint32 win_id, int e2e_protocol) {
  install_css_once();
  ZbDrawer *d = g_new0(ZbDrawer, 1);
  d->win_id = win_id;
  d->e2e = e2e_protocol;
  d->toplevel = toplevel;
  d->has_ratios = zb_drawer_start_ratios(&d->ratios);
  d->stick_bottom = 1;

  d->overlay = gtk_overlay_new();
  gtk_container_add(GTK_CONTAINER(d->overlay), view);
  build_icon(d);
  gtk_overlay_add_overlay(GTK_OVERLAY(d->overlay), d->icon);
  build_panel(d);
  gtk_overlay_add_overlay(GTK_OVERLAY(d->overlay), d->panel);
  d->ghost = named(gtk_event_box_new(), "zb-agent-ghost", NULL);
  gtk_widget_set_no_show_all(d->ghost, TRUE);
  g_signal_connect(d->ghost, "draw", G_CALLBACK(on_ghost_draw), d);
  gtk_overlay_add_overlay(GTK_OVERLAY(d->overlay), d->ghost);

  /* The e2e-only seed (plan S2.3): system messages to scroll through. */
  unsigned int demo = zb_drawer_demo_messages();
  for (unsigned int i = 1; i <= demo; ++i) {
    char text[64];
    g_snprintf(text, sizeof text, "Demo message %u of %u", i, demo);
    add_message(d, "system", text);
  }

  g_signal_connect(d->overlay, "get-child-position", G_CALLBACK(on_child_position), d);
  g_signal_connect_after(d->overlay, "size-allocate", G_CALLBACK(on_overlay_allocated), d);
  g_signal_connect(toplevel, "key-press-event", G_CALLBACK(on_window_key), d);

  gtk_container_add(GTK_CONTAINER(toplevel), d->overlay);
  /* The page keeps the window's keyboard focus, as without the drawer; the
   * icon is reached with Tab (D4). */
  gtk_window_set_focus(GTK_WINDOW(toplevel), view);
  g_atomic_int_inc(&zb_drawer_live);
  return d;
}

void zb_drawer_detach(ZbDrawer *d) {
  if (d == NULL) {
    return;
  }
  if (d->tick_id != 0) {
    gtk_widget_remove_tick_callback(d->overlay, d->tick_id);
  }
  GObject *connected[] = {G_OBJECT(d->toplevel), G_OBJECT(d->overlay), G_OBJECT(d->icon),   G_OBJECT(d->panel),
                          G_OBJECT(d->minus),    G_OBJECT(d->list),    G_OBJECT(d->unread), G_OBJECT(d->input),
                          G_OBJECT(d->send),     G_OBJECT(d->stop),    G_OBJECT(d->vadj),   G_OBJECT(d->scroller),
                          G_OBJECT(d->ghost)};
  for (size_t i = 0; i < G_N_ELEMENTS(connected); ++i) {
    g_signal_handlers_disconnect_by_data(connected[i], d);
  }
  g_atomic_int_add(&zb_drawer_live, -1);
  g_free(d);
}
