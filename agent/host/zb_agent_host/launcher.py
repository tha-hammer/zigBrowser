"""WS7.3 portable launcher contract (plan line 1664).

On Windows the native `zb-claude.exe` (Zig) is the production launcher: it sets up the token channel, starts
`claude.exe` in the session's Job, waits, and returns its exit code. Windows has no `exec` and the Agent SDK refuses
`.bat`/`.cmd` shims, so the launcher spawns a real executable directly. This module is the PORTABLE contract that the
exe must meet (and the POSIX reference): build the exact argv, refuse a `.bat`/`.cmd` shim, spawn, wait, and return
the child's exit code (reaping it, so there are no orphans).

It imports cleanly on win32: only the cross-platform `subprocess` is used at module scope (no fcntl/pty/termios/
resource), per the agent-host-win-import gate.
"""

from __future__ import annotations

import subprocess


class ShimRefused(Exception):
    """A `.bat`/`.cmd` shim target is refused: the Agent SDK requires a real executable, not a shell shim."""


def build_argv(claude_exe, args):
    """The exact launch argv: `[claude_exe, *args]`, with no shell shim. A `.bat`/`.cmd` target (case-insensitive)
    is refused with `ShimRefused`."""
    low = claude_exe.lower()
    if low.endswith(".bat") or low.endswith(".cmd"):
        raise ShimRefused(claude_exe)
    return [claude_exe, *list(args)]


def run(claude_exe, args):
    """Spawn `[claude_exe, *args]`, wait for it, and return its exit code. `wait()` reaps the child, so the launcher
    leaves no orphan. The child's exit code IS the launcher's return value."""
    proc = subprocess.Popen(build_argv(claude_exe, args))
    return proc.wait()
