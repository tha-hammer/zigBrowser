r"""WS5 native Win32 drawer — live entry red on the Win11 VM (OD-W6: native Win32 controls).

UNREGISTERED (red-first; registered in the WS5 green). The portable drawer logic (`agent_drawer.zig`,
`zb_drawer_*`) is backend-agnostic and already exports for Windows; WS5's green is the Win32 BACKEND
(`src/agent_drawer_win.cpp`, mounted from `webview2_shim.cpp`) plus the shim functions
`zb_app_set_agent_drawer` / `zb_app_get_agent_drawer` / `zb_drawer_debug_live_count` (today DEFINED only by
the GTK backend `src/agent_drawer.c`, absent on Windows).

ENTRY RED (WS5.0/WS5.1), pinning the plan's authoritative red (plan: `DRAWER\topen` + the dock equation):
with `--agent-drawer on --e2e-protocol` the drawer mounts and, driven open by the e2e-only seam
`ZIGBROWSER_AGENT_DRAWER_OPEN=1` (a deterministic sibling of `ZIGBROWSER_AGENT_DRAWER_DEMO`, honoured only
under `--e2e-protocol`, so it never widens the page/socket surface WS5.6 forbids), emits the SAME DRAWER row
NAMES as the GTK backend (`src/agent_drawer.c`): a structural `tree` row, an `icon` rect row, and an `open`
panel rect. The test parses the protocol fields (it does NOT accept any `DRAWER\t<anything>` line — a
`DRAWER\tbogus` stub or a row-only stub that creates no Win32 control fails) and pins the **dock geometry**
in client coordinates: the panel is full-width, docked at the bottom, with a non-empty page region above it,
so `page_h + panel_h == client_h` (`panel.y > 0` and `panel.y + panel.h == client_h`). That kills both the
row-only-stub mutant and the panel-overlays-instead-of-docks mutant. Today the Windows backend emits NO
DRAWER rows, so the first assertion (the `tree` row) fails — the failing-first evidence that the drawer is
absent, not a link error in a registered step.

Lifecycle (RoseCat b2595b0 #2 / 29e8852): the runner creates the exe **SUSPENDED**, assigns it to a Job it
OWNS (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) with the assignment CHECKED, then RESUMES — so every descendant
(including `msedgewebview2.exe`) is born inside the job and cannot escape. Teardown terminates/closes the job,
killing the whole tree; **no pid-based kill is ever used** (no reused-pid hazard). Every Win32 API failure
throws and FAILS the test (fail-closed). The owned window is found by the launched **pid** (not a global
`FindWindow`); the census is the **Job's process-id list** (empty after teardown), not a machine-wide name
count; and the host window's **child controls** are counted independently (a row-only impl has none).

Scope (RoseCat b2595b0 #3 / OD-W4): the live drawer runs on the **win11 VM only**. The read-only Windows 10
file server cannot receive an exe (the no-write rule), so — exactly as WS2.0 did at rev 2.10 — the
physical-Win10 drawer leg is withdrawn, not silently skipped; and under the OD-W4 Win10 scope Win10 ships the
browser with the agent drawer in its agent-OFF state. A separate writable Win10 host the owner authorises
would run this same test with `ZB_WIN_HOST` pointed at it.

Run live:  ZB_WIN11_HOST=127.0.0.1 ZB_WIN_EXE=<built zigBrowser.exe> \
           python3 -I tests/windows/win_drawer_test.py -v
"""
import json
import os
import pathlib
import re
import secrets
import subprocess
import unittest

# A trivial local page; the drawer is independent of page content.
_HTML = "<!doctype html><html><head><meta charset=\"utf-8\"><title>drawer</title></head><body>d</body></html>\n"

_RECT = r"-?\d+,-?\d+,\d+,\d+"
# The subset of DRAWER row shapes this entry red pins (names identical to src/agent_drawer.c / agent_common).
_KINDS = {"icon": [_RECT], "open": [_RECT], "tree": [r"[A-Za-z0-9_]+(,[A-Za-z0-9_]+)*"]}

# The e2e seam modes. Both runner mode slots carry a NONEMPTY sentinel ("none" == off), so an empty fail slot
# can never be dropped in the ssh->PowerShell arg transit and shift the force arg (the dbe6382 live-run bug).
FAIL_MODES = ("", "panel", "icon", "bubble")
FORCE_MODES = ("", "assign_fail", "assign_firststop_fail", "cleanup_exhaust", "wait_fail")


def drawer_runner_args(base_win, fail_mode, force_mode):
    """The EXACT positional args to run.ps1 (RoseCat f7ff742): [base_win, fail_slot, force_slot] with a nonempty
    sentinel in BOTH mode slots ('none' for off). Always 3 elements — never a blank positional."""
    assert fail_mode in FAIL_MODES, f"unknown fail mode {fail_mode!r}"
    assert force_mode in FORCE_MODES, f"unknown force mode {force_mode!r}"
    return [base_win, fail_mode or "none", force_mode or "none"]


def decode_mode(arg, allowed):
    """Fail-closed mirror of the runner's decode: 'none' -> off (''); a value in `allowed` passes through;
    anything else (including a blank) raises. The _RUNNER performs the same decode in PowerShell."""
    if arg == "none":
        return ""
    if arg not in allowed:
        raise AssertionError(f"unknown/blank mode {arg!r} (allowed: {allowed})")
    return arg


def bounded_cleanup(now_fn, sleep_fn, deadline_s, step_fn, poll_s=1.0):
    """Retry `step_fn(budget)` until it reports success (True) or ONE absolute monotonic deadline passes
    (RoseCat dfaf431). `budget` is the remaining seconds, so the caller caps each remote op to it — a stalled
    connection can never renew the budget. Returns True iff `step_fn` succeeded before the deadline; a
    never-succeeding step fails PROMPTLY at the deadline, not after hours. Injectable clock/step for offline
    coverage."""
    end = now_fn() + deadline_s
    while True:
        budget = end - now_fn()
        if budget <= 0:
            return False
        if step_fn(budget):
            return True
        if end - now_fn() <= 0:
            return False
        sleep_fn(min(poll_s, max(0.0, end - now_fn())))


def job_count_settled(now_fn, sleep_fn, count_fn, deadline_s, poll_s=0.1):
    """Bounded, FAIL-CLOSED settled read of the owned-Job member count after teardown (RoseCat / orchestrator
    option a). The real `job_count_after` live run showed a just-TerminateProcess'd suspended child still
    enumerated by a single instant read (TerminateProcess is async; the object lingers in the job list a moment
    before it is reaped). A single instant read therefore both (1) spuriously FAILS on that transient, and (2)
    can spuriously PASS a member that is not enumerated yet at the instant but appears/persists just after.

    This polls `count_fn` across the WHOLE window and returns the count at the final poll (the settled reading):
      - a transient member that LEAVES within the window settles to 0 and passes;
      - a member that PERSISTS, or APPEARS during the window and stays, is still counted at the deadline, so the
        caller's `== 0` check FAILS — fail closed. A count still above 0 at the deadline is a FAIL.
    Injectable clock/sleep/count for offline coverage."""
    end = now_fn() + deadline_s
    last = count_fn()
    while now_fn() < end:
        sleep_fn(min(poll_s, max(0.0, end - now_fn())))
        last = count_fn()
    return last


def parse_drawer(line):
    """`DRAWER\\t<win>\\t<kind>\\t...` -> (win, kind, fields) with field validation, or None."""
    parts = line.rstrip("\r\n").split("\t")
    if len(parts) < 3 or parts[0] != "DRAWER" or not re.fullmatch(r"[1-9]\d*", parts[1]):
        return None
    kind = parts[2]
    shape = _KINDS.get(kind)
    if shape is None:
        return None  # a row this red does not pin (or a bogus kind) is ignored, never a pass
    fields = parts[3:]
    if len(fields) != len(shape) or not all(re.fullmatch(p, f) for p, f in zip(shape, fields)):
        return None
    return int(parts[1]), kind, tuple(fields)


def rect_of(fields, i=0):
    x, y, w, h = (int(v) for v in fields[i].split(","))
    return x, y, w, h


# The WebView2 page widget class. The page is selected ONLY by class + owning pid, never by size (RoseCat
# f877bc5): a larger unrelated direct child must not be mistaken for the page.
PAGE_WIDGET_CLASS = "Chrome_WidgetWin_0"


def select_page_child(children, launched_pid):
    """Pure model of [Z]::PageHwnd (RoseCat f877bc5). `children` is the host's DIRECT children, each a dict with
    at least {"hwnd", "cls", "pid"}. Return the UNIQUE direct child whose class is the WebView2 widget class AND
    whose owning pid equals the launched pid, else None. Selection is by class + pid ONLY — NOT by size, and with
    NO visibility gate (the WebView2 widget is not WS_VISIBLE headless; real page presentation is proven on the
    owner's real screen). Absent, duplicate, or wrong-pid => None, so the caller fails closed."""
    matches = [c for c in children
               if c.get("cls") == PAGE_WIDGET_CLASS and int(c.get("pid", 0)) == int(launched_pid)]
    return matches[0]["hwnd"] if len(matches) == 1 else None


def extract_csharp_method(src, name):
    """Extract the body (the text between the method's outermost braces) of a `public static <type> <name>(...)`
    method from the embedded C# source, by brace matching. Lets the offline oracle pin the ACTUAL embedded
    selector the Win11 run executes — not just the detached Python model. Raises AssertionError if not found."""
    m = re.search(r"public static [\w\.]+ " + re.escape(name) + r"\s*\([^)]*\)\s*\{", src)
    assert m is not None, f"method {name} not found in the embedded C# source"
    start = m.end() - 1  # index of the opening brace
    depth = 0
    for j in range(start, len(src)):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[start + 1:j]
    raise AssertionError(f"unbalanced braces extracting {name}")


def page_selector_body_is_strict(body):
    """Causal predicate on the embedded [Z]::PageHwnd body (RoseCat ba35dc5). The selector is strict iff it
    selects by the WebView2 widget CLASS, by the launched PID, requires EXACTLY ONE match, and uses NEITHER a
    size/area heuristic NOR a visibility gate. Reverting to the old largest-visible-child body, dropping the pid
    term, or returning the first match instead of the unique one each flips this to False."""
    norm = " ".join(body.split())  # collapse whitespace so token checks are layout-independent
    has_class = '"Chrome_WidgetWin_0"' in norm         # selects by the widget class
    has_pid = "== Pid" in norm                          # ... AND the launched pid
    has_exactly_one = "n == 1" in norm                  # ... AND exactly one match (not first/largest)
    no_visibility_gate = "StyleVisible" not in norm     # no WS_VISIBLE gate (headless the page is not visible)
    no_size_heuristic = "GetWindowRect" not in norm and "best" not in norm  # no largest-child area pick
    return has_class and has_pid and has_exactly_one and no_visibility_gate and no_size_heuristic


