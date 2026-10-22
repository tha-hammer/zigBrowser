//! The Claude Agent token's shape and its explicit file store (chat-drawer
//! plan D11): `agent-home/secrets/claude-token`, read only when the file
//! store was chosen explicitly (`--agent-secret-store file`). The token goes
//! only to the Claude helper's fd 3; nothing here prints it, and every
//! refusal is a fixed word, never file content.
//!
//! Linux only (the agent drawer is GTK): the checks use openat/statx on the
//! descriptor that is then read, so a swapped path cannot slip in between.
const std = @import("std");
const linux = std.os.linux;

// WS6.1: the token SHAPE is split into the portable, platform-free agent_secrets_shape.zig so the
// Windows CredMan/DPAPI store reuses the one rule without pulling this module's std.os.linux file
// store. Re-exported here so Linux callers and the existing tests keep one import site — no
// duplicated validation (the refactor goal).
pub const shape = @import("agent_secrets_shape.zig");
pub const token_prefix = shape.token_prefix;
pub const min_suffix_len = shape.min_suffix_len;
pub const min_token_len = shape.min_token_len;
pub const max_token_len = shape.max_token_len;
pub const validToken = shape.validToken;
pub const tokenFromPaste = shape.tokenFromPaste;

pub const secrets_dir = "secrets";
pub const token_file = "claude-token";

pub const Refusal = enum {
    /// `secrets/` is not a directory (a symlink to one included).
    dir_not_directory,
    /// `secrets/` is not exactly 0700.
    dir_mode,
    /// `secrets/` or the token file belongs to another user.
    not_owner,
    /// The token file is not a regular file (a symlink, FIFO or directory).
    not_regular,
    /// The token file is not exactly 0600.
    file_mode,
    /// The content is not one valid token (one trailing newline allowed).
    bad_shape,
    /// The directory or file could not be opened or read.
    unreadable,
};

pub fn refusalWord(reason: Refusal) []const u8 {
    return switch (reason) {
        .dir_not_directory => "dir-not-directory",
        .dir_mode => "dir-mode",
        .not_owner => "not-owner",
        .not_regular => "not-regular",
        .file_mode => "file-mode",
        .bad_shape => "bad-shape",
        .unreadable => "unreadable",
    };
}

pub const Loaded = union(enum) {
    /// Owned by the caller's allocator; release it with `wipeFree`.
    token: []u8,
    /// No `secrets/` directory, or no token file in it.
    absent,
    refused: Refusal,
};

/// Zeroes a token before freeing it.
pub fn wipeFree(gpa: std.mem.Allocator, token: []u8) void {
    std.crypto.secureZero(u8, token);
    gpa.free(token);
}

/// The ownership rule: the object's owner is the effective user.
pub fn ownedBy(owner: linux.uid_t, euid: linux.uid_t) bool {
    return owner == euid;
}

/// Reads `<agent_home>/secrets/claude-token`. The directory must be a real
/// directory, 0700 and ours; the file a regular file, 0600 and ours (both
/// checked on the open descriptors, which are opened with O_NOFOLLOW, and
/// the file with O_NONBLOCK so a FIFO cannot block). One trailing newline is
/// stripped; anything else that is not exactly one valid token is refused.
pub fn loadFile(io: std.Io, gpa: std.mem.Allocator, agent_home: []const u8) Loaded {
    _ = io;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&path_buf, "{s}/" ++ secrets_dir, .{agent_home}) catch return .{ .refused = .unreadable };
    const euid = linux.geteuid();

    const dir = openNoFollow(linux.AT.FDCWD, dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    const dir_fd = switch (dir) {
        .fd => |fd| fd,
        .missing => return .absent,
        .not_dir => return .{ .refused = .dir_not_directory },
        .failed => return .{ .refused = .unreadable },
    };
    defer _ = linux.close(dir_fd);
    const dir_stat = statFd(dir_fd) orelse return .{ .refused = .unreadable };
    if (!linux.S.ISDIR(dir_stat.mode)) return .{ .refused = .dir_not_directory };
    if (!ownedBy(dir_stat.uid, euid)) return .{ .refused = .not_owner };
    if (dir_stat.mode & 0o7777 != 0o700) return .{ .refused = .dir_mode };

    const file = openNoFollow(dir_fd, token_file, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    const fd = switch (file) {
        .fd => |fd| fd,
        .missing => return .absent,
        // ELOOP (a symlink, refused by O_NOFOLLOW) or another non-file.
        .not_dir, .failed => return .{ .refused = .not_regular },
    };
    defer _ = linux.close(fd);
    const st = statFd(fd) orelse return .{ .refused = .unreadable };
    if (!linux.S.ISREG(st.mode)) return .{ .refused = .not_regular };
    if (!ownedBy(st.uid, euid)) return .{ .refused = .not_owner };
    if (st.mode & 0o7777 != 0o600) return .{ .refused = .file_mode };

    // At most a token, its newline and one byte more (to see "too long").
    var buf: [max_token_len + 2]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    var len: usize = 0;
    while (len < buf.len) {
        const rc = linux.read(fd, buf[len..].ptr, buf.len - len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return .{ .refused = .unreadable },
        }
        if (rc == 0) break;
        len += rc;
    }
    var text: []const u8 = buf[0..len];
    if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];
    if (!validToken(text)) return .{ .refused = .bad_shape };
    const token = gpa.dupe(u8, text) catch return .{ .refused = .unreadable };
    return .{ .token = token };
}

