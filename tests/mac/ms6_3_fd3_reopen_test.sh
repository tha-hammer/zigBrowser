#!/bin/sh
# MS6.3 (plan :1608) — the fd-3 reopen (`open("/dev/fd/3")`) works UNDER THE GENERATED CLI PROFILE on both arches.
#
#   $1 = a directory holding sandbox_macos.py (the production generator) + ms6_3_fd3_reopen.c.
#
# The macOS CLI reads its OAuth token by REOPENING "/dev/fd/3" (not read(3) on the inherited fd); that open() must
# pass the Seatbelt profile's file-read check. This gate proves:
#   - unsandboxed, the reopen reads the token (the fd plumbing + helper are sound — not a vacuous pass);
#   - under the GENERATED cli profile (broad file-read*), the reopen reads the exact token  <-- the MS6.3 hard gate;
#   - under a deny-read-of-the-token profile (everything needed to exec the helper, but NOT read the token dir),
#     the reopen is DENIED — so the cli-profile success is the file-read grant's doing, not a /dev/fd exemption.
# sandbox-exec denials are silent EPERM; nothing appears on the Mac's screen.
set -eu

DIR="${1:?usage: ms6_3_fd3_reopen_test.sh <dir-with-sandbox_macos.py-and-helper>}"
[ -f "$DIR/sandbox_macos.py" ] || { echo "FAIL	ms6-3-fd3-reopen (sandbox_macos.py not found in $DIR)"; exit 1; }
[ -f "$DIR/ms6_3_fd3_reopen.c" ] || { echo "FAIL	ms6-3-fd3-reopen (helper source not found in $DIR)"; exit 1; }

TMP=$(mktemp -d /tmp/zb-ms63.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; SECRET="$TMP/secret"; SCRATCH="$TMP/scratch"
mkdir -p "$BIN" "$SECRET" "$SCRATCH"

# The token lives in its OWN dir, separate from the helper binary, so the deny profile can refuse the token dir
# while still allowing the loader to read and exec the helper.
TOKEN="zb-fd3-$(/usr/bin/uuidgen | tr -d - | tr 'A-Z' 'a-z')"
printf '%s\n' "$TOKEN" > "$SECRET/token"

HELPER="$BIN/ms6_3_fd3_reopen"
xcrun clang -o "$HELPER" "$DIR/ms6_3_fd3_reopen.c" 2>"$TMP/cc.err" || {
    echo "FAIL	ms6-3-fd3-reopen (helper build failed)"; cat "$TMP/cc.err"; exit 1; }

# The GENERATED cli profile (the production generator; SimpleNamespace stands in for sandbox.Endpoint).
python3 - "$DIR" "$TMP" <<'PY'
import os, sys, types
d, out = sys.argv[1], sys.argv[2]
sys.path.insert(0, d)
import sandbox_macos
ep = types.SimpleNamespace(host="127.0.0.1", port=52346)
with open(os.path.join(out, "cli.sb"), "w") as f:
    f.write(sandbox_macos.render_profile(egress=ep, bridges=(51091, 31337), is_hook=False))
PY

# The deny-read-of-token vacuity guard: file-read* is allowed broadly so the loader can exec the helper, then
# the token dir AND /dev/fd are denied by trailing last-match-wins rules. Whichever path the kernel checks for
# the reopen (the resolved token file, or the literal /dev/fd/3), it is refused. If the reopen still succeeds
# here, /dev/fd/3 is NOT gated and the cli-profile pass would be vacuous — so this MUST be denied.
cat > "$TMP/deny.sb" <<EOF
(version 1)
(deny default)
(allow process-fork)
(allow process-exec*)
(allow file-read*)
(deny file-read* (subpath "$SECRET"))
(deny file-read* (subpath "/dev/fd"))
EOF

run() { # $1=label $2=profile-or-"none"; opens fd 3 on the token, runs the helper, prints its one line
    label="$1"; prof="$2"
    if [ "$prof" = none ]; then
        out=$("$HELPER" 3<"$SECRET/token" 2>&1) || true
    else
        out=$(/usr/bin/sandbox-exec -f "$prof" -D SCRATCHPAD="$SCRATCH" "$HELPER" 3<"$SECRET/token" 2>&1) || true
    fi
    printf '%s| %s\n' "$label" "$out"
    echo "$out"
}

uout=$(run "unsandboxed" none)
echo "$uout" | grep -q "FD3-REOPEN-OK .* $TOKEN$" || {
    echo "FAIL	ms6-3-positive-control (unsandboxed reopen did not read the token — vacuous/plumbing broken)"; exit 1; }
echo "positive control: reopen reads the token unsandboxed"

cout=$(run "cli-profile" "$TMP/cli.sb")
echo "$cout" | grep -q "FD3-REOPEN-OK .* $TOKEN$" || {
    echo "FAIL	ms6-3-fd3-reopen (the GENERATED cli profile BLOCKED the fd-3 reopen — MS6.3 gate)"; exit 1; }
echo "cli profile: fd-3 reopen WORKS (reads the exact token)"

dout=$(run "deny-token" "$TMP/deny.sb")
if echo "$dout" | grep -q "FD3-REOPEN-OK"; then
    echo "FAIL	ms6-3-vacuity (a profile denying the token dir STILL reopened /dev/fd/3 — the gate is vacuous)"; exit 1
fi
echo "$dout" | grep -q "FD3-REOPEN-FAILED" || {
    echo "FAIL	ms6-3-vacuity (no verdict from the deny profile — did it parse?)"; exit 1; }
echo "deny-token profile: fd-3 reopen DENIED (the gate is not vacuous)"

echo "PASS	ms6-3-fd3-reopen"
