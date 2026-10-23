#!/usr/bin/env bash
# MS7 compiled two-Mac hard gate (RoseCat c6b2b32 items 2-4; orchestrator 2026-10-22): the runtime authority for the
# AppKit drawer's bubbles, the live Edit > Copy route and the approval card. The source oracles
# (tests/e2e/mac_drawer_bubble_inert_test.py, tests/e2e/mac_drawer_card_authority_test.py) are offline tripwires.
#
# It certifies ONE commit on BOTH Macs (Intel and Apple Silicon), each from a clean export of that commit:
#   - it runs only from the commit's bytes (as tests/mac/ms6_hard_gate.sh, RoseCat 7275):
#       bash -c "$(git show <rev>:tests/mac/ms7_appkit_gate.sh)" ms7-appkit-gate <rev>
#     run as a file it refuses at once; its executing text must equal `git show <sha>:tests/mac/ms7_appkit_gate.sh`;
#   - it exports <rev> (git archive) and ships only that export's build inputs and tests, printing "== ship <sha256>
#     <path>" for each file and the tar's digest before any connection;
#   - each leg makes ~/zb-ms7gate-<nonce>, builds natively there and runs tests/mac/ms7_appkit_case.py (the evidence,
#     the probe in the real app with a throwaway HOME and profile, no credential, no live network), and deletes the
#     directory by a validated find -delete on exit. Nothing is installed.
#   - BatchMode, strict host keys, no askpass, no DISPLAY. The aggregate is PASS only when both legs end
#     "PASS<TAB>ms7-appkit<TAB><arch>".
# Running it on the Macs needs RoseCat's exact-commit and digest approval plus the orchestrator's release.
set -euo pipefail
if [ -z "${BASH_EXECUTION_STRING:-}" ]; then
  printf 'FAIL\tms7-appkit-gate\trun the committed launcher, never a working-tree file:\n' >&2
  echo '  bash -c "$(git show <rev>:tests/mac/ms7_appkit_gate.sh)" ms7-appkit-gate <rev>' >&2
  exit 1
fi
LAUNCHER=$(printf '%s' "$BASH_EXECUTION_STRING")

LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-2400}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
fail() { printf 'FAIL\tms7-appkit-gate\t%s\n' "$*" >&2; exit 1; }
REV="${1:-HEAD}"
SHA=$(git rev-parse --verify --quiet "${REV}^{commit}") || fail "revision $REV is not a commit"
[ "$(git show "$SHA:tests/mac/ms7_appkit_gate.sh")" = "$LAUNCHER" ] \
  || fail "the running launcher is not the committed tests/mac/ms7_appkit_gate.sh at $SHA"
L=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms7gate-drv-XXXXXX")
trap 'case "$L" in "${TMPDIR:-/tmp}"/zb-ms7gate-drv-??????) find "${L:?}" -delete;; esac' EXIT
mkdir "$L/repo" && git archive "$SHA" | tar -x -C "$L/repo"
# The Macs' host keys are pinned (bd 4pa.77) and come from the exported commit, never the mutable working tree
# (SilverRidge 7f58dd72): every ssh/scp below uses this file, checked against the commit's blob first.
KNOWN_HOSTS="$L/repo/tests/mac/known_hosts"
[ -f "$KNOWN_HOSTS" ] && [ ! -L "$KNOWN_HOSTS" ] \
  && [ "$(git hash-object --no-filters -- "$KNOWN_HOSTS")" = "$(git rev-parse --verify --quiet "$SHA:tests/mac/known_hosts")" ] \
  || fail "tests/mac/known_hosts in the export is missing or is not the blob at $SHA"
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. "$L/repo/tests/mac/mac_config.sh"
mac_config two
[ -n "$ARM_HOST" ] || fail "no arm64 host (set ZB_MAC_ARM_HOST=user@host); the gate needs both Macs"
echo "== ms7 appkit gate at commit $SHA" >&2
cd "$L/repo"

SHIP=(src build.zig build.zig.zon zigbrowser.json tests packaging tools)
odd=$(find "${SHIP[@]}" ! -type f ! -type d | LC_ALL=C sort | tr '\n' ' ')
[ -z "$odd" ] || fail "a shipped path holds a symlink or special entry (refused): $odd"
tar -cf "$L/src.tar" --exclude=__pycache__ "${SHIP[@]}"
find "${SHIP[@]}" -type f ! -path '*/__pycache__/*' | LC_ALL=C sort > "$L/ship.list"
[ "$(tar -tf "$L/src.tar" | grep -v '/$' | LC_ALL=C sort)" = "$(cat "$L/ship.list")" ] \
  || fail "the shipped tar's files are not exactly the named ones"
while IFS= read -r f; do echo "== ship $(sha256sum "$f" | cut -c1-64) $f" >&2; done < "$L/ship.list"
echo "== shipped tree identity: commit $SHA, src.tar sha256 $(sha256sum "$L/src.tar" | cut -c1-64)" >&2

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3" rdir="zb-ms7gate-$(date +%s)-$$-$RANDOM"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
  local SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15)
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "$L/src.tar" "$host:${rdir}/" >/dev/null; then
    "${SSH[@]}" "$host" "d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' /bin/bash -s" <<'REMOTE'
set -uo pipefail
case "$ZB_RDIR" in zb-ms7gate-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
d="$HOME/${ZB_RDIR:?}"
trap 'cd / && find "$HOME/${ZB_RDIR:?}" -delete' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d" && mkdir repo && tar -xf src.tar -C repo && mkdir run || exit 1
ZIG="$HOME/.local/bin/zig"
[ -x "$ZIG" ] || { printf 'FAIL\tms7-appkit\t%s\tno zig at %s\n' "$ZB_ARCH" "$ZIG"; exit 1; }
cd "$d/repo" && env -i PATH=/usr/bin:/bin HOME="$HOME" LANG=C.UTF-8 \
  /usr/bin/python3 -I -B tests/mac/ms7_appkit_case.py "$d/run" "$ZB_ARCH" "$ZIG"
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" | tee "$L/x86_64.log" || true
leg "$ARM_HOST" arm64 "$ARM_KEY" | tee "$L/arm64.log" || true
for arch in x86_64 arm64; do
  [ "$(tail -1 "$L/$arch.log" | cut -f1-3)" = "PASS	ms7-appkit	$arch" ] || { echo "FAIL: $arch leg" >&2; overall=1; }
done
[ "$overall" -eq 0 ] && printf 'PASS\tms7-appkit-gate\tboth-arches\t%s\n' "$SHA"
exit "$overall"
