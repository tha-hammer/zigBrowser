#!/usr/bin/env bash
# Hostless safety selftest of the R4 compile-only Mac harness, tests/mac/mac_compile_only.sh (RoseCat a8a8a37 item 5).
# No Mac, no network, no signal: a fake `ssh` runs each leg's script on this host as a fake /Users/<name> home, and
# the Mac tools the leg names by absolute path (sandbox-exec, xcrun, xcode-select, lipo, shasum, sysctl, uname, ps,
# the developer directory, the system keychain) are replaced by stubs in a COPY of the harness: exactly those paths,
# each required to occur, plus OWN_S (30 -> 2 s); every other byte is the harness's. The stub sandbox-exec runs
# commands as asked, except the leg's canaries: it refuses each forbidden route unless a case permits it, and the
# confined-write probe unless a case breaks it.
# Each case causally drives one failure mode and requires the launcher's exit status and its reason:
#   entry as a file, a wrong digest, a symlink in the commit, no mac-compile-only step (all before any ssh); an
#   honest run (exit 0, both legs PASS, every canary refused, nothing left); a tar changed in transit; a wrong
#   arch; Rosetta; PASS followed by a nonzero ssh exit; each forbidden route permitted (exec outside the
#   toolchain, exec of a product in the prefix or the cache, TCP, a real-home write, a credential read, a keychain
#   read, a signal); a dead sandbox; a stale run root; a held ownership pipe; an escaped toolchain process; an
#   escaped process carrying the run marker; a file left in $HOME; an undeletable root; a failing build.
# Stub processes that outlive a leg (the escape cases) end on their own; the selftest waits for them (it never
# signals) and deletes its own temporary tree.
# Run: bash tests/mac/mac_compile_only_selftest.sh [harness path]   (registered: zig build test-mac-compile-only)
set -uo pipefail
HARNESS=$(realpath "${1:-tests/mac/mac_compile_only.sh}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-mco-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-mco-selftest-??????)
    chmod -R u+w "${T:?}" 2>/dev/null
    rm -rf "${T:?}" ;;
  esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }

S="$T/stub"
mkdir -p "$S" "$T/bin" "$T/ctl" "$T/dev/CommandLineTools/usr/bin" "$T/sys"
echo keychain > "$T/sys/System.keychain"

# --- the harness copy, with exactly the Mac tool paths replaced ---------------------------------------------------
cp "$HARNESS" "$T/h.sh"
subst() { # subst <exact text> <replacement>: it must occur
  local n
  n=$(grep -cF -- "$1" "$T/h.sh")
  if [ "$n" -lt 1 ]; then bad "the harness names $1"; return; fi
  FROM="$1" TO="$2" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$T/h.sh"
}
subst /usr/bin/sandbox-exec "$S/sandbox-exec"
subst /usr/bin/xcode-select "$S/xcode-select"
subst /usr/bin/xcrun "$S/xcrun"
subst /usr/bin/lipo "$S/lipo"
subst /usr/bin/shasum "$S/shasum"
subst /usr/sbin/sysctl "$S/sysctl"
subst /usr/bin/uname "$S/uname"
subst /bin/ps "$S/ps"
subst /Library/Developer/CommandLineTools "$T/dev/CommandLineTools"
subst /Library/Keychains/System.keychain "$T/sys/System.keychain"
subst '^/Users/' "^$T/Users/"
subst 'OWN_S=30' 'OWN_S=2'
DIGEST=$(sha256sum < "$T/h.sh" | cut -c1-64)

# --- stubs ---------------------------------------------------------------------------------------------------------
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
cmd="\${@: -1}" host=
for a in "\$@"; do case "\$a" in *@*) host=\${a%%@*} ;; esac; done
echo "\$host" >> "$T/ctl/ssh.calls"
mode=\$(cat "$T/ctl/ssh" 2>/dev/null)
run() { cd "$T/Users/\$host" && env -i HOME="$T/Users/\$host" PATH=/usr/bin:/bin SELFTEST_HOST="\$host" bash -c "\$cmd"; }
case "\$mode" in
  tamper) { head -c -1; printf X; } | run ;;
  exit255) run; exit 255 ;;
  *) run ;;
esac
EOF
cat > "$S/sandbox-exec" <<EOF
#!/bin/bash
shift 2
if [ "\$1" = /bin/bash ] && [ "\$2" = -c ]; then
  route=
  case "\$3" in
    *tmp/live*) [ -e "$T/ctl/broken" ] && exit 1; exec "\$@" ;;
    /usr/bin/true) route=exec-outside ;;
    *out/bin/zigBrowser*) route=exec-prefix ;;
    *zc/o/00ff*) route=exec-cache ;;
    *dev/tcp*) route=tcp ;;
    *zb-compile-canary*) route=write-home ;;
    *ZB_CRED*) route=cred ;;
    *System.keychain*) route=keychain ;;
    *"kill -0"*) route=signal ;;
  esac
  if [ -n "\$route" ]; then grep -qx "\$route" "$T/ctl/permit" 2>/dev/null && exit 0; exit 1; fi
