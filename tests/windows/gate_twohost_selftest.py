#!/usr/bin/env python3
"""WS0 two-host gate reds (UNREGISTERED) — WS0.6 VM identity + WS0.7 file-server fence.

These drive `tests/windows/gate.sh --probe-only`, the two-host orchestration that is NOT implemented
yet (it currently prints "not implemented yet" and exits 2). So every case here is RED today, for the
right reason: the gate does not yet perform the per-host fail-closed checks, so the expected verdict /
message never appears. They go green when the two-host `--probe-only` run is built, and each carries the
mutant that must flip it (run against the green before it is accepted).

This file is intentionally NOT registered in build.zig (red stays outside gate-registered steps); it is
registered as the `windows-twohost-selftest` step in the green commit. Hermetic: drives gate.sh against
fake `ssh`/`virsh` on PATH that return canned probe JSON — no Windows host, display or live socket.

Contract (rev 2.2) the green `--probe-only` must satisfy, per the plan's WS0.6/WS0.7:
  * both ZB_WIN10_HOST and ZB_WIN11_HOST required (already enforced — fail closed if either missing);
  * VM (WS0.6): `virsh domstate`==running, TCP reach, pinned host key, probe JSON, and the probe's
    `identity_marker` == the pinned `ZB_WIN11_MARKER` (missing/empty/wrong => "wrong host");
  * file server (WS0.7): host_probe pre+post; fail if `groups` has a forbidden group, `zbtest_write_paths`
    is non-empty ("file-server: zbtest can write to <path>"), `console_user` != the configured user, or
    `listeners`/`fw_rules_hash` differ between the pre- and post-run probes.

Run alone:  python3 -I tests/windows/gate_twohost_selftest.py -v
"""
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[2]
GATE = REPO / "tests" / "windows" / "gate.sh"
_BASE_PATH = "/usr/bin:/bin"

VM_MARKER = "MARKER-VM-NONCE"
FS_MARKER = "MARKER-FS-NONCE"

# The fake ssh emits the canned probe JSON for the host named in its argv; for the file server it emits
# the "post" JSON on its second probe call (so WS0.7 can diff pre/post). The fake virsh answers domstate.
_SSH_STUB = r"""
[ -n "${ZB_SELFTEST_SSH_LOG:-}" ] && printf 'ARGV: %s\n' "$*" >> "$ZB_SELFTEST_SSH_LOG"
argv="$*"
case "$argv" in
  *host_probe*|*powershell*|*EncodedCommand*)
    # The real probe streams a script over ssh stdin and runs `$input | Out-String | iex`. Drain stdin
    # (the streamed script) so the transport test can prove it was streamed, and branch on its content:
    # the VM session-trigger script contains `schtasks` -> return a RESULT= line; otherwise it is the
    # host probe -> return the canned JSON. With no file redirected, stdin is /dev/null (empty).
    body="$(cat)"
    [ -n "${ZB_SELFTEST_STDIN_LOG:-}" ] && printf '%s' "$body" >> "$ZB_SELFTEST_STDIN_LOG"
    case "$body" in
      *schtasks*) printf '%s' "${ZB_SELFTEST_SESSION_RESULT:-RESULT=OK interactive=True locked=False}"; exit 0 ;;
    esac
    case "$argv" in
      *127.0.0.1*|*zbtext@*) printf '%s' "${ZB_SELFTEST_PROBE_WIN11:-}" ;;
      *100.123.34.15*|*zbtest@*)
        cf="${ZB_SELFTEST_WIN10_CALLS:-}"
        c=1
        if [ -n "$cf" ]; then c=$(cat "$cf" 2>/dev/null || echo 0); c=$((c+1)); echo "$c" > "$cf"; fi
        if [ "$c" -ge 2 ] && [ -n "${ZB_SELFTEST_PROBE_WIN10_POST:-}" ]; then
          printf '%s' "$ZB_SELFTEST_PROBE_WIN10_POST"
        else
          printf '%s' "${ZB_SELFTEST_PROBE_WIN10:-}"
        fi
        ;;
    esac
    exit 0 ;;
esac
exit 0
"""

