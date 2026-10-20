//! WS2.0 VM probe for tests/e2e/win_transport_test.py (Windows plan rev 2.6, RoseCat 6607 #3, 6647).
//! A tiny Windows exe, cross-built on Linux (x86_64-windows-gnu), that runs as zbtext or zbother and
//! prints exactly one JSON line on stdout:
//!   probe sid             {"ok":true,"sid":"S-1-5-..."}            the process token's user SID
//!   probe sddl <path>     {"ok":true,"sddl":"D:P(...)"}            the DACL read back from the file system
//!   probe connect <path>  {"ok":true} | {"ok":false,"wsa":10013}   an AF_UNIX stream connect to the socket
//!   probe read <path>     {"ok":true,"len":64} | {"ok":false,"err":5}  open for read + ReadFile (the bytes
//!                         are never printed: the token stays secret)
//! Failures carry the Win32/WSA error code, so the test can tell "denied" from "missing".
const std = @import("std");

const DWORD = u32;
const HANDLE = *anyopaque;
const INVALID: usize = std.math.maxInt(usize);

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
extern "shell32" fn CommandLineToArgvW(cmd: [*:0]const u16, argc: *c_int) callconv(.winapi) ?[*][*:0]u16;
extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: DWORD, written: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, len: DWORD, read: ?*DWORD, ov: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?*anyopaque) callconv(.winapi) usize;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn ExitProcess(code: c_uint) callconv(.winapi) noreturn;
extern "advapi32" fn OpenProcessToken(process: HANDLE, access: DWORD, token: *?HANDLE) callconv(.winapi) c_int;
extern "advapi32" fn GetTokenInformation(token: HANDLE, class: c_int, info: ?*anyopaque, len: DWORD, ret: *DWORD) callconv(.winapi) c_int;
extern "advapi32" fn ConvertSidToStringSidW(sid: *anyopaque, out: *?[*:0]u16) callconv(.winapi) c_int;
extern "advapi32" fn GetNamedSecurityInfoW(name: [*:0]const u16, kind: c_int, info: DWORD, owner: ?*?*anyopaque, group: ?*?*anyopaque, dacl: ?*?*anyopaque, sacl: ?*?*anyopaque, sd: *?*anyopaque) callconv(.winapi) DWORD;
extern "advapi32" fn ConvertSecurityDescriptorToStringSecurityDescriptorW(sd: *anyopaque, rev: DWORD, info: DWORD, out: *?[*:0]u16, len: ?*u32) callconv(.winapi) c_int;
extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) c_int;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
extern "ws2_32" fn socket(af: c_int, kind: c_int, proto: c_int) callconv(.winapi) usize;
extern "ws2_32" fn connect(s: usize, addr: *const anyopaque, len: c_int) callconv(.winapi) c_int;
extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) c_int;

var out_buf: [4096]u8 = undefined;

fn emit(comptime fmt: []const u8, args: anytype) noreturn {
    const line = std.fmt.bufPrint(&out_buf, fmt ++ "\n", args) catch "{\"ok\":false,\"err\":-1}\n";
    if (GetStdHandle(@bitCast(@as(i32, -11)))) |h| _ = WriteFile(h, line.ptr, @intCast(line.len), null, null);
    ExitProcess(0);
}

fn utf8(buf: []u8, w: [*:0]const u16) []const u8 {
    const n = std.unicode.utf16LeToUtf8(buf, std.mem.span(w)) catch return "?";
    return buf[0..n];
}

fn sid() noreturn {
    var token: ?HANDLE = null;
    if (OpenProcessToken(GetCurrentProcess(), 0x0008, &token) == 0) emit("{{\"ok\":false,\"err\":{d}}}", .{GetLastError()});
    var info: [256]u8 align(8) = undefined;
    var len: DWORD = 0;
    if (GetTokenInformation(token.?, 1, &info, info.len, &len) == 0) emit("{{\"ok\":false,\"err\":{d}}}", .{GetLastError()});
    // TOKEN_USER starts with SID_AND_ATTRIBUTES, whose first field is the PSID.
    const psid: *anyopaque = @as(*const *anyopaque, @ptrCast(&info)).*;
    var str: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(psid, &str) == 0) emit("{{\"ok\":false,\"err\":{d}}}", .{GetLastError()});
    var u: [256]u8 = undefined;
    emit("{{\"ok\":true,\"sid\":\"{s}\"}}", .{utf8(&u, str.?)});
}

