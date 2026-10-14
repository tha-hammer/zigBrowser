#!/bin/sh
# Installs the Claude Agent helper runtime that `zigBrowser --agent-setup`
# uses (chat-drawer plan D6, rev 15.2): PREFIX/lib/zigbrowser/agent-host/
#   venv/          the locked dependencies (agent/host/uv.lock, frozen) on /usr/bin/python3
#   zb_agent_host/ the helper package
#   runtime.json   {"lock_sha256": ...}: setup records it; a later change is detected
# Usage: tools/install_agent_runtime.sh PREFIX   (needs the network once; the uv cache serves later runs)
set -eu
[ $# -eq 1 ] || { echo "usage: $0 PREFIX" >&2; exit 2; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project="$root/agent/host"
dest="$1/lib/zigbrowser/agent-host"
mkdir -p "$dest"
UV_PROJECT_ENVIRONMENT="$dest/venv" uv sync --frozen --no-dev --no-install-project --python /usr/bin/python3 --project "$project" >&2
if [ -d "$dest/zb_agent_host" ]; then find "$dest/zb_agent_host" -delete; fi
cp -R "$project/zb_agent_host" "$dest/zb_agent_host"
find "$dest/zb_agent_host" -name __pycache__ -type d -prune -exec find {} -delete \;
lock=$(sha256sum "$project/uv.lock" | cut -c1-64)
printf '{"lock_sha256": "%s"}\n' "$lock" > "$dest/runtime.json.tmp"
mv "$dest/runtime.json.tmp" "$dest/runtime.json"
echo "$dest"
