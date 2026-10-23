#!/usr/bin/env bash
# The ONE place a Mac run takes its hosts and key from (bd zigBrowser-3ui.13, SilverRidge a473a027). Sourced, never
# executed; there is no host or key default, real or fake:
#   mac_config one   needs ZB_MAC_HOST and ZB_MAC_KEY; sets HOST, INTEL_HOST and KEY;
#   mac_config two   also needs ZB_MAC_ARM_HOST; sets ARM_HOST and ARM_KEY (ZB_MAC_ARM_KEY, else the explicit KEY).
# A key must be an absolute path to a readable regular file that is not a symlink. A host is [user@]host made of
# letters, digits, '.', '_' and '-' (user) and letters, digits, '.' and '-' (host), not starting with '-': nothing an
# ssh/scp argument could read as an option, a remote path or shell syntax. Anything missing or invalid prints one
# `NOT RUN: ...` line naming the variable and exits 1, before the caller makes any ssh, scp, remote cleanup or other
# host contact; absence is never a skip or a pass. Scripts run from a commit's bytes source this file from that same
# commit's export. Hostless oracle: tests/mac/mac_config_selftest.sh (zig build test-mac-build-script).

mac_config_refuse() { echo "NOT RUN: $*" >&2; exit 1; }

mac_config_host() { # $1=variable name
  local v="${!1-}"
  [ -n "$v" ] || {
    if [ "$1" = ZB_MAC_ARM_HOST ]; then mac_config_refuse "arm64 host not configured (set ZB_MAC_ARM_HOST=user@host)"; fi
    mac_config_refuse "no Mac host configured (set $1=user@host)"
  }
  [[ "$v" =~ ^([A-Za-z0-9._][A-Za-z0-9._-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
    || mac_config_refuse "$1='$v' is not a plain user@host name"
}

mac_config_key() { # $1=variable name
  local v="${!1-}"
  [ -n "$v" ] || mac_config_refuse "no Mac ssh key configured (set $1=/absolute/path/to/key)"
  case "$v" in /*) ;; *) mac_config_refuse "$1='$v' is not an absolute path" ;; esac
  [ -f "$v" ] && [ ! -L "$v" ] && [ -r "$v" ] \
    || mac_config_refuse "$1='$v' is not a readable regular file (a symlink or directory is refused)"
}

mac_config() { # $1=one|two
  case "${1:-}" in one|two) ;; *) mac_config_refuse "mac_config needs one or two, got '${1:-}'" ;; esac
  mac_config_host ZB_MAC_HOST
  mac_config_key ZB_MAC_KEY
  HOST=$ZB_MAC_HOST INTEL_HOST=$ZB_MAC_HOST KEY=$ZB_MAC_KEY
  [ "$1" = two ] || return 0
  mac_config_host ZB_MAC_ARM_HOST
  if [ -n "${ZB_MAC_ARM_KEY-}" ]; then mac_config_key ZB_MAC_ARM_KEY; ARM_KEY=$ZB_MAC_ARM_KEY; else ARM_KEY=$KEY; fi
  ARM_HOST=$ZB_MAC_ARM_HOST
}
