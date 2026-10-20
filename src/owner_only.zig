//! WS2.0 (Windows plan, rev 2.6): one owner-only seam for the automation socket, its token and
//! their directory, and (through a C form) WS3.1's `<profile>\WebView2`.
//! - POSIX: mode 0600 for a file (or a socket), 0700 for a directory.
//! - Windows: a PROTECTED DACL with exactly one allow ACE, full access, for the current user's SID:
//!   nothing inherited, no SYSTEM, Administrators, Everyone, Users or Authenticated Users. On a
//!   directory the ACE is inherited by what is created in it (OICI), so a socket or token created
//!   there never exists with a looser DACL. Built as SDDL by `ownerOnlySddl` (pure, pinned on
//!   Linux) and applied with SetSecurityInfo on the checked handle (the Windows arm; the live check is
//!   tests/e2e/win_transport_test.py on the VM).
//! One object (RoseCat 6607): the check and the apply name the same object, a handle opened without
//! following a link, never the path twice; so a leaf swapped for a symlink or a junction after the
//! check cannot redirect the change. Linux: open(O_PATH|O_NOFOLLOW), statx on that descriptor, then
//! chmod through /proc/self/fd (the opened inode). macOS and the other BSDs: open(O_NOFOLLOW) and
//! fchmod for a file or a directory; a socket, which cannot be opened there, is checked and chmod'ed
//! by path, safe only because every socket this restricts was just bound by this process in a
//! directory only its owner can write. Windows: CreateFileW with FILE_FLAG_OPEN_REPARSE_POINT
//! (+ BACKUP_SEMANTICS), the kind and reparse tag from that handle (only IO_REPARSE_TAG_AF_UNIX, the
//! socket, is accepted), then SetSecurityInfo on it. A symlink, a junction or any other reparse point
//! is refused, never followed.
const std = @import("std");
const builtin = @import("builtin");

pub const Kind = enum { file, dir };

/// Tests only (compiled out of every other build): runs between the check and the apply, so a test
/// can swap the checked leaf there (RoseCat 6607).
pub var after_check: ?*const fn () void = null;

fn afterCheck() void {
    if (builtin.is_test) if (after_check) |f| f();
}

pub const Error = error{ InvalidSid, NoSpaceLeft, NotOwnerOnlyTarget, OwnerOnlyFailed, NameTooLong };

/// A plain SID string: `S-1-` then two or more dash-separated decimal fields, nothing else. Only
/// such a SID goes into the SDDL, so no ACE can be smuggled in through it.
pub fn validSid(sid: []const u8) bool {
    if (!std.mem.startsWith(u8, sid, "S-1-")) return false;
    var parts = std.mem.splitScalar(u8, sid["S-1-".len..], '-');
    var n: usize = 0;
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| if (!std.ascii.isDigit(c)) return false;
        n += 1;
    }
    return n >= 2;
}

/// The owner-only DACL as SDDL for `sid`: `D:P(A;;FA;;;<sid>)` for a file,
/// `D:P(A;OICI;FA;;;<sid>)` for a directory. Never cut: too small a buffer is NoSpaceLeft.
pub fn ownerOnlySddl(buf: []u8, sid: []const u8, kind: Kind) Error![]const u8 {
    if (!validSid(sid)) return error.InvalidSid;
    const inherit = switch (kind) {
        .file => "",
        .dir => "OICI",
    };
    return std.fmt.bufPrint(buf, "D:P(A;{s};FA;;;{s})", .{ inherit, sid }) catch error.NoSpaceLeft;
}

/// Restricts `path` to its owner (see the file comment). The path must exist and be of `kind`
/// (a socket counts as a file); a symlink is refused.
pub fn restrictToOwner(path: []const u8, kind: Kind) Error!void {
    if (comptime builtin.os.tag == .windows) return restrictWindows(path, kind);
    return restrictPosix(path, kind);
}

fn restrictPosix(path: []const u8, kind: Kind) Error!void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const z: [*:0]const u8 = @ptrCast(&buf);
    const mode: std.c.mode_t = switch (kind) {
        .file => 0o600,
        .dir => 0o700,
    };
    if (comptime builtin.os.tag == .linux) return restrictLinux(z, kind, mode);
    return restrictBsd(z, kind, mode);
}

fn kindOk(fmt: u32, kind: Kind) bool {
    return switch (kind) {
        .file => fmt == std.c.S.IFREG or fmt == std.c.S.IFSOCK,
        .dir => fmt == std.c.S.IFDIR,
    };
}

