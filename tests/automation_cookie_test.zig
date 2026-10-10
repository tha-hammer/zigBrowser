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

/// Records everything crossing the TelemetrySink vtable.
const SpySink = struct {
    seen: std.ArrayListUnmanaged(u8) = .empty,
    cookie_spans: usize = 0,
    roots: usize = 0,

    fn sink(self: *SpySink) automation.telemetry.TelemetrySink {
        return .{ .ptr = self, .vtable = &.{ .recordCommandSpan = recordCommand, .recordChildSpan = recordChild } };
    }
    fn recordCommand(ptr: *anyopaque, attrs: automation.telemetry.CommandSpanAttrs) anyerror!void {
        const self: *SpySink = @ptrCast(@alignCast(ptr));
        self.roots += 1;
        const json = try std.json.Stringify.valueAlloc(gpa, attrs, .{});
        defer gpa.free(json);
        try self.seen.appendSlice(gpa, json);
    }
    fn recordChild(ptr: *anyopaque, span: automation.telemetry.ChildSpan) anyerror!void {
        const self: *SpySink = @ptrCast(@alignCast(ptr));
        if (std.mem.eql(u8, span.name, "automation.cookie.command")) self.cookie_spans += 1;
        const json = try std.json.Stringify.valueAlloc(gpa, span, .{});
        defer gpa.free(json);
        try self.seen.appendSlice(gpa, json);
    }
};

test "each cookies.* call records one automation.cookie.command child; nothing raw crosses the sink" {
    var fake = FakeCookiePort{ .store_json = "[{\"name\":\"sid\",\"value\":\"v4lue-in-store\",\"domain\":\"example.com\",\"path\":\"/\",\"expires\":-1,\"httpOnly\":false,\"secure\":false}]" };
    defer fake.deinit();
    var spy: SpySink = .{};
    defer spy.seen.deinit(gpa);

    const path = try writeTemp("spy.txt", ".example.com\tTRUE\t/\tFALSE\t0\timported_name\timp0rted-v4lue\n");
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const import_params = try importParams(path, "netscape");
    defer gpa.free(import_params);

    const calls = [_][2][]const u8{
        .{ "cookies.set", "{\"name\":\"secret_name\",\"value\":\"s3cret-v4lue\",\"domain\":\"private.example\"}" },
        .{ "cookies.getAll", "{\"url\":\"https://private.example/account?token=q\"}" },
        .{ "cookies.delete", "{\"name\":\"secret_name\",\"domain\":\"private.example\"}" },
        .{ "cookies.import", import_params },
    };
    for (calls) |c| {
        var outcome = try callWithSink(&fake, c[0], c[1], spy.sink());
        outcome.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 4), spy.roots);
    try std.testing.expectEqual(@as(usize, 4), spy.cookie_spans);
    for ([_][]const u8{ "s3cret-v4lue", "v4lue-in-store", "imp0rted-v4lue", "secret_name", "imported_name", "private.example", "token=q", "/account", path }) |needle| {
        if (std.mem.indexOf(u8, spy.seen.items, needle) != null) {
            std.debug.print("raw value crossed the sink: {s}\n", .{needle});
            return error.TestRawValueLeaked;
        }
    }
    for ([_][]const u8{ "\"cookie.operation\"", "\"set\"", "\"getAll\"", "\"delete\"", "\"import\"", "\"cookie.name_hash\"", "\"cookie.domain_hash\"", "\"cookie.count\"", "\"cookie.scope\"" }) |needle| {
        if (std.mem.indexOf(u8, spy.seen.items, needle) == null) {
            std.debug.print("missing in cookie spans: {s}\n", .{needle});
            return error.TestMissingAttr;
        }
    }
}

