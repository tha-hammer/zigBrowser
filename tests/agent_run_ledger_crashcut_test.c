/* MS6.5.1 red (crash-cut table C2/C3; macOS-plan 1953-1956, 2032-2036). Each Clean teardown crash cut has ONE
 * signal-free, idempotent recovery. REAL Linux dirs (openat O_NOFOLLOW) — NO signals. UNREGISTERED until green.
 *
 * C2 (claim held, after unlinkat(run.marker), before rmdir): a provenance-valid, EMPTY, MARKER-LESS dir with an
 *    active entry. Recovery opens run.marker no-follow => ENOENT => the durable teardown phase => finish
 *    rmdir+entry-remove, NO signal, NOT a permanent incident. A dir that still HOLDS its marker is a real run.
 *    Mutant: ignore run.marker (treat the marker-less dir as a fresh grammar leftover to re-census / warn for a
 *    signal) => a permanent incident appears. zb_reaper_run_marker_state is the classifier under test.
 * C3 (claim held, after rmdir, before entry removal): an active entry naming NO dir. Recovery openat of the run
 *    dir => ENOENT => drop the entry (reconcile), NO signal. This is zb_reaper_ledger_entry_state => ZB_LEDGER_GONE
 *    (already green); asserted here as the C3 crash-cut recovery row.
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

int main(void) {
  char parent[] = "/tmp/zb-crashcut-XXXXXX";
  if (mkdtemp(parent) == NULL) { printf("FAIL mkdtemp\n"); return 2; }
  if (chmod(parent, 0700) != 0) { printf("FAIL chmod parent\n"); rmdir(parent); return 2; }
  const int runtime_fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (runtime_fd < 0) { printf("FAIL open runtime\n"); rmdir(parent); return 2; }

  const char *live = "zigbrowser-agent-1234-0011223344556677";    /* a real run: holds run.marker */
  const char *teardown = "zigbrowser-agent-5678-8899aabbccddeeff"; /* C2: marker already unlinked, dir not yet rmdir'd */
  int setup = mkdirat(runtime_fd, live, 0700) == 0 && mkdirat(runtime_fd, teardown, 0700) == 0;
  if (setup) {
    const int ldfd = openat(runtime_fd, live, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (ldfd < 0) setup = 0;
    else {
      const int mfd = openat(ldfd, "run.marker", O_CREAT | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0400);
      if (mfd < 0) setup = 0; else close(mfd);
      close(ldfd);
    }
  }
  if (!setup) { printf("FAIL setup (errno=%d)\n", errno); return 2; }

  /* C2: a dir that still holds its marker is a real run; a marker-less dir is the durable teardown phase. */
  check(zb_reaper_run_marker_state(runtime_fd, live) == ZB_RUN_MARKER_PRESENT,
        "a run dir holding run.marker -> PRESENT (a real run)");
  check(zb_reaper_run_marker_state(runtime_fd, teardown) == ZB_RUN_MARKER_TEARDOWN,
        "C2: a provenance-valid marker-less dir -> TEARDOWN (finish rmdir+remove, no signal, no permanent incident)");
  /* grammar + absent-dir fail closed (never reach another dir, never misclassify) */
  check(zb_reaper_run_marker_state(runtime_fd, ".") == ZB_RUN_MARKER_ERR, "\".\" -> ERR (grammar, never another dir)");
  check(zb_reaper_run_marker_state(runtime_fd, "zigbrowser-agent-9-0000000000000000") == ZB_RUN_MARKER_ERR,
        "a name with no dir -> ERR (fail closed)");

  /* C3: an active entry naming NO dir -> openat ENOENT -> GONE -> drop the entry, no signal. */
  struct zb_reaper_dir_id rec = {0};
  check(zb_reaper_ledger_entry_state(runtime_fd, "zigbrowser-agent-9-0000000000000000", &rec, 1) == ZB_LEDGER_GONE,
        "C3: an active entry naming no dir -> GONE (drop the entry, no signal)");

  const int ldfd2 = openat(runtime_fd, live, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (ldfd2 >= 0) { unlinkat(ldfd2, "run.marker", 0); close(ldfd2); }
  unlinkat(runtime_fd, live, AT_REMOVEDIR);
  unlinkat(runtime_fd, teardown, AT_REMOVEDIR);
  close(runtime_fd);
  rmdir(parent);

  if (failures == 0) { printf("PASS ledger-crashcut %d checks\n", total); return 0; }
  printf("FAIL ledger-crashcut %d of %d check(s) failed\n", failures, total);
  return 1;
}
