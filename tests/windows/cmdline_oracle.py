"""VM-side argv oracle — calls the REAL Win32 CommandLineToArgvW on each command line and reports the argv.

Staged to the Win11 VM and run there by wincontain_argv_live_test.py. Independent of zb_agent_host's quoting:
it asks Windows itself how it parses a command line, so the test can confirm `join_argv` round-trips through
the actual parser (not a second hand-written parser). Reads {"lines":[...]} from the JSON file named in argv,
prints {"parsed":[[argv,...],...]} as one JSON line on stdout.

Run (on Windows):  python cmdline_oracle.py batteries.json
"""
import ctypes
import json
import sys
from ctypes import wintypes


def parse(line: str):
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    shell32.CommandLineToArgvW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_int)]
    shell32.CommandLineToArgvW.restype = ctypes.POINTER(wintypes.LPWSTR)
    kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    kernel32.LocalFree.restype = wintypes.HLOCAL
    n = ctypes.c_int(0)
    p = shell32.CommandLineToArgvW(line, ctypes.byref(n))
    if not p:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        return [p[i] for i in range(n.value)]
    finally:
        kernel32.LocalFree(p)


def main():
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    out = [parse(line) for line in data["lines"]]
    sys.stdout.write(json.dumps({"parsed": out}))


if __name__ == "__main__":
    main()