_VIRSH_STUB = r"""
[ -n "${ZB_SELFTEST_VIRSH_LOG:-}" ] && printf 'ARGV: %s\n' "$*" >> "$ZB_SELFTEST_VIRSH_LOG"
case "$1" in
  domstate) echo "${ZB_SELFTEST_VIRSH_STATE:-running}" ;;
  snapshot-list) printf '%s\n' "${ZB_SELFTEST_SNAPSHOTS-pre-4dr-toolchain-2026-10-20}" ;;
  snapshot-info)
    echo "State:          ${ZB_SELFTEST_SNAPSHOT_STATE:-shutoff}"
    if [ -n "${ZB_SELFTEST_SNAPSHOT_BADCREATED:-}" ]; then echo "Creation Time:  not-a-real-date"
    elif [ -z "${ZB_SELFTEST_SNAPSHOT_NOCREATED:-}" ]; then echo "Creation Time:  2026-10-19 08:00:00 -0700"; fi ;;
  *) : ;;
esac
exit 0
"""


def _write_stub(path, body):
    path.write_text("#!/usr/bin/env bash\n" + body)
    path.chmod(0o755)


def _fakes(bindir):
    _write_stub(bindir / "ssh", _SSH_STUB)
    _write_stub(bindir / "virsh", _VIRSH_STUB)
    return str(bindir)


def _vm_probe(**over):
    p = {"schema": 2, "test_user": "linuxwin\\zbtext", "identity_marker": VM_MARKER,
         "native_arch": "x64", "os_build": "26200", "free_gb": 50.0,
         "webview2_pv": "155.0.4283.62", "interactive_session": True,
         "locked": False, "console_user": "zbtext", "root": "C:\\Users\\zbtext\\zb"}
    p.update(over)
    return json.dumps(p)


def _fs_probe(**over):
    p = {"schema": 2, "test_user": "file_server_win\\zbtest", "identity_marker": FS_MARKER,
         "native_arch": "x64", "os_build": "19045", "webview2_pv": "155.0.4283.62",
         "groups": [{"sid": "S-1-5-32-545", "name": "BUILTIN\\Users"}],
         "zbtest_write_paths": [], "console_user": "zbtest",
         "listeners": [22, 135, 139, 445, 3389], "fw_rules_hash": "abc123", "shares": [],
         "root": "C:\\Users\\zbtest\\zb", "free_gb": 500.0,
         "sshd_listen": ["100.123.34.15"], "sshd_allowusers": ["zbtest"]}
    p.update(over)
    return json.dumps(p)


class _TwoHostCase(unittest.TestCase):
    def _run_probe_only(self, td, extra):
        home = td / "home"; home.mkdir(exist_ok=True)
        env = {
            "PATH": _fakes(td) + os.pathsep + _BASE_PATH, "HOME": str(home),
            "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222", "ZB_WIN11_DOMAIN": "win11-m8",
            "ZB_WIN11_USER": "zbtext", "ZB_WIN11_MARKER": VM_MARKER,
            "ZB_WIN11_SNAPSHOT": "pre-4dr-toolchain-2026-10-20",
            "ZB_WIN10_HOST": "100.123.34.15", "ZB_WIN10_PORT": "22", "ZB_WIN10_USER": "zbtest",
            "ZB_WIN10_MARKER": FS_MARKER,
            # Per-host key + known_hosts (distinct files — the two hosts pin different host keys).
            "ZB_WIN11_KEY": str(td / "win11.key"), "ZB_WIN11_KNOWN_HOSTS": str(td / "win11.kh"),
            "ZB_WIN10_KEY": str(td / "win10.key"), "ZB_WIN10_KNOWN_HOSTS": str(td / "win10.kh"),
            "ZB_SELFTEST_WIN10_CALLS": str(td / "win10.calls"),
            # sensible healthy defaults; cases override
            "ZB_SELFTEST_PROBE_WIN11": _vm_probe(),
            "ZB_SELFTEST_PROBE_WIN10": _fs_probe(),
        }
        for _n in ("win11.key", "win11.kh", "win10.key", "win10.kh"):
            (td / _n).write_text("x")
        env.update(extra)
        # stdin=DEVNULL: nothing is piped to the gate itself, so the stub's stdin is /dev/null unless
        # probe_host explicitly redirects host_probe.ps1 into ssh (the streaming path under test).
        proc = subprocess.run(["bash", str(GATE), "--probe-only"], env=env,
                              capture_output=True, text=True, timeout=90,
                              stdin=subprocess.DEVNULL)
        return proc

    def _assert_fail_closed(self, proc, needle):
        detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        self.assertNotEqual(proc.returncode, 0, "must fail closed" + detail)
        self.assertIn(needle, proc.stdout + proc.stderr, f"expected {needle!r}" + detail)


