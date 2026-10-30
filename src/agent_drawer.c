/* The Claude Agent drawer's GTK glue (chat-drawer plan D1-D5; see
 * agent_drawer.h): the host that floats the drawer over the page, the floating "S" icon (click,
 * drag, keyboard, persistence) and the drawer it opens: a header with '-',
 * a scrolling message list and an input row. '-', Escape and
 * Ctrl+Shift+Space minimize it into the icon's last position with a short
 * animation. Text is only ever set with gtk_label_set_text: model output
 * stays inert. Send hands the text to the agent (agent_helper.c); with no
 * provisioned agent home it says the runtime is not set up (S5.5). */

#include "agent_drawer.h"
#include "agent_helper.h"
#include "agent_host.h"
#include "agent_secrets.h"
#include "agent_secrets_window.h"
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
char *zb_drawer_break_runs(const char *text, size_t len, size_t *out_len);
size_t zb_drawer_original_offset(const char *text, size_t len, size_t shown);
size_t zb_drawer_reply_text_max(void);
size_t zb_drawer_reply_content_max(void);
size_t zb_drawer_label_text_max(void);
unsigned int zb_drawer_demo_messages(void);
unsigned int zb_drawer_anim_ms(void);

enum { ZB_GESTURE_DRAG = 1 };
#define ZB_STOPPED_TEXT "(stopped)" /* S5.2 */
#define ZB_TRUNCATED_TEXT "\n[output truncated]" /* S5.6; agent_drawer.zig's truncated_marker */
_Static_assert(sizeof(ZB_TRUNCATED_TEXT) - 1 == 19, "the marker reply_content_max leaves room for");
/* S5.6: a streaming bubble is laid out at most this often (its one pending refresh). */
#define ZB_STREAM_REFRESH_MS 100
/* A streaming text view (over label_text_max) is laid out at most this often. */
#define ZB_STREAM_REFRESH_LARGE_MS 250
/* netd could not start or stopped (plan rev 16.2 §3c.2): shown on that Send and
 * every later one; netd is never started again in this browser. */
/* S4.1: no token is stored (or the store did not answer); the Secrets window opens. */

/* agent_tools.zig (S8 decision 16 part 3; GTK thread): the drawer's state and its card's buttons. */
void zb_agent_tools_drawer_showing(unsigned int win, int shown);
int zb_agent_tools_approve(guint64 card);
int zb_agent_tools_deny(guint64 card);
unsigned int zb_agent_tools_activate(void);
/* webkit_shim.c (GTK thread). */
void zb_window_present(unsigned int id);

static gint zb_agent_drawer_enabled = 0;
static gint zb_drawer_live = 0;
/* Every attached drawer (GTK thread), for netd's failure, which may come later. */
static GList *zb_drawers = NULL;

void zb_app_set_agent_drawer(int enabled) { g_atomic_int_set(&zb_agent_drawer_enabled, enabled != 0); }

int zb_app_get_agent_drawer(void) { return g_atomic_int_get(&zb_agent_drawer_enabled); }

int zb_drawer_debug_live_count(void) { return g_atomic_int_get(&zb_drawer_live); }

