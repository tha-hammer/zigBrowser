#!/bin/sh
# MS6 — the GENERATED Seatbelt profiles parse and enforce under real sandbox-exec (both Macs).
#
#   $1 = a directory holding sandbox_macos.py (the production generator) + ms6_1_procinfo_probe.c.
#
# Proves the profiles sandbox_macos emits — not a hand-written one — are sandbox-exec-valid AND enforce:
#   - a CLI stand-in carries a CANARY in its argv; the MS6.1 probe (procargs2/task_for_pid/proc_pidpath) runs
#     under the GENERATED cli and hook profiles and must be CONTAINED (token isolation holds);
#   - a positive control (unsandboxed) must breach, so a green is the profile's doing, not a TCC artifact;
#   - the GENERATED setup profile parses and runs a trivial command (no network — deny-default).
# This is the both-Mac gate that must pass before any production backend consumes the generated profiles.
set -eu

DIR="${1:?usage: ms6_generated_profile_test.sh <dir-with-sandbox_macos.py-and-probe>}"
[ -f "$DIR/sandbox_macos.py" ] || { echo "FAIL	ms6-generated-profiles (sandbox_macos.py not found in $DIR)"; exit 1; }
[ -f "$DIR/ms6_1_procinfo_probe.c" ] || { echo "FAIL	ms6-generated-profiles (probe source not found in $DIR)"; exit 1; }
DIR=$(cd "$DIR" && pwd -P)

TMP=$(mktemp -d "$DIR/zb-ms6gen.XXXXXX")
TGT=""
cleanup() {
    if [ -n "$TGT" ]; then
        kill "$TGT" 2>/dev/null || true
        wait "$TGT" 2>/dev/null || true
    fi
    case "$TMP" in "$DIR"/zb-ms6gen.??????) rm -rf -- "${TMP:?}" ;; esac
}
trap cleanup EXIT

# Generate the three profiles from the PRODUCTION generator (a SimpleNamespace stands in for sandbox.Endpoint,
# which render_profile only duck-types for .host/.port).
python3 - "$DIR" "$TMP" <<'PY'
import os, sys, types
d, out = sys.argv[1], sys.argv[2]
sys.path.insert(0, d)
import sandbox_macos
ep = types.SimpleNamespace(host="127.0.0.1", port=52346)
with open(os.path.join(out, "cli.sb"), "w") as f:
    f.write(sandbox_macos.render_profile(egress=ep, bridges=(51091, 31337), is_hook=False))
with open(os.path.join(out, "hook.sb"), "w") as f:
    f.write(sandbox_macos.render_profile(egress=None, bridges=(51091, 31337), is_hook=True))
with open(os.path.join(out, "setup.sb"), "w") as f:
    f.write(sandbox_macos.render_setup_profile())
PY

PROBE="$TMP/probe"
xcrun clang -o "$PROBE" "$DIR/ms6_1_procinfo_probe.c" 2>"$TMP/cc.err" || {
    echo "FAIL	ms6-generated-profiles (probe build failed)"; cat "$TMP/cc.err"; exit 1; }

SCRATCH="$TMP/scratch"; mkdir -p "$SCRATCH"
CANARY="zb-gen-$(/usr/bin/uuidgen | tr -d - | tr 'A-Z' 'a-z')"
/usr/bin/perl -e 'sleep 100000' "$CANARY" &
TGT=$!
sleep 0.4

# Positive control: unsandboxed must breach (so a green under a profile is the profile's doing).
"$PROBE" "$TGT" "$CANARY" > "$TMP/pc.out" 2>&1 || true
grep -q "procargs2: rc=0 canary=FOUND" "$TMP/pc.out" || {
    echo "FAIL	ms6-generated-positive-control (unsandboxed did not expose the canary — vacuous)"
    sed 's/^/  pc| /' "$TMP/pc.out"; exit 1; }
echo "positive control: BREACH (canary exposed unsandboxed)"

