//! S6b2's provider seam, decided before the auth window exists (chat-drawer plan rev 16.18.15;
//! rev 16.18.1, RoseCat 5911). `agent_auth_seam.authTestSeam(e2e_protocol, value)` reads
//! ZIGBROWSER_AGENT_AUTH_TEST:
//! - unset: none;
//! - set without --e2e-protocol: ignored, whatever its text (not parsed), with the line
//!   `zigBrowser: ZIGBROWSER_AGENT_AUTH_TEST ignored without --e2e-protocol`;
//! - with it: exactly `proxy=` + proxy + `,ca=` + path, else refused `shape`; the proxy exactly
//!   `http://127.0.0.1:` + a port of 1-65535 (decimal, no sign, no leading zero), else `proxy`;
//!   the path absolute, naming a regular file that is not a symbolic link, of at most 65536
//!   bytes, else `ca`. A refusal's line is `zigBrowser: ZIGBROWSER_AGENT_AUTH_TEST refused
//!   (<word>)`. (A file the TLS library cannot load is also `ca`, decided in C when the window
//!   opens.)
//! Pure, but for the path's one no-follow open and its size.
const std = @import("std");
const seam = @import("agent_auth_seam");

const io = std.testing.io;
const gpa = std.testing.allocator;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",

    fn init() !*Fixture {
        const f = try gpa.create(Fixture);
        f.* = .{ .tmp = std.testing.tmpDir(.{}) };
        try f.tmp.dir.writeFile(io, .{ .sub_path = "ca.pem", .data = "-----BEGIN CERTIFICATE-----\n" });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "max.pem", .data = &([_]u8{'x'} ** 65536) });
        try f.tmp.dir.writeFile(io, .{ .sub_path = "big.pem", .data = &([_]u8{'x'} ** 65537) });
        try f.tmp.dir.createDir(io, "dir.pem", .default_dir);
        try f.tmp.dir.symLink(io, "ca.pem", "link.pem", .{});
        f.root = f.root_buf[0..try f.tmp.dir.realPath(io, &f.root_buf)];
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        gpa.destroy(f);
    }

    /// The seam's value with `proxy` and the fixture's file `name` (or `path` as given when it
    /// starts with '!').
    fn value(f: *Fixture, buf: []u8, proxy: []const u8, name: []const u8) ![]const u8 {
        if (name.len > 0 and name[0] == '!') return std.fmt.bufPrint(buf, "proxy={s},ca={s}", .{ proxy, name[1..] });
        return std.fmt.bufPrint(buf, "proxy={s},ca={s}/{s}", .{ proxy, f.root, name });
    }
};

fn expectRefused(want: seam.Reason, got: seam.Seam) !void {
    switch (got) {
        .refused => |r| try std.testing.expectEqual(want, r),
        else => {
            std.debug.print("want refused {s}, got {s}\n", .{ @tagName(want), @tagName(got) });
            return error.TestUnexpectedResult;
        },
    }
}

test "unset is nothing, with or without --e2e-protocol" {
    try std.testing.expect(seam.authTestSeam(true, null) == .none);
    try std.testing.expect(seam.authTestSeam(false, null) == .none);
    var buf: [256]u8 = undefined;
    try std.testing.expect(seam.stderrLine(&buf, .none) == null);
}

test "without --e2e-protocol it is ignored, whatever its text, with the fixed line" {
    for ([_][]const u8{ "proxy=http://127.0.0.1:8080,ca=/etc/hosts", "garbage", "" }) |v| {
        try std.testing.expect(seam.authTestSeam(false, v) == .ignored);
    }
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("zigBrowser: ZIGBROWSER_AGENT_AUTH_TEST ignored without --e2e-protocol", seam.stderrLine(&buf, .ignored).?);
}

test "the one accepted shape gives the port and the CA path" {
    const f = try Fixture.init();
    defer f.deinit();
    var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    for ([_]struct { []const u8, u16 }{ .{ "1", 1 }, .{ "8080", 8080 }, .{ "65535", 65535 } }) |p| {
        var pbuf: [64]u8 = undefined;
        const proxy = try std.fmt.bufPrint(&pbuf, "http://127.0.0.1:{s}", .{p[0]});
        for ([_][]const u8{ "ca.pem", "max.pem" }) |name| {
            const v = try f.value(&buf, proxy, name);
            switch (seam.authTestSeam(true, v)) {
                .ok => |ok| {
                    try std.testing.expectEqual(p[1], ok.port);
                    try std.testing.expect(std.mem.endsWith(u8, ok.ca, name));
                    try std.testing.expect(std.mem.startsWith(u8, ok.ca, f.root));
                },
                else => |other| {
                    std.debug.print("{s}: {s}\n", .{ v, @tagName(other) });
                    return error.TestUnexpectedResult;
                },
            }
        }
    }
    var lbuf: [256]u8 = undefined;
    try std.testing.expect(seam.stderrLine(&lbuf, seam.authTestSeam(true, try f.value(&buf, "http://127.0.0.1:8080", "ca.pem"))) == null);
}

