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

test "near-max timeout_ms is clamped below the JS/ABI limits without overflow" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }};

    var outcome = try h.run("dom.waitFor", "{\"selector\":\"css=#x\",\"timeout_ms\":18446744073709551615}");
    defer outcome.deinit(gpa);
    const call = h.fake.eval_calls.items[0];
    try std.testing.expectEqual(@as(u64, std.math.maxInt(i32)), call.timeout_ms);
    try std.testing.expect(call.timeout_ms <= std.math.maxInt(u32));
    const expected_js = try std.fmt.allocPrint(gpa, "\"timeout_ms\":{d}", .{engine.max_timeout_ms});
    defer gpa.free(expected_js);
    try std.testing.expect(std.mem.indexOf(u8, call.arg, expected_js) != null);

    var nav = try h.run("page.navigate", "{\"url\":\"http://x/\",\"timeout_ms\":18446744073709551615}");
    defer nav.deinit(gpa);
    try std.testing.expectEqual(engine.max_timeout_ms, h.fake.navigate_timeouts.items[0]);
}

test "url and title receive the command deadline" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();

    var outcome = try h.run("page.title", "{}");
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 30000), h.fake.last_read_timeout_ms);
}

test "dom.press maps to the press op with key and modifiers" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }};

    var outcome = try h.run("dom.press", "{\"selector\":\"css=#q\",\"key\":\"Enter\",\"modifiers\":[\"Shift\"]}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    const arg = try std.json.parseFromSlice(std.json.Value, gpa, h.fake.eval_calls.items[0].arg, .{});
    defer arg.deinit();
    const obj = arg.value.object;
    try std.testing.expectEqualStrings("press", obj.get("op").?.string);
    try std.testing.expectEqualStrings("Enter", obj.get("key").?.string);
    try std.testing.expectEqualStrings("Shift", obj.get("modifiers").?.array.items[0].string);
    try std.testing.expectEqualStrings("css=#q", obj.get("selector").?.string);
}

test "dom.press without selector omits it (focused element)" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }};

    var outcome = try h.run("dom.press", "{\"key\":\"Tab\"}");
    defer outcome.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].arg, "\"selector\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].arg, "\"modifiers\":[]") != null);
}

test "dom.selectOption maps value/label/index and returns the selected value" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"value\":\"fr\"}}" }};

    var by_label = try h.run("dom.selectOption", "{\"selector\":\"css=#c\",\"label\":\"France\"}");
    defer by_label.deinit(gpa);
    try expectResult(by_label, "{\"value\":\"fr\"}");
    var by_index = try h.run("dom.selectOption", "{\"selector\":\"css=#c\",\"index\":3}");
    defer by_index.deinit(gpa);

    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].arg, "\"op\":\"selectOption\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].arg, "\"label\":\"France\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].arg, "\"index\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[1].arg, "\"index\":3") != null);
}

test "dom.selectOption no_option is retried until the deadline" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{
        .{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":true,\"data\":{\"reason\":\"no_option\"}}" },
        .{ .json = "{\"ok\":true,\"value\":{\"value\":\"late\"}}" },
    };

    var outcome = try h.run("dom.selectOption", "{\"selector\":\"css=#c\",\"value\":\"late\"}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"value\":\"late\"}");
    try std.testing.expectEqual(@as(usize, 2), h.fake.eval_calls.items.len);
}

// ---- N7: native (trusted) input ----

const located_reply = "{\"ok\":true,\"value\":{\"x\":10.5,\"y\":20,\"document\":\"0123456789abcdef\"}}";

fn expectFailureData(outcome: engine.Outcome, code: i64, message: []const u8, data_fragment: []const u8) !void {
    try expectFailure(outcome, code, message);
    const data = outcome.failure.data_json orelse return error.TestUnexpectedResult;
    if (std.mem.indexOf(u8, data, data_fragment) == null) {
        std.debug.print("data {s} lacks {s}\n", .{ data, data_fragment });
        return error.TestUnexpectedResult;
    }
}

