#!/usr/bin/env bash
# Hostless selftest: tests/mac/ms5_setup_refusal_gate.sh and tests/mac/ms5_setup_e2e.sh reach the Macs only with the
# pinned host keys in the repo (bd zigBrowser-3ui.5.1; SilverRidge fe4542e: they set StrictHostKeyChecking=yes but no
# UserKnownHostsFile, so they trusted whatever the operator's unversioned ~/.ssh/known_hosts held). Each real script
# runs in a scratch git repo against a stub ssh/scp that records its argv and environment. For EVERY ssh/scp call
# ("-o Key=Value" and "-oKey=Value" both read; keys are case-insensitive):
#   H1 StrictHostKeyChecking is given and every value is "yes" (no "no", "accept-new" or "off");
#   H2 UserKnownHostsFile is given exactly once and is the repo's tests/mac/known_hosts (not /dev/null, not ~/.ssh);
#   H3 BatchMode=yes and IdentitiesOnly=yes are given (no password or askpass prompt can open);
#   H4 ssh/scp run without DISPLAY, WAYLAND_DISPLAY, XAUTHORITY or SSH_ASKPASS, although the script was launched with
#      all four;
#   H5 the host is one of the two configured Macs;
#   H6 the run reaches its end (exit 0, its both-arches PASS line) with at least one ssh and one scp per Mac, so the
#      checks cannot pass vacuously.
# The same rows as tests/mac/ms5_gate_hostkey_selftest.sh. No Mac, no signal: HOME/TMPDIR in this test's temp tree;
# it re-runs itself in a private user+network namespace.
# Run: bash tests/mac/ms5_setup_hostkey_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_MS5SETUPHOSTKEY_SELFTEST_INNER:-}" != 1 ]; then
  ZB_MS5SETUPHOSTKEY_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-ms5setuphostkey-selftest-XXXXXX")
T=$(realpath "$BASE")
printf 'not a real key\n' > "$T/fake_mac_key"   # tests/mac/mac_config.sh needs a readable regular key file (bd 3ui.13)
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-ms5setuphostkey-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2

mkdir -p "$T/bin" "$T/ctl" "$T/home" "$T/tmp"
for tool in ssh scp; do
  cat > "$T/bin/$tool" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' $tool "\$@" > "$T/ctl/call.\$i"
printf 'DISPLAY=%s WAYLAND_DISPLAY=%s XAUTHORITY=%s SSH_ASKPASS=%s\n' "\${DISPLAY-<unset>}" "\${WAYLAND_DISPLAY-<unset>}" \
  "\${XAUTHORITY-<unset>}" "\${SSH_ASKPASS-<unset>}" > "$T/ctl/env.\$i"
cat > /dev/null
exit 0
EOF
  chmod +x "$T/bin/$tool"
done

# The scratch repo: the real scripts, their helper, the pinned host keys, and stand-ins for what they archive.
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/src" "$R/packaging" "$R/agent" "$R/tools"
for f in ms5_setup_refusal_gate.sh ms5_setup_e2e.sh lib_group_cleanup.sh mac_config.sh known_hosts; do cp "$ROOT/tests/mac/$f" "$R/tests/mac/"; done
echo "// stand-in" > "$R/src/main.zig"
echo x > "$R/packaging/x"; echo x > "$R/agent/x"; echo x > "$R/tools/x"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
PINNED=$(realpath "$R/tests/mac/known_hosts")

check() { # check <label> <script> <its both-arches PASS line's start>
  local label=$1 script=$2 want=$3 rc n i j tool host skip opt key val where before=$fails
  local -a a strict khf batch ident pos
  local -A seen=()
  rm -f "$T/ctl"/*
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" \
     ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$T/fake_mac_key" DISPLAY=:99 WAYLAND_DISPLAY=wayland-selftest \
     XAUTHORITY="$T/home/.Xauthority" SSH_ASKPASS="$T/bin/askpass-must-not-run" \
     timeout 120 bash "$script" >"$T/out" 2>&1 </dev/null)
  rc=$?
  if [ "$rc" -eq 0 ] && grep -q "^$want" "$T/out"; then ok "$label: the run reaches its end"
  else bad "$label H6: exit $rc, want 0 with the both-arches PASS line: $(tail -n 2 "$T/out" | tr '\n' ' ')"; fi
  n=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
  for ((i = 0; i < n; i++)); do
    mapfile -d '' a < "$T/ctl/call.$i"
    tool=${a[0]} host= skip= strict=() khf=() batch=() ident=() pos=()
    for ((j = 1; j < ${#a[@]}; j++)); do
      if [ -n "$skip" ]; then skip=; continue; fi
      opt=
      case "${a[j]}" in
        -o) opt=${a[j+1]:-}; skip=1 ;;
        -o?*) opt=${a[j]#-o} ;;
        -i|-F|-p|-P|-l|-c|-J) skip=1; continue ;;
        -*) continue ;;
        *) pos+=("${a[j]}"); continue ;;
      esac
      key=${opt%%[= ]*} val=${opt#*[= ]}
      case "${key,,}" in
        stricthostkeychecking) strict+=("${val,,}") ;;
        userknownhostsfile) khf+=("$val") ;;
        batchmode) batch+=("${val,,}") ;;
        identitiesonly) ident+=("${val,,}") ;;
      esac
    done
    if [ "$tool" = ssh ]; then host=${pos[0]:-}; else host=${pos[${#pos[@]}-1]:-}; host=${host%%:*}; fi
    where="$label call $i ($tool $host)"
    [ "$host" = "$INTEL" ] || [ "$host" = "$ARM" ] || bad "H5: $where goes to an unexpected host"
    seen[$tool:$host]=1
    if [ "${#strict[@]}" -ge 1 ] && [ -z "$(printf '%s\n' "${strict[@]}" | grep -vx yes)" ]; then :
    else bad "H1: $where StrictHostKeyChecking is '${strict[*]}', want yes"; fi
    if [ "${#khf[@]}" -eq 1 ] && [ "$(realpath -m "${khf[0]}")" = "$PINNED" ]; then :
    else bad "H2: $where UserKnownHostsFile is '${khf[*]}', want exactly the pinned $PINNED"; fi
    [ "${batch[*]}" = yes ] || bad "H3: $where BatchMode is '${batch[*]}', want yes"
    [ "${ident[*]}" = yes ] || bad "H3: $where IdentitiesOnly is '${ident[*]}', want yes"
    grep -qx 'DISPLAY=<unset> WAYLAND_DISPLAY=<unset> XAUTHORITY=<unset> SSH_ASKPASS=<unset>' "$T/ctl/env.$i" \
      || bad "H4: $where runs with a display or askpass: $(cat "$T/ctl/env.$i")"
  done
  for host in "$INTEL" "$ARM"; do
    for tool in ssh scp; do
      [ -n "${seen[$tool:$host]:-}" ] || bad "$label H6: no $tool call reached $host (the checks would be vacuous)"
    done
  done
  [ "$fails" -eq "$before" ] && ok "$label: all $n ssh/scp calls use the pinned host keys, BatchMode, and no display or askpass"
}

check ms5-setup-refusal tests/mac/ms5_setup_refusal_gate.sh $'PASS\tms5-setup-refusal-gate\tboth-arches\t'
check ms5-setup-e2e     tests/mac/ms5_setup_e2e.sh          $'PASS\tms5-setup-e2e\tboth-arches\t'

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-ms5-setup-hostkey-selftest\n'; exit 0; fi
printf 'FAIL\tmac-ms5-setup-hostkey-selftest\t%s failure(s)\n' "$fails"
exit 1
