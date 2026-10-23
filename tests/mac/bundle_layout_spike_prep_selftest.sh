#!/usr/bin/env bash
# Hostless selftest of the 4pa.80 spike's PREP phase, tests/mac/bundle_layout_spike.sh prep (SilverRidge 8f28c5d: prep
# installed `pip install sigstore` from whatever PyPI served, duplicated the pins, never checked the committed files'
# hashes, wrote the real ~/.cache/uv and ~/.cache/pip, and no registered test ran it). The REAL prep runs in a scratch
# git repo whose commit holds its own agent_runtime_pins.json, sigstore_verifier.txt, agent/host/uv.lock and the real
# packaging/macos/build_site_packages.sh. Stubs on PATH record argv and the cache environment: curl (serves a fixture
# pkg and bundle), uv, and python3 (real, except `-m venv`, which makes a venv whose pip and python record their calls).
#   P1 prep exits 0 and leaves exactly py.pkg (the fixture bytes), sites.tar (both site trees) and a valid inputs.sha256;
#   P2 curl fetches exactly the pinned url and url.sigstore, each with --proto =https;
#   P3 the verifier installs exactly once as `uv pip install` with --python <scratch venv>/bin/python, --require-hashes,
#      --no-deps, --no-config, --default-index https://pypi.org/simple and -r <export>/<pinned requirements>, and that
#      file is the committed one (SilverRidge
#      5894aef0 Stage A: Debian's python3 has no ensurepip, so prep no longer uses `python3 -m venv` + pip);
#   P4 the pkg is verified exactly once as `python -m sigstore verify identity --bundle <its .sigstore> --cert-identity
#      <pinned identity> --cert-oidc-issuer <pinned issuer> <the downloaded pkg>`;
#   P5 every curl, uv, pip and sigstore call runs with HOME, XDG_CACHE_HOME, XDG_CONFIG_HOME, XDG_DATA_HOME,
#      UV_CACHE_DIR, UV_PYTHON_INSTALL_DIR and PIP_CACHE_DIR inside prep's own scratch tree, never the real HOME;
#   P6 the site trees are built from the export's agent/host (uv export --project <export>/agent/host);
#   P7 an uncommitted edit of the pins in the working tree changes nothing (prep reads the exact commit);
#   P8 refused, exit 1, with no curl call and no output dir: a requirements file or uv.lock that does not match its
#      pin, pins without a sigstore identity, or an existing output dir;
#   P9 refused, exit 1, with no output dir: downloaded bytes that do not match the pinned SHA-256, or a failed Sigstore
#      verification.
# No network (private user+network namespace), no Mac; HOME/TMPDIR live in its temp tree.
# Run: bash tests/mac/bundle_layout_spike_prep_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_SPIKEPREP_SELFTEST_INNER:-}" != 1 ]; then
  ZB_SPIKEPREP_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
REAL_PY=$(command -v python3) || { printf 'FAIL\tmac-bundle-layout-spike-prep-selftest\tno python3\n'; exit 1; }
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-spikeprep-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-spikeprep-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
C="$T/ctl" F="$T/fixture"
URL=https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg
ID=selftest@python.org ISSUER=https://selftest.invalid
mkdir -p "$T/bin" "$C" "$F" "$T/home" "$T/tmp"
printf 'pkg stand-in bytes\n' > "$F/py.pkg"
printf 'not the pinned bytes\n' > "$F/py.pkg.bad"

# Every stub records "<argv NUL-separated>" and the cache environment.
envrec='for v in HOME XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME UV_CACHE_DIR UV_PYTHON_INSTALL_DIR PIP_CACHE_DIR; do printf "%s=%s\n" "$v" "${!v-<unset>}"; done'
rec() { # rec <tool>: the shell lines that record one call of <tool> as ctl/<tool>.<n> and ctl/<tool>.<n>.env
  printf 'n=$(ls "%s" | grep -c "^%s\\.[0-9]*$" || true); printf "%%s\\0" "$@" > "%s/%s.$n"; { %s; } > "%s/%s.$n.env"\n' \
    "$C" "$1" "$C" "$1" "$envrec" "$C" "$1"
}
{ echo '#!/bin/bash'; rec curl; cat <<EOF
out= url= wfmt=
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out=\$2; shift 2 ;; -w|--proto|--proto-redir|--max-redirs) [ "\$1" = -w ] && wfmt=\$2; shift 2 ;; -*) shift ;; *) url=\$1; shift ;; esac
done
case "\$url" in
  $URL) if [ -e "$C/serve_bad" ]; then cp "$F/py.pkg.bad" "\$out"; else cp "$F/py.pkg" "\$out"; fi ;;
  $URL.sigstore) echo '{"bundle": "stand-in"}' > "\$out" ;;
  *) echo "stub curl: unexpected url \$url" >&2; exit 22 ;;
