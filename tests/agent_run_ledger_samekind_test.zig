//! MS6.5.1 red (RoseCat 0e36742 #4). Liveness is keyed on the owner's PLATFORM-TAGGED start identity: a recorded
//! start of a DIFFERENT kind than this platform's probe can never be compared (no conversion) and FAILS CLOSED —
//! even when its numeric value equals a live value. Real fork, no signals (A self-exits, reaped with waitpid).
//! UNREGISTERED until green.
//!
//! The mutant this catches: a comparison that ignores the recorded kind and treats a cross-kind value as if it
//! were this platform's units — so a darwin_tvsec value numerically equal to a live /proc tick count on Linux is
//! wrongly read as live_same (a false identity match that could leave a dead run unrecovered, or vice versa).
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

test "same-kind liveness compares; a cross-kind identity never matches (fails closed), even when numerically equal" {
    // This test's reasoning is Linux-specific (the platform probe kind here is linux_ticks).
    if (ledger.PLATFORM_START_KIND != .linux_ticks) return error.SkipZigTest;

    var ready: [2]i32 = undefined;
    var go: [2]i32 = undefined;
    try std.testing.expect(linux.pipe(&ready) == 0);
    try std.testing.expect(linux.pipe(&go) == 0);
    const pid = linux.fork();
    if (pid == 0) {
        _ = linux.close(ready[0]);
        _ = linux.close(go[1]);
        _ = linux.write(ready[1], "R", 1);
        var b: [1]u8 = undefined;
        _ = linux.read(go[0], &b, 1); // stay alive until released
        linux.exit_group(0);
    }
    _ = linux.close(ready[1]);
    _ = linux.close(go[0]);
    var rb: [1]u8 = undefined;
    try std.testing.expect(linux.read(ready[0], &rb, 1) == 1); // A is live

    const a_pid: i32 = @intCast(pid);
    var released = false;
    defer if (!released) {
        _ = linux.close(go[1]);
        var st: u32 = undefined;
        _ = linux.waitpid(a_pid, &st, 0);
    };
    const a_ticks = ledger.readStartTicks(a_pid) orelse return error.TestNoStart;

    // SAME kind (linux_ticks), matching value -> live_same (left untouched).
    try std.testing.expectEqual(ledger.Liveness.live_same, ledger.probeLivenessTagged(a_pid, .linux_ticks, a_ticks, 0));
    // CROSS kind: a darwin_tvsec identity carrying the SAME numeric value must NOT match — it fails closed
    // (recoveryFor -> .fail_closed), never live_same. This is the cross-kind numeric-equality case.
    try std.testing.expectEqual(ledger.Liveness.unreadable, ledger.probeLivenessTagged(a_pid, .darwin_tvsec, a_ticks, 0));
    try std.testing.expectEqual(ledger.Recovery.fail_closed, ledger.recoveryFor(ledger.probeLivenessTagged(a_pid, .darwin_tvsec, a_ticks, 0)));
    // SAME kind, a different value = PID reuse -> live_reused (fail closed), still never a false dead.
    try std.testing.expectEqual(ledger.Liveness.live_reused, ledger.probeLivenessTagged(a_pid, .linux_ticks, a_ticks +% 1, 0));

    _ = linux.close(go[1]); // release A
    var st: u32 = undefined;
    _ = linux.waitpid(a_pid, &st, 0);
    released = true;
    _ = linux.close(ready[0]);

    // once A is gone, the same-kind probe proves it dead -> recover.
    try std.testing.expectEqual(ledger.Liveness.dead, ledger.probeLivenessTagged(a_pid, .linux_ticks, a_ticks, 0));
}
