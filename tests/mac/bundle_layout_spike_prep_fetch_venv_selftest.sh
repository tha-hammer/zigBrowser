#!/usr/bin/env bash
# The 4pa.80 spike's PREP phase against the real system Python and the real uv, offline (SilverRidge 6ea4636b, after
# the released Stage A failed: Debian's /usr/bin/python3 has no ensurepip, so `python3 -m venv` exits 1). It runs the
# scaffolding of tests/mac/bundle_layout_spike_prep_selftest.sh (from its ROOT= line to its "# P1-P7:" marker: the
# private user+network namespace, the scratch repo at an exact commit with fixture pins, the recording helpers), then:
#   - removes the python3 stub, so prep's python3 is the real /usr/bin/python3;
#   - builds local stand-in wheels: sigstore 4.5.1 (its `python -m sigstore verify identity ...` records argv and the
#     interpreter's sys.prefix, exiting ctl/sigstore_rc) and standin-extra 1.0; new commits pin a verifier
#     requirements file hash-locked to the stand-in (good), one with an extra UNHASHED requirement (nohash) and one
#     with a wrong hash (badhash);
#   - wraps uv: `uv venv` and the verifier `uv pip install` (no --target) run the REAL uv, the install with its index
#     options swapped for `--offline --no-index --find-links <local wheels>`, all other arguments untouched; uv
#     export and the per-arch `--target` site installs stay recorded stand-ins; ctl/scenario=venv_fail makes uv venv
#     fail;
#   - replaces curl with an executing stand-in that honours -o, -w (%{http_code} %{url_effective} %{remote_ip}, \t,
#     \n), -L and --max-redirs like curl: a url in ctl/redirect answers 301 to https://elsewhere.invalid/... (refused,
#     exit 47, under -L --max-redirs 0; FOLLOWED, recorded in ctl/followed, under plain -L; a 301 body, exit 0,
#     without -L); a "<url> <code>" line in ctl/status answers that code with exit 0; a url in ctl/effmismatch answers
#     200 with a different url_effective.
# Rows:
#   V1 the real system Python: prep exits 0 with exactly py.pkg, sites.tar and a valid inputs.sha256, and the verifier
#      ran inside the created environment (the stand-in's sys.prefix is <scratch>/venv);
#   V2 the environment is made once as `uv venv` with --offline, --no-project, --no-config, --python /usr/bin/python3
#      and <scratch>/venv;
#   V3 the verifier installs once as `uv pip install` with --python <scratch>/venv/bin/python, --require-hashes,
#      --no-deps, --no-config, --default-index https://pypi.org/simple and -r <export>/packaging/macos/
#      sigstore_verifier.txt; both per-arch site installs carry --no-config and --default-index https://pypi.org/simple;
#      every uv call keeps HOME, XDG and the uv/pip caches in prep's scratch tree;
#   V4 each download prints FETCH<TAB><requested url><TAB><url_effective><TAB><remote ip><TAB><status>, effective url =
#      requested url, status 200;
#   V5 a redirect on the pkg url or on the bundle url is refused: exit 1, no output dir, nothing followed, no venv, no
#      sigstore call, and the output says redirect;
#   V6 a non-200 status (203) or an effective url that is not the requested one is refused the same way;
#   V7 a requirements file with an unhashed entry, or a wrong hash, is refused at the install: exit 1, no output dir,
#      "did not install", no sigstore call (after a venv was made and the install was tried);
#   V8 a failed venv creation is reported as such ("venv could not be created", not "did not install"): exit 1, no
#      output dir, no install tried.
# No network, no Mac. Run: bash tests/mac/bundle_layout_spike_prep_fetch_venv_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_SPIKEPREP_SELFTEST_INNER:-}" != 1 ]; then
  ZB_SPIKEPREP_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
