#!/usr/bin/env bash
# Hostless rows for the 4pa.80 slice-2 audit classifier at the runner boundary (SilverRidge a365949c, 7f3b4c70). It
# runs the scaffolding of tests/mac/bundle_layout_spike_containment_selftest.sh (from its ROOT= line up to its
# "# ===== K1-K4: clean =====" marker), so the real runner, leg driver and tests/mac/bundle_layout_spike_audit.py (taken
# from the commit) are driven. There the fake getconf names the Darwin user dirs through an alias outside the home
# (alias-<role> -> private/<role>/var, as macOS resolves /var through /private/var), and the fake sandbox keeps them
# read-only. On top, four test seams, each selected only by the scenario name:
#   - sandbox-exec: ambient:<role> / ambient_deny:<role> touch only the mtime of that host's ~/Library/Caches between
#     the audits (a reviewed TS shape); linkroot:<role> has the TEMP root entry itself replaced by a symlink first;
#   - codesign: ambient_deny:<role> also prints a denial in that host's verify log;
#   - python3: tamper changes audit.classified after the classifier has printed its SHA-256;
#   - ssh: nocanary / twocanary drop or double the driver's canary proof line.
# Rows:
#   A1 a clean run: LAYOUT-OK on both legs with no AMBIENT; each leg's evidence/audit.roots is exactly TEMP and CACHE
#      (given: the alias path, physical: the resolved one, link=no), CACHES, HOME and RUN; both snapshots use only the
#      physical Darwin user paths; audit.classified says AUDIT-CLEAN;
#   A2 an ambient-only delta on Intel: exit 0, Intel LAYOUT-OK with "audit AMBIENT 1", arm64 without; audit.classified
#      has the CACHES root as TS-CACHES-ROOT AMBIENT and AUDIT-AMBIENT; the runner's MANIFEST line is the SHA-256 of
#      <ev>/manifest.sha256, which lists exactly the required evidence files once each in byte order (never itself)
#      and verifies; without audit.classified, or with it changed, the manifest no longer verifies;
#   A3 the same delta beside a denial: INCONCLUSIVE (the denial), never LAYOUT-OK;
#   A4 a K10-style change (~/Library/Caches/com.apple.existing/data): INCONCLUSIVE "audit UNKNOWN: CACHES
#      com.apple.existing/data";
#   A5 a TEMP root that is itself a symlink: link=yes, the classifier refuses (rc 2): INCONCLUSIVE, no audit.classified;
#   A6 audit.classified changed after the classifier printed its SHA-256: INCONCLUSIVE;
#   A7 no canary proof line, or two: INCONCLUSIVE;
#   A8 a commit without the classifier: refused before any host is touched (exit 1, no ssh/scp).
# No Mac, no signal, no network. Run: bash tests/mac/bundle_layout_spike_audit_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_CONTAIN_SELFTEST_INNER:-}" != 1 ]; then
  ZB_CONTAIN_SELFTEST_INNER=1 exec unshare --user --map-root-user --mount --net bash "$(realpath "$0")" "$@"
fi
SCAFFOLD="$(realpath "${1:-.}")/tests/mac/bundle_layout_spike_containment_selftest.sh"
grep -q '^# ===== K1-K4: clean =====$' "$SCAFFOLD" || { echo "FAIL no scaffolding marker in $SCAFFOLD"; exit 1; }
# shellcheck source=/dev/null
source <(sed -n '/^ROOT=\$(realpath/,/^# ===== K1-K4: clean =====$/p' "$SCAFFOLD")

mv "$P/usrbin/sandbox-exec" "$P/usrbin/sandbox-exec.scaffold"
fake "$P/usrbin/sandbox-exec" <<'EOF'
scen=$(cat "$C/scenario") H=$(cd "$HOME" && pwd -P)
case "$scen" in
  ambient:*|ambient_deny:*)   # once, at the first outer command: only the mtime of ~/Library/Caches changes
    if [ "${scen#*:}" = "${ZB_ROLE:-}" ] && [ "${3:-}" = /bin/bash ] && [ ! -e "$C/ambient.done" ]; then
      : > "$C/ambient.done"; touch -m -d @1799999999 "$H/Library/Caches"
    fi ;;
  linkroot:*)   # before anything: the TEMP root entry itself becomes a symlink to a real directory beside it
    t="$X/private/${ZB_ROLE:-none}/var/folders/zz/zyxw/T"
    if [ "${scen#*:}" = "${ZB_ROLE:-}" ] && [ ! -L "$t" ]; then mv "$t" "$t.real" && ln -s T.real "$t"; fi ;;
