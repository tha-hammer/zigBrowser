/* MS6.5.1 red (plan "Provenance" row). The run ledger's per-entry creation-provenance decision, on REAL Linux
 * directories (openat O_NOFOLLOW + fstat, like the pin test) — NO signals, no fake ops. UNREGISTERED until green.
 *
 * Contract: a recorded run dir is swept ONLY when an ACTIVE entry's basename reopens to a 0700 this-uid dir whose
 * fstat (dev,ino,uid,mode) matches the recorded tuple EXACTLY. Every other shape is census/warn, never a signal:
 *   - a basename that no longer exists      -> ZB_LEDGER_GONE
 *   - a swapped/replaced dir (new dev,ino)   -> ZB_LEDGER_MISMATCH   (the fork of a planted-dir attack)
 *   - a symlink at the basename              -> ZB_LEDGER_MISMATCH   (O_NOFOLLOW refuses it)
 *   - a changed mode (0755)                  -> ZB_LEDGER_MISMATCH
 *   - a non-`active` (e.g. `left`) entry     -> ZB_LEDGER_NOT_ACTIVE
 *
 * The mutant this catches (the plan's "drop the fstat match"): a decision that reopens the basename but never
 * compares (dev,ino,uid,mode) to the record would SWEEP a swapped or mode-changed dir. */
#include "agent_run_reaper.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures = 0, total = 0;
static void check(int ok, const char *m) { total++; printf("  %s %s\n", ok ? "ok" : "FAIL", m); if (!ok) failures++; }

/* Record the id of a freshly-created 0700 dir, exactly as the owner would pin it at creation. 0 on success. */
static int record_id(int runtime_fd, const char *name, struct zb_reaper_dir_id *out) {
  const int fd = openat(runtime_fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return -1;
  const int rc = zb_reaper_pin_fd(fd, out);
  close(fd);
  return rc == 0 ? 0 : -1;
}

int main(void) {
  char parent[] = "/tmp/zb-ledger-XXXXXX";
  if (mkdtemp(parent) == NULL) { printf("FAIL mkdtemp\n"); return 2; }
  const int runtime_fd = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  if (runtime_fd < 0) { printf("FAIL open runtime\n"); rmdir(parent); return 2; }

  const char *match_name = "zigbrowser-agent-1234-0011223344556677";
  const char *swap_name = "zigbrowser-agent-1234-00112233445566aa";
  const char *mode_name = "zigbrowser-agent-1234-00112233445566bb";
  const char *link_name = "zigbrowser-agent-1234-00112233445566cc";
  const char *gone_name = "zigbrowser-agent-1234-00112233445566dd";

  struct zb_reaper_dir_id rec_match, rec_swap, rec_mode;
  int setup = 1;
  setup = setup && mkdirat(runtime_fd, match_name, 0700) == 0 && record_id(runtime_fd, match_name, &rec_match) == 0;
  /* swap: create, record, then remove + recreate -> a new (dev,ino) at the same name */
  setup = setup && mkdirat(runtime_fd, swap_name, 0700) == 0 && record_id(runtime_fd, swap_name, &rec_swap) == 0;
  setup = setup && unlinkat(runtime_fd, swap_name, AT_REMOVEDIR) == 0 && mkdirat(runtime_fd, swap_name, 0700) == 0;
  /* mode: create 0700, record, then chmod 0755 */
  setup = setup && mkdirat(runtime_fd, mode_name, 0700) == 0 && record_id(runtime_fd, mode_name, &rec_mode) == 0;
  setup = setup && fchmodat(runtime_fd, mode_name, 0755, 0) == 0;
  /* link: a symlink where a run dir would be */
  setup = setup && symlinkat(match_name, runtime_fd, link_name) == 0;
  if (!setup) { printf("FAIL setup (errno=%d)\n", errno); return 2; }

  check(zb_reaper_ledger_entry_state(runtime_fd, match_name, &rec_match, 1) == ZB_LEDGER_SWEEP,
        "an ACTIVE entry whose dir matches (dev,ino,uid,mode) is SWEEP");
  check(zb_reaper_ledger_entry_state(runtime_fd, gone_name, &rec_match, 1) == ZB_LEDGER_GONE,
        "a basename that does not exist is GONE");
  check(zb_reaper_ledger_entry_state(runtime_fd, swap_name, &rec_swap, 1) == ZB_LEDGER_MISMATCH,
        "a swapped/replaced dir (new dev,ino) is MISMATCH, never swept");
  check(zb_reaper_ledger_entry_state(runtime_fd, mode_name, &rec_mode, 1) == ZB_LEDGER_MISMATCH,
        "a changed-mode (0755) dir is MISMATCH, never swept");
  check(zb_reaper_ledger_entry_state(runtime_fd, link_name, &rec_match, 1) == ZB_LEDGER_MISMATCH,
        "a symlink at the basename is MISMATCH (O_NOFOLLOW refuses it), never swept");
  check(zb_reaper_ledger_entry_state(runtime_fd, match_name, &rec_match, 0) == ZB_LEDGER_NOT_ACTIVE,
        "a non-active (e.g. `left`) entry is NOT_ACTIVE, never swept");
  check(zb_reaper_ledger_entry_state(-1, match_name, &rec_match, 1) == ZB_LEDGER_EINVAL, "bad runtime_fd is EINVAL");
  check(zb_reaper_ledger_entry_state(runtime_fd, NULL, &rec_match, 1) == ZB_LEDGER_EINVAL, "null basename is EINVAL");
  check(zb_reaper_ledger_entry_state(runtime_fd, match_name, NULL, 1) == ZB_LEDGER_EINVAL, "null rec is EINVAL");

  /* cleanup */
  unlinkat(runtime_fd, match_name, AT_REMOVEDIR);
  unlinkat(runtime_fd, swap_name, AT_REMOVEDIR);
  unlinkat(runtime_fd, mode_name, AT_REMOVEDIR);
  unlinkat(runtime_fd, link_name, 0);
  close(runtime_fd);
  rmdir(parent);

  if (failures == 0) { printf("PASS ledger-provenance %d checks\n", total); return 0; }
  printf("FAIL ledger-provenance %d of %d check(s) failed\n", failures, total);
  return 1;
}