/// Linux: the object is opened once (O_PATH, never through a symlink); its type comes from that
/// descriptor and the chmod goes through /proc/self/fd to the same inode.
fn restrictLinux(z: [*:0]const u8, kind: Kind, mode: std.c.mode_t) Error!void {
    const linux = std.os.linux;
    const fd_rc = linux.open(z, .{ .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (linux.errno(fd_rc) != .SUCCESS) return error.NotOwnerOnlyTarget;
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    var sx: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &sx)) != .SUCCESS) return error.NotOwnerOnlyTarget;
    if (!kindOk(@as(u32, sx.mode) & std.c.S.IFMT, kind)) return error.NotOwnerOnlyTarget; // a symlink, a device, the wrong kind
    afterCheck();
    var proc_buf: [32]u8 = undefined;
    const proc = std.fmt.bufPrintZ(&proc_buf, "/proc/self/fd/{d}", .{fd}) catch return error.OwnerOnlyFailed;
    if (linux.errno(linux.chmod(proc, mode)) != .SUCCESS) return error.OwnerOnlyFailed;
}

/// macOS and the BSDs: a file or a directory is opened once (O_NOFOLLOW) and fchmod'ed; a socket
/// cannot be opened, so it is checked and chmod'ed by path (see the file comment's invariant).
fn restrictBsd(z: [*:0]const u8, kind: Kind, mode: std.c.mode_t) Error!void {
    const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true, .DIRECTORY = kind == .dir }, @as(std.c.mode_t, 0));
    if (fd >= 0) {
        defer _ = std.c.close(fd);
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) != 0) return error.NotOwnerOnlyTarget;
        if (!kindOk(@as(u32, @intCast(st.mode)) & std.c.S.IFMT, kind)) return error.NotOwnerOnlyTarget;
        afterCheck();
        if (std.c.fchmod(fd, mode) != 0) return error.OwnerOnlyFailed;
        return;
    }
    if (kind != .file or (try modeNoFollow(z)) & std.c.S.IFMT != std.c.S.IFSOCK) return error.NotOwnerOnlyTarget;
    afterCheck();
    if (std.c.chmod(z, mode) != 0) return error.OwnerOnlyFailed;
}

/// The mode of `path` itself (a symlink is not followed); missing is NotOwnerOnlyTarget.
fn modeNoFollow(z: [*:0]const u8) Error!u32 {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true }, &sx)) != .SUCCESS)
            return error.NotOwnerOnlyTarget;
        return sx.mode;
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, z, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return error.NotOwnerOnlyTarget;
    return @intCast(st.mode);
}

const win = struct {
    const BOOL = c_int;
    const DWORD = u32;
    const HANDLE = *anyopaque;
    const PSID = *anyopaque;
    const SidAndAttributes = extern struct { sid: PSID, attributes: DWORD };
    const TOKEN_QUERY: DWORD = 0x0008;
    const TOKEN_USER_CLASS: c_int = 1; // TokenUser
    const SDDL_REVISION_1: DWORD = 1;
    const SE_FILE_OBJECT: c_int = 1;
    const DACL_SECURITY_INFORMATION: DWORD = 0x00000004;
    const PROTECTED_DACL_SECURITY_INFORMATION: DWORD = 0x80000000;
    const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x10;
    const FILE_ATTRIBUTE_REPARSE_POINT: DWORD = 0x400;

    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn LocalFree(mem: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, sa: ?*anyopaque, disposition: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn GetFileInformationByHandleEx(h: HANDLE, class: c_int, info: *anyopaque, size: DWORD) callconv(.winapi) BOOL;
    extern "advapi32" fn SetSecurityInfo(h: HANDLE, kind: c_int, info: DWORD, owner: ?PSID, group: ?PSID, dacl: ?*anyopaque, sacl: ?*anyopaque) callconv(.winapi) DWORD;
    const FileAttributeTagInfo = extern struct { attributes: DWORD, reparse_tag: DWORD };
    const FILE_ATTRIBUTE_TAG_INFO_CLASS: c_int = 9;
    const IO_REPARSE_TAG_AF_UNIX: DWORD = 0x80000023;
    const READ_CONTROL: DWORD = 0x00020000;
    const WRITE_DAC: DWORD = 0x00040000;
    const FILE_READ_ATTRIBUTES: DWORD = 0x0080;
    const SHARE_ALL: DWORD = 0x7;
    const OPEN_EXISTING: DWORD = 3;
    const FILE_FLAG_OPEN_REPARSE_POINT: DWORD = 0x00200000;
    const FILE_FLAG_BACKUP_SEMANTICS: DWORD = 0x02000000;
    const INVALID_HANDLE: usize = std.math.maxInt(usize);
    extern "advapi32" fn OpenProcessToken(process: HANDLE, access: DWORD, token: *HANDLE) callconv(.winapi) BOOL;
    extern "advapi32" fn GetTokenInformation(token: HANDLE, class: c_int, info: ?*anyopaque, len: DWORD, ret: *DWORD) callconv(.winapi) BOOL;
    extern "advapi32" fn ConvertSidToStringSidW(sid: PSID, out: *?[*:0]u16) callconv(.winapi) BOOL;
    extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl: [*:0]const u16, rev: DWORD, sd: *?*anyopaque, size: ?*u32) callconv(.winapi) BOOL;
    extern "advapi32" fn GetSecurityDescriptorDacl(sd: *anyopaque, present: *BOOL, dacl: *?*anyopaque, defaulted: *BOOL) callconv(.winapi) BOOL;
};

