#!/usr/bin/env bash
# R4 compile-only Mac tier (RoseCat 483cdf7; repaired per a8a8a37 items 1-5): proves ONLY that one exact clean commit
# compiles and links natively on both real Mac architectures, x86_64 on the Intel Mac and arm64 on the Apple Silicon
# Mac. It is not a runtime, UI, Keychain or containment proof. One reviewed digest of THIS file is reused while its
# bytes are unchanged:
#   ZB_COMPILE_HARNESS_SHA256=<approved digest> \
#     bash -c "$(git show <harness rev>:tests/mac/mac_compile_only.sh)" mac-compile-only <source rev>
# The digest is `git show <harness rev>:tests/mac/mac_compile_only.sh | sha256sum`. Run as a file, or with executing
# bytes that do not hash to ZB_COMPILE_HARNESS_SHA256, it refuses before any connection.
#
# Here (Linux), before any connection: git archive of the source commit, every exported file's blob checked against
# the commit's tree, a refusal of any symlink/special entry, a build.zig.zon URL dependency or a missing
# mac-compile-only step, and the digest of every shipped file and of the tar.
# Each leg is ONE ssh session (BatchMode, strict host keys, no askpass, no DISPLAY): the leg script (REMOTE below),
# then the tar on the same stdin. The aggregate requires, per leg, the ssh pipeline's status 0 AND the exact last row
# "PASS<TAB>mac-compile<TAB><arch><TAB><sha>" (item 3).
# The leg (macOS /bin/bash 3.2), in order, failing closed at each step:
#   1. refuses unless HOME is a plain real /Users/<name>, the arch is native (no Rosetta), no ~/zb-compile-* root is
#      left from an earlier run (item 4), and zig and the Apple developer directory resolve to plain real paths;
#   2. makes ~/zb-compile-<nonce> (mode 700) and owns its cleanup from that moment (the EXIT trap). Every byte the
#      run writes is below it (item 1): the tar, the export, HOME, TMPDIR, both zig caches, the prefix, the logs;
#   3. takes the tar from stdin and checks its byte count, digest and member names before extracting it;
#   4. writes the sandbox-exec profile (item 2): file writes only below the root and to /dev/null; every network
#      family denied; signals only to itself; no WindowServer, pasteboard, Dock, LaunchServices, TCC or Keychain
#      services; no reads of the real home except the root and the zig toolchain, and none of the keychains; exec
#      only of zig, the Apple developer directory, /usr/bin/xcrun, /bin/bash, the logging xcrun and zig's own build
#      runner, and never of anything in the prefix (the products), the export, TMPDIR or HOME;
#   5. proves the sandbox is live before compiling: a write below the root succeeds, and each forbidden route is
#      refused (exec outside the toolchain, exec of a product path, a TCP connect, a write to the real home, a read
#      of a real-home credential file, a read of the system keychain, signal 0 to the leg itself);
#   6. runs `zig build mac-compile-only` (build.zig's dedicated compile/link-only step: the exe and the shim dylib it
#      links, nothing else), then compiles each src/*.m alone (`xcrun clang -c`, no link), all confined. A logging
#      xcrun first on PATH records every xcrun argv; --verbose-cc/--verbose-link print zig's;
#   7. reports each artifact's sha256 and `lipo -archs` (the leg's arch only);
#   8. ownership without signals (item 4): every confined step holds the write end of an ownership pipe, and the leg
#      waits for its EOF (every holder gone), at most OWN_S seconds after the step ends; a process census before and
#      after deleting the root finds no new process of this user imaged from the zig toolchain, the developer
#      directory or a zb-compile root, or carrying this run's environment marker. A survivor is reported, never
#      signalled. The root is deleted by a validated find -delete and must be gone; $HOME must hold no new entry.
# Nothing built is ever run and no signal is sent (signal 0 in a canary delivers nothing, and is refused).
# tests/mac/mac_compile_only_selftest.sh (registered) drives this file hostless (item 5). Running it on the Macs
# needs RoseCat's digest approval and the orchestrator's release.
set -euo pipefail
if [ -z "${BASH_EXECUTION_STRING:-}" ]; then
  printf 'FAIL\tmac-compile-only\trun the committed bytes, never a working-tree file:\n' >&2
  echo '  ZB_COMPILE_HARNESS_SHA256=<digest> bash -c "$(git show <rev>:tests/mac/mac_compile_only.sh)" mac-compile-only <rev>' >&2
  exit 1