# The GENERATED cli + hook profiles must each CONTAIN the token.
for prof in cli hook; do
    /usr/bin/sandbox-exec -f "$TMP/$prof.sb" -D SCRATCHPAD="$SCRATCH" "$PROBE" "$TGT" "$CANARY" > "$TMP/$prof.out" 2>&1 || true
    if grep -q "RESULT: BREACH" "$TMP/$prof.out"; then
        echo "FAIL	ms6-generated-$prof (the GENERATED profile LEAKED the token)"; sed "s/^/  $prof| /" "$TMP/$prof.out"; exit 1
    fi
    grep -q "RESULT: CONTAINED" "$TMP/$prof.out" || {
        echo "FAIL	ms6-generated-$prof (no verdict — did the generated profile parse under sandbox-exec?)"
        sed "s/^/  $prof| /" "$TMP/$prof.out"; exit 1; }
    echo "generated $prof: CONTAINED"
done

# The GENERATED setup profile must parse and run a trivial command (no network; deny-default).
/usr/bin/sandbox-exec -f "$TMP/setup.sb" -D SCRATCHPAD="$SCRATCH" /usr/bin/true || {
    echo "FAIL	ms6-generated-setup (the generated setup profile did not parse/run)"; exit 1; }
echo "generated setup: parses + runs"

# 7045 regression guard: the real runtime (Python) must START under EVERY generated profile. (deny process-info*)
# alone SIGILLs Python at startup (self code-signature / exec-path introspection); (allow process-info* (target
# self)) fixes it while cross-process introspection stays denied (proven CONTAINED above). A regression that drops
# the self-allow reds here with exit 132 (SIGILL).
for prof in setup cli hook; do
    out=$(/usr/bin/sandbox-exec -f "$TMP/$prof.sb" -D SCRATCHPAD="$SCRATCH" /usr/bin/python3 -c 'print("PYOK")' 2>&1)
    rc=$?
    if [ "$out" != "PYOK" ]; then
        echo "FAIL	ms6-generated-$prof-python (the real runtime did not start under the generated profile — 7045 SIGILL? rc=$rc out=${out:-<none>})"; exit 1
    fi
    echo "generated $prof: python runtime starts (no 7045 SIGILL)"
done

# MS6.7 red/green: every generated profile must still read an immutable system file, but must not read private
# user-home material. The canaries live only inside this run's owned work directory; HOME points at that stand-in,
# so the two paths exercise the exact ~/.ssh and ~/Documents boundary without touching the Mac user's real files.
USER_HOME="$TMP/user-home"
mkdir -p "$USER_HOME/.ssh" "$USER_HOME/Documents"
printf '%s\n' 'zb-ms6-private-ssh' > "$USER_HOME/.ssh/id_canary"
printf '%s\n' 'zb-ms6-private-documents' > "$USER_HOME/Documents/canary.txt"
for prof in setup cli hook; do
    /usr/bin/sandbox-exec -f "$TMP/$prof.sb" -D SCRATCHPAD="$SCRATCH" /bin/cat /etc/hosts > "$TMP/$prof.system" 2>&1 || {
        echo "FAIL	ms6-generated-$prof-system-read (/etc/hosts must remain readable)"; exit 1; }
    for rel in .ssh/id_canary Documents/canary.txt; do
        : > "$TMP/$prof.sensitive.out"
        : > "$TMP/$prof.sensitive.err"
        if HOME="$USER_HOME" /usr/bin/sandbox-exec -f "$TMP/$prof.sb" -D SCRATCHPAD="$SCRATCH" \
                /bin/cat "$USER_HOME/$rel" > "$TMP/$prof.sensitive.out" 2> "$TMP/$prof.sensitive.err"; then
            echo "FAIL	ms6-generated-$prof-sensitive-read (~/$rel is readable under the generated profile)"
            exit 1
        fi
        [ ! -s "$TMP/$prof.sensitive.out" ] && grep -qi 'operation not permitted' "$TMP/$prof.sensitive.err" || {
            echo "FAIL	ms6-generated-$prof-sensitive-read (~/$rel did not fail with Seatbelt EPERM)"; exit 1; }
        echo "generated $prof: ~/$rel DENIED"
    done
done

echo "PASS	ms6-generated-profiles"
