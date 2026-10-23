#!/usr/bin/env bash
# Hostless proof of the 4pa.80 spike's write containment (SilverRidge de82cf2): tests/mac/bundle_layout_spike.sh run and
# the leg driver it sends, tests/mac/bundle_layout_spike_leg.sh. The REAL spike runs in a scratch git repo against
# EXECUTING stub ssh/scp: each remote command runs for real in a fake Mac home per host, reached through a symlinked
# $HOME so the physical-root substitution is exercised. /usr/bin is overlaid (private mount namespace) with a fake
# /usr/bin/sandbox-exec and a recording /usr/bin/python3. The fake sandbox-exec records the profile and argv of every
# call and ENFORCES the profile it is given: it runs the command in a nested mount namespace where the fake home is
# read-only except each (subpath "...") the profile allows, so a write the profile does not admit fails (EROFS) and a
# write it admits works. Fake Mac tools (zig, xcrun, file, codesign, uname, getconf) and a stand-in stager (records its
# arguments, calls /usr/bin/python3 and xcrun, stages the documented layout) record whether they ran inside it.
# Rows:
#   K1 clean: exit 0, LAYOUT-OK on both legs, SPIKE-RESULT; per host the sandbox-exec calls are exactly: the profile
#      parse, mkdir <root>/evidence, the positive write, the /dev/null write, the profile and before-audit evidence,
#      the three canaries, then exactly two /bin/bash outer commands (the native build, then the post-build work), then
#      the after-audit and the evidence tar; every profile is the exact four-line profile naming the PHYSICAL root
#      (not the symlinked home) and /dev/null and nothing else; every recorded tool call on the Mac (zig, xcrun,
#      python3, the stager, file, codesign) ran inside the sandbox;
#   K2 the three canaries are <physical home>/.zb-spike-canary-<nonce> and both getconf dirs' zb-spike-canary-<nonce>,
#      attempted before the build, refused, and absent afterwards; the fake homes are byte-for-byte as before;
#   K3 (the old B2-B5) the stager gets <root>/inputs/py.pkg, the commit's pin, the app's Contents and both site trees
#      from the committed agent tree; the verified .app holds the exe, the shim and agent-host; signing is ad hoc,
#      inside out, never --deep; the census counts the non-Mach-O files under Contents/Frameworks;
#   K4 the evidence (driver output, build/stage/sign/verify logs, both audits) is on Linux, the roots are removed;
#   K5 a missing sandbox-exec, a profile parse error, a failed positive write: INCONCLUSIVE NOT RUN on both legs, exit
#      2, no product tool runs, roots removed;
#   K6 a sandbox-exec that does not enforce: the home canary is written, BREACH, exit 4; the canary and the root stay;
#      the arm64 host is never contacted; no product tool runs;
#   K7 the control ZB_SPIKE_MUTANT=stray_in_frameworks (4pa.80, SilverRidge a365949c; it replaces data_in_frameworks):
#      refused, exit 1, no ssh/scp, without the candidate's LAYOUT-OK result; after it, a control whose signing
#      succeeds (this scaffold's codesign never fails a signing call) is INCONCLUSIVE (wrong stage), with the stray
#      file in the verified tree and census 1, for a clean and for an unsealed verify, never EXPECTED-FAIL (the
#      tree-derived control proof is tests/mac/bundle_layout_spike_layout_selftest.sh);
#   K8 a sandbox denial in verify that also prints a sealed-resource message: INCONCLUSIVE, never LAYOUT-FINDING or
#      EXPECTED-FAIL; a denied signing tool: INCONCLUSIVE naming the denial, no verify;
#   K9 a staged symlink that resolves outside the root: INCONCLUSIVE before any signing;
#   K10 the audit: on each arch, an addition, a content change, a mode-only change or a deletion outside the sandbox
#      during the leg, across the getconf temp root, the getconf cache root, ~/Library/Caches and the shallow home, is
#      INCONCLUSIVE on that leg, naming the path (K4 also requires path|type|mode|inode|size|mtime for all four
#      surfaces in both snapshots);
#   K11 an unsealed verify on the arm leg: LAYOUT-FINDING there, LAYOUT-OK on Intel, exit 0; a verify failure with no
#      diagnostic: INCONCLUSIVE, exit 2;
#   K12 no arm64 host, inputs that do not match inputs.sha256, an unknown mutant: exit 1 and no ssh/scp;
#   K13 an inherited regular-file descriptor outside the root (fd 1, fd 2, fd 9) is NOT RUN before any sandbox-exec or
#      tool call; a root-local fd 9 and a pipe on fd 9 run the whole leg;
#   K14 every ssh/scp call is classified: per leg only create, one scp of the committed source tar and the two
#      hash-pinned prep inputs into <rd>/inputs/, run, one scp of <rd>/evidence.tar into <prep>/evidence/, and remove,
#      each ssh carrying the committed leg driver; anything else is a failure. A run root swapped for a symlink to an
#      outside directory, and a pre-existing symlink at the controlled name, are refused before any sandbox-exec or
#      tool call with the target unchanged.
# K5 and K6 require the whole Mac tool log to be empty and assert both legs' verdicts.
# No Mac, no signal, no network: it re-runs itself in a private user+mount+network namespace.
# Run: bash tests/mac/bundle_layout_spike_containment_selftest.sh [repo root]
set -uo pipefail
if [ "${ZB_CONTAIN_SELFTEST_INNER:-}" != 1 ]; then
  ZB_CONTAIN_SELFTEST_INNER=1 exec unshare --user --map-root-user --mount --net bash "$(realpath "$0")" "$@"
fi
ROOT=$(realpath "${1:-.}")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/zb-contain-selftest-XXXXXX")
T=$(realpath "$BASE")
P="$T/overlay"
cleanup() {
  umount /usr/bin 2>/dev/null; umount "$P/realusrbin" 2>/dev/null
  if mountpoint -q "$P/realusrbin" 2>/dev/null; then echo "WARN: $P/realusrbin is still mounted; $T left in place" >&2; return; fi
  case "$T" in "$(realpath "${TMPDIR:-/tmp}")"/zb-contain-selftest-??????) rm -rf --one-file-system "${T:?}" ;; esac
}
trap cleanup EXIT
fails=0
ok() { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fails=$((fails + 1)); }
INTEL=intel@10.0.0.1 ARM=arm@10.0.0.2 X="$T/x" C="$T/ctl"
PIN=$(printf 'pkg stand-in\n' | sha256sum | cut -c1-64)
APP=spike/zigBrowser.app

# --- the /usr/bin overlay: every real tool stays, plus the fake sandbox-exec and a recording python3 ---
mkdir -p "$P/realusrbin" "$P/usrbin" "$X/bin" "$X/hostbin" "$C" "$T/home" "$T/tmp"
mount --bind /usr/bin "$P/realusrbin" || { echo "FAIL could not bind /usr/bin"; exit 1; }
for f in "$P/realusrbin"/*; do ln -s "$f" "$P/usrbin/${f##*/}"; done
rm -f "$P/usrbin/python3"
printf 'C=%q\nP=%q\nX=%q\n' "$C" "$P" "$X" > "$X/fake.env"
fake() { # fake <path>: a bash script that sources fake.env, body on stdin
  { echo '#!/bin/bash'; echo ". '$X/fake.env'"; cat; } > "$1" && chmod +x "$1"
}
rec='printf "%s\t%s\t%s\t%s\n" "$NAME" "${ZB_FAKE_SANDBOXED:-0}" "${ZB_ROLE:-}" "$*" >> "$C/tools.log"'

