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

test "page.screenshot on a backend without it is -32603 not supported" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.engine = engine.Engine.init(h.fake.portWithoutNative(), h.clock.clock());

    var outcome = try h.run("page.screenshot", "{}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32603, "page.screenshot is not supported");
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

// ---- N8: humanized native input (orchestrator's 5 rules) ----

const NativeCall = fakes.NativeCall;
/// Target at (500, 400) in a 1000x800 viewport: an 80-240 px start never
/// needs clamping.
const human_located = "{\"ok\":true,\"value\":{\"x\":500,\"y\":400,\"document\":\"0123456789abcdef\",\"viewport\":{\"width\":1000,\"height\":800}}}";

const HumanHarness = struct {
    h: Harness,
    prng: std.Random.DefaultPrng,

    fn init(self: *HumanHarness, seed: u64) void {
        self.h.init();
        self.h.fake.clock = &self.h.clock;
        self.h.fake.eval_replies = &.{.{ .json = human_located }};
        self.prng = std.Random.DefaultPrng.init(seed);
        self.h.engine.random = self.prng.random();
    }

    fn deinit(self: *HumanHarness) void {
        self.h.deinit();
    }
};

fn dist(a: NativeCall, x: f64, y: f64) f64 {
    return @sqrt((a.x - x) * (a.x - x) + (a.y - y) * (a.y - y));
}

test "humanized click: unknown pointer starts 80-240 px off target in view, curved moves end on the target, then one click" {
    var hh: HumanHarness = undefined;
    hh.init(7);
    defer hh.deinit();
    const h = &hh.h;
    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");

    var buf: [256]NativeCall = undefined;
    const moves = h.fake.nativeOf(.move, &buf);
    try std.testing.expect(moves.len >= 10);
    const start = moves[0];
    const start_distance = dist(start, 500, 400);
    try std.testing.expect(start_distance >= 80 - 1e-9 and start_distance <= 240 + 1e-9);
    try std.testing.expect(start.x >= 0 and start.x <= 999 and start.y >= 0 and start.y <= 799);
    try std.testing.expect(dist(moves[moves.len - 1], 500, 400) < 1e-6);
    for (moves) |m| try std.testing.expectEqualStrings("0123456789abcdef", m.document.?);
    // The click is the last call, at the target, after every move.
    const calls = h.fake.native_calls.items;
    try std.testing.expect(calls[calls.len - 1].kind == .click);
    try std.testing.expectEqual(@as(usize, moves.len + 1), calls.len);
    try std.testing.expectEqual(@as(f64, 500), calls[calls.len - 1].x);
    // Moves are paced (time passes between first move and click).
    try std.testing.expect(calls[calls.len - 1].at_ms > start.at_ms);
    // The window's pointer cache now holds the target.
    try std.testing.expectEqual(@as(f64, 400), h.fake.pointer_pos.?.y);
}

test "humanized click starts from the window's cached pointer position" {
    var hh: HumanHarness = undefined;
    hh.init(11);
    defer hh.deinit();
    hh.h.fake.pointer_pos = .{ .x = 5, .y = 7 };
    var outcome = try hh.h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    const first = hh.h.fake.native_calls.items[0];
    try std.testing.expect(first.kind == .move);
    try std.testing.expectEqual(@as(f64, 5), first.x);
    try std.testing.expectEqual(@as(f64, 7), first.y);
}

test "humanize schedule that does not fit the deadline fails before any dispatch (humanize_budget)" {
    for ([_][]const u8{
        "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true,\"timeout_ms\":120}}",
    }) |params| {
        var hh: HumanHarness = undefined;
        hh.init(3);
        defer hh.deinit();
        var outcome = try hh.h.run("dom.click", params);
        defer outcome.deinit(gpa);
        try expectFailureData(outcome, -32009, "action_timeout", "\"reason\":\"humanize_budget\"");
        try std.testing.expectEqual(@as(usize, 0), hh.h.fake.native_calls.items.len);
    }
    // Typing: 11 characters need at least 10 x 80 ms (+ a word pause).
    var t: HumanHarness = undefined;
    t.init(3);
    defer t.deinit();
    var typed = try t.h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"hello world\",\"options\":{\"input\":\"native\",\"humanize\":true,\"timeout_ms\":800}}");
    defer typed.deinit(gpa);
    try expectFailureData(typed, -32009, "action_timeout", "\"reason\":\"humanize_budget\"");
    try std.testing.expectEqual(@as(usize, 0), t.h.fake.native_calls.items.len);
    // Not compressed: the clock did not move past the locate.
    try std.testing.expectEqual(@as(usize, 0), t.h.clock.sleeps.items.len);
}

