#include "agent_helper_mac.h"

#include "agent_token_fd_mac.h"

#define ZB_MAC_AGENT_TEST_TOKEN_SERVICE "dev.zigbrowser.MS63ProductTest"

int zb_mac_agent_helper_spawn_fd3(const char *const *argv, const char *const *envp,
                                  int stdin_fd, int stdout_fd, pid_t *out_pid) {
  return zb_mac_helper_spawn_fd3(argv, envp, stdin_fd, stdout_fd,
                                 ZB_MAC_AGENT_TOKEN_SERVICE,
                                 ZB_MAC_AGENT_TOKEN_ACCOUNT, out_pid);
}

int zb_mac_agent_helper_spawn_fd3_for_test(
    const char *const *argv, const char *const *envp,
    int stdin_fd, int stdout_fd,
    const char *keychain_path, const char *unlock_password,
    pid_t *out_pid, char **out_err) {
  return zb_mac_helper_spawn_fd3_for_test(
      argv, envp, stdin_fd, stdout_fd, keychain_path, unlock_password,
      ZB_MAC_AGENT_TEST_TOKEN_SERVICE, ZB_MAC_AGENT_TOKEN_ACCOUNT, out_pid, out_err);
}

#ifdef ZB_AGENT_HELPER_MAC_SESSION

#include "agent_helper.h"
#include "agent_home_lock.h"
#include "agent_spawn_posix.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
  int kind;
  const char *session;
  size_t session_len;
  const char *text;
  size_t text_len;
  const char *code;
  size_t code_len;
  int is_error;
  const char *tool_id;
  size_t tool_id_len;
  const char *tool;
  size_t tool_len;
  const char *args;
  size_t args_len;
  int64_t prompt_id;
} ZbMacAgentFrame;

enum {
  ZB_MAC_FRAME_READY,
  ZB_MAC_FRAME_SESSION_OPENED,
  ZB_MAC_FRAME_DELTA,
  ZB_MAC_FRAME_MESSAGE,
  ZB_MAC_FRAME_TOOL_CALL,
  ZB_MAC_FRAME_RESULT,
  ZB_MAC_FRAME_ERROR,
  ZB_MAC_FRAME_SESSION_ENDED,
  ZB_MAC_FRAME_REPLY_CAPPED,
};

/* The protocol/frame implementation lives in the main Zig executable. The
 * Apple-toolchain dylib resolves these host exports through dynamic_lookup. */
void zb_agent_frames_reset(void);
int zb_agent_frames_open_session(const char *session, unsigned int window);
int zb_agent_frames_validate(const char *line, size_t len, ZbMacAgentFrame *out);
char *zb_agent_out_hello(void);
char *zb_agent_out_open_session(unsigned int window, unsigned int k);
char *zb_agent_out_prompt(const char *session, const char *text, size_t len);
void zb_agent_out_free(char *frame);

#define ZB_MAC_FRAME_MAX (256 * 1024)

typedef struct {
  int configured;
  char **argv;
  char **envp;
  char *home;
  char *unavailable;
  char *bubble;
  char *refusal;
  int e2e;
  pid_t pid;
  int input_fd;
  int output_fd;
  pthread_t reader;
  int reader_started;
  unsigned int window;
  char session[48];
  char *prompt;
} ZbMacHelper;

static ZbMacHelper zb_mac_helper = {
    .pid = -1,
    .input_fd = -1,
    .output_fd = -1,
};

static char **zb_mac_dupv(const char *const *items) {
  size_t n = 0;
  while (items != NULL && items[n] != NULL) n++;
  char **copy = calloc(n + 1, sizeof *copy);
  if (copy == NULL) return NULL;
  for (size_t i = 0; i < n; ++i) {
    copy[i] = strdup(items[i]);
    if (copy[i] == NULL) {
      while (i > 0) free(copy[--i]);
      free(copy);
      return NULL;
    }
  }
  return copy;
}

static int zb_mac_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  return flags >= 0 && fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