fake "$P/usrbin/sandbox-exec" <<'EOF'
[ "${1:-}" = -p ] && [ $# -ge 3 ] || { echo "sandbox-exec: usage" >&2; exit 64; }
prof=$2; shift 2
n=$(cat "$C/sbx.count" 2>/dev/null || echo 0); echo $((n + 1)) > "$C/sbx.count"
printf '%s' "$prof" > "$C/sbx.$n.profile"; printf '%s\0' "$@" > "$C/sbx.$n.argv"; echo "${ZB_ROLE:-}" > "$C/sbx.$n.role"
scen=$(cat "$C/scenario")
[ "$scen" = parse_error ] && { echo "sandbox-exec: syntax error in the profile" >&2; exit 65; }
[ "$scen" = positive_fail ] && [ "$1" = /bin/mkdir ] && exit 1
H=$(cd "$HOME" && pwd -P)
# audit:<role>:<op>:<surface> changes one audited surface outside the sandbox, between the two audits (at the first
# outer command), as another process on the Mac would.
case "$scen" in audit:*)
  IFS=: read -r _ arole op surf <<<"$scen"
  if [ "$arole" = "$ZB_ROLE" ] && [ "$1" = /bin/bash ] && [ ! -e "$C/audit.done" ]; then
    : > "$C/audit.done"
    case "$surf" in
      temp) d="$H/var/folders/zz/zyxw/T" f=resident ;; cache) d="$H/var/folders/zz/zyxw/C" f=resident ;;
      caches) d="$H/Library/Caches/com.apple.existing" f=data ;; shallow) d="$H" f=.profile ;;
    esac
    case "$op" in
      add) echo added > "$d/zb-audit-added" ;; change) echo changed-and-longer >> "$d/$f" ;;
      chmod) chmod 600 "$d/$f" ;; delete) rm -f "$d/$f" ;;
    esac
  fi ;;
esac
[ "$scen" = no_enforce ] && exec env ZB_FAKE_SANDBOXED=1 "$@"
mapfile -t allow < <(grep -oE '\(subpath "[^"]*"\)' <<<"$prof" | sed -E 's/^\(subpath "(.*)"\)$/\1/')
exec unshare --mount --propagation private /bin/bash -c '
H=$1 k=$2; shift 2; allow=("${@:1:k}"); shift "$k"
mount --bind "$H" "$H" && mount -o remount,bind,ro "$H" || exit 70
for p in "${allow[@]+"${allow[@]}"}"; do
  [ -d "$p" ] || continue
  mount --bind "$p" "$p" && mount -o remount,bind,rw "$p" || exit 70
done
exec env ZB_FAKE_SANDBOXED=1 "$@"' _ "$H" "${#allow[@]}" "${allow[@]+"${allow[@]}"}" "$@"
EOF
fake "$P/usrbin/python3" <<EOF
NAME=python3; [ -z "\${ZB_ROLE:-}" ] || $rec
exec "\$P/realusrbin/python3" "\$@"
EOF
mount --bind "$P/usrbin" /usr/bin || { echo "FAIL could not overlay /usr/bin"; exit 1; }

# --- Linux-side stub ssh/scp: run the command in the host's fake home, through a symlinked HOME, behind pipes ---
fake "$X/bin/ssh" <<EOF
echo "ssh \$*" >> "\$C/calls"
n=\$(cat "\$C/xport.count" 2>/dev/null || echo 0); echo \$((n + 1)) > "\$C/xport.count"
host= skip= k=0
for a in "\$@"; do
  k=\$((k + 1))
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-p|-l) skip=1; continue ;; -*) continue ;; esac
  host=\$a; break
done
case "\$host" in $INTEL) role=intel arch=x86_64 ;; $ARM) role=arm arch=arm64 ;; *) echo "stub ssh: unexpected host \$host" >&2; exit 99 ;; esac
printf 'ssh\t%s\t%s\n' "\$host" "\${*:k+1}" > "\$C/xport.\$n"
cd "\$X/homes/\$role" || exit 98
tee "\$C/xport.\$n.stdin" | env -i HOME="\$X/homes/\$role" ZB_ROLE=\$role ZB_ARCH=\$arch PATH="\$X/hostbin:/usr/bin:/bin" \
  bash -c "\${*:k+1}" 2> >(cat >&2) | cat
exit "\${PIPESTATUS[1]}"
EOF
fake "$X/bin/scp" <<EOF
echo "scp \$*" >> "\$C/calls"
n=\$(cat "\$C/xport.count" 2>/dev/null || echo 0); echo \$((n + 1)) > "\$C/xport.count"
pos=() skip=
for a in "\$@"; do
  if [ -n "\$skip" ]; then skip=; continue; fi
  case "\$a" in -i|-o|-F|-P|-l) skip=1; continue ;; -*) continue ;; esac
  pos+=("\$a")
done
role_of() { case "\$1" in $INTEL:*) echo intel ;; $ARM:*) echo arm ;; *) echo "stub scp: bad host in \$1" >&2; exit 99 ;; esac; }
dst=\${pos[\${#pos[@]}-1]}; unset 'pos[\${#pos[@]}-1]'
printf 'scp\t%s\t%s\n' "\$dst" "\${#pos[@]}" > "\$C/xport.\$n"; printf '%s\n' "\${pos[@]}" > "\$C/xport.\$n.srcs"
i=0; for src in "\${pos[@]}"; do [[ "\$src" == *:* ]] || cp "\$src" "\$C/xport.\$n.src.\$i"; i=\$((i + 1)); done
if [[ "\$dst" == *:* ]]; then
  role=\$(role_of "\$dst") || exit 99
  for src in "\${pos[@]}"; do cp "\$src" "\$X/homes/\$role/\${dst#*:}" || exit 1; done
  # swap_root: after the inputs land, another process replaces the run root with a symlink to an outside directory.
  if [ "\$(cat "\$C/scenario")" = swap_root ] && [ ! -e "\$C/swapped.\$role" ]; then
    r=\${dst#*:}; r=\${r%%/*}; : > "\$C/swapped.\$role"
    mv "\$X/hosts/\$role/\$r" "\$X/swapped-aside-\$role" && ln -s "\$X/outside" "\$X/hosts/\$role/\$r"
  fi
else
  for src in "\${pos[@]}"; do role=\$(role_of "\$src") || exit 99; cp "\$X/homes/\$role/\${src#*:}" "\$dst" || exit 1; done
fi
EOF

# --- fake Mac tools ---
fake "$X/hostbin/uname" <<'EOF'
[ "${1:-}" = -m ] && { echo "$ZB_ARCH"; exit 0; }
exec /usr/bin/uname "$@"
EOF
fake "$X/hostbin/getconf" <<'EOF'
H=$(cd "$HOME" && pwd -P)
case "${1:-}" in
  DARWIN_USER_TEMP_DIR) echo "$H/var/folders/zz/zyxw/T/" ;;
  DARWIN_USER_CACHE_DIR) echo "$H/var/folders/zz/zyxw/C/" ;;
  *) exec /usr/bin/getconf "$@" ;;
esac
EOF
fake "$X/hostbin/file" <<EOF
NAME=file; $rec
[ "\$1" = -b ] && shift
if [ "\$(od -An -tx1 -N4 "\$1" 2>/dev/null | tr -d ' \n')" = cffaedfe ]; then echo "Mach-O 64-bit executable"; else echo "ASCII text"; fi
EOF
fake "$X/hostbin/xcrun" <<EOF
NAME=xcrun; $rec
case "\$*" in *--find*python3*) echo /usr/bin/python3 ;; *--show-sdk-path*) echo /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ;; esac
EOF
fake "$X/hostbin/codesign" <<EOF
NAME=codesign; $rec
n=\$(cat "\$C/codesign.\$ZB_ROLE.count" 2>/dev/null || echo 0); echo \$((n + 1)) > "\$C/codesign.\$ZB_ROLE.count"
tgt=\${@: -1}
rel=\${tgt#*/zb-gate-*/}
a=("\$@"); a[\${#a[@]}-1]=\$rel
printf '%s\0' "\${a[@]}" > "\$C/codesign.\$ZB_ROLE.\$n"
if [ -L "\$tgt" ]; then echo symlink; elif [ -e "\$tgt" ]; then echo present; else echo missing; fi > "\$C/codesign.\$ZB_ROLE.\$n.target"
scen=\$(cat "\$C/scenario")
case " \$* " in
  *" --verify "*) ;;
  *) [ "\$scen" = deny_tool ] && { echo "\$tgt: Operation not permitted"; exit 1; }; exit 0 ;;
esac
(cd "\$tgt" && find . | sort) > "\$C/tree.\$ZB_ROLE"
[ "\$scen" = deny_verify ] && { echo "\$tgt: Operation not permitted"; echo "\$tgt: a sealed resource is missing or invalid"; exit 1; }
mode=\$(cat "\$C/verify_mode") where=\$(cat "\$C/verify_where")
[ "\$where" = both ] || [ "\$where" = "\$ZB_ROLE" ] || mode=clean
case "\$mode" in
  clean) echo "\$tgt: valid on disk"; echo "\$tgt: satisfies its Designated Requirement"; exit 0 ;;
  unsealed) echo "\$tgt: unsealed contents present in the bundle root"; exit 1 ;;
  notsigned) echo "\$tgt: code object is not signed at all"; exit 1 ;;
  generic) echo "\$tgt: internal error in Code Signing subsystem"; exit 1 ;;
