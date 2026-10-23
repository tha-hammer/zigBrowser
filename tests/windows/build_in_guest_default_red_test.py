#!/usr/bin/env python3
r"""ong.22 RED (UNREGISTERED): tests/guest/build-in-guest.sh must not fall back to a real host or key.

Today it sets KEY="${ZB_GUEST_KEY:-/home/maceo/vms/win11-m8/zb_guest_key}" and
HOST="${ZB_GUEST_HOST:-maceo@100.103.8.90}", so a bare run tars the tree, copies it to that host and builds there.
The same hazard as ong.16 (msi_install_test.py, f320e1a4).

Pinned (the REAL script runs under bash with recording fake ssh/scp/tar/git first on PATH; ssh/scp answer nothing,
tar writes nothing, git only names the cwd as the top level):
  - a bare run (no ZB_GUEST_HOST/ZB_GUEST_KEY, or both empty) makes NO ssh, scp, tar or git call and exits 2 with a
    `refused:` line naming both missing variables;
  - a host without a key, and a key without a host, are refused the same way, with no call;
  - an explicit host and key (TEST-NET 192.0.2.1, a key file under the test's own temp dir) still reach the transport:
    the first ssh/scp call carries exactly that key and that host.
Run it, and every mutant, inside `unshare --user --map-current-user --net`. No real host value is ever passed.
ong.23 (8ab66913) added a third required selector, ZB_GUEST_KNOWN_HOSTS (its own suite is
build_in_guest_hostkey_red_test.py). Here the host/key cases carry a readable pin ({PIN}), so each still tests the
variable it is named for; the bare run names all three; the explicit control sets all three.

Run alone:  unshare --user --map-current-user --net python3 -I tests/windows/build_in_guest_default_red_test.py -v
"""
import pathlib
import shlex
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "tests" / "guest" / "build-in-guest.sh"
REFUSED_RC = 2
HOST = "zbtest@192.0.2.1"  # TEST-NET-1

_FAKE = r"""#!/usr/bin/env bash
printf '%s' "$(basename "$0")" >> "$ZB_FAKE_LOG"; printf ' %q' "$@" >> "$ZB_FAKE_LOG"; printf '\n' >> "$ZB_FAKE_LOG"
case "$(basename "$0")" in
  git) [ "$*" = "rev-parse --show-toplevel" ] && pwd; exit 0 ;;
  tar) exit 0 ;;
  *) echo "fake $(basename "$0"): no host here" >&2; exit 255 ;;
esac
"""


class BuildInGuestNoDefaultHost(unittest.TestCase):
    def _run(self, extra_env=None):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"
            bindir.mkdir()
            for name in ("ssh", "scp", "tar", "git"):
                (bindir / name).write_text(_FAKE)
                (bindir / name).chmod(0o755)
            log = td / "calls.log"
            log.write_text("")
            key = td / "explicit_key"
            key.write_text("not a key\n")
            pin = td / "known_hosts"
            pin.write_text("192.0.2.1 ssh-ed25519 AAAA\n")
            work = td / "work"
            work.mkdir()
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td), "ZB_FAKE_LOG": str(log)}
            env.update({k: v.replace("{KEY}", str(key)).replace("{PIN}", str(pin)) for k, v in (extra_env or {}).items()})
            proc = subprocess.run(["bash", str(SCRIPT)], cwd=work, env=env, capture_output=True, text=True,
                                  timeout=120, stdin=subprocess.DEVNULL)
            calls = [shlex.split(c) for c in log.read_text().splitlines()]
        detail = f"\nenv={extra_env}\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls: {calls}"
        return proc.returncode, proc.stderr, calls, str(key), detail

    def _assert_refused(self, extra_env, missing):
        rc, stderr, calls, _, detail = self._run(extra_env)
        self.assertEqual(calls, [], "no ssh, scp, tar or git call before the inputs are complete" + detail)
        self.assertEqual(rc, REFUSED_RC, "a refusal" + detail)
        refused = [l for l in stderr.splitlines() if "refused:" in l]
        self.assertTrue(refused, detail)
        for name in missing:
            self.assertIn(name, refused[0], detail)

    def test_a_bare_run_contacts_nothing_and_is_refused(self):
        self._assert_refused(None, ["ZB_GUEST_HOST", "ZB_GUEST_KEY", "ZB_GUEST_KNOWN_HOSTS"])
        self._assert_refused({"ZB_GUEST_HOST": "", "ZB_GUEST_KEY": "", "ZB_GUEST_KNOWN_HOSTS": ""},
                             ["ZB_GUEST_HOST", "ZB_GUEST_KEY", "ZB_GUEST_KNOWN_HOSTS"])

    def test_a_host_without_a_key_is_refused(self):
        self._assert_refused({"ZB_GUEST_HOST": HOST, "ZB_GUEST_KNOWN_HOSTS": "{PIN}"}, ["ZB_GUEST_KEY"])

    def test_a_key_without_a_host_is_refused(self):
        self._assert_refused({"ZB_GUEST_KEY": "{KEY}", "ZB_GUEST_KNOWN_HOSTS": "{PIN}"}, ["ZB_GUEST_HOST"])

    def test_an_explicit_host_and_key_reach_the_transport(self):
        _, _, calls, key, detail = self._run({"ZB_GUEST_HOST": HOST, "ZB_GUEST_KEY": "{KEY}",
                                              "ZB_GUEST_KNOWN_HOSTS": "{PIN}"})
        transport = [c for c in calls if c[0] in ("ssh", "scp")]
        self.assertTrue(transport, "the explicit host is reached" + detail)
        first = transport[0]
        self.assertEqual(first[first.index("-i") + 1], key, detail)
        self.assertTrue(any(a == HOST or a.startswith(HOST + ":") for a in first), detail)
        self.assertFalse([c for c in calls if any("100.103.8.90" in a for a in c)], detail)


if __name__ == "__main__":
    unittest.main()
