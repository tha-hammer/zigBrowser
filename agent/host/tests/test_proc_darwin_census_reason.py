"""The macOS CLI-environment census names WHY it is not clean (RoseCat 7986 / 33a9bf2, after the 2e07c7b Intel fd3 row
failed with a bare census=[False]): proc_darwin.cli_env_census(exe, root, token, canary) returns exactly one of the
fixed, token-free reasons
  ok, walk-unreadable, cli-not-found, env-unreadable, canary-missing, token-found
and production's boolean, proc_darwin.cli_env_clean, is True only for "ok" (still fail closed). The reason is a
constant: it never holds a pid, a path, argv, an environment value, the token or exception text.
A descendant that disappears during the walk is benign ONLY when its disappearance is confirmed (ESRCH: children()
raises ProcessLookupError or path() returns None, or a failing lookup immediately re-probes as gone) AND another live
CLI descendant is found and fully checked. Every other failure stays a failure:
- a child that vanishes between children() and path() (path fails, its re-probe says gone) beside a clean CLI -> ok;
- the vanished child was the only would-be CLI -> cli-not-found;
- a re-probe that still cannot read the child (it fails again, or finds it alive) -> walk-unreadable;
- a child list that fails and re-probes as gone is skipped; one that re-probes alive -> walk-unreadable; the
  root's own child list failing, ESRCH included, is always walk-unreadable with no re-probe of the root (the census
  never takes its root for vanished; RoseCat 7995 #1);
- a CLI whose KERN_PROCARGS2 cannot be read, even because it vanished -> env-unreadable;
- a CLI environment without the exact canary -> canary-missing; the token anywhere in its buffer -> token-found.
The walk's calls (children, path, environ_of) are faked; os.kill / os.killpg raise (the re-probe is never a signal).
Run like the gate: cd agent/host/tests && python -X dev -m unittest -v test_proc_darwin_census_reason
Unregistered until the green."""
import errno
import os
import unittest
from unittest import mock

import support  # noqa: F401  (puts the helper package on sys.path)

from zb_agent_host import proc_darwin

EXE = "/opt/claude"
TOKEN = b"zb-probe-" + b"cd" * 24
CANARY = b"ANTHROPIC_BASE_URL=http://127.0.0.1:50123"
REASONS = ("ok", "walk-unreadable", "cli-not-found", "env-unreadable", "canary-missing", "token-found")
ME = os.getpid()
GONE = object()  # this lookup returns "vanished" (path: None)


def leaky(cls):
    """An OSError whose text holds what a reason must never carry."""
    return cls(errno.EINVAL, f"pid 4242 {EXE} argv=--token env=ANTHROPIC_BASE_URL {TOKEN.decode()}")


