#!/usr/bin/env bash
# Hostless proof of the 4pa.80 spike's write containment (SilverRidge de82cf2): tests/mac/bundle_layout_spike.sh run and
# the leg driver it sends, tests/mac/bundle_layout_spike_leg.sh. The REAL spike runs in a scratch git repo against
# EXECUTING stub ssh/scp: each remote command runs for real in a fake Mac home per host, reached through a symlinked
# $HOME so the physical-root substitution is exercised. /usr/bin is overlaid (private mount namespace) with a fake
# /usr/bin/sandbox-exec and a recording /usr/bin/python3. The fake sandbox-exec records the profile and argv of every
# call and ENFORCES the profile it is given: it runs the command in a nested mount namespace where the fake home is
# read-only except each (subpath "...") the profile allows, so a write the profile does not admit fails (EROFS) and a
# write it admits works. Fake Mac tools (zig, xcrun, file, codesign, uname, getconf) and a stand-in stager (records its
# arguments, calls /usr/bin/python3 and xcrun, stages the documented layout) record whether they ran inside it.
# Rows:
#   K1 clean: exit 0, LAYOUT-OK on both legs, SPIKE-RESULT; per host the sandbox-exec calls are exactly: the profile
#      parse, mkdir <root>/evidence, the positive write, the /dev/null write, the profile and before-audit evidence,
#      the three canaries, then exactly two /bin/bash outer commands (the native build, then the post-build work), then
#      the after-audit and the evidence tar; every profile is the exact four-line profile naming the PHYSICAL root
#      (not the symlinked home) and /dev/null and nothing else; every recorded tool call on the Mac (zig, xcrun,
#      python3, the stager, file, codesign) ran inside the sandbox;
#   K2 the three canaries are <physical home>/.zb-spike-canary-<nonce> and both getconf dirs' zb-spike-canary-<nonce>,
#      attempted before the build, refused, and absent afterwards; the fake homes are byte-for-byte as before;
#   K3 (the old B2-B5) the stager gets <root>/inputs/py.pkg, the commit's pin, the app's Contents and both site trees
#      from the committed agent tree; the verified .app holds the exe, the shim and agent-host; signing is ad hoc,
#      inside out, never --deep; the census counts the non-Mach-O files under Contents/Frameworks;
#   K4 the evidence (driver output, build/stage/sign/verify logs, both audits) is on Linux, the roots are removed;
#   K5 a missing sandbox-exec, a profile parse error, a failed positive write: INCONCLUSIVE NOT RUN on both legs, exit
#      2, no product tool runs, roots removed;
#   K6 a sandbox-exec that does not enforce: the home canary is written, BREACH, exit 4; the canary and the root stay;
#      the arm64 host is never contacted; no product tool runs;
#   K7 ZB_SPIKE_MUTANT=data_in_frameworks with an unsealed verify: EXPECTED-FAIL on both legs, stray-data.txt in the
#      verified tree, census + 1; with a clean verify it is INCONCLUSIVE (verify accepted the mutant);
#   K8 a sandbox denial in verify that also prints a sealed-resource message, under data_in_frameworks: INCONCLUSIVE,
#      never EXPECTED-FAIL; a denied signing tool: INCONCLUSIVE, no verify;
#   K9 a staged symlink that resolves outside the root: INCONCLUSIVE before any signing;
#   K10 an outside write during the leg (audit noise): INCONCLUSIVE, naming the path;
#   K11 an unsealed verify on the arm leg: LAYOUT-FINDING there, LAYOUT-OK on Intel, exit 0; a verify failure with no
#      diagnostic: INCONCLUSIVE, exit 2;
#   K12 no arm64 host, inputs that do not match inputs.sha256, an unknown mutant: exit 1 and no ssh/scp;
#   K13 the driver refuses a regular file as stdout before any sandbox-exec call.
# No Mac, no signal, no network: it re-runs itself in a private user+mount+network namespace.
# Run: bash tests/mac/bundle_layout_spike_containment_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_CONTAIN_SELFTEST_INNER:-}" != 1 ]; then
  ZB_CONTAIN_SELFTEST_INNER=1 exec unshare --user --map-root-user --mount --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-contain-selftest-XXXXXX")
T=$(realpath "$BASE")
P="$T/overlay"
cleanup() {
  umount /usr/bin 2>/dev/null; umount "$P/realusrbin" 2>/dev/null
  if mountpoint -q "$P/realusrbin" 2>/dev/null; then echo "WARN: $P/realusrbin is still mounted; $T left in place" >&2; return; fi
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-contain-selftest-??????) rm -rf --one-file-system "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2 X="$T/x" C="$T/ctl"
PIN=$(printf 'pkg stand-in\n' | sha256sum | cut -c1-64)
APP=spike/zigBrowser.app

