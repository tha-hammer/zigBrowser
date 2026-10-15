/* The Secret Service backend of the Claude Agent's token store (plan D11;
 * see agent_secrets.h). libsecret is loaded with dlopen("libsecret-1.so.0")
 * because the build host has no libsecret dev headers; SecretSchema is
 * declared here with libsecret's stable ABI (since 0.7). */

#include "agent_secrets.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <gio/gio.h>
#include <stdio.h>
#include <string.h>

/* libsecret's SecretSchema (secret-schema.h): a name, flags, up to 32
 * attributes ending with a NULL name, then private padding. */
typedef struct {
  const gchar *name;
  int type; /* SecretSchemaAttributeType: 0 = string */
} ZbSecretSchemaAttribute;

typedef struct {
  const gchar *name;
  int flags; /* SecretSchemaFlags: 0 = none (the xdg:schema attribute is matched) */
  ZbSecretSchemaAttribute attributes[32];
  gint reserved;
  gpointer reserved1, reserved2, reserved3, reserved4, reserved5, reserved6, reserved7;
} ZbSecretSchema;

/* tests/agent_secrets_dlopen_test.c builds this file with a name that does
 * not exist, to drive the load failure (the browser links WebKitGTK, which
 * loads libsecret itself, so there the dlopen always finds it). */
#ifndef ZB_LIBSECRET_SONAME
#define ZB_LIBSECRET_SONAME "libsecret-1.so.0"
#endif

static const ZbSecretSchema zb_token_schema = {
    "dev.zigbrowser.ClaudeAgentToken", 0, {{"account", 0}, {NULL, 0}}, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL};
#define ZB_TOKEN_ACCOUNT "default"
#define ZB_TOKEN_LABEL "zigBrowser Claude Agent token"

typedef gboolean (*StorevSync)(const ZbSecretSchema *, GHashTable *, const gchar *, const gchar *, const gchar *,
                               GCancellable *, GError **);
typedef gchar *(*LookupvSync)(const ZbSecretSchema *, GHashTable *, GCancellable *, GError **);
typedef gboolean (*ClearvSync)(const ZbSecretSchema *, GHashTable *, GCancellable *, GError **);
typedef void (*PasswordFree)(gchar *);

static struct {
  int loaded; /* 1 loaded, -1 failed */
  StorevSync storev;
  LookupvSync lookupv;
  ClearvSync clearv;
  PasswordFree password_free;
} ss;

static GMutex ss_lock;

/* ZIGBROWSER_AGENT_SECRETS_TEST_DELAY (--e2e-protocol only): each Secret
 * Service answer is held back this long after the call, so a test can make
 * an old answer land late (RoseCat 5648). Zero in production. */
static guint delay_lookup_ms, delay_store_ms, delay_clear_ms;

void zb_secrets_set_test_delay(unsigned lookup_ms, unsigned store_ms, unsigned clear_ms) {
  delay_lookup_ms = lookup_ms;
  delay_store_ms = store_ms;
  delay_clear_ms = clear_ms;
}

static void hold_back(guint ms) {
  if (ms > 0) {
    g_usleep((gulong)ms * 1000);
  }
}

/* Loads libsecret once. The handle is never closed: libsecret keeps
 * threads and D-Bus state that must outlive any one call. */
static int ss_load(void) {
  g_mutex_lock(&ss_lock);
  if (ss.loaded == 0) {
    void *lib = dlopen(ZB_LIBSECRET_SONAME, RTLD_NOW | RTLD_LOCAL);
    if (lib != NULL) {
      ss.storev = (StorevSync)dlsym(lib, "secret_password_storev_sync");
      ss.lookupv = (LookupvSync)dlsym(lib, "secret_password_lookupv_sync");
      ss.clearv = (ClearvSync)dlsym(lib, "secret_password_clearv_sync");
      ss.password_free = (PasswordFree)dlsym(lib, "secret_password_free");
    }
    ss.loaded = (lib != NULL && ss.storev && ss.lookupv && ss.clearv && ss.password_free) ? 1 : -1;
    if (ss.loaded < 0) {
      fprintf(stderr, "zigBrowser: agent secrets: libsecret is not available\n");
    }
  }
  int ok = ss.loaded > 0;
  g_mutex_unlock(&ss_lock);
  return ok;
}

