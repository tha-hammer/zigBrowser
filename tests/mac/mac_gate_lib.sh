#!/usr/bin/env bash
# Shared by every caller of tests/mac/build-on-mac.sh: the seven Mac gates and packaging/macos/build-dmg.sh (plan
# R30-MS1, bd 4pa.59 + 4pa.77). Source it from the repo top. It gives:
#   mac_ssh_opts KEY / mac_scp_opts KEY  NUL-delimited ssh/scp argv pinned to tests/mac/known_hosts
#                                        (StrictHostKeyChecking=yes, BatchMode=yes, IdentitiesOnly=yes, no askpass:
#                                        SSH_ASKPASS unset and SSH_ASKPASS_REQUIRE=never; bd 3ui.9);
#   mac_build HOST KEY [TIMEOUT]         build ${ZB_GATE_COMMIT:-HEAD} on HOST into a fresh ~/zb-gate-<sha>-<nonce>,
#                                        keep it, set MAC_RDIR to it and record it; non-zero on any failure;
#   mac_remove_run_dirs                  remove every run dir mac_build recorded (call it from the EXIT trap).
# A gate works ONLY in MAC_RDIR, never in a shared home path, so a stale tree from another run cannot pass it.
# Hostless selftest of all callers: tests/mac/mac_gate_callers_selftest.sh (zig build test-mac-build-script).

MAC_KNOWN_HOSTS="$PWD/tests/mac/known_hosts"
export SSH_ASKPASS_REQUIRE=never
MAC_RUN_DIRS=()   # "host<TAB>key<TAB>dir" for every run dir this gate owns
MAC_RDIR=

mac_ssh_opts() { # $1=key
  printf '%s\0' env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS ssh -i "$1" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$MAC_KNOWN_HOSTS" -o ConnectTimeout=15 -o ServerAliveInterval=10
}
mac_scp_opts() { # $1=key
  printf '%s\0' env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY -u SSH_ASKPASS scp -i "$1" -o IdentitiesOnly=yes -o BatchMode=yes \
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

mac_remove_run_dirs() {
  local entry host key rdir
  local -a SSH
  for entry in "${MAC_RUN_DIRS[@]+"${MAC_RUN_DIRS[@]}"}"; do
    IFS=$'\t' read -r host key rdir <<<"$entry"
    mapfile -d '' SSH < <(mac_ssh_opts "$key")
    "${SSH[@]}" "$host" "cd / && d=\"\$HOME/${rdir:?}\"; [ -d \"\$d\" ] && find \"\$d\" -delete; true" </dev/null \
      || echo "WARN: could not remove $rdir on $host" >&2
  done
  MAC_RUN_DIRS=()
}
