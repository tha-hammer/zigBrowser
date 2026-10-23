#!/usr/bin/env bash
# Hostless selftest of the MS1c gate, tests/mac/ms1c_app_gate.sh (plan R30-MS1 Red 2, bd zigBrowser-4pa.73; SilverRidge
# 94ebe76b; owner decisions 2026-10-23 on /var/folders and crash reports). The REAL gate runs, with the real
# packaging/macos/build-dmg.sh, build-on-mac.sh, mac_gate_lib.sh and mac_config.sh, in a scratch git repo against
# EXECUTING stub ssh/scp: every remote command runs for real in a fake Mac home per host. Fake Mac tools: zig (thin
# per-host slices), lipo (a real byte join), codesign, otool, sips, iconutil, hdiutil (create = a tar of the tree;
# attach = that tree at the mountpoint, with a device line; detach), ditto, file, shasum, stat (BSD -f form), getconf
# (per-user dirs under a /var -> /private/var alias), uname, sysctl, sleep, find (records every -delete and whether
# its target still holds a mount), and python3, which plays the four MS1b workload commands and the control: it
# checks that the exe it is given can load its bundled shim the way dyld would, records its argv and environment, and
# for the control writes a crash report naming the exe under the fake ~/Library/Logs/DiagnosticReports.
# Base run (both Macs fine):
#   P1 exit 0, PASS<TAB>ms1c-app-gate<TAB>both-arches<TAB><dmg sha256>, both legs PASS;
#   P2 ONE dmg: the full commit SHA is named (COMMIT line and evidence); build-dmg.sh made exactly one image, from a
#      clean tree whose tree id is that commit's; its digest at creation equals the printed DMG sha256, and each leg's
#      DMG line equals it;
#   P3 hdiutil attach -readonly -nobrowse -noautoopen -mountpoint <run root>/mnt <run root>/zigBrowser.dmg on each Mac,
#      then a detach of the attached device, before any workload command;
#   P4 codesign --verify --strict --deep on the unpacked .app; otool -L on its exe; every Mach-O census line fat;
#   P5 each of m9_render_test.py, m9_reply_channel_test.py, m9_load_fail_test.py and exec_arch_probe.py ran exactly
#      once per Mac; every one got --browser <run root>/app/zigBrowser.app/Contents/MacOS/zigBrowser, ran with no
#      zig-out left, and with HOME, CFFIXED_USER_HOME, TMPDIR, the XDG dirs and the socket dir under the run root and
#      ZB_DEBUG_EPHEMERAL_DATA_STORE=1;
#   P6 the control ran the exe of <run root>/control/zigBrowser.app while that copy had no dylib and the unpacked .app
#      still had its own; a CRASHREPORT line names the report and its sha256, and the report is still there after;
#   P7 /var/folders, through the shared helper tests/mac/mac_varfolders_audit.sh (contract 143a12f6; a stub with its
#      interface stands in until it lands): VARFOLDERS_ROOTS with both physical roots, the workload's file there as
#      a VARFOLDERS-DELTA line, VARFOLDERS COMPLETE, and nothing under those roots deleted (a sentinel file survives,
#      and no find -delete targeted them);
#   P8 the evidence came back: MANIFEST<TAB><sha256> matches manifest.sha256, which verifies;
#   P9 no run dir is left on either Mac, every CLEANUP rc=0, and no find -delete ran while an image was mounted.
# Fault runs (one Mac unless named; the other Mac stays fine):
#   F1 no arm64 host: NOT RUN, exit 1, no ssh/scp;
#   F2 a thin Mach-O nested in the image: that leg FAIL, exit 1, no PASS;
#   F3 other dmg bytes on one Mac: that leg INCONCLUSIVE, nothing attached there, exit 2;
#   F4 codesign verify fails: FAIL;   F5 no shim reference in otool -L: FAIL;
#   F6 m9_render fails: FAIL, and the later rows still ran;   F7 m9_load_fail skips (77): FAIL;
#   F8 m9_reply_channel leaks a process: HOST_STOPPED, no later row or control on that Mac, the kept LEAKED marker is
#      exactly one line with the four identity fields the workload printed (pid, pgid, start, command), its run root
#      KEPT (no cleanup attempted, never given to find -delete); exit 2; the next run on that Mac is HOST_HELD by it,
#      attaches nothing there and leaves the marker as it was;
#   F9 detach fails: INCONCLUSIVE, no workload there, the run root KEPT with its MOUNTED marker, no cleanup attempted; exit 2;
#   F10 the workload writes ~/Library/Caches/zigBrowser in the real home: HOME-DELTA, INCONCLUSIVE, the file stays;
#   F11 the control starts: FAIL;   F12 the control fails with another library's error: FAIL;
#   F13 a crash report that names another exe: HOME-DELTA, INCONCLUSIVE;
#   F14 the app reports the other arch: FAIL;
#   F15 an unreadable directory under /var/folders: the audit says INCONCLUSIVE, and so does the leg;
#   F16 a run dir of an earlier run holds a LEAKED marker: HOST_HELD, nothing attached there, the marker untouched;
#   F17 build-dmg.sh fails: FAIL, exit 1, no leg ran;
#   F18 the control prints dyld's exact load failure but exits 0: FAIL (the exit and the text are both required);
#   F19 exec_arch_probe writes the right arch but exits 77: FAIL (a skip is never a pass);
#   F20 the home snapshot is incomplete (a stat error on a file that is there before and after): INCONCLUSIVE;
#   F21 the removal of a run root fails (find -delete exits 1): CLEANUP rc != 0 for it, both legs still PASS, the root
#       is still there, the evidence came back, INCONCLUSIVE, exit 2, no PASS;
#   F22 the removal claims success but leaves the root (find -delete exits 0, deletes nothing): the absence check
#       catches it, the same verdict as F21.
# No Mac, no signal: it re-runs itself in a private user+network namespace; HOME/TMPDIR live in its temp tree.
# Run: bash tests/mac/ms1c_app_gate_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_MS1C_SELFTEST_INNER:-}" != 1 ]; then
  ZB_MS1C_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms1c-selftest-XXXXXX")
