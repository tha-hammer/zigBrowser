#!/usr/bin/env bash
# 4pa.80 SPIKE (plan R30-MS9, V79-M7): does the real bundle layout survive strict code-signature verification?
# packaging/macos/stage_agent_runtime.sh puts agent-host/ (Python.framework, zb_agent_host/*.py, runtime.json, the .pth,
# site-packages with its data and extension modules, the fat Claude CLI) under Contents/Frameworks. Apple expects
# only code there, with data under Contents/Resources, so `codesign --verify --strict` may reject the .app. This spike
# answers that on both Macs BEFORE MS1c fixes the layout. It is evidence, not a gate: a FAIL is a finding.
#
#   bash tests/mac/bundle_layout_spike.sh prep <new dir>
#       Linux only, network: the two per-arch site-packages trees from agent/host/uv.lock
#       (packaging/macos/build_site_packages.sh) and the python.org pkg (rev 15's SHA-256 pin and its Sigstore
#       identity), exactly as tests/mac/ms5_deps_gate.sh; writes py.pkg, sites.tar and inputs.sha256.
#   bash tests/mac/bundle_layout_spike.sh run <prep dir>
#       Both Macs, one after the other. Each leg builds ${ZB_GATE_COMMIT:-HEAD} with tests/mac/mac_gate_lib.sh's mac_build
#       (git archive into a fresh ~/zb-gate-<sha>-<nonce>, pinned host keys, both zig caches in the run dir) and works
#       only in that dir: it stages zigBrowser.app (the exe, the shim in Contents/Frameworks) plus the real agent
#       runtime (stage_agent_runtime.sh with the prep inputs, prefix = the app's Contents), signs it ad hoc inside out
#       (every Mach-O deepest first, then each framework version, then the .app; never --deep), then runs
#       `codesign --verify --strict --deep --verbose=4` on the .app. It prints, per leg:
#         SPIKE<TAB><arch><TAB>data-files-under-Frameworks<TAB><n>      (non-Mach-O files in that code location)
#         SPIKE<TAB><arch><TAB>sign-failures<TAB><n>
#         SPIKE<TAB><arch><TAB>verify-rc<TAB><rc><TAB>unsealed<TAB>yes|no<TAB>not-signed<TAB>yes|no
#         PASS<TAB>bundle-layout-spike<TAB><arch>   (verify exit 0, neither message, no sign failure) or FAIL<TAB>...
#       and finally PASS<TAB>bundle-layout-spike<TAB>both-arches<TAB><sha> only when both legs pass.
#       ZB_SPIKE_MUTANT=data_in_frameworks adds Contents/Frameworks/stray-data.txt before signing; that run must FAIL.
# No browser is launched and nothing is installed; every run dir is removed at exit (mac_remove_run_dirs). The arm64
# host is mandatory. BatchMode, pinned host keys, no askpass or display (the shared transport).
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-1800}"
PIN=8373e58da4ea146b3eb1c1f9834f19a319440b6b679b06050b1f9ee3237aa8e4
URL=https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg

cd "$(git rev-parse --show-toplevel)"
MODE="${1:-}" IN="${2:-}"
[ -n "$IN" ] || { echo "usage: bundle_layout_spike.sh prep <new dir> | run <prep dir>" >&2; exit 2; }

