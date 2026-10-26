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
# The final rows also drive production launch.py. They prove its selected backend denies a live direct target while
# the launched payload reaches the API through real netd, and that the separate sign-in policy reaches exactly its
# API/token hosts. This is the product path: a hand-rendered profile alone cannot hide an unsandboxed launch.
set -eu

DIR="${1:?usage: ms6_4_egress_test.sh <dir-with-sandbox_macos.py-and-probe>}"
[ -f "$DIR/sandbox_macos.py" ] || { echo "FAIL	ms6-4-egress (sandbox_macos.py not found in $DIR)"; exit 1; }
[ -f "$DIR/ms6_4_connect_probe.c" ] || { echo "FAIL	ms6-4-egress (probe source not found in $DIR)"; exit 1; }
[ -f "$DIR/netd.py" ] || { echo "FAIL	ms6-4-egress (netd.py not found in $DIR)"; exit 1; }
for f in __init__.py launch.py options.py platforms.py relay.py sandbox.py seccomp.py; do
    [ -f "$DIR/$f" ] || { echo "FAIL	ms6-4-egress ($f not found in $DIR)"; exit 1; }
done

TMP_ROOT=$(cd "${TMPDIR:-/tmp}" && pwd -P)
TMP=$(mktemp -d "$TMP_ROOT/zb-ms64.XXXXXX")
LPID=""
NPID=""
cleanup() {
    [ -n "$LPID" ] && { kill "$LPID" 2>/dev/null || true; wait "$LPID" 2>/dev/null || true; }
    # the netd holder: on TERM it closes netd's stdin (netd's own clean exit) and reaps it
    [ -n "$NPID" ] && { kill "$NPID" 2>/dev/null || true; wait "$NPID" 2>/dev/null || true; }
    # guarded delete (never an empty/parent path — shared-worktree rule): only our own mktemp dir
    case "$TMP" in "$TMP_ROOT"/zb-ms64.??????) find "${TMP:?}" -mindepth 0 -delete 2>/dev/null || rm -rf "${TMP:?}" ;; esac
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

# Listeners: EGRESS (ephemeral) + DECOY (ephemeral) + the two fixed bridges; one DEAD ephemeral port (bound then
# closed) for the refused≠denied self-check; and fake API/token upstreams that record real netd tunnel bytes.
# Ports are written as "egress decoy dead api token".
/usr/bin/python3 -I - "$TMP/ports" 51091 31337 <<'PY' &
import socket, sys, threading, time
ports_file, bridges = sys.argv[1], [int(p) for p in sys.argv[2:]]
root = __import__("os").path.dirname(ports_file)
servers = []
def bind(port):
    s = socket.create_server(("127.0.0.1", port))
    s.listen(16); servers.append(s); return s.getsockname()[1]
egress = bind(0); decoy = bind(0)
for b in bridges:
    bind(b)  # fixed bridge ports; a leftover owner makes this raise and fails the leg loudly
api = bind(0); token = bind(0)
dead = socket.socket(socket.AF_INET, socket.SOCK_STREAM)  # a port nothing listens on
dead.bind(("127.0.0.1", 0)); dead_port = dead.getsockname()[1]; dead.close()
with open(ports_file, "w") as f:
    f.write("%d %d %d %d %d\n" % (egress, decoy, dead_port, api, token))
def serve(s):
    while True:
        try: c, _ = s.accept(); c.close()
        except OSError: return
def upstream(s, name):
    while True:
        try:
            c, _ = s.accept()
            data = c.recv(16384)
            c.close()
            if data:
                with open(root + "/" + name + "-hits", "ab") as f:
                    f.write(b"hit\n")
        except OSError:
            return
for s in servers[:-2]:
    threading.Thread(target=serve, args=(s,), daemon=True).start()
threading.Thread(target=upstream, args=(servers[-2], "api"), daemon=True).start()
threading.Thread(target=upstream, args=(servers[-1], "token"), daemon=True).start()
while True: time.sleep(3600)
PY
LPID=$!

i=0
while [ ! -s "$TMP/ports" ] && [ "$i" -lt 50 ]; do i=$((i+1)); sleep 0.1; done
[ -s "$TMP/ports" ] || { echo "FAIL	ms6-4-egress (listeners did not come up — a bridge port may be in use)"; exit 1; }
read EGRESS DECOY DEAD API_UPSTREAM TOKEN_UPSTREAM < "$TMP/ports"
echo "listeners up: egress=$EGRESS decoy=$DECOY dead=$DEAD api=$API_UPSTREAM token=$TOKEN_UPSTREAM bridges=51091,31337"

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
# both families, so it holds its 127.0.0.1 listener AND its [::1] reservation (V6ONLY, bound, never listening).
# The holder keeps netd's stdin open; on TERM it closes it (netd's normal exit) and reaps only that child.
cat > "$TMP/net-chat.json" <<'JSON'
{"ports":[],"egress":{"endpoint":"127.0.0.1:3128","allow":["api.anthropic.com"]}}
JSON
cat > "$TMP/net-login.json" <<'JSON'
{"ports":[],"egress":{"endpoint":"127.0.0.1:3128","allow":["api.anthropic.com","platform.claude.com"]}}
JSON
chmod 600 "$TMP/net-chat.json" "$TMP/net-login.json"

