#!/usr/bin/env bash
# Hostless oracle: no Mac script reaches a Mac unless the operator names the hosts and the key explicitly (bd
# zigBrowser-3ui.13, SilverRidge a473a027). Every production Mac transport script takes its hosts and key from ONE
# shared helper, tests/mac/mac_config.sh, which has no host or key default:
#   mac_config one   needs ZB_MAC_HOST and ZB_MAC_KEY;
#   mac_config two   also needs ZB_MAC_ARM_HOST; ZB_MAC_ARM_KEY may default only to the explicit ZB_MAC_KEY.
# A key must be an absolute path to a readable regular file that is not a symlink; a host is [user@]host with nothing
# option-like or shell-special. Anything missing or invalid is a named `NOT RUN:` refusal, exit nonzero, before any
# ssh, scp, remote cleanup or other host contact.
# Rows (the test re-runs itself in a private user+network namespace and runs every script under its own
# `unshare --user --map-current-user --net`, with executing ssh/scp stubs first on PATH and a private regular fake key):
#   C  the helper, driven directly in a subshell: each missing or invalid input refuses with NOT RUN naming the
#      variable; valid input sets HOST/INTEL_HOST, KEY, ARM_HOST and ARM_KEY (ARM_KEY = KEY unless ZB_MAC_ARM_KEY);
#   D  every production caller in DRIVEN, run for real: with every Mac variable unset, with the key missing, with the
#      hosts missing, and (two-host) with the primary or the arm host missing, it exits nonzero with a NOT RUN line
#      naming that variable and ZERO ssh/scp calls; with explicit fake inputs it reaches only the fake hosts, at least
#      once each, and every call uses the fake key;
#   R  tests/mac/ms6_5_reaper_gate.sh is NEVER run: it must source the helper and call `mac_config two` before its
#      first ssh line (its existing registered guard selftests stay the behavioral no-contact proof);
#   P  no production Mac script keeps a parallel parser or fallback: outside the helper, no read of ZB_MAC_HOST,
#      ZB_MAC_KEY, ZB_MAC_ARM_HOST or ZB_MAC_ARM_KEY in any form (bare $ZB_MAC_*, braced ${ZB_MAC_*...}, a quoted
#      name for indirection or printenv, ...): the names may appear only in the helper's own refusal text
#      "(set ZB_MAC_ARM_HOST=user@host)" and in mac_gate_lib.sh's hand-off ZB_MAC_HOST="$host" ZB_MAC_KEY="$key";
#      no ${!...} indirection, printenv, /proc/self/environ or compgen -e; no real Mac address or key path;
#   S  source/call census (SilverRidge 25844bef, 0cd4f30c): every D caller and the reaper source the ONE helper exactly
#      once, by the exact path its kind needs (the exact-commit launchers "$L/repo/tests/mac/mac_config.sh", from their
#      guarded export; every other caller tests/mac/mac_config.sh from the repo top), call `mac_config one|two` exactly
#      once with the row's mode, both before the script's first transport line, and define no mac_config* function;
#   X  the exact-commit launchers (mac_compile_only.sh, ms6_hard_gate.sh, ms7_appkit_gate.sh) are run again after the
#      OUTER tests/mac/mac_config.sh is changed past the commit, dirty (a helper that sets other hosts and never
#      refuses) and replaced (a symlink to /dev/null): with every input unset each still refuses NOT RUN with no call,
#      and with the explicit fake inputs each still reaches only the fake hosts with the fake key, so each takes the
#      helper from its guarded export;
#   N  census at the tested commit: every shell/Python file in tests/, packaging/ and tools/ (*.sh, *.py, or a
#      sh/bash/python shebang; selftests and *_test.py drivers aside) that runs ssh, scp or sftp at all (a bare
#      command word in shell, with or without options; an "ssh"/"scp"/"sftp" string in Python) or goes through the
#      shared Mac transport, and is a Mac file (under tests/mac or packaging/macos, or naming a Mac marker:
#      ZB_MAC_*, mac_config, mac_gate_lib, build-on-mac, the real key or a real Mac address), must be in DRIVEN, be
#      the reaper, or be one of the two libraries; a new uncensused transport script is red;
#   H  tests/mac/mac_compile_only_selftest.sh proves, before its first case, that it runs in its own network namespace
#      (not this test's) with no route out.
# Run: bash tests/mac/mac_config_selftest.sh [repo root]   (step: zig build test-mac-build-script)
set -uo pipefail
if [ "${ZB_MAC_CONFIG_SELFTEST_INNER:-}" != 1 ]; then
  ZB_MAC_CONFIG_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-mac-config-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-mac-config-selftest-??????) rm -rf "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2

