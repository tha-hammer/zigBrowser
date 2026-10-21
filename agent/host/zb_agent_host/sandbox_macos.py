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

_LOOPBACK_HOSTS = ("127.0.0.1", "localhost")
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
    if host not in _LOOPBACK_HOSTS:
        raise ValueError(f"endpoint host must be loopback {_LOOPBACK_HOSTS}, got {host!r}")
    return host


def _endpoints(egress, bridges, is_hook):
    """The validated, de-duplicated loopback endpoints this profile may reach, as 'host:port' strings.

    Raises ValueError on an empty or malformed capability (never widens to all-outbound).
    """
    bridges = tuple(bridges)
    if is_hook and egress is not None:
        raise ValueError("a hook profile must not carry an egress endpoint (rev 16.2 §3c: bridges only)")
    if not is_hook and egress is None:
        raise ValueError("a cli/helper profile must carry an egress endpoint")
    if not bridges:
        raise ValueError("empty bridge policy: a profile must name at least the bridge ports (no blanket allow)")

    eps = []
    seen = set()

    def add(host, port):
        host = _validate_host(host)
        port = _validate_port(port)
        key = (host, port)
        if key in seen:
            raise ValueError(f"duplicate endpoint {host}:{port}")
        seen.add(key)
        eps.append(f"{host}:{port}")

    if not is_hook:
        # egress is an object with .host/.port (sandbox.Endpoint); validated above.
        add(getattr(egress, "host"), getattr(egress, "port"))
    for port in bridges:
        add("127.0.0.1", port)  # the backend's bridges are loopback by contract
    return eps


def render_profile(*, egress, bridges, is_hook):
    """Return the Seatbelt profile text for a CLI/helper (``is_hook=False``) or a hook (``is_hook=True``).

    ``egress`` is a :class:`sandbox.Endpoint` (or None for a hook); ``bridges`` is the tuple of loopback
    bridge ports. Raises ``ValueError`` on an empty or malformed network capability. The writable scratchpad
    is NOT an argument — it is bound at launch as the ``SCRATCHPAD`` ``-D`` parameter, so no path is ever
    interpolated into the source.
    """
    eps = _endpoints(egress, bridges, is_hook)
    net = " ".join(f'(remote ip "{e}")' for e in eps)

    first_k, first_v = _SYSCTL_ALLOW[0]
    sysctl_lines = [f'(allow sysctl-read ({first_k} "{first_v}")']
    for k, v in _SYSCTL_ALLOW[1:]:
        sysctl_lines.append(f'  ({k} "{v}")')
    sysctl_lines[-1] += ")"

    devices = " ".join(f'(literal "{d}")' for d in _CHAR_DEVICES)
    kind = "hook" if is_hook else "cli/helper"
    net_note = "bridges only (no egress — rev 16.2 §3c)" if is_hook else "egress + bridges"

    lines = [
        "(version 1)",
        f";; MS6 macOS Seatbelt profile ({kind}) — generated by sandbox_macos.render_profile. Do not hand-edit.",
        ";; The writable path is the SCRATCHPAD -D parameter; no untrusted value is interpolated into source.",
        "(deny default)",
        "(allow process-fork)",
        "(allow process-exec)",
        "(allow file-read*)",  # broad reads (read curation is a later MS6 increment); workspace is readable
        f'(allow file-write* (subpath (param "{SCRATCHPAD_PARAM}")) {devices})',
        f";; network: {net_note}",
        f"(allow network-outbound {net})",
        ";; sysctl-read CURATED (MS6.1): never blanket — a blanket allow re-opens kern.procargs2.",
        *sysctl_lines,
        ";; token isolation (MS6.1): explicit process-info deny; the task port is never granted.",
        "(deny process-info*)",
        "(allow mach-lookup)",  # tiny curated mach-lookup is a separate later MS6 increment
    ]
    return "\n".join(lines) + "\n"


def dparams(*, scratchpad):
    """The validated ``-D`` bindings for a launch. ``scratchpad`` must be a non-empty absolute path (its
    value is bound literally by sandbox-exec, never parsed as profile source, so it cannot inject a rule)."""
    if not isinstance(scratchpad, str) or not scratchpad.startswith("/"):
        raise ValueError(f"SCRATCHPAD must be an absolute path, got {scratchpad!r}")
    return {SCRATCHPAD_PARAM: scratchpad}
