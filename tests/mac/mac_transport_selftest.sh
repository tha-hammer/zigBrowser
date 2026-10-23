#!/usr/bin/env bash
# Hostless selftest of the SHARED Mac transport: tests/mac/build-on-mac.sh and tests/mac/mac_gate_lib.sh (mac_ssh_opts,
# mac_scp_opts), which every build-on-mac caller uses (bd zigBrowser-3ui.9; the rule SilverRidge fe4542e applied to
# ms5_gate.sh: an inherited askpass could open a password window on the owner's desktop). Two real runs against a stub
# ssh/scp that records each argv and environment, both launched with DISPLAY, WAYLAND_DISPLAY, XAUTHORITY and
# SSH_ASKPASS set: build-on-mac.sh on its own, and packaging/macos/build-dmg.sh (mac_build plus the library's ssh and
# scp). For EVERY ssh/scp call:
#   T1 none of DISPLAY, WAYLAND_DISPLAY, XAUTHORITY or SSH_ASKPASS reaches ssh/scp;
#   T2 StrictHostKeyChecking=yes, UserKnownHostsFile = the repo's tests/mac/known_hosts, BatchMode=yes,
#      IdentitiesOnly=yes (kept, as tests/mac/build_on_mac_selftest.sh and mac_gate_callers_selftest.sh also require);
#   T3 each run reaches its end (build-on-mac's PASS line; build-dmg's "==> Done: ") and makes at least one ssh call,
#      and the build-dmg run at least one scp call (not vacuous).
# No Mac, no signal: it re-runs itself in a private user+network namespace; HOME/TMPDIR live in its temp tree.
# Run: bash tests/mac/mac_transport_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_TRANSPORT_SELFTEST_INNER:-}" != 1 ]; then
  ZB_TRANSPORT_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-transport-selftest-XXXXXX")
T=$(realpath "$BASE")
printf 'not a real key\n' > "$T/fake_mac_key"   # tests/mac/mac_config.sh needs a readable regular key file (bd 3ui.13)
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-transport-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
HOST=intel@10.0.0.1 ARM=arm@10.0.0.2   # build-dmg.sh builds on both Macs (the universal .app)

mkdir -p "$T/bin" "$T/ctl" "$T/home" "$T/tmp"
for tool in ssh scp; do
  cat > "$T/bin/$tool" <<EOF
