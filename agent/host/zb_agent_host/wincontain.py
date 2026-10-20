"""Windows helper branches, pure and OS-call-free so they unit-test on Linux (WS, item b).

The Linux backend (``sandbox.py``) contains the helper with bwrap; macOS will use Seatbelt. Windows has
no process-namespace sandbox, so a Windows backend will contain the child in a **Job Object** (kill-on-close
so no helper or CLI child outlives the drawer) and must get its path checks and command line exactly right.
This module holds the three decisions that are pure logic — path containment, argv quoting, and the
containment choice — behind an injected capability probe, so every branch is exercised by `python3 -I`
unit tests with no Windows host. The actual Win32 calls (CreateJobObject/AssignProcessToJobObject,
CreateProcessW) live in the eventual backend; this module decides *what* they do.

Nothing here imports a Win32 module or touches the filesystem; `ntpath` is the stdlib pure-Python Windows
path module and behaves identically on Linux, so the rules are testable and deterministic off-Windows.
"""

import ntpath
import re
from typing import NamedTuple, Protocol


class ContainError(Exception):
    """A path escapes its root, is malformed, or no containment is available — always fail closed."""


# Characters Win32 forbids in a path component, plus every control byte. Colon is handled separately (it is
# the drive separator and, past the drive, an alternate-data-stream marker).
_ILLEGAL_COMPONENT_CHARS = set('<>:"|?*') | {chr(c) for c in range(0, 32)}


# --- Windows path containment (lexical, fail-closed) -----------------------------------------------------
# Reserved DOS device names: these resolve to a device regardless of directory or extension, so a path
# component that is one (CON, NUL, COM3, LPT1.txt, ...) is rejected.
_RESERVED = {"CON", "PRN", "AUX", "NUL",
             *(f"COM{i}" for i in range(1, 10)),
             *(f"LPT{i}" for i in range(1, 10))}


def _check_shape(p: str, who: str) -> None:
    if not p:
        raise ContainError(f"{who}: empty path")
    if "\x00" in p:
        raise ContainError(f"{who}: NUL byte in path")
    # Reject UNC and the \\?\ / \\.\ device namespaces (and their forward-slash spellings): these bypass
    # normalization and name devices/other hosts, so they can never be "within" a local root.
    if p[:2] in ("\\\\", "//") or p[:2] == "\\/" or p[:2] == "/\\":
        raise ContainError(f"{who}: UNC or device-namespace path")
    drive, rest = ntpath.splitdrive(p)
    if len(drive) != 2 or drive[1] != ":" or not drive[0].isascii() or not drive[0].isalpha():
        raise ContainError(f"{who}: not a drive-absolute path (want X:\\...)")
    if not rest[:1] in ("\\", "/"):
        raise ContainError(f"{who}: drive-relative path (X:foo is relative to the drive's cwd)")
    # A ':' past the drive letter names an alternate data stream (file:stream) — a classic fence bypass.
    if ":" in rest:
        raise ContainError(f"{who}: ':' past the drive (alternate data stream?)")
    for comp in re.split(r"[\\/]+", rest):
        if not comp:
            continue
        # Windows silently strips trailing dots/spaces, so "foo." == "foo" and "x /" traversal tricks work;
        # reject any component that is not already in its stripped form. "." and ".." are legitimate
        # navigation (normpath collapses them and the containment check still catches any escape).
        if comp not in (".", "..") and comp != comp.rstrip(" ."):
            raise ContainError(f"{who}: component {comp!r} has a trailing dot/space")
        if comp.split(".")[0].upper() in _RESERVED:
            raise ContainError(f"{who}: reserved device name in {comp!r}")
        bad = _ILLEGAL_COMPONENT_CHARS & set(comp)
        if bad:
            raise ContainError(f"{who}: illegal character(s) {sorted(bad)!r} in {comp!r}")


def normalize_within(root: str, candidate: str) -> str:
    """Lexical PREFILTER only: return candidate's normalized form if it is root or strictly inside it.

    Fail-closed on shape: both paths must be well-formed drive-absolute Windows paths (no UNC, device
    namespace, drive-relative, ADS, reserved name, trailing dot/space, or illegal/control characters). `..`
    is collapsed by normpath and the result must still lie under root, so no `..` can escape. Comparison is
    case-insensitive, as Windows paths are.

    IMPORTANT: this is purely lexical. It CANNOT see a junction or symlink: `C:\\root\\j\\x` passes even when
    `j` reparses to `C:\\Windows`. Before granting access or spawning, the backend MUST resolve the real path
    and re-check — use `resolved_within`, which runs this prefilter and then an injected handle-based
    resolver (CreateFileW + GetFinalPathNameByHandle, or a component reparse walk).
    """
    _check_shape(root, "root")
    _check_shape(candidate, "candidate")
    nr = ntpath.normpath(root)
    nc = ntpath.normpath(candidate)
    rl = nr.rstrip("\\").lower()
    cl = nc.lower()
    if cl == rl or cl.startswith(rl + "\\"):
        return nc
    raise ContainError(f"candidate {candidate!r} escapes root {root!r}")


