#!/usr/bin/env bash
# GREEN, REGISTERED (SilverRidge 0b4c44bd): execute the real runtime-rows gate, selecting only
# mac-signal-runtime, against two fake Macs.  This is execution coverage, not a source/comment match.
#
# Success proves the exact row/PASS tuple, exact-commit package/DMG identity before the row, a read-only attach and
# ditto unpack, a non-build-tree executable with the expected shim reference, three disposition and identity/send
# evidence records in each copied archive, verified evidence before confirmed cleanup, and no retained run root.
# Refusal cases prove unsafe disposition and unsafe identity send nothing, print a live LEAK, stop the host, copy
# evidence, retain the run root, and make the next run HOST_HELD before another row starts.  Transcript mutants drop
# selection, the row tuple, disposition/identity evidence, evidence copy, retention, hold, or cleanup proof; every
# one must be rejected by the same judges.
set -uo pipefail
if [ "${ZB_SIGNAL_GATE_RED_INNER:-}" != 1 ]; then
  ZB_SIGNAL_GATE_RED_INNER=1 exec unshare --user --map-root-user --pid --fork --mount-proc --net \
    bash "$(realpath "$0")" "$@"
fi

ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-signal-gate-red-XXXXXX") || exit 1
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-signal-gate-red-??????)
    chmod -R u+rwx "${T:?}" 2>/dev/null
    rm -rf -- "${T:?}"
  esac
}
trap cleanup EXIT

fails=0
TAB=$'\t'
ok() { printf 'ASSERT\tmac-signal-runtime\t%s\tpass\n' "$1"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1
ARM=arm@10.0.0.2
GATE=tests/mac/ms_runtime_rows_gate.sh
ROW=tests/e2e/mac_signal_runtime_test.py
ID=mac-signal-runtime
RD_RE='zb-gate-[0-9a-f]{40}-[0-9a-f]+'

mkdir -p "$T/bin" "$T/macbin" "$T/ctl" "$T/controller-home" "$T/tmp"
printf 'not a real key\n' > "$T/fake_mac_key"

cat > "$T/bin/ssh" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' ssh "\$@" > "$T/ctl/call.\$i"
while [ \$# -gt 0 ]; do case "\$1" in -i|-o|-F|-p|-l) shift 2 ;; -*) shift ;; *) break ;; esac; done
host=\$1; shift; cmd="\$*"; h="$T/mac/\$host"
mkdir -p "\$h" && cd "\$h" || exit 1
case "\$cmd" in
  *"zig build"*)
    rd=\$(/usr/bin/find "\$h" -mindepth 1 -maxdepth 1 -type d -name 'zb-gate-*' | head -n 1)
    [ -n "\$rd" ] || exit 1
    commit=\${rd##*/zb-gate-}; commit=\${commit%%-*}
    mkdir -p "\$rd/zig-out/bin" "\$rd/zig-out/Frameworks"
    printf 'thin build-tree executable %s %s\n' "\$commit" "\$host" > "\$rd/zig-out/bin/zigBrowser"
    printf 'thin build-tree shim %s %s\n' "\$commit" "\$host" > "\$rd/zig-out/Frameworks/libwkwebview_shim.dylib"
    chmod 755 "\$rd/zig-out/bin/zigBrowser"
    printf 'GENERIC_BUILD\t%s\t%s\n' "\$host" "\$rd" >> "$T/ctl/builds"
    /usr/bin/find "\$rd" -maxdepth 2 \( -name '*.dmg' -o -name '*.app' \) -print > "\$rd/generic-package-output"
    exit 0 ;;
esac
env -i PATH="$T/macbin:/usr/bin:/bin" HOME="\$h" ZB_FAKE_MAC="\$h" LANG=C.UTF-8 /bin/bash -c "\$cmd"
EOF

cat > "$T/bin/scp" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' scp "\$@" > "$T/ctl/call.\$i"
args=()
while [ \$# -gt 0 ]; do
  case "\$1" in -i|-o|-F|-P|-S|-c|-l) shift 2 ;; -*) shift ;; *) args+=("\$1"); shift ;; esac
done
[ "\${#args[@]}" -ge 2 ] || exit 1
last=\$((\${#args[@]} - 1)); dst=\${args[\$last]}; unset 'args[\$last]'
case "\$dst" in
  *:*)
    host=\${dst%%:*}; path=\${dst#*:}; target="$T/mac/\$host/\$path"
    if [ "\${#args[@]}" -gt 1 ] || [[ "\$path" = */ ]]; then mkdir -p "\$target"; fi
    for src in "\${args[@]}"; do cp -f -- "\$src" "\$target"; done ;;
  *)
    [ "\${#args[@]}" -eq 1 ] || exit 1
    src=\${args[0]}; case "\$src" in *:*) ;; *) exit 1 ;; esac
    host=\${src%%:*}; path=\${src#*:}
    cp -f -- "$T/mac/\$host/\$path" "\$dst" ;;
esac
EOF

cat > "$T/macbin/getconf" <<'EOF'
#!/bin/bash
case "$1" in
  DARWIN_USER_TEMP_DIR) echo "$ZB_FAKE_MAC/vf/0/T/" ;;
  DARWIN_USER_CACHE_DIR) echo "$ZB_FAKE_MAC/vf/0/C/" ;;
  *) exit 1 ;;
esac
EOF

cat > "$T/macbin/find" <<'EOF'
#!/bin/bash
exec /usr/bin/find "$@"
EOF

