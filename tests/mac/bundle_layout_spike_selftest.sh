#!/usr/bin/env bash
# Hostless selftest of the 4pa.80 bundle-layout spike's run phase, tests/mac/bundle_layout_spike.sh run (plan R30-MS9).
# The REAL spike (with the real build-on-mac.sh and mac_gate_lib.sh) runs in a scratch git repo against EXECUTING stub
# ssh/scp: every remote command and script runs for real in a fake Mac home per host, with fake Mac tools (zig, uname,
# file, codesign) that record what they get. packaging/macos/stage_agent_runtime.sh is replaced in the scratch repo by
# a stand-in that records its arguments and stages the layout the real one documents (agent-host under
# Contents/Frameworks: Python.framework with a Current symlink, zb_agent_host/*.py, runtime.json, site-packages with an
# extension module and the CLI); the real stager is proven by its own MS5 gates. The fake codesign answers --verify as
# the scenario says and keeps a listing of the .app at that moment. Rows:
#   B1 clean: exit 0, a PASS line per leg, then PASS bundle-layout-spike both-arches <the commit>;
#   B2 the stager gets the leg's run-dir pkg, rev 15's pin, prefix <run dir>/spike/zigBrowser.app/Contents and both
#      site trees, and the agent tree it stages from is the committed one (an uncommitted edit stays off the Mac);
#   B3 at verify time the .app holds the exe, the shim in Contents/Frameworks and the staged agent-host, and no
#      stray-data.txt;
#   B4 signing is ad hoc and inside out, never --deep: every Mach-O file once, deepest first, before any directory;
#      the framework version (Versions/3.12, not the Current symlink) after the files; the .app last; the verify call
#      is --verify --strict --deep;
#   B5 the census line counts the non-Mach-O files under Contents/Frameworks;
#   B6 a verify that reports "unsealed contents present", "code object is not signed at all", or only fails, fails that
#      leg and the run (exit 1, no both-arches PASS line);
#   B7 ZB_SPIKE_MUTANT=data_in_frameworks puts Contents/Frameworks/stray-data.txt into the signed tree (census + 1);
#   B8 every run dir is gone afterwards;
#   B9 no arm64 host, prep inputs that do not match inputs.sha256, or an unknown mutant: exit 1 and no ssh/scp call.
# No Mac, no signal: it re-runs itself in a private user+network namespace; HOME/TMPDIR live in its temp tree.
# Run: bash tests/mac/bundle_layout_spike_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_SPIKE_SELFTEST_INNER:-}" != 1 ]; then
  ZB_SPIKE_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-spike-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-spike-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2 X="$T/x" C="$T/ctl"
PIN=8373e58da4ea146b3eb1c1f9834f19a319440b6b679b06050b1f9ee3237aa8e4
APP=spike/zigBrowser.app

mkdir -p "$X/bin" "$X/hostbin" "$X/hosts/intel/.local/bin" "$X/hosts/arm/.local/bin" "$C" "$T/home" "$T/tmp"
cat > "$X/bin/ssh" <<EOF
#!/bin/bash
echo ssh >> "$C/calls"
host= skip= k=0
for a in "\$@"; do
  k=\$((k + 1))
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
  host=\$a; break
done
case "\$host" in $INTEL) role=intel arch=x86_64 ;; $ARM) role=arm arch=arm64 ;; *) echo "stub ssh: unexpected host \$host" >&2; exit 99 ;; esac
cd "$X/hosts/\$role" && exec env -i HOME="$X/hosts/\$role" ZB_ROLE=\$role ZB_ARCH=\$arch PATH="$X/hostbin:/usr/bin:/bin" bash -c "\${*:k+1}"
EOF
cat > "$X/bin/scp" <<EOF
#!/bin/bash
echo scp >> "$C/calls"
pos=() skip=
for a in "\$@"; do
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-P|-l) skip=1; continue ;; -*) continue ;; esac
  pos+=("\$a")
