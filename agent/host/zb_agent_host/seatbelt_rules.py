"""Curated macOS Seatbelt file-read and Mach-service capabilities.

The broad ``(allow file-read*)`` and ``(allow mach-lookup)`` forms are not
capabilities: they expose the user's whole home and every bootstrap service.
This module builds the two closed allowlists consumed by ``sandbox_macos``.

Caller-owned paths are never interpolated into SBPL.  They are validated and
bound through named ``sandbox-exec -D`` parameters.  The static entries below
are product constants: none may name a user-home root.
"""

from __future__ import annotations

import os
from typing import NamedTuple


# Immutable operating-system files needed by the staged Python 3.12 runtime,
# the bundled Claude CLI, and the system runtime positive controls.  This is a
# closed set: additions require a failing real-CLI run on a supported Mac.
SYSTEM_READ_ALLOW = (
    ("literal", "/"),
    ("literal", "/Applications"),
    ("subpath", "/Applications/Xcode.app"),
    ("literal", "/Library"),
    ("subpath", "/Library/Apple"),
    ("literal", "/Library/Developer"),
    ("subpath", "/Library/Developer/CommandLineTools"),
    ("subpath", "/Library/Frameworks"),
    ("subpath", "/Library/Preferences"),
    ("subpath", "/System"),
    ("subpath", "/bin"),
    ("literal", "/private"),
    ("subpath", "/private/etc"),
    ("literal", "/private/var"),
    ("literal", "/private/var/db"),
    ("subpath", "/private/var/db/timezone"),
    ("literal", "/private/var/db/xcode_select_link"),
    ("subpath", "/private/var/select"),
    ("subpath", "/sbin"),
    ("subpath", "/usr"),
    ("literal", "/dev/dtracehelper"),
    ("literal", "/dev/autofs_nowait"),
    ("literal", "/dev/fd"),
    ("subpath", "/dev/fd"),
    ("literal", "/dev/null"),
    ("literal", "/dev/random"),
    ("literal", "/dev/tty"),
    ("literal", "/dev/urandom"),
    ("literal", "/dev/zero"),
    ("literal", "/etc"),
    ("literal", "/tmp"),
    ("literal", "/var"),
    ("literal", "/var/select"),
)


# The agent uses its backend-owned loopback proxy and descriptor channels.
# Neither the staged Python runtime nor the bundled CLI needs a global Mach
# service in the exercised start/sign-in/chat paths, so deny-default is the
# least-privilege allowlist.  Do not add WindowServer, securityd, trustd,
# mDNSResponder, pasteboard, notification center, or screen-capture brokers.
MACH_LOOKUP_ALLOW = ()


class FileReadRules(NamedTuple):
    """Rendered SBPL lines and their ordered ``-D`` path bindings."""

    lines: tuple[str, ...]
    bindings: tuple[tuple[str, str], ...]


def _validated_path(value: object) -> str:
    """Return one canonical non-root absolute path, or fail closed."""

    if isinstance(value, bytes):
        raise ValueError("read path must be text, not bytes")
    try:
        path = os.fspath(value)
    except TypeError:
        raise ValueError("read path must be path-like text") from None
    if not isinstance(path, str) or not path.startswith("/") or "\0" in path:
        raise ValueError("read path must be absolute text without NUL")
    if "//" in path or os.path.normpath(path) != path:
        raise ValueError("read path must be canonical without '.', '..', repeated, or trailing separators")
    if path == "/":
        raise ValueError("the filesystem root is not a valid read capability")
    return path


def _filter(kind: str, value: str) -> str:
    """Render one trusted static filter after checking its source shape."""

    if kind not in ("literal", "subpath") or not value.startswith("/"):
        raise ValueError("invalid static file-read allowlist entry")
    if any(char in value for char in ('"', "\n", "\r", "\0")):
        raise ValueError("unsafe static file-read allowlist entry")
    return f'({kind} "{value}")'


def file_read_rules(read_paths=()) -> FileReadRules:
    """Build the closed file-read policy for caller-owned ``read_paths``.

    Dynamic paths become ``READ_0``, ``READ_1``, ... bindings and appear in
    source only as ``(param ...)`` references.  Sorting and de-duplicating make
    the same capability render byte-for-byte identically across callers.
    """

    paths = tuple(sorted({_validated_path(path) for path in read_paths}))
    bindings = [(f"READ_{index}", path) for index, path in enumerate(paths)]
    filters = [_filter(kind, path) for kind, path in SYSTEM_READ_ALLOW]
    for name, _path in bindings:
        # ``subpath`` covers descendants, while ``literal`` covers metadata
        # checks on the capability root itself (including a process cwd).
        filters.append(f'(literal (param "{name}"))')
        filters.append(f'(subpath (param "{name}"))')

    # Seatbelt separately checks metadata on each ancestor while resolving a
    # dynamic subpath. Grant those directories literally (never as subpaths),
    # still through -D parameters, so a sibling such as ~/.ssh is not exposed.
    parents = set()
    for path in paths:
        parent = os.path.dirname(path)
        while parent != "/":
            if not any(parent == allowed or parent.startswith(allowed + "/") for allowed in paths):
                parents.add(parent)
            parent = os.path.dirname(parent)
    for index, parent in enumerate(sorted(parents)):
        name = f"READ_PARENT_{index}"
        bindings.append((name, parent))
        filters.append(f'(literal (param "{name}"))')
    return FileReadRules((f'(allow file-read* {" ".join(filters)})',), tuple(bindings))


def mach_lookup_rules() -> tuple[str, ...]:
    """Render exact-name Mach lookup rules; empty means deny-default."""

    lines = []
    for service in MACH_LOOKUP_ALLOW:
        if not service or any(char in service for char in ('"', "\n", "\r", "\0")):
            raise ValueError("unsafe Mach lookup allowlist entry")
        lines.append(f'(allow mach-lookup (global-name "{service}"))')
    return tuple(lines)
