#!/usr/bin/env bash
# Hostless rows for the 4pa.80 relocated-layout hypothesis (SilverRidge a365949c, slice 1). It runs the scaffolding of
# tests/mac/bundle_layout_spike_containment_selftest.sh (from its ROOT= line up to its "# ===== K1-K4: clean ====="
# marker: the private user+mount+network namespace, the /usr/bin overlay with the enforcing fake sandbox-exec, the
# executing stub ssh/scp, the fake Mac homes and tools, the scratch repo and the helpers), so the real runner and leg
# driver are driven. On top of it:
#   - the stand-in stager stages the real agent-host shape: the exact Python framework of the python.org payload
#     (Headers, Python, Resources -> Versions/Current/..., Versions/{3.12,Current -> 3.12}), zb_agent_host, runtime.json,
#     a pure-data package (jwt), a mixed package (rpds) and the bundled CLI, every code file with real Mach-O magic;
#     the zig stand-in builds Mach-O outputs; `file` reads the magic bytes, never the name;
#   - the committed packaging/macos/relocate_agent_data.py is part of the scratch repo, so the leg runs the real helper;
#   - codesign derives its result from the tree it inspects and never sees the mode: signing a .app, or a main
#     executable (Contents/MacOS/<exe> beside Contents/Info.plist), seals that bundle, and every regular non-Mach-O file
#     under its Contents/Frameworks that is not inside a framework whose main binary was already signed makes it print
#     "<target>: code object is not signed at all" and "In subcomponent: <the first such path>" and exit 1, as the
#     released Stage B showed on both Macs. Test scenarios only widen or narrow that model (links_unsigned: links under
#     Frameworks count too; links_detritus: the same with another diagnostic; sign_ignores_data; sign_app_only), or
#     inject a generic error, a denial, or a changed subcomponent, for the INCONCLUSIVE and SIGN-FINDING rows.
# Modes: ZB_SPIKE_MUTANT=none is the candidate (relocated layout); ZB_SPIKE_MUTANT=stray_in_frameworks is the control
# (the same, plus the pinned stray file Contents/Frameworks/agent-host/zb-4pa80-stray.txt, "zb-4pa80-control\n",
# mode 644, written after the relocation). Each run writes <prep>/evidence/SPIKE-RESULT.<mode>; the control runs only
# when SPIKE-RESULT.none is exactly the candidate's LAYOUT-OK line on both Macs at this commit; a second run of a mode
# on the same prep dir is refused (one attempt, no retry). Per leg the driver prints, for every failed signing call,
#   SIGNFAIL<TAB><target below spike/><TAB>not-signed|other<TAB><subcomponent below the .app>|-<TAB>
#     file-data|file-macho|link|dir|missing|-<TAB><lstat mode>|-<TAB><sha256>|-
# then PHASE<TAB>sign<TAB>finding<TAB><n> and no verify.
# Rows:
#   L1 candidate, clean: exit 0, LAYOUT-OK on both legs, SPIKE-RESULT none; the helper ran inside the sandbox (relocate
#      and census, through python3) and its RELOCATED line is in the evidence; census 0; the verified tree has jwt,
#      zb_agent_host and runtime.json as links in Frameworks and real in Resources, the CLI real in Frameworks; every
#      expected sign target exactly once (the seven Mach-O files deepest first, then Versions/3.12, then the .app last),
#      nothing below Resources and no link signed, ad hoc, never --deep; one verify, last; no SIGNFAIL;
#      SPIKE-RESULT.none holds the result line;
#   L2 control after L1: exit 0, EXPECTED-FAIL on both legs, SPIKE-RESULT stray_in_frameworks; census 1; exactly two
#      SIGNFAIL lines per leg, exe then app, each not-signed naming the stray file as file-data, 644, its pinned hash;
#      every sign target exactly once, the .app last; no verify;
#   L3 the control is refused (exit 1, no ssh/scp) with no candidate result, with a candidate result that is not
#      LAYOUT-OK on both, with a LAYOUT-OK result for another commit, and with a candidate that never ended (STARTED);
#   L4 candidate whose signing fails with the not-signed diagnostic (links_unsigned): SIGN-FINDING on both legs, exit 0,
#      its SIGNFAIL lines name a link; the control is then refused;
#   L5 candidate INCONCLUSIVE, exit 2: a generic sign error (one SIGNFAIL, the .app, class other); a failure with
#      another diagnostic that names a subcomponent (links_detritus: "detritus not allowed"); a relocation refusal (a staged hard link: PHASE relocate
#      fail, no codesign call); a non-Mach-O file under Frameworks outside agent-host (census 1, want 0); a denied
#      signing tool;
#   L6 control INCONCLUSIVE after a LAYOUT-OK candidate, exit 2: no sign failure (wrong stage), only the app failing
#      (a missing failure), extra failures naming other subcomponents, a generic error on the app (wrong diagnostic), a
#      changed stray hash, a changed stray mode, a stray replaced by a link (wrong kind), a second data file under
#      Frameworks (census 2, though the two failures still name the stray file first), a denied signing tool;
#   L7 one attempt: each run's SPIKE-RESULT.<mode> already says STARTED<TAB><sha><TAB><mode> at its first host contact;
#      a second candidate after L1, a second control after L2, and a candidate after one that never ended are refused
#      (exit 1, no ssh/scp).
# No Mac, no signal, no network. Run: bash tests/mac/bundle_layout_spike_layout_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_CONTAIN_SELFTEST_INNER:-}" != 1 ]; then
  ZB_CONTAIN_SELFTEST_INNER=1 exec unshare --user --map-root-user --mount --net bash "$(realpath "$0")" "$@"
