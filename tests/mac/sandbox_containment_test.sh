#!/bin/sh
# MS6 containment proof — run a stand-in "helper" under the macOS Seatbelt profile and assert it is contained.
# Headless: sandbox-exec denials are silent EPERM, no GUI pop-ups (measured). $1 = profile path.
#
# Shared SandboxBackend contract: the WORKSPACE is READ-ONLY, only the SCRATCHPAD is writable. Asserts:
#   - a SCRATCHPAD write succeeds (the correct positive oracle) and a WORKSPACE write fails closed (no leak);
#   - the WORKSPACE stays readable (read-only input is usable); a PROTECTED read is denied;
#   - NETWORK: a connect to a forbidden loopback port with a LIVE local listener is denied (so a denial can't
#     false-green offline), while the allowed bridge ports 51091/31337 connect (deleting the allow rule reds);
#   - a CHILD process is equally contained (its workspace write also fails closed).
set -u
PROFILE="${1:?usage: sandbox_containment_test.sh <profile.sb>}"

SCRATCH="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zb-ms6-scratch.XXXXXX")" && pwd -P)"  # the ONLY writable tree
WS="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zb-ms6-ws.XXXXXX")" && pwd -P)"            # read-only workspace input
PROT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zb-ms6-prot.XXXXXX")" && pwd -P)"        # a tree the agent must not read
HELPER="$(mktemp "${TMPDIR:-/tmp}/zb-ms6-helper.XXXXXX")"
echo "workspace-input" > "$WS/input.txt"
echo "top-secret-canary" > "$PROT/secret"
FORB=$(( 49152 + (${RANDOM:-$$} % 12000) ))   # a forbidden loopback port (not in the profile's allowed set)

LISTENER_PIDS=""
trap 'kill $LISTENER_PIDS 2>/dev/null; rm -rf "$SCRATCH" "$WS" "$PROT" "$HELPER"' EXIT

fails=0
bad() { echo "  $1" >&2; fails=$((fails + 1)); }

# Make 127.0.0.1:$1 reachable (a pre-existing owner counts, else start our own keep-alive listener), so a
# sandbox denial is distinguishable from "nothing listening". Returns non-zero if the port can't be made live.
ensure_port() {
  nc -z -G 1 -w 1 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
  nc -k -l "$1" >/dev/null 2>&1 &
  LISTENER_PIDS="$LISTENER_PIDS $!"
  i=0
  while [ "$i" -lt 20 ]; do
    nc -z -G 1 -w 1 127.0.0.1 "$1" >/dev/null 2>&1 && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
ensure_port "$FORB" || { echo "FAIL	ms6-containment"; echo "  setup: forbidden port $FORB never came up (network negative would be meaningless)" >&2; exit 1; }
ensure_port 51091   || { echo "FAIL	ms6-containment"; echo "  setup: bridge port 51091 never came up (bridge positive would be meaningless)" >&2; exit 1; }
ensure_port 31337   || { echo "FAIL	ms6-containment"; echo "  setup: bridge port 31337 never came up (bridge positive would be meaningless)" >&2; exit 1; }

cat > "$HELPER" <<'HELPER_EOF'
SCRATCH="$1"; WS="$2"; PROT="$3"; FORB="$4"
( : > "$SCRATCH/ok.txt" ) 2>/dev/null;         echo "SCRATCH_WRITE=$?"
( : > "$WS/x.txt" ) 2>/dev/null;               echo "WS_WRITE=$?"
( cat "$WS/input.txt" ) >/dev/null 2>&1;       echo "WS_READ=$?"
( cat "$PROT/secret" ) >/dev/null 2>&1;        echo "PROT_READ=$?"
/usr/bin/nc -z -G 2 -w 2 127.0.0.1 "$FORB"  >/dev/null 2>&1; echo "NET_FORBIDDEN=$?"
/usr/bin/nc -z -G 2 -w 2 127.0.0.1 51091    >/dev/null 2>&1; echo "NET_BRIDGE_A=$?"
/usr/bin/nc -z -G 2 -w 2 127.0.0.1 31337    >/dev/null 2>&1; echo "NET_BRIDGE_B=$?"
/bin/sh -c '( : > "$0/child.txt" ) 2>/dev/null; echo "CHILD_WS_WRITE=$?"' "$WS"
HELPER_EOF

OUT="$(/usr/bin/sandbox-exec -f "$PROFILE" -D SCRATCHPAD="$SCRATCH" -D PROTECTED="$PROT" \
  /bin/sh "$HELPER" "$SCRATCH" "$WS" "$PROT" "$FORB" 2>/dev/null)"

get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }
sw=$(get SCRATCH_WRITE); ww=$(get WS_WRITE); wr=$(get WS_READ); pr=$(get PROT_READ)
nf=$(get NET_FORBIDDEN); na=$(get NET_BRIDGE_A); nb=$(get NET_BRIDGE_B); cw=$(get CHILD_WS_WRITE)

[ "$sw" = "0" ]                       || bad "scratchpad write did not succeed (rc=${sw:-none}; helper may not have launched)"
[ -f "$SCRATCH/ok.txt" ]              || bad "scratchpad write produced no file"
{ [ -n "$ww" ] && [ "$ww" != "0" ]; } || bad "a WORKSPACE write did NOT fail closed — workspace must be read-only (rc=${ww:-none})"
[ ! -e "$WS/x.txt" ]                  || bad "a workspace write LEAKED a file (workspace not read-only)"
[ "$wr" = "0" ]                       || bad "the read-only workspace was not readable (rc=${wr:-none})"
{ [ -n "$pr" ] && [ "$pr" != "0" ]; } || bad "a protected read was NOT denied (rc=${pr:-none})"
{ [ -n "$nf" ] && [ "$nf" != "0" ]; } || bad "a forbidden network port (live listener) was NOT denied (rc=${nf:-none})"
[ "$na" = "0" ]                       || bad "an allowed bridge port 51091 did NOT connect (rc=${na:-none})"
[ "$nb" = "0" ]                       || bad "an allowed bridge port 31337 did NOT connect (rc=${nb:-none})"
{ [ -n "$cw" ] && [ "$cw" != "0" ]; } || bad "a CHILD process was NOT contained — its workspace write succeeded (rc=${cw:-none})"
[ ! -e "$WS/child.txt" ]              || bad "a child's workspace write LEAKED a file"

if [ "$fails" -ne 0 ]; then
  echo "FAIL	ms6-containment"
  printf '    helper output: %s\n' "$(printf '%s' "$OUT" | tr '\n' ' ')" >&2
  exit 1
fi
echo "PASS	ms6-containment"