esac
s=\$wfmt; s=\${s//%\{http_code\}/200}; s=\${s//%\{url_effective\}/\$url}; s=\${s//%\{remote_ip\}/2a04:4e42:400::223}; printf '%b' "\$s"
EOF
} > "$T/bin/curl"
{ echo '#!/bin/bash'; rec uv; cat <<'EOF'
if [ "$1" = venv ]; then
  d=${@: -1}; mkdir -p "$d/bin"; cp "$PYSTUB" "$d/bin/python"; chmod +x "$d/bin/python"
elif [ "$1" = export ]; then
  while [ $# -gt 0 ]; do [ "$1" = -o ] && { echo "pinned==1.0 --hash=sha256:00" > "$2"; break; }; shift; done
elif [ "$1" = pip ] && [ "$2" = install ]; then
  while [ $# -gt 0 ]; do [ "$1" = --target ] && { mkdir -p "$2"; echo wheel > "$2/stand-in.py"; break; }; shift; done
fi
exit 0
EOF
} > "$T/bin/uv"
sed -i "2i PYSTUB='$T/bin/venv-python'" "$T/bin/uv"
{ echo '#!/bin/bash'; rec sigstore; echo "exit \$(cat '$C/sigstore_rc' 2>/dev/null || echo 0)"; } > "$T/bin/venv-python"
{ echo '#!/bin/bash'; cat <<EOF
if [ "\$1" = -m ] && [ "\$2" = venv ]; then
  d=\${@: -1}; mkdir -p "\$d/bin"
  { echo '#!/bin/bash'; printf '%s' '$(rec pip | sed "s/'/'\\\\''/g")'; echo; echo 'exit 0'; } > "\$d/bin/pip"
  { echo '#!/bin/bash'; printf '%s' '$(rec sigstore | sed "s/'/'\\\\''/g")'; echo; echo 'exit \$(cat "$C/sigstore_rc" 2>/dev/null || echo 0)'; } > "\$d/bin/python"
  chmod +x "\$d/bin/pip" "\$d/bin/python"; exit 0
fi
exec "$REAL_PY" "\$@"
EOF
} > "$T/bin/python3"
chmod +x "$T/bin"/*

# The scratch repo: the real spike and site-packages builder, and fixture pins that name the fixture files' hashes.
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/packaging/macos" "$R/agent/host"
cp "$ROOT/tests/mac/bundle_layout_spike.sh" "$R/tests/mac/"
cp "$ROOT/packaging/macos/build_site_packages.sh" "$R/packaging/macos/"
printf '# selftest verifier lock\nsigstore==4.5.1 \\\n    --hash=sha256:%064d\n' 1 > "$R/packaging/macos/sigstore_verifier.txt"
printf 'version = 1\n# selftest lock\n' > "$R/agent/host/uv.lock"
write_pins() { # write_pins <identity or empty>
  "$REAL_PY" -I - "$R" "$1" <<'PY'
import hashlib, json, sys
r, ident = sys.argv[1:]
h = lambda p: hashlib.sha256(open(f"{r}/{p}", "rb").read()).hexdigest()
pkg = {"url": "https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg",
       "sha256": hashlib.sha256(b"pkg stand-in bytes\n").hexdigest(), "sigstore_issuer": "https://selftest.invalid"}
if ident:
    pkg["sigstore_identity"] = ident
json.dump({"python_pkg": pkg, "uv_lock_sha256": h("agent/host/uv.lock"),
           "sigstore_verifier": {"requirements": "packaging/macos/sigstore_verifier.txt",
                                 "sha256": h("packaging/macos/sigstore_verifier.txt")}},
          open(f"{r}/packaging/macos/agent_runtime_pins.json", "w"), indent=2)
PY
}
write_pins "$ID"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
commit() { "${G[@]}" add -A && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m "$1" && "${G[@]}" rev-parse HEAD; }
"${G[@]}" init -q || { bad "could not build the scratch repo"; exit 1; }
GOOD=$(commit good) || { bad "could not commit"; exit 1; }
printf '# corrupted\n' >> "$R/packaging/macos/sigstore_verifier.txt"; BADREQ=$(commit bad-requirements)
"${G[@]}" checkout -q "$GOOD" -- . && printf '# edited\n' >> "$R/agent/host/uv.lock"; BADLOCK=$(commit bad-lock)
"${G[@]}" checkout -q "$GOOD" -- . && write_pins ""; NOID=$(commit no-identity)
"${G[@]}" checkout -q "$GOOD" -- .

run_prep() { # run_prep <label> <commit> <out dir>: sets rc
  rm -rf "${C:?}"/*
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_GATE_COMMIT="$2" \
     timeout 120 bash tests/mac/bundle_layout_spike.sh prep "$3" >"$T/out.$1" 2>&1 </dev/null)
  rc=$?
}
calls() { ls "$C" | grep -cE "^$1\.[0-9]+$" || true; }
argv_of() { tr '\0' ' ' < "$C/$1"; }

# P1-P7: the good commit, with an uncommitted pins edit in the working tree (P7).
printf '{"python_pkg": {"url": "https://example.invalid/evil.pkg"}}\n' > "$R/packaging/macos/agent_runtime_pins.json"
OUT="$T/prep-out"
run_prep good "$GOOD" "$OUT"
"${G[@]}" checkout -q "$GOOD" -- packaging/macos/agent_runtime_pins.json
if [ "$rc" -eq 0 ] && [ "$(ls "$OUT" 2>/dev/null | tr '\n' ' ')" = "inputs.sha256 py.pkg sites.tar " ] && cmp -s "$OUT/py.pkg" "$F/py.pkg" \
   && (cd "$OUT" && sha256sum --quiet -c inputs.sha256) && [ "$(tar -tf "$OUT/sites.tar" | grep -cE '^site-(x86_64|aarch64)/$')" -eq 2 ]; then
  ok "P1+P7: prep exits 0 with exactly py.pkg, sites.tar and a valid inputs.sha256, from the commit (the working-tree pins edit is ignored)"
else bad "P1/P7: exit $rc, output '$(ls "$OUT" 2>/dev/null | tr '\n' ' ')': $(tail -n 3 "$T/out.good" | tr '\n' ' ')"; fi
c0=$(argv_of curl.0 2>/dev/null) c1=$(argv_of curl.1 2>/dev/null)
if [ "$(calls curl)" -eq 2 ] && grep -q -- "--proto =https .*$URL \$" <<<"$c0" && grep -q -- "--proto =https .*$URL.sigstore \$" <<<"$c1"; then
  ok "P2: curl fetches exactly the pinned url and url.sigstore, with --proto =https"
else bad "P2: $(calls curl) curl call(s): '$c0' | '$c1'"; fi
p=$(for f in $(ls "$C" | grep -E '^uv\.[0-9]+$'); do a=$(argv_of "$f"); [[ "$a" == "pip install "* && "$a" != *--target* ]] && echo "$a"; done)
req=$(grep -oE -- '-r [^ ]+' <<<"$p" | cut -d' ' -f2)
if [ "$(grep -c . <<<"$p")" -eq 1 ] && [ "$(calls pip)" -eq 0 ] \
   && [[ "$p" == "pip install "* && " $p" == *" --python "*/venv/bin/python" "* && " $p" == *" --require-hashes "* && " $p" == *" --no-deps "* ]] \
   && [[ " $p" == *" --no-config "* && " $p" == *" --default-index https://pypi.org/simple "* && "$p" == *" -r "*/packaging/macos/sigstore_verifier.txt" " ]] \
   && [[ "$req" == "$T/tmp/zb-spike-prep-"*/packaging/macos/sigstore_verifier.txt ]]; then
  ok "P3: the verifier installs once as uv pip install --python <venv>/bin/python --require-hashes --no-deps -r <export>/packaging/macos/sigstore_verifier.txt"
