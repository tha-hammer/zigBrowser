#!/usr/bin/env python3
r"""ONE-TIME incident cleanup after the rejected WS1.2 m8 Win11 run at 1032dbb (NavyCanyon 649755f7, option (a)).

That run left nine run-created processes alive (two zigBrowser, seven msedgewebview2) and two folders the shared
helper correctly refused to delete. This script is the only release-able way to clean that up. Everything it may
touch is pinned below as literals: the Win11 transport and identity marker, the nine (name, pid, UTC start ticks)
identities from the run's evidence, and the two folders. It reads no host, key, pid or folder from the environment.

Order (each step must succeed, or the script STOPS at once, with no retry and nothing further done):
  1. the identity marker in %USERPROFILE%\zb\.gate-identity is the literal Win11 marker;
  2. a read-only snapshot of %LOCALAPPDATA%\zig and zb\zig-global-cache (file count, bytes, listing sha256);
  3. every one of the nine identities is read and validated. An original that is gone is reported (ABSENT). A pid
     that now holds a different name or start time (MISMATCH), or one whose start time cannot be read, is NEVER
     stopped: the script stops before stopping anything;
  4. only the still-matching process objects are force-stopped. Each is re-read and re-checked right before
     `Stop-Process -InputObject` (never by name, never taskkill);
  5. a wait of at most STOP_WAIT_S (60 s, one monotonic budget) for those exact identities to disappear;
  6. no zb_m8_* scheduled task may exist;
  7. a fresh webview2_cleanup census, then webview2_cleanup.remove_after_webview2 exactly once for each of the two
     literal folders, in order; a failure on the first means the second is not attempted;
  8. a final read-only check: the marker, the nine identities gone, no zb_m8_* task, both folders absent, the census
     (reported), the zb\zig-global-cache size (reported), and %LOCALAPPDATA%\zig equal to the pinned baseline.
Exit 0 only when every step and the final check pass; 1 otherwise; 2 without --run (nothing contacted).

It needs NavyCanyon's approval at an exact ref and sha256 and the orchestrator's release. It is scratch-only (run
from a clean export of that ref) and is not a test step.

Run:  env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS -u SSH_ASKPASS_REQUIRE \
      python3 -I tests/windows/m8_1032dbb_incident_cleanup.py --run
"""
import os
import pathlib
import re
import subprocess
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))  # `python3 -I` drops the script dir
import webview2_cleanup  # noqa: E402  the accepted shared cleanup (one rmdir, after a bounded census wait)

# --- pinned literals (evidence: m8run_1032dbb.err sha256 5e3dd5da...4b48, NavyCanyon 649755f7) -------------------
HOST, PORT, USER = "127.0.0.1", "2222", "zbtext"
KEY = "/home/maceo/vms/win11-m8/zb_win_key"
KNOWN_HOSTS = "/home/maceo/vms/win11-m8/known_hosts"
MARKER = "zb-win11-m8-ws0-2026-10-20"
IDENTITIES = (  # (name, pid, UTC start ticks) of the nine survivors
    ("zigBrowser", 5428, 639283414507917678),
    ("msedgewebview2", 4732, 639283414513053026),
    ("msedgewebview2", 2344, 639283414513865651),
    ("msedgewebview2", 2796, 639283414520291614),
    ("msedgewebview2", 7932, 639283414520339797),
    ("msedgewebview2", 1676, 639283414531985870),
    ("msedgewebview2", 6240, 639283414532020792),
    ("zigBrowser", 752, 639283414623742769),
    ("msedgewebview2", 5796, 639283414626455108),
)
FOLDERS = (
    r"%USERPROFILE%\zb\runs\m8-2318289-fdd954617c9b",
    r"%USERPROFILE%\zb\build\run-1032dbb27f7cac837632d35571fca7d3f01ec4c2",
)
# %LOCALAPPDATA%\zig as recorded at 2026-10-23T04:46:45Z, after the last accepted m8 cleanup (the 1032dbb build kept
# its caches under zb\): file count, bytes, sha256 of the sorted FullName|Length|LastWriteTicks listing.
LOCALAPPDATA_ZIG_BASELINE = ("files=977 bytes=98934749 "
                             "listing_sha256=9d71b15c6f0c57b5d5fccadf0056c05bdf68ea3d9e42bc2e9f397d09302373d8")

STOP_WAIT_S = 60.0
POLL_S = 1.0
PROBE_TIMEOUT_S = 120
STREAMED = 'powershell -NoProfile -NonInteractive -Command "$input | Out-String | iex"'
SCRUB = ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE")


class Stop(Exception):
    """A failed step: the script stops here."""


def say(msg):
    print(msg, flush=True)


def ssh(command, timeout=PROBE_TIMEOUT_S, stdin_text=None):
    argv = ["ssh", "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={KNOWN_HOSTS}", "-o", "ConnectTimeout=15", "-p", PORT, f"{USER}@{HOST}", command]
    env = {k: v for k, v in os.environ.items() if k not in SCRUB}
    if stdin_text is None:
        return subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout,
                              stdin=subprocess.DEVNULL)
    return subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout, input=stdin_text)