test "document change after a dispatched move is terminal: no re-locate, no click, pointer stays at the last dispatched move" {
    var hh: HumanHarness = undefined;
    hh.init(5);
    defer hh.deinit();
    const h = &hh.h;
    h.fake.native_fail_at = 3;
    h.fake.native_error = error.DocumentChanged;
    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32001, "element_not_found", "\"reason\":\"document_changed\"");
    try std.testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
    try std.testing.expectEqual(@as(usize, 4), h.fake.native_calls.items.len);
    for (h.fake.native_calls.items) |c| try std.testing.expect(c.kind == .move);
    const last_sent = h.fake.native_calls.items[2];
    try std.testing.expectEqual(last_sent.x, h.fake.pointer_pos.?.x);
    try std.testing.expectEqual(last_sent.y, h.fake.pointer_pos.?.y);
}

test "document change on the first move (nothing dispatched yet) re-locates" {
    var hh: HumanHarness = undefined;
    hh.init(9);
    defer hh.deinit();
    const h = &hh.h;
    h.fake.native_fail_at = 0;
    h.fake.native_error = error.DocumentChanged;
    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 2), h.fake.eval_calls.items.len);
}

test "humanized type: one code point per call, gaps within the typing profile (80-200 ms, 300-600 ms before a space)" {
    var hh: HumanHarness = undefined;
    hh.init(13);
    defer hh.deinit();
    const h = &hh.h;
    const text = "héllo wörld";
    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"héllo wörld\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    const calls = h.fake.native_calls.items;
    try std.testing.expectEqual(try std.unicode.utf8CountCodepoints(text), calls.len);
    // The first character gets its delay too (the clock was 0 after locate).
    try std.testing.expect(calls[0].at_ms >= 80 and calls[0].at_ms <= 200);
    var typed: [32]u8 = undefined;
    try std.testing.expectEqualStrings(text, h.fake.nativeTyped(&typed));
    for (calls[1..], 1..) |c, i| {
        const gap = c.at_ms - calls[i - 1].at_ms;
        if (std.mem.eql(u8, c.data, " ")) {
            try std.testing.expect(gap >= 300 and gap <= 600);
        } else {
            try std.testing.expect(gap >= 80 and gap <= 200);
        }
    }
}

test "humanized press: one profile dwell, then the key" {
    var hh: HumanHarness = undefined;
    hh.init(17);
    defer hh.deinit();
    var outcome = try hh.h.run("dom.press", "{\"key\":\"Enter\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    try std.testing.expectEqual(@as(usize, 1), hh.h.fake.native_calls.items.len);
    const at = hh.h.fake.native_calls.items[0].at_ms;
    try std.testing.expect(at >= 80 and at <= 200);
}

test "an injected seed makes the humanized schedule deterministic" {
    var runs: [2][64]NativeCall = undefined;
    var lens: [2]usize = undefined;
    for (0..2) |r| {
        var hh: HumanHarness = undefined;
        hh.init(42);
        defer hh.deinit();
        var outcome = try hh.h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
        defer outcome.deinit(gpa);
        lens[r] = hh.h.fake.native_calls.items.len;
        for (hh.h.fake.native_calls.items, 0..) |c, i| runs[r][i] = .{ .kind = c.kind, .x = c.x, .y = c.y, .timeout_ms = 0, .at_ms = c.at_ms };
    }
    try std.testing.expectEqual(lens[0], lens[1]);
    for (runs[0][0..lens[0]], runs[1][0..lens[1]]) |a, b| {
        try std.testing.expectEqual(a.x, b.x);
        try std.testing.expectEqual(a.at_ms, b.at_ms);
    }
}

test "humanized click without a known pointer needs the viewport: missing viewport is malformed, nothing sent" {
    var hh: HumanHarness = undefined;
    hh.init(1);
    defer hh.deinit();
    hh.h.fake.eval_replies = &.{.{ .json = located_reply }};
    var outcome = try hh.h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32603, "Malformed script result");
    try std.testing.expectEqual(@as(usize, 0), hh.h.fake.native_calls.items.len);
}

