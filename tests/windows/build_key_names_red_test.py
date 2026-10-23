#!/usr/bin/env python3
"""WS0.8 RED (UNREGISTERED): the build driver honours the gate's per-host key names, ZB_WIN11_KEY first.

Plan rev 2.21 WS0.8 OPEN list: "`build-on-windows.sh:109-112` ... reads `ZB_WIN_KEY` while the gate reads
`ZB_WIN11_KEY` (one name, `ZB_WIN11_KEY`)". Today a caller that sets the gate's ZB_WIN11_KEY /
ZB_WIN11_KNOWN_HOSTS (as hosts.env.example does) gets the driver's built-in default key and known_hosts instead,
silently. The gate's own precedence is ZB_WIN11_* first, then the legacy ZB_WIN_*, then the default.

Drives the REAL tests/windows/build-on-windows.sh with build_on_windows_selftest.py's fake git/ssh/scp/timeout and
reads the -i and UserKnownHostsFile of every ssh/scp call the driver made. The green moves these cases into
build_on_windows_selftest.py (step windows-build-selftest).

Run alone:  python3 -I tests/windows/build_key_names_red_test.py -v
"""
import pathlib
import shlex
import shutil
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import build_on_windows_selftest as bow  # noqa: E402


def _transport_calls(td: pathlib.Path) -> list[list[str]]:
    calls = []
    for name in ("ssh.log", "scp.log"):
        p = td / name
        for line in (p.read_text().splitlines() if p.exists() else []):
            if line.startswith("ARGV: "):
                calls.append(shlex.split(line[len("ARGV: "):], posix=True))
    return calls


def _opts(argv: list[str]) -> tuple[set[str], set[str]]:
    keys, khs = set(), set()
    for i, a in enumerate(argv):
        if a == "-i" and i + 1 < len(argv):
            keys.add(argv[i + 1])
        if a == "-o" and i + 1 < len(argv) and argv[i + 1].startswith("UserKnownHostsFile="):
            khs.add(argv[i + 1].split("=", 1)[1])
    return keys, khs


class BuildDriverKeyNamesRed(bow._Case):
    def test_zb_win11_key_and_known_hosts_are_used(self):
        def extra(td):
            return {"ZB_WIN11_KEY": str(td / "k11"), "ZB_WIN11_KNOWN_HOSTS": str(td / "kh11")}
        keys, khs, td, detail = self._run_with(extra, unset=["ZB_WIN_KEY", "ZB_WIN_KNOWN_HOSTS"])
        self.assertEqual(keys, {str(td / "k11")}, "every ssh/scp must use ZB_WIN11_KEY" + detail)
        self.assertEqual(khs, {str(td / "kh11")}, "every ssh/scp must pin ZB_WIN11_KNOWN_HOSTS" + detail)

    def test_zb_win11_names_win_over_the_legacy_names(self):
        def extra(td):
            return {"ZB_WIN11_KEY": str(td / "k11"), "ZB_WIN11_KNOWN_HOSTS": str(td / "kh11")}
        keys, khs, td, detail = self._run_with(extra, unset=[])   # ZB_WIN_KEY / ZB_WIN_KNOWN_HOSTS also set
        self.assertEqual(keys, {str(td / "k11")}, "ZB_WIN11_KEY takes precedence, as in the gate" + detail)
        self.assertEqual(khs, {str(td / "kh11")}, detail)

    def test_legacy_names_still_work_alone(self):
        keys, khs, td, detail = self._run_with(lambda td: {}, unset=[])
        self.assertEqual(keys, {str(td / "key")}, "the legacy ZB_WIN_KEY stays a fallback" + detail)
        self.assertEqual(khs, {str(td / "kh")}, detail)

    def _run_with(self, extra_fn, unset):
        t = tempfile.mkdtemp(prefix="zb-bkn-")
        self.addCleanup(shutil.rmtree, t, True)
        td = pathlib.Path(t)
        (td / "k11").write_text("x"); (td / "kh11").write_text("#")
        proc = self._run(td, extra=extra_fn(td), unset=unset)
        detail = f"\nrc={proc.returncode}\nstderr:\n{proc.stderr}"
        self.assertEqual(proc.returncode, 0, "the faked build must still succeed" + detail)
        calls = _transport_calls(td)
        self.assertTrue(calls, "the driver made ssh/scp calls" + detail)
        keys, khs = set(), set()
        for c in calls:
            k, h = _opts(c)
            keys |= k; khs |= h
        return keys, khs, td, detail + "\ncalls:\n" + "\n".join(map(shlex.join, calls))


if __name__ == "__main__":
    unittest.main()
