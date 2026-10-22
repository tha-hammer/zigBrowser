//! MS6.5.1 (SCOPED, RoseCat c11bff8). The ONE-live-process liveness probe + action-label mapping keyed on a
//! recorded owner `(pid, start)`: a proved-dead owner labels `.recover`; a live matching owner labels `.leave`;
//! PID reuse (live, different start) or an unreadable result fails closed. The fork creates ONE live process to
//! probe — it is NOT a two-browser startup-recovery run: nothing here signals, retires, or mutates the ledger,
//! and no marked child or other-browser exclusion is modelled. Real fork, no signals.
//!
//! The mutant this catches: a mapping that labels `.recover` regardless of liveness (or a probe that reports a
//! live owner as dead) would mislabel a live process's entry as recoverable.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

test "liveness->label keys on (pid,start): live owner -> leave, dead -> recover, reuse/unreadable -> fail closed" {
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
    // Unconditional cleanup guard (RoseCat d3b31cb #4): a failure in any assertion below must still release and
    // reap A, never leave it blocked on the `go` pipe. The explicit release path clears `released` so this does
    // not double-release (a second close/waitpid would be harmless EBADF/ECHILD, but the flag keeps it clean).
    var released = false;
    defer if (!released) {
        _ = linux.close(go[1]);
        var gst: u32 = undefined;
        _ = linux.waitpid(a_pid, &gst, 0);
    };
    const a_start = ledger.readStartTicks(a_pid) orelse return error.TestNoStart;

    // A is a LIVE matching owner -> label .leave (classification only; nothing is signalled/retired here):
    try std.testing.expectEqual(ledger.Recovery.leave, ledger.recoveryFor(ledger.probeLiveness(a_pid, a_start)));
    // PID reuse (A live, but a different recorded start) -> fail closed:
    try std.testing.expectEqual(ledger.Recovery.fail_closed, ledger.recoveryFor(ledger.probeLiveness(a_pid, a_start +% 1)));
    // An absent pid -> proved dead -> label .recover:
    try std.testing.expectEqual(ledger.Recovery.recover, ledger.recoveryFor(ledger.probeLiveness(2147483646, 0)));

    _ = linux.close(go[1]); // release A
    var st: u32 = undefined;
    _ = linux.waitpid(a_pid, &st, 0);
    released = true;
    _ = linux.close(ready[0]);

    // once A has exited, its (pid,start) is proved dead -> label .recover:
    try std.testing.expectEqual(ledger.Recovery.recover, ledger.recoveryFor(ledger.probeLiveness(a_pid, a_start)));
}
