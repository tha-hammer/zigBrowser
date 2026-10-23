#!/usr/bin/env bash
# Hostless selftest of MS1c (plan R30-MS1 / Rev 29: convert packaging/macos/build-dmg.sh): the dmg's .app must be
# UNIVERSAL, built natively on BOTH Macs and joined with lipo, with every Mach-O in the bundle fat (x86_64 + arm64).
# The REAL script (with the real build-on-mac.sh and mac_gate_lib.sh) runs in a scratch git repo against EXECUTING stub
# ssh/scp: every remote command and script runs for real in a fake Mac home per host. Fake Mac tools record what they
# get: the fake zig builds that host's thin slices ("MACHO thin <arch>"); the fake lipo joins thin files into a fat one
# ("MACHO fat x86_64 arm64" plus each input) and answers -archs/-info; otool, codesign, sips, iconutil and hdiutil (which
# keeps the exact tree the dmg is made from) as in tests/mac/dmg_script_selftest.sh. Rows:
#   U1 a run with both hosts reaches "==> Done: " with the dmg copied back, after one build on each host (each fake
#      zig ran once, in that host's run dir);
#   U2 the dmg's Contents/MacOS/zigBrowser is fat with exactly x86_64 and arm64, and its slices are byte for byte the
#      two hosts' builds; the same for Contents/Frameworks/libwkwebview_shim.dylib;
#   U3 every Mach-O file in the dmg tree is fat with both slices;
#   U4 the script itself checks the bundled exe and shim with lipo -archs before signing;
#   U5 signing stays inside out and never --deep (the shim, the exe, the .app), and otool -L reads the bundled exe;
#   U6 a lipo that leaves a slice out fails the run (exit non-zero, no "==> Done: ", no dmg copied back);
#   U7 no arm64 host: "NOT RUN: arm64 host not configured", exit 1, and no ssh/scp call;
#   U8 no run dir is left on either host.
# No Mac, no signal: it re-runs itself in a private user+network namespace; HOME/TMPDIR live in its temp tree.
# Run: bash tests/mac/dmg_universal_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_DMGUNI_SELFTEST_INNER:-}" != 1 ]; then
  ZB_DMGUNI_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-dmguni-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-dmguni-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2 X="$T/x" C="$T/ctl"
EXE=zigBrowser.app/Contents/MacOS/zigBrowser SHIM=zigBrowser.app/Contents/Frameworks/libwkwebview_shim.dylib
DMG=zigBrowser_0.2.0_macos.dmg

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
case "\$host" in $INTEL) role=intel ;; $ARM) role=arm ;; *) echo "stub ssh: unexpected host \$host" >&2; exit 99 ;; esac
cd "$X/hosts/\$role" && exec env -i HOME="$X/hosts/\$role" ZB_ROLE=\$role PATH="$X/hostbin:/usr/bin:/bin" bash -c "\${*:k+1}"
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
remote() { case "\$1" in $INTEL:*) echo "$X/hosts/intel/\${1#*:}" ;; $ARM:*) echo "$X/hosts/arm/\${1#*:}" ;; *) return 1 ;; esac; }
for src in "\${pos[@]}"; do
  if r=\$(remote "\$src"); then cp "\$r" "\$dst" || exit 1
  elif r=\$(remote "\$dst"); then cp "\$src" "\$r" || exit 1
  else echo "stub scp: no remote side in \$src -> \$dst" >&2; exit 99; fi
done
EOF
rec='n=$(ls "'"$C"'" | grep -c "^$(basename "$0")\.[0-9]*$" || true); printf "%s\0" "$@" > "'"$C"'/$(basename "$0").$n"'
for role in intel arm; do
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  cat > "$X/hosts/$role/.local/bin/zig" <<EOF
#!/bin/bash
[ "\$1" = version ] && { echo 0.16.0; exit 0; }
pwd > "$C/built.$role"
mkdir -p zig-out/bin zig-out/Frameworks
printf 'MACHO thin $arch\nzigBrowser exe built on $role\n' > zig-out/bin/zigBrowser
printf 'MACHO thin $arch\nwkwebview shim built on $role\n' > zig-out/Frameworks/libwkwebview_shim.dylib
cp zig-out/bin/zigBrowser "$C/exe.$arch"; cp zig-out/Frameworks/libwkwebview_shim.dylib "$C/shim.$arch"
echo "build ok"
EOF
done
cat > "$X/hostbin/lipo" <<EOF
#!/bin/bash
$rec
archs_of() { local h; h=\$(head -n 1 "\$1"); case "\$h" in "MACHO thin "*) echo "\${h#MACHO thin }" ;; "MACHO fat "*) echo "\${h#MACHO fat }" ;; *) return 1 ;; esac; }
case "\$1" in
  -create)
    shift; ins=() out=
    while [ \$# -gt 0 ]; do [ "\$1" = -output ] && { out=\$2; shift 2; continue; }; ins+=("\$1"); shift; done
    [ -e "$C/lipo_drops_arm" ] && ins=("\${ins[0]}")
    a=(); for f in "\${ins[@]}"; do a+=("\$(archs_of "\$f")") || exit 1; done
    { echo "MACHO fat \${a[*]}"; for f in "\${ins[@]}"; do echo "--slice--"; cat "\$f"; done; } > "\$out" ;;
  -archs) archs_of "\$2" ;;
  -info) echo "Architectures in the fat file: \$2 are: \$(archs_of "\$2")" ;;
