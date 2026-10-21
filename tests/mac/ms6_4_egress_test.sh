#!/bin/sh
# MS6.4 (plan :1610) — the GENERATED profiles enforce the egress endpoint policy under real sandbox-exec, both arches.
#
#   $1 = a directory holding sandbox_macos.py (the production generator) + ms6_4_connect_probe.c.
#
# The SandboxBackend egress capability (rev 6): the CLI/helper reach egress ONLY at the backend's per-session
# 127.0.0.1:<egress_port>, plus the two canonical bridges :51091/:31337; a HOOK (its own profile) gets the bridges
# but CANNOT reach the egress port. This gate proves the GENERATED cli/hook profiles enforce exactly that:
#   - under the cli profile: connect to the egress port OK; both bridges OK; a live DECOY loopback port DENIED;
#     a public IP DENIED (same-port OK-vs-DENIED across profiles proves it is the profile, not host reachability);
#   - under the hook profile: the egress port is DENIED while both bridges still connect  <-- the key MS6.4 rule.
# A live listener sits on every "must be denied" loopback target, so a Seatbelt EPERM is never a false "refused".
# (This is the sandbox endpoint-enforcement half; the full HTTPS_PROXY traversal through netd to the fake API is
#  MS6.4b, which needs launch.py to thread the proxy env — tracked separately.)
set -u

DIR="${1:?usage: ms6_4_egress_test.sh <dir-with-sandbox_macos.py-and-probe>}"
[ -f "$DIR/sandbox_macos.py" ] || { echo "FAIL	ms6-4-egress (sandbox_macos.py not found in $DIR)"; exit 1; }
[ -f "$DIR/ms6_4_connect_probe.c" ] || { echo "FAIL	ms6-4-egress (probe source not found in $DIR)"; exit 1; }

TMP=$(mktemp -d /tmp/zb-ms64.XXXXXX)
LPID=""
cleanup() { [ -n "$LPID" ] && kill "$LPID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
SCRATCH="$TMP/scratch"; mkdir -p "$SCRATCH"

PROBE="$TMP/probe"
xcrun clang -o "$PROBE" "$DIR/ms6_4_connect_probe.c" 2>"$TMP/cc.err" || {
    echo "FAIL	ms6-4-egress (probe build failed)"; cat "$TMP/cc.err"; exit 1; }

# Listeners: an EGRESS stand-in on an ephemeral port, a DECOY on an ephemeral port, and the two fixed bridges.
# The egress/decoy ephemeral ports are written to $TMP/ports; the python then serves accept loops until killed.
/usr/bin/python3 -I - "$TMP/ports" 51091 31337 <<'PY' &
import socket, sys, threading
ports_file, bridges = sys.argv[1], [int(p) for p in sys.argv[2:]]
servers = []
def bind(port):
    s = socket.create_server(("127.0.0.1", port))
    s.listen(16)
    servers.append(s)
    return s.getsockname()[1]
egress = bind(0)
decoy = bind(0)
for b in bridges:
    bind(b)  # fixed bridge ports; a leftover owner would make this raise and fail the leg loudly
with open(ports_file, "w") as f:
    f.write("%d %d\n" % (egress, decoy))
def serve(s):
    while True:
        try:
            c, _ = s.accept(); c.close()
        except OSError:
            return
for s in servers:
    threading.Thread(target=serve, args=(s,), daemon=True).start()
import time
while True:
    time.sleep(3600)
PY
LPID=$!

# wait for the ports file (up to ~5 s)
i=0
while [ ! -s "$TMP/ports" ] && [ "$i" -lt 50 ]; do i=$((i+1)); sleep 0.1; done
[ -s "$TMP/ports" ] || { echo "FAIL	ms6-4-egress (listeners did not come up — a bridge port may be in use)"; exit 1; }
read EGRESS DECOY < "$TMP/ports"
echo "listeners up: egress=$EGRESS decoy=$DECOY bridges=51091,31337"

# Generate cli (egress=EGRESS) + hook (no egress) profiles from the PRODUCTION generator.
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

fails=0
# probe <profile> <ip> <port> <expected-tag> <label>
probe() {
    prof="$1"; ip="$2"; port="$3"; want="$4"; label="$5"
    out=$(/usr/bin/sandbox-exec -f "$TMP/$prof" -D SCRATCHPAD="$SCRATCH" "$PROBE" "$ip" "$port" 2>&1) || true
    got=$(printf '%s' "$out" | awk '{print $1; exit}')
    if [ "$got" = "$want" ]; then
        echo "  ok   $label ($prof $ip:$port -> $got)"
    else
        echo "  FAIL $label ($prof $ip:$port -> ${out:-<no output>}, wanted $want)"; fails=$((fails+1))
    fi
}

# CLI profile: egress + both bridges reachable; decoy + public denied.
probe cli.sb 127.0.0.1 "$EGRESS" CONNECT-OK     "cli reaches the egress port"
probe cli.sb 127.0.0.1 51091    CONNECT-OK     "cli reaches bridge 51091"
probe cli.sb 127.0.0.1 31337    CONNECT-OK     "cli reaches bridge 31337"
probe cli.sb 127.0.0.1 "$DECOY" CONNECT-DENIED "cli is DENIED a live decoy loopback port"
probe cli.sb 1.1.1.1   443      CONNECT-DENIED "cli is DENIED a public IP"

# HOOK profile: the egress port is denied; the bridges still work.
probe hook.sb 127.0.0.1 "$EGRESS" CONNECT-DENIED "hook is DENIED the egress proxy port"
probe hook.sb 127.0.0.1 51091    CONNECT-OK      "hook reaches bridge 51091"
probe hook.sb 127.0.0.1 31337    CONNECT-OK      "hook reaches bridge 31337"

if [ "$fails" -ne 0 ]; then
    echo "FAIL	ms6-4-egress ($fails assertion(s) failed)"; exit 1
fi
echo "PASS	ms6-4-egress"