esac
EOF

# --- two fake Mac homes, each reached through a symlinked $HOME ---
mkdir -p "$X/homes"
for role in intel arm; do
  h="$X/hosts/$role"
  mkdir -p "$h/.local/bin" "$h/Library/Caches/com.apple.existing" "$h/var/folders/zz/zyxw/T/old" "$h/var/folders/zz/zyxw/C/old"
  echo resident > "$h/Library/Caches/com.apple.existing/data"; echo profile > "$h/.profile"
  echo resident > "$h/var/folders/zz/zyxw/T/resident"; echo resident > "$h/var/folders/zz/zyxw/C/resident"
  ln -s "$h" "$X/homes/$role"
  fake "$h/.local/bin/zig" <<EOF
NAME=zig; $rec
xcrun --show-sdk-path >/dev/null
{ : > "\$HOME/Library/Caches/zig-was-here"; } 2>/dev/null   # an outside write: refused, silently
mkdir -p zig-out/bin zig-out/Frameworks
printf '\\xcf\\xfa\\xed\\xfe zigBrowser exe stand-in\\n' > zig-out/bin/zigBrowser
printf '\\xcf\\xfa\\xed\\xfe libwkwebview_shim stand-in\\n' > zig-out/Frameworks/libwkwebview_shim.dylib
echo "build ok"
EOF
done

mkdir -p "$X/outside"; echo sentinel > "$X/outside/sentinel"   # the target of a symlinked run root
outside_snapshot() { (cd "$X/outside" && find . -printf '%p|%y|%m|%s|%T@\n' | sort); }
outside_snapshot > "$T/outside.want"

# Every ssh/scp call the runner makes, classified. Admitted per leg, in order: create (the committed leg driver on
# stdin), one scp of exactly the committed source tar + the two hash-pinned prep inputs into <rd>/inputs/, run (same
# driver, this arch, the pin, the mutant), one scp of <rd>/evidence.tar into <prep>/evidence/, remove. Anything else,
# a different driver, an extra or unpinned local file, a path outside <rd>, or another run dir, is printed as BAD.
cat > "$T/xport_check.py" <<'PY'
import hashlib, io, os, re, subprocess, sys, tarfile
C, R, SHA, PIN, INTEL, ARM, SUMS, IN, MUT = sys.argv[1:10]
hosts = {INTEL: ("intel", "x86_64"), ARM: ("arm", "arm64")}
drv = subprocess.run(["git", "-C", R, "show", f"{SHA}:tests/mac/bundle_layout_spike_leg.sh"], capture_output=True).stdout
drv_sha = hashlib.sha256(drv).hexdigest() if drv else None
blobs = {}
for line in subprocess.run(["git", "-C", R, "ls-tree", "-r", SHA], capture_output=True, text=True).stdout.splitlines():
    meta, path = line.split("\t", 1)
    blobs[path] = meta.split()[2]
pinned = {}
for line in open(SUMS):
    h, name = line.split()
    pinned[h] = name
def committed_tar(data):
    try:
        t = tarfile.open(fileobj=io.BytesIO(data))
        regs = 0
        for m in t.getmembers():
            if m.isdir() or m.type == tarfile.XGLTYPE:
                continue
            if not m.isfile():
                return False
            body = t.extractfile(m).read()
            if hashlib.sha1(b"blob %d\0" % len(body) + body).hexdigest() != blobs.get(m.name):
                return False
            regs += 1
        return regs > 0
    except Exception:
        return False
tokens = {"intel": [], "arm": []}
bad = []
rds = {}
rd_re = re.compile(r"zb-gate-%s-[0-9a-f]+" % SHA)
ns = sorted(int(f.split(".")[1]) for f in os.listdir(C) if re.fullmatch(r"xport\.\d+", f))
for n in ns:
    kind, a, b = open(f"{C}/xport.{n}").read().rstrip("\n").split("\t", 2)
    if kind == "ssh":
        if a not in hosts:
            bad.append(f"{n}: ssh to unknown host {a}"); continue
        role, arch = hosts[a]
        w = b.split(" ")
        stdin = open(f"{C}/xport.{n}.stdin", "rb").read()
        if drv_sha is None or hashlib.sha256(stdin).hexdigest() != drv_sha:
            bad.append(f"{n}: ssh {role} '{b}' does not send the committed leg driver"); continue
        if len(w) < 4 or w[:2] != ["/bin/bash", "-s"] or not rd_re.fullmatch(w[3]):
            bad.append(f"{n}: ssh {role} unknown command '{b}'"); continue
        if w[2] == "create" and len(w) == 4 and role not in rds:
            rds[role] = w[3]; tokens[role].append("create")
        elif w[2] == "run" and w[3:] == [rds.get(role), arch, PIN, MUT]:
            tokens[role].append("run")
        elif w[2] == "remove" and len(w) == 4 and w[3] == rds.get(role):
            tokens[role].append("remove")
        else:
            bad.append(f"{n}: ssh {role} unadmitted command '{b}'")
    elif kind == "scp":
        srcs = open(f"{C}/xport.{n}.srcs").read().splitlines()
        if ":" in a:
            host, path = a.split(":", 1)
            role = hosts.get(host, ("?",))[0]
            if role == "?" or path != f"{rds.get(role)}/inputs/":
                bad.append(f"{n}: scp to unadmitted destination {a}"); continue
            kinds = []
            for i, src in enumerate(srcs):
                if ":" in src:
                    kinds.append("remote:" + src); continue
                data = open(f"{C}/xport.{n}.src.{i}", "rb").read()
                h = hashlib.sha256(data).hexdigest()
                if h in pinned and os.path.basename(src) == pinned[h]:
                    kinds.append(pinned[h])
                elif committed_tar(data):
                    kinds.append("committed-source")
                else:
                    kinds.append("UNPINNED:" + src)
            if sorted(kinds) == ["committed-source", "py.pkg", "sites.tar"]:
                tokens[role].append("inputs")
            else:
                bad.append(f"{n}: scp {role} inputs are {sorted(kinds)}")
        else:
            ok = len(srcs) == 1 and ":" in srcs[0]
            host, path = srcs[0].split(":", 1) if ok else ("", "")
            role = hosts.get(host, ("?",))[0]
            if ok and role != "?" and path == f"{rds.get(role)}/evidence.tar" and os.path.realpath(a).startswith(IN + "/evidence/"):
                tokens[role].append("evidence")
            else:
                bad.append(f"{n}: scp from the Mac unadmitted: {srcs} -> {a}")
    else:
        bad.append(f"{n}: unknown call {kind}")
print("intel " + " ".join(tokens["intel"]))
print("arm " + " ".join(tokens["arm"]))
for b_ in bad:
    print("BAD " + b_)
PY

# --- the scratch repo: the real spike, leg driver, transport and host keys, the stand-in stager, a committed agent tree ---
R="$T/repo"
mkdir -p "$R/tests/mac" "$R/packaging/macos" "$R/agent/host/zb_agent_host" "$R/src"
cp "$ROOT/tests/mac/bundle_layout_spike.sh" "$ROOT/tests/mac/mac_gate_lib.sh" "$ROOT/tests/mac/build-on-mac.sh" \
  "$ROOT/tests/mac/known_hosts" "$R/tests/mac/"
