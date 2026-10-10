const std = @import("std");
const automation_server = @import("automation_server");
const page_port = automation_server.automation.page_port;
const cookie_port = automation_server.automation.cookie_port;

const net = std.Io.net;
const testing = std.testing;

test "automation API server dispatches page.url through the PagePort and returns the real url" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("url", .{});
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"params\":{},\"id\":1}");
    defer testing.allocator.free(response);

    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"result\":{\"url\":\"file:///fixture/index.html\"},\"id\":1}",
        response,
    );
    try testing.expect(std.mem.indexOf(u8, response, "\"method\"") == null);

    fixture.server.stop();
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, fixture.socket_path, .{}));
}

test "dom result object is installed directly as the JSON-RPC result" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("dom", .{ .eval_reply = "{\"ok\":true,\"value\":{\"text\":\"Ready \\\"now\\\"\"}}" });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"dom.getText\",\"params\":{\"selector\":\"css=#s\"},\"id\":\"a\"}");
    defer testing.allocator.free(response);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"result\":{\"text\":\"Ready \\\"now\\\"\"},\"id\":\"a\"}",
        response,
    );
}

test "page.evaluate array, null and >4 KiB results round-trip unquoted" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const big = "y" ** 6000;
    var fixture = try Fixture.start("eval", .{ .eval_reply = "{\"ok\":true,\"value\":[null,\"" ++ big ++ "\",{\"k\":1.5}]}" });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"page.evaluate\",\"params\":{\"expression\":\"x\"},\"id\":2}");
    defer testing.allocator.free(response);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"result\":{\"result\":[null,\"" ++ big ++ "\",{\"k\":1.5}]},\"id\":2}",
        response,
    );
}

test "automation failure becomes a JSON-RPC error with code, name and data" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("err", .{ .eval_reply = "{\"ok\":false,\"error\":\"element_disabled\",\"retryable\":false,\"data\":{\"reason\":\"enabled\"}}" });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"dom.click\",\"params\":{\"selector\":\"css=#b\"},\"id\":3}");
    defer testing.allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, -32005), err.get("code").?.integer);
    try testing.expectEqualStrings("element_disabled", err.get("message").?.string);
    const data = err.get("data").?.object;
    try testing.expectEqualStrings("enabled", data.get("reason").?.string);
    try testing.expect(data.get("trace_id") != null);
    try testing.expect(data.get("command_id") != null);
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("id").?.integer);
}

test "non-object params map to -32602" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("params", .{});
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"params\":[1],\"id\":4}");
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32602") != null);
}

test "server without a PagePort answers session_invalid instead of a template" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("noport", .{ .with_port = false });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"params\":{},\"id\":5}");
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32011") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"ok\":true") == null);
}

test "one connection carries several requests (persistent SDK clients)" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("persist", .{});
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    for (0..3) |i| {
        const request = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"page.title\",\"id\":{d}}}", .{i});
        defer testing.allocator.free(request);
        const response = try roundTrip(stream, request);
        defer testing.allocator.free(response);
        const expected = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"result\":{{\"title\":\"Fixture\"}},\"id\":{d}}}", .{i});
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, response);
    }
}

test "a second client is served while the first stays connected, and stop() closes idle clients" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("multi", .{});
    defer fixture.deinit();

    var idle = try fixture.connect();
    defer idle.close(testing.io);
    const first = try roundTrip(idle, "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"id\":1}");
    testing.allocator.free(first);

    var other = try fixture.connect();
    defer other.close(testing.io);
    const second = try roundTrip(other, "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"id\":2}");
    defer testing.allocator.free(second);
    try testing.expect(std.mem.indexOf(u8, second, "file:///fixture/index.html") != null);

    // `idle` is still open and blocked server-side in a frame read.
    fixture.server.stop();
}

test "concurrent clients on the same page are serialized by the queue" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("fifo", .{ .eval_reply = "{\"ok\":true,\"value\":{\"ok\":true}}", .eval_delay_ms = 20 });
    defer fixture.deinit();

    const Client = struct {
        fn run(f: *Fixture, ok: *bool) void {
            var stream = f.connect() catch return;
            defer stream.close(testing.io);
            for (0..3) |_| {
                const response = roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"dom.click\",\"params\":{\"selector\":\"css=#b\"},\"id\":1}") catch return;
                defer testing.allocator.free(response);
                if (std.mem.indexOf(u8, response, "\"result\":{\"ok\":true}") == null) return;
            }
            ok.* = true;
        }
    };
    var oks = [_]bool{false} ** 3;
    var threads: [3]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Client.run, .{ fixture, &oks[i] });
    for (threads) |t| t.join();
    for (oks) |ok| try testing.expect(ok);
    try testing.expectEqual(@as(u32, 9), fixture.fake.evals.load(.acquire));
    try testing.expectEqual(@as(u32, 1), fixture.fake.max_in_flight.load(.acquire));
}

test "stop() cancels a command stuck in its retry loop" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("cancel", .{ .eval_reply = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":true,\"data\":{\"reason\":\"strict_zero\"}}" });
    defer fixture.deinit();

    const Client = struct {
        fn run(f: *Fixture, out: *?[]u8) void {
            var stream = f.connect() catch return;
            defer stream.close(testing.io);
            out.* = roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"dom.click\",\"params\":{\"selector\":\"css=#never\"},\"id\":9}") catch null;
        }
    };
    var response: ?[]u8 = null;
    const t = try std.Thread.spawn(.{}, Client.run, .{ fixture, &response });
    while (fixture.fake.evals.load(.acquire) < 3) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};

    const started = std.Io.Clock.now(.awake, testing.io).toMilliseconds();
    fixture.server.stop();
    const elapsed = std.Io.Clock.now(.awake, testing.io).toMilliseconds() - started;
    t.join();
    defer if (response) |r| testing.allocator.free(r);

    try testing.expect(elapsed < 2000); // the command's own deadline is 30 s
    try testing.expect(response != null);
    try testing.expect(std.mem.indexOf(u8, response.?, "\"code\":-32012") != null);
}

test "server records one root span per command with the primary page/window ids" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var sink = automation_server.automation.telemetry.InMemoryTelemetrySink.init(testing.allocator);
    defer sink.deinit();
    var fixture = try Fixture.start("telemetry", .{ .sink = &sink });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    for (0..2) |_| {
        const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"id\":1}");
        testing.allocator.free(response);
    }
    fixture.server.stop();

    var roots: usize = 0;
    for (sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.command")) continue;
        roots += 1;
        try testing.expectEqualStrings("page-1", span.attr("page.id").?);
        try testing.expectEqualStrings("window-1", span.attr("window.id").?);
        try testing.expectEqualStrings("0", span.attr("queue.wait_ms").?);
        try testing.expectEqualStrings("ok", span.attr("result.status").?);
    }
    try testing.expectEqual(@as(usize, 2), roots);
}