esac
exec /usr/bin/sandbox-exec.scaffold "$@"
EOF
mv "$X/hostbin/codesign" "$X/hostbin/codesign.scaffold"
fake "$X/hostbin/codesign" <<'EOF'
scen=$(cat "$C/scenario")
case " $* " in *" --verify "*) [ "$scen" = "ambient_deny:${ZB_ROLE:-}" ] && echo "${@: -1}: Operation not permitted" ;; esac
exec "$X/hostbin/codesign.scaffold" "$@"
EOF
mv "$P/usrbin/python3" "$P/usrbin/python3.scaffold"
fake "$P/usrbin/python3" <<'EOF'
case "$(cat "$C/scenario") $*" in
  "tamper "*bundle_layout_spike_audit.py*|"tamper "*/audit.py*)
    "$P/usrbin/python3.scaffold" "$@"; rc=$?
    printf 'DELTA\ttampered\n' >> "${@: -1}/audit.classified"
    exit "$rc" ;;
esac
exec "$P/usrbin/python3.scaffold" "$@"
EOF
mv "$X/bin/ssh" "$X/bin/ssh.inner"
fake "$X/bin/ssh" <<'EOF'
case "$(cat "$C/scenario") $*" in
  "nocanary "*" run "*) "$X/bin/ssh.inner" "$@" | grep -vP '^PHASE\tcanaries\tok\t'; exit "${PIPESTATUS[0]}" ;;
  "twocanary "*" run "*) "$X/bin/ssh.inner" "$@" | sed '/^PHASE\tcanaries\tok\t/p'; exit "${PIPESTATUS[0]}" ;;
esac
exec "$X/bin/ssh.inner" "$@"
EOF
evd() { ls -d "$IN"/evidence/"$1"-zb-gate-* 2>/dev/null | head -n 1; }   # <arch>: the leg's evidence dir
restore_temp() { local r t; for r in intel arm; do t="$X/private/$r/var/folders/zz/zyxw/T"; [ -L "$t" ] && rm "$t" && mv "$t.real" "$t"; done; }

# ===== A1: a clean run records the physical roots and classifies CLEAN =====
run_spike clean none clean both
if [ "$rc" -eq 0 ] && [ "$(spike_result)" = "x86_64=LAYOUT-OK arm64=LAYOUT-OK" ] && ! grep -q 'AMBIENT' <<<"$out"; then
  ok "clean A1: exit 0, LAYOUT-OK on both legs, no AMBIENT"
else bad "clean A1: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)' '$(leg_class arm64): $(leg_detail arm64)'"; fi
for role in intel arm; do
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  ev=$(evd "$arch") H="$X/hosts/$role" rt=$(root_of "$role")
  want=$(printf 'ROOT\t%s\t%s\t%s\tlink=no\n' TEMP "$X/alias-$role/folders/zz/zyxw/T" "$X/private/$role/var/folders/zz/zyxw/T" \
    CACHE "$X/alias-$role/folders/zz/zyxw/C" "$X/private/$role/var/folders/zz/zyxw/C" CACHES "$H/Library/Caches" "$H/Library/Caches" \
    HOME "$H" "$H" RUN "$rt" "$rt")
  if [ -n "$ev" ] && [ "$(cat "$ev/evidence/audit.roots" 2>/dev/null)" = "$want" ] \
     && grep -q "^$X/private/$role/var/folders/zz/zyxw/T/resident|" "$ev/evidence/audit.before" \
     && grep -q "^$X/private/$role/var/folders/zz/zyxw/C/resident|" "$ev/evidence/audit.after" \
     && ! grep -q "^$X/alias-" "$ev/evidence/audit.before" "$ev/evidence/audit.after" \
     && grep -qxP 'VERDICT\tAUDIT-CLEAN' "$ev/audit.classified" 2>/dev/null; then
    ok "clean A1 $role: audit.roots names the alias and the physical Darwin user dirs (link=no), the snapshots use only the physical paths, AUDIT-CLEAN"
  else bad "clean A1 $role: roots '$(tr '\t\n' ' ;' < "$ev/evidence/audit.roots" 2>/dev/null)', verdict '$(tail -n 1 "$ev/audit.classified" 2>/dev/null)'"; fi