done
dst=\${pos[\${#pos[@]}-1]}; unset 'pos[\${#pos[@]}-1]'
case "\$dst" in $INTEL:*) role=intel ;; $ARM:*) role=arm ;; *) echo "stub scp: bad target \$dst" >&2; exit 99 ;; esac
for src in "\${pos[@]}"; do cp "\$src" "$X/hosts/\$role/\${dst#*:}" || exit 1; done
EOF
cat > "$X/hostbin/uname" <<'EOF'
#!/bin/bash
[ "$1" = -m ] && { echo "$ZB_ARCH"; exit 0; }
exec /usr/bin/uname "$@"
EOF
cat > "$X/hostbin/file" <<'EOF'
#!/bin/bash
[ "$1" = -b ] && shift
if [ "$(head -c 5 "$1" 2>/dev/null)" = MACHO ]; then echo "Mach-O universal binary with 2 architectures"; else echo "ASCII text"; fi
EOF
cat > "$X/hostbin/codesign" <<EOF
#!/bin/bash
n=\$(ls "$C" | grep -c "^codesign\.\$ZB_ROLE\.[0-9]*\$" || true)
printf '%s\0' "\$@" > "$C/codesign.\$ZB_ROLE.\$n"
tgt=\${@: -1}
if [ -L "\$tgt" ]; then echo symlink; elif [ -e "\$tgt" ]; then echo present; else echo missing; fi > "$C/codesign.\$ZB_ROLE.\$n.target"
case " \$* " in *" --verify "*) ;; *) exit 0 ;; esac
(cd "\$tgt" && find . | sort) > "$C/tree.\$ZB_ROLE"
mode=\$(cat "$C/verify_mode") where=\$(cat "$C/verify_where")
[ "\$where" = both ] || [ "\$where" = "\$ZB_ROLE" ] || mode=clean
case "\$mode" in
  clean) echo "\$tgt: valid on disk"; echo "\$tgt: satisfies its Designated Requirement"; exit 0 ;;
  unsealed) echo "\$tgt: unsealed contents present in the bundle root"; exit 1 ;;
  notsigned) echo "\$tgt: code object is not signed at all"; echo "In subcomponent: \$tgt/Contents/Frameworks/agent-host/runtime.json"; exit 1 ;;
  rc1) echo "\$tgt: a sealed resource is missing or invalid"; exit 1 ;;
esac
EOF
for role in intel arm; do
  cat > "$X/hosts/$role/.local/bin/zig" <<'EOF'
#!/bin/bash
[ "$1" = version ] && { echo 0.16.0; exit 0; }
mkdir -p zig-out/bin zig-out/Frameworks
printf 'MACHO zigBrowser exe stand-in\n' > zig-out/bin/zigBrowser
printf 'MACHO libwkwebview_shim stand-in\n' > zig-out/Frameworks/libwkwebview_shim.dylib
echo "build ok"
EOF
done
chmod +x "$X/bin"/* "$X/hostbin"/* "$X/hosts"/*/.local/bin/zig

# The scratch repo: the real spike, build step, library and host keys, the stand-in stager, and an agent tree whose
# marker is committed as "committed" and then edited (uncommitted).
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/packaging/macos" "$R/agent/host/zb_agent_host" "$R/src"
cp "$ROOT/tests/mac/bundle_layout_spike.sh" "$ROOT/tests/mac/build-on-mac.sh" "$ROOT/tests/mac/mac_gate_lib.sh" \
  "$ROOT/tests/mac/known_hosts" "$R/tests/mac/"