test "NUL and control characters are rejected before the C boundary" {
    var fake = FakeCookiePort{};
    defer fake.deinit();
    const bad = [_][2][]const u8{
        .{ "cookies.getAll", "{\"url\":\"https://a.test/\\u0000x\"}" },
        .{ "cookies.getAll", "{\"url\":\"https://a.test/\\u0007x\"}" },
        .{ "cookies.set", "{\"name\":\"a\\u0000b\",\"value\":\"v\",\"domain\":\"d.test\"}" },
        .{ "cookies.set", "{\"name\":\"a\",\"value\":\"v\\u0000\",\"domain\":\"d.test\"}" },
        .{ "cookies.set", "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\\u0000\"}" },
        .{ "cookies.set", "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\",\"path\":\"/\\u0000\"}" },
        .{ "cookies.delete", "{\"name\":\"a\\u0000\"}" },
        .{ "cookies.delete", "{\"name\":\"a\",\"domain\":\"d\\u0000.test\"}" },
        .{ "cookies.import", "{\"path\":\"/tmp/a\\u0000b\",\"format\":\"json\"}" },
    };
    for (bad) |c| {
        var outcome = try call(&fake, c[0], c[1]);
        defer outcome.deinit(gpa);
        try std.testing.expectEqual(@as(i64, -32602), outcome.failure.code);
    }
    try std.testing.expectEqual(@as(usize, 0), fake.sets.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.deletes.items.len);
    try std.testing.expect(fake.get_url == null);
}

test "import refuses files over the byte cap and over the cookie-count cap before any set" {
    var fake = FakeCookiePort{};
    defer fake.deinit();

    const big = try gpa.alloc(u8, cookie_routes.max_import_bytes + 1);
    defer gpa.free(big);
    @memset(big, '#');
    const big_path = try writeTemp("big.txt", big);
    defer gpa.free(big_path);
    defer std.Io.Dir.deleteFileAbsolute(io, big_path) catch {};
    const big_params = try importParams(big_path, "netscape");
    defer gpa.free(big_params);
    var too_big = try call(&fake, "cookies.import", big_params);
    defer too_big.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32602), too_big.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, too_big.failure.data_json.?, "file_too_large") != null);

    var lines: std.ArrayListUnmanaged(u8) = .empty;
    defer lines.deinit(gpa);
    for (0..cookie_routes.max_import_cookies + 1) |i| {
        try lines.print(gpa, "example.com\tFALSE\t/\tFALSE\t0\tc{d}\tv\n", .{i});
    }
    const many_path = try writeTemp("many.txt", lines.items);
    defer gpa.free(many_path);
    defer std.Io.Dir.deleteFileAbsolute(io, many_path) catch {};
    const many_params = try importParams(many_path, "netscape");
    defer gpa.free(many_params);
    var too_many = try call(&fake, "cookies.import", many_params);
    defer too_many.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32602), too_many.failure.code);
    try std.testing.expect(std.mem.indexOf(u8, too_many.failure.data_json.?, "too_many_cookies") != null);
    try std.testing.expectEqual(@as(usize, 0), fake.sets.items.len);
}

test "a store failure mid-import reports how many were applied and where it stopped" {
    var fake = FailAfter{ .ok_sets = 2 };
    const text = "a.test\tFALSE\t/\tFALSE\t0\tc0\tv\n" ++ "a.test\tFALSE\t/\tFALSE\t0\tc1\tv\n" ++ "a.test\tFALSE\t/\tFALSE\t0\tc2\tv\n" ++ "a.test\tFALSE\t/\tFALSE\t0\tc3\tv\n";
    const path = try writeTemp("partial.txt", text);
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const params = try importParams(path, "netscape");
    defer gpa.free(params);

    const Call = struct {
        port: cookie_port.CookiePort,
        params: []const u8,
        fn run(c: @This(), a: std.mem.Allocator, ext: *automation.engine.External) error{OutOfMemory}!automation.engine.Outcome {
            return cookie_routes.handle(a, io, c.port, ext, .import, c.params);
        }
    };
    var clock = fakes.FakeClock.init(gpa);
    defer clock.deinit();
    var eng = automation.engine.Engine.init(automation.page_port.no_page, clock.clock());
    var outcome = try eng.executeExternal(gpa, "cookies.import", "cookies", .{}, Call{ .port = fake.port(), .params = params }, Call.run);
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    const data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try std.testing.expectEqualStrings("import_partial", data.value.object.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 2), data.value.object.get("imported").?.integer);
    try std.testing.expectEqual(@as(i64, 2), data.value.object.get("failed_index").?.integer);
    try std.testing.expect(data.value.object.get("trace_id") != null);
}