test "production humanize (no injected RNG) seeds from OS entropy and runs" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.eval_replies = &.{.{ .json = human_located }};
    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
}

test "a one-character humanized type still waits its 80-200 ms key delay" {
    var hh: HumanHarness = undefined;
    hh.init(23);
    defer hh.deinit();
    var outcome = try hh.h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"é\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    const at = hh.h.fake.native_calls.items[0].at_ms;
    try std.testing.expect(at >= 80 and at <= 200);
}

test "a repeated humanized click on the same target never starts on the target (cached pointer is there)" {
    var hh: HumanHarness = undefined;
    hh.init(29);
    defer hh.deinit();
    const h = &hh.h;
    var first = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer first.deinit(gpa);
    try std.testing.expectEqual(@as(f64, 500), h.fake.pointer_pos.?.x);
    const before = h.fake.native_calls.items.len;
    var second = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer second.deinit(gpa);
    try expectResult(second, "{\"ok\":true}");
    const start = h.fake.native_calls.items[before];
    try std.testing.expect(start.kind == .move);
    const d = dist(start, 500, 400);
    try std.testing.expect(d >= 80 - 1e-9 and d <= 240 + 1e-9);
}

test "unknown-pointer start is in view and never the target, also for targets in viewport corners and a tiny viewport" {
    const cases = [_][]const u8{
        "{\"ok\":true,\"value\":{\"x\":0,\"y\":0,\"document\":\"0123456789abcdef\",\"viewport\":{\"width\":1000,\"height\":800}}}",
        "{\"ok\":true,\"value\":{\"x\":999,\"y\":0,\"document\":\"0123456789abcdef\",\"viewport\":{\"width\":1000,\"height\":800}}}",
        "{\"ok\":true,\"value\":{\"x\":0,\"y\":799,\"document\":\"0123456789abcdef\",\"viewport\":{\"width\":1000,\"height\":800}}}",
        "{\"ok\":true,\"value\":{\"x\":999,\"y\":799,\"document\":\"0123456789abcdef\",\"viewport\":{\"width\":1000,\"height\":800}}}",
        "{\"ok\":true,\"value\":{\"x\":0,\"y\":0,\"document\":\"0123456789abcdef\",\"viewport\":{\"width\":3,\"height\":3}}}",
    };
    const targets = [_][2]f64{ .{ 0, 0 }, .{ 999, 0 }, .{ 0, 799 }, .{ 999, 799 }, .{ 0, 0 } };
    const limits = [_][2]f64{ .{ 999, 799 }, .{ 999, 799 }, .{ 999, 799 }, .{ 999, 799 }, .{ 2, 2 } };
    for (cases, targets, limits) |reply, t, lim| {
        for (0..20) |seed| {
            var hh: HumanHarness = undefined;
            hh.init(seed);
            defer hh.deinit();
            hh.h.fake.eval_replies = &.{.{ .json = reply }};
            var outcome = try hh.h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
            defer outcome.deinit(gpa);
            try expectResult(outcome, "{\"ok\":true}");
            const start = hh.h.fake.native_calls.items[0];
            try std.testing.expect(start.x >= 0 and start.x <= lim[0] and start.y >= 0 and start.y <= lim[1]);
            try std.testing.expect(dist(start, t[0], t[1]) >= 1);
        }
    }
}

