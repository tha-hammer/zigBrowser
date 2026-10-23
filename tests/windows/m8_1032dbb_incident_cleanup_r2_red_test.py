#!/usr/bin/env python3
r"""m8 1032dbb incident cleanup R2 RED (UNREGISTERED), NavyCanyon 9b8b94e0: stop at the FIRST failed stop; check the
%LOCALAPPDATA%\zig baseline before anything is stopped or deleted.

9b8b94e0 reproduced two fail-closed defects in a08ac3f4:
  1. the stop step answered MISMATCH (pid 752 reused) or ERROR for one target but still stopped the later pinned
     target 5796, because the whole stop list went to the host in one loop;
  2. a %LOCALAPPDATA%\zig snapshot that already differed from the pinned baseline let all nine stops and both folder
     deletions happen before the final check failed.
Pinned here, in the pinned identity order (5428, 4732, 2344, 2796, 7932, 1676, 6240, 752, 5796):
  - a stop re-check MISMATCH at 752 ends the stop step: the later 5796 is never sent a stop, stays alive and is not
    stopped; nothing is deleted;
  - a stop ERROR at 752: the same;
  - a first %LOCALAPPDATA%\zig snapshot that is not the pinned baseline stops the script with zero stops and zero
    rmdirs (no stop probe is sent at all).
Reuses the registered selftest's harness (m8_1032dbb_incident_cleanup_selftest.py: the fake VM, every run inside
`unshare --user --map-current-user --net`).

Run alone:  python3 -I tests/windows/m8_1032dbb_incident_cleanup_r2_red_test.py -v
"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import m8_1032dbb_incident_cleanup_selftest as base  # noqa: E402

LATER = 5796  # the pinned target after 752 in the fixed order


class IncidentCleanupR2Red(unittest.TestCase):
    _run = base.IncidentCleanup._run
    _stop_targets = staticmethod(base.IncidentCleanup._stop_targets)

    def _later_target_untouched(self, calls, final, detail):
        self.assertNotIn(LATER, self._stop_targets(calls), "no stop is sent after the first failed stop" + detail)
        self.assertNotIn(LATER, final.get("stopped", []), "the later target is not stopped" + detail)
        self.assertEqual(final["procs"].get(str(LATER)), base.IDS[LATER], "the later target is still alive" + detail)
        self.assertEqual(final.get("rmdirs", []), [], "nothing is deleted" + detail)

    def test_a_recheck_mismatch_ends_the_stop_step_before_any_later_target(self):
        imposter = ["zigBrowser", "639283499999999999"]
        proc, calls, final, detail = self._run(swap_before_stop={"752": imposter})
        self.assertEqual(proc.returncode, 1, detail)
        self.assertNotIn(752, final.get("stopped", []), "the imposter is not stopped" + detail)
        self._later_target_untouched(calls, final, detail)

    def test_a_stop_error_ends_the_stop_step_before_any_later_target(self):
        proc, calls, final, detail = self._run(stop_error=["752"])
        self.assertEqual(proc.returncode, 1, detail)
        self._later_target_untouched(calls, final, detail)

    def test_a_localappdata_zig_off_baseline_stops_before_any_stop_or_rmdir(self):
        proc, calls, final, detail = self._run(localappdata="files=978 bytes=98934750 listing_sha256=00ff")
        self.assertEqual(proc.returncode, 1, detail)
        self.assertIn("baseline", proc.stdout, "the stop names the baseline mismatch" + detail)
        self.assertEqual(self._stop_targets(calls), [], "no stop probe at all" + detail)
        self.assertEqual(final.get("stopped", []), [], "zero stops" + detail)
        self.assertEqual(final.get("rmdirs", []), [], "zero rmdirs" + detail)
        self.assertEqual(sorted(int(p) for p in final["procs"]), sorted({**base.IDS, **base.OTHER}), detail)


if __name__ == "__main__":
    unittest.main()