test "object/array/bool ids are Invalid Request and never dispatch" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("badid", .{ .eval_reply = "{\"ok\":true,\"value\":{\"ok\":true}}" });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    for ([_][]const u8{ "{\"a\":1}", "[1]", "true" }) |id| {
        const request = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"dom.click\",\"params\":{{\"selector\":\"css=#b\"}},\"id\":{s}}}", .{id});
        defer testing.allocator.free(request);
        const response = try roundTrip(stream, request);
        defer testing.allocator.free(response);
        try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"},\"id\":null}", response);
    }
    try testing.expectEqual(@as(u32, 0), fixture.fake.evals.load(.acquire));
}

test "server can be stopped and started again" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("restart", .{});
    defer fixture.deinit();

    fixture.server.stop();
    try fixture.server.start();
    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"id\":1}");
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "file:///fixture/index.html") != null);
}

test "commands that never reach the page still get one root span and ids" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var sink = automation_server.automation.telemetry.InMemoryTelemetrySink.init(testing.allocator);
    defer sink.deinit();
    var fixture = try Fixture.start("noport-telemetry", .{ .with_port = false, .sink = &sink });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"dom.click\",\"params\":{\"selector\":\"css=#b\"},\"id\":1}");
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32011") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"trace_id\"") != null);
    fixture.server.stop();

    try testing.expectEqual(@as(usize, 1), countRoots(&sink, "session_invalid"));
}

test "a command cancelled while queued gets a root span and ids" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var sink = automation_server.automation.telemetry.InMemoryTelemetrySink.init(testing.allocator);
    defer sink.deinit();
    var fixture = try Fixture.start("queued-cancel", .{
        .eval_reply = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":true,\"data\":{\"reason\":\"strict_zero\"}}",
        .sink = &sink,
    });
    defer fixture.deinit();

    const Client = struct {
        fn run(f: *Fixture, request: []const u8, out: *?[]u8) void {
            var stream = f.connect() catch return;
            defer stream.close(testing.io);
            out.* = roundTrip(stream, request) catch null;
        }
    };
    var running: ?[]u8 = null;
    var queued: ?[]u8 = null;
    const a = try std.Thread.spawn(.{}, Client.run, .{ fixture, "{\"jsonrpc\":\"2.0\",\"method\":\"dom.click\",\"params\":{\"selector\":\"css=#never\"},\"id\":1}", &running });
    while (fixture.fake.evals.load(.acquire) < 2) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    const b = try std.Thread.spawn(.{}, Client.run, .{ fixture, "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"id\":2}", &queued });
    while (fixture.server.queue.pendingCount("page-1") < 1) testing.io.sleep(.fromMilliseconds(1), .awake) catch {};

    fixture.server.stop();
    a.join();
    b.join();
    defer if (running) |r| testing.allocator.free(r);
    defer if (queued) |r| testing.allocator.free(r);

    try testing.expect(std.mem.indexOf(u8, queued.?, "\"code\":-32012") != null);
    try testing.expect(std.mem.indexOf(u8, queued.?, "\"trace_id\"") != null);
    try testing.expectEqual(@as(usize, 2), countRoots(&sink, "cancelled"));
}

fn countRoots(sink: *const automation_server.automation.telemetry.InMemoryTelemetrySink, automation_error: []const u8) usize {
    var count: usize = 0;
    for (sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.command")) continue;
        if (std.mem.eql(u8, span.attr("automation.error").?, automation_error)) count += 1;
    }
    return count;
}

test "social.* methods are routed: rate_status, set_pacing, pause, login_check" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("social", .{ .eval_reply = "{\"ok\":true,\"value\":{\"logged_in\":false,\"username\":null}}" });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);

    const status = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.rate_status\",\"id\":1}");
    defer testing.allocator.free(status);
    try testing.expect(std.mem.indexOf(u8, status, "\"result\":{\"remaining_actions\":100,\"reset_at\":\"") != null);

    const pacing = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.set_pacing\",\"params\":{\"daily_cap\":7},\"id\":2}");
    defer testing.allocator.free(pacing);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true},\"id\":2}", pacing);

    const login = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.login_check\",\"id\":3}");
    defer testing.allocator.free(login);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"loggedIn\":false,\"platform\":\"unknown\",\"username\":null},\"id\":3}", login);

    const unknown = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.post\",\"id\":4}");
    defer testing.allocator.free(unknown);
    try testing.expect(std.mem.indexOf(u8, unknown, "\"code\":-32601") != null);

    const bad = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.set_pacing\",\"params\":{\"min_delay_ms\":9000},\"id\":5}");
    defer testing.allocator.free(bad);
    try testing.expect(std.mem.indexOf(u8, bad, "\"code\":-32602") != null);
}

test "social.pause returns after the pause and holds a concurrent client's page command" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("pause", .{});
    defer fixture.deinit();

    const Pauser = struct {
        fn run(f: *Fixture, out: *?[]u8) void {
            var stream = f.connect() catch return;
            defer stream.close(testing.io);
            out.* = roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.pause\",\"params\":{\"duration_ms\":300},\"id\":1}") catch null;
        }
    };
    var paused: ?[]u8 = null;
    const started = std.Io.Clock.now(.awake, testing.io).toMilliseconds();
    const t = try std.Thread.spawn(.{}, Pauser.run, .{ fixture, &paused });
    // Let the pause take the page ticket first.
    testing.io.sleep(.fromMilliseconds(50), .awake) catch {};

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const url = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"id\":2}");
    defer testing.allocator.free(url);
    const url_done = std.Io.Clock.now(.awake, testing.io).toMilliseconds() - started;
    t.join();
    defer if (paused) |p| testing.allocator.free(p);

    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true},\"id\":1}", paused.?);
    try testing.expect(std.mem.indexOf(u8, url, "file:///fixture/index.html") != null);
    try testing.expect(url_done >= 280); // held until the pause ended
}

test "stop() cancels a running social.pause" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("pause-cancel", .{});
    defer fixture.deinit();

    const Pauser = struct {
        fn run(f: *Fixture, out: *?[]u8) void {
            var stream = f.connect() catch return;
            defer stream.close(testing.io);
            out.* = roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.pause\",\"params\":{\"duration_ms\":600000},\"id\":1}") catch null;
        }
    };
    var paused: ?[]u8 = null;
    const t = try std.Thread.spawn(.{}, Pauser.run, .{ fixture, &paused });
    testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    fixture.server.stop();
    t.join();
    defer if (paused) |p| testing.allocator.free(p);
    try testing.expect(std.mem.indexOf(u8, paused.?, "\"code\":-32012") != null);
}