# --- the /usr/bin overlay: every real tool stays, plus the fake sandbox-exec and a recording python3 ---
mkdir -p "$P/realusrbin" "$P/usrbin" "$X/bin" "$X/hostbin" "$C" "$T/home" "$T/tmp"
mount --bind /usr/bin "$P/realusrbin" || { echo "FAIL could not bind /usr/bin"; exit 1; }
for f in "$P/realusrbin"/*; do ln -s "$f" "$P/usrbin/${f##*/}"; done
rm -f "$P/usrbin/python3"
printf 'C=%q\nP=%q\nX=%q\n' "$C" "$P" "$X" > "$X/fake.env"
fake() { # fake <path>: a bash script that sources fake.env, body on stdin
  { echo '#!/bin/bash'; echo ". '$X/fake.env'"; cat; } > "$1" && chmod +x "$1"
}
rec='printf "%s\t%s\t%s\t%s\n" "$NAME" "${ZB_FAKE_SANDBOXED:-0}" "${ZB_ROLE:-}" "$*" >> "$C/tools.log"'

fake "$P/usrbin/sandbox-exec" <<'EOF'
[ "${1:-}" = -p ] && [ $# -ge 3 ] || { echo "sandbox-exec: usage" >&2; exit 64; }
prof=$2; shift 2
n=$(cat "$C/sbx.count" 2>/dev/null || echo 0); echo $((n + 1)) > "$C/sbx.count"
printf '%s' "$prof" > "$C/sbx.$n.profile"; printf '%s\0' "$@" > "$C/sbx.$n.argv"; echo "${ZB_ROLE:-}" > "$C/sbx.$n.role"
scen=$(cat "$C/scenario")
[ "$scen" = parse_error ] && { echo "sandbox-exec: syntax error in the profile" >&2; exit 65; }
[ "$scen" = positive_fail ] && [ "$1" = /bin/mkdir ] && exit 1
H=$(cd "$HOME" && pwd -P)
if [ "$scen" = noise ] && [ "$1" = /bin/bash ] && [ ! -e "$C/noise.$ZB_ROLE" ]; then
  : > "$C/noise.$ZB_ROLE"; echo noise > "$H/Library/Caches/com.example.noise"
fi
[ "$scen" = no_enforce ] && exec env ZB_FAKE_SANDBOXED=1 "$@"
mapfile -t allow < <(grep -oE '\(subpath "[^"]*"\)' <<<"$prof" | sed -E 's/^\(subpath "(.*)"\)$/\1/')
exec unshare --mount --propagation private /bin/bash -c '
H=$1 k=$2; shift 2; allow=("${@:1:k}"); shift "$k"
mount --bind "$H" "$H" && mount -o remount,bind,ro "$H" || exit 70
for p in "${allow[@]+"${allow[@]}"}"; do
  [ -d "$p" ] || continue
  mount --bind "$p" "$p" && mount -o remount,bind,rw "$p" || exit 70
done
exec env ZB_FAKE_SANDBOXED=1 "$@"' _ "$H" "${#allow[@]}" "${allow[@]+"${allow[@]}"}" "$@"
EOF
fake "$P/usrbin/python3" <<EOF
NAME=python3; $rec
exec "\$P/realusrbin/python3" "\$@"
EOF
mount --bind "$P/usrbin" /usr/bin || { echo "FAIL could not overlay /usr/bin"; exit 1; }

# --- Linux-side stub ssh/scp: run the command in the host's fake home, through a symlinked HOME, behind pipes ---
fake "$X/bin/ssh" <<EOF
echo "ssh \$*" >> "\$C/calls"
host= skip= k=0
for a in "\$@"; do
  k=\$((k + 1))
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
  host=\$a; break
done
case "\$host" in $INTEL) role=intel arch=x86_64 ;; $ARM) role=arm arch=arm64 ;; *) echo "stub ssh: unexpected host \$host" >&2; exit 99 ;; esac
cd "\$X/homes/\$role" || exit 98
env -i HOME="\$X/homes/\$role" ZB_ROLE=\$role ZB_ARCH=\$arch PATH="\$X/hostbin:/usr/bin:/bin" bash -c "\${*:k+1}" 2> >(cat >&2) | cat
exit "\${PIPESTATUS[0]}"
EOF
fake "$X/bin/scp" <<EOF
echo "scp \$*" >> "\$C/calls"
pos=() skip=
for a in "\$@"; do
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-P|-l) skip=1; continue ;; -*) continue ;; esac
  pos+=("\$a")
done
role_of() { case "\$1" in $INTEL:*) echo intel ;; $ARM:*) echo arm ;; *) echo "stub scp: bad host in \$1" >&2; exit 99 ;; esac; }
dst=\${pos[\${#pos[@]}-1]}; unset 'pos[\${#pos[@]}-1]'
if [[ "\$dst" == *:* ]]; then
  role=\$(role_of "\$dst") || exit 99
  for src in "\${pos[@]}"; do cp "\$src" "\$X/homes/\$role/\${dst#*:}" || exit 1; done
else
  for src in "\${pos[@]}"; do role=\$(role_of "\$src") || exit 99; cp "\$X/homes/\$role/\${src#*:}" "\$dst" || exit 1; done
fi
EOF

# --- fake Mac tools ---
fake "$X/hostbin/uname" <<'EOF'
[ "${1:-}" = -m ] && { echo "$ZB_ARCH"; exit 0; }
exec /usr/bin/uname "$@"
EOF
fake "$X/hostbin/getconf" <<'EOF'
H=$(cd "$HOME" && pwd -P)
case "${1:-}" in
  DARWIN_USER_TEMP_DIR) echo "$H/var/folders/zz/zyxw/T/" ;;
  DARWIN_USER_CACHE_DIR) echo "$H/var/folders/zz/zyxw/C/" ;;
  *) exec /usr/bin/getconf "$@" ;;