# script | launch (file; commit: bash -c "$(git show)"; compile: plus ZB_COMPILE_HARNESS_SHA256) |
# provenance stubs (-, pin = the script's PIN, empty) | hosts (one, two) | args (PREP = a fabricated spike prep dir)
DRIVEN=(
  "packaging/macos/build-dmg.sh|file|-|one|"
  "tests/mac/build-on-mac.sh|file|-|one|"
  "tests/mac/bundle_layout_spike.sh|file|-|two|run PREP"
  "tests/mac/gate.sh|file|-|two|"
  "tests/mac/mac_compile_only.sh|compile|-|two|"
  "tests/mac/ms1b_signed_gate.sh|file|-|two|"
  "tests/mac/ms2a_gate.sh|file|-|two|"
  "tests/mac/ms2b_gate.sh|file|-|two|"
  "tests/mac/ms2c_gate.sh|file|-|two|"
  "tests/mac/ms3_gate.sh|file|-|two|"
  "tests/mac/ms4_gate.sh|file|-|two|"
  "tests/mac/ms5_deps_gate.sh|file|pin|two|"
  "tests/mac/ms5_gate.sh|file|-|two|"
  "tests/mac/ms5_kill_group_gate.sh|file|-|two|"
  "tests/mac/ms5_r1_env_gate.sh|file|-|two|"
  "tests/mac/ms5_relocate_gate.sh|file|pin|two|"
  "tests/mac/ms5_setup_e2e.sh|file|-|two|"
  "tests/mac/ms5_setup_refusal_gate.sh|file|-|two|"
  "tests/mac/ms5_spawn_gate.sh|file|-|two|"
  "tests/mac/ms5_spawn_io_gate.sh|file|-|two|"
  "tests/mac/ms5_stage_gate.sh|file|pin|two|"
  "tests/mac/ms5_token_fd_gate.sh|file|-|two|"
  "tests/mac/ms6_5_reaper_census_gate.sh|file|-|two|"
  "tests/mac/ms6_gate.sh|file|-|two|"
  "tests/mac/ms6_hard_gate.sh|commit|empty|two|"
  "tests/mac/ms6_harness_mac_gate.sh|file|-|two|"
  "tests/mac/ms6_netd_darwin_gate.sh|file|-|two|"
  "tests/mac/ms6_r1_kernel_gate.sh|file|-|two|"
  "tests/mac/ms7_appkit_gate.sh|commit|-|two|"
  "tests/mac/ms_runtime_rows_gate.sh|file|-|two|"
)
REAPER=tests/mac/ms6_5_reaper_gate.sh
TRANSPORT_RE='(^|[^A-Za-z0-9_./$-])(ssh|scp|sftp)([^A-Za-z0-9_.-]|$)|mac_ssh_opts|mac_scp_opts|(^|[[:space:]])mac_build([[:space:]]|$)'
PY_TRANSPORT_RE="[\"'](ssh|scp|sftp)([\"'[:space:]])"
MAC_MARK_RE='ZB_MAC_|mac_config|mac_gate_lib|build-on-mac|zb_mac_key|100\.92\.212\.47|100\.119\.156\.28|vms/mac-'
EXACT=" tests/mac/mac_compile_only.sh tests/mac/ms6_hard_gate.sh tests/mac/ms7_appkit_gate.sh "
LIBS=(tests/mac/mac_config.sh tests/mac/mac_gate_lib.sh)
HELPER=tests/mac/mac_config.sh

mkdir -p "$T/bin" "$T/prov" "$T/home" "$T/keys"
for tool in ssh scp; do
  cat > "$T/bin/$tool" <<EOF