[ -e "$ROOT/tests/mac/bundle_layout_spike_leg.sh" ] && cp "$ROOT/tests/mac/bundle_layout_spike_leg.sh" "$R/tests/mac/"
cp "$ROOT/packaging/macos/Info.plist" "$R/packaging/macos/"
[ -e "$ROOT/packaging/macos/relocate_agent_data.py" ] && cp "$ROOT/packaging/macos/relocate_agent_data.py" "$R/packaging/macos/"
fake "$R/packaging/macos/stage_agent_runtime.sh" <<EOF
# Selftest stand-in: records its arguments, resolves python like the real stager, stages the documented layout.
NAME=stager; $rec
printf '%s\n' "\$@" > "\$C/stager.\$ZB_ROLE"
REPO=\$(cd "\$(dirname "\$0")/../.." && pwd)
cat "\$REPO/agent/host/marker" > "\$C/agent-tree.\$ZB_ROLE"
xcrun --find python3 >/dev/null
/usr/bin/python3 -I -c 'import sys' || exit 1
[ -s "\$1" ] && [ -d "\$4" ] && [ -d "\$5" ] || { echo "stand-in stager: missing input" >&2; exit 1; }
A="\$3/Frameworks/agent-host"; V="\$A/Python.framework/Versions/3.12"
mkdir -p "\$V/bin" "\$V/lib/python3.12" "\$V/Resources" "\$A/zb_agent_host" "\$A/site-packages/claude_agent_sdk/_bundled" "\$A/site-packages/rpds"
M='\\xcf\\xfa\\xed\\xfe stand-in\\n'   # MH_MAGIC_64: code, by its magic bytes
printf "\$M" > "\$V/Python"; printf "\$M" > "\$V/bin/python3.12"; printf 'import sys\n' > "\$V/lib/python3.12/os.py"
printf '<plist/>\n' > "\$V/Resources/Info.plist"
# the root of the python.org framework: the only Python.framework relocate_agent_data.py exempts
ln -s 3.12 "\$A/Python.framework/Versions/Current"
for n in Headers Python Resources; do ln -s "Versions/Current/\$n" "\$A/Python.framework/\$n"; done
printf "\$M" > "\$A/site-packages/claude_agent_sdk/_bundled/claude"; printf "\$M" > "\$A/site-packages/rpds/rpds.so"
printf '# agent\n' > "\$A/zb_agent_host/__init__.py"; printf '{}\n' > "\$A/runtime.json"
[ "\$(cat "\$C/scenario")" = escape ] && ln -s "\$HOME/.profile" "\$A/site-packages/escape-link"
exit 0
EOF
echo committed > "$R/agent/host/marker"; echo "# host" > "$R/agent/host/zb_agent_host/__init__.py"
cat > "$R/packaging/macos/agent_runtime_pins.json" <<EOF
{"python_pkg": {"url": "https://www.python.org/ftp/python/3.12.10/python-3.12.10-macos11.pkg", "sha256": "$PIN",
  "sigstore_identity": "selftest@python.org", "sigstore_issuer": "https://selftest.invalid"},
 "uv_lock_sha256": "$(printf '%064d' 2)",
 "sigstore_verifier": {"requirements": "packaging/macos/sigstore_verifier.txt", "sha256": "$(printf '%064d' 3)"}}
EOF
echo "// stand-in" > "$R/src/main.zig"
echo build > "$R/build.zig"; echo zon > "$R/build.zig.zon"; echo '{}' > "$R/zigbrowser.json"
G=(env -i PATH=/usr/bin:/bin HOME="$T/home" GIT_CONFIG_NOSYSTEM=1 git -C "$R")
"${G[@]}" init -q && "${G[@]}" add -A \
  && "${G[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m staged \
  || { bad "could not build the scratch repo"; exit 1; }
echo uncommitted > "$R/agent/host/marker"
SHA=$("${G[@]}" rev-parse HEAD)
DATA=0   # non-Mach-O files under Contents/Frameworks outside Python.framework once relocate_agent_data.py has run

IN="$T/prep"
mkdir -p "$IN" "$T/sites/site-x86_64" "$T/sites/site-aarch64"
echo "pkg stand-in" > "$IN/py.pkg"
(cd "$T/sites" && tar -cf "$IN/sites.tar" site-x86_64 site-aarch64)
(cd "$IN" && sha256sum py.pkg sites.tar > inputs.sha256)
homes_snapshot() { (cd "$X/hosts" && find . -mindepth 2 ! -path './*/zb-gate-*' -printf '%p|%y|%m|%s|%T@\n' | sort); }

