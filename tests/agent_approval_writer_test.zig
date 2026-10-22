//! S8 red (chat-drawer plan decision 16, part 5): the store's one writer as the Secrets
//! window's "Navigation approval" control calls it. `writeStore(io, home, owner, selector)`:
//! - a missing `<home>/settings` is created, 0700; the value is written as `writeSelector`
//!   does (0600, exactly the value and a newline, a temporary name renamed over the store,
//!   nothing left behind), and `readStore` reads it back;
//! - it writes only through a settings directory `readStore` would trust: one that is a
//!   symlink (never followed: its target is left as it was), not a directory, owned by
//!   someone else, or writable by group or others is `error.UnsafeStore`, and nothing is
//!   written anywhere.
//! A different `owner` stands for another user's directory (a test cannot chown).
//!
//! On HEAD there is no `writeStore`: this file does not compile there (the red). Unregistered
//! until its green.

const std = @import("std");
const approval = @import("agent_approval");

const testing = std.testing;
const io = testing.io;

fn homeOf(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

fn readAll(dir: std.Io.Dir, name: []const u8, buf: []u8) ![]u8 {
    return dir.readFile(io, name, buf);
}

test "a missing settings directory is made 0700; each value is written 0600 and read back; nothing is left behind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const home = try homeOf(&tmp, &buf);
    const me = approval.effectiveUid();
    for ([_]approval.Selector{ .no, .yes, .conditional, .no }) |selector| {
        try approval.writeStore(io, home, me, selector);
        const settings = try tmp.dir.statFile(io, "settings", .{ .follow_symlinks = false });
        try testing.expectEqual(std.Io.File.Kind.directory, settings.kind);
        try testing.expectEqual(@as(std.posix.mode_t, 0o700), settings.permissions.toMode() & 0o777);
        var dir = try tmp.dir.openDir(io, "settings", .{ .iterate = true });
        defer dir.close(io);
        const file = try dir.statFile(io, approval.store_name, .{ .follow_symlinks = false });
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), file.permissions.toMode() & 0o777);
        var text: [32]u8 = undefined;
        var want: [32]u8 = undefined;
        try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "{s}\n", .{@tagName(selector)}), try readAll(dir, approval.store_name, &text));
        const read = approval.readStore(io, home, me);
        try testing.expect(read.selector == selector and !read.unreadable);
        var names: usize = 0;
        var it = dir.iterate();
        while (try it.next(io)) |_| names += 1;
        try testing.expectEqual(@as(usize, 1), names);
    }
}

test "an unsafe settings directory is refused and nothing is written: a symlink, a file, another owner, writable by others" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const home = try homeOf(&tmp, &buf);
    const me = approval.effectiveUid();

    // A symlink to a directory holding "no": never followed, its file untouched.
    try tmp.dir.createDir(io, "elsewhere", @enumFromInt(0o700));
    {
        var elsewhere = try tmp.dir.openDir(io, "elsewhere", .{});
        defer elsewhere.close(io);
        const file = try elsewhere.createFile(io, approval.store_name, .{ .exclusive = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "no\n");
        try file.setPermissions(io, @enumFromInt(0o600));
    }
    try tmp.dir.symLink(io, "elsewhere", "settings", .{ .is_directory = true });
    try testing.expectError(error.UnsafeStore, approval.writeStore(io, home, me, .yes));
    {
        var elsewhere = try tmp.dir.openDir(io, "elsewhere", .{});
        defer elsewhere.close(io);
        var text: [32]u8 = undefined;
        try testing.expectEqualStrings("no\n", try readAll(elsewhere, approval.store_name, &text));
    }
    try tmp.dir.deleteFile(io, "settings");

    // A regular file where the directory should be.
    {
        const file = try tmp.dir.createFile(io, "settings", .{ .exclusive = true });
        file.close(io);
    }
    try testing.expectError(error.UnsafeStore, approval.writeStore(io, home, me, .yes));
    try tmp.dir.deleteFile(io, "settings");

    // Another owner, and a directory group or others can write.
    try tmp.dir.createDir(io, "settings", @enumFromInt(0o700));
    try testing.expectError(error.UnsafeStore, approval.writeStore(io, home, me +% 1, .yes));
    for ([_]std.posix.mode_t{ 0o720, 0o702, 0o777 }) |mode| {
        try tmp.dir.setFilePermissions(io, "settings", @enumFromInt(mode), .{});
        try testing.expectError(error.UnsafeStore, approval.writeStore(io, home, me, .yes));
    }
    try tmp.dir.setFilePermissions(io, "settings", @enumFromInt(0o700), .{});
    var settings = try tmp.dir.openDir(io, "settings", .{ .iterate = true });
    defer settings.close(io);
    var it = settings.iterate();
    try testing.expectEqual(@as(?std.Io.Dir.Entry, null), try it.next(io));
}
