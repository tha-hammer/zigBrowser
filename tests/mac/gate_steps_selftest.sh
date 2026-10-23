#!/usr/bin/env bash
# Hostless selftest: the Mac gates are real `zig build` steps, each with a committed record of its last approved run
# (plan R29-REG; bd zigBrowser-4pa.62 made ms2b/ms2c/ms3 steps of the hand-run gates). A scratch git copy of the repo
# runs `zig build <step>` for real, with a stub ssh/scp on PATH that records every call and answers like a passing Mac
# (including the remote tests' PASS lines that tests/mac/gate.sh requires). For each of mac-gate, ms1b-gate, ms2a-gate,
# ms2b-gate, ms2c-gate and ms3-gate (the manifest rows of the older mac-gate, ms1b-gate and ms2a-gate steps were added
# for R29-REG, SilverRidge b3b3620 and fb8e6ff):
#   S1 with both Mac hosts configured, `zig build <step>` exits 0 and prints that gate's own both-arches PASS line
#      (mac-gate's is "PASS<TAB>mac-universal-gate<TAB>both-arches"), after ssh calls to both hosts (the step runs that
#      script to its end);
#   S2 with no arm64 host, `zig build <step>` exits non-zero with the gate's "NOT RUN: arm64 host not configured" and
#      makes zero ssh/scp calls (the step passes the gate's failure through; it never turns it into a pass);
#   S3 TRIPWIRE (not proof): tests/mac/approved_runs/<step>.json names the step and its script, and its
#      last_approved_run is null (none recorded yet) or an exact commit with hosts, date, approver and release.
# No Mac, no signal: it re-runs itself in a private user+network namespace; HOME/TMPDIR and both zig caches live in
# its temp tree. ZIG names the zig binary (the build step passes its own).
# Run: ZIG=<zig> bash tests/mac/gate_steps_selftest.sh [repo root]   (step: zig build test-mac-gate-steps)
set -uo pipefail
if [ "${ZB_GATESTEPS_SELFTEST_INNER:-}" != 1 ]; then
  ZB_GATESTEPS_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
ZIG=$(command -v "${ZIG:-zig}") || { printf 'FAIL\tmac-gate-steps-selftest\tno zig (set ZIG)\n'; exit 1; }
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-gatesteps-selftest-XXXXXX")
T=$(realpath "$BASE")
printf 'not a real key\n' > "$T/fake_mac_key"   # tests/mac/mac_config.sh needs a readable regular key file (bd 3ui.13)
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-gatesteps-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2

mkdir -p "$T/bin" "$T/ctl" "$T/home" "$T/tmp"
cat > "$T/bin/ssh" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' ssh "\$@" > "$T/ctl/call.\$i"
s=\$(cat)
# The answers of a passing Mac where a gate reads the remote output (tests/mac/gate.sh, MS1.4).
host= skip=
for a in "\$@"; do
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
  host=\$a; break
done
arch=x86_64; [ "\$host" = "$ARM" ] && arch=arm64
case "\$*" in
  *ZB_ROOT_ABSENT*) last="\${@: -1}"; printf 'ZB_ROOT_ABSENT\t%s\n' "\${last##* }"; exit 0 ;;   # the verified cleanup (mac_gate_lib.sh) confirms
  *"cat "*exec-arch.txt*) echo "\$arch"; exit 0 ;;
  *"pillow_tools.py nonuniform"*) echo '{"stddev": 41.5, "distinct": 913, "width": 800, "height": 600}'; exit 0 ;;
esac
case "\$s" in
  *'lipo -create'*) echo "universal archs: x86_64 arm64"; echo "shim dylib archs: x86_64 arm64" ;;
  *m9_render_test.py*)
    printf 'PASS\tm9-render-webview-screenshot\tzig-out/m9-render.png\tstub\nPASS\tm9-reply-channel-contract\n'
    printf 'PASS\tm9-load-fail-contract\nexec_arch_probe: build.exec_arch=%s\n' "\$arch" ;;
  *mac_universal_test.py*) printf 'PASS\tmac-universal\t12 assertions\n' ;;