cat > "$T/macbin/lipo" <<'EOF'
#!/bin/bash
case "$1" in
  -create)
    shift; inputs=()
    while [ $# -gt 0 ]; do
      case "$1" in -output) out=$2; shift 2 ;; *) inputs+=("$1"); shift ;; esac
    done
    [ "${#inputs[@]}" -eq 2 ] && [ -n "${out:-}" ] || exit 1
    { printf 'FAKE-UNIVERSAL-MACHO arm64 x86_64\n'; cat "${inputs[@]}"; } > "$out" ;;
  -archs)
    case "$2" in */app/zigBrowser.app/*) printf 'LIPO_ARCHS\t%s\n' "$2" >> "$ZB_FAKE_MAC/package-tools" ;;
      *) printf 'PRODUCER_LIPO_ARCHS\t%s\n' "$2" >> "$ZB_FAKE_MAC/producer-tools" ;; esac
    grep -q '^FAKE-UNIVERSAL-MACHO arm64 x86_64$' "$2" && printf 'x86_64 arm64\n' || printf 'x86_64\n' ;;
  *) exit 2 ;;
esac
EOF

cat > "$T/macbin/codesign" <<'EOF'
#!/bin/bash
case " $* " in
  *" --verify "*)
    case "${@: -1}" in */app/zigBrowser.app) printf 'CODESIGN_VERIFY\t%s\n' "$*" >> "$ZB_FAKE_MAC/package-tools" ;;
      *) printf 'PRODUCER_CODESIGN_VERIFY\t%s\n' "$*" >> "$ZB_FAKE_MAC/producer-tools" ;; esac ;;
esac
exit 0
EOF

cat > "$T/macbin/sips" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in --out) out=$2; shift 2 ;; *) shift ;; esac; done
[ -n "${out:-}" ] || exit 1
printf 'fake resized icon\n' > "$out"
EOF

cat > "$T/macbin/iconutil" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2 ;; *) shift ;; esac; done
[ -n "${out:-}" ] || exit 1
printf 'fake icns\n' > "$out"
EOF

cat > "$T/macbin/hdiutil" <<'EOF'
#!/bin/bash
op=$1; shift
case "$op" in
  create)
    src= out=
    while [ $# -gt 0 ]; do
      case "$1" in
        -srcfolder) src=$2; shift 2 ;;
        -volname|-format) shift 2 ;;
        -ov) shift ;;
        -*) shift ;;
        *) out=$1; shift ;;
      esac
    done
    [ -d "$src" ] && [ -n "$out" ] || exit 1
    /usr/bin/tar -C "$src" -cf "$out" . || exit 1
    sha=$(sha256sum "$out" | cut -d' ' -f1)
    commit=${PWD##*/zb-gate-}; commit=${commit%%-*}
    printf 'PRODUCER_CREATE\t%s\t%s\t%s\n' "$commit" "$sha" "$out" >> "$ZB_FAKE_MAC/producer-tools" ;;
  attach)
    mp= dmg=
    while [ $# -gt 0 ]; do
      case "$1" in -mountpoint) mp=$2; shift 2 ;; -*) shift ;; *) dmg=$1; shift ;; esac
    done
    printf 'ATTACH\t%s\t%s\n' "$dmg" "$mp" >> "$ZB_FAKE_MAC/package-tools"
    [ -f "$dmg" ] && [ -d "$mp" ] || exit 1
    before=$(sha256sum "$dmg" | cut -d' ' -f1)
    /usr/bin/tar -C "$mp" -xf "$dmg" || exit 1
    mode=$(cat "$ZB_FAKE_MAC/package-mode" 2>/dev/null || echo good)
    exe="$mp/zigBrowser.app/Contents/MacOS/zigBrowser"
    case "$mode" in
      placeholder) : > "$exe" ;;
      wrong-dmg-digest) printf 'changed after attach\n' >> "$dmg" ;;
    esac
    printf '%s\n' "$before" > "$ZB_FAKE_MAC/dmg-before-attach"
    printf '/dev/disk7\tApple_HFS\t%s\n' "$mp" ;;
  detach)
    printf 'DETACH\t%s\n' "$1" >> "$ZB_FAKE_MAC/package-tools" ;;
  *) exit 2 ;;
esac
EOF

cat > "$T/macbin/ditto" <<'EOF'
#!/bin/bash
src=$1 dst=$2
printf 'DITTO\t%s\t%s\n' "$src" "$dst" >> "$ZB_FAKE_MAC/package-tools"
mode=$(cat "$ZB_FAKE_MAC/package-mode" 2>/dev/null || echo good)
case "$mode" in
  fake-app)
    mkdir -p "$dst/Contents/MacOS" "$dst/Contents/Frameworks"
    printf 'arbitrary fake app executable\n' > "$dst/Contents/MacOS/zigBrowser"
    printf 'arbitrary fake shim\n' > "$dst/Contents/Frameworks/libwkwebview_shim.dylib"
    chmod 755 "$dst/Contents/MacOS/zigBrowser" ;;
  *) cp -R "$src" "$dst" ;;
esac
exe="$dst/Contents/MacOS/zigBrowser"
build="$PWD/zig-out/bin/zigBrowser"
case "$mode" in
  renamed-build) rm -f -- "$exe"; mv "$build" "$exe" ;;
  copied-build) cp -f "$build" "$exe" ;;
  symlinked-build) rm -f -- "$exe"; ln -s "$build" "$exe" ;;
  hardlinked-build) rm -f -- "$exe"; ln "$build" "$exe" ;;
esac
EOF

