"""macOS Seatbelt backend (MS6) — the profile generator.

`render_profile` emits the Seatbelt (.sb) text a `MacSeatbeltBackend` launch runs under
`/usr/bin/sandbox-exec -f <profile> -D SCRATCHPAD=<path> ...`. It realizes, in profile form, the same semantic
launch contract the Linux `LinuxBwrapBackend` realizes as a bwrap argv (MS0 `SandboxBackend`): deny-default,
a read-only workspace with a writable scratchpad, and the backend's network capability (the egress endpoint
for the CLI/helper, the two bridge ports, and hooks reaching the bridges only).

Security construction (RoseCat 6918; plan:1562-1566 "profile file + -D params, not inline"):
  * NO untrusted value is interpolated into the profile source. The writable path and every caller-owned read
    capability are NAMED `-D` parameters; sandbox-exec binds each value as a literal (not re-parsed as profile
    source), so a path containing a quote/newline/paren cannot add a rule. The workspace is absent from every
    write rule, so a write still fails closed under deny-default.
  * The only values placed in the source are the loopback endpoints, and they are VALIDATED first: the host
    must be a loopback literal and each port a plain integer 1..65535 — a validated integer is a proven, non-
    injectable encoding (it is digits), which is why a Seatbelt network filter, which takes no `-D` param,
    can carry it safely.
  * An empty/invalid network capability is REFUSED, never widened: `(allow network-outbound )` with no
    endpoint is the dangerous shape Seatbelt reads as "all outbound", so render_profile raises instead.

The token-isolation recipe was measured against the real kernel on both arches in the MS6.1 Mac gate: an
EXPLICIT `(deny process-info*)` AND a CURATED `sysctl-read` (a blanket allow re-opens kern.procargs2); the
task port is never granted. Reads and Mach lookups come from the closed capabilities in `seatbelt_rules`; the
drawer launch nevertheless enters Seatbelt whether or not the separate release-readiness fact has been accepted.
Pure stdlib, so it unit-tests on Linux; the both-Mac `sandbox-exec` gate still applies.
"""

import contextlib
import enum
import os
import secrets
import shutil
import signal
import stat
import tempfile

if __package__:
    from . import seatbelt_rules
else:  # The Mac profile gate stages these two production modules side by side.
    import seatbelt_rules

# The egress endpoint's host is EXACTLY the loopback literal (plan :1581-1593) — not "localhost", not a
# resolvable name. The bridges are EXACTLY the two named loopback ports; missing/extra/wrong is refused.
_LOOPBACK_HOST = "127.0.0.1"
CANONICAL_BRIDGES = (51091, 31337)
_CHAR_DEVICES = ("/dev/null", "/dev/zero", "/dev/dtracehelper", "/dev/tty", "/dev/urandom", "/dev/random")
# Curated sysctl-read allowlist — never a blanket (allow sysctl-read), which (measured, MS6.1) re-opens
# another process's kern.procargs2 even with process-info denied.
_SYSCTL_ALLOW = (
    ("sysctl-name-prefix", "hw."),
    ("sysctl-name-prefix", "kern.os"),
    ("sysctl-name", "kern.ostype"),
    ("sysctl-name", "kern.osrelease"),
    ("sysctl-name", "kern.version"),
    ("sysctl-name", "kern.hostname"),
    ("sysctl-name", "kern.maxproc"),
    ("sysctl-name", "kern.argmax"),
    ("sysctl-name", "kern.ngroups"),
    ("sysctl-name", "kern.usrstack64"),
)
# The one named -D parameter the profile binds (the writable scratchpad). Kept as a constant so the launch
# and the profile cannot drift.
SCRATCHPAD_PARAM = "SCRATCHPAD"
SESSION_CANARY_PARAM = "SESSION_CANARY"
_SESSION_CANARY_PREFIX = "zb-agent-session-"


def _validate_port(port):
    if isinstance(port, bool) or not isinstance(port, int):
        raise ValueError(f"port must be an integer, got {port!r}")
    if not (1 <= port <= 65535):
        raise ValueError(f"port out of range 1..65535: {port}")
    return port


def _validate_host(host):
    if host != _LOOPBACK_HOST:
        raise ValueError(f"endpoint host must be exactly {_LOOPBACK_HOST!r} (not a name like 'localhost'), got {host!r}")
    return host