start_netd() { # <ready-file> <manifest> [netd test args...]
    ready="$1"; manifest="$2"; shift 2
    /usr/bin/python3 -I - "$DIR" "$ready" "$manifest" "$@" <<'PY' &
import os, signal, socket, subprocess, sys, time
d, out, manifest = sys.argv[1:4]
extra = sys.argv[4:]
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
err = open(out + ".err", "w")
netd = subprocess.Popen(["/usr/bin/python3", "-I", os.path.join(d, "netd.py"), "--test-port", str(port),
                         "--net-manifest", manifest, *extra],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True)
def stop(*_):
    netd.stdin.close(); netd.wait(10); err.close(); sys.exit(0)
signal.signal(signal.SIGTERM, stop)
line = netd.stdout.readline().strip()
with open(out + ".tmp", "w") as f:
    f.write("%d %s\n" % (port, line.replace(" ", "_")))
os.rename(out + ".tmp", out)
while netd.poll() is None:
    time.sleep(0.5)
err.close()
PY
    NPID=$!
    i=0
    while [ ! -s "$ready" ] && [ "$i" -lt 100 ]; do i=$((i+1)); sleep 0.1; done
    [ -s "$ready" ] || { echo "FAIL	ms6-4-egress (the real netd did not report: $(cat "$ready.err" 2>/dev/null || true))"; return 1; }
    read NETD_PORT NETD_LINE < "$ready"
    [ "$NETD_LINE" = "netd_ready_127.0.0.1:$NETD_PORT" ] || {
        echo "FAIL	ms6-4-egress (netd --test-port $NETD_PORT did not come ready: ${NETD_LINE:-<none>})"; return 1; }
    echo "real netd up: 127.0.0.1:$NETD_PORT (+ its [::1]:$NETD_PORT reservation)"
}
stop_netd() {
    [ -n "$NPID" ] || return 0
    kill "$NPID" 2>/dev/null || true
    wait "$NPID" 2>/dev/null || true
    NPID=""
}

start_netd "$TMP/netd-chat" "$TMP/net-chat.json" --test-allow "api.anthropic.com=$API_UPSTREAM"
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

# Product closure: production launch.py chooses the backend and appends the backend's --egress-port to its inner
# payload. The payload is a task-local interpreter stand-in: it makes the same direct socket attempt a compromised
# CLI could make, then performs CONNECT + a real TLS ClientHello through netd. The upstream hit proves that the 200
# response was not merely netd accepting CONNECT: netd validated SNI and opened the real upstream tunnel.
HOST_ROOT="$TMP/host"
HOST_PACKAGE="$HOST_ROOT/zb_agent_host"
AGENT_HOME="$TMP/agent-home"
FAKE_PYTHON="$TMP/venv/bin/python"
mkdir -p "$HOST_PACKAGE" "$AGENT_HOME/workspace" "$AGENT_HOME/scratchpad/tmp" "$AGENT_HOME/runtime" \
    "$(dirname "$FAKE_PYTHON")"
for f in __init__.py launch.py options.py platforms.py relay.py sandbox.py sandbox_macos.py seccomp.py; do
    cp -f "$DIR/$f" "$HOST_PACKAGE/$f"
done
cat > "$HOST_ROOT/claude_agent_sdk.py" <<'PY'
class ClaudeAgentOptions:
    pass
PY
printf '[]\n' > "$AGENT_HOME/runtime/path.json"
cat > "$FAKE_PYTHON" <<PY
#!/usr/bin/python3
import errno, socket, ssl, sys, time

DIRECT_PORT = $DECOY

def direct_verdict():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(2)
    try:
        code = s.connect_ex(("127.0.0.1", DIRECT_PORT))
    except PermissionError as exc:
        code = exc.errno
    except OSError as exc:
        code = exc.errno
    finally:
        s.close()
    if code == 0:
        return "CONNECT-OK"
    if code in (errno.EPERM, errno.EACCES):
        return "CONNECT-DENIED"
    return "CONNECT-ERROR-%d" % code

def client_hello(host):
    ctx = ssl.create_default_context()
    incoming, outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
    obj = ctx.wrap_bio(incoming, outgoing, server_hostname=host)
    try:
        obj.do_handshake()
    except ssl.SSLWantReadError:
        pass
    return outgoing.read()

def through_proxy(port, host):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=3) as s:
            s.sendall(("CONNECT %s:443 HTTP/1.1\r\n\r\n" % host).encode("ascii"))
            data = b""
            while b"\r\n\r\n" not in data and len(data) < 4096:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
            fields = data.split(b" ", 2)
            status = fields[1].decode("ascii") if len(fields) > 1 else "ERROR"
            if status == "200":
                s.sendall(client_hello(host))
                time.sleep(0.2)
            return "HTTP-" + status
    except OSError as exc:
        return "PROXY-ERROR-%s" % (exc.errno if exc.errno is not None else "unknown")