cat > "$T/macbin/otool" <<'EOF'
#!/bin/bash
target=${@: -1}
case "$target" in
  */app/zigBrowser.app/*)
    printf 'OTOOL\t%s\n' "$*" >> "$ZB_FAKE_MAC/package-tools"
    runtime=1 ;;
  *) printf 'PRODUCER_OTOOL\t%s\n' "$*" >> "$ZB_FAKE_MAC/producer-tools" ;;
esac
printf '%s:\n' "$target"
[ "${runtime:-0}:$(cat "$ZB_FAKE_MAC/package-mode" 2>/dev/null || echo good)" = 1:missing-shim-ref ] \
  || printf '\t@executable_path/../Frameworks/libwkwebview_shim.dylib (compatibility version 0.0.0, current version 0.0.0)\n'
EOF

chmod +x "$T/macbin/lipo" "$T/macbin/codesign" "$T/macbin/sips" "$T/macbin/iconutil" \
  "$T/macbin/hdiutil" "$T/macbin/ditto" "$T/macbin/otool"

cat > "$T/macbin/python3" <<'EOF'
#!/bin/bash
row=$1
shift
printf '%s\t%s\n' "$row" "$*" >> "$ZB_FAKE_MAC/row-args"
[ "$row" = tests/e2e/mac_signal_runtime_test.py ] || { printf 'unexpected row %s\n' "$row"; exit 2; }
[ "${1:-}" = --browser ] || { printf 'FAIL\tmac-signal-runtime\tmissing-browser-option\n'; exit 1; }
browser=${2:-}
case "$browser" in
  "$PWD/app/zigBrowser.app/Contents/MacOS/zigBrowser") ;;
  *) printf 'FAIL\tmac-signal-runtime\tpackaged-app-required\t%s\n' "$browser"; exit 1 ;;
esac
case "$browser" in *zig-out*) printf 'FAIL\tmac-signal-runtime\tbuild-tree-browser\n'; exit 1 ;; esac
[ "${3:-}" = --package-evidence ] && manifest=${4:-} \
  || { printf 'FAIL\tmac-signal-runtime\tmissing-package-evidence\n'; exit 1; }
[ "${5:-}" = --package-commit ] && commit=${6:-} \
  || { printf 'FAIL\tmac-signal-runtime\tmissing-package-commit\n'; exit 1; }
case "$PWD" in *"/zb-gate-$commit-"*) ;; *) printf 'FAIL\tmac-signal-runtime\twrong-package-commit\n'; exit 1 ;; esac
[ -f "$manifest" ] && [ ! -L "$manifest" ] || { printf 'FAIL\tmac-signal-runtime\tbad-package-evidence\n'; exit 1; }
[ -f "$browser" ] && [ ! -L "$browser" ] && [ -s "$browser" ] && [ -x "$browser" ] \
  || { printf 'FAIL\tmac-signal-runtime\tbinary-not-packaged\n'; exit 1; }
build=$PWD/zig-out/bin/zigBrowser
shim=$PWD/app/zigBrowser.app/Contents/Frameworks/libwkwebview_shim.dylib
dmg=$PWD/zigBrowser-exact.dmg
[ -f "$build" ] && [ -f "$shim" ] && [ ! -L "$shim" ] && [ -s "$shim" ] && [ -f "$dmg" ] \
  || { printf 'FAIL\tmac-signal-runtime\tpackage-input-missing\n'; exit 1; }
if [ "$(sha256sum "$browser" | cut -d' ' -f1)" = "$(sha256sum "$build" | cut -d' ' -f1)" ] \
   || [ "$browser" -ef "$build" ]; then
  printf 'FAIL\tmac-signal-runtime\tbuild-tree-substitution\n'; exit 1
fi
mapfile -t package < "$manifest"
[ "${#package[@]}" -eq 11 ] \
  && [ "${package[0]}" = "PACKAGE_COMMIT"$'\t'"$commit" ] \
  && [ "${package[2]}" = $'PACKAGE_FLOW\thdiutil-attach-readonly\tditto' ] \
  && grep -q $'^PACKAGE_DMG\t[0-9a-f]\{64\}\t[1-9][0-9]*\t' "$manifest" \
  && grep -q $'^PACKAGE_APP\t[0-9a-f]\{64\}\t' "$manifest" \
  && grep -q $'^PACKAGE_EXECUTABLE\t[0-9a-f]\{64\}\t[1-9][0-9]*\t' "$manifest" \
  && grep -q $'^PACKAGE_BUILD_EXECUTABLE\t[0-9a-f]\{64\}\t[1-9][0-9]*\t' "$manifest" \
  && grep -q $'^PACKAGE_SHIM\t[0-9a-f]\{64\}\t[1-9][0-9]*\t' "$manifest" \
  && grep -qx $'PACKAGE_UNIVERSAL\texecutable=arm64,x86_64\tshim=arm64,x86_64' "$manifest" \
  && grep -qx $'PACKAGE_CODESIGN\t--verify --strict --deep\trc=0' "$manifest" \
  && grep -qx $'PACKAGE_SHIM_REF\t@executable_path/../Frameworks/libwkwebview_shim.dylib\tx86_64=1\tarm64=1' "$manifest" \
  || { printf 'FAIL\tmac-signal-runtime\tmalformed-package-evidence\n'; exit 1; }
dmg_sha=$(sha256sum "$dmg" | cut -d' ' -f1); exe_sha=$(sha256sum "$browser" | cut -d' ' -f1)
build_sha=$(sha256sum "$build" | cut -d' ' -f1); shim_sha=$(sha256sum "$shim" | cut -d' ' -f1)
grep -qx "PACKAGE_PRODUCER${TAB:-$'\t'}packaging/macos/build-dmg.sh${TAB:-$'\t'}$commit${TAB:-$'\t'}$dmg_sha" "$manifest" \
  && grep -qx "PACKAGE_DMG${TAB:-$'\t'}$dmg_sha${TAB:-$'\t'}$(wc -c < "$dmg")${TAB:-$'\t'}$dmg" "$manifest" \
  && grep -qx "PACKAGE_EXECUTABLE${TAB:-$'\t'}$exe_sha${TAB:-$'\t'}$(wc -c < "$browser")${TAB:-$'\t'}$browser" "$manifest" \
  && grep -qx "PACKAGE_BUILD_EXECUTABLE${TAB:-$'\t'}$build_sha${TAB:-$'\t'}$(wc -c < "$build")${TAB:-$'\t'}$build" "$manifest" \
  && grep -qx "PACKAGE_SHIM${TAB:-$'\t'}$shim_sha${TAB:-$'\t'}$(wc -c < "$shim")${TAB:-$'\t'}$shim" "$manifest" \
  || { printf 'FAIL\tmac-signal-runtime\tpackage-digest-mismatch\n'; exit 1; }
mapfile -t tools < "$ZB_FAKE_MAC/package-tools"
[ "${#tools[@]}" -eq 8 ] \
  && [ "${tools[0]}" = "ATTACH${TAB:-$'\t'}$dmg${TAB:-$'\t'}$PWD/mnt" ] \
  && [ "${tools[1]}" = "DITTO${TAB:-$'\t'}$PWD/mnt/zigBrowser.app${TAB:-$'\t'}$PWD/app/zigBrowser.app" ] \
  && [ "${tools[2]}" = "DETACH${TAB:-$'\t'}/dev/disk7" ] \
  && [ "${tools[3]}" = "LIPO_ARCHS${TAB:-$'\t'}$browser" ] \
  && [ "${tools[4]}" = "LIPO_ARCHS${TAB:-$'\t'}$shim" ] \
  && [ "${tools[5]}" = "CODESIGN_VERIFY${TAB:-$'\t'}--verify --strict --deep --verbose=2 $PWD/app/zigBrowser.app" ] \
  && [ "${tools[6]}" = "OTOOL${TAB:-$'\t'}-arch x86_64 -L $browser" ] \
  && [ "${tools[7]}" = "OTOOL${TAB:-$'\t'}-arch arm64 -L $browser" ] \
  || { printf 'FAIL\tmac-signal-runtime\tpackage-flow-not-observed\n'; exit 1; }
app_sha=$(cut -f2 <<<"${package[4]}")
printf 'PACKAGE\t%s\tproducer=packaging/macos/build-dmg.sh\tdmg=%s\tapp=%s\texe=%s\tshim=%s\tshim-ref=@executable_path/../Frameworks/libwkwebview_shim.dylib\n' \
  "$commit" "$dmg_sha" "$app_sha" "$exe_sha" "$shim_sha"
mode=$(cat "$ZB_FAKE_MAC/row-mode" 2>/dev/null || echo good)
case "$mode" in
  bad-disposition)
    printf 'REFUSED_DISPOSITION\tHUP\tCUSTOM\nFAIL\tmac-signal-runtime\n'
    printf 'LEAK\t4242\t4242\tFri Oct 24 12:00:00 2026\t%s --automation-api --e2e-protocol\n' "$browser"
    exit 1 ;;
  bad-identity)
    printf 'SIGNAL_DISPOSITION\tHUP\tSIGINT=SIG_IGN\tSIGTERM=SIG_IGN\tSIGHUP=SIG_IGN\n'
    printf 'REFUSED_IDENTITY\tHUP\tpid=1\nFAIL\tmac-signal-runtime\n'
    printf 'LEAK\t4243\t4243\tFri Oct 24 12:00:00 2026\t%s --automation-api --e2e-protocol\n' "$browser"
    exit 1 ;;
  bad-term-disposition)
    for label in HUP INT; do
      printf 'SIGNAL_DISPOSITION\t%s\tSIGINT=SIG_IGN\tSIGTERM=SIG_IGN\tSIGHUP=SIG_IGN\n' "$label"
      printf 'SIGNAL_IDENTITY\t%s\tpid=4242\tpgid=4242\tstart=Fri Oct 24 12:00:00 2026\tcommand=%s --automation-api --e2e-protocol\n' "$label" "$browser"
      printf 'SIGNAL_SEND\t%s\tpid=4242\tsignal=SIG%s\tcount=1\n' "$label" "$label"
    done
    printf 'REFUSED_DISPOSITION\tTERM\tSIGTERM=CUSTOM\nFAIL\tmac-signal-runtime\n'
    printf 'LEAK\t4244\t4244\tFri Oct 24 12:00:00 2026\t%s --automation-api --e2e-protocol\n' "$browser"
    exit 1 ;;
esac
for label in HUP INT TERM; do
  printf 'SIGNAL_DISPOSITION\t%s\tSIGINT=SIG_IGN\tSIGTERM=SIG_IGN\tSIGHUP=SIG_IGN\n' "$label"
  printf 'SIGNAL_IDENTITY\t%s\tpid=4242\tpgid=4242\tstart=Fri Oct 24 12:00:00 2026\tcommand=%s --automation-api --e2e-protocol\n' "$label" "$browser"
  printf 'SIGNAL_SEND\t%s\tpid=4242\tsignal=SIG%s\tcount=1\n' "$label" "$label"
done
printf 'PASS\tmac-signal-runtime\n'
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp" "$T/macbin/getconf" "$T/macbin/find" "$T/macbin/python3"

fresh_macs() {
  chmod -R u+rwx "$T/mac" 2>/dev/null
  rm -rf -- "${T:?}/mac"
  local h
  for h in "$INTEL" "$ARM"; do
    mkdir -p "$T/mac/$h/vf/0/T" "$T/mac/$h/vf/0/C" "$T/mac/$h/Library/Logs/DiagnosticReports"
    printf 'old report\n' > "$T/mac/$h/Library/Logs/DiagnosticReports/old.ips"
    printf 'good\n' > "$T/mac/$h/row-mode"
    printf 'good\n' > "$T/mac/$h/package-mode"
  done
  rm -f "$T/ctl"/*
}

R="$T/repo"
mkdir -p "$R/tests/mac" "$R/tests/e2e" "$R/src" "$R/packaging/macos" "$R/packaging/assets"
for f in "$ROOT"/tests/mac/*; do [ -f "$f" ] && cp -f "$f" "$R/tests/mac/"; done
cp -f "$ROOT/tests/e2e/mac_signal_runtime_test.py" "$R/tests/e2e/"
cp -f "$ROOT/packaging/macos/build-dmg.sh" "$R/packaging/macos/build-dmg.sh"
cp -f "$ROOT/packaging/macos/Info.plist" "$R/packaging/macos/Info.plist"
cp -f "$ROOT/packaging/macos/entitlements.plist" "$R/packaging/macos/entitlements.plist"
cp -f "$ROOT/packaging/assets/zigBrowser.png" "$R/packaging/assets/zigBrowser.png"
printf 'src\n' > "$R/src/main.zig"
printf 'build\n' > "$R/build.zig"
printf 'zon\n' > "$R/build.zig.zon"
printf '{}\n' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/controller-home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A && \
  "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m signal-gate-red \
  || { bad "could not create exact fake-host repo"; exit 1; }
COMMIT=$("${G[@]}" rev-parse HEAD)

# Mutant transport only: unlike the good generic-build fake above, this one
# fabricates a tar bearing a .dmg name after any ordinary `zig build`.  It must
# never be accepted as evidence that the real package producer ran.
mkdir "$T/fabricating-bin"
cat > "$T/fabricating-bin/ssh" <<EOF
#!/bin/bash
"$T/bin/ssh" "\$@"
rc=\$?
[ "\$rc" -eq 0 ] || exit "\$rc"
case "\$*" in
  *"zig build"*)
    /usr/bin/tar -C "$R" -cf "$R/zigBrowser_0.2.0_macos.dmg" build.zig || exit 1
    sha256sum "$R/zigBrowser_0.2.0_macos.dmg" > "$T/ctl/generic-fabricated-dmg"
    printf '==> Done: %s\n' "$R/zigBrowser_0.2.0_macos.dmg" ;;
esac
EOF
chmod +x "$T/fabricating-bin/ssh"

EVD="$T/evidence"
OUT= RC=0
run_gate() { # existing fake Mac state is preserved; the evidence destination is always fresh
  local transport=${1:-$T/bin}
  chmod -R u+rwx "$EVD" 2>/dev/null
  rm -rf -- "${EVD:?}"
  mkdir -m 700 "$EVD"
  (cd "$R" && env -i PATH="$transport:$T/bin:/usr/bin:/bin" HOME="$T/controller-home" TMPDIR="$T/tmp" \
     ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$T/fake_mac_key" \
     ZB_RUNTIME_ROWS="$ID" ZB_MAC_EVIDENCE_DIR="$EVD" ZB_MAC_BUILD_TIMEOUT=60 ZB_MAC_LEG_TIMEOUT=60 \
     timeout 120 bash "$GATE" > "$T/gate.out" 2>&1 </dev/null)
  RC=$?
  OUT=$(cat "$T/gate.out")
}

ev_line() { grep $'^EVIDENCE\t'"$1"$'\t'"$2"$'\t' <<<"$OUT"; }
ev_ok() {
  local line file="$EVD/$2/evidence.tar"
  line=$(ev_line "$1" "$2")
  [ -f "$file" ] && [ "$(grep -c . <<<"$line")" -eq 1 ] \
    && [ "$line" = "EVIDENCE"$'\t'"$1"$'\t'"$2"$'\t'"$(sha256sum "$file" | cut -d' ' -f1)"$'\t'"$(wc -c < "$file")"$'\t'"$file" ]
}
member() { tar -xOf "$EVD/$1/evidence.tar" "$2" 2>/dev/null; }
line_no() { grep -n -m1 -- "$1" <<<"$2" | cut -d: -f1; }
run_dirs() { find "$T/mac/$1" -mindepth 1 -maxdepth 1 -type d -name 'zb-gate-*' -printf '%f\n' | sort; }

row_has_exact_evidence() { # $1 = extracted row-output file
  local f=$1 label package disposition
  [ "$(grep -c $'^PACKAGE\t' "$f")" -eq 1 ] || return 1
  grep -q "^PACKAGE${TAB:-$'\t'}$COMMIT${TAB:-$'\t'}producer=packaging/macos/build-dmg.sh${TAB:-$'\t'}dmg=[0-9a-f]\{64\}${TAB:-$'\t'}app=[0-9a-f]\{64\}${TAB:-$'\t'}exe=[0-9a-f]\{64\}${TAB:-$'\t'}shim=[0-9a-f]\{64\}${TAB:-$'\t'}shim-ref=@executable_path/../Frameworks/libwkwebview_shim.dylib$" "$f" || return 1
  package=$(line_no $'^PACKAGE\t' "$(cat "$f")")
  disposition=$(line_no $'^SIGNAL_DISPOSITION\t' "$(cat "$f")")
  [ -n "$package" ] && [ -n "$disposition" ] && [ "$package" -lt "$disposition" ] || return 1
  [ "$(grep -c $'^SIGNAL_DISPOSITION\t' "$f")" -eq 3 ] || return 1
  [ "$(grep -c $'^SIGNAL_IDENTITY\t' "$f")" -eq 3 ] || return 1
  [ "$(grep -c $'^SIGNAL_SEND\t' "$f")" -eq 3 ] || return 1
  for label in HUP INT TERM; do
    grep -qx "SIGNAL_DISPOSITION${TAB:-$'\t'}$label${TAB:-$'\t'}SIGINT=SIG_IGN${TAB:-$'\t'}SIGTERM=SIG_IGN${TAB:-$'\t'}SIGHUP=SIG_IGN" "$f" || return 1
    grep -q "^SIGNAL_IDENTITY${TAB:-$'\t'}$label${TAB:-$'\t'}pid=4242${TAB:-$'\t'}pgid=4242${TAB:-$'\t'}start=.*${TAB:-$'\t'}command=.*/app/zigBrowser.app/Contents/MacOS/zigBrowser " "$f" || return 1
    grep -q "^SIGNAL_SEND${TAB:-$'\t'}$label${TAB:-$'\t'}pid=4242${TAB:-$'\t'}signal=SIG$label${TAB:-$'\t'}count=1$" "$f" || return 1
  done
  grep -qx $'PASS\tmac-signal-runtime' "$f"
}

