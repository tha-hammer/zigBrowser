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
# file it ships; the ssh stub keeps its stdin. Per gate, on BOTH independent invocations:
#   P1 every tracked file and every tracked member of every shipped or embedded tar is path-and-byte equal to
#      `git show "$SHA:<path>"`; generated and pinned payloads have closed allowlists, and unknown payloads fail;
#      the dirty-tree marker remains a separate, preserved diagnostic within the same row;
#   P2 an executing fake remote filesystem starts with the selected run root already present and the gate must refuse
#      before extraction, build or any other product work (a textual `mkdir` spelling is not proof);
#   P3 two runs of the same gate use different run dirs;
#   P4 the gate prints the full SHA in one of the documented, line-bounded commit/result formats;
#   P0 non-vacuous: each run reaches every configured fake Mac, ships payloads, and binds at least one exact tracked
#      payload to each configured host.
# Oracle controls cover a marker-free wrong member appended to one tar, a clean first + wrong second tar, an
# indirect `d=...; mkdir -p "$d"` reuse, and a dirty payload introduced only on invocation two. The historical
# marker/lexical/printed-SHA control remains exactly 26 failures at the pre-green tree.
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
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-gate-provenance-selftest-??????) rm -rf -- "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0 legacy_fails=0
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

mkdir -p "$T/bin" "$T/prov" "$T/home" "$T/keys" "$T/remote-bin"
cat > "$T/remote_exec.sh" <<'EOF'
#!/bin/bash
# Execute the selected fake-host command against a real scratch filesystem whose chosen run root already exists.
# mkdir and tar are real/wrapped operations, and later calls after a reuse are recorded as product work.
set -uo pipefail
call=${1:?} stdin=${2:?} ctl=${3:?} host=${4:?} idx=${5:?}
argv=() remote=() skip= seen_host=0
mapfile -d '' argv < "$call"
for ((j = 1; j < ${#argv[@]}; j++)); do
  if [ "$seen_host" -eq 1 ]; then remote+=("${argv[j]}"); continue; fi
  if [ -n "$skip" ]; then skip=; continue; fi
  case "${argv[j]}" in
    -i|-o|-F|-p|-P|-l|-c|-J) skip=1 ;;
    -*) ;;
    *) seen_host=1 ;;
  esac
done
[ "${#remote[@]}" -gt 0 ] || exit 0
command=${remote[0]}
for ((j = 1; j < ${#remote[@]}; j++)); do command+=" ${remote[j]}"; done
root=$(printf '%s\n' "$command" | grep -aoE 'zb-[A-Za-z0-9._-]+' \
  | awk '/[0-9a-f]{6,}/ { print; exit }')
[ -n "$root" ] || exit 0
safe_host=${host//[^A-Za-z0-9_.@-]/_}
remote_home="$ctl/remote.$safe_host/home"
selected_file="$ctl/selected.$host"
if [ ! -f "$selected_file" ]; then
  /usr/bin/mkdir -p -- "$remote_home/$root"
  printf '%s\n' "$root" > "$selected_file"
  printf '%s\n' "$root" > "$ctl/preexisting.$host"
fi
selected="/Users/stub/$(cat "$selected_file")"
printf '%s\n' "$root" > "$ctl/roots.$idx"
if [ -f "$ctl/reused.$host" ]; then
  printf 'later remote call %s after selected-root reuse\n' "$idx" > "$ctl/product.$host"
  exit 0
fi
out="$ctl/exec-out.$idx"
set +e
/usr/bin/bwrap --unshare-user --unshare-pid --unshare-uts --unshare-ipc --die-with-parent \
  --tmpfs / --dir /usr --ro-bind /usr /usr --dir /bin --ro-bind /bin /bin \
  --ro-bind "${ZB_SELFTEST_REMOTE_BIN:?}/uname" /usr/bin/uname \
  --dir /lib --ro-bind /lib /lib --dir /lib64 --ro-bind /lib64 /lib64 \
  --dir /dev --dev /dev --dir /proc --proc /proc --dir /Users --dir /Users/stub \
  --bind "$remote_home" /Users/stub --dir /ctl --bind "$ctl" /ctl \
  --dir /remote-bin --ro-bind "${ZB_SELFTEST_REMOTE_BIN:?}" /remote-bin \
  /usr/bin/env -i PATH=/remote-bin:/usr/bin:/bin HOME=/Users/stub ZB_REMOTE_COMMAND="$command" \
  ZB_SELFTEST_CTL=/ctl ZB_REMOTE_HOST="$host" ZB_SELECTED_ROOT="$selected" ZB_OP_LOG="/ctl/ops.$host" \
  /bin/bash -c 'source /remote-bin/remote_env.sh; export -f _zb_note_guard test "[" ls mkdir tar; eval "$ZB_REMOTE_COMMAND"' \
  < "$stdin" > "$out" 2>&1
rc=$?
set -e
cat "$out"
if grep -qxF product "$out"; then
  printf 'product output in call %s\n' "$idx" > "$ctl/product.$host"
fi
if [ "$rc" -ne 0 ] && [ -f "$ctl/guard.$host" ] \
   && [ ! -f "$ctl/reused.$host" ] && [ ! -f "$ctl/product.$host" ]; then
  printf 'selected pre-existing root refused in call %s\n' "$idx" > "$ctl/refused.$host"
fi
exit "$rc"
EOF
cat > "$T/remote-bin/remote_env.sh" <<'EOF'
# Shell-level `[ ! -e/-L selected-root ]` and `test -e/-d/-L selected-root` are executed pre-existence guards, not
# parsed commands. Functions override the corresponding Bash builtins while delegating their actual result.
_zb_note_guard() {
  local previous= argument resolved
  for argument in "$@"; do
    case "$previous" in
      -e|-d|-L|-f)
        resolved=$(/usr/bin/realpath -m -- "$argument")
        case "$resolved" in
          "${ZB_SELECTED_ROOT:?}")
            printf '%s selected root\n' "$previous" > "$ZB_SELFTEST_CTL/guard.$ZB_REMOTE_HOST"
            ;;
        esac
        previous=
        ;;
      *)
        case "$argument" in -e|-d|-L|-f) previous=$argument ;; esac
        ;;
    esac
  done
}
function [ { _zb_note_guard "$@"; builtin [ "$@"; }
test() { _zb_note_guard "$@"; builtin test "$@"; }
# Exported functions keep the operation wrappers active even when a committed remote body resets PATH.
ls() { /remote-bin/ls "$@"; }
mkdir() { /remote-bin/mkdir "$@"; }
tar() { /remote-bin/tar "$@"; }
EOF
cat > "$T/remote-bin/mkdir" <<'EOF'
#!/bin/bash
set -u
parents=0 operands=()
for arg in "$@"; do
  case "$arg" in
    -p|--parents|-[^-]*p*) parents=1 ;;
    --) ;;
    -*) ;;
    *) operands+=("$arg") ;;
  esac