def _endpoints(egress, bridges, is_hook, is_login=False):
    """The validated, de-duplicated loopback endpoints this profile may reach, as Seatbelt host:port strings.

    Raises ValueError on an empty or malformed capability (never widens to all-outbound): the egress host
    must be exactly 127.0.0.1 with an integer port 1..65535, and the bridges must be EXACTLY the two
    canonical ports (missing/extra/wrong refused, plan :1581-1593).

    NOTE on the emitted rule (measured both arches, RoseCat 7039): Seatbelt's ``remote`` host token accepts ONLY
    ``*`` or ``localhost`` — the IP literal ``127.0.0.1`` is a parse error. So the INPUT capability is validated
    as exactly ``127.0.0.1`` (rejecting names/other IPs), and the rule emits the ``localhost`` loopback token
    with the validated port. The rule uses ``(remote tcp ...)``, NOT ``(remote ip ...)``: ``remote ip`` also
    grants UDP at the port (measured leak), while ``remote tcp`` narrows to TCP, matching the pinned contract
    (plan :1576-1583). ``localhost`` covers BOTH loopback families, so IPv6 ``::1:<port>`` TCP is also permitted
    by policy; it is unreachable in practice (netd and the bridges bind 127.0.0.1 only, so ``::1`` has no
    listener), and Seatbelt offers no token to exclude the v6 loopback. The IPv4-mapped form is denied.
    """
    if type(is_hook) is not bool:
        raise ValueError(f"is_hook must be a bool, got {type(is_hook).__name__} {is_hook!r}")
    if type(is_login) is not bool:
        raise ValueError(f"is_login must be a bool, got {type(is_login).__name__} {is_login!r}")
    bridges = tuple(bridges)

    eps = []
    seen = set()

    def add(host, port):
        _validate_host(host)        # INPUT must be exactly 127.0.0.1 (reject localhost/names/other IPs)
        port = _validate_port(port)
        if port in seen:            # host is uniformly the loopback, so the port is the identity
            raise ValueError(f"duplicate loopback port {port}")
        seen.add(port)
        eps.append(f"localhost:{port}")  # Seatbelt's only accepted loopback host token

    if is_login:
        # The one-shot sign-in: egress endpoint ONLY, no bridges (setup-token runs no hooks).
        if is_hook:
            raise ValueError("a login profile is not a hook")
        if egress is None:
            raise ValueError("a login profile must carry an egress endpoint")
        if bridges:
            raise ValueError("a login profile has no bridges (the sign-in runs no hooks)")
        add(getattr(egress, "host"), getattr(egress, "port"))
        return eps

    if is_hook and egress is not None:
        raise ValueError("a hook profile must not carry an egress endpoint (rev 16.2 §3c: bridges only)")
    if not is_hook and egress is None:
        raise ValueError("a cli/helper profile must carry an egress endpoint")
    if set(bridges) != set(CANONICAL_BRIDGES) or len(bridges) != len(CANONICAL_BRIDGES):
        raise ValueError(f"bridges must be exactly {CANONICAL_BRIDGES} (missing/extra/wrong/duplicate refused), "
                         f"got {bridges}")

    if not is_hook:
        # egress is an object with .host/.port (sandbox.Endpoint); validated in add().
        add(getattr(egress, "host"), getattr(egress, "port"))
    for port in bridges:
        add(_LOOPBACK_HOST, port)  # the backend's bridges are loopback 127.0.0.1 by contract
    return eps


def _sysctl_block():
    """The curated sysctl-read allow, as profile lines (never a blanket allow — MS6.1)."""
    first_k, first_v = _SYSCTL_ALLOW[0]
    lines = [f'(allow sysctl-read ({first_k} "{first_v}")']
    for k, v in _SYSCTL_ALLOW[1:]:
        lines.append(f'  ({k} "{v}")')
    lines[-1] += ")"
    return lines


def _file_write_line():
    """The write rule: ONLY the scratchpad (-D param) and the standard character devices."""
    devices = " ".join(f'(literal "{d}")' for d in _CHAR_DEVICES)
    return f'(allow file-write* (subpath (param "{SCRATCHPAD_PARAM}")) {devices})'


def _login_pty_lines(is_login):
    """Grant login one terminal pair without exposing the device tree.

    ``claude setup-token`` refuses non-terminal input. Current Darwin allocates
    through ``/dev/ptmx`` with a hexadecimal ``/dev/ttys…`` slave; older Intel
    Python scans the fixed BSD ``pty[p-w][0-f]``/``tty[p-w][0-f]`` pairs. Chat,
    hooks, and setup do not receive any of these capabilities.
    """
    if not is_login:
        return ()
    endpoints = ('(literal "/dev/ptmx") '
                 '(regex #"^/dev/(pty[p-w][0-9a-f]|tty[p-w][0-9a-f]|ttys[0-9a-f]+)$")')
    return (f"(allow file-read* {endpoints})", f"(allow file-write* {endpoints})",
            f"(allow file-ioctl {endpoints})", "(allow pseudo-tty)",
            "(allow signal (target children))")


def _login_listener_lines(is_login):
    """Grant only the real setup-token CLI's ephemeral 127.0.0.1 OAuth listener.

    Claude 2.1.294 creates an HTTP server with ``listen(0, "127.0.0.1")`` before
    it prints the manual authorization URL.  Darwin checks bind and listen as
    separate Seatbelt operations.  The local-tcp filter excludes non-loopback
    interfaces; chat, hooks, and setup never receive either capability.
    """
    if not is_login:
        return ()
    loopback_tcp = '(local tcp "localhost:*")'
    return (f"(allow network-bind {loopback_tcp})", f"(allow network-inbound {loopback_tcp})")