row_dmg() { sed -n 's/^PACKAGE\t[^\t]*\tproducer=packaging\/macos\/build-dmg.sh\tdmg=\([0-9a-f]*\)\t.*/\1/p' "$1"; }

judge_success() { # $1 output file, $2 x86 row file, $3 arm row file; current fake roots must be absent
  local of=$1 xf=$2 af=$3 text h a ev rm pass producer_line producer_sha
  text=$(cat "$of")
  [ "$(grep -cx $'ROWS_SELECTED\tmac-signal-runtime' <<<"$text")" -eq 1 ] || return 1
  [ "$(grep -cx $'ROW\ttests/e2e/mac_signal_runtime_test.py\tgreen\trc=0\tMATCH' <<<"$text")" -eq 2 ] || return 1
  grep -qx $'PASS\tms-runtime-rows-gate\tboth-arches' <<<"$text" || return 1
  row_has_exact_evidence "$xf" && row_has_exact_evidence "$af" || return 1
  producer_line=$(grep $'^PRODUCER_DMG\t' <<<"$text")
  [ "$(grep -c $'^PRODUCER_DMG\t' <<<"$text")" -eq 1 ] || return 1
  producer_sha=$(cut -f4 <<<"$producer_line")
  [ "$(cut -f1 <<<"$producer_line")" = PRODUCER_DMG ] \
    && [ "$(cut -f2 <<<"$producer_line")" = packaging/macos/build-dmg.sh ] \
    && [ "$(cut -f3 <<<"$producer_line")" = "$COMMIT" ] \
    && [[ "$producer_sha" =~ ^[0-9a-f]{64}$ ]] \
    && [[ "$(cut -f5 <<<"$producer_line")" =~ ^[1-9][0-9]*$ ]] || return 1
  [ "$(row_dmg "$xf")" = "$producer_sha" ] && [ "$(row_dmg "$af")" = "$producer_sha" ] || return 1
  grep -qx "PRODUCER_CREATE${TAB:-$'\t'}$COMMIT${TAB:-$'\t'}$producer_sha${TAB:-$'\t'}.*zigBrowser_0.2.0_macos.dmg" \
    "$T/mac/$INTEL/producer-tools" || return 1
  [ "$(grep -c '^GENERIC_BUILD' "$T/ctl/builds")" -eq 4 ] || return 1
  for ha in "$INTEL|x86_64" "$ARM|arm64"; do
    h=${ha%|*}; a=${ha#*|}
    grep -q "^EVIDENCE${TAB:-$'\t'}$h${TAB:-$'\t'}$a${TAB:-$'\t'}[0-9a-f]\{64\}${TAB:-$'\t'}" <<<"$text" || return 1
    ev=$(line_no $'^EVIDENCE\t'"$h" "$text")
    rm=$(grep -n $'^REMOVED\t'"$h" <<<"$text" | tail -n 1 | cut -d: -f1)
    pass=$(line_no $'^PASS\tms-runtime-rows-gate\t' "$text")
    [ -n "$ev" ] && [ -n "$rm" ] && [ -n "$pass" ] && [ "$ev" -lt "$rm" ] && [ "$rm" -lt "$pass" ] || return 1
    [ -z "$(run_dirs "$h")" ] || return 1
    args=$(cat "$T/mac/$h/row-args" 2>/dev/null)
    [ "$(grep -c '^tests/e2e/mac_signal_runtime_test.py' <<<"$args")" -eq 1 ] || return 1
    grep -q $'\t--browser .*/app/zigBrowser.app/Contents/MacOS/zigBrowser --package-evidence .*/evidence/package.manifest --package-commit [0-9a-f]\{40\}$' <<<"$args" || return 1
    ! grep -q 'zig-out/bin/zigBrowser' <<<"$args" || return 1
    [ "$(cut -f1 "$T/mac/$h/package-tools")" = $'ATTACH\nDITTO\nDETACH\nLIPO_ARCHS\nLIPO_ARCHS\nCODESIGN_VERIFY\nOTOOL\nOTOOL' ] || return 1
  done
}

fake_state_mutants() { # base success was real; each one-field evidence/transcript deletion must be rejected
  local state=$1 m
  sed '/^ROWS_SELECTED/d' "$state/gate.out" > "$state/no-selection.out"
  ! judge_success "$state/no-selection.out" "$state/x86.row" "$state/arm.row" || bad "M1 dropped selection survived"
  sed '0,/^ROW/{/^ROW/d;}' "$state/gate.out" > "$state/no-row.out"
  ! judge_success "$state/no-row.out" "$state/x86.row" "$state/arm.row" || bad "M2 dropped row tuple survived"
  sed '0,/^SIGNAL_DISPOSITION/{/^SIGNAL_DISPOSITION/d;}' "$state/x86.row" > "$state/no-disposition.row"
  ! judge_success "$state/gate.out" "$state/no-disposition.row" "$state/arm.row" || bad "M3 dropped disposition evidence survived"
  sed '0,/^SIGNAL_IDENTITY/{/^SIGNAL_IDENTITY/d;}' "$state/x86.row" > "$state/no-identity.row"
  ! judge_success "$state/gate.out" "$state/no-identity.row" "$state/arm.row" || bad "M4 dropped identity evidence survived"
  sed '0,/^PACKAGE/{/^PACKAGE/d;}' "$state/x86.row" > "$state/no-package.row"
  ! judge_success "$state/gate.out" "$state/no-package.row" "$state/arm.row" || bad "M4b dropped package identity survived"
  sed '/^PRODUCER_DMG/d' "$state/gate.out" > "$state/no-producer.out"
  ! judge_success "$state/no-producer.out" "$state/x86.row" "$state/arm.row" || bad "M4c dropped producer digest survived"
  sed 's/\tdmg=[0-9a-f]\{64\}\t/\tdmg=0000000000000000000000000000000000000000000000000000000000000000\t/' \
    "$state/arm.row" > "$state/other-leg-dmg.row"
  ! judge_success "$state/gate.out" "$state/x86.row" "$state/other-leg-dmg.row" || bad "M4d other leg digest survived"
  cp -f "$T/mac/$INTEL/producer-tools" "$state/producer-tools"
  sed '/^PRODUCER_CREATE/d' "$state/producer-tools" > "$T/mac/$INTEL/producer-tools"
  ! judge_success "$state/gate.out" "$state/x86.row" "$state/arm.row" || bad "M4e unexecuted producer survived"
  cp -f "$state/producer-tools" "$T/mac/$INTEL/producer-tools"
  sed "/^EVIDENCE${TAB:-$'\t'}$INTEL${TAB:-$'\t'}/d" "$state/gate.out" > "$state/no-evidence.out"
  ! judge_success "$state/no-evidence.out" "$state/x86.row" "$state/arm.row" || bad "M5 dropped evidence copy survived"
  mkdir -p "$T/mac/$INTEL/zb-gate-0000000000000000000000000000000000000000-dead"
  ! judge_success "$state/gate.out" "$state/x86.row" "$state/arm.row" || bad "M6 dropped cleanup verification survived"
  rm -rf -- "${T:?}/mac/$INTEL/zb-gate-0000000000000000000000000000000000000000-dead"
  [ "$fails" -eq 0 ] && ok "integration-success-mutants"
}

fresh_macs
run_gate
if [ "$RC" -ne 0 ]; then
  bad "G1 real two-host named selection did not pass: rc=$RC $(grep -E '^(NOT RUN|FAIL|ROWS_SELECTED)' <<<"$OUT" | tr '\n' ' ')"
else
  STATE="$T/success-state"
  mkdir "$STATE"
  cp -f "$T/gate.out" "$STATE/gate.out"
  member x86_64 "evidence/rows/$ID.out" > "$STATE/x86.row"
  member arm64 "evidence/rows/$ID.out" > "$STATE/arm.row"
  if judge_success "$STATE/gate.out" "$STATE/x86.row" "$STATE/arm.row"; then
    ok "integration-two-host-success"
    fake_state_mutants "$STATE"
  else
    bad "G1 success state lacks selection/output/evidence/cleanup proof"
  fi
fi

if [ "$fails" -ne 0 ]; then
  printf 'FAIL\tms-signal-runtime-gate-red\t%s failure(s)\n' "$fails"
  exit 1
fi

# The good run above proves that the real script can traverse the executing
# transports.  These four controls replace only that producer boundary and
# must all stop before the browser row, with no real PRODUCER_CREATE trace.
GOOD_GATE="$T/ms_runtime_rows_gate.good"
cp -f "$R/$GATE" "$GOOD_GATE"
PRODUCER_LINE=$(grep -nF 'ZB_GATE_COMMIT="$COMMIT" bash packaging/macos/build-dmg.sh' "$GOOD_GATE" | cut -d: -f1)
[ "$(grep -cF 'ZB_GATE_COMMIT="$COMMIT" bash packaging/macos/build-dmg.sh' "$GOOD_GATE")" -eq 1 ] \
  || { bad "P0 good gate lacks one exact producer call"; PRODUCER_LINE=0; }
mutate_producer_line() { # $1 replacement for only the real producer invocation
  sed "${PRODUCER_LINE}c\\$1" "$GOOD_GATE" > "$R/$GATE"
}
check_producer_control() { # $1 name $2 transport $3 expected builds $4 expected attaches $5 fabricated-DMG event
  local name=$1 transport=$2 want_builds=$3 want_attach=$4 want_fabricated=$5
  local row_calls=0 creates=0 builds=0 attaches=0 fabricated=0 h
  fresh_macs
  run_gate "$transport"
  for h in "$INTEL" "$ARM"; do
    [ ! -f "$T/mac/$h/row-args" ] || row_calls=$((row_calls + $(wc -l < "$T/mac/$h/row-args")))
    [ ! -f "$T/mac/$h/producer-tools" ] \
      || creates=$((creates + $(grep -c '^PRODUCER_CREATE' "$T/mac/$h/producer-tools")))
    [ ! -f "$T/mac/$h/package-tools" ] \
      || attaches=$((attaches + $(grep -c '^ATTACH' "$T/mac/$h/package-tools")))
  done
  [ ! -f "$T/ctl/builds" ] || builds=$(grep -c '^GENERIC_BUILD' "$T/ctl/builds")
  [ ! -f "$T/ctl/generic-fabricated-dmg" ] || fabricated=1
  if [ "$RC" -ne 0 ] && [ "$row_calls" -eq 0 ] && [ "$creates" -eq 0 ] \
     && [ "$builds" -eq "$want_builds" ] && [ "$attaches" -eq "$want_attach" ] \
     && [ "$fabricated" -eq "$want_fabricated" ] \
     && ! grep -q $'^PASS\tms-runtime-rows-gate' <<<"$OUT"; then
    ok "producer-control-$name-red-before-row"
  else
    bad "P0 producer control $name survived/wrong boundary: rc=$RC rows=$row_calls creates=$creates builds=$builds attaches=$attaches fabricated=$fabricated"
  fi
  cp -f "$GOOD_GATE" "$R/$GATE"
}

if [ "$PRODUCER_LINE" -gt 0 ]; then
  mutate_producer_line '# ZB_GATE_COMMIT="$COMMIT" bash packaging/macos/build-dmg.sh (name only; producer is not run)'
  check_producer_control comment-only "$T/bin" 0 0 0

  mutate_producer_line 'printf '\''%s\n'\'' '\''ZB_GATE_COMMIT="$COMMIT" bash packaging/macos/build-dmg.sh'\'' > "$PACKAGE_LOG"'
  check_producer_control unrelated-command "$T/bin" 0 0 0

  mutate_producer_line 'ZB_GATE_COMMIT="$COMMIT" bash tests/mac/build-on-mac.sh > "$PACKAGE_LOG" 2>&1 || package_rc=$?'
  check_producer_control ordinary-build-fabricates-dmg "$T/fabricating-bin" 1 0 1

  mutate_producer_line '/usr/bin/tar -cf "$PACKAGE_DMG" build.zig && printf '\''==> Done: %s\n'\'' "$PACKAGE_DMG" > "$PACKAGE_LOG" || package_rc=$?'
  check_producer_control arbitrary-tar-renamed-dmg "$T/bin" 2 2 0
fi

if [ "$fails" -ne 0 ]; then
  printf 'FAIL\tms-signal-runtime-gate-red\t%s failure(s)\n' "$fails"
  exit 1
fi

check_package_rejection() { # exact package-flow substitution must stop before the signal row begins
  local mode=$1 h=$INTEL a=x86_64 row_calls tools
  fresh_macs
  printf '%s\n' "$mode" > "$T/mac/$h/package-mode"
  run_gate
  if [ -f "$T/mac/$h/row-args" ]; then row_calls=$(wc -l < "$T/mac/$h/row-args"); else row_calls=0; fi
  tools=$(cut -f1 "$T/mac/$h/package-tools" 2>/dev/null | tr '\n' ' ')
  if [ "$RC" -ne 0 ] && [ "$row_calls" -eq 0 ] && [[ "$tools" == ATTACH* ]] \
     && ! grep -q $'^PASS\tms-runtime-rows-gate' <<<"$OUT" && ev_ok "$h" "$a" \
     && [ -z "$(run_dirs "$h")" ]; then
    ok "package-mutant-$mode-red-before-row"
  else
    bad "P1 package mutant $mode survived or failed outside its boundary: rc=$RC rows=$row_calls tools=[$tools]"
  fi
}

for package_mode in placeholder renamed-build copied-build symlinked-build hardlinked-build fake-app wrong-dmg-digest missing-shim-ref; do
  check_package_rejection "$package_mode"
done

judge_refusal() { # $1 transcript, $2 row output, $3 host, $4 arch, $5 retained root, $6 sends before refusal
  local text=$1 row=$2 h=$3 a=$4 rd=$5 sends=$6 send_ok=0
  case "$sends" in
    none) ! grep -q $'^SIGNAL_SEND\t' <<<"$row" && send_ok=1 ;;
    hup-int)
      [ "$(grep -c $'^SIGNAL_SEND\t' <<<"$row")" -eq 2 ] \
        && grep -qx $'SIGNAL_SEND\tHUP\tpid=4242\tsignal=SIGHUP\tcount=1' <<<"$row" \
        && grep -qx $'SIGNAL_SEND\tINT\tpid=4242\tsignal=SIGINT\tcount=1' <<<"$row" \
        && ! grep -q $'^SIGNAL_SEND\tTERM\t' <<<"$row" && send_ok=1 ;;
  esac
  grep -q $'^HOST_STOPPED\ttests/e2e/mac_signal_runtime_test.py\t' <<<"$text" \
    && grep -q $'^RETAINED\t'"$h"$'\t'"$rd"$'\t' <<<"$text" \
    && grep -q $'^EVIDENCE\t'"$h"$'\t'"$a"$'\t' <<<"$text" \
    && ! grep -qx "REMOVED${TAB:-$'\t'}$h${TAB:-$'\t'}$rd" <<<"$text" \
    && ! grep -q $'^PASS\tms-runtime-rows-gate' <<<"$text" \
    && grep -q $'^PACKAGE\t' <<<"$row" && grep -q $'^LEAK\t' <<<"$row" && [ "$send_ok" -eq 1 ]
}