esac
EOF
cat > "$X/hostbin/codesign" <<EOF
#!/bin/bash
$rec
exit 0
EOF
cat > "$X/hostbin/otool" <<EOF
#!/bin/bash
$rec
[ "\$1" = -L ] || exit 0
printf '%s:\n\t@executable_path/../Frameworks/libwkwebview_shim.dylib (compatibility version 0.0.0, current version 0.0.0)\n' "\$2"
EOF
cat > "$X/hostbin/sips" <<EOF
#!/bin/bash
while [ \$# -gt 0 ]; do [ "\$1" = --out ] && { : > "\$2"; exit 0; }; shift; done
EOF
cat > "$X/hostbin/iconutil" <<EOF
#!/bin/bash
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { : > "\$2"; exit 0; }; shift; done
EOF
cat > "$X/hostbin/hdiutil" <<EOF
#!/bin/bash
src=
for ((i = 1; i <= \$#; i++)); do [ "\${!i}" = -srcfolder ] && { j=\$((i + 1)); src=\${!j}; }; done
rm -rf "$C/dmg-tree" && cp -a "\$src" "$C/dmg-tree" && echo dmg > "\${@: -1}"
EOF
chmod +x "$X/bin"/* "$X/hostbin"/* "$X/hosts"/*/.local/bin/zig

R="$T/repo"
mkdir -p "$R/tests/mac" "$R/packaging/macos" "$R/packaging/assets" "$R/src"
cp "$ROOT/tests/mac/build-on-mac.sh" "$ROOT/tests/mac/mac_gate_lib.sh" "$ROOT/tests/mac/known_hosts" "$R/tests/mac/"
cp "$ROOT/packaging/macos/build-dmg.sh" "$ROOT/packaging/macos/Info.plist" "$ROOT/packaging/macos/entitlements.plist" \
  "$R/packaging/macos/"
cp "$ROOT/packaging/assets/zigBrowser.png" "$R/packaging/assets/"
echo "// stand-in" > "$R/src/main.zig"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }

run_dmg() { # run_dmg <label> [VAR=value ...]: sets rc
  local label=$1; shift
  rm -rf "${C:?}"/* "$R/$DMG"
  [ "$label" = lipo-drops-arm ] && touch "$C/lipo_drops_arm"
  (cd "$R" && env -i PATH="$X/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/home/no_such_key" "$@" timeout 120 bash packaging/macos/build-dmg.sh >"$T/out.$label" 2>&1 </dev/null)
  rc=$?
  local left
  left=$(find "$X/hosts" -maxdepth 2 -name 'zb-gate-*' 2>/dev/null)
  [ -z "$left" ] || bad "$label U8: a run dir was left: $left"
}
fat_of_both() { # fat_of_both <file> <thin x86_64 file> <thin arm64 file>: fat, both archs, slices byte for byte
  [ "$(head -n 1 "$1" 2>/dev/null)" = "MACHO fat x86_64 arm64" ] || return 1
  [ "$(printf -- '--slice--\n%s\n--slice--\n%s' "$(cat "$2")" "$(cat "$3")")" = "$(tail -n +2 "$1")" ]
}

# U1-U5, U8: both hosts.
run_dmg universal
if [ "$rc" -eq 0 ] && grep -q '^==> Done: ' "$T/out.universal" && [ -s "$R/$DMG" ] \
   && [[ "$(cat "$C/built.intel" 2>/dev/null)" == "$X/hosts/intel/zb-gate-"* ]] && [[ "$(cat "$C/built.arm" 2>/dev/null)" == "$X/hosts/arm/zb-gate-"* ]]; then
  ok "U1: the run reaches its end with the dmg copied back, after a build on each host"
else bad "U1: exit $rc, intel built in '$(cat "$C/built.intel" 2>/dev/null)', arm built in '$(cat "$C/built.arm" 2>/dev/null)': $(tail -n 2 "$T/out.universal" | tr '\n' ' ')"; fi
if fat_of_both "$C/dmg-tree/$EXE" "$C/exe.x86_64" "$C/exe.arm64" 2>/dev/null; then ok "U2: the bundled exe is fat (x86_64 arm64), its slices are the two hosts' builds"
else bad "U2: the bundled exe is not the fat join of both builds: $(head -n 1 "$C/dmg-tree/$EXE" 2>/dev/null)"; fi
if fat_of_both "$C/dmg-tree/$SHIM" "$C/shim.x86_64" "$C/shim.arm64" 2>/dev/null; then ok "U2: the bundled shim is fat (x86_64 arm64), its slices are the two hosts' builds"
else bad "U2: the bundled shim is not the fat join of both builds: $(head -n 1 "$C/dmg-tree/$SHIM" 2>/dev/null)"; fi
# A file is Mach-O by its first line (the stand-in header); a fat file's slices follow it.
thin= nmacho=0
while IFS= read -r f; do
  case "$(head -n 1 "$f")" in "MACHO thin "*) thin+="${f#"$C/dmg-tree/"} " ; nmacho=$((nmacho + 1)) ;; "MACHO fat x86_64 arm64") nmacho=$((nmacho + 1)) ;;
    "MACHO "*) thin+="${f#"$C/dmg-tree/"} " ; nmacho=$((nmacho + 1)) ;; esac
done < <(find "$C/dmg-tree" -type f 2>/dev/null)
if [ -z "$thin" ] && [ "$nmacho" -ge 2 ]; then ok "U3: all $nmacho Mach-O files in the dmg tree are fat"
else bad "U3: thin Mach-O in the dmg tree: '${thin:-none}' ($nmacho Mach-O files)"; fi
lipos=$(for f in $(ls "$C" | grep -E '^lipo\.[0-9]+$'); do tr '\0' ' ' < "$C/$f"; echo; done)
if grep -qE "^-archs (\./)?$EXE $" <<<"$lipos" && grep -qE "^-archs (\./)?$SHIM $" <<<"$lipos"; then
  ok "U4: the script checks the bundled exe and shim with lipo -archs"
else bad "U4: lipo calls were: $(tr '\n' '|' <<<"$lipos")"; fi
signs=$(for f in $(ls "$C" | grep -E '^codesign\.[0-9]+$' | sort -t. -k2 -n); do tr '\0' ' ' < "$C/$f"; echo; done | grep -E -- '(^| )(--sign|-s) ')
order=$(awk '{ print $NF }' <<<"$signs" | tr '\n' ' ')
otools=$(for f in $(ls "$C" | grep -E '^otool\.[0-9]+$'); do tr '\0' ' ' < "$C/$f"; echo; done)
if [ "$order" = "$SHIM $EXE zigBrowser.app " ] && ! grep -q -- '--deep' <<<"$signs" && grep -qE "^-L (\./)?$EXE $" <<<"$otools"; then
  ok "U5: signed inside out (shim, exe, .app) without --deep; otool -L reads the bundled exe"
else bad "U5: signing order '$order', --deep $(grep -c -- '--deep' <<<"$signs"), otool calls '$(tr '\n' '|' <<<"$otools")'"; fi

# U6: a lipo that leaves the arm64 slice out.
run_dmg lipo-drops-arm
{ [ "$rc" -ne 0 ] && ! grep -q '^==> Done: ' "$T/out.lipo-drops-arm" && [ ! -e "$R/$DMG" ]; } \
  && ok "U6: a lipo that leaves a slice out fails the run (exit $rc), no dmg" \
  || bad "U6: exit $rc, Done $(grep -c '^==> Done: ' "$T/out.lipo-drops-arm"), dmg $( [ -e "$R/$DMG" ] && echo copied || echo absent)"

# U7: no arm64 host.
run_dmg noarm ZB_MAC_ARM_HOST=
{ [ "$rc" -eq 1 ] && grep -q 'NOT RUN: arm64 host not configured' "$T/out.noarm" && [ ! -s "$C/calls" ]; } \
  && ok "U7: no arm64 host: NOT RUN, exit 1, no ssh/scp" \
  || bad "U7: exit $rc, $(wc -l < "$C/calls" 2>/dev/null || echo 0) ssh/scp calls: $(tail -n 1 "$T/out.noarm")"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-dmg-universal-selftest\n'; exit 0; fi
printf 'FAIL\tmac-dmg-universal-selftest\t%s failure(s)\n' "$fails"
exit 1