T=$(realpath "$BASE")
printf 'not a real key\n' > "$T/fake_mac_key"   # tests/mac/mac_config.sh needs a readable regular key file (bd 3ui.13)
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-ms1c-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
TB=$'\t'
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2 X="$T/x" C="$T/ctl"
APPEXE=app/zigBrowser.app/Contents/MacOS/zigBrowser

mkdir -p "$X/bin" "$X/hostbin" "$C" "$T/home" "$T/tmp" "$X/private/var/folders"
ln -s private/var "$X/var"
for role in intel arm; do
  mkdir -p "$X/hosts/$role/.local/bin" "$X/hosts/$role/Library/Logs/DiagnosticReports" "$X/hosts/$role/Library/Caches" \
    "$X/private/var/folders/$role/T" "$X/private/var/folders/$role/C"
  echo keep > "$X/private/var/folders/$role/T/sentinel"; echo keep > "$X/private/var/folders/$role/C/sentinel"
  echo old > "$X/hosts/$role/Library/Logs/DiagnosticReports/older.ips"
done
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
  elif r=\$(remote "\$dst"); then
    cp "\$src" "\$r" || exit 1
    case "\$dst" in $ARM:*.dmg) if [ -e "$C/mode_corrupt_dmg.arm" ]; then printf x >> "\$r"; fi ;; esac
  else echo "stub scp: no remote side in \$src -> \$dst" >&2; exit 99; fi
done
EOF
rec='n=$(ls "'"$C"'" | grep -c "^$(basename "$0")\.[0-9]*$" || true); printf "%s\0" "$@" > "'"$C"'/$(basename "$0").$n"'
on='on() { [ -e "'"$C"'/mode_$1" ] || [ -e "'"$C"'/mode_$1.${ZB_ROLE:-}" ]; }'
seq_='printf "%s\t%s\n" "${ZB_ROLE:-local}" "$*" >> "'"$C"'/seq"'
for role in intel arm; do
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  cat > "$X/hosts/$role/.local/bin/zig" <<EOF
#!/bin/bash
[ "\$1" = version ] && { echo 0.16.0; exit 0; }
pwd >> "$C/built.$role"
mkdir -p zig-out/bin zig-out/Frameworks
printf 'MACHO thin $arch\nzigBrowser exe built on $role\n' > zig-out/bin/zigBrowser
printf 'MACHO thin $arch\nwkwebview shim built on $role\n' > zig-out/Frameworks/libwkwebview_shim.dylib
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
    a=(); for f in "\${ins[@]}"; do a+=("\$(archs_of "\$f")") || exit 1; done
    { echo "MACHO fat \${a[*]}"; for f in "\${ins[@]}"; do echo "--slice--"; cat "\$f"; done; } > "\$out" ;;
  -archs) archs_of "\$2" ;;
  -info) echo "Architectures in the fat file: \$2 are: \$(archs_of "\$2")" ;;
esac
EOF
cat > "$X/hostbin/codesign" <<EOF
#!/bin/bash
$rec
$on
case "\${@: -1}" in */app/zigBrowser.app) for a in "\$@"; do [ "\$a" = --verify ] && on codesign_fail && { echo "a sealed resource is missing or invalid" >&2; exit 1; }; done ;; esac
exit 0
EOF
cat > "$X/hostbin/otool" <<EOF
#!/bin/bash
$rec
$on
[ "\$1" = -L ] || exit 0
ref='\t@executable_path/../Frameworks/libwkwebview_shim.dylib (compatibility version 0.0.0, current version 0.0.0)\n'
case "\$2" in */app/zigBrowser.app/*) on otool_noref && ref= ;; esac
# One write, so a reader that stops early (grep -q under pipefail) never meets a half-written pipe.
printf "%s:\n\$ref\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1345.0.0)\n" "\$2"
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
$rec
$on
$seq_
case "\$1" in
  create)
    on dmg_build_fail && { echo "hdiutil: create failed - stub" >&2; exit 1; }
    src=
    for ((i = 1; i <= \$#; i++)); do [ "\${!i}" = -srcfolder ] && { j=\$((i + 1)); src=\${!j}; }; done
    tar -C "\$src" -cf "\${@: -1}" . || exit 1
    sha256sum "\${@: -1}" | cut -d' ' -f1 >> "$C/dmg_created" ;;
  attach)
    mp= img=\${@: -1}
    for ((i = 1; i <= \$#; i++)); do [ "\${!i}" = -mountpoint ] && { j=\$((i + 1)); mp=\${!j}; }; done
    [ -d "\$mp" ] || { echo "hdiutil: attach failed - no mountpoint" >&2; exit 1; }
    tar -C "\$mp" -xf "\$img" || exit 1
    touch "\$mp/.zb-mounted"
    on inject_thin && printf 'MACHO thin x86_64\nan extra thin dylib\n' > "\$mp/zigBrowser.app/Contents/Frameworks/libextra.dylib"
    printf '%s\t%s\n' /dev/disk7 "\$mp" > "$C/mounted.\$ZB_ROLE"
    printf '/dev/disk7          \tGUID_partition_scheme          \t\n/dev/disk7s1        \tApple_HFS                      \t%s\n' "\$mp" ;;
  detach)
    on detach_fail && { echo "hdiutil: couldn't unmount \"disk7\" - Resource busy" >&2; exit 16; }
    IFS="\$(printf '\t')" read -r dev mp < "$C/mounted.\$ZB_ROLE" || exit 1
    [ "\$2" = "\$dev" ] || { echo "hdiutil: detach: no such device \$2" >&2; exit 1; }
    find "\$mp" -mindepth 1 -maxdepth 1 -exec rm -rf {} + && rm -f "$C/mounted.\$ZB_ROLE" && echo '"disk7" ejected.' ;;
esac
EOF
cat > "$X/hostbin/ditto" <<EOF
#!/bin/bash
$rec
cp -a "\$1" "\$2"
EOF
cat > "$X/hostbin/file" <<EOF
#!/bin/bash
f=\${@: -1}
case "\$(head -n 1 "\$f" 2>/dev/null)" in
  "MACHO fat "*) echo "Mach-O universal binary with 2 architectures" ;;
  "MACHO thin "*) echo "Mach-O 64-bit executable \$(head -n 1 "\$f" | cut -d' ' -f3)" ;;
  *) echo data ;;
esac
EOF
cat > "$X/hostbin/shasum" <<EOF
#!/bin/bash
[ "\$1" = -a ] && [ "\$2" = 256 ] && shift 2
exec sha256sum "\$@"
EOF
cat > "$X/hostbin/stat" <<EOF
#!/bin/bash
[ "\$1" = -f ] || exec /usr/bin/stat "\$@"
[ "\$2" = '%N|%HT|%p|%i|%z|%m' ] || { echo "stub stat: unexpected format \$2" >&2; exit 64; }
shift 2; rc=0
for f in "\$@"; do
  case "\$f" in */zb-stat-error) echo "stat: \$f: Input/output error" >&2; rc=1; continue ;; esac
  line=\$(/usr/bin/stat -c '%n|%F|%f|%i|%s|%Y' -- "\$f" 2>/dev/null) || { echo "stat: \$f: No such file or directory" >&2; rc=1; continue; }
  IFS='|' read -r n ty hex ino sz mt <<<"\$line"
  case "\$ty" in "regular file"|"regular empty file") ty="Regular File" ;; directory) ty=Directory ;; "symbolic link") ty="Symbolic Link" ;; fifo) ty="Fifo File" ;; *) ty=Unknown ;; esac
  printf '%s|%s|%o|%s|%s|%s\n' "\$n" "\$ty" "\$((16#\$hex))" "\$ino" "\$sz" "\$mt"
