#!/bin/bash
# The Mac side of one 4pa.80 spike leg. tests/mac/bundle_layout_spike.sh sends this committed file over ssh as
# `/bin/bash -s <subcommand> ...`. Write containment per SilverRidge de82cf2: every write-capable phase runs under ONE
# Seatbelt profile, through ONE wrapper, the real /usr/bin/sandbox-exec:
#   (version 1) (allow default) (deny file-write*) (allow file-write* (subpath "<physical run root>") (literal "/dev/null"))
# Outside the sandbox this script only creates and validates the fresh physical run root, reads (getconf, uname, the
# audit listings, validation) and removes that exact root. Even its evidence is written by sandboxed commands, into
# <root>/evidence. Verdicts go to stdout:
#   PHASE<TAB><phase><TAB>ok|fail|NOT-RUN|BREACH<TAB>[detail]    SPIKE<TAB>census<TAB><non-Mach-O files under Frameworks>
#   VERIFY<TAB>rc=<n><TAB>unsealed=yes|no<TAB>not-signed=yes|no<TAB>sealed-resource=yes|no<TAB>denied=yes|no
# Subcommands (bash 3.2, macOS):
#   create <rd>   rd = zb-gate-<40 hex>-<hex> must not exist: mkdir ~/<rd> and <rd>/inputs, check that `pwd -P` of it is
#                 <physical home>/<rd> and that it is no symlink, print ROOT<TAB><physical root>.
#   run <rd> <arch> <pkg sha256> <none|data_in_frameworks>
#                 preflight (sandbox-exec present, the profile parses, writes below the root and to /dev/null work under
#                 it), the before-audit, three unique pre-absent negative canaries (the real home and both getconf Darwin
#                 temp/cache dirs), each of which must be REFUSED (if one is not, that is a CONTAINMENT BREACH: exit 4, the
#                 target is kept and named, nothing later runs), then exactly two sandboxed outer commands (1: unpack and
#                 the native zig build; 2: staging with the real stager, the symlink check, the census, inside-out signing
#                 and verification), the after-audit and <root>/evidence.tar. Exit 0 when every phase ran (verify may still
#                 fail: that is the evidence), 3 NOT RUN or a failed phase, 4 BREACH.
#   remove <rd>   find -delete of exactly that validated root.
# Hostless proof: tests/mac/bundle_layout_spike_containment_selftest.sh (zig build test-mac-bundle-layout-spike).
# The body is one function, read whole before it runs, so no sandboxed child can read the rest of it from stdin.
main() {
set -u
local CMD="${1:-}" RD="${2:-}" H ROOT
[[ "$RD" =~ ^zb-gate-[0-9a-f]{40}-[0-9a-f]+$ ]] || { printf 'PHASE\troot\tNOT-RUN\tbad run dir name: %s\n' "$RD"; exit 3; }
H=$(cd "$HOME" && pwd -P) || { echo "PHASE	root	NOT-RUN	no home"; exit 3; }
ROOT="$H/$RD"
case "$ROOT" in *[\"\\]*) echo "PHASE	root	NOT-RUN	the root path holds a quote or backslash"; exit 3 ;; esac
valid_root() { [ -d "$ROOT" ] && [ ! -L "$ROOT" ] && [ "$(cd "$ROOT" && pwd -P)" = "$ROOT" ]; }
fd_id() { if [ "$(uname -s)" = Darwin ]; then stat -L -f '%d:%i' "/dev/fd/$1"; else stat -L -c '%d:%i' "/dev/fd/$1"; fi; }
file_ids() { # device:inode of every regular file below $1
  if [ "$(uname -s)" = Darwin ]; then find "$1" -xdev -type f -exec stat -f '%d:%i' {} +; else find "$1" -xdev -type f -exec stat -c '%d:%i' {} +; fi
}

if [ "$CMD" = create ]; then
  [ ! -e "$ROOT" ] && [ ! -L "$ROOT" ] || { echo "PHASE	root	NOT-RUN	$ROOT already exists"; exit 3; }
  mkdir "$ROOT" && mkdir "$ROOT/inputs" || { echo "PHASE	root	NOT-RUN	mkdir failed"; exit 3; }
  valid_root || { echo "PHASE	root	NOT-RUN	$ROOT is not a fresh physical directory"; exit 3; }
  printf 'ROOT\t%s\n' "$ROOT"
  exit 0
fi
if [ "$CMD" = remove ]; then
  valid_root || { echo "PHASE	remove	NOT-RUN	$ROOT is not the validated root"; exit 3; }
  cd / && find "$ROOT" -delete
  exit $?
fi
[ "$CMD" = run ] || { echo "PHASE	root	NOT-RUN	unknown subcommand $CMD"; exit 3; }

local ARCH="${3:?}" PIN="${4:?}" MUTANT="${5:?}" NONCE E TD CD PROFILE SBX fd t rc brc prc=1
NONCE=${RD##*-} E="$ROOT/evidence"
notrun() { printf 'PHASE\t%s\tNOT-RUN\t%s\n' "$1" "$2"; exit 3; }
valid_root || notrun root "$ROOT is not the validated physical root"
# No inherited regular-file descriptor (fd 1, fd 2 or any other but stdin, which carries this script) may point
# outside the root: each one's device:inode must be a file below the root. Pipes and sockets pass. Then 3-19 close.
local ids id p
ids=" $(file_ids "$ROOT" | tr '\n' ' ') "
for p in /dev/fd/*; do
  fd=${p##*/}
  case "$fd" in ''|*[!0-9]*|0) continue ;; esac
  [ -f "$p" ] || continue
  if [ "$fd" -le 2 ]; then { id=$(fd_id 9); } 9>&"$fd"; else id=$(fd_id "$fd"); fi
  case "$ids" in *" $id "*) ;; *) notrun descriptors "fd $fd is a regular file outside the run root" ;; esac