test "native dom.click: locate (no focus, no text), then one trusted click at the centre within the same deadline" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.eval_cost_ms = 300;
    h.fake.eval_replies = &.{.{ .json = located_reply }};

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"timeout_ms\":1000}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");

    try std.testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
    const arg = h.fake.eval_calls.items[0].arg;
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"op\":\"locate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"action\":\"click\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"focus\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"force\":false") != null);

    try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
    const click = h.fake.native_calls.items[0];
    try std.testing.expect(click.kind == .click);
    try std.testing.expectEqual(@as(f64, 10.5), click.x);
    try std.testing.expectEqual(@as(f64, 20), click.y);
    // One deadline: 1000 ms minus the 300 ms locate.
    try std.testing.expectEqual(@as(u64, 700), click.timeout_ms);
}

test "native dom.click retries locate until actionable, then clicks once" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{
        .{ .json = "{\"ok\":false,\"error\":\"element_obscured\",\"retryable\":true,\"data\":{\"reason\":\"covered\"}}" },
        .{ .json = located_reply },
    };
    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 2), h.fake.eval_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
}

test "native trial: locate without focus, no native input at all" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    for ([_][]const u8{
        "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"trial\":true}}",
    }) |params| {
        var outcome = try h.run("dom.click", params);
        defer outcome.deinit(gpa);
        try expectResult(outcome, "{\"ok\":true}");
    }
    var typed = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"hi\",\"options\":{\"input\":\"native\",\"trial\":true}}");
    defer typed.deinit(gpa);
    try expectResult(typed, "{\"ok\":true}");
    for (h.fake.eval_calls.items) |call| try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"focus\":false") != null);
    try std.testing.expectEqual(@as(usize, 0), h.fake.native_calls.items.len);
}

test "native click that times out after dispatch is terminal: no second click" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    h.fake.native_fail_at = 0;
    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32009, "action_timeout");
    try std.testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
}

test "native dom.type: locate with focus (text never sent to the script), then the whole text natively" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"secret café\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    const arg = h.fake.eval_calls.items[0].arg;
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"action\":\"type\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"focus\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "secret") == null);
    // No click side effect: exactly one native call, the text.
    try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
    try std.testing.expect(h.fake.native_calls.items[0].kind == .text);
    try std.testing.expectEqualStrings("secret café", h.fake.native_calls.items[0].data);
}

test "native dom.type partial timeout: partial_input with sent_chars, the prefix is never retyped" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    h.fake.native_fail_at = 0;
    h.fake.native_failed_sent = 3;
    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"abcdef\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32009, "action_timeout", "\"reason\":\"partial_input\",");
    try expectFailureData(outcome, -32009, "action_timeout", "\"sent_chars\":3");
    try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
}

test "native dom.type failing before any character keeps the port error (no partial)" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    h.fake.native_fail_at = 0;
    h.fake.native_error = error.NoPage;
    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"ab\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32011, "session_invalid");
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "sent_chars") == null);
}

test "native dom.type with delay_ms: one code point per call, delays between, progress counted across calls" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"aéb\",\"delay_ms\":50,\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 3), h.fake.native_calls.items.len);
    try std.testing.expectEqualStrings("é", h.fake.native_calls.items[1].data);
    var total: u64 = 0;
    for (h.clock.sleeps.items) |ms| total += ms;
    try std.testing.expectEqual(@as(u64, 100), total);

    // The second character fails: one already typed -> partial_input, sent_chars 1.
    var h2: Harness = undefined;
    h2.init();
    defer h2.deinit();
    h2.fake.eval_replies = &.{.{ .json = located_reply }};
    h2.fake.native_fail_at = 1;
    var failed = try h2.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"aéb\",\"delay_ms\":50,\"options\":{\"input\":\"native\"}}");
    defer failed.deinit(gpa);
    try expectFailureData(failed, -32009, "action_timeout", "\"sent_chars\":1");
    try std.testing.expectEqual(@as(usize, 2), h2.fake.native_calls.items.len);
}

test "native dom.type with delay_ms stops before a delay that would pass the deadline" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"abc\",\"delay_ms\":600,\"options\":{\"input\":\"native\",\"timeout_ms\":1000}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32009, "action_timeout", "\"sent_chars\":2");
    try std.testing.expectEqual(@as(usize, 2), h.fake.native_calls.items.len);
}