fi
exec "\$@"
EOF
cat > "$S/xcrun" <<'EOF'
#!/bin/bash
[ "$1" = --show-sdk-version ] && { echo 26.0; exit 0; }
out=
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
[ -n "$out" ] && echo object > "$out"
exit 0
EOF
cat > "$S/xcode-select" <<EOF
#!/bin/bash
echo "$T/dev/CommandLineTools"
EOF
cat > "$S/lipo" <<EOF
#!/bin/bash
cat "$T/ctl/lipo" 2>/dev/null || { [ "\$SELFTEST_HOST" = arm ] && echo arm64 || echo x86_64; }
EOF
cat > "$S/shasum" <<'EOF'
#!/bin/bash
shift 2
exec sha256sum "$@"
EOF
cat > "$S/sysctl" <<EOF
#!/bin/bash
cat "$T/ctl/rosetta" 2>/dev/null || echo 0
EOF
cat > "$S/uname" <<EOF
#!/bin/bash
cat "$T/ctl/arch.\$SELFTEST_HOST" 2>/dev/null || { [ "\$SELFTEST_HOST" = arm ] && echo arm64 || echo x86_64; }
EOF
# ps -U <uid> -o pid=  |  ps -E -U <uid> -o pid=,command=   (this user's processes; the image path and environment)
cat > "$S/ps" <<'EOF'
#!/bin/bash
fmt=
while [ $# -gt 0 ]; do [ "$1" = -o ] && { fmt=$2; shift; }; shift; done
for d in /proc/[0-9]*; do
  [ -O "$d" ] || continue
  p=${d#/proc/}
  if [ "$fmt" = pid= ]; then echo "$p"; continue; fi
  exe=$(readlink "$d/exe" 2>/dev/null) || continue
  printf '%s %s %s\n' "$p" "$exe" "$(tr '\0' ' ' < "$d/environ" 2>/dev/null)"
done
EOF
chmod +x "$T/bin/ssh" "$S"/*

# The fake Mac homes: /Users/intel and /Users/arm, each with its zig (a stub build) and a credential file.
for u in intel arm; do
  H="$T/Users/$u"
  mkdir -p "$H/.local/zig-0" "$H/.local/bin" "$H/.ssh"
  echo key > "$H/.ssh/known_hosts"
  cat > "$H/.local/zig-0/zig" <<EOF
#!/bin/bash
[ "\$1" = version ] && { echo 0.16.0; exit 0; }
printf '%s\0' "\$@" > "$T/ctl/zig.argv.$u"   # the argv the build really receives (bd 3ui.5)
mode=\$(cat "$T/ctl/zig" 2>/dev/null)
p= c=
while [ \$# -gt 0 ]; do case "\$1" in --prefix) p=\$2 ;; --cache-dir) c=\$2 ;; esac; shift; done
mkdir -p "\$p/bin" "\$c/o/abc123"
echo exe > "\$p/bin/zigBrowser"
xcrun clang -dynamiclib -fobjc-arc -I src src/wkwebview_shim.m -o "\$c/o/abc123/libwkwebview_shim.dylib"
case "\$mode" in
  fail) exit 1 ;;
  held) sleep 5 & echo \$! >> "$T/ctl/pids" ;;
  escape) cp /usr/bin/sleep "$H/.local/zig-0/zig-helper"
          env -u ZB_COMPILE_RUN "$H/.local/zig-0/zig-helper" 5 9>&- > /dev/null 2>&1 &
          echo \$! >> "$T/ctl/pids" ;;
  marker) /usr/bin/sleep 5 9>&- > /dev/null 2>&1 &
          echo \$! >> "$T/ctl/pids" ;;
  leak) echo leak > "$H/leak" ;;
  undeletable) mkdir -p "\$c/locked" && echo x > "\$c/locked/f" && chmod 500 "\$c/locked" ;;
esac
exit 0
EOF
  chmod +x "$H/.local/zig-0/zig"
  ln -s ../zig-0/zig "$H/.local/bin/zig"
done

# A fixture commit: the shipped paths, a .url only in a comment, the step; a second commit adds a symlink, and a
# third has no mac-compile-only step.
R="$T/repo"
mkdir -p "$R/src" "$R/tests" "$R/packaging" "$R/tools"
printf 'int main(void) { return 0; }\n' > "$R/src/wkwebview_shim.m"
printf 'int drawer;\n' > "$R/src/agent_drawer_mac.m"
printf 'const s = b.step("mac-compile-only", "x");\n' > "$R/build.zig"
printf '.{\n    // .url = "https://example.com/x.tar.gz",\n    .dependencies = .{},\n}\n' > "$R/build.zig.zon"
echo '{}' > "$R/zigbrowser.json"
echo t > "$R/tests/t"; echo p > "$R/packaging/p"; echo o > "$R/tools/o"
git -C "$R" init -q
git -C "$R" -c user.email=t@t -c user.name=t add -A
git -C "$R" -c user.email=t@t -c user.name=t commit -qm honest
HONEST=$(git -C "$R" rev-parse HEAD)
ln -s ../build.zig "$R/src/link"
git -C "$R" -c user.email=t@t -c user.name=t add -A
git -C "$R" -c user.email=t@t -c user.name=t commit -qm symlink
SYMLINK=$(git -C "$R" rev-parse HEAD)
git -C "$R" rm -q src/link
printf '// no step\n' > "$R/build.zig"
git -C "$R" -c user.email=t@t -c user.name=t commit -qam nostep
NOSTEP=$(git -C "$R" rev-parse HEAD)

# --- the cases ---------------------------------------------------------------------------------------------------
OUT="$T/out.log"
reset() {
  for f in ssh ssh.calls permit broken rosetta zig lipo arch.intel arch.arm; do rm -f "$T/ctl/$f"; done
}
launch() { # launch <rev> [digest]: runs the harness copy as the committed bytes; status in $code
  (cd "$R" && PATH="$T/bin:$PATH" ZB_MAC_HOST=intel@h1 ZB_MAC_ARM_HOST=arm@h2 ZB_MAC_KEY=/dev/null \
     ZB_COMPILE_HARNESS_SHA256="${2:-$DIGEST}" bash -c "$(cat "$T/h.sh")" mac-compile-only "$1") > "$OUT" 2>&1
  code=$?
}
waitpids() { # the stub's escaped processes end on their own (never signalled)
  local p i
  [ -f "$T/ctl/pids" ] || return 0
  for p in $(cat "$T/ctl/pids"); do
    for i in $(seq 1 40); do [ -d "/proc/$p" ] || break; sleep 0.25; done
    [ -d "/proc/$p" ] && bad "stub process $p outlived its 5 s"
  done
  rm -f "$T/ctl/pids"
}
clean_homes() { # after a case: no run root may remain, except where the case leaves one by design
  local u left
  for u in intel arm; do
    left=$(ls -d "$T/Users/$u"/zb-compile-* 2>/dev/null)
    if [ -n "$left" ] && [ "${1:-}" != keep ]; then bad "$case_name: a run root was left: $left"; fi
    for d in $left; do chmod -R u+w "$d"; case "$d" in "$T"/Users/*/zb-compile-*) rm -rf "${d:?}" ;; esac; done
    rm -f "$T/Users/$u/leak" "$T/Users/$u/.zb-compile-canary" "$T/Users/$u/.local/zig-0/zig-helper"
  done
}
expect() { # expect <name> <want status: 0|fail> <must contain...>
  local name="$1" want="$2" s
  shift 2
  case_name=$name
  if [ "$want" = 0 ] && [ "$code" -ne 0 ]; then bad "$name: exit $code, want 0"; tail -20 "$OUT"; return; fi
  if [ "$want" != 0 ] && [ "$code" -eq 0 ]; then bad "$name: exit 0, want a failure"; tail -20 "$OUT"; return; fi
  for s in "$@"; do
    grep -qF -- "$s" "$OUT" || { bad "$name: no \"$s\""; tail -20 "$OUT"; return; }
  done
  ok "$name"
}
no_contact() { [ ! -s "$T/ctl/ssh.calls" ] || bad "$case_name: contacted a host"; }

