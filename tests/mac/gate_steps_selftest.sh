#!/usr/bin/env bash
# Hostless selftest: the MS2b, MS2c and MS3 Mac gates are real `zig build` steps (bd zigBrowser-4pa.62, plan R30-MS2 and
# R29-REG: tests/mac/ms2b_gate.sh, ms2c_gate.sh and ms3_gate.sh were hand-run, with no step and no record of an approved
# run). A scratch git copy of the repo runs `zig build <step>` for real, with a stub ssh/scp on PATH that records every
# call and answers like a passing Mac. For each of ms2b-gate, ms2c-gate and ms3-gate:
#   S1 with both Mac hosts configured, `zig build <step>` exits 0 and prints that gate's own
#      "PASS<TAB><step><TAB>both-arches" line, after ssh calls to both hosts (the step runs that script to its end);
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
cat > /dev/null
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
     ZB_MAC_ARM_HOST="$2" ZB_MAC_KEY="$T/home/no_such_key" timeout 600 "$ZIG" build "$1" \
     --cache-dir "$T/zig-cache" --global-cache-dir "$T/zig-global-cache" >"$T/out" 2>&1 </dev/null)
  rc=$?
  calls=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
  hosts=$(for f in "$T/ctl"/call.*; do [ -e "$f" ] && tr '\0' '\n' < "$f" | grep -oxE "$INTEL|$ARM|($INTEL|$ARM):.*" | cut -d: -f1; done | sort -u | tr '\n' ' ')
}

for row in "ms2b-gate tests/mac/ms2b_gate.sh" "ms2c-gate tests/mac/ms2c_gate.sh" "ms3-gate tests/mac/ms3_gate.sh"; do
  read -r step script <<<"$row"
  run_step "$step" "$ARM"
  if [ "$rc" -eq 0 ] && grep -qP "^PASS\t$step\tboth-arches$" "$T/out" && [ "$hosts" = "$ARM $INTEL " ]; then
    ok "$step S1: zig build $step runs $script to its PASS line on both hosts ($calls ssh/scp calls)"
  else
    bad "$step S1: zig build $step: exit $rc, hosts '$hosts', want 0 with \"PASS $step both-arches\": $(grep -E 'error|FAIL|PASS|no step' "$T/out" | head -n 3 | tr '\n' ' ')"
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