cp "$ROOT/packaging/macos/Info.plist" "$R/packaging/macos/"
cat > "$R/packaging/macos/stage_agent_runtime.sh" <<EOF
#!/bin/bash
# Selftest stand-in: records its arguments and stages the documented layout under <prefix>/Frameworks/agent-host.
printf '%s\n' "\$@" > "$C/stager.\$ZB_ROLE"
cat agent/host/marker > "$C/agent-tree.\$ZB_ROLE"
[ -s "\$1" ] && [ -d "\$4" ] && [ -d "\$5" ] || { echo "stand-in stager: missing input" >&2; exit 1; }
A="\$3/Frameworks/agent-host"; V="\$A/Python.framework/Versions/3.12"
mkdir -p "\$V/bin" "\$V/lib/python3.12" "\$A/zb_agent_host" "\$A/site-packages/claude_agent_sdk/_bundled" "\$A/site-packages/rpds"
printf 'MACHO\n' > "\$V/Python"; printf 'MACHO\n' > "\$V/bin/python3.12"; printf 'import sys\n' > "\$V/lib/python3.12/os.py"
ln -s 3.12 "\$A/Python.framework/Versions/Current"
printf 'MACHO\n' > "\$A/site-packages/claude_agent_sdk/_bundled/claude"; printf 'MACHO\n' > "\$A/site-packages/rpds/rpds.so"
printf '# agent\n' > "\$A/zb_agent_host/__init__.py"; printf '{}\n' > "\$A/runtime.json"
EOF
chmod +x "$R/packaging/macos/stage_agent_runtime.sh"
echo committed > "$R/agent/host/marker"; echo "# host" > "$R/agent/host/zb_agent_host/__init__.py"
echo "// stand-in" > "$R/src/main.zig"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
echo uncommitted > "$R/agent/host/marker"
SHA=$("${G[@]}" rev-parse HEAD)
# The non-Mach-O files the stand-in stager puts under Contents/Frameworks: os.py, __init__.py, runtime.json.
DATA=3

IN="$T/prep"
mkdir -p "$IN" "$T/sites/site-x86_64" "$T/sites/site-aarch64"
echo "pkg stand-in" > "$IN/py.pkg"
(cd "$T/sites" && tar -cf "$IN/sites.tar" site-x86_64 site-aarch64)
(cd "$IN" && sha256sum py.pkg sites.tar > inputs.sha256)

run_spike() { # run_spike <label> <verify mode> <where> [VAR=value ...]: sets rc, out
  local label=$1 mode=$2 where=$3; shift 3
  rm -rf "${C:?}"/*; echo "$mode" > "$C/verify_mode"; echo "$where" > "$C/verify_where"
  (cd "$R" && env -i PATH="$X/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/home/no_such_key" "$@" timeout 300 bash tests/mac/bundle_layout_spike.sh run "$IN" \
     >"$T/out.$label" 2>&1 </dev/null)
  rc=$?
  out=$(cat "$T/out.$label")
  local left
  left=$(find "$X/hosts" -maxdepth 2 -name 'zb-gate-*' 2>/dev/null)
  [ -z "$left" ] || bad "$label B8: a run dir was left: $left"
}

US=$'\x1f'
check_signing() { # check_signing <label> <role>: B4 on the recorded codesign calls
  local before=$fails label=$1 role=$2 f k id deep verify strict vdeep tgt kind i files_done=no bundle_seen=no app_idx=-1 ver_idx=-1
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
  local n=${#calls[@]} last_file=-1 first_dir=-1
  for ((i = 0; i < n; i++)); do
    IFS=$US read -r tgt id deep verify strict vdeep kind <<<"${calls[i]}"
    if [ "$verify" = yes ]; then
      [ "$i" -eq $((n - 1)) ] || bad "$label B4 $role: the verify call is not the last codesign call"
      [ "$strict" = yes ] && [ "$vdeep" = yes ] || bad "$label B4 $role: the verify call lacks --strict or --deep"
      [ "$tgt" = "$APP" ] || bad "$label B4 $role: verify targets '$tgt', want $APP"
      continue
    fi
    [ "$id" = - ] || bad "$label B4 $role: '$tgt' signed with identity '$id', want '-'"
    [ "$deep" = no ] || bad "$label B4 $role: '$tgt' signed with --deep"
    [ "$kind" != symlink ] || bad "$label B4 $role: the symlink '$tgt' was signed"
    case "$tgt" in
      "$APP") app_idx=$i ;;
      */Python.framework/Versions/3.12) ver_idx=$i ;;
    esac
    case "$tgt" in *.app|*/Versions/3.12) [ "$first_dir" -ge 0 ] || first_dir=$i ;; *) last_file=$i; macho+=("$tgt") ;; esac
  done
  local want_files
  want_files=$(printf '%s\n' "$APP/Contents/MacOS/zigBrowser" "$APP/Contents/Frameworks/libwkwebview_shim.dylib" \
    "$APP/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/Python" \
    "$APP/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12" \
    "$APP/Contents/Frameworks/agent-host/site-packages/claude_agent_sdk/_bundled/claude" \
    "$APP/Contents/Frameworks/agent-host/site-packages/rpds/rpds.so" | sort)
  [ "$(printf '%s\n' "${macho[@]}" | sort)" = "$want_files" ] \
    || bad "$label B4 $role: the signed files are not exactly the six Mach-O files once each: $(printf '%s ' "${macho[@]}")"
  { [ "$last_file" -lt "$first_dir" ] && [ "$ver_idx" -ge 0 ] && [ "$app_idx" -gt "$ver_idx" ] \
    && [ "$app_idx" -eq $((n - 2)) ]; } \
    || bad "$label B4 $role: order is not files, then Versions/3.12, then the .app (files end $last_file, dirs start $first_dir, version $ver_idx, app $app_idx of $n)"
  local depth prev=999
  for tgt in "${macho[@]}"; do
    depth=$(tr -cd / <<<"$tgt" | wc -c)
    [ "$depth" -le "$prev" ] || bad "$label B4 $role: '$tgt' was signed after a shallower file (not deepest first)"
    prev=$depth
  done
  [ "$fails" -eq "$before" ] && ok "$label B4 $role: ad hoc, never --deep; six Mach-O files deepest first, then Versions/3.12, then the .app; verify --strict --deep last"
}