done

# ===== A2: an ambient-only delta, its classification and the evidence manifest =====
run_spike ambient ambient:intel clean both
ev=$(evd x86_64)
if [ "$rc" -eq 0 ] && [ "$(leg_class x86_64)" = LAYOUT-OK ] && [ "$(leg_detail x86_64)" = "verify rc 0; audit AMBIENT 1" ] \
   && [ "$(leg_detail arm64)" = "verify rc 0" ] \
   && grep -qP "^DELTA\tCACHES\t\.\tDirectory\|[0-7]+\|[0-9]+\|[0-9]+\|[0-9]+\tDirectory\|[0-7]+\|[0-9]+\|[0-9]+\|1799999999\tTS-CACHES-ROOT\tAMBIENT$" "$ev/audit.classified" \
   && grep -qxP 'VERDICT\tAUDIT-AMBIENT' "$ev/audit.classified"; then
  ok "ambient A2: Intel LAYOUT-OK with 'audit AMBIENT 1', arm64 without; audit.classified holds the CACHES root as TS-CACHES-ROOT AMBIENT"
else bad "ambient A2: exit $rc, '$(leg_detail x86_64)' '$(leg_detail arm64)', classified: $(grep -E '^(DELTA|VERDICT)' "$ev/audit.classified" 2>/dev/null | tr '\t\n' ' ;')"; fi
want_files="audit.classified driver.out evidence/audit.after evidence/audit.before evidence/audit.roots evidence/build.log evidence/census.log evidence/profile evidence/relocate.log evidence/sign.log evidence/stage.log evidence/verify.log"
mline=$(grep -P '^MANIFEST\tx86_64\t' <<<"$out")
if [ -s "$ev/manifest.sha256" ] && [ "$mline" = "$(printf 'MANIFEST\tx86_64\t%s' "$(sha256sum < "$ev/manifest.sha256" | cut -c1-64)")" ] \
   && [ "$(awk '{ print $2 }' "$ev/manifest.sha256" | tr '\n' ' ')" = "$want_files " ] \
   && (cd "$ev" && sha256sum --quiet -c manifest.sha256); then
  ok "ambient A2: MANIFEST is the SHA-256 of manifest.sha256, which lists exactly the required evidence once each in byte order and verifies"
else bad "ambient A2: MANIFEST '$mline', listed: $(awk '{ print $2 }' "$ev/manifest.sha256" 2>/dev/null | tr '\n' ' ')"; fi
b0=absent b1= b2=
if [ -s "$ev/manifest.sha256" ] && [ -s "$ev/audit.classified" ]; then   # the broken cases only count against a manifest that verifies
  cp -a "$ev" "$T/ev.copy"
  (cd "$T/ev.copy" && sha256sum --quiet -c manifest.sha256 >/dev/null 2>&1) && b0=verified || b0=broken
  rm "$T/ev.copy/audit.classified"; (cd "$T/ev.copy" && sha256sum --quiet -c manifest.sha256 >/dev/null 2>&1) && b1=verified || b1=broken
  cp "$ev/audit.classified" "$T/ev.copy/"; echo x >> "$T/ev.copy/audit.classified"
  (cd "$T/ev.copy" && sha256sum --quiet -c manifest.sha256 >/dev/null 2>&1) && b2=verified || b2=broken
fi
[ "$b0 $b1 $b2" = "verified broken broken" ] && ok "ambient A2: without audit.classified, or with it changed, the manifest no longer verifies" \
  || bad "ambient A2: manifest check as is/without/changed audit.classified: $b0 $b1 $b2"