class WS06VmIdentity(_TwoHostCase):
    def test_vm_shut_off_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_VIRSH_STATE": "shut off"})
            self._assert_fail_closed(proc, "Win11 VM win11-m8 is shut off")

    def test_vm_marker_missing_is_wrong_host(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(identity_marker=None)})
            self._assert_fail_closed(proc, "wrong host")

    def test_vm_marker_empty_is_wrong_host(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(identity_marker="")})
            self._assert_fail_closed(proc, "wrong host")

    def test_vm_marker_wrong_is_wrong_host(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(identity_marker="SOMETHING-ELSE")})
            self._assert_fail_closed(proc, "wrong host")

    def test_healthy_two_host_probe_passes(self):
        """Both hosts healthy + markers match => exit 0 (green). Red now: --probe-only exits 2."""
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {})
            detail = f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            self.assertEqual(proc.returncode, 0, "a healthy two-host probe must pass" + detail)


class WS07FileServerFence(_TwoHostCase):
    def test_forbidden_group_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(groups=[{"sid": "S-1-5-32-544", "name": "BUILTIN\\Administrators"}])
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": bad})
            self._assert_fail_closed(proc, "file-server")

    def test_writable_served_path_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(zbtest_write_paths=["C:\\Shares\\public"])
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": bad})
            self._assert_fail_closed(proc, "zbtest can write to")

    def test_console_user_not_test_user_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(console_user="someone_else")
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": bad})
            self._assert_fail_closed(proc, "file-server")

    def test_listeners_changed_pre_post_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            post = _fs_probe(listeners=[22, 135, 139, 445, 3389, 8080])  # a new SERVICE listener appeared
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10_POST": post})
            self._assert_fail_closed(proc, "file-server")

    def test_high_port_listener_change_fails_closed(self):
        """A persistent NEW listener on a high/"ephemeral" port (50000) is still a disturbance, not churn.
        There is no range exemption: a product service binding 50000 must not slip past. (Tolerating genuine
        OS dynamic-port churn needs ownership/PID identity — a tracked plan item, see the WS0.7 field doc.)"""
        with tempfile.TemporaryDirectory() as t:
            post = _fs_probe(listeners=[22, 135, 139, 445, 3389, 50000])
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10_POST": post})
            self._assert_fail_closed(proc, "listening ports changed")

    # --- fail-closed on malformed/missing probe data (WS0 is fail closed; never coerce to "undisturbed") ---
    def test_listeners_none_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": _fs_probe(listeners=None)})
            self._assert_fail_closed(proc, "file-server")

    def test_listeners_list_of_strings_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": _fs_probe(listeners=["22"])})
            self._assert_fail_closed(proc, "file-server")

    def test_missing_fw_rules_hash_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            d = json.loads(_fs_probe()); d.pop("fw_rules_hash", None)
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": json.dumps(d),
                                                          "ZB_SELFTEST_PROBE_WIN10_POST": json.dumps(d)})
            self._assert_fail_closed(proc, "file-server")

    def test_missing_console_user_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            d = json.loads(_fs_probe()); d.pop("console_user", None)
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": json.dumps(d)})
            self._assert_fail_closed(proc, "file-server")

    def test_missing_groups_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            d = json.loads(_fs_probe()); d.pop("groups", None)
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": json.dumps(d)})
            self._assert_fail_closed(proc, "file-server")

    def test_fs_identity_is_host_key_only(self):
        # The physical file server is pinned by its SSH host key (StrictHostKeyChecking=yes + known_hosts),
        # NOT a nonce file (read-only rule, orchestrator): a probe with no identity_marker still passes —
        # the field is intentionally not required there.
        with tempfile.TemporaryDirectory() as t:
            d = json.loads(_fs_probe()); d.pop("identity_marker", None)
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": json.dumps(d),
                                                          "ZB_SELFTEST_PROBE_WIN10_POST": json.dumps(d)})
            self.assertEqual(proc.returncode, 0,
                             f"FS identity is host-key-only; the marker must not be required:\n{proc.stderr}")


