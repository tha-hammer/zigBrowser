#!/usr/bin/env bash
# Hostless selftest of the dmg script, packaging/macos/build-dmg.sh (bd zigBrowser-4pa.73, plan R30-MS1 Red 1: it copied
# only the executable, so libwkwebview_shim.dylib never reached Contents/Frameworks, and it signed ad hoc with --deep).
# The REAL script (with the real tests/mac/build-on-mac.sh and mac_gate_lib.sh) runs in a scratch git repo. Its ssh/scp
# are EXECUTING stubs: every remote command and remote script runs for real in a fake Mac home per host (the script
# builds on both Macs and joins the slices, bd 4pa.73 MS1c), with fake Mac tools (zig, codesign, otool, lipo, sips,
# iconutil, hdiutil) that record their argv. The fake zig builds the real output layout (zig-out/bin/zigBrowser and
# zig-out/Frameworks/libwkwebview_shim.dylib) with host-specific bytes; the fake lipo joins its inputs; the fake
# hdiutil keeps a copy of the exact tree the dmg is made from. Two runs: ad hoc (the default) and release
# (ZB_DMG_SIGN_IDENTITY and ZB_DMG_SIGN_KEYCHAIN set). Each must:
#   D1 reach its end: exit 0, "==> Done: ", and the dmg copied back;
#   D2 build the committed tree: each Mac's copy of an uncommitted edit in the working tree still reads "committed",
#      and the app's Info.plist is the committed one (an uncommitted edit of it never reaches the app);
#   D3 ship the shim: the dmg tree holds zigBrowser.app/Contents/MacOS/zigBrowser and
#      zigBrowser.app/Contents/Frameworks/libwkwebview_shim.dylib, each byte for byte the lipo join of the two
#      hosts' builds (x86_64, then arm64);
#   D4 sign inside out: exactly three signing calls, on the dylib, then the exe, then the .app, each target present
#      when it is signed, and none with --deep;
#   D5 sign as the run asks: ad hoc uses identity "-" with no --keychain, --options runtime or --entitlements;
#      release uses the given identity and keychain with --options runtime on all three, and --entitlements
#      packaging/macos/entitlements.plist (the committed manifest) on the exe and the .app, never on the dylib;
#   D6 check the bundle: otool -L reads the bundled exe (its shim reference must resolve inside the bundle).
#   D7 (a third and fourth run, ad hoc and release) an otool that prints the valid matching output and then exits
#      non-zero stops the script with "ERROR: otool -L <exe> failed": exit non-zero, no "does not load", no signing
#      call, no hdiutil call, no dmg.
# With ZB_DMG_SELFTEST_OTOOL_LATE=1 (tests/mac/dmg_otool_late_write_selftest.sh) the fake otool writes its later
# dependency line after a pause, so a check that closes otool's pipe early (grep -q under pipefail) fails D1.
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
HOST=intel@10.0.0.1 MACHOME="$T/mac" ARM=arm@10.0.0.2 ARMHOME="$T/mac-arm" C="$T/ctl"
SHIM=zigBrowser.app/Contents/Frameworks/libwkwebview_shim.dylib EXE=zigBrowser.app/Contents/MacOS/zigBrowser

mkdir -p "$T/bin" "$T/hostbin" "$MACHOME/.local/bin" "$ARMHOME/.local/bin" "$C" "$T/home" "$T/tmp"
mkdir -p "$MACHOME/zb-signing"
: > "$MACHOME/zb-signing/dev.keychain-db"
printf 'selftest python package\n' > "$T/fake-python.pkg"
FAKE_PYTHON_SHA=$(sha256sum "$T/fake-python.pkg" | cut -c1-64)
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
host= skip= k=0
for a in "\$@"; do
  k=\$((k + 1))
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
  host=\$a; break