struct ZbDrawer {
  guint32 win_id;
  int e2e;
  GtkWidget *toplevel;
  GtkWidget *host; /* ZbDrawerHost: the page plus the floating children */
  GtkWidget *icon;
  GtkWidget *panel;
  /* Holds the panel and takes the pointer over all of it (an input-only
   * window), so no click or wheel on the drawer reaches the page below. */
  GtkWidget *catcher;
  /* Stands in for the panel while it folds into the icon (D5), so the real
   * panel is never squeezed below its minimum size. */
  GtkWidget *ghost;
  GtkWidget *minus;
  /* The header's Account button (S4, D1/D11): opens the Secrets window in any
   * agent state except while setup is publishing the home. */
  GtkWidget *account;
  GtkWidget *status; /* the header's agent state (S3b) */
  GtkWidget *scroller;
  GtkWidget *list;
  GtkWidget *unread;
  GtkWidget *input;
  GtkWidget *send;
  GtkWidget *stop;
  /* S5.1: the assistant bubble the running reply grows in, and its text so far;
   * NULL until the reply's first delta and again once it is whole. */
  GtkWidget *streaming;
  GString *stream_text;
  /* S5.6 (rev 16.20.2): the one pending refresh that shows stream_text (0: none), and
   * whether the reply reached reply_text_max (later deltas are not shown). */
  guint stream_idle;
  int stream_full;
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
  char *windows_reported;     /* the last `windows` row */
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
    "textview.zb-msg text { background-color: transparent; color: inherit; }"
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
  if (gtk_widget_translate_coordinates(d->host, d->toplevel, 0, 0, &tx, &ty)) {
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
  gtk_widget_translate_coordinates(widget, d->host, 0, 0, &x, &y);
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

/* `windows <census>`: every GdkWindow under the toplevel's own, depth first,
 * as `<owner type>:<output|input>:<viewable|hidden>:<depth>:<x>:<y>:<w>:<h>`
 * (viewable: it and every ancestor are mapped; depth 1 is a child of the
 * toplevel's window; x, y in the toplevel window's coordinates). One row per change;
 * e2e only (a structural check, plan §7.1: on the user's NVIDIA screen an
 * output child window over the accelerated page blanked the whole window). */
static void census_walk(GdkWindow *window, int depth, int ox, int oy, GString *out) {
  for (GList *l = gdk_window_peek_children(window); l != NULL; l = l->next) {
    GdkWindow *child = l->data;
    gpointer owner = NULL;
    gdk_window_get_user_data(child, &owner);
    int x, y;
    gdk_window_get_position(child, &x, &y);
    g_string_append_printf(out, "%s%s:%s:%s:%d:%d:%d:%d:%d", out->len > 0 ? "," : "",
                           owner != NULL && G_IS_OBJECT(owner) ? G_OBJECT_TYPE_NAME(owner) : "-",
                           gdk_window_is_input_only(child) ? "input" : "output",
                           gdk_window_is_viewable(child) ? "viewable" : "hidden", depth, ox + x, oy + y,
                           gdk_window_get_width(child), gdk_window_get_height(child));
    census_walk(child, depth + 1, ox + x, oy + y, out);
  }
}

static void report_windows(ZbDrawer *d) {
  GdkWindow *top = d->e2e ? gtk_widget_get_window(d->toplevel) : NULL;
  if (top == NULL) {
    return;
  }
  GString *out = g_string_new(NULL);
  census_walk(top, 1, 0, 0, out);
  if (g_strcmp0(out->str, d->windows_reported) != 0) {
    g_free(d->windows_reported);
    d->windows_reported = g_strdup(out->str);
    drawer_row(d, "windows", out->len > 0 ? out->str : "-", NULL, NULL);
  }
  g_string_free(out, TRUE);
}

static gboolean on_host_drawn(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)widget;
  (void)cr;
  report_windows(data);
  return FALSE;
}

/* --- placement ------------------------------------------------------------ */

static void content_size(ZbDrawer *d, int *width, int *height) {
  GtkAllocation a;
  gtk_widget_get_allocation(d->host, &a);
  *width = a.width;
  *height = a.height;
}

/* Where the host places a floating child, in content coordinates: the icon
 * exactly at icon_rect, so its input region is the icon and nothing else
 * (D3); the panel at the bottom (D2); the stand-in where the animation has it. */
static void child_rect(ZbDrawer *d, GtkWidget *child, ZbDrawerRect *r) {
  int width, height;
  content_size(d, &width, &height);
  if (child == d->icon) {
    if ((width != d->width || height != d->height) && !d->pressing) {
      d->width = width;
      d->height = height;
      zb_drawer_place(d->has_ratios ? &d->ratios : NULL, width, height, &d->icon_rect);
    }
    *r = d->icon_rect;
  } else if (child == d->catcher) {
    zb_drawer_panel_rect(width, height, r);
  } else {
    *r = d->anim_rect;
  }
}

/* --- the host ------------------------------------------------------------- */

/* The drawer's container, in place of GtkOverlay. It has no window and
 * makes none for its children: GtkOverlay gave each overlay child an output
 * GdkWindow, and on the user's NVIDIA screen an output child window over the
 * accelerated page blanked the whole browser window (review f72e63d; plan
 * §7.1). The page fills the host; the icon and the fold's stand-in float
 * over it and are painted into the page's own window, right after the page
 * (on_page_drawn): painted on the toplevel's window, the page's window would
 * cover them whenever the page repaints alone. Their input arrives through
 * input-only windows, which lie above the page's. The open panel docks
 * instead: the page is laid out above it, because the panel's scroller and
 * text view have output windows of their own, and no output window may lie
 * over the page's. The `windows` row checks this structure under Xvfb;
 * tests/manual/real_screen_check.py checks the real screen. */
typedef struct {
  GtkContainer parent;
  GtkWidget *page;
  GList *floats;
  /* The float that docks: while it is shown the page is laid out above it
   * and the host draws it, so nothing of it lies over the page's window. */
  GtkWidget *dock;
  ZbDrawer *drawer;
} ZbDrawerHost;

typedef struct {
  GtkContainerClass parent_class;
} ZbDrawerHostClass;

G_DEFINE_TYPE(ZbDrawerHost, zb_drawer_host, GTK_TYPE_CONTAINER)

#define ZB_DRAWER_HOST(obj) ((ZbDrawerHost *)(obj))

static gboolean on_page_drawn(GtkWidget *page, cairo_t *cr, gpointer data);

/* The first child is the page; every later one floats over it. */
static void zb_drawer_host_add(GtkContainer *container, GtkWidget *child) {
  ZbDrawerHost *host = ZB_DRAWER_HOST(container);
  if (host->page == NULL) {
    host->page = child;
    g_signal_connect_after(child, "draw", G_CALLBACK(on_page_drawn), host);
  } else {
    host->floats = g_list_append(host->floats, child);
  }
  gtk_widget_set_parent(child, GTK_WIDGET(container));
}

static void zb_drawer_host_remove(GtkContainer *container, GtkWidget *child) {
  ZbDrawerHost *host = ZB_DRAWER_HOST(container);
  if (child == host->page) {
    g_signal_handlers_disconnect_by_func(child, on_page_drawn, host);
    host->page = NULL;
  } else if (child == host->dock) {
    host->dock = NULL;
    host->floats = g_list_remove(host->floats, child);
  } else if (g_list_find(host->floats, child) != NULL) {
    host->floats = g_list_remove(host->floats, child);
  } else {
    return;
  }
  gboolean was_visible = gtk_widget_get_visible(child);
  gtk_widget_unparent(child);
  if (was_visible) {
    gtk_widget_queue_resize(GTK_WIDGET(container));
  }
}

/* The page first, then the floats: this is also the drawing order. */
static void zb_drawer_host_forall(GtkContainer *container, gboolean internals, GtkCallback callback, gpointer data) {
  (void)internals;
  ZbDrawerHost *host = ZB_DRAWER_HOST(container);
  if (host->page != NULL) {
    callback(host->page, data);
  }
  for (GList *l = host->floats; l != NULL;) {
    GtkWidget *child = l->data;
    l = l->next; /* the callback may remove it */
    callback(child, data);
  }
}

/* The page's size is the host's, as with GtkOverlay's main child. */
static void zb_drawer_host_preferred_width(GtkWidget *widget, gint *minimum, gint *natural) {
  GtkWidget *page = ZB_DRAWER_HOST(widget)->page;
  *minimum = *natural = 0;
  if (page != NULL && gtk_widget_get_visible(page)) {
    gtk_widget_get_preferred_width(page, minimum, natural);
  }
}

static void zb_drawer_host_preferred_height(GtkWidget *widget, gint *minimum, gint *natural) {
  GtkWidget *page = ZB_DRAWER_HOST(widget)->page;
  *minimum = *natural = 0;
  if (page != NULL && gtk_widget_get_visible(page)) {
    gtk_widget_get_preferred_height(page, minimum, natural);
  }
}

static gboolean docked(ZbDrawerHost *host) {
  return host->dock != NULL && gtk_widget_get_visible(host->dock);
}

static void zb_drawer_host_size_allocate(GtkWidget *widget, GtkAllocation *allocation) {
  ZbDrawerHost *host = ZB_DRAWER_HOST(widget);
  gtk_widget_set_allocation(widget, allocation);
  if (host->page != NULL && gtk_widget_get_visible(host->page)) {
    GtkAllocation page = *allocation;
    if (docked(host)) {
      ZbDrawerRect r;
      child_rect(host->drawer, host->dock, &r);
      page.height = MAX(1, r.y); /* the dock is at the bottom (D2) */
    }
    gtk_widget_size_allocate(host->page, &page);
  }
  for (GList *l = host->floats; l != NULL; l = l->next) {
    GtkWidget *child = l->data;
    if (!gtk_widget_get_visible(child)) {
      continue;
    }
    GtkRequisition minimum;
    gtk_widget_get_preferred_size(child, &minimum, NULL);
    ZbDrawerRect r;
    child_rect(host->drawer, child, &r);
    /* A no-window parent: child allocations are in the parent window's space. */
    GtkAllocation at = {allocation->x + r.x, allocation->y + r.y, r.w, r.h};
    gtk_widget_size_allocate(child, &at);
  }
}

/* The host draws the page and the dock; on_page_drawn draws the rest. */
static gboolean zb_drawer_host_draw(GtkWidget *widget, cairo_t *cr) {
  ZbDrawerHost *host = ZB_DRAWER_HOST(widget);
  if (host->page != NULL) {
    gtk_container_propagate_draw(GTK_CONTAINER(host), host->page, cr);
  }
  if (docked(host)) {
    gtk_container_propagate_draw(GTK_CONTAINER(host), host->dock, cr);
  }
  return FALSE;
}

/* After the page has drawn itself: the other floats, over it, in the page's
 * window. The page starts at the host's origin, so `cr` is in the host's
 * coordinates too. */
static gboolean on_page_drawn(GtkWidget *page, cairo_t *cr, gpointer data) {
  (void)page;
  ZbDrawerHost *host = data;
  for (GList *l = host->floats; l != NULL; l = l->next) {
    if (l->data != host->dock) {
      gtk_container_propagate_draw(GTK_CONTAINER(host), l->data, cr);
    }
  }
  return FALSE;
}

static void zb_drawer_host_finalize(GObject *object) {
  g_list_free(ZB_DRAWER_HOST(object)->floats);
  G_OBJECT_CLASS(zb_drawer_host_parent_class)->finalize(object);
}

static void zb_drawer_host_class_init(ZbDrawerHostClass *klass) {
  GObjectClass *object_class = G_OBJECT_CLASS(klass);
  GtkWidgetClass *widget_class = GTK_WIDGET_CLASS(klass);
  GtkContainerClass *container_class = GTK_CONTAINER_CLASS(klass);
  object_class->finalize = zb_drawer_host_finalize;
  widget_class->get_preferred_width = zb_drawer_host_preferred_width;
  widget_class->get_preferred_height = zb_drawer_host_preferred_height;
  widget_class->size_allocate = zb_drawer_host_size_allocate;
  widget_class->draw = zb_drawer_host_draw;
  container_class->add = zb_drawer_host_add;
  container_class->remove = zb_drawer_host_remove;
  container_class->forall = zb_drawer_host_forall;
}

static void zb_drawer_host_init(ZbDrawerHost *host) {
  gtk_widget_set_has_window(GTK_WIDGET(host), FALSE);
}

static GtkWidget *drawer_host_new(ZbDrawer *d) {
  ZbDrawerHost *host = g_object_new(zb_drawer_host_get_type(), NULL);
  host->drawer = d;
  return GTK_WIDGET(host);
}

/* Adds `child` as the float that docks (the panel's catcher). */
static void drawer_host_add_dock(GtkWidget *widget, GtkWidget *child) {
  gtk_container_add(GTK_CONTAINER(widget), child);
  ZB_DRAWER_HOST(widget)->dock = child;
}

static void on_host_allocated(GtkWidget *widget, GdkRectangle *allocation, gpointer data) {
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
/* `textrect <role> <rect>`: where a bubble or the status label is drawn (root
 * coordinates), one row per new place, so an e2e test can aim the X pointer at
 * the text (the user's copyable-text requirement). It locates; it is never the
 * oracle of what was copied. */
static gboolean on_text_drawn(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)cr;
  ZbDrawer *d = data;
  ZbDrawerRect r = widget_rect(d, widget);
  ZbDrawerRect *last = g_object_get_data(G_OBJECT(widget), "zb-text-rect");
  if (last != NULL && memcmp(last, &r, sizeof r) == 0) {
    return FALSE;
  }
  g_object_set_data_full(G_OBJECT(widget), "zb-text-rect", g_memdup2(&r, sizeof r), g_free);
  char rect[64];
  root_rect_text(d, &r, rect, sizeof rect);
  drawer_row(d, "textrect", g_object_get_data(G_OBJECT(widget), "zb-text-role"), rect, NULL);
  return FALSE;
}

/* A bubble's original text: what Copy gives and what its rows carry. */
typedef struct {
  char *text;
  size_t len;
} ZbOriginal;

static void original_free(gpointer data) {
  ZbOriginal *o = data;
  g_free(o->text);
  g_free(o);
}

/* S5.6 (rev 16.20.2, the user's decision 1): a bubble shows `text` with break
 * points in its long unbroken runs, so GTK can wrap them, and keeps the original
 * for Copy. A bubble over label_text_max is a read-only text view, whose layout
 * stays fast where a label's takes seconds (rev 16.20.6). */
static void set_bubble_text(GtkWidget *bubble, const char *text, size_t len) {
  ZbOriginal *o = g_new(ZbOriginal, 1);
  o->text = g_strndup(text, len);
  o->len = len;
  g_object_set_data_full(G_OBJECT(bubble), "zb-original", o, original_free);
  size_t shown_len = 0;
  char *shown = zb_drawer_break_runs(o->text, o->len, &shown_len);
  const char *show = shown != NULL ? shown : o->text;
  if (GTK_IS_LABEL(bubble)) {
    gtk_label_set_text(GTK_LABEL(bubble), show);
  } else {
    gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(bubble)), show, -1);
  }
  free(shown);
}

