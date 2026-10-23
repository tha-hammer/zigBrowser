#!/usr/bin/env python3
r"""ong.16 RED (UNREGISTERED): tests/e2e/msi_install_test.py must not fall back to a real host or key.

Today it defaults --host to maceo@100.103.8.90 and --key to /home/maceo/vms/win11-m8/zb_guest_key (which exists on
the dev host), so a bare run probes that host over ssh, copies the repo, builds and installs an MSI. ZB_WIN* variables
do not stop it.

Pinned (the REAL main() runs in a child with a recording fake ssh/scp first on PATH; the fakes answer nothing):
  - a bare run (no --host/--key, no ZB_GUEST_HOST/ZB_GUEST_KEY) makes NO ssh or scp call and exits 2 with a
    `refused:` line naming both missing inputs; it is not a skip;
  - a host without a key, and a key without a host, are refused the same way, with no call;
  - an explicit host and key (TEST-NET 192.0.2.1, a key file under the test's own temp dir) still reach the transport:
    the first call is ssh with exactly that key and that host.
Run it, and every mutant, inside `unshare --user --map-current-user --net`. No real host value is ever passed.

Run alone:  unshare --user --map-current-user --net python3 -I tests/windows/msi_install_default_red_test.py -v
"""
import pathlib
import shlex
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
E2E = REPO / "tests" / "e2e"
REFUSED_RC = 2
HOST = "zbtest@192.0.2.1"  # TEST-NET-1

_FAKE = r"""#!/usr/bin/env bash
printf '%s' "$(basename "$0")" >> "$ZB_FAKE_LOG"; printf ' %q' "$@" >> "$ZB_FAKE_LOG"; printf '\n' >> "$ZB_FAKE_LOG"
echo "fake $(basename "$0"): no host here" >&2
exit 255
"""

_CHILD = r"""
import sys
sys.path.insert(0, sys.argv[1])
import msi_install_test as m
sys.argv = ["msi_install_test.py", *sys.argv[2:]]
try:
    rc = m.main()
except SystemExit as e:
    rc = e.code
print("RC", rc)
"""


class MsiInstallNoDefaultHost(unittest.TestCase):
    def _run(self, args, extra_env=None):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"
            bindir.mkdir()
            for name in ("ssh", "scp"):
                (bindir / name).write_text(_FAKE)
                (bindir / name).chmod(0o755)
            log = td / "calls.log"
            log.write_text("")
            key = td / "explicit_key"
            key.write_text("not a key\n")
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td), "ZB_FAKE_LOG": str(log)}
            env.update({k: v.replace("{KEY}", str(key)) for k, v in (extra_env or {}).items()})
            argv = [a.replace("{KEY}", str(key)) for a in args]
            proc = subprocess.run(["python3", "-I", "-c", _CHILD, str(E2E), *argv], cwd=td, env=env,
                                  capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
            calls = [shlex.split(c) for c in log.read_text().splitlines()]
        detail = f"\nargs={args} env={extra_env}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls: {calls}"
        rows = [l for l in proc.stdout.splitlines() if l.startswith("RC ")]
        self.assertEqual(len(rows), 1, "the child must report main()'s result" + detail)
        return rows[0][3:], proc.stderr, calls, str(key), detail

    def _assert_refused(self, args, extra_env, missing):
        rc, stderr, calls, _, detail = self._run(args, extra_env)
        self.assertEqual(calls, [], "no ssh or scp call before the inputs are complete" + detail)
        self.assertEqual(rc, str(REFUSED_RC), "a refusal, not a skip or a run" + detail)
        refused = [l for l in stderr.splitlines() if "refused:" in l]
        self.assertTrue(refused, detail)
        for name in missing:
            self.assertIn(name, refused[0], detail)

    def test_a_bare_run_contacts_nothing_and_is_refused(self):
        self._assert_refused([], None, ["ZB_GUEST_HOST", "ZB_GUEST_KEY"])

    def test_a_host_without_a_key_is_refused(self):
        self._assert_refused(["--host", HOST], None, ["ZB_GUEST_KEY"])
        self._assert_refused([], {"ZB_GUEST_HOST": HOST}, ["ZB_GUEST_KEY"])

    def test_a_key_without_a_host_is_refused(self):
        self._assert_refused(["--key", "{KEY}"], None, ["ZB_GUEST_HOST"])
        self._assert_refused([], {"ZB_GUEST_KEY": "{KEY}"}, ["ZB_GUEST_HOST"])

    def test_an_explicit_host_and_key_reach_the_transport(self):
        for args, env in ((["--host", HOST, "--key", "{KEY}"], None),
                          ([], {"ZB_GUEST_HOST": HOST, "ZB_GUEST_KEY": "{KEY}"})):
            with self.subTest(args=args, env=env):
                _, _, calls, key, detail = self._run(args, env)
                self.assertTrue(calls, "the explicit host is probed" + detail)
                first = calls[0]
                self.assertEqual(first[0], "ssh", detail)
                self.assertEqual(first[first.index("-i") + 1], key, detail)
                self.assertIn(HOST, first, detail)
                self.assertFalse([c for c in calls if any("100.103.8.90" in a for a in c)], detail)


if __name__ == "__main__":
    unittest.main()
