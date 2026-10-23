#!/usr/bin/env bash
# 4pa.80 SPIKE (plan R30-MS9, V79-M7): does the real bundle layout survive strict code-signature verification?
# packaging/macos/stage_agent_runtime.sh puts agent-host/ (Python.framework, zb_agent_host/*.py, runtime.json, the .pth,
# site-packages with its data and extension modules, the fat Claude CLI) under Contents/Frameworks. Apple expects
# only code there, with data under Contents/Resources, so `codesign --verify --strict` may reject the .app. This spike
# answers that on both Macs BEFORE MS1c fixes the layout. It is evidence, not a gate: a FAIL is a finding.
#
#   bash tests/mac/bundle_layout_spike.sh prep <new dir>
#       Linux only, network. Everything comes from the exact commit (${ZB_GATE_COMMIT:-HEAD}), exported to a scratch tree,
#       and its packaging/macos/agent_runtime_pins.json (SilverRidge 8f28c5d): before any network call it checks the
#       pins and that the committed sigstore_verifier.txt and agent/host/uv.lock match their pinned SHA-256. It then
#       fetches the pinned pkg and its bundle (no redirect followed; a FETCH line gives each final URL, remote IP and
#       status), checks the pkg's pinned SHA-256, makes a scratch venv with `uv venv --offline --no-project --no-config
#       --python /usr/bin/python3` and installs the verifier into it with `uv pip install --no-config --default-index
#       https://pypi.org/simple --python <venv>/bin/python --require-hashes --no-deps -r <the committed requirements>`,
#       checks the pkg's pinned Sigstore identity and issuer, and builds the two site trees from the lock (packaging/macos/build_site_packages.sh). HOME,
#       XDG and the uv and pip caches stay in the scratch tree. Only a complete prep creates <new dir>, with py.pkg,
#       sites.tar and inputs.sha256. Hostless selftests: tests/mac/bundle_layout_spike_prep_selftest.sh and
#       tests/mac/bundle_layout_spike_prep_fetch_venv_selftest.sh.
#   bash tests/mac/bundle_layout_spike.sh run <prep dir>
#       Both Macs, one after the other, everything Mac-side under write containment (SilverRidge de82cf2): each leg
#       sends the committed tests/mac/bundle_layout_spike_leg.sh over ssh (pinned host keys, BatchMode, no askpass or
#       display: mac_gate_lib.sh's transport). `create` makes one fresh physical run root ~/zb-gate-<sha>-<nonce>; scp puts
#       the committed source (git archive of ${ZB_GATE_COMMIT:-HEAD}: src, build files, tests, packaging, agent/host) and
#       the prep inputs into <root>/inputs; `run` checks /usr/bin/sandbox-exec, the exact profile (writes only below the
#       root and to /dev/null), the positive writes and three refused negative canaries (the real home, both getconf
#       Darwin temp/cache dirs), then runs the native zig build and the post-build work (the real stager, a refusal of
#       any symlink that escapes the root, the census, ad hoc inside-out signing, never --deep, and
#       `codesign --verify --strict --deep --verbose=4`) as two sandboxed commands, with before/after audits. Its stdout
#       and <root>/evidence.tar are copied to <prep dir>/evidence/<arch>-<run dir>/ before `remove` deletes the root.
#       Per leg it prints LEG<TAB><arch><TAB><mutant><TAB><class><TAB><detail>, where class is
#         LAYOUT-OK        (normal: verify exit 0, no diagnostic)
#         LAYOUT-FINDING   (normal: verify fails with an unsealed / not-signed / sealed-resource diagnostic)
#         EXPECTED-FAIL    (ZB_SPIKE_MUTANT=data_in_frameworks: Contents/Frameworks/stray-data.txt signed cleanly, then
#                          verify fails with such a diagnostic)
#         INCONCLUSIVE     (any NOT RUN or failed phase, a sandbox denial anywhere, an escaping symlink, an audit delta,
#                          a verify failure without the diagnostic, a mutant that verify accepts, missing evidence)
#         BREACH           (a canary write was not refused: the run stops, the root and the canary stay for the owner)
#       then SPIKE-RESULT<TAB><sha><TAB><mutant><TAB>x86_64=<class><TAB>arm64=<class>. Exit 0 when both legs are
#       conclusive, 2 when one is inconclusive, 4 on a breach, 1 when refused before any host is touched. A root whose
#       ordinary remove still fails after 3 attempts (and one more at exit) makes its leg INCONCLUSIVE, is printed as
#       RETAINED<TAB><host><TAB><run dir>, and the run is nonzero.
# No browser is launched and nothing is installed. The arm64 host is mandatory. Hostless proof:
# tests/mac/bundle_layout_spike_containment_selftest.sh.
set -euo pipefail