def _keychain_denies():
    """Deny Security.framework's brokers and direct legacy-Keychain file path."""
    return [
        ";; token isolation (MS6.1): only the trusted parent reads Keychain before sandbox entry.",
        '(deny file-read* (regex #"^/.*[.]keychain$"))',
        '(deny file-read* (regex #"^/.*[.]keychain-db([.].*)?$"))',
        '(deny file-read* (subpath "/Library/Keychains"))',
        '(deny file-read* (regex #"^/Users/[^/]+/Library/Keychains(/|$)"))',
        '(deny ipc-posix* (ipc-posix-name "com.apple.securityd"))',
        '(deny mach-lookup (global-name "com.apple.securityd"))',
        '(deny mach-lookup (global-name "com.apple.securityd.xpc"))',
        '(deny mach-lookup (global-name "com.apple.securityd.general"))',
        '(deny mach-lookup (global-name "com.apple.securityd.aps"))',
        '(deny mach-lookup (global-name "com.apple.securityd.ckks"))',
        '(deny mach-lookup (global-name "com.apple.securityd.octagon"))',
        '(deny mach-lookup (global-name "com.apple.securityd.systemkeychain"))',
        '(deny mach-lookup (global-name "com.apple.securitydservice"))',
        '(deny mach-lookup (global-name "com.apple.keychainsharingmessagingd"))',
        '(deny mach-lookup (global-name "com.apple.security.agent"))',
    ]


def render_profile(*, egress, bridges, is_hook, is_login=False, read_paths=(), session_canary=None):
    """Return the Seatbelt profile text for a CLI/helper (``is_hook=False``), a hook (``is_hook=True``), or the
    one-shot sign-in (``is_login=True``: egress endpoint only, no bridges).

    ``egress`` is a :class:`sandbox.Endpoint` (or None for a hook); ``bridges`` is the tuple of loopback
    bridge ports (empty for login). Raises ``ValueError`` on an empty or malformed network capability. The
    writable scratchpad is NOT an argument — it is bound at launch as the ``SCRATCHPAD`` ``-D`` parameter, so
    no path is ever interpolated into the source.
    """
    eps = _endpoints(egress, bridges, is_hook, is_login)
    reads = seatbelt_rules.file_read_rules(read_paths)
    canary_line = []
    if session_canary is not None:
        _validated_session_canary(session_canary)
        canary_line = [
            ";; process identity: exact per-session path, queried only by the trusted browser-exit reaper.",
            f'(allow file-read-data (literal (param "{SESSION_CANARY_PARAM}")))',
        ]
    net = " ".join(f'(remote tcp "{e}")' for e in eps)
    kind = "login" if is_login else ("hook" if is_hook else "cli/helper")
    net_note = ("egress + loopback callback listener (sign-in; no bridges)" if is_login
                else "bridges only (no egress — rev 16.2 §3c)" if is_hook else "egress + bridges")

    lines = [
        "(version 1)",
        f";; MS6 macOS Seatbelt profile ({kind}) — generated by sandbox_macos.render_profile. Do not hand-edit.",
        ";; The writable path is the SCRATCHPAD -D parameter; no untrusted value is interpolated into source.",
        "(deny default)",
        "(allow process-fork)",
        "(allow process-exec)",
        *canary_line,
        *reads.lines,
        *_login_pty_lines(is_login),
        _file_write_line(),
        *_login_listener_lines(is_login),
        f";; network: {net_note}",
        f"(allow network-outbound {net})",
        ";; sysctl-read CURATED (MS6.1): never blanket — a blanket allow re-opens kern.procargs2.",
        *_sysctl_block(),
        ";; token isolation (MS6.1): deny cross-process introspection (the task port is never granted); self is",
        ";; allowed so the runtime introspects itself at startup (code signature / exec path) without SIGILL (7045).",
        "(deny process-info*)",
        "(allow process-info* (target self))",
        *seatbelt_rules.mach_lookup_rules(),
        *_keychain_denies(),
    ]
    return "\n".join(lines) + "\n"


def render_setup_profile(*, loopback_port=None, read_paths=()):
    """Return the Seatbelt profile text for setup's OWN runs (`cli --version`, the R1 probe).

    It KEEPS the token-isolation belt (curated `sysctl-read` + explicit `(deny process-info*)`), exactly like
    the agent CLI/hook profile. The R1 process census does NOT run inside this sandbox: `route_probe`, the SDK,
    the wrapper and the CLI are all descendants of the same `sandbox-exec`, so granting introspection here would
    hand the code under test the observer's capability (RoseCat 7019). Instead trusted setup observes its own
    descendants OUTSIDE Seatbelt over a socketpair and answers the probe (BlueBeaver 7021); this profile denies
    process-info for both `cli --version` and the R1 run.

    Network: with no `loopback_port`, there is NO `(allow network-outbound)` form — deny-default denies every
    outbound connect (BlueBeaver's contract: "only its own loopback"). With `loopback_port` (the inherited R1
    listener's 127.0.0.1 port), exactly that one `localhost:<port>` is permitted and nothing else. No value is
    interpolated: the scratch is bound as the `SCRATCHPAD` `-D` param, and the port is range-validated here.
    """
    reads = seatbelt_rules.file_read_rules(read_paths)
    net = [";; network: NONE — deny-default denies all outbound (setup reaches only its own loopback)."]
    if loopback_port is not None:
        _validate_port(loopback_port)
        net = [";; network: ONLY the R1 probe's pre-bound loopback port.",
               f'(allow network-outbound (remote tcp "localhost:{loopback_port}"))']

    lines = [
        "(version 1)",
        ";; MS6 macOS Seatbelt profile (setup own-run) — generated by sandbox_macos.render_setup_profile. Do not hand-edit.",
        ";; The writable path is the SCRATCHPAD -D parameter; no untrusted value is interpolated into source.",
        "(deny default)",
        "(allow process-fork)",
        "(allow process-exec)",
        *reads.lines,
        _file_write_line(),
        *net,
        ";; sysctl-read CURATED (MS6.1): never blanket — a blanket allow re-opens kern.procargs2.",
        *_sysctl_block(),
        ";; token isolation (MS6.1): deny cross-process introspection — the R1 census runs OUTSIDE this sandbox in",
        ";; trusted setup (BlueBeaver 7021), so the probed CLI never reads a SIBLING (RoseCat 7019); self is allowed",
        ";; so Python/the runtime introspects itself at startup without SIGILL (7045).",
        "(deny process-info*)",
        "(allow process-info* (target self))",
        *seatbelt_rules.mach_lookup_rules(),
        *_keychain_denies(),
    ]
    return "\n".join(lines) + "\n"


