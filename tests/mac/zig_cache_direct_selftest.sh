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
# (mac_compile_only.sh and ms7_appkit_gate.sh pass both flags under their run roots already; they are not covered here.)
# No Mac, no signal: the scripts run in a scratch git repo, HOME/TMPDIR in this test's temp tree; it re-runs itself in a
# private user+network namespace.
# Run: bash tests/mac/zig_cache_direct_selftest.sh [repo root]   (step: zig build test-mac-build-script)
set -uo pipefail
if [ "${ZB_ZIGDIRECT_SELFTEST_INNER:-}" != 1 ]; then
  ZB_ZIGDIRECT_SELFTEST_INNER=1 exec unshare --user --map-current-user --net bash "$(realpath "$0")" "$@"
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

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-zig-cache-direct-selftest\n'; exit 0; fi
printf 'FAIL\tmac-zig-cache-direct-selftest\t%s failure(s)\n' "$fails"
exit 1