done
printf 'mkdir' >> "${ZB_OP_LOG:?}"
printf ' <%s>' "$@" >> "$ZB_OP_LOG"
printf '\n' >> "$ZB_OP_LOG"
set +e
/usr/bin/mkdir "$@"
rc=$?
set -e
for operand in "${operands[@]}"; do
  resolved=$(/usr/bin/realpath -m -- "$operand")
  case "$resolved" in
    "${ZB_SELECTED_ROOT:?}")
      if [ "$rc" -ne 0 ] && [ "$parents" -eq 0 ]; then
        printf 'exclusive mkdir refused selected root\n' > "$ZB_SELFTEST_CTL/refused.$ZB_REMOTE_HOST"
      elif [ "$rc" -eq 0 ]; then
        printf 'selected root reused by mkdir\n' > "$ZB_SELFTEST_CTL/reused.$ZB_REMOTE_HOST"
      fi
      ;;
    "${ZB_SELECTED_ROOT:?}"/*)
      if [ "$rc" -eq 0 ]; then
        printf 'selected root reused by descendant mkdir\n' > "$ZB_SELFTEST_CTL/reused.$ZB_REMOTE_HOST"
        printf 'descendant mkdir is product work\n' > "$ZB_SELFTEST_CTL/product.$ZB_REMOTE_HOST"
      fi
      ;;
  esac
done
exit "$rc"
EOF
cat > "$T/remote-bin/ls" <<'EOF'
#!/bin/bash
set -u
for operand in "$@"; do
  case "$operand" in -*) continue ;; esac
  resolved=$(/usr/bin/realpath -m -- "$operand")
  [ "$resolved" != "${ZB_SELECTED_ROOT:?}" ] \
    || printf 'ls selected root\n' > "$ZB_SELFTEST_CTL/guard.$ZB_REMOTE_HOST"
done
exec /usr/bin/ls "$@"
EOF
cat > "$T/remote-bin/tar" <<'EOF'
#!/bin/bash
set -u
printf 'tar' >> "${ZB_OP_LOG:?}"
printf ' <%s>' "$@" >> "$ZB_OP_LOG"
printf '\n' >> "$ZB_OP_LOG"
printf 'tar/extraction reached after selected-root reuse\n' > "$ZB_SELFTEST_CTL/product.$ZB_REMOTE_HOST"
cat > /dev/null
exit 0
EOF
cat > "$T/remote-bin/uname" <<'EOF'
#!/bin/bash
# The fake host must satisfy each configured leg's architecture check before reaching its root guard.
case "${1:-}" in
  -m) printf '%s\n' "${ZB_ARCH:-${ZB_EXPECT_ARCH:-x86_64}}" ;;
  -s) printf 'Darwin\n' ;;
  *) printf 'Darwin fake-host\n' ;;
esac
EOF
chmod +x "$T/remote_exec.sh" "$T/remote-bin"/mkdir "$T/remote-bin"/ls "$T/remote-bin"/tar "$T/remote-bin"/uname
for tool in ssh scp; do
  cat > "$T/bin/$tool" <<'EOF'
#!/bin/bash
set -u
tool=$(basename "$0") c=${ZB_SELFTEST_CTL:?}
i=$(cat "$c/n" 2>/dev/null || echo 0); echo $((i + 1)) > "$c/n"
printf '%s\0' "$tool" "$@" > "$c/call.$i"
pos=() skip=
for a in "$@"; do
  if [ -n "$skip" ]; then skip=; continue; fi
  case "$a" in -i|-o|-F|-p|-P|-l|-c|-J) skip=1 ;; -*) ;; *) pos+=("$a") ;; esac
done
host=
if [ "$tool" = ssh ]; then host=${pos[0]:-}; else for a in "${pos[@]}"; do case "$a" in *:*) host=${a%%:*} ;; esac; done; fi
printf '%s\n' "$host" > "$c/host.$i"
if [ "$tool" = ssh ]; then
  cat > "$c/stdin.$i"
  if [ -n "${ZB_SELFTEST_PREEXIST_HOST:-}" ] && [ "$host" = "$ZB_SELFTEST_PREEXIST_HOST" ]; then
    "${ZB_SELFTEST_EXEC:?}" "$c/call.$i" "$c/stdin.$i" "$c" "$host" "$i"
    exec_rc=$?
    [ "$exec_rc" -eq 0 ] || exit "$exec_rc"
  fi
  # Answer like a passing Mac where gate.sh and ms1b_signed_gate.sh require each remote test's PASS line.
  if grep -q m9_render_test.py "$c/stdin.$i"; then
    printf 'PASS\tm9-render-webview-screenshot\tzig-out/m9-render.png\tstub\nPASS\tm9-reply-channel-contract\n'
    printf 'PASS\tm9-load-fail-contract\nexec_arch_probe: build.exec_arch=stub\n'
  elif grep -q mac_universal_test.py "$c/stdin.$i"; then
    printf 'PASS\tmac-universal\t12 assertions\n'
  fi
  # The bundle-layout spike's leg driver answers its create subcommand with the physical-root row.
  case " $* " in *" /bin/bash -s create "*) printf 'ROOT\t/Users/stub/%s\n' "${@: -1}" ;; esac
else
  dst="${@: -1}" src="${@: -2:1}"
  case "$dst" in
    *:*) mkdir -p "$c/shipped.$i"   # a copy to a Mac: keep the exact bytes it ships
         [ ! -f "$c/reused.$host" ] || printf 'upload in call %s\n' "$i" > "$c/product.$host"
         k=0 skip= last=$(( $# - 1 )); for a in "${@:1:$last}"; do
           if [ -n "$skip" ]; then skip=; continue; fi
           case "$a" in
             -i|-o|-F|-P|-l|-c|-J) skip=1 ;;
             -*) ;;
             *:*) ;;
             *) printf '%s\0' "$a" > "$c/origin.$i.$k"
                cp -Rf -- "$a" "$c/shipped.$i/$k"
                k=$((k + 1)) ;;
           esac
         done ;;
    *)   # a fetch: leave a stub file where the remote file lands
    if [ -d "$dst" ]; then echo stub > "$dst/$(basename "${src#*:}")"; else echo stub > "$dst"; fi ;;
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
    full*|again*) echo "ZB_MAC_HOST=$INTEL"; echo "ZB_MAC_KEY=$KEYF"; [ "$1" = two ] && echo "ZB_MAC_ARM_HOST=$ARM" ;;
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
  local -a ex=(ZB_SELFTEST_CTL="$C" ZB_SELFTEST_EXEC="$T/remote_exec.sh"
               ZB_SELFTEST_REMOTE_BIN="$T/remote-bin" ZB_SELFTEST_GATE="$s") cmd=() argv=()
  pb="$T/bin"
  case "$prov" in
    pin) pb="$T/prov:$T/bin"; ex+=(ZB_STUB_SHA256="$(sed -n 's/^PIN=\([0-9a-f]\{64\}\)$/\1/p' "$R/$s" | head -n 1)") ;;
    empty) pb="$T/prov:$T/bin"; ex+=(ZB_STUB_SHA256=) ;;
  esac
  case "$2" in *.pre.intel) ex+=(ZB_SELFTEST_PREEXIST_HOST="$INTEL") ;; *.pre.arm) ex+=(ZB_SELFTEST_PREEXIST_HOST="$ARM") ;; esac
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

scan_payloads() { # legacy marker control: "<payloads> <first marked payload or ->"
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
exact_payloads() { # exact_payloads <ctl> <gate>: summary + diagnostics; nonzero on any unknown or wrong byte
  /usr/bin/python3 -I - "$1" "$R" "$SHA" "$2" "$MARK" <<'PY'
import io
import pathlib
import subprocess
import sys
import tarfile

ctl, repo = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
sha, gate, mark = sys.argv[3], sys.argv[4], sys.argv[5].encode()
git = ["/usr/bin/git", "-C", str(repo)]
paths = subprocess.check_output(git + ["ls-tree", "-r", "--name-only", sha]).decode().splitlines()
path_set = set(paths)
by_base = {}
for path in paths:
    by_base.setdefault(pathlib.PurePosixPath(path).name, []).append(path)
cache = {}
def blob(path):
    if path not in cache:
        cache[path] = subprocess.check_output(git + ["show", f"{sha}:{path}"])
    return cache[path]

# Paths flattened by a gate before transport. Everything not listed here must resolve uniquely by its committed path
# or basename. Generated and pinned allowlists below are intentionally closed.
flat = {
    "ms5_kill_group_gate": {
        "kill_group_test.c": "tests/kill_group/kill_group_test.c",
        "kill_group_fake.c": "tests/kill_group/kill_group_fake.c",
        "agent_spawn_posix.c": "src/agent_spawn_posix.c",
        "agent_spawn_posix.h": "src/agent_spawn_posix.h",
    },
    "ms6_5_reaper_census_gate": {
        "agent_run_reaper.c": "src/agent_run_reaper.c",
        "agent_run_reaper.h": "src/agent_run_reaper.h",
        "ms6_5_reaper_census_probe.c": "tests/mac/ms6_5_reaper_census_probe.c",
    },
    "ms5_spawn_gate": {
        "__init__.py": "agent/host/zb_agent_host/__init__.py",
        "parent_watch.py": "agent/host/zb_agent_host/parent_watch.py",
        "spawn_group_test.c": "tests/mac/spawn_group_test.c",
        "watch_stub.py": "tests/mac/watch_stub.py",
        "agent_spawn_posix.c": "src/agent_spawn_posix.c",
        "agent_spawn_posix.h": "src/agent_spawn_posix.h",
    },
}
pinned_files = {
    "bundle_layout_spike", "ms5_deps_gate", "ms5_relocate_gate", "ms5_stage_gate", "ms6_hard_gate",
}
generated_names = {
    "gate": {"zigBrowser-universal", "zigBrowser-universal-signed", "libwkwebview_shim-universal.dylib"},
    "ms1b_signed_gate": {"zigBrowser-universal-signed", "libwkwebview_shim-signed.dylib"},
}
errors, payloads, exact = [], 0, {}
def err(where, why): errors.append(f"{where}: {why}")
def add_exact(host): exact[host] = exact.get(host, 0) + 1
def mapped(name, body):
    norm = name.lstrip("./")
    if norm in path_set:
        return norm
    base = pathlib.PurePosixPath(norm).name
    if base in flat.get(gate, {}):
        return flat[gate][base]
    candidates = by_base.get(base, [])
    if len(candidates) == 1:
        return candidates[0]
    byte_matches = [p for p in candidates if blob(p) == body]
    return byte_matches[0] if len(byte_matches) == 1 else None
def bind(where, name, body, host):
    path = mapped(name, body)
    if path is None:
        err(where, f"unknown tracked payload path {name!r}")
        return
    want = blob(path)
    if body != want:
        err(where, f"{name!r} differs from git show {sha}:{path}")
        return
    if mark in body:
        err(where, f"{name!r} contains the dirty-tree marker")
        return
    add_exact(host)
BLOCK = 512
ZERO = bytes(BLOCK)
def tar_header_at(data, at):
    return len(data) >= at + BLOCK and data[at + 257:at + 262] == b"ustar"
def tar_stream(data):
    """Consume a whole stream of one or more tar archives, including only structural zero padding.

    None means the bytes do not begin as a tar and must be classified by the non-archive rules. A list means tar
    classification was selected; in that case every byte is consumed or the returned framing error is fatal.
    """
    if not tar_header_at(data, 0):
        return None, None
    archives, at = [], 0
    while at < len(data):
        if not tar_header_at(data, at):
            return archives, f"unclassified bytes at tar-stream offset {at}"
        try:
            tf = tarfile.open(fileobj=io.BytesIO(data[at:]), mode="r:")
            members = tf.getmembers()
        except (tarfile.TarError, EOFError, OSError, ValueError) as exc:
            return archives, f"invalid tar framing at offset {at}: {exc}"
        if not members:
            tf.close()
            return archives, f"empty tar archive at offset {at}"
        rows = []
        for member in members:
            if member.isfile():
                src = tf.extractfile(member)
                rows.append((member.name, src.read() if src else b""))
            elif member.issym():
                rows.append((member.name, member.linkname.encode()))
        payload_end = at + tf.offset
        tf.close()
        if payload_end + 2 * BLOCK > len(data) \
           or data[payload_end:payload_end + BLOCK] != ZERO \
           or data[payload_end + BLOCK:payload_end + 2 * BLOCK] != ZERO:
            return archives, f"tar at offset {at} has no complete two-block terminator"
        end = payload_end + 2 * BLOCK
        while end + BLOCK <= len(data) and data[end:end + BLOCK] == ZERO:
            end += BLOCK
        archives.append((at, end, rows))
        if end == len(data):
            return archives, None
        if len(data) - end < BLOCK:
            return archives, f"unclassified {len(data) - end}-byte suffix after tar framing"
        at = end
    return archives, None
def inspect_bytes(where, data, host, origin_name, stdin=False):
    sets, framing_error = tar_stream(data)
    if sets is not None:
        for number, (_, _, rows) in enumerate(sets, 1):
            if origin_name == "sites.tar":
                bad = [name for name, _ in rows if not name.lstrip("./").startswith(("site-x86_64/", "site-aarch64/"))]
                if bad: err(where, f"generated sites.tar has unknown members: {bad[:3]}")
                continue
            for name, body in rows:
                bind(f"{where} archive#{number}", name, body, host)
        if framing_error:
            err(where, framing_error)
        return
    if stdin:
        # A non-archive stdin must be a committed remote-program fragment. The only expanded heredoc is gate.sh's
        # bounded universal-test program. mac_compile_only has one explicitly bounded generated envelope: the exact
        # quoted REMOTE_EOF body from its committed harness, then literal `main\n`, then a whole exact tar stream.
        if gate == "mac_compile_only":
            harness = blob("tests/mac/mac_compile_only.sh")
            begin = b"IFS= read -r -d '' REMOTE <<'REMOTE_EOF' || true\n"
            finish = b"\nREMOTE_EOF\n"
            if harness.count(begin) != 1:
                err(where, "committed compile harness has no unique REMOTE_EOF opener")
                return
            remote_and_rest = harness.split(begin, 1)[1]
            if remote_and_rest.count(finish) != 1:
                err(where, "committed compile harness has no unique REMOTE_EOF closer")
                return
            # `read -d ''` retains the here-doc's final newline; printf adds one more before literal `main\n`.
            expected_prefix = remote_and_rest.split(finish, 1)[0] + b"\n\nmain\n"
            if not data.startswith(expected_prefix):
                err(where, "compile remote-program prefix differs from the committed REMOTE_EOF body plus main")
                return
            add_exact(host)
            inspect_bytes(f"{where} compile archive", data[len(expected_prefix):], host, "src.tar")
            return
        # ms5_setup_e2e prepends a separately exact-bound committed helper.
        if gate == "ms5_setup_e2e":
            helper = blob("tests/mac/lib_group_cleanup.sh")
            if not data.startswith(helper):
                err(where, "remote helper prefix differs from git show tests/mac/lib_group_cleanup.sh")
            else:
                tail = data[len(helper):].strip()
                if tail and tail in blob("tests/mac/ms5_setup_e2e.sh"):
                    add_exact(host)
                else:
                    err(where, "bytes after the helper are not the committed ms5_setup_e2e remote body")
            return
        candidates = [p for p in (f"tests/mac/{gate}.sh", f"packaging/macos/{gate}.sh") if p in path_set]
        if gate == "bundle_layout_spike":
            candidates.append("tests/mac/bundle_layout_spike_leg.sh")
        if any(data.strip() in blob(path) for path in candidates):
            add_exact(host)
            return
        if gate == "gate" and b"mac_universal_test.py" in data and b"ZB_EXPECT_ARCH" in data:
            return  # documented generated heredoc: local shell expands its committed gate.sh template
        err(where, "unknown non-archive ssh stdin (not committed remote-program bytes)")
        return
    base = pathlib.PurePath(origin_name).name
    if base == "py.pkg" and gate in pinned_files:
        return
    if base == "sites.tar" and gate in pinned_files:
        return
    if base in generated_names.get(gate, set()):
        return
    if gate in {"gate", "ms1b_signed_gate"} and (
        base.startswith(("zigBrowser-x86_64", "zigBrowser-arm64", "shim-x86_64", "shim-arm64"))
    ):
        return
    bind(where, base, data, host)

for origin in sorted(ctl.glob("origin.*.*")):
    _, call_no, item_no = origin.name.split(".")
    host_file = ctl / f"host.{call_no}"
    host = host_file.read_text().strip() if host_file.exists() else ""
    source = origin.read_bytes().rstrip(b"\0").decode(errors="surrogateescape")
    captured = ctl / f"shipped.{call_no}" / item_no
    if not captured.exists():
        err(origin.name, "captured upload is missing")
        continue
    payloads += 1
    if captured.is_dir():
        for child in sorted(p for p in captured.rglob("*") if p.is_file()):
            rel_child = child.relative_to(captured).as_posix()
            try:
                rel_source = pathlib.Path(source).resolve().relative_to(repo.resolve()).as_posix()
                name = f"{rel_source}/{rel_child}"
            except ValueError:
                name = rel_child
            inspect_bytes(f"{origin.name}/{rel_child}", child.read_bytes(), host, name)
    elif captured.is_file():
        try:
            name = pathlib.Path(source).resolve().relative_to(repo.resolve()).as_posix()
        except ValueError:
            name = pathlib.Path(source).name
        inspect_bytes(origin.name, captured.read_bytes(), host, name)
    else:
        err(origin.name, "captured upload is not a regular file or directory")
for stdin_path in sorted(ctl.glob("stdin.*")):
    if not stdin_path.stat().st_size: continue
    call_no = stdin_path.name.split(".")[1]
    host_file = ctl / f"host.{call_no}"
    host = host_file.read_text().strip() if host_file.exists() else ""
    data = stdin_path.read_bytes()
    sets, _ = tar_stream(data)
    if sets is not None:
        payloads += 1
    inspect_bytes(stdin_path.name, data, host, "stdin", stdin=True)
for host in sorted(exact): print(f"EXACT\t{host}\t{exact[host]}")
print(f"PAYLOADS\t{payloads}")
for problem in errors: print(f"ERROR\t{problem}")
raise SystemExit(1 if errors else 0)
PY
}
commit_line() { # bounded documented identity/result lines only; a free SHA elsewhere does not count
  /usr/bin/python3 -I - "$1" "$SHA" <<'PY'
import pathlib, re, sys
lines, sha = pathlib.Path(sys.argv[1]).read_text(errors="replace").splitlines(), re.escape(sys.argv[2])
patterns = [
    rf"== commit {sha}(?:, mutant [A-Za-z0-9._-]+)?",
    rf"== hard gate at commit {sha}",
    rf"== ms7 appkit gate at commit {sha}",
    rf"== mac compile-only at commit {sha}, harness sha256 [0-9a-f]{{64}}",
    rf"PASS\tbuild-on-mac\t{sha}\tzb-gate-{sha}-[0-9a-f]+",
    rf"PASS\tms5-setup-e2e\tboth-arches\t{sha}",
]
raise SystemExit(0 if any(any(re.fullmatch(p, line) for p in patterns) for line in lines) else 1)
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
controls=0
for row in "${DRIVEN[@]}"; do
  IFS='|' read -r s launch prov hosts args <<<"$row"
  name=$(basename "$s" .sh) before=$fails
  run_case "$row" full; c1=$C
  run_case "$row" again; c2=$C
  n=$(calls_of "$c1")
  p0= p1= p4=
  hit1=- legacy_mk= legacy_sha=0
  for spec in "$c1 first" "$c2 second"; do
    ctl=${spec% *} label=${spec##* }
    exact_payloads "$ctl" "$name" > "$ctl/exact" 2>&1; exact_rc=$?
    read -r payloads hit < <(scan_payloads "$ctl")
    [ "$label" != first ] || hit1=$hit
    expected=("$INTEL"); [ "$hosts" = one ] || expected+=("$ARM")
    for expected_host in "${expected[@]}"; do
      grep -qxF "$expected_host" "$ctl"/host.* 2>/dev/null \
        || p0+="$label invocation never reached $expected_host; "
      awk -F '\t' -v h="$expected_host" '$1 == "EXACT" && $2 == h && $3 > 0 { found=1 } END { exit !found }' "$ctl/exact" \
        || p0+="$label invocation bound no exact tracked payload to $expected_host; "
    done
    [ "$payloads" -gt 0 ] || p0+="$label invocation captured no payload; "
    if [ "$hit" != - ]; then p1+="$label invocation marker at $hit; "; fi
    if [ "$exact_rc" -ne 0 ]; then
      why=$(awk -F '\t' '$1 == "ERROR" { print $2; exit }' "$ctl/exact")
      p1+="$label invocation exact-byte audit: ${why:-unknown failure}; "
    fi
    commit_line "$ctl/out" || p4+="$label invocation has no bounded commit/result line; "
  done
  [ -z "$p0" ] || bad "P0 $name: $p0"
  [ -z "$p1" ] || bad "P1 $name: $p1"
  [ -z "$p4" ] || bad "P4 $name: $p4"

  # Preserve the reviewed pre-green 26-row control independently of the stronger proof above.
  [ "$hit1" = - ] || legacy_fails=$((legacy_fails + 1))
  legacy_mk=$(cat "$c1"/call.* "$c1"/stdin.* 2>/dev/null | tr '\0' '\n' \
    | grep -aoE 'mkdir -p ("?\$HOME/|~/)zb-[A-Za-z0-9._-]+"?([[:space:];&|)]|$)' | head -n 1)
  [ -z "$legacy_mk" ] || legacy_fails=$((legacy_fails + 1))
  grep -qF "$SHA" "$c1/out" && legacy_sha=1
  [ "$legacy_sha" -eq 1 ] || legacy_fails=$((legacy_fails + 1))

  # A selected root that already exists must be refused before any product work, on each host and for both invocations.
  p2=
  expected_specs=("intel $INTEL"); [ "$hosts" = one ] || expected_specs+=("arm $ARM")
  for invocation in full again; do
    for host_spec in "${expected_specs[@]}"; do
      tag=${host_spec%% *} expected_host=${host_spec#* }
      run_case "$row" "$invocation.pre.$tag"; pre=$C pre_rc=$RC
      if [ "$pre_rc" -eq 0 ] || [ ! -f "$pre/refused.$expected_host" ] || [ -f "$pre/product.$expected_host" ]; then
        why=$(tail -n 1 "$pre"/exec-out.* 2>/dev/null | tail -n 1)
        p2+="$invocation/$tag did not refuse the pre-existing root before product work (${why:-no executed operation}); "
      fi
    done
  done
  [ -z "$p2" ] || bad "P2 $name: $p2"

  d1=$(run_dirs "$c1") d2=$(run_dirs "$c2")
  if [ -z "$d1" ] || [ -z "$d2" ]; then bad "P3 $name: one invocation named no zb-* run dir"
  elif [ -n "$(comm -12 <(echo "$d1") <(echo "$d2"))" ]; then
    bad "P3 $name reuses a run dir across runs: $(comm -12 <(echo "$d1") <(echo "$d2") | head -n 1)"
  fi

  # Causal exact-byte controls use build-on-mac's otherwise-clean source tar. Unknown bytes before, after or between
  # archives must fail closed; so must a marker-free duplicate member and an invocation-two-only wrong archive.
  if [ "$name" = build-on-mac ]; then
    wrong="$T/wrong-member"; mkdir "$wrong"; printf 'marker-free wrong build bytes\n' > "$wrong/build.zig"
    clean_stream=$(for f in "$c1"/stdin.*; do grep -aq ustar "$f" && { echo "$f"; break; }; done)

    prefix="$T/control.unknown-prefix"; cp -Rf -- "$c1" "$prefix"
    prefix_stream="$prefix/$(basename "$clean_stream")"
    { printf 'marker-free-unclassified-prefix\n'; cat "$prefix_stream"; } > "$prefix_stream.new"
    mv -f -- "$prefix_stream.new" "$prefix_stream"
    if ! commit_line "$prefix/out"; then
      bad "CONTROL unknown-prefix mutant lost the bounded commit line"
    elif exact_payloads "$prefix" "$name" > "$prefix/exact.control" 2>&1; then
      bad "CONTROL marker-free unknown prefix before an exact archive was accepted"
    else ok "marker-free unknown prefix before an exact archive is rejected"; controls=$((controls + 1)); fi

    suffix="$T/control.unknown-suffix"; cp -Rf -- "$c1" "$suffix"
    suffix_stream="$suffix/$(basename "$clean_stream")"
    printf 'marker-free-unclassified-suffix\n' >> "$suffix_stream"
    if ! commit_line "$suffix/out"; then
      bad "CONTROL unknown-suffix mutant lost the bounded commit line"
    elif exact_payloads "$suffix" "$name" > "$suffix/exact.control" 2>&1; then
      bad "CONTROL marker-free unknown suffix after an exact archive was accepted"
    else ok "marker-free unknown suffix after an exact archive is rejected"; controls=$((controls + 1)); fi

    between="$T/control.unknown-between"; cp -Rf -- "$c1" "$between"
    between_stream="$between/$(basename "$clean_stream")"
    cp -f -- "$between_stream" "$T/clean-build-stream.tar"
    { cat "$T/clean-build-stream.tar"; printf 'marker-free-unclassified-between\n';
      cat "$T/clean-build-stream.tar"; } > "$between_stream.new"
    mv -f -- "$between_stream.new" "$between_stream"
    if ! commit_line "$between/out"; then
      bad "CONTROL unknown-between mutant lost the bounded commit line"
    elif exact_payloads "$between" "$name" > "$between/exact.control" 2>&1; then
      bad "CONTROL marker-free unknown bytes between exact archives were accepted"
    else ok "marker-free unknown bytes between exact archives are rejected"; controls=$((controls + 1)); fi

    same="$T/control.same-archive"; cp -Rf -- "$c1" "$same"
    same_stream=$(for f in "$same"/stdin.*; do grep -aq ustar "$f" && { echo "$f"; break; }; done)
    tar -rf "$same_stream" -C "$wrong" build.zig
    if ! commit_line "$same/out"; then
      bad "CONTROL marker-free member mutant lost the bounded commit line"
    elif exact_payloads "$same" "$name" > "$same/exact.control" 2>&1; then
      bad "CONTROL marker-free duplicate archive member was accepted"
    else ok "marker-free duplicate archive member is rejected"; controls=$((controls + 1)); fi

    second="$T/control.second-archive"; cp -Rf -- "$c2" "$second"
    second_stream=$(for f in "$second"/stdin.*; do grep -aq ustar "$f" && { echo "$f"; break; }; done)
    tar -cf "$T/wrong-second.tar" -C "$wrong" build.zig
    cat "$T/wrong-second.tar" >> "$second_stream"
    if ! commit_line "$c1/out" || ! commit_line "$second/out"; then
      bad "CONTROL second-invocation mutant lost a bounded commit line"
    elif ! exact_payloads "$c1" "$name" > "$T/control.first.clean" 2>&1; then
      bad "CONTROL first invocation is not exact before the second-only mutant"
    elif exact_payloads "$second" "$name" > "$second/exact.control" 2>&1; then
      bad "CONTROL clean-first, wrong-second archive on invocation two was accepted"
    else ok "second-invocation-only clean-first/wrong-second archive is rejected"; controls=$((controls + 1)); fi
  fi
  [ "$fails" -eq "$before" ] && ok "$name: both invocations ship only commit $SHA into refused-if-existing, disjoint roots ($n first-run calls)"
done

# These controls execute against the same fake filesystem as P2. The selected root exists before the shell starts;
# wrappers record the actual mkdir operands and any extraction/later-call product work.
run_root_control() { # name command; sets ROOT_CTL and ROOT_RC
  local name=${1:?} command=${2:?}
  ROOT_CTL="$T/control.$name"; mkdir -p "$ROOT_CTL/tmp" "$ROOT_CTL/home"
  set +e
  env -i PATH="$T/bin:/usr/bin:/bin" HOME="$ROOT_CTL/home" TMPDIR="$ROOT_CTL/tmp" \
    ZB_SELFTEST_CTL="$ROOT_CTL" ZB_SELFTEST_EXEC="$T/remote_exec.sh" ZB_SELFTEST_REMOTE_BIN="$T/remote-bin" \
    ZB_SELFTEST_PREEXIST_HOST="$INTEL" "$T/bin/ssh" "$INTEL" "$command" </dev/null
  ROOT_RC=$?
  set -e
}

run_root_control indirect-mkdir 'd="$HOME/zb-control-123abc"; mkdir -p "$d"; echo product'
if [ "$ROOT_RC" -eq 0 ] && [ -f "$ROOT_CTL/reused.$INTEL" ] && [ -f "$ROOT_CTL/product.$INTEL" ] \
   && [ ! -f "$ROOT_CTL/refused.$INTEL" ] && grep -qF 'mkdir <-p>' "$ROOT_CTL/ops.$INTEL"; then
  ok "indirect d=...; mkdir -p \"\$d\" mutant executes unsafe reuse and product work"; controls=$((controls + 1))
else
  bad "CONTROL indirect mkdir -p mutant did not execute unsafe reuse and product work"
fi

run_root_control unrelated-first \
  'mkdir "$HOME/unrelated-abcdef"; d="$HOME/zb-control-123abc"; mkdir -p "$d"; echo product'
if [ "$ROOT_RC" -eq 0 ] && [ -f "$ROOT_CTL/reused.$INTEL" ] && [ -f "$ROOT_CTL/product.$INTEL" ] \
   && [ ! -f "$ROOT_CTL/refused.$INTEL" ] && [ "$(grep -c '^mkdir' "$ROOT_CTL/ops.$INTEL")" -eq 2 ]; then
  ok "earlier unrelated exclusive mkdir cannot mask later selected-root reuse"; controls=$((controls + 1))
else
  bad "CONTROL unrelated exclusive mkdir masked later selected-root reuse"
fi

run_root_control exclusive-positive 'd="$HOME/zb-control-123abc"; mkdir "$d" && echo product'
if [ "$ROOT_RC" -ne 0 ] && [ -f "$ROOT_CTL/refused.$INTEL" ] && [ ! -f "$ROOT_CTL/reused.$INTEL" ] \
   && [ ! -f "$ROOT_CTL/product.$INTEL" ] && grep -qF 'mkdir <' "$ROOT_CTL/ops.$INTEL"; then
  ok "plain exclusive mkdir refuses the pre-existing selected root before product work"; controls=$((controls + 1))
else
  bad "CONTROL plain exclusive mkdir did not prove selected-root refusal"
fi

run_root_control guarded-positive \
  'd="$HOME/zb-control-123abc"; if test -e "$d"; then exit 73; fi; mkdir -p "$d"; echo product'
if [ "$ROOT_RC" -eq 73 ] && [ -f "$ROOT_CTL/refused.$INTEL" ] && [ ! -f "$ROOT_CTL/reused.$INTEL" ] \
   && [ ! -f "$ROOT_CTL/product.$INTEL" ] && [ ! -f "$ROOT_CTL/ops.$INTEL" ]; then
  ok "explicit pre-existence guard refuses before its later mkdir -p and product work"; controls=$((controls + 1))
else
  bad "CONTROL explicit pre-existence guard was not accepted as safe refusal"
fi

[ "$controls" -eq 9 ] || bad "CONTROL expected 9 exact-byte/fresh-root controls, got $controls"
[ "$legacy_fails" -eq 26 ] && ok "legacy marker/lexical/printed-SHA control remains exactly 26 failures" \
  || bad "CONTROL legacy failure count changed: expected 26, got $legacy_fails"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-gate-provenance-selftest\n'; exit 0; fi
printf 'FAIL\tmac-gate-provenance-selftest\t%s failure(s)\n' "$fails"
exit 1
