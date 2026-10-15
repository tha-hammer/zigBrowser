"""python -m zb_agent_host <command> ..."""

import importlib
import sys

COMMANDS = {
    "contract-config": "contract",  # P0 contracts: one SDK turn under a token route
    "provision-runtime": "provision",  # wrappers, hook-env allowlist, hook rewrite
    "launch": "launch",  # what the app spawns: builds the sandbox argv, execs bwrap in place
    "chat": "chat",  # the drawer's helper, inside the sandbox
    "setup": "setup",  # --agent-setup: the agent home from a SAI source, and the token route
    "probe-r1": "route_probe",  # setup's R1 probe, inside setup's own sandbox (§3c.7)
}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print(f"usage: python -m zb_agent_host <{'|'.join(COMMANDS)}> ...", file=sys.stderr)
        return 2
    module = importlib.import_module(f".{COMMANDS[argv[0]]}", __package__)
    return module.main(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
