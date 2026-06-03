#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: packaging/release-build.sh [extra zig build args...]

Builds the host Linux zigBrowser artifact with:
  zig build -Doptimize=ReleaseSafe

On success, prints the host artifact path:
  zig-out/bin/zigBrowser

Windows release executable:
  Produce zigBrowser.exe in the Win11 guest. Use tests/guest/build-in-guest.sh
  as the sync/build reference and run the guest zig build with
  -Doptimize=ReleaseSafe. The Windows artifact path in the guest is
  zig-out/bin/zigBrowser.exe.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

artifact="zig-out/bin/zigBrowser"

zig build -Doptimize=ReleaseSafe "$@"

if [ ! -x "$artifact" ]; then
  echo "ERROR: missing release artifact: $artifact" >&2
  exit 1
fi

printf '%s\n' "$artifact"
