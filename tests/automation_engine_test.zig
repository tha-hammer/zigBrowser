const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const router = automation.router;
const engine = automation.engine;
const script_command = automation.script_command;
const FakePagePort = fakes.FakePagePort;
const FakeClock = fakes.FakeClock;

const gpa = std.testing.allocator;

const Harness = struct {
    fake: FakePagePort,
    clock: FakeClock,
    engine: engine.Engine,

    fn init(self: *Harness) void {
        self.fake = FakePagePort.init(gpa);
        self.clock = FakeClock.init(gpa);
        self.engine = engine.Engine.init(self.fake.port(), self.clock.clock());
    }

    fn deinit(self: *Harness) void {
        self.fake.deinit();
        self.clock.deinit();
    }

    fn run(self: *Harness, method: []const u8, params: []const u8) !engine.Outcome {
        var command = try router.parse(gpa, method, params, .{});
        defer command.deinit();
        return self.engine.execute(gpa, &command);
    }
};

fn expectResult(outcome: engine.Outcome, expected_json: []const u8) !void {
    switch (outcome) {
        .result => |json| try std.testing.expectEqualStrings(expected_json, json),
        .failure => |failure| {
            std.debug.print("unexpected failure {d} {s}\n", .{ failure.code, failure.message });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectFailure(outcome: engine.Outcome, code: i64, message: []const u8) !void {
    switch (outcome) {
        .result => |json| {
            std.debug.print("unexpected result {s}\n", .{json});
            return error.TestUnexpectedResult;
        },
        .failure => |failure| {
            try std.testing.expectEqual(code, failure.code);
            try std.testing.expectEqualStrings(message, failure.message);
        },
    }
}

// ---- page.* through the fake port (M6) ----

test "page.url returns the port's current url" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.current_url = "http://127.0.0.1:8123/fixture.html";

    var outcome = try h.run("page.url", "{}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"url\":\"http://127.0.0.1:8123/fixture.html\"}");
}

test "page.title returns the port's current title, JSON-escaped" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.current_title = "Fixture \"Ready\"";

    var outcome = try h.run("page.title", "{}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"title\":\"Fixture \\\"Ready\\\"\"}");
}

test "page.navigate calls port.navigate with url and default 30000 ms timeout" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    var outcome = try h.run("page.navigate", "{\"url\":\"http://127.0.0.1/nav-b\"}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 1), h.fake.navigate_calls.items.len);
    try std.testing.expectEqualStrings("http://127.0.0.1/nav-b", h.fake.navigate_calls.items[0]);
    try std.testing.expectEqual(@as(u64, 30000), h.fake.navigate_timeouts.items[0]);
}

test "page.navigate honours timeout_ms" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    var outcome = try h.run("page.navigate", "{\"url\":\"http://x/\",\"timeout_ms\":1234}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 1234), h.fake.navigate_timeouts.items[0]);
}

test "navigation timeout maps to navigation_timeout -32007" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.navigate_result = error.Timeout;

    var outcome = try h.run("page.navigate", "{\"url\":\"http://x/\"}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32007, "navigation_timeout");
}

test "navigation failure maps to navigation_failed -32008" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.navigate_result = error.NavigationFailed;

    var outcome = try h.run("page.navigate", "{\"url\":\"http://x/\"}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32008, "navigation_failed");
}

test "page.reload calls port.reload" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    var outcome = try h.run("page.reload", "{}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 1), h.fake.reload_calls);
}

test "missing page maps to session_invalid -32011" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.url_result = error.NoPage;

    var outcome = try h.run("page.url", "{}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32011, "session_invalid");
}

test "page.evaluate runs in the page world and wraps the value as {result}" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":[1,{\"a\":\"b\"},null]}" }};

    var outcome = try h.run("page.evaluate", "{\"expression\":\"[1, {a: 'b'}, null]\"}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"result\":[1,{\"a\":\"b\"},null]}");
    try std.testing.expectEqual(automation.page_port.World.page, h.fake.eval_calls.items[0].world);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].body, "[1, {a: 'b'}, null]") != null);
}

test "page.evaluate preserves results larger than 4 KB" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    const big = try gpa.alloc(u8, 9000);
    defer gpa.free(big);
    @memset(big, 'x');
    const reply = try std.fmt.allocPrint(gpa, "{{\"ok\":true,\"value\":\"{s}\"}}", .{big});
    defer gpa.free(reply);
    h.fake.eval_replies = &.{.{ .json = reply }};

    var outcome = try h.run("page.evaluate", "{\"expression\":\"'x'.repeat(9000)\"}");
    defer outcome.deinit(gpa);
    const expected = try std.fmt.allocPrint(gpa, "{{\"result\":\"{s}\"}}", .{big});
    defer gpa.free(expected);
    try expectResult(outcome, expected);
}

test "page.evaluate JS exception maps to -32603 with exception data" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":false,\"error\":\"script_exception\",\"retryable\":false,\"data\":{\"reason\":\"script_exception\",\"name\":\"TypeError\",\"message\":\"boom\"}}" }};

    var outcome = try h.run("page.evaluate", "{\"expression\":\"null.x\"}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32603, "script_exception");
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "TypeError") != null);
}