class WS0CompletionReadiness(_TwoHostCase):
    # WS0-completion (Route A): the gate validates the complete schema-2 readiness fail-closed.
    def test_vm_no_snapshot_fails_closed(self):
        # Host-side virsh: the pinned snapshot name is not present => fail closed.
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_SNAPSHOTS": ""})
            self._assert_fail_closed(proc, "no snapshot named")

    def test_vm_wrong_snapshot_name_fails_closed(self):
        # An unrelated snapshot exists, but not the pinned expected name => fail closed.
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_WIN11_SNAPSHOT": "some-other-snap"})
            self._assert_fail_closed(proc, "no snapshot named 'some-other-snap'")

    def test_vm_unpinned_snapshot_fails_closed(self):
        # The expected snapshot name is not pinned at all => fail closed (never an arbitrary one).
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_WIN11_SNAPSHOT": ""})
            self._assert_fail_closed(proc, "ZB_WIN11_SNAPSHOT is not set")

    def test_vm_snapshot_queried_by_exact_name(self):
        # Argv oracle: the gate must query snapshot-info for the EXACT pinned name, not an arbitrary one.
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            log = td / "virsh.log"
            self._run_probe_only(td, {"ZB_SELFTEST_VIRSH_LOG": str(log)})
            text = log.read_text() if log.exists() else ""
            self.assertIn("snapshot-info win11-m8 pre-4dr-toolchain-2026-10-20", text,
                          f"gate must query snapshot-info for the exact pinned name; virsh log:\n{text}")

    def test_vm_snapshot_not_shutoff_fails_closed(self):
        # The snapshot must have been taken while shut off (the user's rule).
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_SNAPSHOT_STATE": "running"})
            self._assert_fail_closed(proc, "not shutoff")

    def test_vm_inactive_session_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(interactive_session=False)})
            self._assert_fail_closed(proc, "no active interactive session")

    def test_vm_locked_session_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(locked=True)})
            self._assert_fail_closed(proc, "locked")

    def test_vm_old_schema_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(schema=1)})
            self._assert_fail_closed(proc, "schema")

    def test_fs_missing_shares_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(shares=None)
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "shares")

    def test_fs_wrong_console_user_fails_closed(self):
        # The file server's own fence: console_user must be the test user (zbtest), proving no real
        # operator is mid-session. interactive_session/locked are not_applicable on the physical FS.
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(console_user="BOSS\\realperson")
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "console user")

    def test_vm_wrong_native_arch_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(native_arch="arm64")})
            self._assert_fail_closed(proc, "native_arch")

    def test_vm_missing_console_user_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(console_user="")})
            self._assert_fail_closed(proc, "console_user")

    def test_vm_wrong_test_user_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(test_user="linuxwin\\someoneelse")})
            self._assert_fail_closed(proc, "test_user")

    def test_vm_old_os_build_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(os_build="19045")})
            self._assert_fail_closed(proc, "os_build")

    def test_vm_missing_webview2_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(webview2_pv="")})
            self._assert_fail_closed(proc, "webview2_pv")

    def test_vm_low_free_gb_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(free_gb=3.0)})
            self._assert_fail_closed(proc, "free_gb")

    def test_fs_old_schema_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(schema=1)
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "schema")

    def test_fs_wrong_test_user_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(test_user="file_server_win\\someoneelse")
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "test_user")

    def test_fs_old_os_build_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(os_build="18000")
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "os_build")

    def test_fs_shares_changed_pre_post_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": _fs_probe(shares=[{"name": "data", "path": "C:\\Served"}]),
                 "ZB_SELFTEST_PROBE_WIN10_POST": _fs_probe(shares=[{"name": "data", "path": "C:\\Served"},
                                                                   {"name": "hole", "path": "C:\\NewHole"}])})
            self._assert_fail_closed(proc, "shares changed")

    def test_fs_untyped_shares_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(shares=["C:\\Served"])   # path-only, not {name, path}
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "share")

    def test_vm_console_user_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(console_user="linuxwin\\boss")})
            self._assert_fail_closed(proc, "console_user")

    def test_vm_root_missing_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(root="")})
            self._assert_fail_closed(proc, "root")

    # NOTE: FS root and free_gb are not_applicable on the read-only file server (no writes; C:\Users\<u>\zb
    # is never created; C: ~0 GB) — the gate does not judge the FS on them, so there are no FS root/free_gb
    # fail-closed cases here. The VM root/free_gb cases remain below.

    def test_fs_sshd_listen_missing_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(sshd_listen=None)
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "sshd_listen")

    def test_fs_sshd_allowusers_missing_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(sshd_allowusers=None)
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "sshd_allowusers")

    def test_vm_snapshot_no_creation_time_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_SNAPSHOT_NOCREATED": "1"})
            self._assert_fail_closed(proc, "no Creation Time")