def check_success(r):
    """The discriminating oracle for a SUCCESSFUL drawer run. Raises AssertionError on any violation. Pure
    (takes the runner's JSON result dict), so it is exercised offline with injected results in WinDrawerOracle
    AND on the live result in WinDrawerLive (RoseCat 29e8852)."""
    assert r.get("error", "") == "", f"runner reported a Win32 failure: {r.get('error')!r}"
    assert not r["timed_out"], f"runner timed out waiting for the drawer rows\nstdout={r['stdout']!r}\nstderr={r['stderr']!r}"
    assert r["terminated"], "the owned Job teardown did not reach WAIT_OBJECT_0 on the browser"
    # Owned-tree census: the Job's process-id list (not a machine-wide name count) is empty after teardown.
    assert r["job_count_after"] == 0, f"the owned Job still had processes after teardown (job_count_after={r['job_count_after']})"
    assert r["job_count_before"] >= 1, f"the Job owned no process while running (job_count_before={r['job_count_before']})"
    # The window is OUR process's, found by pid (not a global FindWindow).
    assert r["window_found"], "no zigBrowserWebView2Host window owned by the launched pid was found"
    # Exact DIRECT STATIC children: the drawer panel ("" text) + the "S" icon, and nothing else. A row-only /
    # null-control implementation (or EnumChildWindows counting WebView2's own HWNDs) does not pass.
    statics = [s for s in (r.get("controls") or "").split("|") if s]
    texts = sorted(s[len("STATIC:"):] for s in statics if s.startswith("STATIC:"))
    # The drawer's DIRECT STATIC host children: the panel ("" text), the "S" icon, and the "-" minimize control
    # (WS5.3). The bubble is a RichEdit child of the PANEL, not a direct host STATIC, so it is not listed here.
    assert texts == ["", "-", "S"], f"host window must have exactly the panel, 'S' icon and '-' control as direct STATIC children; got {statics!r}"
    rows = [row for row in (parse_drawer(ln) for ln in r["stdout"].splitlines()) if row]
    wins = {win for win, _, _ in rows}
    assert len(wins) == 1, f"all DRAWER rows must share one window id; got {sorted(wins)}"
    by_kind = {}
    for win, kind, fields in rows:
        by_kind.setdefault(kind, []).append(fields)
    for k in ("tree", "icon", "open"):
        assert k in by_kind, f"missing DRAWER `{k}` row (the native drawer backend must emit it); rows={r['stdout']!r}"
    px, py, pw, ph = rect_of(by_kind["open"][0])
    assert r["client_h"] > 0, "could not read the client rect (GetClientRect)"
    assert pw == r["client_w"], f"the panel must be full client width ({pw} != {r['client_w']})"
    assert py > 0, f"the panel must dock below a non-empty page region, not overlay (py={py})"
    assert py + ph == r["client_h"], f"page_h + panel_h must equal client_h ({py} + {ph} != {r['client_h']})"
    # ---- INDEPENDENT pid-bound real-HWND checks (RoseCat 1e5ff2d closure #2): never trust the `open` row alone ----
    # The HWND tree was found by the launched pid; require the observed owner pid to match, so a wrong-pid window
    # cannot stand in.
    assert r.get("pid") and int(r.get("hwnd_pid", 0)) == int(r["pid"]), \
        f"the drawer HWND tree must belong to the launched pid ({r.get('hwnd_pid')} != {r.get('pid')})"
    # The child was BORN suspended INTO the owned kill-on-close Job (not started then assigned) — no pre-Job window.
    assert r.get("born_in_job") is True, "the browser must be born suspended into the owned Job (not start-before-Job)"
    # Exactly one read-only (plain-text) RichEdit bubble UNDER the panel — the conversation surface.
    assert r.get("bubble_present") is True, "the panel must host exactly one read-only RichEdit bubble"
    # The emitted `open` rect must EQUAL the independently observed panel HWND rect (row-vs-HWND agreement).
    assert r.get("panel_rect"), "no panel HWND rect was measured (empty panel_rect)"
    panx, pany, panw, panh = rect_of([r.get("panel_rect", "")])
    assert (panx, pany, panw, panh) == (px, py, pw, ph), \
        f"emitted open rect {(px,py,pw,ph)} != observed panel HWND rect {(panx,pany,panw,panh)}"
    # The page HWND fills the client ABOVE the panel: top-left, full width, nonempty, bottom == panel top (the
    # page is docked beside the panel, not left behind/under it).
    assert r.get("page_rect"), "no page (WebView2) HWND rect was measured (empty page_rect)"
    pgx, pgy, pgw, pgh = rect_of([r.get("page_rect", "")])
    assert pgx == 0 and pgy == 0, f"the page must sit at the client top-left; got {(pgx, pgy)}"
    assert pgw == r["client_w"], f"the page must be full client width ({pgw} != {r['client_w']})"
    assert pgh > 0, "the page region above the panel must be nonempty"
    assert pgy + pgh == pany, f"the page bottom ({pgy + pgh}) must meet the panel top ({pany}) — page not behind the panel"
    # Each selected child HWND must belong to the launched pid and be visible; the bubble must be plain-text, not
    # just ES_READONLY (RoseCat 7868 #3) — so a stray/stale/hidden child or a rich-text bubble cannot stand in.
    for who, key in (("panel", "panel_pid"), ("page", "page_pid"), ("bubble", "bubble_pid")):
        assert int(r.get(key, 0)) == int(r["pid"]), \
            f"the {who} HWND must belong to the launched pid ({r.get(key)} != {r['pid']})"
    assert r.get("bubble_plaintext") is True, "the bubble must be in RichEdit PLAIN-TEXT mode (TM_PLAINTEXT)"
    # OPEN-state native visibility (RoseCat ba35dc5 gap 2): the mount settles on the `open` row, so the drawer is
    # OPEN. Each control is read and asserted INDEPENDENTLY (its own WS_VISIBLE style), so a hidden panel, a
    # hidden bubble, a hidden "-" control, or a still-visible "S" icon each fails on its own row. This matches the
    # shim's resize_controller (panel/min/bubble SW_SHOW, icon SW_HIDE while open). The fold terminal state has
    # the mirror visibility and is checked by the WS5.3 fold oracle, not here; the PAGE's real presentation
    # (rendered pixels, not the WebView2 child's WS_VISIBLE bit) is verified in the owner real-screen check.
    assert r.get("panel_visible") is True, "the docked panel must be visible on the open drawer"
    assert r.get("bubble_visible") is True, "the RichEdit bubble must be visible on the open drawer"
    assert int(r.get("minimize_visible", -1)) == 1, \
        f"the '-' minimize control must be VISIBLE on the open drawer (minimize_visible={r.get('minimize_visible')})"
    assert int(r.get("icon_visible", -1)) == 0, \
        f"the 'S' icon must be HIDDEN while the drawer is open (icon_visible={r.get('icon_visible')})"


def check_mounted_fail(r, which):
    """The oracle for a FORCED control-create failure (`which` in {panel, icon}, RoseCat 7646): the browser
    still runs and tears down cleanly, but NO drawer mounts — no DRAWER rows, no drawer controls — and the
    exact failure diagnostic is emitted. Pure; raises AssertionError on any violation."""
    assert r.get("error", "") == "", f"the browser itself must run (a forced drawer-control failure is a drawer branch, not a runner Win32 error): {r.get('error')!r}"
    assert r["terminated"], "teardown must reach WAIT_OBJECT_0 even when the drawer did not mount"
    assert r["job_count_after"] == 0, f"the owned Job must be empty after teardown (got {r['job_count_after']})"
    rows = [row for row in (parse_drawer(ln) for ln in r["stdout"].splitlines()) if row]
    assert rows == [], f"a forced-{which}-fail mount must emit NO DRAWER rows; got {rows}"
    # NO direct drawer controls at all: not the panel ("STATIC:" empty text), the "S" icon ("STATIC:S"), or the
    # "-" minimize control ("STATIC:-", WS5.3). For a later-control failure this causally proves every control
    # created before it was DESTROYED — a leaked (not-destroyed, or failed-DestroyWindow) control shows up here
    # and must fail (RoseCat 7677 / 6774439).
    statics = [s for s in (r.get("controls") or "").split("|") if s]
    drawer_controls = [s for s in statics if s in ("STATIC:", "STATIC:S", "STATIC:-")]
    assert drawer_controls == [], f"a forced-{which}-fail mount must leave NO drawer controls (panel/icon/min); got {statics!r}"
    # The EXACT complete diagnostic (deterministic forced error 87 + "; drawer not mounted"), as a full line,
    # NOT a truncated substring (RoseCat 7677).
    expected = f"zigBrowser: agent-drawer {which} control failed (error 87); drawer not mounted"
    lines = [ln.rstrip("\r") for ln in (r.get("stderr") or "").splitlines()]
    assert expected in lines, f"the exact {which}-failure diagnostic (forced error 87) must be emitted; got {r.get('stderr')!r}"


def check_assign_fail(r):
    """Forced AssignProcessToJobObject failure (RoseCat fd17cba/7662, 7670 #1): the suspended process is
    outside the job, so the bounded cleanup route must terminate it by its HELD handle and PROVE it gone —
    never a pid/name kill, no orphan, and no owned job members left behind."""
    assert r.get("launch_failed"), f"a forced assign failure must report launch_failed; got {r!r}"
    assert r.get("proc_gone"), "the held (unassigned, suspended) process must be proven terminated (proc_gone)"
    assert r.get("job_count_after") == 0, f"no owned job members may survive (got {r.get('job_count_after')})"
    assert "AssignProcessToJobObject" in (r.get("error") or ""), f"the assign-failure error must be surfaced; got {r.get('error')!r}"
    rows = [row for row in (parse_drawer(ln) for ln in r.get("stdout", "").splitlines()) if row]
    assert rows == [], f"a process killed before resume must emit NO DRAWER rows; got {rows}"


def check_assign_firststop_fail(r):
    """Combined forced mode (RoseCat a94db57 #1 / c943215): membership verification fails AND the FIRST stop
    proof fails on the still-suspended child. Teardown is skipped (launch_failed), so the first stop cannot be
    supplied by Teardown. Because the child was BORN INTO the kill-on-close job, closing the job is the durable
    backstop: the post-close wait proves the child terminal even though the first held-handle stop failed."""
    assert r.get("launch_failed"), "the child must never have resumed (pre-resume path), so Teardown is skipped"
    assert "AssignProcessToJobObject" in (r.get("error") or ""), f"the membership failure must be surfaced; got {r.get('error')!r}"
    assert r.get("first_stop_failed"), "the first stop proof must actually have failed on the live suspended child"
    assert r.get("proc_gone"), "the born-in-job backstop (job close + post-close wait) must prove the child gone"
    rows = [row for row in (parse_drawer(ln) for ln in r.get("stdout", "").splitlines()) if row]
    assert rows == [], f"a process killed before resume must emit NO DRAWER rows; got {rows}"


def check_cleanup_exhaustion(r):
    """Forced cleanup-exhaustion (RoseCat c943215): EVERY TerminateProcess-based reap attempt fails, yet because
    the child was BORN INTO the kill-on-close job, the job-close backstop + the durable post-close wait still
    prove it terminal — the child can never outlive the runner. Proves the exhausted held-handle reap is backed
    by durable OS ownership, not a retained handle closed at script exit."""
    assert r.get("launch_failed"), "the pre-resume path (Teardown skipped) isolates the cleanup route"
    assert r.get("cleanup_exhausted"), "the held-handle reap must actually have been exhausted (seam fired)"
    assert r.get("proc_gone"), "the born-in-job backstop must still prove the child terminal despite exhaustion"


def check_wait_fail(r):
    """Forced teardown WaitForSingleObject != WAIT_OBJECT_0 (RoseCat fd17cba/7662 #2, 7670 #2): the first-wait
    failure must be a test FAILURE (never a silent bounded success), AND the distinct bounded cleanup route must
    prove the process + job tree are gone before that failure is reported."""
    assert not r.get("terminated"), "a non-WAIT_OBJECT_0 teardown must NOT count as terminated"
    assert "WAIT_OBJECT_0" in (r.get("error") or ""), f"the first-wait failure must be surfaced as an error; got {r.get('error')!r}"
    assert r.get("proc_gone"), "the distinct bounded cleanup route must prove the process terminal (proc_gone)"
    assert r.get("job_count_after") == 0, f"the job tree must be proven gone (job_count_after={r.get('job_count_after')})"