reset
(cd "$R" && bash "$T/h.sh" "$HONEST") > "$OUT" 2>&1; code=$?
expect "run as a file, it refuses" fail "run the committed bytes"; no_contact
reset; launch "$HONEST" 0000
expect "a wrong digest refuses" fail "is not the approved ZB_COMPILE_HARNESS_SHA256"; no_contact
reset; launch "$SYMLINK"
expect "a symlink in the commit refuses" fail "symlink or special entry"; no_contact
reset; launch "$NOSTEP"
expect "no mac-compile-only step refuses" fail "has no mac-compile-only step"; no_contact

reset; rm -f "$T/ctl"/zig.argv.*; launch "$HONEST"
expect "an honest run passes both legs" 0 "PASS	mac-compile	x86_64	$HONEST" "PASS	mac-compile	arm64	$HONEST" \
  "PASS	mac-compile-only	both-arches	$HONEST" "ok   the sandbox runs a confined write below the root" \
  "ok   the sandbox refuses a read of the system keychain" "argv clang -dynamiclib" "ok   the run root is deleted"
[ "$(grep -c '^ok   the sandbox refuses' "$OUT")" = 16 ] || bad "honest: want 8 refused canaries per leg"
# bd 3ui.5: both zig caches stay inside the leg's run root (never the real ~/.cache/zig), judged on the argv zig got.
for u in intel arm; do
  zc= zg=
  if [ -s "$T/ctl/zig.argv.$u" ]; then
    mapfile -d '' za < "$T/ctl/zig.argv.$u"
    for ((k = 0; k < ${#za[@]}; k++)); do
      case "${za[k]}" in --cache-dir) zc=${za[k+1]:-} ;; --global-cache-dir) zg=${za[k+1]:-} ;;
        --cache-dir=*) zc=${za[k]#*=} ;; --global-cache-dir=*) zg=${za[k]#*=} ;; esac
    done
  fi
  zroot=$(grep -oE "$T/Users/$u/zb-compile-[^/ ]+" <<<"$zc $zg" | sort -u)
  if [ "$(grep -c . <<<"$zroot")" -eq 1 ] && [[ "$zc" == "$zroot"/?* ]] && [[ "$zg" == "$zroot"/?* ]]; then
    ok "honest: the $u build keeps --cache-dir and --global-cache-dir in its run root"
  else
    bad "honest: the $u build's zig argv does not keep both caches in its run root (cache='$zc' global='$zg')"
  fi
done
clean_homes

reset; echo tamper > "$T/ctl/ssh"; launch "$HONEST"
expect "a tar changed in transit fails before the build" fail "FAIL src.tar sha256"
grep -q 'zig build mac-compile-only' "$OUT" && bad "tamper: the build ran"
clean_homes
reset; echo x86_64 > "$T/ctl/arch.arm"; launch "$HONEST"
expect "a wrong arch fails" fail "FAIL native arch is x86_64, expected arm64"; clean_homes
reset; echo 1 > "$T/ctl/rosetta"; launch "$HONEST"
expect "Rosetta fails" fail "FAIL not translated by Rosetta"; clean_homes
reset; echo exit255 > "$T/ctl/ssh"; launch "$HONEST"
expect "PASS then a nonzero ssh exit fails" fail "PASS	mac-compile	x86_64	$HONEST" "pipeline status 255"
grep -q 'PASS	mac-compile-only' "$OUT" && bad "exit255: aggregate PASS"
clean_homes

for route in exec-outside exec-prefix exec-cache tcp write-home cred keychain signal; do
  reset; echo "$route" > "$T/ctl/permit"; launch "$HONEST"
  expect "a permitted route ($route) fails before the build" fail "FAIL the sandbox refuses"
  grep -q 'zig build mac-compile-only' "$OUT" && bad "$route: the build ran"
  clean_homes
done
reset; : > "$T/ctl/broken"; launch "$HONEST"
expect "a dead sandbox fails" fail "FAIL the sandbox runs a confined write below the root"; clean_homes

reset; mkdir "$T/Users/intel/zb-compile-1-2-3"; launch "$HONEST"
expect "a stale run root refuses" fail "no run root left from an earlier run"
[ -d "$T/Users/intel/zb-compile-1-2-3" ] || bad "stale: the harness deleted a root it did not make"
clean_homes keep
reset; echo held > "$T/ctl/zig"; launch "$HONEST"
expect "a held ownership pipe fails" fail "the ownership pipe is still held"; waitpids; clean_homes
reset; echo escape > "$T/ctl/zig"; launch "$HONEST"
expect "an escaped toolchain process fails" fail "FAIL no run-owned process" "zig-helper"; waitpids; clean_homes
reset; echo marker > "$T/ctl/zig"; launch "$HONEST"
expect "an escaped process with the run marker fails" fail "FAIL no run-owned process"; waitpids; clean_homes
reset; echo leak > "$T/ctl/zig"; launch "$HONEST"
expect "a file left in HOME fails" fail "FAIL no new entry in \$HOME (leak"; clean_homes
reset; echo undeletable > "$T/ctl/zig"; launch "$HONEST"
expect "an undeletable root fails" fail "FAIL the run root is deleted"; clean_homes keep
reset; echo fail > "$T/ctl/zig"; launch "$HONEST"
expect "a failing build fails" fail "FAIL zig build mac-compile-only"; clean_homes

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tmac-compile-only-selftest\tharness copy sha256 %s\n' "$DIGEST"
  exit 0
fi
printf 'FAIL\tmac-compile-only-selftest\t%s case(s)\n' "$fails"
exit 1
