#!/usr/bin/env python3
"""M8 HW-gated E2E: Windows WebView2 renders the fixture in a real window."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import tempfile
from html.parser import HTMLParser
from pathlib import Path

from slice2_common import (
    SKIP_EXIT,
    RunResult,
    eprint,
    print_fail_context,
    require_file,
    run_windows_interactive_to_exit,
)


REQUIRED_ENV = "ZB_ENABLE_M8_E2E"

RENDER_CAPTURE_PS1 = r"""
param(
    [Parameter(Mandatory=$true)][string]$Browser,
    [Parameter(Mandatory=$true)][string]$Uri,
    [Parameter(Mandatory=$true)][string]$CapturePath,
    [Parameter(Mandatory=$true)][string]$BrowserStdoutPath,
    [Parameter(Mandatory=$true)][string]$BrowserStderrPath
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

function Ensure-Parent([string]$TargetPath) {
    $parent = [System.IO.Path]::GetDirectoryName($TargetPath)
    if ($parent) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
}

Ensure-Parent $CapturePath
Ensure-Parent $BrowserStdoutPath
Ensure-Parent $BrowserStderrPath

$browserArgs = @($Uri, "--e2e-protocol", "--print-title")
$proc = $null
$bitmap = $null
$graphics = $null

try {
    $proc = Start-Process -FilePath $Browser `
        -ArgumentList $browserArgs `
        -RedirectStandardOutput $BrowserStdoutPath `
        -RedirectStandardError $BrowserStderrPath `
        -PassThru

    for ($i = 0; $i -lt 50; $i += 1) {
        $proc.Refresh()
        if ($proc.HasExited) {
            throw "browser exited before window capture, exit=$($proc.ExitCode)"
        }
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            break
        }
        Start-Sleep -Milliseconds 100
    }

    Start-Sleep -Seconds 5
    $proc.Refresh()

    $left = 0
    $top = 0
    $width = 0
    $height = 0

    if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
        $rect = New-Object RECT
        if (-not [Win32Capture]::GetWindowRect($proc.MainWindowHandle, [ref]$rect)) {
            throw "GetWindowRect failed for process $($proc.Id)"
        }
        $left = $rect.Left
        $top = $rect.Top
        $width = $rect.Right - $rect.Left
        $height = $rect.Bottom - $rect.Top
    }
    else {
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $left = $bounds.Left
        $top = $bounds.Top
        $width = $bounds.Width
        $height = $bounds.Height
    }

    if ($width -lt 64 -or $height -lt 64) {
        throw "capture bounds are too small: ${width}x${height}"
    }

    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($left, $top, 0, 0, [System.Drawing.Size]::new($width, $height))

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
    $bitmap.Save($CapturePath, [System.Drawing.Imaging.ImageFormat]::Png)

    [pscustomobject]@{
        Path = $CapturePath
        Width = $width
        Height = $height
        Samples = $samples
        Distinct = $colors.Count
        StdDev = $stddev
        NonUniform = ($stddev -ge 1.0 -and $colors.Count -ge 8)
        BrowserPid = $proc.Id
    } | ConvertTo-Json -Compress
}
finally {
    if ($graphics) {
        $graphics.Dispose()
    }
    if ($bitmap) {
        $bitmap.Dispose()
    }
    if ($proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        try {
            [void]$proc.WaitForExit(5000)
        }
        catch {
        }
    }
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


def read_file_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").splitlines()
    except (FileNotFoundError, PermissionError, OSError):
        return []


def capture_render_png(
    browser: Path,
    uri: str,
    out_path: Path,
    timeout_sec: float,
) -> tuple[RunResult, dict[str, object] | None, str]:
    ps = powershell_exe()
    if ps is None:
        result = RunResult(1, [], ["PowerShell executable not found"], set())
        return result, None, "PowerShell executable not found"

    work_dir = Path(tempfile.mkdtemp(prefix="zigBrowser-m8-render-"))
    script_path = work_dir / "render_capture.ps1"
    browser_stdout_path = work_dir / "browser_stdout.txt"
    browser_stderr_path = work_dir / "browser_stderr.txt"
    script_path.write_text(RENDER_CAPTURE_PS1, encoding="utf-8")

    task_result = run_windows_interactive_to_exit(
        [
            ps,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script_path),
            "-Browser",
            str(browser),
            "-Uri",
            uri,
            "-CapturePath",
            str(out_path),
            "-BrowserStdoutPath",
            str(browser_stdout_path),
            "-BrowserStderrPath",
            str(browser_stderr_path),
        ],
        dict(os.environ),
        timeout_sec,
    )

    browser_stdout = read_file_lines(browser_stdout_path)
    browser_stderr = read_file_lines(browser_stderr_path)
    result = RunResult(
        returncode=task_result.returncode,
        stdout_lines=browser_stdout,
        stderr_lines=browser_stderr + task_result.stderr_lines,
        tracked_children=set(),
        timed_out=task_result.timed_out,
        pid=task_result.pid,
    )

    stats = None
    stats_error = ""
    for line in task_result.stdout_lines:
        if not line.startswith("{"):
            continue
        try:
            stats = json.loads(line)
            break
        except json.JSONDecodeError as exc:
            stats_error = f"invalid PowerShell capture stats: {exc}: {line!r}"

    if task_result.returncode != 0:
        error = "\n".join(result.stderr_lines).strip() or "\n".join(task_result.stdout_lines).strip()
        return result, stats, error or f"capture task exited {task_result.returncode}"
    if stats is None:
        return result, None, stats_error or f"missing PowerShell capture stats: {task_result.stdout_lines!r}"
    if not out_path.exists() or out_path.stat().st_size == 0:
        return result, stats, f"capture PNG was not written: {out_path}"
    if not stats.get("NonUniform"):
        return result, stats, f"capture is uniform or near-uniform: {stats}"
    return result, stats, ""


def title_observed(stdout_lines: list[str], expected_title: str) -> bool:
    return any(line == f"TITLE\t{expected_title}" for line in stdout_lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", "--browser", dest="binary", default=None)
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
    capture_path = Path(args.capture_path) if args.capture_path else Path(tempfile.gettempdir()) / "zigBrowser-m8-render.png"

    result, stats, capture_error = capture_render_png(browser, uri, capture_path, args.timeout_sec)
    if not title_observed(result.stdout_lines, expected_title):
        print("FAIL\tm8-render-title-not-observed")
        print_fail_context("m8-render-title-not-observed", result)
        return 1

    if capture_error:
        print("FAIL\tm8-render-capture")
        eprint(capture_error)
        if stats is not None:
            eprint(f"capture_stats={stats}")
        print_fail_context("m8-render-capture", result)
        return 1

    print(f"PASS\tm8-render-real-window\t{capture_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