const FailAfter = struct {
    ok_sets: usize,
    sets: usize = 0,

    fn port(self: *FailAfter) cookie_port.CookiePort {
        return .{ .ptr = self, .vtable = &.{ .getAll = getAll, .set = set, .delete = delete } };
    }
    fn getAll(_: *anyopaque, a: std.mem.Allocator, _: ?[]const u8, _: u64) cookie_port.PortError![]u8 {
        return a.dupe(u8, "[]");
    }
    fn set(ptr: *anyopaque, _: []const u8, _: u64) cookie_port.PortError!void {
        const self: *FailAfter = @ptrCast(@alignCast(ptr));
        if (self.sets == self.ok_sets) return error.Timeout;
        self.sets += 1;
    }
    fn delete(_: *anyopaque, _: []const u8, _: ?[]const u8, _: u64) cookie_port.PortError!void {}
};

test "getAll requires cookie-shaped objects from the store" {
    for ([_][]const u8{
        "[1,2]",
        "[{\"name\":\"a\"}]",
        "[{\"name\":\"a\",\"value\":\"v\",\"domain\":3}]",
    }) |store| {
        var fake = FakeCookiePort{ .store_json = store };
        defer fake.deinit();
        var outcome = try call(&fake, "cookies.getAll", "{}");
        defer outcome.deinit(gpa);
        try std.testing.expectEqual(@as(i64, -32603), outcome.failure.code);
    }
}

test "import skips entries whose flags, expiry or sameSite are malformed (never weakens them)" {
    const json_text =
        \\[
        \\  {"name":"a","value":"1","domain":"x.test","secure":"yes"},
        \\  {"name":"b","value":"1","domain":"x.test","httpOnly":1},
        \\  {"name":"c","value":"1","domain":"x.test","session":"false"},
        \\  {"name":"d","value":"1","domain":"x.test","expirationDate":"tomorrow"},
        \\  {"name":"e","value":"1","domain":"x.test","expires":-2},
        \\  {"name":"f","value":"1","domain":"x.test","sameSite":"sometimes"},
        \\  {"name":"g","value":"1","domain":"x.test","sameSite":7},
        \\  {"name":"ok","value":"1","domain":"x.test","sameSite":"unspecified","secure":true}
        \\]
    ;
    const json_path = try writeTemp("flags.json", json_text);
    defer gpa.free(json_path);
    defer std.Io.Dir.deleteFileAbsolute(io, json_path) catch {};
    const json_params = try importParams(json_path, "json");
    defer gpa.free(json_params);

    var fake = FakeCookiePort{};
    defer fake.deinit();
    var outcome = try call(&fake, "cookies.import", json_params);
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"imported\":1,\"skipped\":7}", outcome.result);
    try std.testing.expect(std.mem.indexOf(u8, fake.sets.items[0], "\"name\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.sets.items[0], "\"secure\":true") != null);

    const netscape_text =
        "x.test\tMAYBE\t/\tTRUE\t0\tbad_sub\tv\n" ++
        "x.test\tFALSE\t/\tyes\t0\tbad_secure\tv\n" ++
        "x.test\tFALSE\t/\tTRUE\t-5\tbad_expiry\tv\n" ++
        "x.test\tfalse\t/\ttrue\t0\tok_lower\tv\n";
    const ns_path = try writeTemp("flags.txt", netscape_text);
    defer gpa.free(ns_path);
    defer std.Io.Dir.deleteFileAbsolute(io, ns_path) catch {};
    const ns_params = try importParams(ns_path, "netscape");
    defer gpa.free(ns_params);
    var fake2 = FakeCookiePort{};
    defer fake2.deinit();
    var ns = try call(&fake2, "cookies.import", ns_params);
    defer ns.deinit(gpa);
    try std.testing.expectEqualStrings("{\"imported\":1,\"skipped\":3}", ns.result);
    try std.testing.expect(std.mem.indexOf(u8, fake2.sets.items[0], "\"secure\":true") != null);
}

