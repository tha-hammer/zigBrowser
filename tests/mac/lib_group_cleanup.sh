# Shared by tests/mac/ms5_setup_e2e.sh (and its local test): kill a SAVED setup process group, and nothing else.
# zb_kill_saved_group <pgid-file>: signals the group only when the file exists and holds a plain decimal pgid > 1
# that is not the caller's own process group; otherwise it signals nothing (never group 0, empty, malformed, or
# our own group, RoseCat 6940). Prints what it did, for the test.
zb_kill_saved_group() {
  local file="$1" pg own
  if [ ! -f "$file" ]; then echo "cleanup: no saved group"; return 0; fi
  IFS= read -r pg < "$file" || true
  pg="${pg#"${pg%%[![:space:]]*}"}"   # trim leading whitespace only
  pg="${pg%"${pg##*[![:space:]]}"}"   # trim trailing whitespace only; an inner space stays and is refused below
  case "$pg" in ''|*[!0-9]*) echo "cleanup: refused malformed group '$pg'"; return 0 ;; esac
  if [ "$pg" -le 1 ]; then echo "cleanup: refused group $pg"; return 0; fi
  own=$(ps -o pgid= -p $$ | tr -d ' ')
  if [ "$pg" = "$own" ]; then echo "cleanup: refused our own group $pg"; return 0; fi
  pkill -KILL -g "$pg" 2>/dev/null || true
  echo "cleanup: killed group $pg"
}

# zb_setup_child <browser-pid>: prints the ONE direct child of the browser that is the setup helper, and requires it
# to lead its own process group (PGID == PID). Fails (non-zero, a reason on stderr) on no child, more than one child,
# a child whose command is not `... -m zb_agent_host setup ...`, or a child that is not its group's leader
# (RoseCat 6940: never census whichever child sorts first).
zb_setup_child() {
  local browser="$1" kids n s cmd pg
  kids=$(pgrep -P "$browser" || true)
  n=$(printf '%s\n' "$kids" | grep -c '[0-9]' || true)
  if [ "$n" != 1 ]; then echo "expected exactly one child of the browser, found $n: $(echo $kids)" >&2; return 1; fi
  s=$kids
  case "$s" in *[!0-9]*|'') echo "malformed child pid '$s'" >&2; return 1 ;; esac
  cmd=$(ps -o command= -p "$s")
  case "$cmd" in *" -m zb_agent_host setup "*|*" -m zb_agent_host setup") ;; *) echo "the browser's child is not setup: $cmd" >&2; return 1 ;; esac
  pg=$(ps -o pgid= -p "$s" | tr -d ' ')
  if [ "$pg" != "$s" ]; then echo "setup ($s) does not lead its own group ($pg)" >&2; return 1; fi
  echo "$s"
}
