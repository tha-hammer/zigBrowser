#!/usr/bin/env bash
# Product proof: an app installed from the real DMG provisions its agent home
# from both a fresh private HOME and a HOME that already has ~/.claude.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
. tests/mac/mac_config.sh
mac_config two
. tests/mac/mac_gate_lib.sh

COMMIT=$(git rev-parse --verify HEAD^{commit})
DMG=$ROOT/zigBrowser_0.2.0_macos.dmg
[ ! -e "$DMG" ] || { echo "FAIL mac-dmg-agent-setup: refusing to replace existing $DMG" >&2; exit 1; }
BUILT_DMG=0

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
  if [ "$BUILT_DMG" -eq 1 ] && [ "$DMG" = "$ROOT/zigBrowser_0.2.0_macos.dmg" ]; then
    rm -f -- "$DMG"
  fi
}
trap cleanup EXIT

ZB_GATE_COMMIT="$COMMIT" bash packaging/macos/build-dmg.sh
BUILT_DMG=1
[ -s "$DMG" ] || { echo "FAIL mac-dmg-agent-setup: build-dmg.sh made no DMG" >&2; exit 1; }

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
  mkdir -m 700 "$home" "$tmp" "$home/.ssh"
  printf 'private installed-DMG ssh canary\n' > "$home/.ssh/id_test"
  [ "$shape" != existing ] || mkdir -m 700 "$home/.claude"
  started=$(/bin/date '+%Y-%m-%d %H:%M:%S%z')
  set +e
  env -i HOME="$home" PATH=/usr/bin:/bin TMPDIR="$tmp" LANG=en_US.UTF-8 \
    "$app" --agent-setup >"$d/$shape.out" 2>&1
  setup_rc=$?
  set -e
  /usr/bin/log show --start "$started" --style compact --predicate 'sender == "Sandbox"' \
    >"$d/$shape.sandbox.log" 2>&1 || true
  if [ "$setup_rc" -ne 0 ]; then
    printf 'FAIL mac-dmg-agent-setup: %s %s HOME exited %s\n' "$native" "$shape" "$setup_rc"
    sed -n '1,80p' "$d/$shape.out"
    printf 'SANDBOX_LOG_BEGIN %s %s\n' "$native" "$shape"
    grep -E 'deny|agent-host|Resources|Frameworks|claude|Python' "$d/$shape.sandbox.log" | tail -160 || true
    printf 'SANDBOX_LOG_END %s %s\n' "$native" "$shape"
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
  python="$d/install/zigBrowser.app/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12"
  probe="$d/setup-profile-probe-$shape"
  mkdir -m 700 "$probe"
  set +e
  env -i PATH=/usr/bin:/bin HOME="$probe" TMPDIR="$probe" LANG=en_US.UTF-8 \
    "$python" -I - "$probe" "$home/.ssh/id_test" <<'PY' >"$d/$shape.probe.out" 2>&1
import subprocess
import sys
from zb_agent_host import sandbox_macos

scratch, canary = sys.argv[1:]
with sandbox_macos.setup_sandbox(scratch, [sys.prefix], ["/bin/cat", canary]) as argv:
    done = subprocess.run(argv, capture_output=True, timeout=20)
raise SystemExit(0 if done.returncode != 0 and not done.stdout else 1)
PY
  probe_rc=$?
  set -e
  [ "$probe_rc" -eq 0 ] || {
    printf 'FAIL mac-dmg-agent-setup: %s %s HOME allowed ~/.ssh/id_test\n' "$native" "$shape"
    sed -n '1,80p' "$d/$shape.probe.out"
    exit 1
  }
  printf 'PASS mac-dmg-agent-setup: %s %s HOME provisioned current; denied ~/.ssh/id_test\n' "$native" "$shape"
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
