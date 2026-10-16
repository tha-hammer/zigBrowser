/* Chat drawer S4.1 edge: "the libsecret dlopen fails: same as no keyring (no
 * silent fallback)". Inside the browser this cannot happen (WebKitGTK itself
 * links libsecret-1.so.0, so the dlopen finds it loaded), so the store is
 * built here with ZB_LIBSECRET_SONAME naming a library that does not exist.
 *
 * Checked: the load failure is reported once on stderr; a Save to the Secret
 * Service gives ZB_SECRETS_UNAVAILABLE; zb_agent_token_fetch from the Secret
 * Service gives ZB_TOKEN_UNAVAILABLE and never reads the file store (the
 * stubbed file loader below counts its calls); the file store still works.
 * The session bus is a dead address, so nothing can reach a real keyring. */

#include "agent_secrets.h"

#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int file_loads;

/* src/agent_secrets.zig's file branch, stubbed: "absent". */
int zb_secrets_load_file(const char *agent_home, char **out, const char **word) {
  (void)agent_home;
  file_loads++;
  *out = NULL;
  *word = "";
  return 1;
}

/* src/agent_secrets.zig's paste check, stubbed: never reached here (libsecret
 * is missing, so no keyring item is ever read). */
int zb_secrets_token_from_paste(const char *text, size_t len, size_t *start, size_t *token_len) {
  (void)text;
  *start = 0;
  *token_len = len;
  return 1;
}

static GMainLoop *loop;
static int pending;
static int store_result = -1, service_fetch = -1, file_fetch = -1;

static void done_one(void) {
  if (--pending == 0) {
    g_main_loop_quit(loop);
  }
}

static void on_stored(ZbSecretsResult result, gpointer data) {
  (void)data;
  store_result = result;
  done_one();
}

static void on_fetched(ZbTokenResult result, char *token, void *data) {
  *(int *)data = result;
  zb_secrets_free(token);
  done_one();
}

static int failures;

static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  failures += !ok;
}

int main(void) {
  setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent/zigbrowser-test-no-session-bus", 1);
  char err_path[] = "/tmp/zb-secrets-dlopen-XXXXXX";
  int err_fd = mkstemp(err_path);
  if (err_fd < 0) {
    perror("mkstemp");
    return 1;
  }
  unlink(err_path);
  fflush(stderr);
  int saved = dup(2);
  dup2(err_fd, 2);

  loop = g_main_loop_new(NULL, FALSE);
  pending = 2;
  zb_secrets_service_store_async("sk-ant-oat01-ZBCANARY-0123456789", on_stored, NULL);
  zb_agent_token_fetch(0, "/nonexistent-agent-home", on_fetched, &service_fetch);
  g_main_loop_run(loop);
  int service_loads = file_loads;
  pending = 1;
  zb_agent_token_fetch(1, "/nonexistent-agent-home", on_fetched, &file_fetch);
  g_main_loop_run(loop);
  g_main_loop_unref(loop);

  fflush(stderr);
  dup2(saved, 2);
  close(saved);
  char err[4096] = {0};
  lseek(err_fd, 0, SEEK_SET);
  ssize_t n = read(err_fd, err, sizeof err - 1);
  close(err_fd);
  (void)n;

  int reports = 0;
  for (const char *p = err; (p = strstr(p, "libsecret is not available")) != NULL; p++) {
    reports++;
  }
  check(reports == 1, "the failed libsecret load is reported once on stderr");
  check(store_result == ZB_SECRETS_UNAVAILABLE, "a Save to the Secret Service is UNAVAILABLE");
  check(service_fetch == ZB_TOKEN_UNAVAILABLE, "a Secret Service fetch is UNAVAILABLE");
  check(service_loads == 0, "and it never reads the file store (no silent fallback)");
  check(file_fetch == ZB_TOKEN_ABSENT && file_loads == 1, "the file store is still read when chosen");
  printf("%d failed\n", failures);
  return failures == 0 ? 0 : 1;
}