done
exit \$rc
EOF
cat > "$X/hostbin/getconf" <<EOF
#!/bin/bash
case "\$1" in
  DARWIN_USER_TEMP_DIR) echo "$X/var/folders/\$ZB_ROLE/T/" ;;
  DARWIN_USER_CACHE_DIR) echo "$X/var/folders/\$ZB_ROLE/C/" ;;
  *) exec /usr/bin/getconf "\$@" ;;
esac
EOF
cat > "$X/hostbin/uname" <<EOF
#!/bin/bash
[ "\$1" = -m ] || exec /usr/bin/uname "\$@"
[ "\$ZB_ROLE" = arm ] && echo arm64 || echo x86_64
EOF
cat > "$X/hostbin/sysctl" <<EOF
#!/bin/bash
[ "\$*" = "-n sysctl.proc_translated" ] && { echo 0; exit 0; }
exit 1
EOF
cat > "$X/hostbin/sleep" <<EOF
#!/bin/bash
echo sleep >> "$C/sleeps"
EOF
cat > "$X/hostbin/find" <<EOF
#!/bin/bash
$on
for a in "\$@"; do
  if [ "\$a" = -delete ]; then
    m=unmounted; [ -e "\$1/mnt/.zb-mounted" ] && m=mounted
    printf '%s\t%s\t%s\n' "\$ZB_ROLE" "\$1" "\$m" >> "$C/find_delete"
    # F21/F22: the removal of a gate run root (the one holding evidence.tar) fails, or claims success and leaves it.
    if [ -e "\$1/evidence.tar" ]; then
      if on remove_fails; then echo "find: \$1: Directory not empty" >&2; exit 1; fi
      if on remove_noop; then exit 0; fi
    fi
  fi
done
exec /usr/bin/find "\$@"
EOF
cat > "$X/hostbin/python3" <<EOF
#!/bin/bash
$on
$seq_
REAL="$X/hosts/\$ZB_ROLE"
script=\$1; shift
first=\${1:-} browser= out=
while [ \$# -gt 0 ]; do
  case "\$1" in --browser) browser=\$2; shift 2 ;; --out|--capture-path) out=\$2; shift 2 ;; *) shift ;; esac