REAL_UV=$(command -v uv) || { printf 'FAIL\tmac-bundle-layout-spike-prep-fetch-venv-selftest\tno uv on PATH\n'; exit 1; }
SCAFFOLD="$(realpath "${1:-.}")/tests/mac/bundle_layout_spike_prep_selftest.sh"
grep -q '^# P1-P7:' "$SCAFFOLD" || { echo "FAIL no scaffolding marker in $SCAFFOLD"; exit 1; }
# shellcheck source=/dev/null
source <(sed -n '/^ROOT=\$(realpath/,/^# P1-P7:/p' "$SCAFFOLD")
[ -x /usr/bin/python3 ] || { bad "no /usr/bin/python3"; exit 1; }
rm -f "$T/bin/python3"

# --- local stand-in wheels and the commits that hash-lock them ---
mkdir -p "$F/wheels"
/usr/bin/python3 -I - "$F/wheels" "$C" <<'PY'
import base64, hashlib, sys, zipfile
out, ctl = sys.argv[1:]
main = f'''import os, sys
C = {ctl!r}
n = len([f for f in os.listdir(C) if f.startswith("sigstore.") and f[9:].isdigit()])
open(f"{{C}}/sigstore.{{n}}", "wb").write(b"".join(a.encode() + b"\\0" for a in ["-m", "sigstore"] + sys.argv[1:]))
open(f"{{C}}/sigstore.{{n}}.prefix", "w").write(sys.prefix)
p = f"{{C}}/sigstore_rc"
sys.exit(int(open(p).read()) if os.path.exists(p) else 0)
'''
def wheel(name, version, files):
    dist = f"{name.replace('-', '_')}-{version}"
    files = dict(files)
    files[f"{dist}.dist-info/METADATA"] = f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n"
    files[f"{dist}.dist-info/WHEEL"] = "Wheel-Version: 1.0\nGenerator: selftest\nRoot-Is-Purelib: true\nTag: py3-none-any\n"
    rec = []
    for path, text in files.items():
        data = text.encode()
        digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode()
        rec.append(f"{path},sha256={digest},{len(data)}")
    rec.append(f"{dist}.dist-info/RECORD,,")
    files[f"{dist}.dist-info/RECORD"] = "\n".join(rec) + "\n"
    with zipfile.ZipFile(f"{out}/{dist}-py3-none-any.whl", "w") as z:
        for path, text in files.items():
            z.writestr(path, text)
wheel("sigstore", "4.5.1", {"sigstore/__init__.py": "", "sigstore/__main__.py": main})
wheel("standin-extra", "1.0", {"standin_extra/__init__.py": ""})
PY
WSHA=$(sha256sum "$F/wheels/sigstore-4.5.1-py3-none-any.whl" | cut -c1-64)
XSHA=$(sha256sum "$F/wheels/standin_extra-1.0-py3-none-any.whl" | cut -c1-64)
VR="$R/packaging/macos/sigstore_verifier.txt"
printf '# selftest verifier lock (the local stand-in)\nsigstore==4.5.1 \\\n    --hash=sha256:%s\n' "$WSHA" > "$VR"; write_pins "$ID"; GOOD=$(commit stand-in)
printf 'standin-extra==1.0\n' >> "$VR"; write_pins "$ID"; NOHASH=$(commit nohash)
printf '# selftest verifier lock (wrong hash)\nsigstore==4.5.1 \\\n    --hash=sha256:%s\n' "$XSHA" > "$VR"; write_pins "$ID"; BADHASH=$(commit badhash)
"${G[@]}" checkout -q "$GOOD" -- .

# --- uv: the real one for the venv and the verifier install ---
{ echo '#!/bin/bash'; rec uv; cat <<EOF
scen=\$(cat "$C/scenario" 2>/dev/null)
if [ "\$1" = venv ]; then
  [ "\$scen" = venv_fail ] && { echo "uv venv: failed (selftest scenario)" >&2; exit 2; }
  exec "$REAL_UV" "\$@"
fi
if [ "\$1" = pip ] && [ "\$2" = install ] && ! printf '%s\n' "\$@" | grep -qx -- --target; then
  a=() skip=
  for x in "\$@"; do
    if [ -n "\$skip" ]; then skip=; continue; fi
    case "\$x" in --default-index|--index-url|-i) skip=1 ;; --default-index=*|--index-url=*) ;; *) a+=("\$x") ;; esac
  done
  exec "$REAL_UV" "\${a[@]}" --offline --no-index --find-links "$F/wheels"
