#!/usr/bin/env bash
# Hostless selftest: a Mac run logged to a file (`> log 2>&1`, the way a released run is recorded) keeps every evidence
# line (bd zigBrowser-3ui.10: `tee /dev/stderr` in tests/mac/mac_gate_lib.sh's mac_build and in tests/mac/gate.sh
# reopened that file and truncated it, so each mac_build or remote test wiped what came before). Three real runs
# against a stub ssh/scp that answers like a passing Mac, each with stdout and stderr in one log file:
#   tests/mac/gate.sh (mac_build on both hosts, then the M9 and mac_universal remote tests on both),
#   tests/mac/ms2b_gate.sh (mac_build on both hosts), and packaging/macos/build-dmg.sh (mac_build on both hosts: the universal .app).
# For each log:
#   L1 it has no NUL byte (a truncated file written at the old offset leaves a hole of NULs);
#   L2 it still holds the run's first line and its end line;
#   L3 it holds every host's build-on-mac evidence: ZB_REMOTE_DIR and PASS build-on-mac, once per host;
#   L4 (gate.sh) it holds both hosts' remote test output: the M9 PASS lines and "PASS mac-universal 12 assertions".
# No Mac, no signal: it re-runs itself in a private user+network namespace; HOME/TMPDIR live in its temp tree.
# Run: bash tests/mac/mac_log_integrity_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_LOGINTEGRITY_SELFTEST_INNER:-}" != 1 ]; then
  ZB_LOGINTEGRITY_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-logintegrity-selftest-XXXXXX")
T=$(realpath "$BASE")
printf 'not a real key\n' > "$T/fake_mac_key"   # tests/mac/mac_config.sh needs a readable regular key file (bd 3ui.13)
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-logintegrity-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2

mkdir -p "$T/bin" "$T/ctl" "$T/home" "$T/tmp"
# A passing Mac (the answers tests/mac/gate_selftest.sh's stub gives in its healthy "ok" scenario).
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
host= skip= k=0
for a in "\$@"; do
  k=\$((k + 1))
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
  host=\$a; break
done
cmd=("\${@:k+1}") c="\${*:k+1}"
case "\$host" in $INTEL) arch=x86_64 ;; $ARM) arch=arm64 ;; *) echo "stub ssh: unexpected host \$host" >&2; exit 99 ;; esac
s=\$(cat)
case "\$c" in
  cd\ \"\\\$HOME/zb-gate-*\"\ \&\&\ *zig\ build*) echo "build ok"; exit 0 ;;
  cat\ *exec-arch.txt*) echo "\$arch"; exit 0 ;;
  *pillow_tools.py\ nonuniform*) echo '{"stddev": 41.5, "distinct": 913, "width": 800, "height": 600}'; exit 0 ;;
esac
if [ "\${cmd[0]:-}" = /bin/bash ] && [ "\${cmd[1]:-}" = -s ]; then
  case "\$s" in
    *'lipo -create'*) echo "universal archs: x86_64 arm64"; echo "shim dylib archs: x86_64 arm64" ;;
    *m9_render_test.py*)
      printf 'PASS\tm9-render-webview-screenshot\tzig-out/m9-render.png\tuniformity deferred\n'
      printf 'PASS\tm9-reply-channel-contract\nPASS\tm9-load-fail-contract\nexec_arch_probe: build.exec_arch=%s\n' "\$arch" ;;
    *mac_universal_test.py*) printf 'PASS\tmac-universal\t12 assertions\n' ;;
  esac
  if [ "\${ZB_LOG_GATE:-}" = ms2b ]; then
    printf '%s\n' \
      \$'PASS\tms2b-key-table-parity\t(31 names)' \$'PASS\tms2b.1a-native-click' \
      \$'PASS\tms2b.1b-key-text' \$'PASS\tms2b-key-coverage' \$'PASS\tms2b-ack-error' \
      \$'PASS\tms2b-doc-changed' \$'PASS\tms2b-text-doc-changed-selftest' \
      \$'PASS\tms2b-text-doc-changed' \$'PASS\tms2b-partial-type' \$'PASS\tms2b-pair-race' \
      \$'PASS\tms2b-ack-hang' \$'PASS\tms2b-dialogs' \$'PASS\tms2b-eval-dialog'
  fi
