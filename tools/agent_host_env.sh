#!/bin/sh
# Builds the Claude Agent helper's venv on /usr/bin/python3 from agent/host/uv.lock (frozen) into
# $XDG_CACHE_HOME/zigbrowser-dev/agent-host/<lockhash>/ and prints its python.
# Needs the network once; the uv cache serves later runs. Gates run this first.
# --check builds nothing: it prints ZB_AGENT_HOST_PYTHON or the cached python, or
# exits 1 when neither exists (the agent tests fail closed, never skip).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project="$root/agent/host"
hash=$(sha256sum "$project/uv.lock" | cut -c1-16)
venv="${XDG_CACHE_HOME:-$HOME/.cache}/zigbrowser-dev/agent-host/$hash"
if [ "${1:-}" = "--check" ]; then
    py="${ZB_AGENT_HOST_PYTHON:-$venv/bin/python}"
    if [ ! -x "$py" ]; then
        echo "zigBrowser: agent helper venv missing at $py: run tools/agent_host_env.sh" >&2
        exit 1
    fi
    echo "$py"
    exit 0
fi
UV_PROJECT_ENVIRONMENT="$venv" uv sync --frozen --no-dev --no-install-project --python /usr/bin/python3 --project "$project" >&2
echo "$venv/bin/python"
