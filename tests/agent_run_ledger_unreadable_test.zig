//! MS6.5.1 red (RoseCat d3b31cb #1/#2, afe3920). The owner-liveness probe must keep ABSENCE distinct from
//! UNREADABILITY: only a proved-absent process (open ENOENT/ESRCH) is dead; a permission/read/truncation/parse
//! failure is `.unreadable` and must FAIL CLOSED (recoveryFor -> .fail_closed), never recover. The afe3920 green
//! mapped every read/parse failure to `.dead` (fail OPEN), and the registered test never exercised `.unreadable`
//! (RoseCat's decisive mutant: `.unreadable => .recover` left it green). This drives the pure, injectable
//! classifier/parser so those paths are tested without a crafted /proc. UNREGISTERED until green.
//!
//! The mutants this catches: (1) livenessFromRead(.unreadable) => .dead (unreadable treated as absent);
//! (2) recoveryFor(.unreadable) => .recover (unreadable not failing closed).
const std = @import("std");
const ledger = @import("agent_run_ledger");

test "absence is dead->recover; unreadable fails closed and is never dead or recover" {
    // A proved-absent process is dead, which is the only liveness that becomes recovery work.
    try std.testing.expectEqual(ledger.Liveness.dead, ledger.livenessFromRead(.absent, 12345));
    try std.testing.expectEqual(ledger.Recovery.recover, ledger.recoveryFor(ledger.livenessFromRead(.absent, 12345)));

    // An UNREADABLE read must be `.unreadable` (NOT `.dead`) and must fail closed (NOT recover). This is the
    // exact afe3920 fail-open (read/parse failure -> dead) and the uncovered recoveryFor(.unreadable) mutant.
    try std.testing.expectEqual(ledger.Liveness.unreadable, ledger.livenessFromRead(.unreadable, 12345));
    try std.testing.expectEqual(ledger.Recovery.fail_closed, ledger.recoveryFor(ledger.livenessFromRead(.unreadable, 12345)));

    // A readable-but-unparseable stat yields no ticks -> readStart maps it to `.unreadable` (fail closed), not dead.
    try std.testing.expectEqual(@as(?u64, null), ledger.parseStartTicks("1 (bad-no-fields)"));
    try std.testing.expectEqual(@as(?u64, null), ledger.parseStartTicks("totally malformed, no close paren"));

    // A well-formed stat line parses field 22 after the LAST ')'; comm may contain spaces and ')'.
    const sample = "1234 (we)ird name) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 987654 0 0";
    try std.testing.expectEqual(@as(?u64, 987654), ledger.parseStartTicks(sample));

    // Identity: same start -> live_same (leave); different start (PID reuse) -> live_reused (fail closed).
    try std.testing.expectEqual(ledger.Liveness.live_same, ledger.livenessFromRead(.{ .ticks = 987654 }, 987654));
    try std.testing.expectEqual(ledger.Recovery.leave, ledger.recoveryFor(ledger.livenessFromRead(.{ .ticks = 987654 }, 987654)));
    try std.testing.expectEqual(ledger.Liveness.live_reused, ledger.livenessFromRead(.{ .ticks = 987655 }, 987654));
    try std.testing.expectEqual(ledger.Recovery.fail_closed, ledger.recoveryFor(ledger.livenessFromRead(.{ .ticks = 987655 }, 987654)));
}