test "social.* failures carry ids and every social call records one root span" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var sink = automation_server.automation.telemetry.InMemoryTelemetrySink.init(testing.allocator);
    defer sink.deinit();
    var fixture = try Fixture.start("social-ids", .{ .with_port = false, .sink = &sink });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const login = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.login_check\",\"id\":1}");
    defer testing.allocator.free(login);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, login, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try testing.expectEqual(@as(i64, -32011), err.get("code").?.integer);
    const trace_id = err.get("data").?.object.get("trace_id").?.string;
    try testing.expect(err.get("data").?.object.get("command_id") != null);

    const status = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.rate_status\",\"id\":2}");
    testing.allocator.free(status);
    fixture.server.stop();

    const command_id = err.get("data").?.object.get("command_id").?.string;
    var login_roots: usize = 0;
    var status_roots: usize = 0;
    var login_root_span: []const u8 = "";
    for (sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.command")) continue;
        try testing.expectEqualStrings("social", span.attr("rpc.namespace").?);
        if (std.mem.eql(u8, span.attr("rpc.method").?, "social.login_check")) {
            login_roots += 1;
            login_root_span = span.span_id;
            try testing.expectEqualStrings(trace_id, span.trace_id);
            try testing.expectEqualStrings(command_id, span.command_id);
            try testing.expectEqualStrings("session_invalid", span.attr("automation.error").?);
        } else if (std.mem.eql(u8, span.attr("rpc.method").?, "social.rate_status")) {
            status_roots += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), login_roots);
    try testing.expectEqual(@as(usize, 1), status_roots);

    // The failed url() read emits exactly one errored platform.eval child and
    // no eval child.
    var children: usize = 0;
    for (sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.platform.eval")) continue;
        if (!std.mem.eql(u8, span.command_id, command_id)) continue;
        children += 1;
        try testing.expectEqualStrings("url", span.attr("page_port.op").?);
        try testing.expectEqualStrings("NoPage", span.attr("platform.error_class").?);
        try testing.expectEqualStrings(login_root_span, span.parent_span_id.?);
    }
    try testing.expectEqual(@as(usize, 1), children);
}

test "successful social.login_check emits url then automation-world evalJson children" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var sink = automation_server.automation.telemetry.InMemoryTelemetrySink.init(testing.allocator);
    defer sink.deinit();
    var fixture = try Fixture.start("social-spans", .{ .sink = &sink, .eval_reply = "{\"ok\":true,\"value\":{\"logged_in\":true,\"username\":\"Ada\"}}" });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const login = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.login_check\",\"id\":1}");
    defer testing.allocator.free(login);
    fixture.server.stop();

    var root: ?*const automation_server.automation.telemetry.Span = null;
    for (sink.spans.items) |*span| {
        if (std.mem.eql(u8, span.name, "automation.command")) root = span;
    }
    var ops: [2][]const u8 = undefined;
    var n: usize = 0;
    for (sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.platform.eval")) continue;
        try testing.expect(n < 2);
        try testing.expectEqualStrings(root.?.trace_id, span.trace_id);
        try testing.expectEqualStrings(root.?.command_id, span.command_id);
        try testing.expectEqualStrings(root.?.span_id, span.parent_span_id.?);
        try testing.expectEqualStrings("", span.attr("platform.error_class").?);
        ops[n] = span.attr("page_port.op").?;
        if (n == 1) try testing.expectEqualStrings("automation", span.attr("script.world").?);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("url", ops[0]);
    try testing.expectEqualStrings("evalJson", ops[1]);
    try testing.expect(!sink.containsRaw("Ada"));
}

test "cookies.* are routed through the CookiePort with ids, one root span each, values never in telemetry" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var sink = automation_server.automation.telemetry.InMemoryTelemetrySink.init(testing.allocator);
    defer sink.deinit();
    var store = MemoryCookieStore{};
    defer store.deinit();
    var fixture = try Fixture.start("cookies", .{ .sink = &sink, .cookies = &store });
    defer fixture.deinit();

    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const set = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"cookies.set\",\"params\":{\"name\":\"sid\",\"value\":\"s3cr3t-cookie\",\"domain\":\"example.com\"},\"id\":1}");
    defer testing.allocator.free(set);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true},\"id\":1}", set);

    const all = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"cookies.getAll\",\"id\":2}");
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "\"result\":{\"cookies\":[{\"name\":\"sid\",\"value\":\"s3cr3t-cookie\"") != null);

    const del = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"cookies.delete\",\"params\":{\"name\":\"sid\"},\"id\":3}");
    defer testing.allocator.free(del);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true},\"id\":3}", del);

    const empty = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"cookies.getAll\",\"id\":4}");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"cookies\":[]},\"id\":4}", empty);
    fixture.server.stop();

    var roots: usize = 0;
    for (sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.command")) continue;
        roots += 1;
        try testing.expectEqualStrings("cookies", span.attr("rpc.namespace").?);
    }
    try testing.expectEqual(@as(usize, 4), roots);
    try testing.expect(!sink.containsRaw("s3cr3t-cookie"));
}

test "cookies.* without a cookie store is session_invalid with ids" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("nocookies", .{});
    defer fixture.deinit();
    var stream = try fixture.connect();
    defer stream.close(testing.io);
    const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"cookies.getAll\",\"id\":1}");
    defer testing.allocator.free(response);
    try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32011") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"trace_id\"") != null);
}

/// In-memory CookiePort: one cookie slot is enough for the socket test.
const MemoryCookieStore = struct {
    cookie_json: ?[]u8 = null,

    fn deinit(self: *MemoryCookieStore) void {
        if (self.cookie_json) |c| testing.allocator.free(c);
    }

    fn port(self: *MemoryCookieStore) cookie_port.CookiePort {
        return .{ .ptr = self, .vtable = &.{ .getAll = getAll, .set = set, .delete = delete } };
    }

    fn getAll(ptr: *anyopaque, gpa: std.mem.Allocator, _: ?[]const u8, _: u64) cookie_port.PortError![]u8 {
        const self: *MemoryCookieStore = @ptrCast(@alignCast(ptr));
        const c = self.cookie_json orelse return gpa.dupe(u8, "[]");
        return std.fmt.allocPrint(gpa, "[{s}]", .{c}) catch error.OutOfMemory;
    }
    fn set(ptr: *anyopaque, cookie_json: []const u8, _: u64) cookie_port.PortError!void {
        const self: *MemoryCookieStore = @ptrCast(@alignCast(ptr));
        self.deinit();
        self.cookie_json = testing.allocator.dupe(u8, cookie_json) catch return error.OutOfMemory;
    }
    fn delete(ptr: *anyopaque, _: []const u8, _: ?[]const u8, _: u64) cookie_port.PortError!void {
        const self: *MemoryCookieStore = @ptrCast(@alignCast(ptr));
        self.deinit();
        self.cookie_json = null;
    }
};