# --- BatchMode oracle: every ssh/scp invocation must have EFFECTIVE BatchMode=yes ----------
# Each 'ARGV: ...' line the fake stub writes is one invocation. OpenSSH resolves -o options
# FIRST-occurrence-wins (case-insensitive), so we never hand-parse precedence: we hand each
# invocation's -o options to `ssh -G` itself and read the effective BatchMode it computes.
def _ssh_invocations(log_text):
    return [ln[len("ARGV:"):].split() for ln in log_text.splitlines() if ln.startswith("ARGV:")]


def _o_options(tokens):
    """The -o options from one invocation, in order (both `-o Name=Val` and `-oName=Val`)."""
    opts = []
    i = 0
    while i < len(tokens):
        if tokens[i] == "-o" and i + 1 < len(tokens):
            opts += ["-o", tokens[i + 1]]; i += 2
        elif tokens[i].startswith("-o") and len(tokens[i]) > 2:
            opts.append(tokens[i]); i += 1
        else:
            i += 1
    return opts


def _batchmode_is_on(o_options):
    """OpenSSH's EFFECTIVE BatchMode for these -o options, resolved by `ssh -G` itself
    (first-occurrence-wins, case-insensitive) — authoritative, never a hand parser."""
    ssh = shutil.which("ssh") or "/usr/bin/ssh"
    proc = subprocess.run([ssh, "-G", "-F", "/dev/null", *o_options, "zb-batchmode-probe.invalid"],
                          capture_output=True, text=True, timeout=30)
    for line in proc.stdout.splitlines():
        parts = line.split(None, 1)
        if parts and parts[0].lower() == "batchmode":
            return (parts[1].strip().lower() if len(parts) > 1 else "") in ("yes", "true", "on")
    return False


def _batchmode_violations(log_text):
    invs = _ssh_invocations(log_text)
    return invs, [t for t in invs if not _batchmode_is_on(_o_options(t))]


class SshHygiene(_TwoHostCase):
    def test_every_gate_ssh_invocation_has_effective_batchmode_yes(self):
        # Team rule: a refused key must fail at once, never open a GUI password prompt on DISPLAY :0.
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            log = td / "ssh.log"
            self._run_probe_only(td, {"ZB_SELFTEST_SSH_LOG": str(log)})
            invs, bad = _batchmode_violations(log.read_text() if log.exists() else "")
            self.assertTrue(invs, "gate.sh ran no ssh invocations to check")
            self.assertEqual(bad, [], f"gate.sh ssh invocations without effective BatchMode=yes: {bad}")

    def test_oracle_flags_a_call_that_omits_batchmode(self):
        # Failing-first (1): one call keeps BatchMode, another omits it (OpenSSH default is no).
        invs, bad = _batchmode_violations(
            "ARGV: -o BatchMode=yes -p 2222 zbtext@127.0.0.1 probe\n"
            "ARGV: -o StrictHostKeyChecking=yes -p 22 zbtest@100.123.34.15 probe\n")
        self.assertEqual(len(invs), 2)
        self.assertEqual(len(bad), 1, "the invocation without BatchMode must be flagged")

    def test_oracle_flags_batchmode_no_then_yes(self):
        # Failing-first (2): OpenSSH is FIRST-value-wins, so `no` then `yes` is effectively NO.
        invs, bad = _batchmode_violations("ARGV: -o BatchMode=no -o BatchMode=yes host probe\n")
        self.assertEqual(len(bad), 1, "effective BatchMode=no (first wins) must be flagged")

    def test_oracle_accepts_batchmode_yes_then_no(self):
        # Mirror: `yes` then `no` is effectively YES (first wins) — OpenSSH treats it safe.
        invs, bad = _batchmode_violations("ARGV: -o BatchMode=yes -o BatchMode=no host probe\n")
        self.assertEqual(bad, [], "effective BatchMode=yes (first wins) must be accepted")


