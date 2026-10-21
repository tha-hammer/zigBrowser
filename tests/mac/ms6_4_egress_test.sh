#!/bin/sh
# MS6.4 (plan :1610, :1576-1583) — the GENERATED profiles enforce the egress endpoint policy under real
# sandbox-exec, both arches.
#
#   $1 = a directory holding sandbox_macos.py (the production generator) + ms6_4_connect_probe.c.
#
# The SandboxBackend egress capability (rev 6) pins a TCP 127.0.0.1:<egress_port> plus the two canonical bridges
# :51091/:31337; a HOOK gets the bridges but CANNOT reach the egress port. This gate proves the GENERATED
# cli/hook profiles enforce exactly that endpoint SHAPE under real sandbox-exec:
#   - probe self-check (unsandboxed): a dead port is CONNECT-REFUSED, a live port CONNECT-OK — so REFUSED is
#     never confused with a Seatbelt DENIED (the discriminating branch);
#   - cli profile: egress port OK; both bridges OK; a LIVE decoy loopback port DENIED; a public IP DENIED;
#   - endpoint SHAPE at the SAME allowed numeric port: IPv6 ::1, IPv4-mapped IPv6, and UDP are all DENIED
#     (the contract is TCP/IPv4 only — if Seatbelt granted any of them the renderer would be too wide);
#   - hook profile: the egress port DENIED while both bridges still connect.
# A live listener sits on every must-be-denied loopback target so a Seatbelt EPERM is never a false "refused".
# (Sandbox endpoint-enforcement half; the full HTTPS_PROXY traversal through netd is MS6.4b, needs launch.py.)
set -eu

DIR="${1:?usage: ms6_4_egress_test.sh <dir-with-sandbox_macos.py-and-probe>}"
[ -f "$DIR/sandbox_macos.py" ] || { echo "FAIL	ms6-4-egress (sandbox_macos.py not found in $DIR)"; exit 1; }
[ -f "$DIR/ms6_4_connect_probe.c" ] || { echo "FAIL	ms6-4-egress (probe source not found in $DIR)"; exit 1; }

TMP=$(mktemp -d /tmp/zb-ms64.XXXXXX)
LPID=""
cleanup() {
    [ -n "$LPID" ] && { kill "$LPID" 2>/dev/null || true; wait "$LPID" 2>/dev/null || true; }
    # guarded delete (never an empty/parent path — shared-worktree rule): only our own mktemp dir
    case "$TMP" in /tmp/zb-ms64.*) find "${TMP:?}" -mindepth 0 -delete 2>/dev/null || rm -rf "${TMP:?}" ;; esac
}
trap cleanup EXIT
SCRATCH="$TMP/scratch"; mkdir -p "$SCRATCH"

PROBE="$TMP/probe"
xcrun clang -std=c11 -Wall -Wextra -Werror -o "$PROBE" "$DIR/ms6_4_connect_probe.c" 2>"$TMP/cc.err" || {
    echo "FAIL	ms6-4-egress (probe build failed)"; cat "$TMP/cc.err"; exit 1; }

fails=0
# 7046 #2: the probe's verdict mapping is deterministic — a syscall/observation failure must map to ERROR,
# never DENIED/OK; only EPERM/EACCES are DENIED; the unreachable set is REFUSED. `selftest` exercises classify().
ST=$("$PROBE" selftest 2>&1)
mapis() { # <errno-name> <wanted-tag>
    got=$(printf '%s\n' "$ST" | awk -v n="$1" '$1=="SELFTEST"&&$2==n{print $3; exit}')
    if [ "$got" = "$2" ]; then echo "  ok   selftest $1 -> $got"
    else echo "  FAIL selftest $1 -> ${got:-<none>}, wanted $2"; fails=$((fails+1)); fi
}
mapis EPERM CONNECT-DENIED
mapis EACCES CONNECT-DENIED
mapis ECONNREFUSED CONNECT-REFUSED
mapis EHOSTUNREACH CONNECT-REFUSED
mapis ENETUNREACH CONNECT-REFUSED
mapis EINVAL CONNECT-ERROR
mapis ENOMEM CONNECT-ERROR
mapis EMFILE CONNECT-ERROR
mapis ETIMEDOUT CONNECT-ERROR