test "the socket file is created with mode 0600" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("mode", .{});
    defer fixture.deinit();
    const stat = try std.Io.Dir.cwd().statFile(testing.io, fixture.socket_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "tokensEqual stays constant-time: its body compares digests with std.crypto.timing_safe.eql only" {
    // Behaviour tests cannot see an early-exit compare; this static contract
    // fails if the timing-safe primitive is replaced (RoseCat 4706).
    const source = try std.Io.Dir.cwd().readFileAlloc(testing.io, "src/automation_server.zig", testing.allocator, .limited(1 << 22));
    defer testing.allocator.free(source);
    const start = std.mem.indexOf(u8, source, "pub fn tokensEqual(") orelse return error.TestNoTokensEqual;
    const end = std.mem.indexOfPos(u8, source, start, "\n}\n") orelse return error.TestNoTokensEqual;
    const body = source[start..end];
    try testing.expect(std.mem.indexOf(u8, body, "std.crypto.timing_safe.eql(") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Sha256.hash(given") != null);
    try testing.expect(std.mem.indexOf(u8, body, "Sha256.hash(expected") != null);
    for ([_][]const u8{ "std.mem.eql", "mem.eql(", "std.mem.order", "==" }) |early_exit| {
        if (std.mem.indexOf(u8, body, early_exit) != null) {
            std.debug.print("tokensEqual uses an early-exit compare: {s}\n", .{early_exit});
            return error.TestNotConstantTime;
        }
    }
}

test "tokensEqual is exact for equal, different and different-length tokens" {
    try testing.expect(automation_server.tokensEqual("s3cret", "s3cret"));
    try testing.expect(!automation_server.tokensEqual("s3cret", "s3creT"));
    try testing.expect(!automation_server.tokensEqual("s3cret", "s3cre"));
    try testing.expect(!automation_server.tokensEqual("s3cret", "s3cret!"));
    try testing.expect(!automation_server.tokensEqual("s3cret", ""));
    try testing.expect(automation_server.tokensEqual("", ""));
}

test "requests need the exact token when one is configured" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("token", .{ .token = "s3cret" });
    defer fixture.deinit();
    var stream = try fixture.connect();
    defer stream.close(testing.io);
    for ([_][]const u8{ "", ",\"auth\":\"s3creT\"", ",\"auth\":\"s3cre\"", ",\"auth\":\"s3cret-\"", ",\"auth\":1" }) |auth| {
        const request = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"id\":1{s}}}", .{auth});
        defer testing.allocator.free(request);
        const response = try roundTrip(stream, request);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.indexOf(u8, response, "\"code\":-32000") != null);
    }
    const ok = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"page.url\",\"id\":2,\"auth\":\"s3cret\"}");
    defer testing.allocator.free(ok);
    try testing.expect(std.mem.indexOf(u8, ok, "\"result\"") != null);
}

test "websocket upgrade requires the token (Authorization: Bearer) when one is configured" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("ws-token", .{ .token = "s3cret" });
    defer fixture.deinit();

    for ([_]struct { header: []const u8, expect: []const u8 }{
        .{ .header = "", .expect = "HTTP/1.1 401" },
        .{ .header = "Authorization: Bearer wrong\r\n", .expect = "HTTP/1.1 401" },
        .{ .header = "Authorization: Bearer s3cret\r\n", .expect = "HTTP/1.1 101" },
        .{ .header = "authorization: bearer s3cret\r\n", .expect = "HTTP/1.1 101" },
        .{ .header = "AUTHORIZATION: BEARER s3cret\r\n", .expect = "HTTP/1.1 101" },
        .{ .header = "authorization: bearer S3CRET\r\n", .expect = "HTTP/1.1 401" },
    }) |case| {
        var stream = try fixture.connect();
        defer stream.close(testing.io);
        var writer_buf: [1024]u8 = undefined;
        var writer = stream.writer(testing.io, &writer_buf);
        try writer.interface.print(
            "GET /events HTTP/1.1\r\nHost: zigbrowser.local\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n{s}\r\n",
            .{case.header},
        );
        try writer.interface.flush();
        var reader_buf: [1024]u8 = undefined;
        var reader = stream.reader(testing.io, &reader_buf);
        var response: [64]u8 = undefined;
        const n = try reader.interface.readSliceShort(&response);
        try testing.expect(std.mem.startsWith(u8, response[0..n], case.expect));
    }
}

test "SDK conformance: every shared wire case is routed and accepted by the real server" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/automation/sdk_wire_cases.json", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(text);
    const doc = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer doc.deinit();

    var store = MemoryCookieStore{};
    defer store.deinit();
    var fixture = try Fixture.start("conformance", .{
        .cookies = &store,
        .eval_reply = "{\"ok\":true,\"value\":{\"ok\":true}}",
    });
    defer fixture.deinit();
    var stream = try fixture.connect();
    defer stream.close(testing.io);

    const cases = doc.value.object.get("cases").?.array.items;
    try testing.expect(cases.len >= 20);
    for (cases, 0..) |case, i| {
        const obj = case.object;
        const request = try std.json.Stringify.valueAlloc(testing.allocator, .{
            .jsonrpc = "2.0",
            .method = obj.get("method").?.string,
            .params = obj.get("params").?,
            .id = i,
        }, .{});
        defer testing.allocator.free(request);
        const response = try roundTrip(stream, request);
        defer testing.allocator.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
        defer parsed.deinit();
        if (parsed.value.object.get("error")) |err| {
            const code = err.object.get("code").?.integer;
            // Routed and well-formed; a semantic failure from a fake port
            // (e.g. the nonexistent import file) is fine.
            if (code == -32601 or code == -32602 or code == -32600) {
                // cookies.import of a missing file is -32602 by design; it
                // still proves the route and param names.
                const is_missing_import = std.mem.eql(u8, obj.get("id").?.string, "cookies.import") and
                    std.mem.eql(u8, err.object.get("data").?.object.get("reason").?.string, "unreadable_file");
                if (!is_missing_import) {
                    std.debug.print("case {s} rejected: {s}\n", .{ obj.get("id").?.string, response });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "N12: a build without platform ports (WebView2/WKWebView today) answers every SDK request cleanly" {
    // On non-GTK backends app.zig passes no PagePort and no CookiePort.
    // Every method the SDKs send must still be routed and answer either a
    // result (pure server-side helpers) or -32011 session_invalid, never a
    // crash, -32601/-32602 or an internal error.
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/automation/sdk_wire_cases.json", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(text);
    const doc = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer doc.deinit();

    var fixture = try Fixture.start("no-backend", .{ .with_port = false });
    defer fixture.deinit();
    var stream = try fixture.connect();
    defer stream.close(testing.io);

    var requests: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (requests.items) |r| testing.allocator.free(r);
        requests.deinit(testing.allocator);
    }
    for (doc.value.object.get("cases").?.array.items, 0..) |case, i| {
        const obj = case.object;
        try requests.append(testing.allocator, try std.json.Stringify.valueAlloc(testing.allocator, .{
            .jsonrpc = "2.0",
            .method = obj.get("method").?.string,
            .params = obj.get("params").?,
            .id = i,
        }, .{}));
    }

    var answered_by_server: usize = 0;
    for (requests.items) |request| {
        const response = try roundTrip(stream, request);
        defer testing.allocator.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
        defer parsed.deinit();
        const err = parsed.value.object.get("error") orelse {
            answered_by_server += 1;
            continue;
        };
        const code = err.object.get("code").?.integer;
        if (code == -32011) continue;
        std.debug.print("unclean answer without a backend: {s} -> {s}\n", .{ request, response });
        return error.TestUnexpectedResult;
    }
    // social.rate_status / set_pacing / pause need no page.
    try testing.expect(answered_by_server >= 3);

    // Native input is a capability this backend lacks: -32011 with the
    // documented reason "unsupported" (not a missing page), for every
    // native verb.
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"dom.click\",\"params\":{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}},\"id\":997}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"dom.type\",\"params\":{\"selector\":\"css=#q\",\"text\":\"hi\",\"options\":{\"input\":\"native\"}},\"id\":998}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"dom.press\",\"params\":{\"key\":\"Enter\",\"options\":{\"input\":\"native\"}},\"id\":999}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"dom.hover\",\"params\":{\"selector\":\"css=#m\",\"options\":{\"input\":\"native\"}},\"id\":1000}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"dom.scroll\",\"params\":{\"y\":10,\"options\":{\"input\":\"native\"}},\"id\":1001}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"dom.setInputFiles\",\"params\":{\"selector\":\"css=#f\",\"paths\":[\"/tmp/a\"]},\"id\":1002}",
    }) |request| {
        const native = try roundTrip(stream, request);
        defer testing.allocator.free(native);
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, native, .{});
        defer parsed.deinit();
        const err = parsed.value.object.get("error").?.object;
        try testing.expectEqual(@as(i64, -32011), err.get("code").?.integer);
        try testing.expectEqualStrings("unsupported", err.get("data").?.object.get("reason").?.string);
    }
}

