"""The hook event probe (chat-drawer plan S7.6). A provisioned hook runs it as

    python3 -I -S hook_event_probe.py <nonce>

and, for each run, it writes $HOME/scratchpad/hook-event-<nonce>-<random>.json with the
event and tool the CLI named on its stdin (`hook_event_name`, `tool_name`) and the names
in its own environment (names only, never values). One file per run, so a test can count
how many times a hook fired. Standard library only: the hook's view has /usr, not the
helper's venv."""

import json
import os
import sys


def main(nonce):
    try:
        given = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        given = {}
    record = {
        "nonce": nonce,
        "event": given.get("hook_event_name"),
        "tool": given.get("tool_name"),
        "env_names": sorted(os.environ),
    }
    scratch = os.path.join(os.environ["HOME"], "scratchpad")
    os.makedirs(scratch, exist_ok=True)
    path = os.path.join(scratch, f"hook-event-{nonce}-{os.urandom(6).hex()}.json")
    with open(path, "w") as f:
        json.dump(record, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
