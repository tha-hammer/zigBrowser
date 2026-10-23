#!/usr/bin/env python3
r"""Selftest of tests/windows/m8_1032dbb_incident_cleanup.py (NavyCanyon 649755f7), hostless.

Runs the REAL script (and the REAL webview2_cleanup.py), copied into a temp tree, against a fake `ssh` first on PATH
that plays the Win11 VM from a JSON state file: the processes (pid -> name, start ticks), the zb_m8_* tasks, the
folders, the marker and the two snapshots, plus failure knobs. The script's transport is its pinned literal one (the
real VM address and key paths), so every run is inside `unshare --user --map-current-user --net`: no packet can leave
even if the fake were missing.

Pinned: a pid/name/start mismatch is never stopped (the script stops before stopping anything); any marker, read, stop,
wait, task or delete failure stops the script; only still-matching process objects are stopped, by object, never by
name or taskkill; the wait is bounded; each literal folder is removed through the shared helper exactly once, in
order; the final check proves marker, identities, tasks and folders gone and %LOCALAPPDATA%\zig unchanged; without
`--run` nothing is contacted.

Run alone:  python3 -I tests/windows/m8_1032dbb_incident_cleanup_selftest.py -v
"""
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
NETNS = ["unshare", "--user", "--map-current-user", "--net"]
BASELINE = "files=977 bytes=98934749 listing_sha256=9d71b15c6f0c57b5d5fccadf0056c05bdf68ea3d9e42bc2e9f397d09302373d8"
IDS = {5428: ["zigBrowser", "639283414507917678"], 4732: ["msedgewebview2", "639283414513053026"],
       2344: ["msedgewebview2", "639283414513865651"], 2796: ["msedgewebview2", "639283414520291614"],
       7932: ["msedgewebview2", "639283414520339797"], 1676: ["msedgewebview2", "639283414531985870"],
       6240: ["msedgewebview2", "639283414532020792"], 752: ["zigBrowser", "639283414623742769"],
       5796: ["msedgewebview2", "639283414626455108"]}
OTHER = {6772: ["msedgewebview2", "639280000000000001"], 5536: ["explorer", "639280000000000002"]}
RUNS = r"%USERPROFILE%\zb\runs\m8-2318289-fdd954617c9b"
BUILD = r"%USERPROFILE%\zb\build\run-1032dbb27f7cac837632d35571fca7d3f01ec4c2"

