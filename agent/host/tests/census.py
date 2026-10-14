"""Reading and classifying the exec tracer's log (exec_tracer.py) for the P0.5 census."""

import json
import os
import time

# The reviewed exception for the CLI's own binary (finding 7, RoseCat 5285): run as
# argv[0] "rg" (its built-in ripgrep) only to list files, with these flags, and
# with path operands only under these agent-home paths. Anything else is UNEXPECTED.
CLI_RG_FLAGS = {"--version", "--no-config", "--files", "--hidden", "--no-ignore"}
CLI_RG_VALUED = {"--max-depth": str.isdigit, "--glob": lambda v: v == ".orphaned_at"}
CLI_RG_ROOTS = ("workspace", ".claude/plugins/cache")


def cli_self_exec(argv, agent_home):
    """Census entry for an exec of the CLI's own binary: "$CLI rg", or "$CLI UNEXPECTED ..."."""
    if not argv or argv[0] != "rg":  # the literal argv[0], never a path ending in rg
        return f"$CLI UNEXPECTED {argv[:4]}"
    roots = [os.path.join(str(agent_home), r) for r in CLI_RG_ROOTS]
    args = iter(argv[1:])
    for arg in args:
        if arg in CLI_RG_FLAGS:
            continue
        if arg in CLI_RG_VALUED:
            if not CLI_RG_VALUED[arg](next(args, "")):
                return f"$CLI UNEXPECTED rg {arg}"
            continue
        path = os.path.realpath(arg)
        if arg.startswith("-") or not any(path == r or path.startswith(r + os.sep) for r in roots):
            return f"$CLI UNEXPECTED rg {arg}"
    return "$CLI rg"


def load(path, wait_s=10.0):
    """The records of a finished trace. The supervisor writes END once every traced
    process is gone; a log without it (a dead or stuck supervisor) is red after wait_s."""
    deadline = time.monotonic() + wait_s
    while True:
        with open(path) as f:
            lines = f.read().splitlines()
        if lines and lines[-1].startswith("END "):
            break
        if time.monotonic() >= deadline:
            raise AssertionError(f"the exec log has no END line after {wait_s} s: {path}")
        time.sleep(0.1)
    records = [json.loads(line) for line in lines if line.startswith("{")]
    if int(lines[-1].split()[1]) != len(records):
        raise AssertionError(f"the exec log's END count does not match its {len(records)} records")
    return records


def non_hook_cli_children(records, cli, agent_home):
    """Programs run by the CLI and its descendants outside every hook. The CLI process is
    the first exec of the CLI binary `cli`; a hook is the zb-hook-run exec and everything
    below it (a namespace's PID 1, bwrap's reaper, forks without exec, so the whole
    ancestor chain counts)."""
    cli_pid = next(r["pid"] for r in records if r["real"] == cli)
    hook_pids, found = set(), set()
    for r in records:
        chain = {r["pid"], *r["ancestors"]}
        if hook_pids & chain or (r["real"] or "").endswith("/runtime/bin/zb-hook-run"):
            hook_pids.add(r["pid"])
            continue
        if cli_pid not in r["ancestors"]:
            continue  # not below the CLI: bwrap, the helper, zb-claude -> CLI
        if not (r["complete"] and r["resolved"]):
            # A record the oracle could not read in full, or an execveat other than the plain
            # form, can certify nothing: it is never on the allowlist.
            found.add(f"UNEXPECTED {r['form']} {r['path']!r} complete={r['complete']}")
            continue
        if not r["exists"]:
            continue  # a PATH miss: an exec of a missing path ran nothing
        if r["real"] == cli:
            found.add(cli_self_exec(r["argv"], agent_home))  # its built-in rg, exact shape
        else:
            found.add(r["real"])
    return found
