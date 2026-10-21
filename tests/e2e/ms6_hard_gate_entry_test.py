"""The ARMED MS6 hard-gate entry (RoseCat 7250, 9dfc9c7): tests/mac/ms6_hard_gate.sh with the committed MS5 pins
stages the pinned tree and runs ONLY the reviewed cases, and refuses every bad precondition before any network.

packaging/macos/agent_runtime_pins.json:
  {"python_pkg": {"url": <python.org 3.12.10 macos11 pkg>, "sha256": <rev 15's pin>,
                  "sigstore_identity": "thomas@python.org", "sigstore_issuer": "https://accounts.google.com"},
   "uv_lock_sha256": <sha256 of agent/host/uv.lock>}

The entry, in a throwaway git repo, with recording shims for ssh/scp/sftp/curl/nc/rsync/uv first on PATH (each records
its argv and exits 99) and canary hosts:
- no pins file: NOT ARMED, exit 3, no network (as before);
- malformed pins, a uv.lock that no longer matches its pin, no arm64 host, or a case set that is not the reviewed
  manifest (an extra, unreviewed case_*.py, or an edited one): FAIL, exit 1, before ANY network call;
- with everything in order, its FIRST network call is the download of exactly the pinned pkg URL (curl), and since the
  shim fails it, it stops there: nothing is staged and no Mac is contacted.
The entry hands the driver --manifest tests/mac/hard_gate/MANIFEST.json, and nothing of MS6.5's survivor sweep.
seatbelt_ready is not touched by arming (RoseCat 7250 #4): a separate plan decision.

No signal. Unregistered until the green, which registers it inside the namespace like its siblings.
Run like the gate: cd tests/e2e && unshare --user --map-root-user --pid --fork --mount-proc \\
  sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_entry_test'
"""
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GATE = REPO / "tests" / "mac" / "ms6_hard_gate.sh"
PINS = REPO / "packaging" / "macos" / "agent_runtime_pins.json"
PKG_URL = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg"
PKG_SHA = "8373e58da4ea146b3eb1c1f9834f19a319440b6b679b06050b1f9ee3237aa8e4"
NET_TOOLS = ("ssh", "scp", "sftp", "curl", "nc", "rsync", "uv")


class ArmedEntry(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="zb-hardgate-entry-"))
        self.addCleanup(shutil.rmtree, self.repo, True)
        for rel in ("tests/mac/ms6_hard_gate.sh", "agent/host/uv.lock", "agent/host/pyproject.toml"):
            (self.repo / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / rel, self.repo / rel)
        shutil.copytree(REPO / "tests/mac/hard_gate", self.repo / "tests/mac/hard_gate",
                        ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copytree(REPO / "packaging/macos", self.repo / "packaging/macos")
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.record = self.repo / "network-calls"
        self.shims = self.repo / "shims"
        self.shims.mkdir()
        for tool in NET_TOOLS:
            (self.shims / tool).write_text(f"#!/bin/sh\necho {tool} \"$@\" >> '{self.record}'\nexit 99\n")
            (self.shims / tool).chmod(0o755)
        self.env = {"PATH": f"{self.shims}:/usr/bin:/bin", "LANG": "C.UTF-8", "HOME": str(self.repo),
                    "ZB_MAC_HOST": "canary-intel@192.0.2.10", "ZB_MAC_ARM_HOST": "canary-arm@192.0.2.11",
                    "ZB_MAC_KEY": str(self.repo / "no-key"), "ZB_MAC_ARM_KEY": str(self.repo / "no-key")}

    def run_gate(self):
        p = subprocess.run(["bash", str(self.repo / "tests/mac/ms6_hard_gate.sh")], capture_output=True, text=True,
                           timeout=60, cwd=self.repo, env=self.env)
        return p.returncode, p.stdout + p.stderr, (self.record.read_text() if self.record.exists() else "")

    def pins(self):
        return self.repo / "packaging/macos/agent_runtime_pins.json"

    def refused_offline(self, needle):
        code, out, calls = self.run_gate()
        self.assertEqual(code, 1, out)
        self.assertIn(needle, out)
        self.assertEqual(calls, "", "no network call before the preconditions hold")

    def test_without_pins_it_is_not_armed(self):
        self.pins().unlink(missing_ok=True)
        code, out, calls = self.run_gate()
        self.assertEqual(code, 3, out)
        self.assertIn("NOT ARMED", out)
        self.assertEqual(calls, "")

    def test_malformed_pins_are_refused_offline(self):
        for text in ("{}\n", "not json", json.dumps({"python_pkg": {"url": PKG_URL}})):
            with self.subTest(pins=text[:20]):
                self.pins().write_text(text)
                self.refused_offline("pins")

    def test_a_lock_that_moved_off_its_pin_is_refused_offline(self):
        lock = self.repo / "agent/host/uv.lock"
        lock.write_bytes(lock.read_bytes() + b"\n# changed after pinning\n")
        self.refused_offline("uv.lock")

    def test_no_arm64_host_is_refused_offline(self):
        del self.env["ZB_MAC_ARM_HOST"]
        self.refused_offline("arm64 host")

    def test_an_unreviewed_case_is_refused_offline(self):
        (self.repo / "tests/mac/hard_gate/case_unreviewed.py").write_text(
            "NAME='x'\ndef run(h):\n    h.check(True, '')\n")
        self.refused_offline("case_unreviewed.py")

    def test_an_edited_case_is_refused_offline(self):
        case = self.repo / "tests/mac/hard_gate/case_ms5_spawn_io.py"
        case.write_text(case.read_text() + "# edited after review\n")
        self.refused_offline("case_ms5_spawn_io.py")

    def test_in_order_its_first_network_call_is_the_pinned_pkg_download(self):
        code, out, calls = self.run_gate()
        self.assertNotEqual(code, 0, out)
        lines = calls.splitlines()
        self.assertEqual(len(lines), 1, f"exactly one network call, then stop: {lines}")
        self.assertTrue(lines[0].startswith("curl ") and lines[0].split()[-1] == PKG_URL, lines)


class CommittedPins(unittest.TestCase):
    def test_the_pins_name_the_reviewed_runtime_and_the_current_lock(self):
        self.assertTrue(PINS.is_file(), "packaging/macos/agent_runtime_pins.json is missing")
        pins = json.loads(PINS.read_text())
        self.assertEqual(pins["python_pkg"], {"url": PKG_URL, "sha256": PKG_SHA,
                                              "sigstore_identity": "thomas@python.org",
                                              "sigstore_issuer": "https://accounts.google.com"})
        lock = hashlib.sha256((REPO / "agent/host/uv.lock").read_bytes()).hexdigest()
        self.assertEqual(pins["uv_lock_sha256"], lock, "the pins must name the committed uv.lock")

    def test_the_entry_runs_the_driver_with_the_manifest_and_no_survivor_sweep(self):
        text = GATE.read_text()
        self.assertIn("--manifest", text)
        self.assertIn("tests/mac/hard_gate/MANIFEST.json", text)
        self.assertNotIn("reaper", text.lower())
        self.assertNotIn("seatbelt_ready=", text)


if __name__ == "__main__":
    unittest.main()