# Listeners: EGRESS (ephemeral) + DECOY (ephemeral) + the two fixed bridges; and one DEAD ephemeral port (bound
# then closed) for the refused≠denied self-check. Ports written to $TMP/ports as "egress decoy dead".
/usr/bin/python3 -I - "$TMP/ports" 51091 31337 <<'PY' &
import socket, sys, threading, time
ports_file, bridges = sys.argv[1], [int(p) for p in sys.argv[2:]]
servers = []
def bind(port):
    s = socket.create_server(("127.0.0.1", port))
    s.listen(16); servers.append(s); return s.getsockname()[1]
egress = bind(0); decoy = bind(0)
for b in bridges:
    bind(b)  # fixed bridge ports; a leftover owner makes this raise and fails the leg loudly
dead = socket.socket(socket.AF_INET, socket.SOCK_STREAM)  # a port nothing listens on
dead.bind(("127.0.0.1", 0)); dead_port = dead.getsockname()[1]; dead.close()
with open(ports_file, "w") as f:
    f.write("%d %d %d\n" % (egress, decoy, dead_port))
def serve(s):
    while True:
        try: c, _ = s.accept(); c.close()
        except OSError: return
for s in servers:
    threading.Thread(target=serve, args=(s,), daemon=True).start()
while True: time.sleep(3600)
PY
LPID=$!

i=0
while [ ! -s "$TMP/ports" ] && [ "$i" -lt 50 ]; do i=$((i+1)); sleep 0.1; done
[ -s "$TMP/ports" ] || { echo "FAIL	ms6-4-egress (listeners did not come up — a bridge port may be in use)"; exit 1; }
read EGRESS DECOY DEAD < "$TMP/ports"
echo "listeners up: egress=$EGRESS decoy=$DECOY dead=$DEAD bridges=51091,31337"

/usr/bin/python3 -I - "$DIR" "$TMP" "$EGRESS" <<'PY' || { echo "FAIL	ms6-4-egress (profile generation failed)"; exit 1; }
import os, sys, types
d, out, egress = sys.argv[1], sys.argv[2], int(sys.argv[3])
sys.path.insert(0, d)
import sandbox_macos
ep = types.SimpleNamespace(host="127.0.0.1", port=egress)
with open(os.path.join(out, "cli.sb"), "w") as f:
    f.write(sandbox_macos.render_profile(egress=ep, bridges=(51091, 31337), is_hook=False))
with open(os.path.join(out, "hook.sb"), "w") as f:
    f.write(sandbox_macos.render_profile(egress=None, bridges=(51091, 31337), is_hook=True))
PY

# probe <profile|NONE> <ip> <port> <proto> <want-tag> <label>  (fails is initialized above, with the selftest)
probe() {
    prof="$1"; ip="$2"; port="$3"; proto="$4"; want="$5"; label="$6"
    if [ "$prof" = NONE ]; then
        out=$("$PROBE" "$ip" "$port" 1500 "$proto" 2>&1) || true
    else
        out=$(/usr/bin/sandbox-exec -f "$TMP/$prof" -D SCRATCHPAD="$SCRATCH" "$PROBE" "$ip" "$port" 1500 "$proto" 2>&1) || true
    fi
    got=$(printf '%s' "$out" | awk '{print $1; exit}')
    if [ "$got" = "$want" ]; then
        echo "  ok   $label ($prof $proto $ip:$port -> $got)"
    else
        echo "  FAIL $label ($prof $proto $ip:$port -> ${out:-<no output>}, wanted $want)"; fails=$((fails+1))
    fi
}

# Probe self-check: REFUSED (dead port) and OK (live port) must NOT be reported as DENIED.
probe NONE 127.0.0.1 "$DEAD"   tcp CONNECT-REFUSED "probe self-check: a dead port is REFUSED, not DENIED"
probe NONE 127.0.0.1 "$EGRESS" tcp CONNECT-OK      "probe self-check: a live port is OK"
# Deadline branch (7046 #2): an unsandboxed connect to TEST-NET-1 (RFC 5737, unroutable) neither completes nor is
# denied; the non-blocking deadline must fire as CONNECT-TIMEOUT, not OK/DENIED. Short 500 ms budget.
to=$("$PROBE" 192.0.2.1 80 500 tcp 2>&1) || true
toget=$(printf '%s' "$to" | awk '{print $1; exit}')
case "$toget" in
    CONNECT-TIMEOUT) echo "  ok   probe self-check: an unroutable address TIMES OUT (deadline branch)" ;;
    CONNECT-REFUSED|CONNECT-ERROR) echo "  ok   probe self-check: an unroutable address is $toget (not OK/DENIED — acceptable)" ;;
    *) echo "  FAIL probe self-check: unroutable 192.0.2.1 -> ${to:-<none>}, wanted TIMEOUT (or REFUSED/ERROR)"; fails=$((fails+1)) ;;