test "N16: linkedin.* and instagram.* are routed through the real socket, queue and engine (session cookie gate, pacing, telemetry ids)" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var store = MemoryCookieStore{};
    defer store.deinit();
    var fixture = try Fixture.start("social-flows", .{
        .cookies = &store,
        .eval_reply = "{\"ok\":true,\"value\":{\"ok\":true,\"text\":\"Ada\",\"elements\":[{\"id\":\"zb-1\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{}}]}}",
    });
    defer fixture.deinit();
    var stream = try fixture.connect();
    defer stream.close(testing.io);

    // No session cookie yet: logged out before any page step.
    const logged_out = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"linkedin.follow\",\"params\":{\"profileUrl\":\"https://www.linkedin.com/in/zed/\"},\"id\":1}");
    defer testing.allocator.free(logged_out);
    try testing.expect(std.mem.indexOf(u8, logged_out, "\"code\":-32011") != null);
    try testing.expect(std.mem.indexOf(u8, logged_out, "logged_out") != null);
    try testing.expect(std.mem.indexOf(u8, logged_out, "\"trace_id\"") != null);
    try testing.expectEqual(@as(usize, 0), fixture.fake.events().len);

    // Sign in (cookie store), no pacing pause for the test, then act.
    try store.port().set("{\"name\":\"li_at\",\"value\":\"v\",\"domain\":\".www.linkedin.com\",\"path\":\"/\",\"expires\":-1,\"httpOnly\":true,\"secure\":true}", 1000);
    const paced = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.set_pacing\",\"params\":{\"min_delay_ms\":0,\"max_delay_ms\":0,\"daily_cap\":2},\"id\":2}");
    defer testing.allocator.free(paced);
    const followed = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"linkedin.follow\",\"params\":{\"profileUrl\":\"https://www.linkedin.com/in/zed/\"},\"id\":3}");
    defer testing.allocator.free(followed);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true},\"id\":3}", followed);
    try testing.expectEqual(@as(u8, 'n'), fixture.fake.events()[0]);
    const status = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"social.rate_status\",\"params\":{},\"id\":4}");
    defer testing.allocator.free(status);
    try testing.expect(std.mem.indexOf(u8, status, "\"remaining_actions\":1") != null);

    // Off-platform URL and a request-supplied base are refused.
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"linkedin.visit\",\"params\":{\"profileUrl\":\"https://evil.example/in/zed/\"},\"id\":5}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"linkedin.search\",\"params\":{\"query\":\"zig\",\"baseUrl\":\"http://127.0.0.1:9\"},\"id\":6}",
    }) |request| {
        const refused = try roundTrip(stream, request);
        defer testing.allocator.free(refused);
        try testing.expect(std.mem.indexOf(u8, refused, "\"code\":-32602") != null);
    }

    // instagram.* is routed too (selfcheck needs no session).
    const report = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"instagram.selfcheck\",\"params\":{},\"id\":7}");
    defer testing.allocator.free(report);
    try testing.expect(std.mem.startsWith(u8, report, "{\"jsonrpc\":\"2.0\",\"result\":{\"signed_in\":1,"));
}

test "N16: the fixture origin comes only from server configuration and must be a bare http(s) origin" {
    try testing.expectEqualStrings("http://127.0.0.1:41234", automation_server.validFixtureOrigin("http://127.0.0.1:41234/").?);
    try testing.expectEqualStrings("https://fixture.test", automation_server.validFixtureOrigin("https://fixture.test").?);
    for ([_][]const u8{ "", "127.0.0.1:9", "ftp://x", "http://", "http://a/b", "http://a?b", "http://u@a", "http://a b" }) |bad| {
        try testing.expect(automation_server.validFixtureOrigin(bad) == null);
    }
}

fn tmpPath(comptime tag: []const u8) ![]u8 {
    return std.fmt.allocPrint(testing.allocator, "/tmp/zigbrowser-sidecar-" ++ tag ++ "-{x}", .{testing.random_seed});
}

test "token sidecar: written 0600 with the token before accepting, removed on stop" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const socket_path = try tmpPath("ok.sock");
    defer testing.allocator.free(socket_path);
    const token_path = try tmpPath("ok.sock.token");
    defer testing.allocator.free(token_path);
    cleanupSocketPath(socket_path);
    cleanupSocketPath(token_path);

    var server = try automation_server.AutomationApiServer.init(testing.allocator, testing.io, .{
        .enabled = true,
        .socket_path = socket_path,
        .token = "0123456789abcdef",
        .token_file_path = token_path,
    });
    defer server.deinit();
    try server.start();

    const content = try std.Io.Dir.cwd().readFileAlloc(testing.io, token_path, testing.allocator, .limited(256));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("0123456789abcdef", content);
    const stat = try std.Io.Dir.cwd().statFile(testing.io, token_path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);

    server.stop();
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, token_path, .{}));
}