# VM-side runner (RoseCat 29e8852): create the browser SUSPENDED, assign it to a Job we OWN
# (KILL_ON_JOB_CLOSE) and CHECK the assignment, then resume — so every descendant (incl. msedgewebview2.exe)
# is born inside the job and cannot escape. Teardown closes/terminates the job, which kills the whole tree;
# NO pid-based kill is ever used (no reused-pid hazard). Every Win32 API failure throws -> the test fails
# (fail-closed). The owned window is found by OUR pid (not a global FindWindow), and the Job's process-id
# list is the census (not a machine-wide name count).
_RUNNER = r"""
$ErrorActionPreference='Stop'
# Exactly 3 args; both mode slots carry a nonempty sentinel ('none' == off). Fail-closed enum decode so a
# dropped/blank slot or an unknown value aborts rather than silently shifting a seam (RoseCat f7ff742).
if ($args.Count -ne 3) { throw "runner expected exactly 3 args (dir, failSlot, forceSlot), got $($args.Count): $($args -join '|')" }
$dir = $args[0]
function Decode-Mode($v, $allowed) {
  if ($v -eq 'none') { return '' }
  if ($allowed -notcontains $v) { throw "unknown/blank seam mode '$v' (allowed: none, $($allowed -join ', '))" }
  return $v
}
$failMode = Decode-Mode $args[1] @('panel','icon','bubble')
$forceMode = Decode-Mode $args[2] @('assign_fail','assign_firststop_fail','cleanup_exhaust','wait_fail')
if ($forceMode) { $env:ZB_E2E_DRAWER_FORCE = $forceMode }  # read by [Z]::ForceFail at first use
$exe = Join-Path $dir 'zigBrowser.exe'
$out = Join-Path $dir 'o.txt'; $err = Join-Path $dir 'e.txt'; $nul = 'NUL'
Remove-Item $out,$err -ErrorAction SilentlyContinue
$url = 'file:///' + ((Join-Path $dir 'test.html') -replace '\\','/')

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class Z {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct STARTUPINFO { public int cb; public string lpReserved, lpDesktop, lpTitle;
    public int dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct STARTUPINFOEX { public STARTUPINFO si; public IntPtr lpAttributeList; }
  [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }
  [StructLayout(LayoutKind.Sequential)] struct SECURITY_ATTRIBUTES { public int nLength; public IntPtr lpSD; public int bInherit; }
  [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_BASIC_LIMIT_INFORMATION { public long per; public long job; public uint flags; public UIntPtr minws; public UIntPtr maxws; public UIntPtr pa; public UIntPtr count; public long sched; }
  [StructLayout(LayoutKind.Sequential)] struct IO_COUNTERS { public ulong r,w,o,rb,wb,ob; }
  [StructLayout(LayoutKind.Sequential)] struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION { public JOBOBJECT_BASIC_LIMIT_INFORMATION basic; public IO_COUNTERS io; public UIntPtr pmem, jmem, ppmem, jpmem; }

  // CreateProcess taking the EXTENDED startup info (STARTUPINFOEX) so the child can be born INTO the job via a
  // PROC_THREAD_ATTRIBUTE_JOB_LIST attribute — durable OS ownership before the child's first instruction.
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern bool CreateProcess(string app, string cmd, ref SECURITY_ATTRIBUTES pa, ref SECURITY_ATTRIBUTES ta,
    bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32", SetLastError=true)]
  static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
  [DllImport("kernel32", SetLastError=true)]
  static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
  [DllImport("kernel32", SetLastError=true)]
  static extern bool DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr CreateFile(string name, uint access, uint share, ref SECURITY_ATTRIBUTES sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32", SetLastError=true)] static extern uint ResumeThread(IntPtr t);
  [DllImport("kernel32", SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a, string n);
  [DllImport("kernel32", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  [DllImport("kernel32", SetLastError=true)] static extern bool TerminateJobObject(IntPtr j, uint c);
  [DllImport("kernel32", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j, int cls, IntPtr info, uint len);
  [DllImport("kernel32", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr j, int cls, IntPtr info, uint len, IntPtr ret);
  [DllImport("kernel32", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32", SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32", SetLastError=true)] static extern bool TerminateProcess(IntPtr h, uint code);
  [DllImport("kernel32", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32", SetLastError=true)] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32")] static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32", SetLastError=true)] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32", SetLastError=true)] static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32")] static extern bool IsWindowVisible(IntPtr h);
  // WS_VISIBLE STYLE bit (GWL_STYLE=-16, WS_VISIBLE=0x10000000): proves ShowWindow(SW_SHOW) was called on THIS
  // window, independent of the ancestor chain / interactive desktop. IsWindowVisible walks ancestors, so it is
  // ALWAYS false in the non-interactive sshd session (the host top-level is never WS_VISIBLE there); the style
  // bit is the headless-correct "is this control shown" signal and still catches a never-shown child.
  static bool StyleVisible(IntPtr h) { return (GetWindowLongW(h, -16) & 0x10000000) != 0; }
  [DllImport("user32", SetLastError=true)] static extern IntPtr SendMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);

  const uint CREATE_SUSPENDED = 0x4, GENERIC_WRITE = 0x40000000, FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, CREATE_ALWAYS = 2;
  const uint KILL_ON_CLOSE = 0x2000, GENERIC_READ = 0x80000000, OPEN_EXISTING = 3, STARTF_USESTDHANDLES = 0x100;
  const uint GW_CHILD = 5, GW_HWNDNEXT = 2, WAIT_OBJECT_0 = 0, STILL_ACTIVE = 259;
  const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
  static readonly IntPtr PROC_THREAD_ATTRIBUTE_JOB_LIST = (IntPtr)0x0002000D;
  // e2e-only forced-failure seam for the OFFLINE/LIVE failure-branch proofs (inert unless set).
  public static string ForceFail = Environment.GetEnvironmentVariable("ZB_E2E_DRAWER_FORCE");
  static void Fail(string op) { throw new Exception(op + " failed: " + Marshal.GetLastWin32Error()); }
  static IntPtr OpenWrite(string path) {
    var sa = new SECURITY_ATTRIBUTES(); sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)); sa.bInherit = 1;
    IntPtr h = CreateFile(path, GENERIC_WRITE, FILE_SHARE_READ|FILE_SHARE_WRITE, ref sa, CREATE_ALWAYS, 0, IntPtr.Zero);
    if (h == new IntPtr(-1)) Fail("CreateFile " + path); return h;
  }
  static IntPtr OpenNul() {
    var sa = new SECURITY_ATTRIBUTES(); sa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)); sa.bInherit = 1;
    IntPtr h = CreateFile("NUL", GENERIC_READ, FILE_SHARE_READ|FILE_SHARE_WRITE, ref sa, OPEN_EXISTING, 0, IntPtr.Zero);
    if (h == new IntPtr(-1)) Fail("CreateFile NUL"); return h;
  }
  public static IntPtr Job; static IntPtr _hProc, _hThread; public static int Pid; public static bool ProcGone;
  public static bool FirstStopFailed; public static bool CleanupExhausted; static int _proveCalls;
  // ONE TerminateProcess-based attempt to prove the held process terminal (proof = wait + exit-code;
  // TerminateProcess is only the action). Does NOT close any handle. The e2e `assign_firststop_fail` seam fails
  // ONLY the first attempt; `cleanup_exhaust` fails EVERY attempt. Either way the child was born INTO the
  // kill-on-close job, so the durable backstop (job close + the post-close wait in FinalReap) still proves it.
  static bool ProveTerminal(uint waitMs) {
    if (_hProc == IntPtr.Zero) return true;
    _proveCalls++;
    if ((ForceFail == "assign_firststop_fail" && _proveCalls == 1) || ForceFail == "cleanup_exhaust") {
      FirstStopFailed = true; return false;
    }
    TerminateProcess(_hProc, 1);                       // best-effort action
    uint w = WaitForSingleObject(_hProc, waitMs);
    uint code = STILL_ACTIVE; bool got = GetExitCodeProcess(_hProc, out code);
    return (w == WAIT_OBJECT_0) && got && (code != STILL_ACTIVE);  // proof: signaled + a real exit code
  }
  // First stop attempt for the pre-resume recovery paths. Sets ProcGone; NEVER closes/discards the handle.
  static bool KillHeld() { ProcGone = ProveTerminal(8000); return ProcGone; }
  // The definitive cleanup, run AFTER CloseJob (RoseCat c943215). The child was born into the kill-on-close
  // job, so closing the job has asked the OS to kill it. Try the bounded TerminateProcess-based proofs; if they
  // are exhausted (seam or genuine), fall back to the DURABLE proof: a direct wait on the still-held process
  // handle, which the job-close kill signals. The child therefore cannot outlive the runner — the OS job owns
  // it, not a retained handle. Handles are closed only when terminal is PROVEN.
  public static bool FinalReap() {
    if (_hProc == IntPtr.Zero) { ProcGone = true; return true; }
    for (int i = 0; !ProcGone && i < 3; i++) ProcGone = ProveTerminal(8000);
    if (!ProcGone) {
      CleanupExhausted = true;  // the TerminateProcess-based reap was exhausted; the job-close backstop stands
      uint w = WaitForSingleObject(_hProc, 8000);
      uint code = STILL_ACTIVE; bool got = GetExitCodeProcess(_hProc, out code);
      ProcGone = (w == WAIT_OBJECT_0) && got && (code != STILL_ACTIVE);  // durable proof via the job-close kill
    }
    if (ProcGone) {
      bool okT = _hThread == IntPtr.Zero || CloseHandle(_hThread);
      bool okP = CloseHandle(_hProc);
      _hThread = IntPtr.Zero; _hProc = IntPtr.Zero;
      if (!okT || !okP) Fail("CloseHandle(held)");
    }
    return ProcGone;
  }
  // Create the kill-on-close job, then create the child SUSPENDED and BORN INTO that job (STARTUPINFOEX +
  // PROC_THREAD_ATTRIBUTE_JOB_LIST) so the OS owns it durably before its first instruction, then resume. Durable
  // ownership means closing the job ALWAYS kills the child; no path can leave it outside the job (RoseCat
  // c943215). Any failure throws after a best-effort held stop; the finally's CloseJob + FinalReap guarantee it.
  public static void LaunchOwned(string exe, string cmdline, string cwd, string outPath, string errPath) {
    Job = CreateJobObject(IntPtr.Zero, null); if (Job == IntPtr.Zero) Fail("CreateJobObject");
    var eli = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION(); eli.basic.flags = KILL_ON_CLOSE;
    int sz = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)); IntPtr pe = Marshal.AllocHGlobal(sz);
    try { Marshal.StructureToPtr(eli, pe, false);
      if (!SetInformationJobObject(Job, 9, pe, (uint)sz)) Fail("SetInformationJobObject"); }
    finally { Marshal.FreeHGlobal(pe); }
    IntPtr hOut = OpenWrite(outPath), hErr = OpenWrite(errPath), hIn = OpenNul();
    IntPtr alSize = IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref alSize);
    IntPtr attrList = Marshal.AllocHGlobal(alSize);
    IntPtr jobArr = Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobArr, Job);
    var six = new STARTUPINFOEX();
    six.si.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
    six.si.dwFlags = (int)STARTF_USESTDHANDLES; six.si.hStdInput = hIn; six.si.hStdOutput = hOut; six.si.hStdError = hErr;
    var pa = new SECURITY_ATTRIBUTES(); pa.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
    var ta = new SECURITY_ATTRIBUTES(); ta.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
    PROCESS_INFORMATION pi = new PROCESS_INFORMATION(); bool ok = false;
    try {
      if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref alSize)) Fail("InitializeProcThreadAttributeList");
      if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, jobArr, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) Fail("UpdateProcThreadAttribute");
      six.lpAttributeList = attrList;
      ok = CreateProcess(exe, cmdline, ref pa, ref ta, true, CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero, cwd, ref six, out pi);
      if (ok) { _hProc = pi.hProcess; _hThread = pi.hThread; Pid = pi.dwProcessId; }
    } finally {
      if (attrList != IntPtr.Zero) DeleteProcThreadAttributeList(attrList);
      Marshal.FreeHGlobal(attrList); Marshal.FreeHGlobal(jobArr);
    }
    bool cOut = CloseHandle(hOut), cErr = CloseHandle(hErr), cIn = CloseHandle(hIn);
    if (!ok) Fail("CreateProcess");
    if (!cOut || !cErr || !cIn) { KillHeld(); Fail("CloseHandle(std) (child born-in-job; gone=" + ProcGone + ")"); }
    // The child is already a durable member of the kill-on-close job. Verify membership (fail-closed). The e2e
    // `assign_fail`/`assign_firststop_fail` seams simulate that verification failing to drive the recovery path;
    // the born-in-job backstop still guarantees no orphan.
    bool member = (ForceFail == "assign_fail" || ForceFail == "assign_firststop_fail" || ForceFail == "cleanup_exhaust") ? false : (JobProcessCount() >= 1);
    if (!member) { KillHeld(); throw new Exception("AssignProcessToJobObject membership not verified (born-in-job backstop holds; held stop gone=" + ProcGone + ")"); }
    if (ResumeThread(pi.hThread) == 0xFFFFFFFF) { KillHeld(); Fail("ResumeThread (child born-in-job; gone=" + ProcGone + ")"); }
  }
  // Number of processes currently owned by the job (the owned-tree census; not a machine-wide name count).
  public static int JobProcessCount() {
    int sz = 8 + IntPtr.Size * 512; IntPtr buf = Marshal.AllocHGlobal(sz);
    try {
      if (!QueryInformationJobObject(Job, 3 /*BasicProcessIdList*/, buf, (uint)sz, IntPtr.Zero)) Fail("QueryInformationJobObject");
      return Marshal.ReadInt32(buf, 4); // NumberOfProcessIdsInList
    } finally { Marshal.FreeHGlobal(buf); }
  }
  // FAIL-CLOSED settled read of the owned-job count (orchestrator option a): poll JobProcessCount across the
  // WHOLE deadline window and return the count at the final poll. A just-TerminateProcess'd member that lingers
  // settles to 0 and passes; a member that persists OR appears during the window is still counted at the
  // deadline, so the caller's `== 0` check FAILS. Mirrors job_count_settled() (its offline model).
  public static int JobProcessCountSettled(int deadlineMs, int pollMs) {
    var sw = System.Diagnostics.Stopwatch.StartNew();
    int last = JobProcessCount();
    while (sw.ElapsedMilliseconds < deadlineMs) {
      System.Threading.Thread.Sleep(pollMs);
      last = JobProcessCount();
    }
    return last;
  }
  // Terminate the job and REQUIRE the held process to reach WAIT_OBJECT_0 on the FIRST wait. On a non-OBJECT_0
  // first wait (the `wait_fail` seam) a DISTINCT bounded cleanup route (FinalReap) first PROVES the process +
  // job tree are gone; only THEN is the intentionally-preserved first-wait failure reported (RoseCat 7670 #2).
  public static void Teardown() {
    if (Job != IntPtr.Zero) { if (!TerminateJobObject(Job, 1)) Fail("TerminateJobObject"); }
    uint wait;
    if (ForceFail == "wait_fail") wait = 258u;                               // forced WAIT_TIMEOUT (first wait)
    else if (_hProc != IntPtr.Zero) wait = WaitForSingleObject(_hProc, 8000);
    else wait = WAIT_OBJECT_0;
    if (wait != WAIT_OBJECT_0) {
      FinalReap();  // distinct bounded cleanup: prove the held process terminal (job already terminated above)
      throw new Exception("WaitForSingleObject on the browser did not signal WAIT_OBJECT_0: " + wait +
                          " (bounded cleanup proved gone=" + ProcGone + ", job_members=" + JobProcessCount() + ")");
    }
    ProcGone = true;  // the first wait proved terminal
  }
  // Close ONLY the Job handle (KILL_ON_CLOSE: this kills any STILL-ASSIGNED child). The held process/thread
  // handles are owned by FinalReap, which must run AFTER this so a Job-close kill is proven by a post-close wait
  // through the still-held process handle, and a never-assigned child (closing the empty Job cannot stop it) is
  // reaped by FinalReap's own TerminateProcess+wait (RoseCat a94db57 #2).
  public static void CloseJob() {
    if (Job != IntPtr.Zero) { if (!CloseHandle(Job)) Fail("CloseHandle(Job)"); Job = IntPtr.Zero; }
  }
  static IntPtr _found; static uint _pid; static string _cls; static readonly EnumProc _findCb = FindCb;
  static bool FindCb(IntPtr h, IntPtr l) { uint p; GetWindowThreadProcessId(h, out p);
    if (p == _pid) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); if (sb.ToString() == _cls) { _found = h; return false; } } return true; }
  public static IntPtr FindOwnedWindow(int pid, string cls) { _pid = (uint)pid; _cls = cls; _found = IntPtr.Zero; EnumWindows(_findCb, IntPtr.Zero); return _found; }
  // The DIRECT STATIC children of the host (GW_CHILD/GW_HWNDNEXT) — NOT EnumChildWindows (which also counts
  // WebView2's own HWND hierarchy). Returns "class:text" for each, so the oracle can require exactly the
  // drawer's panel ("" text) + "S" icon. A row-only impl has no such controls.
  public static string DirectStatics(IntPtr parent) {
    var parts = new System.Collections.Generic.List<string>();
    IntPtr c = GetWindow(parent, GW_CHILD);
    while (c != IntPtr.Zero) {
      var cls = new StringBuilder(64); GetClassName(c, cls, 64);
      if (string.Equals(cls.ToString(), "STATIC", StringComparison.OrdinalIgnoreCase)) { var t = new StringBuilder(64); GetWindowText(c, t, 64); parts.Add("STATIC:" + t.ToString()); }
      c = GetWindow(c, GW_HWNDNEXT);
    }
    return String.Join("|", parts.ToArray());
  }
  public static bool Client(IntPtr h, out int w, out int ht) { RECT r; bool ok = GetClientRect(h, out r); w = r.right-r.left; ht = r.bottom-r.top; return ok; }
  // The ACTUAL "S" icon child's rectangle in host-client coords (RoseCat 1cd82d8 #1): read the real HWND, not
  // an implementation-emitted row. Returns "" if the icon child is absent. Works even while the icon is hidden.
  public static string IconClientRect(IntPtr host) {
    IntPtr c = GetWindow(host, GW_CHILD);
    while (c != IntPtr.Zero) {
      var cls = new StringBuilder(64); GetClassName(c, cls, 64);
      if (string.Equals(cls.ToString(), "STATIC", StringComparison.OrdinalIgnoreCase)) {
        var t = new StringBuilder(64); GetWindowText(c, t, 64);
        if (t.ToString() == "S") {
          RECT r; if (!GetWindowRect(c, out r)) return "";
          POINT tl; tl.x = r.left; tl.y = r.top;
          if (!ScreenToClient(host, ref tl)) return "";
          return tl.x + "," + tl.y + "," + (r.right-r.left) + "," + (r.bottom-r.top);
        }
      }
      c = GetWindow(c, GW_HWNDNEXT);
    }
    return "";
  }
  // Visibility of the "S" icon child (1 visible, 0 hidden, -1 absent) — WS5.2 requires the icon be visible when
  // the drag observation is taken (RoseCat b1ea2ed #4).
  public static int IconVisible(IntPtr host) {
    IntPtr c = GetWindow(host, GW_CHILD);
    while (c != IntPtr.Zero) {
      var cls = new StringBuilder(64); GetClassName(c, cls, 64);
      if (string.Equals(cls.ToString(), "STATIC", StringComparison.OrdinalIgnoreCase)) {
        var t = new StringBuilder(64); GetWindowText(c, t, 64);
        if (t.ToString() == "S") { return StyleVisible(c) ? 1 : 0; }
      }
      c = GetWindow(c, GW_HWNDNEXT);
    }
    return -1;
  }
  // Visibility of the "-" minimize/fold control (1 visible, 0 hidden, -1 absent) — WS5.3 requires the "-" be
  // visible on the OPEN drawer (it is the only fold affordance while the panel is shown), the mirror of the
  // hidden "S" icon in that state (RoseCat ba35dc5 gap 2).
  public static int MinimizeVisible(IntPtr host) {
    IntPtr c = GetWindow(host, GW_CHILD);
    while (c != IntPtr.Zero) {
      var cls = new StringBuilder(64); GetClassName(c, cls, 64);
      if (string.Equals(cls.ToString(), "STATIC", StringComparison.OrdinalIgnoreCase)) {
        var t = new StringBuilder(64); GetWindowText(c, t, 64);
        if (t.ToString() == "-") { return StyleVisible(c) ? 1 : 0; }
      }
      c = GetWindow(c, GW_HWNDNEXT);
    }
    return -1;
  }
  // WS5.3 fold observations (RoseCat 02c39a4 #2): measure the REAL panel HWND, never an emitted row. The panel
  // is the direct STATIC child with empty text (the icon is "S", the minimize control is "-").
  static IntPtr PanelHwnd(IntPtr host) {
    IntPtr c = GetWindow(host, GW_CHILD);
    while (c != IntPtr.Zero) {
      var cls = new StringBuilder(64); GetClassName(c, cls, 64);
      if (string.Equals(cls.ToString(), "STATIC", StringComparison.OrdinalIgnoreCase)) { var t = new StringBuilder(64); GetWindowText(c, t, 64); if (t.ToString() == "") return c; }
      c = GetWindow(c, GW_HWNDNEXT);
    }
    return IntPtr.Zero;
  }
  // The panel's current width (px) while it is VISIBLE, else -1 — polled during the fold to catch an in-flight
  // frame (a width strictly between the open drawer and the icon). -1 once it is hidden (folded away).
  public static int PanelWidthVisible(IntPtr host) {
    IntPtr p = PanelHwnd(host);
    if (p == IntPtr.Zero || !StyleVisible(p)) return -1;
    RECT r; if (!GetWindowRect(p, out r)) return -1;
    return r.right - r.left;
  }
  // The panel visible at all (terminal check: a folded drawer's panel must be hidden).
  public static bool PanelVisible(IntPtr host) { IntPtr p = PanelHwnd(host); return p != IntPtr.Zero && StyleVisible(p); }
  // The page re-docked to the full client area after folding: the WebView2 visual (the SAME strict page child
  // PageHwnd selects) covers the whole client height again (not client_h - panel_h). True if its height reaches
  // the client bottom within a small tolerance. Uses PageHwnd for one consistent page identity (no visibility
  // gate; the WebView2 widget is not WS_VISIBLE headless).
  public static bool PageRedocked(IntPtr host) {
    RECT cr; if (!GetClientRect(host, out cr)) return false;
    int ch = cr.bottom - cr.top;
    IntPtr pg = PageHwnd(host); if (pg == IntPtr.Zero) return false;
    RECT r; if (!GetWindowRect(pg, out r)) return false;
    return (r.bottom - r.top) >= ch - 4;
  }
  // WS5.7: drive a real WM_DPICHANGED (0x02E0) to the host with a new per-monitor DPI (wparam = MAKEWPARAM(dpi,
  // dpi)); the drawer's handler adopts it and re-sizes the icon. lparam (the suggested RECT*) is unused by the
  // drawer, so IntPtr.Zero is fine. This drives the PRODUCTION handler, not a helper.
  public static void SendDpiChanged(IntPtr host, int dpi) {
    int w = (dpi & 0xFFFF) | ((dpi & 0xFFFF) << 16);
    SendMessageW(host, 0x02E0, (IntPtr)w, IntPtr.Zero);
  }
  // WS5.7 (RoseCat 00b69e5): send a real WM_NCHITTEST (0x0084) to the "S" icon at its own centre (screen coords
  // in lparam) and return the result code. Used to prove the unreadable-geometry branch REFUSES the hit with
  // HTNOWHERE (0), never HTTRANSPARENT (-1, which would forward the click to the page below).
  public static int IconHitTestAtCenter(IntPtr host) {
    IntPtr c = GetWindow(host, GW_CHILD);
    while (c != IntPtr.Zero) {
      var cls = new StringBuilder(64); GetClassName(c, cls, 64);
      if (string.Equals(cls.ToString(), "STATIC", StringComparison.OrdinalIgnoreCase)) {
        var t = new StringBuilder(64); GetWindowText(c, t, 64);
        if (t.ToString() == "S") {
          RECT r; if (!GetWindowRect(c, out r)) return -999;
          int x = (r.left + r.right) / 2, y = (r.top + r.bottom) / 2;
          IntPtr res = SendMessageW(c, 0x0084, IntPtr.Zero, (IntPtr)(((y & 0xFFFF) << 16) | (x & 0xFFFF)));
          return (int)res;
        }
      }
      c = GetWindow(c, GW_HWNDNEXT);
    }
    return -998;
  }
  // WS5 entry closure (RoseCat 1e5ff2d #2): INDEPENDENT pid-bound real-HWND reads — never trust the emitted row.
  [DllImport("user32", SetLastError=true)] static extern int GetWindowLongW(IntPtr h, int idx);
  [DllImport("kernel32", SetLastError=true)] static extern bool IsProcessInJob(IntPtr proc, IntPtr job, out bool result);
  // The panel HWND rect in host-client coords ("x,y,w,h"), "" if absent.
  public static string PanelClientRect(IntPtr host) {
    IntPtr p = PanelHwnd(host); if (p == IntPtr.Zero) return "";
    RECT r; if (!GetWindowRect(p, out r)) return "";
    POINT tl; tl.x = r.left; tl.y = r.top; if (!ScreenToClient(host, ref tl)) return "";
    return tl.x + "," + tl.y + "," + (r.right-r.left) + "," + (r.bottom-r.top);
  }
  // The WebView2 page: the UNIQUE direct child of the host whose class is the WebView2 widget class
  // (Chrome_WidgetWin_0) AND whose owning pid is the launched pid (RoseCat f877bc5). Selected by class + pid
  // ONLY — NOT the largest non-STATIC child, and NO visibility gate (real page presentation moves to the owner
  // real-screen check). Absent / duplicate / wrong-pid => IntPtr.Zero (the caller fails closed). Mirrors
  // select_page_child() offline; the embedded body is pinned by test_page_hwnd_embedded_selector_is_strict.
  public static IntPtr PageHwnd(IntPtr host) {
    IntPtr found = IntPtr.Zero; int n = 0;
    IntPtr c = GetWindow(host, GW_CHILD);
    while (c != IntPtr.Zero) {
      var cls = new StringBuilder(64); GetClassName(c, cls, 64);
      uint pid; GetWindowThreadProcessId(c, out pid);
      if (cls.ToString() == "Chrome_WidgetWin_0" && (int)pid == Pid) { found = c; n++; }
      c = GetWindow(c, GW_HWNDNEXT);
    }
    return n == 1 ? found : IntPtr.Zero;
  }
  public static string PageClientRect(IntPtr host) {
    IntPtr pg = PageHwnd(host); if (pg == IntPtr.Zero) return "";
    RECT br; if (!GetWindowRect(pg, out br)) return "";
    POINT tl; tl.x = br.left; tl.y = br.top; if (!ScreenToClient(host, ref tl)) return "";
    return tl.x + "," + tl.y + "," + (br.right-br.left) + "," + (br.bottom-br.top);
  }
  // The READ-ONLY RichEdit child UNDER the panel (the conversation surface); IntPtr.Zero if absent/not read-only.
  public static IntPtr BubbleHwnd(IntPtr host) {
    IntPtr p = PanelHwnd(host); if (p == IntPtr.Zero) return IntPtr.Zero;
    IntPtr found = IntPtr.Zero; int n = 0;
    IntPtr c = GetWindow(p, GW_CHILD);
    while (c != IntPtr.Zero) {
      var cls = new StringBuilder(64); GetClassName(c, cls, 64);
      if (cls.ToString().IndexOf("RICHEDIT", StringComparison.OrdinalIgnoreCase) >= 0
          && (GetWindowLongW(c, -16) & 0x800) != 0) { found = c; n++; }   // GWL_STYLE=-16, ES_READONLY=0x0800
      c = GetWindow(c, GW_HWNDNEXT);
    }
    return n == 1 ? found : IntPtr.Zero;   // EXACTLY one read-only RichEdit
  }
  public static bool BubblePresent(IntPtr host) { return BubbleHwnd(host) != IntPtr.Zero; }
  public static int WindowPid(IntPtr h) { uint pid; GetWindowThreadProcessId(h, out pid); return (int)pid; }
  // RoseCat 7868 #3: each selected child HWND must belong to the launched pid, be visible, and (the bubble) be in
  // RichEdit PLAIN-TEXT mode. 0 pid for an absent child.
  public static int PanelPid(IntPtr host) { IntPtr p = PanelHwnd(host); return p == IntPtr.Zero ? 0 : WindowPid(p); }
  public static int PagePid(IntPtr host) { IntPtr p = PageHwnd(host); return p == IntPtr.Zero ? 0 : WindowPid(p); }
  public static int BubblePid(IntPtr host) { IntPtr b = BubbleHwnd(host); return b == IntPtr.Zero ? 0 : WindowPid(b); }
  // The RichEdit bubble's own WS_VISIBLE style (RoseCat ba35dc5 gap 2). Measured independently of the panel so
  // the oracle can fail bubble-hidden and panel-hidden as separate causal rows. The bubble is a control WE
  // ShowWindow, so its per-window style is meaningful headless (unlike the WebView2 page).
  public static bool BubbleVisible(IntPtr host) {
    IntPtr b = BubbleHwnd(host); return b != IntPtr.Zero && StyleVisible(b);
  }
  public static bool BubblePlainText(IntPtr host) {
    IntPtr b = BubbleHwnd(host); if (b == IntPtr.Zero) return false;
    // EM_GETTEXTMODE = WM_USER+90 = 0x045A; TM_PLAINTEXT = 1.
    return (SendMessageW(b, 0x045A, IntPtr.Zero, IntPtr.Zero).ToInt64() & 1) != 0;
  }
  // The launched child is a member of the owned Job (born suspended into it, not started then assigned).
  public static bool BornInJob() { if (_hProc == IntPtr.Zero || Job == IntPtr.Zero) return false; bool r; return IsProcessInJob(_hProc, Job, out r) && r; }
}
'@

$res = @{ stdout=''; stderr=''; client_w=0; client_h=0; pid=0; controls=''; icon_rect=''; icon_visible=-1; minimize_visible=-1; job_count_before=0; job_count_after=0; window_found=$false; terminated=$false; timed_out=$false; proc_gone=$false; first_stop_failed=$false; cleanup_exhausted=$false; launch_failed=$false; decoded_fail=$failMode; decoded_force=$forceMode; fold_elapsed_ms=0; fold_mid_w=0; panel_hidden=$false; page_redocked=$false; dpi_before_px=0; dpi_after_px=0; icon_hittest=99999; panel_rect=''; page_rect=''; bubble_present=$false; hwnd_pid=0; born_in_job=$false; panel_pid=0; page_pid=0; bubble_pid=0; panel_visible=$false; bubble_visible=$false; bubble_plaintext=$false; error='' }
# e2e-only seams, set in this process so the child inherits them (honoured only under --e2e-protocol).
$env:ZIGBROWSER_AGENT_DRAWER_OPEN = '1'
$env:ZIGBROWSER_AGENT_DRAWER_DEMO = 'messages:2'
if ($failMode) { $env:ZIGBROWSER_AGENT_DRAWER_FAIL = $failMode }
# Optional extra e2e seam env (behavior reds): a staged env.json of {name: value} is applied verbatim. Inert
# on a backend that does not honour the named seam (so the behavior reds fail-first until the green emits them).
$envJson = Join-Path $dir 'env.json'
if (Test-Path $envJson) {
  $extra = Get-Content -Raw $envJson | ConvertFrom-Json
  foreach ($p in $extra.PSObject.Properties) { Set-Item -Path ("Env:" + $p.Name) -Value ([string]$p.Value) }
}
$cmdline = '"' + $exe + '" --e2e-protocol --agent-drawer on "' + $url + '"'
$launched = $false
try {
  [Z]::LaunchOwned($exe, $cmdline, $dir, $out, $err)   # suspended -> job -> checked assign -> resume
  $launched = $true
  $res.pid = [Z]::Pid
  # Case-specific settling (RoseCat 02c39a4 #2): ZB_SETTLE_KINDS names the TERMINAL row kind(s) this case waits
  # for; default 'open|drag' (open/drag runs). A fold run sets 'fold', so it is NOT torn down at the first `open`
  # before its timer completes. A fold run also polls finely and MEASURES the animation independently: the
  # wall-clock elapsed between the `open` row and the `fold` row, and the first in-flight real panel width.
  $settle = $env:ZB_SETTLE_KINDS; if (-not $settle) { $settle = 'open|drag' }
  $settleErr = $env:ZB_SETTLE_STDERR   # RoseCat 70fd7f9 #3: a fold-FAILURE run settles on this stderr diagnostic
  $foldWait = ($settle -eq 'fold')
  $pollMs = if ($foldWait) { 25 } else { 300 }
  $sw = [System.Diagnostics.Stopwatch]::new()
  $openSeen = $false; $seen = $false; $openW = 0; $hWin = [IntPtr]::Zero
  $deadline = (Get-Date).AddSeconds(18)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds $pollMs
    $o = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue)
    if ($o) {
      if (-not $openSeen -and ($o -match "DRAWER`t\d+`topen`t")) { $openSeen = $true; $sw.Start() }
      if ($foldWait -and $openSeen) {
        if ($hWin -eq [IntPtr]::Zero) { $hWin = [Z]::FindOwnedWindow([Z]::Pid, 'zigBrowserWebView2Host') }
        if ($hWin -ne [IntPtr]::Zero) {
          $pw = [Z]::PanelWidthVisible($hWin)   # visible panel width, or -1 once hidden
          if ($pw -gt 0) {
            if ($openW -eq 0) { $openW = $pw }                               # the open width (animation start)
            elseif ($res.fold_mid_w -eq 0 -and $pw -lt $openW) { $res.fold_mid_w = $pw }  # first in-flight frame
          }
        }
      }
      if ($o -match "DRAWER`t\d+`t($settle)`t") {
        $seen = $true
        if ($foldWait) { $sw.Stop(); $res.fold_elapsed_ms = [int]$sw.ElapsedMilliseconds }
        break
      }
    }
    # A fold-failure run waits for its exact stderr diagnostic (NOT the earlier `open` row), so the async
    # SetTimer/MoveWindow/DwmFlush/read/delay failure has actually happened before we inspect the HWND below.
    if ($settleErr) {
      $e = [string](Get-Content $err -Raw -ErrorAction SilentlyContinue)
      if ($e -and $e.Contains($settleErr)) { $seen = $true; break }
    }
  }
  if (-not $seen) { $res.timed_out = $true }
  $res.job_count_before = [Z]::JobProcessCount()
  $h = [Z]::FindOwnedWindow([Z]::Pid, 'zigBrowserWebView2Host')   # OUR window, by pid (not global FindWindow)
  if ($h -ne [IntPtr]::Zero) {
    $res.window_found = $true
    $w = 0; $ht = 0; if ([Z]::Client($h, [ref]$w, [ref]$ht)) { $res.client_w = $w; $res.client_h = $ht }
    $res.controls = [Z]::DirectStatics($h)   # exact DIRECT STATIC children, "STATIC:<text>|..."
    $res.icon_rect = [Z]::IconClientRect($h)  # the REAL "S" icon HWND rect in client coords (WS5.2 observation)
    $res.icon_visible = [Z]::IconVisible($h)   # 1 visible / 0 hidden / -1 absent (open: HIDDEN; fold terminal: visible)
    $res.minimize_visible = [Z]::MinimizeVisible($h)  # the "-" control: 1 visible / 0 hidden / -1 absent (open: visible)
    # WS5.3 terminal fold state (RoseCat 02c39a4 #2): after a completed fold the panel is hidden, the page is
    # re-docked to the full client area, and the icon is visible again (icon_visible, above).
    $res.panel_hidden = (-not [Z]::PanelVisible($h))
    $res.page_redocked = [Z]::PageRedocked($h)
    # WS5 entry closure (RoseCat 1e5ff2d #2): INDEPENDENT pid-bound real-HWND reads for check_success — the panel
    # rect (vs the emitted open row), the page rect (docked above the panel), the read-only RichEdit bubble under
    # the panel, the owning pid, and Job membership (born into the owned Job). Measured while the handles are live.
    $res.panel_rect = [Z]::PanelClientRect($h)
    $res.page_rect = [Z]::PageClientRect($h)
    $res.bubble_present = [Z]::BubblePresent($h)
    $res.hwnd_pid = [Z]::WindowPid($h)
    $res.born_in_job = [Z]::BornInJob()
    # RoseCat 7868 #3: each selected child HWND belongs to the launched pid, is visible, and the bubble is in
    # RichEdit plain-text mode (not just ES_READONLY).
    $res.panel_pid = [Z]::PanelPid($h)
    $res.page_pid = [Z]::PagePid($h)
    $res.bubble_pid = [Z]::BubblePid($h)
    $res.panel_visible = [Z]::PanelVisible($h)    # the docked panel's own WS_VISIBLE (independent of the bubble)
    $res.bubble_visible = [Z]::BubbleVisible($h)   # the RichEdit bubble's own WS_VISIBLE
    $res.bubble_plaintext = [Z]::BubblePlainText($h)
    # WS5.7 (RoseCat 7a54253 #1): drive two real WM_DPICHANGED messages — "beforeDpi,afterDpi" — and measure the
    # icon width off the real HWND after each. Driving the before-DPI first makes the baseline deterministic
    # regardless of the VM monitor's own DPI. The drawer must be closed (icon visible + sized) for this.
    $dpiChange = $env:ZB_DPICHANGE
    if ($dpiChange) {
      $parts = $dpiChange -split ','
      [Z]::SendDpiChanged($h, [int]$parts[0]); Start-Sleep -Milliseconds 80
      $rb = [Z]::IconClientRect($h); if ($rb) { $res.dpi_before_px = [int](($rb -split ',')[2]) }
      [Z]::SendDpiChanged($h, [int]$parts[1]); Start-Sleep -Milliseconds 80
      $ra = [Z]::IconClientRect($h); if ($ra) { $res.dpi_after_px = [int](($ra -split ',')[2]) }
    }
    # WS5.7 (RoseCat 00b69e5): probe the icon's WM_NCHITTEST at its centre to prove the refuse-on-unreadable path.
    if ($env:ZB_HITTEST_PROBE) { $res.icon_hittest = [Z]::IconHitTestAtCenter($h) }
  }
} catch { $res.error = $_.Exception.Message; $res.launch_failed = (-not $launched) }
finally {
  if ($launched) {
    try { [Z]::Teardown(); $res.terminated = $true } catch { if (-not $res.error) { $res.error = $_.Exception.Message } }
  }
  # Census the owned job while its handle is still open, THEN close the Job (KILL_ON_CLOSE kills any still-
  # assigned child), THEN run the definitive bounded reap through the still-held process handle — so a Job-close
  # kill is proven by a post-close wait, and a never-assigned child is terminated+proven by FinalReap itself.
  # The runner never exits with an unproved child (RoseCat a94db57 #2).
  # FAIL-CLOSED settled read (orchestrator option a): a just-terminated member may linger an instant in the job
  # list, so wait (bounded) for owned members to leave before recording the count; a count still > 0 at the
  # deadline is a real survivor and FAILS downstream.
  try { if ([Z]::Job -ne [IntPtr]::Zero) { $res.job_count_after = [Z]::JobProcessCountSettled(3000, 100) } } catch { if (-not $res.error) { $res.error = $_.Exception.Message } }
  try { [Z]::CloseJob() } catch { if (-not $res.error) { $res.error = $_.Exception.Message } }
  try { [Z]::FinalReap() | Out-Null } catch { if (-not $res.error) { $res.error = $_.Exception.Message } }
  $res.proc_gone = [Z]::ProcGone
  $res.first_stop_failed = [Z]::FirstStopFailed
  $res.cleanup_exhausted = [Z]::CleanupExhausted
  if (-not $res.proc_gone -and -not $res.error) { $res.error = 'cleanup exhausted: held child not proven terminal' }
  $res.stdout = [string](Get-Content $out -Raw -ErrorAction SilentlyContinue); if ($null -eq $res.stdout) { $res.stdout = '' }
  $res.stderr = [string](Get-Content $err -Raw -ErrorAction SilentlyContinue); if ($null -eq $res.stderr) { $res.stderr = '' }
}
[Console]::Out.Write(($res | ConvertTo-Json -Compress))
"""


