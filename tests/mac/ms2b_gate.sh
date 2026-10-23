#!/usr/bin/env bash
# MS2b gate — the WKWebView native-input port (nativeKey / nativeText) on BOTH Macs (unsigned build).
#
# Builds zigBrowser NATIVELY on each Mac (no -Dtarget) and runs the MS2b native-input e2e there: trusted
# key/text delivery, the FIFO ack, the ack-error and documentToken DOC_CHANGED guards, the per-pair
# ownership transition that closes the check->send race, and the partial-timeout contract. Like ms2a,
# WKWebView needs the WindowServer, so this runs as the console user (no xvfb). Driven from Linux over
# Tailscale SSH; fail-closed (arm64 host mandatory, explicit `|| return 1` per step).
set -euo pipefail


cd "$(git rev-parse --show-toplevel)"
. tests/mac/mac_gate_output.sh
# The Macs and the key come only from the explicit environment, never a default (bd 3ui.13): NOT RUN otherwise.
. tests/mac/mac_config.sh
mac_config two
# Builds one exact commit into a fresh per-run dir and works only there; pinned host keys (bd 4pa.59, 4pa.77).
. tests/mac/mac_gate_lib.sh
trap mac_remove_run_dirs EXIT


BUILD_TIMEOUT="${ZB_MAC_BUILD_TIMEOUT:-420}"
LEG_TIMEOUT="${ZB_MAC_LEG_TIMEOUT:-600}"

verify_host() { # $1=host $2=key $3=label
  local host="$1" key="$2" label="$3"
  local -a SSH; mapfile -d '' SSH < <(mac_ssh_opts "$key")
  echo "== build + MS2b e2e on $host ($label) ==" >&2
  mac_build "$host" "$key" "$BUILD_TIMEOUT" || { echo "FAIL: build on $host timed out/failed" >&2; return 1; }
  local out rc=0
  out=$(timeout "$LEG_TIMEOUT" "${SSH[@]}" "$host" /bin/bash -s "$MAC_RDIR" <<'REMOTE'
set -euo pipefail
cd "$HOME/${1:?}"
python3 tests/e2e/mac_ms2b_key_table_parity_test.py --root "$PWD"
python3 tests/e2e/mac_ms2b_native_input_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_key_text_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_key_coverage_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_ack_error_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_doc_changed_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_text_doc_changed_test.py --selftest
python3 tests/e2e/mac_ms2b_text_doc_changed_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_partial_type_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_pair_race_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_ack_hang_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_dialogs_test.py --browser zig-out/bin/zigBrowser
python3 tests/e2e/mac_ms2b_eval_dialog_test.py --browser zig-out/bin/zigBrowser
REMOTE
  ) || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" -eq 0 ] || { echo "FAIL: MS2b leg on $host timed out/failed" >&2; return 1; }
  mac_require_lines ms2b_gate "$host" "$label" "$out" \
    $'PASS\tms2b-key-table-parity\t(31 names)' $'PASS\tms2b.1a-native-click' \
    $'PASS\tms2b.1b-key-text' $'PASS\tms2b-key-coverage' $'PASS\tms2b-ack-error' \
    $'PASS\tms2b-doc-changed' $'PASS\tms2b-text-doc-changed-selftest' \
    $'PASS\tms2b-text-doc-changed' $'PASS\tms2b-partial-type' $'PASS\tms2b-pair-race' \
    $'PASS\tms2b-ack-hang' $'PASS\tms2b-dialogs' $'PASS\tms2b-eval-dialog' || return 1
  printf 'PASS\tms2b-leg\t%s\t%s\n' "$host" "$label"
}

overall=0
if ! verify_host "$INTEL_HOST" "$KEY" "x86_64"; then echo "FAIL: intel/x86_64 MS2b leg" >&2; overall=1; fi
if ! verify_host "$ARM_HOST" "$ARM_KEY" "arm64"; then echo "FAIL: arm64 MS2b leg" >&2; overall=1; fi

if [ "$overall" -eq 0 ]; then
  printf 'PASS\tms2b-gate\tboth-arches\n'
else
  echo "MS2b gate: INCOMPLETE or FAILED (see legs above)" >&2
fi
exit "$overall"
