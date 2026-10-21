#!/bin/sh
# MS6.4 (plan :1610, :1576-1583) — the GENERATED profiles enforce the egress endpoint policy under real
# sandbox-exec, both arches.
#
#   $1 = a directory holding sandbox_macos.py (the production generator), netd.py (the production egress proxy)
#        and ms6_4_connect_probe.c.
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
[ -f "$DIR/netd.py" ] || { echo "FAIL	ms6-4-egress (netd.py not found in $DIR)"; exit 1; }

TMP=$(mktemp -d /tmp/zb-ms64.XXXXXX)
LPID=""
NPID=""
cleanup() {
    [ -n "$LPID" ] && { kill "$LPID" 2>/dev/null || true; wait "$LPID" 2>/dev/null || true; }
    # the netd holder: on TERM it closes netd's stdin (netd's own clean exit) and reaps it
    [ -n "$NPID" ] && { kill "$NPID" 2>/dev/null || true; wait "$NPID" 2>/dev/null || true; }
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
# The whole classify() table, exactly (RoseCat 7104): every row the probe prints is checked, and the output must be
# exactly these 11 SELFTEST rows, each once, with nothing else, so a dropped, duplicated or unexpected row is red.
mapis EPERM CONNECT-DENIED
mapis EACCES CONNECT-DENIED
mapis ECONNREFUSED CONNECT-REFUSED
mapis EHOSTUNREACH CONNECT-REFUSED
mapis ENETDOWN CONNECT-REFUSED
mapis ENETUNREACH CONNECT-REFUSED
mapis EHOSTDOWN CONNECT-REFUSED
mapis EINVAL CONNECT-ERROR
mapis ENOMEM CONNECT-ERROR
mapis EMFILE CONNECT-ERROR
mapis ETIMEDOUT CONNECT-ERROR
st_names=$(printf '%s\n' "$ST" | awk '$1=="SELFTEST"{print $2}' | sort)
st_want=$(printf '%s\n' EPERM EACCES ECONNREFUSED EHOSTUNREACH ENETDOWN ENETUNREACH EHOSTDOWN EINVAL ENOMEM EMFILE ETIMEDOUT | sort)
st_other=$(printf '%s\n' "$ST" | awk '$1!="SELFTEST"' | grep -c . || true)
if [ "$st_names" = "$st_want" ] && [ "$st_other" -eq 0 ]; then
    echo "  ok   selftest: exactly the 11 classify() rows, each once, nothing else"
else
    echo "  FAIL selftest: the row set is not exactly the 11 expected rows (got: $(printf '%s' "$st_names" | tr '\n' ' '); other lines: $st_other)"
    fails=$((fails+1))
fi

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

# The REAL netd (contract (1); BlueBeaver bead zigBrowser-v9f): started with the --test-port seam on a port free on
# both families, so it holds its 127.0.0.1 listener AND its [::1] reservation (V6ONLY, bound, never listening) for
# the rows below. The holder keeps netd's stdin open; on TERM it closes it (netd's normal exit) and reaps netd.
/usr/bin/python3 -I - "$DIR" "$TMP/netd" <<'PY' &
import os, signal, socket, subprocess, sys, time
d, out = sys.argv[1], sys.argv[2]
def free_both():
    for _ in range(50):
        with socket.socket(socket.AF_INET) as s:
            s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]
        try:
            with socket.socket(socket.AF_INET6) as s6:
                s6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1); s6.bind(("::1", port))
        except OSError:
            continue
        return port
    raise SystemExit("no port free on both families")