test "native dom.press: no selector -> key only; selector -> locate+focus then the key, modifier bits" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    var bare = try h.run("dom.press", "{\"key\":\"Enter\",\"modifiers\":[\"Shift\",\"Meta\"],\"options\":{\"input\":\"native\"}}");
    defer bare.deinit(gpa);
    try expectResult(bare, "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try std.testing.expectEqualStrings("Enter", h.fake.native_calls.items[0].data);
    try std.testing.expectEqual(@as(u8, 0b1001), h.fake.native_calls.items[0].modifiers);

    var targeted = try h.run("dom.press", "{\"selector\":\"css=#q\",\"key\":\"a\",\"modifiers\":[\"Control\",\"Alt\"],\"options\":{\"input\":\"native\"}}");
    defer targeted.deinit(gpa);
    try expectResult(targeted, "{\"ok\":true}");
    const arg = h.fake.eval_calls.items[0].arg;
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"action\":\"press\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"focus\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"key\"") == null);
    try std.testing.expectEqual(@as(usize, 2), h.fake.native_calls.items.len);
    try std.testing.expect(h.fake.native_calls.items[1].kind == .key);
    try std.testing.expectEqual(@as(u8, 0b0110), h.fake.native_calls.items[1].modifiers);
}

test "native input on a backend without it: session_invalid reason unsupported, nothing dispatched" {
    var fake = FakePagePort.init(gpa);
    defer fake.deinit();
    var clock = FakeClock.init(gpa);
    defer clock.deinit();
    var e = engine.Engine.init(fake.portWithoutNative(), clock.clock());
    fake.eval_replies = &.{.{ .json = located_reply }};
    var command = try router.parse(gpa, "dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}}", .{});
    defer command.deinit();
    var outcome = try e.execute(gpa, &command);
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32011, "session_invalid", "\"reason\":\"unsupported\"");
    // Said before any page work: no locate eval either.
    try std.testing.expectEqual(@as(usize, 0), fake.eval_calls.items.len);
}

test "a malformed locate answer is an internal error, and nothing is clicked" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    for ([_][]const u8{
        "{\"ok\":true,\"value\":{\"x\":\"1\",\"y\":2,\"document\":\"0123456789abcdef\"}}",
        "{\"ok\":true,\"value\":{\"x\":1,\"document\":\"0123456789abcdef\"}}",
        "{\"ok\":true,\"value\":{\"x\":1,\"y\":2,\"document\":\"doc-A\"}}",
        "{\"ok\":true,\"value\":{\"x\":1,\"y\":2,\"document\":\"0123456789ABCDEF\"}}",
        "{\"ok\":true,\"value\":{\"x\":1,\"y\":2,\"document\":\"0123456789abcde\"}}",
        "{\"ok\":true,\"value\":{\"x\":1,\"y\":2,\"document\":\"0123456789abcdef0\"}}",
        "{\"ok\":true,\"value\":{\"x\":1,\"y\":2,\"document\":\"0123456789abcd\\u0000f\"}}",
        "{\"ok\":true,\"value\":{\"x\":1,\"y\":2}}",
        "{\"ok\":true,\"value\":{\"x\":1,\"y\":2,\"document\":\"\"}}",
        "{\"ok\":true,\"value\":{\"x\":1,\"y\":2,\"document\":7}}",
        "{\"ok\":true,\"value\":[1,2]}",
    }) |reply| {
        h.fake.eval_replies = &.{.{ .json = reply }};
        var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}}");
        defer outcome.deinit(gpa);
        try expectFailure(outcome, -32603, "Malformed script result");
    }
    try std.testing.expectEqual(@as(usize, 0), h.fake.native_calls.items.len);
}

test "a native type failing after progress keeps its error class, with partial_input and sent_chars" {
    const cases = [_]struct { err: automation.page_port.PortError, code: i64, message: []const u8 }{
        .{ .err = error.Timeout, .code = -32009, .message = "action_timeout" },
        .{ .err = error.Cancelled, .code = -32012, .message = "cancelled" },
        .{ .err = error.NoPage, .code = -32011, .message = "session_invalid" },
        .{ .err = error.EvalFailed, .code = -32603, .message = "Evaluation failed" },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        h.init();
        defer h.deinit();
        h.fake.eval_replies = &.{.{ .json = located_reply }};
        h.fake.native_fail_at = 0;
        h.fake.native_error = case.err;
        h.fake.native_failed_sent = 2;
        var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"abcd\",\"options\":{\"input\":\"native\"}}");
        defer outcome.deinit(gpa);
        try expectFailureData(outcome, case.code, case.message, "\"reason\":\"partial_input\"");
        try expectFailureData(outcome, case.code, case.message, "\"sent_chars\":2");
        try expectFailureData(outcome, case.code, case.message, "\"trace_id\"");
    }
}

