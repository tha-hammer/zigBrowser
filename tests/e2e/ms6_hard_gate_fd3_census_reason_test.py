"""The MS6.3 hard-gate case (tests/mac/hard_gate/case_ms6_3_fd3_cli.py) records the census's fixed REASON, not a bare
bool (RoseCat 7986 / 33a9bf2, after the 2e07c7b Intel positive row failed with census=[False] and no way to tell
why). On Linux with the fd3 case test's FAKE staged zb_agent_host (ms6_hard_gate_fd3_cli_case_test), whose fake
proc_darwin here offers cli_env_census returning a chosen reason:
- while the request is served, the case calls production's proc_darwin.cli_env_census once per calling row (the
  exact request: the CLI path, this process as the root, that row's token, its server's ANTHROPIC_BASE_URL) and
  never the collapsed cli_env_clean;
- an honest host passes; the positive and decoy rows require census == ["ok"] exactly;
- each other fixed reason (walk-unreadable, cli-not-found, env-unreadable, canary-missing, token-found) fails both
  calling rows, and their labels carry exactly census=['<that reason>']; the no-channel row makes no census;
- a census that returns anything outside the fixed set (text holding a pid, a path, argv, an environment value, the
  token) or raises (an exception whose text holds them) fails the rows with census=['invalid'] and echoes none of it:
  each calling row's census label is exactly the fixed sentence plus census=['<one fixed word>'].
No signal is sent: h.spawn_group is a fake, and os.kill / os.killpg are patched to raise.
Run like the gate: cd tests/e2e && unshare --user --map-root-user --pid --fork --mount-proc \\
  sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_fd3_census_reason_test'
Unregistered until the green."""
import os
import re
import textwrap
import unittest

import ms6_hard_gate_fd3_cli_case_test as base

REASONS = ("ok", "walk-unreadable", "cli-not-found", "env-unreadable", "canary-missing", "token-found")
FAKE_PROC_DARWIN = """
    ALIVE = {}
    CENSUS = []
    REASON = {"v": "ok"}
    CENSUS_REASONS = ("ok", "walk-unreadable", "cli-not-found", "env-unreadable", "canary-missing", "token-found")
    def cli_env_census(exe, root, token, canary):
        CENSUS.append(("census", exe, root, token, canary))
        got = REASON["v"]
        if isinstance(got, BaseException):
            raise got
        return got
    def cli_env_clean(exe, root, token, canary):
        CENSUS.append(("clean", exe, root, token, canary))
        return REASON["v"] == "ok"
    def path(pid):
        return ALIVE.get(pid)
    def environ_of(pid):
        return b"raw", [b"node"], []
    """
LABEL = re.compile(r"^(positive|decoy): during the request the CLI's environment holds this row's base URL and not "
                   r"the token \(census=\['([a-z-]+)'\]\)$")


class CensusReason(base.FakeStagedHost):
    def setUp(self):
        super().setUp()
        with open(os.path.join(self.prefix, "zb_agent_host", "proc_darwin.py"), "w") as f:
            f.write(textwrap.dedent(FAKE_PROC_DARWIN))

    def census_labels(self, h):
        return [(ok, label) for ok, label in h.checks if "during the request the CLI's environment" in label]

    def run_with(self, reason):
        self.staged("proc_darwin").REASON["v"] = reason
        return self.run_case()

    def test_the_case_asks_for_the_reason_once_per_calling_row_with_the_exact_request(self):
        h = self.run_with("ok")
        self.assertEqual(self.failed(h), [])
        servers = self.staged("route_probe").SERVERS
        cli = os.path.realpath(self.cli)
        self.assertEqual(self.staged("proc_darwin").CENSUS, [
            ("census", cli, os.getpid(), base.CANARY.encode(), b"ANTHROPIC_BASE_URL=" + servers[0].url.encode()),
            ("census", cli, os.getpid(), base.DECOY.encode(), b"ANTHROPIC_BASE_URL=" + servers[1].url.encode())])
        self.assertEqual([LABEL.match(label).group(2) for _ok, label in self.census_labels(h)], ["ok", "ok"])

    def test_each_other_reason_fails_both_calling_rows_and_is_named_exactly(self):
        for reason in REASONS[1:]:
            with self.subTest(reason=reason):
                self.forget()
                h = self.run_with(reason)
                labels = self.census_labels(h)
                self.assertEqual([(ok, LABEL.match(label).groups()) for ok, label in labels],
                                 [(False, ("positive", reason)), (False, ("decoy", reason))], labels)
                self.assertFalse(any(l.startswith("no channel: ") for l in self.failed(h)), self.failed(h))

    def test_a_census_outside_the_fixed_set_fails_and_echoes_nothing(self):
        leak = f"pid 4242 {os.path.realpath(self.cli)} --home ANTHROPIC_BASE_URL=http://x {base.CANARY}"
        for label_, got in (("free text", leak), ("a bool", False), ("an exception", OSError(5, leak)),
                            ("a runtime error", RuntimeError(leak))):
            with self.subTest(census=label_):
                self.forget()
                h = self.run_with(got)
                labels = self.census_labels(h)
                self.assertEqual([(ok, LABEL.match(label).groups()) for ok, label in labels],
                                 [(False, ("positive", "invalid")), (False, ("decoy", "invalid"))], labels)
                for _ok, label in h.checks:
                    for piece in ("4242", "http://x"):
                        self.assertNotIn(piece, label)


for _name in dir(base.FakeStagedHost):  # ms6_hard_gate_fd3_cli_case_test runs these itself
    if _name.startswith("test_") and _name not in vars(CensusReason):
        setattr(CensusReason, _name, None)


if __name__ == "__main__":
    unittest.main()