fi
SCAFFOLD="$(realpath "${1:-.}")/tests/mac/bundle_layout_spike_containment_selftest.sh"
grep -q '^# ===== K1-K4: clean =====$' "$SCAFFOLD" || { echo "FAIL no scaffolding marker in $SCAFFOLD"; exit 1; }
# shellcheck source=/dev/null
source <(sed -n '/^ROOT=\$(realpath/,/^# ===== K1-K4: clean =====$/p' "$SCAFFOLD")

STRAY=Contents/Frameworks/agent-host/zb-4pa80-stray.txt
STRAY_SHA=$(printf 'zb-4pa80-control\n' | sha256sum | cut -c1-64)
EXE=zigBrowser.app/Contents/MacOS/zigBrowser
MACHO_FILES=$(printf '%s\n' "$APP/Contents/MacOS/zigBrowser" "$APP/Contents/Frameworks/libwkwebview_shim.dylib" \
  "$APP/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/Python" \
  "$APP/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12" \
  "$APP/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/lib/python3.12/lib-dynload/_json.cpython-312-darwin.so" \
  "$APP/Contents/Frameworks/agent-host/site-packages/claude_agent_sdk/_bundled/claude" \
  "$APP/Contents/Frameworks/agent-host/site-packages/rpds/rpds.cpython-312-darwin.so" | sort)