else bad "P3: verifier install call(s): '$p', pip executable calls $(calls pip)"; fi
s=$(argv_of sigstore.0 2>/dev/null)
if [ "$(calls sigstore)" -eq 1 ] && [[ "$s" =~ ^-m\ sigstore\ verify\ identity\ --bundle\ [^\ ]+\.sigstore\ --cert-identity\ $ID\ --cert-oidc-issuer\ $ISSUER\ [^\ ]+/py\.pkg\ $ ]]; then
  ok "P4: the pkg is verified once with the pinned identity and issuer"
else bad "P4: $(calls sigstore) sigstore call(s): '$s'"; fi
conf=0 W=
for e in $(ls "$C" | grep -E '^(curl|uv|pip|sigstore)\.[0-9]+\.env$'); do
  while IFS== read -r k v; do
    if [[ "$v" == "$T/tmp/zb-spike-prep-"?????? || "$v" == "$T/tmp/zb-spike-prep-"??????/* ]]; then
      w=${v#"$T/tmp/"}; w=${w%%/*}; [ -z "$W" ] && W=$w; [ "$w" = "$W" ] || { bad "P5: $e $k=$v is in a different scratch tree"; conf=1; }
    else bad "P5: $e $k=$v is not inside prep's scratch tree"; conf=1; fi
  done < "$C/$e"
done
[ "$conf" -eq 0 ] && [ -n "$W" ] && ok "P5: every curl, uv, pip and sigstore call keeps HOME, XDG and the uv/pip caches in prep's scratch tree"
u=$(for f in $(ls "$C" | grep -E '^uv\.[0-9]+$'); do a=$(argv_of "$f"); [[ "$a" == "export "* ]] && echo "$a"; done)
[[ "$(grep -c . <<<"$u")" -eq 1 && "$u" == "export --project $T/tmp/zb-spike-prep-"*"/agent/host "* ]] && ok "P6: the site trees are built from the export's agent/host" \
  || bad "P6: the uv export call(s): '$u'"

# P8: refused before any network call.
for row in "bad-requirements $BADREQ" "bad-lock $BADLOCK" "no-identity $NOID"; do
  read -r label sha <<<"$row"
  run_prep "$label" "$sha" "$T/out-$label"
  { [ "$rc" -eq 1 ] && [ "$(calls curl)" -eq 0 ] && [ ! -e "$T/out-$label" ]; } \
    && ok "P8 $label: refused, exit 1, no curl call, no output dir" \
    || bad "P8 $label: exit $rc, $(calls curl) curl call(s), output dir $( [ -e "$T/out-$label" ] && echo exists || echo absent): $(tail -n 1 "$T/out.$label")"
done
mkdir -p "$T/exists"
run_prep exists "$GOOD" "$T/exists"
{ [ "$rc" -eq 1 ] && [ "$(calls curl)" -eq 0 ]; } && ok "P8 existing output dir: refused, no curl call" || bad "P8 existing output dir: exit $rc"

# P9: refused after the download.
rm -rf "${C:?}"/*; touch "$C/serve_bad"
(cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_GATE_COMMIT="$GOOD" \
   timeout 120 bash tests/mac/bundle_layout_spike.sh prep "$T/out-pkg-sha2" >"$T/out.pkg-sha2" 2>&1 </dev/null); rc=$?
{ [ "$rc" -eq 1 ] && [ ! -e "$T/out-pkg-sha2" ] && [ "$(calls sigstore)" -eq 0 ]; } \
  && ok "P9 pkg bytes not matching the pin: refused, exit 1, no output dir, no verification" \
  || bad "P9 pkg bytes not matching the pin: exit $rc, output $( [ -e "$T/out-pkg-sha2" ] && echo exists || echo absent)"
rm -rf "${C:?}"/*; echo 1 > "$C/sigstore_rc"
(cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_GATE_COMMIT="$GOOD" \
   timeout 120 bash tests/mac/bundle_layout_spike.sh prep "$T/out-sig" >"$T/out.sig" 2>&1 </dev/null); rc=$?
{ [ "$rc" -eq 1 ] && [ ! -e "$T/out-sig" ]; } && ok "P9 failed Sigstore verification: refused, exit 1, no output dir" \
  || bad "P9 failed Sigstore verification: exit $rc, output $( [ -e "$T/out-sig" ] && echo exists || echo absent)"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-bundle-layout-spike-prep-selftest\n'; exit 0; fi
printf 'FAIL\tmac-bundle-layout-spike-prep-selftest\t%s failure(s)\n' "$fails"
exit 1