def dparams(*, scratchpad):
    """The validated ``-D`` bindings for a launch. ``scratchpad`` must be a **canonical, non-root absolute
    path**: bound to ``(subpath (param "SCRATCHPAD"))`` it is the only write grant, so the filesystem root
    or an alias that resolves to it (``/``, ``/tmp/..``, ``/a/../b``, trailing/double slashes) must be
    refused — otherwise the sole write grant widens (RoseCat 6939 #1). The value is bound literally by
    sandbox-exec (never parsed as profile source), so it cannot inject a rule. The backend's launch_spec
    binds the exact ``home.scratchpad`` here, which is the stronger check at the call site. It must also
    already exist as a directory that is its own real path: Seatbelt compares resolved paths."""
    if not isinstance(scratchpad, str) or not scratchpad.startswith("/"):
        raise ValueError(f"SCRATCHPAD must be an absolute path, got {scratchpad!r}")
    if "//" in scratchpad:  # POSIX normpath keeps a leading '//', so reject any double slash explicitly
        raise ValueError(f"SCRATCHPAD must not contain '//': {scratchpad!r}")
    norm = os.path.normpath(scratchpad)
    if norm != scratchpad:
        raise ValueError(f"SCRATCHPAD must be canonical (no '.'/'..'/trailing or double slash): "
                         f"{scratchpad!r} normalizes to {norm!r}")
    if norm == "/" or os.path.dirname(norm) == norm:
        raise ValueError(f"SCRATCHPAD must not be the filesystem root: {scratchpad!r}")
    # Seatbelt matches the RESOLVED path, so a write root spelled through a symlink (macOS's /tmp -> private/tmp)
    # grants nothing: every write, the scratchpad's own included, is denied (11b3ac4 on both Macs). Refuse it,
    # never rewrite it: only an existing directory that is its own real path (RoseCat 7627). The message names
    # the field only, never the supplied or resolved path.
    if not os.path.isdir(norm) or os.path.realpath(norm) != norm:
        raise ValueError("SCRATCHPAD must be an existing directory that is its own real path (no symlink)")
    return {SCRATCHPAD_PARAM: norm}


def _validated_session_canary(path):
    """Validate the exact, existing regular file used only as one launch's Seatbelt identity."""
    if not isinstance(path, str) or not path.startswith("/") or "\0" in path or "//" in path:
        raise ValueError("SESSION_CANARY must be canonical absolute text")
    if os.path.normpath(path) != path or os.path.realpath(path) != path:
        raise ValueError("SESSION_CANARY must be canonical and contain no symlink")
    base = os.path.basename(path)
    suffix = base.removeprefix(_SESSION_CANARY_PREFIX)
    if not base.startswith(_SESSION_CANARY_PREFIX) or len(suffix) != 32 \
            or any(char not in "0123456789abcdef" for char in suffix):
        raise ValueError("SESSION_CANARY must use the product's random basename")
    try:
        st = os.lstat(path)
    except OSError:
        raise ValueError("SESSION_CANARY must be an existing regular file") from None
    if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o400:
        raise ValueError("SESSION_CANARY must be a 0400 regular file")
    return path


def _materialize_session_canary():
    """Create one unguessable, real path; sandbox_check denies even allowed paths that do not exist."""
    parent = os.path.realpath(tempfile.gettempdir())
    for _ in range(8):
        path = os.path.join(parent, f"{_SESSION_CANARY_PREFIX}{secrets.token_hex(16)}")
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o400)
        except FileExistsError:
            continue
        try:
            os.fchmod(fd, 0o400)
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o400 or st.st_size != 0:
                raise OSError("Seatbelt session canary failed its post-create fd check")
        except BaseException:
            os.close(fd)
            try:
                os.unlink(path)
            except OSError:
                pass
            raise
        os.close(fd)
        return _validated_session_canary(path)
    raise FileExistsError("could not allocate a unique Seatbelt session canary")


