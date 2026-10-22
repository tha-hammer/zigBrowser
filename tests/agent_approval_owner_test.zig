//! S8 red (chat-drawer plan decision 16, part 4; RoseCat f87368e on ebe6529, finding 4): the
//! `navigate_approval` store also fails closed on its owner, and the app reaches it only
//! through a `settings` directory it checks, never by following a path.
//! - `readSelectorOwned(io, dir, name, owner)`: everything `readSelector` already checks
//!   (regular file, no symlink, mode 0600, exactly the value and a newline), and the file
//!   belongs to `owner`; another owner is `yes` and unreadable. `readSelector` is that with
//!   `effectiveUid()`.
//! - `readStore(io, home, owner)`: `<home>/settings` opened without following a symlink; a
//!   missing one is the default (`conditional`); one that is a symlink, not a directory,
//!   owned by someone else, or writable by group or others is `yes` and unreadable; else the
//!   file inside it, as `readSelectorOwned`.
//! The rows use a different `owner` to stand for a file of another user, since a test cannot
//! chown; production passes `effectiveUid()`.
//!
//! On HEAD there is no `readSelectorOwned`, `readStore` or `effectiveUid`: this file does not
//! compile there (the red). Unregistered until its green.

const std = @import("std");
const approval = @import("agent_approval");

const testing = std.testing;
const io = testing.io;

fn writeMode(dir: std.Io.Dir, name: []const u8, bytes: []const u8, mode: std.posix.mode_t) !void {
    dir.deleteFile(io, name) catch {};
    const file = try dir.createFile(io, name, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.setPermissions(io, @enumFromInt(mode));
}

fn homeOf(tmp: *testing.TmpDir, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
}

test "the file's owner: mine reads its value, another owner is yes and unreadable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const me = approval.effectiveUid();
    for ([_]struct { bytes: []const u8, want: approval.Selector }{
        .{ .bytes = "no\n", .want = .no },
        .{ .bytes = "conditional\n", .want = .conditional },
        .{ .bytes = "yes\n", .want = .yes },
    }) |row| {
        try writeMode(tmp.dir, approval.store_name, row.bytes, 0o600);
        const mine = approval.readSelectorOwned(io, tmp.dir, approval.store_name, me);
        try testing.expect(mine.selector == row.want and !mine.unreadable);
        const theirs = approval.readSelectorOwned(io, tmp.dir, approval.store_name, me +% 1);
        try testing.expect(theirs.selector == .yes and theirs.unreadable);
        // readSelector is the effective user's.
        try testing.expectEqual(row.want, approval.readSelector(io, tmp.dir, approval.store_name).selector);
    }
}

test "readStore: a missing settings directory is the default; a good one is read" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const home = try homeOf(&tmp, &buf);
    const me = approval.effectiveUid();
    const missing = approval.readStore(io, home, me);
    try testing.expect(missing.selector == approval.default_selector and !missing.unreadable);

    try tmp.dir.createDir(io, "settings", @enumFromInt(0o700));
    const empty = approval.readStore(io, home, me);
    try testing.expect(empty.selector == approval.default_selector and !empty.unreadable);

    var settings = try tmp.dir.openDir(io, "settings", .{});
    defer settings.close(io);
    try writeMode(settings, approval.store_name, "no\n", 0o600);
    const good = approval.readStore(io, home, me);
    try testing.expect(good.selector == .no and !good.unreadable);
}

test "readStore: settings owned by someone else, writable by others, a symlink or a file: yes and unreadable" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const home = try homeOf(&tmp, &buf);
    const me = approval.effectiveUid();

    try tmp.dir.createDir(io, "settings", @enumFromInt(0o700));
    var settings = try tmp.dir.openDir(io, "settings", .{});
    try writeMode(settings, approval.store_name, "no\n", 0o600);
    settings.close(io);

    // Another owner (the directory and the file are mine, not theirs).
    const theirs = approval.readStore(io, home, me +% 1);
    try testing.expect(theirs.selector == .yes and theirs.unreadable);

    // Writable by group or others.
    for ([_]std.posix.mode_t{ 0o720, 0o702, 0o777 }) |mode| {
        var dir = try tmp.dir.openDir(io, "settings", .{});
        try dir.setPermissions(io, @enumFromInt(mode));
        dir.close(io);
        const loose = approval.readStore(io, home, me);
        testing.expect(loose.selector == .yes and loose.unreadable) catch |e| {
            std.debug.print("settings mode {o} read as {s}\n", .{ mode, @tagName(loose.selector) });
            return e;
        };
    }
    var dir = try tmp.dir.openDir(io, "settings", .{});
    try dir.setPermissions(io, @enumFromInt(0o700));
    dir.close(io);

    // A symlink to a good settings directory is never followed.
    try tmp.dir.rename("settings", tmp.dir, "elsewhere", io);
    try tmp.dir.symLink(io, "elsewhere", "settings", .{ .is_directory = true });
    const linked = approval.readStore(io, home, me);
    try testing.expect(linked.selector == .yes and linked.unreadable);

    // A regular file where the directory should be.
    try tmp.dir.deleteFile(io, "settings");
    try writeMode(tmp.dir, "settings", "no\n", 0o600);
    const file = approval.readStore(io, home, me);
    try testing.expect(file.selector == .yes and file.unreadable);
}
