r"""The ONE cleanup of a Windows run folder after a WebView2 run (NavyCanyon 6dd7fda), shared by the WS2a session
path (tests/windows/spike_driver.py: zb\build\run-<sha>) and the m8 path (tests/windows/m8_live_test.py:
zb\runs\<id>).

WebView2's helper processes (msedgewebview2) outlive the program that started them by seconds and hold files in
its user-data folder, which sits inside the run folder; deleting at once leaves files behind (WS2a.3a red
2264489). So:
  * census(run, timeout) reads the stable identities (name, pid, start ticks) of every process that can hold a run
    folder: msedgewebview2, zigBrowser and the ws<N>... slice executables. A failed, timed-out or raising probe, an
    unparsable answer, or a start time that cannot be read (`na`) raises CensusError (fail closed).
  * remove_after_webview2(run, win_dir, before) waits, within ONE monotonic total deadline of at most 60 s, until
    the census equals the `before` census taken before the run; every census gets only the REMAINING part of that
    deadline as its probe timeout, so a slow or stalled probe cannot outlast it; it never kills anything. Only then, if the folder
    is a plain directory (not a reparse point), it calls ordinary `rmdir /s /q` exactly once and checks both the
    command status and the folder's absence. Any probe, parse, timeout, reparse or deletion failure returns
    (False, why) and deletes nothing more; there is no retry.

`run(command)` sends one command to the Windows account's shell (cmd.exe) and returns an object with
`returncode`, `stdout` and `stderr` (subprocess.CompletedProcess); `run(command, timeout=seconds)` must bound it (the
callers' ssh runners raise subprocess.TimeoutExpired). Only the two caller run-folder shapes are accepted, exactly:
%USERPROFILE%\zb\build\run-<40 hex> (spike_driver) and %USERPROFILE%\zb\runs\m8-<pid>-<12 hex> (m8_live_test).
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
_LINE = re.compile(r"^([A-Za-z0-9-]+)\t([0-9]+)\t([0-9]+)$")  # name, pid, start ticks (a readable start time only)
_DIR = re.compile(r"^%USERPROFILE%\\zb\\(build\\run-[0-9a-f]{40}|runs\\m8-[0-9]+-[0-9a-f]{12})$")


class CensusError(Exception):
    pass


def census(run, timeout=None):
    """The set of (name, pid, start ticks) identities of the processes that can hold a run folder."""
    try:
        r = run(CENSUS_CMD) if timeout is None else run(CENSUS_CMD, timeout=timeout)
    except Exception as e:  # subprocess.TimeoutExpired, OSError, ...: the probe itself failed
        raise CensusError(f"probe failed: {type(e).__name__}: {e}") from e
    if r.returncode != 0:
        raise CensusError(f"probe rc={r.returncode}: {r.stderr.strip()[:300]}")
    lines = [l.strip() for l in r.stdout.replace("\r", "").split("\n") if l.strip()]
    if not lines or lines[-1] != "END":
        raise CensusError(f"no END line (truncated answer): {r.stdout[-300:]!r}")
    found = set()
    for line in lines[:-1]:
        m = _LINE.match(line)
        if not m or not re.match(_NAMES, m.group(1)):
            raise CensusError(f"unparsable census line (or unreadable start time) {line!r}")
        found.add((m.group(1), int(m.group(2)), m.group(3)))
    return frozenset(found)


def _ps_path(win_dir):
    return "(Join-Path $env:USERPROFILE '" + win_dir[len("%USERPROFILE%\\"):] + "')"


def _kind_cmd(win_dir):
    p = _ps_path(win_dir)
    return ('powershell -NoProfile -NonInteractive -Command "'
            f"$i = Get-Item -LiteralPath {p} -Force -ErrorAction SilentlyContinue; "
            "if ($null -eq $i) { 'ABSENT' } "
            "elseif ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { 'REPARSE' } "
            "elseif ($i.PSIsContainer) { 'DIR' } else { 'FILE' }\"")


def remove_after_webview2(run, win_dir, before, deadline_s=DEADLINE_S, poll_s=POLL_S):
    """Wait (bounded, never kill) for the census to equal `before`, then delete `win_dir` once. -> (ok, why)."""
    if not _DIR.fullmatch(win_dir):
        return False, f"refused: {win_dir!r} is not a run folder under %USERPROFILE%\\zb"
    if not 0 < deadline_s <= DEADLINE_S:
        return False, f"refused: deadline {deadline_s}s is outside (0, {DEADLINE_S}]"
    start = time.monotonic()
    end = start + deadline_s
    def timed_out(last):
        return False, (f"census did not return to the pre-run identities within {deadline_s:g}s: "
                       f"survivors {sorted(last - before)}, missing {sorted(before - last)}; nothing deleted")

    last = None
    while True:
        remaining = end - time.monotonic()
        if remaining <= 0:
            return timed_out(last) if last is not None else (False, "no time left for a census; nothing deleted")
        try:
            now = census(run, timeout=remaining)
        except CensusError as e:
            return False, f"census failed: {e}; nothing deleted"
        if now == before:
            break
        last = now
        if time.monotonic() >= end:
            return timed_out(now)
        time.sleep(max(0.0, min(poll_s, end - time.monotonic())))
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