/// CookiePort whose set() takes `cost_ms` of fake time.
const SlowStore = struct {
    clock: *fakes.FakeClock,
    cost_ms: u64,
    timeouts: std.ArrayListUnmanaged(u64) = .empty,

    fn port(self: *SlowStore) cookie_port.CookiePort {
        return .{ .ptr = self, .vtable = &.{ .getAll = FailAfter.getAll, .set = set, .delete = FailAfter.delete } };
    }
    fn set(ptr: *anyopaque, _: []const u8, timeout_ms: u64) cookie_port.PortError!void {
        const self: *SlowStore = @ptrCast(@alignCast(ptr));
        self.timeouts.append(gpa, timeout_ms) catch return error.OutOfMemory;
        self.clock.now_ms += self.cost_ms;
    }
};

test "the whole import shares one deadline; sets get only the remaining time" {
    var lines: std.ArrayListUnmanaged(u8) = .empty;
    defer lines.deinit(gpa);
    for (0..10) |i| try lines.print(gpa, "x.test\tFALSE\t/\tFALSE\t0\tc{d}\tv\n", .{i});
    const path = try writeTemp("budget.txt", lines.items);
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const params = try importParams(path, "netscape");
    defer gpa.free(params);

    var clock = fakes.FakeClock.init(gpa);
    defer clock.deinit();
    var store = SlowStore{ .clock = &clock, .cost_ms = cookie_routes.import_budget_ms / 4 };
    defer store.timeouts.deinit(gpa);
    const Call = struct {
        port: cookie_port.CookiePort,
        params: []const u8,
        fn run(c: @This(), a: std.mem.Allocator, ext: *automation.engine.External) error{OutOfMemory}!automation.engine.Outcome {
            return cookie_routes.handle(a, io, c.port, ext, .import, c.params);
        }
    };
    var eng = automation.engine.Engine.init(automation.page_port.no_page, clock.clock());
    var outcome = try eng.executeExternal(gpa, "cookies.import", "cookies", .{}, Call{ .port = store.port(), .params = params }, Call.run);
    defer outcome.deinit(gpa);

    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 4), store.timeouts.items.len);
    try std.testing.expectEqual(cookie_routes.import_budget_ms, store.timeouts.items[0]);
    try std.testing.expectEqual(cookie_routes.import_budget_ms / 4, store.timeouts.items[3]);
    const data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try std.testing.expectEqualStrings("import_partial", data.value.object.get("reason").?.string);
    try std.testing.expectEqual(@as(i64, 4), data.value.object.get("imported").?.integer);
}

