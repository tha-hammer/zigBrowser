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
[ -n "${ZB_SELFTEST_SSH_LOG:-}" ] && printf '%s\n' "$@" >> "$ZB_SELFTEST_SSH_LOG"
argv="$*"
case "$argv" in
  *host_probe*|*powershell*|*EncodedCommand*)
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
case "$1" in
  domstate) echo "${ZB_SELFTEST_VIRSH_STATE:-running}" ;;
  snapshot-list) echo "pre-ws0-green-2026-10-19" ;;
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
    p = {"schema": 1, "test_user": "linuxwin\\zbtext", "identity_marker": VM_MARKER,
         "native_arch": "x64", "webview2_pv": "155.0.4283.62", "interactive_session": True,
         "locked": False, "console_user": "zbtext"}
    p.update(over)
    return json.dumps(p)


def _fs_probe(**over):
    p = {"schema": 1, "test_user": "file_server_win\\zbtest", "identity_marker": FS_MARKER,
         "native_arch": "x64", "webview2_pv": "155.0.4283.62",
         "groups": [{"sid": "S-1-5-32-545", "name": "BUILTIN\\Users"}],
         "zbtest_write_paths": [], "console_user": "zbtest",
         "listeners": [22, 135, 139, 445, 3389], "fw_rules_hash": "abc123"}
    p.update(over)
    return json.dumps(p)


class _TwoHostCase(unittest.TestCase):
    def _run_probe_only(self, td, extra):
        home = td / "home"; home.mkdir(exist_ok=True)
        env = {
            "PATH": _fakes(td) + os.pathsep + _BASE_PATH, "HOME": str(home),
            "ZB_WIN11_HOST": "127.0.0.1", "ZB_WIN11_PORT": "2222", "ZB_WIN11_DOMAIN": "win11-m8",
            "ZB_WIN11_USER": "zbtext", "ZB_WIN11_MARKER": VM_MARKER,
            "ZB_WIN10_HOST": "100.123.34.15", "ZB_WIN10_PORT": "22", "ZB_WIN10_USER": "zbtest",
            "ZB_WIN10_MARKER": FS_MARKER,
            "ZB_WIN_KEY": str(td / "key"), "ZB_WIN_KNOWN_HOSTS": str(td / "kh"),
            "ZB_SELFTEST_WIN10_CALLS": str(td / "win10.calls"),
            # sensible healthy defaults; cases override
            "ZB_SELFTEST_PROBE_WIN11": _vm_probe(),
            "ZB_SELFTEST_PROBE_WIN10": _fs_probe(),
        }
        (td / "key").write_text("x"); (td / "kh").write_text("#")
        env.update(extra)
        proc = subprocess.run(["bash", str(GATE), "--probe-only"], env=env,
                              capture_output=True, text=True, timeout=90)
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

    def test_win10_marker_missing_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            d = json.loads(_fs_probe()); d.pop("identity_marker", None)
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": json.dumps(d),
                                                          "ZB_SELFTEST_PROBE_WIN10_POST": json.dumps(d)})
            self._assert_fail_closed(proc, "file-server")

    def test_win10_marker_wrong_fails_closed(self):
        with tempfile.TemporaryDirectory() as t:
            bad = _fs_probe(identity_marker="SOMETHING-ELSE")
            proc = self._run_probe_only(pathlib.Path(t), {"ZB_SELFTEST_PROBE_WIN10": bad,
                                                          "ZB_SELFTEST_PROBE_WIN10_POST": bad})
            self._assert_fail_closed(proc, "file-server")


class SshHygiene(_TwoHostCase):
    def test_gate_ssh_passes_batchmode(self):
        # Team rule: a refused key must fail at once, never open a GUI password prompt on
        # the user's DISPLAY :0. Every ssh gate.sh runs must carry -o BatchMode=yes.
        # (The fake ssh stub appends its argv to ZB_SELFTEST_SSH_LOG.)
        with tempfile.TemporaryDirectory() as t:
            td = pathlib.Path(t)
            log = td / "ssh.log"
            self._run_probe_only(td, {"ZB_SELFTEST_SSH_LOG": str(log)})
            text = log.read_text() if log.exists() else ""
            self.assertIn("BatchMode=yes", text, "gate.sh ssh must pass -o BatchMode=yes")


if __name__ == "__main__":
    unittest.main()