esac
exit 0
EOF
cat > "$T/bin/scp" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' scp "\$@" > "$T/ctl/call.\$i"
dst="\${@: -1}" src="\${@: -2:1}"
case "\$dst" in *:*) ;; *)   # a fetch: leave a stub file where the remote file lands
  if [ -d "\$dst" ]; then echo stub > "\$dst/\$(basename "\${src#*:}")"; else echo stub > "\$dst"; fi ;;
esac
exit 0
EOF
chmod +x "$T/bin/ssh" "$T/bin/scp"

# The scratch repo: this tree without caches or build output, committed (the gates build one exact commit).
R="$T/repo"
mkdir -p "$R"
tar -C "$ROOT" --exclude=./.git --exclude=./.zig-cache --exclude=./zig-out --exclude=./.zc --exclude=./.zgc -cf - . \
  | tar -C "$R" -xf - || { bad "could not copy the repo"; exit 1; }
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }

run_step() { # run_step <step> <arm host>: sets rc, calls, hosts; output in $T/out
  rm -f "$T/ctl"/*
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" \
     ZB_MAC_ARM_HOST="$2" ZB_MAC_KEY="$T/fake_mac_key" timeout 600 "$ZIG" build "$1" \
     --cache-dir "$T/zig-cache" --global-cache-dir "$T/zig-global-cache" >"$T/out" 2>&1 </dev/null)
  rc=$?
  calls=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
  hosts=$(for f in "$T/ctl"/call.*; do [ -e "$f" ] && tr '\0' '\n' < "$f" | grep -oxE "$INTEL|$ARM|($INTEL|$ARM):.*" | cut -d: -f1; done | sort -u | tr '\n' ' ')
}

for row in "mac-gate tests/mac/gate.sh mac-universal-gate" "ms1b-gate tests/mac/ms1b_signed_gate.sh ms1b-signed-gate" \
           "ms2a-gate tests/mac/ms2a_gate.sh ms2a-gate" "ms2b-gate tests/mac/ms2b_gate.sh ms2b-gate" \
           "ms2c-gate tests/mac/ms2c_gate.sh ms2c-gate" "ms3-gate tests/mac/ms3_gate.sh ms3-gate"; do
  read -r step script passname <<<"$row"
  run_step "$step" "$ARM"
  if [ "$rc" -eq 0 ] && grep -qP "^PASS\t$passname\tboth-arches$" "$T/out" && [ "$hosts" = "$ARM $INTEL " ]; then
    ok "$step S1: zig build $step runs $script to its PASS line on both hosts ($calls ssh/scp calls)"
  else
    bad "$step S1: zig build $step: exit $rc, hosts '$hosts', want 0 with \"PASS $passname both-arches\": $(grep -E 'error|FAIL|PASS|no step' "$T/out" | head -n 3 | tr '\n' ' ')"
  fi
  run_step "$step" ""
  if [ "$rc" -ne 0 ] && grep -q 'NOT RUN: arm64 host not configured' "$T/out" && [ "$calls" -eq 0 ]; then
    ok "$step S2: with no arm64 host, zig build $step fails (exit $rc) with NOT RUN and no ssh/scp call"
  else
    bad "$step S2: with no arm64 host, zig build $step: exit $rc, $calls ssh/scp calls: $(grep -E 'error|NOT RUN|no step' "$T/out" | head -n 2 | tr '\n' ' ')"
  fi
  m="$ROOT/tests/mac/approved_runs/$step.json"
  if verdict=$(python3 -I - "$m" "$step" "$script" <<'PY' 2>&1
import json, re, sys
path, step, script = sys.argv[1:]
d = json.load(open(path))
assert d.get("gate") == step, f"gate is {d.get('gate')!r}"
assert d.get("script") == script, f"script is {d.get('script')!r}"
run = d.get("last_approved_run", "missing")
if run is not None:
    assert isinstance(run, dict), "last_approved_run is neither null nor an object"
    assert re.fullmatch(r"[0-9a-f]{40}", str(run.get("commit"))), "commit is not a full sha"
    for k in ("hosts", "date", "approver", "release"):
        assert run.get(k), f"no {k}"
print("none recorded" if run is None else "commit " + run["commit"])
PY
  ); then ok "$step S3 TRIPWIRE: approved_runs/$step.json: $verdict"
  else bad "$step S3 TRIPWIRE: approved_runs/$step.json: $(tail -n 1 <<<"$verdict")"; fi
done

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-gate-steps-selftest\n'; exit 0; fi
printf 'FAIL\tmac-gate-steps-selftest\t%s failure(s)\n' "$fails"
exit 1