/// Collects each cookie child span separately for per-span field checks.
const SpanCollector = struct {
    roots: std.ArrayListUnmanaged([3][]u8) = .empty, // trace, span, command
    children: std.ArrayListUnmanaged(std.json.Parsed(std.json.Value)) = .empty,

    fn deinit(self: *SpanCollector) void {
        for (self.roots.items) |r| for (r) |s| gpa.free(s);
        self.roots.deinit(gpa);
        for (self.children.items) |*c| c.deinit();
        self.children.deinit(gpa);
    }
    fn sink(self: *SpanCollector) automation.telemetry.TelemetrySink {
        return .{ .ptr = self, .vtable = &.{ .recordCommandSpan = recordCommand, .recordChildSpan = recordChild } };
    }
    fn recordCommand(ptr: *anyopaque, attrs: automation.telemetry.CommandSpanAttrs) anyerror!void {
        const self: *SpanCollector = @ptrCast(@alignCast(ptr));
        try self.roots.append(gpa, .{ try gpa.dupe(u8, attrs.trace_id), try gpa.dupe(u8, attrs.span_id), try gpa.dupe(u8, attrs.command_id) });
    }
    fn recordChild(ptr: *anyopaque, span: automation.telemetry.ChildSpan) anyerror!void {
        const self: *SpanCollector = @ptrCast(@alignCast(ptr));
        if (!std.mem.eql(u8, span.name, "automation.cookie.command")) return;
        const json = try std.json.Stringify.valueAlloc(gpa, span, .{});
        defer gpa.free(json);
        try self.children.append(gpa, try std.json.parseFromSlice(std.json.Value, gpa, json, .{}));
    }
};

const required_cookie_span_attrs = [_][]const u8{
    "cookie.operation", "cookie.name_hash", "cookie.domain_hash", "cookie.count", "cookie.scope",
    "result.status",    "platform.error_class", "duration_ms", "page.id", "window.id", "backend.name",
};

test "cookie child spans carry every required field and hang off their root (success and failure)" {
    var fake = FakeCookiePort{};
    defer fake.deinit();
    var collector: SpanCollector = .{};
    defer collector.deinit();

    var ok = try callWithSink(&fake, "cookies.set", "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\"}", collector.sink());
    ok.deinit(gpa);
    fake.fail = error.Timeout;
    var bad = try callWithSink(&fake, "cookies.delete", "{\"name\":\"a\"}", collector.sink());
    bad.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), collector.children.items.len);
    for (collector.children.items, collector.roots.items, 0..) |child, root, i| {
        const obj = child.value.object;
        try std.testing.expectEqualStrings(root[0], obj.get("trace_id").?.string);
        try std.testing.expectEqualStrings(root[1], obj.get("parent_span_id").?.string);
        try std.testing.expectEqualStrings(root[2], obj.get("command_id").?.string);
        var attrs = std.StringHashMap([]const u8).init(gpa);
        defer attrs.deinit();
        for (obj.get("attributes").?.array.items) |entry| try attrs.put(entry.object.get("key").?.string, entry.object.get("value").?.string);
        for (required_cookie_span_attrs) |key| {
            if (!attrs.contains(key)) {
                std.debug.print("span {d} missing {s}\n", .{ i, key });
                return error.TestMissingAttr;
            }
        }
        try std.testing.expectEqualStrings(if (i == 0) "ok" else "error", attrs.get("result.status").?);
        if (i == 1) try std.testing.expectEqualStrings("Timeout", attrs.get("platform.error_class").?);
    }
}

test "partial import reports the applied count in the cookie span" {
    var fake = FailAfter{ .ok_sets = 2 };
    const text = "a.test\tFALSE\t/\tFALSE\t0\tc0\tv\n" ++ "a.test\tFALSE\t/\tFALSE\t0\tc1\tv\n" ++ "a.test\tFALSE\t/\tFALSE\t0\tc2\tv\n";
    const path = try writeTemp("partial-span.txt", text);
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const params = try importParams(path, "netscape");
    defer gpa.free(params);

    var collector: SpanCollector = .{};
    defer collector.deinit();
    const Call = struct {
        port: cookie_port.CookiePort,
        params: []const u8,
        fn run(c: @This(), a: std.mem.Allocator, ext: *automation.engine.External) error{OutOfMemory}!automation.engine.Outcome {
            return cookie_routes.handle(a, io, c.port, ext, .import, c.params);
        }
    };
    var clock = fakes.FakeClock.init(gpa);
    defer clock.deinit();
    var eng = automation.engine.Engine.init(automation.page_port.no_page, clock.clock());
    var outcome = try eng.executeExternal(gpa, "cookies.import", "cookies", .{ .route = .{ .telemetry_sink = collector.sink() } }, Call{ .port = fake.port(), .params = params }, Call.run);
    defer outcome.deinit(gpa);
    var saw_count = false;
    for (collector.children.items[0].value.object.get("attributes").?.array.items) |entry| {
        if (std.mem.eql(u8, entry.object.get("key").?.string, "cookie.count")) {
            saw_count = true;
            try std.testing.expectEqualStrings("2", entry.object.get("value").?.string);
        }
    }
    try std.testing.expect(saw_count);
}