static GHashTable *token_attributes(void) {
  GHashTable *attrs = g_hash_table_new(g_str_hash, g_str_equal);
  g_hash_table_insert(attrs, (gpointer) "account", (gpointer)ZB_TOKEN_ACCOUNT);
  return attrs;
}

/* A failure is reported by its GError domain and code only: no message
 * text, which could in principle quote what was sent. */
static void report(const char *what, GError *error) {
  if (error != NULL) {
    fprintf(stderr, "zigBrowser: agent secrets: secret service %s failed (%s %d)\n", what,
            g_quark_to_string(error->domain), error->code);
  }
}

static void wipe_free(char *text) {
  if (text != NULL) {
    explicit_bzero(text, strlen(text));
    g_free(text);
  }
}

void zb_secrets_free(char *token) { wipe_free(token); }

/* --- one call per worker thread -------------------------------------------- */

typedef struct {
  char *token; /* store: the copy to store; lookup: the result */
  ZbSecretsDone done;
  ZbSecretsLookupDone lookup_done;
  gpointer data;
  ZbSecretsResult result;
} SsCall;

static void ss_call_free(gpointer p) {
  SsCall *call = p;
  wipe_free(call->token);
  g_free(call);
}

static void store_thread(GTask *task, gpointer source, gpointer task_data, GCancellable *cancellable) {
  (void)source;
  (void)cancellable;
  SsCall *call = task_data;
  call->result = ZB_SECRETS_UNAVAILABLE;
  if (ss_load()) {
    GError *error = NULL;
    GHashTable *attrs = token_attributes();
    if (ss.storev(&zb_token_schema, attrs, NULL, ZB_TOKEN_LABEL, call->token, NULL, &error)) {
      call->result = ZB_SECRETS_OK;
    }
    report("store", error);
    g_clear_error(&error);
    g_hash_table_unref(attrs);
  }
  wipe_free(call->token);
  call->token = NULL;
  hold_back(delay_store_ms);
  g_task_return_boolean(task, TRUE);
}

static void clear_thread(GTask *task, gpointer source, gpointer task_data, GCancellable *cancellable) {
  (void)source;
  (void)cancellable;
  SsCall *call = task_data;
  call->result = ZB_SECRETS_UNAVAILABLE;
  if (ss_load()) {
    GError *error = NULL;
    GHashTable *attrs = token_attributes();
    ss.clearv(&zb_token_schema, attrs, NULL, &error); /* FALSE with no error: nothing was stored */
    call->result = error == NULL ? ZB_SECRETS_OK : ZB_SECRETS_UNAVAILABLE;
    report("clear", error);
    g_clear_error(&error);
    g_hash_table_unref(attrs);
  }
  hold_back(delay_clear_ms);
  g_task_return_boolean(task, TRUE);
}

static void lookup_thread(GTask *task, gpointer source, gpointer task_data, GCancellable *cancellable) {
  (void)source;
  (void)cancellable;
  SsCall *call = task_data;
  call->result = ZB_SECRETS_UNAVAILABLE;
  if (ss_load()) {
    GError *error = NULL;
    GHashTable *attrs = token_attributes();
    gchar *found = ss.lookupv(&zb_token_schema, attrs, NULL, &error);
    if (error != NULL) {
      report("lookup", error);
    } else if (found == NULL) {
      call->result = ZB_SECRETS_ABSENT;
    } else {
      call->token = g_strdup(found);
      call->result = ZB_SECRETS_OK;
    }
    if (found != NULL) {
      ss.password_free(found); /* libsecret wipes its own copy */
    }
    g_clear_error(&error);
    g_hash_table_unref(attrs);
  }
  hold_back(delay_lookup_ms);
  g_task_return_boolean(task, TRUE);
}

static void call_done(GObject *source, GAsyncResult *res, gpointer user_data) {
  (void)source;
  (void)user_data;
  SsCall *call = g_task_get_task_data(G_TASK(res));
  if (call->lookup_done != NULL) {
    char *token = call->token; /* handed over to the callback */
    call->token = NULL;
    call->lookup_done(call->result, token, call->data);
  } else if (call->done != NULL) {
    call->done(call->result, call->data);
  }
}