class PathResolver(Protocol):
    def resolve(self, path: str) -> str:
        """Return the real, fully-resolved path (reparse points/junctions/symlinks followed); raise on
        failure. Production binds this to CreateFileW + GetFinalPathNameByHandle (or a reparse walk); tests
        inject a fake. Resolution MUST fail closed — a junction that cannot be followed is a denial, never an
        OPEN_REPARSE_POINT that hands back the unresolved link (which would mask the escape)."""
        ...


def resolved_within(root: str, candidate: str, resolver: "PathResolver") -> str:
    """Full containment check: the lexical prefilter, THEN the injected handle-based resolver, fail-closed.

    `normalize_within` cannot see reparse points, so a lexically-in-root path can still resolve outside root
    (a junction `C:\\root\\j` targeting `C:\\Windows`). This resolves BOTH root and candidate to their real
    paths and requires the resolved candidate to lie within the resolved root. Returns the resolved candidate.
    Any resolver failure is a denial.
    """
    normalize_within(root, candidate)        # lexical prefilter (raises on bad shape / lexical escape)
    try:
        real_root = resolver.resolve(root)
        real_cand = resolver.resolve(candidate)
    except Exception as exc:
        raise ContainError(f"cannot resolve real path (fail closed): {exc}")
    if not isinstance(real_root, str) or not isinstance(real_cand, str) or not real_root or not real_cand:
        raise ContainError("resolver returned an empty/invalid path (fail closed)")
    return normalize_within(real_root, real_cand)   # re-check containment on the RESOLVED paths


# --- Windows argv quoting (CommandLineToArgvW / MSVCRT convention) ---------------------------------------
def quote_arg(s: str) -> str:
    """Quote one argument so CommandLineToArgvW parses it back byte-for-byte (Colascione's algorithm).

    Backslashes are literal except before a double-quote: a run of n backslashes then a `"` becomes 2n+1
    backslashes and an escaped quote; a run at the very end (before the closing quote we add) is doubled.
    An empty argument becomes `""`. Note: this is the C runtime / CommandLineToArgvW convention, NOT cmd.exe
    metacharacter escaping — a command line going through cmd needs the separate cmd layer on top.
    """
    if s == "":
        return '""'
    if not any(c in s for c in ' \t\n\v"'):
        return s
    out = ['"']
    backslashes = 0
    for c in s:
        if c == "\\":
            backslashes += 1
        elif c == '"':
            out.append("\\" * (backslashes * 2 + 1))
            out.append('"')
            backslashes = 0
        else:
            if backslashes:
                out.append("\\" * backslashes)
                backslashes = 0
            out.append(c)
    out.append("\\" * (backslashes * 2))  # trailing backslashes are doubled before the closing quote
    out.append('"')
    return "".join(out)


def join_argv(args) -> str:
    """Join an argv list into one Windows command line (each element quoted with quote_arg)."""
    args = list(args)
    if not args:
        raise ContainError("join_argv: empty argv")
    return " ".join(quote_arg(a) for a in args)


# --- containment choice (fail-closed) -------------------------------------------------------------------
class Containment(NamedTuple):
    kind: str                     # "bwrap" (Linux) | "seatbelt" (macOS) | "job-object" (Windows)
    kill_on_close: bool = False   # Job Object: terminate every child when the job handle closes
    create_suspended: bool = False  # Job Object: the child MUST be created suspended, assigned to the job,
    #   and only then resumed — so it cannot spawn or escape before it is inside the job. A boolean
    #   availability probe is not enough; the backend's launch sequence must honour this flag.


class ContainmentProbe(Protocol):
    def job_object_available(self) -> bool: ...


def choose_containment(platform: str, probe: "ContainmentProbe | None") -> Containment:
    """Pick the containment for a platform, failing closed rather than launching a child unconfined.

    `platform` is a sys.platform string. Windows requires a working Job Object (probed via `probe`); if the
    probe says no, or the platform is unknown, we refuse — an uncontained agent child is never acceptable.
    """
    if platform.startswith("linux"):
        return Containment("bwrap")
    if platform == "darwin":
        return Containment("seatbelt")
    if platform == "win32" or platform.startswith("win") or platform == "cygwin":
        if probe is not None and probe.job_object_available():
            return Containment("job-object", kill_on_close=True, create_suspended=True)
        raise ContainError("containment unavailable: no usable Job Object (refusing to launch unconfined)")
    raise ContainError(f"containment unavailable: unsupported platform {platform!r}")
