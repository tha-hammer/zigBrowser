#!/usr/bin/env bash
# Builds the two per-arch macOS site-packages trees of the agent host from its lock alone (MS5 fat agent-host;
# JadeBeacon 7206, BlueBeaver 7197). Runs on Linux (or anywhere uv runs); packaging/macos/merge_universal_tree.py then
# merges them on a Mac. Every wheel is a binary for CPython 3.12 on that platform, pinned by hash: no sdist, nothing
# outside the lock, no dependency resolution (--no-deps over the exported, fully pinned set).
# usage: build_site_packages.sh <agent/host project dir> <out dir>   -> <out>/site-x86_64, <out>/site-aarch64
set -euo pipefail
host="${1:?usage: build_site_packages.sh <agent/host> <out>}"
out="${2:?out dir}"
die() { echo "build_site_packages: $*" >&2; exit 1; }
for plat in x86_64 aarch64; do [ ! -e "$out/site-$plat" ] || die "$out/site-$plat already exists (refused)"; done
mkdir -p "$out"
uv export --project "$host" --frozen --no-emit-project --format requirements-txt -o "$out/requirements-macos.txt" \
  >/dev/null
for plat in x86_64 aarch64; do
  uv pip install --quiet --target "$out/site-$plat" --python-platform "$plat-apple-darwin" --python-version 3.12 \
    --only-binary :all: --require-hashes --no-deps -r "$out/requirements-macos.txt"
done
echo "built $out/site-x86_64 and $out/site-aarch64"
