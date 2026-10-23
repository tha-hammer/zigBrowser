"""Fail-safe fake transport for the hostless Windows selftests (WS0.8 a11a2d8; zigBrowser-ong.17).

The fake ssh/scp first on PATH are the only thing between a hostless selftest and a real Windows host, so every
fake case aims at TEST-NET addresses (RFC 5737, never routed) with key and known_hosts paths that do not exist.
A case that needs a driver's built-in key default (the REAL key) runs inside NETNS, an empty network namespace,
so no packet can leave. problem() is the one check: callers run it on the env before a fake run and on every
ssh/scp argv the fakes logged after it.
"""
import ipaddress
import os

FAKE_WIN11_HOST = "192.0.2.1"        # TEST-NET-1
FAKE_WIN10_HOST = "198.51.100.15"    # TEST-NET-2
TEST_NETS = [ipaddress.ip_network(n) for n in ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")]
NETNS = ["unshare", "--user", "--map-current-user", "--net"]
DEFAULT_KEY = "/home/maceo/vms/win11-m8/zb_win_key"
DEFAULT_KNOWN_HOSTS = "/home/maceo/vms/win11-m8/known_hosts"

# host variable -> the key variables the gate and the build driver read for it, first wins, then DEFAULT_KEY
_KEYS_FOR_HOST = {
    "ZB_WIN11_HOST": ("ZB_WIN11_KEY", "ZB_WIN_KEY"),
    "ZB_WIN10_HOST": ("ZB_WIN10_KEY", "ZB_WIN_KEY"),
}
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


def problem(env, calls, netns=False):
    """None when a fake run cannot reach a real host with a real key, else what is wrong."""
    for var in _HOST_VARS:
        if env.get(var) and not unreachable(env[var]):
            return f"{var}={env[var]!r} is not a TEST-NET address"
    for var, chain in _KEYS_FOR_HOST.items():
        if not env.get(var):
            continue
        key = next((env[k] for k in chain if env.get(k)), DEFAULT_KEY)
        if not netns and _real_key(key):
            return f"{var} resolves to a real key {key!r} outside a network namespace"
    for argv in calls:
        hosts, keys = hosts_and_keys(argv)
        if not hosts or not all(unreachable(h) for h in hosts):
            return f"a transport call targets {hosts!r}: {' '.join(argv)}"
        for k in keys:
            if not netns and _real_key(k):
                return f"a transport call uses a real key {k!r} outside a network namespace"
    return None
