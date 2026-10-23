"""Fail-safe fake transport for the hostless Windows selftests (WS0.8 a11a2d8; zigBrowser-ong.17).

The fake ssh/scp first on PATH are the only thing between a hostless selftest and a real Windows host, so every
fake case aims at TEST-NET addresses (RFC 5737, never routed) with key and known_hosts paths that do not exist.
problem() is the one check: callers run it on the env before a fake run and on every ssh/scp argv the fakes logged
after it. bd zigBrowser-ong.25: a configured host must carry all of its own explicit selectors (port, user, key,
known_hosts); a default, a legacy ZB_WIN_KEY / ZB_WIN_KNOWN_HOSTS or the other host's values never count, even
inside NETNS (an empty network namespace, still required for any case that names a real key file).
"""
import ipaddress
import os

FAKE_WIN11_HOST = "192.0.2.1"        # TEST-NET-1
FAKE_WIN10_HOST = "198.51.100.15"    # TEST-NET-2
TEST_NETS = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
NETNS = ["unshare", "--user", "--map-current-user", "--net"]
DEFAULT_KEY = "/home/maceo/vms/win11-m8/zb_win_key"
DEFAULT_KNOWN_HOSTS = "/home/maceo/vms/win11-m8/known_hosts"

# host variable -> its prefix; every <prefix>_<selector> must be explicit once the host is set (bd zigBrowser-ong.25)
_PREFIX_FOR_HOST = {"ZB_WIN11_HOST": "ZB_WIN11", "ZB_WIN10_HOST": "ZB_WIN10"}
SELECTORS = ("PORT", "USER", "KEY", "KNOWN_HOSTS")
_HOST_VARS = ("ZB_WIN11_HOST", "ZB_WIN10_HOST", "ZB_WIN10_LISTEN")


def unreachable(host):
    """True only for a TEST-NET address (an optional user@ prefix is ignored)."""
    try:
        return any(ipaddress.ip_address(host.rsplit("@", 1)[-1]) in n for n in TEST_NETS)
    except ValueError:
        return False


def _ip(token):
    try:
        ipaddress.ip_address(token)
        return True
    except ValueError:
        return False


def hosts_and_keys(argv):
    """The hosts (user@host[:path] targets and bare IP literals) and the -i keys of one ssh/scp argv."""
    hosts = [a.split("@", 1)[1].split(":", 1)[0] for a in argv if "@" in a and not a.startswith("-")]
    hosts += [a for a in argv if _ip(a)]
    keys = [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == "-i"]
    return hosts, keys


def _real_key(key):
    return key == DEFAULT_KEY or os.path.exists(key)


def problem(env, calls, netns=False, partial_ok=False):
    """None when a fake run cannot reach a real host with a real key, else what is wrong.

    partial_ok: the case under test IS a partial configuration (a refusal). It is fail-safe only if no ssh/scp call
    was made at all; any logged call under it is itself the problem."""
    partial = False
    for var in _HOST_VARS:
        if env.get(var) and not unreachable(env[var]):
            return f"{var}={env[var]!r} is not a TEST-NET address"
    for var, prefix in _PREFIX_FOR_HOST.items():
        if not env.get(var):
            continue
        missing = [f"{prefix}_{s}" for s in SELECTORS if not env.get(f"{prefix}_{s}")]
        if missing and not partial_ok:
            return (f"{var} is set without an explicit {' '.join(missing)} "
                    "(no default, legacy or other-host selector counts)")
        if missing:
            partial = True
            continue
        key = env[f"{prefix}_KEY"]
        if not netns and _real_key(key):
            return f"{var} resolves to a real key {key!r} outside a network namespace"
    if partial and calls:
        return f"a transport call was made under a partial configuration: {' '.join(calls[0])}"
    for argv in calls:
        hosts, keys = hosts_and_keys(argv)
        if not hosts or not all(unreachable(h) for h in hosts):
            return f"a transport call targets {hosts!r}: {' '.join(argv)}"
        for k in keys:
            if not netns and _real_key(k):
                return f"a transport call uses a real key {k!r} outside a network namespace"
    return None