def remove_session_canary(path):
    """Guard-delete exactly one product canary. Used by failed launches and the out-of-group reaper."""
    try:
        checked = _validated_session_canary(path)
    except ValueError:
        return False
    try:
        os.unlink(checked)
    except OSError:
        return False
    return True


def read_bindings(read_paths=()):
    """The ordered named parameters for the curated caller-owned read capabilities."""
    return seatbelt_rules.file_read_rules(read_paths).bindings


def _binding_argv(bindings):
    """Flatten validated ``(name, value)`` bindings into sandbox-exec ``-D`` arguments."""
    return tuple(part for name, value in bindings for part in ("-D", f"{name}={value}"))


def _symlink_spellings(path):
    """Return intermediate target spellings needed to traverse a symlink chain.

    ``realpath`` gives only the final target.  A relative link such as
    ``runtime -> current/runtime`` still makes Seatbelt check ``current`` while
    resolving it, before it reaches ``current -> dist-1``.  Preserve each such
    spelling so ``file_read_rules`` emits the literal ancestor grants needed
    for traversal without granting the agent-home root.
    """
    found = []
    pending = [path]
    seen = {path}
    while pending:
        spelling = pending.pop()
        parts = spelling.split(os.sep)[1:]
        prefix = os.sep
        for index, part in enumerate(parts):
            candidate = os.path.join(prefix, part)
            try:
                target = os.readlink(candidate)
            except OSError:
                prefix = candidate
                continue
            target = target if os.path.isabs(target) else os.path.join(os.path.dirname(candidate), target)
            expanded = os.path.normpath(os.path.join(target, *parts[index + 1:]))
            if expanded not in seen:
                seen.add(expanded)
                found.append(expanded)
                pending.append(expanded)
            break
    return tuple(found)


def _resolved_read_paths(paths):
    """Keep each canonical spelling, its symlink hops, and final resolved spelling.

    The fixed agent-home links (``runtime`` and ``.claude``) are deliberate. Seatbelt compares filesystem access
    against every path used during resolution, so the stable link spelling, intermediate ``current`` spelling and
    immutable distribution target are capabilities; none grants a sibling below the agent-home root.
    """
    raw = tuple(os.fspath(path) for path in paths)
    seatbelt_rules.file_read_rules(raw)  # validate before realpath can normalize a rejected spelling
    expanded = list(raw)
    for path in raw:
        expanded.extend(_symlink_spellings(path))
        resolved = os.path.realpath(path)
        if resolved != path:
            expanded.append(resolved)
    result = tuple(sorted(set(expanded)))
    seatbelt_rules.file_read_rules(result)
    return result


def _launch_read_paths(home, ro_paths):
    """Exact agent-home inputs plus the caller's backend-neutral read capabilities."""
    owned = (home.claude_dir, home.workspace, home.scratchpad, home.runtime, home.state)
    return _resolved_read_paths((*owned, *tuple(ro_paths)))


_SETUP_PROFILE_PREFIX = ".zb-setup-sandbox-"


@contextlib.contextmanager
def setup_sandbox(scratch, ro_paths, command, *, loopback_port=None):
    """Yield the ``sandbox-exec`` argv for one of setup's OWN runs (`cli --version`, the R1 probe), under
    `render_setup_profile`. Setup's throwaway home is the writable scratch.

    `loopback_port` (the R1 probe's pre-bound 127.0.0.1 port): when given, the setup profile permits exactly
    that one `localhost:<port>` outbound and nothing else; when None (e.g. `cli --version`), the profile has
    no network at all (deny-default). It is range-validated by `render_setup_profile`, never interpolated raw.

    File-lifetime (chosen 2026-10-21, orchestrator; BlueBeaver may object by mail): a PER-RUN profile file is
    written under `scratch` and **guard-deleted** here on exit — a context manager, rather than a plain argv-
    returning function, so cleanup is guaranteed. The profile's policy is locked in by sandbox-exec at exec
    time, so a command writing to scratch cannot change the applied policy afterwards. No `setsid`: sandbox-
    exec does not start a new session, so the child stays in setup's process group (BlueBeaver's contract).

    `command` must be a non-empty list of strings. Reads are the curated system allowlist plus the throwaway
    scratch and the caller's `ro_paths`; every caller-owned path is a named ``-D`` binding.
    """
    scratch_norm = dparams(scratchpad=scratch)[SCRATCHPAD_PARAM]  # validate canonical non-root scratch
    if not isinstance(command, (list, tuple)) or not command or not all(isinstance(c, str) for c in command):
        raise ValueError("command must be a non-empty list of strings")
    read_paths = _resolved_read_paths((scratch_norm, *tuple(ro_paths)))
    bindings = read_bindings(read_paths)

    profile_path = os.path.join(scratch_norm, f"{_SETUP_PROFILE_PREFIX}{secrets.token_hex(8)}.sb")
    with open(profile_path, "w", encoding="utf-8") as f:
        f.write(render_setup_profile(loopback_port=loopback_port, read_paths=read_paths))
    try:
        yield ["/usr/bin/sandbox-exec", "-f", profile_path, "-D", f"{SCRATCHPAD_PARAM}={scratch_norm}",
               *_binding_argv(bindings), *command]
    finally:
        base = os.path.basename(profile_path)  # guarded delete: only our per-run file, under the validated scratch
        if os.path.dirname(profile_path) == scratch_norm and base.startswith(_SETUP_PROFILE_PREFIX) and base.endswith(".sb"):
            try:
                os.unlink(profile_path)
            except OSError:
                pass


