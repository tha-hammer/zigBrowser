#!/usr/bin/env python3
r"""Selftest of tests/windows/win10_probe.py, the first read-only Win10 probe (orchestrator 2026-10-23; FoggyReef
8417/8424 fields), hostless.

The probe pins the Win10 transport (zbtest@100.123.34.15 port 22, the m8 key, the win10-fs known_hosts) and the
owner-confirmed host-key fingerprint. No Win10 marker exists in any record, so it READS the marker and reports it
(or `absent`); the host is identified by the pinned host key, checked locally before any contact.

Runs the REAL probe, copied into a temp tree, against fake `ssh`, `scp` and `ssh-keygen` first on PATH that play the
box from a JSON state file. Because the probe's pinned transport is real, every run is inside
`unshare --user --map-current-user --net`: no packet can leave even if a fake were missing.

Pinned: without exactly `--run` nothing is contacted (rc 2); a known_hosts entry without the pinned fingerprint stops
before any contact; one streamed read-only probe reports marker, zb_dir, webview2_pv, c_free_bytes, python,
powershell_ok, os and user; cmd_if_exist through cmd.exe; scp_legacy is one `scp -O` of a nonce file into
C:\Users\zbtest\zb only (skipped, with no write, when zb\ is absent), read back, then deleted by its guarded exact path
`%USERPROFILE%\zb\zb-probe-<16 hex>.txt` and proven gone; no other delete ever (no rmdir, no Remove-Item); every call
uses the pinned transport and never the Win11 VM; a leftover probe file or a failed read fails the run.

Run alone:  python3 -I tests/windows/win10_probe_selftest.py -v
"""
import json
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
NETNS = ["unshare", "--user", "--map-current-user", "--net"]
FP = "SHA256:AhusOW2s/1hKVAOhriqN38c1Hn8hSiNMBrdbcRGAnF4"
PROBE_FILE = re.compile(r"^%USERPROFILE%\\zb\\zb-probe-[0-9a-f]{16}\.txt$")

_FAKE_KEYGEN = r'''#!/usr/bin/env python3
import json, os, sys
st = json.load(open(os.environ["ZB_FAKE_STATE"]))
with open(os.environ["ZB_FAKE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "ssh-keygen", "argv": sys.argv[1:]}) + "\n")
fp = st["knobs"].get("hostkey_fp", "SHA256:AhusOW2s/1hKVAOhriqN38c1Hn8hSiNMBrdbcRGAnF4")
if fp == "none":
    sys.exit(1)
print("# Host 100.123.34.15 found: line 1 type ED25519")
print("100.123.34.15 ED25519 " + fp)
'''

_FAKE_SSH = r'''#!/usr/bin/env python3
import json, os, re, sys
sp = os.environ["ZB_FAKE_STATE"]; st = json.load(open(sp)); k = st["knobs"]
argv = sys.argv[1:]; cmd = argv[-1]
body = sys.stdin.read() if cmd.endswith('"$input | Out-String | iex"') else ""
with open(os.environ["ZB_FAKE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "ssh", "argv": argv, "body": body}) + "\n")
out, rc = [], 0
if body.startswith("# ZB_WIN10_PROBE"):
    if k.get("probe_rc"): rc = k["probe_rc"]
    else:
        f = st["facts"]
        for name in ("marker", "zb_dir", "webview2_pv", "c_free_bytes", "python", "powershell_ok", "os", "user"):
            out.append("FIELD\t%s\t%s" % (name, f[name]))
        out.append("END")
        rc = k.get("probe_rc_after_answer", 0)
elif cmd.startswith("if exist "):
    d = re.search(r'if exist "([^"]+)"', cmd).group(1)
    if d == "%USERPROFILE%\\zb\\":
        out = ["PRESENT" if st["facts"]["zb_dir"] == "present" else "ABSENT"]
    else:
        out = ["PRESENT" if d in st["files"] else "ABSENT"]
elif cmd.startswith("type "):
    d = re.search(r'type "([^"]+)"', cmd).group(1)
    if d in st["files"]: out = [k.get("readback", st["files"][d])]
    else: rc = 1
elif cmd.startswith("del "):
    d = re.search(r'del /q "([^"]+)"', cmd).group(1)
    st.setdefault("dels", []).append(d)
    if not k.get("del_fail"): st["files"].pop(d, None)
else:
    rc = 9; out = ["fake: unknown command " + cmd]
json.dump(st, open(sp, "w"))
sys.stdout.write("\r\n".join(out) + ("\r\n" if out else ""))
sys.exit(rc)
'''

