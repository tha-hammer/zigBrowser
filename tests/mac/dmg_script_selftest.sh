#!/usr/bin/env bash
# Hostless selftest of the dmg script, packaging/macos/build-dmg.sh (bd zigBrowser-4pa.73, plan R30-MS1 Red 1: it copied
# only the executable, so libwkwebview_shim.dylib never reached Contents/Frameworks, and it signed ad hoc with --deep).
# The REAL script (with the real tests/mac/build-on-mac.sh and mac_gate_lib.sh) runs in a scratch git repo. Its ssh/scp
# are EXECUTING stubs: every remote command and remote script runs for real in a fake Mac home, with fake Mac tools
# (zig, codesign, otool, lipo, sips, iconutil, hdiutil) that record their argv. The fake zig builds the real output
# layout (zig-out/bin/zigBrowser and zig-out/Frameworks/libwkwebview_shim.dylib); the fake hdiutil keeps a copy of the
# exact tree the dmg is made from. Two runs: ad hoc (the default) and release (ZB_DMG_SIGN_IDENTITY set). Each must:
#   D1 reach its end: exit 0, "==> Done: ", and the dmg copied back;
#   D2 build the committed tree: the Mac's copy of an uncommitted edit in the working tree still reads "committed";
#   D3 ship the shim: the dmg tree holds zigBrowser.app/Contents/MacOS/zigBrowser and
#      zigBrowser.app/Contents/Frameworks/libwkwebview_shim.dylib, byte-identical to what the build made;
#   D4 sign inside out: exactly three signing calls, on the dylib, then the exe, then the .app, each target present
#      when it is signed, and none with --deep;
#   D5 sign as the run asks: ad hoc uses identity "-" with no --options runtime and no --entitlements; release uses
#      the given identity with --options runtime on all three, and --entitlements packaging/macos/entitlements.plist
#      (the committed manifest) on the exe and the .app, never on the dylib;
#   D6 check the bundle: otool -L reads the bundled exe (its shim reference must resolve inside the bundle).
# Plus a TRIPWIRE (not proof): the header calls the output an ad-hoc dev dmg, not a distributable artifact.
# No Mac, no signal: it re-runs itself in a private user+network namespace; HOME/TMPDIR live in its temp tree.
# Run: bash tests/mac/dmg_script_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_DMG_SELFTEST_INNER:-}" != 1 ]; then
  ZB_DMG_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-dmg-selftest-XXXXXX")
T=$(realpath "$BASE")
printf 'not a real key\n' > "$T/fake_mac_key"   # tests/mac/mac_config.sh needs a readable regular key file (bd 3ui.13)
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-dmg-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
HOST=intel@10.0.0.1 MACHOME="$T/mac" C="$T/ctl"
SHIM=zigBrowser.app/Contents/Frameworks/libwkwebview_shim.dylib EXE=zigBrowser.app/Contents/MacOS/zigBrowser

mkdir -p "$T/bin" "$T/hostbin" "$MACHOME/.local/bin" "$C" "$T/home" "$T/tmp"
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
host= skip= k=0
for a in "\$@"; do
  k=\$((k + 1))
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
  host=\$a; break
done
[ "\$host" = "$HOST" ] || { echo "stub ssh: unexpected host \$host" >&2; exit 99; }
cd "$MACHOME" && exec env -i HOME="$MACHOME" PATH="$T/hostbin:/usr/bin:/bin" bash -c "\${*:k+1}"
EOF
cat > "$T/bin/scp" <<EOF
#!/bin/bash
pos=() skip=
for a in "\$@"; do
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-P|-l) skip=1; continue ;; -*) continue ;; esac
  pos+=("\$a")
done
dst=\${pos[\${#pos[@]}-1]}; unset 'pos[\${#pos[@]}-1]'
for src in "\${pos[@]}"; do
  case "\$src" in $HOST:*) cp "$MACHOME/\${src#*:}" "\$dst" || exit 1; continue ;; *:*) echo "stub scp: bad source \$src" >&2; exit 99 ;; esac
  case "\$dst" in $HOST:*) cp "\$src" "$MACHOME/\${dst#*:}" || exit 1 ;; *) echo "stub scp: bad target \$dst" >&2; exit 99 ;; esac