run_spike() { # run_spike <label> <scenario> <verify mode> <where> [VAR=value ...]: sets rc, out
  local label=$1 scen=$2 mode=$3 where=$4; shift 4
  rm -rf "${C:?}"/*
  [ -n "${KEEP_EV:-}" ] || rm -rf "${IN:?}/evidence"   # KEEP_EV=1: keep the prep evidence (the candidate's result)
  echo "$scen" > "$C/scenario"; echo "$mode" > "$C/verify_mode"; echo "$where" > "$C/verify_where"
  homes_snapshot > "$T/homes.before"
  (cd "$R" && env -i PATH="$X/bin:/usr/bin:/bin" HOME="$T/home" TMPDIR="$T/tmp" ZB_MAC_HOST="$INTEL" ZB_MAC_ARM_HOST="$ARM" \
     ZB_MAC_KEY="$T/home/no_such_key" "$@" timeout 300 bash tests/mac/bundle_layout_spike.sh run "$IN" \
     >"$T/out.$label" 2>&1 </dev/null)
  rc=$?
  out=$(cat "$T/out.$label")
}
roots_left() { find "$X/hosts" -maxdepth 2 -name 'zb-gate-*' 2>/dev/null; }
check_removed() { # <label>
  local left; left=$(roots_left)
  [ -z "$left" ] && ok "$1: every run root is removed" || bad "$1: run roots left: $left"
}
leg_class() { awk -F'\t' -v a="$1" '$1 == "LEG" && $2 == a { print $4 }' <<<"$out" | tail -n 1; }
leg_detail() { awk -F'\t' -v a="$1" '$1 == "LEG" && $2 == a { print $5 }' <<<"$out" | tail -n 1; }
mac_tool_calls() { cat "$C/tools.log" 2>/dev/null | wc -l; }   # every recorded Mac-side tool call, of any kind
spike_result() { awk -F'\t' '$1 == "SPIKE-RESULT" { print $4 " " $5 }' <<<"$out" | tail -n 1; }
xport() { python3 "$T/xport_check.py" "$C" "$R" "$SHA" "$PIN" "$INTEL" "$ARM" "$IN/inputs.sha256" "$IN" "$1"; }
check_xport() { # <label> <mutant> <intel tokens> <arm tokens>
  local got want
  got=$(xport "$2"); want=$(printf 'intel %s\narm %s' "$3" "$4")
  [ "$got" = "$want" ] && ok "$1: every ssh/scp call is admitted (intel: $3; arm: ${4:-none})" \
    || bad "$1: ssh/scp calls are '$(tr '\n' ';' <<<"$got")', want '$(tr '\n' ';' <<<"$want")'"
}
LEG5="create inputs run evidence remove"
root_of() { # <role>: the physical run root named in the sandbox-exec calls
  local f
  for f in "$C"/sbx.*.role; do
    [ -e "$f" ] && [ "$(cat "$f")" = "$1" ] || continue
    tr '\0' '\n' < "${f%.role}.argv" | grep -oE "^$X/hosts/$1/zb-gate-$SHA-[0-9a-f]+" | head -n 1 && return
  done
}

# sbx_sequence <role>: one token per sandbox-exec call, in order
sbx_sequence() {
  local role=$1 n=0 r a last seq=() H="$X/hosts/$1" rt
  rt=$(root_of "$role")
  while [ -e "$C/sbx.$n.argv" ]; do
    if [ "$(cat "$C/sbx.$n.role")" = "$role" ]; then
      mapfile -d '' a < "$C/sbx.$n.argv"
      last=${a[${#a[@]}-1]}
      case "${a[0]}|${a[2]:-}|$last" in
        /usr/bin/true*) seq+=(parse) ;;
        "/bin/mkdir||$rt/evidence") seq+=(mkdir-evidence) ;;
        "/bin/sh|: > \"\$1\"|$rt/evidence/positive") seq+=(positive) ;;
        "/bin/sh|: > /dev/null|: > /dev/null") seq+=(devnull) ;;
        "/bin/sh|cat > \"\$1\"|$rt/evidence/profile") seq+=(profile) ;;
        "/bin/sh|$SNAP|$rt/audit-tmp")   # the snapshot: sorted under the profile, temporary files in the root
          case "${#a[@]}|${a[4]:-}" in
            "6|$rt/evidence/audit.before") seq+=(audit-before) ;; "6|$rt/evidence/audit.after") seq+=(audit-after) ;;
            *) seq+=(audit-bad) ;;
          esac ;;
        "/bin/sh|: > \"\$1\"|$H/.zb-spike-canary-"*) seq+=(canary-home) ;;
        "/bin/sh|: > \"\$1\"|$H/var/folders/zz/zyxw/T/zb-spike-canary-"*) seq+=(canary-temp) ;;
        "/bin/sh|: > \"\$1\"|$H/var/folders/zz/zyxw/C/zb-spike-canary-"*) seq+=(canary-cache) ;;
        "/bin/sh|cd \"\$1\" && tar -cf evidence.tar evidence|$rt") seq+=(evidence-tar) ;;
        "/bin/bash|"*) if [ "${a[3]:-}" = bash ] && [ "${a[4]:-}" = "$rt" ]; then
                         case "${a[2]}" in *'zig" build'*) seq+=(build) ;; *stage_agent_runtime.sh*) seq+=(post) ;; *) seq+=(bash-other) ;; esac
                       else seq+=(bash-bad-args); fi ;;
        *) seq+=("other:${a[0]}") ;;
      esac
    fi
    n=$((n + 1))
  done
  echo "${seq[*]}"
}
SNAP='mkdir -p "$2" && LC_ALL=C TMPDIR="$2" sort -T "$2" > "$1"'
WANT_SEQ="parse mkdir-evidence positive devnull profile audit-before canary-home canary-temp canary-cache build post audit-after evidence-tar"

US=$'\x1f'
check_signing() { # check_signing <label> <role>: the old B4 on the recorded codesign calls
  local before=$fails label=$1 role=$2 f k id deep verify strict vdeep tgt kind i
  local -a a calls=() macho=()
  for f in $(ls "$C" | grep -E "^codesign\.$role\.[0-9]+$" | sort -t. -k3 -n); do
    mapfile -d '' a < "$C/$f"
    id= deep=no verify=no strict=no vdeep=no
    for ((k = 0; k < ${#a[@]}; k++)); do
      case "${a[k]}" in -s|--sign) id=${a[k+1]:-} ;; --deep) deep=yes; vdeep=yes ;; --verify|-v) verify=yes ;; --strict*) strict=yes ;; esac
    done
    tgt=${a[${#a[@]}-1]}
    calls+=("$tgt$US$id$US$deep$US$verify$US$strict$US$vdeep$US$(cat "$C/$f.target")")
  done
  local n=${#calls[@]} last_file=-1 first_dir=-1 app_idx=-1 ver_idx=-1
  for ((i = 0; i < n; i++)); do
    IFS=$US read -r tgt id deep verify strict vdeep kind <<<"${calls[i]}"
    if [ "$verify" = yes ]; then
      [ "$i" -eq $((n - 1)) ] || bad "$label K3 $role: the verify call is not the last codesign call"
      [ "$strict" = yes ] && [ "$vdeep" = yes ] || bad "$label K3 $role: the verify call lacks --strict or --deep"
      [ "$tgt" = "$APP" ] || bad "$label K3 $role: verify targets '$tgt', want $APP"
      continue
    fi
    [ "$id" = - ] || bad "$label K3 $role: '$tgt' signed with identity '$id', want '-'"
    [ "$deep" = no ] || bad "$label K3 $role: '$tgt' signed with --deep"
    [ "$kind" != symlink ] || bad "$label K3 $role: the symlink '$tgt' was signed"
    case "$tgt" in "$APP") app_idx=$i ;; */Python.framework/Versions/3.12) ver_idx=$i ;; esac
    case "$tgt" in *.app|*/Versions/3.12) [ "$first_dir" -ge 0 ] || first_dir=$i ;; *) last_file=$i; macho+=("$tgt") ;; esac
  done
  local want_files
  want_files=$(printf '%s\n' "$APP/Contents/MacOS/zigBrowser" "$APP/Contents/Frameworks/libwkwebview_shim.dylib" \
    "$APP/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/Python" \
    "$APP/Contents/Frameworks/agent-host/Python.framework/Versions/3.12/bin/python3.12" \
    "$APP/Contents/Frameworks/agent-host/site-packages/claude_agent_sdk/_bundled/claude" \
    "$APP/Contents/Frameworks/agent-host/site-packages/rpds/rpds.so" | sort)
  [ "$(printf '%s\n' "${macho[@]+"${macho[@]}"}" | sort)" = "$want_files" ] \
    || bad "$label K3 $role: the signed files are not exactly the six Mach-O files once each: ${macho[*]+"${macho[*]}"}"
  { [ "$last_file" -lt "$first_dir" ] && [ "$ver_idx" -ge 0 ] && [ "$app_idx" -gt "$ver_idx" ] && [ "$app_idx" -eq $((n - 2)) ]; } \
    || bad "$label K3 $role: order is not files, then Versions/3.12, then the .app (files end $last_file, dirs start $first_dir, version $ver_idx, app $app_idx of $n)"
  local depth prev=999
  for tgt in "${macho[@]+"${macho[@]}"}"; do
    depth=$(tr -cd / <<<"$tgt" | wc -c)
    [ "$depth" -le "$prev" ] || bad "$label K3 $role: '$tgt' was signed after a shallower file (not deepest first)"
    prev=$depth
  done
  [ "$fails" -eq "$before" ] && ok "$label K3 $role: ad hoc, never --deep; six Mach-O files deepest first, then Versions/3.12, then the .app; verify --strict --deep last"
}

# ===== K1-K4: clean =====
run_spike clean none clean both
if [ "$rc" -eq 0 ] && [ "$(leg_class x86_64)" = LAYOUT-OK ] && [ "$(leg_class arm64)" = LAYOUT-OK ] \
   && grep -qxF "$(printf 'SPIKE-RESULT\t%s\tnone\tx86_64=LAYOUT-OK\tarm64=LAYOUT-OK' "$SHA")" <<<"$out"; then
  ok "clean K1: exit 0, LAYOUT-OK on both legs, SPIKE-RESULT for $SHA"
