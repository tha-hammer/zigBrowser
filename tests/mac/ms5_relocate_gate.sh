#!/usr/bin/env bash
# MS5 framework relocation on BOTH Macs (tests/e2e/mac_relocate_test.py is the off-Mac planner suite). Measured
# 2026-10-21: the staged python.org CPython 3.12.10 cannot run as staged (it loads
# /Library/Frameworks/Python.framework/Versions/3.12/... by absolute path), and relocating only its executables let
# dyld fall back to a foreign /usr/local/lib/libssl.3.dylib on x86_64. Per leg:
#   1. stage the verified pkg with packaging/macos/stage_agent_runtime.sh (pkgutil --expand-full, never installed);
#   2. packaging/macos/relocate_python_framework.py <Versions/3.12> (run by the Mac's /usr/bin/python3) rewrites every
#      Mach-O and re-signs ad hoc; its --check then reports no absolute framework or foreign path left;
#   3. `codesign --verify --strict` passes for every Mach-O of the framework;
#   4. the staged python3.12, under `env -i`, imports EVERY lib-dynload module, and every image dyld loaded that is
#      not under /usr/lib/ or /System/ lies inside the staged framework;
#   5. step 4 again after the whole agent-host is moved elsewhere (the paths are relative, not where it was staged).
# The driver checks the pkg's SHA-256 pin and Sigstore identity first (as tests/mac/ms5_stage_gate.sh). Per-run
# ~/zb-reloc-<nonce>, deleted by validated find -delete; nothing installed. BatchMode, strict host keys, no askpass.
# usage: tests/mac/ms5_relocate_gate.sh [commit]   (default HEAD)
set -euo pipefail

LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-900}"
PIN=8373e58da4ea146b3eb1c1f9834f19a319440b6b679b06050b1f9ee3237aa8e4
URL=https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg
export SSH_ASKPASS_REQUIRE=never

cd "$(git rev-parse --show-toplevel)"
. tests/mac/mac_gate_output.sh
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# The Macs' host keys are pinned (bd 4pa.77): every ssh/scp below uses this file, never ~/.ssh/known_hosts.
KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -F none -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -F none -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15)

L=$(mktemp -d "${TMPDIR:-/tmp}/zb-reloc-drv-XXXXXX")
trap 'case "$L" in "${TMPDIR:-/tmp}"/zb-reloc-drv-??????) find "${L:?}" -delete;; esac' EXIT
curl -fsSL --proto '=https' -o "$L/py.pkg" "$URL"
curl -fsSL --proto '=https' -o "$L/py.pkg.sigstore" "$URL.sigstore"
[ "$(sha256sum "$L/py.pkg" | cut -c1-64)" = "$PIN" ] || { echo "FAIL: pkg SHA-256 is not rev 15's pin" >&2; exit 1; }
python3 -m venv "$L/venv" >/dev/null && "$L/venv/bin/pip" -q install sigstore >/dev/null 2>&1
"$L/venv/bin/python" -m sigstore verify identity --bundle "$L/py.pkg.sigstore" --cert-identity thomas@python.org \
  --cert-oidc-issuer https://accounts.google.com "$L/py.pkg" || { echo "FAIL: Sigstore" >&2; exit 1; }
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}"); echo "== commit $SHA" >&2
git archive --format=tar -o "$L/src.tar" "$SHA" packaging/macos agent/host/zb_agent_host agent/host/uv.lock

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2" rdir="zb-reloc-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "$L/py.pkg" "$L/src.tar" "$host:${rdir}/" >/dev/null; then
    "${SSH[@]}" "$host" "d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  local out rc=0
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' ZB_PIN='${PIN}' /bin/bash -s" <<'REMOTE'
set -uo pipefail
case "$ZB_RDIR" in zb-reloc-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
d="$HOME/${ZB_RDIR:?}"
trap 'cd / && find "$HOME/${ZB_RDIR:?}" -delete' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d" && tar -xf src.tar
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }
RELOC=packaging/macos/relocate_python_framework.py
[ -f "$RELOC" ] || { printf 'FAIL\tms5-relocate\t%s\t%s is missing (MS5 relocation)\n' "$ZB_ARCH" "$RELOC"; exit 1; }
bash packaging/macos/stage_agent_runtime.sh "$d/py.pkg" "$ZB_PIN" "$d/prefix" >stage.log 2>&1 \
  || { tail -5 stage.log; printf 'FAIL\tms5-relocate\t%s\tstaging\n' "$ZB_ARCH"; exit 1; }
