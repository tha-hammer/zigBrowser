//! Atomic replacement of a small JSON state file in the profile
//! (automation-pacing.json, agent-drawer.json): a fresh 0600 temp file next
//! to `path`, synced, renamed over it, and then the directory synced too.
//! Readers only ever see the old or the new file; once a save returned, it
//! survives a crash; the temp file never outlives a failed save.
const std = @import("std");
const builtin = @import("builtin");

pub fn replaceJson(io: std.Io, path: []const u8, value: anytype) !void {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp-{x}", .{ path, std.mem.readInt(u64, &nonce, .little) });
    const dir = std.Io.Dir.cwd();
    // `permissions = .fromMode` is a POSIX mode; on Windows file protection is ACL-based (the temp file
    // inherits the profile directory's ACL), and the Permissions enum has no `fromMode`, so omit it there.
    var file = try dir.createFile(io, tmp, if (builtin.os.tag == .windows)
        .{ .exclusive = true }
    else
        .{ .exclusive = true, .permissions = .fromMode(0o600) });
    var renamed = false;
    defer if (!renamed) dir.deleteFile(io, tmp) catch {};
    {
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var writer = file.writer(io, &buf);
        try std.json.Stringify.value(value, .{}, &writer.interface);
        try writer.interface.flush();
        try file.sync(io);
    }
    try dir.rename(tmp, dir, path, io);
    renamed = true;
    try syncParent(io, path);
}

/// fsync of the directory holding `path`, so the rename itself is durable.
fn syncParent(io: std.Io, path: []const u8) !void {
    // Windows has no directory fsync (and `std.c.fsync` is POSIX-only); NTFS journals the rename's metadata,
    // so the rename is durable once the file's own buffers are flushed (done above via `file.sync`).
    if (builtin.os.tag == .windows) return;
    // `iterate` opens it O_RDONLY (a plain open is O_PATH, which fsync refuses).
    var parent = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{ .iterate = true });
    defer parent.close(io);
    if (std.c.fsync(parent.handle) != 0) return error.SyncFailed;
}
