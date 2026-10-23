r"""The ONE cleanup of a Windows run folder after a WebView2 run (NavyCanyon 6dd7fda), shared by the WS2a session
path (tests/windows/spike_driver.py: zb\build\run-<sha>) and the m8 path (tests/windows/m8_live_test.py:
zb\runs\<id>).

WebView2's helper processes (msedgewebview2) outlive the program that started them by seconds and hold files in
its user-data folder, which sits inside the run folder; deleting at once leaves files behind (WS2a.3a red
2264489). So:
  * census(run) reads the stable identities (name, pid, start time) of every process that can hold a run folder:
    msedgewebview2, zigBrowser and the ws<N>... slice executables. A failed probe or an unparsable answer raises
    CensusError (fail closed).
  * remove_after_webview2(run, win_dir, before) waits, within ONE monotonic total deadline of at most 60 s, until
    the census equals the `before` census taken before the run; it never kills anything. Only then, if the folder
    is a plain directory (not a reparse point), it calls ordinary `rmdir /s /q` exactly once and checks both the
    command status and the folder's absence. Any probe, parse, timeout, reparse or deletion failure returns
    (False, why) and deletes nothing more; there is no retry.

`run(command)` sends one command to the Windows account's shell (cmd.exe) and returns an object with
`returncode`, `stdout` and `stderr` (subprocess.CompletedProcess). Only paths under %USERPROFILE%\zb are accepted.
"""
import re
import time

DEADLINE_S = 60.0
POLL_S = 1.0

_NAMES = r"^(msedgewebview2|zigBrowser|ws[0-9][a-z0-9-]*)$"
CENSUS_CMD = (
    'powershell -NoProfile -NonInteractive -Command "'
    "Get-Process | Where-Object { $_.ProcessName -match '" + _NAMES + "' } | ForEach-Object { "
    "$_.ProcessName + [char]9 + $_.Id + [char]9 + $(try { $_.StartTime.ToUniversalTime().Ticks } catch { 'na' }) }; "
    "'END'\""
)
_LINE = re.compile(r"^([A-Za-z0-9-]+)\t([0-9]+)\t([0-9]+|na)$")
_DIR = re.compile(r"^(%USERPROFILE%|[A-Za-z]:\\Users\\[A-Za-z0-9._-]+)\\zb\\(build\\run-[0-9a-f]{40}|runs\\[A-Za-z0-9._-]+)$")


class CensusError(Exception):
    pass


def census(run):
    """The set of (name, pid, start) identities of the processes that can hold a run folder."""
    r = run(CENSUS_CMD)
    if r.returncode != 0:
        raise CensusError(f"probe rc={r.returncode}: {r.stderr.strip()[:300]}")
    lines = [l.strip() for l in r.stdout.replace("\r", "").split("\n") if l.strip()]
    if not lines or lines[-1] != "END":
        raise CensusError(f"no END line (truncated answer): {r.stdout[-300:]!r}")
    found = set()
    for line in lines[:-1]:
        m = _LINE.match(line)
        if not m or not re.match(_NAMES, m.group(1)):
            raise CensusError(f"unparsable census line {line!r}")
        found.add((m.group(1), int(m.group(2)), m.group(3)))
    return frozenset(found)


def _ps_path(win_dir):
    if win_dir.startswith("%USERPROFILE%\\"):
        return "(Join-Path $env:USERPROFILE '" + win_dir[len("%USERPROFILE%\\"):] + "')"
    return "'" + win_dir + "'"


def _kind_cmd(win_dir):
    p = _ps_path(win_dir)
    return ('powershell -NoProfile -NonInteractive -Command "'
            f"$i = Get-Item -LiteralPath {p} -Force -ErrorAction SilentlyContinue; "
            "if ($null -eq $i) { 'ABSENT' } "
            "elseif ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { 'REPARSE' } "
            "elseif ($i.PSIsContainer) { 'DIR' } else { 'FILE' }\"")


def remove_after_webview2(run, win_dir, before, deadline_s=DEADLINE_S, poll_s=POLL_S):
    """Wait (bounded, never kill) for the census to equal `before`, then delete `win_dir` once. -> (ok, why)."""
    if not _DIR.match(win_dir) or ".." in win_dir:
        return False, f"refused: {win_dir!r} is not a run folder under %USERPROFILE%\\zb"
    if not 0 < deadline_s <= DEADLINE_S:
        return False, f"refused: deadline {deadline_s}s is outside (0, {DEADLINE_S}]"
    start = time.monotonic()
    # RED (bd/6dd7fda): no wait for the census yet; the folder is deleted at once, as the callers did before.
    waited = time.monotonic() - start

    kind = run(_kind_cmd(win_dir))
    what = kind.stdout.replace("\r", "").strip()
    if kind.returncode != 0 or what not in ("ABSENT", "DIR"):
        return False, f"folder probe rc={kind.returncode} {what!r}: not deleted"
    if what == "ABSENT":
        return True, f"{win_dir} already absent after {waited:.1f}s; nothing to delete"
    rm = run(f'rmdir /s /q "{win_dir}"')
    gone = run(f'if exist "{win_dir}" (echo LEFT) else (echo GONE)')
    if rm.returncode != 0 or gone.returncode != 0 or gone.stdout.strip() != "GONE":
        return False, (f"rmdir of {win_dir} failed (rc={rm.returncode}; {gone.stdout.strip()!r}): "
                       f"{rm.stdout.strip()[:300]} {rm.stderr.strip()[:300]}; not retried")
    return True, f"removed {win_dir} after waiting {waited:.1f}s for the census"
