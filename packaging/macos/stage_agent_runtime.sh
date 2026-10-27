#!/usr/bin/env bash
# Stages the agent runtime into <prefix>/Frameworks/agent-host (macOS plan rev 17, Behavior MS5.1c; MS5.1c-a; the fat
# agent-host of plan rev 20, JadeBeacon 7206).
# Usage: stage_agent_runtime.sh <python-3.12.10-macos11.pkg> <expected_sha256> <prefix> [<site-x86_64> <site-arm64>]
#   * the pkg's SHA-256 must equal <expected_sha256> AND rev 15's pin (the Linux driver checked the same bytes'
#     Sigstore identity before handing them over);
#   * pkgutil --check-signature must name "Developer ID Installer: Python Software Foundation (BMM5U3QVKW)" and
#     Apple notarization;
#   * pkgutil --expand-full into a temporary directory; the installer is NEVER run, nothing goes to a system path;
#   * Python_Framework.pkg/Payload -> agent-host/Python.framework, without Versions/3.12/bin/*-intel64;
#   * agent/host/zb_agent_host/'s regular files (no __pycache__, no symlink) -> agent-host/zb_agent_host/;
#   * agent-host/runtime.json identifies the locked dependencies and exact staged zb_agent_host content;
#   * with the two per-arch site-packages trees (packaging/macos/build_site_packages.sh, from the lock): their strict
#     universal2 merge (packaging/macos/merge_universal_tree.py) -> agent-host/site-packages, which holds the fat
#     Claude CLI at claude_agent_sdk/_bundled/claude (token.bundled_cli()'s path); without them the staging is PARTIAL;
#   * with them, the ONE .pth (packaging/macos/sdk_pth.py install: the committed agent_host_sdk.pth, one relative path
#     line, as Python.framework/Versions/3.12/lib/python3.12/site-packages/zb_agent_host_sdk.pth): the staged
#     interpreter, -I included, imports from agent-host/site-packages with no PYTHONPATH (27a9a62); a stray .pth there
#     or any non-path line is refused;
#   * the framework relocated (packaging/macos/relocate_python_framework.py): every Mach-O loads @loader_path-relative
#     paths and is re-signed ad hoc, so the staged python runs from wherever the app is.
# The merge and the relocation run under the Mac's /usr/bin/python3. Staged into a sibling temporary directory and
# renamed into place; an existing agent-host is refused, never merged.
set -euo pipefail

PIN=8373e58da4ea146b3eb1c1f9834f19a319440b6b679b06050b1f9ee3237aa8e4
PKG="${1:?usage: stage_agent_runtime.sh <pkg> <expected_sha256> <prefix>}"
WANT="${2:?expected sha256}"
PREFIX="${3:?prefix}"
SITE_X86="${4:-}"
SITE_ARM="${5:-}"
REPO=$(cd "$(dirname "$0")/../.." && pwd)

die() { echo "stage_agent_runtime: $*" >&2; exit 1; }
if [ -n "$SITE_X86$SITE_ARM" ]; then
  [ -d "$SITE_X86" ] && [ -d "$SITE_ARM" ] || die "both per-arch site-packages trees are required, as directories"
fi
got=$(shasum -a 256 "$PKG" | cut -c1-64)
[ "$got" = "$WANT" ] || die "pkg SHA-256 $got is not the expected $WANT"
[ "$got" = "$PIN" ] || die "pkg SHA-256 $got is not rev 15's pin $PIN"
sig=$(pkgutil --check-signature "$PKG") || die "pkgutil --check-signature failed"
grep -q "Developer ID Installer: Python Software Foundation (BMM5U3QVKW)" <<<"$sig" || die "not signed by the PSF (BMM5U3QVKW)"
grep -q "Notarization: trusted by the Apple notary service" <<<"$sig" || die "not notarized"

AGENT="$PREFIX/Frameworks/agent-host"
[ ! -e "$AGENT" ] || die "$AGENT already exists (refused: never merged into)"
mkdir -p "$PREFIX/Frameworks"
WORK=$(mktemp -d "$PREFIX/Frameworks/.agent-host-stage-XXXXXX")
trap 'case "$WORK" in "$PREFIX/Frameworks/.agent-host-stage-"??????) find "${WORK:?}" -delete;; esac' EXIT
pkgutil --expand-full "$PKG" "$WORK/x" >/dev/null
S="$WORK/agent-host"; mkdir "$S"
ditto "$WORK/x/Python_Framework.pkg/Payload" "$S/Python.framework"
rm -f "$S/Python.framework/Versions/3.12/bin/"*-intel64
(cd "$REPO/agent/host" && find zb_agent_host -type f ! -path '*/__pycache__/*' -print) | while IFS= read -r rel; do
  mkdir -p "$S/$(dirname "$rel")"
  cp "$REPO/agent/host/$rel" "$S/$rel"
done
host=$(/usr/bin/python3 -I - "$S/zb_agent_host" <<'PY'
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
printf '{"lock_sha256": "%s", "host_sha256": "%s"}\n' \
  "$(shasum -a 256 "$REPO/agent/host/uv.lock" | cut -c1-64)" "$host" > "$S/runtime.json"
if [ -n "$SITE_X86" ]; then
  /usr/bin/python3 -I "$REPO/packaging/macos/merge_universal_tree.py" "$SITE_X86" "$SITE_ARM" "$S/site-packages" \
    >/dev/null || die "merging the two site-packages trees failed"
  /usr/bin/python3 -I -B "$REPO/packaging/macos/sdk_pth.py" install \
    "$S/Python.framework/Versions/3.12/lib/python3.12/site-packages" "$S" || die "installing the SDK .pth failed"
fi
/usr/bin/python3 -I "$REPO/packaging/macos/relocate_python_framework.py" "$S/Python.framework/Versions/3.12" \
  >/dev/null || die "relocating the framework failed"
mv "$S" "$AGENT"
if [ -n "$SITE_X86" ]; then
  echo "staged $AGENT (with its locked dependencies and the fat Claude CLI; framework relocated)"
else
  echo "staged $AGENT (partial: dependencies and CLI not staged; framework relocated)"
fi