esac
EOF
fake "$X/hostbin/file" <<EOF
NAME=file; $rec
[ "\$1" = -b ] && shift
if [ "\$(head -c 5 "\$1" 2>/dev/null)" = MACHO ]; then echo "Mach-O universal binary with 2 architectures"; else echo "ASCII text"; fi
EOF
fake "$X/hostbin/xcrun" <<EOF
NAME=xcrun; $rec
case "\$*" in *--find*python3*) echo /usr/bin/python3 ;; *--show-sdk-path*) echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ;; esac
EOF
fake "$X/hostbin/codesign" <<EOF
NAME=codesign; $rec
n=\$(cat "\$C/codesign.\$ZB_ROLE.count" 2>/dev/null || echo 0); echo \$((n + 1)) > "\$C/codesign.\$ZB_ROLE.count"
tgt=\${@: -1}
rel=\${tgt#*/zb-gate-*/}
a=("\$@"); a[\${#a[@]}-1]=\$rel
printf '%s\0' "\${a[@]}" > "\$C/codesign.\$ZB_ROLE.\$n"
if [ -L "\$tgt" ]; then echo symlink; elif [ -e "\$tgt" ]; then echo present; else echo missing; fi > "\$C/codesign.\$ZB_ROLE.\$n.target"
scen=\$(cat "\$C/scenario")
case " \$* " in
  *" --verify "*) ;;
  *) [ "\$scen" = deny_tool ] && { echo "\$tgt: Operation not permitted"; exit 1; }; exit 0 ;;
esac
(cd "\$tgt" && find . | sort) > "\$C/tree.\$ZB_ROLE"
[ "\$scen" = deny_verify ] && { echo "\$tgt: Operation not permitted"; echo "\$tgt: a sealed resource is missing or invalid"; exit 1; }
mode=\$(cat "\$C/verify_mode") where=\$(cat "\$C/verify_where")
[ "\$where" = both ] || [ "\$where" = "\$ZB_ROLE" ] || mode=clean
case "\$mode" in
  clean) echo "\$tgt: valid on disk"; echo "\$tgt: satisfies its Designated Requirement"; exit 0 ;;
  unsealed) echo "\$tgt: unsealed contents present in the bundle root"; exit 1 ;;
  notsigned) echo "\$tgt: code object is not signed at all"; exit 1 ;;
  generic) echo "\$tgt: internal error in Code Signing subsystem"; exit 1 ;;
esac
EOF

# --- two fake Mac homes, each reached through a symlinked $HOME ---
mkdir -p "$X/homes"
for role in intel arm; do
  h="$X/hosts/$role"
  mkdir -p "$h/.local/bin" "$h/Library/Caches/com.apple.existing" "$h/var/folders/zz/zyxw/T/old" "$h/var/folders/zz/zyxw/C/old"
  echo resident > "$h/Library/Caches/com.apple.existing/data"; echo profile > "$h/.profile"
  ln -s "$h" "$X/homes/$role"
  fake "$h/.local/bin/zig" <<EOF
NAME=zig; $rec
xcrun --show-sdk-path >/dev/null
{ : > "\$HOME/Library/Caches/zig-was-here"; } 2>/dev/null   # an outside write: refused, silently
mkdir -p zig-out/bin zig-out/Frameworks
printf 'MACHO zigBrowser exe stand-in\n' > zig-out/bin/zigBrowser
printf 'MACHO libwkwebview_shim stand-in\n' > zig-out/Frameworks/libwkwebview_shim.dylib
echo "build ok"
EOF
done

# --- the scratch repo: the real spike, leg driver, transport and host keys, the stand-in stager, a committed agent tree ---
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/packaging/macos" "$R/agent/host/zb_agent_host" "$R/src"
cp "$ROOT/tests/mac/bundle_layout_spike.sh" "$ROOT/tests/mac/mac_gate_lib.sh" "$ROOT/tests/mac/build-on-mac.sh" \
  "$ROOT/tests/mac/known_hosts" "$R/tests/mac/"
