"""macOS Seatbelt backend (MS6) — the profile generator.

`render_profile` emits the Seatbelt (.sb) text a `MacSeatbeltBackend` launch runs under
`/usr/bin/sandbox-exec -f <profile> -D SCRATCHPAD=<path>`. It realizes, in profile form, the same semantic
launch contract the Linux `LinuxBwrapBackend` realizes as a bwrap argv (MS0 `SandboxBackend`): deny-default,
a read-only workspace with a writable scratchpad, and the backend's network capability (the egress endpoint
for the CLI/helper, the two bridge ports, and hooks reaching the bridges only).

Security construction (RoseCat 6918; plan:1562-1566 "profile file + -D params, not inline"):
  * NO untrusted value is interpolated into the profile source. The writable path is a NAMED `-D` parameter
    `(subpath (param "SCRATCHPAD"))`; sandbox-exec binds the `-D` value as a literal (not re-parsed as
    profile source), so a path containing a quote/newline/paren cannot add a rule. The workspace is not
    referenced in the profile at all (broad reads cover it; it is simply absent from every write rule, so a
    write fails closed under deny-default).
  * The only values placed in the source are the loopback endpoints, and they are VALIDATED first: the host
    must be a loopback literal and each port a plain integer 1..65535 — a validated integer is a proven, non-
    injectable encoding (it is digits), which is why a Seatbelt network filter, which takes no `-D` param,
    can carry it safely.
  * An empty/invalid network capability is REFUSED, never widened: `(allow network-outbound )` with no
    endpoint is the dangerous shape Seatbelt reads as "all outbound", so render_profile raises instead.

The token-isolation recipe was measured against the real kernel on both arches in the MS6.1 Mac gate: an
EXPLICIT `(deny process-info*)` AND a CURATED `sysctl-read` (a blanket allow re-opens kern.procargs2); the
task port is never granted. Reads stay broad and mach-lookup blanket here — the deny-default read curation
and the tiny curated mach-lookup are a separate later MS6 increment (do not wire this renderer until they
land). Pure stdlib, so it unit-tests on Linux; the eventual both-Mac `sandbox-exec` gate still applies.
"""

import contextlib
import os
import secrets
import shutil
import signal
import stat
import tempfile

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

    NOTE on the host token: Seatbelt's ``(remote ip ...)`` accepts ONLY ``*`` or ``localhost`` as the host —
    the IP literal ``127.0.0.1`` is a parse error (measured on both arches). So the INPUT capability is
    validated as exactly ``127.0.0.1`` (rejecting names/other IPs), and the emitted rule uses Seatbelt's
    ``localhost`` loopback token with the validated port. (``localhost`` is the loopback; the listeners are on
    127.0.0.1, and Seatbelt offers no finer host control.)
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


def render_profile(*, egress, bridges, is_hook, is_login=False):
    """Return the Seatbelt profile text for a CLI/helper (``is_hook=False``), a hook (``is_hook=True``), or the
    one-shot sign-in (``is_login=True``: egress endpoint only, no bridges).

    ``egress`` is a :class:`sandbox.Endpoint` (or None for a hook); ``bridges`` is the tuple of loopback
    bridge ports (empty for login). Raises ``ValueError`` on an empty or malformed network capability. The
    writable scratchpad is NOT an argument — it is bound at launch as the ``SCRATCHPAD`` ``-D`` parameter, so
    no path is ever interpolated into the source.
    """
    eps = _endpoints(egress, bridges, is_hook, is_login)
    net = " ".join(f'(remote ip "{e}")' for e in eps)
    kind = "login" if is_login else ("hook" if is_hook else "cli/helper")
    net_note = ("egress only (sign-in; no bridges)" if is_login
                else "bridges only (no egress — rev 16.2 §3c)" if is_hook else "egress + bridges")

    lines = [
        "(version 1)",
        f";; MS6 macOS Seatbelt profile ({kind}) — generated by sandbox_macos.render_profile. Do not hand-edit.",
        ";; The writable path is the SCRATCHPAD -D parameter; no untrusted value is interpolated into source.",
        "(deny default)",
        "(allow process-fork)",
        "(allow process-exec)",
        "(allow file-read*)",  # broad reads (read curation is a later MS6 increment); workspace is readable
        _file_write_line(),
        f";; network: {net_note}",
        f"(allow network-outbound {net})",
        ";; sysctl-read CURATED (MS6.1): never blanket — a blanket allow re-opens kern.procargs2.",
        *_sysctl_block(),
        ";; token isolation (MS6.1): explicit process-info deny; the task port is never granted.",
        "(deny process-info*)",
        "(allow mach-lookup)",  # tiny curated mach-lookup is a separate later MS6 increment
    ]
    return "\n".join(lines) + "\n"


