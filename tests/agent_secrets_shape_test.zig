//! The token shape is the setup-token shape (the user's requirement after the
//! S4a real-screen check; RoseCat's contract 5731):
//! ^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$, so 35 to 512 characters in all.
//! One rule for Save, storeFile and loadFile (`validToken`), so a seeded file
//! cannot bypass the window. A paste is trimmed of surrounding ASCII
//! whitespace (SP HT CR LF VT FF) first and only the trimmed token is kept;
//! inner whitespace is refused. API keys (`sk-ant-api03-`) are refused: the
//! plan's section 5 ("What we are NOT doing") lists API-key authentication.
//! The floor of 22: RFC 6819 §5.1.4.2.2 asks at least 128 bits of a token
//! handle, and 22 characters of a 64-symbol alphabet carry 132 (21 carry 126).
//! The bundled Claude CLI 2.1.294's own scanner rule for an OAuth token,
//! \b(sk-ant-(?:oat|ort)\d{2}-[\w-]{20,}), is looser. Canary tokens only.
const std = @import("std");
const secrets = @import("agent_secrets");

const prefix = "sk-ant-oat01-";
const canary = "sk-ant-oat01-ZBCANARY-0123456789abcdef";

/// `tokenFromPaste`, or error.TestNoTokenFromPaste before it exists (so this
/// file compiles, and fails by behavior, against the old store).
fn fromPaste(text: []const u8) !?[]const u8 {
    if (!@hasDecl(secrets, "tokenFromPaste")) return error.TestNoTokenFromPaste;
    return secrets.tokenFromPaste(text);
}

test "validToken: sk-ant-oat01- then 22 to 499 of [A-Za-z0-9_-]" {
    for ([_][]const u8{
        canary,
        prefix ++ "a" ** 22,
        prefix ++ "Az09_-" ** 4,
        prefix ++ "-" ** 22,
        prefix ++ "_" ** 22,
        prefix ++ "x" ** 499,
    }) |good| try std.testing.expect(secrets.validToken(good));
}

test "validToken: near misses are refused (table)" {
    for ([_][]const u8{
        "", // empty
        prefix, // the prefix alone
        prefix ++ "a" ** 21, // one short
        prefix ++ "x" ** 500, // one long (513 in all)
        "sk-ant-api03-" ++ "a" ** 40, // an API key
        "sk-ant-oat02-" ++ "a" ** 40, // wrong version
        "sk-ant-ort01-" ++ "a" ** 40, // a refresh token
        "sk-ant-oat01" ++ "a" ** 40, // no hyphen after the prefix
        "sk-ant-oat01_" ++ "a" ** 40,
        "SK-ANT-OAT01-" ++ "a" ** 40, // wrong case
        "sk-ant-Oat01-" ++ "a" ** 40,
        "sk-ant-oatO1-" ++ "a" ** 40, // a letter O for the zero
        "xsk-ant-oat01-" ++ "a" ** 40, // something before the prefix
        " " ++ canary, // surrounding whitespace (only a paste is trimmed)
        canary ++ "\n",
        prefix ++ "ZBCANARY 0123456789abcdef", // inner space
        prefix ++ "ZBCANARY\t0123456789abcdef", // inner tab
        prefix ++ "ZBCANARY\n0123456789abcdef", // inner newline
        prefix ++ "ZBCANARY.0123456789abcdef", // bad characters
        prefix ++ "ZBCANARY+0123456789abcdef",
        prefix ++ "ZBCANARY/0123456789abcdef",
        prefix ++ "ZBCANARY=0123456789abcdef",
        prefix ++ "ZBCANARY~0123456789abcdef",
        prefix ++ "ZBCANARY\x000123456789abcdef",
        prefix ++ "ZBCANARY\x7f0123456789abcdef",
        prefix ++ "ZBCANARY\xc3\xa90123456789abcdef", // é
        "not-a-token-at-all-but-long-enough",
        "a" ** 40, // the old printable-run shape
    }) |bad| {
        if (secrets.validToken(bad)) {
            std.debug.print("accepted near miss: {any}\n", .{bad});
            return error.TestUnexpectedResult;
        }
    }
}

test "tokenFromPaste trims surrounding ASCII whitespace, then checks the shape" {
    for ([_][]const u8{
        canary,
        " " ++ canary,
        canary ++ "\n",
        "\n  " ++ canary ++ " \r\n",
        "\t" ++ canary ++ "\t",
        "\x0b\x0c" ++ canary ++ "\x0c\x0b",
    }) |pasted| {
        const token = (try fromPaste(pasted)) orelse return error.TestExpectedToken;
        try std.testing.expectEqualStrings(canary, token);
        // A slice of the paste, not a copy: the caller wipes one buffer.
        try std.testing.expect(@intFromPtr(token.ptr) >= @intFromPtr(pasted.ptr) and
            @intFromPtr(token.ptr) + token.len <= @intFromPtr(pasted.ptr) + pasted.len);
    }
    for ([_][]const u8{
        "",
        " \n\t\r\x0b\x0c",
        " " ++ prefix ++ "ZBCANARY 0123456789abcdef ", // inner whitespace stays refused
        "\n" ++ prefix ++ "ZBCANARY\n0123456789abcdef\n",
        " sk-ant-api03-" ++ "a" ** 40 ++ " ",
        " " ++ prefix ++ "a" ** 21 ++ "\n",
        "\xc2\xa0" ++ canary, // a no-break space is not ASCII whitespace
        canary ++ "\x00",
    }) |bad| try std.testing.expect((try fromPaste(bad)) == null);
}