test "a native type that reports fewer code points than requested is a partial failure, not success" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    h.fake.native_success_sent = 1;
    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"a\\nb\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32603, "Incomplete native input", "\"sent_chars\":1");
    try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
}

// ---- N7 v3.1: native input is bound to the located document ----

test "native calls carry the located document token; press without a selector carries none" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    var click = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}}");
    defer click.deinit(gpa);
    var typed = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"x\",\"options\":{\"input\":\"native\"}}");
    defer typed.deinit(gpa);
    var bare = try h.run("dom.press", "{\"key\":\"Enter\",\"options\":{\"input\":\"native\"}}");
    defer bare.deinit(gpa);
    const calls = h.fake.native_calls.items;
    try std.testing.expectEqual(@as(usize, 3), calls.len);
    try std.testing.expectEqualStrings("0123456789abcdef", calls[0].document.?);
    try std.testing.expectEqualStrings("0123456789abcdef", calls[1].document.?);
    try std.testing.expect(calls[2].document == null);
}

test "document changed before any input: the target is located again and the input goes to the new document" {
    for ([_][]const u8{
        "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}}",
    }) |params| {
        var h: Harness = undefined;
        h.init();
        defer h.deinit();
        h.fake.eval_replies = &.{
            .{ .json = located_reply },
            .{ .json = "{\"ok\":true,\"value\":{\"x\":3,\"y\":4,\"document\":\"fedcba9876543210\"}}" },
        };
        h.fake.native_fail_at = 0;
        h.fake.native_error = error.DocumentChanged;
        var outcome = try h.run("dom.click", params);
        defer outcome.deinit(gpa);
        try expectResult(outcome, "{\"ok\":true}");
        try std.testing.expectEqual(@as(usize, 2), h.fake.eval_calls.items.len);
        try std.testing.expectEqual(@as(usize, 2), h.fake.native_calls.items.len);
        try std.testing.expectEqualStrings("fedcba9876543210", h.fake.native_calls.items[1].document.?);
        try std.testing.expectEqual(@as(f64, 3), h.fake.native_calls.items[1].x);
    }
    // Same for type when nothing was typed yet.
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{
        .{ .json = located_reply },
        .{ .json = "{\"ok\":true,\"value\":{\"x\":3,\"y\":4,\"document\":\"fedcba9876543210\"}}" },
    };
    h.fake.native_fail_at = 0;
    h.fake.native_error = error.DocumentChanged;
    var typed = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"hi\",\"options\":{\"input\":\"native\"}}");
    defer typed.deinit(gpa);
    try expectResult(typed, "{\"ok\":true}");
    try std.testing.expectEqualStrings("hi", h.fake.native_calls.items[1].data);
}

test "document changed after typing (even sent == requested on a one-code-point call) is terminal; the suffix is never sent" {
    // delay_ms: "a" ok, "\n" is dispatched and navigates (sent 1 of 1 +
    // DocumentChanged), "b" must never be sent.
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    h.fake.native_fail_at = 1;
    h.fake.native_error = error.DocumentChanged;
    h.fake.native_failed_sent = 1;
    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"a\\nb\",\"delay_ms\":10,\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32001, "element_not_found", "\"reason\":\"partial_input\"");
    try expectFailureData(outcome, -32001, "element_not_found", "\"last_error\":\"document_changed\"");
    try expectFailureData(outcome, -32001, "element_not_found", "\"sent_chars\":2");
    try std.testing.expectEqual(@as(usize, 2), h.fake.native_calls.items.len);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("a\n", h.fake.nativeTyped(&buf));
    try std.testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);

    // Whole string: the backend stops after "a\n" (2 of 3) on the change.
    var w: Harness = undefined;
    w.init();
    defer w.deinit();
    w.fake.eval_replies = &.{.{ .json = located_reply }};
    w.fake.native_fail_at = 0;
    w.fake.native_error = error.DocumentChanged;
    w.fake.native_failed_sent = 2;
    var whole = try w.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"a\\nb\",\"options\":{\"input\":\"native\"}}");
    defer whole.deinit(gpa);
    try expectFailureData(whole, -32001, "element_not_found", "\"sent_chars\":2");
    try std.testing.expectEqual(@as(usize, 1), w.fake.native_calls.items.len);
    try std.testing.expectEqual(@as(usize, 1), w.fake.eval_calls.items.len);
}