_FAKE_SSH = r'''#!/usr/bin/env python3
import json, os, re, sys
state_path = os.environ["ZB_FAKE_STATE"]
st = json.load(open(state_path))
argv = sys.argv[1:]
cmd = argv[-1]
body = sys.stdin.read() if cmd.endswith('"$input | Out-String | iex"') else ""
kind = body.split("\n", 1)[0].replace("# ZB_INCIDENT_PROBE ", "") if body else ""
with open(os.environ["ZB_FAKE_LOG"], "a") as log:
    log.write(json.dumps({"argv": argv, "kind": kind, "body": body}) + "\n")
k = st["knobs"]
procs = st["procs"]
out, rc = [], 0
if r"\zb\.gate-identity" in cmd:
    out = [st["marker"]]
elif cmd == "schtasks /query /fo csv /nh":
    rc = k.get("tasks_rc", 0); out = ['"\\%s","N/A","Ready"' % t for t in st["tasks"]] + ['"\\Other","N/A","Ready"']
elif kind == "snapshots":
    if k.get("snap_fail"): rc = 1
    else:
        out = ["localappdata_zig\t" + st["localappdata"], "zb_zig_global_cache\tfiles=916 bytes=67594985 listing_sha256=5eaa"]
        st["localappdata"] = k.get("localappdata_after", st["localappdata"])
    out.append("'END'".strip("'") if not k.get("snap_fail") else "")
elif kind == "identities":
    if k.get("ident_fail"): rc = 1
    else:
        ids = re.search(r"foreach \(\$id in @\(([0-9, ]+)\)\)", body).group(1)
        for pid in [int(x) for x in ids.split(",")]:
            p = procs.get(str(pid))
            out.append("ABSENT\t%d" % pid if p is None else "PRESENT\t%d\t%s\t%s" % (pid, p[0], p[1]))
        out.append("END")
elif kind == "stop":
    for pid, imposter in k.get("swap_before_stop", {}).items():   # the pid is reused after validation
        procs[pid] = imposter
    for pid, name, ticks in re.findall(r"\$targets \+= ,@\(([0-9]+), '([A-Za-z0-9]+)', ([0-9]+)\)", body):
        p = procs.get(pid)
        if p is None: out.append("ABSENT\t" + pid); continue
        if p[0] != name or p[1] != ticks: out.append("MISMATCH\t%s\t%s\t%s" % (pid, p[0], p[1])); continue
        if pid in k.get("stop_error", []): out.append("ERROR\t%s\tAccess is denied" % pid); continue
        st.setdefault("stopped", []).append(int(pid))
        if pid not in k.get("survive", []): del procs[pid]
        out.append("STOPPED\t" + pid)
    out.append("END")
elif "Get-Process" in cmd:   # webview2_cleanup census
    for pid, (name, ticks) in sorted(procs.items()):
        if re.match(r"^(msedgewebview2|zigBrowser|ws[0-9][a-z0-9-]*)$", name): out.append("%s\t%s\t%s" % (name, pid, ticks))
    out.append("END")
elif "Get-Item" in cmd:
    d = "%USERPROFILE%\\" + re.search(r"Join-Path \$env:USERPROFILE '([^']+)'", cmd).group(1)
    out = ["DIR" if d in st["folders"] else "ABSENT"]
elif cmd.startswith("rmdir /s /q "):
    d = cmd[len("rmdir /s /q "):].strip('"')
    st.setdefault("rmdirs", []).append(d)
    if d not in k.get("rmdir_fail", []) and d in st["folders"]: st["folders"].remove(d)
elif cmd.startswith("if exist "):
    d = re.search(r'if exist "([^"]+)"', cmd).group(1)
    out = ["LEFT" if d in st["folders"] else "GONE"]
else:
    rc = 9; out = ["fake: unknown command"]
json.dump(st, open(state_path, "w"))
sys.stdout.write("\r\n".join(out) + ("\r\n" if out else ""))
sys.exit(rc)
'''

_CHILD = r"""
import sys
sys.path.insert(0, sys.argv[1])
import m8_1032dbb_incident_cleanup as m
m.STOP_WAIT_S = 2.0      # the 60 s wait, shortened for a hostless run
m.POLL_S = 0.1
sys.exit(m.main(sys.argv[2:]))
"""