#!/bin/bash
c=\${ZB_SELFTEST_CTL:?}
i=\$(cat "\$c/n" 2>/dev/null || echo 0); echo \$((i + 1)) > "\$c/n"
printf '%s\0' $tool "\$@" > "\$c/call.\$i"
if [ $tool = ssh ]; then
  cat > "\$c/stdin.\$i"
  # Answer like a passing Mac where gate.sh and ms1b_signed_gate.sh require each remote test's PASS line.
  if grep -q m9_render_test.py "\$c/stdin.\$i"; then
    printf 'PASS\tm9-render-webview-screenshot\tzig-out/m9-render.png\tstub\nPASS\tm9-reply-channel-contract\n'
    printf 'PASS\tm9-load-fail-contract\nexec_arch_probe: build.exec_arch=stub\n'
  elif grep -q mac_universal_test.py "\$c/stdin.\$i"; then
    printf 'PASS\tmac-universal\t12 assertions\n'
  fi
else
  dst="\${@: -1}" src="\${@: -2:1}"
  case "\$dst" in *:*) ;; *)   # a fetch: leave a stub file where the remote file lands
    if [ -d "\$dst" ]; then echo stub > "\$dst/\$(basename "\${src#*:}")"; else echo stub > "\$dst"; fi ;;
  esac
fi
exit 0
EOF
done
printf '#!/bin/bash\nexit 0\n' > "$T/bin/zig"
cat > "$T/prov/curl" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do [ "$1" = -o ] && { echo stub > "$2"; shift; }; shift; done
exit 0
EOF
cat > "$T/prov/uv" <<'EOF'
#!/bin/bash
prev=
for a in "$@"; do case "$prev" in --target) mkdir -p "$a" ;; -o) : > "$a" ;; esac; prev=$a; done
exit 0
EOF
cat > "$T/prov/python3" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -m ] && [ "${2:-}" = venv ]; then
  mkdir -p "$3/bin" && for t in pip python; do printf '#!/bin/sh\nexit 0\n' > "$3/bin/$t"; chmod +x "$3/bin/$t"; done
