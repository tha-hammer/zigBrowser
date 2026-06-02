#!/usr/bin/env python3
"""M8 HW-gated E2E: Windows WebView2 renders the fixture in a real window."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import tempfile
from html.parser import HTMLParser
from pathlib import Path

from slice2_common import (
    SKIP_EXIT,
    assert_children_exit,
    eprint,
    print_fail_context,
    protocol_rows,
    require_file,
    run_interactive_until,
)


REQUIRED_ENV = "ZB_ENABLE_M8_E2E"

CAPTURE_WINDOW_PS1 = r"""
param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][int]$Pid
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$signature = @"
using System;
using System.Runtime.InteropServices;

public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

public static class Win32Capture {
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
}
"@
Add-Type -TypeDefinition $signature

$proc = Get-Process -Id $Pid -ErrorAction Stop
$handle = $proc.MainWindowHandle
if ($handle -eq [IntPtr]::Zero) {
    throw "process $Pid has no main window handle"
}

$rect = New-Object RECT
if (-not [Win32Capture]::GetWindowRect($handle, [ref]$rect)) {
    throw "GetWindowRect failed for process $Pid"
}

$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top
if ($width -lt 64 -or $height -lt 64) {
    throw "window capture bounds are too small: ${width}x${height}"
}

$parent = [System.IO.Path]::GetDirectoryName($Path)
if ($parent) {
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
}