A="$d/prefix/Frameworks/agent-host"; V="$A/Python.framework/Versions/3.12"
# 2. relocate, then the static census
if /usr/bin/python3 -I "$RELOC" "$V" >reloc.log 2>&1; then ok "relocate_python_framework.py rewrote and re-signed the framework"
else tail -5 reloc.log; bad "relocate_python_framework.py failed"; fi
if /usr/bin/python3 -I "$RELOC" --check "$V" >check.log 2>&1; then ok "no absolute framework or foreign load path left (otool -D/-L census)"
else head -10 check.log; bad "absolute paths left after relocation"; fi
# 3. signatures
unsigned=0
while IFS= read -r f; do
  if ! file_desc=$(file -b "$f"); then
    unsigned=$((unsigned+1)); echo "    file inspection failed: ${f#$V/}"
    continue
  fi
  case "$file_desc" in *Mach-O*) ;; *) continue;; esac
  codesign --verify --strict "$f" 2>/dev/null || { unsigned=$((unsigned+1)); echo "    invalid signature: ${f#$V/}"; }
done < <(find "$V" -type f)
[ "$unsigned" = 0 ] && ok "every Mach-O of the framework passes codesign --verify --strict" || bad "$unsigned Mach-O with an invalid signature"
# 4. and 5. the runtime proof, staged and moved
cat > probe.py <<'PY'
import ctypes, os, sys, importlib
root = os.path.realpath(sys.argv[1])
dyn = os.path.join(sys.prefix, "lib", "python3.12", "lib-dynload")
failed = []
for name in sorted(os.listdir(dyn)):
    if name.endswith(".cpython-312-darwin.so"):
        mod = name.split(".", 1)[0]
        try:
            importlib.import_module(mod)
        except Exception as exc:
            failed.append(f"{mod}: {type(exc).__name__}: {exc}"[:200])
libc = ctypes.CDLL(None)
libc._dyld_get_image_name.restype = ctypes.c_char_p
foreign = []
for i in range(libc._dyld_image_count()):
    path = libc._dyld_get_image_name(i).decode()
    real = os.path.realpath(path)
    if real.startswith(("/usr/lib/", "/System/")) or path.startswith(("/usr/lib/", "/System/")):
        continue
    if not real.startswith(root + os.sep):
        foreign.append(path)
print(f"PROBE {sys.version.split()[0]} imported={len(os.listdir(dyn)) - len(failed)} failed={len(failed)} foreign={len(foreign)}")
for f in failed: print("  import failed:", f)
for f in foreign: print("  foreign image:", f)
sys.exit(1 if failed or foreign else 0)
PY
probe() { # $1=agent-host dir $2=label
  local out; out=$(cd / && env -i "$1/Python.framework/Versions/3.12/bin/python3.12" -I "$d/probe.py" "$1" 2>&1)
  local rc=$?; echo "$out" | sed -n '1,12p' | sed 's/^/    /'
  [ "$rc" = 0 ] && ok "$2: every lib-dynload module imports; every non-system image is inside the staged tree" || bad "$2"
}
probe "$A" "staged"
mv "$A" "$d/moved-agent-host" && probe "$d/moved-agent-host" "after moving the whole agent-host"
if [ "$fails" -eq 0 ]; then printf 'PASS\tms5-relocate\t%s\n' "$ZB_ARCH"; else printf 'FAIL\tms5-relocate\t%s\t%d\n' "$ZB_ARCH" "$fails"; exit 1; fi
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: ms5-relocate $arch leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms5_relocate_gate "$host" "$arch" "$out" $'PASS\tms5-relocate\t'"$arch" || return 1
}

overall=0
leg "$INTEL_HOST" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-relocate-gate\tboth-arches\n'
exit "$overall"
