/* MS6.5.1 red (RoseCat 2f57b1e). Strengthens the ledger provenance decision at its boundary. REAL Linux dirs
 * (openat O_NOFOLLOW + fstat) — NO signals. UNREGISTERED until green.
 *
 * (1) EXACT (dev,ino,uid,mode) match: from ONE valid record, change exactly ONE field at a time; each must be
 *     MISMATCH. This pins all four fields of the comparison — a dev+ino-only check would SWEEP the uid-only and
 *     mode-only rows. (pin_fd already enforces this-uid/0700 on the REOPENED dir, so these perturb the RECORD.)
 * (2) SINGLE-COMPONENT GRAMMAR at the openat boundary: the basename must be exactly
 *     zigbrowser-agent-<pid>-<16 lowercase hex> and a single path component. A ".", "..", absolute path, embedded
 *     slash, or wrong prefix/case/length must NEVER reach another directory or SWEEP. The causal case is "."
 *     with a record equal to the runtime dir's own id: without the grammar gate, openat(runtime_fd, ".") reopens
 *     the runtime dir, matches, and SWEEPs. */
#include "agent_run_reaper.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures = 0, total = 0;
static void check(int ok, const char *m) { total++; printf("  %s %s\n", ok ? "ok" : "FAIL", m); if (!ok) failures++; }

static int pin_name(int runtime_fd, const char *name, struct zb_reaper_dir_id *out) {
  const int fd = openat(runtime_fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -1;
  const int rc = zb_reaper_pin_fd(fd, out);
  close(fd);
  return rc == 0 ? 0 : -1;
}

int main(void) {
  char parent[] = "/tmp/zb-ledgerb-XXXXXX";
  if (mkdtemp(parent) == NULL) { printf("FAIL mkdtemp\n"); return 2; }
  if (chmod(parent, 0700) != 0) { printf("FAIL chmod parent\n"); rmdir(parent); return 2; }
  const int runtime_fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (runtime_fd < 0) { printf("FAIL open runtime\n"); rmdir(parent); return 2; }

  const char *valid = "zigbrowser-agent-1234-0011223344556677";
  struct zb_reaper_dir_id rec_valid, rec_runtime;
  int setup = mkdirat(runtime_fd, valid, 0700) == 0 && pin_name(runtime_fd, valid, &rec_valid) == 0 &&
              zb_reaper_pin_fd(runtime_fd, &rec_runtime) == 0; /* the runtime dir is 0700/this-uid (mkdtemp+chmod) */
  if (!setup) { printf("FAIL setup (errno=%d)\n", errno); return 2; }

  /* (1) EXACT four-field comparison: one field wrong at a time -> MISMATCH */
  struct zb_reaper_dir_id r;
  r = rec_valid; r.dev = rec_valid.dev + 1;
  check(zb_reaper_ledger_entry_state(runtime_fd, valid, &r, 1) == ZB_LEDGER_MISMATCH, "wrong dev only -> MISMATCH");
  r = rec_valid; r.ino = rec_valid.ino + 1;
  check(zb_reaper_ledger_entry_state(runtime_fd, valid, &r, 1) == ZB_LEDGER_MISMATCH, "wrong ino only -> MISMATCH");
  r = rec_valid; r.uid = rec_valid.uid + 1;
  check(zb_reaper_ledger_entry_state(runtime_fd, valid, &r, 1) == ZB_LEDGER_MISMATCH, "wrong uid only -> MISMATCH");
  r = rec_valid; r.mode = rec_valid.mode + 1;
  check(zb_reaper_ledger_entry_state(runtime_fd, valid, &r, 1) == ZB_LEDGER_MISMATCH, "wrong mode only -> MISMATCH");
  /* control: the exact record still sweeps */
  check(zb_reaper_ledger_entry_state(runtime_fd, valid, &rec_valid, 1) == ZB_LEDGER_SWEEP, "the exact record -> SWEEP");

  /* (2) single-component grammar at the boundary -> never reach another dir, never SWEEP */
  check(zb_reaper_ledger_entry_state(runtime_fd, ".", &rec_runtime, 1) == ZB_LEDGER_MISMATCH,
        "\".\" (reopens the runtime dir, id matches) is refused by the grammar -> MISMATCH, never SWEEP");
  check(zb_reaper_ledger_entry_state(runtime_fd, "..", &rec_valid, 1) == ZB_LEDGER_MISMATCH, "\"..\" -> MISMATCH");
  check(zb_reaper_ledger_entry_state(runtime_fd, "/etc", &rec_valid, 1) == ZB_LEDGER_MISMATCH, "absolute path -> MISMATCH");
  check(zb_reaper_ledger_entry_state(runtime_fd, "zigbrowser-agent-1234-0011223344556677/x", &rec_valid, 1) == ZB_LEDGER_MISMATCH,
        "embedded slash -> MISMATCH");
  check(zb_reaper_ledger_entry_state(runtime_fd, "notzigbrowser-1234-0011223344556677", &rec_valid, 1) == ZB_LEDGER_MISMATCH,
        "wrong prefix -> MISMATCH");
  check(zb_reaper_ledger_entry_state(runtime_fd, "zigbrowser-agent-1234-00112233445566AA", &rec_valid, 1) == ZB_LEDGER_MISMATCH,
        "uppercase hex -> MISMATCH");
  check(zb_reaper_ledger_entry_state(runtime_fd, "zigbrowser-agent-1234-001122334455667", &rec_valid, 1) == ZB_LEDGER_MISMATCH,
        "wrong length (15 hex) -> MISMATCH");

  unlinkat(runtime_fd, valid, AT_REMOVEDIR);
  close(runtime_fd);
  rmdir(parent);

  if (failures == 0) { printf("PASS ledger-boundary %d checks\n", total); return 0; }
  printf("FAIL ledger-boundary %d of %d check(s) failed\n", failures, total);
  return 1;
}