def probe(kind, body):
    """Streams one tagged PowerShell probe; returns its lines up to the END line, or raises Stop."""
    try:
        r = ssh(STREAMED, stdin_text=f"# ZB_INCIDENT_PROBE {kind}\n{body}\n'END'\n")
    except (subprocess.TimeoutExpired, OSError) as e:
        raise Stop(f"{kind} probe failed: {type(e).__name__}: {e}")
    lines = [l.strip() for l in r.stdout.replace("\r", "").split("\n") if l.strip()]
    if r.returncode != 0 or not lines or lines[-1] != "END":
        raise Stop(f"{kind} probe rc={r.returncode} without an END line: {r.stdout[-300:]!r} {r.stderr.strip()[:300]}")
    return lines[:-1]


_SNAP_FN = r"""function Snap([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return 'absent' }
  $f = @(Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction Stop)
  $bytes = ($f | Measure-Object -Property Length -Sum).Sum; if ($null -eq $bytes) { $bytes = 0 }
  $lines = $f | Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $h = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))).Replace('-','').ToLower()
  return "files=$($f.Count) bytes=$bytes listing_sha256=$h"
}
$ErrorActionPreference = 'Stop'
'localappdata_zig' + [char]9 + (Snap (Join-Path $env:LOCALAPPDATA 'zig'))
'zb_zig_global_cache' + [char]9 + (Snap (Join-Path (Join-Path $env:USERPROFILE 'zb') 'zig-global-cache'))"""


def snapshots():
    got = dict(l.split("\t", 1) for l in probe("snapshots", _SNAP_FN) if "\t" in l)
    if set(got) != {"localappdata_zig", "zb_zig_global_cache"}:
        raise Stop(f"snapshot probe answered {sorted(got)}")
    return got


def check_marker():
    try:
        r = ssh(r'type "%USERPROFILE%\zb\.gate-identity"')
    except (subprocess.TimeoutExpired, OSError) as e:
        raise Stop(f"marker read failed: {type(e).__name__}: {e}")
    seen = r.stdout.strip() if r.returncode == 0 else ""
    say(f"HOST\twin11\tidentity_marker={seen or '<unreadable>'}")
    if seen != MARKER:
        raise Stop(f"wrong host: marker {seen!r} != {MARKER!r} (ssh rc={r.returncode})")


_IDENT_BODY = "\n".join(
    [f"foreach ($id in @({', '.join(str(pid) for _, pid, _ in IDENTITIES)})) {{",
     "  $p = Get-Process -Id $id -ErrorAction SilentlyContinue",
     "  if ($null -eq $p) { \"ABSENT`t$id\"; continue }",
     "  $k = try { $p.StartTime.ToUniversalTime().Ticks } catch { 'na' }",
     "  \"PRESENT`t$id`t$($p.ProcessName)`t$k\"",
     "}"])


def read_identities():
    """pid -> 'absent' | 'match' | 'mismatch: ...' for every pinned identity; raises Stop on a bad answer."""
    want = {pid: (name, ticks) for name, pid, ticks in IDENTITIES}
    state = {}
    for line in probe("identities", _IDENT_BODY):
        row = line.split("\t")
        if len(row) == 2 and row[0] == "ABSENT" and row[1].isdigit() and int(row[1]) in want:
            state[int(row[1])] = "absent"
        elif len(row) == 4 and row[0] == "PRESENT" and row[1].isdigit() and int(row[1]) in want:
            pid = int(row[1])
            name, ticks = want[pid]
            if row[2] == name and row[3] == str(ticks):
                state[pid] = "match"
            else:
                state[pid] = f"mismatch: now {row[2]} start {row[3]} (pinned {name} start {ticks})"
        else:
            raise Stop(f"identity probe answered an unexpected line {line!r}")
    if set(state) != set(want):
        raise Stop(f"identity probe did not answer for pids {sorted(set(want) - set(state))}")
    return state


def stop_body(targets):
    lines = ["$targets = @()"]
    lines += [f"$targets += ,@({pid}, '{name}', {ticks})" for name, pid, ticks in targets]
    lines += ["foreach ($t in $targets) {",
              "  $id = [int]$t[0]; $n = [string]$t[1]; $k = [long]$t[2]",
              "  $p = Get-Process -Id $id -ErrorAction SilentlyContinue",
              "  if ($null -eq $p) { \"ABSENT`t$id\"; continue }",
              "  $pk = try { $p.StartTime.ToUniversalTime().Ticks } catch { -1 }",
              "  if ($p.ProcessName -ne $n -or $pk -ne $k) { \"MISMATCH`t$id`t$($p.ProcessName)`t$pk\"; continue }",
              "  try { Stop-Process -InputObject $p -Force -ErrorAction Stop; \"STOPPED`t$id\" }",
              "  catch { \"ERROR`t$id`t$($_.Exception.Message)\" }",
              "}"]
    return "\n".join(lines)