rm -rf "${T:?}/ev.copy"

# ===== A3: ambient beside a denial =====
run_spike ambient_deny ambient_deny:intel clean both
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [[ "$(leg_detail x86_64)" == *denied* ]] && [ "$(leg_class arm64)" = LAYOUT-OK ]; } \
  && ok "ambient_deny A3: an ambient delta beside a denial is INCONCLUSIVE ($(leg_detail x86_64))" \
  || bad "ambient_deny A3: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)'"

# ===== A4: a K10-style change is UNKNOWN =====
run_spike unknown audit:intel:change:caches clean both
{ [ "$rc" -eq 2 ] && [ "$(leg_detail x86_64)" = "audit UNKNOWN: CACHES com.apple.existing/data" ] && [ "$(leg_class arm64)" = LAYOUT-OK ]; } \
  && ok "unknown A4: INCONCLUSIVE '$(leg_detail x86_64)'" || bad "unknown A4: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)'"
for role in intel arm; do d="$X/hosts/$role/Library/Caches/com.apple.existing/data"; echo resident > "$d"; chmod 644 "$d"; done

# ===== A5: a TEMP root that is itself a symlink =====
run_spike linkroot linkroot:intel clean both
ev=$(evd x86_64)
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [[ "$(leg_detail x86_64)" == "the audit classifier failed (rc 2): AUDIT-ERROR"*"symlink"* ]] \
  && grep -qP '^ROOT\tTEMP\t.*\tlink=yes$' "$ev/evidence/audit.roots" && [ ! -e "$ev/audit.classified" ] && [ "$(leg_class arm64)" = LAYOUT-OK ]; } \
  && ok "linkroot A5: link=yes is refused by the classifier: INCONCLUSIVE ($(leg_detail x86_64)), no audit.classified" \
  || bad "linkroot A5: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)', roots: $(tr '\t\n' ' ;' < "$ev/evidence/audit.roots" 2>/dev/null)"
restore_temp

# ===== A6: audit.classified changed after its SHA-256 was printed =====
run_spike tamper tamper clean both
{ [ "$rc" -eq 2 ] && [ "$(spike_result)" = "x86_64=INCONCLUSIVE arm64=INCONCLUSIVE" ] \
  && [ "$(leg_detail x86_64)" = "audit.classified does not match the SHA-256 the classifier printed" ]; } \
  && ok "tamper A6: a changed audit.classified is INCONCLUSIVE on both legs" || bad "tamper A6: exit $rc, '$(leg_detail x86_64)'"

# ===== A7: the canary proof must be there exactly once =====
for scen in nocanary twocanary; do
  run_spike "$scen" "$scen" clean both
  { [ "$rc" -eq 2 ] && [ "$(spike_result)" = "x86_64=INCONCLUSIVE arm64=INCONCLUSIVE" ] \
    && [ "$(leg_detail arm64)" = "the driver output does not hold exactly one canary proof" ]; } \
    && ok "$scen A7: INCONCLUSIVE on both legs ($(leg_detail arm64))" || bad "$scen A7: exit $rc, '$(leg_detail arm64)'"
done

# ===== A8: the classifier comes from the commit =====
"${G[@]}" rm -q tests/mac/bundle_layout_spike_audit.py && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m 'no classifier' \
  || { bad "could not commit without the classifier"; exit 1; }
run_spike noclassifier none clean both
{ [ "$rc" -eq 1 ] && grep -q "REFUSED: the audit classifier tests/mac/bundle_layout_spike_audit.py is missing at $("${G[@]}" rev-parse HEAD)" <<<"$out" \
  && [ ! -s "$C/calls" ]; } && ok "noclassifier A8: refused before any host is touched, exit 1, no ssh/scp" \
  || bad "noclassifier A8: exit $rc: $(tail -n 2 <<<"$out" | tr '\n' ' ')"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-bundle-layout-spike-audit-selftest\n'; exit 0; fi
printf 'FAIL\tmac-bundle-layout-spike-audit-selftest\t%s failure(s)\n' "$fails"
exit 1