KEY="${ZB_MAC_KEY:-/home/maceo/vms/mac-m9/zb_mac_key}"
ARM_KEY="${ZB_MAC_ARM_KEY:-$KEY}"
INTEL_HOST="${ZB_MAC_HOST:-maceojourdan@100.92.212.47}"
ARM_HOST="${ZB_MAC_ARM_HOST:-}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-1800}"
PINS=packaging/macos/agent_runtime_pins.json

cd "$(git rev-parse --show-toplevel)"
MODE="${1:-}" IN="${2:-}"
[ -n "$IN" ] || { echo "usage: bundle_layout_spike.sh prep <new dir> | run <prep dir>" >&2; exit 2; }

read_pins() { # $1 = a pins file -> "url sha256 identity issuer uv_lock_sha256 requirements requirements_sha256"
  python3 -I -B - "$1" <<'PY'
import json, re, sys
try:
    pins = json.load(open(sys.argv[1]))
    pkg = pins["python_pkg"]
    assert set(pkg) == {"url", "sha256", "sigstore_identity", "sigstore_issuer"}, "python_pkg keys"
    assert re.fullmatch(r"https://www\.python\.org/ftp/python/[0-9.]+/python-[0-9.]+-macos11\.pkg", pkg["url"]), "url"
    assert re.fullmatch(r"[0-9a-f]{64}", pkg["sha256"]), "sha256"
    assert re.fullmatch(r"[0-9a-f]{64}", pins["uv_lock_sha256"]), "uv_lock_sha256"
    assert pkg["sigstore_identity"] and pkg["sigstore_issuer"].startswith("https://"), "sigstore"
    ver = pins["sigstore_verifier"]
    assert ver["requirements"] == "packaging/macos/sigstore_verifier.txt", "sigstore_verifier.requirements"
    assert re.fullmatch(r"[0-9a-f]{64}", ver["sha256"]), "sigstore_verifier.sha256"
except Exception as exc:
    print(f"malformed pins: {exc!r}", file=sys.stderr)
    sys.exit(1)
print(pkg["url"], pkg["sha256"], pkg["sigstore_identity"], pkg["sigstore_issuer"], pins["uv_lock_sha256"],
      ver["requirements"], ver["sha256"])
PY
}

