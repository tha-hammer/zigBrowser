#!/usr/bin/env bash
# Product proof: an app installed from the real DMG provisions its agent home
# from both a fresh private HOME and a HOME that already has ~/.claude.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
. tests/mac/mac_config.sh
mac_config two
. tests/mac/mac_gate_lib.sh

DMG=${ZB_DMG_PATH:-$ROOT/zigBrowser_0.2.0_macos.dmg}
[ -s "$DMG" ] || { echo "FAIL mac-dmg-agent-setup: DMG is missing: $DMG" >&2; exit 1; }

RUNS=()
cleanup() {
  local entry host key dir
  local -a SSH
  for entry in "${RUNS[@]+"${RUNS[@]}"}"; do
    IFS=$'\t' read -r host key dir <<<"$entry"
    mapfile -d '' SSH < <(mac_ssh_opts "$key")
    "${SSH[@]}" "$host" /bin/bash -c '
      d=$1
      case "$d" in "$HOME"/zb-dmg-agent-setup-??????) ;; *) exit 2 ;; esac
      [ ! -e "$d/mnt" ] || hdiutil detach "$d/mnt" >/dev/null 2>&1 || true
      find "$d" -depth -delete
    ' bash "$dir" </dev/null >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

run_host() { # host key native-arch
  local host=$1 key=$2 native=$3 dir out rc=0
  local -a SSH SCP
  mapfile -d '' SSH < <(mac_ssh_opts "$key")
  mapfile -d '' SCP < <(mac_scp_opts "$key")
  dir=$("${SSH[@]}" "$host" 'mktemp -d "$HOME/zb-dmg-agent-setup-XXXXXX"' </dev/null)
  [[ "$dir" =~ ^/Users/[^/]+/zb-dmg-agent-setup-[A-Za-z0-9]{6}$ ]] \
    || { echo "FAIL mac-dmg-agent-setup: $host returned an invalid run directory" >&2; return 1; }
  RUNS+=("$host"$'\t'"$key"$'\t'"$dir")
  "${SCP[@]}" "$DMG" "$host:$dir/zigBrowser.dmg" >/dev/null
  out=$("${SSH[@]}" "$host" /bin/bash -s "$dir" "$native" <<'REMOTE'
set -euo pipefail
d=$1 native=$2
mkdir "$d/mnt" "$d/install" "$d/tmp"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$d/mnt" "$d/zigBrowser.dmg" >/dev/null
ditto "$d/mnt/zigBrowser.app" "$d/install/zigBrowser.app"
hdiutil detach "$d/mnt" >/dev/null
app="$d/install/zigBrowser.app/Contents/MacOS/zigBrowser"

for shape in fresh existing; do
  home="$d/home-$shape"
  tmp="$d/tmp/$shape"
  mkdir -m 700 "$home" "$tmp"
  [ "$shape" != existing ] || mkdir -m 700 "$home/.claude"
  set +e
  env -i HOME="$home" PATH=/usr/bin:/bin TMPDIR="$tmp" LANG=en_US.UTF-8 \
    "$app" --agent-setup >"$d/$shape.out" 2>&1
  setup_rc=$?
  set -e
  if [ "$setup_rc" -ne 0 ]; then
    printf 'FAIL mac-dmg-agent-setup: %s %s HOME exited %s\n' "$native" "$shape" "$setup_rc"
    sed -n '1,80p' "$d/$shape.out"
    exit 1
  fi
  current="$home/.local/share/zigbrowser/agent-home/current"
  [ -L "$current" ] || {
    printf 'FAIL mac-dmg-agent-setup: %s %s HOME has no provisioned current link\n' "$native" "$shape"
    exit 1
  }
  grep -Fx 'zigBrowser: agent running unsandboxed (dev build)' "$d/$shape.out" >/dev/null || {
    printf 'FAIL mac-dmg-agent-setup: %s %s HOME lacks the development warning\n' "$native" "$shape"
    exit 1
  }
  printf 'PASS mac-dmg-agent-setup: %s %s HOME provisioned current\n' "$native" "$shape"
done
REMOTE
  ) || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

failed=0
run_host "$HOST" "$KEY" x86_64 || failed=1
run_host "$ARM_HOST" "$ARM_KEY" arm64 || failed=1
[ "$failed" -eq 0 ]
