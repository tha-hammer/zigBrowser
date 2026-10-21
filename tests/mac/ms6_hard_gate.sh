#!/usr/bin/env bash
# The ONE MS6 hard-gate harness (plan rev 18.1; BlueBeaver 7123, 7127; JadeBeacon 7125, 7130), run BEFORE
# seatbelt_ready. ARMED by the committed MS5 pins (packaging/macos/agent_runtime_pins.json; RoseCat 7250, 9dfc9c7): on
# both Macs it stages the pinned python.org runtime with the lock's dependencies and the fat Claude CLI
# (packaging/macos/stage_agent_runtime.sh), then runs tests/mac/hard_gate/hard_gate_driver.py under the STAGED
# interpreter over ONLY the reviewed cases of tests/mac/hard_gate/MANIFEST.json. It never goes through the browser and
# never arms ms5_setup_e2e.sh; the app stays fail closed. Passing it does not by itself set seatbelt_ready (RoseCat
# 7250 #4): that also needs the completed MS6.3 and MS6.6 (B) cases and a review of the evidence.
#
# Provenance (RoseCat 7267): the gate certifies ONE commit. The revision (default HEAD) must resolve to a commit
# object, else exit 1 before any network; it is exported (git archive) into the per-run temp tree, and EVERYTHING below
# reads that export, never the mutable working tree (a shared worktree is routinely dirty). It prints "== hard gate at
# commit <sha>" and, before any network, "== ship <sha256> <path>" for every shipped seam source, staging tool and
# zb_agent_host file.
# Before ANY network call (each refusal is exit 1 and names its reason; no pins file at all is NOT ARMED, exit 3):
#   - the pins are well formed: python_pkg {url, sha256, sigstore_identity, sigstore_issuer} and uv_lock_sha256;
#   - agent/host/uv.lock still has the pinned SHA-256;
#   - both hosts are set (the arm64 host is required, no default);
#   - the case files are exactly the reviewed manifest, each with its pinned SHA-256 (the driver's own check).
# Then: the pkg (pinned URL) is downloaded and checked against its SHA-256 and Sigstore identity; the two per-arch
# site-packages trees are built from the lock (packaging/macos/build_site_packages.sh); each leg ships the working
# tree's staging tools, cases and seam sources (the tar's SHA-256 is printed as the run's identity), stages, and runs
# the driver with --manifest. The aggregate is PASS only when both legs end "PASS ms6-hard-gate".
# Per-run ~/zb-hardgate-<nonce> on each Mac, deleted by validated find -delete; nothing installed. BatchMode, strict
# host keys, no askpass.
# usage: tests/mac/ms6_hard_gate.sh [revision]   (default HEAD)
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-1800}"
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
PINS=packaging/macos/agent_runtime_pins.json
MANIFEST=tests/mac/hard_gate/MANIFEST.json
fail() { printf 'FAIL\tms6-hard-gate\t%s\n' "$*" >&2; exit 1; }
REV="${1:-HEAD}"
SHA=$(git rev-parse --verify --quiet "${REV}^{commit}") || fail "revision $REV is not a commit"
L=$(mktemp -d "${TMPDIR:-/tmp}/zb-hardgate-drv-XXXXXX")
trap 'case "$L" in "${TMPDIR:-/tmp}"/zb-hardgate-drv-??????) find "${L:?}" -delete;; esac' EXIT
mkdir "$L/repo" && git archive "$SHA" | tar -x -C "$L/repo"
echo "== hard gate at commit $SHA" >&2
cd "$L/repo"  # from here on, only the exported commit is read
if [ ! -f "$PINS" ]; then
  echo "NOT ARMED: the pinned dependency tree is not staged ($PINS is absent)" >&2
  exit 3
fi

# --- offline preconditions ---
pinned=$(python3 -I -B - "$PINS" <<'PY'
import json, re, sys
try:
    pins = json.load(open(sys.argv[1]))
    pkg = pins["python_pkg"]
    assert set(pkg) == {"url", "sha256", "sigstore_identity", "sigstore_issuer"}, "python_pkg keys"
    assert re.fullmatch(r"https://www\.python\.org/ftp/python/[0-9.]+/python-[0-9.]+-macos11\.pkg", pkg["url"]), "url"
    assert re.fullmatch(r"[0-9a-f]{64}", pkg["sha256"]), "sha256"
    assert re.fullmatch(r"[0-9a-f]{64}", pins["uv_lock_sha256"]), "uv_lock_sha256"
    assert pkg["sigstore_identity"] and pkg["sigstore_issuer"].startswith("https://"), "sigstore"
except Exception as exc:
    print(f"malformed: {exc!r}", file=sys.stderr)
    sys.exit(1)
print(pkg["url"], pkg["sha256"], pkg["sigstore_identity"], pkg["sigstore_issuer"], pins["uv_lock_sha256"])
PY
) || fail "pins: $PINS is malformed"
read -r PKG_URL PKG_SHA SIG_ID SIG_ISSUER LOCK_SHA <<<"$pinned"
[ "$(sha256sum agent/host/uv.lock | cut -c1-64)" = "$LOCK_SHA" ] \
  || fail "agent/host/uv.lock no longer matches its pinned SHA-256 ($PINS): re-pin after review"