if [ "$MODE" = prep ]; then
  [ ! -e "$IN" ] || { echo "REFUSED: $IN exists (prep writes only a new dir)" >&2; exit 1; }
  mkdir -p "$IN"; IN=$(cd "$IN" && pwd)
  COMMIT=$(git rev-parse --verify "${ZB_GATE_COMMIT:-HEAD}^{commit}")
  W=$(mktemp -d "${TMPDIR:-/tmp}/zb-spike-prep-XXXXXX")
  trap 'case "$W" in "${TMPDIR:-/tmp}"/zb-spike-prep-??????) rm -rf "${W:?}";; esac' EXIT
  git archive --format=tar "$COMMIT" packaging/macos agent/host | tar -xf - -C "$W"
  bash "$W/packaging/macos/build_site_packages.sh" "$W/agent/host" "$W/sites" >/dev/null
  (cd "$W/sites" && tar -cf "$IN/sites.tar" site-x86_64 site-aarch64)
  curl -fsSL --proto '=https' -o "$IN/py.pkg" "$URL"
  curl -fsSL --proto '=https' -o "$W/py.pkg.sigstore" "$URL.sigstore"
  [ "$(sha256sum "$IN/py.pkg" | cut -c1-64)" = "$PIN" ] || { echo "FAIL: pkg SHA-256 is not rev 15's pin" >&2; exit 1; }
  python3 -m venv "$W/venv" >/dev/null && "$W/venv/bin/pip" -q install sigstore >/dev/null 2>&1
  "$W/venv/bin/python" -m sigstore verify identity --bundle "$W/py.pkg.sigstore" --cert-identity thomas@python.org \
    --cert-oidc-issuer https://accounts.google.com "$IN/py.pkg" || { echo "FAIL: Sigstore" >&2; exit 1; }
  (cd "$IN" && sha256sum py.pkg sites.tar > inputs.sha256)
  printf 'PREP\tbundle-layout-spike\t%s\t%s\n' "$COMMIT" "$IN"
  exit 0
fi
[ "$MODE" = run ] || { echo "usage: bundle_layout_spike.sh prep <new dir> | run <prep dir>" >&2; exit 2; }

if [ -z "$ARM_HOST" ]; then
  echo "NOT RUN: arm64 host not configured (set ZB_MAC_ARM_HOST=user@host)" >&2
  exit 1
fi
MUTANT="${ZB_SPIKE_MUTANT:-none}"
case "$MUTANT" in none|data_in_frameworks) ;; *) echo "REFUSED: unknown ZB_SPIKE_MUTANT=$MUTANT" >&2; exit 1 ;; esac
IN=$(cd "$IN" && pwd)
for f in py.pkg sites.tar inputs.sha256; do [ -s "$IN/$f" ] || { echo "FAIL: $IN/$f is missing (run prep first)" >&2; exit 1; }; done
(cd "$IN" && sha256sum --quiet -c inputs.sha256) || { echo "FAIL: the prep inputs do not match inputs.sha256" >&2; exit 1; }

COMMIT=$(git rev-parse --verify "${ZB_GATE_COMMIT:-HEAD}^{commit}")
export ZB_GATE_COMMIT=$COMMIT   # mac_build and the agent tree below both use this one commit
. tests/mac/mac_gate_lib.sh
L=$(mktemp -d "${TMPDIR:-/tmp}/zb-spike-run-XXXXXX")
trap 'mac_remove_run_dirs; case "$L" in "${TMPDIR:-/tmp}"/zb-spike-run-??????) rm -rf "${L:?}";; esac' EXIT
git archive --format=tar -o "$L/agent.tar" "$COMMIT" agent/host
echo "== commit $COMMIT, mutant $MUTANT" >&2

