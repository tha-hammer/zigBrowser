"""WS7.5's entry points (RoseCat 6324 blocker 3; AzureRidge 6335, the Windows plan's command
contract): on Windows, no zb_agent_host command reaches a fork or an exec.

- The dispatcher (`python -m zb_agent_host <command>`) refuses, on win32, every command not
  marked Windows-capable in its capability table, before it imports the command's module: exit 2
  and exactly `zb_agent_host <command>: not available on Windows yet` on stderr. Fail-closed: a
  command added without a table entry is refused too. Today no command is Windows-capable (setup
  and provision flip first, at WS7's green).
- Belt and braces: each fork/exec seam (launch, netd, relay, hook_run, probe's two forks, the
  token wrapper writer) fails closed on win32 with an error named NotOnWindows (a RuntimeError;
  the standalone stdlib-only scripts define their own) whose text is exactly
  `zb_agent_host <name>: not available on Windows yet`, never an AttributeError from a missing
  os.fork.

All of it runs in a Windows-shaped child of the agent-host Python, as in
test_windows_import_deep.py: the package's outside imports loaded under the real platform, then
sys.platform "win32", the POSIX-only modules blocked, os.fork/forkpty/exec*/spawn*p deleted.
Run the module alone, as the gate does."""

import json
import os
import subprocess
import sys
import unittest

import test_windows_import_deep as deep

CHILD = deep.CHILD.split("# 3. every zb_agent_host module, afresh")[0] + r'''
# 3. the entry points
import contextlib, io, tempfile
report = {"commands": {}, "seams": {}}
m = importlib.import_module("zb_agent_host.__main__")
report["capable"] = sorted(getattr(m, "WINDOWS_CAPABLE", ["<no table>"]))
cases = dict(m.COMMANDS)
cases["zz-added-later"] = "zz_no_such_module"   # a command added without a table entry
for cmd, module in cases.items():
    if cmd == "zz-added-later":
        m.COMMANDS[cmd] = module
    full = f"zb_agent_host.{module}"
    sys.modules.pop(full, None)
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            rc = m.main([cmd, "--help"])
    except BaseException as e:
        rc = f"{type(e).__name__}: {e}"
    report["commands"][cmd] = {"rc": rc, "stderr": err.getvalue(), "imported": full in sys.modules}
    m.COMMANDS.pop("zz-added-later", None)
tmp = tempfile.mkdtemp(prefix="zb-win-seam-")
def seam(name, call):
    try:
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            call()
        report["seams"][name] = "returned"
    except BaseException as e:
        report["seams"][name] = f"{type(e).__name__}|{isinstance(e, RuntimeError)}|{e}"
def mod(name):
    return importlib.import_module(f"zb_agent_host.{name}")
seam("launch.main", lambda: mod("launch").main([]))
seam("netd.main", lambda: mod("netd").main([]))
seam("relay.main", lambda: mod("relay").main([]))
seam("hook_run.main", lambda: mod("hook_run").main([]))
seam("probe._in_child", lambda: mod("probe")._in_child(lambda: None))
seam("probe._sleeper", lambda: mod("probe")._sleeper())
seam("token.write_wrapper", lambda: mod("token").write_wrapper(os.path.join(tmp, "zb-claude"), "/nonexistent/claude"))
print(json.dumps(report))
'''

SEAM_OWNER = {"launch.main": "launch", "netd.main": "netd", "relay.main": "relay", "hook_run.main": "hook_run",
              "probe._in_child": "probe", "probe._sleeper": "probe", "token.write_wrapper": "token"}


def run_child():
    python = os.environ.get("ZB_AGENT_HOST_PYTHON", sys.executable)
    names = [name for _, name in deep.package_modules()]
    done = subprocess.run([python, "-I", "-c", CHILD, str(deep.HOST_DIR), json.dumps(names),
                           json.dumps(sorted(deep.POSIX_ONLY)), json.dumps(deep.GONE_FROM_OS)],
                          capture_output=True, text=True, timeout=120,
                          env={"PATH": "/usr/bin:/bin", "LANG": "C.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"})
    if done.returncode != 0:
        raise AssertionError(done.stderr[-2000:])
    return json.loads(done.stdout.strip().splitlines()[-1])


class WindowsEntryPoints(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = run_child()

    def test_no_command_is_windows_capable_today(self):
        self.assertEqual(self.report["capable"], [])

    def test_every_command_is_refused_before_its_module_is_imported(self):
        wrong = {}
        for cmd, got in self.report["commands"].items():
            want = {"rc": 2, "stderr": f"zb_agent_host {cmd}: not available on Windows yet\n", "imported": False}
            if got != want:
                wrong[cmd] = got
        self.assertEqual(wrong, {})
        self.assertIn("zz-added-later", self.report["commands"])  # fail-closed for a new command

    def test_every_fork_or_exec_seam_fails_closed_by_name(self):
        want = {name: f"NotOnWindows|True|zb_agent_host {owner}: not available on Windows yet"
                for name, owner in SEAM_OWNER.items()}
        self.assertEqual(self.report["seams"], want)


if __name__ == "__main__":
    unittest.main()
