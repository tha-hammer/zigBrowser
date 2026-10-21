param(
    [string]$RepoUrl = "",
    [string]$RepoPath = "$env:USERPROFILE\zigBrowser",
    [string]$ToolsRoot = "$env:LOCALAPPDATA\zigBrowser-tools",
    [string]$ZigVersion = "0.16.0",
    [string]$ZigUrl = "",
    [string]$WebView2PackageVersion = "",
    [switch]$SkipToolchainInstall,
    [switch]$SkipRepoSync
)

Set-StrictMode -Version Latest

# WS1.1 (bead zigBrowser-4dr): the ONE authoritative WebView2 SDK version this build pins. The NuGet
# install consumes it EXACTLY — there is no "latest" fallback. Keep in sync with the registered oracle
# tests/windows/pe_census_selftest.py (WebView2SdkPin), which fails if this drifts or is emptied.
$WebView2PinnedVersion = '1.0.3967.48'
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Add-UserPath {
    param([string]$Path)
    $current = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($current) {
        $parts = $current -split ";"
    }
    if ($parts -notcontains $Path) {
        $newPath = if ($current) { "$current;$Path" } else { $Path }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    }
    if (($env:Path -split ";") -notcontains $Path) {
        $env:Path = "$Path;$env:Path"
    }
}

function Get-WebView2RuntimeVersion {
    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}",
        "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
    )
    foreach ($key in $keys) {
        if (Test-Path -LiteralPath $key) {
            $props = Get-ItemProperty -LiteralPath $key
            if ($props.pv) {
                return $props.pv
            }
        }
    }
    return $null
}

function Enable-OpenSshServer {
    Write-Step "Ensuring OpenSSH Server is installed and running"
    if (-not (Test-Admin)) {
        throw "setup.ps1 must run from an elevated PowerShell session to enable OpenSSH Server"
    }

    $capabilityName = "OpenSSH.Server~~~~0.0.1.0"
    $capability = Get-WindowsCapability -Online -Name $capabilityName
    if ($capability.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $capabilityName | Out-Null
    }

    Set-Service -Name sshd -StartupType Automatic
    if ((Get-Service -Name sshd).Status -ne "Running") {
        Start-Service -Name sshd
    }

    $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if ($null -eq $rule) {
        New-NetFirewallRule `
            -Name "OpenSSH-Server-In-TCP" `
            -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True `
            -Direction Inbound `
            -Protocol TCP `
            -Action Allow `
            -LocalPort 22 | Out-Null
    }
}

function Install-Zig {
    Write-Step "Ensuring Zig $ZigVersion is installed"
    Ensure-Directory -Path $ToolsRoot
    $zigDir = Join-Path $ToolsRoot "zig-$ZigVersion"
    $zigExe = Join-Path $zigDir "zig.exe"

    if (Test-Path -LiteralPath $zigExe) {
        $installed = & $zigExe version
        if ($installed -eq $ZigVersion) {
            Add-UserPath -Path $zigDir
            return $zigExe
        }
    }

    $pathZig = Get-Command "zig.exe" -ErrorAction SilentlyContinue
    if ($null -ne $pathZig) {
        $installed = & $pathZig.Source version
        if ($installed -ne $ZigVersion) {
            Write-Warning "Using zig on PATH at $($pathZig.Source) with version $installed; requested $ZigVersion"
        }
        return $pathZig.Source
    }

    if (-not $ZigUrl) {
        $ZigUrl = "https://ziglang.org/download/$ZigVersion/zig-x86_64-windows-$ZigVersion.zip"
    }

    $archive = Join-Path $ToolsRoot "zig-$ZigVersion.zip"
    $extractRoot = Join-Path $ToolsRoot "zig-extract-$ZigVersion"
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    Ensure-Directory -Path $extractRoot

    Invoke-WebRequest -Uri $ZigUrl -OutFile $archive -UseBasicParsing
    Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot -Force

    $found = Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter "zig.exe" | Select-Object -First 1
    if ($null -eq $found) {
        throw "zig.exe was not found after expanding $archive"
    }

    $expandedDir = Split-Path -Parent $found.FullName
    if (Test-Path -LiteralPath $zigDir) {
        Remove-Item -LiteralPath $zigDir -Recurse -Force
    }
    Move-Item -LiteralPath $expandedDir -Destination $zigDir -Force
    Remove-Item -LiteralPath $extractRoot -Recurse -Force

    Add-UserPath -Path $zigDir
    return $zigExe
}