/// CookiePort that sets `flag` after `cancel_after` successful sets.
const CancellingStore = struct {
    flag: *std.atomic.Value(bool),
    cancel_after: usize,
    sets: usize = 0,

    fn port(self: *CancellingStore) cookie_port.CookiePort {
        return .{ .ptr = self, .vtable = &.{ .getAll = FailAfter.getAll, .set = set, .delete = FailAfter.delete } };
    }
    fn set(ptr: *anyopaque, _: []const u8, _: u64) cookie_port.PortError!void {
        const self: *CancellingStore = @ptrCast(@alignCast(ptr));
        self.sets += 1;
        if (self.sets == self.cancel_after) self.flag.store(true, .release);
    }
};

test "an import cancelled between entries stops with cancelled and the applied count" {
    var lines: std.ArrayListUnmanaged(u8) = .empty;
    defer lines.deinit(gpa);
    for (0..5) |i| try lines.print(gpa, "x.test\tFALSE\t/\tFALSE\t0\tc{d}\tv\n", .{i});
    const path = try writeTemp("cancel.txt", lines.items);
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const params = try importParams(path, "netscape");
    defer gpa.free(params);

    var flag = std.atomic.Value(bool).init(false);
    var store = CancellingStore{ .flag = &flag, .cancel_after = 2 };
    const Call = struct {
        port: cookie_port.CookiePort,
        params: []const u8,
        fn run(c: @This(), a: std.mem.Allocator, ext: *automation.engine.External) error{OutOfMemory}!automation.engine.Outcome {
            return cookie_routes.handle(a, io, c.port, ext, .import, c.params);
        }
    };
    var clock = fakes.FakeClock.init(gpa);
    defer clock.deinit();
    var eng = automation.engine.Engine.init(automation.page_port.no_page, clock.clock());
    var outcome = try eng.executeExternal(gpa, "cookies.import", "cookies", .{ .cancel = &flag }, Call{ .port = store.port(), .params = params }, Call.run);
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 2), store.sets);
    const data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try std.testing.expectEqual(@as(i64, 2), data.value.object.get("imported").?.integer);
}

test "session:false without an expiry is contradictory and skipped" {
    const path = try writeTemp("contradiction.json", "[{\"name\":\"a\",\"value\":\"1\",\"domain\":\"x.test\",\"session\":false},{\"name\":\"b\",\"value\":\"1\",\"domain\":\"x.test\",\"session\":true}]");
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const params = try importParams(path, "json");
    defer gpa.free(params);
    var fake = FakeCookiePort{};
    defer fake.deinit();
    var outcome = try call(&fake, "cookies.import", params);
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"imported\":1,\"skipped\":1}", outcome.result);
}