else bad "clean K1: exit $rc: $(grep -E '^(LEG|SPIKE-RESULT|PHASE)|FAIL|NOT RUN' <<<"$out" | tail -n 6 | tr '\n' ' ')"; fi
for role in intel arm; do
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  rt=$(root_of "$role")
  seq=$(sbx_sequence "$role")
  [ "$seq" = "$WANT_SEQ" ] && ok "clean K1 $role: sandbox-exec calls are exactly: $seq" \
    || bad "clean K1 $role: sandbox-exec calls are '$seq', want '$WANT_SEQ'"
  want_prof=$(printf '(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write* (subpath "%s") (literal "/dev/null"))' "$rt")
  nprof=0 badprof=0
  for f in "$C"/sbx.*.role; do
    [ -e "$f" ] && [ "$(cat "$f")" = "$role" ] || continue
    nprof=$((nprof + 1)); [ "$(cat "${f%.role}.profile")" = "$want_prof" ] || badprof=$((badprof + 1))
  done
  if [ -n "$rt" ] && [[ "$rt" == "$X/hosts/$role/zb-gate-$SHA-"* ]] && [ "$nprof" -gt 0 ] && [ "$badprof" -eq 0 ]; then
    ok "clean K1 $role: all $nprof profiles are the exact four lines, write grant only the physical root $rt and /dev/null"
  else bad "clean K1 $role: root '$rt', $badprof of $nprof profiles differ from: $want_prof"; fi
  unwrapped=$(awk -F'\t' -v r="$role" '$3 == r && $2 != 1 { print $1 ": " $4 }' "$C/tools.log" 2>/dev/null)
  seen=$(awk -F'\t' -v r="$role" '$3 == r { print $1 }' "$C/tools.log" 2>/dev/null | sort -u | tr '\n' ' ')
  if [ -z "$unwrapped" ] && [ "$seen" = "codesign file python3 stager xcrun zig " ]; then
    ok "clean K1 $role: every Mac tool call ran inside the sandbox ($seen)"
  else bad "clean K1 $role: tools seen '$seen'; outside the sandbox: $(tr '\n' ';' <<<"$unwrapped")"; fi
  # K2
  nonce=${rt##*-} H="$X/hosts/$role"
  can=()
  for n in $(seq 0 40); do
    [ -e "$C/sbx.$n.role" ] && [ "$(cat "$C/sbx.$n.role")" = "$role" ] || continue
    mapfile -d '' a < "$C/sbx.$n.argv"; case "${a[${#a[@]}-1]}" in *zb-spike-canary-*) can+=("${a[${#a[@]}-1]}") ;; esac
  done
  wantc="$H/.zb-spike-canary-$nonce $H/var/folders/zz/zyxw/T/zb-spike-canary-$nonce $H/var/folders/zz/zyxw/C/zb-spike-canary-$nonce"
  if [ "${can[*]+"${can[*]}"}" = "$wantc" ] && grep -qP '^PHASE\tcanaries\tok\t3 refused$' "$IN"/evidence/"$arch"-*/driver.out 2>/dev/null \
     && ! ls "${can[@]}" >/dev/null 2>&1; then
    ok "clean K2 $role: the three canaries (home, getconf temp, getconf cache) were refused and are absent"
  else bad "clean K2 $role: canaries '${can[*]+"${can[*]}"}', want '$wantc'"; fi
  # K3
  mapfile -t sa < <(cat "$C/stager.$role" 2>/dev/null)
  if [ "${sa[0]:-}" = "$rt/inputs/py.pkg" ] && [ "${sa[1]:-}" = "$PIN" ] && [ "${sa[2]:-}" = "$rt/$APP/Contents" ] \
     && [ "${sa[3]:-}" = "$rt/site-x86_64" ] && [ "${sa[4]:-}" = "$rt/site-aarch64" ] \
     && [ "$(cat "$C/agent-tree.$role" 2>/dev/null)" = committed ]; then
    ok "clean K3 $role: the stager gets <root>/inputs/py.pkg, the pin, the app's Contents and both site trees, from the committed tree"
  else bad "clean K3 $role: stager args '${sa[*]:-}', agent tree '$(cat "$C/agent-tree.$role" 2>/dev/null)'"; fi
  tree=$(cat "$C/tree.$role" 2>/dev/null)
  if grep -qx ./Contents/MacOS/zigBrowser <<<"$tree" && grep -qx ./Contents/Frameworks/libwkwebview_shim.dylib <<<"$tree" \
     && grep -qx ./Contents/Frameworks/agent-host/runtime.json <<<"$tree" && grep -qx ./Contents/Resources/agent-host/runtime.json <<<"$tree" \
     && ! grep -q zb-4pa80-stray <<<"$tree"; then
    ok "clean K3 $role: the verified .app holds the exe, the shim and agent-host (runtime.json also in Resources), and no stray file"
  else bad "clean K3 $role: the verified tree is: $(tr '\n' ' ' <<<"$tree")"; fi
  check_signing clean "$role"
  grep -qP "^SPIKE\tcensus\t$DATA$" "$IN"/evidence/"$arch"-*/driver.out 2>/dev/null \
    && ok "clean K3 $role: the census counts $DATA data files under Frameworks after the relocation" || bad "clean K3 $role: census line missing or not $DATA"
  # K4
  ev=$(ls -d "$IN"/evidence/"$arch"-zb-gate-"$SHA"-* 2>/dev/null | head -n 1)
  missing=
  for f in driver.out evidence/build.log evidence/verify.log evidence/audit.before evidence/audit.after evidence/profile \
           evidence/relocate.log evidence/census.log; do
    [ -s "$ev/$f" ] || missing+="$f "
  done
  for f in evidence/stage.log evidence/sign.log; do [ -e "$ev/$f" ] || missing+="$f "; done
  [ -n "$ev" ] && [ -z "$missing" ] && grep -qx LEGDONE "$ev/driver.out" \
    && ok "clean K4 $role: driver output, logs and both audits are in $IN/evidence" || bad "clean K4 $role: evidence '$ev' lacks: $missing"
done
check_removed "clean K4"
check_xport "clean K14" none "$LEG5" "$LEG5"
for role in intel arm; do
  arch=x86_64; [ "$role" = arm ] && arch=arm64
  H="$X/hosts/$role" missing=
  for f in "$IN"/evidence/"$arch"-*/evidence/audit.before "$IN"/evidence/"$arch"-*/evidence/audit.after; do
    for want in "$H/var/folders/zz/zyxw/T/resident" "$H/var/folders/zz/zyxw/C/resident" "$H/Library/Caches/com.apple.existing/data" "$H/.profile"; do
      grep -qE "^$want\|[^|]+\|[0-7]+\|[0-9]+\|[0-9]+\|[0-9]+$" "$f" 2>/dev/null || missing+="${f##*/}:${want#$H/} "
    done
    grep -q '/zb-gate-' "$f" 2>/dev/null && missing+="${f##*/}:the-run-root "
  done
  [ -z "$missing" ] && ok "clean K4 $role: both audits hold path|type|mode|inode|size|mtime for the getconf temp and cache roots, ~/Library/Caches and the shallow home, never the root" \
    || bad "clean K4 $role: audit lines missing or wrong: $missing"
done
homes_snapshot > "$T/homes.after"
cmp -s "$T/homes.before" "$T/homes.after" && ok "clean K2: the fake Mac homes are exactly as before (outside the removed roots)" \
  || bad "clean K2: the fake homes changed: $(diff "$T/homes.before" "$T/homes.after" | grep -E '^[<>]' | head -n 4 | tr '\n' ' ')"