judge_hold() { # $1 transcript, $2 retained root
  grep -q $'^HOST_HELD\t../'"$2"'/LEAKED' <<<"$1" && ! grep -q $'^PASS\tms-runtime-rows-gate' <<<"$1"
}

check_refusal_and_hold() { # $1 host, $2 arch, $3 mode, $4 refusal marker, $5 sends before refusal
  local h=$1 a=$2 mode=$3 marker=$4 sends=$5 before rd row rc1 out1 held_before out2 rc2
  fresh_macs
  printf '%s\n' "$mode" > "$T/mac/$h/row-mode"
  run_gate; rc1=$RC; out1=$OUT
  rd=$(run_dirs "$h" | head -n 1)
  row=$(member "$a" "evidence/rows/$ID.out")
  if [ "$rc1" -ne 0 ] && [ -n "$rd" ] && [ -f "$T/mac/$h/$rd/LEAKED" ] \
     && grep -q "^$marker" <<<"$row" && grep -q $'^LEAK\t' <<<"$row" \
     && ev_ok "$h" "$a" && judge_refusal "$out1" "$row" "$h" "$a" "$rd" "$sends"; then
    ok "integration-$mode-refusal-leak-retain"
  else
    bad "G2 $mode refusal/retention failed: rc=$rc1 rd=$rd $(grep -E '^(HOST_STOPPED|EVIDENCE|RETAINED|REMOVED)' <<<"$out1" | tr '\n' ' ') row=[$(tr '\n' ' ' <<<"$row")]"
    return
  fi
  printf '%s\n' "$out1" > "$T/refusal.out"
  sed '/^RETAINED/d' "$T/refusal.out" > "$T/no-retained.out"
  ! judge_refusal "$(cat "$T/no-retained.out")" "$row" "$h" "$a" "$rd" "$sends" || bad "M7 dropped retention survived"
  sed '/^HOST_STOPPED/d' "$T/refusal.out" > "$T/no-stop.out"
  ! judge_refusal "$(cat "$T/no-stop.out")" "$row" "$h" "$a" "$rd" "$sends" || bad "M8 dropped HOST_STOPPED survived"
  before=$(wc -l < "$T/mac/$h/row-args")
  run_gate; rc2=$RC; out2=$OUT
  if [ "$rc2" -ne 0 ] && judge_hold "$out2" "$rd" \
     && [ "$(wc -l < "$T/mac/$h/row-args")" -eq "$before" ] && [ -e "$T/mac/$h/$rd/LEAKED" ]; then
    ok "integration-$mode-next-run-hold"
  else
    bad "G3 $mode next-run hold failed: rc=$rc2 rows-before=$before rows-after=$(wc -l < "$T/mac/$h/row-args") $(grep -E '^(HOST_HELD|ROW)' <<<"$out2" | tr '\n' ' ')"
  fi
  printf '%s\n' "$out2" > "$T/hold.out"
  sed '/^HOST_HELD/d' "$T/hold.out" > "$T/no-hold.out"
  ! judge_hold "$(cat "$T/no-hold.out")" "$rd" || bad "M9 dropped next-run hold survived"
}

check_refusal_and_hold "$INTEL" x86_64 bad-disposition REFUSED_DISPOSITION none
check_refusal_and_hold "$ARM" arm64 bad-identity REFUSED_IDENTITY none
check_refusal_and_hold "$INTEL" x86_64 bad-term-disposition $'REFUSED_DISPOSITION\tTERM' hup-int

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tms-signal-runtime-gate-red\n'
  exit 0
fi
printf 'FAIL\tms-signal-runtime-gate-red\t%s failure(s)\n' "$fails"
exit 1
