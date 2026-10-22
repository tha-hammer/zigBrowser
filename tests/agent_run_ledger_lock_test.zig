//! MS6.5.1 red (RoseCat flock row). The ledger's cross-process advisory lock: a bounded, cancellable
//! LOCK_EX|LOCK_NB + retry. A stalled holder in a SEPARATE process must make acquisition FAIL CLOSED
//! (error.LockBusy) within the bound, mutating nothing. Real fork + flock — no signals. UNREGISTERED until green.
//!
//! The mutant this catches: an acquisition that opens the lock file without honoring the exclusive lock (or
//! blocks forever) never returns the bounded fail-closed LockBusy against a held lock.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

const A = [_]ledger.Entry{.{ .basename = "zigbrowser-agent-2-00aa00aa00aa00aa", .dev = 1, .ino = 2, .uid = 0, .mode = 16832, .pid = 2, .start_kind = .linux_ticks, .start_sec = 0, .start_usec = 0, .state = .active }};

test "acquire on a free lock succeeds; releasing lets the next acquire succeed" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    var f = try ledger.acquireLock(io, td.dir, 20, 5);
    f.close(io); // release
    var g = try ledger.acquireLock(io, td.dir, 20, 5);
    g.close(io);
}

test "a stalled holder in a SEPARATE process -> acquire fails closed, bounded, zero mutation" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try ledger.publish(io, td.dir, "runs.json", &A); // a store to prove the failed acquire mutates nothing

    var ready: [2]i32 = undefined;
    try std.testing.expect(linux.pipe(&ready) == 0);

    const pid = linux.fork();
    if (pid == 0) {
        // CHILD (separate process): take LOCK_EX on the lock file, signal ready, hold for a BOUNDED window,
        // then exit (self-release). The hold outlasts the parent's acquire deadline (~100ms), so a correct
        // bounded acquire returns LockBusy while the child still holds. Crucially, the child self-releases on
        // its OWN timer rather than waiting for the parent, so even a BLOCKING-LOCK_EX mutant (whose parent
        // acquireLock never returns to release a go pipe) still sees the holder exit and is reaped with NO
        // signal -> the mutant test fails (wrong return) without hanging the gate forever.
        _ = linux.close(ready[0]);
        const lf = linux.openat(td.dir.handle, ledger.LOCK_NAME, .{ .ACCMODE = .RDWR, .CREAT = true }, 0o600);
        _ = linux.flock(@intCast(lf), std.posix.LOCK.EX);
        _ = linux.write(ready[1], "R", 1);
        var ts: linux.timespec = .{ .sec = 0, .nsec = 500 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, &ts); // bounded hold, then self-release on exit
        linux.exit_group(0);
    }
    // PARENT
    _ = linux.close(ready[1]);
    var rb: [1]u8 = undefined;
    try std.testing.expect(linux.read(ready[0], &rb, 1) == 1); // the child now holds the lock

    const r = ledger.acquireLock(io, td.dir, 20, 5); // bounded (~100ms), shorter than the child's 500ms hold
    try std.testing.expectError(error.LockBusy, r);

    // zero mutation: the store is still exactly A
    var l = try ledger.load(io, std.testing.allocator, td.dir, "runs.json");
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.entries().len);
    try std.testing.expectEqualStrings(A[0].basename, l.entries()[0].basename);

    // wait out the child's bounded hold; once it exits the lock is free (reaped, no signal sent)
    var st: u32 = undefined;
    _ = linux.waitpid(@intCast(pid), &st, 0);
    _ = linux.close(ready[0]);

    // and once the holder is gone, acquisition succeeds:
    var f = try ledger.acquireLock(io, td.dir, 20, 5);
    f.close(io);
}
