#!/usr/bin/env bash
# MS5.1c-a, the staging half (macOS plan rev 17, Behavior MS5.1c): packaging/macos/stage_agent_runtime.sh on BOTH
# Macs. The Linux driver downloads python-3.12.10-macos11.pkg and its .sigstore, checks the SHA-256 against rev 15's
# pin and the Sigstore identity (thomas@python.org, https://accounts.google.com), then hands THAT pkg to each Mac.
# Each leg (a per-run ~/zb-stage-<nonce>, deleted on exit; nothing installed, never the installer):
#   * a tampered copy of the pkg (one byte appended) is refused: exit nonzero, nothing staged;
#   * the real pkg stages into <prefix>/Frameworks/agent-host; then
#     - the python-runtime components (bin/python3.12, Python) are fat (x86_64 arm64);
#     - no Versions/3.12/bin/*-intel64 and no other thin Mach-O anywhere under agent-host (whole-tree scan);
#     - zb_agent_host/ is exact (tests/e2e/mac_ms5_census.py package_problems: no missing/extra/symlink/special);
#     - runtime.json is exactly the installer's bytes for agent/host/uv.lock;
#   * each leg returns its declared resources (runtime.json + zb_agent_host/, rooted at the prefix), and the driver
#     runs the committed production entry point `mac_resource_compat.py --manifest universal_components_ms5.json
#     --milestone MS5 <x86_64 tree> <arm64 tree>`: every declared resource present and byte-identical across the two
#     per-arch trees, before any lipo (RoseCat 6909).
# Since the fat agent-host (plan rev 20; JadeBeacon 7206, 06f1d4b): the driver also builds the two per-arch
# site-packages trees from the lock (packaging/macos/build_site_packages.sh) and each leg stages WITH them, so
# agent-host/site-packages and its fat Claude CLI are covered by the whole-tree thin-Mach-O scan.
# Usage: bash tests/mac/ms5_stage_gate.sh [commit]   (default HEAD). BatchMode, strict host keys.
set -euo pipefail

LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-900}"
PIN=8373e58da4ea146b3eb1c1f9834f19a319440b6b679b06050b1f9ee3237aa8e4
URL=https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# The Macs' host keys are pinned (bd 4pa.77): every ssh/scp below uses this file, never ~/.ssh/known_hosts.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -F none -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -F none -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15)

L=$(mktemp -d "${TMPDIR:-/tmp}/zb-stage-drv-XXXXXX")
trap 'case "$L" in "${TMPDIR:-/tmp}"/zb-stage-drv-??????) find "${L:?}" -delete;; esac' EXIT
# --- driver: provenance (SHA-256 pin + Sigstore), then the exact bytes go to the Macs ---
curl -fsSL --proto '=https' -o "$L/py.pkg" "$URL"
curl -fsSL --proto '=https' -o "$L/py.pkg.sigstore" "$URL.sigstore"
[ "$(sha256sum "$L/py.pkg" | cut -c1-64)" = "$PIN" ] || { echo "FAIL: pkg SHA-256 is not rev 15's pin" >&2; exit 1; }
python3 -m venv "$L/venv" >/dev/null && "$L/venv/bin/pip" -q install sigstore >/dev/null 2>&1
"$L/venv/bin/python" -m sigstore verify identity --bundle "$L/py.pkg.sigstore" --cert-identity thomas@python.org \
  --cert-oidc-issuer https://accounts.google.com "$L/py.pkg" || { echo "FAIL: Sigstore" >&2; exit 1; }
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}"); echo "== commit $SHA" >&2
git archive --format=tar -o "$L/src.tar" "$SHA" packaging/macos tests/e2e/mac_ms5_census.py tests/e2e/mac_universal_test.py tests/e2e/mac_resource_compat.py agent/host/zb_agent_host agent/host/uv.lock agent/host/pyproject.toml
mkdir "$L/repo" && tar -xf "$L/src.tar" -C "$L/repo"
bash "$L/repo/packaging/macos/build_site_packages.sh" "$L/repo/agent/host" "$L/sites" >/dev/null
(cd "$L/sites" && tar -cf "$L/sites.tar" site-x86_64 site-aarch64)

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2" rdir="zb-stage-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "$L/py.pkg" "$L/src.tar" "$L/sites.tar" "$host:${rdir}/" >/dev/null; then
    "${SSH[@]}" "$host" "d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' ZB_PIN='${PIN}' /bin/bash -s" <<'REMOTE'