/* Ctrl+C and the menu's Copy: the selection's original bytes, never the break
 * points the bubble shows. */
static void on_bubble_copy(GtkWidget *bubble, gpointer unused) {
  (void)unused;
  ZbOriginal *o = g_object_get_data(G_OBJECT(bubble), "zb-original");
  int start = 0, end = 0;
  if (GTK_IS_LABEL(bubble)) {
    if (!gtk_label_get_selection_bounds(GTK_LABEL(bubble), &start, &end)) {
      return;
    }
  } else {
    GtkTextIter a, b;
    if (!gtk_text_buffer_get_selection_bounds(gtk_text_view_get_buffer(GTK_TEXT_VIEW(bubble)), &a, &b)) {
      return;
    }
    start = gtk_text_iter_get_offset(&a);
    end = gtk_text_iter_get_offset(&b);
  }
  if (o == NULL) {
    return;
  }
  size_t from = zb_drawer_original_offset(o->text, o->len, (size_t)MIN(start, end));
  size_t to = zb_drawer_original_offset(o->text, o->len, (size_t)MAX(start, end));
  gtk_clipboard_set_text(gtk_widget_get_clipboard(bubble, GDK_SELECTION_CLIPBOARD), o->text + from, (gint)(to - from));
  g_signal_stop_emission_by_name(bubble, "copy-clipboard");
}

/* Every bubble and the status label: the mouse selects their text and Ctrl+C
 * copies it (the user's requirement, 2026-10-15). */
static void report_text(ZbDrawer *d, GtkWidget *widget, const char *role) {
  if (GTK_IS_LABEL(widget)) {
    gtk_label_set_selectable(GTK_LABEL(widget), TRUE);
  }
  g_object_set_data(G_OBJECT(widget), "zb-text-role", (gpointer)role);
  g_signal_connect_after(widget, "draw", G_CALLBACK(on_text_drawn), d);
}

static const char *text_role(const char *role) {
  return strcmp(role, "user") == 0        ? "user"
         : strcmp(role, "assistant") == 0 ? "assistant"
         : strcmp(role, "error") == 0     ? "error"
                                          : "system";
}

/* The widget of a bubble holding `len` bytes: a label, or past label_text_max a
 * read-only text view; styled for `role`, with its text set. */
static GtkWidget *bubble_widget(ZbDrawer *d, const char *role, const char *text, size_t len) {
  GtkWidget *bubble;
  if (len <= zb_drawer_label_text_max()) {
    bubble = gtk_label_new(NULL);
    gtk_label_set_line_wrap(GTK_LABEL(bubble), TRUE);
    gtk_label_set_line_wrap_mode(GTK_LABEL(bubble), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_max_width_chars(GTK_LABEL(bubble), 80);
    gtk_label_set_xalign(GTK_LABEL(bubble), 0);
    gtk_widget_set_halign(bubble, strcmp(role, "user") == 0 ? GTK_ALIGN_END : GTK_ALIGN_START);
  } else {
    bubble = gtk_text_view_new();
    gtk_text_view_set_editable(GTK_TEXT_VIEW(bubble), FALSE);
    gtk_text_view_set_cursor_visible(GTK_TEXT_VIEW(bubble), TRUE); /* else arrow keys scroll, not select */
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(bubble), GTK_WRAP_WORD_CHAR);
    gtk_widget_set_halign(bubble, GTK_ALIGN_FILL);
  }
  set_bubble_text(bubble, text, len);
  g_signal_connect(bubble, "copy-clipboard", G_CALLBACK(on_bubble_copy), NULL);
  GtkStyleContext *style = gtk_widget_get_style_context(bubble);
  gtk_style_context_add_class(style, "zb-msg");
  char *role_class = g_strdup_printf("zb-msg-%s", role);
  gtk_style_context_add_class(style, role_class);
  g_free(role_class);
  report_text(d, bubble, text_role(role));
  return bubble;
}

/* A text-view bubble keeps the keyboard: its list row neither takes the focus
 * nor activates on a click (a row that did would take Ctrl+A and Shift+arrows). */
