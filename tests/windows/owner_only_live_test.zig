//! WS2.0 live (Windows plan rev 2.6): the owner-only seam on real Windows, run on the Win11 VM as
//! zbtext by `bash tests/windows/build-on-windows.sh owner-only-test-win`. The DACL is read back
//! from the file system (GetNamedSecurityInfoW, as SDDL), not from what the seam meant to write.
//! - a directory under %LOCALAPPDATA%: exactly one ACE, `(A;OICI;FA;;;<the user's SID>)`, and the
//!   DACL protected (`P`; Windows also reports its own `AI`/`AR` control flags: on the VM it read
//!   back `D:PAI(...)`, so control flags are P plus only those);
//! - a file created inside it: one ACE, the user's, inherited (nothing else);
//! - that file restricted itself: exactly one ACE, `(A;;FA;;;<SID>)`, protected;
//! - the positive control: an unrestricted directory beside it still carries the inherited
//!   %LOCALAPPDATA% ACEs (SYSTEM, Administrators), which the seam must remove.
//! RoseCat 6607: the check and the apply name one object (a handle opened without following a reparse
//! point), so a junction passed in is refused and a leaf swapped for a junction after the check
//! (the test-only hook `owner_only.after_check`) never redirects the DACL to the junction's target.
//! An AF_UNIX socket, itself a reparse point (IO_REPARSE_TAG_AF_UNIX), is accepted as a file.
//! Windows only (skipped elsewhere).
const std = @import("std");
const builtin = @import("builtin");
const oo = @import("owner_only");

const has = @hasDecl(oo, "restrictToOwner") and @hasDecl(oo, "currentUserSid");
const has_hook = @hasDecl(oo, "after_check");

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
    extern "kernel32" fn MoveFileW(from: [*:0]const u16, to: [*:0]const u16) callconv(.winapi) c_int;
    extern "kernel32" fn DeviceIoControl(h: *anyopaque, code: DWORD, in: ?*const anyopaque, in_len: DWORD, out: ?*anyopaque, out_len: DWORD, ret: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) c_int;
    extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) c_int;
    extern "ws2_32" fn socket(af: c_int, kind: c_int, proto: c_int) callconv(.winapi) usize;
    extern "ws2_32" fn bind(s: usize, addr: *const anyopaque, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) c_int;
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

/// The DACL is protected, carries only Windows' own control flags besides, and holds exactly `ace`.
fn expectOwnerOnly(sddl: []const u8, ace: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, sddl, "D:"));
    const open = std.mem.indexOfScalar(u8, sddl, '(') orelse return error.NoAce;
    const flags = sddl[2..open];
    try std.testing.expect(std.mem.indexOfScalar(u8, flags, 'P') != null);
    var rest = flags;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "P")) rest = rest[1..] else if (std.mem.startsWith(u8, rest, "AI") or std.mem.startsWith(u8, rest, "AR")) rest = rest[2..] else {
            std.debug.print("unexpected DACL control flags {s} in {s}\n", .{ flags, sddl });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqualStrings(ace, sddl[open..]);
}

