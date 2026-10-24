#!/usr/bin/env python3
"""RED, UNREGISTERED: MS1c must attribute every new crash report and browser exit.

This oracle extends the real fake-Mac execution fixture and drives the real
``ms1c_app_gate.sh``.  The fake Python launcher reports every browser/control
PID and terminal status, then creates reports only after the control starts so
the scan must be final rather than row-local.  Report identity comes from the
JSON header's exact ``pid``/``procPath`` pair.  A product report deliberately
mentions the control executable only in its body, killing raw-substring
attribution.

Required evidence records are deliberately canonical and bounded::

    PROCESS <row> <pid> <status> <b64:procPath>
    CRASHREPORT <b64:basename> <sha256-or--> <CONTROL|PRODUCT|OTHER|MALFORMED|UNREADABLE> <pid-or--> <b64:procPath-or-->

Each product report also needs a bounded ``PRODUCT-FAIL crash-report`` record
naming its encoded basename.  A negative non-control terminal status needs a
``PRODUCT-FAIL abnormal-exit`` record naming row, pid and status.  This covers
zero reports, one exact control report, control plus delayed product, product
only, a disagreeing pid/path pair, malformed and unreadable reports, and two
exact control reports.  An unrelated report proves enumeration is not filtered
by filename.  Together those rows kill the delayed-report, raw-substring,
report-filter, abnormal-exit-ignore and extra-report-ignore mutants.

The file is intentionally unregistered until the production behavior exists.
It contacts no Mac.  Its shell driver re-execs itself in the existing fixture's
private user/network/PID namespace before any fake host or browser is run.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SELFTEST = HERE / "ms1c_app_gate_selftest.sh"
problems: list[str] = []


DRIVER_SUFFIX = r'''
# Replace only the fake Python launcher.  The unchanged fixture still executes
# every real gate row and its missing-dylib control.
mv -f "$X/hostbin/python3" "$X/hostbin/python3.fixture" || exit 1
cat > "$X/hostbin/python3" <<EOF
#!/bin/bash
script=\${1:-}
args=("\$@")
role=\${ZB_ROLE:-}
case "\$role" in intel) base=5100 ;; arm) base=6100 ;; *) exec "$X/hostbin/python3.fixture" "\$@" ;; esac

browser=
if [ "\$script" = - ]; then
  browser=\${2:-}
else
  i=1
  while [ \$i -lt \${#args[@]} ]; do
    if [ "\${args[\$i]}" = --browser ]; then j=\$((i + 1)); browser=\${args[\$j]:-}; break; fi
    i=\$((i + 1))
  done
fi

if [ "\$script" = - ]; then
  # Reproduce the fixture's exact control transcript without its old, unattributed
  # crash file.  This keeps the zero-report case from changing the directory.
  cat >/dev/null
  real="$X/hosts/\$role"
  app=\${browser/\/control\//\/app\/}
  env_line="HOME=\$HOME|CF=\${CFFIXED_USER_HOME:-}|TMPDIR=\${TMPDIR:-}|XD=\${XDG_DATA_HOME:-}|XC=\${XDG_CACHE_HOME:-}|XG=\${XDG_CONFIG_HOME:-}|XR=\${XDG_RUNTIME_DIR:-}|S=\${ZB_E2E_SOCKET_DIR:-}|E=\${ZB_DEBUG_EPHEMERAL_DATA_STORE:-}"
  printf '%s\tcontrol\t%s\tabsent\tpresent\t%s\n' "\$role" "\$browser" "\$env_line" >> "$C/py.log"
  echo "dyld[4242]: Library not loaded: @executable_path/../Frameworks/libwkwebview_shim.dylib" >&2
  echo "  Referenced from: <6A1B2C3D-0000-0000-0000-000000000000> \$browser" >&2
  echo "  Reason: tried: '\$(dirname "\$browser")/../Frameworks/libwkwebview_shim.dylib' (no such file)" >&2
  printf 'CONTROL_RC\t-6\n'
  rc=0
else
  out=\$(mktemp "\${TMPDIR:?}/d-detect-out.XXXXXX") || exit 97
  err=\$(mktemp "\${TMPDIR:?}/d-detect-err.XXXXXX") || exit 97
  "$X/hostbin/python3.fixture" "\$@" >"\$out" 2>"\$err"; rc=\$?
  cat "\$out"; cat "\$err" >&2; rm -f "\$out" "\$err"
fi

status() { printf 'BROWSER-STATUS\t%s\t%s\t%s\n' "\$1" "\$2" "\$browser"; }
case "\${script##*/}" in
  m9_render_test.py) status \$((base + 1)) 0; status \$((base + 2)) 0 ;;
  m9_reply_channel_test.py) status \$((base + 3)) 0 ;;
  m9_load_fail_test.py) status \$((base + 4)) 0 ;;
  exec_arch_probe.py)
    terminal=0
    [ -e "$C/mode_detect_abnormal.\$role" ] && terminal=-11
    status \$((base + 5)) "\$terminal"
    ;;
  -)
    status \$((base + 6)) -6
    reports="\$real/Library/Logs/DiagnosticReports"
    control_report() {
      printf '{"pid":%s,"procPath":"%s","bundleID":"com.cosmichq.zigBrowser","exception":"EXC_CRASH (SIGABRT)","termination":"DYLD"}\n' \
        "\$((base + 6))" "\$browser" > "\$reports/\$1"
    }
    product_report() {
      printf '{"pid":%s,"procPath":"%s","bundleID":"com.cosmichq.zigBrowser","exception":"EXC_BREAKPOINT (SIGTRAP)","termination":"SIGNAL 5"}\n' \
        "\$((base + 5))" "\$app" > "\$reports/\$1"
      if [ "\${2:-}" = control-in-body ]; then
        # Raw substring attribution is wrong: this is body text, not header identity.
        printf '{"note":"the control executable was %s"}\n' "\$browser" >> "\$reports/\$1"
      fi
    }
    if [ -e "$C/mode_detect_control.\$role" ]; then
      control_report zigBrowser-control.ips
    elif [ -e "$C/mode_detect_delayed.\$role" ]; then
      control_report zigBrowser-control.ips
      product_report zigBrowser-delayed-product.ips control-in-body
      printf ambient > "\$real/Library/Preferences/d-detection-ambient"
    elif [ -e "$C/mode_detect_product.\$role" ]; then
      product_report zigBrowser-product-only.ips
    elif [ -e "$C/mode_detect_disagree.\$role" ]; then
      printf '{"pid":%s,"procPath":"%s","bundleID":"com.cosmichq.zigBrowser","exception":"EXC_CRASH (SIGABRT)","termination":"DYLD"}\n' \
        "\$((base + 6))" "\$app" > "\$reports/zigBrowser-disagree.ips"
    elif [ -e "$C/mode_detect_malformed.\$role" ]; then
      printf '{not-json\n' > "\$reports/zigBrowser-malformed.ips"
    elif [ -e "$C/mode_detect_unreadable.\$role" ]; then
      printf unreadable > "\$reports/zigBrowser-unreadable.ips"
      chmod 000 "\$reports/zigBrowser-unreadable.ips"
    elif [ -e "$C/mode_detect_extra.\$role" ]; then
      control_report zigBrowser-control-a.ips
      control_report zigBrowser-control-b.ips
    elif [ -e "$C/mode_detect_other.\$role" ]; then
      printf '{"pid":7999,"procPath":"/Applications/Other.app/Contents/MacOS/Other","bundleID":"invalid.example.Other"}\n' \
        > "\$reports/Other-application.ips"
    fi
    ;;
esac
exit "\$rc"
EOF
chmod 0755 "$X/hostbin/python3"

cp -f -- "$ROOT/tests/mac/ms1c_home_protected_paths.txt" "$R/tests/mac/ms1c_home_protected_paths.txt" \
  && "${GIT[@]}" add -- tests/mac/ms1c_home_protected_paths.txt \
  && "${GIT[@]}" -c user.name=selftest -c user.email=selftest@invalid commit -q -m protected-data \
  || { bad "D detection: could not add protected-path data"; exit 1; }
TREE=$("${GIT[@]}" rev-parse 'HEAD^{tree}')
COMMITSHA=$("${GIT[@]}" rev-parse HEAD)

clean_detection_artifacts() {
  local role reports
  for role in intel arm; do
    reports="$X/hosts/$role/Library/Logs/DiagnosticReports"
    chmod 600 "$reports/zigBrowser-unreadable.ips" 2>/dev/null || :
    rm -f "$reports/zigBrowser-control.ips" "$reports/zigBrowser-delayed-product.ips" \
      "$reports/zigBrowser-product-only.ips" "$reports/zigBrowser-disagree.ips" \
      "$reports/zigBrowser-malformed.ips" "$reports/zigBrowser-unreadable.ips" \
      "$reports/zigBrowser-control-a.ips" "$reports/zigBrowser-control-b.ips" \
      "$reports/Other-application.ips" "$X/hosts/$role/Library/Preferences/d-detection-ambient"
  done
}

field() { home_field "$1"; }
sha() { sha256sum "$1" | awk '{ print $1 }'; }
leg_log() { # leg_log <intel|arm>
  if [ "$1" = intel ]; then printf '%s/x86_64/evidence/leg.log' "$EV"; else printf '%s/arm64/evidence/leg.log' "$EV"; fi
}
intel_log() { leg_log intel; }

process_contract() { # process_contract <intel|arm> <normal|abnormal>
  local role=$1 kind=$2 base rd log app ctl expected actual
  if [ "$role" = intel ]; then base=5100; else base=6100; fi
  rd=$(rd_of "$role"); log=$(leg_log "$role")
  app=$(field "$rd/$APPEXE"); ctl=$(field "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
  expected="PROCESS${TB}render${TB}$((base + 1))${TB}0${TB}$app
PROCESS${TB}render${TB}$((base + 2))${TB}0${TB}$app
PROCESS${TB}reply${TB}$((base + 3))${TB}0${TB}$app
PROCESS${TB}loadfail${TB}$((base + 4))${TB}0${TB}$app
PROCESS${TB}arch${TB}$((base + 5))${TB}$([ "$kind" = abnormal ] && printf -- -11 || printf 0)${TB}$app
PROCESS${TB}control${TB}$((base + 6))${TB}-6${TB}$ctl"
  actual=$(grep "^PROCESS${TB}" "$log" 2>/dev/null || :)
  [ "$actual" = "$expected" ]
}
all_processes() { # all_processes <normal|abnormal-intel>
  local intel_kind=normal
  [ "$1" = abnormal-intel ] && intel_kind=abnormal
  process_contract intel "$intel_kind" && process_contract arm normal
}

bounded_reports() { # bounded_reports <log>
  /usr/bin/python3 -I -B - "$1" <<'PY'
from pathlib import Path
import sys
lines = [line for line in Path(sys.argv[1]).read_text(errors="strict").splitlines()
         if line.startswith("CRASHREPORT\t") or line.startswith("PRODUCT-FAIL\t")]
raise SystemExit(0 if all(len(line.encode()) <= 1000 for line in lines) else 1)
PY
}

report_row() { # report_row <name> <sha> <kind> <pid> <path-or-->
  local name=$1 digest=$2 kind=$3 pid=$4 path=$5
  [ "$path" = - ] || path=$(field "$path")
  printf 'CRASHREPORT%s%s%s%s%s%s%s%s%s%s' "$TB" "$(field "$name")" "$TB" "$digest" "$TB" "$kind" "$TB" "$pid" "$TB" "$path"
}

product_named() { # product_named <log> <basename>
  local encoded
  encoded=$(field "$2")
  awk -F'\t' -v n="$encoded" '$1 == "PRODUCT-FAIL" && $2 == "crash-report" && $3 == n { found++ } END { exit(found == 1 ? 0 : 1) }' "$1"
}

run_detection() { # run_detection <label> [modes...]
  clean_detection_artifacts
  run_gate "$@"
}

# D0: zero reports is permitted, but all six launched processes are recorded.
run_detection d-zero
log=$(intel_log)
if [ "$rc" -eq 0 ] && leg_is x86_64 PASS && leg_is arm64 PASS && all_processes normal \
   && ! grep -q "^CRASHREPORT${TB}" "$log" && bounded_reports "$log"; then
  ok "D0: zero reports, six exact process terminal records"
else bad "D0: exit $rc, verdict/process/report contract: $(tailout)"; fi

# D1: one header-exact missing-dylib control report is permitted and recorded.
run_detection d-control detect_control.intel
log=$(intel_log); reports="$X/hosts/intel/Library/Logs/DiagnosticReports"
want=$(report_row zigBrowser-control.ips "$(sha "$reports/zigBrowser-control.ips")" CONTROL 5106 "$(rd_of intel)/control/zigBrowser.app/Contents/MacOS/zigBrowser")
if [ "$rc" -eq 0 ] && leg_is x86_64 PASS && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] && bounded_reports "$log"; then
  ok "D1: one exact pid/procPath missing-dylib control report is allowed"
else bad "D1: exact control attribution missing: exit $rc $(tailout)"; fi

# D2: the product report is delayed until control time and contains the control path only in its body.
# The unrelated Preferences delta keeps the aggregate verdict INCONCLUSIVE, but may not hide the named product.
run_detection d-delayed detect_delayed.intel
log=$(intel_log); rd=$(rd_of intel)
control=$(report_row zigBrowser-control.ips "$(sha "$reports/zigBrowser-control.ips")" CONTROL 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
product=$(report_row zigBrowser-delayed-product.ips "$(sha "$reports/zigBrowser-delayed-product.ips")" PRODUCT 5105 "$rd/$APPEXE")
actual=$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null || :)
if [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass && all_processes normal \
   && [ "$actual" = "$control
$product" ] && product_named "$log" zigBrowser-delayed-product.ips \
   && grep -q "^HOME-DELTA${TB}.*$(field Library/Preferences/d-detection-ambient)" "$log" \
   && bounded_reports "$log"; then
  ok "D2/M-delayed/M-raw: delayed product stays named under unrelated HOME ambiguity"
else bad "D2: delayed/raw-substring product contract: exit $rc $(tailout)"; fi

# D3: a product-only report is a product failure, not generic HOME ambiguity.
run_detection d-product detect_product.intel
log=$(intel_log); rd=$(rd_of intel)
want=$(report_row zigBrowser-product-only.ips "$(sha "$reports/zigBrowser-product-only.ips")" PRODUCT 5105 "$rd/$APPEXE")
if [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && product_named "$log" zigBrowser-product-only.ips && bounded_reports "$log"; then
  ok "D3: product-only report is a named product failure"
else bad "D3: product-only report was not explicit FAIL: exit $rc $(tailout)"; fi

# D4: pid and procPath are an exact pair; a control pid with the product path is not the control.
run_detection d-disagree detect_disagree.intel
log=$(intel_log); rd=$(rd_of intel)
want=$(report_row zigBrowser-disagree.ips "$(sha "$reports/zigBrowser-disagree.ips")" PRODUCT 5106 "$rd/$APPEXE")
if [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && product_named "$log" zigBrowser-disagree.ips && bounded_reports "$log"; then
  ok "D4: disagreeing pid/procPath cannot impersonate the control"
else bad "D4: disagreeing header was not a product failure: exit $rc $(tailout)"; fi

# D5: malformed and unreadable headers are each bounded, named and fail closed.
run_detection d-malformed detect_malformed.intel
log=$(intel_log)
want=$(report_row zigBrowser-malformed.ips "$(sha "$reports/zigBrowser-malformed.ips")" MALFORMED - -)
if [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && ! grep -q Traceback "$log" && bounded_reports "$log"; then
  ok "D5a: malformed header is named, hashed and INCONCLUSIVE"
else bad "D5a: malformed report escaped or disappeared: exit $rc $(tailout)"; fi

run_detection d-unreadable detect_unreadable.intel
log=$(intel_log)
want=$(report_row zigBrowser-unreadable.ips - UNREADABLE - -)
if [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && ! grep -q Traceback "$log" && bounded_reports "$log"; then
  ok "D5b: unreadable header is named and INCONCLUSIVE"
else bad "D5b: unreadable report escaped or disappeared: exit $rc $(tailout)"; fi

# D6/M-report-filter: every new .ips is printed even when it is unrelated.
run_detection d-other detect_other.intel
log=$(intel_log)
want=$(report_row Other-application.ips "$(sha "$reports/Other-application.ips")" OTHER 7999 /Applications/Other.app/Contents/MacOS/Other)
if [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && ! grep -q "^PRODUCT-FAIL${TB}" "$log" && bounded_reports "$log"; then
  ok "D6/M-filter: unrelated .ips is named, hashed and attributed OTHER"
else bad "D6: report filtering or unrelated attribution survived: exit $rc $(tailout)"; fi

# D7/M-extra: only one exact control report is permitted; the second is a named product failure.
run_detection d-extra detect_extra.intel
log=$(intel_log); rd=$(rd_of intel)
first=$(report_row zigBrowser-control-a.ips "$(sha "$reports/zigBrowser-control-a.ips")" CONTROL 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
second=$(report_row zigBrowser-control-b.ips "$(sha "$reports/zigBrowser-control-b.ips")" PRODUCT 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
if [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$first
$second" ] && product_named "$log" zigBrowser-control-b.ips && bounded_reports "$log"; then
  ok "D7/M-extra: the second exact control report is a named product failure"
else bad "D7: extra-control-report ignore survived: exit $rc $(tailout)"; fi

# D8/M-abnormal: row rc 0 cannot hide a negative browser terminal status.
run_detection d-abnormal detect_abnormal.intel
log=$(intel_log)
failure="PRODUCT-FAIL${TB}abnormal-exit${TB}arch${TB}5105${TB}-11"
if [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes abnormal-intel \
   && grep -qxF "$failure" "$log" && grep -qxF "ROW${TB}arch${TB}rc=1" "$log" \
   && bounded_reports "$log"; then
  ok "D8/M-abnormal: negative terminal status fails the owning row"
else bad "D8: abnormal-exit-ignore survived: exit $rc $(tailout)"; fi

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tms1c-crash-attribution-red\tall report, process-status and five mutant rows\n'
else
  printf 'FAIL\tms1c-crash-attribution-red\t%s contract rows failed\n' "$fails"
  exit 1
fi
'''


def bad(label: str, detail: str) -> None:
    problems.append(f"{label}: {detail}")


def main() -> int:
    if not SELFTEST.is_file():
        print(f"FAIL\tms1c-crash-attribution-red\tmissing fixture {SELFTEST}")
        return 1
    scratch = Path(os.environ.get("TMPDIR", ""))
    if not scratch.is_dir():
        print("FAIL\tms1c-crash-attribution-red\tTMPDIR must name private scratch")
        return 1
    source = SELFTEST.read_text(encoding="utf-8")
    marker = "# ── Base run ──\n"
    if source.count(marker) != 1:
        print(f"FAIL\tms1c-crash-attribution-red\twanted one fixture boundary, found {source.count(marker)}")
        return 1
    work = Path(tempfile.mkdtemp(prefix="crash-attribution-red-", dir=scratch))
    try:
        driver = work / "driver.sh"
        driver.write_text(source.split(marker, 1)[0] + DRIVER_SUFFIX, encoding="utf-8")
        driver.chmod(0o700)
        result = subprocess.run(
            ["bash", str(driver), str(ROOT)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=300,
        )
        expected = "PASS\tms1c-crash-attribution-red\tall report, process-status and five mutant rows"
        if result.returncode != 0 or expected not in result.stdout.splitlines() or result.stderr:
            failures = [line for line in result.stdout.splitlines() if line.startswith("FAIL")]
            bad("real gate", f"rc={result.returncode}; failures={failures[-12:]!r}; stderr={result.stderr[-600:]!r}")
        if problems:
            for problem in problems:
                print(f"FAIL\tms1c-crash-attribution-red\t{problem}")
            return 1
        print(expected)
        return 0
    except subprocess.TimeoutExpired:
        print("FAIL\tms1c-crash-attribution-red\treal gate execution fixture timed out")
        return 1
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    raise SystemExit(main())