static void bubble_row_settle(GtkWidget *bubble) {
  GtkWidget *row = gtk_widget_get_parent(bubble);
  if (GTK_IS_TEXT_VIEW(bubble) && GTK_IS_LIST_BOX_ROW(row)) {
    gtk_list_box_row_set_activatable(GTK_LIST_BOX_ROW(row), FALSE);
    gtk_widget_set_can_focus(row, FALSE);
  }
}

/* A bubble on screen; its `msg` row is bubble_row's. */
static GtkWidget *new_bubble(ZbDrawer *d, const char *role, const char *text) {
  GtkWidget *bubble = bubble_widget(d, role, text, strlen(text));
  gtk_container_add(GTK_CONTAINER(d->list), bubble);
  bubble_row_settle(bubble);
  gtk_widget_show_all(gtk_widget_get_parent(bubble)); /* its GtkListBoxRow */
  return bubble;
}

/* A streaming text view's new text: only the part after what it already shows
 * changes in its buffer, so GTK lays out only the changed tail again. */
static void text_view_replace_tail(GtkWidget *bubble, const char *text, size_t len) {
  ZbOriginal *o = g_new(ZbOriginal, 1);
  o->text = g_strndup(text, len);
  o->len = len;
  g_object_set_data_full(G_OBJECT(bubble), "zb-original", o, original_free);
  size_t shown_len = 0;
  char *shown = zb_drawer_break_runs(o->text, o->len, &shown_len);
  const char *show = shown != NULL ? shown : o->text;
  size_t show_len = shown != NULL ? shown_len : o->len;
  GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(bubble));
  GtkTextIter start, end;
  gtk_text_buffer_get_bounds(buffer, &start, &end);
  char *old = gtk_text_buffer_get_text(buffer, &start, &end, TRUE);
  size_t same = 0, old_len = strlen(old);
  while (same < old_len && same < show_len && old[same] == show[same]) {
    same += 1;
  }
  while (same > 0 && ((unsigned char)show[same] & 0xC0) == 0x80) { /* back to a character's start */
    same -= 1;
  }
  GtkTextIter from;
  gtk_text_buffer_get_iter_at_offset(buffer, &from, (gint)g_utf8_strlen(show, (gssize)same));
  gtk_text_buffer_delete(buffer, &from, &end);
  gtk_text_buffer_insert(buffer, &from, show + same, (gint)(show_len - same));
  g_free(old);
  free(shown);
}

/* The streaming bubble now holds `len` bytes: a label that grew past
 * label_text_max is replaced, in its row, by a text view (rev 16.20.6). */
static void streaming_text(ZbDrawer *d, const char *text, size_t len) {
  if (GTK_IS_LABEL(d->streaming) && len > zb_drawer_label_text_max()) {
    GtkWidget *row = gtk_widget_get_parent(d->streaming);
    gtk_container_remove(GTK_CONTAINER(row), d->streaming);
    d->streaming = bubble_widget(d, "assistant", text, len);
    gtk_container_add(GTK_CONTAINER(row), d->streaming);
    bubble_row_settle(d->streaming);
    gtk_widget_show(d->streaming);
    return;
  }
  if (GTK_IS_TEXT_VIEW(d->streaming)) {
    text_view_replace_tail(d->streaming, text, len);
    return;
  }
  set_bubble_text(d->streaming, text, len);
}

static void bubble_row(ZbDrawer *d, const char *role, const char *text) {
  size_t len = strlen(text);
  size_t keep = zb_drawer_row_text_len(text, len);
  char *capped = keep < len ? g_strdup_printf("%.*s…", (int)keep, text) : g_strdup(text);
  drawer_row(d, "msg", role, capped, NULL);
  g_free(capped);
  if (d->open && !d->stick_bottom) {
    set_unread(d, 1);
  }
}

static void add_message(ZbDrawer *d, const char *role, const char *text) {
  new_bubble(d, role, text);
  bubble_row(d, role, text);
}

static void stream_idle_cancel(ZbDrawer *d) {
  if (d->stream_idle != 0) {
    g_source_remove(d->stream_idle);
    d->stream_idle = 0;
  }
}

/* The streaming bubble is whole: `text` is its last word, and its row is written.
 * Every end of a reply comes here (its message, Stop, an error, the session's end,
 * a crash), so the pending idle ends with it. */
static void end_stream(ZbDrawer *d, const char *text) {
  stream_idle_cancel(d);
  streaming_text(d, text, strlen(text));
  bubble_row(d, "assistant", text);
  d->streaming = NULL;
  d->stream_full = 0;
  g_string_truncate(d->stream_text, 0);
}

/* The one pending refresh (S5.6), at most every ZB_STREAM_REFRESH_MS: the bubble
 * shows the reply's text so far. */
static gboolean on_stream_idle(gpointer data) {
  ZbDrawer *d = data;
  d->stream_idle = 0;
  if (d->streaming != NULL) {
    streaming_text(d, d->stream_text->str, d->stream_text->len);
  }
  return G_SOURCE_REMOVE;
}

/* The reply is capped: its text so far and the marker are final (rev 16.20.12 and
 * 16.20.13): no later delta or message changes them. */
static void stream_cap(ZbDrawer *d) {
  if (!d->stream_full) {
    g_string_append(d->stream_text, ZB_TRUNCATED_TEXT);
    d->stream_full = 1;
  }
}

/* A delta's text joins the reply's, up to reply_content_max (cut on a character
 * boundary), after which the reply is capped and later text is not shown. */
static void stream_append(ZbDrawer *d, const char *text, size_t len) {
  if (d->stream_full) {
    return;
  }
  size_t room = zb_drawer_reply_content_max() - d->stream_text->len;
  if (len <= room) {
    g_string_append_len(d->stream_text, text, (gssize)len);
    return;
  }
  while (room > 0 && ((unsigned char)text[room] & 0xC0) == 0x80) {
    room -= 1;
  }
  g_string_append_len(d->stream_text, text, (gssize)room);
  stream_cap(d);
}

/* The streaming bubble's text changed: its one pending refresh shows it. */
static void stream_changed(ZbDrawer *d) {
  if (d->stream_idle == 0) {
    guint every = GTK_IS_TEXT_VIEW(d->streaming) ? ZB_STREAM_REFRESH_LARGE_MS : ZB_STREAM_REFRESH_MS;
    d->stream_idle = g_timeout_add_full(G_PRIORITY_DEFAULT_IDLE, every, on_stream_idle, d, NULL);
  }
}

/* The streaming bubble ends as it is (a capped reply's message, or a reply's ending
 * frame that no message preceded). */
static void end_stream_as_shown(ZbDrawer *d) {
  char *shown = g_strdup(d->stream_text->str);
  end_stream(d, shown);
  g_free(shown);
}

/* --- the agent's reports (agent_helper.h; S3b) ------------------------------- */

static const char *status_text(const char *state, const char *reason) {
  if (strcmp(state, "setting-up") == 0) return "Setting up…";
  if (strcmp(state, "starting") == 0) return "Starting…";
  if (strcmp(state, "ready") == 0) return "Ready";
  if (strcmp(state, "busy") == 0) return "Working…";
  if (strcmp(state, "crashed") == 0) return "Stopped";
  if (strcmp(state, "unavailable") == 0) return strcmp(reason, "no-token") == 0 ? "No token" : "Unavailable";
  return "Not connected";
}

