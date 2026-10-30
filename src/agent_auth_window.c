/* The auth window's GTK body (chat-drawer plan S6b2; rev 16.18.15-16.18.20). See agent_auth_window.h.
 *
 * - A native GtkWindow titled "Sign in to Claude" with a WebKitWebView on its own ephemeral
 *   WebKitWebContext (never a related view: no shared web process or data store), its own empty
 *   user content manager (no zbHost, no automation script, no drawer), and the hardware and media
 *   policies and the Safari identity every browsing window gets (zb_apply_view_policies, webkit_shim.c).
 * - Under --e2e-protocol, an accepted ZIGBROWSER_AGENT_AUTH_TEST gives that context a custom proxy
 *   (no ignore hosts) and allows the seam's certificate for claude.com and platform.claude.com only.
 * - Every navigation goes through zb_auth_decide (agent_auth.decideNavigation): allow (loads;
 *   `AUTH allowed <origin>`) or block (ignored; `AUTH blocked <reason>` and its stderr line; the
 *   window stays). A would-be capture (rev 16.20.33) becomes the one pending callback and is let
 *   through, because only a response can tell the main frame from a subframe: its response, via
 *   zb_auth_respond (agent_auth.decideResponse), is ignored either way (the code page is never
 *   committed) and captures only in the main frame and only as that exact pending callback
 *   (`AUTH captured`; the code goes to the caller once; the window closes); a subframe's is
 *   `AUTH blocked subframe`, any other main-frame callback `unexpected`, a second different
 *   callback while one is pending `pending`. A new window is refused (`AUTH blocked popup`).
 * - Closing it by hand writes nothing; the sign-in keeps waiting for a pasted code. */
#include "agent_auth_window.h"

#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>
#include <webkit2/webkit2.h>

#include "agent_drawer.h" /* zb_emit_protocol_row */

/* webkit_shim.c (BlackRobin 6436): the policies every browsing window gets. Declared here, since
 * webkit_shim.h is shared by every backend. */
void zb_apply_view_policies(WebKitWebView *view);

/* agent_login.zig */
int zb_auth_seam(int e2e, const char *value, unsigned short *port, char *ca, size_t ca_cap, char *line,
                 size_t line_cap);
int zb_auth_decide(const char *authorize, const char *nav, int captured, char *out, size_t cap);
int zb_auth_respond(const char *authorize, const char *pending, const char *response, int main_frame, int captured,
                    char *out, size_t cap);

#define TITLE "Sign in to Claude"
#define SEAM_ENV "ZIGBROWSER_AGENT_AUTH_TEST"

static struct {
  GtkWidget *window;
  char *authorize_url;
  /* The one pending callback (rev 16.20.33): the exact URI of a navigation decideNavigation would
   * capture, let through so its RESPONSE (where WebKit tells the main frame from a subframe)
   * decides. Never overwritten by a different one; cleared by its response or the close. */
  char *pending;
  int e2e;
  int captured;
  ZbAuthCaptured on_capture;
  void *data;
} aw;

static void auth_row(const char *a, const char *b) {
  const char *fields[] = {a, b};
  zb_emit_protocol_row(aw.e2e, "AUTH", fields, b != NULL ? 2 : 1);
}

static void on_destroy(GtkWidget *widget, gpointer unused) {
  (void)widget;
  (void)unused;
  aw.window = NULL;
  g_free(aw.authorize_url);
  aw.authorize_url = NULL;
  g_free(aw.pending);
  aw.pending = NULL;
}

/* A refusal: the row and the fixed stderr line, the reason word only (never the URL, the code or
 * the state; rev 16.18; RoseCat 6457 #2). */
static void blocked(const char *reason) {
  auth_row("blocked", reason);
  g_printerr("zigBrowser: agent auth: callback rejected (%s)\n", reason);
}

/* `AUTH view hw <never|always|on-demand>` (e2e only; rev 16.20.33, RoseCat 6457 #3): the auth
 * view's hardware policy, read back from its own settings after zb_apply_view_policies. */
