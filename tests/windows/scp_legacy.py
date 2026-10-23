"""bd zigBrowser-ong.12: the one way the Windows live harnesses build an scp command.

OpenSSH's scp speaks the SFTP protocol by default, and the Win10 test box's sshd has no sftp subsystem
("subsystem request failed on channel 0"). Every staging and fetch copy therefore uses the legacy scp protocol,
-O, which this helper always puts first, before every option and operand. The fix is in the harness, never in the
host's sshd (orchestrator ruling). Pinned by tests/windows/scp_callers_legacy_test.py and
tests/windows/transport_scp_legacy_test.py (step windows-transport-scp-selftest).
"""


def scp_argv(*args: str) -> list:
    """["scp", "-O", *args]: the options and operands of one copy, over the legacy scp protocol."""
    return ["scp", "-O", *args]