set -euo pipefail
case "$ZB_RDIR" in zb-stage-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
d="$HOME/${ZB_RDIR:?}"; trap 'cd / && find "$HOME/${ZB_RDIR:?}" -delete' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d" && mkdir repo && tar -xf src.tar -C repo && tar -xf sites.tar
STAGE=repo/packaging/macos/stage_agent_runtime.sh
[ -f "$STAGE" ] || { printf 'FAIL\tms5-stage\t%s\tpackaging/macos/stage_agent_runtime.sh is missing (rev 17)\n' "$ZB_ARCH"; exit 1; }
fails=0
# 1. a tampered pkg is refused and stages nothing
cp py.pkg bad.pkg && printf 'x' >> bad.pkg
if bash "$STAGE" "$d/bad.pkg" "$ZB_PIN" "$d/bad-prefix" >/dev/null 2>&1; then echo "  FAIL a tampered pkg was accepted"; fails=$((fails+1)); fi
[ ! -e "$d/bad-prefix" ] || [ -z "$(ls -A "$d/bad-prefix")" ] || { echo "  FAIL a tampered pkg left something under its prefix: $(cd "$d/bad-prefix" && find . | head -5 | tr '\n' ' ')"; fails=$((fails+1)); }
# 2. the real pkg stages
bash "$STAGE" "$d/py.pkg" "$ZB_PIN" "$d/prefix" "$d/site-x86_64" "$d/site-aarch64" > stage.log 2>&1 || { tail -5 stage.log; echo "  FAIL staging the real pkg"; exit 1; }
A="$d/prefix/Frameworks/agent-host"
for c in Python.framework/Versions/3.12/bin/python3.12 Python.framework/Versions/3.12/Python; do
  [ "$(lipo -archs "$A/$c" 2>/dev/null)" = "x86_64 arm64" ] || { echo "  FAIL $c is not fat"; fails=$((fails+1)); }
done
if ! launchers=$(ls "$A/Python.framework/Versions/3.12/bin/"); then
  echo "  FAIL unable to list the staged launchers"; fails=$((fails+1))
else
  case "$launchers" in *intel64*) echo "  FAIL an -intel64 launcher was staged"; fails=$((fails+1));; esac
fi
thin=0; while IFS= read -r f; do
  if ! file_desc=$(file -b "$f"); then
    echo "  FAIL file inspection failed for ${f#$A/}"; fails=$((fails+1)); continue
  fi
  case "$file_desc" in *Mach-O*) ;; *) continue;; esac
  case "$(lipo -archs "$f" 2>/dev/null)" in "x86_64 arm64"|"arm64 x86_64") ;; *) thin=$((thin+1)); echo "  thin: ${f#$A/}";; esac
done < <(find "$A" -type f); [ "$thin" = 0 ] || { echo "  FAIL $thin thin Mach-O staged"; fails=$((fails+1)); }
/usr/bin/python3 - "$d/repo" "$A" <<'PY' || fails=$((fails+1))
import json, sys
from pathlib import Path
repo, agent = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(repo / "tests/e2e")); sys.path.insert(0, str(repo / "packaging/macos"))
import mac_ms5_census as c, ms5_inventory as inv
listed = [r["path"].split("Frameworks/agent-host/", 1)[1] for r in inv.generate(repo)["resources"]
          if r["role"] == "agent-host-package"]
probs = c.package_problems(agent, listed)
rj = c.runtime_json_problem((agent / "runtime.json").read_bytes(), (repo / "agent/host/uv.lock").read_bytes())
for p in probs + ([rj] if rj else []): print("  FAIL", p)
sys.exit(1 if probs or rj else 0)
PY
# 3. the staged interpreter imports the staged SDK under -I with no PYTHONPATH (27a9a62: ModuleNotFoundError on both
# Macs), from agent-host/site-packages, through exactly the committed .pth and no other (sdk_pth.problems).
FSITE="$A/Python.framework/Versions/3.12/lib/python3.12/site-packages"
sdk=$(cd / && env -i PATH=/usr/bin:/bin HOME="$d" "$A/Python.framework/Versions/3.12/bin/python3.12" -I -B -c \
  'import sys, claude_agent_sdk; print(sys.flags.no_site, claude_agent_sdk.__file__)' 2>&1) || true
