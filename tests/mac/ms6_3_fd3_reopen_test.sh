#!/bin/sh
# MS5.3/MS6.3 product test. The production macOS Keychain-to-helper boundary
# creates the unnamed socket, maps it explicitly to child fd 3, and spawns
# sandbox-exec. The child reopens /dev/fd/3 like the Claude CLI. No token is
# accepted in argv, env, output, or the generated profile.
set -eu

ROOT="${1:?usage: ms6_3_fd3_reopen_test.sh <repository-root>}"
for file in \
  "$ROOT/agent/host/zb_agent_host/sandbox_macos.py" \
  "$ROOT/src/agent_secrets_mac.h" "$ROOT/src/agent_secrets_mac.m" \
  "$ROOT/src/agent_token_fd_mac.h" "$ROOT/src/agent_token_fd_mac.c" \
  "$ROOT/src/agent_spawn_posix.h" "$ROOT/src/agent_spawn_posix.c" \
  "$ROOT/tests/mac/ms6_3_fd3_reopen.c"
do
  [ -f "$file" ] || { echo "FAIL\tms6-3-product-channel\tmissing product input"; exit 1; }
done

TMP=$(mktemp -d /tmp/zb-ms63.XXXXXX)
cleanup() {
  case "$TMP" in /tmp/zb-ms63.??????) rm -rf -- "${TMP:?}" ;; esac
}
trap cleanup EXIT
SCRATCH="$TMP/scratch"
mkdir -p "$SCRATCH"
SCRATCH=$(cd "$SCRATCH" && pwd -P)
DRIVER="$TMP/ms6_3_product"

xcrun clang -fobjc-arc -std=gnu11 -Wno-deprecated-declarations -I "$ROOT/src" \
  "$ROOT/tests/mac/ms6_3_fd3_reopen.c" \
  "$ROOT/src/agent_secrets_mac.m" "$ROOT/src/agent_token_fd_mac.c" "$ROOT/src/agent_spawn_posix.c" \
  -framework Security -framework Foundation -o "$DRIVER" 2>"$TMP/cc.err" || {
    echo "FAIL\tms6-3-product-channel\tproduct driver build failed"
    cat "$TMP/cc.err"
    exit 1
  }

python3 - "$ROOT/agent/host/zb_agent_host" "$TMP" <<'PY'
import os, sys, types
product, output = sys.argv[1], sys.argv[2]
sys.path.insert(0, product)
import sandbox_macos
endpoint = types.SimpleNamespace(host="127.0.0.1", port=52346)
with open(os.path.join(output, "cli.sb"), "w", encoding="utf-8") as stream:
    stream.write(sandbox_macos.render_profile(
        egress=endpoint, bridges=(51091, 31337), is_hook=False))
PY

cat >"$TMP/deny.sb" <<EOF
(version 1)
(deny default)
(allow process-fork)
(allow process-exec*)
(allow file-read*)
(deny file-read* (subpath "/dev/fd"))
EOF

"$DRIVER" --parent none "$SCRATCH"
"$DRIVER" --parent "$TMP/cli.sb" "$SCRATCH"
"$DRIVER" --parent "$TMP/deny.sb" "$SCRATCH"
echo "PASS\tms6-3-fd3-reopen-product\tKeychain-to-sandbox-fd3"
