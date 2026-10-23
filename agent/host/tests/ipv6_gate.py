"""The IPv6 precondition of the dual-family reservation tests (test_netd_darwin_v6, test_setup_darwin_r1_v6; bd
zigBrowser-4pa.29, review CR11). Their property is that the [::1]:<port> reservation is held, so a gate host without
IPv6 loopback must FAIL them by name, never skip them to a green run that checked nothing.
"""
import socket


def _bind_v6_loopback() -> None:
    """Bind an IPV6_V6ONLY TCP socket on [::1] (any port), as the reservations do; raises OSError when it cannot."""
    with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as s:
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        s.bind(("::1", 0))


def ipv6_loopback_problem():
    """None when this host can take a [::1] reservation; else why it cannot (read at call time)."""
    if not socket.has_ipv6:
        return "this Python has no IPv6 support (socket.has_ipv6 is False)"
    try:
        _bind_v6_loopback()
    except OSError as exc:
        return f"[::1] cannot be bound on this host: {exc}"
    return None


def require_ipv6_loopback(what: str) -> None:
    """For setUpClass: raise a named AssertionError (an ERROR in the run, never a skip) when IPv6 loopback is absent."""
    problem = ipv6_loopback_problem()
    if problem:
        raise AssertionError(f"IPV6_MISSING: {what} needs IPv6 loopback on this gate host: {problem}")