fn sddl(path: [*:0]const u16) noreturn {
    var sd: ?*anyopaque = null;
    const rc = GetNamedSecurityInfoW(path, 1, 0x4, null, null, null, null, &sd);
    if (rc != 0) emit("{{\"ok\":false,\"err\":{d}}}", .{rc});
    var str: ?[*:0]u16 = null;
    if (ConvertSecurityDescriptorToStringSecurityDescriptorW(sd.?, 1, 0x4, &str, null) == 0) emit("{{\"ok\":false,\"err\":{d}}}", .{GetLastError()});
    var u: [2048]u8 = undefined;
    emit("{{\"ok\":true,\"sddl\":\"{s}\"}}", .{utf8(&u, str.?)});
}

fn connectTo(path: [*:0]const u16) noreturn {
    var wsa: [512]u8 = undefined;
    if (WSAStartup(0x0202, &wsa) != 0) emit("{{\"ok\":false,\"wsa\":{d}}}", .{WSAGetLastError()});
    const s = socket(1, 1, 0); // AF_UNIX, SOCK_STREAM
    if (s == INVALID) emit("{{\"ok\":false,\"wsa\":{d}}}", .{WSAGetLastError()});
    // sockaddr_un: u16 family + char path[108].
    var addr: extern struct { family: u16, path: [108]u8 } = .{ .family = 1, .path = @splat(0) };
    var u: [512]u8 = undefined;
    const p = utf8(&u, path);
    if (p.len >= addr.path.len) emit("{{\"ok\":false,\"err\":\"too long\"}}", .{});
    @memcpy(addr.path[0..p.len], p);
    if (connect(s, &addr, @sizeOf(@TypeOf(addr))) != 0) emit("{{\"ok\":false,\"wsa\":{d}}}", .{WSAGetLastError()});
    _ = closesocket(s);
    emit("{{\"ok\":true}}", .{});
}

fn readFrom(path: [*:0]const u16) noreturn {
    // GENERIC_READ, share read|write|delete, OPEN_EXISTING.
    const h = CreateFileW(path, 0x80000000, 0x7, null, 3, 0, null);
    if (h == INVALID) emit("{{\"ok\":false,\"err\":{d}}}", .{GetLastError()});
    const handle: HANDLE = @ptrFromInt(h);
    var buf: [512]u8 = undefined;
    var got: DWORD = 0;
    if (ReadFile(handle, &buf, buf.len, &got, null) == 0) emit("{{\"ok\":false,\"err\":{d}}}", .{GetLastError()});
    _ = CloseHandle(handle);
    emit("{{\"ok\":true,\"len\":{d}}}", .{got});
}

pub fn main() void {
    var argc: c_int = 0;
    const argv = CommandLineToArgvW(GetCommandLineW(), &argc) orelse emit("{{\"ok\":false,\"err\":\"argv\"}}", .{});
    if (argc < 2) emit("{{\"ok\":false,\"err\":\"usage: sid | sddl|connect|read <path>\"}}", .{});
    var cb: [32]u8 = undefined;
    const cmd = utf8(&cb, argv[1]);
    if (std.mem.eql(u8, cmd, "sid")) sid();
    if (argc < 3) emit("{{\"ok\":false,\"err\":\"missing path\"}}", .{});
    if (std.mem.eql(u8, cmd, "sddl")) sddl(argv[2]);
    if (std.mem.eql(u8, cmd, "connect")) connectTo(argv[2]);
    if (std.mem.eql(u8, cmd, "read")) readFrom(argv[2]);
    emit("{{\"ok\":false,\"err\":\"unknown command\"}}", .{});
}
