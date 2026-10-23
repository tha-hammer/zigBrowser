#!/usr/bin/env python3
"""zigBrowser-ong.17 R2 (NavyCanyon f52ef80): the live VM suite never runs from an inherited host environment.

gate_twohost_selftest.load_tests always imports tests/windows/host_live_test.py, and that module turned its live
cases on from an inherited ZB_WIN11_HOST alone. So the nominally hostless step `windows-twohost-selftest`, run from
a shell that sourced hosts.env, contacted the Win11 VM without a release. The contract pinned here:

  - host_live_test's live cases run only with an explicit ZB_HOST_LIVE=1 AND a complete Win11 configuration
    (ZB_WIN11_HOST, _PORT, _USER, _KEY and _KNOWN_HOSTS all set); otherwise they skip;
  - the registered hostless step launches through an environment that removes ZB_HOST_LIVE and every Win11, Win10
    and legacy host, key and known-hosts variable before anything is imported.

Every child here runs inside `unshare --user --map-current-user --net` (an empty network namespace), with a
recording fake ssh/scp first on PATH. The inherited values are deliberately real-looking (the VM address and the
real key paths): in the namespace no packet can leave even if both guards miss. `ssh -G` (config resolution, no
connection; the selftest's own oracle) is passed to the real ssh and not recorded.

The registered step is exercised through its own argv, read from build.zig, so a step that skips the scrub turns
this red.

Run alone:  python3 -I tests/windows/host_live_optin_test.py -v
"""
import os
import pathlib
import re
import shlex
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
STEP_CONST = "windows_twohost_selftest"
NETNS = ["unshare", "--user", "--map-current-user", "--net"]

_FAKE = r"""#!/usr/bin/env bash
if [ "${1:-}" = "-G" ]; then exec /usr/bin/ssh "$@"; fi
printf '%s' "$(basename "$0")" >> "$ZB_OPTIN_SSH_LOG"; printf ' %q' "$@" >> "$ZB_OPTIN_SSH_LOG"
printf '\n' >> "$ZB_OPTIN_SSH_LOG"
cat > /dev/null 2>&1
exit 255
"""

# real-looking: the VM address and the real key paths (safe only because every child runs in NETNS)
COMPLETE_WIN11 = {
    "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222", "ZB_WIN11_USER": "zbtext",
    "ZB_WIN11_KEY": "/home/maceo/vms/win11-m8/zb_win_key",
    "ZB_WIN11_KNOWN_HOSTS": "/home/maceo/vms/win11-m8/known_hosts",
}
INHERITED = {
    **COMPLETE_WIN11,
    "ZB_WIN_KEY": "/home/maceo/vms/win11-m8/zb_win_key",
    "ZB_WIN_KNOWN_HOSTS": "/home/maceo/vms/win11-m8/known_hosts",
    "ZB_WIN10_HOST": "100.123.34.15", "ZB_WIN10_PORT": "22", "ZB_WIN10_USER": "zbtest",
    "ZB_WIN10_KEY": "/home/maceo/vms/win11-m8/zb_win_key",
    "ZB_WIN10_KNOWN_HOSTS": "/home/maceo/vms/win10-fs/known_hosts",
}

SCRUBBED = ("ZB_HOST_LIVE", *INHERITED, "ZB_WIN10_LISTEN")


def step_argv():
    """The argv of the registered windows-twohost-selftest command, as build.zig declares it."""
    src = (REPO / "build.zig").read_text()
    m = re.search(r"const " + STEP_CONST + r" = b\.addSystemCommand\(&\.\{(.*?)\}\);", src, re.S)
    if not m:
        raise AssertionError(f"build.zig declares no `const {STEP_CONST} = b.addSystemCommand(...)`")
    return re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))


