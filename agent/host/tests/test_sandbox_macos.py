"""MS6 (macOS Seatbelt backend) — the profile generator, unit-tested on Linux.

The generator emits the Seatbelt (.sb) text a `MacSeatbeltBackend` launch runs under
`/usr/bin/sandbox-exec -f <profile> -D ...`. These are PURE-Python content assertions (no
sandbox-exec, so they run in the Linux gate); the actual kernel enforcement is the MS6.1–MS6.5
Mac gate. They pin the security-load-bearing rules the MS6.1 Mac proof measured:

  * deny-default;
  * the TOKEN-ISOLATION belt (MS6.1, measured on both arches): an EXPLICIT `(deny process-info*)`
    AND a CURATED `sysctl-read` (never a blanket `(allow sysctl-read)`, which re-opens another
    process's kern.procargs2 even with process-info denied);
  * the WORKSPACE is read-only, only the SCRATCHPAD is writable (a direct workspace write bypasses
    the broker — it must fail closed);
  * the network: the CLI/helper reach the egress endpoint + the two bridge ports; a HOOK reaches the
    two bridge ports ONLY, never the egress endpoint (rev 16.2 §3c: hooks get bridges, never egress).

Run:  cd agent/host/tests && python3 -m unittest -v test_sandbox_macos
"""
import re
import sys
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_DIR))

from zb_agent_host import sandbox  # noqa: E402
from zb_agent_host import sandbox_macos  # noqa: E402

SCRATCH = "/zb/dist/current/state/scratchpad"
WORKSPACE = "/zb/dist/current/state/workspace"
EGRESS = sandbox.Endpoint("127.0.0.1", 52346)
BRIDGES = (51091, 31337)


def cli_profile():
    return sandbox_macos.render_profile(scratchpad=SCRATCH, workspace=WORKSPACE,
                                        egress=EGRESS, bridges=BRIDGES, is_hook=False)


def hook_profile():
    return sandbox_macos.render_profile(scratchpad=SCRATCH, workspace=WORKSPACE,
                                        egress=EGRESS, bridges=BRIDGES, is_hook=True)


class DenyDefault(unittest.TestCase):
    def test_version_and_deny_default(self):
        p = cli_profile()
        self.assertTrue(p.lstrip().startswith("(version 1)"), "profile must start with (version 1)")
        self.assertIn("(deny default)", p, "the profile must be deny-default")


class TokenIsolationBelt(unittest.TestCase):
    """The MS6.1 recipe, measured on both arches: explicit process-info deny + curated sysctl."""

    def test_process_info_is_explicitly_denied(self):
        for label, p in (("cli", cli_profile()), ("hook", hook_profile())):
            self.assertIn("(deny process-info*)", p,
                          f"[{label}] MS6.1: process-info must be EXPLICITLY denied — (deny default) alone "
                          "does not block cross-process proc_pidinfo/kern.procargs2")

    def test_sysctl_read_is_curated_not_blanket(self):
        for label, p in (("cli", cli_profile()), ("hook", hook_profile())):
            # A blanket (allow sysctl-read) with no filter re-opens kern.procargs2 (the token leak). Every
            # sysctl-read allow must carry a filter (a sysctl-name / sysctl-name-prefix on the same form).
            for m in re.finditer(r"\(allow\s+sysctl-read\b([^\n]*)", p):
                self.assertRegex(m.group(1), r"sysctl-name",
                                 f"[{label}] MS6.1: sysctl-read must be curated (filtered), never blanket — a "
                                 "blanket allow re-opens kern.procargs2")

    def test_task_port_not_granted(self):
        for label, p in (("cli", cli_profile()), ("hook", hook_profile())):
            self.assertNotIn("mach-priv-task-port", p,
                             f"[{label}] MS6.1: the task port must never be granted")


class FilesystemContainment(unittest.TestCase):
    def test_scratchpad_is_writable(self):
        p = cli_profile()
        self.assertIn("(allow file-write*", p, "the profile must allow some file-write*")
        # The scratchpad path appears only ever as a write subpath (reads are broad), so its presence as a
        # write subpath is the writable proof.
        self.assertIn(f'(subpath "{SCRATCH}")', p, "the SCRATCHPAD must be writable")

    def test_workspace_is_not_writable(self):
        # The workspace is read-only input; a direct write must fail closed (bypasses the broker). It must
        # not appear as a write subpath (deny-default then denies a workspace write).
        self.assertNotIn(f'(subpath "{WORKSPACE}")', cli_profile(),
                         "the WORKSPACE must NOT be in a write rule (read-only input)")


class NetworkCapability(unittest.TestCase):
    def test_cli_reaches_egress_and_bridges(self):
        p = cli_profile()
        self.assertIn(f'(remote ip "localhost:{EGRESS.port}")', p, "the CLI profile must permit the egress port")
        for port in BRIDGES:
            self.assertIn(f'(remote ip "localhost:{port}")', p, f"the CLI profile must permit bridge {port}")

    def test_hook_reaches_bridges_only_never_egress(self):
        p = hook_profile()
        for port in BRIDGES:
            self.assertIn(f'(remote ip "localhost:{port}")', p, f"the hook profile must permit bridge {port}")
        self.assertNotIn(f'(remote ip "localhost:{EGRESS.port}")', p,
                         "rev 16.2 §3c: a HOOK must NOT reach the egress endpoint — bridges only")

    def test_deny_default_covers_other_outbound(self):
        # No blanket network-outbound allow: only the named loopback endpoints.
        self.assertNotRegex(hook_profile(), r"\(allow\s+network\*?\s*\)",
                            "no blanket network allow — deny-default plus the named loopback ports only")


if __name__ == "__main__":
    unittest.main()
