"""The R1 hard-gate case observes setup's sandboxed run through its NAMED seam, setup.run_in_owned_group (fd1bd92;
RoseCat 7418: keep the hard-gate observation on the named helper, never on subprocess.run once _sandboxed stops using it).

Every RunWithAFakeStagedHost row of ms6_hard_gate_r1_case_test runs again with the fake staged setup changed the way
production changed: its probe_r1 runs the sandboxed command through run_in_owned_group, and setup.subprocess.run fails
the test if anything calls it. A case that still spies subprocess.run sees no sandboxed run at all.
No process is started and no signal is sent (the same fakes, os.kill/os.killpg patched to raise).
Run like the gate: cd tests/e2e && python3 -X dev -m unittest -v ms6_hard_gate_r1_seam_test. Unregistered until the
green.
"""
import os
import unittest

import ms6_hard_gate_r1_case_test as base

OLD = '''        done = subprocess.run(argv, capture_output=True, text=True, timeout=60, env={},'''
NEW = '''        done = run_in_owned_group(argv, timeout=60, env={},'''
SEAM_SETUP = base.FAKE_SETUP.replace(OLD, NEW).replace(
    '''subprocess = types.SimpleNamespace(
    run=lambda argv, *a, **kw: _sp.CompletedProcess(argv, RESULT["rc"], RESULT["out"], RESULT["err"]),''',
    '''def run_in_owned_group(argv, *, env=None, pass_fds=(), timeout):
    return _sp.CompletedProcess(argv, RESULT["rc"], RESULT["out"], RESULT["err"])
def _no_subprocess_run(*a, **kw):
    raise AssertionError("setup's Darwin run went through subprocess.run, not run_in_owned_group")
subprocess = types.SimpleNamespace(
    run=_no_subprocess_run,''')


class RunThroughTheNamedSeam(base.RunWithAFakeStagedHost):
    def setUp(self):
        super().setUp()
        self.assertNotEqual(SEAM_SETUP, base.FAKE_SETUP, "the fake setup was not rewritten to the named seam")
        with open(os.path.join(self.prefix, "zb_agent_host", "setup.py"), "w") as f:
            f.write(SEAM_SETUP)
        self.forget()


if __name__ == "__main__":
    unittest.main()
