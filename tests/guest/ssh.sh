#!/usr/bin/env sh
set -eu

usage() {
  cat <<'EOF'
usage: tests/guest/ssh.sh <windows-user> [remote-command...]

Environment:
  ZB_GUEST_USER          default Windows user when omitted
  ZB_GUEST_HOST          default: 127.0.0.1
  ZB_GUEST_PORT          default: 2222
  ZB_SSH_BATCH_MODE      default: yes
  ZB_SSH_STRICT_HOSTKEY  default: accept-new

The host-to-guest passt forward is expected to be live: tcp 2222 -> guest 22.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

host="${ZB_GUEST_HOST:-127.0.0.1}"
port="${ZB_GUEST_PORT:-2222}"
batch_mode="${ZB_SSH_BATCH_MODE:-yes}"
strict_hostkey="${ZB_SSH_STRICT_HOSTKEY:-accept-new}"

if [ -n "${ZB_GUEST_USER:-}" ]; then
  user="$ZB_GUEST_USER"
else
  if [ $# -lt 1 ]; then
    usage >&2
    exit 2
  fi
  user="$1"
  shift
fi

case "$user" in
  *@*) target="$user" ;;
  *) target="$user@$host" ;;
esac

exec ssh \
  -o BatchMode="$batch_mode" \
  -o StrictHostKeyChecking="$strict_hostkey" \
  -p "$port" \
  "$target" \
  "$@"