fi
cat > /dev/null
exit 0
EOF
cat > "$T/prov/sha256sum" <<'EOF'
#!/bin/bash
[ -n "${ZB_STUB_SHA256:-}" ] && printf '%s  %s\n' "$ZB_STUB_SHA256" "${1:--}"
exit 0
EOF
chmod +x "$T"/bin/* "$T"/prov/*
KEYF="$T/keys/fake_mac_key"
printf 'not a real key\n' > "$KEYF" && chmod 600 "$KEYF"

# The scratch repo: the real scripts and everything they read, committed (several launch from the commit's bytes).
R="$T/repo"
mkdir -p "$R"
for p in src tests packaging agent tools build.zig build.zig.zon zigbrowser.json; do
  [ -e "$ROOT/$p" ] && cp -R "$ROOT/$p" "$R/"
done
find "${R:?}" -depth \( -name __pycache__ -o -name .zig-cache -o -name zig-out \) -exec rm -rf {} +
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
SHA=$("${G[@]}" rev-parse HEAD)

# ---- C: the helper's contract, driven directly ----------------------------------------------------------------
ln -s "$KEYF" "$T/keys/link_key"; mkdir "$T/keys/dir_key"
printf 'k\n' > "$T/keys/unreadable_key"; chmod 000 "$T/keys/unreadable_key"
helper() { # helper <mode> [VAR=value...]: source the helper in a clean subshell; prints rc, then its output
  local mode=$1; shift
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" ZB_SELFTEST_CTL="$T/ctl.helper" "$@" \
     bash -c '. "$1" || exit 99; mac_config "$2"; printf "SET HOST=%s INTEL_HOST=%s KEY=%s ARM_HOST=%s ARM_KEY=%s\n" \
              "${HOST-}" "${INTEL_HOST-}" "${KEY-}" "${ARM_HOST-}" "${ARM_KEY-}"' helper "$HELPER" "$mode" 2>&1)
}
mkdir -p "$T/ctl.helper"
refuses() { # refuses <label> <variable it must name> <mode> [VAR=value...]
  local label=$1 var=$2 out rc; shift 2
  out=$(helper "$@"); rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 99 ] && grep -q "^NOT RUN: .*$var" <<<"$out" && ! grep -q '^SET ' <<<"$out"; then
    ok "C $label: refused, NOT RUN names $var"
  else bad "C $label: rc=$rc, want a NOT RUN refusal naming $var: $(head -n 2 <<<"$out" | tr '\n' ' ')"; fi
}
refuses "one, nothing set" ZB_MAC_HOST one
refuses "one, no key" ZB_MAC_KEY one ZB_MAC_HOST="$INTEL"
refuses "one, no host" ZB_MAC_HOST one ZB_MAC_KEY="$KEYF"
refuses "one, empty host" ZB_MAC_HOST one ZB_MAC_HOST= ZB_MAC_KEY="$KEYF"
refuses "one, relative key" ZB_MAC_KEY one ZB_MAC_HOST="$INTEL" ZB_MAC_KEY=keys/fake_mac_key
refuses "one, missing key file" ZB_MAC_KEY one ZB_MAC_HOST="$INTEL" ZB_MAC_KEY="$T/keys/no_such_key"
refuses "one, symlink key" ZB_MAC_KEY one ZB_MAC_HOST="$INTEL" ZB_MAC_KEY="$T/keys/link_key"
refuses "one, directory key" ZB_MAC_KEY one ZB_MAC_HOST="$INTEL" ZB_MAC_KEY="$T/keys/dir_key"
refuses "one, unreadable key" ZB_MAC_KEY one ZB_MAC_HOST="$INTEL" ZB_MAC_KEY="$T/keys/unreadable_key"
refuses "one, option-like host" ZB_MAC_HOST one ZB_MAC_HOST=-oProxyCommand=true ZB_MAC_KEY="$KEYF"
refuses "one, host with a space" ZB_MAC_HOST one "ZB_MAC_HOST=intel@10.0.0.1 -v" ZB_MAC_KEY="$KEYF"
refuses "one, host with a colon" ZB_MAC_HOST one ZB_MAC_HOST=intel@10.0.0.1:/x ZB_MAC_KEY="$KEYF"
refuses "one, host with a semicolon" ZB_MAC_HOST one "ZB_MAC_HOST=intel@h;true" ZB_MAC_KEY="$KEYF"
refuses "two, no arm host" ZB_MAC_ARM_HOST two ZB_MAC_HOST="$INTEL" ZB_MAC_KEY="$KEYF"
refuses "two, no primary host" ZB_MAC_HOST two ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$KEYF"
refuses "two, no key" ZB_MAC_KEY two ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM"
refuses "two, option-like arm host" ZB_MAC_ARM_HOST two ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST=-oX=y ZB_MAC_KEY="$KEYF"
refuses "two, symlink arm key" ZB_MAC_ARM_KEY two ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$KEYF" \
  ZB_MAC_ARM_KEY="$T/keys/link_key"
out=$(helper one ZB_MAC_HOST="$INTEL" ZB_MAC_KEY="$KEYF")
[ "$(grep '^SET ' <<<"$out")" = "SET HOST=$INTEL INTEL_HOST=$INTEL KEY=$KEYF ARM_HOST= ARM_KEY=" ] \
  && ok "C one, valid: HOST/INTEL_HOST and KEY set" || bad "C one, valid: $(tr '\n' ' ' <<<"$out")"
out=$(helper two ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$KEYF")
[ "$(grep '^SET ' <<<"$out")" = "SET HOST=$INTEL INTEL_HOST=$INTEL KEY=$KEYF ARM_HOST=$ARM ARM_KEY=$KEYF" ] \
  && ok "C two, valid: ARM_KEY defaults to the explicit key" || bad "C two, valid: $(tr '\n' ' ' <<<"$out")"
cp "$KEYF" "$T/keys/arm_key"
out=$(helper two ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$KEYF" ZB_MAC_ARM_KEY="$T/keys/arm_key")
[ "$(grep '^SET ' <<<"$out")" = "SET HOST=$INTEL INTEL_HOST=$INTEL KEY=$KEYF ARM_HOST=$ARM ARM_KEY=$T/keys/arm_key" ] \
  && ok "C two, valid: an explicit ZB_MAC_ARM_KEY is used" || bad "C two, explicit arm key: $(tr '\n' ' ' <<<"$out")"
[ ! -e "$T/ctl.helper/n" ] && ok "C the helper itself made no ssh/scp call" || bad "C the helper called ssh/scp"

# ---- D: every production caller, run for real -----------------------------------------------------------------
case_env() { # case_env <hosts one|two> <case>: the Mac variables that case sets
  case "$2" in
    x_*_unset) ;;
    x_*_full) echo "ZB_MAC_HOST=$INTEL"; echo "ZB_MAC_KEY=$KEYF"; [ "$1" = two ] && echo "ZB_MAC_ARM_HOST=$ARM" ;;
    unset) ;;
    key_missing) echo "ZB_MAC_HOST=$INTEL"; [ "$1" = two ] && echo "ZB_MAC_ARM_HOST=$ARM" ;;
    hosts_missing) echo "ZB_MAC_KEY=$KEYF" ;;
    primary_missing) echo "ZB_MAC_ARM_HOST=$ARM"; echo "ZB_MAC_KEY=$KEYF" ;;
    arm_missing) echo "ZB_MAC_HOST=$INTEL"; echo "ZB_MAC_KEY=$KEYF" ;;
    full) echo "ZB_MAC_HOST=$INTEL"; echo "ZB_MAC_KEY=$KEYF"; [ "$1" = two ] && echo "ZB_MAC_ARM_HOST=$ARM" ;;
  esac
}
case_var() { # the variable a refusal must name
  case "$1" in unset|hosts_missing|primary_missing) echo ZB_MAC_HOST ;; key_missing) echo ZB_MAC_KEY ;;
               arm_missing) echo ZB_MAC_ARM_HOST ;; esac
}
run_case() { # run_case <row> <case> -> sets C (ctl dir) and RC
  local s launch prov hosts args name pb a
  IFS='|' read -r s launch prov hosts args <<<"$1"
  name=$(basename "$s" .sh)
  C="$T/ctl.$name.$2"; mkdir -p "$C/tmp" "$C/home"
  local -a ex=(ZB_SELFTEST_CTL="$C") cmd=() argv=()
  pb="$T/bin"
  case "$prov" in
    pin) pb="$T/prov:$T/bin"; ex+=(ZB_STUB_SHA256="$(sed -n 's/^PIN=\([0-9a-f]\{64\}\)$/\1/p' "$R/$s" | head -n 1)") ;;
    empty) pb="$T/prov:$T/bin"; ex+=(ZB_STUB_SHA256=) ;;
  esac
  while IFS= read -r a; do [ -n "$a" ] && ex+=("$a"); done < <(case_env "$hosts" "$2")
  for a in $args; do
    if [ "$a" = PREP ]; then   # a fresh, complete spike prep dir per case (the spike allows one attempt per dir)
      a="$C/prep"; mkdir -p "$a" "$C/sites/site-x86_64" "$C/sites/site-aarch64"
      echo "pkg stand-in" > "$a/py.pkg"; tar -C "$C/sites" -cf "$a/sites.tar" site-x86_64 site-aarch64
      (cd "$a" && /usr/bin/sha256sum py.pkg sites.tar > inputs.sha256)
    fi
    argv+=("$a")
  done
  case "$launch" in
    file) cmd=(bash "$s" "${argv[@]}") ;;
    commit) cmd=(bash -c "$("${G[@]}" show "$SHA:$s")" "$name" "$SHA" "${argv[@]}") ;;
    compile) cmd=(bash -c "$("${G[@]}" show "$SHA:$s")" "$name" "$SHA" "${argv[@]}")
             ex+=(ZB_COMPILE_HARNESS_SHA256="$("${G[@]}" show "$SHA:$s" | /usr/bin/sha256sum | cut -c1-64)") ;;
  esac
  (cd "$R" && env -i PATH="$pb:/usr/bin:/bin" HOME="$C/home" TMPDIR="$C/tmp" "${ex[@]}" \
     unshare --user --map-current-user --net timeout -s TERM 120 "${cmd[@]}" >"$C/out" 2>&1 </dev/null)
  RC=$?
}
calls_of() { cat "$1/n" 2>/dev/null || echo 0; }
call_host_key() { # call_host_key <ctl> <i>: prints "tool host key"
  local -a a pos=()
  local j skip= key=
  mapfile -d '' a < "$1/call.$2"
  for ((j = 1; j < ${#a[@]}; j++)); do
    if [ -n "$skip" ]; then skip=; continue; fi
    case "${a[j]}" in
      -i) key=${a[j+1]:-}; skip=1 ;;
      -o|-F|-p|-P|-l|-c|-J) skip=1 ;;
      -*) ;;
      *) pos+=("${a[j]}") ;;
    esac
  done
  local host=
  if [ "${a[0]}" = ssh ]; then host=${pos[0]:-}
  else for j in "${pos[@]}"; do case "$j" in *:*) host=${j%%:*} ;; esac; done; fi
  printf '%s %s %s\n' "${a[0]}" "$host" "$key"
}
for row in "${DRIVEN[@]}"; do
  IFS='|' read -r s launch prov hosts args <<<"$row"
  name=$(basename "$s" .sh)
  [ -f "$R/$s" ] || { bad "D $name: $s is missing"; continue; }
  cases=(unset key_missing hosts_missing)
  [ "$hosts" = two ] && cases+=(primary_missing arm_missing)
  for cs in "${cases[@]}"; do
    run_case "$row" "$cs"
    n=$(calls_of "$C") var=$(case_var "$cs")
    if [ "$RC" -ne 0 ] && [ "$n" -eq 0 ] && grep -q "NOT RUN: .*$var" "$C/out"; then ok "D $name [$cs]: NOT RUN ($var), no contact"
    else bad "D $name [$cs]: exit $RC, $n ssh/scp call(s), want nonzero, none, and a NOT RUN naming $var:" \
               "$(grep -m1 -E 'NOT RUN|FAIL|DISABLED' "$C/out" | cut -c1-110)$( [ "$n" -gt 0 ] && call_host_key "$C" 0)"; fi
  done
  run_case "$row" full
  n=$(calls_of "$C") before=$fails
  declare -A seen=()
  for ((i = 0; i < n; i++)); do
    read -r tool host key < <(call_host_key "$C" "$i")
    seen[$host]=1
    [ "$host" = "$INTEL" ] || { [ "$hosts" = two ] && [ "$host" = "$ARM" ]; } \
      || bad "D $name [full]: call $i ($tool) reached '$host', not a configured fake Mac"
    [ "$key" = "$KEYF" ] || bad "D $name [full]: call $i ($tool $host) uses key '$key', not the explicit fake key"
  done
  [ -n "${seen[$INTEL]:-}" ] || bad "D $name [full]: no call reached $INTEL (the row would be vacuous)"
  if [ "$hosts" = two ]; then [ -n "${seen[$ARM]:-}" ] || bad "D $name [full]: no call reached $ARM (vacuous)"; fi
  unset seen
  [ "$fails" -eq "$before" ] && ok "D $name [full]: $n call(s), only the explicit fake hosts and key"
done

# ---- X: the exact-commit launchers take the helper from their guarded export --------------------------------------
x_before=$fails
OUTER="$R/$HELPER"
for state in dirty replaced; do
  rm -f -- "$OUTER"
  case "$state" in
    dirty) printf '%s\n' 'mac_config() { HOST=evil@10.6.6.6 INTEL_HOST=evil@10.6.6.6 KEY=/etc/hostname' \
             '  ARM_HOST=evil@10.6.6.7 ARM_KEY=/etc/hostname; }' > "$OUTER" ;;
    replaced) ln -s /dev/null "$OUTER" ;;
  esac
  [ -n "$("${G[@]}" status --porcelain -- "$HELPER")" ] || { bad "X $state: the outer helper is not changed"; continue; }
  for row in "${DRIVEN[@]}"; do
    IFS='|' read -r s launch prov hosts args <<<"$row"
    [[ "$EXACT" == *" $s "* ]] || continue
    name=$(basename "$s" .sh)
    run_case "$row" "x_${state}_unset"
    n=$(calls_of "$C")
    if [ "$RC" -ne 0 ] && [ "$n" -eq 0 ] && grep -q 'NOT RUN: .*ZB_MAC_HOST' "$C/out"; then :
    else bad "X $name [outer $state, unset]: exit $RC, $n call(s), want the export helper's NOT RUN and no contact"; fi
    run_case "$row" "x_${state}_full"
    n=$(calls_of "$C")
    declare -A seen=()
    for ((i = 0; i < n; i++)); do
      read -r tool host key < <(call_host_key "$C" "$i")
      seen[$host]=1
      { [ "$host" = "$INTEL" ] || [ "$host" = "$ARM" ]; } && [ "$key" = "$KEYF" ] \
        || bad "X $name [outer $state, full]: call $i ($tool) went to '$host' with key '$key' (the outer helper's?)"
    done
    [ -n "${seen[$INTEL]:-}" ] && [ -n "${seen[$ARM]:-}" ] \
      || bad "X $name [outer $state, full]: it did not reach both fake Macs (the outer helper broke it?)"
    unset seen
  done
done
rm -f -- "$OUTER"; "${G[@]}" checkout -q -- "$HELPER"
[ "$fails" -eq "$x_before" ] && ok "X the three exact-commit launchers ignore a dirty or replaced outer helper"

# ---- R: the destructive reaper gate is never run ----------------------------------------------------------------
rp="$R/$REAPER"
code=$(grep -vE '^[[:space:]]*#' "$rp")
src_line=$(grep -nE "^[[:space:]]*(\.|source)[[:space:]]+(\"?\\\$PWD/)?\"?$HELPER\"?[[:space:]]*$" <<<"$code" | head -n 1 | cut -d: -f1)
cfg_line=$(grep -nE '^[[:space:]]*mac_config[[:space:]]+two([[:space:]]|$)' <<<"$code" | head -n 1 | cut -d: -f1)
ssh_line=$(grep -nE '(^|[[:space:](])(ssh|scp)[[:space:]]+-|mac_ssh_opts|mac_scp_opts' <<<"$code" | head -n 1 | cut -d: -f1)
if [ -n "$src_line" ] && [ -n "$cfg_line" ] && [ -n "$ssh_line" ] && [ "$src_line" -lt "$cfg_line" ] \
   && [ "$cfg_line" -lt "$ssh_line" ]; then ok "R $REAPER sources the helper and calls mac_config two before any ssh (not run)"
else bad "R $REAPER: source line '${src_line}', mac_config two line '${cfg_line}', first ssh line '${ssh_line}'"; fi

# ---- S: every caller sources the one helper and calls it, before any transport ------------------------------------
s_before=$fails
for row in "${DRIVEN[@]}" "$REAPER|file|-|two|"; do
  IFS='|' read -r s launch prov hosts args <<<"$row"
  code=$(grep -vE '^[[:space:]]*#' "$R/$s")
  if [[ "$EXACT" == *" $s "* ]]; then want='^[[:space:]]*(\.|source)[[:space:]]+"\$L/repo/tests/mac/mac_config\.sh"[[:space:]]*$'
  else want='^[[:space:]]*(\.|source)[[:space:]]+tests/mac/mac_config\.sh[[:space:]]*$'; fi
  srcs=$(grep -cE 'mac_config\.sh' <<<"$code")
  src_line=$(grep -nE "$want" <<<"$code" | head -n 1 | cut -d: -f1)
  calls=$(grep -cE '^[[:space:]]*mac_config[[:space:]]+(one|two)([[:space:]]|$)' <<<"$code")
  cfg_line=$(grep -nE "^[[:space:]]*mac_config[[:space:]]+$hosts([[:space:]]|$)" <<<"$code" | head -n 1 | cut -d: -f1)
  tr_line=$(grep -nE "$TRANSPORT_RE" <<<"$code" | head -n 1 | cut -d: -f1)
  defs=$(grep -cE '(^|[[:space:]])(function[[:space:]]+)?mac_config[A-Za-z0-9_]*[[:space:]]*\(\)' <<<"$code")
  if [ "$srcs" -eq 1 ] && [ -n "$src_line" ] && [ "$calls" -eq 1 ] && [ -n "$cfg_line" ] && [ -n "$tr_line" ] \
     && [ "$src_line" -lt "$cfg_line" ] && [ "$cfg_line" -lt "$tr_line" ] && [ "$defs" -eq 0 ]; then :
  else bad "S $s: helper sources $srcs (want 1, line '${src_line}' by its exact path), mac_config calls $calls" \
           "(want 1 '$hosts', line '${cfg_line}'), first transport line '${tr_line}', mac_config* definitions $defs"; fi
done
[ "$fails" -eq "$s_before" ] && ok "S all $(( ${#DRIVEN[@]} + 1 )) callers source the one helper by their exact path and call it before transport"

# ---- P: no parallel parser or real default ----------------------------------------------------------------------
p_before=$fails
mapfile -t PROD < <(for row in "${DRIVEN[@]}"; do echo "${row%%|*}"; done; echo "$REAPER"; echo tests/mac/mac_gate_lib.sh)
for f in "${PROD[@]}"; do
  [ -f "$R/$f" ] || continue
  hits=$(grep -nvE '^[[:space:]]*#' "$R/$f" \
         | sed -e 's/(set ZB_MAC_ARM_HOST=user@host)//g' \
               -e "$([ "$f" = tests/mac/mac_gate_lib.sh ] && echo 's/ZB_MAC_HOST=\"\$host\" ZB_MAC_KEY=\"\$key\"//' || echo 's/^//')" \
         | grep -E 'ZB_MAC_(HOST|KEY|ARM_HOST|ARM_KEY)|\$\{!|printenv|/proc/self/environ|compgen[[:space:]]+-[a-z]*e|100\.92\.212\.47|100\.119\.156\.28|zb_mac_key' \
         | head -n 2 | cut -c1-110)
  [ -z "$hits" ] || bad "P $f keeps its own host/key parsing or a real default: $(tr '\n' ' ' <<<"$hits")"
done
[ "$fails" -eq "$p_before" ] && ok "P no production Mac script parses hosts/keys itself or names a real Mac"

# ---- N: census of every Mac transport entry at the tested commit -----------------------------------------------
n_before=$fails
known=" $REAPER ${LIBS[*]} "
for row in "${DRIVEN[@]}"; do known+="${row%%|*} "; done
census=0
while IFS= read -r rel; do
  case "$rel" in *selftest*|*_test.py) continue ;; esac
  f="$R/$rel"
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  case "$rel" in
    *.sh|*.py) ;;
    *) head -n 1 "$f" | grep -qE '^#!.*(sh|bash|python)' || continue ;;
  esac
  code=$(grep -vE '^[[:space:]]*#' "$f")
  if [[ "$rel" == *.py ]] || head -n 1 "$f" | grep -q '^#!.*python'; then
    grep -qE "$PY_TRANSPORT_RE" <<<"$code" || continue
  else
    grep -qE "$TRANSPORT_RE|build-on-mac\.sh" <<<"$code" || continue
  fi
  case "$rel" in tests/mac/*|packaging/macos/*) ;; *) grep -qE "$MAC_MARK_RE" <<<"$code" || continue ;; esac
  census=$((census + 1))
  [[ "$known" == *" $rel "* ]] || bad "N $rel is a Mac transport entry that this oracle does not drive (add it to DRIVEN)"
done < <(cd "$R" && "${G[@]}" ls-files -- tests packaging tools | LC_ALL=C sort)
[ "$census" -ge "${#DRIVEN[@]}" ] || bad "N the census found $census transport entries, fewer than the ${#DRIVEN[@]} driven"
[ "$fails" -eq "$n_before" ] && ok "N census: $census Mac transport entries, every one driven, the reaper, or a library"

# ---- H: the compile-only selftest is hermetic -------------------------------------------------------------------
mine=$(readlink /proc/self/ns/net)
out=$(cd "$R" && env -i PATH=/usr/bin:/bin HOME="$T/home" TMPDIR="$T/tmp.h" ZB_ORACLE_NETNS="$mine" \
        bash -c 'mkdir -p "$TMPDIR" && exec bash tests/mac/mac_compile_only_selftest.sh' 2>&1)
line=$(grep -m1 -E '^ok   netns: ' <<<"$out")
got=$(sed -nE 's/^ok   netns: .*own (net:\[[0-9]+\]).*/\1/p' <<<"$line")
if [ -n "$got" ] && [ "$got" != "$mine" ] && grep -q 'no route out' <<<"$line" \
   && [ "$(grep -nE '^(ok|FAIL) ' <<<"$out" | head -n 1 | cut -d: -f2- | cut -c1-10)" = "ok   netns" ]; then
  ok "H the compile-only selftest proves its own network namespace ($got, not $mine) with no route out, first"
else bad "H the compile-only selftest shows no first-line proof of its own network namespace: '${line}'"; fi

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-config-selftest\n'; exit 0; fi
printf 'FAIL\tmac-config-selftest\t%s failure(s)\n' "$fails"
exit 1
