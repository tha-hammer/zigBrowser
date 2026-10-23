#!/usr/bin/env python3
r"""Win10 probe R2 RED (UNREGISTERED), NavyCanyon 13a73828: discovery is unconditionally read-only; the legacy-scp
check is a distinct, marker-gated, fail-closed mode.

13a73828 blocked 8f85a9f1: with zb\ present, `--run` copied, read and deleted a file (not read-only before first
contact), and it returned 0 when the copy or the read-back failed. Pinned here:
  - `--run` (first-contact discovery) never copies, reads back or deletes, even when zb\ exists: only the host-key
    pin, the streamed facts and cmd.exe's `if exist`; scp_legacy / scp_cleanup report `not run: read-only discovery`
    / `not run`;
  - `--scp-check <literal marker>` is the distinct mode. It writes nothing unless the box's marker equals that literal
    and zb\ exists; it returns 1 on a failed copy, a mismatched read-back or a file left behind, and 0 only with
    scp_legacy=ok and scp_cleanup=gone; a marker argument that is not a plain token is refused before any contact.
Reuses the registered selftest's fake box (win10_probe_selftest.py; every run inside
`unshare --user --map-current-user --net`, the pinned transport asserted on every call).

Run alone:  python3 -I tests/windows/win10_probe_r2_red_test.py -v
"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import win10_probe_selftest as base  # noqa: E402

MARKER = "zb-win10-fs-2026-10-23"
SCP = ("--scp-check", MARKER)


class Win10ProbeR2Red(unittest.TestCase):
    _run = base.Win10Probe._run

    @staticmethod
    def _writes(calls):
        """Every call that could write or delete: scp, and ssh `type`/`del` (the copy's read-back and removal)."""
        return [c for c in calls if c["tool"] == "scp"
                or (c["tool"] == "ssh" and c["argv"][-1].startswith(("del ", "type ")))]

    def test_discovery_is_read_only_even_with_a_zb_dir(self):
        proc, calls, final, fields, detail = self._run(facts={"zb_dir": "present"})
        self.assertEqual(proc.returncode, 0, detail)
        self.assertEqual(self._writes(calls), [], "no copy, read-back or delete in discovery" + detail)
        self.assertEqual(final["files"], {}, detail)
        self.assertEqual(final.get("dels", []), [], detail)
        self.assertEqual(fields["scp_legacy"], "not run: read-only discovery", detail)
        self.assertEqual(fields["scp_cleanup"], "not run", detail)
        for name in ("hostkey", "marker", "zb_dir", "webview2_pv", "c_free_bytes", "python", "powershell_ok", "os",
                     "user", "cmd_if_exist"):
            self.assertIn(name, fields, f"field {name}" + detail)

    def test_scp_check_succeeds_only_with_ok_and_gone(self):
        proc, calls, final, fields, detail = self._run(args=SCP, facts={"marker": MARKER})
        self.assertEqual(proc.returncode, 0, detail)
        self.assertEqual((fields["scp_legacy"], fields["scp_cleanup"]), ("ok", "gone"), detail)
        self.assertEqual(final["files"], {}, detail)

    def test_scp_check_failed_copy_returns_1(self):
        proc, calls, final, fields, detail = self._run(args=SCP, facts={"marker": MARKER}, scp_fail=True)
        self.assertEqual(proc.returncode, 1, "a failed copy is a failed check" + detail)
        self.assertTrue(fields["scp_legacy"].startswith("fail"), detail)

    def test_scp_check_mismatched_readback_returns_1_and_still_removes_the_file(self):
        proc, calls, final, fields, detail = self._run(args=SCP, facts={"marker": MARKER}, readback="garbage")
        self.assertEqual(proc.returncode, 1, "a mismatched read-back is a failed check" + detail)
        self.assertEqual(fields["scp_cleanup"], "gone", detail)
        self.assertEqual(final["files"], {}, detail)

    def test_scp_check_file_left_returns_1(self):
        proc, calls, final, fields, detail = self._run(args=SCP, facts={"marker": MARKER}, del_fail=True)
        self.assertEqual(proc.returncode, 1, detail)
        self.assertEqual(fields["scp_cleanup"], "left", detail)

    def test_scp_check_writes_nothing_without_the_literal_marker(self):
        for marker in ("absent", "zb-someone-else"):
            with self.subTest(marker=marker):
                proc, calls, final, fields, detail = self._run(args=SCP, facts={"marker": marker})
                self.assertEqual(proc.returncode, 1, detail)
                self.assertEqual(self._writes(calls), [], "no write without the literal marker" + detail)

    def test_scp_check_writes_nothing_without_a_zb_dir(self):
        proc, calls, final, fields, detail = self._run(args=SCP, facts={"marker": MARKER, "zb_dir": "absent"})
        self.assertEqual(proc.returncode, 1, detail)
        self.assertEqual(self._writes(calls), [], detail)

    def test_a_marker_argument_that_is_not_a_plain_token_is_refused_before_contact(self):
        for bad in ("", "a b", 'x" & del *', "x;y", "../zb"):
            with self.subTest(marker=bad):
                proc, calls, final, fields, detail = self._run(args=("--scp-check", bad))
                self.assertEqual(proc.returncode, 2, detail)
                self.assertEqual([c for c in calls if c["tool"] != "ssh-keygen"], [], detail)


if __name__ == "__main__":
    unittest.main()
