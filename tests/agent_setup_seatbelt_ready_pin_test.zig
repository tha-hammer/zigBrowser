//! 4pa.66 (plan R29 C-W7, R30.2 T8): `seatbelt_ready` stays false until the reviewed MS6 acceptance commit, which must
//! edit this file to flip it (so the flip is visible). A constant read: a TRIPWIRE, not proof. The proof is the real
//! macOS binary's `--agent-setup` refusing with the fixed line (tests/mac/ms5_setup_refusal_gate.sh, both Macs) and
//! the readiness invariant (tests/agent_seatbelt_readiness_invariant_test.zig).
const std = @import("std");
const agent_setup = @import("agent_setup");

test "seatbelt_ready is false, so macOS --agent-setup refuses with the fixed line" {
    try std.testing.expect(!agent_setup.seatbelt_ready);
    const gate = agent_setup.platformGate(.macos, agent_setup.seatbelt_ready);
    try std.testing.expect(gate == .refuse);
    try std.testing.expectEqualStrings(agent_setup.macos_unsandboxed_refusal, gate.refuse);
}