/// The oracle: ^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$ restated with std.ascii
/// and std.mem, not with validToken's own tests.
fn referenceToken(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "sk-ant-oat01-")) return false;
    const suffix = text["sk-ant-oat01-".len..];
    if (suffix.len < 22 or suffix.len > 499) return false;
    for (suffix) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

test "property (oracle): validToken matches ^sk-ant-oat01-[A-Za-z0-9_-]{22,499}$ over 10k strings" {
    var prng = std.Random.DefaultPrng.init(0x5E7_0A7);
    const random = prng.random();
    const prefixes = [_][]const u8{ prefix, prefix, prefix, prefix, "sk-ant-api03-", "SK-ANT-OAT01-", "sk-ant-oat01", "sk-ant-oat02-", "", " sk-ant-oat01-" };
    const suffix_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-";
    const odd = [_]u8{ ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x00, 0x7f, 0x80, 0xc3, 0xff, '.', '+', '/', '=', '~', '!' };
    var buf: [600]u8 = undefined;
    var accepted: usize = 0;
    for (0..10_000) |_| {
        const p = prefixes[random.uintLessThan(usize, prefixes.len)];
        @memcpy(buf[0..p.len], p);
        // Suffix lengths cluster around both bounds.
        const suffix_len: usize = switch (random.uintLessThan(u8, 3)) {
            0 => random.intRangeAtMost(usize, 19, 25),
            1 => random.intRangeAtMost(usize, 496, 502),
            else => random.uintAtMost(usize, 120),
        };
        for (buf[p.len..][0..suffix_len]) |*c| c.* = suffix_chars[random.uintLessThan(usize, suffix_chars.len)];
        // One string in four gets one odd byte somewhere (per string, not per
        // byte, so long suffixes stay valid often enough).
        if (suffix_len > 0 and random.uintLessThan(u8, 4) == 0) {
            buf[p.len + random.uintLessThan(usize, suffix_len)] = odd[random.uintLessThan(usize, odd.len)];
        }
        const text = buf[0 .. p.len + suffix_len];
        try std.testing.expectEqual(referenceToken(text), secrets.validToken(text));
        if (referenceToken(text)) accepted += 1;
    }
    try std.testing.expect(accepted > 1000 and accepted < 9000);
}

/// A temporary agent home; `seed`, unless null, is written as a 0600
/// secrets/claude-token in a 0700 secrets/.
const Home = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(seed: ?[]const u8) !Home {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const path = try std.testing.allocator.dupe(u8, buf[0..n]);
        errdefer std.testing.allocator.free(path);
        if (seed) |text| {
            try tmp.dir.createDir(io, "secrets", .default_dir);
            try tmp.dir.writeFile(io, .{ .sub_path = "secrets/claude-token", .data = text });
            try chmod(path, "secrets/claude-token", 0o600);
            try chmod(path, "secrets", 0o700);
        }
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *Home) void {
        std.testing.allocator.free(self.path);
        self.tmp.cleanup();
    }
};

fn chmod(home: []const u8, sub: []const u8, mode: u32) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ home, sub });
    if (std.c.chmod(full.ptr, @intCast(mode)) != 0) return error.ChmodFailed;
}

test "storeFile stores only the setup-token shape: a near miss writes nothing" {
    const io = std.testing.io;
    var home = try Home.init(null);
    defer home.deinit();
    for ([_][]const u8{ "a" ** 40, "sk-ant-api03-" ++ "a" ** 40, prefix ++ "a" ** 21, " " ++ canary }) |bad| {
        try std.testing.expectError(error.BadShape, secrets.storeFile(io, home.path, bad));
        try std.testing.expectError(error.FileNotFound, home.tmp.dir.access(io, "secrets", .{}));
    }
    try secrets.storeFile(io, home.path, prefix ++ "a" ** 22);
    try home.tmp.dir.access(io, "secrets/claude-token", .{});
}

test "loadFile refuses a seeded file that is not the setup-token shape" {
    for ([_][]const u8{ "a" ** 40, "a" ** 40 ++ "\n", "sk-ant-api03-" ++ "a" ** 40, prefix ++ "a" ** 21 ++ "\n", " " ++ canary }) |content| {
        var home = try Home.init(content);
        defer home.deinit();
        switch (secrets.loadFile(std.testing.io, std.testing.allocator, home.path)) {
            .refused => |reason| try std.testing.expectEqual(secrets.Refusal.bad_shape, reason),
            .token => |t| {
                secrets.wipeFree(std.testing.allocator, t);
                return error.TestExpectedRefusal;
            },
            .absent => return error.TestExpectedRefusal,
        }
    }
}