[ -e "$ROOT/tests/mac/bundle_layout_spike_leg.sh" ] && cp "$ROOT/tests/mac/bundle_layout_spike_leg.sh" "$R/tests/mac/"
cp "$ROOT/packaging/macos/Info.plist" "$R/packaging/macos/"
fake "$R/packaging/macos/stage_agent_runtime.sh" <<EOF
# Selftest stand-in: records its arguments, resolves python like the real stager, stages the documented layout.
NAME=stager; $rec
printf '%s\n' "\$@" > "\$C/stager.\$ZB_ROLE"
REPO=\$(cd "\$(dirname "\$0")/../.." && pwd)
cat "\$REPO/agent/host/marker" > "\$C/agent-tree.\$ZB_ROLE"
xcrun --find python3 >/dev/null
/usr/bin/python3 -I -c 'import sys' || exit 1
[ -s "\$1" ] && [ -d "\$4" ] && [ -d "\$5" ] || { echo "stand-in stager: missing input" >&2; exit 1; }
A="\$3/Frameworks/agent-host"; V="\$A/Python.framework/Versions/3.12"
mkdir -p "\$V/bin" "\$V/lib/python3.12" "\$A/zb_agent_host" "\$A/site-packages/claude_agent_sdk/_bundled" "\$A/site-packages/rpds"
printf 'MACHO\n' > "\$V/Python"; printf 'MACHO\n' > "\$V/bin/python3.12"; printf 'import sys\n' > "\$V/lib/python3.12/os.py"
ln -s 3.12 "\$A/Python.framework/Versions/Current"
printf 'MACHO\n' > "\$A/site-packages/claude_agent_sdk/_bundled/claude"; printf 'MACHO\n' > "\$A/site-packages/rpds/rpds.so"
printf '# agent\n' > "\$A/zb_agent_host/__init__.py"; printf '{}\n' > "\$A/runtime.json"
[ "\$(cat "\$C/scenario")" = escape ] && ln -s "\$HOME/.profile" "\$A/site-packages/escape-link"
exit 0
EOF
echo committed > "$R/agent/host/marker"; echo "# host" > "$R/agent/host/zb_agent_host/__init__.py"
cat > "$R/packaging/macos/agent_runtime_pins.json" <<EOF
{"python_pkg": {"url": "https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg", "sha256": "$PIN",
  "sigstore_identity": "selftest@python.org", "sigstore_issuer": "https://selftest.invalid"},
 "uv_lock_sha256": "$(printf '%064d' 2)",
 "sigstore_verifier": {"requirements": "packaging/macos/sigstore_verifier.txt", "sha256": "$(printf '%064d' 3)"}}
EOF
echo "// stand-in" > "$R/src/main.zig"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
echo uncommitted > "$R/agent/host/marker"
SHA=$("${G[@]}" rev-parse HEAD)
DATA=3   # the stand-in's non-Mach-O files under Contents/Frameworks: os.py, __init__.py, runtime.json

IN="$T/prep"
mkdir -p "$IN" "$T/sites/site-x86_64" "$T/sites/site-aarch64"
echo "pkg stand-in" > "$IN/py.pkg"
(cd "$T/sites" && tar -cf "$IN/sites.tar" site-x86_64 site-aarch64)
(cd "$IN" && sha256sum py.pkg sites.tar > inputs.sha256)
homes_snapshot() { (cd "$X/hosts" && find . -mindepth 2 ! -path './*/zb-gate-*' -printf '%p|%y|%m|%s|%T@\n' | sort); }

