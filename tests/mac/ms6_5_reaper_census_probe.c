/* MS6.5 signal-free Mac identity probe (RoseCat 175efb8). NO kill — census ONLY. It proves, on real macOS, that
 * (a) F_GETPATH from the held run-dir fd names that dir's current path, and (b) with the pinned fd NOT leaked to
 * the helpers, the census classifies EXACTLY the detached escaper (cwd under the run dir) and NOT the decoy
 * (cwd /tmp) or the scrubber (cwd /). Helpers are stopped by closing a control pipe (EOF); this driver sends no
 * signal of its own, and census never signals. Run by ms6_5_reaper_census_gate.sh on both arches. */
#include "agent_run_reaper.h"
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures = 0;
static void check(int ok, const char *m) { printf("  %s %s\n", ok ? "ok" : "FAIL", m); if (!ok) failures++; }
static int in_list(const int *a, int n, pid_t pid) { for (int i = 0; i < n; i++) if (a[i] == (int)pid) return 1; return 0; }

/* A process whose cwd is `dir`, detached or a direct child, held on a control pipe (close it -> EOF -> exits).
 * Returns 0 and fills pid + ctrl_w, or -1. No run-dir fd is passed in, so none is inherited. */
static int make_holder(const char *dir, int detached, pid_t *pid, int *ctrl_w) {
  int ctrl[2], info[2];
  if (pipe(ctrl) != 0) return -1;
  if (pipe(info) != 0) { close(ctrl[0]); close(ctrl[1]); return -1; }
  pid_t c = fork();
  if (c < 0) { close(ctrl[0]); close(ctrl[1]); close(info[0]); close(info[1]); return -1; }
  if (c == 0) {
    close(ctrl[1]);
    close(info[0]);
    if (detached) {
      if (setsid() < 0) _exit(31);
      pid_t g = fork();
      if (g < 0) _exit(32);
      if (g > 0) _exit(0);
    }
    if (chdir(dir) != 0) _exit(33);
    pid_t me = getpid();
    (void)write(info[1], &me, sizeof me);
    close(info[1]);
    char b;
    (void)read(ctrl[0], &b, 1);
    _exit(0);
  }
  close(ctrl[0]);
  close(info[1]);
  pid_t got = -1;
  if (read(info[0], &got, sizeof got) != (ssize_t)sizeof got) got = -1;
  close(info[0]);
  if (detached) waitpid(c, NULL, 0);
  if (got <= 1) { close(ctrl[1]); return -1; }
  *pid = got;
  *ctrl_w = ctrl[1];
  return 0;
}

int main(void) {
  char parent[] = "/tmp/zb-reaper-census-XXXXXX";
  if (mkdtemp(parent) == NULL) { printf("FAIL mkdtemp\n"); return 2; }
  char run[PATH_MAX];
  snprintf(run, sizeof run, "%s/zigbrowser-agent-%d-00112233445566ff", parent, (int)getpid());
  if (mkdir(run, 0700) != 0) { printf("FAIL mkdir run\n"); rmdir(parent); return 2; }

  pid_t esc = -1, dec = -1, scr = -1;
  int ew = -1, dw = -1, sw = -1;
  int setup = 1;
  if (make_holder(run, 1, &esc, &ew) != 0) { printf("FAIL: spawn escaper\n"); setup = 0; }
  if (setup && make_holder("/tmp", 0, &dec, &dw) != 0) { printf("FAIL: spawn decoy\n"); setup = 0; }
  if (setup && make_holder("/", 1, &scr, &sw) != 0) { printf("FAIL: spawn scrubber\n"); setup = 0; }

  int rfd = -1;
  struct zb_reaper_dir_id rid;
  if (setup) {
    rfd = open(run, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (rfd < 0 || zb_reaper_pin_fd(rfd, &rid) != 0) { printf("FAIL pin\n"); if (rfd >= 0) { close(rfd); rfd = -1; } setup = 0; }
  }

  if (setup) {
    sleep(1);
    char fpath[PATH_MAX], resolved[PATH_MAX];
    check(fcntl(rfd, F_GETPATH, fpath) == 0, "F_GETPATH from the held fd succeeds");
    check(realpath(run, resolved) != NULL && strcmp(fpath, resolved) == 0,
          "F_GETPATH names the held vnode's current path (== realpath of the run dir)");

    int cen[512], cn = 0, ov = 0;
    zb_reaper_census(rfd, &rid, cen, 512, &cn, &ov);
    printf("census matched %d:", cn);
    for (int i = 0; i < cn; i++) printf(" %d", cen[i]);
    printf(" (escaper=%d decoy=%d scrubber=%d self=%d)\n", esc, dec, scr, getpid());
    check(cn == 1 && cen[0] == (int)esc, "census is EXACTLY {escaper}");
    check(!in_list(cen, cn, dec), "the decoy (cwd /tmp) does NOT classify");
    check(!in_list(cen, cn, scr), "the scrubber (cwd /) does NOT classify");
    check(ov == 0, "census reports no overflow");
  }

  if (rfd >= 0) close(rfd);
  if (ew >= 0) close(ew);
  if (dw >= 0) close(dw);
  if (sw >= 0) close(sw);
  if (dec > 1) waitpid(dec, NULL, 0);
  rmdir(run);
  rmdir(parent);
  if (setup && failures == 0) { printf("PASS ms6-5-reaper-census 6 checks\n"); return 0; }
  printf("FAIL ms6-5-reaper-census %d check(s) failed%s\n", failures, setup ? "" : " (setup)");
  return 1;
}