test "token sidecar never writes through a pre-planted symlink" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const socket_path = try tmpPath("sym.sock");
    defer testing.allocator.free(socket_path);
    const token_path = try tmpPath("sym.sock.token");
    defer testing.allocator.free(token_path);
    const victim = try tmpPath("victim");
    defer testing.allocator.free(victim);
    cleanupSocketPath(socket_path);
    cleanupSocketPath(token_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = victim, .data = "victim" });
    defer cleanupSocketPath(victim);
    try std.Io.Dir.cwd().symLink(testing.io, victim, token_path, .{});

    var server = try automation_server.AutomationApiServer.init(testing.allocator, testing.io, .{
        .enabled = true,
        .socket_path = socket_path,
        .token = "fedcba9876543210",
        .token_file_path = token_path,
    });
    defer server.deinit();
    try server.start();

    const victim_content = try std.Io.Dir.cwd().readFileAlloc(testing.io, victim, testing.allocator, .limited(64));
    defer testing.allocator.free(victim_content);
    try testing.expectEqualStrings("victim", victim_content);
    const content = try std.Io.Dir.cwd().readFileAlloc(testing.io, token_path, testing.allocator, .limited(64));
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("fedcba9876543210", content);
}

test "token sidecar: whitespace-only token refused; failed start leaves no sidecar" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const token_path = try tmpPath("fail.token");
    defer testing.allocator.free(token_path);
    cleanupSocketPath(token_path);

    var blank = try automation_server.AutomationApiServer.init(testing.allocator, testing.io, .{
        .enabled = true,
        .socket_path = "/tmp/zigbrowser-sidecar-blank.sock",
        .token = "  \t\n",
        .token_file_path = token_path,
    });
    defer blank.deinit();
    try testing.expectError(error.EmptyToken, blank.start());

    var broken = try automation_server.AutomationApiServer.init(testing.allocator, testing.io, .{
        .enabled = true,
        .socket_path = "/nonexistent-dir-zb/automation.sock",
        .token = "0123456789abcdef",
        .token_file_path = token_path,
    });
    defer broken.deinit();
    try testing.expect(std.meta.isError(broken.start()));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, token_path, .{}));
}

test "AutomationApiServer.init frees everything when an allocation fails" {
    const Init = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var server = try automation_server.AutomationApiServer.init(allocator, testing.io, .{
                .enabled = true,
                .socket_path = "/tmp/zigbrowser-init-oom.sock",
                .token = "0123456789abcdef",
                .token_file_path = "/tmp/zigbrowser-init-oom.sock.token",
            });
            server.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Init.run, .{});
}

test "telemetry.query returns the redacted span tree of a recent command" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var sink = automation_server.automation.telemetry.InMemoryTelemetrySink.init(testing.allocator);
    defer sink.deinit();
    var fixture = try Fixture.start("tquery", .{
        .sink = &sink,
        .eval_reply = "{\"ok\":false,\"error\":\"element_disabled\",\"retryable\":false,\"data\":{\"reason\":\"enabled\"}}",
    });
    defer fixture.deinit();
    var stream = try fixture.connect();
    defer stream.close(testing.io);

    const click = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"dom.fill\",\"params\":{\"selector\":\"css=#secret-field\",\"value\":\"hunter2\"},\"id\":1}");
    defer testing.allocator.free(click);
    const click_doc = try std.json.parseFromSlice(std.json.Value, testing.allocator, click, .{});
    defer click_doc.deinit();
    const trace_id = click_doc.value.object.get("error").?.object.get("data").?.object.get("trace_id").?.string;

    const request = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"telemetry.query\",\"params\":{{\"trace_id\":\"{s}\"}},\"id\":2}}", .{trace_id});
    defer testing.allocator.free(request);
    const response = try roundTrip(stream, request);
    defer testing.allocator.free(response);
    const doc = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer doc.deinit();
    const spans = doc.value.object.get("result").?.object.get("spans").?.array.items;
    try testing.expect(spans.len >= 2);
    try testing.expectEqualStrings("automation.command", spans[0].object.get("name").?.string);
    const attrs = spans[0].object.get("attributes").?.object;
    try testing.expectEqualStrings("dom.fill", attrs.get("rpc.method").?.string);
    try testing.expectEqualStrings("element_disabled", attrs.get("automation.error").?.string);
    try testing.expect(std.mem.indexOf(u8, response, "hunter2") == null);
    try testing.expect(std.mem.indexOf(u8, response, "#secret-field") == null);

    // The configured sink still receives everything (tee).
    var roots: usize = 0;
    for (sink.spans.items) |span| {
        if (std.mem.eql(u8, span.name, "automation.command")) roots += 1;
    }
    try testing.expectEqual(@as(usize, 1), roots);

    const unknown = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"telemetry.query\",\"params\":{\"trace_id\":\"nope\"},\"id\":3}");
    defer testing.allocator.free(unknown);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"spans\":[]},\"id\":3}", unknown);

    for ([_][]const u8{ "{}", "{\"trace_id\":1}", "{\"trace_id\":\"\"}", "{\"trace_id\":\"a\",\"x\":1}" }) |params| {
        const bad_request = try std.fmt.allocPrint(testing.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"telemetry.query\",\"params\":{s},\"id\":4}}", .{params});
        defer testing.allocator.free(bad_request);
        const bad = try roundTrip(stream, bad_request);
        defer testing.allocator.free(bad);
        try testing.expect(std.mem.indexOf(u8, bad, "\"code\":-32602") != null);
    }
}

test "token sidecar: a write failure after create leaves no file behind" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const socket_path = try tmpPath("partial.sock");
    defer testing.allocator.free(socket_path);
    const token_path = try tmpPath("partial.sock.token");
    defer testing.allocator.free(token_path);
    cleanupSocketPath(socket_path);
    cleanupSocketPath(token_path);

    automation_server.testing_hooks.fail_token_write = true;
    defer automation_server.testing_hooks.fail_token_write = false;
    var server = try automation_server.AutomationApiServer.init(testing.allocator, testing.io, .{
        .enabled = true,
        .socket_path = socket_path,
        .token = "0123456789abcdef",
        .token_file_path = token_path,
    });
    defer server.deinit();
    try testing.expectError(error.InjectedTokenWriteFailure, server.start());
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, token_path, .{}));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, socket_path, .{}));
}