class Census(unittest.TestCase):
    def setUp(self):
        for name in ("kill", "killpg"):
            p = mock.patch.object(os, name, side_effect=AssertionError(f"os.{name} reached"))
            p.start()
            self.addCleanup(p.stop)
        self.addCleanup(mock.patch.stopall)

    def census(self, tree, paths, envs=None):
        """tree: pid -> children or an exception; paths: pid -> a list of successive path() results (a str, GONE, or
        an exception), the last one repeating; envs: pid -> (argv, env) or an exception."""
        envs = {7: ([b"--x"], [CANARY]), 9: ([b"--y"], [CANARY])} if envs is None else envs
        self.path_calls = {}

        def children(pid):
            got = tree.get(pid, [])
            if isinstance(got, BaseException):
                raise got
            return list(got)

        def path(pid):
            n = self.path_calls[pid] = self.path_calls.get(pid, 0) + 1
            seq = paths.get(pid, [GONE])
            got = seq[min(n, len(seq)) - 1]
            if isinstance(got, BaseException):
                raise got
            return None if got is GONE else got

        def environ_of(pid):
            got = envs[pid]
            if isinstance(got, BaseException):
                raise got
            argv, env = got
            return b"\0".join([EXE.encode()] + argv + env), argv, env

        mock.patch.object(proc_darwin, "children", side_effect=children).start()
        mock.patch.object(proc_darwin, "path", side_effect=path).start()
        mock.patch.object(proc_darwin, "environ_of", side_effect=environ_of).start()
        if not hasattr(proc_darwin, "cli_env_census"):
            self.fail("proc_darwin.cli_env_census (the census's fixed reason) is missing (RoseCat 7986)")
        reason = proc_darwin.cli_env_census(EXE, ME, TOKEN, CANARY)
        calls, self.path_calls = self.path_calls, {}
        clean = proc_darwin.cli_env_clean(EXE, ME, TOKEN, CANARY)
        self.path_calls = calls  # the census's own lookups
        self.assertIn(reason, REASONS)
        self.assertIs(clean, reason == "ok", "the boolean is not derived from the reason")
        return reason

    def test_the_reasons_are_the_fixed_set(self):
        self.assertEqual(getattr(proc_darwin, "CENSUS_REASONS", None), REASONS)

    def test_one_clean_cli_is_ok(self):
        self.assertEqual(self.census({ME: [7]}, {7: [EXE]}), "ok")

    def test_a_child_vanishing_between_children_and_path_beside_a_live_cli_is_ok(self):
        tree = {ME: [8, 7]}
        self.assertEqual(self.census(tree, {8: [leaky(OSError), GONE], 7: [EXE]}), "ok")
        self.assertEqual(self.path_calls[8], 2, "the failing lookup is re-probed exactly once, immediately")
        self.assertEqual(self.census(tree, {8: [GONE], 7: [EXE]}), "ok")

    def test_the_vanished_child_as_the_only_would_be_cli_is_cli_not_found(self):
        self.assertEqual(self.census({ME: [8]}, {8: [leaky(OSError), GONE]}), "cli-not-found")
        self.assertEqual(self.census({ME: [8]}, {8: [GONE]}), "cli-not-found")
        self.assertEqual(self.census({ME: []}, {}), "cli-not-found")

    def test_a_reprobe_that_still_cannot_read_the_child_is_walk_unreadable(self):
        for label, seq in (("fails again", [leaky(OSError), leaky(PermissionError)]),
                           ("finds it alive", [leaky(OSError), "/usr/bin/python3"]),
                           ("alive as the CLI", [leaky(OSError), EXE])):
            with self.subTest(reprobe=label):
                self.assertEqual(self.census({ME: [8, 7]}, {8: seq, 7: [EXE]}), "walk-unreadable")

    def test_a_failing_child_list_is_skipped_only_when_it_reprobes_as_gone(self):
        self.assertEqual(self.census({ME: [7, 8], 8: ProcessLookupError(errno.ESRCH, "gone")},
                                     {7: [EXE], 8: ["/usr/bin/python3"]}), "ok")
        self.assertEqual(self.census({ME: [7, 8], 8: leaky(OSError)},
                                     {7: [EXE], 8: ["/usr/bin/python3", GONE]}), "ok")
        self.assertEqual(self.census({ME: [7, 8], 8: leaky(PermissionError)},
                                     {7: [EXE], 8: ["/usr/bin/python3"]}), "walk-unreadable")
        self.assertEqual(self.census({ME: leaky(PermissionError)}, {}), "walk-unreadable")
        self.assertNotIn(ME, self.path_calls, "the root was re-probed")

    def test_the_root_reported_as_vanished_is_walk_unreadable_without_a_reprobe(self):
        # RoseCat 7995 #1: ESRCH on the census's own root is never "vanished"; a catch-ProcessLookupError-everywhere
        # walk would skip it and say cli-not-found.
        self.assertEqual(self.census({ME: ProcessLookupError(errno.ESRCH, "gone")}, {7: [EXE]}), "walk-unreadable")
        self.assertNotIn(ME, self.path_calls, "the root was re-probed")

    def test_an_unreadable_cli_environment_is_env_unreadable(self):
        for exc in (leaky(OSError), ProcessLookupError(errno.ESRCH, "gone")):
            with self.subTest(exc=type(exc).__name__):
                self.assertEqual(self.census({ME: [7, 9]}, {7: [EXE], 9: [EXE]},
                                             {7: ([b"--x"], [CANARY]), 9: exc}), "env-unreadable")

    def test_a_cli_without_the_exact_canary_is_canary_missing(self):
        for env in ([], [CANARY + b"/v1"], [b"OTHER=1"]):
            with self.subTest(env=env):
                self.assertEqual(self.census({ME: [7]}, {7: [EXE]}, {7: ([b"--x"], env)}), "canary-missing")

    def test_the_token_anywhere_in_a_cli_buffer_is_token_found(self):
        for argv, env in (([b"--x"], [CANARY, b"T=" + TOKEN]), ([b"--t=" + TOKEN], [CANARY]),
                          ([b"--x"], [b"T=" + TOKEN])):
            with self.subTest(argv=argv, env=env):
                self.assertEqual(self.census({ME: [7, 9]}, {7: [EXE], 9: [EXE]},
                                             {7: ([b"--x"], [CANARY]), 9: (argv, env)}), "token-found")

    def test_a_reason_never_carries_a_pid_path_argv_env_value_token_or_exception_text(self):
        reasons = [self.census({ME: leaky(OSError)}, {}),
                   self.census({ME: [8]}, {8: [leaky(OSError), leaky(OSError)]}),
                   self.census({ME: [7]}, {7: [EXE]}, {7: leaky(OSError)})]
        self.assertEqual(reasons, ["walk-unreadable", "walk-unreadable", "env-unreadable"])
        for reason in reasons:
            self.assertRegex(reason, r"^[a-z]+(-[a-z]+)?$")  # no digit: no pid
            for leak in ("pid", EXE, "argv=", "--token", "ANTHROPIC_BASE_URL", TOKEN.decode(), "Errno", "Invalid"):
                self.assertNotIn(leak, reason)


if __name__ == "__main__":
    unittest.main()
