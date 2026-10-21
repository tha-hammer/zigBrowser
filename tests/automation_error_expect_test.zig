//! S8a (chat-drawer plan rev 16.20.38, S8 in detail): -32015 `expectation_mismatch`, the
//! engine's answer when an approved action's expectation (origin, load_serial, account,
//! recipient or the element token) no longer holds inside the real run's ticket. Not
//! retryable: a refused approval needs a new one, never a retry. The new variant is reached
//! by name, so this file compiles before the green and fails.
const std = @import("std");
const automation = @import("automation");

const errors = automation.errors;
const has = @hasField(errors.AutomationError, "expectation_mismatch");

test "expectation_mismatch is -32015, last in the taxonomy, and not retryable" {
    if (!has) return error.TestNoExpectationMismatch;
    const err = @field(errors.AutomationError, "expectation_mismatch");
    try std.testing.expectEqualStrings("expectation_mismatch", errors.name(err));
    try std.testing.expectEqual(@as(i32, -32015), errors.downstreamCode(err));
    try std.testing.expect(!errors.isRetryable(err));
    try std.testing.expectEqual(err, try errors.fromName("expectation_mismatch"));
    try std.testing.expectEqual(@as(usize, 15), errors.error_count);
}

test "the taxonomy's codes now run from -32001 to -32015" {
    if (!has) return error.TestNoExpectationMismatch;
    try std.testing.expect(errors.isAutomationCode(-32015));
    try std.testing.expect(!errors.isAutomationCode(-32016));
    try std.testing.expect(errors.isAutomationCode(-32014));
}
