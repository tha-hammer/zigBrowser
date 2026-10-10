//! N5: cookies.getAll / set / delete / import through a CookiePort.
const std = @import("std");
const automation = @import("automation");

const cookie_routes = automation.cookie_routes;
const cookie_port = automation.cookie_port;

const gpa = std.testing.allocator;
const io = std.testing.io;
const fakes = @import("automation/fake_page_port.zig");

const FakeCookiePort = struct {
    sets: std.ArrayListUnmanaged([]u8) = .empty,
    deletes: std.ArrayListUnmanaged([]u8) = .empty,
    get_url: ?[]u8 = null,
    store_json: []const u8 = "[]",
    fail: ?cookie_port.PortError = null,

    fn deinit(self: *FakeCookiePort) void {
        for (self.sets.items) |s| gpa.free(s);
        self.sets.deinit(gpa);
        for (self.deletes.items) |s| gpa.free(s);
        self.deletes.deinit(gpa);
        if (self.get_url) |u| gpa.free(u);
    }

    fn port(self: *FakeCookiePort) cookie_port.CookiePort {
        return .{ .ptr = self, .vtable = &.{ .getAll = getAll, .set = set, .delete = delete } };
    }

    fn from(ptr: *anyopaque) *FakeCookiePort {
        return @ptrCast(@alignCast(ptr));
    }

    fn getAll(ptr: *anyopaque, a: std.mem.Allocator, url: ?[]const u8, _: u64) cookie_port.PortError![]u8 {
        const self = from(ptr);
        if (self.fail) |err| return err;
        if (url) |u| self.get_url = gpa.dupe(u8, u) catch return error.OutOfMemory;
        return a.dupe(u8, self.store_json);
    }

    fn set(ptr: *anyopaque, cookie_json: []const u8, _: u64) cookie_port.PortError!void {
        const self = from(ptr);
        if (self.fail) |err| return err;
        self.sets.append(gpa, gpa.dupe(u8, cookie_json) catch return error.OutOfMemory) catch return error.OutOfMemory;
    }

    fn delete(ptr: *anyopaque, name: []const u8, domain: ?[]const u8, _: u64) cookie_port.PortError!void {
        const self = from(ptr);
        if (self.fail) |err| return err;
        const entry = std.fmt.allocPrint(gpa, "{s}@{s}", .{ name, domain orelse "*" }) catch return error.OutOfMemory;
        self.deletes.append(gpa, entry) catch return error.OutOfMemory;
    }
};

fn call(fake: ?*FakeCookiePort, method: []const u8, params: []const u8) !automation.engine.Outcome {
    return callWithSink(fake, method, params, null);
}

fn callWithSink(fake: ?*FakeCookiePort, method: []const u8, params: []const u8, sink: ?automation.telemetry.TelemetrySink) !automation.engine.Outcome {
    const Call = struct {
        port: ?cookie_port.CookiePort,
        verb: cookie_routes.Verb,
        params: []const u8,

        fn run(c: @This(), a: std.mem.Allocator, ext: *automation.engine.External) error{OutOfMemory}!automation.engine.Outcome {
            return cookie_routes.handle(a, io, c.port, ext, c.verb, c.params);
        }
    };
    var clock = fakes.FakeClock.init(gpa);
    defer clock.deinit();
    var eng = automation.engine.Engine.init(automation.page_port.no_page, clock.clock());
    return eng.executeExternal(gpa, method, "cookies", .{ .route = .{ .telemetry_sink = sink } }, Call{
        .port = if (fake) |f| f.port() else null,
        .verb = cookie_routes.verbFromMethod(method).?,
        .params = params,
    }, Call.run);
}

test "only the cookie methods are recognised" {
    for ([_][]const u8{ "cookies.getAll", "cookies.set", "cookies.delete", "cookies.import" }) |m| {
        try std.testing.expect(cookie_routes.verbFromMethod(m) != null);
    }
    for ([_][]const u8{ "cookies.get", "cookies.clear", "cookies.", "dom.click" }) |m| {
        try std.testing.expect(cookie_routes.verbFromMethod(m) == null);
    }
}

test "getAll wraps the store array as {cookies} and passes url" {
    var fake = FakeCookiePort{ .store_json = "[{\"name\":\"sid\",\"value\":\"v\",\"domain\":\"example.com\",\"path\":\"/\",\"expires\":-1,\"httpOnly\":true,\"secure\":true}]" };
    defer fake.deinit();

    var all = try call(&fake, "cookies.getAll", "{}");
    defer all.deinit(gpa);
    try std.testing.expectEqualStrings("{\"cookies\":[{\"name\":\"sid\",\"value\":\"v\",\"domain\":\"example.com\",\"path\":\"/\",\"expires\":-1,\"httpOnly\":true,\"secure\":true}]}", all.result);
    try std.testing.expect(fake.get_url == null);

    var scoped = try call(&fake, "cookies.getAll", "{\"url\":\"https://example.com/a\"}");
    defer scoped.deinit(gpa);
    try std.testing.expectEqualStrings("https://example.com/a", fake.get_url.?);
}

