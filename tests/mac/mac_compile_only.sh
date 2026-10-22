#!/usr/bin/env bash
# R4 compile-only Mac tier (RoseCat 483cdf7): proves ONLY that one exact clean commit compiles and links natively on
# both real Mac architectures, x86_64 on the Intel Mac and arm64 on the Apple Silicon Mac. It is not a runtime, UI,
# Keychain or containment proof. One reviewed digest of THIS file is reused while its bytes are unchanged:
#   ZB_COMPILE_HARNESS_SHA256=<approved digest> \
#     bash -c "$(git show <harness rev>:tests/mac/mac_compile_only.sh)" mac-compile-only <source rev>
# The digest is `git show <harness rev>:tests/mac/mac_compile_only.sh | sha256sum`; a run whose executing bytes do not
# hash to ZB_COMPILE_HARNESS_SHA256 refuses before any connection, and run as a file it refuses at once.
#
# Here (Linux): export <source rev> with git archive, check every exported file's blob against the commit's tree,
# refuse a symlink/special entry or a build.zig.zon URL dependency, and print the digest of every shipped file and
# of the tar before any connection.
# Each leg (one ssh to make the run root, one scp, one ssh to build): the leg makes ~/zb-compile-<nonce> (a unique
# root; it refuses if the name exists), checks the arch is native (no Rosetta), the tar's digest and its member
# names, extracts it, and runs `zig build` (the default install step: the exe and the shim dylib, into a prefix
# inside the root) with HOME, TMPDIR and both zig caches inside the root, under `nice` and a sandbox-exec profile
# that denies IP networking, denies every file write outside the root, /dev and the user's temp and cache
# directories, and denies executing any zigBrowser. A logging `xcrun` first on PATH records every xcrun argv
# (shell-quoted, one line each); zig's own compiler and linker argv come from --verbose-cc/--verbose-link. Each
# src/*.m is also compiled alone (`xcrun clang -c -fobjc-arc -I src`, no link), so an Objective-C file not yet
# wired into build.zig still gets compiler feedback. Nothing built is ever run, and no signal is sent anywhere.
# The leg prints the artifacts' sha256 and `lipo -archs`, deletes the root with a validated find -delete, then
# reports a census: the root is gone, no process still names it, and no new entry in $HOME, ~/Library/Caches or
# the user's temp and cache directories. Its last line is "PASS<TAB>mac-compile<TAB><arch><TAB><sha>" or FAIL.
# BatchMode, strict host keys, no askpass, no DISPLAY. Needs the orchestrator's release for each run.
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
find "${SHIP[@]}" -type f ! -path '*/__pycache__/*' | LC_ALL=C sort > "$L/ship.list"
git -C "$TOP" ls-tree -r "$SHA" -- "${SHIP[@]}" | awk -F'\t' '$1 ~ / blob / {split($1, m, " "); print $2 " " m[3]}' \
  | grep -v '/__pycache__/' | LC_ALL=C sort > "$L/tree.list"
while IFS= read -r f; do echo "$f $(git hash-object --no-filters -- "$f")"; done < "$L/ship.list" > "$L/export.list"
cmp -s "$L/tree.list" "$L/export.list" || fail "the export is not exactly the commit's blobs: $(diff "$L/tree.list" "$L/export.list" | head -5)"
tar -cf "$L/src.tar" -T "$L/ship.list"
[ "$(tar -tf "$L/src.tar" | LC_ALL=C sort)" = "$(cat "$L/ship.list")" ] || fail "the shipped tar's files are not exactly the named ones"
while IFS= read -r f; do echo "== ship $(sha256sum "$f" | cut -c1-64) $f" >&2; done < "$L/ship.list"
TAR_SHA=$(sha256sum "$L/src.tar" | cut -c1-64)
echo "== shipped tree identity: commit $SHA, src.tar sha256 $TAR_SHA" >&2

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3" r="zb-compile-$(date +%s)-$$-$RANDOM"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=6)
  local SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY scp -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o ConnectTimeout=15)
  echo "== leg $arch on $host, run root ~/$r"
  # The before-census is taken before the root exists, then kept inside it.
  "${SSH[@]}" "$host" "ZB_R='$r' /bin/bash -s" <<'MAKE' || { printf 'FAIL\tmac-compile\t%s\tcould not make the run root\n' "$arch"; return 1; }