static void auth_view_hw_row(WebKitWebView *view) {
  WebKitSettings *settings = webkit_web_view_get_settings(view);
  if (settings == NULL) {
    return;
  }
  const char *hw = "on-demand";
  switch (webkit_settings_get_hardware_acceleration_policy(settings)) {
    case WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER:
      hw = "never";
      break;
    case WEBKIT_HARDWARE_ACCELERATION_POLICY_ALWAYS:
      hw = "always";
      break;
    default:
      break;
  }
  const char *fields[] = {"view", "hw", hw};
  zb_emit_protocol_row(aw.e2e, "AUTH", fields, 3);
}

static gboolean close_later(gpointer unused) {
  (void)unused;
  zb_auth_window_close();
  return G_SOURCE_REMOVE;
}

/* A response (rev 16.20.33): agent_auth.decideResponse with the pending record and WebKit's
 * main-frame flag. Pass: WebKit's default. Capture: the response is ignored (the code page is
 * never committed), the code goes to the sign-in once, the window closes. Block: ignored before
 * commit; a subframe's refusal clears only a pending record that is its own. */
static gboolean on_response(WebKitResponsePolicyDecision *decision) {
  WebKitURIRequest *request = webkit_response_policy_decision_get_request(decision);
  const char *uri = request != NULL ? webkit_uri_request_get_uri(request) : NULL;
  if (uri == NULL || aw.authorize_url == NULL) {
    return FALSE;
  }
  int main_frame = webkit_response_policy_decision_is_main_frame_main_resource(decision) ? 1 : 0;
  char out[640];
  int kind = zb_auth_respond(aw.authorize_url, aw.pending, uri, main_frame, aw.captured, out, sizeof out);
  if (kind == 0) {
    return FALSE;
  }
  webkit_policy_decision_ignore(WEBKIT_POLICY_DECISION(decision));
  if (kind == 1) {
    aw.captured = 1;
    g_free(aw.pending);
    aw.pending = NULL;
    auth_row("captured", NULL);
    if (aw.on_capture != NULL) {
      aw.on_capture(out, aw.data);
    }
    explicit_bzero(out, sizeof out);
    g_idle_add(close_later, NULL); /* not from inside WebKit's own signal */
    return TRUE;
  }
  if (strcmp(out, "subframe") == 0 && aw.pending != NULL && strcmp(aw.pending, uri) == 0) {
    g_free(aw.pending);
    aw.pending = NULL;
  }
  blocked(out[0] != '\0' ? out : "unexpected");
  return TRUE;
}

static gboolean on_decide_policy(WebKitWebView *view, WebKitPolicyDecision *decision,
                                 WebKitPolicyDecisionType type, gpointer unused) {
  (void)view;
  (void)unused;
  if (type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION) {
    auth_row("blocked", "popup");
    webkit_policy_decision_ignore(decision);
    return TRUE;
  }
  if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
    return on_response(WEBKIT_RESPONSE_POLICY_DECISION(decision));
  }
  if (type != WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
    return FALSE;
  }
  WebKitNavigationPolicyDecision *nav = WEBKIT_NAVIGATION_POLICY_DECISION(decision);
  WebKitNavigationAction *action = webkit_navigation_policy_decision_get_navigation_action(nav);
  WebKitURIRequest *request = webkit_navigation_action_get_request(action);
  const char *uri = request != NULL ? webkit_uri_request_get_uri(request) : NULL;
  if (uri == NULL || aw.authorize_url == NULL) {
    webkit_policy_decision_ignore(decision);
    return TRUE;
  }
  char out[640];
  int kind = zb_auth_decide(aw.authorize_url, uri, aw.captured, out, sizeof out);
  if (kind == 0) {
    auth_row("allowed", out);
    webkit_policy_decision_use(decision);
    return TRUE;
  }
  if (kind == 1) {
    /* A capture at this point could be a subframe's (rev 16.20.33): send nothing yet; record it as
     * the one pending callback and let it through, so its response decides. */
    explicit_bzero(out, sizeof out);
    if (aw.pending != NULL && strcmp(aw.pending, uri) != 0) {
      webkit_policy_decision_ignore(decision);
      blocked("pending");
      return TRUE;
    }
    if (aw.pending == NULL) {
      aw.pending = g_strdup(uri);
    }
    webkit_policy_decision_use(decision);
    return TRUE;
  }
  webkit_policy_decision_ignore(decision);
  blocked(out[0] != '\0' ? out : "origin");
  return TRUE;
}