test "getAll rejects a malformed store answer without echoing it" {
    var fake = FakeCookiePort{ .store_json = "{\"not\":\"an array secret\"}" };
    defer fake.deinit();
    var outcome = try call(&fake, "cookies.getAll", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32603), outcome.failure.code);
    try std.testing.expect(outcome.failure.data_json == null);
}

test "set normalizes defaults and forwards one cookie object" {
    var fake = FakeCookiePort{};
    defer fake.deinit();
    var outcome = try call(&fake, "cookies.set", "{\"name\":\"sid\",\"value\":\"abc\",\"domain\":\".example.com\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", outcome.result);
    try std.testing.expectEqualStrings(
        "{\"name\":\"sid\",\"value\":\"abc\",\"domain\":\".example.com\",\"path\":\"/\",\"expires\":-1,\"httpOnly\":false,\"secure\":false}",
        fake.sets.items[0],
    );

    var full = try call(&fake, "cookies.set", "{\"name\":\"a\",\"value\":\"\",\"domain\":\"x.test\",\"path\":\"/p\",\"expires\":1893456000,\"httpOnly\":true,\"secure\":true,\"sameSite\":\"Lax\"}");
    defer full.deinit(gpa);
    try std.testing.expectEqualStrings(
        "{\"name\":\"a\",\"value\":\"\",\"domain\":\"x.test\",\"path\":\"/p\",\"expires\":1893456000,\"httpOnly\":true,\"secure\":true,\"sameSite\":\"Lax\"}",
        fake.sets.items[1],
    );
}

test "set rejects invalid cookies with -32602 and never echoes the value" {
    var fake = FakeCookiePort{};
    defer fake.deinit();
    const bad = [_][]const u8{
        "{\"value\":\"v\",\"domain\":\"d.test\"}",
        "{\"name\":\"\",\"value\":\"v\",\"domain\":\"d.test\"}",
        "{\"name\":\"a b\",\"value\":\"v\",\"domain\":\"d.test\"}",
        "{\"name\":\"a;b\",\"value\":\"v\",\"domain\":\"d.test\"}",
        "{\"name\":\"a\",\"value\":\"x;secret=1\",\"domain\":\"d.test\"}",
        "{\"name\":\"a\",\"value\":\"line\\nbreak\",\"domain\":\"d.test\"}",
        "{\"name\":\"a\",\"value\":\"v\"}",
        "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"\"}",
        "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\",\"path\":\"nope\"}",
        "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\",\"expires\":\"soon\"}",
        "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\",\"sameSite\":\"Sometimes\"}",
        "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\",\"secure\":\"yes\"}",
        "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\",\"bogus\":1}",
    };
    for (bad) |params| {
        var outcome = try call(&fake, "cookies.set", params);
        defer outcome.deinit(gpa);
        try std.testing.expectEqual(@as(i64, -32602), outcome.failure.code);
        if (outcome.failure.data_json) |data| try std.testing.expect(std.mem.indexOf(u8, data, "secret") == null);
    }
    try std.testing.expectEqual(@as(usize, 0), fake.sets.items.len);
}

test "delete takes name and optional domain" {
    var fake = FakeCookiePort{};
    defer fake.deinit();
    var a = try call(&fake, "cookies.delete", "{\"name\":\"sid\",\"domain\":\"example.com\"}");
    defer a.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", a.result);
    var b = try call(&fake, "cookies.delete", "{\"name\":\"sid\"}");
    defer b.deinit(gpa);
    try std.testing.expectEqualStrings("sid@example.com", fake.deletes.items[0]);
    try std.testing.expectEqualStrings("sid@*", fake.deletes.items[1]);

    var bad = try call(&fake, "cookies.delete", "{\"domain\":\"example.com\"}");
    defer bad.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32602), bad.failure.code);
}

test "no cookie store -> session_invalid with ids; port errors map like PagePort" {
    var none = try call(null, "cookies.getAll", "{}");
    defer none.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32011), none.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, none.failure.data_json.?, "\"trace_id\":\"") != null);

    var fake = FakeCookiePort{ .fail = error.Timeout };
    defer fake.deinit();
    var timeout = try call(&fake, "cookies.set", "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\"}");
    defer timeout.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), timeout.failure.code);
}