test "a document change on a selector-less press (no binding) is reported, not retried" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.native_fail_at = 0;
    h.fake.native_error = error.DocumentChanged;
    var outcome = try h.run("dom.press", "{\"key\":\"Enter\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32001, "element_not_found", "\"reason\":\"document_changed\"");
    try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
}

test "a page that keeps replacing its document: re-locate until the deadline, then element_not_found document_changed, nothing sent" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.eval_cost_ms = 50;
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    h.fake.native_fail_at = 0;
    h.fake.native_fail_onwards = true;
    h.fake.native_error = error.DocumentChanged;
    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"abc\",\"options\":{\"input\":\"native\",\"timeout_ms\":1000}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32001, "element_not_found", "\"reason\":\"document_changed\"");
    try expectFailureData(outcome, -32001, "element_not_found", "\"trace_id\"");
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "sent_chars") == null);
    try std.testing.expect(h.fake.native_calls.items.len > 1);
    // Hard deadline: no page call outlives the time it was given.
    try std.testing.expect(h.clock.now_ms <= 1000);
}

test "after a re-locate, only the final locate's timeout becomes document_changed; other failures stay as they are" {
    // Timeline (timeout 116): locate 50 ms, native DocumentChanged, 16 ms
    // pause, re-locate gets the last 50 ms and ends exactly at the deadline.
    const cases = [_]struct { final: fakes.EvalReply, code: i64, message: []const u8, data: []const u8 }{
        .{ .final = .{ .err = error.Cancelled }, .code = -32012, .message = "cancelled", .data = "\"trace_id\"" },
        .{ .final = .{ .err = error.NoPage }, .code = -32011, .message = "session_invalid", .data = "\"trace_id\"" },
        .{ .final = .{ .err = error.EvalFailed }, .code = -32603, .message = "Evaluation failed", .data = "" },
        .{ .final = .{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"no_match\"}}" }, .code = -32001, .message = "element_not_found", .data = "\"reason\":\"no_match\"" },
    };
    for (cases) |case| {
        var h: Harness = undefined;
        h.init();
        defer h.deinit();
        h.fake.clock = &h.clock;
        h.fake.eval_cost_ms = 50;
        h.fake.eval_replies = &.{ .{ .json = located_reply }, case.final };
        h.fake.native_fail_at = 0;
        h.fake.native_error = error.DocumentChanged;
        var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"timeout_ms\":116}}");
        defer outcome.deinit(gpa);
        try std.testing.expectEqual(@as(u64, 116), h.clock.now_ms);
        if (case.data.len > 0) try expectFailureData(outcome, case.code, case.message, case.data) else try expectFailure(outcome, case.code, case.message);
        try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
    }

    // The final re-locate's own PagePort Timeout yields to the evidence.
    var t: Harness = undefined;
    t.init();
    defer t.deinit();
    t.fake.clock = &t.clock;
    t.fake.eval_cost_ms = 50;
    t.fake.eval_replies = &.{.{ .json = located_reply }};
    t.fake.native_fail_at = 0;
    t.fake.native_error = error.DocumentChanged;
    var timed_out = try t.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"timeout_ms\":100}}");
    defer timed_out.deinit(gpa);
    try expectFailureData(timed_out, -32001, "element_not_found", "\"reason\":\"document_changed\"");
    try std.testing.expectEqual(@as(u64, 100), t.clock.now_ms);
}

test "after a re-locate, real evidence from the new document is kept (element_obscured to the deadline is not document_changed)" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.eval_cost_ms = 10;
    h.fake.eval_replies = &.{
        .{ .json = located_reply },
        .{ .json = "{\"ok\":false,\"error\":\"element_obscured\",\"retryable\":true,\"data\":{\"reason\":\"receives-events\"}}" },
    };
    h.fake.native_fail_at = 0;
    h.fake.native_error = error.DocumentChanged;
    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"timeout_ms\":200}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32009, "action_timeout", "\"last_error\":\"element_obscured\"");
    try expectFailureData(outcome, -32009, "action_timeout", "\"reason\":\"receives-events\"");
    try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
    try std.testing.expect(h.clock.now_ms <= 200);
}