# ===== K5: safe NOT RUN =====
for scen in missing parse_error positive_fail; do
  [ "$scen" = missing ] && chmod -x "$P/usrbin/sandbox-exec"
  run_spike "$scen" "$scen" clean both
  [ "$scen" = missing ] && chmod +x "$P/usrbin/sandbox-exec"
  case "$scen" in missing|parse_error) want=preflight ;; positive_fail) want=positive ;; esac
  if [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [ "$(leg_class arm64)" = INCONCLUSIVE ] \
     && [[ "$(leg_detail x86_64)" == "$want: "* ]] && [[ "$(leg_detail arm64)" == "$want: "* ]] \
     && [ "$(spike_result)" = "x86_64=INCONCLUSIVE arm64=INCONCLUSIVE" ] && [ "$(mac_tool_calls)" -eq 0 ]; then
    ok "$scen K5: INCONCLUSIVE ($(leg_detail x86_64) / $(leg_detail arm64)) on both legs, exit 2, the Mac tool log is empty"
  else bad "$scen K5: exit $rc, intel '$(leg_class x86_64): $(leg_detail x86_64)', arm '$(leg_class arm64): $(leg_detail arm64)', Mac tool calls $(mac_tool_calls)"; fi
  check_removed "$scen K5"
  check_xport "$scen K14" none "$LEG5" "$LEG5"
done

# ===== K6: a non-refused canary is a BREACH =====
run_spike breach no_enforce clean both
canary=$(ls -A "$X/hosts/intel" | grep '^\.zb-spike-canary-' | head -n 1)
if [ "$rc" -eq 4 ] && [ "$(leg_class x86_64)" = BREACH ] && [ -z "$(leg_class arm64)" ] && [ -n "$canary" ] \
   && [[ "$(leg_detail x86_64)" == "$X/hosts/intel/$canary (root "* ]] && grep -q 'CONTAINMENT BREACH' <<<"$out" \
   && ! grep -q "$ARM" "$C/calls" && [ "$(mac_tool_calls)" -eq 0 ] && [ -d "$(roots_left | head -n 1)" ] \
   && [ "$(spike_result)" = "x86_64=BREACH arm64=NOT-RUN" ]; then
  ok "breach K6: BREACH names $canary, exit 4, x86_64=BREACH arm64=NOT-RUN; the canary and the root are kept; arm64 never contacted; the Mac tool log is empty"
else bad "breach K6: exit $rc, intel '$(leg_class x86_64): $(leg_detail x86_64)', arm '$(leg_class arm64)', result '$(spike_result)', canary '$canary', roots '$(roots_left)', Mac tool calls $(mac_tool_calls)"; fi
check_xport "breach K14" none "create inputs run" ""
rm -rf "$X/hosts/intel/"zb-gate-* "$X/hosts/intel/".zb-spike-canary-*

# ===== K7: the control (stray_in_frameworks), gated on the candidate =====
run_spike mutant_first none clean both ZB_SPIKE_MUTANT=stray_in_frameworks
{ [ "$rc" -eq 1 ] && grep -q 'REFUSED: the control runs only after the candidate is LAYOUT-OK on both' <<<"$out" && [ ! -s "$C/calls" ]; } \
  && ok "mutant_first K7: the control without the candidate's result is refused, exit 1, no ssh/scp" \
  || bad "mutant_first K7: exit $rc: $(tail -n 2 <<<"$out" | tr '\n' ' ')"
for vm in clean unsealed; do
  run_spike "mutant_cand_$vm" none clean both
  KEEP_EV=1 run_spike "mutant_$vm" none "$vm" both ZB_SPIKE_MUTANT=stray_in_frameworks
  if [ "$rc" -eq 2 ] && [ "$(spike_result)" = "x86_64=INCONCLUSIVE arm64=INCONCLUSIVE" ] && [[ "$(leg_detail x86_64)" == *"wrong stage"* ]] \
     && grep -qx ./Contents/Frameworks/agent-host/zb-4pa80-stray.txt "$C/tree.intel" && grep -qx ./Contents/Frameworks/agent-host/zb-4pa80-stray.txt "$C/tree.arm" \
     && [ "$(grep -hP '^SPIKE\tcensus\t' "$IN"/evidence/*/driver.out | sort | uniq -c | awk '{ print $1 " " $NF }' | tr '\n' ' ')" = "2 0 2 1 " ] \
     && ! grep -q EXPECTED-FAIL <<<"$out"; then
    ok "mutant_$vm K7: a control whose signing succeeds is INCONCLUSIVE on both legs (wrong stage) with a $vm verify; the stray file in the verified tree, census 1"
  else bad "mutant_$vm K7: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)' '$(leg_class arm64)'"; fi
done
check_xport "mutant K14" stray_in_frameworks "$LEG5" "$LEG5"

# ===== K8: a sandbox denial is never product evidence =====
run_spike deny_verify deny_verify clean both
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [ "$(leg_class arm64)" = INCONCLUSIVE ] \
  && [[ "$(leg_detail x86_64)" == *"denied"* ]] && ! grep -qE 'LAYOUT-FINDING|EXPECTED-FAIL' <<<"$out"; } \
  && ok "deny_verify K8: a denied verify with a sealed-resource message is INCONCLUSIVE, never LAYOUT-FINDING or EXPECTED-FAIL" \
  || bad "deny_verify K8: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)'"
check_removed "deny_verify K8"
run_spike deny_tool deny_tool clean both
nverify=$(grep -c -- '--verify' "$C/tools.log" 2>/dev/null || true)
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [[ "$(leg_detail x86_64)" == *"denied"* ]] && [ "$nverify" = 0 ]; } \
  && ok "deny_tool K8: a denied signing tool is INCONCLUSIVE ($(leg_detail x86_64)), no verify" \
  || bad "deny_tool K8: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)', verify calls $nverify"

# ===== K9: an escaping symlink =====
run_spike escape escape clean both
nsign=$(grep -c '^codesign	' "$C/tools.log" 2>/dev/null || true)
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [[ "$(leg_detail x86_64)" == "symlinks: 1 escape"* ]] && [ "$nsign" = 0 ]; } \
  && ok "escape K9: a staged symlink to outside the root is INCONCLUSIVE before any signing" \
  || bad "escape K9: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)', codesign calls $nsign"
check_removed "escape K9"

# ===== K10: every audited surface, both arches: an addition, a content change, a mode-only change or a deletion =====
restore_homes() {
  local role h d
  for role in intel arm; do
    h="$X/hosts/$role"
    for d in "$h/var/folders/zz/zyxw/T" "$h/var/folders/zz/zyxw/C"; do echo resident > "$d/resident"; chmod 644 "$d/resident"; rm -f "$d/zb-audit-added"; done
    echo resident > "$h/Library/Caches/com.apple.existing/data"; chmod 644 "$h/Library/Caches/com.apple.existing/data"
    rm -f "$h/Library/Caches/com.apple.existing/zb-audit-added" "$h/zb-audit-added"
    echo profile > "$h/.profile"; chmod 644 "$h/.profile"
  done
}
restore_homes
for row in intel:add:temp intel:chmod:cache intel:change:caches intel:delete:shallow \
           arm:delete:temp arm:add:cache arm:chmod:caches arm:change:shallow; do
  IFS=: read -r role op surf <<<"$row"
  H="$X/hosts/$role"
  case "$surf" in
    temp) d="$H/var/folders/zz/zyxw/T" f=resident ;; cache) d="$H/var/folders/zz/zyxw/C" f=resident ;;
    caches) d="$H/Library/Caches/com.apple.existing" f=data ;; shallow) d="$H" f=.profile ;;
  esac
  [ "$op" = add ] && f=zb-audit-added
  hit=x86_64 other=arm64; [ "$role" = arm ] && hit=arm64 other=x86_64
  run_spike "audit-$role-$op-$surf" "audit:$role:$op:$surf" clean both
  if [ "$rc" -eq 2 ] && [ "$(leg_class "$hit")" = INCONCLUSIVE ] && [[ "$(leg_detail "$hit")" == "audit delta outside the root: "*"$d/$f "* ]] \
     && [ "$(leg_class "$other")" = LAYOUT-OK ]; then
    ok "audit K10 $role $op $surf: INCONCLUSIVE on $hit naming ${d#$X/hosts/}/$f; $other LAYOUT-OK"
  else bad "audit K10 $role $op $surf: exit $rc, $hit '$(leg_class "$hit"): $(leg_detail "$hit")', $other '$(leg_class "$other")'"; fi
  restore_homes
done

# ===== K11: findings and inconclusive verify =====
run_spike finding none unsealed arm
{ [ "$rc" -eq 0 ] && [ "$(leg_class x86_64)" = LAYOUT-OK ] && [ "$(leg_class arm64)" = LAYOUT-FINDING ]; } \
  && ok "finding K11: an unsealed verify on arm64 is LAYOUT-FINDING, Intel LAYOUT-OK, exit 0" \
  || bad "finding K11: exit $rc, '$(leg_class x86_64)' '$(leg_class arm64)'"
run_spike generic none generic intel
{ [ "$rc" -eq 2 ] && [ "$(leg_class x86_64)" = INCONCLUSIVE ] && [ "$(leg_class arm64)" = LAYOUT-OK ]; } \
  && ok "generic K11: a verify failure with no code-signature diagnostic is INCONCLUSIVE, exit 2" \
  || bad "generic K11: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)' '$(leg_class arm64)'"