[ -n "$ARM_HOST" ] || fail "no arm64 host (set ZB_MAC_ARM_HOST=user@host); the gate needs both Macs"
problem=$(python3 -I -B - "$MANIFEST" tests/mac/hard_gate <<'PY'
import os, re, sys
sys.path.insert(0, sys.argv[2])
import hard_gate_driver as d
files = sorted(f for f in os.listdir(sys.argv[2]) if re.fullmatch(d.CASE_FILE, f))
print(d.manifest_problem(sys.argv[1], sys.argv[2], files) or "")
PY
) || fail "manifest: cannot check $MANIFEST"
[ -z "$problem" ] || fail "manifest: $problem"

# --- what ships, from the export, named before any network ---
SHIP=(packaging/macos agent/host/zb_agent_host agent/host/uv.lock tests/mac/hard_gate tests/mac/spawn_group_io_test.c
      src/agent_spawn_posix.c src/agent_spawn_posix.h)
tar -cf "$L/src.tar" --exclude=__pycache__ "${SHIP[@]}"
find "${SHIP[@]}" -type f ! -path '*/__pycache__/*' | LC_ALL=C sort | while IFS= read -r f; do
  echo "== ship $(sha256sum "$f" | cut -c1-64) $f" >&2
done
echo "== staged tree identity: commit $SHA, src.tar sha256 $(sha256sum "$L/src.tar" | cut -c1-64)" >&2

# --- network: the pinned pkg, its provenance, the lock-built trees ---
curl -fsSL --proto '=https' -o "$L/py.pkg" "$PKG_URL"
curl -fsSL --proto '=https' -o "$L/py.pkg.sigstore" "$PKG_URL.sigstore"
[ "$(sha256sum "$L/py.pkg" | cut -c1-64)" = "$PKG_SHA" ] || fail "the pkg's SHA-256 is not its pin"
# The temporary verifier, in the per-run venv only, at a pinned version (RoseCat 7265); the pkg's own SHA-256 pin
# remains the independent integrity check.
python3 -m venv "$L/venv" >/dev/null && "$L/venv/bin/pip" -q install "sigstore==4.5.1" >/dev/null 2>&1
"$L/venv/bin/python" -m sigstore verify identity --bundle "$L/py.pkg.sigstore" --cert-identity "$SIG_ID" \
  --cert-oidc-issuer "$SIG_ISSUER" "$L/py.pkg" >/dev/null || fail "the pkg's Sigstore identity"
bash packaging/macos/build_site_packages.sh agent/host "$L/sites" >/dev/null
(cd "$L/sites" && tar -cf "$L/sites.tar" site-x86_64 site-aarch64)

leg() { # $1=host $2=expected uname -m $3=key
  local host="$1" arch="$2" key="$3" rdir="zb-hardgate-$(date +%s)-$$-$RANDOM"
  local SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY ssh -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=10)
  local SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY scp -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes
             -o StrictHostKeyChecking=yes -o ConnectTimeout=15)
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "$L/py.pkg" "$L/src.tar" "$L/sites.tar" "$host:${rdir}/" >/dev/null; then
    "${SSH[@]}" "$host" "d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" \
    "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' ZB_PIN='${PKG_SHA}' /bin/bash -s" <<'REMOTE'
set -uo pipefail
case "$ZB_RDIR" in zb-hardgate-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
d="$HOME/${ZB_RDIR:?}"
trap 'cd / && find "$HOME/${ZB_RDIR:?}" -delete' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d" && mkdir repo && tar -xf src.tar -C repo && tar -xf sites.tar || exit 1
if ! bash repo/packaging/macos/stage_agent_runtime.sh "$d/py.pkg" "$ZB_PIN" "$d/prefix" "$d/site-x86_64" \
    "$d/site-aarch64" >stage.log 2>&1; then
  tail -5 stage.log; printf 'FAIL\tms6-hard-gate\t%s\tstaging\n' "$ZB_ARCH"; exit 1
fi
PY312="$d/prefix/Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12"
cd "$d/repo" && env -i PATH=/usr/bin:/bin HOME="$HOME" LANG=C.UTF-8 ZB_HG_PYTHON="$PY312" \
  ZB_HG_PREFIX="$d/prefix/Frameworks/agent-host" \
  ZB_HG_CLI="$d/prefix/Frameworks/agent-host/site-packages/claude_agent_sdk/_bundled/claude" \
  "$PY312" -I -B tests/mac/hard_gate/hard_gate_driver.py --manifest tests/mac/hard_gate/MANIFEST.json \
  tests/mac/hard_gate
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 "$KEY" | tee "$L/x86_64.log" || true
leg "$ARM_HOST" arm64 "$ARM_KEY" | tee "$L/arm64.log" || true
for arch in x86_64 arm64; do
  [ "$(tail -1 "$L/$arch.log" | cut -f1-2)" = "PASS	ms6-hard-gate" ] || { echo "FAIL: $arch leg" >&2; overall=1; }
done
[ "$overall" -eq 0 ] && printf 'PASS\tms6-hard-gate-gate\tboth-arches\n'
exit "$overall"