def _sb():
    """Import the shared `sandbox` module lazily, so `render_profile`/`render_setup_profile`/`dparams` stay
    importable as a standalone file (the Mac gate scp's just this module, with no `zb_agent_host` package).
    Only the `MacSeatbeltBackend` capability methods — which return the shared `sandbox` value types — pay it."""
    from zb_agent_host import sandbox
    return sandbox


def _materialize_profile(profile_text):
    """Write ``profile_text`` to a UNIQUE, exclusively-created, read-only file in its OWN 0700 directory,
    OUTSIDE the published immutable dist (never ``current/runtime``), and return its path.

    Security (RoseCat 6972): the published dist is never written; every launch gets its own path (two live
    LaunchSpecs can never alias one profile / one session's port); and the file is tamper/symlink-resistant —
    created with ``O_CREAT|O_EXCL|O_NOFOLLOW`` in a fresh 0700 dir, made ``0400`` read-only, then VERIFIED
    through the fd (`fstat`: a regular file, mode 0400, exact size). The caller owns the directory's lifetime:
    remove it after the spawn has consumed the profile.
    """
    data = profile_text.encode("utf-8")
    d = tempfile.mkdtemp(prefix=_PROFILE_DIR_PREFIX)  # mode 0700, unique per launch
    try:
        path = os.path.join(d, "agent-cli.sb")
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        try:
            if os.write(fd, data) != len(data):
                raise OSError("short write materializing the Seatbelt profile")
            os.fchmod(fd, 0o400)
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or stat.S_IMODE(st.st_mode) != 0o400 or st.st_size != len(data):
                raise OSError("Seatbelt profile failed its post-write fd check (mode/size/type)")
        finally:
            os.close(fd)
    except BaseException:
        # Any failure (open/write/chmod/fstat) leaves NO directory or partial artifact behind (RoseCat 6984).
        _remove_profile_dir(d)
        raise
    return path


_PROFILE_DIR_PREFIX = "zb-seatbelt-"


def _remove_profile_dir(d):
    """Guarded removal of a profile's OWN temp dir: only a `zb-seatbelt-*` directory directly under the
    system temp dir is ever removed (never an empty/parent/foreign path — feedback_guard_delete_paths)."""
    if (d and os.path.basename(d).startswith(_PROFILE_DIR_PREFIX)
            and os.path.dirname(d) == tempfile.gettempdir()):  # exactly where mkdtemp placed it
        shutil.rmtree(d, ignore_errors=True)


class Curation(enum.Enum):
    """Whether every release capability, including process-exec, has completed its acceptance gate."""
    BROAD = "broad"
    CURATED = "curated"


# The ONE readiness source for the macOS profile (plan R29-MS6 D2, bd zigBrowser-4pa.66). Only the reviewed MS6
# acceptance commit flips it, after the curated renderers and src/seatbelt_gate.zig's accepted_commit agree;
# tests/agent_seatbelt_readiness_invariant_test.zig fails if any one of the three moves alone.
PROFILE_CURATION = Curation.BROAD


def LAUNCH_SPEC_CONSUMABLE():  # noqa: N802 - the plan's name; a function, so it is never an independent flag
    """Whether the macOS LaunchSpec is production-consumable (RoseCat 6972 #3). While the profile grants broad
    file-read* and a blanket mach-lookup, LaunchSpec.mounts cannot be the truthful per-path filesystem contract, so
    the platform dispatch must not wire it. Derived from PROFILE_CURATION, never set on its own."""
    return PROFILE_CURATION is Curation.CURATED


UNSANDBOXED_DEV_STATUS = "agent running unsandboxed (dev build)"


