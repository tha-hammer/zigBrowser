#!/usr/bin/env bash
# Shared by every caller of tests/mac/build-on-mac.sh: the seven Mac gates and packaging/macos/build-dmg.sh (plan
# R30-MS1, bd 4pa.59 + 4pa.77). Source it from the repo top. It gives:
#   mac_ssh_opts KEY / mac_scp_opts KEY  NUL-delimited ssh/scp argv pinned to tests/mac/known_hosts
#                                        (StrictHostKeyChecking=yes, BatchMode=yes, IdentitiesOnly=yes, no askpass:
#                                        SSH_ASKPASS unset and SSH_ASKPASS_REQUIRE=never; bd 3ui.9);
#   mac_build HOST KEY [TIMEOUT]         build ${ZB_GATE_COMMIT:-HEAD} on HOST into a fresh ~/zb-gate-<sha>-<nonce>,
#                                        keep it, set MAC_RDIR to it and record it; non-zero on any failure;
#   mac_remove_run_dirs                  remove every run dir mac_build recorded and VERIFY each is gone: one
#                                        REMOVED<TAB>host<TAB>dir per confirmed-absent dir, else RETAINED<TAB>host<TAB>
#                                        dir<TAB>why (on stderr) and a non-zero status (fail closed; SilverRidge 0632602f). A gate
#                                        whose result depends on it calls it before its PASS line; the EXIT trap call
#                                        then has nothing left;
#   mac_keep_run_dir HOST DIR WHY        keep that dir (never removed here) and report RETAINED<TAB>host<TAB>dir<TAB>why.
# A gate works ONLY in MAC_RDIR, never in a shared home path, so a stale tree from another run cannot pass it.
# Hostless selftest of all callers: tests/mac/mac_gate_callers_selftest.sh (zig build test-mac-build-script).

MAC_KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
export SSH_ASKPASS_REQUIRE=never
MAC_RUN_DIRS=()   # "host<TAB>key<TAB>dir" for every run dir this gate owns
MAC_RDIR=

mac_ssh_opts() { # $1=key
  printf '%s\0' env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -F none -i "$1" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$MAC_KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10
}
mac_scp_opts() { # $1=key
  printf '%s\0' env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -F none -i "$1" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$MAC_KNOWN_HOSTS" -o ConnectTimeout=15
}

mac_build() { # $1=host $2=key [$3=timeout seconds, 0 = none]
  local host="$1" key="$2" limit="${3:-0}" out rc rdir passed
  MAC_RDIR=
  # Captured, then printed: `tee /dev/stderr` reopens a stderr that is redirected to a log file and truncates it (bd 3ui.10).
  out=$(ZB_MAC_HOST="$host" ZB_MAC_KEY="$key" ZB_KEEP_REMOTE_DIR=1 timeout "$limit" bash tests/mac/build-on-mac.sh)
  rc=$?
  printf '%s\n' "$out" >&2
  rdir=$(awk -F'\t' '$1 == "ZB_REMOTE_DIR" { print $2; exit }' <<<"$out")
  if [[ "$rdir" =~ ^zb-gate-[0-9a-f]{40}-[0-9a-f]+$ ]]; then
    MAC_RUN_DIRS+=("$host"$'\t'"$key"$'\t'"$rdir")   # removed at exit even when the build fails
  else
    echo "FAIL: build-on-mac.sh on $host named no run dir" >&2; return 1
  fi
  [ "$rc" -eq 0 ] || { echo "FAIL: build-on-mac.sh on $host exited $rc" >&2; return 1; }
  passed=$(awk -F'\t' '$1 == "PASS" && $2 == "build-on-mac" { print $4 }' <<<"$out" | tail -n 1)
  [ "$passed" = "$rdir" ] || { echo "FAIL: build-on-mac.sh on $host gave no PASS line for $rdir" >&2; return 1; }
  MAC_RDIR=$rdir
}

mac_keep_run_dir() { # $1=host $2=run dir $3=why: drop it from the removal list and report it RETAINED
  local entry h k d
  local -a keep=()
  for entry in "${MAC_RUN_DIRS[@]+"${MAC_RUN_DIRS[@]}"}"; do
    IFS=$'\t' read -r h k d <<<"$entry"
    if [ "$h" = "$1" ] && [ "$d" = "$2" ]; then continue; fi
    keep+=("$entry")
  done
  MAC_RUN_DIRS=("${keep[@]+"${keep[@]}"}")
  printf 'RETAINED\t%s\t%s\t%s\n' "$1" "$2" "${3:?why}" >&2
}

mac_remove_run_dirs() {
  local entry host key rdir out rc bad=0
  local -a SSH
  for entry in "${MAC_RUN_DIRS[@]+"${MAC_RUN_DIRS[@]}"}"; do
    IFS=$'\t' read -r host key rdir <<<"$entry"
    if ! [[ "$rdir" =~ ^zb-gate-[0-9a-f]{40}-[0-9a-f]+$ ]]; then
      printf 'RETAINED\t%s\t%s\tnot a run dir name: nothing removed\n' "$host" "$rdir" >&2; bad=1; continue
    fi
    mapfile -d '' SSH < <(mac_ssh_opts "$key")
    # Absent only when the remote shell itself finds no file, dir or link there after the delete, and says so.
    rc=0
    out=$("${SSH[@]}" "$host" "cd / && d=\"\$HOME/$rdir\" && { [ ! -e \"\$d\" ] || find \"\$d\" -delete; } && [ ! -e \"\$d\" ] && [ ! -L \"\$d\" ] && printf 'ZB_ROOT_ABSENT\\t%s\\n' $rdir" </dev/null 2>&1) || rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "ZB_ROOT_ABSENT"$'\t'"$rdir" ]; then
      printf 'REMOVED\t%s\t%s\n' "$host" "$rdir" >&2
    else
      printf 'RETAINED\t%s\t%s\tits removal was not confirmed (ssh exit %s): %s\n' "$host" "$rdir" "$rc" \
        "$(printf '%s' "$out" | tr '\t\n' '  ' | cut -c1-200)" >&2
      bad=1
    fi
  done
  MAC_RUN_DIRS=()
  return "$bad"
}
