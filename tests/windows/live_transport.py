"""The one transport resolver for the Linux-driven Windows live callers (bd zigBrowser-ong.25, NavyCanyon fb4d56d1).

A host that is not configured ({prefix}_HOST unset or empty) is the caller's own no-host path: resolve() returns None
and nothing is contacted. Once the host is set, every selector is explicit: {prefix}_PORT, {prefix}_USER,
{prefix}_KEY and {prefix}_KNOWN_HOSTS, plus any extra the caller names (win_transport_test's ZB_WIN11_OTHER_USER).
A missing one raises TransportConfigError naming every missing variable, before the caller makes any ssh/scp call.
There is no default, the legacy ZB_WIN_KEY / ZB_WIN_KNOWN_HOSTS are never read, and a Win10 record reads only
ZB_WIN10_* (never a Win11 value).

  live tests:  t = live_transport.for_test(self, "ZB_WIN11")   # a FAILURE naming what is missing, never a skip
  drivers:     except live_transport.TransportConfigError as e: return live_transport.refuse(e)   # rc 2
"""
import os
import sys
from typing import NamedTuple

PREFIXES = ("ZB_WIN11", "ZB_WIN10")
SELECTORS = ("PORT", "USER", "KEY", "KNOWN_HOSTS")
REFUSED_EXIT = 2


class TransportConfigError(Exception):
    """A configured host whose transport selectors are incomplete."""


class Transport(NamedTuple):
    prefix: str
    host: str
    port: str
    user: str
    key: str
    known_hosts: str
    extra: dict


def resolve(prefix: str, env=None, extra: tuple = ()) -> Transport | None:
    """The complete transport record for `prefix`, or None when its host is not configured."""
    if prefix not in PREFIXES:
        raise ValueError(f"unknown transport prefix {prefix!r}")
    if any(not name.startswith(prefix + "_") for name in extra):
        raise ValueError(f"an extra selector of {prefix} must be one of its own variables: {extra!r}")
    env = os.environ if env is None else env
    host = env.get(f"{prefix}_HOST", "")
    if not host:
        return None
    names = [f"{prefix}_{s}" for s in SELECTORS] + list(extra)
    missing = [name for name in names if not env.get(name)]
    if missing:
        raise TransportConfigError(
            f"refused: {prefix}_HOST is set but {' '.join(missing)} {'is' if len(missing) == 1 else 'are'} not; "
            "every transport selector must be explicit (no default, no ZB_WIN_KEY / ZB_WIN_KNOWN_HOSTS)")
    return Transport(prefix, host, env[f"{prefix}_PORT"], env[f"{prefix}_USER"], env[f"{prefix}_KEY"],
                     env[f"{prefix}_KNOWN_HOSTS"], {name: env[name] for name in extra})


def for_test(test, prefix: str, extra: tuple = ()) -> Transport | None:
    """In a live unittest's setUp, after its own no-host check: the record, or a test failure (never a skip)."""
    try:
        return resolve(prefix, extra=extra)
    except TransportConfigError as e:
        test.fail(str(e))


def refuse(err: TransportConfigError) -> int:
    """A driver's exit for an incomplete configuration: the `refused:` line on stderr, rc 2."""
    print(str(err), file=sys.stderr, flush=True)
    return REFUSED_EXIT