esac

# CLI profile: egress + both bridges reachable (TCP/IPv4); decoy + public denied.
probe cli.sb 127.0.0.1 "$EGRESS" tcp CONNECT-OK     "cli reaches the egress port"
probe cli.sb 127.0.0.1 51091    tcp CONNECT-OK     "cli reaches bridge 51091"
probe cli.sb 127.0.0.1 31337    tcp CONNECT-OK     "cli reaches bridge 31337"
probe cli.sb 127.0.0.1 "$DECOY" tcp CONNECT-DENIED "cli is DENIED a live decoy loopback port"
probe cli.sb 1.1.1.1   443      tcp CONNECT-DENIED "cli is DENIED a public IP"

# Endpoint SHAPE at the SAME allowed numeric port (measured both arches, RoseCat 7039):
#  - UDP is DENIED: the rule is (remote tcp ...), so UDP at the port is refused by policy (EPERM). A mutant
#    back to (remote ip ...) re-opens UDP and reds this line.
#  - IPv4-mapped IPv6 is DENIED.
#  - IPv6 ::1 TCP is REFUSED, not DENIED: Seatbelt's "localhost" token covers BOTH loopback families and has no
#    v4-only form (the 127.0.0.1 literal is a parse error), so ::1:<port> TCP is permitted by POLICY — but it is
#    unreachable (netd and the bridges bind 127.0.0.1 only, so nothing listens on ::1): REFUSED proves the CLI
#    reaches no v6 endpoint. This is the enforced shape: loopback TCP:<port>, v4-reachable only.
probe cli.sb 127.0.0.1        "$EGRESS" udp CONNECT-DENIED  "cli is DENIED UDP v4 at the egress port"
probe cli.sb ::1              "$EGRESS" udp CONNECT-DENIED  "cli is DENIED UDP v6 at the egress port"
probe cli.sb ::ffff:127.0.0.1 "$EGRESS" tcp CONNECT-DENIED  "cli is DENIED IPv4-mapped IPv6 at the egress port"
probe cli.sb 127.0.0.1        "$DECOY"  tcp CONNECT-DENIED  "cli is DENIED another v4 port (policy, not just refused)"
probe cli.sb ::1              "$DECOY"  tcp CONNECT-DENIED  "cli is DENIED another v6 port (policy, not just refused)"
# The ONE permitted-but-reachless endpoint: ::1 at the ALLOWED port. Policy admits loopback TCP (both families;
# Seatbelt has no v4-only token), so this is not DENIED — but it must reach nothing. Durability is netd's job:
# netd RESERVES [::1]:<port> (IPV6_V6ONLY, non-listening) and fails startup if it can't, so a squatter can never
# own it (RoseCat 7071; BlueBeaver bead zigBrowser-v9f, tested in the netd gate). Here, with no listener, REFUSED.
probe cli.sb ::1              "$EGRESS" tcp CONNECT-REFUSED "cli reaches no v6 listener at the egress port (netd reserves it; v4-only reachable)"

# HOOK profile: the egress port is denied; the bridges still work.
probe hook.sb 127.0.0.1 "$EGRESS" tcp CONNECT-DENIED "hook is DENIED the egress proxy port"
probe hook.sb 127.0.0.1 51091    tcp CONNECT-OK      "hook reaches bridge 51091"
probe hook.sb 127.0.0.1 31337    tcp CONNECT-OK      "hook reaches bridge 31337"

if [ "$fails" -ne 0 ]; then
    echo "FAIL	ms6-4-egress ($fails assertion(s) failed)"; exit 1
fi
echo "PASS	ms6-4-egress"
