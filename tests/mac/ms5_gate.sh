#!/usr/bin/env bash
# MS5 gate (Keychain seam half) — the macOS Keychain token store (agent_secrets_mac.m) on BOTH Macs.
#
# No display, no browser, no socket: compiles the seam + its disposable-canary test natively on each Mac
# (xcrun clang, Security + Foundation) and runs it headless. The test creates/unlocks its own throwaway
# keychain, so SecItem never touches the login keychain (which refuses headless, -25308) and never prompts.
# Driven from Linux over Tailscale SSH; fail-closed (arm64 host mandatory, explicit `|| return 1` per step).
set -euo pipefail


cd "$(git rev-parse --show-toplevel)"
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two

# Only the pinned Mac host keys are trusted, and no password, askpass or display can be used (SilverRidge 1915e0d;
# the same options as tests/mac/mac_gate_lib.sh). Hostless selftest: tests/mac/ms5_gate_hostkey_selftest.sh.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
export SSH_ASKPASS_REQUIRE=never
ssh_opts() { printf '%s\0' env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$1" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10; }
scp_opts() { printf '%s\0' env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -i "$1" -o IdentitiesOnly=yes -o BatchMode=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15; }


LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-180}"
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}")
echo "== commit $SHA" >&2
stage=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms5-drv-XXXXXX")
trap 'case "$stage" in "${TMPDIR:-/tmp}"/zb-ms5-drv-??????) rm -rf -- "${stage:?}";; esac' EXIT
FILES=(src/agent_secrets_mac.h src/agent_secrets_mac.m src/agent_secrets_mac.zig tests/mac/keychain_seam_test.m)
git archive "$SHA" -- "${FILES[@]}" | tar -x -C "$stage"
STAGED_FILES=()
for f in "${FILES[@]}"; do STAGED_FILES+=("$stage/$f"); done

verify_host() { # $1=host $2=key $3=label (the label is the EXPECTED uname -m, asserted on the host)
  local host="$1" key="$2" label="$3"
  local -a SSH SCP; mapfile -d '' SSH < <(ssh_opts "$key"); mapfile -d '' SCP < <(scp_opts "$key")
  echo "== MS5 Keychain seam on $host ($label) ==" >&2
  # Per-run nonce dir (RoseCat SHOULD): never a fixed shared tree, so concurrent runs can't collide, and
  # cleanup deletes only this exact validated path.
  local rdir="zb-ms5-$(date +%s)-$$-$RANDOM"
  # Best-effort exact-path cleanup for failures BEFORE the remote EXIT trap exists (mkdir/scp). The nonce
  # dir is validated (${rdir:?}) so this never expands to a bare $HOME.
  local rm_rdir="rm -rf \"\$HOME/${rdir:?}\""
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir}\"" || { echo "FAIL: mkdir ${rdir} on $host" >&2; return 1; }
  "${SCP[@]}" "${STAGED_FILES[@]}" "$host":"${rdir}"/ >/dev/null \
    || { echo "FAIL: scp MS5 sources to $host" >&2; "${SSH[@]}" "$host" "$rm_rdir" >/dev/null 2>&1 || true; return 1; }
  # Pass the expected arch + the nonce dir into the (quoted) remote; the remote asserts the EXECUTING arch
  # against the label (RoseCat #3: two legs must be two architectures, not the same machine twice).
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_EXPECT_ARCH='${label}' ZB_RDIR='${rdir}' /bin/bash -s" <<'REMOTE' || { echo "FAIL: MS5 leg on $host timed out/failed" >&2; "${SSH[@]}" "$host" "$rm_rdir" >/dev/null 2>&1 || true; return 1; }
set -euo pipefail
d="$HOME/${ZB_RDIR:?}"
trap 'rm -rf "$HOME/${ZB_RDIR:?}"' EXIT  # delete only this exact nonce dir; the test self-cleans its keychains
got="$(uname -m)"
if [ "$got" != "$ZB_EXPECT_ARCH" ]; then
  echo "FAIL: arch oracle — uname -m=$got but this leg expected $ZB_EXPECT_ARCH (same machine run twice?)" >&2
  exit 1
fi
cd "$d"
xcrun clang -fobjc-arc -Wno-deprecated-declarations -I "$d" \
  -framework Security -framework Foundation \
  keychain_seam_test.m agent_secrets_mac.m -o kc_seam_test
./kc_seam_test
# MS5.2 Zig port over the C seam (groundwork; not yet wired into app.zig's switch): compile the seam to an
# object and run the Zig port's round-trip test against a disposable keychain.
xcrun clang -c -fobjc-arc -Wno-deprecated-declarations -I "$d" agent_secrets_mac.m -o "$d/asm.o"
# Both zig caches stay inside this run dir, never the owner's ~/.cache/zig (bd 3ui.5).
ZIG_LOCAL_CACHE_DIR="$d/.zig-cache" ZIG_GLOBAL_CACHE_DIR="$d/.zig-global-cache" \
  "$HOME/.local/bin/zig" test --cache-dir "$d/.zig-cache" --global-cache-dir "$d/.zig-global-cache" \
  "$d/agent_secrets_mac.zig" "$d/asm.o" -lc -framework Security -framework Foundation
printf 'PASS\tms5-keychain-zigport\n'
REMOTE
  printf 'PASS\tms5-leg\t%s\t%s\n' "$host" "$label"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 MS5 leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 MS5 leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms5-gate\tboth-arches\n'
else
  echo "MS5 gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