fi
if [ "\$1" = export ]; then
  while [ \$# -gt 0 ]; do [ "\$1" = -o ] && { echo "pinned==1.0 --hash=sha256:00" > "\$2"; break; }; shift; done
elif [ "\$1" = pip ] && [ "\$2" = install ]; then
  while [ \$# -gt 0 ]; do [ "\$1" = --target ] && { mkdir -p "\$2"; echo wheel > "\$2/stand-in.py"; break; }; shift; done
fi
exit 0
EOF
} > "$T/bin/uv"
# --- curl: an executing stand-in with curl's redirect semantics ---
{ echo '#!/bin/bash'; rec curl; cat <<EOF
out= url= wfmt= follow=no maxr=-1
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out=\$2; shift 2 ;; -w|--write-out) wfmt=\$2; shift 2 ;; --max-redirs) maxr=\$2; shift 2 ;;
    --proto|--proto-redir) shift 2 ;; -L|--location) follow=yes; shift ;;
    -[a-zA-Z]*) case "\$1" in *L*) follow=yes ;; esac; shift ;; -*) shift ;; *) url=\$1; shift ;;
  esac
done
body() { case "\$1" in
  $URL) if [ -e "$C/serve_bad" ]; then cp "$F/py.pkg.bad" "\$out"; else cp "$F/py.pkg" "\$out"; fi ;;
  $URL.sigstore) echo '{"bundle": "stand-in"}' > "\$out" ;;
  *) return 1 ;;