# ===== K12: refusals before any host is touched =====
run_spike noarm none clean both ZB_MAC_ARM_HOST=
{ [ "$rc" -eq 1 ] && grep -q 'NOT RUN: arm64 host not configured' <<<"$out" && [ ! -s "$C/calls" ]; } \
  && ok "noarm K12: NOT RUN, exit 1, no ssh/scp" || bad "noarm K12: exit $rc"
run_spike badmutant none clean both ZB_SPIKE_MUTANT=other
{ [ "$rc" -eq 1 ] && grep -q 'REFUSED: unknown ZB_SPIKE_MUTANT' <<<"$out" && [ ! -s "$C/calls" ]; } \
  && ok "badmutant K12: refused, exit 1, no ssh/scp" || bad "badmutant K12: exit $rc"
cp "$IN/py.pkg" "$T/py.pkg.good"; echo tampered >> "$IN/py.pkg"
run_spike tampered none clean both
{ [ "$rc" -eq 1 ] && grep -q 'do not match inputs.sha256' <<<"$out" && [ ! -s "$C/calls" ]; } \
  && ok "tampered K12: inputs that do not match inputs.sha256 are refused, no ssh/scp" || bad "tampered K12: exit $rc"
cp "$T/py.pkg.good" "$IN/py.pkg"

# ===== K13: no inherited regular-file descriptor outside the root (fd 1, fd 2, fd 9); pipes and root-local are fine =====
DRV="$R/tests/mac/bundle_layout_spike_leg.sh"
HENV=(env -i HOME="$X/homes/intel" ZB_ROLE=intel ZB_ARCH=x86_64 PATH="$X/hostbin:/usr/bin:/bin")
k=0
direct_root() { # a fresh root with the runner's inputs: sets RDX, RT
  k=$((k + 1)); RDX="zb-gate-$SHA-0123abc$k" RT="$X/hosts/intel/zb-gate-$SHA-0123abc$k"
  rm -rf "${C:?}"/*; echo none > "$C/scenario"; echo clean > "$C/verify_mode"; echo both > "$C/verify_where"
  (cd "$X/homes/intel" && "${HENV[@]}" bash -s create "$RDX" < "$DRV" | cat >/dev/null)
  "${G[@]}" archive --format=tar -o "$RT/inputs/src.tar" "$SHA" && cp "$IN/py.pkg" "$IN/sites.tar" "$RT/inputs/"
}
drun() { (cd "$X/homes/intel" && "${HENV[@]}" bash -s run "$RDX" x86_64 "$PIN" none < "$DRV"); }
refused_before_sbx() { # <label> <rc> <output> <fd>
  if [ "$2" -eq 3 ] && grep -qP "^PHASE\tdescriptors\tNOT-RUN\tfd $4 is a regular file outside the run root$" <<<"$3" \
     && [ ! -e "$C/sbx.0.argv" ] && [ "$(mac_tool_calls)" -eq 0 ]; then
    ok "$1: NOT RUN before any sandbox-exec or tool call"
  else bad "$1: exit $2, sandbox-exec calls $(cat "$C/sbx.count" 2>/dev/null || echo 0): $(tr '\n' ' ' <<<"$3" | cut -c1-200)"; fi
}
direct_root; drun > "$T/outside-fd1" 2>/dev/null; r=$?
refused_before_sbx "fd K13 fd1-outside" "$r" "$(cat "$T/outside-fd1")" 1; rm -rf "${RT:?}"
direct_root; o=$(drun 2> "$T/outside-fd2"); r=$?
refused_before_sbx "fd K13 fd2-outside" "$r" "$o" 2; rm -rf "${RT:?}"
direct_root; o=$(drun 2>/dev/null 9> "$T/outside-fd9"); r=$?
refused_before_sbx "fd K13 fd9-outside" "$r" "$o" 9; rm -rf "${RT:?}"
direct_root; o=$(drun 2>/dev/null 9> "$RT/inputs/fd9-root-local"); r=$?
{ [ "$r" -eq 0 ] && grep -qx LEGDONE <<<"$o" && grep -qP '^PHASE\tpreflight\tok$' <<<"$o"; } \
  && ok "fd K13 fd9-root-local: a root-local fd 9 with pipe stdout/stderr runs the whole leg" || bad "fd K13 fd9-root-local: exit $r: $(tr '\n' ' ' <<<"$o" | cut -c1-200)"
rm -rf "${RT:?}"
direct_root; o=$(drun 2>/dev/null 9> >(cat >/dev/null)); r=$?
{ [ "$r" -eq 0 ] && grep -qx LEGDONE <<<"$o"; } \
  && ok "fd K13 fd9-pipe: a pipe on fd 9 runs the whole leg" || bad "fd K13 fd9-pipe: exit $r: $(tr '\n' ' ' <<<"$o" | cut -c1-200)"
rm -rf "${RT:?}"

# ===== K14: a run root that is a symlink to an outside directory is refused before any sandbox or tool =====
run_spike swap_root swap_root clean both ZB_SPIKE_REMOVE_SLEEP=0
if [ "$rc" -eq 2 ] && [[ "$(leg_detail x86_64)" == "root: "* ]] && [[ "$(leg_detail arm64)" == "root: "* ]] \
   && [ ! -e "$C/sbx.0.argv" ] && [ "$(mac_tool_calls)" -eq 0 ] && outside_snapshot | cmp -s - "$T/outside.want" \
   && [ "$(grep -c '^RETAINED' <<<"$out")" -eq 2 ]; then
  ok "swap_root K14: a root swapped for a symlink after transfer is INCONCLUSIVE (root) on both legs, no sandbox-exec or tool call, the target unchanged, the unremovable root named RETAINED"
else bad "swap_root K14: exit $rc, '$(leg_class x86_64): $(leg_detail x86_64)' '$(leg_class arm64): $(leg_detail arm64)', sandbox-exec calls $(cat "$C/sbx.count" 2>/dev/null || echo 0)"; fi
# The validated remove refuses the symlink, so it is retried (3) and tried once more at exit (SilverRidge 0d0656f4).
check_xport "swap_root K14" none "create inputs run evidence remove remove remove remove" "create inputs run evidence remove remove remove remove"
for role in intel arm; do
  find "$X/hosts/$role" -maxdepth 1 -name 'zb-gate-*' -type l -delete
  case "$X/swapped-aside-$role" in "$X"/swapped-aside-*) rm -rf "${X:?}/swapped-aside-$role" ;; esac
done
rm -rf "${C:?}"/*; echo none > "$C/scenario"
RDX="zb-gate-$SHA-0123abcf"
ln -s "$X/outside" "$X/hosts/intel/$RDX"
o=$( (cd "$X/homes/intel" && "${HENV[@]}" bash -s create "$RDX" < "$DRV") ); r1=$?
o2=$( (cd "$X/homes/intel" && "${HENV[@]}" bash -s remove "$RDX" < "$DRV") ); r2=$?
o3=$(drun 2>/dev/null); r3=$?
if [ "$r1" -eq 3 ] && [ "$r2" -eq 3 ] && [ "$r3" -eq 3 ] && grep -qP '^PHASE\troot\tNOT-RUN\t' <<<"$o3" && [ ! -e "$C/sbx.0.argv" ] \
   && [ "$(mac_tool_calls)" -eq 0 ] && [ -L "$X/hosts/intel/$RDX" ] && outside_snapshot | cmp -s - "$T/outside.want"; then
  ok "symlink-root K14: a pre-existing symlink at the controlled name is refused by create, remove and run; the target is unchanged"
else bad "symlink-root K14: create $r1, remove $r2, run $r3 ($(tr '\n' ' ' <<<"$o $o2 $o3" | cut -c1-200))"; fi
rm -f "$X/hosts/intel/$RDX"

if [ "$fails" -eq 0 ]; then printf 'PASS\tmac-bundle-layout-spike-containment-selftest\n'; exit 0; fi
printf 'FAIL\tmac-bundle-layout-spike-containment-selftest\t%s failure(s)\n' "$fails"
exit 1