done
for fd in 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do eval "exec $fd>&-" 2>/dev/null; done
[ "$(uname -m)" = "$ARCH" ] || notrun arch "this host is $(uname -m), not $ARCH"
TD=$(getconf DARWIN_USER_TEMP_DIR) && CD=$(getconf DARWIN_USER_CACHE_DIR) || notrun getconf "no Darwin user dirs"
case "$TD" in /?*) ;; *) notrun getconf "DARWIN_USER_TEMP_DIR is not absolute: $TD" ;; esac
case "$CD" in /?*) ;; *) notrun getconf "DARWIN_USER_CACHE_DIR is not absolute: $CD" ;; esac

PROFILE="(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath \"$ROOT\") (literal \"/dev/null\"))"
SBX=/usr/bin/sandbox-exec
sbx() { "$SBX" -p "$PROFILE" "$@"; }

# --- preflight: the real sandbox-exec parses the exact profile, and the allowed writes work through it ---
[ -x "$SBX" ] || notrun preflight "$SBX is missing"
sbx /usr/bin/true </dev/null 2>/dev/null || notrun preflight "sandbox-exec refused the profile"
sbx /bin/mkdir "$E" </dev/null 2>/dev/null && sbx /bin/sh -c ': > "$1"' sh "$E/positive" </dev/null 2>/dev/null \
  && [ -e "$E/positive" ] || notrun positive "a write below the run root failed under the profile"
sbx /bin/sh -c ': > /dev/null' </dev/null 2>/dev/null || notrun positive "a write to /dev/null failed under the profile"
printf '%s\n' "$PROFILE" | sbx /bin/sh -c 'cat > "$1"' sh "$E/profile" || notrun positive "the evidence write failed"
echo "PHASE	preflight	ok"