void zb_drawer_agent_status(unsigned int win_id, const char *state, const char *reason) {
  for (GList *l = zb_drawers; l != NULL; l = l->next) {
    ZbDrawer *d = l->data;
    if (win_id != 0 && d->win_id != win_id) {
      continue;
    }
    drawer_row(d, "status", state, reason, NULL);
    gtk_label_set_text(GTK_LABEL(d->status), status_text(state, reason));
    if (d->account != NULL) gtk_widget_set_sensitive(d->account, strcmp(state, "setting-up") != 0);
    gtk_widget_set_sensitive(d->stop, strcmp(state, "busy") == 0); /* S5.2 */
    if (strcmp(reason, "no-token") == 0) { /* S4.1: the Secrets window opens */
      GtkWidget *top = gtk_widget_get_toplevel(d->input);
      zb_secrets_window_present(top != NULL && GTK_IS_WINDOW(top) ? GTK_WINDOW(top) : NULL);
    }
  }
}

void zb_drawer_agent_message(unsigned int win_id, const char *role, const char *text, size_t len) {
  char *copy = g_strndup(text, len);
  for (GList *l = zb_drawers; l != NULL; l = l->next) {
    ZbDrawer *d = l->data;
    if (win_id != 0 && d->win_id != win_id) {
      continue;
    }
    if (d->streaming != NULL && strcmp(role, "assistant") == 0) {
      if (d->stream_full) { /* a capped bubble never shrinks (rev 16.20.13) */
        end_stream_as_shown(d);
      } else {
        end_stream(d, copy);
      }
      continue;
    }
    if (d->streaming != NULL) { /* an error mid-reply: the bubble keeps what it shows */
      char *partial = g_strdup(d->stream_text->str);
      end_stream(d, partial);
      g_free(partial);
    }
    add_message(d, role, copy);
  }
  g_free(copy);
}

/* A coalesced delta: its row, and its text grows the reply's one bubble (S5.1). */
void zb_drawer_agent_delta(unsigned int win_id, const char *session, const char *text, size_t len) {
  for (GList *l = zb_drawers; l != NULL; l = l->next) {
    ZbDrawer *d = l->data;
    if (d->win_id == win_id) {
      if (d->stream_full) { /* the bubble shows no more of this reply, and its row says so */
        continue;
      }
      size_t keep = zb_drawer_row_text_len(text, len);
      char *capped = g_strdup_printf("%.*s%s", (int)keep, text, keep < len ? "…" : "");
      drawer_row(d, "delta", session, capped, NULL);
      g_free(capped);
      size_t before = d->stream_text->len;
      stream_append(d, text, len);
      if (d->streaming == NULL) {
        d->streaming = new_bubble(d, "assistant", d->stream_text->str);
      } else if (d->stream_text->len != before) {
        stream_changed(d);
      }
    }
  }
}

/* The helper capped window `win_id`'s reply (reply_capped): its bubble ends with the
 * marker and shows no more of it. */
void zb_drawer_agent_capped(unsigned int win_id) {
  for (GList *l = zb_drawers; l != NULL; l = l->next) {
    ZbDrawer *d = l->data;
    if (d->win_id == win_id && d->streaming != NULL && !d->stream_full) {
      stream_cap(d);
      stream_changed(d);
    }
  }
}

/* Window `win_id`'s reply ended (its result) without a message ending its bubble: the
 * bubble keeps what it streamed, and the next reply starts its own (rev 16.20.13). */
void zb_drawer_agent_end(unsigned int win_id) {
  for (GList *l = zb_drawers; l != NULL; l = l->next) {
    ZbDrawer *d = l->data;
    if (d->win_id == win_id && d->streaming != NULL) {
      end_stream_as_shown(d);
    }
  }
}

/* The window's reply was stopped (S5.2): its bubble keeps what it showed and ends
 * with "(stopped)"; with nothing shown yet, the bubble is just that. */
void zb_drawer_agent_stopped(unsigned int win_id) {
  for (GList *l = zb_drawers; l != NULL; l = l->next) {
    ZbDrawer *d = l->data;
    if (d->win_id != win_id) {
      continue;
    }
    if (d->streaming == NULL) {
      add_message(d, "assistant", ZB_STOPPED_TEXT);
      continue;
    }
    GString *text = g_string_new(d->stream_text->str);
    if (text->len > 0 && text->str[text->len - 1] != ' ') {
      g_string_append_c(text, ' ');
    }
    g_string_append(text, ZB_STOPPED_TEXT);
    end_stream(d, text->str);
    g_string_free(text, TRUE);
  }
}

static void on_stop_clicked(GtkButton *button, gpointer data) {
  (void)button;
  ZbDrawer *d = data;
  zb_agent_helper_interrupt(d->win_id);
  gtk_widget_grab_focus(d->input); /* Stop greys out: the next prompt is typed at once */
}

/* Send: the user's bubble, then the agent (agent_helper.c): with a provisioned
 * agent home it takes the owner lock, starts netd, fetches the token (the
 * Secrets window opens without one) and starts the helper, which answers. */
