/* Chat drawer S4.2 edge (BlackRobin 5815, RoseCat 5813): the store never hands
 * out a token it is deleting. Remove deletes the file at the click and starts
 * an asynchronous keyring clear; a token fetch that overlaps that clear (it
 * started while the clear runs, or the clear started before its answer) must
 * answer ZB_TOKEN_ABSENT and never pass the token on. A fetch after the clear
 * has answered works again.
 *
 * Built like agent_secrets_dlopen_test.c: libsecret is a library that does not
 * exist, so each clear answers at once (UNAVAILABLE) on its worker thread, and
 * the file loader is stubbed to return a canary. Every call is made on the
 * main thread before the loop runs, so the interleavings are exact. The
 * session bus is a dead address: nothing can reach a real keyring. */

#include "agent_secrets.h"

#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CANARY "sk-ant-oat01-ZBCANARY-clear-fetch-0123456789"

/* src/agent_secrets.zig's file branch, stubbed: always the canary. */
int zb_secrets_load_file(const char *agent_home, char **out, const char **word) {
  (void)agent_home;
  *out = strdup(CANARY);
  *word = "";
  return 0;
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

typedef struct {
  int result;
  int had_token;
} Fetched;

static void done_one(void) {
  if (--pending == 0) {
    g_main_loop_quit(loop);
  }
}

static void on_fetched(ZbTokenResult result, char *token, void *data) {
  Fetched *f = data;
  f->result = result;
  f->had_token = token != NULL;
  zb_secrets_free(token);
  done_one();
}

static void on_cleared(ZbSecretsResult result, gpointer data) {
  (void)result;
  (void)data;
  done_one();
}

static int failures;

static void check(int ok, const char *what) {
  printf("%s %s\n", ok ? "ok  " : "FAIL", what);
  failures += !ok;
}

static void run_loop(int calls) {
  pending = calls;
  g_main_loop_run(loop);
}

int main(void) {
  setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent/zigbrowser-test-no-session-bus", 1);
  loop = g_main_loop_new(NULL, FALSE);

  Fetched alone = {-1, 0};
  zb_agent_token_fetch(1, "/nonexistent-agent-home", on_fetched, &alone);
  run_loop(1);
  check(alone.result == ZB_TOKEN_OK && alone.had_token, "a fetch with no clear running gives the token");

  Fetched after_clear_started = {-1, 0};
  zb_secrets_service_clear_async(on_cleared, NULL);
  zb_agent_token_fetch(1, "/nonexistent-agent-home", on_fetched, &after_clear_started);
  run_loop(2);
  check(after_clear_started.result == ZB_TOKEN_ABSENT && !after_clear_started.had_token,
        "a fetch started while a clear runs answers ABSENT, without the token");

  Fetched before_clear_started = {-1, 0};
  zb_agent_token_fetch(1, "/nonexistent-agent-home", on_fetched, &before_clear_started);
  zb_secrets_service_clear_async(on_cleared, NULL);
  run_loop(2);
  check(before_clear_started.result == ZB_TOKEN_ABSENT && !before_clear_started.had_token,
        "a fetch whose answer comes after a clear started answers ABSENT, without the token");

  Fetched later = {-1, 0};
  zb_agent_token_fetch(1, "/nonexistent-agent-home", on_fetched, &later);
  run_loop(1);
  check(later.result == ZB_TOKEN_OK && later.had_token, "after the clear answered, a fetch gives the token again");

  g_main_loop_unref(loop);
  return failures == 0 ? 0 : 1;
}
