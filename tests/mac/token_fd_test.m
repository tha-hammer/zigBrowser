/* MS5.3 seam (macOS plan rev 14 item 7): zb_mac_token_to_fd(fd, keychain_path, unlock_password, service,
 * account, &err) looks the token up in the Keychain (JadeBeacon's zb_keychain_lookup), writes ALL of it to
 * `fd`, then wipes and frees its copy. The token reaches only that descriptor: never the environment, argv,
 * stderr, or any error text. Driven headless against a DISPOSABLE keychain with a canary, never a real
 * credential. Run by tests/mac/ms5_token_fd_gate.sh on both Macs.
 *
 * Proves:
 *  - a stored canary arrives byte-for-byte at the reader of `fd` (a pipe, as the helper's fd 3 will be),
 *    and the call returns ZB_KC_OK with no error text;
 *  - a token larger than the pipe buffer arrives whole while a timer signal (no SA_RESTART) keeps
 *    interrupting the write and the reader is slow, so write() returns short counts and EINTR: only a writer
 *    that loops delivers it all (a single write() is the mutant this catches);
 *  - ABSENT: nothing is written, ZB_KC_ABSENT, and the error names no token;
 *  - a closed reader: the write fails, the call returns ZB_MAC_FD_WRITE_FAILED with fixed error text
 *    that names no token, and no SIGPIPE kills the process;
 *  - nowhere else: after every case the canary is in no environment variable, not in argv, and not in
 *    anything this process wrote to stderr (stderr is captured to a file and scanned). */
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include "agent_secrets_mac.h"
#include <crt_externs.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

/* Weak, so the red fails by behaviour ("missing"), not at link time. */
extern int zb_mac_token_to_fd(int fd, const char *keychain_path, const char *unlock_password, const char *service,
                              const char *account, char **out_err) __attribute__((weak_import));
#ifndef ZB_MAC_FD_WRITE_FAILED
#define ZB_MAC_FD_WRITE_FAILED 3
#endif

static void on_alarm(int sig) { (void)sig; }

static int failures = 0;
static void fail(const char *msg) { fprintf(stdout, "  FAIL %s\n", msg); failures++; }

static char canary[64];
static char big[200001];

static int env_has(const char *needle) {
  for (char **e = *_NSGetEnviron(); *e != NULL; e++) if (strstr(*e, needle) != NULL) return 1;
  return 0;
}

static char *read_all(int fd, size_t *len) {
  size_t cap = 4096, n = 0;
  char *buf = malloc(cap);
  for (;;) {
    if (n == cap) buf = realloc(buf, cap *= 2);
    ssize_t r = read(fd, buf + n, cap - n);
    if (r < 0 && errno == EINTR) continue;
    if (r <= 0) break;
    n += (size_t)r;
  }
  *len = n;
  return buf;
}