if [ "$MODE" = prep ]; then
  [ ! -e "$IN" ] || { echo "REFUSED: $IN exists (prep writes only a new dir)" >&2; exit 1; }
  COMMIT=$(git rev-parse --verify "${ZB_GATE_COMMIT:-HEAD}^{commit}")
  W=$(mktemp -d "${TMPDIR:-/tmp}/zb-spike-prep-XXXXXX")
  trap 'case "$W" in "${TMPDIR:-/tmp}"/zb-spike-prep-??????) rm -rf "${W:?}";; esac' EXIT
  mkdir "$W/repo" "$W/out" && git archive --format=tar "$COMMIT" packaging/macos agent/host | tar -xf - -C "$W/repo"
  pinned=$(read_pins "$W/repo/$PINS") || { echo "FAIL: $PINS at $COMMIT is malformed" >&2; exit 1; }
  read -r PKG_URL PKG_SHA SIG_ID SIG_ISSUER LOCK_SHA VREQ VREQ_SHA <<<"$pinned"
  [ "$(sha256sum "$W/repo/$VREQ" | cut -c1-64)" = "$VREQ_SHA" ] || { echo "FAIL: $VREQ does not match its pin" >&2; exit 1; }
  [ "$(sha256sum "$W/repo/agent/host/uv.lock" | cut -c1-64)" = "$LOCK_SHA" ] \
    || { echo "FAIL: agent/host/uv.lock does not match its pin" >&2; exit 1; }
  # No tool here reads or writes the real HOME's caches or config (uv, pip, the venv, curl).
  mkdir "$W/home" "$W/xdg-cache" "$W/xdg-config" "$W/xdg-data" "$W/uv-cache" "$W/uv-python" "$W/pip-cache"
  SCR=(env HOME="$W/home" XDG_CACHE_HOME="$W/xdg-cache" XDG_CONFIG_HOME="$W/xdg-config" XDG_DATA_HOME="$W/xdg-data"
       UV_CACHE_DIR="$W/uv-cache" UV_PYTHON_INSTALL_DIR="$W/uv-python" PIP_CACHE_DIR="$W/pip-cache" PIP_CONFIG_FILE=/dev/null)
  # Each download follows no redirect (curl -L --max-redirs 0 refuses one) and must answer 200 at exactly its URL; its
  # final URL, remote IP and status are printed as FETCH lines, so the host list is checked, not inferred.
  fetch() { # fetch <url> <out file>
    local w code eff ip
    w=$("${SCR[@]}" curl -fsS -L --max-redirs 0 --proto '=https' --proto-redir '=https' \
          -w '%{http_code}\t%{url_effective}\t%{remote_ip}' -o "$2" "$1") \
      || { printf 'FETCH\t%s\tREFUSED\t%s\n' "$1" "$w"; echo "FAIL: $1 failed or tried to redirect (no redirect is followed)" >&2; return 1; }
    IFS=$'\t' read -r code eff ip <<<"$w"
    printf 'FETCH\t%s\t%s\t%s\t%s\n' "$1" "$eff" "$ip" "$code"
    [ "$code" = 200 ] && [ "$eff" = "$1" ] || { echo "FAIL: $1 answered $code at $eff (a redirect or an error; nothing is followed)" >&2; return 1; }
  }
  fetch "$PKG_URL" "$W/out/py.pkg" || { echo "FAIL: pkg download" >&2; exit 1; }
  fetch "$PKG_URL.sigstore" "$W/py.pkg.sigstore" || { echo "FAIL: bundle download" >&2; exit 1; }
  [ "$(sha256sum "$W/out/py.pkg" | cut -c1-64)" = "$PKG_SHA" ] || { echo "FAIL: the pkg's SHA-256 is not its pin" >&2; exit 1; }
  # uv makes the venv from Debian's /usr/bin/python3, which has no ensurepip (so `python3 -m venv` cannot), offline, with
  # no project discovery, no config and no managed-Python fetch; then installs the hash-locked verifier into exactly that
  # environment from the pinned index (SilverRidge 6ea4636b). Each step fails with its own message; errors stay visible.
  "${SCR[@]}" uv venv --quiet --offline --no-project --no-config --python /usr/bin/python3 "$W/venv" \
    || { echo "FAIL: the verifier venv could not be created (uv venv from /usr/bin/python3)" >&2; exit 1; }
  "${SCR[@]}" uv pip install --quiet --no-config --default-index https://pypi.org/simple --python "$W/venv/bin/python" \
    --require-hashes --no-deps -r "$W/repo/$VREQ" || { echo "FAIL: the hash-locked Sigstore verifier did not install" >&2; exit 1; }
  "${SCR[@]}" "$W/venv/bin/python" -m sigstore verify identity --bundle "$W/py.pkg.sigstore" --cert-identity "$SIG_ID" \
    --cert-oidc-issuer "$SIG_ISSUER" "$W/out/py.pkg" >/dev/null || { echo "FAIL: the pkg's Sigstore identity" >&2; exit 1; }
  "${SCR[@]}" bash "$W/repo/packaging/macos/build_site_packages.sh" "$W/repo/agent/host" "$W/sites" >/dev/null \
    || { echo "FAIL: the site trees" >&2; exit 1; }
  (cd "$W/sites" && tar -cf "$W/out/sites.tar" site-x86_64 site-aarch64)
  (cd "$W/out" && sha256sum py.pkg sites.tar > inputs.sha256)
  mkdir "$IN" && mv "$W/out/py.pkg" "$W/out/sites.tar" "$W/out/inputs.sha256" "$IN/"
  printf 'PREP\tbundle-layout-spike\t%s\t%s\n' "$COMMIT" "$(cd "$IN" && pwd)"
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
. tests/mac/mac_gate_lib.sh
L=$(mktemp -d "${TMPDIR:-/tmp}/zb-spike-run-XXXXXX")
LIVE=()   # "host<TAB>key<TAB>run dir" of every root that exists and is ours to remove
remove_root() { # $1=host $2=key $3=run dir; 0 only when the leg driver removed exactly that root
  local -a SSH
  mapfile -d '' SSH < <(mac_ssh_opts "$2")
  "${SSH[@]}" "$1" /bin/bash -s remove "$3" < "$L/leg.sh" >/dev/null
}
REMOVE_TRIES=3 REMOVE_SLEEP="${ZB_SPIKE_REMOVE_SLEEP:-10}"
remove_retry() { # $1=host $2=key $3=run dir: at most REMOVE_TRIES attempts
  local i
  for ((i = 1; i <= REMOVE_TRIES; i++)); do
    remove_root "$@" && return 0
    echo "WARN: removing $3 on $1 failed (attempt $i of $REMOVE_TRIES)" >&2
    [ "$i" -eq "$REMOVE_TRIES" ] || sleep "$REMOVE_SLEEP"
  done
  return 1
}
cleanup() { # one last attempt for every root still live; a root that stays is named and the run is nonzero
  local st=$? e h k r
  for e in "${LIVE[@]+"${LIVE[@]}"}"; do
    IFS=$'\t' read -r h k r <<<"$e"
    if ! remove_root "$h" "$k" "$r"; then
      printf 'RETAINED\t%s\t%s\n' "$h" "$r"
      echo "INCONCLUSIVE: run root $r is still on $h (not removed)" >&2
      [ "$st" -ne 0 ] || st=2
    fi
  done
  case "$L" in "${TMPDIR:-/tmp}"/zb-spike-run-??????) rm -rf "${L:?}" ;; esac
  exit "$st"
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP
# Committed bytes only: the source the Mac builds, the leg driver it runs, and the pkg pin the stager checks again.
git archive --format=tar -o "$L/src.tar" "$COMMIT" src build.zig build.zig.zon zigbrowser.json tests packaging agent/host
git show "$COMMIT:tests/mac/bundle_layout_spike_leg.sh" > "$L/leg.sh"
git show "$COMMIT:$PINS" > "$L/pins.json" && pinned=$(read_pins "$L/pins.json") || { echo "FAIL: $PINS at $COMMIT is malformed" >&2; exit 1; }
read -r _ PIN _ <<<"$pinned"
echo "== commit $COMMIT, mutant $MUTANT" >&2