static int zb_mac_write_all(int fd, const char *bytes, size_t len) {
  size_t done = 0;
  while (done < len) {
    ssize_t n = write(fd, bytes + done, len - done);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return -1;
    done += (size_t)n;
  }
  return 0;
}

static int zb_mac_write_frame(char *frame) {
  if (frame == NULL) return -1;
  int rc = zb_mac_write_all(zb_mac_helper.input_fd, frame, strlen(frame));
  zb_agent_out_free(frame);
  return rc;
}

static void zb_mac_fixed_e2e(const char *verdict) {
  if (!zb_mac_helper.e2e) return;
  fprintf(stderr, "DRAWER_AGENT_E2E\t%s\n", verdict);
  fflush(stderr);
}

static void zb_mac_on_frame(const ZbMacAgentFrame *frame) {
  if (frame->kind == ZB_MAC_FRAME_READY) {
    /* `ready` is emitted only after chat read and validated fd 3 and completed
     * its start scrub. Then follow the production hello/open ordering. */
    zb_mac_fixed_e2e("ready-fd3");
    if (zb_mac_write_frame(zb_agent_out_hello()) != 0) return;
    if (zb_agent_frames_open_session(zb_mac_helper.session, zb_mac_helper.window) != 0) return;
    (void)zb_mac_write_frame(zb_agent_out_open_session(zb_mac_helper.window, 1));
    return;
  }
  if (frame->kind == ZB_MAC_FRAME_SESSION_OPENED) {
    (void)zb_mac_write_frame(zb_agent_out_prompt(
        zb_mac_helper.session, zb_mac_helper.prompt, strlen(zb_mac_helper.prompt)));
    return;
  }
  if (frame->kind == ZB_MAC_FRAME_ERROR && frame->code_len == 4 &&
      memcmp(frame->code, "auth", 4) == 0) {
    zb_mac_fixed_e2e("auth-error");
  }
}

static void *zb_mac_reader(void *unused) {
  (void)unused;
  char line[ZB_MAC_FRAME_MAX + 1];
  size_t used = 0;
  int dropping = 0;
  char chunk[4096];
  for (;;) {
    ssize_t n = read(zb_mac_helper.output_fd, chunk, sizeof chunk);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) break;
    for (ssize_t i = 0; i < n; ++i) {
      if (chunk[i] != '\n') {
        if (used < ZB_MAC_FRAME_MAX) line[used++] = chunk[i];
        else dropping = 1;
        continue;
      }
      if (!dropping) {
        ZbMacAgentFrame frame;
        if (zb_agent_frames_validate(line, used, &frame) == 0) zb_mac_on_frame(&frame);
      }
      used = 0;
      dropping = 0;
    }
  }
  close(zb_mac_helper.output_fd);
  return NULL;
}

static void zb_mac_close_pipe(int pipefd[2]) {
  if (pipefd[0] >= 0) close(pipefd[0]);
  if (pipefd[1] >= 0) close(pipefd[1]);
  pipefd[0] = pipefd[1] = -1;
}