port = free_both()
netd = subprocess.Popen(["/usr/bin/python3", "-I", os.path.join(d, "netd.py"), "--test-port", str(port)],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
def stop(*_):
    netd.stdin.close(); netd.wait(10); sys.exit(0)
signal.signal(signal.SIGTERM, stop)
line = netd.stdout.readline().strip()
with open(out + ".tmp", "w") as f:
    f.write("%d %s\n" % (port, line.replace(" ", "_")))
os.rename(out + ".tmp", out)
while netd.poll() is None:
    time.sleep(0.5)
PY
NPID=$!
i=0
while [ ! -s "$TMP/netd" ] && [ "$i" -lt 100 ]; do i=$((i+1)); sleep 0.1; done
[ -s "$TMP/netd" ] || { echo "FAIL	ms6-4-egress (the real netd did not report)"; exit 1; }
read NETD_PORT NETD_LINE < "$TMP/netd"
[ "$NETD_LINE" = "netd_ready_127.0.0.1:$NETD_PORT" ] || {
    echo "FAIL	ms6-4-egress (netd --test-port $NETD_PORT did not come ready: ${NETD_LINE:-<none>})"; exit 1; }
echo "real netd up: 127.0.0.1:$NETD_PORT (+ its [::1]:$NETD_PORT reservation)"
/usr/bin/python3 -I - "$DIR" "$TMP" "$NETD_PORT" <<'PY' || { echo "FAIL	ms6-4-egress (netd profile generation failed)"; exit 1; }
import os, sys, types
d, out, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
sys.path.insert(0, d)
import sandbox_macos
with open(os.path.join(out, "cli-netd.sb"), "w") as f:
    f.write(sandbox_macos.render_profile(egress=types.SimpleNamespace(host="127.0.0.1", port=port),
                                         bridges=(51091, 31337), is_hook=False))
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
#  - IPv6 ::1 TCP at the allowed port is permitted by POLICY (Seatbelt's "localhost" token covers both loopback
#    families and has no v4-only form), so it must reach NOTHING: see the real-netd rows below.
probe cli.sb 127.0.0.1        "$EGRESS" udp CONNECT-DENIED  "cli is DENIED UDP v4 at the egress port"
probe cli.sb ::1              "$EGRESS" udp CONNECT-DENIED  "cli is DENIED UDP v6 at the egress port"
probe cli.sb ::ffff:127.0.0.1 "$EGRESS" tcp CONNECT-DENIED  "cli is DENIED IPv4-mapped IPv6 at the egress port"
probe cli.sb 127.0.0.1        "$DECOY"  tcp CONNECT-DENIED  "cli is DENIED another v4 port (policy, not just refused)"
probe cli.sb ::1              "$DECOY"  tcp CONNECT-DENIED  "cli is DENIED another v6 port (policy, not just refused)"
# The ONE permitted-but-reachless endpoint: [::1] at the ALLOWED port, with the REAL netd holding it (plan contract
# (1)-(2), e05774f; RoseCat 7097). Policy admits it, so it is not DENIED; netd's reservation is bound and never
# listening, and macOS DROPS a SYN at such a socket, so the connect never completes: exactly CONNECT-TIMEOUT.
# Fail-closed classification: CONNECT-OK (a completed connection: a foreign listener) and CONNECT-REFUSED (nothing
# holds ::1: the reservation is missing) are both violations; so is DENIED (the policy changed under us).
probe cli-netd.sb 127.0.0.1 "$NETD_PORT" tcp CONNECT-OK      "cli reaches the real netd's egress listener (positive control)"
probe NONE        ::1       "$NETD_PORT" tcp CONNECT-TIMEOUT "unsandboxed: netd's [::1] reservation alone drops the SYN (the timeout is the reservation, not Seatbelt)"
probe cli-netd.sb ::1       "$NETD_PORT" tcp CONNECT-TIMEOUT "cli's [::1]:<egress port> reaches nothing: netd's reservation holds it (contract (2))"

# HOOK profile: the egress port is denied; the bridges still work.
probe hook.sb 127.0.0.1 "$EGRESS" tcp CONNECT-DENIED "hook is DENIED the egress proxy port"
probe hook.sb 127.0.0.1 51091    tcp CONNECT-OK      "hook reaches bridge 51091"
probe hook.sb 127.0.0.1 31337    tcp CONNECT-OK      "hook reaches bridge 31337"

if [ "$fails" -ne 0 ]; then
    echo "FAIL	ms6-4-egress ($fails assertion(s) failed)"; exit 1
fi
echo "PASS	ms6-4-egress"
