"""MS6.6 (B), R1's production chain on a Mac (plan rev 18, 18.1; RoseCat 7053). NOT WRITTEN YET, deliberately: it
needs the staged pinned runtime and dependency tree (the MS5 decision), so that the real zb_agent_host.setup can be
imported and setup.probe_r1 called directly. Until then it fails, so the harness can never report it met.

To keep, when written (RoseCat 7053): the exact pass_fds (listener + census end), the forged-capability negative,
listener service, the census request and reply, the timeout/lifecycle cases, and the planted-token control, on
both arches, through the real setup.probe_r1 -> sandbox-exec -> route_probe -> wrapper -> a controlled CLI."""
NAME = "ms6.6b-r1-chain"


def run(h):
    h.check(False, "MS6.6 (B) is not written: it waits on the staged pinned tree (MS5 decision)")