static int zb_mac_start(unsigned int window, const char *text) {
  int input[2] = {-1, -1}, output[2] = {-1, -1};
  if (pipe(input) != 0 || pipe(output) != 0) {
    zb_mac_close_pipe(input);
    zb_mac_close_pipe(output);
    return -1;
  }
  if (!zb_mac_cloexec(input[0]) || !zb_mac_cloexec(input[1]) ||
      !zb_mac_cloexec(output[0]) || !zb_mac_cloexec(output[1])) {
    zb_mac_close_pipe(input);
    zb_mac_close_pipe(output);
    return -1;
  }
  (void)fcntl(input[1], F_SETNOSIGPIPE, 1);

  pid_t pid = -1;
  int rc = zb_mac_agent_helper_spawn_fd3(
      (const char *const *)zb_mac_helper.argv,
      (const char *const *)zb_mac_helper.envp,
      input[0], output[1], &pid);
  close(input[0]);
  close(output[1]);
  input[0] = output[1] = -1;
  if (rc != 0 || pid <= 1) {
    zb_mac_close_pipe(input);
    zb_mac_close_pipe(output);
    zb_mac_fixed_e2e("token-unavailable");
    return -1;
  }

  zb_mac_helper.pid = pid;
  zb_mac_helper.input_fd = input[1];
  zb_mac_helper.output_fd = output[0];
  zb_mac_helper.window = window;
  snprintf(zb_mac_helper.session, sizeof zb_mac_helper.session, "s-%u-1", window);
  free(zb_mac_helper.prompt);
  zb_mac_helper.prompt = strdup(text);
  if (zb_mac_helper.prompt == NULL) {
    close(zb_mac_helper.input_fd);
    (void)zb_agent_kill_group(pid);
    zb_mac_helper.pid = -1;
    return -1;
  }
  zb_agent_frames_reset();
  if (pthread_create(&zb_mac_helper.reader, NULL, zb_mac_reader, NULL) != 0) {
    close(zb_mac_helper.input_fd);
    close(zb_mac_helper.output_fd);
    (void)zb_agent_kill_group(pid);
    zb_mac_helper.pid = -1;
    return -1;
  }
  zb_mac_helper.reader_started = 1;
  zb_mac_fixed_e2e("helper-spawned-fd3");
  return 0;
}

const char *zb_agent_helper_home(void) { return zb_mac_helper.home; }

void zb_agent_helper_configure(const char *const *argv, const char *const *envp,
                               const char *home, const char *unavailable,
                               const char *bubble, const char *refusal,
                               int e2e_protocol) {
  if (zb_mac_helper.configured) return;
  zb_mac_helper.argv = zb_mac_dupv(argv);
  zb_mac_helper.envp = zb_mac_dupv(envp);
  zb_mac_helper.home = home != NULL ? strdup(home) : NULL;
  if (zb_mac_helper.argv == NULL || zb_mac_helper.envp == NULL || zb_mac_helper.home == NULL) return;
  zb_mac_helper.unavailable = unavailable != NULL ? strdup(unavailable) : NULL;
  zb_mac_helper.bubble = bubble != NULL ? strdup(bubble) : NULL;
  zb_mac_helper.refusal = refusal != NULL ? strdup(refusal) : NULL;
  zb_mac_helper.e2e = e2e_protocol != 0;
  zb_mac_helper.configured = 1;
}

int zb_agent_helper_configured(void) { return zb_mac_helper.configured; }

void zb_agent_helper_send(unsigned int window_id, const char *text) {
  if (!zb_mac_helper.configured || text == NULL || text[0] == '\0') return;
  if (zb_mac_helper.unavailable != NULL) {
    zb_mac_fixed_e2e("runtime-unavailable");
    return;
  }
  if (zb_mac_helper.refusal != NULL) {
    fprintf(stderr, "%s\n", zb_mac_helper.refusal);
    free(zb_mac_helper.refusal);
    zb_mac_helper.refusal = NULL;
    return;
  }
  if (zb_mac_helper.pid > 1) return;
  if (zb_agent_home_lock(zb_mac_helper.home) != 0) {
    zb_mac_fixed_e2e("home-locked");
    return;
  }
  (void)zb_mac_start(window_id, text);
}

void zb_agent_helper_interrupt(unsigned int window_id) { (void)window_id; }
void zb_agent_helper_window_closed(unsigned int window_id) { (void)window_id; }

void zb_agent_helper_stop(void) {
  pid_t pid = zb_mac_helper.pid;
  if (pid <= 1) return;
  if (zb_mac_helper.input_fd >= 0) {
    close(zb_mac_helper.input_fd);
    zb_mac_helper.input_fd = -1;
  }
  (void)zb_agent_kill_group(pid);
  if (zb_mac_helper.reader_started) {
    (void)pthread_join(zb_mac_helper.reader, NULL);
    zb_mac_helper.reader_started = 0;
  }
  zb_mac_helper.output_fd = -1;
  zb_mac_helper.pid = -1;
}

void zb_agent_helper_token_removed(void) { zb_agent_helper_stop(); }

#endif /* ZB_AGENT_HELPER_MAC_SESSION */
