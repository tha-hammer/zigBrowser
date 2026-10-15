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

pub const min_token_len = 16;
pub const max_token_len = 512;

/// One line of 16-512 printable non-space characters: ^[\x21-\x7e]{16,512}$.
pub fn validToken(text: []const u8) bool {
    if (text.len < min_token_len or text.len > max_token_len) return false;
    for (text) |c| {
        if (c < 0x21 or c > 0x7e) return false;
    }
    return true;
}

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

// --- C exports (src/agent_secrets_window.c, src/agent_secrets.c) ----------------

comptime {
    if (@import("builtin").os.tag == .linux) {
        @export(&zb_secrets_valid_token, .{ .name = "zb_secrets_valid_token" });
        @export(&zb_secrets_store_file, .{ .name = "zb_secrets_store_file" });
        @export(&zb_secrets_remove_file, .{ .name = "zb_secrets_remove_file" });
        @export(&zb_secrets_file_present, .{ .name = "zb_secrets_file_present" });
        @export(&zb_secrets_load_file, .{ .name = "zb_secrets_load_file" });
    }
}

fn zb_secrets_valid_token(text: [*]const u8, len: usize) callconv(.c) c_int {
    return @intFromBool(validToken(text[0..len]));
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
