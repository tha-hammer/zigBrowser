#!/usr/bin/env bash
# WS1 build driver — build the Windows release exe on the Win11 VM over SSH (MSVC target) from a CLEAN,
# EXACT source tree and fetch the artifact to Linux for the WS1.1 PE census. Generalizes build-in-guest.sh.
#
# Hardened per RoseCat's review of defb5a2 (findings 1-6); pinned by tests/windows/build_on_windows_selftest.py:
#   1. CLEAN/EXACT source — stage `git archive` of an explicit, verified commit (tracked files only; no
#      uncommitted/untracked/stale content) into a FRESH per-SHA remote directory, re-created each run.
#   2. NO remote injection — `step` and `mode` are validated against strict grammars; the build command is
#      sent as a base64 `-EncodedCommand` with every value embedded as a PowerShell single-quoted literal,
#      so no caller value is ever parsed by cmd.exe / PowerShell as a metacharacter.
#   4. Outer deadlines — stage/build/fetch each run under an explicit `timeout`, bounding a stalled-but-
#      connected operation (ssh ConnectTimeout only bounds connection setup).
#   5. Fail-closed startup — `set -euo pipefail`; the repo root is resolved and validated before any cd, so a
#      failed git/cd can never leave the script operating in the caller's directory.
#   6. Atomic fetch — the exe is fetched to a `.part` file, validated (non-empty + PE `MZ` magic), then
#      renamed; a failed fetch leaves no artifact. Provenance (`<out>.sha`) records the exact commit.
#   (3 — hermetic selftest — is the registered build_on_windows_selftest.py, driving this against fakes.)
#
# WS0.3/0.8 transport hygiene: pinned host key, BatchMode, ConnectTimeout, and every child that reaches the
# guest is display-scrubbed (no DISPLAY/WAYLAND/XAUTHORITY leaves Linux). A plain build is not a gate run, so
# this needs no Linux slot; the build itself runs remotely on the VM.
#
# LIVE-VERIFY PENDING: zig + the WebView2 SDK must be made readable/executable by zbtext first (bead
# zigBrowser-4dr); MSVC (VS18 BuildTools) and the Windows SDK are already machine-wide.
#
# Usage:
#   ZB_ZIG=... ZB_WEBVIEW2_INCLUDE=... ZB_WEBVIEW2_LIB=... bash tests/windows/build-on-windows.sh
#   ZB_BUILD_COMMIT=<ref> bash tests/windows/build-on-windows.sh           # a specific commit (default HEAD)
#   bash tests/windows/build-on-windows.sh ipc-test-win                    # a specific build step
#
# NOTE: `set -e` is deliberately NOT used — every command below is checked explicitly (so PIPESTATUS/$? can
# be captured and the failure named), and the root is resolved+validated before any cd, which is the actual
# fail-closed-startup fix for finding 5.
set -uo pipefail

# Finding 5: resolve + validate the repo root explicitly; never operate from the caller's cwd on failure.
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "build-on-windows: not inside a git repo" >&2; exit 2; }
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "build-on-windows: cannot resolve repo root" >&2; exit 2; }
cd "$ROOT" || { echo "build-on-windows: cannot cd to repo root $ROOT" >&2; exit 2; }

host="${ZB_WIN11_HOST:?set ZB_WIN11_HOST (see tests/windows/hosts.env)}"
port="${ZB_WIN11_PORT:-2222}"
user="${ZB_WIN11_USER:-zbtext}"
key="${ZB_WIN_KEY:-/home/maceo/vms/win11-m8/zb_win_key}"
kh="${ZB_WIN_KNOWN_HOSTS:-/home/maceo/vms/win11-m8/known_hosts}"
zig="${ZB_ZIG:-zig}"                               # zig.exe on the host (once zbtext can run it)
inc="${ZB_WEBVIEW2_INCLUDE:?set ZB_WEBVIEW2_INCLUDE (WebView2 SDK include dir on the host)}"
lib="${ZB_WEBVIEW2_LIB:?set ZB_WEBVIEW2_LIB (WebView2 SDK x64 lib dir on the host)}"
winrt="${ZB_WINRT_INCLUDE:-C:\\Program Files (x86)\\Windows Kits\\10\\Include\\10.0.26100.0\\winrt}"
mode="${ZB_BUILD_MODE:-ReleaseSafe}"
commit="${ZB_BUILD_COMMIT:-HEAD}"
step="${1:-}"

# Finding 2: validate the free-form inputs against strict grammars BEFORE they can reach a remote command.
case "$mode" in
  Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;;
  *) echo "build-on-windows: invalid -Doptimize mode: $mode" >&2; exit 2 ;;