fn localAppData(out: []u8) ![]const u8 {
    var name: [16]u16 = undefined;
    var buf: [400]u16 = undefined;
    const n = w.GetEnvironmentVariableW(try wide(&name, "LOCALAPPDATA"), &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.NoLocalAppData;
    const m = try std.unicode.utf16LeToUtf8(out, buf[0..n]);
    return out[0..m];
}

/// Makes the empty directory `link` a junction (mount point) to the directory `target`. Standard
/// users may create junctions.
fn makeJunction(link: []const u8, target: []const u8) !void {
    var wl: [800]u16 = undefined;
    const lz = try wide(&wl, link);
    if (w.CreateDirectoryW(lz, null) == 0) return error.Mkdir;
    const h = w.CreateFileW(lz, 0x40000000, 0x7, null, 3, 0x02000000 | 0x00200000, null) orelse return error.OpenLink;
    defer _ = w.CloseHandle(h);
    var subst_buf: [800]u8 = undefined;
    const subst = try std.fmt.bufPrint(&subst_buf, "\\??\\{s}", .{target});
    var ws: [800]u16 = undefined;
    const sn = try std.unicode.utf8ToUtf16Le(&ws, subst);
    var wp: [800]u16 = undefined;
    const pn = try std.unicode.utf8ToUtf16Le(&wp, target);
    var buf: [4096]u8 align(4) = undefined;
    @memset(&buf, 0);
    const path_bytes = (sn + 1 + pn + 1) * 2;
    std.mem.writeInt(u32, buf[0..4], 0xA0000003, .little); // IO_REPARSE_TAG_MOUNT_POINT
    std.mem.writeInt(u16, buf[4..6], @intCast(8 + path_bytes), .little);
    std.mem.writeInt(u16, buf[8..10], 0, .little); // substitute name offset
    std.mem.writeInt(u16, buf[10..12], @intCast(sn * 2), .little);
    std.mem.writeInt(u16, buf[12..14], @intCast((sn + 1) * 2), .little); // print name offset
    std.mem.writeInt(u16, buf[14..16], @intCast(pn * 2), .little);
    @memcpy(buf[16 .. 16 + sn * 2], std.mem.sliceAsBytes(ws[0..sn]));
    @memcpy(buf[16 + (sn + 1) * 2 .. 16 + (sn + 1) * 2 + pn * 2], std.mem.sliceAsBytes(wp[0..pn]));
    var ret: w.DWORD = 0;
    if (w.DeviceIoControl(h, 0x000900A4, &buf, @intCast(16 + path_bytes), null, 0, &ret, null) == 0) return error.SetReparse;
}

const JunctionSwap = struct {
    var leaf: []const u8 = "";
    var moved: []const u8 = "";
    var victim: []const u8 = "";
    fn swap() void {
        var a: [800]u16 = undefined;
        var b: [800]u16 = undefined;
        if (w.MoveFileW(wide(&a, leaf) catch unreachable, wide(&b, moved) catch unreachable) == 0) @panic("move");
        makeJunction(leaf, victim) catch @panic("junction");
    }
};

fn hasForeignAce(sddl: []const u8) bool {
    return std.mem.indexOf(u8, sddl, ";SY)") != null or std.mem.indexOf(u8, sddl, ";BA)") != null;
}

test "a junction passed in is refused, and its target keeps its DACL" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!has) return error.TestNoOwnerOnly;
    var base_buf: [600]u8 = undefined;
    const base = try localAppData(&base_buf);
    var vb: [700]u8 = undefined;
    const victim = try std.fmt.bufPrint(&vb, "{s}\\zb-ws20-victim-{d}-{d}", .{ base, w.GetCurrentProcessId(), w.GetTickCount64() });
    var lb: [760]u8 = undefined;
    const link = try std.fmt.bufPrint(&lb, "{s}-link", .{victim});
    var wv: [800]u16 = undefined;
    var wl: [800]u16 = undefined;
    const vz = try wide(&wv, victim);
    if (w.CreateDirectoryW(vz, null) == 0) return error.Mkdir;
    defer _ = w.RemoveDirectoryW(vz);
    try makeJunction(link, victim);
    const lz = try wide(&wl, link);
    defer _ = w.RemoveDirectoryW(lz);
    try std.testing.expectError(error.NotOwnerOnlyTarget, oo.restrictToOwner(link, .dir));
    var s: [1024]u8 = undefined;
    try std.testing.expect(hasForeignAce(try daclSddl(victim, &s)));
}