# --- `file` by magic bytes: thin Mach-O, or FAT with a plausible slice count (a Java class file is not Mach-O) ---
fake "$X/hostbin/file" <<'EOF'
NAME=file; printf "%s\t%s\t%s\t%s\n" "$NAME" "${ZB_FAKE_SANDBOXED:-0}" "${ZB_ROLE:-}" "$*" >> "$C/tools.log"
[ "$1" = -b ] && shift
h=$(od -An -tx1 -N8 "$1" 2>/dev/null | tr -d ' \n')
case "$h" in
  cffaedfe*|cefaedfe*|feedfacf*|feedface*) echo "Mach-O 64-bit executable"; exit 0 ;;
  cafebabe*|cafebabf*) n=$((16#${h:8:8})); [ "$n" -ge 1 ] && [ "$n" -lt 20 ] && { echo "Mach-O universal binary with $n architectures"; exit 0; } ;;
esac
echo "ASCII text"
EOF
for role in intel arm; do
  fake "$X/hosts/$role/.local/bin/zig" <<'EOF'
NAME=zig; printf "%s\t%s\t%s\t%s\n" "$NAME" "${ZB_FAKE_SANDBOXED:-0}" "${ZB_ROLE:-}" "$*" >> "$C/tools.log"
xcrun --show-sdk-path >/dev/null
mkdir -p zig-out/bin zig-out/Frameworks
printf '\xca\xfe\xba\xbe\x00\x00\x00\x02 zigBrowser stand-in\n' > zig-out/bin/zigBrowser
printf '\xca\xfe\xba\xbe\x00\x00\x00\x02 shim stand-in\n' > zig-out/Frameworks/libwkwebview_shim.dylib
chmod 755 zig-out/bin/zigBrowser zig-out/Frameworks/libwkwebview_shim.dylib
echo "build ok"
EOF
done

# --- codesign: the result comes from the tree it inspects (and the earlier signing calls), never from the mode ---
fake "$X/hostbin/codesign" <<'EOF'
NAME=codesign; printf "%s\t%s\t%s\t%s\n" "$NAME" "${ZB_FAKE_SANDBOXED:-0}" "${ZB_ROLE:-}" "$*" >> "$C/tools.log"
tgt=${@: -1}
rel=${tgt#*/zb-gate-*/}
kind=missing; if [ -L "$tgt" ]; then kind=symlink; elif [ -d "$tgt" ]; then kind=dir; elif [ -f "$tgt" ]; then kind=file; fi
printf '%s\t%s\t%s\n' "$rel" "$kind" "$*" >> "$C/signs.$ZB_ROLE"
scen=$(cat "$C/scenario")
macho() {
  local h; h=$(od -An -tx1 -N8 "$1" 2>/dev/null | tr -d ' \n')
  case "$h" in cffaedfe*|cefaedfe*|feedfacf*|feedface*) return 0 ;; cafebabe*|cafebabf*) [ $((16#${h:8:8})) -ge 1 ] && [ $((16#${h:8:8})) -lt 20 ] ;; *) return 1 ;; esac
}
case " $* " in *" --verify "*)
  (cd "$tgt" && find . -printf '%p %y\n' | sort) > "$C/tree.$ZB_ROLE"
  echo "$tgt: valid on disk"; echo "$tgt: satisfies its Designated Requirement"; exit 0 ;;
esac
[ "$scen" = deny_tool ] && { echo "$tgt: Operation not permitted"; exit 1; }
bundle=
case "$tgt" in
  *.app) [ "$kind" = dir ] && bundle=$tgt ;;
  */Contents/MacOS/*) [ "$scen" = sign_app_only ] || { [ -f "${tgt%/MacOS/*}/Info.plist" ] && bundle=${tgt%/Contents/MacOS/*}; } ;;
esac
[ -n "$bundle" ] || exit 0
[ "$scen" = sign_generic ] && [ "$kind" = dir ] && { echo "$tgt: internal error in Code Signing subsystem"; exit 1; }
# frameworks whose main binary was signed earlier are sealed code; their contents are not loose subcomponents
sealed=()
while IFS= read -r fw; do
  name=$(basename "$fw" .framework)
  fwrel=${fw#*/zb-gate-*/}
  grep -qE "^${fwrel}/Versions/[^/]+/${name}"$'\t'"file"$'\t' "$C/signs.$ZB_ROLE" && sealed+=("$fw/")
done < <(find "$bundle/Contents/Frameworks" -type d -name '*.framework' | sort)
first=
while IFS= read -r p; do
  for s in "${sealed[@]+"${sealed[@]}"}"; do case "$p" in "$s"*) continue 2 ;; esac; done
  if [ -L "$p" ]; then
    [ "$scen" = links_unsigned ] || [ "$scen" = links_detritus ] || { [ "$scen" = stray_link ] && [[ "$p" == */zb-4pa80-stray.txt ]]; } || continue
  elif [ "$scen" = sign_ignores_data ] || macho "$p"; then continue; fi
  first=$p; break
done < <(find "$bundle/Contents/Frameworks" \( -type f -o -type l \) | LC_ALL=C sort)
[ -n "$first" ] || exit 0
case "$scen" in
  stray_changed) [[ "$first" == */zb-4pa80-stray.txt ]] && echo extra >> "$first" ;;
  stray_mode) [[ "$first" == */zb-4pa80-stray.txt ]] && chmod 600 "$first" ;;
  stray_link) [[ "$first" == */zb-4pa80-stray.txt ]] && [ ! -L "$first" ] && rm "$first" && ln -s ../../Resources/agent-host/runtime.json "$first" ;;
esac
if [ "$scen" = links_detritus ]; then echo "$tgt: resource fork, Finder information, or similar detritus not allowed"
else echo "$tgt: code object is not signed at all"; fi
echo "In subcomponent: $first"
exit 1
EOF

