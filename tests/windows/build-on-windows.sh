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

# RoseCat c09d439 (1): refuse any path with a SYMLINK in ANY component (not just the leaf), so a parent
# symlink can never redirect a write or a recursive delete outside the intended root. Logical (no-follow)
# and physical (follow-all) resolutions must be identical.
zb_no_symlink_path() {
  local p="$1" phys logi
  phys=$(realpath -m -- "$p" 2>/dev/null) || return 1
  logi=$(realpath -m -s -- "$p" 2>/dev/null) || return 1
  [ -n "$phys" ] && [ "$phys" = "$logi" ]
}
# The <dir>/current/<name> surface grammar, shared by publish and --gc.
zb_surface_ok() {  # $1=req
  local req="$1" cl base
  cl=$(dirname "$req"); base=$(basename "$req")
  [ "$(basename "$cl")" = "current" ] && [ -n "$base" ] && [ "$base" != "current" ] && [ "$cl" != "$req" ]
}

# ---- GC: a SEPARATE, locked, symlink-safe reaper (RoseCat 3da2862/ c09d439). Publish is append-only; this
# is the only place generations are deleted. It enforces the same surface grammar, refuses ANY symlinked
# path component, takes the publish lock (bounded wait, so it can never interleave with a live publish), and
# never touches the live target. Needs no VM/host.
if [ "${1:-}" = "--gc" ]; then
  req="${ZB_WIN_EXE:-zig-out/win/current/zigBrowser.exe}"
  if ! zb_surface_ok "$req"; then
    echo "build-on-windows: ZB_WIN_EXE must be a <dir>/current/<name> path for --gc (got '$req')" >&2; exit 2
  fi
  gc_curlink=$(dirname "$req"); gc_outdir=$(dirname "$gc_curlink")
  if ! zb_no_symlink_path "$gc_outdir"; then
    echo "build-on-windows: publish root '$gc_outdir' has a symlink component — refusing GC" >&2; exit 3
  fi
  [ -d "$gc_outdir" ] || { echo "build-on-windows: no generations to GC" >&2; exit 0; }
  # RoseCat 175efb8: PIN the directory identity — cd into the verified root and operate ONLY on relative
  # paths, so a later rename/symlink swap of the pathname cannot redirect the reaper. Confirm the entered
  # cwd resolves with no symlink component.
  cd "$gc_outdir" || { echo "build-on-windows: cannot enter publish root for GC" >&2; exit 3; }
  if [ "$(pwd -P)" != "$PWD" ]; then
    echo "build-on-windows: publish root '$gc_outdir' resolves through a symlink — refusing GC" >&2; exit 3
  fi
  # RoseCat 94be4e5/705dcf8: no persistent 'gen/' hop (generations are g-* directly in the pinned cwd), and
  # the lock is the PINNED DIRECTORY INODE itself (fd 9 = the cwd `.`), never a `.publish.lock` leaf. A
  # directory fd cannot be redirected by a planted symlink, so the check-then-open race is gone entirely.
  {
    if ! flock -w "${ZB_GC_LOCK_WAIT:-10}" 9; then
      echo "build-on-windows: GC could not acquire the publish lock (a publish is in progress)" >&2; exit 3
    fi
    live_base=$(basename "$(readlink current 2>/dev/null || echo __none__)")
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      gb=$(basename "$g")
      [ "$gb" = "$live_base" ] && continue
      if [ -d "$g" ] && [ ! -L "$g" ] && [[ "$g" == ./g-* ]]; then rm -rf -- "${g:?}"; fi
    done < <(find . -mindepth 1 -maxdepth 1 -type d -name 'g-*' -not -newermt '-1 hour' 2>/dev/null)
  } 9<"."
  exit 0
