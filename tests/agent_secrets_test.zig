//! The Claude Agent token store's pure checks (src/agent_secrets.zig): the
//! read-only loader of the explicit file store, agent-home/secrets/claude-token
//! (D11; S3b reads it, S4 writes it), and the file store's write side.
//! Canary tokens only.
const std = @import("std");
const secrets = @import("agent_secrets");

const canary = "sk-ant-oat01-ZBCANARY-0123456789abcdef";

// The token shape (validToken, tokenFromPaste) and its property test live in
// tests/agent_secrets_shape_test.zig.

/// A temporary agent home with `secrets/` (dir_mode) and, unless null,
/// `secrets/claude-token` (file_mode) holding `content`.
const Home = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(dir_mode: ?u32, content: ?[]const u8, file_mode: u32) !Home {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const path = try std.testing.allocator.dupe(u8, buf[0..n]);
        if (dir_mode) |mode| {
            try tmp.dir.createDir(io, "secrets", .default_dir);
            if (content) |text| {
                try tmp.dir.writeFile(io, .{ .sub_path = "secrets/claude-token", .data = text });
                try chmod(path, "secrets/claude-token", file_mode);
            }
            try chmod(path, "secrets", mode);
        }
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Home) void {
        chmod(self.path, "secrets", 0o700) catch {};
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

fn chmod(home: []const u8, sub: []const u8, mode: u32) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ home, sub });
    if (std.c.chmod(full.ptr, @intCast(mode)) != 0) return error.ChmodFailed;
}

fn load(home: *const Home) secrets.Loaded {
    return secrets.loadFile(std.testing.io, std.testing.allocator, home.path);
}

fn expectRefused(want: secrets.Refusal, got: secrets.Loaded) !void {
    switch (got) {
        .refused => |reason| try std.testing.expectEqual(want, reason),
        .token => |t| {
            secrets.wipeFree(std.testing.allocator, t);
            return error.TestExpectedRefusal;
        },
        .absent => return error.TestExpectedRefusal,
    }
}

test "loadFile returns the token, with one trailing newline stripped" {
    for ([_][]const u8{ canary, canary ++ "\n" }) |content| {
        var home = try Home.init(0o700, content, 0o600);
        defer home.deinit();
        switch (load(&home)) {
            .token => |t| {
                defer secrets.wipeFree(std.testing.allocator, t);
                try std.testing.expectEqualStrings(canary, t);
            },
            else => return error.TestExpectedToken,
        }
    }
}

test "loadFile: no secrets directory, or no token file, is absent" {
    var no_dir = try Home.init(null, null, 0);
    defer no_dir.deinit();
    try std.testing.expectEqual(secrets.Loaded.absent, load(&no_dir));
    var no_file = try Home.init(0o700, null, 0);
    defer no_file.deinit();
    try std.testing.expectEqual(secrets.Loaded.absent, load(&no_file));
}

test "loadFile refuses a token file that is not exactly 0600" {
    for ([_]u32{ 0o644, 0o640, 0o604, 0o400, 0o700, 0o660 }) |mode| {
        var home = try Home.init(0o700, canary, mode);
        defer home.deinit();
        try expectRefused(.file_mode, load(&home));
    }
}

test "loadFile refuses a secrets directory that is not exactly 0700" {
    for ([_]u32{ 0o755, 0o750, 0o711, 0o777 }) |mode| {
        var home = try Home.init(mode, canary, 0o600);
        defer home.deinit();
        try expectRefused(.dir_mode, load(&home));
    }
}

test "loadFile refuses a symlink, a directory or a FIFO in place of the token file, without blocking" {
    const io = std.testing.io;
    {
        var home = try Home.init(0o700, null, 0);
        defer home.deinit();
        try home.tmp.dir.writeFile(io, .{ .sub_path = "elsewhere", .data = canary });
        try home.tmp.dir.symLink(io, "../elsewhere", "secrets/claude-token", .{});
        try expectRefused(.not_regular, load(&home));
    }
    {
        var home = try Home.init(0o700, null, 0);
        defer home.deinit();
        try home.tmp.dir.createDir(io, "secrets/claude-token", .default_dir);
        try expectRefused(.not_regular, load(&home));
    }
    {
        var home = try Home.init(0o700, null, 0);
        defer home.deinit();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const fifo = try std.fmt.bufPrintZ(&buf, "{s}/secrets/claude-token", .{home.path});
        if (std.os.linux.errno(std.os.linux.mknod(fifo.ptr, std.os.linux.S.IFIFO | 0o600, 0)) != .SUCCESS) return error.MkfifoFailed;
        try expectRefused(.not_regular, load(&home)); // no writer: a blocking open would hang here
    }
}