/// The current user's SID as text (UTF-8), from the process token (Windows only).
pub fn currentUserSid(out: []u8) Error![]const u8 {
    var token: win.HANDLE = undefined;
    if (win.OpenProcessToken(win.GetCurrentProcess(), win.TOKEN_QUERY, &token) == 0) return error.OwnerOnlyFailed;
    defer _ = win.CloseHandle(token);
    var info: [256]u8 align(@alignOf(win.SidAndAttributes)) = undefined;
    var len: win.DWORD = 0;
    if (win.GetTokenInformation(token, win.TOKEN_USER_CLASS, &info, info.len, &len) == 0) return error.OwnerOnlyFailed;
    const user: *const win.SidAndAttributes = @ptrCast(&info);
    var wide: ?[*:0]u16 = null;
    if (win.ConvertSidToStringSidW(user.sid, &wide) == 0) return error.OwnerOnlyFailed;
    defer _ = win.LocalFree(wide);
    const w = std.mem.span(wide.?);
    if (w.len > out.len) return error.NoSpaceLeft;
    for (w, 0..) |c, i| {
        if (c > 0x7f) return error.InvalidSid;
        out[i] = @intCast(c);
    }
    return out[0..w.len];
}

fn restrictWindows(path: []const u8, kind: Kind) Error!void {
    var wpath: [std.fs.max_path_bytes + 1]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wpath[0 .. wpath.len - 1], path) catch return error.NameTooLong;
    wpath[n] = 0;
    const wz: [*:0]u16 = @ptrCast(&wpath);
    // One object: opened without following a reparse point; checked and changed through this handle.
    const h = win.CreateFileW(wz, win.READ_CONTROL | win.WRITE_DAC | win.FILE_READ_ATTRIBUTES, win.SHARE_ALL, null, win.OPEN_EXISTING, win.FILE_FLAG_OPEN_REPARSE_POINT | win.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (@intFromPtr(h) == win.INVALID_HANDLE) return error.NotOwnerOnlyTarget;
    defer _ = win.CloseHandle(h);
    var tag: win.FileAttributeTagInfo = undefined;
    if (win.GetFileInformationByHandleEx(h, win.FILE_ATTRIBUTE_TAG_INFO_CLASS, &tag, @sizeOf(win.FileAttributeTagInfo)) == 0) return error.NotOwnerOnlyTarget;
    const reparse = tag.attributes & win.FILE_ATTRIBUTE_REPARSE_POINT != 0;
    const socket = reparse and tag.reparse_tag == win.IO_REPARSE_TAG_AF_UNIX;
    if (reparse and !(socket and kind == .file)) return error.NotOwnerOnlyTarget; // a link or junction: never through it
    const is_dir = tag.attributes & win.FILE_ATTRIBUTE_DIRECTORY != 0;
    if (is_dir != (kind == .dir)) return error.NotOwnerOnlyTarget;
    var sid_buf: [192]u8 = undefined;
    var sddl_buf: [256]u8 = undefined;
    const sddl = try ownerOnlySddl(&sddl_buf, try currentUserSid(&sid_buf), kind);
    var wsddl: [256]u16 = undefined;
    for (sddl, 0..) |c, i| wsddl[i] = c;
    wsddl[sddl.len] = 0;
    var sd: ?*anyopaque = null;
    if (win.ConvertStringSecurityDescriptorToSecurityDescriptorW(@ptrCast(&wsddl), win.SDDL_REVISION_1, &sd, null) == 0)
        return error.OwnerOnlyFailed;
    defer _ = win.LocalFree(sd);
    var present: win.BOOL = 0;
    var defaulted: win.BOOL = 0;
    var dacl: ?*anyopaque = null;
    if (win.GetSecurityDescriptorDacl(sd.?, &present, &dacl, &defaulted) == 0 or present == 0 or dacl == null)
        return error.OwnerOnlyFailed;
    afterCheck();
    const info = win.DACL_SECURITY_INFORMATION | win.PROTECTED_DACL_SECURITY_INFORMATION;
    if (win.SetSecurityInfo(h, win.SE_FILE_OBJECT, info, null, null, dacl, null) != 0) return error.OwnerOnlyFailed;
}

/// The seam's C form (WS3.1's `<profile>\WebView2`, webview2_shim.cpp): 0 on success, -1 on any
/// failure. Windows only: the other backends call restrictToOwner from Zig.
pub fn zbRestrictToOwner(path: [*:0]const u16, is_dir: c_int) callconv(.c) c_int {
    var utf8: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&utf8, std.mem.span(path)) catch return -1;
    restrictToOwner(utf8[0..n], if (is_dir != 0) .dir else .file) catch return -1;
    return 0;
}

comptime {
    if (builtin.os.tag == .windows) @export(&zbRestrictToOwner, .{ .name = "zb_restrict_to_owner" });
}