# B1-B5, B8: clean.
run_spike clean clean both
if [ "$rc" -eq 0 ] && grep -qP '^PASS\tbundle-layout-spike\tx86_64$' <<<"$out" && grep -qP '^PASS\tbundle-layout-spike\tarm64$' <<<"$out" \
   && [ "$(tail -n 1 <<<"$out")" = "$(printf 'PASS\tbundle-layout-spike\tboth-arches\t%s' "$SHA")" ]; then
  ok "clean B1: exit 0, both legs pass, then PASS both-arches $SHA"
else bad "clean B1: exit $rc: $(grep -E 'PASS|FAIL' <<<"$out" | tail -n 4 | tr '\n' ' ')"; fi
for role in intel arm; do
  rd=$(grep -oE 'zb-gate-[0-9a-f]{40}-[0-9a-f]+' <<<"$out" | head -n 1)
  mapfile -t sa < "$C/stager.$role" 2>/dev/null
  if [[ "${sa[0]:-}" == "$X/hosts/$role/zb-gate-$SHA-"*/py.pkg ]] && [ "${sa[1]:-}" = "$PIN" ] \
     && [[ "${sa[2]:-}" == "$X/hosts/$role/zb-gate-$SHA-"*"/$APP/Contents" ]] && [[ "${sa[3]:-}" == */site-x86_64 ]] \
     && [[ "${sa[4]:-}" == */site-aarch64 ]] && [ "$(cat "$C/agent-tree.$role" 2>/dev/null)" = committed ]; then
    ok "clean B2 $role: the stager gets the run-dir pkg, the pin, the app's Contents and both site trees, from the committed tree"
  else bad "clean B2 $role: stager args '${sa[*]:-}', agent tree '$(cat "$C/agent-tree.$role" 2>/dev/null)'"; fi
  tree=$(cat "$C/tree.$role" 2>/dev/null)
  if grep -qx ./Contents/MacOS/zigBrowser <<<"$tree" && grep -qx ./Contents/Frameworks/libwkwebview_shim.dylib <<<"$tree" \
     && grep -qx ./Contents/Frameworks/agent-host/runtime.json <<<"$tree" && ! grep -q stray-data <<<"$tree"; then
    ok "clean B3 $role: the verified .app holds the exe, the shim and agent-host, and no stray data"
  else bad "clean B3 $role: the verified tree is: $(tr '\n' ' ' <<<"$tree")"; fi
  check_signing clean "$role"
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  grep -qP "^SPIKE\t$arch\tdata-files-under-Frameworks\t$DATA$" <<<"$out" && ok "clean B5 $role: the census counts $DATA data files under Frameworks" \
    || bad "clean B5 $role: $(grep -P "^SPIKE\t$arch\tdata-files" <<<"$out")"