_FAKE_SCP = r'''#!/usr/bin/env python3
import json, os, sys
sp = os.environ["ZB_FAKE_STATE"]; st = json.load(open(sp)); k = st["knobs"]
argv = sys.argv[1:]
with open(os.environ["ZB_FAKE_LOG"], "a") as log:
    log.write(json.dumps({"tool": "scp", "argv": argv}) + "\n")
if k.get("scp_fail") or st["facts"]["zb_dir"] != "present":
    sys.stderr.write("scp: dest open: No such file or directory\n"); sys.exit(1)
src, dst = argv[-2], argv[-1]
rel = dst.split(":", 1)[1]                       # zb/zb-probe-....txt
st["files"]["%USERPROFILE%\\" + rel.replace("/", "\\")] = open(src).read().strip()
json.dump(st, open(sp, "w"))
'''

_CHILD = r"""
import sys
sys.path.insert(0, sys.argv[1])
import win10_probe as p
sys.exit(p.main(sys.argv[2:]))
"""

FACTS = {"marker": "absent", "zb_dir": "present", "webview2_pv": "155.0.4283.62", "c_free_bytes": "2147483648",
         "python": "missing", "powershell_ok": "yes", "os": "10.0.19041", "user": "zbtest"}


class Win10Probe(unittest.TestCase):
    def _run(self, args=("--run",), facts=None, **knobs):
        t = tempfile.mkdtemp(prefix="zb-w10probe-")
        self.addCleanup(shutil.rmtree, t, True)
        td = pathlib.Path(t)
        win = td / "tests" / "windows"; win.mkdir(parents=True)
        src = HERE / "win10_probe.py"
        if src.exists():
            shutil.copy2(src, win / "win10_probe.py")
        bindir = td / "bin"; bindir.mkdir()
        for name, body in (("ssh", _FAKE_SSH), ("scp", _FAKE_SCP), ("ssh-keygen", _FAKE_KEYGEN)):
            (bindir / name).write_text(body); (bindir / name).chmod(0o755)
        state = {"facts": {**FACTS, **(facts or {})}, "files": {}, "knobs": knobs}
        sp = td / "state.json"; sp.write_text(json.dumps(state))
        log = td / "calls.log"; log.write_text("")
        env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td / "home"), "TMPDIR": str(td),
               "ZB_FAKE_STATE": str(sp), "ZB_FAKE_LOG": str(log),
               # decoys the probe must ignore (it pins its own transport)
               "ZB_WIN10_HOST": "198.51.100.15", "ZB_WIN10_KEY": str(td / "no-such-key"),
               "ZB_WIN11_HOST": "192.0.2.1"}
        (td / "home").mkdir()
        proc = subprocess.run([*NETNS, "python3", "-I", "-c", _CHILD, str(win), *args], env=env, cwd=td,
                              capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL)
        calls = [json.loads(l) for l in log.read_text().splitlines()]
        final = json.loads(sp.read_text())
        detail = (f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls:\n"
                  + "\n".join(f"{c['tool']} {c['argv'][-1][:120]}" for c in calls))
        self.assertNotIn("unshare: ", proc.stderr, "the network namespace must start" + detail)
        self.assertNotIn("No module named", proc.stderr, "the probe must exist" + detail)
        for c in calls:
            a = c["argv"]
            if c["tool"] == "ssh-keygen":
                continue
            self.assertNotIn("127.0.0.1", " ".join(a), "never the Win11 VM" + detail)
            self.assertEqual(a[:2], ["-i", "/home/maceo/vms/win11-m8/zb_win_key"], "the pinned key" + detail)
            for opt in ("IdentitiesOnly=yes", "BatchMode=yes", "StrictHostKeyChecking=yes",
                        "UserKnownHostsFile=/home/maceo/vms/win10-fs/known_hosts"):
                self.assertIn(opt, a, detail)
            if c["tool"] == "ssh":
                self.assertEqual(a[-4:-1], ["-p", "22", "zbtest@100.123.34.15"], "the pinned transport" + detail)
                self.assertNotRegex(a[-1] + c.get("body", ""), r"(?i)rmdir|Remove-Item|\brd\b",
                                    "no other delete, ever" + detail)
                if a[-1].startswith("del "):
                    d = re.search(r'del /q "([^"]+)"', a[-1]).group(1)
                    self.assertRegex(d, PROBE_FILE, "the only delete is the guarded probe file" + detail)
            else:
                self.assertIn("-O", a, "legacy scp protocol" + detail)
                self.assertEqual(a[a.index("-P") + 1], "22", detail)
                self.assertRegex(a[-1], r"^zbtest@100\.123\.34\.15:zb/zb-probe-[0-9a-f]{16}\.txt$",
                                 "writes only into C:\\Users\\zbtest\\zb" + detail)
        fields = dict(l.split("\t")[1:3] for l in proc.stdout.splitlines() if l.startswith("FIELD\t"))
        return proc, calls, final, fields, detail

    def test_happy_probe_reports_every_field_and_proves_legacy_scp_then_removes_its_file(self):
        proc, calls, final, fields, detail = self._run()
        self.assertEqual(proc.returncode, 0, detail)
        for name in ("hostkey", "marker", "zb_dir", "webview2_pv", "c_free_bytes", "python", "powershell_ok", "os",
                     "user", "cmd_if_exist", "scp_legacy", "scp_cleanup"):
            self.assertIn(name, fields, f"field {name}" + detail)
        self.assertEqual(fields["hostkey"], FP, detail)
        self.assertEqual(fields["marker"], "absent", detail)
        self.assertEqual(fields["webview2_pv"], "155.0.4283.62", detail)
        self.assertEqual(fields["cmd_if_exist"], "PRESENT", detail)
        self.assertEqual(fields["scp_legacy"], "ok", detail)
        self.assertEqual(fields["scp_cleanup"], "gone", detail)
        self.assertEqual(final["files"], {}, "the probe file is gone" + detail)
        self.assertEqual(len(final.get("dels", [])), 1, "exactly one delete" + detail)
        tools = [c["tool"] for c in calls]
        self.assertEqual(tools[0], "ssh-keygen", "the host key is checked before any contact" + detail)

    def test_a_present_marker_is_reported_literally(self):
        proc, calls, final, fields, detail = self._run(facts={"marker": "zb-win10-fs-2026-10-23"})
        self.assertEqual(proc.returncode, 0, detail)
        self.assertEqual(fields["marker"], "zb-win10-fs-2026-10-23", detail)

    def test_without_run_nothing_is_contacted(self):
        for args in ((), ("--dry",), ("--run", "x")):
            with self.subTest(args=args):
                proc, calls, final, fields, detail = self._run(args=args)
                self.assertEqual(proc.returncode, 2, detail)
                self.assertEqual([c for c in calls if c["tool"] != "ssh-keygen"], [], detail)

    def test_a_host_key_without_the_pinned_fingerprint_contacts_nothing(self):
        for fp in ("SHA256:someoneElse000000000000000000000000000000000", "none"):
            with self.subTest(fp=fp):
                proc, calls, final, fields, detail = self._run(hostkey_fp=fp)
                self.assertEqual(proc.returncode, 1, detail)
                self.assertEqual([c["tool"] for c in calls], ["ssh-keygen"], "no ssh or scp at all" + detail)

    def test_no_zb_dir_skips_the_scp_and_writes_nothing(self):
        proc, calls, final, fields, detail = self._run(facts={"zb_dir": "absent"})
        self.assertEqual(proc.returncode, 0, detail)
        self.assertEqual(fields["scp_legacy"], "skipped: no zb dir", detail)
        self.assertEqual([c for c in calls if c["tool"] == "scp"], [], "no write at all" + detail)
        self.assertEqual(final.get("dels", []), [], detail)

    def test_a_failed_scp_is_reported_and_nothing_is_deleted(self):
        proc, calls, final, fields, detail = self._run(scp_fail=True)
        self.assertEqual(proc.returncode, 0, detail)
        self.assertTrue(fields["scp_legacy"].startswith("fail"), detail)
        self.assertEqual(fields["scp_cleanup"], "gone", detail)
        self.assertEqual(final.get("dels", []), [], "no file, no delete" + detail)

    def test_a_readback_mismatch_is_a_failed_scp_and_the_file_is_still_removed(self):
        proc, calls, final, fields, detail = self._run(readback="garbage")
        self.assertEqual(proc.returncode, 0, detail)
        self.assertTrue(fields["scp_legacy"].startswith("fail"), detail)
        self.assertEqual(fields["scp_cleanup"], "gone", detail)
        self.assertEqual(final["files"], {}, detail)

    def test_a_probe_file_left_behind_fails_the_run(self):
        proc, calls, final, fields, detail = self._run(del_fail=True)
        self.assertEqual(proc.returncode, 1, detail)
        self.assertEqual(fields["scp_cleanup"], "left", detail)

    def test_a_failed_read_probe_stops_before_any_write(self):
        proc, calls, final, fields, detail = self._run(probe_rc=255)
        self.assertEqual(proc.returncode, 1, detail)
        self.assertEqual([c for c in calls if c["tool"] == "scp"], [], detail)
        self.assertEqual(final.get("dels", []), [], detail)

    def test_a_nonzero_read_probe_stops_even_with_a_full_answer(self):
        proc, calls, final, fields, detail = self._run(probe_rc_after_answer=1)
        self.assertEqual(proc.returncode, 1, "the probe's exit status is part of the read" + detail)
        self.assertIn("STOPPED", proc.stdout, detail)
        self.assertEqual([c for c in calls if c["tool"] == "scp"], [], detail)


if __name__ == "__main__":
    unittest.main()
