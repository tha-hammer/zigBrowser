#!/usr/bin/env bash
# MS5 fat agent-host with its locked dependencies and the Claude CLI on BOTH Macs (JadeBeacon 7206; BlueBeaver 7197,
# 7221). The Linux driver builds the two per-arch macOS site-packages trees from agent/host/uv.lock:
#   uv export --frozen --no-emit-project, then uv pip install --target <tree> --python-platform {x86_64,aarch64}-apple-darwin
#   --python-version 3.12 --only-binary :all: --require-hashes --no-deps
# and checks the python.org pkg's SHA-256 pin and Sigstore identity (as tests/mac/ms5_stage_gate.sh). Each leg then runs
#   packaging/macos/stage_agent_runtime.sh <pkg> <sha256> <prefix> <site-x86_64> <site-arm64>
# and requires:
#   1. Frameworks/agent-host/site-packages exists, and claude_agent_sdk/_bundled/claude in it is fat (x86_64 arm64);
#   2. no thin Mach-O anywhere under agent-host, and relocate_python_framework.py --check is clean;
#   3. under `env -i`, the staged python3.12 with sys.path = [agent-host, agent-host/site-packages] imports
#      cryptography (and its _rust binding), cffi, pydantic_core, rpds and claude_agent_sdk; token.bundled_cli() is
#      exactly the staged fat CLI, which answers --version; every non-system image dyld loaded is inside agent-host;
#   4. on arm64, the same probe through `arch -x86_64` when Rosetta is ALREADY present (never installed by us).
# Per-run ~/zb-deps-<nonce>, deleted by validated find -delete; nothing installed. BatchMode, strict host keys.
# usage: tests/mac/ms5_deps_gate.sh [commit]   (default HEAD)
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
SSH=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10)
SCP=(env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes
     -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" -o ConnectTimeout=15)

L=$(mktemp -d "${TMPDIR:-/tmp}/zb-deps-drv-XXXXXX")
trap 'case "$L" in "${TMPDIR:-/tmp}"/zb-deps-drv-??????) find "${L:?}" -delete;; esac' EXIT
SHA=$(git rev-parse --verify "${1:-HEAD}^{commit}"); echo "== commit $SHA" >&2
git archive --format=tar -o "$L/src.tar" "$SHA" packaging/macos agent/host
mkdir "$L/repo" && tar -xf "$L/src.tar" -C "$L/repo"
# --- the two per-arch trees, from the lock only (exactly the commands above, in the committed builder) ---
bash "$L/repo/packaging/macos/build_site_packages.sh" "$L/repo/agent/host" "$L/sites" >/dev/null
(cd "$L/sites" && tar -cf "$L/sites.tar" site-x86_64 site-aarch64)
# --- the python.org pkg: pin + Sigstore ---
curl -fsSL --proto '=https' -o "$L/py.pkg" "$URL"
curl -fsSL --proto '=https' -o "$L/py.pkg.sigstore" "$URL.sigstore"
[ "$(sha256sum "$L/py.pkg" | cut -c1-64)" = "$PIN" ] || { echo "FAIL: pkg SHA-256 is not rev 15's pin" >&2; exit 1; }
python3 -m venv "$L/venv" >/dev/null && "$L/venv/bin/pip" -q install sigstore >/dev/null 2>&1
"$L/venv/bin/python" -m sigstore verify identity --bundle "$L/py.pkg.sigstore" --cert-identity thomas@python.org \
  --cert-oidc-issuer https://accounts.google.com "$L/py.pkg" || { echo "FAIL: Sigstore" >&2; exit 1; }

leg() { # $1=host $2=expected uname -m
  local host="$1" arch="$2" rdir="zb-deps-$(date +%s)-$$-$RANDOM"
  "${SSH[@]}" "$host" "mkdir \"\$HOME/${rdir:?}\"" || { echo "FAIL: mkdir on $host" >&2; return 1; }
  if ! "${SCP[@]}" "$L/py.pkg" "$L/src.tar" "$L/sites.tar" "$host:${rdir}/" >/dev/null; then
    "${SSH[@]}" "$host" "d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete" || true
    echo "FAIL: scp to $host" >&2; return 1
  fi
  timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" "ZB_RDIR='${rdir}' ZB_ARCH='${arch}' ZB_PIN='${PIN}' /bin/bash -s" <<'REMOTE'
set -uo pipefail
case "$ZB_RDIR" in zb-deps-*) ;; *) echo "FAIL: bad run dir $ZB_RDIR" >&2; exit 1;; esac
d="$HOME/${ZB_RDIR:?}"
trap 'cd / && find "$HOME/${ZB_RDIR:?}" -delete' EXIT
[ "$(uname -m)" = "$ZB_ARCH" ] || { echo "FAIL: this leg is $(uname -m), expected $ZB_ARCH" >&2; exit 1; }
cd "$d" && tar -xf src.tar && tar -xf sites.tar
fails=0
ok() { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }
bash packaging/macos/stage_agent_runtime.sh "$d/py.pkg" "$ZB_PIN" "$d/prefix" "$d/site-x86_64" "$d/site-aarch64" \
  >stage.log 2>&1 || { tail -8 stage.log; printf 'FAIL\tms5-deps\t%s\tstaging\n' "$ZB_ARCH"; exit 1; }