field() { # $1=driver output $2=key: the value of key=value in its VERIFY line
  awk -F'\t' -v k="$2" '$1 == "VERIFY" { for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == k) print kv[2] } }' <<<"$1" | tail -n 1
}
classify() { # $1=driver output $2=evidence dir -> "<class><TAB><detail>"
  local out=$1 ev=$2 nr vrc diag delta
  nr=$(awk -F'\t' '$1 == "PHASE" && ($3 == "NOT-RUN" || $3 == "fail") { print $2 ": " $4; exit }' <<<"$out")
  [ -z "$nr" ] || { printf 'INCONCLUSIVE\t%s\n' "$nr"; return; }
  grep -q '^LEGDONE$' <<<"$out" || { printf 'INCONCLUSIVE\tthe leg did not finish\n'; return; }
  [ -s "$ev/evidence/audit.before" ] && [ -s "$ev/evidence/audit.after" ] && [ -s "$ev/evidence/verify.log" ] \
    || { printf 'INCONCLUSIVE\tthe evidence is missing\n'; return; }
  delta=$(diff "$ev/evidence/audit.before" "$ev/evidence/audit.after" | grep -E '^[<>]' | cut -d'|' -f1 | sort -u | head -n 3 | tr '\n' ' ') || true
  [ -z "$delta" ] || { printf 'INCONCLUSIVE\taudit delta outside the root: %s\n' "$delta"; return; }
  vrc=$(field "$out" rc)
  [ -n "$vrc" ] || { printf 'INCONCLUSIVE\tno verify result\n'; return; }
  [ "$(field "$out" denied)" = no ] || { printf 'INCONCLUSIVE\tthe sandbox denied a tool (see the evidence logs)\n'; return; }
  diag=no
  [ "$(field "$out" unsealed)$(field "$out" not-signed)$(field "$out" sealed-resource)" = nonono ] || diag=yes
  if [ "$MUTANT" = data_in_frameworks ]; then
    if [ "$vrc" != 0 ] && [ "$diag" = yes ]; then printf 'EXPECTED-FAIL\tverify rc %s with the code-signature diagnostic\n' "$vrc"
    elif [ "$vrc" = 0 ]; then printf 'INCONCLUSIVE\tverify accepted the data_in_frameworks mutant\n'
    else printf 'INCONCLUSIVE\tverify rc %s without the code-signature diagnostic\n' "$vrc"; fi
  elif [ "$vrc" = 0 ] && [ "$diag" = no ]; then printf 'LAYOUT-OK\tverify rc 0\n'
  elif [ "$vrc" != 0 ] && [ "$diag" = yes ]; then printf 'LAYOUT-FINDING\tverify rc %s with the code-signature diagnostic\n' "$vrc"
  else printf 'INCONCLUSIVE\tverify rc %s, diagnostic %s\n' "$vrc" "$diag"; fi
}

