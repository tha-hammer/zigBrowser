//! MS6.5.1 red (RoseCat recovery row). Startup recovery keys on the recorded owner (pid, start): a leftover
//! `active` entry is recovery work ONLY when its owner is proved dead; a LIVE matching owner (another browser
//! instance) is left untouched; PID reuse (live, different start) or an unreadable result fails closed. Real
//! fork — no signals. UNREGISTERED until green.
//!
//! Two-browser case: B starts while A (a live owner, recorded (pid,start)) and A's marked child are live. B's
//! decision for A's entry must be `.leave` — so B neither signals A's child nor retires A's entry.
//!
//! The mutant this catches: a decision that recovers regardless of liveness (or a probe that reports a live
//! owner as dead) would make B recover — i.e. signal/retire — a live instance's entry.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

test "recovery decision keys on (pid,start): live owner is left, dead recovers, reuse/unreadable fail closed" {
    var ready: [2]i32 = undefined;
    var go: [2]i32 = undefined;
    try std.testing.expect(linux.pipe(&ready) == 0);
    try std.testing.expect(linux.pipe(&go) == 0);

    const pid = linux.fork();
    if (pid == 0) {
        // CHILD = browser instance A: just stay alive until released.
        _ = linux.close(ready[0]);
        _ = linux.close(go[1]);
        _ = linux.write(ready[1], "R", 1);
        var b: [1]u8 = undefined;
        _ = linux.read(go[0], &b, 1); // block until the parent closes go[1]
        linux.exit_group(0);
    }
    // PARENT = browser instance B.
    _ = linux.close(ready[1]);
    _ = linux.close(go[0]);
    var rb: [1]u8 = undefined;
    try std.testing.expect(linux.read(ready[0], &rb, 1) == 1); // A is now live

    const a_pid: i32 = @intCast(pid);
    const a_start = ledger.readStartTicks(a_pid) orelse return error.TestNoStart;

    // A is a LIVE matching owner -> leave untouched (B neither signals nor retires A's entry):
    try std.testing.expectEqual(ledger.Recovery.leave, ledger.recoveryFor(ledger.probeLiveness(a_pid, a_start)));
    // PID reuse (A live, but a different recorded start) -> fail closed:
    try std.testing.expectEqual(ledger.Recovery.fail_closed, ledger.recoveryFor(ledger.probeLiveness(a_pid, a_start +% 1)));
    // An absent pid -> proved dead -> recovery work:
    try std.testing.expectEqual(ledger.Recovery.recover, ledger.recoveryFor(ledger.probeLiveness(2147483646, 0)));

    _ = linux.close(go[1]); // release A
    var st: u32 = undefined;
    _ = linux.waitpid(a_pid, &st, 0);
    _ = linux.close(ready[0]);

    // once A has exited, its (pid,start) is proved dead -> recovery work:
    try std.testing.expectEqual(ledger.Recovery.recover, ledger.recoveryFor(ledger.probeLiveness(a_pid, a_start)));
}
