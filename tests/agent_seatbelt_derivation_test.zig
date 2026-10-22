//! 4pa.66 fix-forward (SilverRidge 1915e0d): `agent_setup.seatbelt_ready` is DERIVED from seatbelt_gate.accepted_commit,
//! shown by compiling the real src/agent_setup.zig against two gate fixtures: a null accepted commit, then a non-null one.
//! A hand-set seatbelt_ready (true or false) agrees with the production null gate, so only the two-state build tells it
//! from the derivation. build.zig copies src/agent_setup.zig and its imports beside each fixture seatbelt_gate.zig.
const std = @import("std");
const unaccepted = @import("agent_setup_unaccepted");
const accepted = @import("agent_setup_accepted");

test "the fixtures are the two states: null, then a named commit" {
    try std.testing.expect(unaccepted.seatbelt_gate.accepted_commit == null);
    try std.testing.expectEqualStrings("fixture-accepted-commit", accepted.seatbelt_gate.accepted_commit.?);
}

test "seatbelt_ready follows accepted_commit: false when null, true when a commit is named" {
    try std.testing.expectEqual(false, unaccepted.seatbelt_ready);
    try std.testing.expectEqual(true, accepted.seatbelt_ready);
}

test "the macOS gate follows the derived readiness: refuse with the fixed line, then run" {
    const refused = unaccepted.platformGate(.macos, unaccepted.seatbelt_ready);
    try std.testing.expect(refused == .refuse);
    try std.testing.expectEqualStrings(unaccepted.macos_unsandboxed_refusal, refused.refuse);
    try std.testing.expect(accepted.platformGate(.macos, accepted.seatbelt_ready) == .run);
}