done

# B6: the verify outcomes that must fail.
for row in "unsealed arm arm64 1:yes:no" "notsigned intel x86_64 1:no:yes" "rc1 arm arm64 1:no:no"; do
  read -r mode where arch want <<<"$row"
  IFS=: read -r vrc uns nsg <<<"$want"
  run_spike "$mode" "$mode" "$where"
  if [ "$rc" -eq 1 ] && grep -qP "^FAIL\tbundle-layout-spike\t$arch\tverify$" <<<"$out" && ! grep -qP '\tboth-arches\t' <<<"$out" \
     && grep -qP "^SPIKE\t$arch\tverify-rc\t$vrc\tunsealed\t$uns\tnot-signed\t$nsg$" <<<"$out"; then
    ok "$mode B6: the $arch leg fails (verify-rc $vrc, unsealed $uns, not-signed $nsg), the run exits 1 with no both-arches PASS"
  else bad "$mode B6: exit $rc: $(grep -E 'SPIKE|PASS|FAIL' <<<"$out" | tail -n 5 | tr '\n' ' ')"; fi
done

# B7: the mutant's stray data file is signed into the tree.
run_spike mutant clean both ZB_SPIKE_MUTANT=data_in_frameworks
for role in intel arm; do
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  if grep -qx ./Contents/Frameworks/stray-data.txt "$C/tree.$role" 2>/dev/null \
     && grep -qP "^SPIKE\t$arch\tdata-files-under-Frameworks\t$((DATA + 1))$" <<<"$out"; then
    ok "mutant B7 $role: Contents/Frameworks/stray-data.txt is in the verified tree (census $((DATA + 1)))"
  else bad "mutant B7 $role: no stray-data.txt in the verified tree, or census not $((DATA + 1))"; fi
done

# B9: refusals before any host is touched.
run_spike noarm clean both ZB_MAC_ARM_HOST=
{ [ "$rc" -eq 1 ] && grep -q 'NOT RUN: arm64 host not configured' <<<"$out" && [ ! -s "$C/calls" ]; } \
  && ok "noarm B9: NOT RUN, exit 1, no ssh/scp" || bad "noarm B9: exit $rc, calls $(wc -l < "$C/calls" 2>/dev/null)"
run_spike badmutant clean both ZB_SPIKE_MUTANT=other
{ [ "$rc" -eq 1 ] && grep -q 'REFUSED: unknown ZB_SPIKE_MUTANT' <<<"$out" && [ ! -s "$C/calls" ]; } \
  && ok "badmutant B9: refused, exit 1, no ssh/scp" || bad "badmutant B9: exit $rc"
echo tampered >> "$IN/py.pkg"
run_spike tampered clean both
{ [ "$rc" -eq 1 ] && grep -q 'do not match inputs.sha256' <<<"$out" && [ ! -s "$C/calls" ]; } \
  && ok "tampered B9: inputs that do not match inputs.sha256 are refused, no ssh/scp" || bad "tampered B9: exit $rc"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-bundle-layout-spike-selftest\n'; exit 0; fi
printf 'FAIL\tmac-bundle-layout-spike-selftest\t%s failure(s)\n' "$fails"
exit 1