test "contradictory or dual expiry fields are skipped, never weakened to session" {
    const text =
        \\[
        \\  {"name":"a","value":"1","domain":"x.test","session":false,"expirationDate":1893456000,"expires":-1},
        \\  {"name":"b","value":"1","domain":"x.test","session":false,"expires":-1},
        \\  {"name":"c","value":"1","domain":"x.test","expirationDate":1893456000,"expires":1893456000},
        \\  {"name":"d","value":"1","domain":"x.test","session":true,"expirationDate":1893456000},
        \\  {"name":"ok","value":"1","domain":"x.test","session":false,"expirationDate":1893456000}
        \\]
    ;
    const path = try writeTemp("contradict2.json", text);
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const params = try importParams(path, "json");
    defer gpa.free(params);
    var fake = FakeCookiePort{};
    defer fake.deinit();
    var outcome = try call(&fake, "cookies.import", params);
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"imported\":1,\"skipped\":4}", outcome.result);
    try std.testing.expect(std.mem.indexOf(u8, fake.sets.items[0], "\"expires\":1893456000") != null);
}

test "expiry beyond year 9999 (253402300799) is rejected for set, netscape and json" {
    var fake = FakeCookiePort{};
    defer fake.deinit();
    var edge = try call(&fake, "cookies.set", "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\",\"expires\":253402300799}");
    defer edge.deinit(gpa);
    try std.testing.expectEqualStrings("{\"ok\":true}", edge.result);
    var over = try call(&fake, "cookies.set", "{\"name\":\"a\",\"value\":\"v\",\"domain\":\"d.test\",\"expires\":253402300800}");
    defer over.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32602), over.failure.code);

    const ns = try writeTemp("far.txt", "x.test\tFALSE\t/\tFALSE\t253402300800\tfar\tv\nx.test\tFALSE\t/\tFALSE\t253402300799\tedge\tv\n");
    defer gpa.free(ns);
    defer std.Io.Dir.deleteFileAbsolute(io, ns) catch {};
    const ns_params = try importParams(ns, "netscape");
    defer gpa.free(ns_params);
    var ns_out = try call(&fake, "cookies.import", ns_params);
    defer ns_out.deinit(gpa);
    try std.testing.expectEqualStrings("{\"imported\":1,\"skipped\":1}", ns_out.result);

    const js = try writeTemp("far.json", "[{\"name\":\"far\",\"value\":\"v\",\"domain\":\"x.test\",\"expirationDate\":253402300800.5},{\"name\":\"big\",\"value\":\"v\",\"domain\":\"x.test\",\"expirationDate\":9.0e14}]");
    defer gpa.free(js);
    defer std.Io.Dir.deleteFileAbsolute(io, js) catch {};
    const js_params = try importParams(js, "json");
    defer gpa.free(js_params);
    var js_out = try call(&fake, "cookies.import", js_params);
    defer js_out.deinit(gpa);
    try std.testing.expectEqualStrings("{\"imported\":0,\"skipped\":2}", js_out.result);
}

test "the import deadline covers reading and parsing: a pre-cancelled import touches nothing" {
    const path = try writeTemp("precancel.txt", "x.test\tFALSE\t/\tFALSE\t0\tc\tv\n");
    defer gpa.free(path);
    defer std.Io.Dir.deleteFileAbsolute(io, path) catch {};
    const params = try importParams(path, "netscape");
    defer gpa.free(params);

    var flag = std.atomic.Value(bool).init(false);
    var store = CancellingStore{ .flag = &flag, .cancel_after = 99 };
    const Call = struct {
        port: cookie_port.CookiePort,
        params: []const u8,
        flag: *std.atomic.Value(bool),
        fn run(c: @This(), a: std.mem.Allocator, ext: *automation.engine.External) error{OutOfMemory}!automation.engine.Outcome {
            c.flag.store(true, .release); // cancelled after the root started, before any I/O
            return cookie_routes.handle(a, io, c.port, ext, .import, c.params);
        }
    };
    var clock = fakes.FakeClock.init(gpa);
    defer clock.deinit();
    var eng = automation.engine.Engine.init(automation.page_port.no_page, clock.clock());
    var outcome = try eng.executeExternal(gpa, "cookies.import", "cookies", .{ .cancel = &flag }, Call{ .port = store.port(), .params = params, .flag = &flag }, Call.run);
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32012), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 0), store.sets);
}
