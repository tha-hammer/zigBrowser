#!/usr/bin/env bash
# Product proof: the DMG made by packaging/macos/build-dmg.sh contains one movable universal agent runtime, and its
# native interpreter and bundled Claude CLI execute on both supported Macs. This is an explicit two-Mac test.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
. tests/mac/mac_config.sh
mac_config two
. tests/mac/mac_gate_lib.sh

DMG="$ROOT/zigBrowser_0.2.0_macos.dmg"
INSPECT_DIRS=()
cleanup() {
  local entry host key dir
  local -a SSH
  for entry in "${INSPECT_DIRS[@]+"${INSPECT_DIRS[@]}"}"; do
    IFS=$'\t' read -r host key dir <<<"$entry"
    mapfile -d '' SSH < <(mac_ssh_opts "$key")
    "${SSH[@]}" "$host" /bin/bash -c '
      d=$1
      case "$d" in "$HOME"/zb-dmg-runtime-product-??????) ;; *) exit 2 ;; esac
      [ ! -e "$d/mnt" ] || hdiutil detach "$d/mnt" >/dev/null 2>&1 || true
      find "$d" -depth -delete
    ' bash "$dir" </dev/null >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

ZB_GATE_COMMIT="${ZB_GATE_COMMIT:-$(git rev-parse --verify HEAD^{commit})}" \
  bash packaging/macos/build-dmg.sh
[ -s "$DMG" ] || { echo "FAIL mac-dmg-agent-runtime: build-dmg.sh produced no DMG" >&2; exit 1; }

inspect() { # host key expected-native-arch
  local host=$1 key=$2 native=$3 dir out rc=0
  local -a SSH SCP
  mapfile -d '' SSH < <(mac_ssh_opts "$key")
  mapfile -d '' SCP < <(mac_scp_opts "$key")
  dir=$("${SSH[@]}" "$host" 'mktemp -d "$HOME/zb-dmg-runtime-product-XXXXXX"' </dev/null)
  [[ "$dir" =~ ^/Users/[^/]+/zb-dmg-runtime-product-[A-Za-z0-9]{6}$ ]] \
    || { echo "FAIL mac-dmg-agent-runtime: $host returned an invalid inspection directory" >&2; return 1; }
  INSPECT_DIRS+=("$host"$'\t'"$key"$'\t'"$dir")
  "${SCP[@]}" "$DMG" "$host:$dir/zigBrowser.dmg" >/dev/null
  out=$("${SSH[@]}" "$host" /bin/bash -s "$dir" "$native" <<'REMOTE'
set -euo pipefail
d=$1 native=$2
mkdir "$d/mnt" "$d/home" "$d/tmp"
mounted=0
finish() { [ "$mounted" -eq 0 ] || hdiutil detach "$d/mnt" >/dev/null; }
trap finish EXIT
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$d/mnt" "$d/zigBrowser.dmg" >/dev/null
mounted=1
app="$d/mnt/zigBrowser.app"
agent="$app/Contents/Frameworks/agent-host"
python="$agent/Python.framework/Versions/3.12/bin/python3"
cli="$agent/site-packages/claude_agent_sdk/_bundled/claude"
[ -x "$python" ] || { echo "FAIL mac-dmg-agent-runtime: staged python3 is missing on $native"; exit 1; }
[ -x "$cli" ] || { echo "FAIL mac-dmg-agent-runtime: bundled Claude CLI is missing on $native"; exit 1; }
for item in "$python" "$cli"; do
  arches=$(lipo -archs "$item" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ')
  [ "$arches" = "arm64 x86_64 " ] \
    || { echo "FAIL mac-dmg-agent-runtime: $item holds '${arches% }', not arm64+x86_64"; exit 1; }
done
env -i HOME="$d/home" TMPDIR="$d/tmp" PATH=/usr/bin:/bin "$python" -I - "$agent" <<'PY'
import os
import sys

assert sys.flags.isolated == 1
agent = os.path.realpath(sys.argv[1])
sys.path[:0] = [agent, os.path.join(agent, "site-packages")]
import zb_agent_host
import claude_agent_sdk
print("IMPORT_OK", zb_agent_host.__file__, claude_agent_sdk.__file__)
PY
version=$(env -i HOME="$d/home" TMPDIR="$d/tmp" PATH=/usr/bin:/bin "$cli" --version)
[ -n "$version" ] || { echo "FAIL mac-dmg-agent-runtime: Claude CLI --version was empty on $native"; exit 1; }
printf 'PASS mac-dmg-agent-runtime: %s python -I imports and Claude CLI %s\n' "$native" "$version"
REMOTE
  ) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

failed=0
inspect "$HOST" "$KEY" x86_64 || failed=1
inspect "$ARM_HOST" "$ARM_KEY" arm64 || failed=1
[ "$failed" -eq 0 ] || exit 1
