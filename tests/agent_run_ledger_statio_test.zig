//! MS6.5.1 red (RoseCat 83d3a0f #2, 16cff86). Drives the PRODUCTION read-outcome mapping, not just the pure
//! parser: each lower-level `/proc/<pid>/stat` outcome — a non-absence open error, a read error, an empty/
//! truncated read, or unparseable bytes — must map to `.unreadable` and carry through liveness/recovery to NO
//! recovery (fail closed). ONLY an `open_absent` outcome is `.absent` -> dead -> recover. Pure injected outcomes,
//! no /proc, no signals. UNREGISTERED until green.
//!
//! The decisive mutant (RoseCat): `startReadFromIo`'s parse-null branch -> `.absent` instead of `.unreadable`.
//! With the old test (an already-classified `.unreadable` + `parseStartTicks -> null`) that mutant stayed green;
//! here it fails, because unparseable bytes are carried through the production mapping and required to fail closed.
const std = @import("std");
const ledger = @import("agent_run_ledger");

fn recoveryOf(o: ledger.StatIo) ledger.Recovery {
    return ledger.recoveryFor(ledger.livenessFromRead(ledger.startReadFromIo(o), 987654));
}

test "the read-outcome mapping: only open_absent recovers; every unreadable class fails closed" {
    // ONLY a proved-absent open is absence -> dead -> recover.
    try std.testing.expectEqual(ledger.StartRead.absent, ledger.startReadFromIo(.open_absent));
    try std.testing.expectEqual(ledger.Recovery.recover, recoveryOf(.open_absent));

    // A non-absence open error (permission/IO) -> unreadable -> fail closed (no recovery).
    try std.testing.expectEqual(ledger.StartRead.unreadable, ledger.startReadFromIo(.open_error));
    try std.testing.expectEqual(ledger.Recovery.fail_closed, recoveryOf(.open_error));

    // A read error or an empty/0-byte read -> unreadable -> fail closed.
    try std.testing.expectEqual(ledger.StartRead.unreadable, ledger.startReadFromIo(.read_error));
    try std.testing.expectEqual(ledger.Recovery.fail_closed, recoveryOf(.read_error));

    // Opened + read, but the bytes are unparseable (truncated / wrong shape) -> unreadable -> fail closed. This is
    // the production parse-null branch the decisive mutant flips to `.absent`.
    try std.testing.expectEqual(ledger.StartRead.unreadable, ledger.startReadFromIo(.{ .bytes = "1 (x) S 1 1" }));
    try std.testing.expectEqual(ledger.Recovery.fail_closed, recoveryOf(.{ .bytes = "1 (x) S 1 1" }));
    try std.testing.expectEqual(ledger.StartRead.unreadable, ledger.startReadFromIo(.{ .bytes = "" }));
    try std.testing.expectEqual(ledger.Recovery.fail_closed, recoveryOf(.{ .bytes = "no close paren at all" }));

    // Opened + read + parseable bytes -> the real ticks; identity drives live_same / live_reused.
    const sample = "1234 (we)ird name) S 1 1 1 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 987654 0 0";
    try std.testing.expectEqual(ledger.StartRead{ .ticks = 987654 }, ledger.startReadFromIo(.{ .bytes = sample }));
    try std.testing.expectEqual(ledger.Recovery.leave, recoveryOf(.{ .bytes = sample })); // live_same (start matches)
}
