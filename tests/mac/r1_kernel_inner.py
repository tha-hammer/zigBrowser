"""The inside half of tests/mac/r1_kernel_driver.py, run under the real setup Seatbelt profile. It plays the probe:
starts the CLI stand-in (the canary, and with argv[5] != "-" that token, in its environment) and a sibling, tries
the R1 port, the decoy port, and KERN_PROCARGS2 / proc_pidpath of both, prints one JSON line, then holds its
children alive until its stdin closes. argv: <sleeper> <r1 port> <decoy port> <canary entry> <token or ->"""
import ctypes
import ctypes.util
import json
import os
import socket
import subprocess
import sys

sleeper, port, decoy, canary, token = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
key, _, value = canary.partition("=")
env = {"PATH": "/usr/bin:/bin", key: value}
if token != "-":
    env["ZB_LEAK"] = token
cli = subprocess.Popen([sleeper, "60"], env=env)
sibling = subprocess.Popen([sleeper, "60"], env={"PATH": "/usr/bin:/bin"})

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
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return f"errno {ctypes.get_errno()}"
    return "ok"


def pidpath(pid):
    buf = ctypes.create_string_buffer(4096)
    ctypes.set_errno(0)
    if libproc.proc_pidpath(pid, buf, 4096) <= 0:
        return f"errno {ctypes.get_errno()}"
    return "ok"


report = {"r1_connect": connect(port), "decoy_connect": connect(decoy),
          "sibling_procargs2": procargs2(sibling.pid), "sibling_pidpath": pidpath(sibling.pid),
          "cli_procargs2": procargs2(cli.pid), "cli_pidpath": pidpath(cli.pid)}
sys.stdout.write(json.dumps(report) + "\n")
sys.stdout.flush()
try:
    sys.stdin.read()
finally:
    for p in (cli, sibling):
        p.kill()
        p.wait()