$bitmap = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, [System.Drawing.Size]::new($width, $height))

    $stepX = [Math]::Max(1, [int][Math]::Floor($width / 64.0))
    $stepY = [Math]::Max(1, [int][Math]::Floor($height / 64.0))
    $colors = [System.Collections.Generic.HashSet[string]]::new()
    $sum = 0.0
    $sumSq = 0.0
    $samples = 0

    for ($y = 0; $y -lt $height; $y += $stepY) {
        for ($x = 0; $x -lt $width; $x += $stepX) {
            $pixel = $bitmap.GetPixel($x, $y)
            [void]$colors.Add("$($pixel.R),$($pixel.G),$($pixel.B),$($pixel.A)")
            $lum = (0.2126 * $pixel.R) + (0.7152 * $pixel.G) + (0.0722 * $pixel.B)
            $sum += $lum
            $sumSq += $lum * $lum
            $samples += 1
        }
    }

    $mean = $sum / $samples
    $variance = [Math]::Max(0.0, ($sumSq / $samples) - ($mean * $mean))
    $stddev = [Math]::Sqrt($variance)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)

    [pscustomobject]@{
        Path = $Path
        Width = $width
        Height = $height
        Samples = $samples
        Distinct = $colors.Count
        StdDev = $stddev
        NonUniform = ($stddev -ge 1.0 -and $colors.Count -ge 8)
    } | ConvertTo-Json -Compress
}
finally {
    $graphics.Dispose()
    $bitmap.Dispose()
}
"""


class TitleParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self._in_title = False
        self.parts: list[str] = []

    def handle_starttag(self, tag: str, attrs) -> None:
        if tag.lower() == "title":
            self._in_title = True

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "title":
            self._in_title = False

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.parts.append(data)

    @property
    def title(self) -> str:
        return "".join(self.parts).strip()


def hw_gate_ready() -> tuple[bool, str]:
    if platform.system() != "Windows":
        return False, "SKIP: M8 is Windows-only"
    if os.environ.get(REQUIRED_ENV) != "1":
        return False, f"SKIP: set {REQUIRED_ENV}=1 to run M8 HW-gated E2E"
    return True, "ok"


def default_binary() -> str:
    return "zig-out/bin/zigBrowser.exe" if platform.system() == "Windows" else "zig-out/bin/zigBrowser"


def fixture_title(index: Path) -> str:
    parser = TitleParser()
    parser.feed(index.read_text(encoding="utf-8"))
    if not parser.title:
        raise ValueError(f"missing <title> in {index}")
    return parser.title


def powershell_exe() -> str | None:
    return shutil.which("powershell.exe") or shutil.which("powershell") or shutil.which("pwsh")


def capture_window_png(pid: int, out_path: Path) -> tuple[bool, dict[str, object] | None, str]:
    ps = powershell_exe()
    if ps is None:
        return False, None, "PowerShell executable not found"

    script_path = out_path.with_suffix(".capture.ps1")
    script_path.write_text(CAPTURE_WINDOW_PS1, encoding="utf-8")
    result = subprocess.run(
        [
            ps,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script_path),
            "-Path",
            str(out_path),
            "-Pid",
            str(pid),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        return False, None, (result.stderr.strip() or result.stdout.strip())

    try:
        stats = json.loads(result.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError) as exc:
        return False, None, f"invalid PowerShell capture stats: {exc}: {result.stdout!r}"

    if not out_path.exists() or out_path.stat().st_size == 0:
        return False, stats, f"capture PNG was not written: {out_path}"
    if not stats.get("NonUniform"):
        return False, stats, f"capture is uniform or near-uniform: {stats}"
    return True, stats, ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default=None)
    parser.add_argument("--index", default="tests/fixtures/app/index.html")
    parser.add_argument("--timeout-sec", type=float, default=35.0)
    parser.add_argument("--capture-path", default=None)
    args = parser.parse_args()

    enabled, reason = hw_gate_ready()
    if not enabled:
        eprint(reason)
        return SKIP_EXIT

    browser = Path(args.binary or default_binary())
    index = Path(args.index)
    if not require_file(browser, "binary") or not require_file(index, "app index"):
        return SKIP_EXIT

    try:
        expected_title = fixture_title(index)
    except ValueError as exc:
        eprint(f"SKIP: {exc}")
        return SKIP_EXIT

    uri = index.resolve().as_uri()
    cmd = [str(browser), uri, "--e2e-protocol", "--print-title"]
    env = dict(os.environ)
    capture_path = Path(args.capture_path) if args.capture_path else Path(tempfile.gettempdir()) / "zigBrowser-m8-render.png"
    state: dict[str, object] = {
        "captured": False,
        "capture_error": "",
        "capture_stats": None,
    }

    def saw_render_evidence(stdout_lines: list[str]) -> bool:
        title_ok = any(line == f"TITLE\t{expected_title}" for line in stdout_lines)
        nav_ok = any(
            len(row) == 3 and row[1] == uri and row[2] == expected_title
            for row in protocol_rows(stdout_lines, "NAV")
        )
        return title_ok and nav_ok

    def on_tick(stdout_lines: list[str], _stderr: list[str], proc) -> None:
        if state["captured"] or state["capture_error"]:
            return
        if not saw_render_evidence(stdout_lines):
            return
        ok, stats, error = capture_window_png(proc.pid, capture_path)
        state["captured"] = ok
        state["capture_stats"] = stats
        state["capture_error"] = error

    def condition(stdout_lines: list[str], _stderr: list[str], _proc) -> bool:
        return bool(state["captured"] or state["capture_error"]) and saw_render_evidence(stdout_lines)

    matched, result = run_interactive_until(cmd, env, args.timeout_sec, condition, on_tick=on_tick)
    if not matched or not saw_render_evidence(result.stdout_lines):
        print("FAIL\tm8-render-title-or-nav-not-observed")
        print_fail_context("m8-render-title-or-nav-not-observed", result)
        return 1

    if not state["captured"]:
        print("FAIL\tm8-render-capture")
        eprint(str(state["capture_error"]))
        if state["capture_stats"] is not None:
            eprint(f"capture_stats={state['capture_stats']}")
        print_fail_context("m8-render-capture", result)
        return 1

    ok_children, alive = assert_children_exit(result.tracked_children, 4.0)
    ok_exit = result.returncode in (0, 1, 130)
    if not ok_exit or not ok_children:
        print("FAIL\tm8-render-clean-quit")
        if not ok_children:
            eprint(f"alive_children={alive}")
        print_fail_context("m8-render-clean-quit", result)
        return 1

    print(f"PASS\tm8-render-real-window\t{capture_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
