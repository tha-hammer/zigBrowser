"""The launch seam of the Mac runtime red rows (SilverRidge c78a1f6): each row's main gets its browser from its
module-level LAUNCH (this `launch` by default) and reads time through its module-level `time`, so the hostless
selftest (tests/e2e/mac_red_shape_selftest.py) runs the REAL main against a scripted fake browser and a fake clock.
Every value main observes then comes from the injected process, RPC and output source, so an accepted constant
written into main in place of an observation turns the selftest red.

A Session is one launched browser: `proc`, its stdout lines `out`, stderr lines `err`, `connect()` -> the RPC client,
and `stop()` (SIGTERM only, tests/e2e/mac_term_teardown.py).
"""
import subprocess
import threading

from automation_core_test import RpcClient, _read_lines  # noqa: E402
from mac_term_teardown import stop_browser_term_only  # noqa: E402


class Session:
    def __init__(self, proc: subprocess.Popen, socket_path, timeout_sec: float):
        self.proc, self.socket_path, self.timeout_sec = proc, socket_path, timeout_sec
        self.out: list = []
        self.err: list = []
        self.rpc = None
        for stream, buf in ((proc.stdout, self.out), (proc.stderr, self.err)):
            threading.Thread(target=_read_lines, args=(stream, buf), daemon=True).start()

    def connect(self):
        self.rpc = RpcClient(self.socket_path, self.timeout_sec)
        return self.rpc

    def stop(self) -> None:
        if self.rpc is not None:
            self.rpc.close()
            self.rpc = None
        stop_browser_term_only(self.proc)


def launch(argv: list, env: dict, socket_path, timeout_sec: float) -> Session:
    """Start the browser in its own session (process group) with piped output."""
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env,
                            start_new_session=True)
    return Session(proc, socket_path, timeout_sec)