class WS0FieldHardening(_TwoHostCase):
    def test_vm_wrong_root_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(root="C:\\Users\\zbtext\\elsewhere")})
            self._assert_fail_closed(proc, "root")

    def test_empty_identity_share_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(shares=[{"name": "", "path": ""}])
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "shares")

    def test_sshd_wildcard_listen_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": _fs_probe(sshd_listen=["0.0.0.0"])})
            self._assert_fail_closed(proc, "ListenAddress")

    def test_sshd_wrong_concrete_address_fails_closed(self):
        # A valid-looking but WRONG tailnet address must fail (exact pin, not just non-wildcard).
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": _fs_probe(sshd_listen=["192.0.2.44"])})
            self._assert_fail_closed(proc, "ListenAddress")

    def test_relative_share_path_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(shares=[{"name": "docs", "path": "relative\\docs"}])
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "share")

    def test_duplicate_share_path_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(shares=[{"name": "a", "path": "C:\\Served"},
                                    {"name": "b", "path": "C:\\Served"}])
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": bad, "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "duplicate")

    def test_vm_nan_free_gb_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(free_gb=float("nan"))})
            self._assert_fail_closed(proc, "free_gb")

    # FS free_gb is not_applicable (no writes; ~0 GB) and there is NO fixed listener baseline (the real FS
    # has no 3389 and churny dynamic RPC ports) — WS0.7 enforces only pre==post listeners (tested below),
    # so there are no FS-free_gb or baseline-set fail-closed cases here.

    def test_sshd_empty_listen_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": _fs_probe(sshd_listen=[])})
            self._assert_fail_closed(proc, "sshd_listen")

    def test_sshd_allowusers_extra_user_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": _fs_probe(sshd_allowusers=["zbtest zbother"])})
            self._assert_fail_closed(proc, "AllowUsers")

    def test_sshd_allowusers_wrong_user_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_PROBE_WIN10": _fs_probe(sshd_allowusers=["someoneelse"])})
            self._assert_fail_closed(proc, "AllowUsers")

    def test_snapshot_unparseable_creation_time_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_SNAPSHOT_BADCREATED": "1"})
            self._assert_fail_closed(proc, "parseable")

    def test_sshd_tailnet_allowusers_exact_passes(self):
        # Healthy FS (concrete ListenAddress, AllowUsers exactly zbtest, port 22 up) still passes.
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {})
            self.assertEqual(proc.returncode, 0, f"healthy FS must pass\n{proc.stderr}")


def _known_hosts_of(tokens):
    """The UserKnownHostsFile value from one ssh invocation's -o options (or None)."""
    for o in _o_options(tokens):
        if o.startswith("-oUserKnownHostsFile="):
            return o[len("-oUserKnownHostsFile="):]
    for i, o in enumerate(_o_options(tokens)):
        if o.startswith("UserKnownHostsFile="):
            return o[len("UserKnownHostsFile="):]
    return None


class ProbeTransport(_TwoHostCase):
    def test_probe_streams_script_over_stdin_not_file(self):
        # Read-only rule: the probe script is NEVER written to a host; it streams over ssh stdin and is
        # run with `$input | Out-String | iex` (NOT `powershell -Command -`, which silently drops a
        # multi-line here-string — the probe's Add-Type block — verified on the VM). So no invocation
        # may use -File, the transport must read $input, and the EXACT host_probe.ps1 text must reach
        # the stub on stdin. (Red against the old `-File zb\host_probe.ps1` form.)
        script = (REPO / "tests" / "windows" / "host_probe.ps1").read_text()
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            sshlog = td / "ssh.log"; stdinlog = td / "stdin.log"
            proc = self._run_probe_only(td, {"ZB_SELFTEST_SSH_LOG": str(sshlog),
                                             "ZB_SELFTEST_STDIN_LOG": str(stdinlog)})
            self.assertEqual(proc.returncode, 0, f"healthy probe must pass\n{proc.stderr}")
            argv = sshlog.read_text() if sshlog.exists() else ""
            self.assertNotIn("-File", argv, "probe must not place/run a script FILE on the host")
            self.assertIn("$input", argv, "probe must read the streamed script via $input (Out-String | iex)")
            streamed = stdinlog.read_text() if stdinlog.exists() else ""
            # The stub captures stdin via $(cat), which strips the trailing newline; compare sans it.
            self.assertIn(script.rstrip("\n"), streamed, "the exact host_probe.ps1 must be streamed over ssh stdin")

    def test_each_host_pins_its_own_known_hosts(self):
        # The VM and the file server have different host keys, so each ssh must pin its OWN known_hosts.
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            sshlog = td / "ssh.log"
            proc = self._run_probe_only(td, {"ZB_SELFTEST_SSH_LOG": str(sshlog)})
            self.assertEqual(proc.returncode, 0, f"healthy probe must pass\n{proc.stderr}")
            win11_kh = str(td / "win11.kh"); win10_kh = str(td / "win10.kh")
            self.assertNotEqual(win11_kh, win10_kh)
            invs = _ssh_invocations(sshlog.read_text())
            self.assertTrue(invs, "no ssh invocations to check")
            saw11 = saw10 = False
            for tokens in invs:
                argv = " ".join(tokens); kh = _known_hosts_of(tokens)
                if "127.0.0.1" in argv or "zbtext@" in argv:
                    self.assertEqual(kh, win11_kh, f"win11 ssh must pin win11 known_hosts: {argv}"); saw11 = True
                elif "100.123.34.15" in argv or "zbtest@" in argv:
                    self.assertEqual(kh, win10_kh, f"win10 ssh must pin win10 known_hosts: {argv}"); saw10 = True
            self.assertTrue(saw11 and saw10, "expected ssh to both the VM and the file server")

    def test_vm_free_gb_13_passes_new_bar(self):
        # 13.4 GB is the real VM value; the 10 GB bar (host-disk limit, orchestrator 2026-10-20) accepts it.
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(free_gb=13.4)})
            self.assertEqual(proc.returncode, 0, f"VM free_gb 13.4 must pass the 10 GB bar\n{proc.stderr}")

    def test_vm_free_gb_below_10_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                                        {"ZB_SELFTEST_PROBE_WIN11": _vm_probe(free_gb=9.5)})
            self._assert_fail_closed(proc, "free_gb")