static void run(GTaskThreadFunc fn, SsCall *call) {
  GTask *task = g_task_new(NULL, NULL, call_done, NULL);
  g_task_set_task_data(task, call, ss_call_free);
  g_task_run_in_thread(task, fn);
  g_object_unref(task);
}

void zb_secrets_service_store_async(const char *token, ZbSecretsDone done, gpointer data) {
  SsCall *call = g_new0(SsCall, 1);
  call->token = g_strdup(token);
  call->done = done;
  call->data = data;
  run(store_thread, call);
}

void zb_secrets_service_clear_async(ZbSecretsDone done, gpointer data) {
  SsCall *call = g_new0(SsCall, 1);
  call->done = done;
  call->data = data;
  run(clear_thread, call);
}

void zb_secrets_service_lookup_async(ZbSecretsLookupDone done, gpointer data) {
  SsCall *call = g_new0(SsCall, 1);
  call->lookup_done = done;
  call->data = data;
  run(lookup_thread, call);
}

/* --- zb_agent_token_fetch --------------------------------------------------- */

/* src/agent_secrets.zig: 0 token (malloc'd into *out), 1 absent, 2 refused
 * (the fixed word in *word). */
int zb_secrets_load_file(const char *agent_home, char **out, const char **word);

typedef struct {
  int store;
  char *agent_home;
  ZbTokenDone done;
  void *data;
  ZbTokenResult result;
  char *token;
} TokenFetch;

static void token_fetch_free(gpointer p) {
  TokenFetch *fetch = p;
  wipe_free(fetch->token);
  g_free(fetch->agent_home);
  g_free(fetch);
}

static void token_fetch_thread(GTask *task, gpointer source, gpointer task_data, GCancellable *cancellable) {
  (void)source;
  (void)cancellable;
  TokenFetch *fetch = task_data;
  if (fetch->store == 1) {
    const char *word = "";
    char *token = NULL;
    int rc = zb_secrets_load_file(fetch->agent_home, &token, &word);
    if (rc == 0) {
      fetch->token = g_strdup(token);
      explicit_bzero(token, strlen(token));
      free(token);
      fetch->result = ZB_TOKEN_OK;
    } else if (rc == 1) {
      fetch->result = ZB_TOKEN_ABSENT;
    } else {
      fprintf(stderr, "zigBrowser: agent secrets: token file refused (%s)\n", word);
      fetch->result = ZB_TOKEN_REFUSED;
    }
  } else {
    fetch->result = ZB_TOKEN_UNAVAILABLE;
    if (ss_load()) {
      GError *error = NULL;
      GHashTable *attrs = token_attributes();
      gchar *found = ss.lookupv(&zb_token_schema, attrs, NULL, &error);
      if (error != NULL) {
        report("lookup", error);
      } else if (found == NULL) {
        fetch->result = ZB_TOKEN_ABSENT;
      } else {
        fetch->token = g_strdup(found);
        fetch->result = ZB_TOKEN_OK;
      }
      if (found != NULL) {
        ss.password_free(found);
      }
      g_clear_error(&error);
      g_hash_table_unref(attrs);
    }
    hold_back(delay_lookup_ms);
  }
  g_task_return_boolean(task, TRUE);
}

static void token_fetch_done(GObject *source, GAsyncResult *res, gpointer user_data) {
  (void)source;
  (void)user_data;
  TokenFetch *fetch = g_task_get_task_data(G_TASK(res));
  char *token = fetch->token; /* handed over to the callback */
  fetch->token = NULL;
  fetch->done(fetch->result, token, fetch->data);
}

void zb_agent_token_fetch(int store, const char *agent_home, ZbTokenDone done, void *data) {
  TokenFetch *fetch = g_new0(TokenFetch, 1);
  fetch->store = store;
  fetch->agent_home = g_strdup(agent_home != NULL ? agent_home : "");
  fetch->done = done;
  fetch->data = data;
  GTask *task = g_task_new(NULL, NULL, token_fetch_done, NULL);
  g_task_set_task_data(task, fetch, token_fetch_free);
  g_task_run_in_thread(task, token_fetch_thread);
  g_object_unref(task);
}
