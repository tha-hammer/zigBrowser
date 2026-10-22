#!/usr/bin/env bash
# Hostless selftest: the Mac harnesses that run zig on their own (not through tests/mac/build-on-mac.sh) keep BOTH zig
# caches inside their per-run dir (bd zigBrowser-3ui.5; the brief: write only under a fresh per-run dir; SilverRidge
# fe88498 named them). Each of tests/mac/ms5_setup_refusal_gate.sh, tests/mac/ms5_setup_e2e.sh and tests/mac/ms5_gate.sh
# runs for real against a stub ssh/scp that records every remote command and the script it sends on stdin. A leg's
# run dir is the name the ssh command passes as ZB_RDIR='<name>'. Every zig invocation in a remote script is parsed as
# shell (python shlex: comments dropped; its argv ends at the first ; & | ( ) < > token or the end of the line), and:
#   D1 the leg names a run dir (ZB_RDIR='zb-...');
#   D2 the zig argv has --cache-dir and --global-cache-dir, and every cache-dir flag in it (also --flag=value) is inside
#      the run dir: "$HOME/<name>/...", "$HOME/${ZB_RDIR:?}/...", or "$d/..." where the script sets
#      d="$HOME/${ZB_RDIR:?}";
#   D3 every leg's script runs zig at least once (the check cannot pass vacuously).
# tests/mac/ms7_appkit_gate.sh runs zig from tests/mac/ms7_appkit_case.py, so it is DRIVEN, not parsed (SilverRidge
# 3c09433): launched as committed, its legs run for real through an executing stub ssh/scp in a fake home per Mac, with a
# fake `uname` (the leg's arch) and a fake zig that records the argv it actually receives; M1 each leg's case runs zig
# exactly once, and M2 that argv has --cache-dir and --global-cache-dir, both inside that leg's run dir.
# (tests/mac/mac_compile_only.sh is driven the same way by its own registered selftest, mac_compile_only_selftest.sh.)
# No Mac: the scripts run in a scratch git repo, HOME/TMPDIR in this test's temp tree; it re-runs itself in a private
# user+network+PID namespace (the ms7 case's harness signals only the process groups it spawned, all inside it).
# Run: bash tests/mac/zig_cache_direct_selftest.sh [repo root]   (step: zig build test-mac-build-script)
set -uo pipefail
if [ "${ZB_ZIGDIRECT_SELFTEST_INNER:-}" != 1 ]; then
  ZB_ZIGDIRECT_SELFTEST_INNER=1 exec unshare --user --map-current-user --net --pid --fork --mount-proc bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-zigdirect-selftest-XXXXXX")
T=$(realpath "$BASE")
cleanup() {
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-zigdirect-selftest-??????) rm -rf "${T:?}" ;; esac
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
cat > "$T/ctl/stdin.\$i"
exit 0
EOF
  chmod +x "$T/bin/$tool"
done

cat > "$T/zigargv.py" <<'ZIGARGV'
# argv[1:] = the accepted run-dir prefixes. Prints "ZIG<TAB>ok|bad<TAB>detail" per zig invocation on stdin, judging
# ONLY that invocation's own argv (comments dropped; it ends at the first ; & | ( ) < > token or the end of the line).
import shlex, sys
prefixes = sys.argv[1:]
PUNCT = set("();<>|&")
def inside(v):
    return any(v.startswith(p) and len(v) > len(p) for p in prefixes)
for line in sys.stdin.read().replace("\\\n", " ").split("\n"):
    lex = shlex.shlex(line, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    try:
        toks = list(lex)
    except ValueError as exc:
        if "zig" in line:
            print(f"ZIG\tbad\tunparsable line ({exc}): {line[:120]}")
        continue
    i = 0
    while i < len(toks):
        t = toks[i]
        if (t == "zig" or t.endswith("/zig")) and i + 1 < len(toks) and toks[i + 1][:1].isalpha():
            argv, j = [], i + 1
            while j < len(toks) and not set(toks[j]) <= PUNCT:
                argv.append(toks[j])
                j += 1
            problems = []
            for flag in ("--cache-dir", "--global-cache-dir"):
                vals = [argv[k + 1] for k in range(len(argv) - 1) if argv[k] == flag]
                vals += [a.split("=", 1)[1] for a in argv if a.startswith(flag + "=")]
                if not vals:
                    problems.append(f"no {flag} in the zig argv")
                for v in vals:
                    if not inside(v):
                        problems.append(f"{flag} {v} is outside the run dir")
            print("ZIG\t" + ("bad" if problems else "ok") + "\t" + ("; ".join(problems) or "zig " + " ".join(argv)))
            i = j
        else:
            i += 1
ZIGARGV

# The scratch repo: the real scripts, their helper, and stand-ins for what they archive or copy.
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/src" "$R/packaging" "$R/agent" "$R/tools"
for f in ms5_setup_refusal_gate.sh ms5_setup_e2e.sh ms5_gate.sh lib_group_cleanup.sh; do cp "$ROOT/tests/mac/$f" "$R/tests/mac/"; done
for f in agent_secrets_mac.h agent_secrets_mac.m agent_secrets_mac.zig; do echo "// stand-in" > "$R/src/$f"; done
echo "// stand-in" > "$R/tests/mac/keychain_seam_test.m"
echo x > "$R/packaging/x"; echo x > "$R/agent/x"; echo x > "$R/tools/x"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }

check() { # check <label> <script>
  local label=$1 script=$2 i j n rc host skip rdir legs=0 zn
  local -a a cmd prefixes
  rm -f "$T/ctl"/*
  (cd "$R" && env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" \
     ZB_MAC_ARM_HOST="$ARM" ZB_MAC_KEY="$T/home/no_such_key" timeout 120 bash "$script" >"$T/out" 2>&1 </dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || bad "$label: exit $rc (the run must reach its end): $(tail -n 2 "$T/out" | tr '\n' ' ')"
  n=$(cat "$T/ctl/n" 2>/dev/null || echo 0)
  for ((i = 0; i < n; i++)); do
    mapfile -d '' a < "$T/ctl/call.$i"
    [ "${a[0]}" = ssh ] || continue
    host= skip=
    for ((j = 1; j < ${#a[@]}; j++)); do
      if [ -n "$skip" ]; then skip=; continue; fi
      case "${a[j]}" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
      host=${a[j]}; cmd=("${a[@]:j+1}"); break
    done
    [ -s "$T/ctl/stdin.$i" ] || continue                     # only calls that send a remote script
    [[ "${cmd[*]}" == *"/bin/bash -s"* ]] || continue
    legs=$((legs + 1))
    rdir=$(grep -oE "ZB_RDIR='zb-[A-Za-z0-9_.-]+'" <<<"${cmd[*]}" | head -1); rdir=${rdir#ZB_RDIR=\'}; rdir=${rdir%\'}
    if [ -z "$rdir" ]; then bad "$label D1: call $i on $host sends a script without ZB_RDIR='zb-...'"; continue; fi
    prefixes=("\$HOME/$rdir/" "\$HOME/\${ZB_RDIR:?}/" "\$HOME/\${ZB_RDIR}/")
    grep -qE '^d="\$HOME/\$\{ZB_RDIR:\?\}"' "$T/ctl/stdin.$i" && prefixes+=("\$d/" "\${d}/")
    zn=0
    while IFS=$'\t' read -r kind verdict detail; do
      [ "$kind" = ZIG ] || continue
      zn=$((zn + 1))
      [ "$verdict" = ok ] || bad "$label D2: call $i on $host (run dir $rdir): $detail"
    done < <(python3 -I "$T/zigargv.py" "${prefixes[@]}" < "$T/ctl/stdin.$i")
    if [ "$zn" -ge 1 ]; then ok "$label: $host leg ($rdir) runs zig $zn time(s)"
    else bad "$label D3: the $host leg's script (call $i) runs no zig"; fi
  done
  [ "$legs" -eq 2 ] || bad "$label: $legs legs sent a remote script, want 2 (one per Mac)"
}

check ms5-setup-refusal tests/mac/ms5_setup_refusal_gate.sh
check ms5-setup-e2e     tests/mac/ms5_setup_e2e.sh
check ms5-keychain      tests/mac/ms5_gate.sh

# ---- ms7_appkit_gate.sh: driven through executing stubs; zig's real argv is recorded -------------------------------
X="$T/x"; R7="$T/repo7"
mkdir -p "$X/bin" "$X/hostbin" "$X/hosts/intel/.local/bin" "$X/hosts/arm/.local/bin" "$X/ctl"
cat > "$X/bin/ssh" <<EOF
#!/bin/bash
host= skip= k=0
for a in "\$@"; do
  k=\$((k + 1))
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
  host=\$a; break
done
case "\$host" in $INTEL) role=intel ;; $ARM) role=arm ;; *) echo "stub ssh: unexpected host \$host" >&2; exit 99 ;; esac
cd "$X/hosts/\$role" && exec env -i HOME="$X/hosts/\$role" PATH="$X/hostbin:/usr/bin:/bin" bash -c "\${*:k+1}"
EOF
cat > "$X/bin/scp" <<EOF
#!/bin/bash
dst="\${@: -1}" src="\${@: -2:1}"
case "\$dst" in $INTEL:*) role=intel ;; $ARM:*) role=arm ;; *) echo "stub scp: unexpected target \$dst" >&2; exit 99 ;; esac
cp "\$src" "$X/hosts/\$role/\${dst#*:}"
EOF
cat > "$X/hostbin/uname" <<'EOF'
#!/bin/bash
[ "$1" = -m ] && { echo "${ZB_ARCH:-x86_64}"; exit 0; }
exec /usr/bin/uname "$@"
EOF
for role in intel arm; do
  cat > "$X/hosts/$role/.local/bin/zig" <<EOF
#!/bin/bash
[ "\$1" = version ] && { echo 0.16.0; exit 0; }
n=\$(ls "$X/ctl" | grep -c "^zig\.$role\." || true)
printf '%s\0' "\$@" > "$X/ctl/zig.$role.\$n"
exit 1   # a stub build: the case records a failed build and stops; only the argv matters here
EOF
done
chmod +x "$X/bin/ssh" "$X/bin/scp" "$X/hostbin/uname" "$X/hosts/intel/.local/bin/zig" "$X/hosts/arm/.local/bin/zig"
mkdir -p "$R7/tests/mac/hard_gate" "$R7/src" "$R7/packaging" "$R7/tools"
cp "$ROOT/tests/mac/ms7_appkit_gate.sh" "$ROOT/tests/mac/ms7_appkit_case.py" "$ROOT/tests/mac/ms7_appkit_check.py" "$R7/tests/mac/"
cp "$ROOT/tests/mac/hard_gate/harness.py" "$R7/tests/mac/hard_gate/"
echo "// stand-in" > "$R7/src/wkwebview_shim.m"; echo x > "$R7/packaging/x"; echo x > "$R7/tools/x"
echo build > "$R7/build.zig"; echo zon > "$R7/build.zig.zon"; echo '{}' > "$R7/zigbrowser.json"
G7=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R7")
"${G7[@]}" init -q && "${G7[@]}" add -A \
  && "${G7[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the ms7 scratch repo"; exit 1; }
(cd "$R7" && env -i PATH="$X/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
   ZB_MAC_KEY="$T/home/no_such_key" timeout 300 bash -c "$("${G7[@]}" show HEAD:tests/mac/ms7_appkit_gate.sh)" \
   ms7-appkit-gate HEAD >"$T/out7" 2>&1 </dev/null)
for role in intel arm; do
  mapfile -t recs < <(ls "$X/ctl" | grep "^zig\.$role\." || true)
  if [ "${#recs[@]}" -ne 1 ]; then
    bad "ms7-appkit M1: the $role leg ran zig ${#recs[@]} time(s), want 1: $(grep -m3 -E 'FAIL|Error|error' "$T/out7" | tr '\n' ' ')"
    continue
  fi
  mapfile -d '' zargv < "$X/ctl/${recs[0]}"
  cache= gcache=
  for ((k = 0; k < ${#zargv[@]}; k++)); do
    case "${zargv[k]}" in
      --cache-dir) cache=${zargv[k+1]:-} ;; --global-cache-dir) gcache=${zargv[k+1]:-} ;;
      --cache-dir=*) cache=${zargv[k]#*=} ;; --global-cache-dir=*) gcache=${zargv[k]#*=} ;;
    esac
  done
  rundir=$(grep -oE "$X/hosts/$role/zb-ms7gate-[0-9]+-[0-9]+-[0-9]+" <<<"$cache $gcache" | sort -u)
  if [ "$(grep -c . <<<"$rundir")" -eq 1 ] && [[ "$cache" == "$rundir"/?* ]] && [[ "$gcache" == "$rundir"/?* ]]; then
    ok "ms7-appkit: $role leg's zig argv keeps --cache-dir and --global-cache-dir in $rundir"
  else
    bad "ms7-appkit M2: $role leg's zig argv (${zargv[*]}) does not keep both caches in one run dir (cache='$cache' global='$gcache')"
  fi
done
left=$(find "$X/hosts" -maxdepth 2 -name 'zb-ms7gate-*' 2>/dev/null)
[ -z "$left" ] || bad "ms7-appkit: a leg left its run dir: $left"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-zig-cache-direct-selftest\n'; exit 0; fi
printf 'FAIL\tmac-zig-cache-direct-selftest\t%s failure(s)\n' "$fails"
exit 1