done
case "\$host" in $HOST) home="$MACHOME" ;; $ARM) home="$ARMHOME" ;; *) echo "stub ssh: unexpected host \$host" >&2; exit 99 ;; esac
cd "\$home" && exec env -i HOME="\$home" PATH="$T/hostbin:/usr/bin:/bin" bash -c "\${*:k+1}"
EOF
cat > "$T/bin/curl" <<EOF
#!/bin/bash
out=
while [ \$# -gt 0 ]; do
  [ "\$1" = --output ] && { out=\$2; shift 2; continue; }
  shift
done
[ -n "\$out" ] || exit 2
cp "$T/fake-python.pkg" "\$out"
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
  case "\$src" in $HOST:*) cp "$MACHOME/\${src#*:}" "\$dst" || exit 1; continue ;; $ARM:*) cp "$ARMHOME/\${src#*:}" "\$dst" || exit 1; continue ;;
    *:*) echo "stub scp: bad source \$src" >&2; exit 99 ;; esac
  case "\$dst" in $HOST:*) cp "\$src" "$MACHOME/\${dst#*:}" || exit 1 ;; $ARM:*) cp "\$src" "$ARMHOME/\${dst#*:}" || exit 1 ;;
    *) echo "stub scp: bad target \$dst" >&2; exit 99 ;; esac
done
EOF
# The fake Mac tools. Each records its argv (NUL-separated) as ctl/<tool>.<n>.
rec='n=$(ls "'"$C"'" | grep -c "^$(basename "$0")\.[0-9]*$" || true); printf "%s\0" "$@" > "'"$C"'/$(basename "$0").$n"'
for home in "$MACHOME" "$ARMHOME"; do
  role=intel; [ "$home" = "$ARMHOME" ] && role=arm
  cat > "$home/.local/bin/zig" <<EOF
#!/bin/bash
[ "\$1" = version ] && { echo 0.16.0; exit 0; }
cat packaging/macos/marker > "$C/built-from.$role"   # which tree this Mac built: the committed one or the working tree
mkdir -p zig-out/bin zig-out/Frameworks
printf 'zigBrowser exe stand-in built on $role\n' > zig-out/bin/zigBrowser; chmod 755 zig-out/bin/zigBrowser
printf 'libwkwebview_shim stand-in built on $role\n' > zig-out/Frameworks/libwkwebview_shim.dylib
cp zig-out/bin/zigBrowser "$C/zigBrowser.$role"; cp zig-out/Frameworks/libwkwebview_shim.dylib "$C/libwkwebview_shim.dylib.$role"
echo "build ok"
EOF
done
cat > "$T/hostbin/codesign" <<EOF
#!/bin/bash
$rec
if [ -e "\${@: -1}" ]; then echo present; else echo missing; fi > "$C/codesign.\$n.target"
exit 0
EOF
cat > "$T/hostbin/file" <<'EOF'
#!/bin/bash
case "${@: -1}" in
  */Contents/MacOS/zigBrowser|*/Contents/Frameworks/libwkwebview_shim.dylib) echo 'Mach-O universal binary' ;;
  *) echo 'ASCII text' ;;
esac
EOF
cat > "$T/hostbin/otool" <<EOF
#!/bin/bash
$rec
[ "\$1" = -L ] || exit 0
printf '%s:\n\t@executable_path/../Frameworks/libwkwebview_shim.dylib (compatibility version 0.0.0, current version 0.0.0)\n' "\$2"
# ZB_DMG_SELFTEST_OTOOL_LATE=1: the later dependency line comes after a pause, as a real otool can write it after the
# shim line has already been read. A reader that stops at the first match (grep -q) has closed the pipe by then.
[ "${ZB_DMG_SELFTEST_OTOOL_LATE:-}" = 1 ] && sleep 0.5
printf '\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)\n'
# D7: valid, matching output, then a failing exit (otool's own status must count, not only its text).
if [ -e "$C/otool_fail" ]; then exit 3; fi
EOF
cat > "$T/hostbin/lipo" <<EOF
#!/bin/bash
$rec
case "\$1" in   # -create joins its inputs in order; a joined file answers both slices
  -create)
    shift; ins=() out=
    while [ \$# -gt 0 ]; do [ "\$1" = -output ] && { out=\$2; shift 2; continue; }; ins+=("\$1"); shift; done
    { echo "FAT x86_64 arm64"; for f in "\${ins[@]}"; do echo "--slice--"; cat "\$f"; done; } > "\$out" ;;
  -archs) if [ "\$(head -n 1 "\$2")" = "FAT x86_64 arm64" ]; then echo "x86_64 arm64"; else echo x86_64; fi ;;
  -info) echo "Architectures in the fat file: \$2" ;;
