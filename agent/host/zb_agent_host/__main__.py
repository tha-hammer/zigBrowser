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
    "login": "login",  # S6: the one-shot sign-in helper (claude setup-token on a pty; the token on fd 4)
}


# WS7.5 (the Windows plan; AzureRidge 6335): the commands that run on Windows. Fail-closed:
# on win32 any other command, a new one included, is refused before its module is imported.
# None yet; setup and provision come first, at WS7's green.
WINDOWS_CAPABLE = frozenset()


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print(f"usage: python -m zb_agent_host <{'|'.join(COMMANDS)}> ...", file=sys.stderr)
        return 2
    if sys.platform == "win32" and argv[0] not in WINDOWS_CAPABLE:
        print(f"zb_agent_host {argv[0]}: not available on Windows yet", file=sys.stderr)
        return 2
    module = importlib.import_module(f".{COMMANDS[argv[0]]}", __package__)
    return module.main(argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
