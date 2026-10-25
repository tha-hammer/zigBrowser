#!/usr/bin/env python3
"""GREEN, REGISTERED: MS1c attributes every new crash report and browser exit.

This oracle extends the real fake-Mac execution fixture and drives the real
``ms1c_app_gate.sh``.  Its launcher writes process identity and terminal status
only through a gate-owned evidence ledger after the simulated Popen/wait
boundary; stdout contains forged status records which must never be trusted.
Reports appear only after the control starts, so the scan must be final rather
than row-local.

The fixtures are minimal faithful macOS 15 ``.ips`` files: a metadata JSON
record followed by a distinct, pretty-printed/multiline incident JSON object;
the parser contract consumes the complete second value rather than one line.
Their shapes are derived
from retained run ``733135f6`` control report SHA-256
``5c28369e19a58b4f2d4dc40a90f0f98fead2a3a9ecbf0b915ff51436270bf0ec``
and product report SHA-256
``ed0266139ae1ac83416e7d2ee54a7ed817ffeb2dc4008fc8ba4d3575b8c72e13``.
Only the incident object's exact ``pid``/``procPath`` and nested exception and
termination objects are causal.  Product metadata and incident notes contain
control-looking raw strings, killing first-record and whole-file substring
attribution.

Required evidence records are deliberately canonical and bounded::

    PROCESS <row> <pid> <status> <b64:procPath>
    CRASHREPORT <b64:basename> <sha256-or--> <CONTROL|PRODUCT|OTHER|MALFORMED|UNREADABLE|UNVERIFIED> <pid-or--> <b64:procPath-or-->

Each product report also needs a bounded ``PRODUCT-FAIL crash-report`` record
naming its encoded basename.  A negative non-control terminal status needs a
``PRODUCT-FAIL abnormal-exit`` record naming row, pid and status.  This covers
zero reports, one exact control report, control plus delayed product, product
reports from arch and render launches, both one-sided identity mismatches,
wrong control status/termination, malformed/truncated/unreadable incident
evidence, two exact control reports, and missing/duplicate/conflicting process
records.  A valid unrelated report proves enumeration is not filename-filtered
and is AMBIENT under the owner's policy.  Together those rows kill the required
early-scan, raw-substring, report-filter, abnormal/status/diagnostic-ignore,
one-sided-identity, arch-only and extra-report mutants.  A direct fake-Popen
driver also invokes the real production teardown helpers with status unavailable
until wait completes, forged stdout and forged gate-side reconstruction values;
both control and normal browser paths must write exactly once from the helper.

The registered oracle contacts no Mac.  Its shell driver re-execs itself in the existing fixture's
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
  control_rc=-6
  [ -e "$C/mode_detect_control_wrong_status.\$role" ] && control_rc=-9
  env_line="HOME=\$HOME|CF=\${CFFIXED_USER_HOME:-}|TMPDIR=\${TMPDIR:-}|XD=\${XDG_DATA_HOME:-}|XC=\${XDG_CACHE_HOME:-}|XG=\${XDG_CONFIG_HOME:-}|XR=\${XDG_RUNTIME_DIR:-}|S=\${ZB_E2E_SOCKET_DIR:-}|E=\${ZB_DEBUG_EPHEMERAL_DATA_STORE:-}"
  printf '%s\tcontrol\t%s\tabsent\tpresent\t%s\n' "\$role" "\$browser" "\$env_line" >> "$C/py.log"
  if [ -e "$C/mode_detect_wrong_diag.\$role" ]; then
    echo "dyld[4242]: Library not loaded: @rpath/libother.dylib" >&2
    echo "  Referenced from: <6A1B2C3D-0000-0000-0000-000000000000> \$browser" >&2
    echo "  Reason: tried: '@rpath/libother.dylib' (no such file)" >&2
  else
    echo "dyld[4242]: Library not loaded: @executable_path/../Frameworks/libwkwebview_shim.dylib" >&2
    echo "  Referenced from: <6A1B2C3D-0000-0000-0000-000000000000> \$browser" >&2
    echo "  Reason: tried: '\$(dirname "\$browser")/../Frameworks/libwkwebview_shim.dylib' (no such file)" >&2
  fi
  printf 'CONTROL_RC\t%s\n' "\$control_rc"
  rc=0
else
  out=\$(mktemp "\${TMPDIR:?}/d-detect-out.XXXXXX") || exit 97
  err=\$(mktemp "\${TMPDIR:?}/d-detect-err.XXXXXX") || exit 97
  ZB_FIXTURE_NO_PROCESS_RECORD=1 "$X/hostbin/python3.fixture" "\$@" >"\$out" 2>"\$err"; rc=\$?
  cat "\$out"; cat "\$err" >&2; rm -f "\$out" "\$err"
fi

status() { # status <row> <pid> <terminal-status>
  row=\$1 pid=\$2 terminal=\$3 ledger=\${ZB_PROCESS_LEDGER:-}
  # This is browser-controlled stdout poison.  Accepting it instead of the
  # gate-owned boundary ledger must never authorize a report.
  printf 'BROWSER-STATUS\t%s\t77\t/forged/browser/stdout\n' "\$((pid + 90000))"
  printf '%s\t%s\n' "\$row" "\${ledger:--}" >> "$C/boundary.\$role"
  [ -n "\$ledger" ] || return 0
  if [ "\$row" = control ] && [ -e "$C/mode_detect_process_missing.\$role" ]; then return 0; fi
  printf '%s\t%s\t%s\t%s\n' "\$row" "\$pid" "\$terminal" "\$browser" >> "\$ledger"
  if [ "\$row" = control ] && [ -e "$C/mode_detect_process_duplicate.\$role" ]; then
    printf '%s\t%s\t%s\t%s\n' "\$row" "\$pid" "\$terminal" "\$browser" >> "\$ledger"
  fi
  if [ "\$row" = control ] && [ -e "$C/mode_detect_process_conflict.\$role" ]; then
    printf '%s\t%s\t0\t%s\n' "\$row" "\$pid" "\$app" >> "\$ledger"
  fi
}
term_marker() { # term_marker <row> <pid>
  row=\$1 pid=\$2 lifecycle=\${ZB_PROCESS_LIFECYCLE_LEDGER:-}
  [ -n "\$lifecycle" ] || return 0
  printf 'TERM\t%s\t%s\t%s\n' "\$row" "\$pid" "\$pid" >> "\$lifecycle"
}
case "\${script##*/}" in
  m9_render_test.py)
    status render \$((base + 1)) 130; status render \$((base + 2)) 0
    term_marker render \$((base + 1)) ;;
  m9_reply_channel_test.py)
    status reply \$((base + 3)) 130; term_marker reply \$((base + 3)) ;;
  m9_load_fail_test.py) status loadfail \$((base + 4)) 5 ;;
  exec_arch_probe.py)
    terminal=130
    [ -e "$C/mode_detect_abnormal.\$role" ] && terminal=-11
    [ -e "$C/mode_detect_positive.\$role" ] && terminal=7
    status arch \$((base + 5)) "\$terminal"
    term_marker arch \$((base + 5))
    ;;
  -)
    status control \$((base + 6)) "\$control_rc"
    reports="\$real/Library/Logs/DiagnosticReports"
    metadata() { # metadata <file> <app-name> <bundle-id> <incident-id> <raw-decoy>
      printf '{"app_name":"%s","timestamp":"2026-10-24 16:05:15.00 -0400","app_version":"0.2.0","slice_uuid":"6A1B2C3D-0000-0000-0000-000000000000","build_version":"1","platform":1,"bundleID":"%s","share_with_app_devs":0,"is_first_party":0,"bug_type":"309","os_version":"macOS 15.7.1 (24G231)","roots_installed":0,"name":"%s","incident_id":"%s","reportNotes":"%s"}\n' \
        "\$2" "\$3" "\$2" "\$4" "\$5" > "\$1"
    }
    control_incident() { # control_incident <file> <pid> <path>
      printf '{"uptime":42,"procRole":"Foreground","version":2,"userID":501,"deployVersion":210,"modelCode":"Mac15,6","coalitionID":700,"osVersion":{"train":"macOS 15.7.1","build":"24G231","releaseType":"User"},"captureTime":"2026-10-24 16:05:15.1234 -0400","incident":"CONTROL-733135F6","pid":%s,"translated":false,"cpuType":"ARM-64","procLaunch":"2026-10-24 16:05:15.0000 -0400","procName":"zigBrowser","procPath":"%s","bundleInfo":{"CFBundleIdentifier":"com.cosmichq.zigBrowser"},"parentProc":"Python","parentPid":4000,"exception":{"codes":"0x0, 0x0","rawCodes":[0,0],"type":"EXC_CRASH","signal":"SIGABRT"},"termination":{"code":1,"flags":518,"namespace":"DYLD","indicator":"Library missing","details":["Library not loaded: @executable_path/../Frameworks/libwkwebview_shim.dylib"]},"faultingThread":0,"threads":[],"usedImages":[]}\n' \
        "\$2" "\$3" >> "\$1"
    }
    product_incident() { # product_incident <file> <pid> <path>
      printf '{\n  "uptime": 43,\n  "procRole": "Foreground",\n  "version": 2,\n  "userID": 501,\n  "deployVersion": 210,\n  "modelCode": "Mac15,6",\n  "coalitionID": 701,\n  "osVersion": {"train":"macOS 15.7.1","build":"24G231","releaseType":"User"},\n  "captureTime": "2026-10-24 16:05:41.5678 -0400",\n  "incident": "PRODUCT-733135F6",\n  "pid": %s,\n  "translated": false,\n  "cpuType": "ARM-64",\n  "procLaunch": "2026-10-24 16:05:40.0000 -0400",\n  "procName": "zigBrowser",\n  "procPath": "%s",\n  "bundleInfo": {"CFBundleIdentifier":"com.cosmichq.zigBrowser"},\n  "parentProc": "Python",\n  "parentPid": 4000,\n  "exception": {"codes":"0x1, 0x0","rawCodes":[1,0],"type":"EXC_BREAKPOINT","signal":"SIGTRAP"},\n  "termination": {"flags":0,"code":5,"namespace":"SIGNAL","indicator":"Trace/BPT trap: 5","byProc":"exc handler","byPid":4000},\n  "diagnosticNotes": ["raw decoy only: pid=%s procPath=%s DYLD Library missing"],\n  "faultingThread": 0,\n  "threads": [],\n  "usedImages": []\n}\n' \
        "\$2" "\$3" "\$((base + 6))" "\$browser" >> "\$1"
    }
    other_incident() { # other_incident <file>
      printf '{"uptime":44,"procRole":"Foreground","version":2,"userID":501,"deployVersion":210,"modelCode":"Mac15,6","coalitionID":702,"osVersion":{"train":"macOS 15.7.1","build":"24G231","releaseType":"User"},"captureTime":"2026-10-24 16:06:00.0000 -0400","incident":"OTHER-733135F6","pid":7999,"translated":false,"cpuType":"ARM-64","procLaunch":"2026-10-24 16:05:59.0000 -0400","procName":"Other","procPath":"/Applications/Other.app/Contents/MacOS/Other","bundleInfo":{"CFBundleIdentifier":"invalid.example.Other"},"parentProc":"launchd","parentPid":1,"exception":{"codes":"0x0, 0x0","rawCodes":[0,0],"type":"EXC_CRASH","signal":"SIGABRT"},"termination":{"flags":0,"code":6,"namespace":"SIGNAL","indicator":"Abort trap: 6"},"faultingThread":0,"threads":[],"usedImages":[]}\n' >> "\$1"
    }
    control_report() { # control_report <name>
      file="\$reports/\$1"
      metadata "\$file" zigBrowser com.cosmichq.zigBrowser CONTROL-733135F6 "raw decoy only: pid=\$((base + 5)) procPath=\$app"
      control_incident "\$file" \$((base + 6)) "\$browser"
    }
    product_report() { # product_report <name> <pid> <path>
      file="\$reports/\$1"
      metadata "\$file" zigBrowser com.cosmichq.zigBrowser PRODUCT-733135F6 "raw decoy only: pid=\$((base + 6)) procPath=\$browser DYLD Library missing"
      product_incident "\$file" "\$2" "\$3"
    }
    if [ -e "$C/mode_detect_control.\$role" ]; then
      control_report zigBrowser-control.ips
    elif [ -e "$C/mode_detect_delayed.\$role" ]; then
      control_report zigBrowser-control.ips
      product_report zigBrowser-delayed-product.ips \$((base + 5)) "\$app"
      printf ambient > "\$real/Library/Preferences/d-detection-ambient"
    elif [ -e "$C/mode_detect_product.\$role" ]; then
      product_report zigBrowser-product-only.ips \$((base + 5)) "\$app"
    elif [ -e "$C/mode_detect_render_product.\$role" ]; then
      product_report zigBrowser-render-product.ips \$((base + 1)) "\$app"
    elif [ -e "$C/mode_detect_disagree.\$role" ]; then
      file="\$reports/zigBrowser-disagree.ips"
      metadata "\$file" zigBrowser com.cosmichq.zigBrowser DISAGREE-733135F6 "raw decoy only: procPath=\$browser"
      control_incident "\$file" \$((base + 6)) "\$app"
    elif [ -e "$C/mode_detect_reverse_disagree.\$role" ]; then
      file="\$reports/zigBrowser-reverse-disagree.ips"
      metadata "\$file" zigBrowser com.cosmichq.zigBrowser REVERSE-733135F6 "raw decoy only: pid=\$((base + 6)) procPath=\$browser"
      control_incident "\$file" \$((base + 5)) "\$browser"
    elif [ -e "$C/mode_detect_control_wrong_status.\$role" ]; then
      control_report zigBrowser-wrong-status.ips
    elif [ -e "$C/mode_detect_control_wrong_term.\$role" ]; then
      file="\$reports/zigBrowser-wrong-termination.ips"
      metadata "\$file" zigBrowser com.cosmichq.zigBrowser WRONGTERM-733135F6 "raw decoy only: DYLD Library missing"
      printf '{"uptime":42,"procRole":"Foreground","version":2,"userID":501,"deployVersion":210,"modelCode":"Mac15,6","coalitionID":700,"osVersion":{"train":"macOS 15.7.1","build":"24G231","releaseType":"User"},"captureTime":"2026-10-24 16:05:15.1234 -0400","incident":"WRONGTERM-733135F6","pid":%s,"translated":false,"cpuType":"ARM-64","procName":"zigBrowser","procPath":"%s","bundleInfo":{"CFBundleIdentifier":"com.cosmichq.zigBrowser"},"exception":{"codes":"0x0, 0x0","rawCodes":[0,0],"type":"EXC_CRASH","signal":"SIGABRT"},"termination":{"flags":0,"code":9,"namespace":"SIGNAL","indicator":"Killed: 9"},"faultingThread":0,"threads":[],"usedImages":[]}\n' "\$((base + 6))" "\$browser" >> "\$file"
    elif [ -e "$C/mode_detect_wrong_diag.\$role" ]; then
      control_report zigBrowser-wrong-diagnostic.ips
    elif [ -e "$C/mode_detect_malformed.\$role" ]; then
      printf '{not-json\n' > "\$reports/zigBrowser-malformed.ips"
    elif [ -e "$C/mode_detect_truncated_incident.\$role" ]; then
      file="\$reports/zigBrowser-truncated-incident.ips"
      metadata "\$file" zigBrowser com.cosmichq.zigBrowser TRUNCATED-733135F6 "raw decoy only: pid=\$((base + 6)) procPath=\$browser DYLD Library missing"
      printf '{"pid":%s,"procPath":"%s","exception":' "\$((base + 6))" "\$browser" >> "\$file"
    elif [ -e "$C/mode_detect_malformed_incident.\$role" ]; then
      file="\$reports/zigBrowser-malformed-incident.ips"
      metadata "\$file" zigBrowser com.cosmichq.zigBrowser MALFORMED-733135F6 "raw decoy only: pid=\$((base + 6)) procPath=\$browser DYLD Library missing"
      printf '{"pid":"%s","procPath":["%s"],"exception":"EXC_CRASH","termination":{"namespace":"DYLD","indicator":"Library missing"}}\n' "\$((base + 6))" "\$browser" >> "\$file"
    elif [ -e "$C/mode_detect_metadata_only.\$role" ]; then
      file="\$reports/zigBrowser-metadata-only.ips"
      metadata "\$file" zigBrowser com.cosmichq.zigBrowser METAONLY-733135F6 "raw decoy only: pid=\$((base + 6)) procPath=\$browser DYLD Library missing"
    elif [ -e "$C/mode_detect_trailing_value.\$role" ]; then
      file="\$reports/zigBrowser-trailing-value.ips"
      metadata "\$file" zigBrowser com.cosmichq.zigBrowser TRAILING-733135F6 "raw decoy only: pid=\$((base + 6)) procPath=\$browser DYLD Library missing"
      product_incident "\$file" \$((base + 5)) "\$app"
      printf '{"unexpected":"third JSON value"}\n' >> "\$file"
    elif [ -e "$C/mode_detect_whitespace_incident.\$role" ]; then
      file="\$reports/zigBrowser-whitespace-product.ips"
      metadata "\$file" zigBrowser com.cosmichq.zigBrowser WHITESPACE-733135F6 "raw decoy only: pid=\$((base + 6)) procPath=\$browser DYLD Library missing"
      printf '\n \t\n' >> "\$file"
      product_incident "\$file" \$((base + 3)) "\$app"
      printf '\n \t\n' >> "\$file"
    elif [ -e "$C/mode_detect_unreadable.\$role" ]; then
      printf unreadable > "\$reports/zigBrowser-unreadable.ips"
      chmod 000 "\$reports/zigBrowser-unreadable.ips"
    elif [ -e "$C/mode_detect_extra.\$role" ]; then
      control_report zigBrowser-control-a.ips
      control_report zigBrowser-control-b.ips
    elif [ -e "$C/mode_detect_other.\$role" ]; then
      file="\$reports/Other-application.ips"
      metadata "\$file" Other invalid.example.Other OTHER-733135F6 "ordinary unrelated report"
      other_incident "\$file"
    elif [ -e "$C/mode_detect_process_missing.\$role" ] \
      || [ -e "$C/mode_detect_process_duplicate.\$role" ] \
      || [ -e "$C/mode_detect_process_conflict.\$role" ]; then
      control_report zigBrowser-unverified-control.ips
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
      "$reports/zigBrowser-product-only.ips" "$reports/zigBrowser-render-product.ips" \
      "$reports/zigBrowser-disagree.ips" "$reports/zigBrowser-reverse-disagree.ips" \
      "$reports/zigBrowser-wrong-status.ips" "$reports/zigBrowser-wrong-termination.ips" \
      "$reports/zigBrowser-wrong-diagnostic.ips" "$reports/zigBrowser-malformed.ips" \
      "$reports/zigBrowser-truncated-incident.ips" "$reports/zigBrowser-malformed-incident.ips" \
      "$reports/zigBrowser-metadata-only.ips" "$reports/zigBrowser-trailing-value.ips" \
      "$reports/zigBrowser-whitespace-product.ips" \
      "$reports/zigBrowser-unreadable.ips" "$reports/zigBrowser-unverified-control.ips" \
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

process_contract() { # process_contract <intel|arm> <normal|abnormal|positive|control-wrong>
  local role=$1 kind=$2 base rd log app ctl arch_status=130 control_status=-6 expected actual
  if [ "$role" = intel ]; then base=5100; else base=6100; fi
  rd=$(rd_of "$role"); log=$(leg_log "$role")
  app=$(field "$rd/$APPEXE"); ctl=$(field "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
  [ "$kind" = abnormal ] && arch_status=-11
  [ "$kind" = positive ] && arch_status=7
  [ "$kind" = control-wrong ] && control_status=-9
  expected="PROCESS${TB}render${TB}$((base + 1))${TB}130${TB}$app
PROCESS${TB}render${TB}$((base + 2))${TB}0${TB}$app
PROCESS${TB}reply${TB}$((base + 3))${TB}130${TB}$app
PROCESS${TB}loadfail${TB}$((base + 4))${TB}5${TB}$app
PROCESS${TB}arch${TB}$((base + 5))${TB}$arch_status${TB}$app
PROCESS${TB}control${TB}$((base + 6))${TB}$control_status${TB}$ctl"
  actual=$(grep "^PROCESS${TB}" "$log" 2>/dev/null || :)
  [ "$actual" = "$expected" ]
}

raw_processes() { # raw_processes <intel|arm> <normal|abnormal|positive|control-wrong>
  local role=$1 kind=$2 base rd app ctl arch_status=130 control_status=-6
  if [ "$role" = intel ]; then base=5100; else base=6100; fi
  rd=$(rd_of "$role"); app="$rd/$APPEXE"; ctl="$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser"
  [ "$kind" = abnormal ] && arch_status=-11
  [ "$kind" = positive ] && arch_status=7
  [ "$kind" = control-wrong ] && control_status=-9
  printf 'render\t%s\t130\t%s\nrender\t%s\t0\t%s\nreply\t%s\t130\t%s\nloadfail\t%s\t5\t%s\narch\t%s\t%s\t%s\ncontrol\t%s\t%s\t%s\n' \
    "$((base + 1))" "$app" "$((base + 2))" "$app" "$((base + 3))" "$app" \
    "$((base + 4))" "$app" "$((base + 5))" "$arch_status" "$app" \
    "$((base + 6))" "$control_status" "$ctl"
}

boundary_contract() { # boundary_contract <intel|arm> <normal|abnormal|positive|control-wrong> <normal|missing|duplicate|conflict>
  local role=$1 kind=$2 shape=$3 rd path copied calls want actual
  rd=$(rd_of "$role"); path="$rd/evidence/browser-processes"
  copied="$(dirname "$(leg_log "$role")")/browser-processes"
  calls="render${TB}$path
render${TB}$path
reply${TB}$path
loadfail${TB}$path
arch${TB}$path
control${TB}$path"
  [ "$(cat "$C/boundary.$role" 2>/dev/null)" = "$calls" ] || return 1
  want=$(raw_processes "$role" "$kind")
  case "$shape" in
    normal) ;;
    missing) want=$(printf '%s\n' "$want" | sed '$d') ;;
    duplicate) want="$want
$(printf '%s\n' "$want" | tail -n 1)" ;;
    conflict)
      want="$want
control${TB}$([ "$role" = intel ] && printf 5106 || printf 6106)${TB}0${TB}$rd/$APPEXE"
      ;;
    *) return 1 ;;
  esac
  actual=$(cat "$copied" 2>/dev/null || :)
  [ "$actual" = "$want" ]
}

stdout_poison_contract() { # stdout_poison_contract <intel|arm>
  local role=$1 base dir row want actual
  if [ "$role" = intel ]; then base=5100; dir="$EV/x86_64/evidence"; else base=6100; dir="$EV/arm64/evidence"; fi
  for row in render reply loadfail arch control; do
    case "$row" in
      render) want="BROWSER-STATUS${TB}$((base + 1 + 90000))${TB}77${TB}/forged/browser/stdout
BROWSER-STATUS${TB}$((base + 2 + 90000))${TB}77${TB}/forged/browser/stdout" ;;
      reply) want="BROWSER-STATUS${TB}$((base + 3 + 90000))${TB}77${TB}/forged/browser/stdout" ;;
      loadfail) want="BROWSER-STATUS${TB}$((base + 4 + 90000))${TB}77${TB}/forged/browser/stdout" ;;
      arch) want="BROWSER-STATUS${TB}$((base + 5 + 90000))${TB}77${TB}/forged/browser/stdout" ;;
      control) want="BROWSER-STATUS${TB}$((base + 6 + 90000))${TB}77${TB}/forged/browser/stdout" ;;
    esac
    if [ "$row" = control ]; then
      actual=$(grep "^BROWSER-STATUS${TB}" "$dir/control.out" 2>/dev/null || :)
    else
      actual=$(grep "^BROWSER-STATUS${TB}" "$dir/row-$row.out" 2>/dev/null || :)
    fi
    [ "$actual" = "$want" ] || return 1
  done
}

all_processes() { # all_processes <normal|abnormal-intel|positive-intel|control-wrong-intel>
  local intel_kind=normal
  [ "$1" = abnormal-intel ] && intel_kind=abnormal
  [ "$1" = positive-intel ] && intel_kind=positive
  [ "$1" = control-wrong-intel ] && intel_kind=control-wrong
  stdout_poison_contract intel && stdout_poison_contract arm \
    && boundary_contract intel "$intel_kind" normal && boundary_contract arm normal normal \
    && process_contract intel "$intel_kind" && process_contract arm normal
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

faithful_report() { # faithful_report <file> <pid> <procPath> <exception-type> <termination-namespace> <indicator> [pretty]
  /usr/bin/python3 -I -B - "$@" <<'PY'
import json
from pathlib import Path
import sys
path, pid, proc_path, exception_type, namespace, indicator = sys.argv[1:7]
pretty = sys.argv[7:] == ["pretty"]
source = Path(path).read_text(encoding="utf-8")
decoder = json.JSONDecoder()
try:
    meta, meta_end = decoder.raw_decode(source)
    incident_start = meta_end
    while incident_start < len(source) and source[incident_start].isspace():
        incident_start += 1
    incident, incident_end = decoder.raw_decode(source, incident_start)
except (json.JSONDecodeError, TypeError):
    raise SystemExit(1)
if source[incident_end:].strip() or (pretty and "\n" not in source[incident_start:incident_end]):
    raise SystemExit(1)
required_meta = {"app_name", "timestamp", "slice_uuid", "bundleID", "bug_type", "os_version", "name", "incident_id"}
if not required_meta <= set(meta) or "pid" in meta or "procPath" in meta:
    raise SystemExit(1)
if incident.get("pid") != int(pid) or incident.get("procPath") != proc_path:
    raise SystemExit(1)
exception, termination = incident.get("exception"), incident.get("termination")
if not isinstance(exception, dict) or not isinstance(termination, dict):
    raise SystemExit(1)
if exception.get("type") != exception_type or termination.get("namespace") != namespace:
    raise SystemExit(1)
if termination.get("indicator") != indicator:
    raise SystemExit(1)
if namespace == "DYLD" and not any("libwkwebview_shim.dylib" in item for item in termination.get("details", [])):
    raise SystemExit(1)
PY
}

raw_decoys_only() { # raw_decoys_only <file> <causal-pid> <causal-path> <control-pid> <control-path>
  /usr/bin/python3 -I -B - "$@" <<'PY'
import json
from pathlib import Path
import sys
path, causal_pid, causal_path, control_pid, control_path = sys.argv[1:]
source = Path(path).read_text(encoding="utf-8")
decoder = json.JSONDecoder()
meta, meta_end = decoder.raw_decode(source)
incident_start = meta_end
while incident_start < len(source) and source[incident_start].isspace():
    incident_start += 1
incident, incident_end = decoder.raw_decode(source, incident_start)
if source[incident_end:].strip():
    raise SystemExit(1)
meta_raw, incident_raw = source[:meta_end], source[incident_start:incident_end]
if incident.get("pid") != int(causal_pid) or incident.get("procPath") != causal_path:
    raise SystemExit(1)
if meta.get("pid") is not None or meta.get("procPath") is not None:
    raise SystemExit(1)
need = (control_pid, control_path, "DYLD", "Library missing")
if not all(token in meta_raw for token in need) or not all(token in incident_raw for token in need):
    raise SystemExit(1)
PY
}

bad_incident_fixture() { # bad_incident_fixture <file> <metadata|truncated|malformed|trailing>
  /usr/bin/python3 -I -B - "$@" <<'PY'
import json
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text(encoding="utf-8")
decoder = json.JSONDecoder()
try:
    meta, meta_end = decoder.raw_decode(source)
except json.JSONDecodeError:
    raise SystemExit(1)
if "incident_id" not in meta or "pid" in meta or "procPath" in meta:
    raise SystemExit(1)
incident_start = meta_end
while incident_start < len(source) and source[incident_start].isspace():
    incident_start += 1
mode = sys.argv[2]
if mode == "metadata":
    raise SystemExit(0 if incident_start == len(source) else 1)
if mode == "truncated":
    try:
        decoder.raw_decode(source, incident_start)
    except json.JSONDecodeError:
        raise SystemExit(0)
    raise SystemExit(1)
try:
    incident, incident_end = decoder.raw_decode(source, incident_start)
except json.JSONDecodeError:
    raise SystemExit(1)
if mode == "trailing":
    raise SystemExit(0 if source[incident_end:].strip() else 1)
if source[incident_end:].strip():
    raise SystemExit(1)
valid = (isinstance(incident.get("pid"), int) and isinstance(incident.get("procPath"), str)
         and isinstance(incident.get("exception"), dict) and isinstance(incident.get("termination"), dict))
raise SystemExit(1 if valid else 0)
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
fixture_check() { # fixture_check <label> <validator> [args...]
  local label=$1
  shift
  "$@" || bad "SETUP-$label: generated fixture did not meet its independent shape contract"
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
fixture_check D1 faithful_report "$reports/zigBrowser-control.ips" 5106 "$(rd_of intel)/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH DYLD "Library missing"
if faithful_report "$reports/zigBrowser-control.ips" 5106 "$(rd_of intel)/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH DYLD "Library missing" \
   && [ "$rc" -eq 0 ] && leg_is x86_64 PASS && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] && bounded_reports "$log"; then
  ok "D1: one exact pid/procPath missing-dylib control report is allowed"
else bad "D1: exact control attribution missing: exit $rc $(tailout)"; fi

# D1a: an exact incident identity with the wrong recorded terminal status is PRODUCT, never CONTROL.
run_detection d-control-wrong-status detect_control_wrong_status.intel
log=$(intel_log); rd=$(rd_of intel)
want=$(report_row zigBrowser-wrong-status.ips "$(sha "$reports/zigBrowser-wrong-status.ips")" PRODUCT 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
failure="PRODUCT-FAIL${TB}abnormal-exit${TB}control${TB}5106${TB}-9"
if faithful_report "$reports/zigBrowser-wrong-status.ips" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH DYLD "Library missing" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes control-wrong-intel \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && product_named "$log" zigBrowser-wrong-status.ips && grep -qxF "$failure" "$log"; then
  ok "D1a/M-status: wrong control status is a named product failure"
else bad "D1a: wrong status authorized CONTROL or escaped failure: exit $rc $(tailout)"; fi

# D1b: exact identity/status plus a non-DYLD termination is PRODUCT, never CONTROL.
run_detection d-control-wrong-term detect_control_wrong_term.intel
log=$(intel_log); rd=$(rd_of intel)
want=$(report_row zigBrowser-wrong-termination.ips "$(sha "$reports/zigBrowser-wrong-termination.ips")" PRODUCT 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
fixture_check D1b faithful_report "$reports/zigBrowser-wrong-termination.ips" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH SIGNAL "Killed: 9"
if faithful_report "$reports/zigBrowser-wrong-termination.ips" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH SIGNAL "Killed: 9" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && product_named "$log" zigBrowser-wrong-termination.ips; then
  ok "D1b/M-diagnostic: non-DYLD termination is a named product failure"
else bad "D1b: non-DYLD termination authorized CONTROL: exit $rc $(tailout)"; fi

# D1c: even an exact DYLD incident cannot be CONTROL when the observed control diagnostic names another library.
run_detection d-control-wrong-diag detect_wrong_diag.intel
log=$(intel_log); rd=$(rd_of intel)
want=$(report_row zigBrowser-wrong-diagnostic.ips "$(sha "$reports/zigBrowser-wrong-diagnostic.ips")" PRODUCT 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
if faithful_report "$reports/zigBrowser-wrong-diagnostic.ips" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH DYLD "Library missing" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && product_named "$log" zigBrowser-wrong-diagnostic.ips; then
  ok "D1c/M-diagnostic: wrong observed dyld diagnostic cannot authorize CONTROL"
else bad "D1c: wrong observed diagnostic authorized CONTROL or lost attribution: exit $rc $(tailout)"; fi

# D2: the product report is delayed until control time and contains the control path only in its body.  The unrelated
# Preferences delta remains recorded as ambient evidence, while the product report makes the leg FAIL.
run_detection d-delayed detect_delayed.intel
log=$(intel_log); rd=$(rd_of intel)
control=$(report_row zigBrowser-control.ips "$(sha "$reports/zigBrowser-control.ips")" CONTROL 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
product=$(report_row zigBrowser-delayed-product.ips "$(sha "$reports/zigBrowser-delayed-product.ips")" PRODUCT 5105 "$rd/$APPEXE")
actual=$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null || :)
fixture_check D2-shape faithful_report "$reports/zigBrowser-delayed-product.ips" 5105 "$rd/$APPEXE" EXC_BREAKPOINT SIGNAL "Trace/BPT trap: 5" pretty
fixture_check D2-decoys raw_decoys_only "$reports/zigBrowser-delayed-product.ips" 5105 "$rd/$APPEXE" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser"
if faithful_report "$reports/zigBrowser-control.ips" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH DYLD "Library missing" \
   && faithful_report "$reports/zigBrowser-delayed-product.ips" 5105 "$rd/$APPEXE" EXC_BREAKPOINT SIGNAL "Trace/BPT trap: 5" pretty \
   && raw_decoys_only "$reports/zigBrowser-delayed-product.ips" 5105 "$rd/$APPEXE" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$actual" = "$control
$product" ] && product_named "$log" zigBrowser-delayed-product.ips \
   && grep -q "^HOME-DELTA${TB}.*$(field "$X/hosts/intel/Library/Preferences/d-detection-ambient")" "$log" \
   && grep -qxF "HOMEAUDIT${TB}FAIL${TB}1" "$log" \
   && bounded_reports "$log"; then
  ok "D2/M-delayed/M-raw: delayed product stays named and FAIL while unrelated HOME churn stays recorded"
else bad "D2: delayed/raw-substring product contract: exit $rc $(tailout)"; fi

# D3: a product-only report is a product failure, not generic HOME ambiguity.
run_detection d-product detect_product.intel
log=$(intel_log); rd=$(rd_of intel)
want=$(report_row zigBrowser-product-only.ips "$(sha "$reports/zigBrowser-product-only.ips")" PRODUCT 5105 "$rd/$APPEXE")
if faithful_report "$reports/zigBrowser-product-only.ips" 5105 "$rd/$APPEXE" EXC_BREAKPOINT SIGNAL "Trace/BPT trap: 5" \
   && raw_decoys_only "$reports/zigBrowser-product-only.ips" 5105 "$rd/$APPEXE" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && product_named "$log" zigBrowser-product-only.ips && bounded_reports "$log"; then
  ok "D3: product-only report is a named product failure"
else bad "D3: product-only report was not explicit FAIL: exit $rc $(tailout)"; fi

# D3a/M-arch-only: attribution joins the whole process table, including the first render launch.
run_detection d-render-product detect_render_product.intel
log=$(intel_log); rd=$(rd_of intel)
want=$(report_row zigBrowser-render-product.ips "$(sha "$reports/zigBrowser-render-product.ips")" PRODUCT 5101 "$rd/$APPEXE")
if faithful_report "$reports/zigBrowser-render-product.ips" 5101 "$rd/$APPEXE" EXC_BREAKPOINT SIGNAL "Trace/BPT trap: 5" \
   && raw_decoys_only "$reports/zigBrowser-render-product.ips" 5101 "$rd/$APPEXE" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && product_named "$log" zigBrowser-render-product.ips && bounded_reports "$log"; then
  ok "D3a/M-arch-only: render-process report is a named product failure"
else bad "D3a: render process was absent from attribution: exit $rc $(tailout)"; fi

# D4: pid and procPath are an exact pair; a control pid with the product path is not the control.
run_detection d-disagree detect_disagree.intel
log=$(intel_log); rd=$(rd_of intel)
want=$(report_row zigBrowser-disagree.ips "$(sha "$reports/zigBrowser-disagree.ips")" PRODUCT 5106 "$rd/$APPEXE")
fixture_check D4 faithful_report "$reports/zigBrowser-disagree.ips" 5106 "$rd/$APPEXE" EXC_CRASH DYLD "Library missing"
if faithful_report "$reports/zigBrowser-disagree.ips" 5106 "$rd/$APPEXE" EXC_CRASH DYLD "Library missing" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && product_named "$log" zigBrowser-disagree.ips && bounded_reports "$log"; then
  ok "D4: disagreeing pid/procPath cannot impersonate the control"
else bad "D4: disagreeing header was not a product failure: exit $rc $(tailout)"; fi

# D4a/M-one-sided: the product pid paired with the control path also cannot impersonate CONTROL.
run_detection d-reverse-disagree detect_reverse_disagree.intel
log=$(intel_log); rd=$(rd_of intel)
want=$(report_row zigBrowser-reverse-disagree.ips "$(sha "$reports/zigBrowser-reverse-disagree.ips")" PRODUCT 5105 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
fixture_check D4a faithful_report "$reports/zigBrowser-reverse-disagree.ips" 5105 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH DYLD "Library missing"
if faithful_report "$reports/zigBrowser-reverse-disagree.ips" 5105 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH DYLD "Library missing" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && product_named "$log" zigBrowser-reverse-disagree.ips && bounded_reports "$log"; then
  ok "D4a/M-one-sided: product pid plus control path is a named product failure"
else bad "D4a: one-sided reverse identity authorized CONTROL: exit $rc $(tailout)"; fi

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

run_detection d-truncated-incident detect_truncated_incident.intel
log=$(intel_log)
want=$(report_row zigBrowser-truncated-incident.ips "$(sha "$reports/zigBrowser-truncated-incident.ips")" MALFORMED - -)
fixture_check D5c bad_incident_fixture "$reports/zigBrowser-truncated-incident.ips" truncated
if bad_incident_fixture "$reports/zigBrowser-truncated-incident.ips" truncated \
   && [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && ! grep -q Traceback "$log" && bounded_reports "$log"; then
  ok "D5c/M-raw: valid metadata plus truncated incident is hashed MALFORMED/INCONCLUSIVE"
else bad "D5c: truncated incident supplied identity or escaped: exit $rc $(tailout)"; fi

run_detection d-malformed-incident detect_malformed_incident.intel
log=$(intel_log)
want=$(report_row zigBrowser-malformed-incident.ips "$(sha "$reports/zigBrowser-malformed-incident.ips")" MALFORMED - -)
fixture_check D5d bad_incident_fixture "$reports/zigBrowser-malformed-incident.ips" malformed
if bad_incident_fixture "$reports/zigBrowser-malformed-incident.ips" malformed \
   && [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && ! grep -q Traceback "$log" && bounded_reports "$log"; then
  ok "D5d/M-first-record: valid metadata plus malformed incident is hashed MALFORMED/INCONCLUSIVE"
else bad "D5d: malformed incident supplied identity or escaped: exit $rc $(tailout)"; fi

run_detection d-metadata-only detect_metadata_only.intel
log=$(intel_log)
want=$(report_row zigBrowser-metadata-only.ips "$(sha "$reports/zigBrowser-metadata-only.ips")" MALFORMED - -)
fixture_check D5e bad_incident_fixture "$reports/zigBrowser-metadata-only.ips" metadata
if bad_incident_fixture "$reports/zigBrowser-metadata-only.ips" metadata \
   && [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && ! grep -q Traceback "$log" && bounded_reports "$log"; then
  ok "D5e: metadata without a second JSON value is MALFORMED/INCONCLUSIVE"
else bad "D5e: metadata-only report supplied raw identity or escaped: exit $rc $(tailout)"; fi

run_detection d-trailing-value detect_trailing_value.intel
log=$(intel_log)
want=$(report_row zigBrowser-trailing-value.ips "$(sha "$reports/zigBrowser-trailing-value.ips")" MALFORMED - -)
fixture_check D5f bad_incident_fixture "$reports/zigBrowser-trailing-value.ips" trailing
if bad_incident_fixture "$reports/zigBrowser-trailing-value.ips" trailing \
   && [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && ! grep -q Traceback "$log" && bounded_reports "$log"; then
  ok "D5f: a third non-whitespace JSON value is MALFORMED/INCONCLUSIVE"
else bad "D5f: trailing JSON value was ignored or supplied identity: exit $rc $(tailout)"; fi

run_detection d-whitespace-incident detect_whitespace_incident.intel
log=$(intel_log); rd=$(rd_of intel)
want=$(report_row zigBrowser-whitespace-product.ips "$(sha "$reports/zigBrowser-whitespace-product.ips")" PRODUCT 5103 "$rd/$APPEXE")
fixture_check D5g faithful_report "$reports/zigBrowser-whitespace-product.ips" 5103 "$rd/$APPEXE" EXC_BREAKPOINT SIGNAL "Trace/BPT trap: 5" pretty
if faithful_report "$reports/zigBrowser-whitespace-product.ips" 5103 "$rd/$APPEXE" EXC_BREAKPOINT SIGNAL "Trace/BPT trap: 5" pretty \
   && raw_decoys_only "$reports/zigBrowser-whitespace-product.ips" 5103 "$rd/$APPEXE" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && product_named "$log" zigBrowser-whitespace-product.ips && bounded_reports "$log"; then
  ok "D5g: harmless whitespace and a multiline incident remain a valid PRODUCT"
else bad "D5g: complete multiline remainder was not parsed as one product incident: exit $rc $(tailout)"; fi

# D6/M-report-filter: every new .ips is printed even when D classifies it OTHER; C makes every non-control report fail.
run_detection d-other detect_other.intel
log=$(intel_log)
want=$(report_row Other-application.ips "$(sha "$reports/Other-application.ips")" OTHER 7999 /Applications/Other.app/Contents/MacOS/Other)
fixture_check D6 faithful_report "$reports/Other-application.ips" 7999 /Applications/Other.app/Contents/MacOS/Other EXC_CRASH SIGNAL "Abort trap: 6"
if faithful_report "$reports/Other-application.ips" 7999 /Applications/Other.app/Contents/MacOS/Other EXC_CRASH SIGNAL "Abort trap: 6" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && leg_is arm64 PASS && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
   && ! grep -q "^PRODUCT-FAIL${TB}" "$log" \
   && grep -q "^HOME-ATTRIBUTABLE${TB}ADDED${TB}.*${TB}crash-report$" "$log" \
   && grep -qxF "HOMEAUDIT${TB}FAIL${TB}1" "$log" && bounded_reports "$log"; then
  ok "D6/M-filter: complete unrelated .ips is recorded OTHER and C makes it an attributable FAIL"
else bad "D6: report filtering or unrelated attribution survived: exit $rc $(tailout)"; fi

# D7/M-extra: only one exact control report is permitted; the second is a named product failure.
run_detection d-extra detect_extra.intel
log=$(intel_log); rd=$(rd_of intel)
first=$(report_row zigBrowser-control-a.ips "$(sha "$reports/zigBrowser-control-a.ips")" CONTROL 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
second=$(report_row zigBrowser-control-b.ips "$(sha "$reports/zigBrowser-control-b.ips")" PRODUCT 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
if faithful_report "$reports/zigBrowser-control-a.ips" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH DYLD "Library missing" \
   && faithful_report "$reports/zigBrowser-control-b.ips" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH DYLD "Library missing" \
   && [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes normal \
   && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$first
$second" ] \
   && product_named "$log" zigBrowser-control-b.ips && bounded_reports "$log"; then
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

run_detection d-positive-status detect_positive.intel
log=$(intel_log)
failure="PRODUCT-FAIL${TB}abnormal-exit${TB}arch${TB}5105${TB}7"
if [ "$rc" -eq 1 ] && leg_is x86_64 FAIL && no_pass && all_processes positive-intel \
   && grep -qxF "$failure" "$log" && grep -qxF "ROW${TB}arch${TB}rc=1" "$log" \
   && ! grep -q "^CRASHREPORT${TB}" "$log" && bounded_reports "$log"; then
  ok "D8a/M-positive: positive nonzero terminal status fails the owning row"
else bad "D8a: status<0-only implementation ignored positive nonzero exit: exit $rc $(tailout)"; fi

# D9: incomplete or contradictory boundary evidence cannot authorize the otherwise exact control report.
for shape in missing duplicate conflict; do
  run_detection "d-process-$shape" "detect_process_$shape.intel"
  log=$(intel_log); rd=$(rd_of intel)
  want=$(report_row zigBrowser-unverified-control.ips "$(sha "$reports/zigBrowser-unverified-control.ips")" UNVERIFIED 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser")
  reason="${shape} process record"
  if faithful_report "$reports/zigBrowser-unverified-control.ips" 5106 "$rd/control/zigBrowser.app/Contents/MacOS/zigBrowser" EXC_CRASH DYLD "Library missing" \
     && stdout_poison_contract intel && stdout_poison_contract arm \
     && boundary_contract intel normal "$shape" && process_contract arm normal && boundary_contract arm normal normal \
     && [ "$rc" -eq 2 ] && leg_is x86_64 INCONCLUSIVE && leg_is arm64 PASS && no_pass \
     && [ "$(grep "^CRASHREPORT${TB}" "$log" 2>/dev/null)" = "$want" ] \
     && grep -qxF "PROCESSAUDIT${TB}INCONCLUSIVE${TB}$reason" "$log" \
     && ! grep "^CRASHREPORT${TB}" "$log" | grep -q "${TB}CONTROL${TB}" \
     && ! grep -q "^PRODUCT-FAIL${TB}" "$log" && bounded_reports "$log"; then
    ok "D9-$shape: $shape Popen/wait record is INCONCLUSIVE and cannot authorize CONTROL"
  else bad "D9-$shape: invalid process evidence did not fail closed: exit $rc $(tailout)"; fi
done

# D10: bind provenance to the real Popen/wait helpers, not to workload/browser stdout or a gate-side reconstruction.
if /usr/bin/python3 -I -B - "$ROOT" "$T/direct-boundary-ledger" <<'PY'
import importlib.util
import os
from pathlib import Path
import sys

root, ledger = Path(sys.argv[1]), Path(sys.argv[2])
helper_path = root / "tests" / "e2e" / "mac_term_teardown.py"
spec = importlib.util.spec_from_file_location("d_boundary_teardown", helper_path)
helper = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(helper)

events = []

class FakeProc:
    def __init__(self, pid, terminal, argv, poison=""):
        self.pid, self.terminal, self.args = pid, terminal, argv
        self._returncode = None
        self.poison = poison
        self.stdout = self.stderr = None
    @property
    def returncode(self):
        events.append(f"returncode:{self._returncode}")
        return self._returncode
    @returncode.setter
    def returncode(self, value):
        self._returncode = value
    def communicate(self, timeout=None):
        events.append("communicate:begin")
        if self._returncode is not None:
            raise AssertionError("terminal status was reconstructed before wait")
        self._returncode = self.terminal
        events.append("communicate:end")
        return self.poison, ""
    def poll(self):
        events.append(f"poll:{self._returncode}")
        return self._returncode

def want(row, pid, status, path):
    lines = ledger.read_text(encoding="utf-8").splitlines() if ledger.is_file() else []
    if lines != [f"{row}\t{pid}\t{status}\t{path}"]:
        raise SystemExit(1)

os.environ["ZB_PROCESS_LEDGER"] = str(ledger)
os.environ["ZB_GATE_RECONSTRUCTED_PID"] = "9991"
os.environ["ZB_GATE_RECONSTRUCTED_STATUS"] = "99"
os.environ["ZB_GATE_RECONSTRUCTED_EXE"] = "/forged/gate/reconstruction"

# Control: Popen is real production helper code; status becomes visible only when communicate() completes.
ledger.write_text("", encoding="ascii")
os.environ["ZB_PROCESS_ROW"] = "control"
control_path = "/private/run/control/zigBrowser.app/Contents/MacOS/zigBrowser"
poison = "PROCESS\tcontrol\t9992\t0\t/forged/browser/stdout\n"
control = FakeProc(7001, -6, [control_path, "--version"], poison)
def one_popen(*_args, **_kwargs):
    events.append("popen:control")
    return control
helper.subprocess.Popen = one_popen
result = helper.run_term_only(control.args, 1.0)
if result.returncode != -6:
    raise SystemExit(1)
want("control", 7001, -6, control_path)
if events[:3] != ["popen:control", "communicate:begin", "communicate:end"] or "returncode:None" in events:
    raise SystemExit(1)

# Normal browser: the same real Popen/wait helper must ignore stdout and record its post-wait zero status.
events.clear()
ledger.write_text("", encoding="ascii")
os.environ["ZB_PROCESS_ROW"] = "render"
app_path = "/private/run/app/zigBrowser.app/Contents/MacOS/zigBrowser"
normal = FakeProc(7002, 0, [app_path, "--screenshot", "/private/run/cap.png"],
                  "PROCESS\trender\t9993\t-11\t/forged/browser/stdout\n")
def normal_popen(*_args, **_kwargs):
    events.append("popen:normal")
    return normal
helper.subprocess.Popen = normal_popen
result = helper.run_term_only(normal.args, 1.0)
if result.returncode != 0:
    raise SystemExit(1)
want("render", 7002, 0, app_path)
if events[:3] != ["popen:normal", "communicate:begin", "communicate:end"] or "returncode:None" in events:
    raise SystemExit(1)

# GUI teardown: stop_browser_term_only is the other real wait boundary. No real signal is sent.
events.clear()
ledger.write_text("", encoding="ascii")
os.environ["ZB_PROCESS_ROW"] = "arch"
app = FakeProc(7003, 0, [app_path, "about:blank", "--automation-api"])
helper.os.getpgid = lambda pid: pid
def fake_killpg(pid, sig):
    events.append(f"killpg:{pid}:{int(sig)}")
    app._returncode = app.terminal
helper.os.killpg = fake_killpg
helper._group_has_members = lambda _pgid: False
helper.stop_browser_term_only(app, grace_s=0.1)
want("arch", 7003, 0, app_path)
if "returncode:None" in events or not any(event.startswith("killpg:7003:") for event in events):
    raise SystemExit(1)
PY
then
  ok "D10/M-boundary: control, normal and teardown Popen/wait helpers ignore stdout/gate reconstruction and write post-wait records"
else
  bad "D10: helper-write/stdout/pre-wait/gate-reconstruction provenance contract failed"
fi

if [ "$fails" -eq 0 ]; then
  printf 'PASS\tms1c-crash-attribution-red\tmacOS-15 reports, boundary ledger and attribution mutants\n'
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
        expected = "PASS\tms1c-crash-attribution-red\tmacOS-15 reports, boundary ledger and attribution mutants"
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