fn writeTemp(name: []const u8, data: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(gpa, "/tmp/zb-cookie-test-{x}-{s}", .{ std.testing.random_seed, name });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
    return path;
}

fn importParams(path: []const u8, format: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{ .path = path, .format = format }, .{});
}

test "import netscape cookies.txt (HttpOnly prefix, comments, subdomain flag)" {
    const text =
        "# Netscape HTTP Cookie File\n" ++
        "# comment line\n" ++
        "\n" ++
        ".linkedin.com\tTRUE\t/\tTRUE\t1893456000\tli_at\tAQEDAT0k3n\n" ++
        "#HttpOnly_www.instagram.com\tFALSE\t/\tTRUE\t0\tsessionid\tIGs3ss\n" ++
        "broken line without tabs\n" ++
        "example.com\tFALSE\t/x\tFALSE\t1893456000\tbad name\tv\n";
    const path = try writeTemp("cookies.txt", text);
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const params = try importParams(path, "netscape");
    defer gpa.free(params);

    var fake = FakeCookiePort{};
    defer fake.deinit();
    var outcome = try call(&fake, "cookies.import", params);
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"imported\":2,\"skipped\":2}", outcome.result);
    try std.testing.expectEqualStrings(
        "{\"name\":\"li_at\",\"value\":\"AQEDAT0k3n\",\"domain\":\".linkedin.com\",\"path\":\"/\",\"expires\":1893456000,\"httpOnly\":false,\"secure\":true}",
        fake.sets.items[0],
    );
    try std.testing.expectEqualStrings(
        "{\"name\":\"sessionid\",\"value\":\"IGs3ss\",\"domain\":\"www.instagram.com\",\"path\":\"/\",\"expires\":-1,\"httpOnly\":true,\"secure\":true}",
        fake.sets.items[1],
    );
}

test "import json: browser-extension export and our own shape" {
    const text =
        \\[
        \\  {"domain":".x.com","expirationDate":1893456000.25,"hostOnly":false,"httpOnly":true,"name":"auth_token","path":"/","sameSite":"no_restriction","secure":true,"session":false,"value":"t0k"},
        \\  {"domain":"x.com","httpOnly":false,"name":"lang","path":"/","sameSite":"lax","secure":false,"session":true,"value":"en"},
        \\  {"name":"ours","value":"1","domain":"y.test","path":"/","expires":-1,"httpOnly":false,"secure":false,"sameSite":"Strict"},
        \\  {"name":"","value":"skip-me","domain":"z.test"},
        \\  42
        \\]
    ;
    const path = try writeTemp("cookies.json", text);
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const params = try importParams(path, "json");
    defer gpa.free(params);

    var fake = FakeCookiePort{};
    defer fake.deinit();
    var outcome = try call(&fake, "cookies.import", params);
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"imported\":3,\"skipped\":2}", outcome.result);
    try std.testing.expectEqualStrings(
        "{\"name\":\"auth_token\",\"value\":\"t0k\",\"domain\":\".x.com\",\"path\":\"/\",\"expires\":1893456000,\"httpOnly\":true,\"secure\":true,\"sameSite\":\"None\"}",
        fake.sets.items[0],
    );
    try std.testing.expectEqualStrings(
        "{\"name\":\"lang\",\"value\":\"en\",\"domain\":\"x.com\",\"path\":\"/\",\"expires\":-1,\"httpOnly\":false,\"secure\":false,\"sameSite\":\"Lax\"}",
        fake.sets.items[1],
    );
    try std.testing.expect(std.mem.indexOf(u8, fake.sets.items[2], "\"sameSite\":\"Strict\"") != null);
}

test "import errors: bad format, unreadable file, unparsable json -> -32602, no content echoed" {
    var fake = FakeCookiePort{};
    defer fake.deinit();

    var bad_format = try call(&fake, "cookies.import", "{\"path\":\"/tmp/x\",\"format\":\"har\"}");
    defer bad_format.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32602), bad_format.failure.code);

    var missing = try call(&fake, "cookies.import", "{\"path\":\"/nonexistent/zb/cookies.txt\",\"format\":\"netscape\"}");
    defer missing.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32602), missing.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, missing.failure.data_json.?, "unreadable_file") != null);

    const path = try writeTemp("garbage.json", "{not json secret-value");
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const params = try importParams(path, "json");
    defer gpa.free(params);
    var garbage = try call(&fake, "cookies.import", params);
    defer garbage.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32602), garbage.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, garbage.failure.data_json.?, "secret") == null);
    try std.testing.expectEqual(@as(usize, 0), fake.sets.items.len);
}
