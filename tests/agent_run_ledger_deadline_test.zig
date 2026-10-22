//! MS6.5.1 red (RoseCat e665676 #1). The startup-recovery acquisition must honor ONE absolute monotonic deadline,
//! not try-count arithmetic: it retries ONLY while the clock is before the deadline, and stops AT the deadline.
//! Driven deterministically through an injected fake clock + a counting attempt — fork-free, no /proc, no signals.
//! UNREGISTERED until green.
//!
//! The mutant this catches: a fixed-try-count loop that ignores the clock/deadline (rev 27's exact regression: a
//! ~900ms acquisition "survives" under a loose watchdog). With a clock that jumps PAST the deadline after one
//! sleep, a deadline-honoring loop makes ~2 attempts; a 20-try loop makes 20.
const std = @import("std");
const ledger = @import("agent_run_ledger");

/// A fake monotonic clock: `nowMs` reads a shared counter; `sleepMs` jumps it forward by a large fixed step
/// (simulating real elapsed time) regardless of the requested backoff, so a deadline-honoring loop bails after one
/// sleep while a count-based loop keeps going.
const FakeClock = struct {
    t: *i64,
    step: i64,
    pub fn nowMs(self: FakeClock) i64 {
        return self.t.*;
    }
    pub fn sleepMs(self: FakeClock, ms: i64) void {
        _ = ms;
        self.t.* += self.step;
    }
};

/// An attempt that is always contended and counts how many times it was tried.
const CountingAttempt = struct {
    n: *u32,
    pub fn tryOnce(self: CountingAttempt) ledger.AcquireResult {
        self.n.* += 1;
        return .busy;
    }
};

test "acquisition honors ONE absolute deadline, not a try count" {
    var now: i64 = 0;
    var tries: u32 = 0;
    const clock = FakeClock{ .t = &now, .step = 1000 }; // each sleep jumps 1000ms
    const attempt = CountingAttempt{ .n = &tries };

    // deadline = 100ms. First tryOnce at t=0 (< 100) -> busy -> sleep (t=1000) -> second tryOnce check: t=1000 >=
    // 100 -> fail closed (.busy). A deadline-honoring loop makes exactly 2 attempts; a 20-try loop makes 20.
    const r = ledger.acquireWithinDeadline(clock, 100, 5, attempt);
    try std.testing.expectEqual(ledger.AcquireResult.busy, r);
    try std.testing.expect(tries <= 3); // deadline-bounded; the fixed-count mutant does 20 and fails here
    try std.testing.expect(now >= 100); // it actually consulted the clock and reached the deadline
}

test "acquisition that succeeds before the deadline returns immediately" {
    var now: i64 = 0;
    const clock = FakeClock{ .t = &now, .step = 1000 };
    const OkAttempt = struct {
        pub fn tryOnce(_: @This()) ledger.AcquireResult {
            return .acquired;
        }
    };
    try std.testing.expectEqual(ledger.AcquireResult.acquired, ledger.acquireWithinDeadline(clock, 100, 5, OkAttempt{}));
    try std.testing.expectEqual(@as(i64, 0), now); // no sleep needed -> clock did not advance
}
