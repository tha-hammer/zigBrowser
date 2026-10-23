#!/usr/bin/env bash
# Shared driver-side output oracle for macOS gate legs.
# Call only after the producer has completed and its exit status was checked.

mac_require_lines() { # $1=gate $2=host $3=arch $4=completed output $5...=exact required lines
  local gate=$1 host=$2 arch=$3 output=$4 expected
  shift 4
  for expected in "$@"; do
    if ! grep -Fqx -- "$expected" <<<"$output"; then
      printf 'FAIL\tremote-success\t%s\t%s\t%s\tmissing\n' "$gate" "$host" "$arch" >&2
      return 1
    fi
  done
}