test "humanized click on a backend without nativeMove: -32011 unsupported at once, no page work" {
    var fake = FakePagePort.init(gpa);
    defer fake.deinit();
    var clock = FakeClock.init(gpa);
    defer clock.deinit();
    var e = engine.Engine.init(fake.portWithoutMove(), clock.clock());
    fake.eval_replies = &.{.{ .json = human_located }};
    var command = try router.parse(gpa, "dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}", .{});
    defer command.deinit();
    var outcome = try e.execute(gpa, &command);
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32011, "session_invalid", "\"reason\":\"unsupported\"");
    try std.testing.expectEqual(@as(usize, 0), fake.eval_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), fake.native_calls.items.len);
    // Humanized type/press need no motion and still run.
    var typed = try router.parse(gpa, "dom.press", "{\"key\":\"a\",\"options\":{\"input\":\"native\",\"humanize\":true}}", .{});
    defer typed.deinit();
    var pressed = try e.execute(gpa, &typed);
    defer pressed.deinit(gpa);
    try expectResult(pressed, "{\"ok\":true}");
}

test "a one-character humanized type below the 80 ms key minimum fails humanize_budget before dispatch" {
    var hh: HumanHarness = undefined;
    hh.init(31);
    defer hh.deinit();
    var outcome = try hh.h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"x\",\"options\":{\"input\":\"native\",\"humanize\":true,\"timeout_ms\":79}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32009, "action_timeout", "\"reason\":\"humanize_budget\"");
    try std.testing.expectEqual(@as(usize, 0), hh.h.fake.native_calls.items.len);
}

// ---- v3.3 / v3.4: dom.setInputFiles, dom.hover, dom.scroll, page.screenshot ----

test "dom.setInputFiles: chooseFiles op with count and strict, the paths go to the port, the op's value is the result" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"multiple\":true,\"changed\":true}}" }};
    var outcome = try h.run("dom.setInputFiles", "{\"selector\":\"css=#f\",\"paths\":[\"/tmp/a.txt\",\"/tmp/b.png\"]}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"multiple\":true,\"changed\":true}");
    try std.testing.expectEqual(@as(usize, 1), h.fake.files_calls.items.len);
    try std.testing.expectEqualStrings("/tmp/a.txt\n/tmp/b.png", h.fake.files_calls.items[0]);
    const call = h.fake.eval_calls.items[0];
    try std.testing.expectEqual(automation.page_port.World.automation, call.world);
    try std.testing.expectEqualStrings(script_command.handle_body, call.body);
    try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"op\":\"chooseFiles\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"strict\":true") != null);
    // The paths never go to the script (the chooser gets them natively).
    try std.testing.expect(std.mem.indexOf(u8, call.arg, "/tmp/a.txt") == null);
}

test "dom.setInputFiles retries the op's retryable refusal (nothing was clicked), then succeeds once" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{
        .{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":true,\"data\":{\"reason\":\"no_match\"}}" },
        .{ .json = "{\"ok\":true,\"value\":{\"multiple\":false,\"changed\":true}}" },
    };
    var outcome = try h.run("dom.setInputFiles", "{\"selector\":\"css=#f\",\"paths\":[\"/tmp/a.txt\"]}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"multiple\":false,\"changed\":true}");
    try std.testing.expectEqual(@as(usize, 2), h.fake.files_calls.items.len);
}

