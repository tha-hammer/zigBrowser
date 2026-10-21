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
Provenance (RoseCat 7267): the entry takes a revision (default HEAD), refuses a non-commit before any network, exports
THAT commit into its per-run temp tree and reads everything from the export (pins, lock, manifest, shipped sources,
the dependency build). It prints "== hard gate at commit <sha>" and, before any network, "== ship <sha256> <path>" for
the shipped seam sources, staging script and zb_agent_host files, so a dirty or replaced working tree is shown not to
be what ships. The temporary Sigstore verifier is pinned (RoseCat 7265).
RoseCat 7269: the running launcher must be byte-identical to the exported one (else exit 1, offline); a symlink or
other non-regular entry among the shipped paths is refused offline, and the tar's file set equals the "== ship" rows;
the verifier is installed only from a committed, hash-locked requirements file (--require-hashes --no-deps) whose
SHA-256 the pins name; the no-installer oracle rejects any command token whose basename is installer or sudo, or an
installer-named variable. With ZB_HG_EVIDENCE_DIR set (a test seam), the entry copies the exact src.tar it made, before
any network, so the dirty-worktree row inspects the real bytes.
seatbelt_ready is not touched by arming (RoseCat 7250 #4): a separate plan decision.

No signal. Registered (build.zig: test-mac-census and the Linux test step), inside the namespace like its siblings.
Run like the gate: cd tests/e2e && unshare --user --map-root-user --pid --fork --mount-proc \\
  sh -c 'setsid python3 -X dev -m unittest -v ms6_hard_gate_entry_test'
"""
import hashlib
import json
import os
import re
import shlex
import shutil
import tarfile
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GATE = REPO / "tests" / "mac" / "ms6_hard_gate.sh"
PINS = REPO / "packaging" / "macos" / "agent_runtime_pins.json"
PKG_URL = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg"
PKG_SHA = "8373e58da4ea146b3eb1c1f9834f19a319440b6b679b06050b1f9ee3237aa8e4"
STAGE = REPO / "packaging" / "macos" / "stage_agent_runtime.sh"
SIGSTORE_PIN = "sigstore==4.5.1"
VERIFIER_REQS = REPO / "packaging" / "macos" / "sigstore_verifier.txt"
NET_TOOLS = ("ssh", "scp", "sftp", "curl", "nc", "rsync", "uv")


class ArmedEntry(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="zb-hardgate-entry-"))
        self.addCleanup(shutil.rmtree, self.repo, True)
        for rel in ("tests/mac/ms6_hard_gate.sh", "agent/host/uv.lock", "agent/host/pyproject.toml",
                    "tests/mac/spawn_group_io_test.c", "src/agent_spawn_posix.c", "src/agent_spawn_posix.h"):
            (self.repo / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / rel, self.repo / rel)
        shutil.copytree(REPO / "tests/mac/hard_gate", self.repo / "tests/mac/hard_gate",
                        ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copytree(REPO / "packaging/macos", self.repo / "packaging/macos")
        shutil.copytree(REPO / "agent/host/zb_agent_host", self.repo / "agent/host/zb_agent_host",
                        ignore=shutil.ignore_patterns("__pycache__"))
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
        self.commit()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), "-c", "user.email=t@t", "-c", "user.name=t", *args],
                              check=True, capture_output=True, text=True).stdout.strip()

    def commit(self):
        self.git("add", "-A", ".", ":!shims", ":!network-calls")
        self.git("commit", "-q", "--allow-empty", "-m", "fixture")

    def run_gate(self, *args):
        p = subprocess.run(["bash", str(self.repo / "tests/mac/ms6_hard_gate.sh"), *args], capture_output=True,
                           text=True, timeout=60, cwd=self.repo, env=self.env)
        return p.returncode, p.stdout + p.stderr, (self.record.read_text() if self.record.exists() else "")

    def pins(self):
        return self.repo / "packaging/macos/agent_runtime_pins.json"

    def refused_offline(self, needle, *args):
        code, out, calls = self.run_gate(*args)
        self.assertEqual(code, 1, out)
        self.assertIn(needle, out)
        self.assertEqual(calls, "", "no network call before the preconditions hold")

    def test_without_pins_it_is_not_armed(self):
        self.pins().unlink(missing_ok=True)
        self.commit()
        code, out, calls = self.run_gate()
        self.assertEqual(code, 3, out)
        self.assertIn("NOT ARMED", out)
        self.assertEqual(calls, "")

    def test_malformed_pins_are_refused_offline(self):
        for text in ("{}\n", "not json", json.dumps({"python_pkg": {"url": PKG_URL}})):
            with self.subTest(pins=text[:20]):
                self.pins().write_text(text)
                self.commit()
                self.refused_offline("pins")

    def test_a_lock_that_moved_off_its_pin_is_refused_offline(self):
        lock = self.repo / "agent/host/uv.lock"
        lock.write_bytes(lock.read_bytes() + b"\n# changed after pinning\n")
        self.commit()
        self.refused_offline("uv.lock")

    def test_no_arm64_host_is_refused_offline(self):
        del self.env["ZB_MAC_ARM_HOST"]
        self.refused_offline("arm64 host")

    def test_an_unreviewed_case_is_refused_offline(self):
        (self.repo / "tests/mac/hard_gate/case_unreviewed.py").write_text(
            "NAME='x'\ndef run(h):\n    h.check(True, '')\n")
        self.commit()
        self.refused_offline("case_unreviewed.py")

    def test_an_edited_case_is_refused_offline(self):
        case = self.repo / "tests/mac/hard_gate/case_ms5_spawn_io.py"
        case.write_text(case.read_text() + "# edited after review\n")
        self.commit()
        self.refused_offline("case_ms5_spawn_io.py")

    def only_the_pkg_download(self, code, out, calls):
        self.assertNotEqual(code, 0, out)
        lines = calls.splitlines()
        self.assertEqual(len(lines), 1, f"exactly one network call, then stop: {lines}\n{out}")
        self.assertTrue(lines[0].startswith("curl ") and lines[0].split()[-1] == PKG_URL, lines)

    def test_in_order_its_first_network_call_is_the_pinned_pkg_download(self):
        code, out, calls = self.run_gate()
        self.only_the_pkg_download(code, out, calls)
        self.assertIn(f"== hard gate at commit {self.git('rev-parse', 'HEAD')}", out)

    def test_a_dirty_worktree_is_not_what_ships(self):
        rels = ("src/agent_spawn_posix.c", "packaging/macos/stage_agent_runtime.sh", "agent/host/zb_agent_host/netd.py")
        committed = {rel: (self.repo / rel).read_bytes() for rel in rels}
        for rel in rels:
            (self.repo / rel).write_text((self.repo / rel).read_text() + "\n# uncommitted, unreviewed\n")
        for rel in ("tests/mac/hard_gate/case_ms5_spawn_io.py", "agent/host/uv.lock"):  # would fail if read here
            (self.repo / rel).write_text((self.repo / rel).read_text() + "\n# uncommitted\n")
        evidence = self.repo / "evidence"
        evidence.mkdir()
        self.env["ZB_HG_EVIDENCE_DIR"] = str(evidence)
        code, out, calls = self.run_gate()
        self.only_the_pkg_download(code, out, calls)
        with tarfile.open(evidence / "src.tar") as tar:
            members = {m.name: m for m in tar.getmembers()}
            for rel, data in committed.items():
                self.assertEqual(tar.extractfile(members[rel]).read(), data, f"{rel}: the committed bytes ship")
            files = {n for n, m in members.items() if m.isfile()}
            self.assertFalse([n for n, m in members.items() if not (m.isfile() or m.isdir())], "only files, dirs")
            rows = {}
            for line in out.splitlines():
                if line.startswith("== ship "):
                    _, _, digest, path = line.split(" ", 3)
                    rows[path] = digest
            self.assertEqual(set(rows), files, "every shipped file is named, and nothing else")
            for name in files:
                self.assertEqual(rows[name], hashlib.sha256(tar.extractfile(members[name]).read()).hexdigest(), name)

    def test_a_dirty_launcher_is_refused_offline(self):
        launcher = self.repo / "tests/mac/ms6_hard_gate.sh"
        lines = launcher.read_text().splitlines(keepends=True)
        at = next(i for i, l in enumerate(lines) if l.startswith("set -euo pipefail")) + 1
        launcher.write_text("".join(lines[:at] + ["echo DIRTY-LAUNCHER >&2\n"] + lines[at:]))
        self.refused_offline("launcher")

    def test_a_committed_symlink_among_the_shipped_paths_is_refused_offline(self):
        os.symlink("/etc/passwd", self.repo / "packaging/macos/escape-link")
        self.commit()
        self.refused_offline("packaging/macos/escape-link")

    def test_a_verifier_lock_off_its_pin_is_refused_offline(self):
        reqs = self.repo / "packaging/macos/sigstore_verifier.txt"
        reqs.write_text(reqs.read_text() + "\n# changed after review\n")
        self.commit()
        self.refused_offline("sigstore_verifier.txt")

    def test_a_revision_that_is_not_a_commit_is_refused_offline(self):
        self.refused_offline("revision", "no-such-revision")
        self.refused_offline("revision", self.git("rev-parse", "HEAD^{tree}"))


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

    def install_problems(self, text, name):
        """Every command line of `text` that runs installer/sudo (any path, quoting or variable spelling), names a
        system prefix, or uses pkgutil for anything but a signature check or an expansion."""
        out = []
        for n, line in enumerate(text.splitlines(), 1):
            code = "" if line.lstrip().startswith("#") else line.split(" #", 1)[0]
            try:
                tokens = shlex.split(code, posix=True)
            except ValueError:
                tokens = code.split()
            words = [t for tok in tokens for t in re.split(r"[;&|()`]", tok) if t]
            where = f"{name}:{n}: {line.strip()}"
            if any(os.path.basename(w) in ("installer", "sudo") for w in words):
                out.append(where)
            if re.search(r"\$\{?[A-Za-z_]*(installer|INSTALLER)[A-Za-z_]*", code):
                out.append(where)
            if re.search(r"(^|[\s\"'=])(/Library/|/Applications/|/usr/local/|/opt/|/System/)", code):
                out.append(where)
            if any(u not in ("--check-signature", "--expand-full") for u in re.findall(r"pkgutil\s+(--\S+)", code)):
                out.append(where)
        return out

    def test_neither_the_entry_nor_its_staging_installs_anything(self):
        # RoseCat 7265, 7269: the entry test stops at its first curl and cannot watch the remote leg, so pin the
        # commands: no installer or sudo (bare, absolute or via a variable), no system prefix; pkgutil only checks a
        # signature or expands into the run dir.
        for script in (GATE, STAGE):
            self.assertEqual(self.install_problems(script.read_text(), script.name), [])

    def test_the_install_oracle_catches_every_spelling(self):
        for bad in ('/usr/sbin/installer -pkg "$PKG" -target /', 'installer -pkg x -target /',
                    '"/usr/sbin/installer" x',
                    'sudo cp a b', '/usr/bin/sudo true', 'x=1; installer -pkg y', '"$INSTALLER" -pkg y',
                    '${installer_bin} -pkg y', 'cp a /Library/Frameworks/', 'pkgutil --forget org.python'):
            with self.subTest(line=bad):
                self.assertEqual(len(self.install_problems(bad, "probe")), 1, bad)
        ok = 'grep -q "Developer ID Installer: Python Software Foundation (BMM5U3QVKW)" <<<"$sig" || die "x"'
        self.assertEqual(self.install_problems(ok, "probe"), [], "the PSF signature check is not an install")

    def test_the_temporary_sigstore_verifier_is_hash_locked(self):
        text = GATE.read_text()
        installs = [l.strip() for l in text.splitlines()
                    if "pip" in l and " install" in l and not l.lstrip().startswith("#")]
        self.assertEqual(len(installs), 1, installs)
        for flag in ("--require-hashes", "--no-deps", "-r", "packaging/macos/sigstore_verifier.txt"):
            self.assertIn(flag, installs[0])
        self.assertNotRegex(text, r"install\s+[\"']?sigstore", "never a direct, unlocked sigstore install")
        self.assertTrue(VERIFIER_REQS.is_file(), "packaging/macos/sigstore_verifier.txt is missing")
        reqs = [l for l in VERIFIER_REQS.read_text().replace("\\\n", " ").splitlines()
                if l.strip() and not l.startswith("#")]
        self.assertIn(SIGSTORE_PIN, " ".join(reqs))
        for r in reqs:
            self.assertRegex(r, r"^[A-Za-z0-9._-]+==\S+", r)
            self.assertIn("--hash=sha256:", r, r)
        pins = json.loads(PINS.read_text())
        self.assertEqual(pins["sigstore_verifier"], {"requirements": "packaging/macos/sigstore_verifier.txt",
                                                     "sha256": hashlib.sha256(VERIFIER_REQS.read_bytes()).hexdigest()})


if __name__ == "__main__":
    unittest.main()