const Opened = union(enum) { fd: i32, missing, not_dir, failed };

fn openNoFollow(dir_fd: i32, path: [*:0]const u8, flags: linux.O) Opened {
    while (true) {
        const rc = linux.openat(dir_fd, path, flags, 0);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .fd = @intCast(rc) },
            .INTR => continue,
            .NOENT => .missing,
            .NOTDIR, .LOOP => .not_dir,
            else => .failed,
        };
    }
}

const FdStat = struct { mode: u32, uid: linux.uid_t };

fn statFd(fd: i32) ?FdStat {
    var sx: linux.Statx = undefined;
    const mask: linux.STATX = .{ .TYPE = true, .MODE = true, .UID = true };
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, mask, &sx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return .{ .mode = sx.mode, .uid = sx.uid };
}

// --- S4: the file store's write side ------------------------------------------

pub const StoreError = error{ BadShape, DirNotDirectory, DirMode, NotOwner, WriteFailed };

/// Stores `token` as the explicit file store: `secrets/` is created 0700 if
/// missing (and must otherwise be a real 0700 directory of ours); the token
/// goes into a fresh O_EXCL 0600 temp file in it, is synced, and is renamed
/// over `claude-token` (a planted symlink is replaced, never followed); then
/// the directory is synced. The temp file never outlives a failure.
pub fn storeFile(io: std.Io, agent_home: []const u8, token: []const u8) StoreError!void {
    _ = io;
    if (!validToken(token)) return error.BadShape;
    const dir_fd = openSecretsDir(agent_home, true) catch |err| switch (err) {
        error.DirMissing => return error.WriteFailed, // just created, then gone
        else => |e| return e,
    };
    defer _ = linux.close(dir_fd);

    var nonce: [8]u8 = undefined;
    if (linux.getrandom(&nonce, nonce.len, 0) != nonce.len) return error.WriteFailed;
    var tmp_buf: [64]u8 = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, ".{s}.{x}.tmp", .{ token_file, std.mem.readInt(u64, &nonce, .little) }) catch unreachable;
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true };
    const rc = linux.openat(dir_fd, tmp, flags, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.WriteFailed;
    const fd: i32 = @intCast(rc);
    var installed = false;
    defer if (!installed) {
        _ = linux.unlinkat(dir_fd, tmp, 0);
    };
    {
        defer _ = linux.close(fd);
        if (linux.errno(linux.fchmod(fd, 0o600)) != .SUCCESS) return error.WriteFailed;
        var off: usize = 0;
        while (off < token.len) {
            const n = linux.write(fd, token[off..].ptr, token.len - off);
            switch (linux.errno(n)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.WriteFailed,
            }
            if (n == 0) return error.WriteFailed;
            off += n;
        }
        if (linux.errno(linux.fsync(fd)) != .SUCCESS) return error.WriteFailed;
    }
    if (linux.errno(linux.renameat(dir_fd, tmp, dir_fd, token_file)) != .SUCCESS) return error.WriteFailed;
    installed = true;
    if (linux.errno(linux.fsync(dir_fd)) != .SUCCESS) return error.WriteFailed;
}

/// Deletes the token file. A missing `secrets/` or file is already removed.
pub fn removeFile(io: std.Io, agent_home: []const u8) StoreError!void {
    _ = io;
    const dir_fd = openSecretsDir(agent_home, false) catch |err| switch (err) {
        error.DirMissing => return,
        else => |e| return e,
    };
    defer _ = linux.close(dir_fd);
    switch (linux.errno(linux.unlinkat(dir_fd, token_file, 0))) {
        .SUCCESS, .NOENT => {},
        else => return error.WriteFailed,
    }
    if (linux.errno(linux.fsync(dir_fd)) != .SUCCESS) return error.WriteFailed;
}