test "docs/how-to-automate.md documents every method the SDKs send, and every error code" {
    const doc = try std.Io.Dir.cwd().readFileAlloc(testing.io, "docs/how-to-automate.md", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(doc);
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/automation/sdk_wire_cases.json", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(text);
    const cases = try std.json.parseFromSlice(std.json.Value, testing.allocator, text, .{});
    defer cases.deinit();
    for (cases.value.object.get("cases").?.array.items) |case| {
        const method = case.object.get("method").?.string;
        const heading = try std.fmt.allocPrint(testing.allocator, "`{s}`", .{method});
        defer testing.allocator.free(heading);
        if (std.mem.indexOf(u8, doc, heading) == null) {
            std.debug.print("method not documented: {s}\n", .{method});
            return error.TestUndocumentedMethod;
        }
    }
    for ([_][]const u8{ "`telemetry.query`", "--automation-api", "--profile-dir", "--automation-token-file", "ZIGBROWSER_SOCKET", ".token", "contenteditable", "cookies.import" }) |needle| {
        if (std.mem.indexOf(u8, doc, needle) == null) {
            std.debug.print("missing in docs: {s}\n", .{needle});
            return error.TestUndocumented;
        }
    }
    var code: i64 = -32012;
    while (code <= -32000) : (code += 1) {
        const needle = try std.fmt.allocPrint(testing.allocator, "{d}", .{code});
        defer testing.allocator.free(needle);
        if (std.mem.indexOf(u8, doc, needle) == null) {
            std.debug.print("error code not documented: {s}\n", .{needle});
            return error.TestUndocumentedErrorCode;
        }
    }
}

test "x.* is routed: x.post runs its steps on the page and returns the flow result" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var sink = automation_server.automation.telemetry.InMemoryTelemetrySink.init(testing.allocator);
    defer sink.deinit();
    var fixture = try Fixture.start("x-post", .{ .sink = &sink, .eval_reply = "{\"ok\":true,\"value\":{\"ok\":true,\"elements\":[{\"id\":\"zb-1\",\"tag\":\"button\",\"text\":\"Post\",\"bbox\":{}}]}}" });
    defer fixture.deinit();
    var stream = try fixture.connect();
    defer stream.close(testing.io);

    const response = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"x.post\",\"params\":{\"text\":\"hi from the socket\",\"compose_url\":\"http://127.0.0.1:9/compose\"},\"id\":1}");
    defer testing.allocator.free(response);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true},\"id\":1}", response);
    // 8 flow steps plus the N20 scans: after the navigation, before the
    // fill, the type, the trial probe and the Post click, and before
    // reporting success.
    try testing.expectEqual(@as(u32, 6), fixture.fake.scans.load(.acquire));
    try testing.expectEqual(@as(u32, 8 + 6), fixture.fake.evals.load(.acquire));

    const bad = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"x.post\",\"params\":{\"text\":\"\"},\"id\":2}");
    defer testing.allocator.free(bad);
    try testing.expect(std.mem.indexOf(u8, bad, "\"code\":-32602") != null);
    const unknown = try roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"x.delete\",\"id\":3}");
    defer testing.allocator.free(unknown);
    try testing.expect(std.mem.indexOf(u8, unknown, "\"code\":-32601") != null);
    fixture.server.stop();

    var x_roots: usize = 0;
    for (sink.spans.items) |span| {
        if (std.mem.eql(u8, span.name, "automation.command") and std.mem.eql(u8, span.attr("rpc.method").?, "x.post")) x_roots += 1;
    }
    try testing.expectEqual(@as(usize, 2), x_roots);
    try testing.expect(!sink.containsRaw("hi from the socket"));
}

test "x.* holds the page queue for the whole flow: a racing page command is queued, then runs after it (deterministic)" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    var fixture = try Fixture.start("x-queue", .{ .eval_reply = "{\"ok\":true,\"value\":{\"ok\":true,\"elements\":[{\"id\":\"zb-1\",\"tag\":\"button\",\"text\":\"Post\",\"bbox\":{}}]}}" });
    defer fixture.deinit();
    const page_id = automation_server.primary_route.page_id;

    // The flow navigates to /a, then blocks in its first page step.
    fixture.fake.hold.store(true, .release);
    // Never leave the flow blocked (a failed check would hang teardown).
    defer fixture.fake.hold.store(false, .release);
    var flow = try fixture.connect();
    defer flow.close(testing.io);
    try writeFrame(flow, "{\"jsonrpc\":\"2.0\",\"method\":\"x.post\",\"params\":{\"text\":\"hi\",\"compose_url\":\"http://127.0.0.1:9/a\"},\"id\":1}");
    try waitUntil(&fixture.fake.held, 5000);

    // A second client asks to navigate while the flow is mid-step.
    var racer = try fixture.connect();
    defer racer.close(testing.io);
    try writeFrame(racer, "{\"jsonrpc\":\"2.0\",\"method\":\"page.navigate\",\"params\":{\"url\":\"http://127.0.0.1:9/b\"},\"id\":2}");

    // Handshake: the racer is enqueued behind the flow (explicit queue
    // state, not timing), and it has not touched the page.
    var waited: u32 = 0;
    while (fixture.server.queue.pendingCount(page_id) != 1) : (waited += 1) {
        if (waited > 5000) return error.RacerNeverQueued;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try testing.expectEqualStrings("Ae", fixture.fake.events());

    fixture.fake.hold.store(false, .release);
    const posted = try readFrame(flow);
    defer testing.allocator.free(posted);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true},\"id\":1}", posted);
    const navigated = try readFrame(racer);
    defer testing.allocator.free(navigated);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true},\"id\":2}", navigated);

    // Every flow step ran before the racer's navigation: A e...e B.
    const events = fixture.fake.events();
    try testing.expectEqual(@as(u8, 'A'), events[0]);
    try testing.expectEqual(@as(u8, 'B'), events[events.len - 1]);
    for (events[1 .. events.len - 1]) |event| try testing.expectEqual(@as(u8, 'e'), event);
    try testing.expectEqual(@as(usize, 2 + fixture.fake.evals.load(.acquire)), events.len);
}

