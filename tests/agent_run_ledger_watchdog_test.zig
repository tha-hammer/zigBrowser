//! MS6.5.1 red (RoseCat e665676 #3 / 2de82c4). The recovery-busy watchdog must be bounded by an ABSOLUTE monotonic
//! deadline even under an EINTR storm: a run of EINTR interruptions can never keep it alive past the deadline.
//! Driven deterministically through an injected fake clock + a fake poll — no real poll, no fork, no signals.
//! UNREGISTERED until green.
//!
//! The mutant this catches: an EINTR branch that retries WITHOUT re-checking the deadline (the defa0c0 watchdog's
//! `continue`-without-charging-time). With a poll that storms EINTR while the clock advances past the deadline, a
//! deadline-honoring wait returns `.timed_out`; the mutant keeps polling until the fake's bounded cap and returns
//! something else.
const std = @import("std");
const ledger = @import("agent_run_ledger");

/// A fake monotonic clock reading a shared counter.
const FakeClock = struct {
    t: *i64,
    pub fn nowMs(self: FakeClock) i64 {
        return self.t.*;
    }
};

/// A fake poll that STORMS EINTR: every call advances the shared clock by `step` (a slice of elapsed time) and
/// returns `.eintr`, until a bounded cap `n` after which it would return `.ready` (so a mutant that ignores the
/// deadline still terminates the test instead of hanging — and is caught by returning the wrong result).
const EintrStorm = struct {
    t: *i64,
    calls: *u32,
    step: i64,
    cap: u32,
    pub fn pollOnce(self: EintrStorm) ledger.PollOutcome {
        self.calls.* += 1;
        self.t.* += self.step;
        return if (self.calls.* >= self.cap) .ready else .eintr;
    }
};

test "the watchdog is bounded by the absolute deadline even under an EINTR storm" {
    var now: i64 = 0;
    var calls: u32 = 0;
    const clock = FakeClock{ .t = &now };
    const storm = EintrStorm{ .t = &now, .calls = &calls, .step = 10, .cap = 1000 };

    // deadline = 100ms; the storm advances 10ms/poll, so a deadline-honoring wait must time out by ~call 10 — long
    // before the 1000-call cap. The mutant (EINTR without a deadline check) storms to the cap and returns .ready.
    const r = ledger.waitWithinDeadline(clock, 100, storm);
    try std.testing.expectEqual(ledger.WaitResult.timed_out, r);
    try std.testing.expect(calls <= 12); // bounded by the deadline, not the 1000-call cap
    try std.testing.expect(now >= 100); // it consulted the clock and reached the deadline
}

test "the watchdog returns ready as soon as data arrives, and fails closed on a poll error" {
    var now: i64 = 0;
    const clock = FakeClock{ .t = &now };
    const ReadyNow = struct {
        pub fn pollOnce(_: @This()) ledger.PollOutcome {
            return .ready;
        }
    };
    const ErrNow = struct {
        pub fn pollOnce(_: @This()) ledger.PollOutcome {
            return .err;
        }
    };
    try std.testing.expectEqual(ledger.WaitResult.ready, ledger.waitWithinDeadline(clock, 100, ReadyNow{}));
    try std.testing.expectEqual(ledger.WaitResult.poll_error, ledger.waitWithinDeadline(clock, 100, ErrNow{}));
}
