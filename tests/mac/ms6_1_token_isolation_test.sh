#!/bin/sh
# MS6.1 token-isolation test (plan §MS6.1). Runs ON a Mac; needs /usr/bin/sandbox-exec + xcrun clang.
#
#   $1 = the Seatbelt profile to test (the MS6.1 token-isolation profile for the gate).
#
# A target process (CLI stand-in) carries a unique CANARY in its argv — the way a token on the CLI's
# command line or environment would appear to a same-user reader. A probe (the malicious hook) then tries
# to read it back.
#   1. POSITIVE CONTROL (unsandboxed): the probe MUST breach — reading the canary from the target's
#      kern.procargs2. This proves the leak is real and same-user-readable, so a green under the profile is
#      the profile's doing, not a TCC/host artifact that would stay denied regardless (plan's explicit rule).
#   2. SANDBOXED: the probe under $1 MUST be CONTAINED — every introspection path denied, no canary.
# PASS requires BOTH. A mutant profile that drops the kern.procargs2 deny makes the sandboxed run breach -> FAIL.
set -eu

PROFILE="${1:?usage: ms6_1_token_isolation_test.sh <profile.sb>}"
DIR=$(cd "$(dirname "$0")" && pwd)
PROBE_SRC="$DIR/ms6_1_procinfo_probe.c"
[ -f "$PROFILE" ] || { echo "FAIL	ms6.1-token-isolation (profile not found: $PROFILE)"; exit 1; }
[ -f "$PROBE_SRC" ] || { echo "FAIL	ms6.1-token-isolation (probe source not found: $PROBE_SRC)"; exit 1; }

TMP=$(mktemp -d /tmp/zb-ms6-1.XXXXXX)
TGT=""
cleanup() { [ -n "$TGT" ] && kill "$TGT" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

SCRATCH="$TMP/scratch"; PROT="$TMP/prot"; mkdir -p "$SCRATCH" "$PROT"
PROBE="$TMP/probe"
xcrun clang -o "$PROBE" "$PROBE_SRC" 2>"$TMP/cc.err" || { echo "FAIL	ms6.1-token-isolation (probe build failed)"; cat "$TMP/cc.err"; exit 1; }

CANARY="zb-tok-$(/usr/bin/uuidgen | tr -d - | tr 'A-Z' 'a-z')"
# CLI stand-in: perl sleeps with the canary in its argv (a same-user-readable process-args leak).
/usr/bin/perl -e 'sleep 100000' "$CANARY" &
TGT=$!
sleep 0.4
kill -0 "$TGT" 2>/dev/null || { echo "FAIL	ms6.1-token-isolation (target failed to start)"; exit 1; }

# 1) POSITIVE CONTROL — unsandboxed must BREACH, reading the canary from kern.procargs2.
"$PROBE" "$TGT" "$CANARY" > "$TMP/pc.out" 2>&1 || true
if ! grep -q "procargs2: rc=0 canary=FOUND" "$TMP/pc.out" || ! grep -q "RESULT: BREACH" "$TMP/pc.out"; then
  echo "FAIL	ms6.1-positive-control (unsandboxed probe did NOT expose the canary — the oracle is vacuous)"
  sed 's/^/  pc| /' "$TMP/pc.out"
  exit 1
fi
echo "positive control: BREACH (canary exposed unsandboxed)"

# 2) SANDBOXED — under the profile must be CONTAINED (every path denied, no canary).
/usr/bin/sandbox-exec -f "$PROFILE" -D SCRATCHPAD="$SCRATCH" -D PROTECTED="$PROT" \
  "$PROBE" "$TGT" "$CANARY" > "$TMP/sb.out" 2>&1 || true
if grep -q "RESULT: BREACH" "$TMP/sb.out"; then
  echo "FAIL	ms6.1-token-isolation (the profile LEAKED the token — a hook read the canary)"
  sed 's/^/  sb| /' "$TMP/sb.out"
  exit 1
fi
if ! grep -q "RESULT: CONTAINED" "$TMP/sb.out"; then
  echo "FAIL	ms6.1-token-isolation (the sandboxed probe did not run to a verdict — sandbox-exec error?)"
  sed 's/^/  sb| /' "$TMP/sb.out"
  exit 1
fi
echo "sandboxed: CONTAINED"
sed 's/^/  sb| /' "$TMP/sb.out"
echo "PASS	ms6.1-token-isolation"
