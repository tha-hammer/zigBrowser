#!/usr/bin/env bash
# Local (no Mac, no live process) test of tests/mac/lib_group_cleanup.sh (RoseCat 6940): with `pkill` stubbed on
# PATH to log its arguments, the cleanup signals ONLY a valid saved group: never when the file is missing, empty,
# malformed, 0, 1, negative, or our own group.  Run: bash tests/mac/lib_group_cleanup_test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
mkdir "$T/bin"; printf '#!/bin/sh\necho "$@" >> "%s/pkill.log"\n' "$T" > "$T/bin/pkill"; chmod +x "$T/bin/pkill"
export PATH="$T/bin:$PATH"
. "$here/lib_group_cleanup.sh"
fails=0
check() { # $1=name $2=file content or "-" for no file  $3=expected pkill args or "" for none
  rm -f "$T/pkill.log" "$T/pg"; [ "$2" = "-" ] || printf '%s' "$2" > "$T/pg"
  zb_kill_saved_group "$T/pg" >/dev/null
  got=$(cat "$T/pkill.log" 2>/dev/null || true)
  if [ "$got" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: pkill got '$got', want '$3'"; fails=$((fails+1)); fi
}
own=$(ps -o pgid= -p $$ | tr -d ' ')
check "no saved group"       "-"      ""
check "empty"                ""       ""
check "zero"                 "0"      ""
check "one"                  "1"      ""
check "negative"             "-5"     ""
check "malformed"            "12ab"   ""
check "with spaces inside"   "12 34"  ""
check "our own group"        "$own"   ""
check "a valid other group"  "424242" "-KILL -g 424242"
check "trailing newline ok"  "424243
" "-KILL -g 424243"
# zb_setup_child with stubbed pgrep/ps (each case writes the children and their command/pgid tables).
stub_children() { # $1 = "pid|command|pgid" lines
  printf '%s\n' "$1" > "$T/table"
  printf '#!/bin/sh\ncut -d"|" -f1 "%s/table" | grep . \nexit 0\n' "$T" > "$T/bin/pgrep"
  cat > "$T/bin/ps" <<PS
#!/bin/sh
# ps -o command= -p PID | ps -o pgid= -p PID
field=\$2; pid=\$4
line=\$(grep "^\$pid|" "$T/table")
case "\$field" in command=) echo "\$line" | cut -d"|" -f2 ;; pgid=) echo "\$line" | cut -d"|" -f3 ;; esac
PS
  chmod +x "$T/bin/pgrep" "$T/bin/ps"
}
child() { # $1=name $2=table $3=expected stdout ("" = must fail)
  stub_children "$2"
  out=$(zb_setup_child 999 2>/dev/null); rc=$?
  if [ -n "$3" ] && [ "$rc" = 0 ] && [ "$out" = "$3" ]; then echo "ok   $1"
  elif [ -z "$3" ] && [ "$rc" != 0 ] && [ -z "$out" ]; then echo "ok   $1"
  else echo "FAIL $1: rc=$rc out='$out' want '$3'"; fails=$((fails+1)); fi
}
SETUP="/f/python3.12 -m zb_agent_host setup --home /h --browser-pid 999"
child "the one setup child"            "500|$SETUP|500"                  "500"
child "no child"                       ""                                ""
child "a decoy before setup"           "400|/bin/sleep 300|400
500|$SETUP|500"                                                          ""
child "only a decoy"                   "400|/bin/sleep 300|400"          ""
child "setup not its group's leader"   "500|$SETUP|999"                  ""
[ "$fails" -eq 0 ] && echo "PASS lib_group_cleanup (15 cases)" || { echo "FAIL lib_group_cleanup: $fails"; exit 1; }