class WinDrawerLive(unittest.TestCase):
    def setUp(self):
        self.host = os.environ.get("ZB_WIN11_HOST")
        if not self.host:
            self.skipTest("ZB_WIN11_HOST unset — live VM drawer test skipped")
        self.exe = os.environ.get("ZB_WIN_EXE")
        if not self.exe or not pathlib.Path(self.exe).is_file():
            self.skipTest("ZB_WIN_EXE unset or missing — set it to a built zigBrowser.exe")
        self.port = os.environ.get("ZB_WIN11_PORT", "2222")
        self.user = os.environ.get("ZB_WIN11_USER", "zbtext")
        self.key = os.environ.get("ZB_WIN_KEY", "/home/maceo/vms/win11-m8/zb_win_key")
        self.kh = os.environ.get("ZB_WIN_KNOWN_HOSTS", "/home/maceo/vms/win11-m8/known_hosts")
        # No broad `drawer-*` sweep here: deleting other dirs could hit a concurrent run's live tree
        # (RoseCat 29e8852/7640 #3). Each run owns and removes ONLY its own unique root, fail-closed.

    def _scrub(self, *cmd):
        return ["env", "-u", "DISPLAY", "-u", "WAYLAND_DISPLAY", "-u", "XAUTHORITY", *cmd]

    def _ssh(self, *args, timeout=120):
        base = ["ssh", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-p", self.port, f"{self.user}@{self.host}"]
        return subprocess.run(self._scrub(*base, *args), capture_output=True, text=True, timeout=timeout)

    def _scp(self, local, remote):
        base = ["scp", "-i", self.key, "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", f"UserKnownHostsFile={self.kh}", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
                "-o", "ConnectionAttempts=3", "-P", self.port, local, f"{self.user}@{self.host}:{remote}"]
        return subprocess.run(self._scrub(*base), capture_output=True, text=True, timeout=120).returncode

    def _run_drawer(self, fail_mode="", force_mode="", body=None, extra_env=None):
        """Stage + run run.ps1 (optionally with the production control-factory seam `fail_mode`, the harness
        job-lifecycle seam `force_mode`, and/or `extra_env` — extra e2e seam env applied verbatim via a staged
        env.json), parse the JSON result, invoke `body(r)`, and always tear down this run's unique root
        fail-closed."""
        rel = f"zb/drawer-{os.getpid()}-{secrets.token_hex(4)}"
        base_win = f"%USERPROFILE%\\{rel}".replace("/", "\\")
        self.assertEqual(self._ssh("cmd", "/c", f"mkdir {base_win}").returncode, 0)
        tmp = pathlib.Path(os.environ.get("TMPDIR", "/tmp"))
        html = tmp / f"drawer-{secrets.token_hex(4)}.html"
        runner = tmp / f"drawerrun-{secrets.token_hex(4)}.ps1"
        html.write_text(_HTML, encoding="utf-8")
        runner.write_text(_RUNNER, encoding="utf-8", newline="\r\n")
        env_file = None
        if extra_env:
            env_file = tmp / f"drawerenv-{secrets.token_hex(4)}.json"
            env_file.write_text(json.dumps(extra_env), encoding="utf-8")
        try:
            pairs = [(self.exe, "zigBrowser.exe"), (str(html), "test.html"), (str(runner), "run.ps1")]
            if env_file is not None:
                pairs.append((str(env_file), "env.json"))
            loader = pathlib.Path(self.exe).with_name("WebView2Loader.dll")
            if loader.is_file():
                pairs.append((str(loader), "WebView2Loader.dll"))
            for local, name in pairs:
                self.assertEqual(self._scp(local, f"{rel}/{name}"), 0, f"scp {name}")
            # Always 3 positionals with nonempty sentinels (no blank positional that could be dropped in transit
            # and shift the seam — the dbe6382 live-run bug; RoseCat f7ff742).
            args = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                    "-File", f"{base_win}\\run.ps1", *drawer_runner_args(base_win, fail_mode, force_mode)]
            run = self._ssh(*args)
            self.assertEqual(run.returncode, 0, f"runner failed: {run.stdout}\n{run.stderr}")
            r = json.loads(run.stdout.strip().splitlines()[-1])
            if body:
                body(r)
            return r
        finally:
            # The owned Job (KILL_ON_JOB_CLOSE) kills the WHOLE tree — including the WebView2 children born
            # inside it — so the run dir's WebView2 cache is released and this unique root must come back
            # clean. Remove ONLY this run's root, bounded retry, and FAIL if it survives (29e8852/7640 #3/#4),
            # without masking a body failure.
            import sys as _sys
            import time as _t
            # Bounded by ONE absolute 60 s deadline (RoseCat dfaf431): a just-killed child (esp. a born-suspended
            # one whose image is the scp'd exe) can hold the exe image lock briefly after its handle closes, so
            # rmdir can transiently fail. Each iteration is a SINGLE remote op (rmdir + existence check) capped to
            # the remaining budget, so a stalled connection can never renew the budget past the deadline.
            def _rm_step(budget):
                try:
                    # budget is always > 0 here (bounded_cleanup only steps with a positive remaining budget),
                    # so cap the ssh timeout to exactly the remaining budget — never overshoot the deadline.
                    out = self._ssh("cmd", "/c",
                                    f"rmdir /s /q {base_win} & if exist {base_win} (echo LEFT) else (echo GONE)",
                                    timeout=budget).stdout
                    return "GONE" in out
                except subprocess.TimeoutExpired:
                    return False
            gone = bounded_cleanup(_t.monotonic, _t.sleep, 60.0, _rm_step)
            for p in (html, runner, env_file):
                if p is None:
                    continue
                try:
                    p.unlink()
                except OSError:
                    pass
            if not gone:
                # Report cleanup exhaustion either way (never silently accepted); only raise if the body did
                # not already fail, so the original failure is preserved (29e8852 #4).
                _sys.stderr.write(f"CLEANUP: run dir left behind (not removed): {base_win}\n")
                if _sys.exc_info()[0] is None:
                    self.fail(f"run dir left behind (not removed): {base_win}")

    def test_native_drawer_mounts_docks_and_emits_census(self):
        self._run_drawer(body=check_success)

    def _seam_body(self, want_fail, want_force, check):
        # Verify the runner DECODED the seam the test intended (the live echo, RoseCat f7ff742) — this is what
        # catches the dropped/blank-positional bug — then apply the behavior check.
        def body(r):
            self.assertEqual(r.get("decoded_fail"), want_fail, f"decoded fail seam mismatch: {r.get('decoded_fail')!r}")
            self.assertEqual(r.get("decoded_force"), want_force, f"decoded force seam mismatch: {r.get('decoded_force')!r}")
            check(r)
        return body

    def test_panel_create_failure_leaves_no_drawer(self):
        # WS5 (RoseCat 7646): forcing the panel CreateWindowExW to fail must mount NO drawer — no DRAWER rows,
        # no drawer controls — the browser still runs and tears down cleanly, with the panel diagnostic.
        self._run_drawer(fail_mode="panel", body=self._seam_body("panel", "", lambda r: check_mounted_fail(r, "panel")))

    def test_icon_create_failure_leaves_no_drawer(self):
        self._run_drawer(fail_mode="icon", body=self._seam_body("icon", "", lambda r: check_mounted_fail(r, "icon")))

    def test_bubble_create_failure_leaves_no_drawer(self):
        # WS5.4 (RoseCat 6774439): the bubble is the conversation surface, not expendable chrome. Forcing its
        # RichEdit create to fail must mount NO drawer — no rows, no controls — with the bubble diagnostic. This
        # causally proves the panel/icon/min created before it were all DESTROYED (no leaked STATICs).
        self._run_drawer(fail_mode="bubble", body=self._seam_body("bubble", "", lambda r: check_mounted_fail(r, "bubble")))

    def test_assign_failure_terminates_held_process(self):
        # RoseCat fd17cba/7662, 7670 #1: forcing AssignProcessToJobObject to fail must terminate the held
        # (suspended) process by its handle — proven gone, no owned job members left (no pid/name kill, no orphan).
        self._run_drawer(force_mode="assign_fail", body=self._seam_body("", "assign_fail", check_assign_fail))

    def test_assign_plus_first_stop_failure_reaped_by_independent_cleanup(self):
        # RoseCat a94db57 #1 / c943215: membership verify fails AND the first stop proof fails on the suspended
        # child, so only the born-in-job backstop (job close + post-close wait) can prove it gone — Teardown is
        # skipped and cannot supply the proof.
        self._run_drawer(force_mode="assign_firststop_fail",
                         body=self._seam_body("", "assign_firststop_fail", check_assign_firststop_fail))

    def test_cleanup_exhaustion_cannot_outlive_runner(self):
        # RoseCat c943215: every held-handle reap attempt is exhausted, yet because the child was BORN INTO the
        # kill-on-close job, closing the job + the durable post-close wait still prove it terminal. The child
        # cannot outlive the runner even when the TerminateProcess-based reap fails entirely.
        self._run_drawer(force_mode="cleanup_exhaust",
                         body=self._seam_body("", "cleanup_exhaust", check_cleanup_exhaustion))

    def test_wait_failure_is_reported(self):
        # RoseCat 7670 #2: a teardown whose first wait is not WAIT_OBJECT_0 must FAIL (never a silent bounded
        # success) AND the distinct bounded cleanup route must prove the process + job tree gone first.
        self._run_drawer(force_mode="wait_fail", body=self._seam_body("", "wait_fail", check_wait_fail))