static GtkWidget *on_create(WebKitWebView *view, WebKitNavigationAction *action, gpointer unused) {
  (void)view;
  (void)action;
  (void)unused;
  auth_row("blocked", "popup");
  return NULL; /* no new window */
}

int zb_auth_window_open(const char *authorize_url, int e2e_protocol, ZbAuthCaptured on_capture, void *data) {
  zb_auth_window_close();
  aw.e2e = e2e_protocol;
  unsigned short port = 0;
  char ca[4096];
  char line[256];
  int seam = zb_auth_seam(e2e_protocol, getenv(SEAM_ENV), &port, ca, sizeof ca, line, sizeof line);
  if (line[0] != '\0') {
    g_printerr("%s\n", line);
  }
  GTlsCertificate *cert = NULL;
  if (seam == 3) {
    GError *error = NULL;
    cert = g_tls_certificate_new_from_file(ca, &error);
    if (cert == NULL) { /* a file the TLS library cannot load: also `ca` (rev 16.18.15) */
      g_printerr("zigBrowser: " SEAM_ENV " refused (ca)\n");
      g_clear_error(&error);
      seam = 2;
    }
  }
  if (seam == 2) {
    auth_row("blocked", "seam");
    return -1;
  }

  WebKitWebsiteDataManager *manager = webkit_website_data_manager_new_ephemeral();
  if (seam == 3) {
    char proxy[64];
    g_snprintf(proxy, sizeof proxy, "http://127.0.0.1:%u", (unsigned)port);
    WebKitNetworkProxySettings *settings = webkit_network_proxy_settings_new(proxy, NULL);
    webkit_website_data_manager_set_network_proxy_settings(manager, WEBKIT_NETWORK_PROXY_MODE_CUSTOM, settings);
    webkit_network_proxy_settings_free(settings);
  }
  WebKitWebContext *context = webkit_web_context_new_with_website_data_manager(manager);
  g_object_unref(manager);
  if (cert != NULL) {
    webkit_web_context_allow_tls_certificate_for_host(context, cert, "claude.com");
    webkit_web_context_allow_tls_certificate_for_host(context, cert, "platform.claude.com");
    g_object_unref(cert);
  }
  WebKitUserContentManager *ucm = webkit_user_content_manager_new();
  WebKitWebView *view = WEBKIT_WEB_VIEW(
      g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", context, "user-content-manager", ucm, NULL));
  g_object_unref(ucm);
  g_object_unref(context);
  zb_apply_view_policies(view);
  auth_view_hw_row(view);

  aw.authorize_url = g_strdup(authorize_url);
  g_free(aw.pending);
  aw.pending = NULL;
  aw.captured = 0;
  aw.on_capture = on_capture;
  aw.data = data;
  aw.window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_title(GTK_WINDOW(aw.window), TITLE);
  gtk_window_set_default_size(GTK_WINDOW(aw.window), 520, 640);
  gtk_container_add(GTK_CONTAINER(aw.window), GTK_WIDGET(view));
  g_signal_connect(view, "decide-policy", G_CALLBACK(on_decide_policy), NULL);
  g_signal_connect(view, "create", G_CALLBACK(on_create), NULL);
  g_signal_connect(aw.window, "destroy", G_CALLBACK(on_destroy), NULL);
  gtk_widget_show_all(aw.window);
  webkit_web_view_load_uri(view, authorize_url);
  return 0;
}

void zb_auth_window_close(void) {
  if (aw.window != NULL) {
    GtkWidget *w = aw.window;
    aw.window = NULL;
    gtk_widget_destroy(w);
  }
}
