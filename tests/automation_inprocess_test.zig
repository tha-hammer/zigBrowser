//! S7a (chat-drawer plan section 10, S7.1, revs 16.20.30 and 16.20.32): the automation core
//! runs without the socket. `startCore` makes the engine and its state and opens no socket and
//! writes no token sidecar; `start` is still the core plus the socket, unchanged. `callInProcess`
//! answers a method exactly as the socket answers `{auth, method, params}` (ids normalized),
//! for every router and special method, and needs no auth; the socket still demands it.
//!
//! The new API is reached through @hasDecl, so this file compiles before the green and fails.
const std = @import("std");
const automation_server = @import("automation_server");
const fake = @import("agent_tools_fake.zig");

const Server = automation_server.AutomationApiServer;
const net = std.Io.net;
const testing = std.testing;
const gpa = testing.allocator;

const token = "zb-automation-token-canary-7f3a9c";

fn startCore(server: *Server) !void {
    if (!@hasDecl(Server, "startCore")) return error.TestNoStartCore;
    return server.startCore();
}

/// The core's answer to `method` with `params_json`, a JSON-RPC response with id 0.
fn callInProcess(server: *Server, method: []const u8, params_json: []const u8) ![]u8 {
    if (!@hasDecl(Server, "callInProcess")) return error.TestNoCallInProcess;
    return server.callInProcess(gpa, method, params_json);
}

test "S7.1: with only the drawer, the core runs: no socket file, no token sidecar, and page.url answers" {
    const f = try fake.Fixture.create("core", token);
    defer f.destroy();
    try startCore(&f.server);
    try testing.expect(!fake.exists(f.socket_path));
    try testing.expect(!fake.exists(f.token_path));
    const reply = try callInProcess(&f.server, "page.url", "{}");
    defer gpa.free(reply);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"url\":\"file:///fixture/page1.html\"},\"id\":0}", reply);
}

test "S7.1: the core answers a window's dom.getText in process" {
    const f = try fake.Fixture.create("gettext", token);
    defer f.destroy();
    try startCore(&f.server);
    const reply = try callInProcess(&f.server, "dom.getText", "{\"selector\":\"css=#greeting\",\"window_id\":\"window-2\"}");
    defer gpa.free(reply);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"text\":\"Hello from page 2\"},\"id\":0}", reply);
    try testing.expectEqual(@as(u32, 0), f.pages.windows[0].evals.load(.acquire));
}

test "S7.1: in process needs no auth; the socket still demands it, and never echoes the given auth" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const f = try fake.Fixture.create("auth", token);
    defer f.destroy();
    try f.server.start();
    try testing.expect(fake.exists(f.socket_path));
    try testing.expect(fake.exists(f.token_path));

    const in_process = try callInProcess(&f.server, "page.title", "{}");
    defer gpa.free(in_process);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"title\":\"Page 1\"},\"id\":0}", in_process);

    var stream = try f.connect();
    defer stream.close(testing.io);
    const wrong = "zb-wrong-auth-canary-0000";
    const refused = try fake.roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"page.title\",\"params\":{},\"auth\":\"" ++ wrong ++ "\",\"id\":1}");
    defer gpa.free(refused);
    try testing.expect(std.mem.indexOf(u8, refused, "-32000") != null);
    try testing.expect(std.mem.indexOf(u8, refused, wrong) == null);
    const allowed = try fake.roundTrip(stream, "{\"jsonrpc\":\"2.0\",\"method\":\"page.title\",\"params\":{},\"auth\":\"" ++ token ++ "\",\"id\":1}");
    defer gpa.free(allowed);
    try testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"result\":{\"title\":\"Page 1\"},\"id\":1}", allowed);
}

/// The response with its id set to 0 and every trace/span id dropped, re-encoded.
fn normalized(text: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer parsed.deinit();
    if (parsed.value == .object) {
        _ = parsed.value.object.orderedRemove("id");
        dropIds(&parsed.value);
    }
    return std.json.Stringify.valueAlloc(gpa, parsed.value, .{});
}

fn dropIds(value: *std.json.Value) void {
    switch (value.*) {
        .object => |*object| {
            _ = object.orderedRemove("trace_id");
            _ = object.orderedRemove("span_id");
            for (object.values()) |*child| dropIds(child);
        },
        .array => |*array| for (array.items) |*child| dropIds(child),
        else => {},
    }
}

