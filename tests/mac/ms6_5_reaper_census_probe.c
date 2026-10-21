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

static int failures = 0, total = 0;
static void check(int ok, const char *m) { total++; printf("  %s %s\n", ok ? "ok" : "FAIL", m); if (!ok) failures++; }
static int in_list(const int *a, int n, pid_t pid) { for (int i = 0; i < n; i++) if (a[i] == (int)pid) return 1; return 0; }

/* A process whose cwd is `dir`, detached or a direct child, held on a control pipe (close it -> EOF -> exits).
 * `close_fd` (>= 0) is closed in the child first, so a process spawned AFTER the pin never inherits it. Returns
 * 0 and fills pid + ctrl_w, or -1. */
static int make_holder(const char *dir, int detached, int close_fd, pid_t *pid, int *ctrl_w) {
  int ctrl[2], info[2];
  if (pipe(ctrl) != 0) return -1;
  if (pipe(info) != 0) { close(ctrl[0]); close(ctrl[1]); return -1; }
  pid_t c = fork();
  if (c < 0) { close(ctrl[0]); close(ctrl[1]); close(info[0]); close(info[1]); return -1; }
  if (c == 0) {
    close(ctrl[1]);
    close(info[0]);
    if (close_fd >= 0) close(close_fd); /* never inherit the pinned fd (its F_GETPATH would falsely classify) */
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

  pid_t esc = -1, dec = -1, scr = -1, rep = -1;
  int ew = -1, dw = -1, sw = -1, rw = -1;
  char moved[PATH_MAX] = "";
  int setup = 1;
  if (make_holder(run, 1, -1, &esc, &ew) != 0) { printf("FAIL: spawn escaper\n"); setup = 0; }
  if (setup && make_holder("/tmp", 0, -1, &dec, &dw) != 0) { printf("FAIL: spawn decoy\n"); setup = 0; }
  if (setup && make_holder("/", 1, -1, &scr, &sw) != 0) { printf("FAIL: spawn scrubber\n"); setup = 0; }

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

    /* RENAME/REPLACEMENT (RoseCat 94be4e5 boundary 2): move the held dir aside and plant a replacement at the
     * OLD name, with a process whose cwd is that replacement. Classification must stay tied to the HELD inode
     * (F_GETPATH follows it to the new path), and the replacement process must NOT classify. */
    snprintf(moved, sizeof moved, "%s.moved", run);
    check(rename(run, moved) == 0, "rename the held run dir aside");
    check(mkdir(run, 0700) == 0, "plant a replacement dir at the old name");
    /* the replacement process is spawned AFTER the pin, so it must not inherit rfd (close_fd = rfd). */
    check(make_holder(run, 1, rfd, &rep, &rw) == 0, "spawn a process whose cwd is the REPLACEMENT (old name)");
    sleep(1);
    char fp2[PATH_MAX], rp2[PATH_MAX];
    check(fcntl(rfd, F_GETPATH, fp2) == 0 && realpath(moved, rp2) != NULL && strcmp(fp2, rp2) == 0,
          "F_GETPATH follows the held inode to its NEW path after the rename");
    int cen2[512], cn2 = 0, ov2 = 0;
    zb_reaper_census(rfd, &rid, cen2, 512, &cn2, &ov2);
    printf("after rename, census matched %d:", cn2);
    for (int i = 0; i < cn2; i++) printf(" %d", cen2[i]);
    printf(" (escaper=%d replacement=%d)\n", esc, rep);
    /* SAFETY (the property that matters): after a rename + a replacement at the old name, the reaper never
     * targets the replacement; the post-rename census is a SUBSET of {escaper} (the held run only). A survivor
     * whose cwd dir was renamed out from under it becomes un-inspectable via libproc (PROC_PIDVNODEPATHINFO
     * returns nothing for it), so it may DROP from the census — a completeness gap, NOT a safety hole, and the
     * app never renames its own run dir mid-cleanup. */
    check(!in_list(cen2, cn2, rep), "the REPLACEMENT-dir process does NOT classify (tied to the held run, not the old name)");
    int only_escaper = 1;
    for (int i = 0; i < cn2; i++) if (cen2[i] != (int)esc) only_escaper = 0;
    check(only_escaper, "the post-rename census is a SUBSET of {escaper}: never the replacement or any other pid");
    if (!in_list(cen2, cn2, esc))
      printf("  note: the renamed-out survivor dropped (macOS libproc limit; completeness, not safety)\n");
  }

  if (rfd >= 0) close(rfd);
  if (ew >= 0) close(ew);
  if (dw >= 0) close(dw);
  if (sw >= 0) close(sw);
  if (rw >= 0) close(rw);
  if (dec > 1) waitpid(dec, NULL, 0);
  rmdir(run);                      /* the replacement dir (or the original, if the rename case did not run) */
  if (moved[0] != '\0') rmdir(moved); /* the moved (held) dir, now its holder exits on the control-pipe EOF */
  rmdir(parent);
  if (setup && failures == 0) { printf("PASS ms6-5-reaper-census %d checks\n", total); return 0; }
  printf("FAIL ms6-5-reaper-census %d of %d check(s) failed%s\n", failures, total, setup ? "" : " (setup)");
  return 1;
}