class IncidentCleanup(unittest.TestCase):
    def _run(self, args=("--run",), procs=None, tasks=(), folders=(RUNS, BUILD), marker="zb-win11-m8-ws0-2026-10-20",
             **knobs):
        t = tempfile.mkdtemp(prefix="zb-incident-")
        self.addCleanup(shutil.rmtree, t, True)
        td = pathlib.Path(t)
        win = td / "tests" / "windows"; win.mkdir(parents=True)
        for name in ("m8_1032dbb_incident_cleanup.py", "webview2_cleanup.py"):
            src = HERE / name
            if src.exists():
                shutil.copy2(src, win / name)
        bindir = td / "bin"; bindir.mkdir()
        (bindir / "ssh").write_text(_FAKE_SSH); (bindir / "ssh").chmod(0o755)
        if procs is None:
            procs = {**IDS, **OTHER}
        state = {"procs": {str(p): v for p, v in procs.items()}, "tasks": list(tasks), "folders": list(folders),
                 "marker": marker, "localappdata": knobs.pop("localappdata", BASELINE), "knobs": knobs}
        sp = td / "state.json"; sp.write_text(json.dumps(state))
        log = td / "calls.log"; log.write_text("")
        env = {"PATH": f"{bindir}:/usr/bin:/bin", "HOME": str(td / "home"), "ZB_FAKE_STATE": str(sp),
               "ZB_FAKE_LOG": str(log),
               # a decoy configuration the script must ignore (it pins its own transport)
               "ZB_WIN11_HOST": "192.0.2.1", "ZB_WIN11_KEY": str(td / "no-such-key")}
        proc = subprocess.run([*NETNS, "python3", "-I", "-c", _CHILD, str(win), *args], env=env, cwd=td,
                              capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
        calls = [json.loads(l) for l in log.read_text().splitlines()]
        final = json.loads(sp.read_text())
        detail = (f"\nrc={proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}\ncalls:\n"
                  + "\n".join(f"{c['kind'] or c['argv'][-1]}" for c in calls))
        self.assertNotIn("unshare: ", proc.stderr, "the network namespace must start" + detail)
        self.assertNotIn("No module named", proc.stderr, "the script must exist" + detail)
        for c in calls:
            a = c["argv"]
            self.assertEqual(a[:2], ["-i", "/home/maceo/vms/win11-m8/zb_win_key"], "the pinned key" + detail)
            for opt in ("IdentitiesOnly=yes", "BatchMode=yes", "StrictHostKeyChecking=yes",
                        "UserKnownHostsFile=/home/maceo/vms/win11-m8/known_hosts"):
                self.assertIn(opt, a, detail)
            self.assertEqual(a[-4:-1], ["-p", "2222", "zbtext@127.0.0.1"], "the pinned transport" + detail)
            self.assertNotIn("taskkill", json.dumps(c), "never taskkill" + detail)
            self.assertNotRegex(c["body"], r"Stop-Process\s+-Name", "never a name-wide stop" + detail)
        return proc, calls, final, detail

    @staticmethod
    def _stop_targets(calls):
        import re
        return [int(p) for c in calls if c["kind"] == "stop"
                for p in re.findall(r"\$targets \+= ,@\(([0-9]+),", c["body"])]

    def _nothing_stopped_or_deleted(self, final, detail):
        self.assertEqual(final.get("stopped", []), [], "nothing may be stopped" + detail)
        self.assertEqual(final.get("rmdirs", []), [], "nothing may be deleted" + detail)

    def test_happy_cleanup_stops_the_nine_removes_both_folders_once_and_proves_it(self):
        proc, calls, final, detail = self._run()
        self.assertEqual(proc.returncode, 0, detail)
        self.assertIn("RESULT\tPASS", proc.stdout, detail)
        self.assertEqual(sorted(final["stopped"]), sorted(IDS), "exactly the nine pinned identities" + detail)
        self.assertEqual(sorted(int(p) for p in final["procs"]), sorted(OTHER), "others untouched" + detail)
        self.assertEqual(final["rmdirs"], [RUNS, BUILD], "each folder once, runs first" + detail)
        self.assertEqual(final["folders"], [], detail)
        self.assertIn(f"FINAL\tlocalappdata_zig\t{BASELINE}", proc.stdout, detail)
        kinds = [c["kind"] or c["argv"][-1].split()[0] for c in calls]
        self.assertLess(kinds.index("stop"), kinds.index("rmdir"), "stops before deletions" + detail)

    def test_absent_originals_are_reported_and_only_present_ones_stopped(self):
        procs = {p: v for p, v in {**IDS, **OTHER}.items() if p not in (4732, 752)}
        proc, calls, final, detail = self._run(procs=procs)
        self.assertEqual(proc.returncode, 0, detail)
        self.assertIn("IDENTITY\tzigBrowser\t752\t639283414623742769\tabsent", proc.stdout, detail)
        self.assertNotIn(752, self._stop_targets(calls), "an absent original is not a stop target" + detail)
        self.assertEqual(sorted(final["stopped"]), sorted(set(IDS) - {4732, 752}), detail)

    def test_a_reused_pid_is_never_stopped(self):
        for label, imposter in (("start", ["zigBrowser", "639283499999999999"]), ("name", ["notepad", IDS[752][1]])):
            with self.subTest(mismatch=label):
                procs = {**IDS, **OTHER, 752: imposter}
                proc, calls, final, detail = self._run(procs=procs)
                self.assertEqual(proc.returncode, 1, detail)
                self.assertIn("mismatch", proc.stdout, detail)
                self.assertEqual(self._stop_targets(calls), [], "no stop probe at all after a mismatch" + detail)
                self._nothing_stopped_or_deleted(final, detail)
                self.assertEqual(final["procs"]["752"], imposter, "the imposter is still running" + detail)

    def test_a_pid_reused_between_validation_and_stop_is_not_stopped(self):
        imposter = ["zigBrowser", "639283499999999999"]
        proc, calls, final, detail = self._run(swap_before_stop={"752": imposter})
        self.assertEqual(proc.returncode, 1, "a MISMATCH at the stop re-check stops the script" + detail)
        self.assertIn("MISMATCH\t752", proc.stdout, detail)
        self.assertNotIn(752, final.get("stopped", []), "the imposter is not stopped" + detail)
        self.assertEqual(final["procs"]["752"], imposter, detail)
        self.assertEqual(final.get("rmdirs", []), [], detail)
        # NavyCanyon 9b8b94e0: the failed stop ends the step; the later pinned target 5796 is untouched
        self.assertNotIn(5796, self._stop_targets(calls), "no stop after the first failed stop" + detail)
        self.assertEqual(final["procs"].get("5796"), IDS[5796], "the later target is still alive" + detail)
        # tripwire on the PowerShell the fake cannot execute (the Win11 run proves it): the stop re-reads the
        # object, re-checks name and start, and stops that object
        body = next(c["body"] for c in calls if c["kind"] == "stop")
        self.assertIn("if ($p.ProcessName -ne $n -or $pk -ne $k)", body, detail)
        self.assertIn("Stop-Process -InputObject $p -Force", body, detail)

    def test_wrong_marker_contacts_nothing_else(self):
        proc, calls, final, detail = self._run(marker="someone-else")
        self.assertEqual(proc.returncode, 1, detail)
        self.assertEqual(len(calls), 1, "only the marker read" + detail)
        self._nothing_stopped_or_deleted(final, detail)

    def test_a_failed_identity_read_stops_before_any_stop(self):
        proc, calls, final, detail = self._run(ident_fail=True)
        self.assertEqual(proc.returncode, 1, detail)
        self._nothing_stopped_or_deleted(final, detail)

    def test_a_failed_snapshot_read_stops_before_any_stop(self):
        proc, calls, final, detail = self._run(snap_fail=True)
        self.assertEqual(proc.returncode, 1, detail)
        self._nothing_stopped_or_deleted(final, detail)

    def test_a_stop_error_stops_the_script_before_any_deletion(self):
        proc, calls, final, detail = self._run(stop_error=["752"])
        self.assertEqual(proc.returncode, 1, detail)
        self.assertIn("stop failed", proc.stdout, detail)
        self.assertEqual(final.get("rmdirs", []), [], detail)
        # NavyCanyon 9b8b94e0: the failed stop ends the step; the later pinned target 5796 is untouched
        self.assertNotIn(5796, self._stop_targets(calls), "no stop after the first failed stop" + detail)
        self.assertNotIn(5796, final.get("stopped", []), detail)
        self.assertEqual(final["procs"].get("5796"), IDS[5796], "the later target is still alive" + detail)

    def test_a_survivor_after_the_bounded_wait_stops_the_script(self):
        proc, calls, final, detail = self._run(survive=["5796"])
        self.assertEqual(proc.returncode, 1, detail)
        self.assertIn("still alive after 2 s: [5796]", proc.stdout, detail)
        self.assertEqual(final.get("rmdirs", []), [], detail)

    def test_a_leftover_m8_task_stops_the_script_before_any_deletion(self):
        proc, calls, final, detail = self._run(tasks=["zb_m8_123_deadbeef"])
        self.assertEqual(proc.returncode, 1, detail)
        self.assertIn("zb_m8_* task check failed", proc.stdout, detail)
        self.assertEqual(final.get("rmdirs", []), [], detail)

    def test_a_failed_first_removal_stops_before_the_second(self):
        proc, calls, final, detail = self._run(rmdir_fail=[RUNS])
        self.assertEqual(proc.returncode, 1, detail)
        self.assertEqual(final["rmdirs"], [RUNS], "the second folder is not attempted" + detail)

    def test_a_changed_localappdata_zig_fails_the_final_check(self):
        proc, calls, final, detail = self._run(localappdata_after="files=978 bytes=1 listing_sha256=00")
        self.assertEqual(proc.returncode, 1, detail)
        self.assertIn("%LOCALAPPDATA%\\zig changed", proc.stdout, detail)

    def test_without_run_nothing_is_contacted(self):
        for args in ((), ("--dry",), ("--run", "--extra")):
            with self.subTest(args=args):
                proc, calls, final, detail = self._run(args=args)
                self.assertEqual(proc.returncode, 2, detail)
                self.assertEqual(calls, [], detail)


if __name__ == "__main__":
    unittest.main()