fn waitUntil(flag: *std.atomic.Value(bool), max_ms: u32) !void {
    var waited: u32 = 0;
    while (!flag.load(.acquire)) : (waited += 1) {
        if (waited > max_ms) return error.TimedOut;
        try testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

const FixtureOptions = struct {
    with_port: bool = true,
    eval_reply: []const u8 = "{\"ok\":true,\"value\":null}",
    eval_delay_ms: u64 = 0,
    sink: ?*automation_server.automation.telemetry.InMemoryTelemetrySink = null,
    cookies: ?*MemoryCookieStore = null,
    token: []const u8 = "",
};

const Fixture = struct {
    socket_path: []u8,
    fake: FakePort,
    server: automation_server.AutomationApiServer,

    fn start(comptime tag: []const u8, options: FixtureOptions) !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        self.socket_path = try std.fmt.allocPrint(
            testing.allocator,
            "/tmp/zigbrowser-automation-" ++ tag ++ "-{x}.sock",
            .{testing.random_seed},
        );
        cleanupSocketPath(self.socket_path);
        self.fake = .{ .eval_reply = options.eval_reply, .eval_delay_ms = options.eval_delay_ms };
        self.server = try automation_server.AutomationApiServer.init(testing.allocator, testing.io, .{
            .enabled = true,
            .socket_path = self.socket_path,
            .token = options.token,
            .page_port = if (options.with_port) self.fake.port() else null,
            .telemetry_sink = if (options.sink) |sink| sink.sink() else null,
            .cookie_port = if (options.cookies) |store| store.port() else null,
        });
        try self.server.start();
        return self;
    }

    fn connect(self: *Fixture) !net.Stream {
        const address = try net.UnixAddress.init(self.socket_path);
        return address.connect(testing.io);
    }

    fn deinit(self: *Fixture) void {
        self.server.deinit();
        cleanupSocketPath(self.socket_path);
        testing.allocator.free(self.socket_path);
        testing.allocator.destroy(self);
    }
};

/// Minimal PagePort for socket-level tests; engine behaviour is covered by
/// tests/automation_engine_test.zig.
const FakePort = struct {
    eval_reply: []const u8,
    eval_delay_ms: u64 = 0,
    evals: std.atomic.Value(u32) = .init(0),
    /// N20 rateLimitScan evals among `evals`.
    scans: std.atomic.Value(u32) = .init(0),
    in_flight: std.atomic.Value(u32) = .init(0),
    max_in_flight: std.atomic.Value(u32) = .init(0),
    /// While set, the first eval blocks (and sets `held`) until cleared.
    hold: std.atomic.Value(bool) = .init(false),
    held: std.atomic.Value(bool) = .init(false),
    /// Order of page calls: 'e' per eval, 'A'/'B' per navigate to a URL
    /// containing "/a" / "/b" (else 'n').
    log: [64]u8 = undefined,
    log_len: std.atomic.Value(usize) = .init(0),

    fn record(self: *FakePort, event: u8) void {
        const i = self.log_len.fetchAdd(1, .acq_rel);
        if (i < self.log.len) self.log[i] = event;
    }

    fn events(self: *FakePort) []const u8 {
        return self.log[0..@min(self.log_len.load(.acquire), self.log.len)];
    }

    fn port(self: *FakePort) page_port.PagePort {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = page_port.PagePort.VTable{
        .evalJson = evalJson,
        .navigate = navigate,
        .reload = reload,
        .url = url,
        .title = title,
    };

    fn evalJson(ptr: *anyopaque, gpa: std.mem.Allocator, world: page_port.World, body: []const u8, arg: []const u8, timeout_ms: u64) page_port.PortError![]u8 {
        _ = .{ world, body, timeout_ms };
        const self: *FakePort = @ptrCast(@alignCast(ptr));
        if (std.mem.indexOf(u8, arg, "\"op\":\"rateLimitScan\"") != null) _ = self.scans.fetchAdd(1, .acq_rel);
        const now_in_flight = self.in_flight.fetchAdd(1, .acq_rel) + 1;
        defer _ = self.in_flight.fetchSub(1, .acq_rel);
        _ = self.max_in_flight.fetchMax(now_in_flight, .acq_rel);
        self.record('e');
        while (self.hold.load(.acquire)) {
            self.held.store(true, .release);
            testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        if (self.eval_delay_ms > 0) testing.io.sleep(.fromMilliseconds(@intCast(self.eval_delay_ms)), .awake) catch {};
        _ = self.evals.fetchAdd(1, .acq_rel);
        return gpa.dupe(u8, self.eval_reply);
    }
    fn navigate(ptr: *anyopaque, target: []const u8, _: u64) page_port.PortError!void {
        const self: *FakePort = @ptrCast(@alignCast(ptr));
        self.record(if (std.mem.indexOf(u8, target, "/a") != null) 'A' else if (std.mem.indexOf(u8, target, "/b") != null) 'B' else 'n');
    }
    fn reload(_: *anyopaque, _: u64) page_port.PortError!void {}
    fn url(_: *anyopaque, gpa: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
        return gpa.dupe(u8, "file:///fixture/index.html");
    }
    fn title(_: *anyopaque, gpa: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
        return gpa.dupe(u8, "Fixture");
    }
};

fn roundTrip(stream: net.Stream, request: []const u8) ![]u8 {
    try writeFrame(stream, request);
    return readFrame(stream);
}

test "automation API server accepts WebSocket upgrade and pushes ready notification" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;

    const socket_path = try std.fmt.allocPrint(
        testing.allocator,
        "/tmp/zigbrowser-automation-websocket-{x}.sock",
        .{testing.random_seed},
    );
    defer testing.allocator.free(socket_path);
    cleanupSocketPath(socket_path);
    defer cleanupSocketPath(socket_path);

    var server = try automation_server.AutomationApiServer.init(testing.allocator, testing.io, .{
        .enabled = true,
        .socket_path = socket_path,
        .token = "",
    });
    defer server.deinit();

    try server.start();
    defer server.stop();

    const address = try net.UnixAddress.init(socket_path);
    var stream = try address.connect(testing.io);
    defer stream.close(testing.io);

    var writer_buf: [1024]u8 = undefined;
    var writer = stream.writer(testing.io, &writer_buf);
    try writer.interface.writeAll(
        "GET /events HTTP/1.1\r\n" ++
            "Host: zigbrowser.local\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n",
    );
    try writer.interface.flush();

    var reader_buf: [1024]u8 = undefined;
    var reader = stream.reader(testing.io, &reader_buf);
    var response: [512]u8 = undefined;
    var total: usize = 0;
    while (total < response.len) {
        const read_len = try reader.interface.readSliceShort(response[total..]);
        total += read_len;
        const bytes = response[0..total];
        if (std.mem.indexOf(u8, bytes, "automation.ready") != null) break;
    }
    const bytes = response[0..total];

    try testing.expect(std.mem.indexOf(u8, bytes, "HTTP/1.1 101 Switching Protocols") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "automation.ready") != null);
}

fn writeFrame(stream: net.Stream, payload: []const u8) !void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);

    var writer_buf: [1024]u8 = undefined;
    var writer = stream.writer(testing.io, &writer_buf);
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(payload);
    try writer.interface.flush();
}

fn readFrame(stream: net.Stream) ![]u8 {
    var reader_buf: [1024]u8 = undefined;
    var reader = stream.reader(testing.io, &reader_buf);

    var header: [4]u8 = undefined;
    try reader.interface.readSliceAll(&header);
    const len = std.mem.readInt(u32, &header, .big);

    const payload = try testing.allocator.alloc(u8, len);
    errdefer testing.allocator.free(payload);
    try reader.interface.readSliceAll(payload);
    return payload;
}

fn cleanupSocketPath(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};
}