test "dom.setInputFiles port errors end the command: BadFile -32602 bad_file (nothing ran), FilesUnconfirmed -32009 once, Unsupported -32011" {
    var bad: Harness = undefined;
    bad.init();
    defer bad.deinit();
    bad.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{}}" }};
    bad.fake.files_error = error.BadFile;
    var bad_outcome = try bad.run("dom.setInputFiles", "{\"selector\":\"css=#f\",\"paths\":[\"relative.txt\"]}");
    defer bad_outcome.deinit(gpa);
    try expectFailureData(bad_outcome, -32602, "Invalid params", "\"reason\":\"bad_file\"");
    try std.testing.expectEqual(@as(usize, 0), bad.fake.eval_calls.items.len);

    var late: Harness = undefined;
    late.init();
    defer late.deinit();
    late.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{}}" }};
    late.fake.files_error = error.FilesUnconfirmed;
    var late_outcome = try late.run("dom.setInputFiles", "{\"selector\":\"css=#f\",\"paths\":[\"/tmp/a.txt\"]}");
    defer late_outcome.deinit(gpa);
    try expectFailureData(late_outcome, -32009, "action_timeout", "\"reason\":\"files_unconfirmed\"");
    try std.testing.expectEqual(@as(usize, 1), late.fake.files_calls.items.len);

    var none: Harness = undefined;
    none.init();
    defer none.deinit();
    none.engine = engine.Engine.init(none.fake.portWithoutMove(), none.clock.clock());
    var none_outcome = try none.run("dom.setInputFiles", "{\"selector\":\"css=#f\",\"paths\":[\"/tmp/a.txt\"]}");
    defer none_outcome.deinit(gpa);
    try expectFailureData(none_outcome, -32011, "session_invalid", "\"reason\":\"unsupported\"");
}

test "synthetic dom.hover runs the hover op; native hover locates (no focus) and moves the real pointer, no click" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{}}" }};
    var synthetic = try h.run("dom.hover", "{\"selector\":\"css=#m\"}");
    defer synthetic.deinit(gpa);
    try expectResult(synthetic, "{}");
    try std.testing.expect(std.mem.indexOf(u8, h.fake.eval_calls.items[0].arg, "\"op\":\"hover\"") != null);
    try std.testing.expectEqual(@as(usize, 0), h.fake.native_calls.items.len);

    var n: Harness = undefined;
    n.init();
    defer n.deinit();
    n.fake.eval_replies = &.{.{ .json = located_reply }};
    var native = try n.run("dom.hover", "{\"selector\":\"css=#m\",\"options\":{\"input\":\"native\"}}");
    defer native.deinit(gpa);
    try expectResult(native, "{\"ok\":true}");
    const arg = n.fake.eval_calls.items[0].arg;
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"op\":\"locate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"action\":\"hover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"focus\":false") != null);
    try std.testing.expectEqual(@as(usize, 1), n.fake.native_calls.items.len);
    const move = n.fake.native_calls.items[0];
    try std.testing.expect(move.kind == .move);
    try std.testing.expectEqual(@as(f64, 10.5), move.x);
    try std.testing.expectEqual(@as(f64, 20), move.y);
    try std.testing.expectEqualStrings("0123456789abcdef", move.document.?);
}

test "humanized native hover: a curved path that ends on the target, and no click" {
    var hh: HumanHarness = undefined;
    hh.init(11);
    defer hh.deinit();
    const h = &hh.h;
    var outcome = try h.run("dom.hover", "{\"selector\":\"css=#m\",\"options\":{\"input\":\"native\",\"humanize\":true}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"ok\":true}");
    var buf: [256]NativeCall = undefined;
    const moves = h.fake.nativeOf(.move, &buf);
    try std.testing.expect(moves.len >= 10);
    try std.testing.expect(dist(moves[moves.len - 1], 500, 400) < 1e-6);
    try std.testing.expectEqual(moves.len, h.fake.native_calls.items.len);
}

test "native hover on a backend without nativeMove: -32011 unsupported, no page work" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.engine = engine.Engine.init(h.fake.portWithoutMove(), h.clock.clock());
    h.fake.eval_replies = &.{.{ .json = located_reply }};
    var outcome = try h.run("dom.hover", "{\"selector\":\"css=#m\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32011, "session_invalid", "\"reason\":\"unsupported\"");
    try std.testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.fake.native_calls.items.len);
}

test "synthetic dom.scroll sends the scroll op with x/y and returns its offsets" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"scrollX\":0,\"scrollY\":300}}" }};
    var outcome = try h.run("dom.scroll", "{\"y\":300}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"scrollX\":0,\"scrollY\":300}");
    const arg = h.fake.eval_calls.items[0].arg;
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"op\":\"scroll\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"x\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"y\":300") != null);
}