test "a leaf swapped for a junction after the check never redirects the DACL" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!has) return error.TestNoOwnerOnly;
    if (!has_hook) return error.TestNoAfterCheckHook;
    var base_buf: [600]u8 = undefined;
    const base = try localAppData(&base_buf);
    var lb: [700]u8 = undefined;
    const leaf = try std.fmt.bufPrint(&lb, "{s}\\zb-ws20-swap-{d}-{d}", .{ base, w.GetCurrentProcessId(), w.GetTickCount64() });
    var mb: [760]u8 = undefined;
    const moved = try std.fmt.bufPrint(&mb, "{s}-moved", .{leaf});
    var vb: [760]u8 = undefined;
    const victim = try std.fmt.bufPrint(&vb, "{s}-victim", .{leaf});
    var w1: [800]u16 = undefined;
    var w2: [800]u16 = undefined;
    var w3: [800]u16 = undefined;
    if (w.CreateDirectoryW(try wide(&w1, leaf), null) == 0) return error.Mkdir;
    if (w.CreateDirectoryW(try wide(&w3, victim), null) == 0) return error.Mkdir;
    defer {
        _ = w.RemoveDirectoryW(wide(&w1, leaf) catch unreachable);
        _ = w.RemoveDirectoryW(wide(&w2, moved) catch unreachable);
        _ = w.RemoveDirectoryW(wide(&w3, victim) catch unreachable);
    }
    JunctionSwap.leaf = leaf;
    JunctionSwap.moved = moved;
    JunctionSwap.victim = victim;
    oo.after_check = JunctionSwap.swap;
    defer oo.after_check = null;
    try oo.restrictToOwner(leaf, .dir);
    var s1: [1024]u8 = undefined;
    try std.testing.expect(hasForeignAce(try daclSddl(victim, &s1))); // the target was never touched
    var sid_buf: [192]u8 = undefined;
    var want: [256]u8 = undefined;
    var s2: [512]u8 = undefined;
    try expectOwnerOnly(try daclSddl(moved, &s2), try std.fmt.bufPrint(&want, "(A;OICI;FA;;;{s})", .{try oo.currentUserSid(&sid_buf)}));
}

test "an AF_UNIX socket (a reparse point) is accepted as a file and made owner-only" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!has) return error.TestNoOwnerOnly;
    var wsa: [512]u8 = undefined;
    if (w.WSAStartup(0x0202, &wsa) != 0) return error.WsaStartup;
    var base_buf: [600]u8 = undefined;
    const base = try localAppData(&base_buf);
    var pb: [700]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}\\zb-ws20-{d}.sock", .{ base, w.GetCurrentProcessId() });
    var addr: [110]u8 = [_]u8{0} ** 110;
    std.mem.writeInt(u16, addr[0..2], 1, .little); // AF_UNIX
    if (path.len >= 108) return error.PathTooLong;
    @memcpy(addr[2 .. 2 + path.len], path);
    const sock = w.socket(1, 1, 0);
    if (sock == std.math.maxInt(usize)) return error.Socket;
    defer _ = w.closesocket(sock);
    if (w.bind(sock, &addr, @intCast(2 + path.len + 1)) != 0) return error.Bind;
    var wp: [800]u16 = undefined;
    defer _ = w.DeleteFileW(wide(&wp, path) catch unreachable);
    try oo.restrictToOwner(path, .file);
    var sid_buf: [192]u8 = undefined;
    var want: [256]u8 = undefined;
    var s: [512]u8 = undefined;
    try expectOwnerOnly(try daclSddl(path, &s), try std.fmt.bufPrint(&want, "(A;;FA;;;{s})", .{try oo.currentUserSid(&sid_buf)}));
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
    try expectOwnerOnly(try daclSddl(dir, &s1), try std.fmt.bufPrint(&want_buf, "(A;OICI;FA;;;{s})", .{sid}));

    const h = w.CreateFileW(fz, 0x40000000, 0, null, 1, 0x80, null) orelse return error.CreateFile;
    _ = w.CloseHandle(h);
    defer _ = w.DeleteFileW(fz);
    var s2: [512]u8 = undefined;
    const inherited = try daclSddl(file, &s2);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, inherited, "(A;"));
    try std.testing.expect(std.mem.indexOf(u8, inherited, sid) != null);
    try oo.restrictToOwner(file, .file);
    var s3: [512]u8 = undefined;
    try expectOwnerOnly(try daclSddl(file, &s3), try std.fmt.bufPrint(&want_buf, "(A;;FA;;;{s})", .{sid}));

    var s4: [1024]u8 = undefined;
    const control = try daclSddl(plain, &s4);
    try std.testing.expect(std.mem.indexOf(u8, control, ";SY)") != null or std.mem.indexOf(u8, control, ";BA)") != null);
}
