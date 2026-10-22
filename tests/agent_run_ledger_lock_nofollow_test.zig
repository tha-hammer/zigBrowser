//! MS6.5.1 red (RoseCat 53a467b #1). The ledger lock must be opened/created O_NOFOLLOW|O_CLOEXEC, so a planted
//! or swapped symlink at `.zigbrowser-agent-runs.lock` can NEVER select a different inode (which would defeat the
//! single global claim). A symlink (or any other error) must FAIL CLOSED. Real symlink — no signals.
//! UNREGISTERED until green.
//!
//! The mutant this catches: Dir.createFile follows the final-component symlink, so it locks (and even creates)
//! the symlink's target instead of failing closed.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

test "a symlink at the lock path fails closed (O_NOFOLLOW), never following to another inode" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    // Plant a symlink where the lock file would be. A no-follow open must refuse it (ELOOP) -> LockFailed; a
    // following open would lock (and O_CREAT create) the decoy target instead.
    const rc = linux.symlinkat("zb-lock-decoy-target", td.dir.handle, ledger.LOCK_NAME);
    try std.testing.expect(linux.errno(rc) == .SUCCESS);
    try std.testing.expectError(error.LockFailed, ledger.acquireLock(io, td.dir, 20, 5));
    // and the decoy target must not have been created through the symlink
    try std.testing.expectError(error.FileNotFound, td.dir.access(io, "zb-lock-decoy-target", .{}));
}