esac
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
chmod +x "$T/bin/ssh" "$T/bin/scp" "$T/bin/curl" "$MACHOME/.local/bin/zig" "$ARMHOME/.local/bin/zig" "$T"/hostbin/*

# The scratch repo: the real script, its build step and library, the pinned host keys, the real packaging inputs, a
# marker that is committed as "committed" and then edited (uncommitted) in the working tree, and stand-ins for the rest.
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/packaging/macos" "$R/packaging/assets" "$R/src" "$R/agent/host"
cp "$ROOT/tests/mac/build-on-mac.sh" "$ROOT/tests/mac/mac_gate_lib.sh" "$ROOT/tests/mac/mac_config.sh" "$ROOT/tests/mac/known_hosts" \
  "$R/tests/mac/"
cp "$ROOT/packaging/macos/build-dmg.sh" "$ROOT/packaging/macos/Info.plist" "$ROOT/packaging/macos/entitlements.plist" \
  "$R/packaging/macos/"
cp "$ROOT/packaging/assets/zigBrowser.png" "$R/packaging/assets/"
printf 'stand-in agent host\n' > "$R/agent/host/README"
cat > "$R/packaging/macos/agent_runtime_pins.json" <<EOF
{"python_pkg":{"url":"https://www.python.org/selftest.pkg","sha256":"$FAKE_PYTHON_SHA"}}
EOF
cat > "$R/packaging/macos/build_site_packages.sh" <<'EOF'
#!/bin/bash
set -e
mkdir -p "$2/site-x86_64" "$2/site-aarch64"
printf 'x86 site\n' > "$2/site-x86_64/stand-in"
printf 'arm site\n' > "$2/site-aarch64/stand-in"
EOF
cat > "$R/packaging/macos/stage_agent_runtime.sh" <<'EOF'
#!/bin/bash
set -e
mkdir -p "$3/Frameworks/agent-host" "$3/Resources/agent-host"
EOF
cat > "$R/packaging/macos/relocate_agent_data.py" <<'EOF'
import sys
raise SystemExit(0)
EOF
echo committed > "$R/packaging/macos/marker"
echo "// stand-in" > "$R/src/main.zig"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
echo uncommitted > "$R/packaging/macos/marker"
PLIST_COMMITTED=$(sed 's/__VERSION__/0.2.0/g' "$R/packaging/macos/Info.plist")
echo "<!-- uncommitted working-tree edit -->" >> "$R/packaging/macos/Info.plist"

US=$'\x1f'   # the field separator: not whitespace, so an empty field survives `read`
signs=() # per signing call: target, identity, keychain, deep, runtime, entitlements, present (US-separated)
read_signs() {
  local f a k id kc deep rt ent tgt
  signs=()
  for f in $(ls "$C" | grep -E '^codesign\.[0-9]+$' | sort -t. -k2 -n); do
    mapfile -d '' a < "$C/$f"
    id= kc= deep=no rt=no ent=
    for ((k = 0; k < ${#a[@]}; k++)); do
      case "${a[k]}" in
        -s|--sign) id=${a[k+1]:-} ;;
        --sign=*) id=${a[k]#*=} ;;
        --keychain) kc=${a[k+1]:-} ;;
        --keychain=*) kc=${a[k]#*=} ;;
        --deep) deep=yes ;;
        -o|--options) [[ ",${a[k+1]:-}," == *,runtime,* ]] && rt=yes ;;
        --options=*) [[ ",${a[k]#*=}," == *,runtime,* ]] && rt=yes ;;
        --entitlements) ent=${a[k+1]:-} ;;
        --entitlements=*) ent=${a[k]#*=} ;;
      esac
    done
    [ -n "$id" ] || continue                       # --verify / --display calls are not signing
    tgt=${a[${#a[@]}-1]}; tgt=${tgt#./}; tgt=${tgt%/}
    signs+=("$tgt$US$id$US$kc$US$deep$US$rt$US$ent$US$(cat "$C/$f.target")")
  done
}

run_dmg() { # run_dmg <label> <identity or empty> <keychain or empty>: D1-D6 for one run
  local label=$1 ident=$2 keychain=$3 rc s tgt id kc deep rt ent present i want_id
  local -a want=("$SHIM" "$EXE" zigBrowser.app)
  rm -rf "${C:?}"/* "$R/zigBrowser_0.2.0_macos.dmg"
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$HOST" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/fake_mac_key" ${ident:+ZB_DMG_SIGN_IDENTITY="$ident"} \
     ${keychain:+ZB_DMG_SIGN_KEYCHAIN="$keychain"} \
     timeout 120 bash packaging/macos/build-dmg.sh >"$T/out.$label" 2>&1 </dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^==> Done: ' "$T/out.$label" && [ -s "$R/zigBrowser_0.2.0_macos.dmg" ]; then
    ok "$label D1: the run reaches its end and copies the dmg back"
  else bad "$label D1: exit $rc, want 0 with \"==> Done: \" and the dmg: $(tail -n 3 "$T/out.$label" | tr '\n' ' ')"; fi
  if [ "$(cat "$C/built-from.intel" 2>/dev/null)" = committed ] && [ "$(cat "$C/built-from.arm" 2>/dev/null)" = committed ] \
     && [ "$(cat "$C/dmg-tree/zigBrowser.app/Contents/Info.plist" 2>/dev/null)" = "$PLIST_COMMITTED" ]; then
    ok "$label D2: both Macs built the committed tree, and the app's Info.plist is the committed one"
  else bad "$label D2: built '$(cat "$C/built-from.intel" 2>/dev/null)' and '$(cat "$C/built-from.arm" 2>/dev/null)', Info.plist $(cmp -s <(printf '%s\n' "$PLIST_COMMITTED") "$C/dmg-tree/zigBrowser.app/Contents/Info.plist" && echo committed || echo 'not the committed one'); want the committed tree"; fi
  joined() { printf 'FAT x86_64 arm64\n--slice--\n'; cat "$1"; printf -- '--slice--\n'; cat "$2"; }
  if [ -f "$C/dmg-tree/$EXE" ] && cmp -s <(joined "$C/zigBrowser.intel" "$C/zigBrowser.arm") "$C/dmg-tree/$EXE"; then
    ok "$label D3: the dmg holds the lipo join of both hosts' exe builds"
  else bad "$label D3: the dmg tree has no joined exe at $EXE"; fi
  if [ -f "$C/dmg-tree/$SHIM" ] && cmp -s <(joined "$C/libwkwebview_shim.dylib.intel" "$C/libwkwebview_shim.dylib.arm") "$C/dmg-tree/$SHIM"; then
    ok "$label D3: the dmg holds the lipo join of both hosts' shim builds at Contents/Frameworks"
  else bad "$label D3: the dmg tree has no joined shim at $SHIM ($(cd "$C/dmg-tree" 2>/dev/null && find . -type f | tr '\n' ' '))"; fi
  read_signs
  if [ "${#signs[@]}" -eq 3 ]; then ok "$label D4: three signing calls"
  else bad "$label D4: ${#signs[@]} signing call(s), want 3 (dylib, exe, .app): $(printf '%s | ' "${signs[@]%%"$US"*}")"; fi
  want_id=${ident:--}
  for ((i = 0; i < ${#signs[@]}; i++)); do
    IFS=$US read -r tgt id kc deep rt ent present <<<"${signs[i]}"
    [ "$tgt" = "${want[i]:-<none>}" ] || bad "$label D4: signing call $((i + 1)) is on '$tgt', want '${want[i]:-<none>}'"
    [ "$deep" = no ] || bad "$label D4: signing call $((i + 1)) ($tgt) uses --deep"
    [ "$present" = present ] || bad "$label D4: '$tgt' did not exist when it was signed"
    [ "$id" = "$want_id" ] || bad "$label D5: '$tgt' signed with identity '$id', want '$want_id'"
    if [ -z "$ident" ]; then
      [ -z "$kc" ] || bad "$label D5: the ad-hoc '$tgt' uses --keychain $kc"
      [ "$rt" = no ] || bad "$label D5: the ad-hoc '$tgt' uses --options runtime"
      [ -z "$ent" ] || bad "$label D5: the ad-hoc '$tgt' uses --entitlements $ent"
    else
      [ "$kc" = "$keychain" ] || bad "$label D5: the release '$tgt' uses keychain '$kc', want '$keychain'"
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

run_otool_fail() { # run_otool_fail <label> <identity or empty> <keychain or empty>: D7
  local label=$1 ident=$2 keychain=$3 rc hd
  rm -rf "${C:?}"/* "$R/zigBrowser_0.2.0_macos.dmg"
  touch "$C/otool_fail"
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$HOST" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/fake_mac_key" ${ident:+ZB_DMG_SIGN_IDENTITY="$ident"} \
     ${keychain:+ZB_DMG_SIGN_KEYCHAIN="$keychain"} \
     timeout 120 bash packaging/macos/build-dmg.sh >"$T/out.$label" 2>&1 </dev/null)
  rc=$?
  read_signs
  hd=$(ls "$C" | grep -cE '^hdiutil\.[0-9]+$')
  if [ "$rc" -ne 0 ] && grep -qxF "ERROR: otool -L $EXE failed" "$T/out.$label" && ! grep -q 'does not load' "$T/out.$label" \
     && [ "${#signs[@]}" -eq 0 ] && [ "$hd" -eq 0 ] && [ ! -e "$R/zigBrowser_0.2.0_macos.dmg" ]; then
    ok "$label D7: a failing otool (valid output, exit 3) stops the script with its own reason, before any signing or dmg"
  else bad "$label D7: exit $rc, ${#signs[@]} signing call(s), $hd hdiutil call(s), dmg $( [ -e "$R/zigBrowser_0.2.0_macos.dmg" ] && echo copied || echo absent): $(tail -n 2 "$T/out.$label" | tr '\n' ' ')"; fi
}

run_dmg adhoc "" ""
run_dmg release "Developer ID Application: Selftest (SELFTEST01)" "$MACHOME/zb-signing/dev.keychain-db"
run_otool_fail otoolfail-adhoc "" ""
run_otool_fail otoolfail-release "Developer ID Application: Selftest (SELFTEST01)" "$MACHOME/zb-signing/dev.keychain-db"
if [ "$(sed -n 2p "$R/packaging/macos/build-dmg.sh")" = "# Build an ad-hoc dev dmg, not a distributable artifact, on the M9 build host over Tailscale SSH." ]; then
  ok "TRIPWIRE: the header calls it an ad-hoc dev dmg, not a distributable artifact"
else bad "TRIPWIRE: header line 2 is '$(sed -n 2p "$R/packaging/macos/build-dmg.sh")'"; fi

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-dmg-script-selftest\n'; exit 0; fi
printf 'FAIL\tmac-dmg-script-selftest\t%s failure(s)\n' "$fails"
exit 1