test "S7.1 oracle: every SDK wire case, and telemetry.query, answers in process exactly as through the socket" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, "tests/fixtures/automation/sdk_wire_cases.json", gpa, .limited(1 << 20));
    defer gpa.free(text);
    const doc = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
    defer doc.deinit();
    var cases: std.ArrayListUnmanaged(struct { method: []const u8, params: []u8 }) = .empty;
    defer {
        for (cases.items) |case| gpa.free(case.params);
        cases.deinit(gpa);
    }
    for (doc.value.object.get("cases").?.array.items) |case| {
        const obj = case.object;
        try cases.append(gpa, .{ .method = obj.get("method").?.string, .params = try std.json.Stringify.valueAlloc(gpa, obj.get("params").?, .{}) });
    }
    try cases.append(gpa, .{ .method = "telemetry.query", .params = try gpa.dupe(u8, "{\"trace_id\":\"zb-no-such-trace\"}") });
    try testing.expect(cases.items.len >= 50);

    // Two servers in the same state: one answers through its socket, one in process.
    const by_socket = try fake.Fixture.create("oracle-socket", token);
    defer by_socket.destroy();
    try by_socket.server.start();
    const in_process = try fake.Fixture.create("oracle-core", token);
    defer in_process.destroy();
    try startCore(&in_process.server);
    for ([_]*fake.Fixture{ by_socket, in_process }) |f| {
        for (&f.pages.windows) |*w| w.reply = "{\"ok\":true,\"value\":{\"ok\":true}}"; // as SDK conformance does
    }
    var stream = try by_socket.connect();
    defer stream.close(testing.io);

    for (cases.items, 0..) |case, i| {
        const request = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s},\"auth\":\"{s}\",\"id\":{d}}}", .{ case.method, case.params, token, i });
        defer gpa.free(request);
        const socket_reply = try fake.roundTrip(stream, request);
        defer gpa.free(socket_reply);
        const core_reply = try callInProcess(&in_process.server, case.method, case.params);
        defer gpa.free(core_reply);
        const want = try normalized(socket_reply);
        defer gpa.free(want);
        const got = try normalized(core_reply);
        defer gpa.free(got);
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("{s}: socket {s}\n  in process {s}\n", .{ case.method, want, got });
            return error.TestUnexpectedResult;
        }
    }
}

test "S7.1 parity (RoseCat 6566): an unknown method and bad params answer in process as through the socket" {
    if (!net.has_unix_sockets) return error.AddressFamilyUnsupported;
    const by_socket = try fake.Fixture.create("parity-socket", token);
    defer by_socket.destroy();
    try by_socket.server.start();
    const in_process = try fake.Fixture.create("parity-core", token);
    defer in_process.destroy();
    try startCore(&in_process.server);
    var stream = try by_socket.connect();
    defer stream.close(testing.io);
    const cases = [_]struct { method: []const u8, params: []const u8, code: []const u8 }{
        .{ .method = "page.nope", .params = "{}", .code = "-32601" },
        .{ .method = "agent.tools", .params = "{}", .code = "-32601" },
        .{ .method = "page.url", .params = "[1]", .code = "-32602" },
        .{ .method = "page.url", .params = "\"x\"", .code = "-32602" },
        .{ .method = "dom.getText", .params = "{\"selector\":5}", .code = "-32602" },
        .{ .method = "page.url", .params = "{\"window_id\":\"window-0\"}", .code = "-32602" },
    };
    for (cases) |case| {
        const request = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s},\"auth\":\"{s}\",\"id\":7}}", .{ case.method, case.params, token });
        defer gpa.free(request);
        const socket_reply = try fake.roundTrip(stream, request);
        defer gpa.free(socket_reply);
        const core_reply = try callInProcess(&in_process.server, case.method, case.params);
        defer gpa.free(core_reply);
        try testing.expect(std.mem.indexOf(u8, socket_reply, case.code) != null);
        const want = try normalized(socket_reply);
        defer gpa.free(want);
        const got = try normalized(core_reply);
        defer gpa.free(got);
        try testing.expectEqualStrings(want, got);
    }
    // A malformed params text cannot reach the socket as JSON at all; in process it is -32602.
    const malformed = try callInProcess(&in_process.server, "page.url", "{");
    defer gpa.free(malformed);
    try testing.expect(std.mem.indexOf(u8, malformed, "-32602") != null);
}

test "WS5.6 (RoseCat 6b324c8): the drawer is unreachable through the REAL in-process dispatch (-32601)" {
    // The right boundary is the actual dispatch (callInProcess -> dispatchParsed -> router.parse), not the
    // phase1_command_verbs list. Every drawer.* method is unrouted, so it returns exactly method-not-found.
    // A planted drawer route in the router makes one of these carry a different code — verified in-session by
    // adding a `drawer.state` route and watching this go red, then reverting (the production router is clean).
    const f = try fake.Fixture.create("ws56-drawer-iso", token);
    defer f.destroy();
    try startCore(&f.server);
    for ([_][]const u8{ "drawer.state", "drawer.open", "drawer.send" }) |method| {
        const reply = try callInProcess(&f.server, method, "{}");
        defer gpa.free(reply);
        try testing.expect(std.mem.indexOf(u8, reply, "-32601") != null);
        try testing.expect(std.mem.indexOf(u8, reply, "Method not found") != null);
        try testing.expect(std.mem.indexOf(u8, reply, "\"result\"") == null); // never a success
    }
    // Causal contrast: a genuinely-routed method does NOT yield -32601 through the SAME path — so the rows
    // above are specific to the unrouted drawer.*, not "everything is -32601".
    const routed = try callInProcess(&f.server, "page.url", "{}");
    defer gpa.free(routed);
    try testing.expect(std.mem.indexOf(u8, routed, "-32601") == null);
    try testing.expect(std.mem.indexOf(u8, routed, "\"result\"") != null);
}