def stop_matching(state):
    targets = [(n, pid, t) for n, pid, t in IDENTITIES if state[pid] == "match"]
    if not targets:
        say("STOP\tnothing to stop: every pinned identity is already gone")
        return
    outcome = {}
    for line in probe("stop", stop_body(targets)):
        row = line.split("\t")
        if len(row) < 2 or not row[1].isdigit() or int(row[1]) not in {pid for _, pid, _ in targets}:
            raise Stop(f"stop probe answered an unexpected line {line!r}")
        outcome[int(row[1])] = row
        say("STOP\t" + "\t".join(row))
    bad = [r for r in outcome.values() if r[0] not in ("STOPPED", "ABSENT")]
    missing = sorted({pid for _, pid, _ in targets} - set(outcome))
    if bad or missing:
        raise Stop(f"stop failed: {bad} no answer for {missing}")


def wait_gone():
    end = time.monotonic() + STOP_WAIT_S
    while True:
        state = read_identities()
        alive = sorted(pid for pid, s in state.items() if s == "match")
        if not alive:
            return
        if time.monotonic() >= end:
            raise Stop(f"pinned identities still alive after {STOP_WAIT_S:g} s: {alive}")
        time.sleep(min(POLL_S, max(0.0, end - time.monotonic())))


def no_m8_tasks():
    try:
        r = ssh("schtasks /query /fo csv /nh")
    except (subprocess.TimeoutExpired, OSError) as e:
        raise Stop(f"task query failed: {type(e).__name__}: {e}")
    left = [l for l in r.stdout.splitlines() if "zb_m8_" in l]
    if r.returncode != 0 or left:
        raise Stop(f"zb_m8_* task check failed (rc={r.returncode}): {left}")


def folders_absent():
    for d in FOLDERS:
        try:
            r = ssh(f'if exist "{d}" (echo LEFT) else (echo GONE)')
        except (subprocess.TimeoutExpired, OSError) as e:
            raise Stop(f"folder check failed: {type(e).__name__}: {e}")
        say(f"FOLDER\t{d}\t{r.stdout.strip()}")
        if r.returncode != 0 or r.stdout.strip() != "GONE":
            raise Stop(f"{d} is not absent (rc={r.returncode} {r.stdout.strip()!r})")


def cleanup():
    check_marker()
    pre = snapshots()
    say(f"PRE\tlocalappdata_zig\t{pre['localappdata_zig']}")
    say(f"PRE\tzb_zig_global_cache\t{pre['zb_zig_global_cache']}")
    state = read_identities()
    for name, pid, ticks in IDENTITIES:
        say(f"IDENTITY\t{name}\t{pid}\t{ticks}\t{state[pid]}")
    mismatched = [pid for pid, s in state.items() if s.startswith("mismatch")]
    if mismatched:
        raise Stop(f"pid/name/start mismatch for {sorted(mismatched)}: nothing is stopped")
    stop_matching(state)
    wait_gone()
    no_m8_tasks()
    try:
        before = webview2_cleanup.census(ssh, timeout=PROBE_TIMEOUT_S)
    except webview2_cleanup.CensusError as e:
        raise Stop(f"fresh census failed: {e}")
    say(f"CENSUS\tbefore removal\t{sorted(before)}")
    for d in FOLDERS:
        removed, why = webview2_cleanup.remove_after_webview2(ssh, d, before)
        say(f"REMOVE\t{d}\t{why}")
        if not removed:
            raise Stop(f"removal of {d} failed: {why}")


def final_check():
    """The read-only proof. Returns the list of failed checks."""
    failed = []
    for step in (check_marker, wait_gone_now, no_m8_tasks, folders_absent):
        try:
            step()
        except Stop as e:
            failed.append(str(e))
    try:
        now = webview2_cleanup.census(ssh, timeout=PROBE_TIMEOUT_S)
        say(f"FINAL\tcensus\t{sorted(now)}")
    except webview2_cleanup.CensusError as e:
        failed.append(f"final census failed: {e}")
    try:
        snap = snapshots()
        say(f"FINAL\tzb_zig_global_cache\t{snap['zb_zig_global_cache']}")
        say(f"FINAL\tlocalappdata_zig\t{snap['localappdata_zig']}")
        if snap["localappdata_zig"] != LOCALAPPDATA_ZIG_BASELINE:
            failed.append(f"%LOCALAPPDATA%\\zig changed: {snap['localappdata_zig']} != baseline {LOCALAPPDATA_ZIG_BASELINE}")
    except Stop as e:
        failed.append(str(e))
    return failed


def wait_gone_now():
    state = read_identities()
    alive = sorted(pid for pid, s in state.items() if s == "match")
    if alive:
        raise Stop(f"pinned identities still alive: {alive}")


def main(argv):
    if argv != ["--run"]:
        print("m8_1032dbb_incident_cleanup: refusing without exactly `--run` (needs NavyCanyon's approval at an exact"
              " ref and sha256 and the orchestrator's release); nothing contacted", file=sys.stderr)
        return 2
    try:
        cleanup()
    except Stop as e:
        say(f"STOPPED\t{e}")
        return 1
    failed = final_check()
    for f in failed:
        say(f"FINAL\tFAIL\t{f}")
    say("RESULT\tPASS" if not failed else "RESULT\tFAIL")
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
