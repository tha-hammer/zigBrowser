"""Both-Mac kernel red for R1 under Seatbelt (RoseCat 7019 item 2, 7041 #3; BlueBeaver 7021; JadeBeacon 7023).
This driver plays SETUP, outside any sandbox. It binds the R1 listener and a decoy listener on 127.0.0.1, then runs
an inner script under the REAL setup profile (sandbox_macos.setup_sandbox(..., loopback_port=<the listener's port>)).
The inner script plays the probe: it starts a CLI stand-in (the canary in its environment) and a sibling. Proved
together:
 1. inside, a connect to the R1 port succeeds (the profile permits exactly that port);
 2. inside, a connect to the decoy port is denied;
 3. inside, KERN_PROCARGS2 and proc_pidpath of the sibling and of the CLI stand-in are denied (token isolation);
 4. outside, setup's census proc_darwin.cli_env_clean finds the CLI stand-in and its canary (True), and a token
    planted in a second stand-in's environment makes it False.
Run by tests/mac/ms6_r1_kernel_gate.sh with sandbox_macos.py, proc_darwin.py and r1_kernel_inner.py next to it.
argv: <sleeper binary>"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sandbox_macos  # noqa: E402

try:
    import proc_darwin  # noqa: E402
except ImportError:
    proc_darwin = None

TOKEN = "zb-probe-" + "ab" * 24
failures = []


def check(ok, what):
    print(("  ok   " if ok else "  FAIL ") + what)
    if not ok:
        failures.append(what)


def listen():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    s.listen(8)
    accepted = []

    def loop():
        while True:
            try:
                c, _ = s.accept()
            except OSError:
                return
            accepted.append(1)
            c.close()
    threading.Thread(target=loop, daemon=True).start()
    return s, accepted


def run_inner(sleeper, port, decoy, plant):
    scratch = os.path.realpath(tempfile.mkdtemp(prefix="zb-r1k-"))
    canary = f"ANTHROPIC_BASE_URL=http://127.0.0.1:{port}"
    # The real interpreter, as setup runs it; /usr/bin/python3 is Apple's xcrun shim, which traps (SIGILL) when the
    # deny-default profile blocks its toolchain lookup.
    cmd = [os.path.realpath(sys.executable), "-I", os.path.join(HERE, "r1_kernel_inner.py"), sleeper, str(port), str(decoy),
           canary, TOKEN if plant else "-"]
    env = {"PATH": "/usr/bin:/bin", "HOME": scratch, "LANG": "C", "PYTHONDONTWRITEBYTECODE": "1"}
    with sandbox_macos.setup_sandbox(scratch, [], cmd, loopback_port=port) as argv:
        inner = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 env=env, text=True)
        try:
            line = inner.stdout.readline()
            if line.strip():
                report = json.loads(line)
            else:
                inner.stdin.close()
                code = inner.wait(timeout=10)
                report = {"error": f"exit {code}: {inner.stderr.read()}"}
            census = None
            if proc_darwin is not None and hasattr(proc_darwin, "cli_env_clean"):
                census = proc_darwin.cli_env_clean(os.path.realpath(sleeper), os.getpid(), TOKEN.encode(),
                                                   canary.encode())
            return report, census
        finally:
            if not inner.stdin.closed:
                inner.stdin.close()
            try:
                inner.wait(timeout=10)
            except subprocess.TimeoutExpired:
                inner.kill()
                inner.wait()
            for s in (inner.stdout, inner.stderr):
                s.close()


def main():
    sleeper = os.path.realpath(sys.argv[1])
    r1, r1_accepted = listen()
    decoy, decoy_accepted = listen()
    port, decoy_port = r1.getsockname()[1], decoy.getsockname()[1]
    try:
        report, census = run_inner(sleeper, port, decoy_port, plant=False)
        if "error" in report:
            check(False, f"the inner probe reported: {report['error'][:300]!r}")
            return 1
        check(report["r1_connect"] == "ok", f"inside: the R1 port {port} is reachable ({report['r1_connect']})")
        check(report["decoy_connect"] != "ok", f"inside: the decoy port {decoy_port} is denied ({report['decoy_connect']})")
        for who in ("sibling", "cli"):
            check(report[f"{who}_procargs2"] != "ok", f"inside: KERN_PROCARGS2 of the {who} is denied ({report[f'{who}_procargs2']})")
            check(report[f"{who}_pidpath"] != "ok", f"inside: proc_pidpath of the {who} is denied ({report[f'{who}_pidpath']})")
        if proc_darwin is None or not hasattr(proc_darwin, "cli_env_clean"):
            check(False, "outside: setup's census proc_darwin.cli_env_clean is missing (7021)")
        else:
            check(census is True, f"outside: setup's census finds the CLI stand-in and its canary ({census})")
            _, planted = run_inner(sleeper, port, decoy_port, plant=True)
            check(planted is False, f"outside: a token in the CLI stand-in's environment is not clean ({planted})")
        check(decoy_accepted == [], "the decoy listener never accepted a connection")
    finally:
        r1.close()
        decoy.close()
    if failures:
        print(f"FAIL\tms6-r1-kernel\t{len(failures)} failure(s)")
        return 1
    print("PASS\tms6-r1-kernel\t4 properties")
    return 0


if __name__ == "__main__":
    sys.exit(main())
