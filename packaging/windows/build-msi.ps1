param(
    [string]$Version = "0.1.0",
    [string]$WixDir = "C:\Users\maceo\WiX314",
    [string]$WebView2Include = "C:\Users\maceo\AppData\Local\zigBrowser-tools\nuget\Microsoft.Web.WebView2.1.0.3967.48\build\native\include",
    [string]$WebView2Lib = "C:\Users\maceo\AppData\Local\zigBrowser-tools\nuget\Microsoft.Web.WebView2.1.0.3967.48\build\native\x64",
    [string]$WinRtInclude = "C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\winrt",
    [string]$SourceRoot = "",
    [switch]$SkipZigBuild
)

$ErrorActionPreference = "Stop"

function Resolve-SourceRoot {
    if ($SourceRoot) {
        return (Resolve-Path -LiteralPath $SourceRoot).Path
    }
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
}

function Require-File([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing ${Label}: $Path"
    }
}

function Require-CommandPath([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Missing ${Label}: $Path"
    }
}

function Invoke-Checked([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory) {
    Write-Host "> $Exe $($Arguments -join ' ')"
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $Exe @Arguments
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($exitCode -ne 0) {
        throw "$Exe exited with $exitCode"
    }
}

function Get-MsiMetadata([string]$MsiPath) {
    $installer = New-Object -ComObject WindowsInstaller.Installer
    $database = $installer.OpenDatabase($MsiPath, 0)

    $versionView = $database.OpenView('SELECT `Value` FROM `Property` WHERE `Property`=''ProductVersion''')
    [void]$versionView.Execute()
    $versionRecord = $versionView.Fetch()
    $productVersion = ([string]$versionRecord.StringData(1)) -replace '[^0-9.]', ''
    [void]$versionView.Close()

    $files = @()
    $fileView = $database.OpenView('SELECT `File`, `FileName` FROM `File`')
    [void]$fileView.Execute()
    while ($true) {
        $record = $fileView.Fetch()
        if ($null -eq $record) { break }
        $files += [pscustomobject]@{
            File = $record.StringData(1)
            FileName = $record.StringData(2)
        }
    }
    [void]$fileView.Close()

    return [pscustomobject]@{
        ProductVersion = $productVersion
        Files = $files
    }
}

$root = Resolve-SourceRoot
$windowsDir = Join-Path $root "packaging\windows"
$assetsIcon = Join-Path $root "packaging\assets\zigBrowser.ico"
$fallbackIcon = Join-Path $windowsDir "zigBrowser-temp.ico"
$iconPath = if (Test-Path -LiteralPath $assetsIcon -PathType Leaf) { $assetsIcon } else { $fallbackIcon }
$bootstrapper = Join-Path $windowsDir "MicrosoftEdgeWebview2Setup.exe"
$wxs = Join-Path $windowsDir "zigBrowser.wxs"
$outDir = Join-Path $windowsDir "dist"
$wixObj = Join-Path $outDir "zigBrowser.wixobj"
$msi = Join-Path $outDir "zigBrowser-$Version.msi"
$candle = Join-Path $WixDir "candle.exe"
$light = Join-Path $WixDir "light.exe"

Require-CommandPath $candle "WiX candle.exe"
Require-CommandPath $light "WiX light.exe"
Require-File $wxs "WiX source"
Require-File $iconPath "installer icon"
Require-File $bootstrapper "WebView2 Evergreen bootstrapper"
Require-File (Join-Path $WebView2Include "WebView2.h") "WebView2.h"
Require-File (Join-Path $WebView2Lib "WebView2LoaderStatic.lib") "WebView2LoaderStatic.lib"
Require-File (Join-Path $WinRtInclude "wrl.h") "wrl.h"

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

if (-not $SkipZigBuild) {
    Get-Process -Name "zigBrowser" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $root "zig-out\bin\zigBrowser.exe") -Force -ErrorAction SilentlyContinue
    Invoke-Checked "zig" @(
        "build",
        "-Doptimize=ReleaseSafe",
        "-Dtarget=x86_64-windows-msvc",
        "-Dwebview2_include=$WebView2Include",
        "-Dwebview2_lib=$WebView2Lib",
        "-Dwinrt_include=$WinRtInclude"
    ) $root
}

$payloadDir = Join-Path $root "zig-out\bin"
$exe = Join-Path $payloadDir "zigBrowser.exe"
Require-File $exe "ReleaseSafe zigBrowser.exe"

Remove-Item -LiteralPath $wixObj,$msi -Force -ErrorAction SilentlyContinue
Invoke-Checked $candle @(
    "-nologo",
    "-dProductVersion=$Version",
    "-dPayloadDir=$payloadDir",
    "-dIconPath=$iconPath",
    "-dWebView2Bootstrapper=$bootstrapper",
    "-out", $wixObj,
    $wxs
) $root
Invoke-Checked $light @(
    "-nologo",
    "-ext", "WixUIExtension",
    "-out", $msi,
    $wixObj
) $root

Require-File $msi "MSI output"
$metadata = Get-MsiMetadata $msi
if ($metadata.ProductVersion -ne $Version) {
    throw "MSI ProductVersion mismatch: expected $Version, got $($metadata.ProductVersion)"
}
$fileNames = @($metadata.Files | ForEach-Object { $_.FileName })
if (-not ($fileNames -match "zigBrowser.exe")) {
    throw "MSI File table does not list zigBrowser.exe"
}
if (-not ($fileNames -match "MicrosoftEdgeWebview2Setup.exe")) {
    throw "MSI File table does not list MicrosoftEdgeWebview2Setup.exe"
}

$result = [pscustomobject]@{
    MsiPath = $msi
    ProductVersion = $metadata.ProductVersion
    Files = $metadata.Files
}
$result | ConvertTo-Json -Depth 5 -Compress