done
zo=absent; [ -e zig-out ] && zo=present
env_line="HOME=\$HOME|CF=\${CFFIXED_USER_HOME:-}|TMPDIR=\${TMPDIR:-}|XD=\${XDG_DATA_HOME:-}|XC=\${XDG_CACHE_HOME:-}|XG=\${XDG_CONFIG_HOME:-}|XR=\${XDG_RUNTIME_DIR:-}|S=\${ZB_E2E_SOCKET_DIR:-}|E=\${ZB_DEBUG_EPHEMERAL_DATA_STORE:-}"
loads() { [ -f "\$1" ] && [ -f "\$(dirname "\$1")/../Frameworks/libwkwebview_shim.dylib" ]; }
dyld_fail() {
  echo "dyld[4242]: Library not loaded: @executable_path/../Frameworks/libwkwebview_shim.dylib" >&2
  echo "  Referenced from: <6A1B2C3D-0000-0000-0000-000000000000> \$1" >&2
  echo "  Reason: tried: '\$(dirname "\$1")/../Frameworks/libwkwebview_shim.dylib' (no such file)" >&2
}
if [ "\$script" = - ]; then   # the control
  cat > /dev/null
  exe=\$first
  app=\${exe/\/control\//\/app\/}
  c=absent; [ -e "\$(dirname "\$exe")/../Frameworks/libwkwebview_shim.dylib" ] && c=present
  a=absent; [ -e "\$(dirname "\$app")/../Frameworks/libwkwebview_shim.dylib" ] && a=present
  printf '%s\tcontrol\t%s\t%s\t%s\t%s\n' "\$ZB_ROLE" "\$exe" "\$c" "\$a" "\$env_line" >> "$C/py.log"
  if on control_starts || loads "\$exe"; then echo "zigBrowser 0.2.0"; printf 'CONTROL_RC\t0\n'; exit 0; fi
  if on control_wrongdiag; then
    echo "dyld[4242]: Library not loaded: @rpath/libother.dylib" >&2
    echo "  Referenced from: <6A1B2C3D-0000-0000-0000-000000000000> \$exe" >&2
  else
    dyld_fail "\$exe"
  fi
  proc=\$exe; on crash_other && proc=/Applications/Other.app/Contents/MacOS/Other
  printf '{"procPath":"%s","exception":"EXC_CRASH (SIGABRT)","termination":"DYLD"}\n' "\$proc" \
    > "\$REAL/Library/Logs/DiagnosticReports/zigBrowser-2026-10-23-100000.ips"
  if on control_rc0; then printf 'CONTROL_RC\t0\n'; else printf 'CONTROL_RC\t-6\n'; fi
  exit 0
fi
name=\${script##*/}
printf '%s\t%s\t%s\t%s\t%s\n' "\$ZB_ROLE" "\$name" "\$browser" "\$zo" "\$env_line" >> "$C/py.log"
loads "\$browser" || { dyld_fail "\$browser"; exit 134; }
case "\$name" in
  m9_render_test.py)
    if on var_unreadable; then mkdir -p "$X/private/var/folders/\$ZB_ROLE/T/zb-locked"; chmod 000 "$X/private/var/folders/\$ZB_ROLE/T/zb-locked"; fi
    echo render > "$X/private/var/folders/\$ZB_ROLE/T/zigBrowser-render.tmp"
    on home_write && { mkdir -p "\$REAL/Library/Caches/zigBrowser"; echo db > "\$REAL/Library/Caches/zigBrowser/cache.db"; }
    on fail_render && { printf '%b\n' "FAIL\tm9-render-title-or-nav-not-observed"; exit 1; }
    : > "\$out"; printf '%b\n' "PASS\tm9-render-webview-screenshot\t\$out\tuniformity deferred to the caller's PIL host" ;;
  m9_reply_channel_test.py)
    if on leak_reply; then   # this fake's own identity, as mac_term_teardown prints a process it left running
      printf 'LEAK\t%s\t%s\t%s\t%s about:blank\n' "\$\$" "\$\$" "\$(date '+%a %b %e %H:%M:%S %Y')" "\$browser" | tee "$C/leak_line.\$ZB_ROLE"
      printf '%b\n' "FAIL\tmac-teardown-leak\t1"; exit 1
    fi
    printf '%b\n' "PASS\tm9-reply-channel-contract" ;;
  m9_load_fail_test.py)
    on skip_loadfail && { echo "SKIP: hw gate"; exit 77; }
    printf '%b\n' "PASS\tm9-load-fail-contract" ;;
  exec_arch_probe.py)
    a=x86_64; [ "\$ZB_ROLE" = arm ] && a=arm64
    on arch_wrong && a=x86_64
    echo "\$a" > "\$out"; echo "exec_arch_probe: build.exec_arch=\$a"
    if on skip_arch; then exit 77; fi ;;
  *) echo "stub python3: unexpected script \$script" >&2; exit 98 ;;
esac
EOF
chmod +x "$X/bin"/* "$X/hostbin"/* "$X/hosts"/*/.local/bin/zig

R="$T/repo"
mkdir -p "$R/tests/mac" "$R/tests/e2e" "$R/tests/fixtures/app" "$R/packaging/macos" "$R/packaging/assets" "$R/src"
for f in tests/mac/ms1c_app_gate.sh tests/mac/build-on-mac.sh tests/mac/mac_gate_lib.sh tests/mac/mac_config.sh \
  tests/mac/known_hosts tests/mac/mac_varfolders_audit.sh tests/mac/exec_arch_probe.py tests/e2e/m9_render_test.py tests/e2e/m9_reply_channel_test.py \
  tests/e2e/m9_load_fail_test.py tests/e2e/mac_term_teardown.py tests/fixtures/app/index.html \
  packaging/macos/build-dmg.sh packaging/macos/Info.plist packaging/macos/entitlements.plist packaging/assets/zigBrowser.png; do
  [ -e "$ROOT/$f" ] && cp "$ROOT/$f" "$R/$f"
done
if [ ! -e "$R/tests/mac/mac_varfolders_audit.sh" ]; then
  # Until HazySpring's shared helper lands (contract: tests/e2e/mac_varfolders_audit_test.py, 143a12f6), a stub with
  # its interface stands in; once the real helper exists it is copied from the repo above and this is not used.
  cat > "$R/tests/mac/mac_varfolders_audit.sh" <<'STUB'
