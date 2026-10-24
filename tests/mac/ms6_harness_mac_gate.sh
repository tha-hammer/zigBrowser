#!/usr/bin/env bash
# The MS6 hard-gate harness's own tests on BOTH Macs (bead zigBrowser-a2t): tests/e2e/ms6_hard_gate_harness_test.py and
# ms6_hard_gate_harness_safety_test.py (the Harness signals only its own child's own group; RoseCat on efe2517), run
# there under the framework python.org interpreter, with -X dev. On Darwin no test may be skipped: the
# SpawnGroupWithoutWaitid class (os.waitid removed, as on the bundled CPython 3.12, which has none on macOS) must run
# every SpawnGroup test through kqueue. The run must end in exactly "OK" with the expected count, and no
# ResourceWarning. Per-run ~/zb-hgmac-<nonce>, deleted on exit; nothing installed. BatchMode, strict host keys, no
# askpass; the arm64 host is required (no default).
# usage: tests/mac/ms6_harness_mac_gate.sh [commit]   (default: HEAD)
set -euo pipefail

MAC_PY="${ZB_MAC_PY:-/Library/Frameworks/Python.framework/Versions/Current/bin/python3}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-240}"
EXPECTED_TESTS=19
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
. tests/mac/mac_gate_output.sh
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# The Macs' host keys are pinned (bd 4pa.77): every ssh/scp below uses this file, never ~/.ssh/known_hosts.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
FILES=(tests/e2e/ms6_hard_gate_harness_test.py tests/e2e/ms6_hard_gate_harness_safety_test.py
       tests/mac/hard_gate/harness.py tests/mac/hard_gate/hard_gate_driver.py tests/mac/ms6_hard_gate.sh)
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-hgmac-XXXXXX")
trap 'case "$stage" in */zb-hgmac-*) rm -rf -- "${stage:?}";; esac' EXIT
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
git archive "$SHA" -- "${FILES[@]}" | tar -x -C "$stage"

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -F none -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
  local rdir="zb-hgmac-$(date +%s)-$$-$RANDOM"
  tar -C "${stage:?}" -cf - tests | "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\" && tar -xf - -C \"\$HOME/${rdir}\"" \
    || { "${SSH[@]}" "$host" "rm -rf \"\$HOME/${rdir:?}\"" || true; echo "FAIL: staging on $host" >&2; return 1; }
  local out rc=0
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" \
    "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' ZB_PY='${MAC_PY}' ZB_N='${EXPECTED_TESTS}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
trap 'rm -rf "$HOME/${ZB_RDIR:?}"' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d/tests/e2e"
set +e
out=$(env -i PATH=/usr/bin:/bin HOME="$HOME" LANG=C.UTF-8 "$ZB_PY" -X dev -m unittest -v ms6_hard_gate_harness_test \
  ms6_hard_gate_harness_safety_test 2>&1)
rc=$?
set -e
printf '%s\n' "$out" | grep -E "^test_| \.\.\. |^Ran |^OK|^FAILED|Warning|Error" || true
last=$(printf '%s\n' "$out" | grep -E "^(OK|FAILED)" | tail -1)
ran=$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]*\) tests\{0,1\} in.*/\1/p' | tail -1)
warns=$(printf '%s\n' "$out" | grep -c "ResourceWarning" || true)
if [ "$rc" -eq 0 ] && [ "$last" = "OK" ] && [ "$ran" = "$ZB_N" ] && [ "$warns" -eq 0 ]; then
  printf 'PASS\tms6-harness-mac\t%s\t%s tests, none skipped, 0 ResourceWarning\n' "$ZB_ARCH" "$ran"
else
  printf 'FAIL\tms6-harness-mac\t%s\texit %s, last %q, ran %s of %s, %s ResourceWarning\n' "$ZB_ARCH" "$rc" "$last" \
    "${ran:-?}" "$ZB_N" "$warns"
  exit 1
fi
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: ms6-harness-mac $arch leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms6_harness_mac_gate "$host" "$arch" "$out" \
    $'PASS\tms6-harness-mac\t'"$arch"$'\t19 tests, none skipped, 0 ResourceWarning' || return 1
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 "$ARM_KEY" || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms6-harness-mac-gate\tboth-arches\n'
exit "$overall"
