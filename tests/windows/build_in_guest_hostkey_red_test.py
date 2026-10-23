#!/usr/bin/env python3
r"""ong.23 RED (UNREGISTERED), NavyCanyon 8ab66913: tests/guest/build-in-guest.sh pins the guest's host key.

Today every scp/ssh call carries `StrictHostKeyChecking=no` and no pinned known_hosts, so an endpoint substitution
would receive the source archive and run the build. The ong.22 suite (build_in_guest_default_red_test.py) stays.

Pinned (the REAL script runs under bash with recording fake ssh/scp/tar/git first on PATH; ssh/scp answer nothing,
tar writes nothing, git only names the cwd):
  - ZB_GUEST_KNOWN_HOSTS is a third required selector with no fallback. With the host and key set and the pin unset
    or empty: rc 2, exactly one `refused:` line naming it, and no git/tar/scp/ssh call. With nothing set, the one
    `refused:` line names all three variables.
  - A nonempty pin must be a readable regular file (`-r` and `-f`) before git/tar/transport: a missing path, a
    directory or an unreadable file gives rc 2, one `refused:` line naming the pin, and no call.
  - Complete TEST-NET configuration (192.0.2.1, a key path under the temp dir, a real temp known_hosts file, also
    reached through a symlink): every scp AND every ssh call carries exactly -i <key>, IdentitiesOnly=yes,
    BatchMode=yes, StrictHostKeyChecking=yes, one UserKnownHostsFile=<the pin> and GlobalKnownHostsFile=none, and no
    other StrictHostKeyChecking, known-hosts source or /dev/null; every target is the TEST-NET host.
Run it, and every mutant, inside `unshare --user --map-current-user --net`. No real host value is ever passed.

Run alone:  unshare --user --map-current-user --net python3 -I tests/windows/build_in_guest_hostkey_red_test.py -v
"""
import os
import pathlib
import shlex
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / "tests" / "guest" / "build-in-guest.sh"
REFUSED_RC = 2
HOST = "zbtest@192.0.2.1"  # TEST-NET-1
PIN = "ZB_GUEST_KNOWN_HOSTS"

_FAKE = r"""#!/usr/bin/env bash
printf '%s' "$(basename "$0")" >> "$ZB_FAKE_LOG"; printf ' %q' "$@" >> "$ZB_FAKE_LOG"; printf '\n' >> "$ZB_FAKE_LOG"
case "$(basename "$0")" in
  git) [ "$*" = "rev-parse --show-toplevel" ] && pwd; exit 0 ;;
  tar) exit 0 ;;
  *) exit 0 ;;
esac
"""


def _options(argv):
    """The -o values and the -i key of one logged ssh/scp argv."""
    opts, keys = [], []
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "-o" and i + 1 < len(argv):
            opts.append(argv[i + 1]); i += 2; continue
        if a.startswith("-o") and len(a) > 2:
            opts.append(a[2:]); i += 1; continue
        if a == "-i" and i + 1 < len(argv):
            keys.append(argv[i + 1]); i += 2; continue
        i += 1
    return opts, keys