leg() { # $1=host $2=key $3=expected uname -m
  local host="$1" key="$2" arch="$3" rd out rc
  local -a SSH SCP
  mapfile -d '' SSH < <(mac_ssh_opts "$key")
  mapfile -d '' SCP < <(mac_scp_opts "$key")
  echo "== $arch on $host ==" >&2
  mac_build "$host" "$key" || return 1
  rd=$MAC_RDIR
  "${SCP[@]}" "$IN/py.pkg" "$IN/sites.tar" "$L/agent.tar" "$host:$rd/" >/dev/null || { echo "FAIL: scp to $host" >&2; return 1; }
  # Captured, then printed to stderr: `tee /dev/stderr` would reopen (and truncate) a stderr redirected to a file.
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s "$rd" "$arch" "$PIN" "$MUTANT" <<'REMOTE'
set -uo pipefail
cd "$HOME/${1:?}" || exit 1
ARCH=$2 PIN=$3 MUTANT=$4
[ "$(uname -m)" = "$ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ARCH" >&2; exit 1; }
mkdir -p tmp && export TMPDIR="$PWD/tmp" PYTHONDONTWRITEBYTECODE=1
tar -xf agent.tar && tar -xf sites.tar || { echo "FAIL: unpack" >&2; exit 1; }
APP=spike/zigBrowser.app; C=$APP/Contents
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources"
cp zig-out/bin/zigBrowser "$C/MacOS/zigBrowser" && cp zig-out/Frameworks/libwkwebview_shim.dylib "$C/Frameworks/" \
  || { echo "FAIL: build output" >&2; exit 1; }
sed "s/__VERSION__/0.0.0-spike/g" packaging/macos/Info.plist > "$C/Info.plist"
bash packaging/macos/stage_agent_runtime.sh "$PWD/py.pkg" "$PIN" "$PWD/$C" "$PWD/site-x86_64" "$PWD/site-aarch64" \
  > stage.log 2>&1 || { tail -8 stage.log; printf 'FAIL\tbundle-layout-spike\t%s\tstaging\n' "$ARCH"; exit 1; }
[ "$MUTANT" = data_in_frameworks ] && printf 'stray data\n' > "$C/Frameworks/stray-data.txt"
is_macho() { file -b "$1" | grep -q Mach-O; }
data=0
while IFS= read -r f; do is_macho "$f" || data=$((data + 1)); done < <(find "$C/Frameworks" -type f)
printf 'SPIKE\t%s\tdata-files-under-Frameworks\t%d\n' "$ARCH" "$data"
signfail=0
sign() { codesign --force --sign - "$1" >> sign.log 2>&1 || { signfail=$((signfail + 1)); echo "sign failed: $1" >> sign.log; }; }
while IFS= read -r f; do is_macho "$f" && sign "$f"; done \
  < <(find "$C" -type f | awk -F/ '{ print NF "\t" $0 }' | sort -t "$(printf '\t')" -k1,1nr -k2 | cut -f2-)
while IFS= read -r fw; do
  for v in "$fw"/Versions/*; do [ -d "$v" ] && [ ! -L "$v" ] && sign "$v"; done
done < <(find "$C" -type d -name '*.framework')
sign "$APP"
printf 'SPIKE\t%s\tsign-failures\t%d\n' "$ARCH" "$signfail"
[ "$signfail" = 0 ] || sed -n 1,20p sign.log
codesign --verify --strict --deep --verbose=4 "$APP" > verify.log 2>&1; vrc=$?
sed -n 1,40p verify.log | sed 's/^/    /'
unsealed=no notsigned=no
grep -q 'unsealed contents present' verify.log && unsealed=yes
grep -q 'code object is not signed at all' verify.log && notsigned=yes
printf 'SPIKE\t%s\tverify-rc\t%d\tunsealed\t%s\tnot-signed\t%s\n' "$ARCH" "$vrc" "$unsealed" "$notsigned"
if [ "$vrc" = 0 ] && [ "$unsealed" = no ] && [ "$notsigned" = no ] && [ "$signfail" = 0 ]; then
  printf 'PASS\tbundle-layout-spike\t%s\n' "$ARCH"
else
  printf 'FAIL\tbundle-layout-spike\t%s\tverify\n' "$ARCH"; exit 1
fi
REMOTE
  ); rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || return 1
  grep -qP "^PASS\tbundle-layout-spike\t$arch$" <<<"$out" || { echo "FAIL: $arch printed no PASS line" >&2; return 1; }
}

overall=0
leg "$INTEL_HOST" "$KEY" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" "$ARM_KEY" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tbundle-layout-spike\tboth-arches\t%s\n' "$COMMIT"
exit "$overall"