/// Whether `loadFile` would return a token.
pub fn filePresent(io: std.Io, agent_home: []const u8) bool {
    const gpa = std.heap.c_allocator;
    return switch (loadFile(io, gpa, agent_home)) {
        .token => |t| blk: {
            wipeFree(gpa, t);
            break :blk true;
        },
        else => false,
    };
}

/// `<agent_home>/secrets` as an O_PATH-free directory descriptor, after the
/// same checks as loadFile (a real directory, 0700, ours); created 0700 when
/// `create` and missing.
fn openSecretsDir(agent_home: []const u8, create: bool) (StoreError || error{DirMissing})!i32 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&path_buf, "{s}/" ++ secrets_dir, .{agent_home}) catch return error.WriteFailed;
    if (create) {
        switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, dir_path, 0o700))) {
            .SUCCESS, .EXIST => {},
            else => return error.WriteFailed,
        }
    }
    const dir_fd = switch (openNoFollow(linux.AT.FDCWD, dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true })) {
        .fd => |fd| fd,
        .missing => return error.DirMissing,
        .not_dir => return error.DirNotDirectory,
        .failed => return error.WriteFailed,
    };
    errdefer _ = linux.close(dir_fd);
    const st = statFd(dir_fd) orelse return error.WriteFailed;
    if (!linux.S.ISDIR(st.mode)) return error.DirNotDirectory;
    if (!ownedBy(st.uid, linux.geteuid())) return error.NotOwner;
    if (st.mode & 0o7777 != 0o700) return error.DirMode;
    return dir_fd;
}

// --- which store is active (RoseCat 5648, D11) ---------------------------------

/// Values match agent_secrets_window.h's ZbSecretStore.
pub const Store = enum(c_int) { secret_service = 0, file = 1 };

/// The active store: this session's explicit "Save to a private file
/// instead" click, else an explicit --agent-secret-store, else the file when
/// secrets/claude-token exists (it only ever exists through one of those
/// explicit choices, so that is the choice persisting), else the Secret
/// Service.
pub fn effectiveStore(explicit: ?Store, session_file_choice: bool, file_exists: bool) Store {
    if (session_file_choice) return .file;
    if (explicit) |store| return store;
    return if (file_exists) .file else .secret_service;
}

/// Whether anything is named secrets/claude-token (lstat: a symlink is the
/// link itself; a file loadFile would refuse counts too, so its refusal is
/// reported instead of the keyring being asked).
pub fn fileExists(agent_home: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/" ++ secrets_dir ++ "/" ++ token_file, .{agent_home}) catch return false;
    var sx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &sx);
    return linux.errno(rc) == .SUCCESS;
}

// --- the e2e-only answer delays (ZIGBROWSER_AGENT_SECRETS_TEST_DELAY) ------------

/// How long each Secret Service answer is held back after the call, so a test
/// can make an old answer land late, and `preclear_ms`: how long Remove's clear
/// waits before it deletes, so a test can read the item while a clear is under
/// way (RoseCat 5821; honoured only with --e2e-protocol).
pub const TestDelay = struct { lookup_ms: u32 = 0, store_ms: u32 = 0, clear_ms: u32 = 0, preclear_ms: u32 = 0 };
pub const max_test_delay_ms = 10_000;

/// `lookup=MS,store=MS,clear=MS,preclear=MS`, any of them, each at most once; MS is
/// decimal 0-10000 with no sign and no leading zero.
pub fn parseTestDelay(text: []const u8) error{BadTestDelay}!TestDelay {
    if (text.len == 0) return error.BadTestDelay;
    var out: TestDelay = .{};
    var seen = [_]bool{ false, false, false, false };
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.BadTestDelay;
        const name = pair[0..eq];
        const digits = pair[eq + 1 ..];
        if (digits.len == 0 or digits.len > 5 or (digits.len > 1 and digits[0] == '0')) return error.BadTestDelay;
        var ms: u32 = 0;
        for (digits) |ch| {
            if (ch < '0' or ch > '9') return error.BadTestDelay;
            ms = ms * 10 + (ch - '0');
        }
        if (ms > max_test_delay_ms) return error.BadTestDelay;
        const index: usize = if (std.mem.eql(u8, name, "lookup")) 0 else if (std.mem.eql(u8, name, "store")) 1 else if (std.mem.eql(u8, name, "clear")) 2 else if (std.mem.eql(u8, name, "preclear")) 3 else return error.BadTestDelay;
        if (seen[index]) return error.BadTestDelay;
        seen[index] = true;
        switch (index) {
            0 => out.lookup_ms = ms,
            1 => out.store_ms = ms,
            2 => out.clear_ms = ms,
            else => out.preclear_ms = ms,
        }
    }
    return out;
}