/// measure op answer: centre, document, viewport, current offsets.
fn measured(comptime x: []const u8, comptime y: []const u8, comptime doc: []const u8, comptime scroll_y: []const u8) []const u8 {
    return "{\"ok\":true,\"value\":{\"x\":" ++ x ++ ",\"y\":" ++ y ++ ",\"document\":\"" ++ doc ++ "\",\"viewport\":{\"width\":800,\"height\":600},\"scroll\":{\"x\":0,\"y\":" ++ scroll_y ++ "}}}";
}

test "native dom.scroll by offset: measure (no selector, no scrolling), one real wheel at the viewport centre bound to the document, offsets from the port" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = measured("400", "300", "0123456789abcdef", "0") }};
    var outcome = try h.run("dom.scroll", "{\"y\":300.5,\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"scrollX\":0,\"scrollY\":300.5}");
    try std.testing.expectEqual(@as(usize, 1), h.fake.eval_calls.items.len);
    const arg = h.fake.eval_calls.items[0].arg;
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"op\":\"measure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, arg, "\"selector\"") == null);
    try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
    const wheel = h.fake.native_calls.items[0];
    try std.testing.expect(wheel.kind == .scroll);
    try std.testing.expectEqual(@as(f64, 400), wheel.x);
    try std.testing.expectEqual(@as(f64, 300), wheel.y);
    try std.testing.expectEqual(@as(f64, 0), wheel.delta_x);
    try std.testing.expectEqual(@as(f64, 300.5), wheel.delta_y);
    try std.testing.expectEqualStrings("0123456789abcdef", wheel.document.?);
}

test "native dom.scroll to a selector: wheel by (element centre - viewport centre), then a fresh measure confirms it is in view" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{
        .{ .json = measured("400", "1500", "0123456789abcdef", "0") },
        .{ .json = measured("400", "300", "0123456789abcdef", "1200") },
    };
    var outcome = try h.run("dom.scroll", "{\"selector\":\"css=#far\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"scrollX\":0,\"scrollY\":1200}");
    try std.testing.expectEqual(@as(usize, 2), h.fake.eval_calls.items.len);
    for (h.fake.eval_calls.items) |call| {
        try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"op\":\"measure\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, call.arg, "\"selector\":\"css=#far\"") != null);
    }
    try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
    const wheel = h.fake.native_calls.items[0];
    try std.testing.expectEqual(@as(f64, 400), wheel.x);
    try std.testing.expectEqual(@as(f64, 300), wheel.y);
    try std.testing.expectEqual(@as(f64, 1200), wheel.delta_y);
}

test "native dom.scroll to a selector already centred sends no wheel" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = measured("400.4", "300", "0123456789abcdef", "50") }};
    var outcome = try h.run("dom.scroll", "{\"selector\":\"css=#here\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"scrollX\":0,\"scrollY\":50}");
    try std.testing.expectEqual(@as(usize, 0), h.fake.native_calls.items.len);
}

test "native dom.scroll to a selector that never comes into view: three wheels, then -32009 scroll_not_reached" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = measured("400", "5000", "0123456789abcdef", "0") }};
    var outcome = try h.run("dom.scroll", "{\"selector\":\"css=#stuck\",\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32009, "action_timeout", "\"reason\":\"scroll_not_reached\"");
    try std.testing.expectEqual(@as(usize, 3), h.fake.native_calls.items.len);
    try std.testing.expectEqual(@as(usize, 4), h.fake.eval_calls.items.len);
}

