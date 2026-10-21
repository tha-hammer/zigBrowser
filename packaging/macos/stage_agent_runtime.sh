#!/usr/bin/env bash
# Stages the agent runtime into <prefix>/Frameworks/agent-host (macOS plan rev 17, Behavior MS5.1c; MS5.1c-a).
# Usage: stage_agent_runtime.sh <python-3.12.10-macos11.pkg> <expected_sha256> <prefix>
#   * the pkg's SHA-256 must equal <expected_sha256> AND rev 15's pin (the Linux driver checked the same bytes'
#     Sigstore identity before handing them over);
#   * pkgutil --check-signature must name "Developer ID Installer: Python Software Foundation (BMM5U3QVKW)" and
#     Apple notarization;
#   * pkgutil --expand-full into a temporary directory; the installer is NEVER run, nothing goes to a system path;
#   * Python_Framework.pkg/Payload -> agent-host/Python.framework, without Versions/3.12/bin/*-intel64;
#   * agent/host/zb_agent_host/'s regular files (no __pycache__, no symlink) -> agent-host/zb_agent_host/;
#   * agent-host/runtime.json = '{"lock_sha256": "<sha256 of agent/host/uv.lock>"}\n' (install_agent_runtime.sh's bytes).
# Staged into a sibling temporary directory and renamed into place; an existing agent-host is refused, never merged.
# PARTIAL (MS5.1c-a): the locked dependencies and the Claude CLI are not staged until their layout is decided.
set -euo pipefail

PIN=8373e58da4ea146b3eb1c1f9834f19a319440b6b679b06050b1f9ee3237aa8e4
PKG="${1:?usage: stage_agent_runtime.sh <pkg> <expected_sha256> <prefix>}"
WANT="${2:?expected sha256}"
PREFIX="${3:?prefix}"
REPO=$(cd "$(dirname "$0")/../.." && pwd)

die() { echo "stage_agent_runtime: $*" >&2; exit 1; }
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
trap 'rm -rf "${WORK:?}"' EXIT
pkgutil --expand-full "$PKG" "$WORK/x" >/dev/null
S="$WORK/agent-host"; mkdir "$S"
ditto "$WORK/x/Python_Framework.pkg/Payload" "$S/Python.framework"
rm -f "$S/Python.framework/Versions/3.12/bin/"*-intel64
(cd "$REPO/agent/host" && find zb_agent_host -type f ! -path '*/__pycache__/*' -print) | while IFS= read -r rel; do
  mkdir -p "$S/$(dirname "$rel")"
  cp "$REPO/agent/host/$rel" "$S/$rel"
done
printf '{"lock_sha256": "%s"}\n' "$(shasum -a 256 "$REPO/agent/host/uv.lock" | cut -c1-64)" > "$S/runtime.json"
mv "$S" "$AGENT"
echo "staged $AGENT (MS5.1c-a, partial: dependencies and CLI not staged)"