fi
exit 0
EOF
cat > "$T/bin/scp" <<EOF
#!/bin/bash
dst="\${@: -1}" src="\${@: -2:1}"
case "\$dst" in *:*) ;; *)   # a fetch: leave a stub file where the remote file lands
  if [ -d "\$dst" ]; then echo stub > "\$dst/\$(basename "\${src#*:}")"; else echo stub > "\$dst"; fi ;;
esac
exit 0
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp"

R="$T/repo"
mkdir -p "$R/tests/mac" "$R/tests/e2e" "$R/src" "$R/packaging/macos" "$R/packaging/assets"
for f in gate.sh ms2b_gate.sh build-on-mac.sh mac_gate_lib.sh mac_gate_output.sh mac_config.sh known_hosts; do
  cp "$ROOT/tests/mac/$f" "$R/tests/mac/"
done
cp "$ROOT/tests/e2e/mac_resource_compat.py" "$ROOT/tests/e2e/mac_universal_test.py" "$R/tests/e2e/"
cp "$ROOT/packaging/macos/universal_components.json" "$ROOT/packaging/macos/entitlements.plist" \
  "$ROOT/packaging/macos/build-dmg.sh" "$ROOT/packaging/macos/Info.plist" "$R/packaging/macos/"
cp "$ROOT/packaging/assets/zigBrowser.png" "$R/packaging/assets/"
echo src > "$R/src/main.zig"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
SHA=$("${G[@]}" rev-parse HEAD)

check_log() { # check_log <label> <script> <first line, ERE> <end line, ERE> <hosts> [gate]
  local label=$1 script=$2 first=$3 end=$4 nhosts=$5 gate=${6:-} log="$T/log.$1" rc
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/fake_mac_key" ZB_LOG_GATE="$label" timeout 120 bash "$script" > "$log" 2>&1 </dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || bad "$label: exit $rc, want 0 (a passing Mac): $(tr -d '\0' < "$log" | tail -n 2 | tr '\n' ' ')"
  if [ "$(tr -cd '\0' < "$log" | wc -c)" -eq 0 ]; then ok "$label L1: the log has no NUL byte"
  else bad "$label L1: the log has $(tr -cd '\0' < "$log" | wc -c) NUL bytes (it was truncated under the writer)"; fi
  if grep -aqE "$first" "$log" && grep -aqE "$end" "$log"; then ok "$label L2: the log keeps its first line and its end line"
  else bad "$label L2: first line /$first/ or end line /$end/ is gone"; fi
  if [ "$(grep -acP "^ZB_REMOTE_DIR\tzb-gate-$SHA-" "$log")" -eq "$nhosts" ] \
     && [ "$(grep -acP "^PASS\tbuild-on-mac\t$SHA\tzb-gate-$SHA-" "$log")" -eq "$nhosts" ]; then
    ok "$label L3: the build-on-mac evidence of all $nhosts host(s) is in the log"
  else bad "$label L3: $(grep -acP '^ZB_REMOTE_DIR\t' "$log") ZB_REMOTE_DIR and $(grep -acP '^PASS\tbuild-on-mac\t' "$log") PASS build-on-mac lines, want $nhosts each"; fi
  if [ -n "$gate" ]; then
    if [ "$(grep -acP '^PASS\tm9-render-webview-screenshot\t' "$log")" -eq 2 ] && [ "$(grep -acP '^PASS\tmac-universal\t12 assertions$' "$log")" -eq 2 ]; then
      ok "$label L4: both hosts' M9 and mac_universal output is in the log"
    else bad "$label L4: $(grep -acP '^PASS\tm9-render-webview-screenshot\t' "$log") M9 and $(grep -acP '^PASS\tmac-universal\t' "$log") mac_universal PASS lines, want 2 each"; fi
  fi
}

check_log gate      tests/mac/gate.sh              '^== build x86_64 on intel@10\.0\.0\.1 ==$' $'^PASS\tmac-universal-gate\tboth-arches$' 2 gate
check_log ms2b      tests/mac/ms2b_gate.sh         '^== build \+ MS2b e2e on intel@10\.0\.0\.1 \(x86_64\) ==$' $'^PASS\tms2b-gate\tboth-arches$'          2
check_log build-dmg packaging/macos/build-dmg.sh   '^==> Building on macOS host\.\.\.$'        '^==> Done: '                               2

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-log-integrity-selftest\n'; exit 0; fi
printf 'FAIL\tmac-log-integrity-selftest\t%s failure(s)\n' "$fails"
exit 1