test "anything but proxy=...,ca=... is refused: shape" {
    const f = try Fixture.init();
    defer f.deinit();
    var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const good = try std.fmt.allocPrint(gpa, "{s}/ca.pem", .{f.root});
    defer gpa.free(good);
    const cases = [_][]const u8{
        "",
        "proxy=http://127.0.0.1:8080",
        "ca=/x",
        "PROXY=http://127.0.0.1:8080,ca=@",
        " proxy=http://127.0.0.1:8080,ca=@",
        "proxy=http://127.0.0.1:8080;ca=@",
        "proxy=http://127.0.0.1:8080, ca=@",
        "proxy=http://127.0.0.1:8080,CA=@",
        "ca=@,proxy=http://127.0.0.1:8080",
        "proxy=http://127.0.0.1:8080,extra=1,ca=@",
    };
    for (cases) |template| {
        const v = try std.mem.replaceOwned(u8, gpa, template, "@", good);
        defer gpa.free(v);
        expectRefused(.shape, seam.authTestSeam(true, v)) catch |e| {
            std.debug.print("value: {s}\n", .{v});
            return e;
        };
    }
    _ = &buf;
}

test "a proxy that is not http://127.0.0.1:<1-65535> is refused: proxy" {
    const f = try Fixture.init();
    defer f.deinit();
    var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    const proxies = [_][]const u8{
        "",                         "http://127.0.0.1:0",      "http://127.0.0.1:65536", "http://127.0.0.1:080",
        "http://127.0.0.1:+80",     "http://127.0.0.1:-1",     "http://127.0.0.1:",      "http://127.0.0.1",
        "http://127.0.0.1:80/",     "http://127.0.0.1:80 ",    "https://127.0.0.1:8080", "http://localhost:8080",
        "http://127.0.0.2:8080",    "http://[::1]:8080",       "HTTP://127.0.0.1:8080",  "http://127.1:8080",
        "http://u@127.0.0.1:8080",  "socks5://127.0.0.1:1080", "http://127.0.0.1:99999999999999999999",
    };
    for (proxies) |p| {
        const v = try f.value(&buf, p, "ca.pem");
        expectRefused(.proxy, seam.authTestSeam(true, v)) catch |e| {
            std.debug.print("proxy: '{s}'\n", .{p});
            return e;
        };
    }
}

test "a CA that is not an absolute path to a regular, unlinked file of at most 64 KiB: ca" {
    const f = try Fixture.init();
    defer f.deinit();
    var buf: [std.fs.max_path_bytes + 64]u8 = undefined;
    // A relative path that does reach the CA from the working directory is still refused.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memset(&cwd_buf, 0);
    if (std.os.linux.errno(std.os.linux.getcwd(&cwd_buf, cwd_buf.len)) != .SUCCESS) return error.NoCwd;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    const ca_abs = try std.fs.path.join(gpa, &.{ f.root, "ca.pem" });
    defer gpa.free(ca_abs);
    const rel = try std.fs.path.relative(gpa, cwd, null, cwd, ca_abs);
    defer gpa.free(rel);
    try std.testing.expect(rel.len > 0 and rel[0] != '/');
    const rel_name = try std.fmt.allocPrint(gpa, "!{s}", .{rel});
    defer gpa.free(rel_name);
    for ([_][]const u8{ "big.pem", "dir.pem", "link.pem", "missing.pem", "!ca.pem", "!", "!./ca.pem", rel_name }) |name| {
        const v = try f.value(&buf, "http://127.0.0.1:8080", name);
        expectRefused(.ca, seam.authTestSeam(true, v)) catch |e| {
            std.debug.print("ca: {s}\n", .{name});
            return e;
        };
    }
}

test "a refusal's line names its word" {
    var buf: [256]u8 = undefined;
    inline for (.{ seam.Reason.shape, seam.Reason.proxy, seam.Reason.ca }) |r| {
        const want = "zigBrowser: ZIGBROWSER_AGENT_AUTH_TEST refused (" ++ @tagName(r) ++ ")";
        try std.testing.expectEqualStrings(want, seam.stderrLine(&buf, .{ .refused = r }).?);
    }
    try std.testing.expectEqualStrings("ZIGBROWSER_AGENT_AUTH_TEST", seam.env);
}