int main(int argc, char **argv) {
  if (zb_mac_token_to_fd == NULL) {
    printf("FAIL\tms5-token-fd\tzb_mac_token_to_fd is missing (rev 14 item 7)\n");
    return 1;
  }
  /* Everything this process writes to stderr goes to a file we scan at the end. */
  char errpath[] = "/tmp/zb-tokfd-stderr-XXXXXX";
  int errfd = mkstemp(errpath);
  if (errfd < 0 || dup2(errfd, 2) < 0) { printf("FAIL\tms5-token-fd\tcannot capture stderr\n"); return 1; }

  snprintf(canary, sizeof canary, "sk-ant-oat01-ZBCANARY%08x%08x", arc4random(), arc4random());
  memset(big, 'Q', sizeof big - 1);
  memcpy(big, canary, strlen(canary));
  big[sizeof big - 1] = 0;

  char kcpath[] = "/tmp/zb-tokfd-kc-XXXXXX";
  if (mkdtemp(kcpath) == NULL) { printf("FAIL\tms5-token-fd\tmkdtemp\n"); return 1; }
  char kc[600];
  snprintf(kc, sizeof kc, "%s/t.keychain", kcpath);
  const char *pw = "zb-disposable";
  SecKeychainRef ref = NULL;
  if (SecKeychainCreate(kc, (UInt32)strlen(pw), pw, false, NULL, &ref) != errSecSuccess) {
    printf("FAIL\tms5-token-fd\tSecKeychainCreate\n");
    return 1;
  }
  const char *svc = "zb-tokfd-test", *acct = "canary";
  char *err = NULL;

  /* 1. A stored canary reaches the reader of fd, whole. */
  if (zb_keychain_store(kc, pw, svc, acct, canary, &err) != ZB_KC_OK) fail("store canary");
  free(err); err = NULL;
  int p[2];
  if (pipe(p) != 0) return 1;
  int r = zb_mac_token_to_fd(p[1], kc, pw, svc, acct, &err);
  close(p[1]);
  size_t got_len = 0;
  char *got = read_all(p[0], &got_len);
  close(p[0]);
  if (r != ZB_KC_OK) fail("roundtrip returns ZB_KC_OK");
  if (err != NULL) fail("no error text on success");
  if (got_len != strlen(canary) || memcmp(got, canary, got_len) != 0) fail("the reader gets exactly the canary");
  free(got); free(err); err = NULL;

  /* 2. Larger than a pipe buffer: a reader child drains while the seam writes. */
  if (zb_keychain_store(kc, pw, svc, acct, big, &err) != ZB_KC_OK) fail("store big");
  free(err); err = NULL;
  if (pipe(p) != 0) return 1;
  pid_t child = fork();
  if (child == 0) {
    close(p[1]);
    size_t n = 0, cap = sizeof big;
    char *all = malloc(cap);
    for (;;) { /* a slow reader: small reads with pauses, so the writer blocks again and again */
      ssize_t k = read(p[0], all + n, n + 1024 <= cap ? 1024 : cap - n);
      if (k < 0 && errno == EINTR) continue;
      if (k <= 0) break;
      n += (size_t)k;
      usleep(200);
    }
    _exit(n == strlen(big) && memcmp(all, big, n) == 0 ? 0 : 1);
  }
  close(p[0]);
  /* Interrupt the writer every 1 ms; without SA_RESTART a blocked write returns a short count or EINTR. */
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_handler = on_alarm;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGALRM, &sa, NULL);
  struct itimerval tick = {{0, 1000}, {0, 1000}}, off = {{0, 0}, {0, 0}};
  setitimer(ITIMER_REAL, &tick, NULL);
  r = zb_mac_token_to_fd(p[1], kc, pw, svc, acct, &err);
  setitimer(ITIMER_REAL, &off, NULL);
  close(p[1]);
  int st = 0;
  waitpid(child, &st, 0);
  if (r != ZB_KC_OK || !WIFEXITED(st) || WEXITSTATUS(st) != 0) fail("a token larger than the pipe buffer arrives whole");
  free(err); err = NULL;

  /* 3. Absent: nothing written. */
  if (pipe(p) != 0) return 1;
  r = zb_mac_token_to_fd(p[1], kc, pw, svc, "no-such-account", &err);
  close(p[1]);
  got = read_all(p[0], &got_len);
  close(p[0]);
  if (r != ZB_KC_ABSENT) fail("absent returns ZB_KC_ABSENT");
  if (got_len != 0) fail("absent writes nothing");
  if (err != NULL && strstr(err, "ZBCANARY") != NULL) fail("absent error names no token");
  free(got); free(err); err = NULL;

  /* 4. A closed reader: a fixed failure, no SIGPIPE death, no token in the text. */
  if (zb_keychain_store(kc, pw, svc, acct, canary, &err) != ZB_KC_OK) fail("store canary again");
  free(err); err = NULL;
  if (pipe(p) != 0) return 1;
  close(p[0]);
  r = zb_mac_token_to_fd(p[1], kc, pw, svc, acct, &err);
  close(p[1]);
  if (r != ZB_MAC_FD_WRITE_FAILED) fail("a closed reader returns ZB_MAC_FD_WRITE_FAILED (and the process lives)");
  if (err == NULL) fail("a closed reader gives an error text");
  else if (strstr(err, "ZBCANARY") != NULL) fail("the write error names no token");
  free(err); err = NULL;

  /* 5. Nowhere else: env, argv, stderr. */
  if (env_has("ZBCANARY")) fail("the canary is in the environment");
  for (int i = 0; i < argc; i++) if (strstr(argv[i], "ZBCANARY") != NULL) fail("the canary is in argv");
  fflush(stderr);
  lseek(errfd, 0, SEEK_SET);
  size_t elen = 0;
  char *etext = read_all(errfd, &elen);
  if (elen > 0 && memmem(etext, elen, "ZBCANARY", 8) != NULL) fail("the canary reached stderr");
  free(etext);

  SecKeychainDelete(ref);
  CFRelease(ref);
  unlink(errpath);
  rmdir(kcpath);
  if (failures == 0) {
    printf("PASS\tms5-token-fd\t5 cases\n");
    return 0;
  }
  printf("FAIL\tms5-token-fd\t%d failure(s)\n", failures);
  return 1;
}
#pragma clang diagnostic pop