run_spike() { # run_spike <label> <scenario> <verify mode> <where> [VAR=value ...]: sets rc, out
  local label=$1 scen=$2 mode=$3 where=$4; shift 4
  rm -rf "${C:?}"/* "${IN:?}/evidence"
  echo "$scen" > "$C/scenario"; echo "$mode" > "$C/verify_mode"; echo "$where" > "$C/verify_where"
  homes_snapshot > "$T/homes.before"
  (cd "$R" && env -i PATH="$X/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/home/no_such_key" "$@" timeout 300 bash tests/mac/bundle_layout_spike.sh run "$IN" \
     >"$T/out.$label" 2>&1 </dev/null)
  rc=$?
  out=$(cat "$T/out.$label")
}
roots_left() { find "$X/hosts" -maxdepth 2 -name 'zb-gate-*' 2>/dev/null; }
check_removed() { # <label>
  local left; left=$(roots_left)
  [ -z "$left" ] && ok "$1: every run root is removed" || bad "$1: run roots left: $left"
}
leg_class() { awk -F'\t' -v a="$1" '$1 == "LEG" && $2 == a { print $4 }' <<<"$out" | tail -n 1; }
leg_detail() { awk -F'\t' -v a="$1" '$1 == "LEG" && $2 == a { print $5 }' <<<"$out" | tail -n 1; }
product_calls() { grep -cE '^(zig|stager|codesign)	' "$C/tools.log" 2>/dev/null || true; }
root_of() { # <role>: the physical run root named in the sandbox-exec calls
  local f
  for f in "$C"/sbx.*.role; do
    [ -e "$f" ] && [ "$(cat "$f")" = "$1" ] || continue
    tr '\0' '\n' < "${f%.role}.argv" | grep -oE "^$X/hosts/$1/zb-gate-$SHA-[0-9a-f]+" | head -n 1 && return
  done
}

# sbx_sequence <role>: one token per sandbox-exec call, in order
sbx_sequence() {
  local role=$1 n=0 r a last seq=() H="$X/hosts/$1" rt
  rt=$(root_of "$role")
  while [ -e "$C/sbx.$n.argv" ]; do
    if [ "$(cat "$C/sbx.$n.role")" = "$role" ]; then
      mapfile -d '' a < "$C/sbx.$n.argv"
      last=${a[${#a[@]}-1]}
      case "${a[0]}|${a[2]:-}|$last" in
        /usr/bin/true*) seq+=(parse) ;;
        "/bin/mkdir||$rt/evidence") seq+=(mkdir-evidence) ;;
        "/bin/sh|: > \"\$1\"|$rt/evidence/positive") seq+=(positive) ;;
        "/bin/sh|: > /dev/null|: > /dev/null") seq+=(devnull) ;;
        "/bin/sh|cat > \"\$1\"|$rt/evidence/profile") seq+=(profile) ;;
        "/bin/sh|cat > \"\$1\"|$rt/evidence/audit.before") seq+=(audit-before) ;;
        "/bin/sh|cat > \"\$1\"|$rt/evidence/audit.after") seq+=(audit-after) ;;
        "/bin/sh|: > \"\$1\"|$H/.zb-spike-canary-"*) seq+=(canary-home) ;;
        "/bin/sh|: > \"\$1\"|$H/var/folders/zz/zyxw/T/zb-spike-canary-"*) seq+=(canary-temp) ;;
        "/bin/sh|: > \"\$1\"|$H/var/folders/zz/zyxw/C/zb-spike-canary-"*) seq+=(canary-cache) ;;
        "/bin/sh|cd \"\$1\" && tar -cf evidence.tar evidence|$rt") seq+=(evidence-tar) ;;
        "/bin/bash|"*) if [ "${a[3]:-}" = bash ] && [ "${a[4]:-}" = "$rt" ]; then
                         case "${a[2]}" in *'zig" build'*) seq+=(build) ;; *stage_agent_runtime.sh*) seq+=(post) ;; *) seq+=(bash-other) ;; esac
                       else seq+=(bash-bad-args); fi ;;
        *) seq+=("other:${a[0]}") ;;
      esac
    fi
    n=$((n + 1))
  done
  echo "${seq[*]}"
}
WANT_SEQ="parse mkdir-evidence positive devnull profile audit-before canary-home canary-temp canary-cache build post audit-after evidence-tar"

US=$'\x1f'
check_signing() { # check_signing <label> <role>: the old B4 on the recorded codesign calls
  local before=$fails label=$1 role=$2 f k id deep verify strict vdeep tgt kind i
  local -a a calls=() macho=()
  for f in $(ls "$C" | grep -E "^codesign\.$role\.[0-9]+$" | sort -t. -k3 -n); do
    mapfile -d '' a < "$C/$f"
    id= deep=no verify=no strict=no vdeep=no
    for ((k = 0; k < ${#a[@]}; k++)); do
      case "${a[k]}" in -s|--sign) id=${a[k+1]:-} ;; --deep) deep=yes; vdeep=yes ;; --verify|-v) verify=yes ;; --strict*) strict=yes ;; esac
    done
    tgt=${a[${#a[@]}-1]}
    calls+=("$tgt$US$id$US$deep$US$verify$US$strict$US$vdeep$US$(cat "$C/$f.target")")
  done
  local n=${#calls[@]} last_file=-1 first_dir=-1 app_idx=-1 ver_idx=-1
  for ((i = 0; i < n; i++)); do
    IFS=$US read -r tgt id deep verify strict vdeep kind <<<"${calls[i]}"
    if [ "$verify" = yes ]; then
      [ "$i" -eq $((n - 1)) ] || bad "$label K3 $role: the verify call is not the last codesign call"
      [ "$strict" = yes ] && [ "$vdeep" = yes ] || bad "$label K3 $role: the verify call lacks --strict or --deep"
      [ "$tgt" = "$APP" ] || bad "$label K3 $role: verify targets '$tgt', want $APP"
      continue
    fi
    [ "$id" = - ] || bad "$label K3 $role: '$tgt' signed with identity '$id', want '-'"
    [ "$deep" = no ] || bad "$label K3 $role: '$tgt' signed with --deep"
    [ "$kind" != symlink ] || bad "$label K3 $role: the symlink '$tgt' was signed"
    case "$tgt" in "$APP") app_idx=$i ;; */Python.framework/Versions/3.12) ver_idx=$i ;; esac
    case "$tgt" in *.app|*/Versions/3.12) [ "$first_dir" -ge 0 ] || first_dir=$i ;; *) last_file=$i; macho+=("$tgt") ;; esac
  done
  local want_files
  want_files=$(printf '%s\n' "$APP/Contents/MacOS/zigBrowser" "$APP/Contents/Frameworks/libwkwebview_shim.dylib" \
    "$APP/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/Python" \
    "$APP/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12" \
    "$APP/Contents/Frameworks/agent-host/site-packages/claude_agent_sdk/_bundled/claude" \
    "$APP/Contents/Frameworks/agent-host/site-packages/rpds/rpds.so" | sort)
  [ "$(printf '%s\n' "${macho[@]+"${macho[@]}"}" | sort)" = "$want_files" ] \
    || bad "$label K3 $role: the signed files are not exactly the six Mach-O files once each: ${macho[*]+"${macho[*]}"}"
  { [ "$last_file" -lt "$first_dir" ] && [ "$ver_idx" -ge 0 ] && [ "$app_idx" -gt "$ver_idx" ] && [ "$app_idx" -eq $((n - 2)) ]; } \
    || bad "$label K3 $role: order is not files, then Versions/3.12, then the .app (files end $last_file, dirs start $first_dir, version $ver_idx, app $app_idx of $n)"
  local depth prev=999
  for tgt in "${macho[@]+"${macho[@]}"}"; do
    depth=$(tr -cd / <<<"$tgt" | wc -c)
    [ "$depth" -le "$prev" ] || bad "$label K3 $role: '$tgt' was signed after a shallower file (not deepest first)"
    prev=$depth
  done
  [ "$fails" -eq "$before" ] && ok "$label K3 $role: ad hoc, never --deep; six Mach-O files deepest first, then Versions/3.12, then the .app; verify --strict --deep last"
}

