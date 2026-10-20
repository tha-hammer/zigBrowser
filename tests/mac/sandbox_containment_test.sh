#!/bin/sh
# MS6 containment proof — run a stand-in "helper" under the macOS Seatbelt profile and assert it is contained.
# Headless: sandbox-exec denials are silent EPERM, no GUI pop-ups (measured). $1 = profile path.
#
# Asserts: an ALLOWED workspace write succeeds; a WRITE outside the workspace fails closed (and leaks no file);
# a READ of the protected tree is denied; NETWORK outside the allowed set (a public IP) is denied; and a CHILD
# process the helper spawns is equally contained (its out-of-workspace write also fails closed, leaks no file).
set -u
PROFILE="${1:?usage: sandbox_containment_test.sh <profile.sb>}"

WS="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zb-ms6-ws.XXXXXX")" && pwd -P)"      # the one writable tree
PROT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zb-ms6-prot.XXXXXX")" && pwd -P)"  # a tree the agent must not read
DENY="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/zb-ms6-deny.XXXXXX")" && pwd -P)"  # a writable-looking tree OUTSIDE the set
HELPER="$(mktemp "${TMPDIR:-/tmp}/zb-ms6-helper.XXXXXX")"
echo "top-secret-canary" > "$PROT/secret"
trap 'rm -rf "$WS" "$PROT" "$DENY" "$HELPER"' EXIT

# The sandboxed helper (run under sandbox-exec): attempt the matrix and print each result code. A nested
# /bin/sh is the child whose containment we check. Written to a file to keep quoting simple.
cat > "$HELPER" <<'HELPER_EOF'
WS="$1"; PROT="$2"; DENY="$3"
( : > "$WS/ok.txt" ) 2>/dev/null;              echo "ALLOW_WRITE=$?"
( : > "$DENY/x.txt" ) 2>/dev/null;             echo "DENY_WRITE=$?"
( cat "$PROT/secret" ) >/dev/null 2>&1;        echo "DENY_READ=$?"
# Bounded connect so a permissive profile (the red mutant) can't hang: denied -> EPERM fast (rc!=0);
# allowed -> 1.1.1.1:80 (Cloudflare) connects well under the 3s timeout (rc=0, the leak).
/usr/bin/nc -z -G 3 -w 3 1.1.1.1 80 >/dev/null 2>&1; echo "DENY_NET=$?"
/bin/sh -c '( : > "$0/child.txt" ) 2>/dev/null; echo "CHILD_DENY_WRITE=$?"' "$DENY"
HELPER_EOF

OUT="$(/usr/bin/sandbox-exec -f "$PROFILE" -D WORKSPACE="$WS" -D PROTECTED="$PROT" /bin/sh "$HELPER" "$WS" "$PROT" "$DENY" 2>/dev/null)"

fails=0
bad() { echo "  $1" >&2; fails=$((fails + 1)); }
get() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p"; }
aw=$(get ALLOW_WRITE); dw=$(get DENY_WRITE); dr=$(get DENY_READ); dn=$(get DENY_NET); cw=$(get CHILD_DENY_WRITE)

[ "$aw" = "0" ]                       || bad "allowed workspace write did not succeed (rc=${aw:-none}; helper may not have launched)"
[ -f "$WS/ok.txt" ]                   || bad "allowed workspace write produced no file"
{ [ -n "$dw" ] && [ "$dw" != "0" ]; } || bad "a denied write did NOT fail closed (rc=${dw:-none})"
[ ! -e "$DENY/x.txt" ]                || bad "a denied write LEAKED a file outside the workspace"
{ [ -n "$dr" ] && [ "$dr" != "0" ]; } || bad "a protected read was NOT denied (rc=${dr:-none})"
{ [ -n "$dn" ] && [ "$dn" != "0" ]; } || bad "network outside the allowed set was NOT denied (rc=${dn:-none})"
{ [ -n "$cw" ] && [ "$cw" != "0" ]; } || bad "a CHILD process was NOT contained (rc=${cw:-none})"
[ ! -e "$DENY/child.txt" ]            || bad "a child's denied write LEAKED a file"

if [ "$fails" -ne 0 ]; then
  echo "FAIL	ms6-containment"
  printf '    helper output: %s\n' "$(printf '%s' "$OUT" | tr '\n' ' ')" >&2
  exit 1
fi
echo "PASS	ms6-containment"