class MacUnsandboxedDevBackend:
    """Explicitly requested macOS development realization of the shared launch contract.

    This backend deliberately contributes no command prefix: the helper runs directly on the host. Production must
    never select it implicitly; ``launch.main`` reaches it only after parsing ``--unsandboxed-dev``. It keeps the
    network, lifetime and token-channel values shaped like the Seatbelt backend. Linux-only realization inputs still
    fail closed.
    """

    SANDBOX_PROGRAM = None

    def __init__(self, egress_port, *, explicit_dev):
        if explicit_dev is not True:
            raise ValueError("the unsandboxed macOS backend requires the explicit development flag")
        self._capabilities = MacSeatbeltBackend(egress_port)

    def network(self, session=None):
        return self._capabilities.network(session)

    def login_network(self):
        return self._capabilities.login_network()

    def lifetime(self):
        return self._capabilities.lifetime()

    def channel(self):
        return self._capabilities.channel()

    def launch_spec(self, home, *, seccomp_fd=None, ro_paths=(), state_dirs=None, claude_writable=False,
                    net_dir=None, network=None):
        sb = _sb()
        state_dirs = () if state_dirs is None else state_dirs
        if seccomp_fd is not None:
            raise sb.UnsupportedLaunchInput("macOS has no seccomp: seccomp_fd must be None")
        if net_dir is not None:
            raise sb.UnsupportedLaunchInput("macOS reaches netd by port, not a socket dir: net_dir must be None")
        if claude_writable:
            raise sb.UnsupportedLaunchInput("macOS cannot grant all of .claude writable")
        if state_dirs:
            raise sb.UnsupportedLaunchInput("macOS grants no state directories yet")
        tuple(ro_paths)
        net = network if network is not None else self.network()
        return sb.LaunchSpec(argv=(), unshare=(), mounts=(), workdir=str(home.workspace), seccomp_fd=None,
                             network=net, lifetime=self.lifetime(), channel=self.channel())

    @contextlib.contextmanager
    def launch(self, home, *, seccomp_fd=None, ro_paths=(), state_dirs=None, claude_writable=False,
               net_dir=None, network=None):
        yield self.launch_spec(home, seccomp_fd=seccomp_fd, ro_paths=ro_paths, state_dirs=state_dirs,
                               claude_writable=claude_writable, net_dir=net_dir, network=network)


