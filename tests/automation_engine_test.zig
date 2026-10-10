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

test "page.evaluate JS exception maps to -32603 with only the exception class" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    // Even if a script answer carried a message, it must not reach the client.
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":false,\"error\":\"script_exception\",\"retryable\":false,\"data\":{\"reason\":\"script_exception\",\"name\":\"TypeError\",\"message\":\"token=s3cret\"}}" }};

    var outcome = try h.run("page.evaluate", "{\"expression\":\"null.x\"}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32603, "script_exception");
    try std.testing.expectEqualStrings("{\"name\":\"TypeError\"}", outcome.failure.data_json.?);
}

test "page.evaluate body never reports the exception message" {
    const body = try script_command.buildEvaluateBody(gpa, "1");
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "e.message") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "String(e") == null);
}

test "page.evaluate passes a null arg" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":1}" }};

    var outcome = try h.run("page.evaluate", "{\"expression\":\"1\"}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("null", h.fake.eval_calls.items[0].arg);
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
    try std.testing.expectEqualStrings(script_command.handle_body, call.body);
    try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"op\":\"click\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"selector\":\"css=#go\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"options\":{\"force\":true,\"trial\":false}") != null);
    try std.testing.expectEqual(@as(u64, 30000), call.timeout_ms);
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
    const data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try std.testing.expectEqualStrings("malformed_selector", data.value.object.get("reason").?.string);
    try std.testing.expectEqual(@as(usize, 32), data.value.object.get("trace_id").?.string.len);
    try std.testing.expect(std.mem.startsWith(u8, data.value.object.get("command_id").?.string, "cmd-"));
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
    return script_command.buildCommandJson(gpa, &command, .{ .trace_id = "t1", .parent_span_id = "p1", .command_id = "c1" }, null);
}

test "fill maps selector, value, strict default true, options and ids" {
    const json = try commandJson("dom.fill", "{\"selector\":\"css=#email\",\"value\":\"a@b.c\",\"options\":{\"trial\":true}}");
    defer gpa.free(json);
    try std.testing.expectEqualStrings(
        "{\"op\":\"fill\",\"selector\":\"css=#email\",\"value\":\"a@b.c\",\"strict\":true,\"options\":{\"force\":false,\"trial\":true},\"trace_id\":\"t1\",\"parent_span_id\":\"p1\",\"command_id\":\"c1\",\"attempt_index\":0}",
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
    try std.testing.expectError(error.NotADomCommand, script_command.buildCommandJson(gpa, &command, .{ .trace_id = "t", .parent_span_id = "p", .command_id = "c" }, null));
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

test "automation errors from the port carry trace_id and command_id" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.url_result = error.NoPage;

    var outcome = try h.run("page.url", "{}");
    defer outcome.deinit(gpa);
    const data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try std.testing.expect(data.value.object.get("trace_id") != null);
    try std.testing.expect(data.value.object.get("command_id") != null);
    try std.testing.expect(data.value.object.get("reason") == null);
}

test "dom command carries the root span id as parent_span_id and the same trace in errors" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":false,\"error\":\"element_disabled\",\"retryable\":false,\"data\":{\"reason\":\"enabled\"}}" }};

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\"}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32005, "element_disabled");

    const arg = try std.json.parseFromSlice(std.json.Value, gpa, h.fake.eval_calls.items[0].arg, .{});
    defer arg.deinit();
    const data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try std.testing.expectEqual(@as(usize, 16), arg.value.object.get("parent_span_id").?.string.len);
    try std.testing.expectEqualStrings(arg.value.object.get("trace_id").?.string, data.value.object.get("trace_id").?.string);
    try std.testing.expectEqualStrings(arg.value.object.get("command_id").?.string, data.value.object.get("command_id").?.string);
}

test "each command gets a distinct command_id and trace_id" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }};

    var a = try h.run("dom.click", "{\"selector\":\"css=#b\"}");
    defer a.deinit(gpa);
    var b = try h.run("dom.click", "{\"selector\":\"css=#b\"}");
    defer b.deinit(gpa);
    const arg_a = try std.json.parseFromSlice(std.json.Value, gpa, h.fake.eval_calls.items[0].arg, .{});
    defer arg_a.deinit();
    const arg_b = try std.json.parseFromSlice(std.json.Value, gpa, h.fake.eval_calls.items[1].arg, .{});
    defer arg_b.deinit();
    try std.testing.expect(!std.mem.eql(u8, arg_a.value.object.get("command_id").?.string, arg_b.value.object.get("command_id").?.string));
    try std.testing.expect(!std.mem.eql(u8, arg_a.value.object.get("trace_id").?.string, arg_b.value.object.get("trace_id").?.string));
}

test "adversarial selector/value/text never reach the JS source and round-trip exactly" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }};

    // quotes, backslash, newline, </script>, U+2028, U+2029, and a JS breakout attempt
    const nasty = "a\"b'c\\d\ne</script>\u{2028}\u{2029}`);alert(1);//";
    const params = try std.json.Stringify.valueAlloc(gpa, .{ .selector = nasty, .value = nasty }, .{});
    defer gpa.free(params);

    var outcome = try h.run("dom.fill", params);
    defer outcome.deinit(gpa);
    const call = h.fake.eval_calls.items[0];
    try std.testing.expectEqualStrings(script_command.handle_body, call.body);
    const arg = try std.json.parseFromSlice(std.json.Value, gpa, call.arg, .{});
    defer arg.deinit();
    try std.testing.expectEqualStrings(nasty, arg.value.object.get("selector").?.string);
    try std.testing.expectEqualStrings(nasty, arg.value.object.get("value").?.string);
}

test "waitFor: JS timeout is the command timeout, native deadline adds grace" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }};

    var outcome = try h.run("dom.waitFor", "{\"selector\":\"css=#x\",\"timeout_ms\":700}");
    defer outcome.deinit(gpa);
    const call = h.fake.eval_calls.items[0];
    try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"timeout_ms\":700") != null);
    try std.testing.expectEqual(@as(u64, 700 + engine.wait_for_native_grace_ms), call.timeout_ms);
}

test "waitFor default timeout is sent explicitly to the script" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }};

    var outcome = try h.run("dom.waitFor", "{\"selector\":\"css=#x\"}");
    defer outcome.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].arg, "\"timeout_ms\":30000") != null);
}

test "waitFor script timeout maps to element_not_found, not a platform timeout" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":true,\"data\":{\"reason\":\"timeout\"}}" }};

    var outcome = try h.run("dom.waitFor", "{\"selector\":\"css=#never\",\"timeout_ms\":50}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32001, "element_not_found");
}
