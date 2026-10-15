"""The orphan hook (chat-drawer plan rev 16.2, §3c.8b, "No orphan"; S3n2). A hook runs it as

    /usr/bin/python3 -I -S hook_orphan.py <canary> <ready-file> exit|wait

It starts a grandchild by a double fork and setsid (so it leaves the hook's
process group and is reparented), which connects to the bridge 127.0.0.1:51091,
sends `orphan-<canary>` and then holds the connection open for good. Every one
of these processes carries the canary in its argv. When the grandchild is
connected the hook writes <ready-file>, then exits 0 (`exit`) or waits for good
(`wait`). Standard library only."""

import os
import socket
import sys
import time


def grandchild(canary):
    s = socket.create_connection(("127.0.0.1", 51091), timeout=5)
    s.sendall(f"orphan-{canary}".encode())
    os.write(1, b"connected\n")
    while True:
        time.sleep(60)


def main(canary, ready, mode):
    r, w = os.pipe()
    if os.fork() == 0:
        os.setsid()
        if os.fork() == 0:
            os.close(r)
            os.dup2(w, 1)
            null = os.open("/dev/null", os.O_RDWR)  # holds none of the hook's stdio
            os.dup2(null, 0)
            os.dup2(null, 2)
            grandchild(canary)
        os._exit(0)
    os.close(w)
    os.wait()
    if os.read(r, 64) != b"connected\n":
        return 3
    with open(ready, "w"):
        pass
    if mode == "wait":
        while True:
            time.sleep(60)
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:4]))