// --- C exports (src/agent_secrets_window.c, src/agent_secrets.c) ----------------

comptime {
    if (@import("builtin").os.tag == .linux) {
        @export(&zb_secrets_token_from_paste, .{ .name = "zb_secrets_token_from_paste" });
        @export(&zb_secrets_store_file, .{ .name = "zb_secrets_store_file" });
        @export(&zb_secrets_remove_file, .{ .name = "zb_secrets_remove_file" });
        @export(&zb_secrets_file_present, .{ .name = "zb_secrets_file_present" });
        @export(&zb_secrets_load_file, .{ .name = "zb_secrets_load_file" });
        @export(&zb_secrets_effective_store, .{ .name = "zb_secrets_effective_store" });
        @export(&zb_secrets_parse_test_delay, .{ .name = "zb_secrets_parse_test_delay" });
    }
}

/// 1 with the trimmed token at text[*start..][0..*out_len], or 0.
fn zb_secrets_token_from_paste(text: [*]const u8, len: usize, start: *usize, out_len: *usize) callconv(.c) c_int {
    const token = tokenFromPaste(text[0..len]) orelse return 0;
    start.* = @intFromPtr(token.ptr) - @intFromPtr(text);
    out_len.* = token.len;
    return 1;
}

fn zb_secrets_store_file(agent_home: [*:0]const u8, token: [*]const u8, len: usize) callconv(.c) c_int {
    storeFile(undefined, std.mem.span(agent_home), token[0..len]) catch return -1;
    return 0;
}

fn zb_secrets_remove_file(agent_home: [*:0]const u8) callconv(.c) c_int {
    removeFile(undefined, std.mem.span(agent_home)) catch return -1;
    return 0;
}

fn zb_secrets_file_present(agent_home: [*:0]const u8) callconv(.c) c_int {
    return @intFromBool(filePresent(undefined, std.mem.span(agent_home)));
}

/// The file branch of zb_agent_token_fetch (src/agent_secrets.c): 0 with a
/// malloc'd, NUL-terminated token in `out` (the caller wipes and frees it,
/// zb_secrets_free), 1 when absent, 2 when refused, with the fixed refusal
/// word in `word`.
fn zb_secrets_load_file(agent_home: [*:0]const u8, out: *?[*:0]u8, word: *[*:0]const u8) callconv(.c) c_int {
    out.* = null;
    word.* = "";
    const gpa = std.heap.c_allocator;
    switch (loadFile(undefined, gpa, std.mem.span(agent_home))) {
        .token => |t| {
            defer wipeFree(gpa, t);
            const z = gpa.allocSentinel(u8, t.len, 0) catch {
                word.* = refusalWordZ(.unreadable);
                return 2;
            };
            @memcpy(z[0..t.len], t);
            out.* = z.ptr;
            return 0;
        },
        .absent => return 1,
        .refused => |reason| {
            word.* = refusalWordZ(reason);
            return 2;
        },
    }
}

fn refusalWordZ(reason: Refusal) [*:0]const u8 {
    return switch (reason) {
        inline else => |r| comptime blk: {
            const w = refusalWord(r);
            break :blk w[0..w.len :0];
        },
    };
}

/// `explicit`: -1 for no --agent-secret-store, else a Store value.
fn zb_secrets_effective_store(explicit: c_int, session_file_choice: c_int, agent_home: [*:0]const u8) callconv(.c) c_int {
    const flag: ?Store = switch (explicit) {
        0 => .secret_service,
        1 => .file,
        else => null,
    };
    return @intFromEnum(effectiveStore(flag, session_file_choice != 0, fileExists(std.mem.span(agent_home))));
}

/// 0 with the four delays filled in, -1 for a bad value.
fn zb_secrets_parse_test_delay(text: [*:0]const u8, lookup_ms: *c_uint, store_ms: *c_uint, clear_ms: *c_uint, preclear_ms: *c_uint) callconv(.c) c_int {
    const d = parseTestDelay(std.mem.span(text)) catch return -1;
    lookup_ms.* = d.lookup_ms;
    store_ms.* = d.store_ms;
    clear_ms.* = d.clear_ms;
    preclear_ms.* = d.preclear_ms;
    return 0;
}