[ "$sdk" = "0 $A/site-packages/claude_agent_sdk/__init__.py" ] \
  || { echo "  FAIL the staged python3.12 -I does not import the staged SDK: $(printf '%s' "$sdk" | tail -1)"; fails=$((fails+1)); }
/usr/bin/python3 -I -B repo/packaging/macos/sdk_pth.py check "$FSITE" "$A" \
  || { echo "  FAIL the staged runtime's .pth is not exactly the committed one"; fails=$((fails+1)); }
# 4. the .pth is inside the framework version's seal (RoseCat 7339): the staged version verifies --deep --strict, and
# a post-sign write to the .pth of a scratch copy breaks that copy's seal (so a .pth written after the relocation's
# signing, or a seal that left lib/ out, would be red here).
FV="$A/Python.framework/Versions/3.12"
codesign --verify --deep --strict "$FV" 2>"$d/seal.err" \
  || { echo "  FAIL codesign --verify --deep --strict on the staged framework version: $(tail -1 "$d/seal.err")"; fails=$((fails+1)); }
mkdir "$d/seal-copy" && ditto "$A/Python.framework" "$d/seal-copy/Python.framework"
CV="$d/seal-copy/Python.framework/Versions/3.12"
codesign --verify --deep --strict "$CV" 2>/dev/null \
  || { echo "  FAIL the scratch copy of the framework does not verify before the write"; fails=$((fails+1)); }
printf '\n' >> "$CV/lib/python3.12/site-packages/zb_agent_host_sdk.pth"
if codesign --verify --deep --strict "$CV" 2>/dev/null; then
  echo "  FAIL a post-sign write to the .pth leaves the framework seal valid (the .pth is not sealed)"; fails=$((fails+1))
fi
# The declared resources go back to the driver for the cross-arch comparison (outside $d, which the trap deletes).
(cd "$d/prefix" && tar -cf "$HOME/${ZB_RDIR}-res.tar" Frameworks/agent-host/runtime.json Frameworks/agent-host/zb_agent_host \
  Frameworks/agent-host/Python.framework/Versions/3.12/lib/python3.12/site-packages/zb_agent_host_sdk.pth)
if [ "$fails" -eq 0 ]; then printf 'PASS\tms5-stage\t%s\t(with its locked dependencies and the fat Claude CLI)\n' "$ZB_ARCH"; else printf 'FAIL\tms5-stage\t%s\t%d\n' "$ZB_ARCH" "$fails"; exit 1; fi
REMOTE
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    mkdir -p "$L/tree-$arch"
    "${SCP[@]}" "$host:${rdir}-res.tar" "$L/res-$arch.tar" >/dev/null && tar -xf "$L/res-$arch.tar" -C "$L/tree-$arch" || rc=1
  fi
  "${SSH[@]}" "$host" "rm -f \"\$HOME/${rdir:?}-res.tar\"" || true
  return "$rc"
}

overall=0
leg "$INTEL_HOST" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
if [ "$overall" -eq 0 ]; then
  # The committed production two-tree oracle, over the two per-arch staged trees (before any lipo).
  if (cd "$L/repo/tests/e2e" && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 mac_resource_compat.py \
        --manifest "$L/repo/packaging/macos/universal_components_ms5.json" --milestone MS5 "$L/tree-x86_64" "$L/tree-arm64"); then
    printf 'PASS\tms5-resource-compat\tx86_64-vs-arm64\n'
  else
    echo "FAIL: mac_resource_compat.py --milestone MS5 (the two per-arch trees differ or lack a declared resource)" >&2; overall=1
  fi
fi
[ "$overall" -eq 0 ] && printf 'PASS\tms5-stage-gate\tboth-arches\t(fat agent-host with its dependencies and CLI)\n'
exit "$overall"