set -eu
case "$ZB_R" in zb-compile-[0-9]*-[0-9]*-[0-9]*) ;; *) echo "bad run root name $ZB_R" >&2; exit 1;; esac
[ ! -e "$HOME/$ZB_R" ] && [ ! -L "$HOME/$ZB_R" ] || { echo "run root $ZB_R already exists" >&2; exit 1; }
ut=$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P); uc=$(cd "$(getconf DARWIN_USER_CACHE_DIR)" && pwd -P)
h=$(ls -A "$HOME"); lc=$(ls -A "$HOME/Library/Caches"); t=$(ls -A "$ut"); c=$(ls -A "$uc")
mkdir -m 700 "$HOME/$ZB_R"
printf '%s\n' "$h" > "$HOME/$ZB_R/census.home"; printf '%s\n' "$lc" > "$HOME/$ZB_R/census.caches"
printf '%s\n' "$t" > "$HOME/$ZB_R/census.utmp"; printf '%s\n' "$c" > "$HOME/$ZB_R/census.ucache"
MAKE
  if ! "${SCP[@]}" "$L/src.tar" "$host:$r/src.tar" >/dev/null; then
    "${SSH[@]}" "$host" "case '$r' in zb-compile-*) d=\"\$HOME/$r\"; [ -d \"\$d\" ] && find \"\$d\" -delete;; esac" || true
    printf 'FAIL\tmac-compile\t%s\tscp to %s\n' "$arch" "$host"; return 1
  fi
  "${SSH[@]}" "$host" "ZB_R='$r' ZB_ARCH='$arch' ZB_TAR_SHA='$TAR_SHA' ZB_SHA='$SHA' /bin/bash -s" <<'REMOTE'
set -u
case "$ZB_R" in zb-compile-[0-9]*-[0-9]*-[0-9]*) ;; *) printf 'FAIL\tmac-compile\t%s\tbad run root\n' "$ZB_ARCH"; exit 1;; esac
root="$HOME/$ZB_R"
[ -d "$root" ] && [ ! -L "$root" ] || { printf 'FAIL\tmac-compile\t%s\tno run root\n' "$ZB_ARCH"; exit 1; }
root=$(cd "$root" && pwd -P)
case "$root" in "$(cd "$HOME" && pwd -P)/$ZB_R") ;; *) printf 'FAIL\tmac-compile\t%s\tthe run root resolves elsewhere\n' "$ZB_ARCH"; exit 1;; esac
cleaned=0
cleanup() { [ "$cleaned" = 1 ] && return; cleaned=1; cd / && case "$root" in "$HOME"/zb-compile-*) find "${root:?}" -delete;; esac; }
trap cleanup EXIT
bad=0
check() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; bad=1; fi; }

check "$([ "$(uname -m)" = "$ZB_ARCH" ]; echo $?)" "native arch is $(uname -m), expected $ZB_ARCH"
check "$([ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 0 ]; echo $?)" "not translated by Rosetta"
check "$([ "$(shasum -a 256 "$root/src.tar" | cut -c1-64)" = "$ZB_TAR_SHA" ]; echo $?)" "src.tar sha256 is $ZB_TAR_SHA"
names=$(tar -tf "$root/src.tar" | grep -Ev '^(src|tests|packaging|tools)/[^ ]*[^/]$|^(build\.zig|build\.zig\.zon|zigbrowser\.json)$' || true)
dots=$(tar -tf "$root/src.tar" | grep -E '(^|/)\.\.(/|$)' || true)
types=$(tar -tvf "$root/src.tar" | cut -c1 | grep -v '^-$' || true)
check "$([ -z "$names$dots$types" ]; echo $?)" "src.tar holds only regular files under the shipped paths"
if [ "$bad" = 0 ]; then
  mkdir "$root/repo" "$root/home" "$root/tmp" "$root/out" "$root/extra" "$root/argv-shim"
  tar -xf "$root/src.tar" -C "$root/repo"
  odd=$(find "$root/repo" ! -type f ! -type d)
  check "$([ -z "$odd" ]; echo $?)" "the extracted tree holds no symlink or special entry"
fi
ZIG="$HOME/.local/bin/zig"
if [ "$bad" = 0 ]; then
  echo "== zig $("$ZIG" version) at $ZIG; $(/usr/bin/xcrun --show-sdk-version 2>/dev/null | sed 's/^/sdk /')"
  printf '#!/bin/bash\nprintf "%%q " "$@" >> "$ZB_XCRUN_LOG"; echo >> "$ZB_XCRUN_LOG"\nexec /usr/bin/xcrun "$@"\n' \
    > "$root/argv-shim/xcrun"
  chmod 755 "$root/argv-shim/xcrun"
  ut=$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P); uc=$(cd "$(getconf DARWIN_USER_CACHE_DIR)" && pwd -P)
  cat > "$root/compile.sb" <<'SB'