class HostLiveOptIn(unittest.TestCase):
    def _run(self, argv, extra):
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            bindir = td / "bin"; bindir.mkdir()
            for name in ("ssh", "scp"):
                (bindir / name).write_text(_FAKE); (bindir / name).chmod(0o755)
            log = td / "ssh.log"; log.write_text("")
            env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td / "home"), "TMPDIR": str(td),
                   "ZB_OPTIN_SSH_LOG": str(log), **extra}
            (td / "home").mkdir()
            proc = subprocess.run([*NETNS, *argv], cwd=REPO, env=env, capture_output=True, text=True,
                                  timeout=300, stdin=subprocess.DEVNULL)
            calls = log.read_text().splitlines()
        detail = (f"\nargv: {shlex.join(argv)}\nrc={proc.returncode}\nstdout:\n{proc.stdout[-2000:]}"
                  f"\nstderr:\n{proc.stderr[-3000:]}\nssh/scp calls:\n" + "\n".join(calls))
        self.assertNotIn("unshare: ", proc.stderr, "the network namespace must start" + detail)
        return proc, calls, detail

    def _live(self, extra):
        return self._run(["python3", "-I", "tests/windows/host_live_test.py", "-v"], extra)

    # --- the registered hostless step ---------------------------------------------------------------------
    def test_step_argv_removes_the_opt_in_and_every_host_variable(self):
        # tripwire (each layer alone is proven by the runs below): the scrub names the opt-in and every
        # inherited host, key and known_hosts variable, before the interpreter starts
        argv = step_argv()
        head = argv[:argv.index("python3")] if "python3" in argv else argv
        removed = {head[i + 1] for i, a in enumerate(head[:-1]) if a == "-u"}
        self.assertEqual(head[:1], ["env"], f"the step must start through `env -u ...`: {argv}")
        self.assertEqual(set(SCRUBBED) - removed, set(), f"the step does not remove these: {argv}")

    def test_registered_step_runs_no_ssh_with_an_inherited_opt_in_and_hosts(self):
        proc, calls, detail = self._run(step_argv(), {"ZB_HOST_LIVE": "1", **INHERITED})
        self.assertEqual(calls, [], "the hostless step executed ssh/scp from inherited host variables" + detail)
        self.assertEqual(proc.returncode, 0, "the hostless step must still pass" + detail)

    def test_registered_step_runs_no_ssh_with_inherited_hosts_alone(self):
        proc, calls, detail = self._run(step_argv(), INHERITED)
        self.assertEqual(calls, [], "the hostless step executed ssh/scp from inherited host variables" + detail)
        self.assertEqual(proc.returncode, 0, detail)

    # --- host_live_test run directly ----------------------------------------------------------------------
    def test_direct_live_cases_skip_without_the_opt_in(self):
        proc, calls, detail = self._live(COMPLETE_WIN11)
        self.assertEqual(calls, [], "live cases ran without ZB_HOST_LIVE=1" + detail)
        self.assertEqual(proc.returncode, 0, detail)
        self.assertIn("skipped", proc.stderr, detail)

    def test_direct_live_cases_skip_with_the_opt_in_but_incomplete_config(self):
        for missing in COMPLETE_WIN11:
            with self.subTest(missing=missing):
                cfg = {k: v for k, v in COMPLETE_WIN11.items() if k != missing}
                proc, calls, detail = self._live({"ZB_HOST_LIVE": "1", **cfg})
                self.assertEqual(calls, [], f"live cases ran without {missing}" + detail)
                self.assertEqual(proc.returncode, 0, detail)

    def test_direct_live_cases_run_with_the_opt_in_and_complete_config(self):
        # positive control: the guard is not simply always off. The fake ssh refuses (rc 255), so the live
        # cases fail; what matters is that they reached ssh, aimed at the configured host and key.
        proc, calls, detail = self._live({"ZB_HOST_LIVE": "1", **COMPLETE_WIN11})
        self.assertTrue(calls, "with the opt-in and a complete config the live cases must run" + detail)
        self.assertTrue(all("zbtext@127.0.0.1" in c and "/home/maceo/vms/win11-m8/zb_win_key" in c for c in calls),
                        detail)


if __name__ == "__main__":
    unittest.main()