fi

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
# bd zigBrowser-ong.11: both Zig caches stay under %USERPROFILE%\zb (writes are confined to zb\): the global
# cache in zb\zig-global-cache (shared by runs), the local cache inside this run's own folder. Without them
# Zig writes its global cache to %LOCALAPPDATA%\zig.
psq() { printf "%s" "$1" | sed "s/'/''/g"; }   # PowerShell single-quote escaping
build_ps=$(cat <<PS
\$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath (Join-Path \$env:USERPROFILE '$remote_rundir')
\$env:ZIG_GLOBAL_CACHE_DIR = Join-Path \$env:USERPROFILE 'zb\zig-global-cache'
\$env:ZIG_LOCAL_CACHE_DIR = Join-Path \$env:USERPROFILE '$remote_rundir\.zig-cache'
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
  # RoseCat 3da2862/c09d439 (1): ZB_WIN_EXE IS the stable consumer surface and MUST be a <dir>/current/<name>
  # path. Reject the old ambiguous direct-file form, and refuse ANY symlink component of the publish root so
  # a parent symlink can never redirect a write or delete outside it — all BEFORE writing anything.
  req="${ZB_WIN_EXE:-zig-out/win/current/zigBrowser.exe}"
  if ! zb_surface_ok "$req"; then
    echo "build-on-windows: ZB_WIN_EXE must be a <dir>/current/<name> surface path (got '$req'); e.g. zig-out/win/current/zigBrowser.exe" >&2
    exit 2
  fi
  curlink=$(dirname "$req"); base=$(basename "$req"); outdir=$(dirname "$curlink")
  if ! zb_no_symlink_path "$outdir"; then
    echo "build-on-windows: publish root '$outdir' has a symlink component — refusing to publish" >&2; exit 3
  fi
  if ! mkdir -p "$outdir"; then echo "build-on-windows: cannot create the publish root '$outdir'" >&2; exit 3; fi
  # RoseCat 175efb8: PIN the directory identity — the earlier checks are TOCTOU, so cd INTO the verified
  # root and perform EVERY subsequent write/move/swap/fetch on RELATIVE paths. Once entered, the cwd is a
  # held reference to that inode; a later rename or symlink-swap of the pathname cannot redirect any of our
  # relative operations. Confirm the entered cwd resolves with no symlink component.
  if ! cd "$outdir"; then echo "build-on-windows: cannot enter the publish root '$outdir'" >&2; exit 3; fi
  if [ "$(pwd -P)" != "$PWD" ]; then
    echo "build-on-windows: publish root '$outdir' resolves through a symlink — refusing to publish" >&2; exit 3
  fi
  # RoseCat 94be4e5: NO persistent 'gen/' hop — generations are g-* directly in the pinned cwd, created
  # fresh by mktemp each run, so there is no post-validation intermediate component an attacker could swap.
  part=".fetch-$$.part"
  rm -f -- "$part" "$part.sha"
  "${scrub[@]}" timeout "$fetch_to" scp -i "$key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$kh" -o BatchMode=yes -o ConnectTimeout=15 -o ConnectionAttempts=3 -P "$port" \
    "$user@$host:$rundir/zig-out/bin/zigBrowser.exe" "$part"
  rc=$?
  if [ "$rc" -ne 0 ]; then echo "build-on-windows: fetch failed (rc=$rc)" >&2; rm -f -- "$part"; exit "$rc"; fi
  # Validate before publishing: non-empty and a real PE (DOS 'MZ' magic). Anything else is a failed build.
  if [ ! -s "$part" ] || [ "$(head -c2 "$part" 2>/dev/null)" != "MZ" ]; then
    echo "build-on-windows: fetched artifact is not a PE executable" >&2; rm -f -- "$part"; exit 3
  fi
  if ! printf '%s\n' "$sha" > "$part.sha"; then
    echo "build-on-windows: provenance write failed" >&2; rm -f -- "$part" "$part.sha"; exit 3
  fi
  # RoseCat c09d439/705dcf8: hold the lock from BEFORE generation creation through the checked swap (the
  # fetch/validate above stays outside it). The lock is the PINNED DIRECTORY INODE itself (fd 9 = the cwd
  # `.`), NOT a `.publish.lock` leaf — a directory fd cannot be redirected by a planted symlink, so there is
  # no check-then-open race. mktemp -d is an O_EXCL fresh generation; publish is APPEND-ONLY; a concurrent
  # --gc takes this SAME directory-inode lock, so it can never delete this in-flight generation. All paths
  # are relative to the pinned cwd (RoseCat 175efb8).
  pub_rc=0
  {
    if ! flock -w "${ZB_PUBLISH_LOCK_WAIT:-60}" 9; then
      pub_rc=3
    else
      gendir=$(mktemp -d "g-${sha}-XXXXXXXXXX") || gendir=""
      if [ -z "$gendir" ]; then
        pub_rc=3
      elif ! mv -fT "$part" "$gendir/$base" || ! mv -fT "$part.sha" "$gendir/$base.sha"; then
        pub_rc=3
        if [ -d "$gendir" ] && [ ! -L "$gendir" ] && [[ "$gendir" == g-* ]]; then rm -rf -- "${gendir:?}"; fi
      elif [ -n "${ZB_SELFTEST_CUT_PUBLISH:-}" ]; then
        pub_rc=42   # selftest: crash after the generation exists but before the swap (gen left; current intact)
      elif ! ln -sfn "$gendir" ".current.$$"; then
        pub_rc=3; rm -f -- ".current.$$"
      elif ! mv -fT ".current.$$" "current"; then
        pub_rc=3; rm -f -- ".current.$$"
      fi
    fi
  } 9<"."
  rm -f -- "$part" "$part.sha"
  if [ "$pub_rc" -eq 42 ]; then echo "build-on-windows: interrupted before current-swap (selftest)" >&2; exit 42; fi
  if [ "$pub_rc" -ne 0 ]; then echo "build-on-windows: publish failed" >&2; exit 3; fi
  echo "build-on-windows: fetched $req (commit $sha)"
  echo "build-on-windows: export ZB_WIN_EXE=$req for the WS1.1 census"
fi