# --- the read-only audit: path plus stable metadata, both Darwin user dirs, ~/Library/Caches, the shallow home ---
audit() {
  local -a st
  if [ "$(uname -s)" = Darwin ]; then st=(stat -f '%N|%HT|%p|%i|%z|%m'); else st=(stat -c '%n|%F|%a|%i|%s|%Y'); fi
  for d in "${TD%/}" "${CD%/}" "$H/Library/Caches"; do
    [ -d "$d" ] && find "$d" -xdev -print0 2>/dev/null | xargs -0 "${st[@]}" 2>/dev/null
  done
  find "$H" -mindepth 1 -maxdepth 1 ! -path "$ROOT" -print0 2>/dev/null | xargs -0 "${st[@]}" 2>/dev/null
  return 0
}
# The listing is read outside (find/stat); sort, which may spill temporary files, runs under the profile with them in
# the root (SilverRidge 0d0656f4).
snapshot() { audit | sbx /bin/sh -c 'mkdir -p "$2" && LC_ALL=C TMPDIR="$2" sort -T "$2" > "$1"' sh "$1" "$ROOT/audit-tmp"; }
snapshot "$E/audit.before" || notrun audit "the before-audit could not be stored"

# --- negative canaries, before any real work: unique, pre-absent targets outside the root; each write must be refused ---
for t in "$H/.zb-spike-canary-$NONCE" "${TD%/}/zb-spike-canary-$NONCE" "${CD%/}/zb-spike-canary-$NONCE"; do
  [ ! -e "$t" ] && [ ! -L "$t" ] || notrun canaries "canary target already exists: $t"
  sbx /bin/sh -c ': > "$1"' sh "$t" </dev/null 2>/dev/null; rc=$?
  if [ "$rc" -eq 0 ] || [ -e "$t" ] || [ -L "$t" ]; then
    printf 'PHASE\tcanaries\tBREACH\t%s\n' "$t"
    echo "CONTAINMENT BREACH: a write outside the run root was not refused: $t (kept for the owner; nothing later runs)"
    exit 4
  fi
done
echo "PHASE	canaries	ok	3 refused"

# --- outer command 1: unpack the committed source and build it natively (zig and every xcrun/compiler/linker child) ---
sbx /bin/bash -c '
ROOT=$1
exec > "$ROOT/evidence/build.log" 2>&1
cd "$ROOT" && mkdir repo tmp && tar -xf inputs/src.tar -C repo || { echo "unpack failed"; exit 1; }
cd repo && TMPDIR="$ROOT/tmp" ZIG_LOCAL_CACHE_DIR="$ROOT/zig-cache" ZIG_GLOBAL_CACHE_DIR="$ROOT/zig-global-cache" \
  "$HOME/.local/bin/zig" build --cache-dir "$ROOT/zig-cache" --global-cache-dir "$ROOT/zig-global-cache"
' bash "$ROOT" </dev/null; brc=$?
if [ "$brc" -eq 0 ]; then echo "PHASE	build	ok"; else printf 'PHASE\tbuild\tfail\trc=%d\n' "$brc"; fi

# --- outer command 2: stage with the real stager, refuse escaping symlinks, sign inside out, verify ---
if [ "$brc" -eq 0 ]; then
sbx /bin/bash -c '
ROOT=$1 ARCH=$2 PIN=$3 MUTANT=$4 E=$1/evidence
export TMPDIR="$ROOT/tmp" PYTHONDONTWRITEBYTECODE=1 XDG_CACHE_HOME="$ROOT/xdg-cache"
cd "$ROOT" && mkdir xdg-cache && tar -xf inputs/sites.tar || { echo "PHASE	unpack	fail"; exit 1; }
APP="$ROOT/spike/zigBrowser.app" C="$ROOT/spike/zigBrowser.app/Contents"
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources"
cp repo/zig-out/bin/zigBrowser "$C/MacOS/zigBrowser" && cp repo/zig-out/Frameworks/libwkwebview_shim.dylib "$C/Frameworks/" \
  || { echo "PHASE	stage	fail	no build output"; exit 1; }
sed "s/__VERSION__/0.0.0-spike/g" repo/packaging/macos/Info.plist > "$C/Info.plist"
bash repo/packaging/macos/stage_agent_runtime.sh "$ROOT/inputs/py.pkg" "$PIN" "$C" "$ROOT/site-x86_64" "$ROOT/site-aarch64" \
  > "$E/stage.log" 2>&1 || { echo "PHASE	stage	fail	stage_agent_runtime.sh"; exit 1; }
