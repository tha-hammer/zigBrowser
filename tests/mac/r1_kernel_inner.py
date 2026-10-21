"""The inside half of tests/mac/r1_kernel_driver.py (under the real setup profile, or unsandboxed as the control).
It plays the probe's position: starts the CLI stand-in (the canary, and with argv[5] != "-" that token, in its
environment) and a sibling, tries the R1 port, the decoy port, and KERN_PROCARGS2 / proc_pidpath of both while
they are alive, prints one JSON line, then holds its children until its stdin closes or it is killed.
argv: <sleeper> <r1 port> <decoy port> <canary entry> <token or -> <report|silent> <sibling binary>"""
import ctypes
import ctypes.util
import json
import os
import socket
import subprocess
import sys
import time

sleeper, port, decoy, canary, token, mode, sibling_exe = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                                                          sys.argv[4], sys.argv[5], sys.argv[6], sys.argv[7])
key, _, value = canary.partition("=")
if mode == "silent":  # the harness self-test: alive with live children in its group, never reports
    kids = [subprocess.Popen([sleeper, "120"]) for _ in range(2)]
    time.sleep(120)
    sys.exit(0)
env = {"PATH": "/usr/bin:/bin", key: value}
if token != "-":
    env["ZB_LEAK"] = token
cli = subprocess.Popen([sleeper, "60"], env=env)
# The sibling runs the same code from ANOTHER path: it is not the CLI, so setup's census must not count it.
sibling = subprocess.Popen([sibling_exe, "60"], env={"PATH": "/usr/bin:/bin"})
time.sleep(0.3)

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)


def connect(p):
    try:
        socket.create_connection(("127.0.0.1", p), timeout=3).close()
        return "ok"
    except OSError as exc:
        return f"errno {exc.errno}"


def procargs2(pid):
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(0)
    ctypes.set_errno(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return f"errno {ctypes.get_errno()}"
    buf = ctypes.create_string_buffer(size.value)
    ctypes.set_errno(0)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return f"errno {ctypes.get_errno()}"
    return "ok"


def pidpath(pid):
    buf = ctypes.create_string_buffer(4096)
    ctypes.set_errno(0)
    if libproc.proc_pidpath(pid, buf, 4096) <= 0:
        return f"errno {ctypes.get_errno()}"
    return "ok"


def connect6(p):
    try:
        socket.create_connection(("::1", p), timeout=3).close()
        return "ok"
    except socket.timeout:
        return "timeout"
    except OSError as exc:
        return f"errno {exc.errno}"


report = {"r1_connect": connect(port), "decoy_connect": connect(decoy), "v6_connect": connect6(port),
          "sibling_procargs2": procargs2(sibling.pid), "sibling_pidpath": pidpath(sibling.pid),
          "cli_procargs2": procargs2(cli.pid), "cli_pidpath": pidpath(cli.pid)}
report["children_alive"] = cli.poll() is None and sibling.poll() is None
report["pids"] = [cli.pid, sibling.pid]  # this run's exact resources, for the harness's exact-scope cleanup
sys.stdout.write(json.dumps(report) + "\n")
sys.stdout.flush()
try:
    sys.stdin.read()
finally:
    for p in (cli, sibling):
        p.kill()
        p.wait()