fi
fail() { printf 'FAIL\tmac-compile-only\t%s\n' "$*" >&2; exit 1; }
HARNESS_SHA256=$(printf '%s\n' "$BASH_EXECUTION_STRING" | sha256sum | cut -c1-64)
[ "$HARNESS_SHA256" = "${ZB_COMPILE_HARNESS_SHA256:-}" ] \
  || fail "this harness's digest $HARNESS_SHA256 is not the approved ZB_COMPILE_HARNESS_SHA256"

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-jj@100.119.156.28}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"
export SSH_ASKPASS_REQUIRE=never

TOP=$(git rev-parse --show-toplevel)
cd "$TOP"
REV="${1:-HEAD}"
SHA=$(git rev-parse --verify --quiet "${REV}^{commit}") || fail "revision $REV is not a commit"
L=$(mktemp -d "${TMPDIR:-/tmp}/zb-compile-drv-XXXXXX")
trap 'case "$L" in "${TMPDIR:-/tmp}"/zb-compile-drv-??????) find "${L:?}" -delete;; esac' EXIT
SHIP=(src build.zig build.zig.zon zigbrowser.json tests packaging tools)
mkdir "$L/repo" && git archive "$SHA" -- "${SHIP[@]}" | tar -x -C "$L/repo"
echo "== mac compile-only at commit $SHA, harness sha256 $HARNESS_SHA256" >&2
cd "$L/repo"

odd=$(find "${SHIP[@]}" ! -type f ! -type d | LC_ALL=C sort | tr '\n' ' ')
[ -z "$odd" ] || fail "a shipped path holds a symlink or special entry (refused): $odd"
! sed 's#//.*##' build.zig.zon | grep -Eq '\.url[[:space:]]*=' || fail "build.zig.zon names a URL dependency (no outbound fetch)"
grep -q '"mac-compile-only"' build.zig || fail "build.zig at $SHA has no mac-compile-only step"
find "${SHIP[@]}" -type f ! -path '*/__pycache__/*' | LC_ALL=C sort > "$L/ship.list"
git -C "$TOP" ls-tree -r "$SHA" -- "${SHIP[@]}" | awk -F'\t' '$1 ~ / blob / {split($1, m, " "); print $2 " " m[3]}' \
  | { grep -v '/__pycache__/' || true; } | LC_ALL=C sort > "$L/tree.list"
while IFS= read -r f; do echo "$f $(git hash-object --no-filters -- "$f")"; done < "$L/ship.list" > "$L/export.list"
cmp -s "$L/tree.list" "$L/export.list" || fail "the export is not exactly the commit's blobs: $(diff "$L/tree.list" "$L/export.list" | head -5)"
tar -cf "$L/src.tar" -T "$L/ship.list"
[ "$(tar -tf "$L/src.tar" | LC_ALL=C sort)" = "$(cat "$L/ship.list")" ] || fail "the shipped tar's files are not exactly the named ones"
while IFS= read -r f; do echo "== ship $(sha256sum "$f" | cut -c1-64) $f" >&2; done < "$L/ship.list"
TAR_SHA=$(sha256sum "$L/src.tar" | cut -c1-64)
TAR_BYTES=$(wc -c < "$L/src.tar" | tr -d ' ')
echo "== shipped tree identity: commit $SHA, src.tar sha256 $TAR_SHA, $TAR_BYTES bytes" >&2