# STUB of tests/mac/mac_varfolders_audit.sh for tests/mac/ms1c_app_gate_selftest.sh only (its contract, 143a12f6).
varfolders__py() { /usr/bin/python3 -I -B - "$@" <<'PY'
import os, sys
mode, ev = sys.argv[1], sys.argv[2]
def snap(root):
    out, bad = [], []
    for d, dirs, files in os.walk(root, onerror=lambda e: bad.append(e.filename)):
        for n in sorted(dirs + files):
            q = os.path.join(d, n); st = os.lstat(q)
            out.append(f"{os.path.relpath(q, root)}|{st.st_mode:o}|{st.st_size}|{int(st.st_mtime)}")
            if os.path.isdir(q) and not os.path.islink(q) and not os.access(q, os.R_OK | os.X_OK): bad.append(q)
    return sorted(out), bad
roots = open(os.path.join(ev, "roots")).read().split()
if mode == "begin":
    for tok, r in zip("TC", roots):
        lines, bad = snap(r)
        open(os.path.join(ev, f"{tok}.before"), "w").write("\n".join(lines + [f"#BAD {b}" for b in bad]) + "\nEND\n")
    sys.exit(0)
print(f"VARFOLDERS_ROOTS\tT\t{roots[0]}\tC\t{roots[1]}")
deltas, why = [], ""
for tok, r in zip("TC", roots):
    try: before = open(os.path.join(ev, f"{tok}.before")).read().splitlines()
    except OSError: why = f"no before snapshot of {tok}"; break
    if not before or before[-1] != "END" or any(l.startswith("#BAD ") for l in before): why = f"incomplete before snapshot of {tok}"; break
    after, bad = snap(r)
    if bad: why = f"unreadable under {tok}: {bad[0]}"; break
    b = {l.split("|", 1)[0]: l.split("|", 1)[1] for l in before[:-1]}
    a = {l.split("|", 1)[0]: l.split("|", 1)[1] for l in after}
    for k in sorted(set(a) | set(b)):
        if k not in b: deltas.append(f"VARFOLDERS-DELTA\tadded\t{tok}\t{k}\t-\t{a[k]}")
        elif k not in a: deltas.append(f"VARFOLDERS-DELTA\tremoved\t{tok}\t{k}\t{b[k]}\t-")
        elif a[k] != b[k]: deltas.append(f"VARFOLDERS-DELTA\tchanged\t{tok}\t{k}\t{b[k]}\t{a[k]}")
if why: print(f"VARFOLDERS\tINCONCLUSIVE\t{why}"); sys.exit(2)
for d in sorted(deltas): print(d)
print(f"VARFOLDERS\tCOMPLETE\t{len(deltas)}")
PY
}
varfolders_begin() { # $1=evidence dir
  local t c
  t=$(getconf DARWIN_USER_TEMP_DIR) && c=$(getconf DARWIN_USER_CACHE_DIR) || return 2
  t=$(cd -P "$t" 2>/dev/null && pwd) && c=$(cd -P "$c" 2>/dev/null && pwd) || return 2
  [ "$t" != "$c" ] || return 2
  mkdir -p "$1" && printf '%s\n%s\n' "$t" "$c" > "$1/roots" && varfolders__py begin "$1"
}
varfolders_end() { # $1=evidence dir
  [ -f "$1/roots" ] || { printf 'VARFOLDERS\tINCONCLUSIVE\tno roots recorded\n'; return 2; }
  varfolders__py end "$1"
}
STUB
fi
echo "// stand-in" > "$R/src/main.zig"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
GIT=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${GIT[@]}" init -q && "${GIT[@]}" add -A \
  && "${GIT[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
TREE=$("${GIT[@]}" rev-parse 'HEAD^{tree}')
COMMITSHA=$("${GIT[@]}" rev-parse HEAD)

run_gate() { # run_gate <label> [mode files...] [-- VAR=value ...]: sets rc, OUT, EV (leaknext keeps the run dirs)
  local label=$1; shift
  rm -rf "${C:?}"/*
  : > "$C/seq"; : > "$C/py.log"; : > "$C/find_delete"; : > "$C/dmg_created"; : > "$C/calls"
  while [ $# -gt 0 ] && [ "$1" != -- ]; do touch "$C/mode_$1"; shift; done
  [ "${1:-}" = -- ] && shift
  for role in intel arm; do
    [ "$label" = leaknext ] || find "$X/hosts/$role" -mindepth 1 -maxdepth 1 -name 'zb-gate-*' -exec rm -rf {} +
    rm -rf "$X/hosts/$role/Library/Caches/zigBrowser"
    find "$X/hosts/$role/Library/Logs/DiagnosticReports" -name 'zigBrowser-*' -delete
    rm -f "$X/private/var/folders/$role/T/zigBrowser-render.tmp" "$X/hosts/$role/zb-stat-error"
    if [ -d "$X/private/var/folders/$role/T/zb-locked" ]; then chmod 700 "$X/private/var/folders/$role/T/zb-locked"; rmdir "$X/private/var/folders/$role/T/zb-locked"; fi
  done
  [ "$label" = homestat ] && echo x > "$X/hosts/intel/zb-stat-error"
  [ "$label" = held ] && { mkdir -p "$X/hosts/arm/zb-gate-old"; printf 'LEAKED\t1\t1\tx\ty\n' > "$X/hosts/arm/zb-gate-old/LEAKED"; }
  OUT="$T/out.$label"
  (cd "$R" && env -i PATH="$X/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/fake_mac_key" "$@" timeout 300 bash tests/mac/ms1c_app_gate.sh >"$OUT" 2>&1 </dev/null)
  rc=$?
  EV=$(sed -n "s/^EVIDENCE$TB//p" "$OUT" | head -n 1)
}
rd_of() { # rd_of <role>: the gate's run root on that Mac (from its attach call)
  local f
  for f in $(ls "$C" 2>/dev/null | grep -E '^hdiutil\.[0-9]+$'); do
    tr '\0' '\n' < "$C/$f" | grep -qx attach || continue
    tr '\0' '\n' < "$C/$f" | awk -v p="$X/hosts/$1/" 'prev == "-mountpoint" && index($0, p) == 1 { sub(/\/mnt$/, ""); print } { prev = $0 }'
  done | head -n 1
}
leg_is() { grep -qE "^LEG$TB$1$TB$2($TB|$)" "$OUT"; }
no_pass() { ! grep -q "^PASS${TB}ms1c-app-gate" "$OUT"; }
pyrows() { awk -F'\t' -v r="$1" '$1 == r { print $2 }' "$C/py.log" 2>/dev/null | tr '\n' ' '; }
tailout() { tail -n 3 "$OUT" | tr '\n' ' '; }

# ── Base run ──
run_gate pass
DSHA=$(sed -n "s/^DMG$TB\([0-9a-f]*\)$TB.*/\1/p" "$OUT" | head -n 1)
if [ "$rc" -eq 0 ] && grep -qxF "PASS${TB}ms1c-app-gate${TB}both-arches${TB}$DSHA" "$OUT" && [ -n "$DSHA" ] \
   && leg_is x86_64 PASS && leg_is arm64 PASS; then ok "P1: exit 0, PASS with the dmg sha256, both legs PASS"
else bad "P1: exit $rc: $(tailout)"; fi
ct=$(sed -n "s/^CLEANTREE$TB//p" "$OUT" | head -n 1)
legsha=$(for a in x86_64 arm64; do sed -n "s/^DMG$TB//p" "$EV/$a/evidence/leg.log" 2>/dev/null; done | tr '\n' ' ')
made=$(cat "$C/dmg_created" 2>/dev/null)
if [ "$(sed -n "s/^COMMIT$TB//p" "$OUT")" = "$COMMITSHA" ] && [ "$(cat "$EV/commit" 2>/dev/null)" = "COMMIT$TB$COMMITSHA" ] \
   && [ "$(cut -f2,3 <<<"$ct")" = "$TREE$TB$TREE" ] && [ "$made" = "$DSHA" ] && [ "$legsha" = "$DSHA $DSHA " ]; then
  ok "P2: commit $COMMITSHA (tree $TREE) named in full; one dmg built from that tree; both legs saw its digest"
else bad "P2: COMMIT '$(sed -n "s/^COMMIT$TB//p" "$OUT")' (want $COMMITSHA), clean tree '$ct' (want $TREE), images made '$made', leg digests '$legsha', printed '$DSHA'"; fi
p3=ok
for role in intel arm; do
  rd=$(rd_of $role)
  att=$(awk -F'\t' -v r=$role '$1 == r && $2 ~ /^attach /' "$C/seq" | head -n 1 | cut -f2)
  want="attach -readonly -nobrowse -noautoopen -mountpoint $rd/mnt $rd/zigBrowser.dmg"
  order=$(awk -F'\t' -v r=$role '$1 == r { split($2, w, " "); print w[1] }' "$C/seq" | grep -v '^create$' | uniq | tr '\n' ' ')
  case "$order" in "attach detach "*) ;; *) p3="$role order '$order'" ;; esac
  [ -n "$rd" ] && [ "$att" = "$want" ] || p3="$role attach '$att'"
  awk -F'\t' -v r=$role '$1 == r && $2 == "detach /dev/disk7"' "$C/seq" | grep -q . || p3="$role: no detach of /dev/disk7"
done
[ "$p3" = ok ] && ok "P3: attach -readonly -nobrowse -noautoopen at <run root>/mnt, then detach of its device, before any workload" \
  || bad "P3: $p3"
p4=ok
for role in intel arm; do
  rd=$(rd_of $role)
  cs=$(for f in $(ls "$C" | grep -E '^codesign\.[0-9]+$'); do tr '\0' ' ' < "$C/$f"; echo; done)
  grep -qxF -- "--verify --strict --deep --verbose=2 $rd/app/zigBrowser.app " <<<"$cs" || p4="$role codesign calls: $(grep -- --verify <<<"$cs" | tr '\n' '|')"
  ot=$(for f in $(ls "$C" | grep -E '^otool\.[0-9]+$'); do tr '\0' ' ' < "$C/$f"; echo; done)
  grep -qxF -- "-L $rd/$APPEXE " <<<"$ot" || p4="$role otool calls: $(tr '\n' '|' <<<"$ot")"
done
cen=$(cat "$EV"/*/evidence/census 2>/dev/null)
{ [ "$(grep -c "^MACHO$TB" <<<"$cen")" -ge 4 ] && ! grep "^MACHO$TB" <<<"$cen" | grep -qv "${TB}arm64 x86_64\$"; } || p4="census '$(tr '\n' '|' <<<"$cen")'"
[ "$p4" = ok ] && ok "P4: codesign --verify --strict --deep on the unpacked .app, otool -L on its exe, every Mach-O fat" || bad "P4: $p4"
p5=ok
for role in intel arm; do
  rd=$(rd_of $role)
  rows=$(awk -F'\t' -v r=$role '$1 == r && $2 != "control"' "$C/py.log" 2>/dev/null)
  names=$(cut -f2 <<<"$rows" | LC_ALL=C sort | tr '\n' ' ')
  [ "$names" = "exec_arch_probe.py m9_load_fail_test.py m9_render_test.py m9_reply_channel_test.py " ] \
    || { p5="$role ran '$names', not each of the four exactly once"; continue; }
  wantenv="HOME=$rd/run-env/home|CF=$rd/run-env/home|TMPDIR=$rd/run-env/tmp/|XD=$rd/run-env/xdg-data|XC=$rd/run-env/xdg-cache|XG=$rd/run-env/xdg-config|XR=$rd/run-env/xdg-runtime|S=$rd/s|E=1"
  while IFS=$'\t' read -r _ name br zo envl; do
    [ "$br" = "$rd/$APPEXE" ] && [ "$zo" = absent ] && [ "$envl" = "$wantenv" ] || p5="$role $name: browser '$br' zig-out $zo env '$envl'"
  done <<<"$rows"
done
[ "$p5" = ok ] && ok "P5: each of the four workload scripts exactly once per Mac, on the unpacked exe, no zig-out, private env under the run root, ephemeral store" || bad "P5: $p5"
p6=ok
for role in intel arm; do
  rd=$(rd_of $role)
  ctl=$(awk -F'\t' -v r=$role '$1 == r && $2 == "control"' "$C/py.log" 2>/dev/null)
  [ "$(cut -f3-5 <<<"$ctl")" = "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser${TB}absent${TB}present" ] || p6="$role control '$ctl'"
  arch=x86_64; [ $role = arm ] && arch=arm64
  ips="$X/hosts/$role/Library/Logs/DiagnosticReports/zigBrowser-2026-10-23-100000.ips"
  want="CRASHREPORT${TB}zigBrowser-2026-10-23-100000.ips${TB}$(sha256sum "$ips" 2>/dev/null | awk '{ print $1 }')"
  [ -f "$ips" ] && grep -qxF "$want" "$EV/$arch/evidence/leg.log" 2>/dev/null || p6="$role: no '$want' (report $( [ -f "$ips" ] && echo kept || echo gone))"
done
[ "$p6" = ok ] && ok "P6: the control ran a private copy without its dylib; CRASHREPORT name and sha256; the report is kept" || bad "P6: $p6"
p7=ok
for role in intel arm; do
  arch=x86_64; [ $role = arm ] && arch=arm64
  L="$EV/$arch/evidence/leg.log"
  grep -qxF "VARFOLDERS_ROOTS${TB}T${TB}$X/private/var/folders/$role/T${TB}C${TB}$X/private/var/folders/$role/C" "$L" 2>/dev/null \
    || p7="$role: no VARFOLDERS_ROOTS line with both physical roots"
  grep -qE "^VARFOLDERS-DELTA${TB}added${TB}T${TB}zigBrowser-render.tmp${TB}" "$L" 2>/dev/null || p7="$role: the workload's /var/folders file is not reported"
  grep -qE "^VARFOLDERS${TB}COMPLETE${TB}[1-9][0-9]*\$" "$L" 2>/dev/null || p7="$role: no VARFOLDERS COMPLETE line"
  [ -f "$X/private/var/folders/$role/T/sentinel" ] && [ -f "$X/private/var/folders/$role/C/sentinel" ] || p7="$role: a sentinel was deleted"
done
grep -q "$X/private/var\|$X/var" "$C/find_delete" 2>/dev/null && p7="a find -delete targeted /var/folders: $(grep var "$C/find_delete")"
[ "$p7" = ok ] && ok "P7: the shared /var/folders audit ran: both physical roots, the change reported, COMPLETE, nothing deleted there" || bad "P7: $p7"
mf=$(sed -n "s/^MANIFEST$TB//p" "$OUT")
if [ -n "$EV" ] && [ -n "$mf" ] && [ "$mf" = "$(sha256sum "$EV/manifest.sha256" 2>/dev/null | awk '{ print $1 }')" ] \
   && (cd "$EV" && sha256sum -c --quiet manifest.sha256 >/dev/null 2>&1) && [ -f "$EV/x86_64/evidence/leg.log" ] && [ -f "$EV/arm64/evidence/leg.log" ]; then
  ok "P8: the evidence of both legs came back and its manifest verifies"
else bad "P8: evidence '$EV', MANIFEST '$mf'"; fi
left=$(find "$X/hosts" -maxdepth 2 -name 'zb-gate-*' 2>/dev/null)
if [ -z "$left" ] && [ "$(grep -c "^CLEANUP$TB.*${TB}rc=0\$" "$OUT")" -eq 2 ] && ! grep -q "${TB}mounted\$" "$C/find_delete" 2>/dev/null; then
  ok "P9: both run roots removed (CLEANUP rc=0), no removal while mounted"
else bad "P9: left '$left', cleanup lines '$(grep "^CLEANUP" "$OUT" | tr '\n' '|')'"; fi

# ── Fault runs ──
run_gate noarm -- ZB_MAC_ARM_HOST=
{ [ "$rc" -eq 1 ] && grep -q 'NOT RUN: arm64 host not configured' "$OUT" && [ ! -s "$C/calls" ]; } \
  && ok "F1: no arm64 host: NOT RUN, exit 1, no ssh/scp" || bad "F1: exit $rc, $(wc -l < "$C/calls" 2>/dev/null || echo 0) calls: $(tailout)"

run_gate thin inject_thin.arm
{ [ "$rc" -eq 1 ] && leg_is arm64 FAIL && leg_is x86_64 PASS && no_pass \
  && grep -qxF "MACHO${TB}Contents/Frameworks/libextra.dylib${TB}x86_64" "$EV/arm64/evidence/census" 2>/dev/null; } \
  && ok "F2: a thin nested Mach-O: that leg FAIL, exit 1, no PASS" || bad "F2: exit $rc: $(tailout)"

run_gate corrupt corrupt_dmg.arm
{ [ "$rc" -eq 2 ] && leg_is arm64 INCONCLUSIVE && no_pass && ! grep -q "^arm${TB}attach" "$C/seq"; } \
  && ok "F3: other dmg bytes on one Mac: INCONCLUSIVE, nothing attached there, exit 2" || bad "F3: exit $rc: $(tailout)"

run_gate codesign codesign_fail.intel
{ [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass; } && ok "F4: codesign verify fails: FAIL" || bad "F4: exit $rc: $(tailout)"
run_gate otool otool_noref.intel
{ [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass; } && ok "F5: no shim reference: FAIL" || bad "F5: exit $rc: $(tailout)"

run_gate render fail_render.intel
{ [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass \
  && [ "$(pyrows intel)" = "m9_render_test.py m9_reply_channel_test.py m9_load_fail_test.py exec_arch_probe.py control " ]; } \
  && ok "F6: m9_render fails: FAIL, the later rows still ran" || bad "F6: exit $rc, intel rows '$(pyrows intel)': $(tailout)"
run_gate skip skip_loadfail.arm
{ [ "$rc" -eq 1 ] && leg_is arm64 FAIL && no_pass; } && ok "F7: a skip (77) is FAIL" || bad "F7: exit $rc: $(tailout)"

run_gate leak leak_reply.intel
rd=$(rd_of intel)
seen=$(cat "$C/leak_line.intel" 2>/dev/null)   # the identity the workload actually printed
want="LEAKED${TB}$(cut -f2- <<<"$seen")"
f8=ok
[ "$(grep -c "^LEAK$TB" <<<"$seen")" -eq 1 ] && [ "$(cut -f2 <<<"$seen")" -gt 1 ] 2>/dev/null || f8="the workload printed no single LEAK identity: '$seen'"
[ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && leg_is arm64 PASS && no_pass && grep -q "HOST_STOPPED" "$OUT" || f8="exit $rc: $(tailout)"
[ "$(pyrows intel)" = "m9_render_test.py m9_reply_channel_test.py " ] || f8="intel rows '$(pyrows intel)'"
[ -n "$rd" ] && [ -d "$rd" ] || f8="the run root '$rd' was not kept"
[ "$(cat "$rd/LEAKED" 2>/dev/null)" = "$want" ] || f8="LEAKED holds '$(cat "$rd/LEAKED" 2>/dev/null)', not exactly '$want'"
! grep -qF "$rd" "$C/find_delete" 2>/dev/null && ! grep "^CLEANUP" "$OUT" | grep -qF "${rd##*/}" || f8="a cleanup reached the kept run root"
run_gate leaknext   # the next run on that Mac: held by the kept marker, nothing attached, the marker untouched
{ [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && leg_is arm64 PASS && grep -q "HOST_HELD${TB}$rd/LEAKED" "$OUT" \
  && ! grep -q "^intel${TB}attach" "$C/seq" && [ "$(cat "$rd/LEAKED" 2>/dev/null)" = "$want" ]; } || f8="the next run was not held: exit $rc: $(tailout)"
[ "$f8" = ok ] && ok "F8: a leak stops that Mac: no later row or control, exactly the printed identity in the kept LEAKED, no cleanup, the next run HOST_HELD" \
  || bad "F8: $f8"

run_gate detach detach_fail.arm
rd=$(rd_of arm)
if [ "$rc" -eq 2 ] && leg_is arm64 INCONCLUSIVE && no_pass && [ -z "$(pyrows arm)" ] && [ -n "$rd" ] && [ -f "$rd/MOUNTED" ] \
   && ! grep -qF "$rd" "$C/find_delete" 2>/dev/null && ! grep "^CLEANUP" "$OUT" | grep -qF "${rd##*/}"; then
  ok "F9: a failed detach: INCONCLUSIVE, no workload, the run root KEPT with MOUNTED, exit 2"
else bad "F9: exit $rc, arm rows '$(pyrows arm)', root '$rd': $(tailout)"; fi

run_gate homewrite home_write.intel
{ [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass && [ -f "$X/hosts/intel/Library/Caches/zigBrowser/cache.db" ] \
  && grep -q "^HOME-DELTA${TB}ADDED${TB}$X/hosts/intel/Library/Caches/zigBrowser/cache.db${TB}" "$EV/x86_64/evidence/leg.log" 2>/dev/null; } \
  && ok "F10: a write in the real home: HOME-DELTA, INCONCLUSIVE, the file stays" || bad "F10: exit $rc: $(tailout)"

run_gate ctlstarts control_starts.arm
{ [ "$rc" -eq 1 ] && leg_is arm64 FAIL && no_pass; } && ok "F11: a control that starts: FAIL" || bad "F11: exit $rc: $(tailout)"
run_gate wrongdiag control_wrongdiag.arm
{ [ "$rc" -eq 1 ] && leg_is arm64 FAIL && no_pass; } && ok "F12: a control with another library's error: FAIL" || bad "F12: exit $rc: $(tailout)"
run_gate crashother crash_other.intel
{ [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass \
  && grep -q "^HOME-DELTA${TB}ADDED${TB}$X/hosts/intel/Library/Logs/DiagnosticReports/zigBrowser-2026-10-23-100000.ips" "$EV/x86_64/evidence/leg.log" 2>/dev/null; } \
  && ok "F13: a crash report of another exe: HOME-DELTA, INCONCLUSIVE" || bad "F13: exit $rc: $(tailout)"
run_gate arch arch_wrong.arm
{ [ "$rc" -eq 1 ] && leg_is arm64 FAIL && no_pass; } && ok "F14: the other arch reported: FAIL" || bad "F14: exit $rc: $(tailout)"
run_gate varlocked var_unreadable.intel
{ [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass && grep -q "^VARFOLDERS${TB}INCONCLUSIVE${TB}" "$EV/x86_64/evidence/leg.log" 2>/dev/null; } \
  && ok "F15: an unreadable directory under /var/folders: the audit is INCONCLUSIVE, so is the leg" || bad "F15: exit $rc: $(tailout)"
run_gate homestat
{ [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && leg_is arm64 PASS && no_pass; } \
  && ok "F20: an incomplete home snapshot (a stat error): INCONCLUSIVE" || bad "F20: exit $rc: $(tailout)"
run_gate held
{ [ "$rc" -eq 2 ] && leg_is arm64 INCONCLUSIVE && no_pass && grep -q "HOST_HELD" "$OUT" && ! grep -q "^arm${TB}attach" "$C/seq" \
  && [ "$(cat "$X/hosts/arm/zb-gate-old/LEAKED" 2>/dev/null)" = "LEAKED${TB}1${TB}1${TB}x${TB}y" ]; } \
  && ok "F16: a held Mac: HOST_HELD, nothing attached, the old marker untouched" || bad "F16: exit $rc: $(tailout)"
rm -rf "$X/hosts/arm/zb-gate-old"
run_gate dmgfail dmg_build_fail
{ [ "$rc" -eq 1 ] && no_pass && ! grep -q "${TB}attach" "$C/seq" && [ ! -s "$C/py.log" ]; } \
  && ok "F17: build-dmg.sh fails: FAIL, exit 1, no leg ran" || bad "F17: exit $rc: $(tailout)"

run_gate ctlrc0 control_rc0.arm
{ [ "$rc" -eq 1 ] && leg_is arm64 FAIL && no_pass; } && ok "F18: a control with dyld's exact text that exits 0: FAIL" || bad "F18: exit $rc: $(tailout)"
run_gate skiparch skip_arch.intel
{ [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass; } && ok "F19: exec_arch_probe exits 77 with the right arch written: FAIL" || bad "F19: exit $rc: $(tailout)"

for mode in remove_fails remove_noop; do
  row=F21; [ "$mode" = remove_noop ] && row=F22
  run_gate "$mode" "$mode.arm"
  rd=$(rd_of arm)
  if [ "$rc" -eq 2 ] && leg_is x86_64 PASS && leg_is arm64 PASS && no_pass && grep -q "^INCONCLUSIVE${TB}ms1c-app-gate\$" "$OUT" \
     && grep -qE "^CLEANUP${TB}$ARM${TB}${rd##*/}${TB}rc=[1-9][0-9]*\$" "$OUT" && [ -n "$rd" ] && [ -d "$rd" ] \
     && [ -f "$EV/arm64/evidence/leg.log" ] && grep -qE "^CLEANUP${TB}$INTEL${TB}zb-gate-[^${TB}]*${TB}rc=0\$" "$OUT"; then
    ok "$row: a run root that is not removed ($mode) is a CLEANUP failure: INCONCLUSIVE, exit 2, evidence kept"
  else bad "$row: exit $rc, root '$rd' $( [ -d "$rd" ] && echo kept || echo gone): $(grep '^CLEANUP' "$OUT" | tr '\n' '|') $(tailout)"; fi
done

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-ms1c-app-gate-selftest\n'; exit 0; fi
printf 'FAIL\tmac-ms1c-app-gate-selftest\t%s failure(s)\n' "$fails"
exit 1
