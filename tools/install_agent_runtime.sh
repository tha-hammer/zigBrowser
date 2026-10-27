#!/bin/sh
# Installs the Claude Agent helper runtime that `zigBrowser --agent-setup`
# uses (chat-drawer plan D6, rev 15.2): PREFIX/lib/zigbrowser/agent-host/
#   venv/          the locked dependencies (agent/host/uv.lock, frozen) on /usr/bin/python3
#   zb_agent_host/ the helper package
#   runtime.json   locked dependencies plus the exact helper-package content identity
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
host=$(/usr/bin/python3 -I - "$dest/zb_agent_host" <<'PY'
import hashlib
import sys
from pathlib import Path

root = Path(sys.argv[1])
digest = hashlib.sha256()
for path in sorted(p for p in root.rglob("*") if p.is_file() and not p.is_symlink()):
    rel = path.relative_to(root).as_posix().encode("utf-8")
    data = path.read_bytes()
    digest.update(len(rel).to_bytes(4, "big"))
    digest.update(rel)
    digest.update(len(data).to_bytes(8, "big"))
    digest.update(data)
print(digest.hexdigest())
PY
)
printf '{"lock_sha256": "%s", "host_sha256": "%s"}\n' "$lock" "$host" > "$dest/runtime.json.tmp"
mv "$dest/runtime.json.tmp" "$dest/runtime.json"
echo "$dest"