esac; }
wout() { # wout <code> <url_effective>
  [ -n "\$wfmt" ] || return 0
  local s=\$wfmt; s=\${s//%\{http_code\}/\$1}; s=\${s//%\{url_effective\}/\$2}; s=\${s//%\{remote_ip\}/2a04:4e42:400::223}
  printf '%b' "\$s"
}
body "\$url" || { echo "stub curl: unexpected url \$url" >&2; exit 22; }
if grep -qxF "\$url" "$C/redirect" 2>/dev/null; then
  if [ "\$follow" = yes ] && [ "\$maxr" = 0 ]; then rm -f "\$out"; wout 301 "\$url"; echo "curl: (47) Maximum (0) redirects followed" >&2; exit 47; fi
  if [ "\$follow" = yes ]; then echo "\$url" >> "$C/followed"; wout 200 "https://elsewhere.invalid/\${url##*/}"; exit 0; fi
  echo '<html>301 Moved Permanently</html>' > "\$out"; wout 301 "\$url"; exit 0
fi
code=\$(awk -v u="\$url" '\$1 == u { print \$2 }' "$C/status" 2>/dev/null)
if [ -n "\$code" ]; then wout "\$code" "\$url"; exit 0; fi
if grep -qxF "\$url" "$C/effmismatch" 2>/dev/null; then wout 200 "https://www.python.org/ftp/python/elsewhere/\${url##*/}"; exit 0; fi
wout 200 "\$url"
EOF
} > "$T/bin/curl"
chmod +x "$T/bin"/*

uv_call() { # uv_call <first word>: argv (space-joined) of every recorded uv call starting with it, in order
  local f
  for f in $(ls "$C" | grep -E '^uv\.[0-9]+$' | sort -t. -k2 -n); do
    [ "$(tr '\0' '\n' < "$C/$f" | head -n 1)" = "$1" ] && tr '\0' ' ' < "$C/$f" && echo
  done
}
has() { [[ " $1 " == *" $2 "* ]]; }   # has <argv line> <exact token sequence>
prep_keep() { # prep_keep <label> <commit>: like run_prep, but keeps the scenario files already in ctl/; sets rc
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_GATE_COMMIT="$2" \
     timeout 120 bash tests/mac/bundle_layout_spike.sh prep "$T/out-$1" >"$T/out.$1" 2>&1 </dev/null)
  rc=$?
}
refused() { # refused <label> <what> <pattern>: exit 1, no output dir, nothing followed, no venv, no sigstore, pattern in output
  if [ "$rc" -eq 1 ] && [ ! -e "$T/out-$1" ] && [ ! -s "$C/followed" ] && [ -z "$(uv_call venv)" ] && [ "$(calls sigstore)" -eq 0 ] \
     && grep -qiE "$3" "$T/out.$1"; then
    ok "$1: $2 is refused: exit 1, no output dir, nothing followed, no venv, no sigstore call"
  else bad "$1: exit $rc, output dir $( [ -e "$T/out-$1" ] && echo exists || echo absent), followed '$(cat "$C/followed" 2>/dev/null)', venv '$(uv_call venv)', sigstore $(calls sigstore): $(tail -n 2 "$T/out.$1" | tr '\n' ' ')"; fi
}

# ===== V1-V4: the real system Python and the real uv =====
rm -rf "${C:?}"/*
OUT="$T/out-v"
run_prep v "$GOOD" "$OUT"
venvs=$(uv_call venv)
W=$(grep -oE "$T/tmp/zb-spike-prep-[A-Za-z0-9]{6}" <<<"$venvs" | head -n 1)
if [ "$rc" -eq 0 ] && [ "$(ls "$OUT" 2>/dev/null | tr '\n' ' ')" = "inputs.sha256 py.pkg sites.tar " ] && cmp -s "$OUT/py.pkg" "$F/py.pkg" \
   && (cd "$OUT" && sha256sum --quiet -c inputs.sha256) && [ -n "$W" ] && [ "$(cat "$C/sigstore.0.prefix" 2>/dev/null)" = "$W/venv" ]; then
  ok "V1: with the real /usr/bin/python3, prep exits 0 with exactly py.pkg, sites.tar and a valid inputs.sha256; the verifier ran inside $W/venv"
else bad "V1: the verifier environment from the real system Python: exit $rc, output '$(ls "$OUT" 2>/dev/null | tr '\n' ' ')', verifier prefix '$(cat "$C/sigstore.0.prefix" 2>/dev/null)': $(tail -n 3 "$T/out.v" | tr '\n' ' ')"; fi
if [ "$(grep -c . <<<"$venvs")" -eq 1 ] && has "$venvs" --offline && has "$venvs" --no-project && has "$venvs" --no-config \
   && has "$venvs" "--python /usr/bin/python3" && [[ "$venvs" == *" $W/venv " ]]; then
  ok "V2: the environment is made once by uv venv --offline --no-project --no-config --python /usr/bin/python3 <scratch>/venv"
else bad "V2: uv venv calls '$(tr '\n' ';' <<<"$venvs")'"; fi
vin=$(uv_call pip | grep -v -- ' --target ')
sites=$(uv_call pip | grep -- ' --target ')
if [ "$(grep -c . <<<"$vin")" -eq 1 ] && has "$vin" "--python $W/venv/bin/python" && has "$vin" --require-hashes && has "$vin" --no-deps \
   && has "$vin" --no-config && has "$vin" "--default-index https://pypi.org/simple" \
   && has "$vin" "-r $W/repo/packaging/macos/sigstore_verifier.txt" && [ "$(calls pip)" -eq 0 ] \
   && [ "$(grep -c . <<<"$sites")" -eq 2 ] && [ "$(grep -c -- ' --no-config ' <<<"$sites")" -eq 2 ] \
   && [ "$(grep -c -- ' --default-index https://pypi.org/simple ' <<<"$sites")" -eq 2 ]; then
  ok "V3: the verifier installs once by uv pip install --python <venv>/bin/python --require-hashes --no-deps --no-config --default-index https://pypi.org/simple -r <pinned requirements>; both site installs pin --no-config and the index"
else bad "V3: verifier install '$(tr '\n' ';' <<<"$vin")', site installs '$(tr '\n' ';' <<<"$sites")'"; fi
conf=0
for e in $(ls "$C" | grep -E '^uv\.[0-9]+\.env$'); do
  while IFS== read -r k v; do [[ -n "$W" && ( "$v" == "$W" || "$v" == "$W"/* ) ]] || { bad "V3: $e $k=$v is not inside prep's scratch tree"; conf=1; }; done < "$C/$e"
done
if [ -z "$W" ]; then bad "V3: no uv venv call named prep's scratch tree, so the uv cache environment is unproven"
elif [ "$conf" -eq 0 ]; then ok "V3: every uv call keeps HOME, XDG and the uv/pip caches in prep's scratch tree"; fi
fetches=$(grep -P '^FETCH\t' "$T/out.v")
want=$(printf 'FETCH\t%s\t%s\t2a04:4e42:400::223\t200\nFETCH\t%s\t%s\t2a04:4e42:400::223\t200' "$URL" "$URL" "$URL.sigstore" "$URL.sigstore")
[ "$fetches" = "$want" ] && ok "V4: each download prints FETCH with its requested url, url_effective (equal), remote ip and status 200" \
  || bad "V4: FETCH lines are '$(tr '\t\n' ' ;' <<<"$fetches")'"

# ===== V5-V6: no redirect, no non-200, no other effective url =====
for which in pkg bundle; do
  u=$URL; [ "$which" = bundle ] && u=$URL.sigstore
  rm -rf "${C:?}"/*; printf '%s\n' "$u" > "$C/redirect"
  prep_keep "redirect-$which" "$GOOD"; refused "redirect-$which" "a redirect on the $which url" redirect
done
rm -rf "${C:?}"/*; printf '%s 203\n' "$URL.sigstore" > "$C/status"
prep_keep status203 "$GOOD"; refused status203 "status 203 on the bundle url" '203'
rm -rf "${C:?}"/*; printf '%s\n' "$URL" > "$C/effmismatch"
prep_keep effmismatch "$GOOD"; refused effmismatch "an effective url other than the pkg url" 'elsewhere'

# ===== V7: the verifier install is hash-locked =====
for row in "nohash $NOHASH" "badhash $BADHASH"; do
  read -r label sha <<<"$row"
  rm -rf "${C:?}"/*
  prep_keep "$label" "$sha"
  if [ "$rc" -eq 1 ] && [ ! -e "$T/out-$label" ] && [ -n "$(uv_call venv)" ] && [ -n "$(uv_call pip | grep -v -- ' --target ')" ] \
     && [ "$(calls sigstore)" -eq 0 ] && grep -q 'did not install' "$T/out.$label"; then
    ok "V7 $label: the verifier install refuses it: exit 1, no output dir, no sigstore call"
  else bad "V7 $label: exit $rc, output dir $( [ -e "$T/out-$label" ] && echo exists || echo absent), sigstore $(calls sigstore): $(tail -n 2 "$T/out.$label" | tr '\n' ' ')"; fi
done

# ===== V8: a failed venv creation is named as such =====
rm -rf "${C:?}"/*; echo venv_fail > "$C/scenario"
prep_keep venvfail "$GOOD"
if [ "$rc" -eq 1 ] && [ ! -e "$T/out-venvfail" ] && grep -q 'venv could not be created' "$T/out.venvfail" \
   && ! grep -q 'did not install' "$T/out.venvfail" && [ -z "$(uv_call pip | grep -v -- ' --target ')" ]; then
  ok "V8: a failed venv creation is reported as such: exit 1, no output dir, no install tried"
else bad "V8: exit $rc, output dir $( [ -e "$T/out-venvfail" ] && echo exists || echo absent): $(tail -n 2 "$T/out.venvfail" | tr '\n' ' ')"; fi

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-bundle-layout-spike-prep-fetch-venv-selftest\n'; exit 0; fi
printf 'FAIL\tmac-bundle-layout-spike-prep-fetch-venv-selftest\t%s failure(s)\n' "$fails"
exit 1