def render_setup_profile():
    """Return the Seatbelt profile text for setup's OWN runs (`cli --version`, the R1 probe).

    It is a DISTINCT profile from the CLI/helper's: setup has **no network at all**, so there is NO
    `(allow network-outbound)` form — deny-default denies every outbound connect (BlueBeaver's contract:
    "only its own loopback"). Otherwise it matches: scratch writable via the `SCRATCHPAD` `-D` param, broad
    reads (the deny-default read curation to `ro_paths`+system is the same later MS6 increment), and the
    token-isolation belt (explicit `(deny process-info*)` + curated sysctl). No value is interpolated.
    """
    lines = [
        "(version 1)",
        ";; MS6 macOS Seatbelt profile (setup) — generated by sandbox_macos.render_setup_profile. No network.",
        ";; The writable path is the SCRATCHPAD -D parameter; no untrusted value is interpolated into source.",
        "(deny default)",
        "(allow process-fork)",
        "(allow process-exec)",
        "(allow file-read*)",  # broad reads (read curation to ro_paths+system is a later MS6 increment)
        _file_write_line(),
        ";; network: NONE — deny-default denies all outbound (setup reaches only its own loopback).",
        ";; sysctl-read CURATED (MS6.1): never blanket — a blanket allow re-opens kern.procargs2.",
        *_sysctl_block(),
        ";; token isolation (MS6.1): explicit process-info deny; the task port is never granted.",
        "(deny process-info*)",
        "(allow mach-lookup)",  # tiny curated mach-lookup is a separate later MS6 increment
    ]
    return "\n".join(lines) + "\n"


def dparams(*, scratchpad):
    """The validated ``-D`` bindings for a launch. ``scratchpad`` must be a **canonical, non-root absolute
    path**: bound to ``(subpath (param "SCRATCHPAD"))`` it is the only write grant, so the filesystem root
    or an alias that resolves to it (``/``, ``/tmp/..``, ``/a/../b``, trailing/double slashes) must be
    refused — otherwise the sole write grant widens (RoseCat 6939 #1). The value is bound literally by
    sandbox-exec (never parsed as profile source), so it cannot inject a rule. The backend's launch_spec
    binds the exact ``home.scratchpad`` here, which is the stronger check at the call site."""
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
    return {SCRATCHPAD_PARAM: norm}


_SETUP_PROFILE_PREFIX = ".zb-setup-sandbox-"


@contextlib.contextmanager
def setup_sandbox(scratch, ro_paths, command):
    """Yield the ``sandbox-exec`` argv for one of setup's OWN runs (`cli --version`, the R1 probe), under
    `render_setup_profile` (no network). Setup's throwaway home is the writable scratch.

    File-lifetime (chosen 2026-10-21, orchestrator; BlueBeaver may object by mail): a PER-RUN profile file is
    written under `scratch` and **guard-deleted** here on exit — a context manager, rather than a plain argv-
    returning function, so cleanup is guaranteed. The profile's policy is locked in by sandbox-exec at exec
    time, so a command writing to scratch cannot change the applied policy afterwards. No `setsid`: sandbox-
    exec does not start a new session, so the child stays in setup's process group (BlueBeaver's contract).

    `command` must be a non-empty list of strings. `ro_paths` is accepted for the contract but not yet used
    (reads are broad this increment; the deny-default read curation to ro_paths+system is the later increment).
    """
    scratch_norm = dparams(scratchpad=scratch)[SCRATCHPAD_PARAM]  # validate canonical non-root scratch
    if not isinstance(command, (list, tuple)) or not command or not all(isinstance(c, str) for c in command):
        raise ValueError("command must be a non-empty list of strings")
    tuple(ro_paths)  # accepted; reserved for the read-curation increment

    profile_path = os.path.join(scratch_norm, f"{_SETUP_PROFILE_PREFIX}{secrets.token_hex(8)}.sb")
    with open(profile_path, "w", encoding="utf-8") as f:
        f.write(render_setup_profile())
    try:
        yield ["/usr/bin/sandbox-exec", "-f", profile_path, "-D", f"{SCRATCHPAD_PARAM}={scratch_norm}", *command]
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