(version 1)
(allow default)
(deny network-outbound (remote ip))
(deny network-bind (local ip))
(deny file-write*)
(allow file-write* (subpath (param "ROOT")) (subpath "/dev") (subpath (param "UTMP")) (subpath (param "UCACHE")))
(deny process-exec (regex #"/zigBrowser$"))
SB
  run() { # the confined environment for every compile
    env -i PATH="$root/argv-shim:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$root/home" TMPDIR="$root/tmp/" LANG=C \
      ZB_XCRUN_LOG="$root/xcrun.argv" \
      /usr/bin/nice -n 10 /usr/bin/sandbox-exec -f "$root/compile.sb" -D ROOT="$root" -D UTMP="$ut" -D UCACHE="$uc" "$@"
  }
  cd "$root/repo"
  run "$ZIG" build --prefix "$root/out" --cache-dir "$root/zc" --global-cache-dir "$root/zgc" \
    --verbose-cc --verbose-link > "$root/build.log" 2>&1
  code=$?
  echo "== build log sha256 $(shasum -a 256 "$root/build.log" | cut -c1-64), $(wc -l < "$root/build.log") lines"
  sed 's/^/| /' "$root/build.log"
  check "$code" "zig build (exe + shim dylib) compiled and linked natively ($code)"
  for m in src/*.m; do
    [ -f "$m" ] || continue
    o="$root/extra/$(basename "$m" .m).o"
    run /usr/bin/xcrun clang -c -fobjc-arc -I src "$m" -o "$o" > "$root/extra.log" 2>&1
    code=$?
    sed 's/^/| /' "$root/extra.log"
    check "$code" "$m compiles alone ($code)"
  done
  echo "== xcrun argv (sha256 $(shasum -a 256 "$root/xcrun.argv" 2>/dev/null | cut -c1-64)):"
  sed 's/^/argv /' "$root/xcrun.argv" 2>/dev/null
  for a in "$root/out/bin/zigBrowser" "$root/out/Frameworks/libwkwebview_shim.dylib" "$root"/extra/*.o; do
    [ -f "$a" ] || { check 1 "artifact ${a#$root/} exists"; continue; }
    archs=$(lipo -archs "$a" 2>/dev/null)
    echo "== artifact $(shasum -a 256 "$a" | cut -c1-64) ${a#$root/} [$archs]"
    check "$([ "$archs" = "$ZB_ARCH" ]; echo $?)" "${a#$root/} is $ZB_ARCH only"
  done
  cd /
fi

before_home=$(cat "$root/census.home"); before_caches=$(cat "$root/census.caches")
before_utmp=$(cat "$root/census.utmp"); before_ucache=$(cat "$root/census.ucache")
cleanup
check "$([ ! -e "$root" ] && [ ! -L "$root" ]; echo $?)" "the run root is deleted"
left=$(pgrep -U "$(id -u)" -f -- "$root/" || true)
check "$([ -z "$left" ]; echo $?)" "no process names the run root ($left)"
ut=$(cd "$(getconf DARWIN_USER_TEMP_DIR)" && pwd -P); uc=$(cd "$(getconf DARWIN_USER_CACHE_DIR)" && pwd -P)
for pair in "home:$HOME" "caches:$HOME/Library/Caches" "utmp:$ut" "ucache:$uc"; do
  k=${pair%%:*} d=${pair#*:}
  case "$k" in home) b=$before_home;; caches) b=$before_caches;; utmp) b=$before_utmp;; ucache) b=$before_ucache;; esac
  new=$(comm -13 <(printf '%s\n' "$b" | LC_ALL=C sort) <(ls -A "$d" | LC_ALL=C sort) | tr '\n' ' ')
  check "$([ -z "$new" ]; echo $?)" "no new entry in $d ($new)"
done
if [ "$bad" = 0 ]; then printf 'PASS\tmac-compile\t%s\t%s\n' "$ZB_ARCH" "$ZB_SHA"; else printf 'FAIL\tmac-compile\t%s\t%s\n' "$ZB_ARCH" "$ZB_SHA"; fi
exit "$bad"
REMOTE
}

mkdir "$L/logs"
leg "$INTEL_HOST" x86_64 "$KEY" | tee "$L/logs/x86_64.log" || true
leg "$ARM_HOST" arm64 "$ARM_KEY" | tee "$L/logs/arm64.log" || true
overall=0
for arch in x86_64 arm64; do
  [ "$(tail -1 "$L/logs/$arch.log" | cut -f1-4)" = "PASS	mac-compile	$arch	$SHA" ] || { echo "FAIL: $arch leg" >&2; overall=1; }
done
[ "$overall" -eq 0 ] && printf 'PASS\tmac-compile-only\tboth-arches\t%s\tharness %s\n' "$SHA" "$HARNESS_SHA256"
exit "$overall"