esac
if [ -n "$step" ] && ! printf '%s' "$step" | grep -Eq '^[A-Za-z][A-Za-z0-9_-]*$'; then
  echo "build-on-windows: invalid build step name: $step" >&2; exit 2
fi
# Finding 1: resolve the commit to a full, verified SHA (fail closed if unknown) — identity for the run dir.
sha=$(git rev-parse --verify "${commit}^{commit}" 2>/dev/null) || {
  echo "build-on-windows: cannot resolve commit: $commit" >&2; exit 2; }

SSH=(-i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$kh"
     -o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=3)
scrub=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY)

# Finding 4: explicit outer deadlines (seconds) so a connected-but-stalled op cannot hang forever.
stage_to=${ZB_STAGE_TIMEOUT:-300}
build_to=${ZB_BUILD_TIMEOUT:-1800}
fetch_to=${ZB_FETCH_TIMEOUT:-300}

# Finding 1: a FRESH per-run directory named by the exact SHA — no stale/dirty/deleted file can survive.
rundir="zb/build/run-$sha"
remote_rundir="zb\\build\\run-$sha"

# ---- stage: git archive of the exact commit (tracked files only) into a fresh remote run dir ------------
echo "build-on-windows: staging CLEAN tree of $sha to $user@$host:$remote_rundir" >&2
"${scrub[@]}" git archive --format=tar "$sha" \
  | "${scrub[@]}" timeout "$stage_to" ssh "${SSH[@]}" -p "$port" "$user@$host" \
      "cmd /c \"if exist %USERPROFILE%\\$remote_rundir rmdir /s /q %USERPROFILE%\\$remote_rundir\" & cmd /c \"mkdir %USERPROFILE%\\$remote_rundir\" & cd $remote_rundir && tar -x -f -"
rc_arch=${PIPESTATUS[0]} rc_stage=${PIPESTATUS[1]}
[ "$rc_arch" -eq 0 ] || { echo "build-on-windows: git archive failed (rc=$rc_arch)" >&2; exit "$rc_arch"; }
[ "$rc_stage" -eq 0 ] || { echo "build-on-windows: stage failed (rc=$rc_stage)" >&2; exit "$rc_stage"; }

# ---- build: a base64 -EncodedCommand; values embedded as PowerShell single-quoted literals (no injection) -
psq() { printf "%s" "$1" | sed "s/'/''/g"; }   # PowerShell single-quote escaping
build_ps=$(cat <<PS
\$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Join-Path \$env:USERPROFILE '$remote_rundir')
& '$(psq "$zig")' build $step '-Dtarget=x86_64-windows-msvc' '-Doptimize=$mode' '-Dwebview2_include=$(psq "$inc")' '-Dwebview2_lib=$(psq "$lib")' '-Dwinrt_include=$(psq "$winrt")'
exit \$LASTEXITCODE
PS
)
enc=$(printf '%s' "$build_ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
echo "build-on-windows: zig build $step -Doptimize=$mode (target x86_64-windows-msvc) on $sha" >&2
"${scrub[@]}" timeout "$build_to" ssh "${SSH[@]}" -p "$port" "$user@$host" \
  "powershell -NoProfile -NonInteractive -EncodedCommand $enc"
rc=$?
[ "$rc" -eq 0 ] || { echo "build-on-windows: build failed (rc=$rc)" >&2; exit "$rc"; }

# ---- fetch: atomic + validated; provenance recorded (findings 1 & 6) -----------------------------------
# With no explicit step, fetch the built exe to Linux for the WS1.1 census (export ZB_WIN_EXE to it).
if [ -z "$step" ]; then
  out="${ZB_WIN_EXE:-zig-out/win/zigBrowser.exe}"
  mkdir -p "$(dirname "$out")"
  part="$out.part"
  rm -f "$part"
  "${scrub[@]}" timeout "$fetch_to" scp -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$kh" -o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=3 -P "$port" \
    "$user@$host:$rundir/zig-out/bin/zigBrowser.exe" "$part"
  rc=$?
  if [ "$rc" -ne 0 ]; then echo "build-on-windows: fetch failed (rc=$rc)" >&2; rm -f "$part"; exit "$rc"; fi
  # Validate before publishing: non-empty and a real PE (DOS 'MZ' magic). Anything else is a failed build.
  if [ ! -s "$part" ] || [ "$(head -c2 "$part" 2>/dev/null)" != "MZ" ]; then
    echo "build-on-windows: fetched artifact is not a PE executable" >&2; rm -f "$part"; exit 3
  fi
  mv -f "$part" "$out"
  printf '%s\n' "$sha" > "$out.sha"            # provenance: the census artifact's exact source commit
  echo "build-on-windows: fetched $out (commit $sha)"
  echo "build-on-windows: export ZB_WIN_EXE=$out for the WS1.1 census"
fi