test "loadFile refuses a symlinked secrets directory" {
    const io = std.testing.io;
    var home = try Home.init(null, null, 0);
    defer home.deinit();
    try home.tmp.dir.createDir(io, "real-secrets", .default_dir);
    try chmod(home.path, "real-secrets", 0o700);
    try home.tmp.dir.writeFile(io, .{ .sub_path = "real-secrets/claude-token", .data = canary });
    try chmod(home.path, "real-secrets/claude-token", 0o600);
    try home.tmp.dir.symLink(io, "real-secrets", "secrets", .{});
    try expectRefused(.dir_not_directory, load(&home));
}

test "loadFile refuses content that is not one valid token" {
    for ([_][]const u8{
        "",
        "\n",
        "short\n",
        canary ++ "\n\n",
        "sk-ant-oat01 ZBCANARY-0123456789abcdef",
        canary ++ "\r\n",
        "a" ** 513,
        "a" ** 4096,
    }) |content| {
        var home = try Home.init(0o700, content, 0o600);
        defer home.deinit();
        try expectRefused(.bad_shape, load(&home));
    }
}

test "checkOwner: a file or directory owned by another user is refused (stat-level rule)" {
    try std.testing.expect(secrets.ownedBy(1000, 1000));
    try std.testing.expect(!secrets.ownedBy(0, 1000));
    try std.testing.expect(!secrets.ownedBy(1001, 1000));
}

test "the refusal reasons are fixed words" {
    inline for (std.meta.fields(secrets.Refusal)) |field| {
        const word = secrets.refusalWord(@enumFromInt(field.value));
        try std.testing.expect(word.len > 0);
        for (word) |c| try std.testing.expect(std.ascii.isLower(c) or c == '-');
    }
}

// --- S4: the file store's write side (storeFile, removeFile, filePresent) ---

fn statMode(home: []const u8, sub: []const u8) !u32 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ home, sub });
    var sx: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, full.ptr, std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true }, &sx);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => sx.mode,
        .NOENT => error.FileNotFound,
        else => error.StatFailed,
    };
}

fn entries(home: *const Home, sub: []const u8) !usize {
    var dir = try home.tmp.dir.openDir(std.testing.io, sub, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(std.testing.io)) |_| n += 1;
    return n;
}

test "storeFile creates a 0700 secrets/ and a 0600 token file that loadFile reads back" {
    var home = try Home.init(null, null, 0);
    defer home.deinit();
    try secrets.storeFile(std.testing.io, home.path, canary);
    try std.testing.expectEqual(@as(u32, std.os.linux.S.IFDIR | 0o700), try statMode(home.path, "secrets"));
    try std.testing.expectEqual(@as(u32, std.os.linux.S.IFREG | 0o600), try statMode(home.path, "secrets/claude-token"));
    try std.testing.expectEqual(@as(usize, 1), try entries(&home, "secrets")); // no temp file left
    switch (load(&home)) {
        .token => |t| {
            defer secrets.wipeFree(std.testing.allocator, t);
            try std.testing.expectEqualStrings(canary, t);
        },
        else => return error.TestExpectedToken,
    }
    try std.testing.expect(secrets.filePresent(std.testing.io, home.path));
}

test "storeFile replaces a stored token, and replaces a planted symlink instead of following it" {
    const io = std.testing.io;
    var home = try Home.init(0o700, canary, 0o600);
    defer home.deinit();
    const second = "sk-ant-oat01-ZBCANARY-second-0123456789";
    try secrets.storeFile(io, home.path, second);
    try std.testing.expectEqual(@as(u32, std.os.linux.S.IFREG | 0o600), try statMode(home.path, "secrets/claude-token"));

    try home.tmp.dir.writeFile(io, .{ .sub_path = "target", .data = "untouched" });
    try home.tmp.dir.deleteFile(io, "secrets/claude-token");
    try home.tmp.dir.symLink(io, "../target", "secrets/claude-token", .{});
    try secrets.storeFile(io, home.path, canary);
    try std.testing.expectEqual(@as(u32, std.os.linux.S.IFREG | 0o600), try statMode(home.path, "secrets/claude-token"));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("untouched", try home.tmp.dir.readFile(io, "target", &buf));
}