# --- the stand-in stager: the real agent-host shape, code with real Mach-O magic ---
fake "$R/packaging/macos/stage_agent_runtime.sh" <<'EOF'
# Selftest stand-in: records its arguments, resolves python like the real stager, stages the agent-host shape.
NAME=stager; printf "%s\t%s\t%s\t%s\n" "$NAME" "${ZB_FAKE_SANDBOXED:-0}" "${ZB_ROLE:-}" "$*" >> "$C/tools.log"
printf '%s\n' "$@" > "$C/stager.$ZB_ROLE"
xcrun --find python3 >/dev/null
/usr/bin/python3 -I -c 'import sys' || exit 1
[ -s "$1" ] && [ -d "$4" ] && [ -d "$5" ] || { echo "stand-in stager: missing input" >&2; exit 1; }
macho() { mkdir -p "$(dirname "$1")" && printf '\xca\xfe\xba\xbe\x00\x00\x00\x02 stand-in\n' > "$1" && chmod 755 "$1"; }
data() { mkdir -p "$(dirname "$1")" && printf '%s\n' "$2" > "$1" && chmod 644 "$1"; }
A="$3/Frameworks/agent-host"; F="$A/Python.framework"; V="$F/Versions/3.12"
macho "$V/Python"; macho "$V/bin/python3.12"; macho "$V/lib/python3.12/lib-dynload/_json.cpython-312-darwin.so"
data "$V/lib/python3.12/os.py" 'import sys'; data "$V/Resources/Info.plist" '<plist/>'
data "$V/include/python3.12/Python.h" '/* */'
data "$V/lib/python3.12/site-packages/zb_agent_host_sdk.pth" '../../../../../../site-packages'
ln -s include/python3.12 "$V/Headers"; ln -s 3.12 "$F/Versions/Current"
for n in Headers Python Resources; do ln -s "Versions/Current/$n" "$F/$n"; done
data "$A/zb_agent_host/__init__.py" '# agent'; data "$A/zb_agent_host/token.py" '# token'; data "$A/runtime.json" '{}'
macho "$A/site-packages/claude_agent_sdk/_bundled/claude"; data "$A/site-packages/claude_agent_sdk/__init__.py" ''
data "$A/site-packages/jwt/__init__.py" '# jwt'; data "$A/site-packages/jwt/utils.py" '# utils'
macho "$A/site-packages/rpds/rpds.cpython-312-darwin.so"; data "$A/site-packages/rpds/__init__.py" ''
case "$(cat "$C/scenario")" in
  hard_link) ln "$A/runtime.json" "$A/site-packages/runtime-copy.json" ;;
  extra_data) data "$3/Frameworks/notes.txt" 'outside agent-host' ;;
esac
exit 0
EOF
echo committed > "$R/agent/host/marker"
[ -e "$ROOT/packaging/macos/relocate_agent_data.py" ] && cp "$ROOT/packaging/macos/relocate_agent_data.py" "$R/packaging/macos/"
"${G[@]}" add -A && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m layout \
  || { bad "could not commit the layout stand-ins"; exit 1; }
echo uncommitted > "$R/agent/host/marker"
SHA=$("${G[@]}" rev-parse HEAD)
# the result records as they are at the first host contact of each run
printf 'IN=%q\n' "$IN" >> "$X/fake.env"
mv "$X/bin/ssh" "$X/bin/ssh.inner"
fake "$X/bin/ssh" <<'EOF'
[ -e "$C/first.ssh" ] || for m in none stray_in_frameworks; do
  printf '%s\t%s\n' "$m" "$(head -n 1 "$IN/evidence/SPIKE-RESULT.$m" 2>/dev/null | cut -f1-3)"
done > "$C/first.ssh"
exec "$X/bin/ssh.inner" "$@"
EOF

