/* MS6.5 reaper on real macOS (the user's decision 2026-10-21; RoseCat a2fd8af). The ONLY SIGKILLs here come from
 * zb_reaper_sweep (guarded: pid>1, not self, same uid, marker+uid+start-time re-checked immediately before the
 * signal). This driver sends NO signal of its own: every helper process it starts is stopped by closing a
 * control pipe (the holder exits on EOF) and, for a direct child, reaped with waitpid — never a raw kill of a
 * numeric pid that might have been reused. A spawn/chdir/setsid failure yields no pid and fails the test closed.
 *
 * A detached setsid+double-fork escaper whose cwd is under the (app-signature) run dir is found by the census and
 * killed by the sweep; a decoy outside the run dir is untouched; a marker-scrubber (cwd "/") is the accepted
 * residual the census cannot see. Run by tests/mac/ms6_5_reaper_gate.sh on both arches. */
#include "agent_run_reaper.h"
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures = 0;
static void check(int ok, const char *msg) { printf("  %s %s\n", ok ? "ok" : "FAIL", msg); if (!ok) failures++; }
static int in_list(const int *a, int n, pid_t pid) { for (int i = 0; i < n; i++) if (a[i] == (int)pid) return 1; return 0; }

/* Start a process whose cwd is `dir`, detached (setsid + double-fork) or a direct child, holding on a control
 * pipe. Returns 0 and fills *pid and *ctrl_w (close it to make the holder exit on EOF); -1 on any failure, in
 * which case there is NO pid to clean up. setsid()/chdir() failures make the holder exit before reporting, so
 * *pid is never a bogus value. */
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
      if (g > 0) _exit(0); /* middle child exits -> the grandchild detaches (reparents to launchd) */
    }
    if (chdir(dir) != 0) _exit(33);
    pid_t me = getpid();
    (void)write(info[1], &me, sizeof me);
    close(info[1]);
    char b;
    (void)read(ctrl[0], &b, 1); /* blocks until the parent closes the control write end (EOF) */
    _exit(0);
  }
  close(ctrl[0]);
  close(info[1]);
  pid_t got = -1;
  if (read(info[0], &got, sizeof got) != (ssize_t)sizeof got) got = -1;
  close(info[0]);
  if (detached) waitpid(c, NULL, 0); /* reap the middle child */
  if (got <= 1) { close(ctrl[1]); return -1; } /* spawn/chdir/setsid failed: no valid pid */
  *pid = got;
  *ctrl_w = ctrl[1];
  return 0;
}

int main(void) {
  char parent[] = "/tmp/zb-reaper-gate-XXXXXX";
  if (mkdtemp(parent) == NULL) { printf("FAIL mkdtemp\n"); return 2; }
  char run[PATH_MAX]; /* the exact sockdirPath grammar: zigbrowser-agent-<pid>-<16 lowercase hex>, mode 0700 */
  snprintf(run, sizeof run, "%s/zigbrowser-agent-%d-00112233445566ff", parent, (int)getpid());
  if (mkdir(run, 0700) != 0) { printf("FAIL mkdir run\n"); rmdir(parent); return 2; }
  /* Spawn the helpers BEFORE opening the pinned fd: O_CLOEXEC does not close across a fork that never execs, so
   * an inherited run-dir fd would make the decoy/scrubber classify via their open-file marker (RoseCat 175efb8
   * #1). The escaper's marker is its CWD under the run dir, not an fd. */
  pid_t esc = -1, dec = -1, scr = -1;
  int ew = -1, dw = -1, sw = -1;
  int setup = 1;
  if (make_holder(run, 1, &esc, &ew) != 0) { printf("FAIL: spawn escaper\n"); setup = 0; }
  if (setup && make_holder("/tmp", 0, &dec, &dw) != 0) { printf("FAIL: spawn decoy\n"); setup = 0; }
  if (setup && make_holder("/", 1, &scr, &sw) != 0) { printf("FAIL: spawn scrubber\n"); setup = 0; }

  /* creation-pinned: open + hold the run dir fd and capture its identity, AFTER the helpers exist. */
  int rfd = -1;
  struct zb_reaper_dir_id rid;
  if (setup) {
    rfd = open(run, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (rfd < 0 || zb_reaper_pin_fd(rfd, &rid) != 0) {
      printf("FAIL pin run dir\n");
      if (rfd >= 0) { close(rfd); rfd = -1; }
      setup = 0;
    }
  }

  if (setup) {
    printf("run=%s escaper=%d decoy=%d scrubber=%d self=%d\n", run, esc, dec, scr, getpid());
    sleep(1);

    int cen[512], cn = 0, ov = 0;
    zb_reaper_census(rfd, &rid, cen, 512, &cn, &ov);
    check(cn == 1 && cen[0] == (int)esc, "census is EXACTLY {escaper}");
    check(ov == 0, "census reports no overflow");

    int killed[512], surv[512], kn = 0, sn = 0, ov2 = 0;
    zb_reaper_sweep(rfd, &rid, killed, 512, &kn, surv, 512, &sn, &ov2);
    check(kn == 1 && killed[0] == (int)esc, "sweep killed EXACTLY {escaper}");
    check(sn == 0, "sweep reports no survivors");
    check(ov2 == 0, "sweep reports no overflow");
    check(!in_list(killed, kn, dec) && !in_list(surv, sn, dec), "sweep did not touch the decoy");
    check(!in_list(killed, kn, scr) && !in_list(surv, sn, scr), "sweep did not touch the scrubber");

    int cen2[512], cn2 = 0, ov3 = 0; /* the escaper is gone: a re-census finds nothing (no kill0 on a reused pid) */
    zb_reaper_census(rfd, &rid, cen2, 512, &cn2, &ov3);
    check(cn2 == 0, "re-census is empty: the escaper is gone");

    int st = 0;
    check(waitpid(dec, &st, WNOHANG) == 0, "the decoy is still alive"); /* WNOHANG on our own child, not a kill0 */
  }

  /* Clean up with NO signal: close every control write end (holders exit on EOF), reap the direct child. */
  if (rfd >= 0) close(rfd);
  if (ew >= 0) close(ew);
  if (dw >= 0) close(dw);
  if (sw >= 0) close(sw);
  if (dec > 1) waitpid(dec, NULL, 0);
  rmdir(run);
  rmdir(parent);

  if (setup && failures == 0) { printf("PASS ms6-5-reaper 9 checks\n"); return 0; }
  printf("FAIL ms6-5-reaper %d check(s) failed%s\n", failures, setup ? "" : " (setup)");
  return 1;
}