#!/bin/bash
i=\$(cat "$T/ctl/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "$T/ctl/n"
printf '%s\0' $tool "\$@" > "$T/ctl/call.\$i"
printf 'DISPLAY=%s WAYLAND_DISPLAY=%s XAUTHORITY=%s SSH_ASKPASS=%s\n' "\${DISPLAY-<unset>}" "\${WAYLAND_DISPLAY-<unset>}" \
  "\${XAUTHORITY-<unset>}" "\${SSH_ASKPASS-<unset>}" > "$T/ctl/env.\$i"
cat > /dev/null
if [ $tool = scp ]; then   # a fetch: leave a stub file where the remote file lands
  dst="\${@: -1}" src="\${@: -2:1}"
  case "\$dst" in *:*) ;; *) if [ -d "\$dst" ]; then echo stub > "\$dst/\$(basename "\${src#*:}")"; else echo stub > "\$dst"; fi ;; esac
fi
exit 0
EOF
  chmod +x "$T/bin/$tool"
done

R="$T/repo"
mkdir -p "$R/tests/mac" "$R/packaging/macos" "$R/packaging/assets" "$R/src"
cp "$ROOT/tests/mac/build-on-mac.sh" "$ROOT/tests/mac/mac_gate_lib.sh" "$ROOT/tests/mac/mac_config.sh" "$ROOT/tests/mac/known_hosts" \
  "$R/tests/mac/"
cp "$ROOT/packaging/macos/build-dmg.sh" "$ROOT/packaging/macos/Info.plist" "$R/packaging/macos/"
cp "$ROOT/packaging/assets/zigBrowser.png" "$R/packaging/assets/"
echo "// stand-in" > "$R/src/main.zig"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
PINNED=$(realpath "$R/tests/mac/known_hosts")

check() { # check <label> <command> <its end line, as a grep -E pattern>
  local label=$1 cmd=$2 want=$3 rc n i j tool skip opt key val where before=$fails nssh=0 nscp=0
  local -a a strict khf batch ident
  rm -f "$T/ctl"/*
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$HOST" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/fake_mac_key" DISPLAY=:99 WAYLAND_DISPLAY=wayland-selftest XAUTHORITY="$T/home/.Xauthority" \
     SSH_ASKPASS="$T/bin/askpass-must-not-run" timeout 120 bash $cmd >"$T/out" 2>&1 </dev/null)
  rc=$?
  n=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
  for ((i = 0; i < n; i++)); do
    mapfile -d '' a < "$T/ctl/call.$i"
    tool=${a[0]} skip= strict=() khf=() batch=() ident=()
    [ "$tool" = ssh ] && nssh=$((nssh + 1)); [ "$tool" = scp ] && nscp=$((nscp + 1))
    for ((j = 1; j < ${#a[@]}; j++)); do
      if [ -n "$skip" ]; then skip=; continue; fi
      opt=
      case "${a[j]}" in -o) opt=${a[j+1]:-}; skip=1 ;; -o?*) opt=${a[j]#-o} ;; -i|-F|-p|-P|-l|-c|-J) skip=1; continue ;; *) continue ;; esac
      key=${opt%%[= ]*} val=${opt#*[= ]}
      case "${key,,}" in
        stricthostkeychecking) strict+=("${val,,}") ;; userknownhostsfile) khf+=("$val") ;;
        batchmode) batch+=("${val,,}") ;; identitiesonly) ident+=("${val,,}") ;;
      esac
    done
    where="$label call $i ($tool)"
    grep -qx 'DISPLAY=<unset> WAYLAND_DISPLAY=<unset> XAUTHORITY=<unset> SSH_ASKPASS=<unset>' "$T/ctl/env.$i" \
      || bad "T1: $where runs with a display or askpass: $(cat "$T/ctl/env.$i")"
    [ "${strict[*]}" = yes ] || bad "T2: $where StrictHostKeyChecking is '${strict[*]}', want yes"
    { [ "${#khf[@]}" -eq 1 ] && [ "$(realpath -m "${khf[0]}")" = "$PINNED" ]; } \
      || bad "T2: $where UserKnownHostsFile is '${khf[*]}', want the pinned $PINNED"
    [ "${batch[*]}" = yes ] || bad "T2: $where BatchMode is '${batch[*]}', want yes"
    [ "${ident[*]}" = yes ] || bad "T2: $where IdentitiesOnly is '${ident[*]}', want yes"
  done
  if [ "$rc" -eq 0 ] && grep -qE "$want" "$T/out" && [ "$nssh" -ge 1 ]; then ok "$label T3: the run reaches its end ($nssh ssh, $nscp scp)"
  else bad "$label T3: exit $rc, $nssh ssh call(s): $(tail -n 2 "$T/out" | tr '\n' ' ')"; fi
  [ "$fails" -eq "$before" ] && ok "$label: all $n ssh/scp calls run with no display or askpass, pinned host keys and BatchMode"
}

check build-on-mac tests/mac/build-on-mac.sh $'^PASS\tbuild-on-mac\t'
check build-dmg    packaging/macos/build-dmg.sh '^==> Done: '
n=$(cat "$T/ctl/n" 2>/dev/null || echo 0); scps=0
for ((i = 0; i < n; i++)); do [ "$(head -c 3 "$T/ctl/call.$i")" = scp ] && scps=$((scps + 1)); done
[ "$scps" -ge 1 ] || bad "build-dmg T3: no scp call (the library's mac_scp_opts was not exercised)"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-transport-selftest\n'; exit 0; fi
printf 'FAIL\tmac-transport-selftest\t%s failure(s)\n' "$fails"
exit 1
