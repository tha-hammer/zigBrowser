param(
    [string]$Version = "0.1.0",
    [string]$SourceRoot = "",
    [string]$MsiPath = "",
    [string]$Url = "",
    [switch]$KeepInstalled
)

$ErrorActionPreference = "Stop"
$ProductCode = "{d4781018-6dc9-5c4d-80bc-1e5cb0de988e}"

function Resolve-SourceRoot {
    if ($SourceRoot) {
        return (Resolve-Path -LiteralPath $SourceRoot).Path
    }
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
}

function Invoke-Msi([string[]]$Arguments, [int[]]$AllowedExitCodes) {
    $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    if ($AllowedExitCodes -notcontains $proc.ExitCode) {
        throw "msiexec $($Arguments -join ' ') exited with $($proc.ExitCode)"
    }
    return $proc.ExitCode
}

function Get-MsiProductVersion([string]$Path) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($Path, 0)
    $view = $database.OpenView('SELECT `Value` FROM `Property` WHERE `Property`=''ProductVersion''')
    [void]$view.Execute()
    $record = $view.Fetch()
    $value = ([string]$record.StringData(1)) -replace '[^0-9.]', ''
    [void]$view.Close()
    return $value
}

function Test-NonUniformPng([string]$Path) {
    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::new($Path)
    try {
        $stepX = [Math]::Max(1, [int][Math]::Floor($bitmap.Width / 64.0))
        $stepY = [Math]::Max(1, [int][Math]::Floor($bitmap.Height / 64.0))
        $colors = [System.Collections.Generic.HashSet[string]]::new()
        $sum = 0.0
        $sumSq = 0.0
        $samples = 0
        for ($y = 0; $y -lt $bitmap.Height; $y += $stepY) {
            for ($x = 0; $x -lt $bitmap.Width; $x += $stepX) {
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
        return [pscustomobject]@{
            Width = $bitmap.Width
            Height = $bitmap.Height
            Samples = $samples
            Distinct = $colors.Count
            StdDev = $stddev
            NonUniform = ($stddev -ge 1.0 -and $colors.Count -ge 8)
        }
    }
    finally {
        $bitmap.Dispose()
    }
}

function Invoke-ScheduledTaskCommand([string[]]$Arguments, [switch]$IgnoreFailure) {
    & schtasks.exe @Arguments
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreFailure -and $exitCode -ne 0) {
        throw "schtasks $($Arguments -join ' ') exited with $exitCode"
    }
    return $exitCode
}

function Quote-PowerShellLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-InteractiveCapture([string]$Browser, [string]$TargetUrl, [string]$OutDir) {
    $capture = Join-Path $OutDir "msi-install-screenshot.png"
    $stdout = Join-Path $OutDir "browser.stdout.txt"
    $stderr = Join-Path $OutDir "browser.stderr.txt"
    $stats = Join-Path $OutDir "capture.json"
    $script = Join-Path $OutDir "capture.ps1"
    $runner = Join-Path $OutDir "run-capture-task.ps1"

    @'
param(
    [string]$Browser,
    [string]$Url,
    [string]$CapturePath,
    [string]$StdoutPath,
    [string]$StderrPath,
    [string]$StatsPath
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
$signature = @"
using System;
using System.Runtime.InteropServices;
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
public static class Win32Capture { [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect); }
"@
Add-Type -TypeDefinition $signature
$p = $null
$bitmap = $null
$graphics = $null
try {
    $p = Start-Process -FilePath $Browser -ArgumentList @($Url, '--print-title', '--e2e-protocol') -RedirectStandardOutput $StdoutPath -RedirectStandardError $StderrPath -PassThru
    for ($i = 0; $i -lt 80; $i += 1) {
        $p.Refresh()
        if ($p.HasExited) { throw "browser exited before capture: $($p.ExitCode)" }
        if ($p.MainWindowHandle -ne [IntPtr]::Zero -and (Test-Path $StdoutPath) -and ((Get-Content $StdoutPath -ErrorAction SilentlyContinue) -match '^NAV\t')) { break }
        Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Seconds 3
    $p.Refresh()
    if ($p.MainWindowHandle -eq [IntPtr]::Zero) { throw 'browser has no main window handle' }
    $rect = New-Object RECT
    if (-not [Win32Capture]::GetWindowRect($p.MainWindowHandle, [ref]$rect)) { throw 'GetWindowRect failed' }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 64 -or $height -lt 64) { throw "capture bounds too small: ${width}x${height}" }
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, [System.Drawing.Size]::new($width, $height))
    $bitmap.Save($CapturePath, [System.Drawing.Imaging.ImageFormat]::Png)
    [pscustomobject]@{ Path=$CapturePath; Width=$width; Height=$height; BrowserPid=$p.Id } | ConvertTo-Json -Compress | Set-Content -Path $StatsPath -Encoding UTF8
}
finally {
    if ($graphics) { $graphics.Dispose() }
    if ($bitmap) { $bitmap.Dispose() }
    if ($p -and -not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; [void]$p.WaitForExit(5000) }
}
'@ | Set-Content -LiteralPath $script -Encoding UTF8

    @(
        "& $(Quote-PowerShellLiteral $script) " +
            "-Browser $(Quote-PowerShellLiteral $Browser) " +
            "-Url $(Quote-PowerShellLiteral $TargetUrl) " +
            "-CapturePath $(Quote-PowerShellLiteral $capture) " +
            "-StdoutPath $(Quote-PowerShellLiteral $stdout) " +
            "-StderrPath $(Quote-PowerShellLiteral $stderr) " +
            "-StatsPath $(Quote-PowerShellLiteral $stats)"
    ) | Set-Content -LiteralPath $runner -Encoding UTF8

    $taskName = "zigBrowserSlice5Gate"
    Invoke-ScheduledTaskCommand @('/Delete', '/TN', $taskName, '/F') -IgnoreFailure | Out-Null
    $taskCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$runner`""
    Invoke-ScheduledTaskCommand @('/Create', '/TN', $taskName, '/TR', $taskCommand, '/SC', 'ONCE', '/ST', '23:59', '/IT', '/RL', 'HIGHEST', '/F') | Out-Null
    Invoke-ScheduledTaskCommand @('/Run', '/TN', $taskName) | Out-Null
    Start-Sleep -Seconds 16
    Invoke-ScheduledTaskCommand @('/Delete', '/TN', $taskName, '/F') -IgnoreFailure | Out-Null

    if (-not (Test-Path -LiteralPath $capture -PathType Leaf)) {
        $err = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
        throw "screenshot was not created. stderr=$err"
    }
    $pngStats = Test-NonUniformPng $capture
    if (-not $pngStats.NonUniform) {
        throw "screenshot is not non-uniform: $($pngStats | ConvertTo-Json -Compress)"
    }
    return [pscustomobject]@{
        Screenshot = $capture
        Png = $pngStats
        BrowserStdout = if (Test-Path -LiteralPath $stdout) { @(Get-Content -LiteralPath $stdout | ForEach-Object { [string]$_ }) } else { @() }
        BrowserStderr = if (Test-Path -LiteralPath $stderr) { @(Get-Content -LiteralPath $stderr | ForEach-Object { [string]$_ }) } else { @() }
    }
}

$root = Resolve-SourceRoot
if (-not $MsiPath) {
    $MsiPath = Join-Path $root "packaging\windows\dist\zigBrowser-$Version.msi"
}
$MsiPath = (Resolve-Path -LiteralPath $MsiPath).Path
if (-not $Url) {
    $fixture = ((Resolve-Path -LiteralPath (Join-Path $root "tests\fixtures\app\index.html")).Path -replace '\\', '/')
    $Url = "file:///$fixture"
}

$productVersion = Get-MsiProductVersion $MsiPath
if ($productVersion -ne $Version) {
    throw "MSI ProductVersion mismatch: expected $Version got $productVersion"
}

Invoke-Msi @('/x', $ProductCode, '/qn', '/norestart') @(0, 1605, 1614) | Out-Null
Invoke-Msi @('/i', $MsiPath, '/qn', '/norestart', 'MSIINSTALLPERUSER=1') @(0, 3010) | Out-Null

$installDir = Join-Path $env:LOCALAPPDATA "Programs\zigBrowser"
$installedExe = Join-Path $installDir "zigBrowser.exe"
if (-not (Test-Path -LiteralPath $installedExe -PathType Leaf)) {
    throw "installed exe missing: $installedExe"
}
$versionLine = (& $installedExe --version) -join "`n"
if ($versionLine -notmatch '^zigBrowser \(WebView2 .+\)$') {
    throw "installed --version did not report WebView2: $versionLine"
}

$startMenuShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\zigBrowser\zigBrowser.lnk"
$desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) "zigBrowser.lnk"
if (-not (Test-Path -LiteralPath $startMenuShortcut -PathType Leaf)) { throw "missing Start Menu shortcut: $startMenuShortcut" }
if (-not (Test-Path -LiteralPath $desktopShortcut -PathType Leaf)) { throw "missing Desktop shortcut: $desktopShortcut" }

$outDir = Join-Path $root "packaging\windows\dist"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$capture = Invoke-InteractiveCapture $installedExe $Url $outDir

$uninstallExit = $null
$removed = $false
if (-not $KeepInstalled) {
    $uninstallExit = Invoke-Msi @('/x', $ProductCode, '/qn', '/norestart') @(0, 3010)
    $removed = -not (Test-Path -LiteralPath $installedExe)
    if (-not $removed) { throw "installed exe still exists after uninstall: $installedExe" }
}

[pscustomobject]@{
    ProductVersion = $productVersion
    InstalledExe = $installedExe
    VersionLine = $versionLine
    StartMenuShortcut = $startMenuShortcut
    DesktopShortcut = $desktopShortcut
    Url = $Url
    Screenshot = $capture.Screenshot
    ScreenshotNonUniform = $capture.Png.NonUniform
    ScreenshotStats = $capture.Png
    BrowserStdout = $capture.BrowserStdout
    BrowserStderr = $capture.BrowserStderr
    FinalUninstallExit = $uninstallExit
    RemovedAfterUninstall = $removed
} | ConvertTo-Json -Depth 6 -Compress
