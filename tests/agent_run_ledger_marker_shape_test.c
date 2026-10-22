/* MS6.5.1 red (RoseCat 35823e0 / 7575 #2). The C2 marker classifier must be NO-WEDGE and shape-strict: a special
 * object at run.marker must never block or masquerade as a valid run. Only the exact app-owned marker shape
 * (a regular file, this uid, mode 0400) is PRESENT; a directory, FIFO, socket, symlink, wrong owner/mode, or any
 * other error fails closed (ERR). REAL Linux dirs, no signals, no wedge. UNREGISTERED until green.
 *
 * The mutants this catches: (a) accepting a DIRECTORY (or other non-regular object) at run.marker as PRESENT
 * (the current blocking-open-no-fstat classifier); (b) a blocking open that wedges forever on a FIFO (proven in
 * the green by O_NONBLOCK returning ERR without hanging).
 */
#include "agent_run_reaper.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures = 0, total = 0;
static void check(int ok, const char *m) { total++; printf("  %s %s\n", ok ? "ok" : "FAIL", m); if (!ok) failures++; }

/* make a fresh 0700 run dir with a given basename, return its fd (or -1) */
static int make_run_dir(int runtime_fd, const char *name) {
  if (mkdirat(runtime_fd, name, 0700) != 0) return -1;
  return openat(runtime_fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
}

int main(void) {
  char parent[] = "/tmp/zb-markershape-XXXXXX";
  if (mkdtemp(parent) == NULL) { printf("FAIL mkdtemp\n"); return 2; }
  if (chmod(parent, 0700) != 0) { printf("FAIL chmod\n"); rmdir(parent); return 2; }
  const int runtime_fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (runtime_fd < 0) { printf("FAIL open runtime\n"); rmdir(parent); return 2; }

  /* (control) a real app-owned 0400 regular marker -> PRESENT */
  const char *good = "zigbrowser-agent-1-0000000000000000";
  int gd = make_run_dir(runtime_fd, good);
  if (gd >= 0) { int m = openat(gd, "run.marker", O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0400); if (m >= 0) close(m); close(gd); }
  check(zb_reaper_run_marker_state(runtime_fd, good) == ZB_RUN_MARKER_PRESENT, "a regular 0400 marker -> PRESENT");

  /* a DIRECTORY at run.marker must NOT masquerade as a present marker -> ERR (the current classifier returns PRESENT) */
  const char *asdir = "zigbrowser-agent-2-0000000000000000";
  int dd = make_run_dir(runtime_fd, asdir);
  if (dd >= 0) { mkdirat(dd, "run.marker", 0700); close(dd); }
  check(zb_reaper_run_marker_state(runtime_fd, asdir) == ZB_RUN_MARKER_ERR, "a DIRECTORY at run.marker -> ERR (never PRESENT)");

  /* a SYMLINK at run.marker must fail closed (no-follow) -> ERR */
  const char *aslink = "zigbrowser-agent-3-0000000000000000";
  int ld = make_run_dir(runtime_fd, aslink);
  if (ld >= 0) { symlinkat("/etc/hostname", ld, "run.marker"); close(ld); }
  check(zb_reaper_run_marker_state(runtime_fd, aslink) == ZB_RUN_MARKER_ERR, "a SYMLINK at run.marker -> ERR (never followed)");

  /* a wrong-mode (0644) regular marker must fail closed -> ERR */
  const char *badmode = "zigbrowser-agent-4-0000000000000000";
  int bd = make_run_dir(runtime_fd, badmode);
  if (bd >= 0) { int m = openat(bd, "run.marker", O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0644); if (m >= 0) close(m); close(bd); }
  check(zb_reaper_run_marker_state(runtime_fd, badmode) == ZB_RUN_MARKER_ERR, "a wrong-mode (0644) marker -> ERR");

  /* a FIFO at run.marker must fail closed WITHOUT wedging (O_NONBLOCK): a blocking O_RDONLY open would hang here */
  const char *asfifo = "zigbrowser-agent-5-0000000000000000";
  int fd5 = make_run_dir(runtime_fd, asfifo);
  if (fd5 >= 0) { mkfifoat(fd5, "run.marker", 0400); close(fd5); }
  check(zb_reaper_run_marker_state(runtime_fd, asfifo) == ZB_RUN_MARKER_ERR, "a FIFO at run.marker -> ERR (no wedge, O_NONBLOCK)");

  if (failures == 0) { printf("PASS ledger-marker-shape %d checks\n", total); return 0; }
  printf("FAIL ledger-marker-shape %d of %d check(s) failed\n", failures, total);
  return 1;
}