class WS0SessionTrigger(_TwoHostCase):
    def test_gate_triggers_console_task_with_nonce(self):
        # The gate must write a per-run nonce and trigger the pre-registered console task over SSH.
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            stdinlog = td / "stdin.log"
            proc = self._run_probe_only(td, {"ZB_SELFTEST_STDIN_LOG": str(stdinlog)})
            self.assertEqual(proc.returncode, 0, f"healthy probe must pass\n{proc.stderr}")
            streamed = stdinlog.read_text() if stdinlog.exists() else ""
            self.assertIn("schtasks /Run /TN 'zb-session-probe'", streamed,
                          "gate must trigger the in-console session task")
            self.assertIn("nonce.txt", streamed, "gate must write a per-run nonce before triggering")
            # The gate must PIN-VERIFY the task by exact XML fields (via the prepended verify_task.ps1).
            self.assertIn("ZB_TASK_NAME='zb-session-probe'", streamed, "gate must set the task name for verify_task.ps1")
            self.assertIn("schtasks /Query", streamed, "gate must query the task")
            self.assertIn("/XML", streamed, "gate must verify the task by XML, not localized list output")
            self.assertIn("Get-FileHash", streamed, "gate must verify the staged session_probe.ps1 hash")
            self.assertIn("InteractiveToken", streamed, "gate must require the task's InteractiveToken logon type")
            self.assertIn("$ZB_VERIFY -ne 'OK'", streamed, "gate must only trigger when verify_task.ps1 returns OK")

    def test_session_task_missing_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_SESSION_RESULT": "RESULT=TASK_MISSING"})
            self._assert_fail_closed(proc, "session helper")

    def test_session_task_hash_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_SESSION_RESULT": "RESULT=TASK_SCRIPT_HASH_MISMATCH deadbeef"})
            self._assert_fail_closed(proc, "session helper")

    def test_session_timeout_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_SESSION_RESULT": "RESULT=TIMEOUT"})
            self._assert_fail_closed(proc, "session helper")

    def test_session_trigger_failed_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_SESSION_RESULT": "RESULT=TRIGGER_FAILED access denied"})
            self._assert_fail_closed(proc, "session helper")

    def test_session_ok_passes(self):
        with tempfile.TemporaryDirectory() as t:
            proc = self._run_probe_only(pathlib.Path(t),
                {"ZB_SELFTEST_SESSION_RESULT": "RESULT=OK interactive=True locked=False"})
            self.assertEqual(proc.returncode, 0, f"a nonce-matching session result must pass\n{proc.stderr}")


def _strip_ps_comments(src):
    # Heuristic for our own script: drop each line from its first '#' to EOL. host_probe.ps1 uses '#'
    # only for comments (never inside a string literal), so this cleanly separates code from comments.
    out = []
    for line in src.splitlines():
        i = line.find("#")
        out.append(line if i < 0 else line[:i])
    return "\n".join(out)


