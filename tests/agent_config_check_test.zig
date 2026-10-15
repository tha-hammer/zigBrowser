//! Chat drawer S3c (plan §2 "Per-session integrity", S3.10): the app re-hashes
//! the agent home's `.claude` against runtime/config-manifest.json before each
//! session. Each case builds a small home with a manifest computed here
//! (setup.py's format: relative path -> lowercase hex SHA-256), then changes it.

const std = @import("std");
const config = @import("agent_config_check");

const io = std.testing.io;
const gpa = std.testing.allocator;

const files = [_][2][]const u8{
    .{ "settings.json", "{\"hooks\": {}}\n" },
    .{ "CLAUDE.md", "# agent\n" },
    .{ "hooks/notify.py", "print('notify')\n" },
    .{ "commands/hello.md", "hello\n" },
    .{ "SAI/deep/README.md", "deep\n" },
};
const state_dirs = "[\"projects\", \"sessions\", \"todos\"]";

const Home = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init() !Home {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const self: Home = .{ .tmp = tmp, .path = try gpa.dupe(u8, buf[0..n]) };
        for (files) |f| try self.write(f[0], f[1]);
        try self.write(".claude/sessions/s1.json", "{}");
        try self.writeRaw("runtime/writable.json", state_dirs);
        try self.writeManifest();
        return self;
    }

    fn deinit(self: *Home) void {
        gpa.free(self.path);
        self.tmp.cleanup();
    }

    fn writeRaw(self: Home, rel: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(rel)) |dir| try self.tmp.dir.createDirPath(io, dir);
        try self.tmp.dir.writeFile(io, .{ .sub_path = rel, .data = data });
    }

    fn write(self: Home, rel: []const u8, data: []const u8) !void {
        if (std.mem.startsWith(u8, rel, ".claude/")) return self.writeRaw(rel, data);
        const full = try std.fs.path.join(gpa, &.{ ".claude", rel });
        defer gpa.free(full);
        try self.writeRaw(full, data);
    }

    /// The manifest of `files`, as setup.py writes it.
    fn writeManifest(self: Home) !void {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try out.writer.writeAll("{");
        for (files, 0..) |f, i| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(f[1], &digest, .{});
            try out.writer.print("{s}\"{s}\": \"{s}\"", .{ if (i == 0) "" else ", ", f[0], &std.fmt.bytesToHex(digest, .lower) });
        }
        try out.writer.writeAll("}");
        try self.writeRaw("runtime/config-manifest.json", out.written());
    }

    fn check(self: Home) config.Check {
        return config.check(gpa, io, self.path);
    }
};

test "an unchanged tree matches its manifest" {
    var home = try Home.init();
    defer home.deinit();
    try std.testing.expectEqual(config.Check.ok, home.check());
}

test "a writable state directory is not configuration: writing in it changes nothing" {
    var home = try Home.init();
    defer home.deinit();
    try home.write(".claude/sessions/s2.json", "{\"new\": 1}");
    try home.write(".claude/todos/t.json", "[]");
    try home.write(".claude/projects/p/transcript.jsonl", "{}\n");
    try std.testing.expectEqual(config.Check.ok, home.check());
}

test "a file edited, added or removed anywhere outside the state directories is a change" {
    const Change = struct { what: []const u8, rel: []const u8, data: ?[]const u8 };
    const changes = [_]Change{
        .{ .what = "settings.json edited", .rel = "settings.json", .data = "{\"hooks\": {}}\n\n" },
        .{ .what = "a nested file edited", .rel = "SAI/deep/README.md", .data = "deeper\n" },
        .{ .what = "a hook added", .rel = "hooks/planted.py", .data = "print('x')\n" },
        .{ .what = "a top-level file added", .rel = "settings.local.json", .data = "{}" },
        .{ .what = "a file added in a new directory", .rel = "agents/new/a.md", .data = "a" },
        .{ .what = "a command removed", .rel = "commands/hello.md", .data = null },
        .{ .what = "the same bytes, but truncated to empty", .rel = "CLAUDE.md", .data = "" },
    };
    for (changes) |c| {
        var home = try Home.init();
        defer home.deinit();
        const full = try std.fs.path.join(gpa, &.{ ".claude", c.rel });
        defer gpa.free(full);
        if (c.data) |data| try home.write(c.rel, data) else try home.tmp.dir.deleteFile(io, full);
        std.testing.expectEqual(config.Check.changed, home.check()) catch |err| {
            std.debug.print("not refused: {s}\n", .{c.what});
            return err;
        };
    }
}

test "fail closed: no manifest, a manifest that is not JSON, no writable.json, no .claude" {
    const Damage = struct { what: []const u8, rel: []const u8, data: ?[]const u8 };
    const damages = [_]Damage{
        .{ .what = "manifest missing", .rel = "runtime/config-manifest.json", .data = null },
        .{ .what = "manifest not JSON", .rel = "runtime/config-manifest.json", .data = "not json" },
        .{ .what = "manifest not an object of strings", .rel = "runtime/config-manifest.json", .data = "{\"settings.json\": 1}" },
        .{ .what = "writable.json missing", .rel = "runtime/writable.json", .data = null },
    };
    for (damages) |d| {
        var home = try Home.init();
        defer home.deinit();
        if (d.data) |data| try home.writeRaw(d.rel, data) else try home.tmp.dir.deleteFile(io, d.rel);
        std.testing.expectEqual(config.Check.changed, home.check()) catch |err| {
            std.debug.print("not refused: {s}\n", .{d.what});
            return err;
        };
    }
    var home = try Home.init();
    defer home.deinit();
    try home.tmp.dir.deleteTree(io, ".claude");
    try std.testing.expectEqual(config.Check.changed, home.check());
}

test "property (metamorphic): flipping any one byte of any configuration file is a change" {
    var prng = std.Random.DefaultPrng.init(0xC0_F1_6C);
    const random = prng.random();
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var home = try Home.init();
        defer home.deinit();
        const f = files[random.uintLessThan(usize, files.len)];
        const data = try gpa.dupe(u8, f[1]);
        defer gpa.free(data);
        const at = random.uintLessThan(usize, data.len);
        data[at] ^= @as(u8, 1) << random.int(u3);
        try home.write(f[0], data);
        try std.testing.expectEqual(config.Check.changed, home.check());
    }
}