# ===== K1-K4: clean =====
run_spike clean none clean both
if [ "$rc" -eq 0 ] && [ "$(leg_class x86_64)" = LAYOUT-OK ] && [ "$(leg_class arm64)" = LAYOUT-OK ] \
   && grep -qxF "$(printf 'SPIKE-RESULT\t%s\tnone\tx86_64=LAYOUT-OK\tarm64=LAYOUT-OK' "$SHA")" <<<"$out"; then
  ok "clean K1: exit 0, LAYOUT-OK on both legs, SPIKE-RESULT for $SHA"
else bad "clean K1: exit $rc: $(grep -E '^(LEG|SPIKE-RESULT|PHASE)|FAIL|NOT RUN' <<<"$out" | tail -n 6 | tr '\n' ' ')"; fi
for role in intel arm; do
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  rt=$(root_of "$role")
  seq=$(sbx_sequence "$role")
  [ "$seq" = "$WANT_SEQ" ] && ok "clean K1 $role: sandbox-exec calls are exactly: $seq" \
    || bad "clean K1 $role: sandbox-exec calls are '$seq', want '$WANT_SEQ'"
  want_prof=$(printf '(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write* (subpath "%s") (literal "/dev/null"))' "$rt")
  nprof=0 badprof=0
  for f in "$C"/sbx.*.role; do
    [ -e "$f" ] && [ "$(cat "$f")" = "$role" ] || continue
    nprof=$((nprof + 1)); [ "$(cat "${f%.role}.profile")" = "$want_prof" ] || badprof=$((badprof + 1))
  done
  if [ -n "$rt" ] && [[ "$rt" == "$X/hosts/$role/zb-gate-$SHA-"* ]] && [ "$nprof" -gt 0 ] && [ "$badprof" -eq 0 ]; then
    ok "clean K1 $role: all $nprof profiles are the exact four lines, write grant only the physical root $rt and /dev/null"
  else bad "clean K1 $role: root '$rt', $badprof of $nprof profiles differ from: $want_prof"; fi
  unwrapped=$(awk -F'\t' -v r="$role" '$3 == r && $2 != 1 { print $1 ": " $4 }' "$C/tools.log" 2>/dev/null)
  seen=$(awk -F'\t' -v r="$role" '$3 == r { print $1 }' "$C/tools.log" 2>/dev/null | sort -u | tr '\n' ' ')
  if [ -z "$unwrapped" ] && [ "$seen" = "codesign file python3 stager xcrun zig " ]; then
    ok "clean K1 $role: every Mac tool call ran inside the sandbox ($seen)"
  else bad "clean K1 $role: tools seen '$seen'; outside the sandbox: $(tr '\n' ';' <<<"$unwrapped")"; fi
  # K2
  nonce=${rt##*-} H="$X/hosts/$role"
  can=()
  for n in $(seq 0 40); do
    [ -e "$C/sbx.$n.role" ] && [ "$(cat "$C/sbx.$n.role")" = "$role" ] || continue
    mapfile -d '' a < "$C/sbx.$n.argv"; case "${a[${#a[@]}-1]}" in *zb-spike-canary-*) can+=("${a[${#a[@]}-1]}") ;; esac
  done
  wantc="$H/.zb-spike-canary-$nonce $H/var/folders/zz/zyxw/T/zb-spike-canary-$nonce $H/var/folders/zz/zyxw/C/zb-spike-canary-$nonce"
  if [ "${can[*]+"${can[*]}"}" = "$wantc" ] && grep -qP '^PHASE\tcanaries\tok\t3 refused$' "$IN"/evidence/"$arch"-*/driver.out 2>/dev/null \
     && ! ls "${can[@]}" >/dev/null 2>&1; then
    ok "clean K2 $role: the three canaries (home, getconf temp, getconf cache) were refused and are absent"
  else bad "clean K2 $role: canaries '${can[*]+"${can[*]}"}', want '$wantc'"; fi
  # K3
  mapfile -t sa < <(cat "$C/stager.$role" 2>/dev/null)
  if [ "${sa[0]:-}" = "$rt/inputs/py.pkg" ] && [ "${sa[1]:-}" = "$PIN" ] && [ "${sa[2]:-}" = "$rt/$APP/Contents" ] \
     && [ "${sa[3]:-}" = "$rt/site-x86_64" ] && [ "${sa[4]:-}" = "$rt/site-aarch64" ] \
     && [ "$(cat "$C/agent-tree.$role" 2>/dev/null)" = committed ]; then
    ok "clean K3 $role: the stager gets <root>/inputs/py.pkg, the pin, the app's Contents and both site trees, from the committed tree"
  else bad "clean K3 $role: stager args '${sa[*]:-}', agent tree '$(cat "$C/agent-tree.$role" 2>/dev/null)'"; fi
  tree=$(cat "$C/tree.$role" 2>/dev/null)
  if grep -qx ./Contents/MacOS/zigBrowser <<<"$tree" && grep -qx ./Contents/Frameworks/libwkwebview_shim.dylib <<<"$tree" \
     && grep -qx ./Contents/Frameworks/agent-host/runtime.json <<<"$tree" && ! grep -q stray-data <<<"$tree"; then
    ok "clean K3 $role: the verified .app holds the exe, the shim and agent-host, and no stray data"
  else bad "clean K3 $role: the verified tree is: $(tr '\n' ' ' <<<"$tree")"; fi
  check_signing clean "$role"
  grep -qP "^SPIKE\tcensus\t$DATA$" "$IN"/evidence/"$arch"-*/driver.out 2>/dev/null \
    && ok "clean K3 $role: the census counts $DATA data files under Frameworks" || bad "clean K3 $role: census line missing or not $DATA"
  # K4
  ev=$(ls -d "$IN"/evidence/"$arch"-zb-gate-"$SHA"-* 2>/dev/null | head -n 1)
  missing=
  for f in driver.out evidence/build.log evidence/verify.log evidence/audit.before evidence/audit.after evidence/profile; do
    [ -s "$ev/$f" ] || missing+="$f "
  done
  for f in evidence/stage.log evidence/sign.log; do [ -e "$ev/$f" ] || missing+="$f "; done
  [ -n "$ev" ] && [ -z "$missing" ] && grep -qx LEGDONE "$ev/driver.out" \
    && ok "clean K4 $role: driver output, logs and both audits are in $IN/evidence" || bad "clean K4 $role: evidence '$ev' lacks: $missing"