test "storeFile refuses an invalid token and a secrets/ that is not ours to trust, writing nothing" {
    {
        var home = try Home.init(null, null, 0);
        defer home.deinit();
        try std.testing.expectError(error.BadShape, secrets.storeFile(std.testing.io, home.path, "not a token"));
        try std.testing.expectError(error.FileNotFound, statMode(home.path, "secrets"));
    }
    {
        var home = try Home.init(0o755, null, 0);
        defer home.deinit();
        try std.testing.expectError(error.DirMode, secrets.storeFile(std.testing.io, home.path, canary));
        try std.testing.expectEqual(@as(usize, 0), try entries(&home, "secrets"));
    }
    {
        const io = std.testing.io;
        var home = try Home.init(null, null, 0);
        defer home.deinit();
        try home.tmp.dir.createDir(io, "elsewhere", .default_dir);
        try home.tmp.dir.symLink(io, "elsewhere", "secrets", .{});
        try std.testing.expectError(error.DirNotDirectory, secrets.storeFile(io, home.path, canary));
        try std.testing.expectEqual(@as(usize, 0), try entries(&home, "elsewhere"));
    }
}

test "removeFile deletes the token file; removing an absent token is fine" {
    var home = try Home.init(0o700, canary, 0o600);
    defer home.deinit();
    try secrets.removeFile(std.testing.io, home.path);
    try std.testing.expectEqual(secrets.Loaded.absent, load(&home));
    try std.testing.expect(!secrets.filePresent(std.testing.io, home.path));
    try secrets.removeFile(std.testing.io, home.path);
    var none = try Home.init(null, null, 0);
    defer none.deinit();
    try secrets.removeFile(std.testing.io, none.path);
}

// --- S4a follow-up (RoseCat 5648): which store is active, and the e2e delay seam ---

test "effectiveStore: this session's file click, then the flag, then a token file, then the Secret Service" {
    const S = secrets.Store;
    // Exhaustive over (explicit flag, session click, file exists).
    for ([_]?S{ null, .secret_service, .file }) |explicit| {
        for ([_]bool{ false, true }) |clicked| {
            for ([_]bool{ false, true }) |exists| {
                const want: S = if (clicked)
                    .file
                else if (explicit) |e|
                    e
                else if (exists)
                    .file
                else
                    .secret_service;
                try std.testing.expectEqual(want, secrets.effectiveStore(explicit, clicked, exists));
            }
        }
    }
}

test "fileExists: any entry named secrets/claude-token counts (a refused one too), never followed" {
    const io = std.testing.io;
    {
        var none = try Home.init(null, null, 0);
        defer none.deinit();
        try std.testing.expect(!secrets.fileExists(none.path));
        try none.tmp.dir.createDir(io, "secrets", .default_dir);
        try std.testing.expect(!secrets.fileExists(none.path));
    }
    {
        var good = try Home.init(0o700, canary, 0o600);
        defer good.deinit();
        try std.testing.expect(secrets.fileExists(good.path));
    }
    {
        var loose = try Home.init(0o700, canary, 0o644); // loadFile refuses it; it still selects the file store
        defer loose.deinit();
        try std.testing.expect(secrets.fileExists(loose.path));
    }
    {
        var dangling = try Home.init(0o700, null, 0);
        defer dangling.deinit();
        try dangling.tmp.dir.symLink(io, "../nowhere", "secrets/claude-token", .{});
        try std.testing.expect(secrets.fileExists(dangling.path)); // the link itself, not its target
    }
}

test "parseTestDelay: lookup=, store=, clear=, preclear= in milliseconds (0-10000), each at most once" {
    const all = try secrets.parseTestDelay("lookup=3000,store=4000,clear=0,preclear=5000");
    try std.testing.expectEqual(secrets.TestDelay{ .lookup_ms = 3000, .store_ms = 4000, .clear_ms = 0, .preclear_ms = 5000 }, all);
    try std.testing.expectEqual(secrets.TestDelay{ .preclear_ms = 10000 }, try secrets.parseTestDelay("preclear=10000"));
    try std.testing.expectEqual(secrets.TestDelay{ .store_ms = 10000 }, try secrets.parseTestDelay("store=10000"));
    try std.testing.expectEqual(secrets.TestDelay{ .clear_ms = 1, .lookup_ms = 2 }, try secrets.parseTestDelay("clear=1,lookup=2"));
    const bad = [_][]const u8{ "", ",", "lookup", "lookup=", "lookup=-1", "lookup=+1", "lookup=01", "lookup=10001",
        "lookup=1x", "fetch=1", "lookup=1,lookup=2", "preclear=1,preclear=2", "preclear=10001", "PRECLEAR=1", "pre-clear=1", "lookup=1,", ",lookup=1", "lookup=1 ,store=2", "LOOKUP=1" };
    for (bad) |text| {
        if (secrets.parseTestDelay(text)) |_| {
            std.debug.print("accepted: {s}\n", .{text});
            return error.TestExpectedError;
        } else |err| try std.testing.expectEqual(error.BadTestDelay, err);
    }
}