A="$d/prefix/Frameworks/agent-host"; S="$A/site-packages"; CLI="$S/claude_agent_sdk/_bundled/claude"
# 1. the fat site-packages and CLI
[ -d "$S" ] && ok "Frameworks/agent-host/site-packages is staged" || bad "Frameworks/agent-host/site-packages is missing"
case "$(lipo -archs "$CLI" 2>/dev/null)" in "x86_64 arm64"|"arm64 x86_64") ok "the Claude CLI is fat (x86_64 arm64)";;
  *) bad "the Claude CLI is not a fat x86_64+arm64 binary at $CLI";; esac
# 2. no thin Mach-O; relocation clean
thin=0; while IFS= read -r f; do
  if ! file_desc=$(file -b "$f"); then bad "file inspection failed for ${f#$A/}"; continue; fi
  case "$file_desc" in *Mach-O*) ;; *) continue;; esac
  case "$f" in *.o|*.a) continue;; esac
  case "$(lipo -archs "$f" 2>/dev/null)" in "x86_64 arm64"|"arm64 x86_64") ;; *) thin=$((thin+1)); echo "    thin: ${f#$A/}";; esac
done < <(find "$A" -type f)
[ "$thin" = 0 ] && ok "no thin Mach-O under agent-host" || bad "$thin thin Mach-O under agent-host"
/usr/bin/python3 -I packaging/macos/relocate_python_framework.py --check "$A/Python.framework/Versions/3.12" >check.log 2>&1 \
  && ok "the framework is relocated (no absolute framework or foreign load path)" || { head -5 check.log; bad "relocation"; }
# 3. and 4. the runtime proof
cat > probe.py <<'PY'
import ctypes, os, subprocess, sys
agent = os.path.realpath(sys.argv[1])
sys.path[:0] = [agent, os.path.join(agent, "site-packages")]
import cryptography, cryptography.hazmat.bindings._rust, cffi, _cffi_backend, pydantic_core, rpds, claude_agent_sdk
from zb_agent_host import token
cli = token.bundled_cli()
want = os.path.join(agent, "site-packages", "claude_agent_sdk", "_bundled", "claude")
version = subprocess.run([cli, "--version"], capture_output=True, text=True, timeout=60, env={"PATH": "/usr/bin:/bin"})
libc = ctypes.CDLL(None)
libc._dyld_get_image_name.restype = ctypes.c_char_p
foreign = [p for p in (libc._dyld_get_image_name(i).decode() for i in range(libc._dyld_image_count()))
           if not p.startswith(("/usr/lib/", "/System/")) and not os.path.realpath(p).startswith(agent + os.sep)]
print(f"PROBE {os.uname().machine} cryptography={cryptography.__version__} pydantic_core={pydantic_core.__version__}"
      f" cli_ok={os.path.realpath(cli) == os.path.realpath(want)} version_rc={version.returncode}"
      f" version={version.stdout.strip()[:40]!r} foreign={foreign}")
sys.exit(0 if os.path.realpath(cli) == os.path.realpath(want) and version.returncode == 0 and version.stdout.strip()
         and not foreign and cryptography.__version__ == "48.0.1" else 1)
PY
PY312="$A/Python.framework/Versions/3.12/bin/python3.12"
out=$(cd / && env -i "$PY312" -I "$d/probe.py" "$A" 2>&1); rc=$?; echo "$out" | tail -3 | sed 's/^/    /'
[ "$rc" = 0 ] && ok "native $ZB_ARCH: imports, bundled_cli() is the staged fat CLI and runs, no foreign image" \
  || bad "native $ZB_ARCH runtime probe"
if [ "$ZB_ARCH" = arm64 ]; then
  if arch -x86_64 /usr/bin/true 2>/dev/null; then
    out=$(cd / && env -i arch -x86_64 "$PY312" -I "$d/probe.py" "$A" 2>&1); rc=$?; echo "$out" | tail -3 | sed 's/^/    /'
    [ "$rc" = 0 ] && ok "x86_64 slice under Rosetta: the same probe" || bad "x86_64 slice under Rosetta"
  else
    echo "  note x86_64 slice not run on arm64: Rosetta is not present (never installed by this gate); the x86_64 leg covers it"
  fi
fi
if [ "$fails" -eq 0 ]; then printf 'PASS\tms5-deps\t%s\n' "$ZB_ARCH"; else printf 'FAIL\tms5-deps\t%s\t%d\n' "$ZB_ARCH" "$fails"; exit 1; fi
REMOTE
}

overall=0
leg "$INTEL_HOST" x86_64 || { echo "FAIL: x86_64 leg" >&2; overall=1; }
leg "$ARM_HOST" arm64 || { echo "FAIL: arm64 leg" >&2; overall=1; }
[ "$overall" -eq 0 ] && printf 'PASS\tms5-deps-gate\tboth-arches\n'
exit "$overall"