test "native dom.scroll: a document change before the first wheel re-measures; after a wheel it is terminal" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{
        .{ .json = measured("400", "300", "0123456789abcdef", "0") },
        .{ .json = measured("400", "300", "fedcba9876543210", "0") },
    };
    h.fake.native_fail_at = 0;
    h.fake.native_error = error.DocumentChanged;
    var outcome = try h.run("dom.scroll", "{\"y\":100,\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"scrollX\":0,\"scrollY\":100}");
    try std.testing.expectEqual(@as(usize, 2), h.fake.native_calls.items.len);
    try std.testing.expectEqualStrings("fedcba9876543210", h.fake.native_calls.items[1].document.?);

    var t: Harness = undefined;
    t.init();
    defer t.deinit();
    t.fake.eval_replies = &.{.{ .json = measured("400", "5000", "0123456789abcdef", "0") }};
    t.fake.native_fail_at = 1;
    t.fake.native_error = error.DocumentChanged;
    var terminal = try t.run("dom.scroll", "{\"selector\":\"css=#far\",\"options\":{\"input\":\"native\"}}");
    defer terminal.deinit(gpa);
    try expectFailureData(terminal, -32001, "element_not_found", "\"reason\":\"document_changed\"");
    try std.testing.expectEqual(@as(usize, 2), t.fake.native_calls.items.len);
}

test "native dom.scroll on a backend without nativeScroll: -32011 unsupported, no page work" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.engine = engine.Engine.init(h.fake.portWithoutMove(), h.clock.clock());
    var outcome = try h.run("dom.scroll", "{\"y\":10,\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32011, "session_invalid", "\"reason\":\"unsupported\"");
    try std.testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
}

test "a malformed measure answer is an internal error and nothing is scrolled" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"x\":1,\"y\":1,\"document\":\"0123456789abcdef\"}}" }};
    var outcome = try h.run("dom.scroll", "{\"y\":10,\"options\":{\"input\":\"native\"}}");
    defer outcome.deinit(gpa);
    try expectFailure(outcome, -32603, "Malformed script result");
    try std.testing.expectEqual(@as(usize, 0), h.fake.native_calls.items.len);
}

test "page.screenshot returns base64 PNG with its size; fullPage reaches the port; TooLarge is -32603 screenshot_too_large" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.screenshot_png = "PNGDATA";
    var outcome = try h.run("page.screenshot", "{\"fullPage\":true}");
    defer outcome.deinit(gpa);
    try expectResult(outcome, "{\"data\":\"UE5HREFUQQ==\",\"width\":800,\"height\":600}");
    try std.testing.expectEqual(@as(?bool, true), h.fake.screenshot_full_page);
    try std.testing.expectEqual(engine.default_timeout_ms, h.fake.last_read_timeout_ms);

    h.fake.screenshot_error = error.TooLarge;
    var big = try h.run("page.screenshot", "{}");
    defer big.deinit(gpa);
    try expectFailureData(big, -32603, "Internal error", "\"reason\":\"screenshot_too_large\"");
}

test "native dom.scroll: a new document after a wheel is terminal even when the next measure finds the target (RoseCat 4749)" {
    // Doc A: target out of view, one wheel; then doc B (same selector)
    // answers in view or out of view: never success, never a second wheel.
    for ([_][]const u8{ measured("400", "300", "fedcba9876543210", "0"), measured("400", "5000", "fedcba9876543210", "0") }) |second| {
        var h: Harness = undefined;
        h.init();
        defer h.deinit();
        h.fake.eval_replies = &.{ .{ .json = measured("400", "5000", "0123456789abcdef", "0") }, .{ .json = second } };
        var outcome = try h.run("dom.scroll", "{\"selector\":\"css=#far\",\"options\":{\"input\":\"native\"}}");
        defer outcome.deinit(gpa);
        try expectFailureData(outcome, -32001, "element_not_found", "\"reason\":\"document_changed\"");
        try std.testing.expectEqual(@as(usize, 1), h.fake.native_calls.items.len);
    }
}

test "page.screenshot that returns at or past the command deadline is a timeout, not a late success" {
    var h: Harness = undefined;
    h.init();
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.screenshot_cost_ms = 1000;
    var outcome = try h.run("page.screenshot", "{\"timeout_ms\":1000}");
    defer outcome.deinit(gpa);
    try expectFailureData(outcome, -32009, "action_timeout", "\"reason\":\"screenshot_deadline\"");
}