static void send_input(ZbDrawer *d) {
  GtkTextBuffer *buffer = gtk_text_view_get_buffer(GTK_TEXT_VIEW(d->input));
  GtkTextIter start, end;
  gtk_text_buffer_get_bounds(buffer, &start, &end);
  char *text = gtk_text_buffer_get_text(buffer, &start, &end, FALSE);
  g_strstrip(text);
  if (text[0] != '\0') {
    add_message(d, "user", text);
    if (zb_agent_helper_configured()) {
      zb_agent_helper_send(d->win_id, text);
    } else { /* no provisioned agent home (app.zig): the same as a missing runtime (S5.5) */
      zb_drawer_agent_status(d->win_id, "unavailable", "runtime-missing");
      add_message(d, "system", ZB_AGENT_TEXT_RUNTIME);
    }
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
  zb_agent_tools_drawer_showing(d->win_id, 1); /* decision 16: interactive, not headless */
  d->scroll_reported[0] = '\0';
  gtk_widget_hide(d->icon);
  gtk_widget_show(d->catcher);
  gtk_widget_grab_focus(d->input);
  zb_agent_helper_prepare(d->win_id);
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
  ZbDrawerRect stop = widget_rect(d, d->stop);
  drawer_rect_row(d, "stop", &stop);
  if (d->account != NULL) {
    ZbDrawerRect account = widget_rect(d, d->account);
    drawer_rect_row(d, "account", &account);
  }
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
  zb_agent_tools_drawer_showing(d->win_id, 0); /* decision 16: from now on, headless */
  d->anim_from = widget_rect(d, d->panel);
  d->anim_rect = d->anim_from;
  d->anim_frames = 0;
  d->anim_start = 0;
  memset(&d->fold_reported, 0, sizeof d->fold_reported);
  gtk_widget_hide(d->catcher);
  gtk_widget_show(d->ghost);
  d->tick_id = gtk_widget_add_tick_callback(d->host, on_anim_tick, d, NULL);
}

static void on_minus_clicked(GtkButton *button, gpointer data) {
  (void)button;
  drawer_minimize(data);
}

/* --- S8 decision 16 part 3: navigate and reload cards (plan rev 16.20.56) ------------------
 * A card waits only in the main window's drawer. The broker's worker shows it and ends it
 * (agent_tools.zig); each hops here on an idle. Approve and Deny are the cards' only
 * native callers. */

typedef struct {
  guint64 id;
  guint32 win; /* the main window whose drawer holds it */
  GtkWidget *buttons, *approve, *deny, *box;
} ZbCard; /* waiting or approved: an ended card is freed */

static GList *zb_cards = NULL; /* GTK thread */

static ZbDrawer *drawer_of(guint32 win) {
  for (GList *l = zb_drawers; l != NULL; l = l->next) {
    ZbDrawer *d = l->data;
    if (d->win_id == win) {
      return d;
    }
  }
  return NULL;
}

static ZbCard *card_of(guint64 id) {
  for (GList *l = zb_cards; l != NULL; l = l->next) {
    ZbCard *c = l->data;
    if (c->id == id) {
      return c;
    }
  }
  return NULL;
}

static void card_row(ZbDrawer *d, const char *kind, guint64 id, const char *a, const char *b) {
  char win[16], card[24];
  g_snprintf(win, sizeof win, "%u", d->win_id);
  g_snprintf(card, sizeof card, "%" G_GUINT64_FORMAT, id);
  const char *fields[] = {win, kind, card, a, b};
  zb_emit_protocol_row(d->e2e, "DRAWER", fields, b != NULL ? 5 : 4);
}

/* `approvalrect <card> approve|deny <rect>` once per new place, so a test's X click can aim. */
static gboolean on_card_button_drawn(GtkWidget *widget, cairo_t *cr, gpointer data) {
  (void)cr;
  ZbCard *c = data;
  ZbDrawer *d = drawer_of(c->win);
  if (d == NULL) {
    return FALSE;
  }
  ZbDrawerRect r = widget_rect(d, widget);
  ZbDrawerRect *last = g_object_get_data(G_OBJECT(widget), "zb-card-rect");
  if (last != NULL && memcmp(last, &r, sizeof r) == 0) {
    return FALSE;
  }
  g_object_set_data_full(G_OBJECT(widget), "zb-card-rect", g_memdup2(&r, sizeof r), g_free);
  char rect[64];
  root_rect_text(d, &r, rect, sizeof rect);
  card_row(d, "approvalrect", c->id, widget == c->approve ? "approve" : "deny", rect);
  return FALSE;
}

/* The card's buttons give way to its outcome's words. */
static void card_settle(ZbCard *c, const char *words) {
  gtk_widget_set_sensitive(c->approve, FALSE);
  gtk_widget_set_sensitive(c->deny, FALSE);
  if (words != NULL) {
    gtk_widget_hide(c->buttons);
    GtkWidget *label = gtk_label_new(words);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_style_context_add_class(gtk_widget_get_style_context(label), "zb-msg");
    gtk_container_add(GTK_CONTAINER(c->box), label);
    gtk_widget_show(label);
  }
}

static void on_card_approve(GtkButton *button, gpointer data) {
  (void)button;
  ZbCard *c = data;
  ZbDrawer *d = drawer_of(c->win);
  if (d == NULL || !zb_agent_tools_approve(c->id)) {
    return;
  }
  card_row(d, "approvalstate", c->id, "approved", NULL);
  card_settle(c, NULL);
}

static void on_card_deny(GtkButton *button, gpointer data) {
  (void)button;
  ZbCard *c = data;
  if (zb_agent_tools_deny(c->id)) {
    card_settle(c, NULL); /* its approvalend comes with the broker's ending */
  }
}

typedef struct {
  guint32 main, bound;
  guint64 id;
  char *verb, *params, *url, *origin; /* origin: the document the card describes (phase A) */
  size_t params_len;
} ZbCardShow;

static gboolean card_show_idle(gpointer data) {
  ZbCardShow *s = data;
  ZbDrawer *d = drawer_of(s->main);
  if (d != NULL) {
    char *digest = g_compute_checksum_for_data(G_CHECKSUM_SHA256, (const guchar *)s->params, s->params_len);
    char *text;
    if (strcmp(s->verb, "navigate") == 0) {
      text = g_strdup_printf("Claude wants to open %s in window %u.", s->url != NULL ? s->url : "", s->bound);
    } else if (strcmp(s->verb, "reload") == 0) {
      text = g_strdup_printf("Claude wants to reload window %u.", s->bound);
    } else if (strcmp(s->verb, "click") == 0) {
      text = g_strdup_printf("Claude wants to click on the page in window %u.", s->bound);
    } else if (strcmp(s->verb, "type_text") == 0) {
      text = g_strdup_printf("Claude wants to type text in window %u.", s->bound);
    } else if (strcmp(s->verb, "press_key") == 0) {
      text = g_strdup_printf("Claude wants to press a key in window %u.", s->bound);
    } else if (strcmp(s->verb, "select_option") == 0) {
      text = g_strdup_printf("Claude wants to choose an option in window %u.", s->bound);
    } else {
      text = g_strdup_printf("Claude wants to use the page in window %u.", s->bound);
    }
    char win[16], card[24];
    g_snprintf(win, sizeof win, "%u", d->win_id);
    g_snprintf(card, sizeof card, "%" G_GUINT64_FORMAT, s->id);
    const char *fields[] = {win, "approval", card, s->verb, s->origin, "-", digest};
    zb_emit_protocol_row(d->e2e, "DRAWER", fields, 7);

    ZbCard *c = g_new0(ZbCard, 1);
    c->id = s->id;
    c->win = d->win_id;
    c->box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_container_add(GTK_CONTAINER(c->box), bubble_widget(d, "approval", text, strlen(text)));
    c->buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    c->approve = gtk_button_new_with_label("Approve");
    c->deny = gtk_button_new_with_label("Deny");
    gtk_container_add(GTK_CONTAINER(c->buttons), c->approve);
    gtk_container_add(GTK_CONTAINER(c->buttons), c->deny);
    gtk_container_add(GTK_CONTAINER(c->box), c->buttons);
    g_signal_connect(c->approve, "clicked", G_CALLBACK(on_card_approve), c);
    g_signal_connect(c->deny, "clicked", G_CALLBACK(on_card_deny), c);
    g_signal_connect_after(c->approve, "draw", G_CALLBACK(on_card_button_drawn), c);
    g_signal_connect_after(c->deny, "draw", G_CALLBACK(on_card_button_drawn), c);
    gtk_container_add(GTK_CONTAINER(d->list), c->box);
    gtk_widget_show_all(gtk_widget_get_parent(c->box)); /* its GtkListBoxRow */
    zb_cards = g_list_prepend(zb_cards, c);
    bubble_row(d, "approval", text);
    g_free(text);
    g_free(digest);
  }
  g_free(s->verb);
  g_free(s->params);
  g_free(s->url);
  g_free(s->origin);
  g_free(s);
  return G_SOURCE_REMOVE;
}

/* Any thread (a broker's worker): card `id` for window `bound`'s call, in window `main`'s drawer. */
void zb_drawer_card_show(unsigned int main, guint64 id, const char *verb, unsigned int bound, const char *params,
                         size_t params_len, const char *url, const char *origin) {
  ZbCardShow *s = g_new0(ZbCardShow, 1);
  s->main = main;
  s->bound = bound;
  s->id = id;
  s->verb = g_strdup(verb);
  s->params = g_strndup(params, params_len);
  s->params_len = params_len;
  s->url = g_strdup(url);
  s->origin = g_strdup(origin);
  g_idle_add(card_show_idle, s);
}

typedef struct {
  guint64 id;
  char *ending;
} ZbCardEnd;

static const char *ending_words(const char *ending) {
  return strcmp(ending, "done") == 0      ? "Done."
         : strcmp(ending, "failed") == 0  ? "Approved, but the browser could not do it."
         : strcmp(ending, "denied") == 0  ? "Denied. Nothing was opened."
         : strcmp(ending, "expired") == 0 ? "Not approved in time. Nothing was opened."
         : strcmp(ending, "changed") == 0 ? "The page changed after you approved. Nothing was opened."
         : strcmp(ending, "crashed") == 0 ? "The page crashed. Nothing was opened."
                                          : "Cancelled: its window closed. Nothing was opened.";
}

static gboolean card_end_idle(gpointer data) {
  ZbCardEnd *e = data;
  ZbCard *c = card_of(e->id);
  ZbDrawer *d = c != NULL ? drawer_of(c->win) : NULL;
  if (c != NULL) {
    if (d != NULL) { /* else the main window closed, and the card's widgets with it */
      card_row(d, "approvalend", c->id, e->ending, NULL);
      card_settle(c, ending_words(e->ending));
      g_signal_handlers_disconnect_by_data(c->approve, c);
      g_signal_handlers_disconnect_by_data(c->deny, c);
    }
    /* An ended card is done with: its words stay in the list, its record goes (RoseCat f87368e). */
    zb_cards = g_list_remove(zb_cards, c);
    g_free(c);
  }
  g_free(e->ending);
  g_free(e);
  return G_SOURCE_REMOVE;
}

/* Any thread: card `id`'s one ending (D7b's approvalend outcome). */
void zb_drawer_card_end(guint64 id, const char *ending) {
  ZbCardEnd *e = g_new0(ZbCardEnd, 1);
  e->id = id;
  e->ending = g_strdup(ending);
  g_idle_add(card_end_idle, e);
}

typedef struct {
  guint32 win;
  char *text;
} ZbSystemLine;

static gboolean system_line_idle(gpointer data) {
  ZbSystemLine *m = data;
  zb_drawer_agent_message(m->win, "system", m->text, strlen(m->text));
  g_free(m->text);
  g_free(m);
  return G_SOURCE_REMOVE;
}

/* Any thread: a system line in window `win`'s drawer (the unreadable store). */
void zb_drawer_post_system(unsigned int win, const char *text, size_t len) {
  ZbSystemLine *m = g_new0(ZbSystemLine, 1);
  m->win = win;
  m->text = g_strndup(text, len);
  g_idle_add(system_line_idle, m);
}

/* The desktop notification: org.freedesktop.Notifications on the session bus. It carries only
 * fixed text and one `default` action; its activation, only by the server that answered our
 * Notify, presents the main window and opens its drawer, and changes no card. Any failure (no
 * bus, no server) leaves the card waiting. */
#define ZB_NOTIFY_NAME "org.freedesktop.Notifications"
#define ZB_NOTIFY_PATH "/org/freedesktop/Notifications"

static GDBusConnection *zb_notify_bus = NULL;
static int zb_notify_state = 0;          /* 0 not tried, 1 connecting, 2 connected, 3 failed */
static GHashTable *zb_notify_owner = NULL; /* our notification id -> the unique name that gave it */
static GQueue zb_notify_pending = G_QUEUE_INIT; /* (title, body) pairs waiting for the bus */

static void on_notify_action(GDBusConnection *bus, const char *sender, const char *path, const char *iface,
                             const char *signal, GVariant *params, gpointer data) {
  (void)bus, (void)path, (void)iface, (void)signal, (void)data;
  if (!g_variant_is_of_type(params, G_VARIANT_TYPE("(us)"))) {
    return;
  }
  guint32 id = 0;
  const char *key = NULL;
  g_variant_get(params, "(u&s)", &id, &key);
  const char *owner = zb_notify_owner != NULL ? g_hash_table_lookup(zb_notify_owner, GUINT_TO_POINTER(id)) : NULL;
  if (strcmp(key, "default") != 0 || owner == NULL || sender == NULL || strcmp(owner, sender) != 0) {
    return;
  }
  unsigned int main = zb_agent_tools_activate();
  ZbDrawer *d = main != 0 ? drawer_of(main) : NULL;
  if (d == NULL) {
    return;
  }
  zb_window_present(main);
  drawer_open(d);
}

static void on_notified(GObject *source, GAsyncResult *result, gpointer data) {
  (void)data;
  GDBusMessage *reply = g_dbus_connection_send_message_with_reply_finish(G_DBUS_CONNECTION(source), result, NULL);
  if (reply == NULL) {
    return;
  }
  GVariant *body = g_dbus_message_get_body(reply);
  if (g_dbus_message_get_message_type(reply) == G_DBUS_MESSAGE_TYPE_METHOD_RETURN && body != NULL &&
      g_variant_is_of_type(body, G_VARIANT_TYPE("(u)")) && g_dbus_message_get_sender(reply) != NULL) {
    guint32 id = 0;
    g_variant_get(body, "(u)", &id);
    if (zb_notify_owner == NULL) {
      zb_notify_owner = g_hash_table_new_full(g_direct_hash, g_direct_equal, NULL, g_free);
    }
    g_hash_table_replace(zb_notify_owner, GUINT_TO_POINTER(id), g_strdup(g_dbus_message_get_sender(reply)));
  }
  g_object_unref(reply);
}

static void notify_send(const char *title, const char *body) {
  GVariantBuilder actions;
  g_variant_builder_init(&actions, G_VARIANT_TYPE("as"));
  g_variant_builder_add(&actions, "s", "default");
  g_variant_builder_add(&actions, "s", "Open zigBrowser");
  GDBusMessage *call = g_dbus_message_new_method_call(ZB_NOTIFY_NAME, ZB_NOTIFY_PATH, ZB_NOTIFY_NAME, "Notify");
  g_dbus_message_set_body(call, g_variant_new("(susssasa{sv}i)", "zigBrowser", 0u, "", title, body, &actions, NULL, -1));
  g_dbus_connection_send_message_with_reply(zb_notify_bus, call, G_DBUS_SEND_MESSAGE_FLAGS_NONE, -1, NULL, NULL,
                                            on_notified, NULL);
  g_object_unref(call);
}

static void notify_flush(void) {
  while (!g_queue_is_empty(&zb_notify_pending)) {
    char *title = g_queue_pop_head(&zb_notify_pending);
    char *body = g_queue_pop_head(&zb_notify_pending);
    if (zb_notify_state == 2) {
      notify_send(title, body);
    }
    g_free(title);
    g_free(body);
  }
}

static void on_notify_bus(GObject *source, GAsyncResult *result, gpointer data) {
  (void)source, (void)data;
  zb_notify_bus = g_bus_get_finish(result, NULL);
  zb_notify_state = zb_notify_bus != NULL ? 2 : 3;
  if (zb_notify_bus != NULL) {
    g_dbus_connection_signal_subscribe(zb_notify_bus, NULL, ZB_NOTIFY_NAME, "ActionInvoked", ZB_NOTIFY_PATH, NULL,
                                       G_DBUS_SIGNAL_FLAGS_NONE, on_notify_action, NULL, NULL);
  }
  notify_flush();
}

typedef struct {
  char *title, *body;
} ZbNotifyText;

static gboolean notify_idle(gpointer data) {
  ZbNotifyText *n = data;
  g_queue_push_tail(&zb_notify_pending, n->title);
  g_queue_push_tail(&zb_notify_pending, n->body);
  g_free(n);
  if (zb_notify_state == 0) {
    zb_notify_state = 1;
    g_bus_get(G_BUS_TYPE_SESSION, NULL, on_notify_bus, NULL);
  } else if (zb_notify_state != 1) {
    notify_flush();
  }
  return G_SOURCE_REMOVE;
}

/* Any thread: one desktop notification for a new card. */
void zb_drawer_card_notify(const char *title, const char *body) {
  ZbNotifyText *n = g_new0(ZbNotifyText, 1);
  n->title = g_strdup(title);
  n->body = g_strdup(body);
  g_idle_add(notify_idle, n);
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

/* Account: the Secrets window, above this browser window, whatever the agent's
 * state (a missing runtime included). */
static void on_account_clicked(GtkButton *button, gpointer data) {
  (void)button;
  ZbDrawer *d = data;
  GtkWidget *top = gtk_widget_get_toplevel(d->panel);
  zb_secrets_window_present(top != NULL && GTK_IS_WINDOW(top) ? GTK_WINDOW(top) : NULL);
}

/* The drawer: header ("Claude Agent", status, Account, '-'), the scrolling message
 * list, "New messages", and the input row (text, Send, Stop). */
static void build_panel(ZbDrawer *d) {
  d->panel = named(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0), "zb-agent-drawer", "Claude Agent");

  GtkWidget *header = named(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8), "zb-agent-header", NULL);
  GtkWidget *title = named(gtk_label_new("Claude Agent"), "zb-agent-title", NULL);
  gtk_label_set_xalign(GTK_LABEL(title), 0);
  GtkWidget *status = named(gtk_label_new("Not connected"), "zb-agent-status", NULL);
  gtk_widget_set_hexpand(status, TRUE);
  gtk_label_set_xalign(GTK_LABEL(status), 0);
  d->status = status;
  report_text(d, status, "status");
  d->minus = named(gtk_button_new_with_label("-"), "zb-agent-minus", "Minimize Claude Agent");
  gtk_widget_set_tooltip_text(d->minus, "Minimize");
  gtk_box_pack_start(GTK_BOX(header), title, FALSE, FALSE, 0);
  gtk_box_pack_start(GTK_BOX(header), status, TRUE, TRUE, 0);
  gtk_box_pack_end(GTK_BOX(header), d->minus, FALSE, FALSE, 0);
  if (zb_secrets_window_configured()) {
    d->account = named(gtk_button_new_with_label("Account"), "zb-agent-account", "Account");
    gtk_widget_set_tooltip_text(d->account, "Claude Agent account");
    gtk_box_pack_end(GTK_BOX(header), d->account, FALSE, FALSE, 0);
  }

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

  /* Every part is shown inside the panel; its catcher stays hidden until
   * the drawer is opened (the window's show_all must not show it). The
   * catcher's input-only window lies under the panel's own widgets. */
  gtk_widget_show_all(d->panel);
  d->catcher = gtk_event_box_new();
  gtk_event_box_set_visible_window(GTK_EVENT_BOX(d->catcher), FALSE);
  gtk_widget_add_events(d->catcher, GDK_SCROLL_MASK | GDK_SMOOTH_SCROLL_MASK | GDK_POINTER_MOTION_MASK);
  gtk_container_add(GTK_CONTAINER(d->catcher), d->panel);
  gtk_widget_set_no_show_all(d->catcher, TRUE);

  report_focus(d, d->input, "input");
  report_focus(d, d->send, "send");
  report_focus(d, d->stop, "stop");
  report_focus(d, d->minus, "minus");
  if (d->account != NULL) {
    report_focus(d, d->account, "account");
    g_signal_connect(d->account, "clicked", G_CALLBACK(on_account_clicked), d);
  }
  g_signal_connect(d->list, "set-focus-child", G_CALLBACK(on_list_focus_child), d);
  g_signal_connect(d->minus, "clicked", G_CALLBACK(on_minus_clicked), d);
  g_signal_connect(d->send, "clicked", G_CALLBACK(on_send_clicked), d);
  g_signal_connect(d->stop, "clicked", G_CALLBACK(on_stop_clicked), d);
  g_signal_connect(d->unread, "clicked", G_CALLBACK(on_unread_clicked), d);
  g_signal_connect(d->input, "key-press-event", G_CALLBACK(on_input_key), d);
  g_signal_connect(d->vadj, "changed", G_CALLBACK(on_list_changed), d);
  g_signal_connect(d->vadj, "value-changed", G_CALLBACK(on_list_scrolled), d);
  g_signal_connect_after(d->scroller, "size-allocate", G_CALLBACK(on_scroller_allocated), d);
  /* On the catcher: shown again at the same size, it is allocated again,
   * while GTK skips the unchanged panel inside it. */
  g_signal_connect_after(d->catcher, "size-allocate", G_CALLBACK(on_panel_allocated), d);

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
  d->stream_text = g_string_new(NULL);

  /* The page, then the floats in drawing order (D2-D5). */
  d->host = drawer_host_new(d);
  gtk_container_add(GTK_CONTAINER(d->host), view);
  build_icon(d);
  gtk_container_add(GTK_CONTAINER(d->host), d->icon);
  build_panel(d);
  drawer_host_add_dock(d->host, d->catcher);
  /* A no-window box: the stand-in draws its CSS background only. */
  d->ghost = named(gtk_box_new(GTK_ORIENTATION_VERTICAL, 0), "zb-agent-ghost", NULL);
  gtk_widget_set_no_show_all(d->ghost, TRUE);
  g_signal_connect(d->ghost, "draw", G_CALLBACK(on_ghost_draw), d);
  gtk_container_add(GTK_CONTAINER(d->host), d->ghost);

  /* The e2e-only seed (plan S2.3): system messages to scroll through. */
  unsigned int demo = zb_drawer_demo_messages();
  for (unsigned int i = 1; i <= demo; ++i) {
    char text[64];
    g_snprintf(text, sizeof text, "Demo message %u of %u", i, demo);
    add_message(d, "system", text);
  }

  g_signal_connect_after(d->host, "size-allocate", G_CALLBACK(on_host_allocated), d);
  g_signal_connect_after(d->host, "draw", G_CALLBACK(on_host_drawn), d);
  g_signal_connect(toplevel, "key-press-event", G_CALLBACK(on_window_key), d);

  gtk_container_add(GTK_CONTAINER(toplevel), d->host);
  /* The page keeps the window's keyboard focus, as without the drawer; the
   * icon is reached with Tab (D4). */
  gtk_window_set_focus(GTK_WINDOW(toplevel), view);
  g_atomic_int_inc(&zb_drawer_live);
  zb_drawers = g_list_prepend(zb_drawers, d);
  return d;
}