mode = "login" if "login" in sys.argv else "chat"
try:
    i = sys.argv.index("--egress-port")
    egress_port = int(sys.argv[i + 1])
except (ValueError, IndexError):
    print("PRODUCTION-EGRESS-PORT %s MISSING" % mode, flush=True)
    raise SystemExit(0)

print("PRODUCTION-DIRECT %s %s" % (mode, direct_verdict()), flush=True)
print("PRODUCTION-PROXY %s api.anthropic.com %s" %
      (mode, through_proxy(egress_port, "api.anthropic.com")), flush=True)
if mode == "chat":
    print("PRODUCTION-PROXY chat platform.claude.com %s" %
          through_proxy(egress_port, "platform.claude.com"), flush=True)
else:
    print("PRODUCTION-PROXY login platform.claude.com %s" %
          through_proxy(egress_port, "platform.claude.com"), flush=True)
    print("PRODUCTION-PROXY login example.invalid %s" %
          through_proxy(egress_port, "example.invalid"), flush=True)
PY
chmod 700 "$FAKE_PYTHON"

run_launch() { # <chat|login> <egress-port>
    mode="$1"; port="$2"; rc=0
    LAST_LAUNCH_OUT=$(/usr/bin/python3 -I - "$HOST_ROOT" "$AGENT_HOME" "$FAKE_PYTHON" "$mode" "$port" 2>&1 <<'PY'
import sys
root, home, python, mode, port = sys.argv[1:]
sys.path.insert(0, root)
from zb_agent_host import launch
raise SystemExit(launch.main(["--home", home, "--python", python, "--command", mode,
                              "--egress-port", port]))
PY
    ) || rc=$?
    printf '%s\n' "$LAST_LAUNCH_OUT"
    if [ "$rc" -ne 0 ]; then
        echo "  FAIL production launch $mode exited $rc"; fails=$((fails+1))
    fi
}

expect_launch_line() { # <output> <exact-line> <label>
    launch_output="$1"; wanted="$2"; label="$3"
    if printf '%s\n' "$launch_output" | grep -F -x -q "$wanted"; then
        echo "  ok   $label"
    else
        got=$(printf '%s\n' "$launch_output" | grep -F "${wanted% *}" | head -1 || true)
        echo "  FAIL $label -> ${got:-<missing>}, wanted $wanted"; fails=$((fails+1))
    fi
}

wait_hits() { # <file> <minimum>
    hit_file="$1"; minimum="$2"; n=0; i=0
    while [ "$i" -lt 30 ]; do
        n=$([ -f "$hit_file" ] && wc -l < "$hit_file" || echo 0)
        [ "$n" -ge "$minimum" ] && return 0
        i=$((i+1)); sleep 0.1
    done
    return 1
}

run_launch chat "$NETD_PORT"
chat_out="$LAST_LAUNCH_OUT"
expect_launch_line "$chat_out" "PRODUCTION-DIRECT chat CONNECT-DENIED" \
    "production-launched chat helper is DENIED direct outbound"
expect_launch_line "$chat_out" "PRODUCTION-PROXY chat api.anthropic.com HTTP-200" \
    "production-launched chat helper reaches api.anthropic.com through netd"
expect_launch_line "$chat_out" "PRODUCTION-PROXY chat platform.claude.com HTTP-403" \
    "chat netd refuses a sign-in-only host"
if wait_hits "$TMP/api-hits" 1; then
    echo "  ok   chat netd opened the fake API upstream after CONNECT/SNI"
else
    echo "  FAIL chat netd never opened the fake API upstream"; fails=$((fails+1))
fi

stop_netd
start_netd "$TMP/netd-login" "$TMP/net-login.json" \
    --test-allow "api.anthropic.com=$API_UPSTREAM" --test-allow "platform.claude.com=$TOKEN_UPSTREAM"
run_launch login "$NETD_PORT"
login_out="$LAST_LAUNCH_OUT"
expect_launch_line "$login_out" "PRODUCTION-DIRECT login CONNECT-DENIED" \
    "production-launched sign-in helper is DENIED direct outbound"
expect_launch_line "$login_out" "PRODUCTION-PROXY login api.anthropic.com HTTP-200" \
    "sign-in reaches api.anthropic.com through its netd"
expect_launch_line "$login_out" "PRODUCTION-PROXY login platform.claude.com HTTP-200" \
    "sign-in reaches platform.claude.com through its netd"
expect_launch_line "$login_out" "PRODUCTION-PROXY login example.invalid HTTP-403" \
    "sign-in netd refuses a non-allowlisted host"
if wait_hits "$TMP/api-hits" 2 && wait_hits "$TMP/token-hits" 1; then
    echo "  ok   sign-in netd opened both allowlisted upstream tunnels"
else
    echo "  FAIL sign-in netd did not open both allowlisted upstream tunnels"; fails=$((fails+1))
fi

if [ "$fails" -ne 0 ]; then
    echo "FAIL	ms6-4-egress ($fails assertion(s) failed)"; exit 1
fi
echo "PASS	ms6-4-egress"
