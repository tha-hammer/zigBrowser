//! WS2.0 (Windows plan, rev 2.6): one owner-only seam, `owner_only.restrictToOwner(path, kind)`,
//! for the automation socket, its token and their directory (and, through its C form, WS3.1's
//! `<profile>\WebView2`). POSIX: mode 0600 for a file, 0700 for a directory. Windows: a PROTECTED
//! DACL with exactly one allow ACE, full access, for the current user's SID, nothing inherited, no
//! SYSTEM, Administrators, Everyone, Users or Authenticated Users; on a directory the ACE is
//! inherited by what is created in it, so the socket and token never exist with a looser DACL.
//! The Windows DACL is built as SDDL by `ownerOnlySddl`, pure, so Linux pins its exact text; the
//! live ACL check is tests/e2e/win_transport_test.py on the VM. Outside the gate until the green.
const std = @import("std");
const builtin = @import("builtin");
const oo = @import("owner_only");

const has = @hasDecl(oo, "ownerOnlySddl") and @hasDecl(oo, "restrictToOwner") and @hasDecl(oo, "validSid");
const SID = "S-1-5-21-1004336348-1177238915-682003330-1001";

test "the owner-only DACL, exactly: protected, one ACE, full access, the given SID" {
    if (!has) return error.TestNoOwnerOnly;
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("D:P(A;;FA;;;" ++ SID ++ ")", try oo.ownerOnlySddl(&buf, SID, .file));
    try std.testing.expectEqualStrings("D:P(A;OICI;FA;;;" ++ SID ++ ")", try oo.ownerOnlySddl(&buf, SID, .dir));
}

test "the DACL names no one but the owner" {
    if (!has) return error.TestNoOwnerOnly;
    var buf: [256]u8 = undefined;
    for ([_]oo.Kind{ .file, .dir }) |kind| {
        const sddl = try oo.ownerOnlySddl(&buf, SID, kind);
        try std.testing.expect(std.mem.startsWith(u8, sddl, "D:P("));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, sddl, "("));
        for ([_][]const u8{ ";WD)", ";BU)", ";AU)", ";SY)", ";BA)", ";IU)", "(D;", "ID" }) |other|
            try std.testing.expect(std.mem.indexOf(u8, sddl, other) == null);
    }
}

test "a SID that is not a plain SID is refused: no SDDL can be smuggled in" {
    if (!has) return error.TestNoOwnerOnly;
    var buf: [256]u8 = undefined;
    for ([_][]const u8{
        "",                           "S-1",                           "S-1-5-",
        "S-1-5-21-x",                 "s-1-5-21-1",                    "S-1-5--21",
        "WD",                         SID ++ ")(A;;FA;;;WD",           SID ++ ";(A;;FA;;;BU)",
        " S-1-5-21-1",                "S-1-5-21-1 ",                   "S-1-5-21-1\x00",
    }) |bad| {
        try std.testing.expect(!oo.validSid(bad));
        try std.testing.expectError(error.InvalidSid, oo.ownerOnlySddl(&buf, bad, .file));
    }
    for ([_][]const u8{ SID, "S-1-5-18", "S-1-5-21-1-2-3-500" }) |good| try std.testing.expect(oo.validSid(good));
}

test "too small a buffer is an error, never a cut DACL" {
    if (!has) return error.TestNoOwnerOnly;
    var small: [16]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, oo.ownerOnlySddl(&small, SID, .file));
}

fn modeOf(path: []const u8) !u32 {
    const z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(z);
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, .{ .MODE = true }, &sx)) != .SUCCESS) return error.Stat;
        return @as(u32, sx.mode) & 0o7777;
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, z, &st, 0) != 0) return error.Stat;
    return @as(u32, @intCast(st.mode)) & 0o7777;
}

var serial: u32 = 0;

fn tmpPath(buf: []u8, name: []const u8) ![]const u8 {
    serial += 1;
    return std.fmt.bufPrint(buf, "/tmp/zb-owner-only-{d}-{d}-{s}", .{ std.c.getpid(), serial, name });
}

test "POSIX: a file becomes 0600, a directory 0700" {
    if (!has) return error.TestNoOwnerOnly;
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var fb: [96]u8 = undefined;
    var db: [96]u8 = undefined;
    const file = try tmpPath(&fb, "file");
    const dir = try tmpPath(&db, "dir");
    const fz = try std.testing.allocator.dupeZ(u8, file);
    defer std.testing.allocator.free(fz);
    const dz = try std.testing.allocator.dupeZ(u8, dir);
    defer std.testing.allocator.free(dz);
    const fd = std.c.open(fz, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(fz);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(dz, 0o755));
    defer _ = std.c.rmdir(dz);
    _ = std.c.chmod(fz, 0o644);
    _ = std.c.chmod(dz, 0o755);
    try oo.restrictToOwner(file, .file);
    try oo.restrictToOwner(dir, .dir);
    try std.testing.expectEqual(@as(u32, 0o600), try modeOf(file));
    try std.testing.expectEqual(@as(u32, 0o700), try modeOf(dir));
}

test "POSIX: a symlink is refused, and its target is left alone" {
    if (!has) return error.TestNoOwnerOnly;
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tb: [96]u8 = undefined;
    var lb: [96]u8 = undefined;
    const target = try tmpPath(&tb, "target");
    const link = try tmpPath(&lb, "link");
    const tz = try std.testing.allocator.dupeZ(u8, target);
    defer std.testing.allocator.free(tz);
    const lz = try std.testing.allocator.dupeZ(u8, link);
    defer std.testing.allocator.free(lz);
    const fd = std.c.open(tz, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(tz);
    _ = std.c.chmod(tz, 0o644);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(tz, lz));
    defer _ = std.c.unlink(lz);
    try std.testing.expectError(error.NotOwnerOnlyTarget, oo.restrictToOwner(link, .file));
    try std.testing.expectEqual(@as(u32, 0o644), try modeOf(target));
}

test "POSIX: the wrong kind, or nothing there, is an error" {
    if (!has) return error.TestNoOwnerOnly;
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var db: [96]u8 = undefined;
    const dir = try tmpPath(&db, "kind");
    const dz = try std.testing.allocator.dupeZ(u8, dir);
    defer std.testing.allocator.free(dz);
    try std.testing.expectEqual(@as(c_int, 0), std.c.mkdir(dz, 0o755));
    defer _ = std.c.rmdir(dz);
    try std.testing.expectError(error.NotOwnerOnlyTarget, oo.restrictToOwner(dir, .file));
    var mb: [96]u8 = undefined;
    try std.testing.expectError(error.NotOwnerOnlyTarget, oo.restrictToOwner(try tmpPath(&mb, "missing"), .file));
}
