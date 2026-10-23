#!/usr/bin/env bash
# Hostless oracle: every Mac gate ships the exact commit it names, never the working tree, into a fresh run dir (bd
# zigBrowser-4pa.59, validation ms0-3 F5; owner default #2: every Mac gate builds from git archive into a fresh remote
# dir). build-on-mac.sh and its eight callers already do (build_on_mac_selftest.sh, mac_gate_callers_selftest.sh); this
# covers every Mac gate the config oracle drives, the direct-transport gates included.
# Each gate runs for real (as tests/mac/mac_config_selftest.sh runs it: a scratch git repo, executing ssh/scp stubs
# first on PATH, explicit fake hosts and a private fake key, every run under `unshare --user --map-current-user --net`,
# the whole test re-run in its own user+network namespace). AFTER the commit, every tracked file a gate could ship
# (src, tests, packaging, agent, tools, build.zig*; the gate scripts, the helper, the shared library and the pinned
# host keys aside) gets one appended marker line in the working tree only. The scp stub keeps a copy of every local
# file it ships; the ssh stub keeps its stdin. Per gate:
#   P1 no shipped byte comes from the dirty working tree: the marker is in no scp'd file, no ssh stdin, and no file
#      inside a tar shipped either way;
#   P2 the run dir is fresh: no `mkdir -p` creates the exact $HOME/zb-* run root (only a plain mkdir, which fails on
#      an existing dir);
#   P3 two runs of the same gate use different run dirs;
#   P4 the gate prints the exact commit it shipped (the full SHA of the scratch repo's HEAD);
#   P0 non-vacuous: each run reaches every configured fake Mac and ships at least one payload.
# tests/mac/ms6_5_reaper_gate.sh is never run (session brief); it is covered by its own registered guard selftests.
# Run: bash tests/mac/mac_gate_provenance_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_GATE_PROVENANCE_SELFTEST_INNER:-}" != 1 ]; then
  ZB_GATE_PROVENANCE_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-gate-provenance-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-gate-provenance-selftest-??????) rm -rf "${T:?}" ;; esac
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
  # the bundle-layout spike's leg driver answers `create <run dir>` with its ROOT line
  case " \$* " in *" /bin/bash -s create "*) printf 'ROOT\t/Users/stub/%s\n' "\${@: -1}" ;; esac
else
  dst="\${@: -1}" src="\${@: -2:1}"
  case "\$dst" in
    *:*) mkdir -p "\$c/shipped.\$i"   # a copy to a Mac: keep the exact bytes it ships
         skip=; for a in "\${@:1:\$((\$# - 1))}"; do
           if [ -n "\$skip" ]; then skip=; continue; fi
           case "\$a" in -i|-o|-F|-P|-l|-c|-J) skip=1 ;; -*) ;; *:*) ;; *) cp -R -- "\$a" "\$c/shipped.\$i/" ;; esac
         done ;;
    *)   # a fetch: leave a stub file where the remote file lands
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

case_env() { # case_env <hosts one|two> <case>: the Mac variables that case sets
  case "$2" in
    x_*_unset) ;;
    x_*_full) echo "ZB_MAC_HOST=$INTEL"; echo "ZB_MAC_KEY=$KEYF"; [ "$1" = two ] && echo "ZB_MAC_ARM_HOST=$ARM" ;;
    unset) ;;
    key_missing) echo "ZB_MAC_HOST=$INTEL"; [ "$1" = two ] && echo "ZB_MAC_ARM_HOST=$ARM" ;;
    hosts_missing) echo "ZB_MAC_KEY=$KEYF" ;;
    primary_missing) echo "ZB_MAC_ARM_HOST=$ARM"; echo "ZB_MAC_KEY=$KEYF" ;;
    arm_missing) echo "ZB_MAC_HOST=$INTEL"; echo "ZB_MAC_KEY=$KEYF" ;;
    full|again) echo "ZB_MAC_HOST=$INTEL"; echo "ZB_MAC_KEY=$KEYF"; [ "$1" = two ] && echo "ZB_MAC_ARM_HOST=$ARM" ;;
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

MARK="ZB_DIRTY_WORK""TREE_MARKER_4pa59"   # assembled, so this file's own committed bytes never carry it
skip_dirty=" $HELPER tests/mac/mac_gate_lib.sh tests/mac/build-on-mac.sh tests/mac/known_hosts $REAPER "
for row in "${DRIVEN[@]}"; do skip_dirty+="${row%%|*} "; done
dirtied=0
while IFS= read -r rel; do
  [[ "$skip_dirty" == *" $rel "* ]] && continue
  f="$R/$rel"
  [ -f "$f" ] && [ ! -L "$f" ] && grep -Iq . "$f" 2>/dev/null || continue   # text files only
  printf '\n%s\n' "$MARK" >> "$f"; dirtied=$((dirtied + 1))