run_layout() { # run_layout <label> <scenario> [VAR=value ...]: run_spike that keeps the prep evidence (the candidate result)
  local label=$1 scen=$2; shift 2
  rm -rf "${C:?}"/*
  echo "$scen" > "$C/scenario"; echo clean > "$C/verify_mode"; echo both > "$C/verify_where"
  ls -d "$IN"/evidence/*-zb-gate-* 2>/dev/null | sort > "$T/ev.before"
  (cd "$R" && env -i PATH="$X/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/home/no_such_key" ZB_SPIKE_REMOVE_SLEEP=0 "$@" timeout 300 bash tests/mac/bundle_layout_spike.sh run "$IN" \
     >"$T/out.$label" 2>&1 </dev/null)
  rc=$?
  out=$(cat "$T/out.$label")
}
fresh() { rm -rf "${IN:?}/evidence"; find "${X:?}/hosts" -maxdepth 2 -name 'zb-gate-*' -type d -exec rm -rf {} +; }
new_ev() { # <arch>: the evidence dir this run made for that arch
  comm -13 "$T/ev.before" <(ls -d "$IN"/evidence/*-zb-gate-* 2>/dev/null | sort) | grep "/$1-zb-gate-" | head -n 1
}
signfails() { grep -P '^SIGNFAIL\t' "$(new_ev "$1")/driver.out" 2>/dev/null; }
census() { grep -P '^SPIKE\tcensus\t' "$(new_ev "$1")/driver.out" 2>/dev/null | cut -f3; }
result_line() { printf 'SPIKE-RESULT\t%s\t%s\tx86_64=%s\tarm64=%s' "$SHA" "$1" "$2" "$3"; }
check_signs() { # <label> <role> <verify calls wanted>: every sign target exactly once, the .app last
  local label=$1 role=$2 want_verify=$3 before=$fails
  local log="$C/signs.$role" signs files dirs last nverify
  signs=$(grep -v -- '--verify' "$log" 2>/dev/null)
  nverify=$(grep -c -- '--verify' "$log" 2>/dev/null)
  files=$(awk -F'\t' '$2 == "file" { print $1 }' <<<"$signs" | sort)
  dirs=$(awk -F'\t' '$2 == "dir" { print $1 }' <<<"$signs" | tr '\n' ' ')
  last=$(tail -n 1 <<<"$signs" | cut -f1)
  [ -n "$signs" ] && [ -z "$(cut -f1 <<<"$signs" | sort | uniq -d)" ] || bad "$label $role: a sign target is missing or signed twice"
  [ "$files" = "$MACHO_FILES" ] || bad "$label $role: the signed files are not exactly the seven Mach-O files: $(tr '\n' ' ' <<<"$files")"
  [ "$dirs" = "$APP/Contents/Frameworks/agent-host/Python.framework/Versions/3.12 $APP " ] || bad "$label $role: signed directories '$dirs'"
  [ "$last" = "$APP" ] || bad "$label $role: the last signing call is '$last', not the .app"
  ! grep -q $'\tsymlink\t' <<<"$signs" && ! grep -q '/Contents/Resources/' <<<"$signs" || bad "$label $role: a link or a Resources path was signed"
  ! grep -q -- '--deep' <<<"$signs" && [ -z "$(grep -v -- '--sign -' <<<"$signs")" ] || bad "$label $role: signing is not ad hoc without --deep"
  [ "$nverify" = "$want_verify" ] || bad "$label $role: $nverify verify calls, want $want_verify"
  if [ "$want_verify" != 0 ]; then
    local lastcall; lastcall=$(tail -n 1 "$log")
    [ "$(cut -f1 <<<"$lastcall")" = "$APP" ] && grep -q -- '--verify' <<<"$lastcall" || bad "$label $role: the verify is not the last codesign call"
  fi
  [ "$fails" -eq "$before" ] && ok "$label $role: every sign target once (seven Mach-O files, Versions/3.12, the .app last), ad hoc, no link or Resources path; $want_verify verify"
}
calls_none() { [ ! -s "$C/calls" ]; }

# ===== L1: the candidate, clean =====
fresh
run_layout candidate none
if [ "$rc" -eq 0 ] && [ "$(leg_class x86_64)" = LAYOUT-OK ] && [ "$(leg_class arm64)" = LAYOUT-OK ] \
   && grep -qxF "$(result_line none LAYOUT-OK LAYOUT-OK)" <<<"$out" \
   && [ "$(cat "$IN/evidence/SPIKE-RESULT.none" 2>/dev/null)" = "$(result_line none LAYOUT-OK LAYOUT-OK)" ]; then
  ok "candidate L1: exit 0, LAYOUT-OK on both legs, SPIKE-RESULT none, recorded in SPIKE-RESULT.none"
else bad "candidate L1: exit $rc: $(grep -E '^(LEG|SPIKE-RESULT|PHASE)|REFUSED|FAIL' <<<"$out" | tail -n 6 | tr '\n' ' ')"; fi
for role in intel arm; do
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  ev=$(new_ev "$arch")
  rel=$(awk -F'\t' -v r="$role" '$1 == "python3" && $3 == r && $4 ~ /relocate_agent_data\.py relocate / { print $2 }' "$C/tools.log" 2>/dev/null | tr '\n' ' ')
  cen=$(awk -F'\t' -v r="$role" '$1 == "python3" && $3 == r && $4 ~ /relocate_agent_data\.py census / { print $2 }' "$C/tools.log" 2>/dev/null | tr '\n' ' ')
  if [ "$rel" = "1 " ] && [ "$cen" = "1 " ] && grep -qP '^PHASE\trelocate\tok' "$ev/driver.out" 2>/dev/null \
     && grep -qP '^RELOCATED\tfiles=\d+\tdirs=\d+\tlinks=\d+$' "$ev/evidence/relocate.log" 2>/dev/null && [ "$(census "$arch")" = 0 ] \
     && [ -z "$(signfails "$arch")" ]; then
    ok "candidate L1 $role: the helper ran once each for relocate and census, inside the sandbox; RELOCATED in the evidence; census 0; no SIGNFAIL"
  else bad "candidate L1 $role: relocate sandboxed '$rel', census sandboxed '$cen', census '$(census "$arch")', SIGNFAIL '$(signfails "$arch" | head -n 1)'"; fi
  tree=$(cat "$C/tree.$role" 2>/dev/null)
  want="./Contents/Frameworks/agent-host/runtime.json l
./Contents/Frameworks/agent-host/site-packages/claude_agent_sdk/_bundled/claude f
./Contents/Frameworks/agent-host/site-packages/jwt l
./Contents/Frameworks/agent-host/zb_agent_host l
./Contents/Resources/agent-host/runtime.json f
./Contents/Resources/agent-host/site-packages/jwt d
./Contents/Resources/agent-host/zb_agent_host d"
  got=$(grep -E '^\./Contents/(Frameworks|Resources)/agent-host/(runtime\.json|zb_agent_host|site-packages/jwt|site-packages/claude_agent_sdk/_bundled/claude) ' <<<"$tree")
  [ "$got" = "$want" ] && ok "candidate L1 $role: the verified tree is the relocated layout (links in Frameworks, data in Resources, the CLI in place)" \
    || bad "candidate L1 $role: the verified tree has: $(tr '\n' ';' <<<"$got")"
  check_signs "candidate L1" "$role" 1
done
[ "$(grep -P '^none\t' "$C/first.ssh" 2>/dev/null)" = "$(printf 'none\tSTARTED\t%s\tnone' "$SHA")" ] \
  && ok "candidate L1 L7: SPIKE-RESULT.none says STARTED for this commit before the first host contact" \
  || bad "candidate L1 L7: at the first host contact the records were: $(tr '\n' ';' < "$C/first.ssh" 2>/dev/null)"

# ===== L7a: one attempt =====
run_layout candidate_again none
{ [ "$rc" -eq 1 ] && grep -q 'REFUSED: .*already holds' <<<"$out" && calls_none; } \
  && ok "candidate_again L7: a second candidate on the same prep dir is refused, exit 1, no ssh/scp" \
  || bad "candidate_again L7: exit $rc, ssh/scp calls $(wc -l < "$C/calls" 2>/dev/null || echo 0): $(tail -n 2 <<<"$out" | tr '\n' ' ')"

# ===== L2: the control, after the LAYOUT-OK candidate =====
run_layout control none ZB_SPIKE_MUTANT=stray_in_frameworks
if [ "$rc" -eq 0 ] && [ "$(leg_class x86_64)" = EXPECTED-FAIL ] && [ "$(leg_class arm64)" = EXPECTED-FAIL ] \
   && grep -qxF "$(result_line stray_in_frameworks EXPECTED-FAIL EXPECTED-FAIL)" <<<"$out"; then
  ok "control L2: exit 0, EXPECTED-FAIL on both legs, SPIKE-RESULT stray_in_frameworks"
else bad "control L2: exit $rc: $(grep -E '^(LEG|SPIKE-RESULT|PHASE)|REFUSED|FAIL' <<<"$out" | tail -n 6 | tr '\n' ' ')"; fi
want_sf=$(printf 'SIGNFAIL\t%s\tnot-signed\t%s\tfile-data\t644\t%s\nSIGNFAIL\t%s\tnot-signed\t%s\tfile-data\t644\t%s' \
  "$EXE" "$STRAY" "$STRAY_SHA" zigBrowser.app "$STRAY" "$STRAY_SHA")
for role in intel arm; do
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  { [ "$(signfails "$arch")" = "$want_sf" ] && [ "$(census "$arch")" = 1 ] \
    && grep -qP '^PHASE\tsign\tfinding\t2$' "$(new_ev "$arch")/driver.out"; } \
    && ok "control L2 $role: census 1; exactly two SIGNFAIL lines, exe then app, not-signed, the stray file, file-data 644, its pinned hash" \
    || bad "control L2 $role: census '$(census "$arch")', SIGNFAIL: $(signfails "$arch" | tr '\n' ';')"
  check_signs "control L2" "$role" 0
done
[ "$(cat "$C/first.ssh" 2>/dev/null)" = "$(printf 'none\t%s\nstray_in_frameworks\tSTARTED\t%s\tstray_in_frameworks' "$(result_line none LAYOUT-OK LAYOUT-OK | cut -f1-3)" "$SHA")" ] \
  && ok "control L2 L7: SPIKE-RESULT.stray_in_frameworks says STARTED before the first host contact, beside the candidate's result" \
  || bad "control L2 L7: at the first host contact the records were: $(tr '\n' ';' < "$C/first.ssh" 2>/dev/null)"
run_layout control_again none ZB_SPIKE_MUTANT=stray_in_frameworks
{ [ "$rc" -eq 1 ] && grep -q 'REFUSED: .*already holds' <<<"$out" && calls_none; } \
  && ok "control_again L7: a second control on the same prep dir is refused, exit 1, no ssh/scp" \
  || bad "control_again L7: exit $rc: $(tail -n 2 <<<"$out" | tr '\n' ' ')"

fresh; mkdir -p "$IN/evidence"; printf 'STARTED\t%s\tnone\n' "$SHA" > "$IN/evidence/SPIKE-RESULT.none"
run_layout interrupted none
{ [ "$rc" -eq 1 ] && grep -q 'REFUSED: .*already holds a none result' <<<"$out" && calls_none; } \
  && ok "interrupted L7: a candidate that started and never ended blocks another, exit 1, no ssh/scp" \
  || bad "interrupted L7: exit $rc: $(tail -n 2 <<<"$out" | tr '\n' ' ')"

# ===== L3: the control needs the candidate's LAYOUT-OK on both, at this commit =====
for case_ in none finding othercommit started; do
  fresh; mkdir -p "$IN/evidence"
  case "$case_" in
    started) printf 'STARTED\t%s\tnone\n' "$SHA" > "$IN/evidence/SPIKE-RESULT.none" ;;
    finding) result_line none LAYOUT-OK LAYOUT-FINDING > "$IN/evidence/SPIKE-RESULT.none" ;;
    othercommit) printf 'SPIKE-RESULT\t%040d\tnone\tx86_64=LAYOUT-OK\tarm64=LAYOUT-OK\n' 7 > "$IN/evidence/SPIKE-RESULT.none" ;;
  esac
  run_layout "gate_$case_" none ZB_SPIKE_MUTANT=stray_in_frameworks
  { [ "$rc" -eq 1 ] && grep -q 'REFUSED: the control runs only after the candidate is LAYOUT-OK on both' <<<"$out" && calls_none; } \
    && ok "gate_$case_ L3: the control is refused, exit 1, no ssh/scp" \
    || bad "gate_$case_ L3: exit $rc: $(tail -n 2 <<<"$out" | tr '\n' ' ')"
done

# ===== L4: a candidate signing finding refutes the hypothesis and stops the request =====
fresh
run_layout sign_finding links_unsigned
sf=$(signfails x86_64 | head -n 1)
{ [ "$rc" -eq 0 ] && [ "$(spike_result)" = "x86_64=SIGN-FINDING arm64=SIGN-FINDING" ] \
  && [ "$(cut -f3,5 <<<"$sf")" = "not-signed	link" ] && [ "$(cut -f2 <<<"$sf")" = "$EXE" ]; } \
  && ok "sign_finding L4: a not-signed signing failure on the candidate is SIGN-FINDING on both legs, exit 0, naming a link" \
  || bad "sign_finding L4: exit $rc, result '$(spike_result)', first SIGNFAIL '$sf'"
run_layout sign_finding_control none ZB_SPIKE_MUTANT=stray_in_frameworks
{ [ "$rc" -eq 1 ] && grep -q 'REFUSED: the control runs only after' <<<"$out" && calls_none; } \
  && ok "sign_finding L4: the control is then refused" || bad "sign_finding L4: the control after SIGN-FINDING: exit $rc"

# ===== L5: candidate INCONCLUSIVE =====
for scen in sign_generic links_detritus hard_link extra_data deny_tool; do
  fresh
  run_layout "cand_$scen" "$scen"
  d=$(leg_detail x86_64)
  case "$scen" in
    sign_generic|links_detritus) why='without the not-signed diagnostic' ;; hard_link) why='relocate' ;; extra_data) why='census 1, want 0' ;;
    deny_tool) why='denied' ;;
  esac
  extra=ok
  [ "$scen" != hard_link ] || [ ! -s "$C/signs.intel" ] || extra="codesign ran after a refused relocation"
  [ "$scen" != sign_generic ] || [ "$(signfails x86_64 | cut -f2,3)" = "zigBrowser.app	other" ] || extra="SIGNFAIL '$(signfails x86_64 | tr '\n' ';')'"
  { [ "$rc" -eq 2 ] && [ "$(spike_result)" = "x86_64=INCONCLUSIVE arm64=INCONCLUSIVE" ] && [[ "$d" == *"$why"* ]] && [ "$extra" = ok ]; } \
    && ok "cand_$scen L5: INCONCLUSIVE on both legs ($d), exit 2" \
    || bad "cand_$scen L5: exit $rc, result '$(spike_result)', '$d', $extra"
done

# ===== L6: control INCONCLUSIVE, each after a LAYOUT-OK candidate =====
for scen in sign_ignores_data sign_app_only links_unsigned sign_generic stray_changed stray_mode stray_link extra_data deny_tool; do
  fresh
  run_layout "pre_$scen" none
  [ "$(spike_result)" = "x86_64=LAYOUT-OK arm64=LAYOUT-OK" ] || { bad "ctl_$scen L6: the candidate was not LAYOUT-OK ($(spike_result))"; continue; }
  run_layout "ctl_$scen" "$scen" ZB_SPIKE_MUTANT=stray_in_frameworks
  case "$scen" in
    sign_ignores_data) why='wrong stage' ;; sign_app_only) why='1 sign failures' ;;
    links_unsigned) why='agent-host/runtime.json link' ;; sign_generic) why='zigBrowser.app other' ;;
    stray_changed) why="zb-4pa80-stray.txt file-data 644 " ;; stray_mode) why='zb-4pa80-stray.txt file-data 600' ;;
    stray_link) why='zb-4pa80-stray.txt link' ;; extra_data) why='control census 2, want 1' ;; deny_tool) why='denied' ;;
  esac
  { [ "$rc" -eq 2 ] && [ "$(spike_result)" = "x86_64=INCONCLUSIVE arm64=INCONCLUSIVE" ] && ! grep -q EXPECTED-FAIL <<<"$out" \
    && [[ "$(leg_detail x86_64)" == *"$why"* ]] && [[ "$(leg_detail arm64)" == *"$why"* ]]; } \
    && ok "ctl_$scen L6: the control is INCONCLUSIVE on both legs ($(leg_detail x86_64)), exit 2" \
    || bad "ctl_$scen L6: exit $rc, result '$(spike_result)', '$(leg_detail x86_64)'"
done
fresh

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-bundle-layout-spike-layout-selftest\n'; exit 0; fi
printf 'FAIL\tmac-bundle-layout-spike-layout-selftest\t%s failure(s)\n' "$fails"
exit 1