# Write primitives / dynamic compilation that would touch disk on the zero-write Win10 file server.
# Add-Type -MemberDefinition compiles via CodeDOM (csc.exe) -> %TEMP% files on Windows PowerShell 5.1.
_FS_WRITE_PRIMITIVES = [
    r"\bAdd-Type\b", r"\bcsc(?:\.exe)?\b",
    r"\bSet-Content\b", r"\bAdd-Content\b", r"\bOut-File\b",
    r"\bNew-Item\b", r"\bSet-ItemProperty\b", r"\bNew-ItemProperty\b",
    r"\bExport-Csv\b", r"\bExport-Clixml\b",
    r"StreamWriter", r"WriteAllText", r"WriteAllBytes", r"AppendAllText", r"AppendAllLines",
    r"\bschtasks\b", r"\bscp\b",
    # Future persistence mutations the deny list must also kill (RoseCat SHOULD on 0353dfb):
    r"RunAndSave", r"\.Save\(", r"DefineDynamicModule\([^,)]*,",  # 2-arg = filename (saved) overload
    r"FileStream", r"File\.Create", r"\.CreateText\(",
    r"\bCopy-Item\b", r"\bMove-Item\b", r"\bRemove-Item\b", r"\bRename-Item\b", r"\bmkdir\b",
    r"CreateDirectory", r"\bStart-Transcript\b", r"\bTee-Object\b",
]


class WS0ZeroWrite(unittest.TestCase):
    def test_host_probe_is_zero_write_no_dynamic_compilation(self):
        # The probe streamed to the Win10 file server must write NOTHING and compile NOTHING there.
        import re
        src = (REPO / "tests" / "windows" / "host_probe.ps1").read_text()
        code = _strip_ps_comments(src)
        for pat in _FS_WRITE_PRIMITIVES:
            self.assertIsNone(re.search(pat, code),
                              f"host_probe.ps1 contains a write/compile primitive: {pat}")
        # File redirection to a path. Allow only the stderr-to-null / stderr-to-stdout idioms.
        redir = code
        for ok in (r"2>\$null", r"2>&1", r">\$null", r">&1"):
            redir = re.sub(ok, "", redir)
        self.assertNotIn(">", redir, "host_probe.ps1 has a file redirection (writes to disk)")

    def test_host_probe_still_emits_full_schema(self):
        # Zero-write must not drop fields: the ordered object must still declare every WS0 field.
        src = (REPO / "tests" / "windows" / "host_probe.ps1").read_text()
        for field in ("schema", "native_arch", "console_user", "console_session_id", "my_session_id",
                      "identity_marker", "shares", "zbtest_write_paths", "fw_rules_hash",
                      "sshd_listen", "sshd_allowusers", "root", "free_gb"):
            self.assertRegex(src, rf"\b{field}\b", f"host_probe.ps1 no longer declares {field}")

    def test_acl_function_is_extractable_and_used(self):
        # The live DACL test (host_live_test.py) extracts Get-ZbWritable VERBATIM between these markers,
        # so the markers must exist, wrap the function, and host_probe must actually call it.
        import re
        src = (REPO / "tests" / "windows" / "host_probe.ps1").read_text()
        m = re.search(r"# >>> ZB_ACL_FN.*?\n(.*?)\n# <<< ZB_ACL_FN", src, re.S)
        self.assertIsNotNone(m, "host_probe.ps1 is missing the ZB_ACL_FN extraction markers")
        block = m.group(1)
        self.assertIn("function Get-ZbWritable", block, "the marked block must define Get-ZbWritable")
        self.assertIn("function Initialize-ZbAccessCheck", block, "the marked block must define Initialize-ZbAccessCheck")
        self.assertIn("AccessCheck", block, "Get-ZbWritable must use the real Win32 AccessCheck")
        self.assertRegex(src, r"Get-ZbWritable \$acl \$ZbAcCtx", "host_probe.ps1 must call Get-ZbWritable with the AccessCheck context")


def load_tests(loader, tests, pattern):
    # Register the live VM suite (host_live_test.py) alongside the hostless cases so one run covers both.
    # The live cases SKIP when the VM env (ZB_WIN11_HOST...) is absent, so this is a no-op in CI without a VM.
    import importlib.util
    try:
        _p = pathlib.Path(__file__).with_name("host_live_test.py")
        _spec = importlib.util.spec_from_file_location("host_live_test", str(_p))
        _mod = importlib.util.module_from_spec(_spec)
        _spec.loader.exec_module(_mod)
        tests.addTests(loader.loadTestsFromModule(_mod))
    except Exception as _e:  # never let registration break the hostless suite
        import sys as _sys
        _sys.stderr.write("note: could not load host_live_test.py: %r\n" % (_e,))
    return tests


if __name__ == "__main__":
    unittest.main()