done
check_removed "clean K4"
homes_snapshot > "$T/homes.after"
cmp -s "$T/homes.before" "$T/homes.after" && ok "clean K2: the fake Mac homes are exactly as before (outside the removed roots)" \
  || bad "clean K2: the fake homes changed: $(diff "$T/homes.before" "$T/homes.after" | grep -E '^[<>]' | head -n 4 | tr '\n' ' ')"

# ===== K5: safe NOT RUN =====
for scen in missing parse_error positive_fail; do
  [ "$scen" = missing ] && chmod -x "$P/usrbin/sandbox-exec"
  run_spike "$scen" "$scen" clean both
  [ "$scen" = missing ] && chmod +x "$P/usrbin/sandbox-exec"
  case "$scen" in missing|parse_error) want=preflight ;; positive_fail) want=positive ;; esac
  if [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [ "$(leg_class arm64)" = INCONCLUSIVE ] \
     && [[ "$(leg_detail x86_64)" == "$want: "* ]] && [ "$(product_calls)" = 0 ]; then
    ok "$scen K5: INCONCLUSIVE ($(leg_detail x86_64)) on both legs, exit 2, no product tool ran"
  else bad "$scen K5: exit $rc, intel '$(leg_class x86_64): $(leg_detail x86_64)', product calls $(product_calls)"; fi
  check_removed "$scen K5"
done

# ===== K6: a non-refused canary is a BREACH =====
run_spike breach no_enforce clean both
canary=$(ls -A "$X/hosts/intel" | grep '^\.zb-spike-canary-' | head -n 1)
if [ "$rc" -eq 4 ] && [ "$(leg_class x86_64)" = BREACH ] && [ -z "$(leg_class arm64)" ] && [ -n "$canary" ] \
   && [[ "$(leg_detail x86_64)" == "$X/hosts/intel/$canary (root "* ]] && grep -q 'CONTAINMENT BREACH' <<<"$out" \
   && ! grep -q "$ARM" "$C/calls" && [ "$(product_calls)" = 0 ] && [ -d "$(roots_left | head -n 1)" ]; then
  ok "breach K6: BREACH names $canary, exit 4; the canary and the root are kept; arm64 never contacted; no product tool ran"
else bad "breach K6: exit $rc, intel '$(leg_class x86_64): $(leg_detail x86_64)', arm '$(leg_class arm64)', canary '$canary', roots '$(roots_left)'"; fi
rm -rf "$X/hosts/intel/"zb-gate-* "$X/hosts/intel/".zb-spike-canary-*

# ===== K7: the data_in_frameworks mutant =====
run_spike mutant none unsealed both ZB_SPIKE_MUTANT=data_in_frameworks
if [ "$rc" -eq 0 ] && [ "$(leg_class x86_64)" = EXPECTED-FAIL ] && [ "$(leg_class arm64)" = EXPECTED-FAIL ] \
   && grep -qx ./Contents/Frameworks/stray-data.txt "$C/tree.intel" && grep -qx ./Contents/Frameworks/stray-data.txt "$C/tree.arm" \
   && [ "$(grep -hP '^SPIKE\tcensus\t' "$IN"/evidence/*/driver.out | sort -u)" = "$(printf 'SPIKE\tcensus\t%d' $((DATA + 1)))" ]; then
  ok "mutant K7: EXPECTED-FAIL on both legs; stray-data.txt in the verified tree, census $((DATA + 1))"
else bad "mutant K7: exit $rc, '$(leg_class x86_64)' '$(leg_class arm64)'"; fi
run_spike mutant_clean none clean both ZB_SPIKE_MUTANT=data_in_frameworks
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [[ "$(leg_detail x86_64)" == *"accepted the data_in_frameworks mutant"* ]]; } \
  && ok "mutant_clean K7: a verify that accepts the mutant is INCONCLUSIVE, exit 2" || bad "mutant_clean K7: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)'"

# ===== K8: a sandbox denial is never product evidence =====
run_spike deny_verify deny_verify clean both ZB_SPIKE_MUTANT=data_in_frameworks
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [ "$(leg_class arm64)" = INCONCLUSIVE ] \
  && [[ "$(leg_detail x86_64)" == *"denied"* ]] && ! grep -q EXPECTED-FAIL <<<"$out"; } \
  && ok "deny_verify K8: a denied verify with a sealed-resource message is INCONCLUSIVE, never EXPECTED-FAIL" \
  || bad "deny_verify K8: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)'"