class WinDrawerOracle(unittest.TestCase):
    """OFFLINE (no VM) injected coverage proving the runner-result oracle is discriminating and fail-closed
    (RoseCat 29e8852 'add non-live injected coverage ...'). Each case feeds a crafted result dict to
    check_success and asserts it raises for the corresponding failure branch."""

    def _good(self):
        return {
            "error": "", "timed_out": False, "terminated": True, "job_count_after": 0, "job_count_before": 2,
            "window_found": True, "controls": "STATIC:|STATIC:S|STATIC:-", "client_w": 1008, "client_h": 729,
            "pid": 4242, "hwnd_pid": 4242, "born_in_job": True, "bubble_present": True,
            "panel_pid": 4242, "page_pid": 4242, "bubble_pid": 4242, "bubble_plaintext": True,
            "panel_visible": True, "bubble_visible": True, "minimize_visible": 1, "icon_visible": 0,  # open: panel/bubble/"-" shown, "S" hidden

            "panel_rect": "0,437,1008,292",  # == the emitted open rect (independent HWND read)
            "page_rect": "0,0,1008,437",     # top-left, full width, bottom (437) == panel top (437)
            "stdout": ("DRAWER\t1\ttree\thost,page,icon,panel\n"
                       "DRAWER\t1\ticon\t928,649,56,56\n"
                       "DRAWER\t1\topen\t0,437,1008,292\n"),
            "stderr": "",
        }

    def test_good_passes(self):
        check_success(self._good())  # must NOT raise

    def _reject(self, mutate):
        r = self._good(); mutate(r)
        with self.assertRaises(AssertionError):
            check_success(r)

    def test_assign_failure_rejected(self):
        self._reject(lambda r: r.update(error="AssignProcessToJobObject failed (held process terminated; gone=True)"))

    def test_win32_error_rejected(self):
        self._reject(lambda r: r.update(error="CreateProcess failed: 2"))

    def test_wait_not_object0_rejected(self):
        self._reject(lambda r: r.update(terminated=False))

    def test_timed_out_rejected(self):
        self._reject(lambda r: r.update(timed_out=True))

    def test_job_survivor_rejected(self):
        self._reject(lambda r: r.update(job_count_after=1))

    def test_no_owned_window_rejected(self):
        self._reject(lambda r: r.update(window_found=False))

    def test_row_only_no_controls_rejected(self):
        self._reject(lambda r: r.update(controls=""))  # a row-only / null-control impl

    def test_wrong_or_extra_controls_rejected(self):
        self._reject(lambda r: r.update(controls="STATIC:|STATIC:S|STATIC:X"))

    def test_multiple_window_ids_rejected(self):
        self._reject(lambda r: r.update(stdout=r["stdout"].replace("DRAWER\t1\topen", "DRAWER\t2\topen")))

    def test_missing_open_row_rejected(self):
        self._reject(lambda r: r.update(stdout="DRAWER\t1\ttree\thost,page,icon,panel\nDRAWER\t1\ticon\t928,649,56,56\n"))

    def test_overlay_geometry_rejected(self):  # panel.y == 0 (overlay, not docked)
        self._reject(lambda r: r.update(stdout=r["stdout"].replace("0,437,1008,292", "0,0,1008,729")))

    def test_panel_not_full_width_rejected(self):
        self._reject(lambda r: r.update(client_w=1200))

    # --- independent pid-bound real-HWND mutants (RoseCat 1e5ff2d closure #3) ---
    def test_missing_bubble_rejected(self):
        self._reject(lambda r: r.update(bubble_present=False))  # no read-only RichEdit conversation surface

    def test_wrong_bubble_rejected(self):
        # a bubble that is not a read-only RichEdit under the panel is reported as not-present and must fail
        self._reject(lambda r: r.update(bubble_present=False))

    def test_row_vs_hwnd_rect_mismatch_rejected(self):
        # the emitted open row disagrees with the observed panel HWND rect — a trusted-row-only impl is caught
        self._reject(lambda r: r.update(panel_rect="0,440,1008,292"))

    def test_page_still_behind_panel_rejected(self):
        # the page HWND was not shrunk above the panel (its bottom runs past the panel top) — left behind/under
        self._reject(lambda r: r.update(page_rect="0,0,1008,729"))

    def test_page_not_full_width_rejected(self):
        self._reject(lambda r: r.update(page_rect="0,0,900,437"))

    def test_wrong_pid_hwnd_rejected(self):
        # the observed HWND tree belongs to a different pid than the one launched — a stray/stale window
        self._reject(lambda r: r.update(hwnd_pid=9999))

    def test_start_before_job_rejected(self):
        # the browser was started then assigned (a pre-Job window existed), not born suspended into the Job
        self._reject(lambda r: r.update(born_in_job=False))

    def test_wrong_child_pid_rejected(self):
        # a selected child HWND (here the page) belongs to a different pid than the launched one — a stray window
        self._reject(lambda r: r.update(page_pid=9998))

    # OPEN-state native visibility — one causal negative per condition (RoseCat ba35dc5 gap 2).
    def test_open_panel_hidden_rejected(self):
        # the docked panel is not WS_VISIBLE on the open drawer — must fail
        self._reject(lambda r: r.update(panel_visible=False))

    def test_open_bubble_hidden_rejected(self):
        # the RichEdit bubble is not WS_VISIBLE on the open drawer — must fail
        self._reject(lambda r: r.update(bubble_visible=False))

    def test_open_minimize_hidden_rejected(self):
        # the "-" minimize control is hidden on the open drawer (no fold affordance) — must fail
        self._reject(lambda r: r.update(minimize_visible=0))

    def test_open_minimize_absent_rejected(self):
        # the "-" minimize control is absent entirely (never created) — must fail
        self._reject(lambda r: r.update(minimize_visible=-1))

    def test_open_icon_still_visible_rejected(self):
        # the "S" collapsed icon is still visible while the drawer is open (should be SW_HIDE) — must fail
        self._reject(lambda r: r.update(icon_visible=1))

    def test_rich_text_bubble_rejected(self):
        # the bubble is ES_READONLY but NOT plain-text (RichEdit rich-text mode) — RTF could render markup
        self._reject(lambda r: r.update(bubble_plaintext=False))

    # --- strict page-child selector (select_page_child / [Z]::PageHwnd, RoseCat f877bc5) ---
    # The headless gate keeps page EXISTENCE + OWNERSHIP (class + launched pid); only real page PRESENTATION
    # (rendered pixels) moves to the owner real-screen check. These prove the selector is causal: a larger
    # unrelated direct child is ignored, while absent / duplicate / wrong-pid matches fail closed.
    def test_page_child_larger_unrelated_ignored(self):
        # A LARGER unrelated direct child (a different class) must NOT be mistaken for the page: selection is by
        # class + pid, never by size. The genuine Chrome_WidgetWin_0 child is still picked.
        children = [
            {"hwnd": 0x10, "cls": "Static", "pid": 4242},
            {"hwnd": 0x20, "cls": "SomeHugeOverlay", "pid": 4242},  # larger area, wrong class — a size-based pick would take this
            {"hwnd": 0x30, "cls": PAGE_WIDGET_CLASS, "pid": 4242},
        ]
        self.assertEqual(select_page_child(children, 4242), 0x30)

    def test_page_child_absent_fails(self):
        # No Chrome_WidgetWin_0 child at all => None (caller fails closed).
        children = [{"hwnd": 0x10, "cls": "Static", "pid": 4242},
                    {"hwnd": 0x20, "cls": "SomeHugeOverlay", "pid": 4242}]
        self.assertIsNone(select_page_child(children, 4242))

    def test_page_child_duplicate_fails(self):
        # TWO launched-pid Chrome_WidgetWin_0 children => ambiguous => None (not "pick the bigger/first one").
        children = [{"hwnd": 0x30, "cls": PAGE_WIDGET_CLASS, "pid": 4242},
                    {"hwnd": 0x31, "cls": PAGE_WIDGET_CLASS, "pid": 4242}]
        self.assertIsNone(select_page_child(children, 4242))

    def test_page_child_wrong_pid_fails(self):
        # A Chrome_WidgetWin_0 child owned by a DIFFERENT pid (a stray/stale browser) must not count => None.
        children = [{"hwnd": 0x30, "cls": PAGE_WIDGET_CLASS, "pid": 9999}]
        self.assertIsNone(select_page_child(children, 4242))

    def test_page_hwnd_embedded_selector_is_strict(self):
        # RoseCat ba35dc5: bind the oracle to the ACTUAL embedded C# selector that the Win11 run executes, not
        # only the detached Python model. Extract [Z]::PageHwnd's real body and pin class + pid + exactly-one and
        # the ABSENCE of size/visibility heuristics, so reverting the C# to the old largest-visible-child body
        # would turn this red (it does not change select_page_child or the four model rows above).
        body = extract_csharp_method(_RUNNER, "PageHwnd")
        self.assertTrue(page_selector_body_is_strict(body),
                        f"embedded PageHwnd must select by class + pid + exactly-one, no size/visibility; body={body!r}")
        # independent of the predicate: the real body must carry each required token and neither heuristic
        self.assertIn('"Chrome_WidgetWin_0"', body)      # the widget class
        self.assertIn("== Pid", body)                     # the launched pid
        self.assertIn("n == 1", body)                     # exactly one match
        self.assertNotIn("StyleVisible", body)            # no visibility gate
        self.assertNotIn("GetWindowRect", body)           # no size/area measurement

    def test_page_hwnd_selector_mutants_rejected(self):
        # The same predicate must REJECT each reverted selector — proving it is causal, not vacuous.
        old_largest = (  # the pre-f877bc5 largest-VISIBLE-non-STATIC heuristic
            'IntPtr best_h = IntPtr.Zero; int best = 0; IntPtr c = GetWindow(host, GW_CHILD);'
            'while (c != IntPtr.Zero) { var cls = new StringBuilder(64); GetClassName(c, cls, 64);'
            'if (cls.ToString() != "STATIC" && StyleVisible(c)) { RECT r; if (GetWindowRect(c, out r)) {'
            'int hh = r.bottom - r.top; if (hh > best) { best = hh; best_h = c; } } }'
            'c = GetWindow(c, GW_HWNDNEXT); } return best_h;')
        no_pid = (  # class + exactly-one, but the pid term dropped (a wrong-pid page would be accepted)
            'IntPtr found = IntPtr.Zero; int n = 0; IntPtr c = GetWindow(host, GW_CHILD);'
            'while (c != IntPtr.Zero) { var cls = new StringBuilder(64); GetClassName(c, cls, 64);'
            'if (cls.ToString() == "Chrome_WidgetWin_0") { found = c; n++; } c = GetWindow(c, GW_HWNDNEXT); }'
            'return n == 1 ? found : IntPtr.Zero;')
        first_match = (  # returns the FIRST class+pid match instead of requiring a unique one
            'IntPtr c = GetWindow(host, GW_CHILD); while (c != IntPtr.Zero) {'
            'var cls = new StringBuilder(64); GetClassName(c, cls, 64); uint pid;'
            'GetWindowThreadProcessId(c, out pid);'
            'if (cls.ToString() == "Chrome_WidgetWin_0" && (int)pid == Pid) return c;'
            'c = GetWindow(c, GW_HWNDNEXT); } return IntPtr.Zero;')
        for label, mutant in (("old-largest", old_largest), ("no-pid", no_pid), ("first-match", first_match)):
            self.assertFalse(page_selector_body_is_strict(mutant), f"mutant {label} must be rejected by the predicate")

    def test_exactly_eight_live_methods(self):
        # RoseCat 7862/7868 #2: pin the hostless skip count — WinDrawerLive has EXACTLY the 8 entry live rows.
        live = [m for m in dir(WinDrawerLive) if m.startswith("test_")]
        self.assertEqual(len(live), 8, f"WinDrawerLive must have exactly 8 live rows; got {sorted(live)}")

    def test_aggregate_gate_step_scrubs_live_vars(self):
        # RoseCat 7862/7868 #1: prove the aggregate gate step cannot contact the VM — the registered
        # windows-drawer-live/behaviors commands must unset EVERY live connection var before python3, so an
        # inherited ZB_WIN11_HOST/etc. can never reach _ssh/_scp.
        bz = (pathlib.Path(__file__).resolve().parents[2] / "build.zig").read_text(encoding="utf-8")
        for var in ("ZB_WIN11_HOST", "ZB_WIN_EXE", "ZB_WIN11_PORT", "ZB_WIN11_USER", "ZB_WIN_KEY", "ZB_WIN_KNOWN_HOSTS"):
            self.assertIn(f"-u {var}", bz, f"the gate drawer step must unset {var} so the gate cannot reach the VM")

    # --- forced control-create failure oracle (check_mounted_fail, RoseCat 7646) ---
    def _good_fail(self, which):
        return {"error": "", "terminated": True, "job_count_after": 0, "controls": "",
                "stdout": "NAV\tfile:///x/test.html\tdrawer\n",
                "stderr": f"zigBrowser: agent-drawer {which} control failed (error 87); drawer not mounted\n"}

    def test_panel_fail_good_passes(self):
        check_mounted_fail(self._good_fail("panel"), "panel")

    def test_icon_fail_good_passes(self):
        check_mounted_fail(self._good_fail("icon"), "icon")

    def test_bubble_fail_good_passes(self):
        check_mounted_fail(self._good_fail("bubble"), "bubble")

    def test_bubble_fail_but_leaked_min_rejected(self):
        # A bubble failure must DESTROY the panel/icon/min created before it; a leaked "-" control must fail.
        r = self._good_fail("bubble"); r["controls"] = "STATIC:-"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "bubble")

    def test_fail_but_rows_emitted_rejected(self):
        r = self._good_fail("panel"); r["stdout"] += "DRAWER\t1\ttree\thost,page,icon,panel\n"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "panel")

    def test_fail_but_icon_control_present_rejected(self):
        r = self._good_fail("icon"); r["controls"] = "STATIC:|STATIC:S"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "icon")

    def test_icon_fail_but_leaked_panel_rejected(self):
        # RoseCat 7677 survived mutant: an icon failure that LEAKS the panel ("STATIC:", no icon). The panel
        # must have been destroyed, so a leaked panel must fail.
        r = self._good_fail("icon"); r["controls"] = "STATIC:"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "icon")

    def test_fail_without_diagnostic_rejected(self):
        r = self._good_fail("panel"); r["stderr"] = ""
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "panel")

    def test_fail_truncated_diagnostic_rejected(self):
        # RoseCat 7677 survived mutant: a truncated diagnostic (no "(error 87); drawer not mounted") must fail.
        r = self._good_fail("icon"); r["stderr"] = "zigBrowser: agent-drawer icon control failed\n"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "icon")

    def test_fail_wrong_error_code_rejected(self):
        # the pinned diagnostic requires the deterministic forced error 87; a different code must fail.
        r = self._good_fail("panel")
        r["stderr"] = "zigBrowser: agent-drawer panel control failed (error 5); drawer not mounted\n"
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "panel")

    def test_fail_but_not_torn_down_rejected(self):
        r = self._good_fail("panel"); r["terminated"] = False
        with self.assertRaises(AssertionError):
            check_mounted_fail(r, "panel")

    # --- forced job-lifecycle failure oracles (check_assign_fail / check_assign_firststop_fail / check_wait_fail) ---
    def test_assign_fail_good_passes(self):
        check_assign_fail({"launch_failed": True, "proc_gone": True, "job_count_after": 0,
                           "error": "AssignProcessToJobObject failed (held stop gone=True)", "stdout": ""})

    def test_assign_fail_orphan_survivor_rejected(self):
        with self.assertRaises(AssertionError):
            check_assign_fail({"launch_failed": True, "proc_gone": False, "job_count_after": 0,
                               "error": "AssignProcessToJobObject failed (held stop gone=False)", "stdout": ""})

    def test_assign_fail_job_member_survivor_rejected(self):
        # RoseCat 7670 #1: an owned job member surviving teardown must fail even if proc_gone is claimed.
        with self.assertRaises(AssertionError):
            check_assign_fail({"launch_failed": True, "proc_gone": True, "job_count_after": 1,
                               "error": "AssignProcessToJobObject failed", "stdout": ""})

    def test_assign_fail_rows_emitted_rejected(self):
        with self.assertRaises(AssertionError):
            check_assign_fail({"launch_failed": True, "proc_gone": True, "job_count_after": 0,
                               "error": "AssignProcessToJobObject failed", "stdout": "DRAWER\t1\topen\t0,437,1008,292\n"})

    def test_assign_firststop_fail_good_passes(self):
        # RoseCat a94db57 #1 / c943215: membership verify fails + first stop fails; the born-in-job backstop
        # (job close + post-close wait) proves the child gone. launch_failed proves Teardown did not supply it.
        check_assign_firststop_fail({"launch_failed": True, "first_stop_failed": True, "proc_gone": True,
                                     "error": "AssignProcessToJobObject membership not verified", "stdout": ""})

    def test_assign_firststop_fail_but_not_reaped_rejected(self):
        with self.assertRaises(AssertionError):
            check_assign_firststop_fail({"launch_failed": True, "first_stop_failed": True, "proc_gone": False,
                                         "error": "AssignProcessToJobObject membership not verified", "stdout": ""})

    def test_assign_firststop_fail_teardown_supplied_proof_rejected(self):
        # if the run resumed (launch_failed False), Teardown supplied the proof — not the independent cleanup.
        with self.assertRaises(AssertionError):
            check_assign_firststop_fail({"launch_failed": False, "first_stop_failed": True, "proc_gone": True,
                                         "error": "AssignProcessToJobObject membership not verified", "stdout": ""})

    def test_assign_firststop_fail_not_actually_exercised_rejected(self):
        # if the first-stop seam never fired, this is not evidence of first-stop-fails/backstop-succeeds.
        with self.assertRaises(AssertionError):
            check_assign_firststop_fail({"launch_failed": True, "first_stop_failed": False, "proc_gone": True,
                                         "error": "AssignProcessToJobObject membership not verified", "stdout": ""})

    def test_cleanup_exhaustion_good_passes(self):
        # RoseCat c943215: every held-handle reap attempt is exhausted, but the born-in-job backstop + durable
        # post-close wait still prove the child terminal — it cannot outlive the runner.
        check_cleanup_exhaustion({"launch_failed": True, "cleanup_exhausted": True, "proc_gone": True,
                                  "error": "AssignProcessToJobObject membership not verified"})

    def test_cleanup_exhaustion_orphan_rejected(self):
        # the runner must never exit with an unproved child: exhausted AND not proven terminal must FAIL.
        with self.assertRaises(AssertionError):
            check_cleanup_exhaustion({"launch_failed": True, "cleanup_exhausted": True, "proc_gone": False,
                                      "error": "cleanup exhausted: held child not proven terminal"})

    def test_cleanup_exhaustion_not_exercised_rejected(self):
        with self.assertRaises(AssertionError):
            check_cleanup_exhaustion({"launch_failed": True, "cleanup_exhausted": False, "proc_gone": True,
                                      "error": "AssignProcessToJobObject membership not verified"})

    def test_wait_fail_good_passes(self):
        check_wait_fail({"terminated": False, "proc_gone": True, "job_count_after": 0,
                         "error": "WaitForSingleObject on the browser did not signal WAIT_OBJECT_0: 258 (bounded cleanup proved gone=True, job_members=0)"})

    def test_wait_fail_silent_success_rejected(self):
        with self.assertRaises(AssertionError):
            check_wait_fail({"terminated": True, "proc_gone": True, "job_count_after": 0, "error": ""})

    def test_wait_fail_without_cleanup_proof_rejected(self):
        # RoseCat 7670 #2: reporting the diagnostic without proving the process/job gone must fail.
        with self.assertRaises(AssertionError):
            check_wait_fail({"terminated": False, "proc_gone": False, "job_count_after": 0,
                             "error": "WaitForSingleObject on the browser did not signal WAIT_OBJECT_0: 258"})

    def test_wait_fail_job_member_survivor_rejected(self):
        with self.assertRaises(AssertionError):
            check_wait_fail({"terminated": False, "proc_gone": True, "job_count_after": 1,
                             "error": "WaitForSingleObject on the browser did not signal WAIT_OBJECT_0: 258"})

    # --- runner arg encoding / decoding oracles (RoseCat f7ff742: no blank positional) ---
    def test_runner_args_causal_rows(self):
        b = "C:\\Users\\zbtext\\zb\\drawer-x"
        self.assertEqual(drawer_runner_args(b, "", ""), [b, "none", "none"])          # no seam
        self.assertEqual(drawer_runner_args(b, "panel", ""), [b, "panel", "none"])    # fail-only
        self.assertEqual(drawer_runner_args(b, "", "assign_fail"), [b, "none", "assign_fail"])  # force-only
        self.assertEqual(drawer_runner_args(b, "panel", "assign_fail"), [b, "panel", "assign_fail"])  # both
        for fm, fo in (("", ""), ("panel", ""), ("", "assign_fail"), ("icon", "wait_fail")):
            self.assertEqual(len(drawer_runner_args(b, fm, fo)), 3, "exactly 3 positionals")

    def test_runner_args_force_only_is_not_blank_positional(self):
        # The exact dbe6382 regression: a force-only run must put 'none' (not '') in the fail slot, so the force
        # arg cannot shift. base='...', fail slot pinned 'none', force 'assign_fail'.
        b = "C:\\Users\\zbtext\\zb\\drawer-x"
        args = drawer_runner_args(b, "", "assign_fail")
        self.assertEqual(args, [b, "none", "assign_fail"])
        self.assertEqual(args[1], "none", "the fail slot must be a nonempty sentinel, never a blank positional")

    def test_runner_args_fail_closed(self):
        b = "C:\\Users\\zbtext\\zb\\drawer-x"
        with self.assertRaises(AssertionError):
            drawer_runner_args(b, "bogus", "")
        with self.assertRaises(AssertionError):
            drawer_runner_args(b, "", "bogus")

    def test_decode_mode_fail_closed(self):
        self.assertEqual(decode_mode("none", ("assign_fail",)), "")
        self.assertEqual(decode_mode("assign_fail", ("assign_fail", "wait_fail")), "assign_fail")
        with self.assertRaises(AssertionError):
            decode_mode("bogus", ("assign_fail",))      # unknown -> fail closed
        with self.assertRaises(AssertionError):
            decode_mode("", ("assign_fail",))           # a blank (dropped) slot -> fail closed, not treated as off

    def test_runner_decodes_and_echoes(self):
        # structural: the VM runner enforces the exact arg count, fail-closed decode, and echoes the decoded seam.
        self.assertIn("if ($args.Count -ne 3)", _RUNNER)
        self.assertIn("function Decode-Mode", _RUNNER)
        self.assertIn("unknown/blank seam mode", _RUNNER)
        self.assertIn("decoded_fail=$failMode", _RUNNER)
        self.assertIn("decoded_force=$forceMode", _RUNNER)
        # option a: the runner records job_count_after via the fail-closed SETTLED read, not a single instant read.
        self.assertIn("JobProcessCountSettled", _RUNNER)
        self.assertNotIn("$res.job_count_after = [Z]::JobProcessCount()", _RUNNER)

    def test_runner_matches_static_class_case_insensitively(self):
        # GetClassName reports the Win32 built-in control class as "Static", NOT "STATIC" (confirmed by the
        # 361935b hierarchy diagnostic: the panel/icon/min all enumerate as class 'Static'). The runner's class
        # checks MUST be case-insensitive, or DirectStatics finds no controls and the native-mount success row
        # spuriously fails though the drawer mounted correctly.
        self.assertIn("StringComparison.OrdinalIgnoreCase", _RUNNER)
        self.assertNotIn('cls.ToString() == "STATIC"', _RUNNER)
        self.assertNotIn('cls.ToString() != "STATIC"', _RUNNER)

    def test_runner_seam_allowlists_match_the_python_modes(self):
        # The runner's PowerShell Decode-Mode allowlists MUST list every FAIL_MODES / FORCE_MODES value (minus
        # the empty 'none'); a drift (e.g. adding a shim+Python fail mode but not the runner's list) silently
        # reds a VM row as "unknown/blank seam mode". Pin both lists so the drift reds OFFLINE instead.
        for m in FAIL_MODES:
            if m:
                self.assertIn(f"'{m}'", _RUNNER, f"runner Decode-Mode fail allowlist is missing {m!r}")
        for m in FORCE_MODES:
            if m:
                self.assertIn(f"'{m}'", _RUNNER, f"runner Decode-Mode force allowlist is missing {m!r}")

    # --- fail-closed settled owned-job count oracles (orchestrator option a) ---
    def _run_settled(self, counts, deadline_s=0.4, poll_s=0.1):
        clock = [0.0]
        seq = list(counts)
        def count():
            return seq.pop(0) if len(seq) > 1 else seq[0]  # hold the last value once exhausted
        return job_count_settled(lambda: clock[0], lambda s: clock.__setitem__(0, clock[0] + s), count, deadline_s, poll_s)

    def test_settled_transient_terminated_member_passes(self):
        # the real bug: a just-terminated member lingers one instant, then leaves. Settled read -> 0 (PASS).
        self.assertEqual(self._run_settled([1, 1, 0, 0, 0]), 0)

    def test_settled_persistent_survivor_fails(self):
        # a member that never leaves the owned job -> settled read stays > 0 at the deadline -> FAIL (fail closed).
        self.assertGreater(self._run_settled([1, 1, 1, 1, 1]), 0)

    def test_settled_late_appearing_member_fails_though_instant_read_passes(self):
        # CAUSAL row: the member is NOT enumerated at the instant (first read 0), so a single instant read
        # (the old code) PASSES; it appears during the window and persists, so the settled read (new code)
        # returns > 0 and FAILS. This is exactly the row an instant read would wrongly pass.
        counts = [0, 0, 1, 1, 1]
        self.assertEqual(counts[0], 0, "the instant/first read is 0 — the old single read would PASS")
        self.assertGreater(self._run_settled(counts), 0, "the settled read must FAIL the late-appearing member")

    # --- bounded run-dir cleanup oracles (RoseCat dfaf431: one absolute deadline, budget never renews) ---
    def test_bounded_cleanup_recovers_after_transient(self):
        # a post-kill image lock lingering PAST the old 20 s window still recovers within the 60 s deadline.
        clock = [0.0]
        budgets = []
        def step(budget):
            budgets.append(budget)
            clock[0] += 5.0            # each single remote op takes ~5 s
            return clock[0] >= 25.0    # the lock releases at ~25 s (beyond the old 20 s bound)
        ok = bounded_cleanup(lambda: clock[0], lambda s: clock.__setitem__(0, clock[0] + s), 60.0, step, poll_s=1.0)
        self.assertTrue(ok, "a transient failure beyond 20 s must still recover")
        self.assertLessEqual(clock[0], 60.0, "recovered within the absolute deadline")
        self.assertTrue(all(b <= 60.0 for b in budgets), "each op is capped to the remaining budget")

    def test_bounded_cleanup_fails_promptly_and_budget_never_renews(self):
        clock = [0.0]
        budgets = []
        def step(budget):
            budgets.append(budget)
            clock[0] += 5.0
            return False               # never gone
        ok = bounded_cleanup(lambda: clock[0], lambda s: clock.__setitem__(0, clock[0] + s), 60.0, step, poll_s=1.0)
        self.assertFalse(ok, "a never-removable dir must fail at the deadline")
        self.assertLess(clock[0], 75.0, "fails PROMPTLY at ~the deadline, not after hours (the 679bdac bug)")
        self.assertTrue(all(b <= 60.0 for b in budgets))
        self.assertTrue(all(budgets[i] >= budgets[i + 1] for i in range(len(budgets) - 1)),
                        "the budget strictly decreases — one absolute deadline, never renewed per-op")


if __name__ == "__main__":
    unittest.main()
