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
# TOOLCHAIN (bead zigBrowser-4dr, option B): zig 0.16.0 and the WebView2 SDK nuget are installed
# machine-wide under C:\tools (readable+executable by all users), so zig/include/lib default to that
# layout (see below) and need no per-run env. MSVC (VS18 BuildTools) and the Windows SDK are already
# machine-wide. LIVE-VERIFY PENDING: the user runs the C:\tools install on the VM console as admin (the
# exact PowerShell is in the session morning-brief); then this driver builds without ZB_ZIG/ZB_WEBVIEW2_*.
#
# Usage (machine-wide install: no toolchain env needed):
#   bash tests/windows/build-on-windows.sh                                 # defaults to C:\tools layout
#   ZB_ZIG=... ZB_WEBVIEW2_INCLUDE=... ZB_WEBVIEW2_LIB=... bash tests/windows/build-on-windows.sh  # override
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
# bead zigBrowser-4dr (option B): zig 0.16.0 and the WebView2 SDK nuget are installed MACHINE-WIDE under
# C:\tools (readable+executable by all users), so these default to the known layout; override only for an
# off-standard host. zig => C:\tools\zig\zig.exe; the WebView2 nuget unzips to C:\tools\webview2 with its
# headers at build\native\include and its x64 import libs at build\native\x64.
zig="${ZB_ZIG:-C:\\tools\\zig\\zig.exe}"
inc="${ZB_WEBVIEW2_INCLUDE:-C:\\tools\\webview2\\build\\native\\include}"
lib="${ZB_WEBVIEW2_LIB:-C:\\tools\\webview2\\build\\native\\x64}"
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
# Exclude thoughts/ — it holds git symlinks (thoughts/global|maceo|shared) that Windows tar cannot create
# ("Invalid argument"), and it is docs, never a build input. Everything the build needs stays in the archive.
"${scrub[@]}" git archive --format=tar "$sha" -- . ':(exclude)thoughts' \
  | "${scrub[@]}" timeout "$stage_to" ssh "${SSH[@]}" -p "$port" "$user@$host" \
      "cmd /c \"if exist %USERPROFILE%\\$remote_rundir rmdir /s /q %USERPROFILE%\\$remote_rundir\" && cmd /c \"mkdir %USERPROFILE%\\$remote_rundir\" && cd $remote_rundir && tar -x -f -"
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
# Finding (b): the encode must be CHECKED — pipefail surfaces an iconv/base64 failure in the command
# substitution, and an empty result is rejected, so a failed/partial encode can never be sent as an
# (empty) -EncodedCommand that the remote would run as a no-op "successful" build.
if ! enc=$(printf '%s' "$build_ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0) || [ -z "$enc" ]; then
  echo "build-on-windows: failed to construct/encode the build command" >&2; exit 2
fi
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
  # RoseCat 9dfc9c7: publish the {exe, provenance} pair atomically with NO two-name step and NO set -e.
  # The SINGLE consumer surface is $outdir/current/<base> (+ .sha). Each run gets a FRESH IMMUTABLE
  # generation dir (gen/g-<sha>-<utc>-<pid>, unique even for a same-SHA rerun), the complete pair is moved
  # in with one rename, and the only live mutation is ONE atomic 'current' symlink swap. Before the swap the
  # old generation current points at is untouched; after it, the new one. Every ln/mv is checked (the script
  # runs without set -e), and every recursive delete is guarded (prefix-validated + ${var:?}, never empty).
  outdir=$(dirname "$out"); outbase=$(basename "$out")
  if ! printf '%s\n' "$sha" > "$part.sha"; then
    echo "build-on-windows: provenance write failed" >&2; rm -f -- "$part" "$part.sha"; exit 3
  fi
  if ! mkdir -p "$outdir/gen"; then
    echo "build-on-windows: cannot create the generations dir" >&2; rm -f -- "$part" "$part.sha"; exit 3
  fi
  gen="g-${sha}-$(date -u +%Y%m%d%H%M%SZ)-$$"
  genrel="gen/$gen"; gendir="$outdir/$genrel"; stagedir="$outdir/.pub.$gen"
  # Guarded cleanup of our OWN unique scratch (prefix-validated, non-empty, must exist).
  for d in "$stagedir" "$gendir"; do
    if [ -n "$d" ] && { [[ "$d" == "$outdir"/.pub.g-* ]] || [[ "$d" == "$outdir"/gen/g-* ]]; } && [ -e "$d" ]; then
      rm -rf -- "${d:?}"
    fi
  done
  if ! mkdir -p "$stagedir"; then
    echo "build-on-windows: cannot create the staging dir" >&2
    if [ -n "$stagedir" ] && [[ "$stagedir" == "$outdir"/.pub.g-* ]] && [ -e "$stagedir" ]; then rm -rf -- "${stagedir:?}"; fi
    rm -f -- "$part" "$part.sha"; exit 3
  fi
  if ! mv -fT "$part" "$stagedir/$outbase" || ! mv -fT "$part.sha" "$stagedir/$outbase.sha"; then
    echo "build-on-windows: assembling the generation pair failed" >&2
    if [ -n "$stagedir" ] && [[ "$stagedir" == "$outdir"/.pub.g-* ]] && [ -e "$stagedir" ]; then rm -rf -- "${stagedir:?}"; fi
    rm -f -- "$part" "$part.sha"; exit 3
  fi
  if ! mv -fT "$stagedir" "$gendir"; then
    echo "build-on-windows: publishing the generation failed" >&2
    if [ -n "$stagedir" ] && [[ "$stagedir" == "$outdir"/.pub.g-* ]] && [ -e "$stagedir" ]; then rm -rf -- "${stagedir:?}"; fi
    exit 3
  fi
  # Selftest-only: model a crash AFTER the generation exists but BEFORE the atomic current-swap. NEVER set
  # in production. The old generation (if any) still owns 'current', so the surface is an intact old pair.
  if [ -n "${ZB_SELFTEST_CUT_PUBLISH:-}" ]; then
    echo "build-on-windows: interrupted before current-swap (selftest)" >&2; exit 42
  fi
  # Atomic commit: point 'current' at the new generation with a single symlink rename. Each step checked.
  if ! ln -sfn "$genrel" "$outdir/.current.$gen"; then
    echo "build-on-windows: staging the current symlink failed" >&2; rm -f -- "$outdir/.current.$gen"; exit 3
  fi
  # The swap is CHECKED (the script runs without set -e): a failed rename must NOT report success.
  if ! mv -fT "$outdir/.current.$gen" "$outdir/current"; then
    echo "build-on-windows: current-swap failed" >&2; rm -f -- "$outdir/.current.$gen"; exit 3
  fi
  # Post-swap: reap only UNREACHABLE generations — never the one 'current' now points at. Guarded deletes.
  live=$(readlink "$outdir/current" 2>/dev/null || true)
  for g in "$outdir"/gen/g-*; do
    [ -e "$g" ] || continue
    gname=$(basename "$g")
    [ "gen/$gname" = "$live" ] && continue
    if [ -n "$gname" ] && [[ "$g" == "$outdir"/gen/g-* ]]; then rm -rf -- "${g:?}"; fi
  done
  echo "build-on-windows: fetched $outdir/current/$outbase (commit $sha)"
  echo "build-on-windows: export ZB_WIN_EXE=$outdir/current/$outbase for the WS1.1 census"
fi