check_removed "deny_verify K8"
run_spike deny_tool deny_tool clean both
nverify=$(grep -c -- '--verify' "$C/tools.log" 2>/dev/null || true)
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [[ "$(leg_detail x86_64)" == "sign: "* ]] && [ "$nverify" = 0 ]; } \
  && ok "deny_tool K8: a denied signing tool is INCONCLUSIVE ($(leg_detail x86_64)), no verify" \
  || bad "deny_tool K8: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)', verify calls $nverify"

# ===== K9: an escaping symlink =====
run_spike escape escape clean both
nsign=$(grep -c '^codesign	' "$C/tools.log" 2>/dev/null || true)
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [[ "$(leg_detail x86_64)" == "symlinks: 1 escape"* ]] && [ "$nsign" = 0 ]; } \
  && ok "escape K9: a staged symlink to outside the root is INCONCLUSIVE before any signing" \
  || bad "escape K9: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)', codesign calls $nsign"
check_removed "escape K9"

# ===== K10: an outside write during the leg =====
run_spike noise noise clean both
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [[ "$(leg_detail x86_64)" == "audit delta"*com.example.noise* ]]; } \
  && ok "noise K10: an outside write during the leg is an audit delta, INCONCLUSIVE" \
  || bad "noise K10: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)'"
rm -f "$X/hosts/intel/Library/Caches/com.example.noise" "$X/hosts/arm/Library/Caches/com.example.noise"

# ===== K11: findings and inconclusive verify =====
run_spike finding none unsealed arm
{ [ "$rc" -eq 0 ] && [ "$(leg_class x86_64)" = LAYOUT-OK ] && [ "$(leg_class arm64)" = LAYOUT-FINDING ]; } \
  && ok "finding K11: an unsealed verify on arm64 is LAYOUT-FINDING, Intel LAYOUT-OK, exit 0" \
  || bad "finding K11: exit $rc, '$(leg_class x86_64)' '$(leg_class arm64)'"
run_spike generic none generic intel
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [ "$(leg_class arm64)" = LAYOUT-OK ]; } \
  && ok "generic K11: a verify failure with no code-signature diagnostic is INCONCLUSIVE, exit 2" \
  || bad "generic K11: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)' '$(leg_class arm64)'"

# ===== K12: refusals before any host is touched =====
run_spike noarm none clean both ZB_MAC_ARM_HOST=
{ [ "$rc" -eq 1 ] && grep -q 'NOT RUN: arm64 host not configured' <<<"$out" && [ ! -s "$C/calls" ]; } \
  && ok "noarm K12: NOT RUN, exit 1, no ssh/scp" || bad "noarm K12: exit $rc"
run_spike badmutant none clean both ZB_SPIKE_MUTANT=other
{ [ "$rc" -eq 1 ] && grep -q 'REFUSED: unknown ZB_SPIKE_MUTANT' <<<"$out" && [ ! -s "$C/calls" ]; } \
  && ok "badmutant K12: refused, exit 1, no ssh/scp" || bad "badmutant K12: exit $rc"
cp "$IN/py.pkg" "$T/py.pkg.good"; echo tampered >> "$IN/py.pkg"
run_spike tampered none clean both
{ [ "$rc" -eq 1 ] && grep -q 'do not match inputs.sha256' <<<"$out" && [ ! -s "$C/calls" ]; } \
  && ok "tampered K12: inputs that do not match inputs.sha256 are refused, no ssh/scp" || bad "tampered K12: exit $rc"
cp "$T/py.pkg.good" "$IN/py.pkg"

# ===== K13: no regular file as the driver's stdout =====
rm -rf "${C:?}"/*; echo none > "$C/scenario"
RDX="zb-gate-$SHA-0123abcd"
DRV="$R/tests/mac/bundle_layout_spike_leg.sh"
(cd "$X/homes/intel" && env -i HOME="$X/homes/intel" ZB_ROLE=intel ZB_ARCH=x86_64 PATH="$X/hostbin:/usr/bin:/bin" \
   bash -s create "$RDX" < "$DRV" | cat >/dev/null
 env -i HOME="$X/homes/intel" ZB_ROLE=intel ZB_ARCH=x86_64 PATH="$X/hostbin:/usr/bin:/bin" \
   bash -s run "$RDX" x86_64 "$PIN" none < "$DRV" > "$T/k13.out" 2>/dev/null)
k13=$?
{ [ "$k13" -eq 3 ] && grep -qP '^PHASE\tdescriptors\tNOT-RUN\tfd 1 is a regular file$' "$T/k13.out" && [ ! -e "$C/sbx.0.argv" ]; } \
  && ok "fd K13: a regular-file stdout is NOT RUN before any sandbox-exec call" || bad "fd K13: exit $k13: $(cat "$T/k13.out" 2>/dev/null)"
rm -rf "$X/hosts/intel/$RDX"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-bundle-layout-spike-containment-selftest\n'; exit 0; fi
printf 'FAIL\tmac-bundle-layout-spike-containment-selftest\t%s failure(s)\n' "$fails"
exit 1