leg() { # $1=host $2=key $3=expected uname -m; sets CLASS
  local host="$1" key="$2" arch="$3" rd ev out rc root
  local -a SSH SCP
  mapfile -d '' SSH < <(mac_ssh_opts "$key")
  mapfile -d '' SCP < <(mac_scp_opts "$key")
  rd="zb-gate-$COMMIT-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  ev="$IN/evidence/$arch-$rd"
  mkdir -p "${ev:?}"
  echo "== $arch on $host, $rd ==" >&2
  out=$("${SSH[@]}" "$host" /bin/bash -s create "$rd" < "$L/leg.sh") && rc=0 || rc=$?
  printf '%s\n' "$out" > "$ev/create.out"
  root=$(awk -F'\t' '$1 == "ROOT" { print $2; exit }' <<<"$out")
  if [ "$rc" -ne 0 ] || [ -z "$root" ]; then
    CLASS=INCONCLUSIVE; printf 'LEG\t%s\t%s\tINCONCLUSIVE\tcreate: %s\n' "$arch" "$MUTANT" "$(tail -n 1 <<<"$out")"; return
  fi
  LIVE+=("$host"$'\t'"$key"$'\t'"$rd")
  if ! "${SCP[@]}" "$L/src.tar" "$IN/py.pkg" "$IN/sites.tar" "$host:$rd/inputs/" >/dev/null; then
    CLASS=INCONCLUSIVE; printf 'LEG\t%s\t%s\tINCONCLUSIVE\tscp of the inputs failed\n' "$arch" "$MUTANT"; return
  fi
  # Captured, then printed to stderr: `tee /dev/stderr` would reopen (and truncate) a stderr redirected to a file.
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s run "$rd" "$arch" "$PIN" "$MUTANT" < "$L/leg.sh") && rc=0 || rc=$?
  printf '%s\n' "$out" > "$ev/driver.out"
  printf '%s\n' "$out" >&2
  if [ "$rc" -eq 4 ] || grep -qP '^PHASE\tcanaries\tBREACH\t' <<<"$out"; then
    LIVE=("${LIVE[@]:0:${#LIVE[@]}-1}")   # never cleaned: the root and the canary stay for the owner
    CLASS=BREACH
    printf 'LEG\t%s\t%s\tBREACH\t%s (root %s kept on %s)\n' "$arch" "$MUTANT" \
      "$(awk -F'\t' '$1 == "PHASE" && $3 == "BREACH" { print $4; exit }' <<<"$out")" "$root" "$host"
    return
  fi
  mkdir -p "$ev/evidence"
  if "${SCP[@]}" "$host:$rd/evidence.tar" "$ev/" >/dev/null 2>&1; then
    tar --no-same-owner -xf "$ev/evidence.tar" -C "${ev:?}" evidence 2>/dev/null || true
  fi
  local verdict removed=no
  # A root that will not go stays live (the EXIT trap tries once more and names it) and the leg is not conclusive.
  if remove_retry "$host" "$key" "$rd"; then LIVE=("${LIVE[@]:0:${#LIVE[@]}-1}"); removed=yes; fi
  verdict=$(classify "$out" "$ev")
  [ "$rc" -eq 0 ] || [ "${verdict%%$'\t'*}" = INCONCLUSIVE ] || verdict=$(printf 'INCONCLUSIVE\tthe leg exited %s' "$rc")
  if [ "$removed" != yes ]; then
    local why="remove failed $REMOVE_TRIES times: root $rd is kept on $host"
    if [ "${verdict%%$'\t'*}" = INCONCLUSIVE ]; then verdict="$verdict; $why"; else verdict=$(printf 'INCONCLUSIVE\t%s' "$why"); fi
  fi
  CLASS=${verdict%%$'\t'*}
  printf 'LEG\t%s\t%s\t%s\n' "$arch" "$MUTANT" "$verdict"
}

CLASS= INTEL_CLASS=NOT-RUN ARM_CLASS=NOT-RUN
leg "$INTEL_HOST" "$KEY" x86_64; INTEL_CLASS=$CLASS
if [ "$INTEL_CLASS" != BREACH ]; then leg "$ARM_HOST" "$ARM_KEY" arm64; ARM_CLASS=$CLASS; fi
printf 'SPIKE-RESULT\t%s\t%s\tx86_64=%s\tarm64=%s\n' "$COMMIT" "$MUTANT" "$INTEL_CLASS" "$ARM_CLASS"
case "$INTEL_CLASS $ARM_CLASS" in
  *BREACH*) echo "CONTAINMENT BREACH: stop, keep the evidence and tell the owner; nothing was cleaned" >&2; exit 4 ;;
  *INCONCLUSIVE*|*NOT-RUN*) exit 2 ;;
esac
exit 0