done < <("${G[@]}" ls-files -- src tests packaging agent tools build.zig build.zig.zon)
[ "$dirtied" -gt 100 ] && ok "the working tree is dirty past the commit ($dirtied files marked)" \
  || bad "only $dirtied files could be marked dirty"

scan_payloads() { # scan_payloads <ctl>: "<payloads> <first marked payload or ->"; tars embedded in stdin included
  python3 -I - "$1" "$MARK" <<'PY'
import io, pathlib, sys, tarfile
ctl, mark = pathlib.Path(sys.argv[1]), sys.argv[2].encode()
count, hit = 0, None
def tars_in(data):  # every tar archive inside data (a header's "ustar" magic sits at offset 257)
    i = data.find(b"ustar")
    while i >= 257:
        try:
            with tarfile.open(fileobj=io.BytesIO(data[i - 257:])) as t:
                yield [(m.name, t.extractfile(m).read()) for m in t.getmembers() if m.isfile()]
            return
        except (tarfile.TarError, EOFError, ValueError):
            i = data.find(b"ustar", i + 1)
for f in sorted([*ctl.glob("shipped.*/**/*"), *ctl.glob("stdin.*")]):
    if not f.is_file() or f.stat().st_size == 0:
        continue
    data = f.read_bytes()
    is_ship = "shipped." in str(f)
    if is_ship:
        count += 1
    for members in tars_in(data):
        count += 0 if is_ship else 1
        for name, body in members:
            if mark in body and hit is None:
                hit = f"{f.relative_to(ctl)} :: {name}"
    if mark in data and hit is None:
        hit = str(f.relative_to(ctl))
print(count, hit or "-")
PY
}
run_dirs() { # run_dirs <ctl>: every zb-* run root carrying a 6+ hex/digit nonce in its ssh/scp argv and stdin scripts
  python3 -I - "$1" <<'PY'
import pathlib, re, sys
ctl, names = pathlib.Path(sys.argv[1]), set()
for f in [*ctl.glob("call.*"), *ctl.glob("stdin.*")]:
    data = f.read_bytes()
    i = data.find(b"ustar")
    if f.name.startswith("stdin.") and i >= 257:
        data = data[: i - 257]          # the script text only, not a shipped tar
    for m in re.findall(rb"zb-[A-Za-z0-9._-]+", data.replace(b"\0", b"\n")):
        if re.search(rb"[0-9a-f]{6,}", m):
            names.add(m.decode())
print("\n".join(sorted(names)))
PY
}
for row in "${DRIVEN[@]}"; do
  IFS='|' read -r s launch prov hosts args <<<"$row"
  name=$(basename "$s" .sh) before=$fails
  run_case "$row" full; c1=$C
  n=$(calls_of "$c1")
  declare -A seen=()
  for ((i = 0; i < n; i++)); do read -r tool host key < <(call_host_key "$c1" "$i"); seen[$host]=1; done
  read -r payloads hit < <(scan_payloads "$c1")
  { [ -n "${seen[$INTEL]:-}" ] && { [ "$hosts" = one ] || [ -n "${seen[$ARM]:-}" ]; } && [ "$payloads" -gt 0 ]; } \
    || bad "P0 $name: vacuous run (ssh to the Macs: ${!seen[*]}; payloads $payloads)"
  unset seen
  [ "$hit" = - ] || bad "P1 $name ships working-tree bytes, not the commit's: $hit"
  mk=$(cat "$c1"/call.* "$c1"/stdin.* 2>/dev/null | tr '\0' '\n' \
       | grep -aoE 'mkdir -p ("?\$HOME/|~/)zb-[A-Za-z0-9._-]+"?([[:space:];&|)]|$)' | head -n 1)
  [ -z "$mk" ] || bad "P2 $name creates its run root with mkdir -p (an old dir would be reused): $mk"
  grep -qF "$SHA" "$c1/out" || bad "P4 $name never prints the exact commit it shipped ($SHA)"
  run_case "$row" again; c2=$C
  d1=$(run_dirs "$c1") d2=$(run_dirs "$c2")
  if [ -z "$d1" ]; then bad "P3 $name: no zb-* run dir found in its calls"
  elif [ -n "$(comm -12 <(echo "$d1") <(echo "$d2"))" ]; then bad "P3 $name reuses a run dir across runs: $(comm -12 <(echo "$d1") <(echo "$d2") | head -n 1)"; fi
  [ "$fails" -eq "$before" ] && ok "$name: ships only commit $SHA, into a fresh run dir ($n calls)"
done

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-gate-provenance-selftest\n'; exit 0; fi
printf 'FAIL\tmac-gate-provenance-selftest\t%s failure(s)\n' "$fails"
exit 1