done
EOF
# The fake Mac tools. Each records its argv (NUL-separated) as ctl/<tool>.<n>.
rec='n=$(ls "'"$C"'" | grep -c "^$(basename "$0")\.[0-9]*$" || true); printf "%s\0" "$@" > "'"$C"'/$(basename "$0").$n"'
cat > "$MACHOME/.local/bin/zig" <<EOF
#!/bin/bash
[ "\$1" = version ] && { echo 0.16.0; exit 0; }
cat packaging/macos/marker > "$C/built-from"   # which tree the Mac built: the committed one or the working tree
mkdir -p zig-out/bin zig-out/Frameworks
printf 'zigBrowser exe stand-in\n' > zig-out/bin/zigBrowser; chmod 755 zig-out/bin/zigBrowser
printf 'libwkwebview_shim stand-in\n' > zig-out/Frameworks/libwkwebview_shim.dylib
cp zig-out/bin/zigBrowser zig-out/Frameworks/libwkwebview_shim.dylib "$C/"
echo "build ok"
EOF
cat > "$T/hostbin/codesign" <<EOF
#!/bin/bash
$rec
if [ -e "\${@: -1}" ]; then echo present; else echo missing; fi > "$C/codesign.\$n.target"
exit 0
EOF
cat > "$T/hostbin/otool" <<EOF
#!/bin/bash
$rec
[ "\$1" = -L ] || exit 0
printf '%s:\n\t@executable_path/../Frameworks/libwkwebview_shim.dylib (compatibility version 0.0.0, current version 0.0.0)\n' "\$2"
printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)\n'
EOF
cat > "$T/hostbin/lipo" <<EOF
#!/bin/bash
$rec
case "\$1" in -archs) echo x86_64 ;; -info) echo "Non-fat file: \$2 is architecture: x86_64" ;; esac
exit 0
EOF
cat > "$T/hostbin/sips" <<EOF
#!/bin/bash
$rec
while [ \$# -gt 0 ]; do [ "\$1" = --out ] && { : > "\$2"; exit 0; }; shift; done
EOF
cat > "$T/hostbin/iconutil" <<EOF
#!/bin/bash
$rec
while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { : > "\$2"; exit 0; }; shift; done
EOF
cat > "$T/hostbin/hdiutil" <<EOF
#!/bin/bash
$rec
src=
for ((i = 1; i <= \$#; i++)); do [ "\${!i}" = -srcfolder ] && { j=\$((i + 1)); src=\${!j}; }; done
rm -rf "$C/dmg-tree" && cp -a "\$src" "$C/dmg-tree" && echo dmg > "\${@: -1}"
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp" "$MACHOME/.local/bin/zig" "$T"/hostbin/*

# The scratch repo: the real script, its build step and library, the pinned host keys, the real packaging inputs, a
# marker that is committed as "committed" and then edited (uncommitted) in the working tree, and stand-ins for the rest.
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/packaging/macos" "$R/packaging/assets" "$R/src"
cp "$ROOT/tests/mac/build-on-mac.sh" "$ROOT/tests/mac/mac_gate_lib.sh" "$ROOT/tests/mac/mac_config.sh" "$ROOT/tests/mac/known_hosts" \
  "$R/tests/mac/"
cp "$ROOT/packaging/macos/build-dmg.sh" "$ROOT/packaging/macos/Info.plist" "$ROOT/packaging/macos/entitlements.plist" \
  "$R/packaging/macos/"
cp "$ROOT/packaging/assets/zigBrowser.png" "$R/packaging/assets/"
echo committed > "$R/packaging/macos/marker"
echo "// stand-in" > "$R/src/main.zig"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
echo uncommitted > "$R/packaging/macos/marker"

US=$'\x1f'   # the field separator: not whitespace, so an empty field survives `read`
signs=() # per signing call: target, identity, deep, runtime, entitlements, present (US-separated)
read_signs() {
  local f a k id deep rt ent tgt
  signs=()
  for f in $(ls "$C" | grep -E '^codesign\.[0-9]+$' | sort -t. -k2 -n); do
    mapfile -d '' a < "$C/$f"
    id= deep=no rt=no ent=
    for ((k = 0; k < ${#a[@]}; k++)); do
      case "${a[k]}" in
        -s|--sign) id=${a[k+1]:-} ;;
        --sign=*) id=${a[k]#*=} ;;
        --deep) deep=yes ;;
        -o|--options) [[ ",${a[k+1]:-}," == *,runtime,* ]] && rt=yes ;;
        --options=*) [[ ",${a[k]#*=}," == *,runtime,* ]] && rt=yes ;;
        --entitlements) ent=${a[k+1]:-} ;;
        --entitlements=*) ent=${a[k]#*=} ;;
      esac
    done
    [ -n "$id" ] || continue                       # --verify / --display calls are not signing
    tgt=${a[${#a[@]}-1]}; tgt=${tgt#./}; tgt=${tgt%/}
    signs+=("$tgt$US$id$US$deep$US$rt$US$ent$US$(cat "$C/$f.target")")
  done
}

run_dmg() { # run_dmg <label> <identity or empty>: D1-D6 for one run
  local label=$1 ident=$2 rc s tgt id deep rt ent present i want_id
  local -a want=("$SHIM" "$EXE" zigBrowser.app)
  rm -rf "${C:?}"/* "$R/zigBrowser_0.2.0_macos.dmg"
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$HOST" \
     ZB_MAC_KEY="$T/fake_mac_key" ${ident:+ZB_DMG_SIGN_IDENTITY="$ident"} \
     timeout 120 bash packaging/macos/build-dmg.sh >"$T/out.$label" 2>&1 </dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^==> Done: ' "$T/out.$label" && [ -s "$R/zigBrowser_0.2.0_macos.dmg" ]; then
    ok "$label D1: the run reaches its end and copies the dmg back"
  else bad "$label D1: exit $rc, want 0 with \"==> Done: \" and the dmg: $(tail -n 3 "$T/out.$label" | tr '\n' ' ')"; fi
  if [ "$(cat "$C/built-from" 2>/dev/null)" = committed ]; then ok "$label D2: the Mac built the committed tree"
  else bad "$label D2: the Mac built '$(cat "$C/built-from" 2>/dev/null)', want the committed tree"; fi
  if [ -f "$C/dmg-tree/$EXE" ] && cmp -s "$C/zigBrowser" "$C/dmg-tree/$EXE"; then ok "$label D3: the dmg holds the built exe"
  else bad "$label D3: the dmg tree has no built exe at $EXE"; fi
  if [ -f "$C/dmg-tree/$SHIM" ] && cmp -s "$C/libwkwebview_shim.dylib" "$C/dmg-tree/$SHIM"; then
    ok "$label D3: the dmg holds the built shim at Contents/Frameworks"
  else bad "$label D3: the dmg tree has no built shim at $SHIM ($(cd "$C/dmg-tree" 2>/dev/null && find . -type f | tr '\n' ' '))"; fi
  read_signs
  if [ "${#signs[@]}" -eq 3 ]; then ok "$label D4: three signing calls"
  else bad "$label D4: ${#signs[@]} signing call(s), want 3 (dylib, exe, .app): $(printf '%s | ' "${signs[@]%%"$US"*}")"; fi
  want_id=${ident:--}
  for ((i = 0; i < ${#signs[@]}; i++)); do
    IFS=$US read -r tgt id deep rt ent present <<<"${signs[i]}"
    [ "$tgt" = "${want[i]:-<none>}" ] || bad "$label D4: signing call $((i + 1)) is on '$tgt', want '${want[i]:-<none>}'"
    [ "$deep" = no ] || bad "$label D4: signing call $((i + 1)) ($tgt) uses --deep"
    [ "$present" = present ] || bad "$label D4: '$tgt' did not exist when it was signed"
    [ "$id" = "$want_id" ] || bad "$label D5: '$tgt' signed with identity '$id', want '$want_id'"
    if [ -z "$ident" ]; then
      [ "$rt" = no ] || bad "$label D5: the ad-hoc '$tgt' uses --options runtime"
      [ -z "$ent" ] || bad "$label D5: the ad-hoc '$tgt' uses --entitlements $ent"
    else
      [ "$rt" = yes ] || bad "$label D5: the release '$tgt' lacks --options runtime"
      if [ "$tgt" = "$SHIM" ]; then [ -z "$ent" ] || bad "$label D5: the release dylib uses --entitlements $ent"
      else
        [ "${ent#./}" = packaging/macos/entitlements.plist ] \
          || bad "$label D5: the release '$tgt' uses --entitlements '$ent', want packaging/macos/entitlements.plist"
      fi
    fi
  done
  local otools
  otools=$(for f in $(ls "$C" | grep -E '^otool\.[0-9]+$'); do tr '\0' ' ' < "$C/$f"; echo; done)
  if grep -qE "^-L (\./)?$EXE $" <<<"$otools"; then ok "$label D6: otool -L reads the bundled exe"
  else bad "$label D6: no otool -L on the bundled exe $EXE (otool calls: ${otools:-none})"; fi
}

run_dmg adhoc ""
run_dmg release "Developer ID Application: Selftest (SELFTEST01)"
if [ "$(sed -n 2p "$R/packaging/macos/build-dmg.sh")" = "# Build an ad-hoc dev dmg, not a distributable artifact, on the M9 build host over Tailscale SSH." ]; then
  ok "TRIPWIRE: the header calls it an ad-hoc dev dmg, not a distributable artifact"
else bad "TRIPWIRE: header line 2 is '$(sed -n 2p "$R/packaging/macos/build-dmg.sh")'"; fi

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-dmg-script-selftest\n'; exit 0; fi
printf 'FAIL\tmac-dmg-script-selftest\t%s failure(s)\n' "$fails"
exit 1