echo "PHASE	stage	ok"
[ "$MUTANT" = data_in_frameworks ] && printf "stray data\n" > "$C/Frameworks/stray-data.txt"
resolve() { # the physical target of a symlink, chains followed
  local p=$1 n=0 t d
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    t=$(readlink "$p"); case "$t" in /*) p=$t ;; *) p="$(dirname "$p")/$t" ;; esac; n=$((n + 1))
  done
  [ "$n" -lt 40 ] || { echo "$p (a loop)"; return 0; }
  d=$(cd -P "$(dirname "$p")" 2>/dev/null && pwd -P) || { echo "$p"; return 0; }
  echo "$d/$(basename "$p")"
}
escape=0
while IFS= read -r l; do
  r=$(resolve "$l")
  case "$r" in "$ROOT"|"$ROOT"/*) ;; *) escape=$((escape + 1)); echo "escaping symlink: ${l#$ROOT/} -> $r" >> "$E/symlinks.log" ;; esac
done < <(find "$ROOT" -type l)
[ "$escape" -eq 0 ] || { printf "PHASE\tsymlinks\tfail\t%d escape the run root\n" "$escape"; exit 1; }
echo "PHASE	symlinks	ok"
is_macho() { file -b "$1" | grep -q Mach-O; }
data=0
while IFS= read -r f; do is_macho "$f" || data=$((data + 1)); done < <(find "$C/Frameworks" -type f)
printf "SPIKE\tcensus\t%d\n" "$data"
signfail=0
sign() { codesign --force --sign - "$1" >> "$E/sign.log" 2>&1 || { signfail=$((signfail + 1)); echo "sign failed: $1" >> "$E/sign.log"; }; }
while IFS= read -r f; do is_macho "$f" && sign "$f"; done \
  < <(find "$C" -type f | awk -F/ "{ print NF \"\t\" \$0 }" | sort -t "$(printf "\t")" -k1,1nr -k2 | cut -f2-)
while IFS= read -r fw; do
  for v in "$fw"/Versions/*; do [ -d "$v" ] && [ ! -L "$v" ] && sign "$v"; done
done < <(find "$C" -type d -name "*.framework")
sign "$APP"
[ "$signfail" -eq 0 ] || { printf "PHASE\tsign\tfail\t%d\n" "$signfail"; exit 1; }
echo "PHASE	sign	ok"
codesign --verify --strict --deep --verbose=4 "$APP" > "$E/verify.log" 2>&1; vrc=$?
yn() { if grep -qE "$1" "$2"; then echo yes; else echo no; fi; }
printf "VERIFY\trc=%d\tunsealed=%s\tnot-signed=%s\tsealed-resource=%s\tdenied=%s\n" "$vrc" \
  "$(yn "unsealed contents present" "$E/verify.log")" "$(yn "code object is not signed at all" "$E/verify.log")" \
  "$(yn "a sealed resource is missing or invalid" "$E/verify.log")" \
  "$(cat "$E"/*.log | grep -qE "Operation not permitted|Read-only file system|deny\(" && echo yes || echo no)"
' bash "$ROOT" "$ARCH" "$PIN" "$MUTANT" </dev/null 2>/dev/null; prc=$?
if [ "$prc" -eq 0 ]; then echo "PHASE	post	ok"; else printf 'PHASE\tpost\tfail\trc=%d\n' "$prc"; fi
fi

snapshot "$E/audit.after" || echo "PHASE	audit	fail	the after-audit could not be stored"
sbx /bin/sh -c 'cd "$1" && tar -cf evidence.tar evidence' sh "$ROOT" </dev/null || echo "PHASE	evidence	fail"
echo "LEGDONE"
[ "$brc" -eq 0 ] && [ "$prc" -eq 0 ] && exit 0
exit 3
}
main "$@"
