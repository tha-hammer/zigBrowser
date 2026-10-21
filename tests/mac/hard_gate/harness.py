"""The Harness object every MS6 hard-gate case receives (plan rev 18.1; BlueBeaver 7127; JadeBeacon 7125, 7130).

A case is tests/mac/hard_gate/case_<name>.py defining NAME (a non-empty string, unique) and run(h). The driver
(hard_gate_driver.py) runs it under the STAGED pinned runtime on each Mac, with a fresh Harness:

- h.python, h.prefix, h.cli: the staged interpreter, the staged Frameworks/agent-host and the pinned CLI (from the
  gate's environment, ZB_HG_PYTHON / ZB_HG_PREFIX / ZB_HG_CLI; None when not staged);
- h.scratch: this case's own empty directory, removed (and checked gone) by the driver afterwards;
- h.check(ok, label): one assertion; a case passes only with at least one check and no failed one;
- h.spawn_group(argv, env=None, pass_fds=(), timeout=30): runs argv in its own process group, bounded; returns
  (returncode or None on timeout, stdout, stderr); the whole group is SIGKILLed and reaped on every path, and
  h.close() (the driver's) reaps any group a case left;
- h.render_profile(**kw) / h.setup_sandbox(...): the production sandbox_macos from the staged tree."""
import os
import signal
import subprocess


class Harness:
    def __init__(self, scratch):
        self.scratch = scratch
        self.python = os.environ.get("ZB_HG_PYTHON") or None
        self.prefix = os.environ.get("ZB_HG_PREFIX") or None
        self.cli = os.environ.get("ZB_HG_CLI") or None
        self.checks = 0
        self.failures = []
        self._groups = []

    def check(self, ok, label):
        self.checks += 1
        print(("  ok   " if ok else "  FAIL ") + label, flush=True)
        if not ok:
            self.failures.append(label)
        return bool(ok)

    def spawn_group(self, argv, env=None, pass_fds=(), timeout=30):
        proc = subprocess.Popen(argv, env=env, pass_fds=pass_fds, start_new_session=True,
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self._groups.append(proc)
        try:
            out, err = proc.communicate(timeout=timeout)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            code, out, err = None, b"", b""
        finally:
            self._reap(proc)
        return code, out, err

    def _reap(self, proc):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        for stream in (proc.stdout, proc.stderr):
            if stream is not None:
                stream.close()

    def _sandbox_macos(self):
        import importlib
        return importlib.import_module("zb_agent_host.sandbox_macos")

    def render_profile(self, **kw):
        return self._sandbox_macos().render_profile(**kw)

    def setup_sandbox(self, *args, **kw):
        return self._sandbox_macos().setup_sandbox(*args, **kw)

    def close(self):
        for proc in self._groups:
            self._reap(proc)