IFS= read -r -d '' REMOTE <<'REMOTE_EOF' || true
set -u
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin
OWN_S=30
bad=0 made=0 cleaned=0 finished=0 root= ZIGDIR=/nonexistent DEVDIR=/nonexistent CRED= procs_before=" " home_before= SURV=
MARK="ZB_COMPILE_RUN=$ZB_R"
say() { printf '%s\n' "$*"; }
check() { if [ "$1" = 0 ]; then say "ok   $2"; else say "FAIL $2"; bad=1; fi; }
verdict() {
  if [ "$bad" = 0 ]; then printf 'PASS\tmac-compile\t%s\t%s\n' "$ZB_ARCH" "$ZB_SHA"; else printf 'FAIL\tmac-compile\t%s\t%s\n' "$ZB_ARCH" "$ZB_SHA"; fi
}
cleanup() {
  [ "$made" = 1 ] && [ "$cleaned" = 0 ] || return 0
  cleaned=1
  cd / || return 1
  case "$root" in "$HOME"/zb-compile-[0-9]*-[0-9]*-[0-9]*) find "$root" -delete 2>/dev/null ;; *) return 1 ;; esac
  [ ! -e "$root" ] && [ ! -L "$root" ]
}
# The run-owned processes still alive: new since the start, of this user, imaged from the toolchains or a run root,
# or carrying this run's environment marker. Sets SURV; never signals anything.
survivors() {
  local pid rest
  SURV=
  while read -r pid rest; do
    case "$procs_before" in *" $pid "*) continue ;; esac
    [ "$pid" = "$$" ] && continue
    case "$rest" in "$ZIGDIR"/* | "$DEVDIR"/* | "$HOME"/zb-compile-* | *"$MARK"*) SURV="$SURV$pid ${rest%% *}; " ;; esac
  done < <(/bin/ps -E -U "$(id -u)" -o pid=,command=)
}
finish() {
  if [ "$made" = 1 ]; then
    survivors
    check "$([ -z "$SURV" ]; echo $?)" "no run-owned process before deleting the root ($SURV)"
    cleanup
    check $? "the run root is deleted (validated find -delete)"
    survivors
    check "$([ -z "$SURV" ]; echo $?)" "no run-owned process after deleting the root ($SURV)"
    new=$(comm -13 <(printf '%s\n' "$home_before" | LC_ALL=C sort) <(ls -A "$HOME" | LC_ALL=C sort) | tr '\n' ' ')
    check "$([ -z "$new" ]; echo $?)" "no new entry in \$HOME ($new)"
  fi
  finished=1
  verdict
  [ "$bad" = 0 ]
  exit $?
}
on_exit() {
  local st=$?
  [ "$finished" = 1 ] && exit "$st"
  check 1 "the leg stopped early ($st)"
  finish
}
refuse() { check 1 "$*"; finish; }
# Waits for EOF on the ownership pipe: every holder gone. After the step's own end it waits at most OWN_S seconds,
# then marks the pipe held (never a signal).
own_wait() {
  local after=0
  while :; do
    IFS= read -r -t 2 _ && continue
    [ $? -gt 128 ] || return 0
    [ -e "$root/status" ] && after=$((after + 2))
    if [ "$after" -ge "$OWN_S" ]; then : > "$root/held"; return 0; fi
  done
}
confined() {
  env -i PATH="$root/argv-shim:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$root/home" TMPDIR="$root/tmp/" LANG=C \
    XDG_CACHE_HOME="$root/home/.cache" ZB_XCRUN_LOG="$root/xcrun.argv" ZB_ROOT="$root" ZB_REALHOME="$HOME" \
    ZB_CRED="$CRED" ZB_LEG_PID="$$" "$MARK" \
    /usr/bin/nice -n 10 /usr/bin/sandbox-exec -f "$root/compile.sb" "$@"
}
# owned <log> <cmd...>: cmd confined, holding the ownership pipe; returns its status. A holder that outlives it fails
# the leg.
owned() {
  local log="$1" s
  shift
  rm -f "$root/status"
  { confined "$@"; echo "$?" > "$root/status"; } 9>&1 > "$log" 2>&1 | own_wait
  if [ -e "$root/held" ]; then
    check 1 "every process of [$*] is gone within ${OWN_S}s of its end (the ownership pipe is still held)"
    finish
  fi
  s=$(cat "$root/status" 2>/dev/null)
  return "${s:-126}"
}
canary() { # canary <route> <script>: the sandbox must refuse it
  owned "$root/canary.log" /bin/bash -c "$2"
  local s=$?
  check "$([ "$s" -ne 0 ]; echo $?)" "the sandbox refuses $1 ($s)"
}
safe_path() { [[ "$1" =~ ^/[A-Za-z0-9._/-]+$ ]] && [[ "$1" != *..* ]]; }

main() {
  trap on_exit EXIT
  case "$ZB_R" in zb-compile-[0-9]*-[0-9]*-[0-9]*) ;; *) refuse "run root name $ZB_R" ;; esac
  case "$ZB_ARCH" in x86_64 | arm64) ;; *) refuse "arch $ZB_ARCH" ;; esac
  [[ "$HOME" =~ ^/Users/[A-Za-z0-9._-]+$ ]] && [ "$(cd "$HOME" && pwd -P)" = "$HOME" ] || refuse "HOME $HOME is not a plain real /Users/<name>"
  check "$([ "$(/usr/bin/uname -m)" = "$ZB_ARCH" ]; echo $?)" "native arch is $(/usr/bin/uname -m), expected $ZB_ARCH"
  check "$([ "$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 0 ]; echo $?)" "not translated by Rosetta"
  [ "$bad" = 0 ] || finish
  stale=$(ls -d "$HOME"/zb-compile-* 2>/dev/null | tr '\n' ' ')
  [ -z "$stale" ] || refuse "no run root left from an earlier run (found: $stale; remove it by hand after a look)"
  zig_real=$(/bin/realpath "$HOME/.local/bin/zig" 2>/dev/null) || refuse "zig at ~/.local/bin/zig"
  ZIGDIR=${zig_real%/*}
  case "$ZIGDIR" in "$HOME"/.local/?*) ;; *) refuse "zig resolves outside ~/.local ($zig_real)" ;; esac
  safe_path "$zig_real" && [ -f "$zig_real" ] && [ -x "$zig_real" ] || refuse "zig resolves to a plain executable ($zig_real)"
  DEVDIR=$(/usr/bin/xcode-select -p 2>/dev/null) || refuse "xcode-select -p"
  case "$DEVDIR" in /Library/Developer/CommandLineTools | /Applications/Xcode*.app/Contents/Developer) ;; *) refuse "developer dir $DEVDIR" ;; esac
  safe_path "$DEVDIR" && [ "$(cd "$DEVDIR" && pwd -P)" = "$DEVDIR" ] || refuse "developer dir $DEVDIR is not a plain real path"
  for f in "$HOME/.ssh/authorized_keys" "$HOME/.ssh/known_hosts" "$HOME/.zshrc"; do
    if [ -f "$f" ] && [ -r "$f" ]; then CRED=$f; break; fi
  done
  [ -n "$CRED" ] || refuse "no readable real-home file to prove the read denial with"
  [ -r /Library/Keychains/System.keychain ] || refuse "no readable system keychain to prove the read denial with"
  while read -r p; do procs_before="$procs_before$p "; done < <(/bin/ps -U "$(id -u)" -o pid=)
  home_before=$(ls -A "$HOME")

  root="$HOME/$ZB_R"
  mkdir -m 700 "$root" || refuse "make the run root $root"
  made=1
  [ "$(cd "$root" && pwd -P)" = "$root" ] && [ ! -L "$root" ] || refuse "the run root resolves elsewhere"
  say "== leg $ZB_ARCH, run root $root, zig $zig_real, developer dir $DEVDIR"

  head -c "$ZB_TAR_BYTES" > "$root/src.tar"
  check "$([ "$(wc -c < "$root/src.tar" | tr -d ' ')" = "$ZB_TAR_BYTES" ]; echo $?)" "src.tar is $ZB_TAR_BYTES bytes"
  check "$([ "$(/usr/bin/shasum -a 256 "$root/src.tar" | cut -c1-64)" = "$ZB_TAR_SHA" ]; echo $?)" "src.tar sha256 is $ZB_TAR_SHA"
  [ "$bad" = 0 ] || finish
  names=$(tar -tf "$root/src.tar" | grep -Ev '^(src|tests|packaging|tools)/[A-Za-z0-9._/+@-]*[^/]$|^(build\.zig|build\.zig\.zon|zigbrowser\.json)$' || true)
  dots=$(tar -tf "$root/src.tar" | grep -E '(^|/)\.\.(/|$)' || true)
  types=$(tar -tvf "$root/src.tar" | cut -c1 | grep -v '^-$' || true)
  check "$([ -z "$names$dots$types" ]; echo $?)" "src.tar holds only regular files under the shipped paths"
  [ "$bad" = 0 ] || finish
  mkdir "$root/repo" "$root/home" "$root/tmp" "$root/out" "$root/extra" "$root/argv-shim" "$root/zc" "$root/zgc" || refuse "make the run tree"
  tar -xf "$root/src.tar" -C "$root/repo" || refuse "extract src.tar"
  odd=$(find "$root/repo" ! -type f ! -type d)
  check "$([ -z "$odd" ]; echo $?)" "the extracted tree holds no symlink or special entry"
  [ "$bad" = 0 ] || finish

  printf '#!/bin/bash\nprintf "%%q " "$@" >> "$ZB_XCRUN_LOG"; echo >> "$ZB_XCRUN_LOG"\nexec /usr/bin/xcrun "$@"\n' > "$root/argv-shim/xcrun"
  chmod 700 "$root/argv-shim/xcrun"
  rx=$(printf '%s' "$root" | sed 's/[.]/\\./g')
  cat > "$root/compile.sb" <<SB
(version 1)
(allow default)
(deny network*)
(deny signal)
(allow signal (target self))
(deny file-write*)
(allow file-write* (subpath "$root") (literal "/dev/null"))
(deny file-read-data (subpath "$HOME"))
(allow file-read-data (subpath "$root") (subpath "$ZIGDIR"))
(deny file-read* (subpath "/Library/Keychains") (subpath "/System/Library/Keychains") (subpath "/private/var/db/mds"))
(deny mach-lookup (global-name "com.apple.SecurityServer") (global-name "com.apple.securityd")
  (global-name "com.apple.securityd.xpc") (global-name "com.apple.secd") (global-name "com.apple.security.agent")
  (global-name "com.apple.security.authhost") (global-name "com.apple.windowserver")
  (global-name "com.apple.windowserver.active") (global-name "com.apple.CARenderServer")
  (global-name "com.apple.pasteboard.1") (global-name "com.apple.dock.server")
  (global-name "com.apple.coreservices.launchservicesd") (global-name "com.apple.tccd"))
(deny process-exec*)
(allow process-exec* (literal "$zig_real") (subpath "$DEVDIR") (literal "/usr/bin/xcrun") (literal "/bin/bash")
  (literal "$root/argv-shim/xcrun") (regex #"^$rx/(zc|zgc)/o/[0-9a-f]+/build\$"))
(deny process-exec* (subpath "$root/out") (subpath "$root/repo") (subpath "$root/tmp") (subpath "$root/home"))
SB
  say "== sandbox profile sha256 $(/usr/bin/shasum -a 256 "$root/compile.sb" | cut -c1-64)"
  sed 's/^/sb /' "$root/compile.sb"

  # The sandbox is live: a write below the root works; every forbidden route is refused.
  owned "$root/canary.log" /bin/bash -c ': > "$ZB_ROOT/tmp/live"'
  live=$?
  check "$([ "$live" = 0 ] && [ -f "$root/tmp/live" ]; echo $?)" "the sandbox runs a confined write below the root"
  mkdir -p "$root/out/bin" "$root/zc/o/00ff"
  cp /usr/bin/true "$root/out/bin/zigBrowser" && cp /usr/bin/true "$root/zc/o/00ff/zigBrowser" || refuse "stage the exec canaries"
  canary "exec outside the toolchain" '/usr/bin/true'
  canary "exec of a product in the prefix" '"$ZB_ROOT/out/bin/zigBrowser"'
  canary "exec of a product in the cache" '"$ZB_ROOT/zc/o/00ff/zigBrowser"'
  canary "a TCP connect" 'exec 3<>/dev/tcp/127.0.0.1/22'
  canary "a write to the real home" ': > "$ZB_REALHOME/.zb-compile-canary"'
  canary "a read of a real-home credential file" 'cat "$ZB_CRED" > /dev/null'
  canary "a read of the system keychain" 'cat /Library/Keychains/System.keychain > /dev/null'
  canary "signal 0 to the leg" 'kill -0 "$ZB_LEG_PID"'
  check "$([ ! -e "$HOME/.zb-compile-canary" ]; echo $?)" "the real-home write canary left nothing"
  rm -f "$root/out/bin/zigBrowser" "$root/zc/o/00ff/zigBrowser"
  rmdir "$root/out/bin" "$root/zc/o/00ff" "$root/zc/o"
  [ "$bad" = 0 ] || finish

  cd "$root/repo" || refuse "enter the export"
  say "== zig $("$zig_real" version), sdk $(/usr/bin/xcrun --show-sdk-version 2>/dev/null)"
  owned "$root/build.log" "$zig_real" build mac-compile-only --prefix "$root/out" --cache-dir "$root/zc" \
    --global-cache-dir "$root/zgc" --verbose-cc --verbose-link
  code=$?
  say "== build log sha256 $(/usr/bin/shasum -a 256 "$root/build.log" | cut -c1-64), $(wc -l < "$root/build.log" | tr -d ' ') lines"
  sed 's/^/| /' "$root/build.log"
  check "$code" "zig build mac-compile-only (the exe and the shim dylib) compiled and linked natively ($code)"
  for m in src/*.m; do
    [ -f "$m" ] || continue
    owned "$root/extra.log" /usr/bin/xcrun clang -c -fobjc-arc -I src "$m" -o "$root/extra/$(basename "$m" .m).o"
    code=$?
    sed 's/^/| /' "$root/extra.log"
    check "$code" "$m compiles alone ($code)"
  done
  say "== xcrun argv (sha256 $(/usr/bin/shasum -a 256 "$root/xcrun.argv" 2>/dev/null | cut -c1-64)):"
  sed 's/^/argv /' "$root/xcrun.argv" 2>/dev/null
  dylibs=$(find "$root/zc" -type f -name libwkwebview_shim.dylib)
  check "$([ "$(printf '%s\n' "$dylibs" | grep -c .)" = 1 ]; echo $?)" "exactly one shim dylib was linked"
  for a in "$root/out/bin/zigBrowser" $dylibs "$root"/extra/*.o; do
    [ -f "$a" ] || { check 1 "artifact ${a#$root/} exists"; continue; }
    archs=$(/usr/bin/lipo -archs "$a" 2>/dev/null)
    say "== artifact $(/usr/bin/shasum -a 256 "$a" | cut -c1-64) ${a#$root/} [$archs]"
    check "$([ "$archs" = "$ZB_ARCH" ]; echo $?)" "${a#$root/} is $ZB_ARCH only"
  done
  finish
}
REMOTE_EOF

leg() { # $1=host $2=expected uname -m $3=key: one ssh session, the leg script then the tar on its stdin
  local host="$1" arch="$2" key="$3" r="zb-compile-$(date +%s)-$$-$RANDOM"
  echo "== leg $arch on $host, run root ~/$r"
  { printf '%s\n' "$REMOTE"; printf 'main\n'; cat "$L/src.tar"; } \
    | env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
        "$host" "ZB_R='$r' ZB_ARCH='$arch' ZB_SHA='$SHA' ZB_TAR_SHA='$TAR_SHA' ZB_TAR_BYTES='$TAR_BYTES' /bin/bash -s"
}

mkdir "$L/logs"
overall=0
for spec in "$INTEL_HOST x86_64 $KEY" "$ARM_HOST arm64 $ARM_KEY"; do
  set -- $spec
  if leg "$1" "$2" "$3" | tee "$L/logs/$2.log"; then st=0; else st=$?; fi
  last=$(tail -1 "$L/logs/$2.log")
  if [ "$st" -ne 0 ] || [ "$last" != "$(printf 'PASS\tmac-compile\t%s\t%s' "$2" "$SHA")" ]; then
    echo "FAIL: $2 leg (pipeline status $st, last line: $last)" >&2
    overall=1
  fi
done
[ "$overall" -eq 0 ] && printf 'PASS\tmac-compile-only\tboth-arches\t%s\tharness %s\n' "$SHA" "$HARNESS_SHA256"
exit "$overall"
