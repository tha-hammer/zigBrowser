"""The Harness object every MS6 hard-gate case receives (plan rev 18.1; BlueBeaver 7127; JadeBeacon 7125, 7130).

A case is tests/mac/hard_gate/case_<name>.py defining NAME (a non-empty string, unique) and run(h). The driver
(hard_gate_driver.py) runs it under the STAGED pinned runtime on each Mac, with a fresh Harness:

- h.python, h.prefix, h.cli: the staged interpreter, the staged Frameworks/agent-host and the pinned CLI (from the
  gate's environment, ZB_HG_PYTHON / ZB_HG_PREFIX / ZB_HG_CLI; None when not staged);
- h.scratch: this case's own empty directory, removed (and checked gone) by the driver afterwards;
- h.check(ok, label): one assertion; a case passes only with at least one check and no failed one;
- h.spawn_group(argv, env=None, pass_fds=(), timeout=30): runs argv in its own process group, bounded; returns
  (returncode or None on timeout, stdout, stderr). The group is owned EXACTLY once (RoseCat 7134): the leader is
  waited for WITHOUT being reaped (waitid WNOWAIT), so its zombie keeps the pgid from being reused; then the whole
  group is SIGKILLed (a child that outlived the leader too), and only then is the leader reaped. h.close() (the
  driver's) consumes any group not yet consumed and never signals one twice;
- h.render_profile(**kw) / h.setup_sandbox(...): the production sandbox_macos from the staged tree."""
import os
import signal
import subprocess
import threading
import time


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
        entry = {"proc": proc, "consumed": False}
        self._groups.append(entry)
        chunks = {"out": [], "err": []}
        readers = [threading.Thread(target=_drain, args=(proc.stdout, chunks["out"]), daemon=True),
                   threading.Thread(target=_drain, args=(proc.stderr, chunks["err"]), daemon=True)]
        for t in readers:
            t.start()
        exited = False
        try:
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                # Wait for the leader to exit WITHOUT reaping it: its zombie keeps the pgid unique until we signal.
                if os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None:
                    exited = True
                    break
                time.sleep(0.01)
        finally:
            self._consume(entry)
            for t in readers:
                t.join(5)
            for stream in (proc.stdout, proc.stderr):
                stream.close()
        return (proc.returncode if exited else None), b"".join(chunks["out"]), b"".join(chunks["err"])

    def _consume(self, entry):
        """Exactly once per group: SIGKILL the group while its leader is still unreaped, then reap the leader."""
        if entry["consumed"]:
            return
        entry["consumed"] = True
        proc = entry["proc"]
        # Only a real child pid may be signalled. killpg(1) is kill(-1): every process the user owns. A mocked Popen's
        # MagicMock pid indexes as 1, which logged the user out twice on 2026-10-21.
        if type(proc.pid) is not int or proc.pid <= 1:
            raise RuntimeError(f"refusing to signal process group {proc.pid!r}: not a real child pid")
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        proc.wait()

    def _sandbox_macos(self):
        import importlib
        return importlib.import_module("zb_agent_host.sandbox_macos")

    def render_profile(self, **kw):
        return self._sandbox_macos().render_profile(**kw)

    def setup_sandbox(self, *args, **kw):
        return self._sandbox_macos().setup_sandbox(*args, **kw)

    def close(self):
        for entry in self._groups:
            self._consume(entry)


def _drain(stream, into):
    for chunk in iter(lambda: stream.read(65536), b""):
        into.append(chunk)