# The macOS LaunchSpec is NOT production-consumable yet (RoseCat 6972 #3): the profile grants broad file-read*
# and a blanket mach-lookup, so LaunchSpec.mounts cannot be the truthful per-path filesystem contract. The
# platform dispatch must not wire this until the deny-default read / tiny mach-lookup curation lands and this
# flag is flipped (together with per-path read mounts).
LAUNCH_SPEC_CONSUMABLE = False


class MacSeatbeltBackend:
    """macOS Seatbelt realization of the MS0 ``SandboxBackend`` seam (MS6).

    First increment: the network / lifetime / channel capability surface, stating the SAME contract values as
    :class:`sandbox.LinuxBwrapBackend` in macOS terms. ``launch_spec`` — the ``sandbox-exec`` prefix built from
    :func:`render_profile`/:func:`dparams` plus the semantic ``LaunchSpec`` (mounts as Seatbelt rules, the
    network/lifetime/channel fields) — is a following increment.

    ``egress_port`` is the OS-selected, per-session loopback port netd listens on (the ephemeral host-loopback
    proxy; plan :1575-1581); the CLI/helper reach ``127.0.0.1:<egress_port>`` and the two canonical bridges, a
    hook the bridges only.
    """

    def __init__(self, egress_port):
        self._egress_port = _validate_port(egress_port)

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

    def launch_spec(self, home, *, seccomp_fd=None, ro_paths=(), state_dirs=(), claude_writable=False,
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
        backend's, and ``mounts`` is the enforced write-grant contract (the scratchpad). The Linux-only kwargs
        (``seccomp_fd``, ``state_dirs``, ``claude_writable``, ``net_dir``, ``ro_paths``) are accepted for the
        Protocol and not used here; per-path read mounts (``ro_paths``/``state_dirs``) arrive with the
        deny-default read-curation increment.
        """
        sb = _sb()
        net = network if network is not None else self.network()
        scratch = dparams(scratchpad=str(home.scratchpad))[SCRATCHPAD_PARAM]  # validated canonical non-root
        # Materialize the per-launch profile SECURELY (O_EXCL + 0400 + fd check) in its own 0700 dir OUTSIDE
        # the published dist — never current/runtime, never a shared/reused path (RoseCat 6972 #1/#2). The
        # login network carries no bridges, which selects the egress-only sign-in profile.
        is_login = not net.bridges.ports
        profile_path = _materialize_profile(render_profile(
            egress=net.egress.endpoint, bridges=net.bridges.ports, is_hook=False, is_login=is_login))
        argv = ("/usr/bin/sandbox-exec", "-f", profile_path, "-D", f"{SCRATCHPAD_PARAM}={scratch}")
        mounts = (sb.Mount(source=scratch, target=scratch, writable=True),)
        return sb.LaunchSpec(argv=argv, unshare=(), mounts=mounts, workdir=str(home.workspace),
                             seccomp_fd=None, network=net, lifetime=self.lifetime(), channel=self.channel())

    def login_launch_spec(self, home, *, seccomp_fd=None, ro_paths=(), net_dir=None):
        """The one-shot sign-in's launch: :meth:`launch_spec` carrying :meth:`login_network` (egress only, no
        bridges), which renders the egress-only sign-in profile. Production uses :meth:`launch` (the lease)."""
        return self.launch_spec(home, seccomp_fd=seccomp_fd, ro_paths=ro_paths, net_dir=net_dir,
                                network=self.login_network())

    @contextlib.contextmanager
    def launch(self, home, *, seccomp_fd=None, ro_paths=(), net_dir=None, network=None):
        """The production launch LEASE (RoseCat 6984): yields the :class:`sandbox.LaunchSpec` and OWNS the
        materialized profile's 0700 temp directory, GUARD-removing it after the caller has spawned (so the
        spawn has consumed the ``-f`` profile). A bare :meth:`launch_spec`/:meth:`login_launch_spec` leaves
        the dir for the caller; the production chain goes through this lease so nothing leaks. Pass
        ``network=login_network()`` for the sign-in.
        """
        spec = self.launch_spec(home, seccomp_fd=seccomp_fd, ro_paths=ro_paths, net_dir=net_dir, network=network)
        try:
            yield spec
        finally:
            _remove_profile_dir(os.path.dirname(spec.argv[2]))