void zb_drawer_detach(ZbDrawer *d) {
  if (d == NULL) {
    return;
  }
  zb_agent_helper_window_closed(d->win_id); /* end_session for this window only */
  if (d->tick_id != 0) {
    gtk_widget_remove_tick_callback(d->host, d->tick_id);
  }
  GObject *connected[] = {G_OBJECT(d->toplevel), G_OBJECT(d->host), G_OBJECT(d->icon),   G_OBJECT(d->panel),
                          G_OBJECT(d->catcher),
                          G_OBJECT(d->minus),    G_OBJECT(d->list),    G_OBJECT(d->unread), G_OBJECT(d->input),
                          G_OBJECT(d->send),     G_OBJECT(d->stop),    G_OBJECT(d->vadj),   G_OBJECT(d->scroller),
                          G_OBJECT(d->ghost)};
  for (size_t i = 0; i < G_N_ELEMENTS(connected); ++i) {
    g_signal_handlers_disconnect_by_data(connected[i], d);
  }
  if (d->account != NULL) {
    g_signal_handlers_disconnect_by_data(d->account, d);
  }
  g_atomic_int_add(&zb_drawer_live, -1);
  zb_drawers = g_list_remove(zb_drawers, d);
  g_free(d->windows_reported);
  stream_idle_cancel(d);
  g_string_free(d->stream_text, TRUE);
  g_free(d);
}
