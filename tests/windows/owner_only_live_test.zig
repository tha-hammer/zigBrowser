//! WS2.0 live (Windows plan rev 2.6): the owner-only seam on real Windows, run on the Win11 VM as
//! zbtext by `bash tests/windows/build-on-windows.sh owner-only-test-win`. The DACL is read back
//! from the file system (GetNamedSecurityInfoW, as SDDL), not from what the seam meant to write.
//! - a directory under %LOCALAPPDATA%: exactly `D:P(A;OICI;FA;;;<the user's SID>)`;
//! - a file created inside it: one ACE, the user's, inherited (nothing else);
//! - that file restricted itself: exactly `D:P(A;;FA;;;<SID>)`;
//! - the positive control: an unrestricted directory beside it still carries the inherited
//!   %LOCALAPPDATA% ACEs (SYSTEM, Administrators), which the seam must remove.
//! Windows only (skipped elsewhere).
const std = @import("std");
const builtin = @import("builtin");
const oo = @import("owner_only");

const has = @hasDecl(oo, "restrictToOwner") and @hasDecl(oo, "currentUserSid");

const w = struct {
    const DWORD = u32;
    extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: [*]u16, size: DWORD) callconv(.winapi) DWORD;
    extern "kernel32" fn CreateDirectoryW(path: [*:0]const u16, sa: ?*anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn RemoveDirectoryW(path: [*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn DeleteFileW(path: [*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CloseHandle(h: *anyopaque) callconv(.winapi) c_int;
    extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "advapi32" fn GetNamedSecurityInfoW(name: [*:0]const u16, kind: c_int, info: DWORD, owner: ?*?*anyopaque, group: ?*?*anyopaque, dacl: ?*?*anyopaque, sacl: ?*?*anyopaque, sd: *?*anyopaque) callconv(.winapi) DWORD;
    extern "advapi32" fn ConvertSecurityDescriptorToStringSecurityDescriptorW(sd: *anyopaque, rev: DWORD, info: DWORD, out: *?[*:0]u16, len: ?*u32) callconv(.winapi) c_int;
};

fn wide(buf: []u16, s: []const u8) ![*:0]const u16 {
    const n = try std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], s);
    buf[n] = 0;
    return @ptrCast(buf.ptr);
}

/// The DACL of `path`, as SDDL (UTF-8), read from the file system.
fn daclSddl(path: []const u8, out: []u8) ![]const u8 {
    var wp: [600]u16 = undefined;
    var sd: ?*anyopaque = null;
    if (w.GetNamedSecurityInfoW(try wide(&wp, path), 1, 0x4, null, null, null, null, &sd) != 0) return error.ReadDacl;
    defer _ = w.LocalFree(sd);
    var str: ?[*:0]u16 = null;
    if (w.ConvertSecurityDescriptorToStringSecurityDescriptorW(sd.?, 1, 0x4, &str, null) == 0) return error.ToSddl;
    defer _ = w.LocalFree(str);
    const n = try std.unicode.utf16LeToUtf8(out, std.mem.span(str.?));
    return out[0..n];
}

fn localAppData(out: []u8) ![]const u8 {
    var name: [16]u16 = undefined;
    var buf: [400]u16 = undefined;
    const n = w.GetEnvironmentVariableW(try wide(&name, "LOCALAPPDATA"), &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.NoLocalAppData;
    const m = try std.unicode.utf16LeToUtf8(out, buf[0..n]);
    return out[0..m];
}

test "the seam's DACLs, read back from Windows" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!has) return error.TestNoOwnerOnly;
    var base_buf: [600]u8 = undefined;
    const base = try localAppData(&base_buf);
    var sid_buf: [192]u8 = undefined;
    const sid = try oo.currentUserSid(&sid_buf);
    var dir_buf: [700]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}\\zb-ws20-live-{d}-{d}", .{ base, w.GetCurrentProcessId(), w.GetTickCount64() });
    var plain_buf: [700]u8 = undefined;
    const plain = try std.fmt.bufPrint(&plain_buf, "{s}-plain", .{dir});
    var file_buf: [760]u8 = undefined;
    const file = try std.fmt.bufPrint(&file_buf, "{s}\\token", .{dir});
    var wd: [800]u16 = undefined;
    var wpl: [800]u16 = undefined;
    var wf: [800]u16 = undefined;
    const dz = try wide(&wd, dir);
    const pz = try wide(&wpl, plain);
    const fz = try wide(&wf, file);
    if (w.CreateDirectoryW(dz, null) == 0) return error.Mkdir;
    defer _ = w.RemoveDirectoryW(dz);
    if (w.CreateDirectoryW(pz, null) == 0) return error.Mkdir;
    defer _ = w.RemoveDirectoryW(pz);

    var s1: [512]u8 = undefined;
    try oo.restrictToOwner(dir, .dir);
    var want_buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want_buf, "D:P(A;OICI;FA;;;{s})", .{sid}), try daclSddl(dir, &s1));

    const h = w.CreateFileW(fz, 0x40000000, 0, null, 1, 0x80, null) orelse return error.CreateFile;
    _ = w.CloseHandle(h);
    defer _ = w.DeleteFileW(fz);
    var s2: [512]u8 = undefined;
    const inherited = try daclSddl(file, &s2);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, inherited, "(A;"));
    try std.testing.expect(std.mem.indexOf(u8, inherited, sid) != null);
    try oo.restrictToOwner(file, .file);
    var s3: [512]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&want_buf, "D:P(A;;FA;;;{s})", .{sid}), try daclSddl(file, &s3));

    var s4: [1024]u8 = undefined;
    const control = try daclSddl(plain, &s4);
    try std.testing.expect(std.mem.indexOf(u8, control, ";SY)") != null or std.mem.indexOf(u8, control, ";BA)") != null);
}
