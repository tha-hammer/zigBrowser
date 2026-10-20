"""WS7.5 (the Windows plan; AzureRidge 6335): the package's POSIX-only seams fail closed on Windows.

The dispatcher (__main__) refuses, on win32, every command not marked Windows-capable, before
importing it. As a second line, each fork/exec seam calls posix_only(): a mis-marked command then
stops with a clear NotOnWindows, never an AttributeError from a missing os.fork. The standalone,
standard-library-only scripts (netd, relay, hook_run, probe) carry the same few lines themselves,
since they run by path, outside the package."""

import sys


class NotOnWindows(RuntimeError):
    """A POSIX-only part of zb_agent_host was reached on Windows."""


def posix_only(name):
    if sys.platform == "win32":
        raise NotOnWindows(f"zb_agent_host {name}: not available on Windows yet")