class BuildInGuestHostKeyPin(unittest.TestCase):
    def _run(self, pin_setup=None, env_over=None):
        """pin_setup(td) -> the ZB_GUEST_KNOWN_HOSTS value (or None to leave it unset)."""
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"
            bindir.mkdir()
            for name in ("ssh", "scp", "tar", "git"):
                (bindir / name).write_text(_FAKE)
                (bindir / name).chmod(0o755)
            log = td / "calls.log"
            log.write_text("")
            work = td / "work"
            work.mkdir()
            key = td / "explicit_key"
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td), "TMPDIR": str(td), "ZB_FAKE_LOG": str(log),
                   "ZB_GUEST_HOST": HOST, "ZB_GUEST_KEY": str(key)}
            pin = pin_setup(td) if pin_setup else None
            if pin is not None:
                env[PIN] = pin
            for k, v in (env_over or {}).items():
                if v is None:
                    env.pop(k, None)
                else:
                    env[k] = v
            proc = subprocess.run(["bash", str(SCRIPT)], cwd=work, env=env, capture_output=True, text=True,
                                  timeout=120, stdin=subprocess.DEVNULL)
            calls = [shlex.split(c) for c in log.read_text().splitlines()]
        detail = f"\nenv={ {k: v for k, v in env.items() if k.startswith('ZB_GUEST')} }\nrc={proc.returncode}" \
                 f"\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls: {calls}"
        return proc, calls, str(key), pin, detail

    def _assert_refused(self, proc, calls, names, detail):
        self.assertEqual(calls, [], "no git/tar/scp/ssh call before the pin is valid" + detail)
        self.assertEqual(proc.returncode, REFUSED_RC, "refused with rc 2" + detail)
        refused = [l for l in proc.stderr.splitlines() if "refused:" in l]
        self.assertEqual(len(refused), 1, "exactly one refused: diagnostic" + detail)
        for name in names:
            self.assertIn(name, refused[0], detail)

    # -- the pin is a required selector ------------------------------------------------------------------------
    def test_an_unset_pin_is_refused_before_any_call(self):
        proc, calls, _, _, detail = self._run()
        self._assert_refused(proc, calls, [PIN], detail)

    def test_an_empty_pin_is_refused_before_any_call(self):
        proc, calls, _, _, detail = self._run(lambda td: "")
        self._assert_refused(proc, calls, [PIN], detail)

    def test_nothing_set_names_every_missing_variable_once(self):
        proc, calls, _, _, detail = self._run(env_over={"ZB_GUEST_HOST": None, "ZB_GUEST_KEY": None})
        self._assert_refused(proc, calls, ["ZB_GUEST_HOST", "ZB_GUEST_KEY", PIN], detail)

    # -- the pin must be a readable regular file ------------------------------------------------------------------
    def test_a_pin_naming_a_missing_path_is_refused(self):
        proc, calls, _, pin, detail = self._run(lambda td: str(td / "no-such-known_hosts"))
        self._assert_refused(proc, calls, [PIN], detail)

    def test_a_pin_naming_a_directory_is_refused(self):
        def setup(td):
            (td / "khdir").mkdir()
            return str(td / "khdir")
        proc, calls, _, _, detail = self._run(setup)
        self._assert_refused(proc, calls, [PIN], detail)

    def test_an_unreadable_pin_is_refused(self):
        def setup(td):
            p = td / "known_hosts"
            p.write_text("192.0.2.1 ssh-ed25519 AAAA\n")
            p.chmod(0)
            return str(p)
        if os.geteuid() == 0:
            self.fail("run unprivileged: root can read a mode-000 file, so the -r case would prove nothing")
        proc, calls, _, _, detail = self._run(setup)
        self._assert_refused(proc, calls, [PIN], detail)

    # -- a complete configuration reaches the transport with exactly the pinned options -------------------------------
    def _assert_pinned(self, pin_setup):
        proc, calls, key, pin, detail = self._run(pin_setup)
        transport = [c for c in calls if c and c[0] in ("ssh", "scp")]
        self.assertTrue(any(c[0] == "scp" for c in transport), "the archive is copied" + detail)
        self.assertGreaterEqual(sum(c[0] == "ssh" for c in transport), 2, "extract + build over ssh" + detail)
        for argv in transport:
            opts, keys = _options(argv)
            where = f"\n{argv[0]} call: {argv}" + detail
            self.assertEqual(keys, [key], "exactly the explicit key" + where)
            for want in ("IdentitiesOnly=yes", "BatchMode=yes", "StrictHostKeyChecking=yes",
                         f"UserKnownHostsFile={pin}", "GlobalKnownHostsFile=none"):
                self.assertIn(want, opts, f"{want} on every call" + where)
            strict = [o for o in opts if o.lower().startswith("stricthostkeychecking=")]
            self.assertEqual(strict, ["StrictHostKeyChecking=yes"], "no other host-key policy" + where)
            sources = [o for o in opts if o.lower().startswith(("userknownhostsfile=", "globalknownhostsfile="))]
            self.assertEqual(sorted(sources), sorted([f"UserKnownHostsFile={pin}", "GlobalKnownHostsFile=none"]),
                             "the pin is the only known-hosts source" + where)
            self.assertFalse(any("/dev/null" in o for o in opts), where)
            targets = [a for a in argv[1:] if "@" in a and not a.startswith("-")]
            self.assertTrue(targets, where)
            for target in targets:
                self.assertEqual(target.split(":", 1)[0], HOST, "only the TEST-NET guest" + where)

    def test_a_complete_configuration_pins_every_ssh_and_scp_call(self):
        def setup(td):
            p = td / "known_hosts"
            p.write_text("192.0.2.1 ssh-ed25519 AAAA\n")
            return str(p)
        self._assert_pinned(setup)

    def test_a_symlink_to_a_readable_regular_pin_is_accepted(self):
        def setup(td):
            real = td / "real_known_hosts"
            real.write_text("192.0.2.1 ssh-ed25519 AAAA\n")
            link = td / "known_hosts_link"
            link.symlink_to(real)
            return str(link)
        self._assert_pinned(setup)


if __name__ == "__main__":
    unittest.main()