function Ensure-NuGet {
    Write-Step "Ensuring nuget.exe is available"
    Ensure-Directory -Path $ToolsRoot
    $nuget = Join-Path $ToolsRoot "nuget.exe"
    if (-not (Test-Path -LiteralPath $nuget)) {
        Invoke-WebRequest `
            -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" `
            -OutFile $nuget `
            -UseBasicParsing
    }
    return $nuget
}

function Install-WebView2Sdk {
    Write-Step "Ensuring Microsoft.Web.WebView2 NuGet SDK is installed"
    $nuget = Ensure-NuGet
    $packages = Join-Path $ToolsRoot "nuget"
    Ensure-Directory -Path $packages

    # The fetch ALWAYS uses the one authoritative pin. An explicit override is accepted only when it equals
    # the pin, otherwise it is refused — so the version actually fetched can never drift from the pin.
    if ($WebView2PackageVersion -and ($WebView2PackageVersion -ne $WebView2PinnedVersion)) {
        throw "WebView2PackageVersion '$WebView2PackageVersion' does not match the pinned $WebView2PinnedVersion"
    }
    $ver = $WebView2PinnedVersion
    $installArgs = @(
        "install",
        "Microsoft.Web.WebView2",
        "-Version", $ver,
        "-OutputDirectory",
        $packages,
        "-NonInteractive",
        "-Verbosity",
        "quiet"
    )
    & $nuget @installArgs

    # Select the EXACT pinned package directory, not merely the newest installed one.
    $packageDir = Get-ChildItem -LiteralPath $packages -Directory |
        Where-Object { $_.Name -ieq "Microsoft.Web.WebView2.$ver" } |
        Select-Object -First 1
    if ($null -eq $packageDir) {
        throw "Microsoft.Web.WebView2.$ver package was not installed under $packages"
    }

    $includeDir = Join-Path $packageDir.FullName "build\native\include"
    $loaderLibNames = @("WebView2Loader.lib", "WebView2Loader.dll.lib", "WebView2LoaderStatic.lib")
    $loaderLib = Get-ChildItem -LiteralPath $packageDir.FullName -Recurse -File |
        Where-Object {
            $loaderLibNames -contains $_.Name -and
            ($_.FullName -match "\\x64\\" -or $_.FullName -match "\\build\\native\\x64\\")
        } |
        Sort-Object @{
            Expression = {
                switch ($_.Name) {
                    "WebView2Loader.lib" { 0 }
                    "WebView2Loader.dll.lib" { 1 }
                    "WebView2LoaderStatic.lib" { 2 }
                    default { 3 }
                }
            }
        } |
        Select-Object -First 1
    $loaderDll = Get-ChildItem -LiteralPath $packageDir.FullName -Recurse -Filter "WebView2Loader.dll" |
        Where-Object { $_.FullName -match "\\x64\\" } |
        Select-Object -First 1

    if (-not (Test-Path -LiteralPath (Join-Path $includeDir "WebView2.h"))) {
        throw "WebView2.h not found under $includeDir"
    }
    if ($null -eq $loaderLib) {
        throw "WebView2Loader import library not found under $($packageDir.FullName); expected one of: $($loaderLibNames -join ', ')"
    }

    $libDir = Split-Path -Parent $loaderLib.FullName
    [Environment]::SetEnvironmentVariable("WEBVIEW2_INCLUDE", $includeDir, "User")
    [Environment]::SetEnvironmentVariable("WEBVIEW2_LIB", $libDir, "User")
    [Environment]::SetEnvironmentVariable("WEBVIEW2_LOADER_LIB", $loaderLib.FullName, "User")
    $env:WEBVIEW2_INCLUDE = $includeDir
    $env:WEBVIEW2_LIB = $libDir
    $env:WEBVIEW2_LOADER_LIB = $loaderLib.FullName

    if ($null -ne $loaderDll) {
        [Environment]::SetEnvironmentVariable("WEBVIEW2_LOADER_DLL", $loaderDll.FullName, "User")
        $env:WEBVIEW2_LOADER_DLL = $loaderDll.FullName
    }

    return [pscustomobject]@{
        Include = $includeDir
        Lib = $libDir
        LoaderLib = $loaderLib.FullName
        LoaderDll = if ($null -ne $loaderDll) { $loaderDll.FullName } else { "" }
    }
}

function Get-VsWhere {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }
    return $null
}

function Get-WindowsKitsRoots {
    $roots = @()
    if ($env:WindowsSdkDir) {
        $roots += $env:WindowsSdkDir
    }
    $roots += "C:\Program Files (x86)\Windows Kits\10"

    $sdkKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots"
    )
    foreach ($key in $sdkKeys) {
        if (Test-Path -LiteralPath $key) {
            $props = Get-ItemProperty -LiteralPath $key
            if ($props.KitsRoot10) {
                $roots += $props.KitsRoot10
            }
        }
    }
    return ($roots | Where-Object { $_ } | Select-Object -Unique)
}

function Get-WindowsSdkInfo {
    foreach ($root in (Get-WindowsKitsRoots)) {
        $includeRoot = Join-Path $root "Include"
        if (-not (Test-Path -LiteralPath $includeRoot)) {
            continue
        }

        $versions = Get-ChildItem -LiteralPath $includeRoot -Directory |
            Sort-Object -Property @{
                Expression = {
                    try {
                        [version]$_.Name
                    } catch {
                        [version]"0.0.0.0"
                    }
                }
                Descending = $true
            }
        foreach ($version in $versions) {
            $eventToken = Join-Path $version.FullName "um\EventToken.h"
            $winrtInclude = Join-Path $version.FullName "winrt"
            $wrl = Join-Path $winrtInclude "wrl.h"
            if ((Test-Path -LiteralPath $eventToken) -and (Test-Path -LiteralPath $wrl)) {
                return [pscustomobject]@{
                    Root = $root
                    Version = $version.Name
                    EventToken = $eventToken
                    WinrtInclude = $winrtInclude
                    Wrl = $wrl
                }
            }
        }
    }
    return $null
}

function Set-WinrtIncludeEnvironment {
    param([object]$Sdk)
    [Environment]::SetEnvironmentVariable("WINRT_INCLUDE", $Sdk.WinrtInclude, "User")
    $env:WINRT_INCLUDE = $Sdk.WinrtInclude
}

function Get-MsvcBuildToolsInstall {
    $vswhere = Get-VsWhere
    if (-not $vswhere) {
        return $null
    }

    $install = & $vswhere `
        -latest `
        -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if ($install) {
        return ($install | Select-Object -First 1)
    }
    return $null
}

function Test-CppToolchain {
    $vsInstall = Get-MsvcBuildToolsInstall
    $sdk = Get-WindowsSdkInfo
    if ($vsInstall -and $sdk) {
        return [pscustomobject]@{
            VsInstall = $vsInstall
            Sdk = $sdk
            Summary = "MSVC Build Tools at $vsInstall; Windows SDK $($sdk.Version)"
        }
    }
    return $null
}

function Install-CppToolchain {
    Write-Step "Ensuring MSVC Build Tools and Windows 11 SDK 22621 are installed"
    $existing = Test-CppToolchain
    if ($existing) {
        Set-WinrtIncludeEnvironment -Sdk $existing.Sdk
        Write-Host "C/C++ toolchain found: $($existing.Summary)"
        return $existing
    }
    if ($SkipToolchainInstall) {
        throw "MSVC Build Tools with VC tools and Windows 11 SDK 22621 not found, and -SkipToolchainInstall was set"
    }

    $winget = Get-Command "winget.exe" -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw "MSVC Build Tools and Windows 11 SDK 22621 not found, and winget.exe is unavailable. Install Visual Studio Build Tools with VC tools and Windows11SDK.22621, then rerun setup.ps1."
    }

    & $winget.Source install `
        --id Microsoft.VisualStudio.2022.BuildTools `
        --source winget `
        --silent `
        --accept-package-agreements `
        --accept-source-agreements `
        --override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --includeRecommended"

    $installed = Test-CppToolchain
    if (-not $installed) {
        throw "Build Tools install completed, but MSVC VC tools plus a Windows SDK with um\EventToken.h and winrt\wrl.h were not detected. Open a new PowerShell or verify Visual Studio Build Tools installation."
    }
    Set-WinrtIncludeEnvironment -Sdk $installed.Sdk
    Write-Host "C/C++ toolchain installed: $($installed.Summary)"
    return $installed
}

function Sync-Repo {
    if ($SkipRepoSync) {
        Write-Step "Skipping repo sync by request"
        return
    }

    Write-Step "Ensuring repository checkout at $RepoPath"
    $git = Get-Command "git.exe" -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        Write-Warning "git.exe is not installed; skipping repo sync"
        return
    }

    if (Test-Path -LiteralPath (Join-Path $RepoPath ".git")) {
        & $git.Source -C $RepoPath fetch --all --prune
        & $git.Source -C $RepoPath pull --ff-only
        return
    }

    if (-not $RepoUrl) {
        Write-Warning "RepoPath does not contain a git checkout and -RepoUrl was not provided; skipping clone"
        return
    }

    Ensure-Directory -Path (Split-Path -Parent $RepoPath)
    & $git.Source clone $RepoUrl $RepoPath
}

Enable-OpenSshServer
$zig = Install-Zig
$webview2 = Install-WebView2Sdk
$toolchain = Install-CppToolchain
Sync-Repo

$runtimeVersion = Get-WebView2RuntimeVersion
Write-Step "Provisioning summary"
Write-Host "zig=$zig"
Write-Host "zig_version=$(& $zig version)"
Write-Host "WEBVIEW2_INCLUDE=$($webview2.Include)"
Write-Host "WEBVIEW2_LIB=$($webview2.Lib)"
Write-Host "WEBVIEW2_LOADER_LIB=$($webview2.LoaderLib)"
Write-Host "WINRT_INCLUDE=$($toolchain.Sdk.WinrtInclude)"
if ($webview2.LoaderDll) {
    Write-Host "WEBVIEW2_LOADER_DLL=$($webview2.LoaderDll)"
}
if ($runtimeVersion) {
    Write-Host "webview2_runtime=$runtimeVersion"
} else {
    Write-Warning "WebView2 Runtime version was not found in the EdgeUpdate registry keys"
}
Write-Host "repo=$RepoPath"