test "page.screenshot is not supported by PagePort yet" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    var outcome = try h.run("page.screenshot", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32603), outcome.failure.code);
}

// ---- dom.* command mapping (slice B) ----

test "dom.click sends a click op to automation.js in the automation world" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true},\"telemetry\":[]}" }};

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#go\",\"options\":{\"force\":true}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");

    const call = h.fake.eval_calls.items[0];
    try std.testing.expectEqual(automation.page_port.World.automation, call.world);
    try std.testing.expect(std.mem.indexOf(u8, call.body, "globalThis.__zbAutomation") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.body, "\"op\":\"click\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.body, "\"selector\":\"css=#go\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.body, "\"options\":{\"force\":true,\"trial\":false}") != null);
}

test "dom.query returns the script's elements value verbatim" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"elements\":[{\"id\":\"zb-1\",\"tag\":\"button\",\"text\":\"Go\",\"bbox\":{\"x\":1,\"y\":2,\"width\":3,\"height\":4}}]},\"telemetry\":[]}" }};

    var outcome = try h.run("dom.query", "{\"selector\":\"css=button\"}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"elements\":[{\"id\":\"zb-1\",\"tag\":\"button\",\"text\":\"Go\",\"bbox\":{\"x\":1,\"y\":2,\"width\":3,\"height\":4}}]}");
}

test "dom.getText returns {text}" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"text\":\"Ready\"}}" }};

    var outcome = try h.run("dom.getText", "{\"selector\":\"css=#status\"}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"text\":\"Ready\"}");
}

test "non-retryable script error maps to its automation code" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"malformed_selector\"}}" }};

    var outcome = try h.run("dom.click", "{\"selector\":\"nope\"}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32001, "element_not_found");
    try std.testing.expectEqualStrings("{\"reason\":\"malformed_selector\"}", outcome.failure.data_json.?);
}

test "malformed script JSON maps to -32603 without echoing the payload" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "not json <secret>" }};

    var outcome = try h.run("dom.getText", "{\"selector\":\"css=#a\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32603), outcome.failure.code);
    try std.testing.expect(outcome.failure.data_json == null);
}

test "unknown script error name maps to -32603" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":false,\"error\":\"weird\",\"retryable\":false}" }};

    var outcome = try h.run("dom.getText", "{\"selector\":\"css=#a\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32603), outcome.failure.code);
}

test "native eval failure maps to -32603" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .err = error.EvalFailed }};

    var outcome = try h.run("dom.getText", "{\"selector\":\"css=#a\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32603), outcome.failure.code);
}

test "cancelled port call maps to cancelled -32012" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .err = error.Cancelled }};

    var outcome = try h.run("dom.getText", "{\"selector\":\"css=#a\"}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32012, "cancelled");
}

// ---- buildCommandJson field mapping ----

fn commandJson(method: []const u8, params: []const u8) ![]u8 {
    var command = try router.parse(gpa, method, params, .{});
    defer command.deinit();
    return script_command.buildCommandJson(gpa, &command, .{ .trace_id = "t1", .command_id = "c1" }, null);
}

test "fill maps selector, value, strict default true, options and ids" {
    const json = try commandJson("dom.fill", "{\"selector\":\"css=#email\",\"value\":\"a@b.c\",\"options\":{\"trial\":true}}");
    defer gpa.free(json);
    try std.testing.expectEqualStrings(
        "{\"op\":\"fill\",\"selector\":\"css=#email\",\"value\":\"a@b.c\",\"strict\":true,\"options\":{\"force\":false,\"trial\":true},\"trace_id\":\"t1\",\"command_id\":\"c1\"}",
        json,
    );
}

test "type maps text" {
    const json = try commandJson("dom.type", "{\"selector\":\"css=#q\",\"text\":\"hi\"}");
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"op\":\"type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"hi\"") != null);
}

test "getAttribute maps name" {
    const json = try commandJson("dom.getAttribute", "{\"selector\":\"css=a\",\"name\":\"href\"}");
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"op\":\"getAttribute\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"href\"") != null);
}

test "waitFor maps state and timeout_ms" {
    const json = try commandJson("dom.waitFor", "{\"selector\":\"css=#x\",\"state\":\"hidden\",\"timeout_ms\":500}");
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"op\":\"waitFor\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"hidden\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"timeout_ms\":500") != null);
}

test "query keeps strict false by default" {
    const json = try commandJson("dom.query", "{\"selector\":\"css=li\"}");
    defer gpa.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"op\":\"query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"strict\":false") != null);
}

test "page verbs are not dom commands" {
    var command = try router.parse(gpa, "page.url", "{}", .{});
    defer command.deinit();
    try std.testing.expectError(error.NotADomCommand, script_command.buildCommandJson(gpa, &command, .{ .trace_id = "t", .command_id = "c" }, null));
}

test "page.evaluate keeps numbers exactly as the script produced them" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":[2.5,1e21,-0.1,12345678901234567890]}" }};

    var outcome = try h.run("page.evaluate", "{\"expression\":\"x\"}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"result\":[2.5,1e21,-0.1,12345678901234567890]}");
}