class MacSeatbeltBackend:
    """macOS Seatbelt realization of the MS0 ``SandboxBackend`` seam (MS6).

    This is the drawer launch's production default. ``launch_spec`` builds the ``sandbox-exec`` prefix from
    :func:`render_profile`/:func:`dparams` plus the semantic ``LaunchSpec`` (mounts as Seatbelt rules and the
    network/lifetime/channel fields). PROFILE_CURATION records release readiness; it does not disable Seatbelt.

    ``egress_port`` is the OS-selected, per-session loopback port netd listens on (the ephemeral host-loopback
    proxy; plan :1575-1581); the CLI/helper reach ``127.0.0.1:<egress_port>`` and the two canonical bridges, a
    hook the bridges only.
    """

    SANDBOX_PROGRAM = "/usr/bin/sandbox-exec"

    def __init__(self, egress_port):
        self._egress_port = _validate_port(egress_port)
        self._session_canary = None
        self._session_canaries = set()

    @property
    def session_canary(self):
        """The current launch's exact identity path, populated by ``launch_spec`` before spawn."""
        return self._session_canary

    def release_session_canary(self, path=None):
        targets = tuple(self._session_canaries) if path is None else (path,)
        removed = False
        for target in targets:
            removed = remove_session_canary(target) or removed
            self._session_canaries.discard(target)
        if path is None or self._session_canary == path:
            self._session_canary = None
        return removed

    def network(self, session=None):
        """The whole macOS network capability as one immutable ``sandbox.Network`` — the single source the
        egress endpoint, the allowlist and the bridge policy project from. The egress is the ephemeral
        host-loopback ``127.0.0.1:<egress_port>``; the allowlist is the backend-owned ``EGRESS_ALLOW``; there
        is NO relay socket dir (macOS reaches the host-loopback proxy directly), so ``dir`` is None."""
        sb = _sb()
        return sb.Network(
            egress=sb.Egress(sb.Endpoint(_LOOPBACK_HOST, self._egress_port), sb.EGRESS_ALLOW, None),
            bridges=self.bridge_policy(),
        )

    def login_network(self):
        """The one-shot sign-in's network: the same egress endpoint, the login allowlist, and no bridges
        (setup-token runs no hooks)."""
        sb = _sb()
        base = self.network()
        return sb.Network(egress=base.egress._replace(allow=sb.LOGIN_EGRESS_ALLOW),
                          bridges=sb.BridgePolicy(ports=(), hooks_get_egress=False))

    def egress_endpoint(self, session=None):
        return self.network(session).egress.endpoint

    def egress_dir(self):
        return self.network().egress.dir  # None on macOS (no relay socket dir)

    def bridge_policy(self):
        return _sb().BridgePolicy(ports=CANONICAL_BRIDGES, hooks_get_egress=False)

    def hook_launch_spec(self):
        # macOS has no mounted bridges directory (Linux binds /run/zb-net/bridges); the hook's own Seatbelt
        # profile permits the loopback bridge ports directly, so bridges_dir is None. Bridges only, no egress.
        return _sb().HookNetwork(bridges_dir=None, ports=CANONICAL_BRIDGES, egress=None)

    def lifetime(self):
        # Die with the browser by SIGKILL, with the parent re-check, no extra delay — the same meaning as
        # Linux; the native macOS realization is BlueBeaver's posix_spawn group + kqueue NOTE_EXIT parent watch.
        return _sb().Lifetime(die_with_parent=True, signal=signal.SIGKILL, check_parent_race=True, delay_ms=0)

    def channel(self):
        # The CLI's fd-3 token contract is cross-platform; macOS writes the token to fd 3 via zb_mac_token_to_fd.
        return _sb().Channel(fd=3, env="CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR")

    def launch_spec(self, home, *, seccomp_fd=None, ro_paths=(), state_dirs=None, claude_writable=False,
                    net_dir=None, network=None):
        """The CLI/helper launch as a ``sandbox-exec`` prefix + the semantic ``LaunchSpec`` (MS0 rev 6).

        Unlike the Linux bwrap argv, the macOS argv runs the command under a generated Seatbelt profile:
        ``/usr/bin/sandbox-exec -f <profile> -D SCRATCHPAD=<scratch>`` (the caller appends the command;
        sandbox-exec takes it directly, no ``--``). ``<profile>`` is :func:`render_profile`'s CLI output
        written by :func:`_materialize_profile` to a UNIQUE read-only file in its own 0700 temp dir (never the
        published ``current/runtime``); production goes through the :meth:`launch` LEASE, which owns that dir
        and removes it after the spawn. The scratchpad is bound as the literal ``-D`` value
        (never interpolated into source). The semantic fields state the backend-neutral meaning: macOS has no
        namespaces (``unshare=()`` — Seatbelt is the isolation), ``network``/``lifetime``/``channel`` are this
        backend's, and ``mounts`` records the enforced read grants plus the writable scratchpad. The Linux-only kwargs
        (``seccomp_fd``, ``net_dir``, ``claude_writable=True`` and a nonempty ``state_dirs``) cannot be honoured
        here and raise ``sandbox.UnsupportedLaunchInput`` before any profile exists (bd 4pa.22). ``ro_paths`` and
        the fixed agent-home inputs are the profile's only caller-owned read capabilities.
        """
        sb = _sb()
        state_dirs = () if state_dirs is None else state_dirs  # None: this backend's default
        if seccomp_fd is not None:
            raise sb.UnsupportedLaunchInput("macOS has no seccomp: seccomp_fd must be None")
        if net_dir is not None:
            raise sb.UnsupportedLaunchInput("macOS reaches netd by port, not a socket dir: net_dir must be None")
        if claude_writable:
            raise sb.UnsupportedLaunchInput("macOS cannot grant all of .claude writable")
        if state_dirs:
            raise sb.UnsupportedLaunchInput("macOS grants no state directories yet")
        net = network if network is not None else self.network()
        scratch = dparams(scratchpad=str(home.scratchpad))[SCRATCHPAD_PARAM]  # validated canonical non-root
        read_paths = _launch_read_paths(home, ro_paths)
        bindings = read_bindings(read_paths)
        canary = _materialize_session_canary()
        self._session_canary = canary
        self._session_canaries.add(canary)
        # Materialize the per-launch profile SECURELY (O_EXCL + 0400 + fd check) in its own 0700 dir OUTSIDE
        # the published dist — never current/runtime, never a shared/reused path (RoseCat 6972 #1/#2). The
        # login network carries no bridges, which selects the egress-only sign-in profile.
        is_login = not net.bridges.ports
        try:
            profile_path = _materialize_profile(render_profile(
                egress=net.egress.endpoint, bridges=net.bridges.ports, is_hook=False, is_login=is_login,
                read_paths=read_paths, session_canary=canary))
        except BaseException:
            self.release_session_canary(canary)
            raise
        argv = ("/usr/bin/sandbox-exec", "-f", profile_path, "-D", f"{SCRATCHPAD_PARAM}={scratch}",
                "-D", f"{SESSION_CANARY_PARAM}={canary}", *_binding_argv(bindings))
        mounts = [sb.Mount(source=scratch, target=scratch, writable=True)]
        mounts.extend(sb.Mount(source=path, target=path, writable=False)
                      for path in read_paths if path != scratch)
        return sb.LaunchSpec(argv=argv, unshare=(), mounts=tuple(mounts), workdir=str(home.workspace),
                             seccomp_fd=None, network=net, lifetime=self.lifetime(), channel=self.channel())

    def login_launch_spec(self, home, *, seccomp_fd=None, ro_paths=(), net_dir=None):
        """The one-shot sign-in's launch: :meth:`launch_spec` carrying :meth:`login_network` (egress only, no
        bridges), which renders the egress-only sign-in profile. Production uses :meth:`launch` (the lease)."""
        return self.launch_spec(home, seccomp_fd=seccomp_fd, ro_paths=ro_paths, net_dir=net_dir,
                                network=self.login_network())

    @contextlib.contextmanager
    def launch(self, home, *, seccomp_fd=None, ro_paths=(), state_dirs=None, claude_writable=False, net_dir=None,
               network=None):
        """The production launch LEASE (RoseCat 6984): yields the :class:`sandbox.LaunchSpec` and OWNS the
        materialized profile's 0700 temp directory, GUARD-removing it after the caller has spawned (so the
        spawn has consumed the ``-f`` profile). A bare :meth:`launch_spec`/:meth:`login_launch_spec` leaves
        the dir for the caller; the production chain goes through this lease so nothing leaks. Pass
        ``network=login_network()`` for the sign-in.
        """
        spec = self.launch_spec(home, seccomp_fd=seccomp_fd, ro_paths=ro_paths, state_dirs=state_dirs,
                                claude_writable=claude_writable, net_dir=net_dir, network=network)
        try:
            yield spec
        finally:
            _remove_profile_dir(os.path.dirname(spec.argv[2]))
