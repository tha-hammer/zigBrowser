//! M11: the engine records exactly one root automation.command span per
//! command, child spans share its trace, and raw values never reach the sink.
const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const router = automation.router;
const engine = automation.engine;
const telemetry = automation.telemetry;

const gpa = std.testing.allocator;

const required_root_attrs = [_][]const u8{
    "rpc.method",  "rpc.namespace", "page.id",     "window.id",     "os.name",       "arch",
    "timeout_ms",  "queue.wait_ms", "duration_ms", "retry.count",   "result.status", "automation.error",
};

const Harness = struct {
    fake: fakes.FakePagePort,
    clock: fakes.FakeClock,
    sink: telemetry.InMemoryTelemetrySink,
    engine: engine.Engine,

    fn init(self: *Harness, replies: []const fakes.EvalReply) void {
        self.fake = fakes.FakePagePort.init(gpa);
        self.fake.eval_replies = replies;
        self.clock = fakes.FakeClock.init(gpa);
        self.sink = telemetry.InMemoryTelemetrySink.init(gpa);
        self.engine = engine.Engine.init(self.fake.port(), self.clock.clock());
    }

    fn deinit(self: *Harness) void {
        self.sink.deinit();
        self.fake.deinit();
        self.clock.deinit();
    }

    fn run(self: *Harness, method: []const u8, params: []const u8, queue_wait_ms: u64) !engine.Outcome {
        var command = try router.parse(gpa, method, params, .{});
        defer command.deinit();
        return self.engine.executeWith(gpa, &command, .{
            .queue_wait_ms = queue_wait_ms,
            .route = .{ .page_id = "page-7", .window_id = "window-3", .telemetry_sink = &self.sink },
        });
    }

    fn roots(self: *Harness) []const telemetry.Span {
        return self.sink.spans.items;
    }

    fn root(self: *Harness) !*const telemetry.Span {
        var found: ?*const telemetry.Span = null;
        for (self.sink.spans.items) |*span| {
            if (std.mem.eql(u8, span.name, "automation.command")) {
                if (found != null) return error.TestMoreThanOneRoot;
                found = span;
            }
        }
        return found orelse error.TestNoRoot;
    }
};

const click_ok = fakes.EvalReply{ .json =
    \\{"ok":true,"value":{"ok":true},"telemetry":[
    \\{"name":"automation.selector.resolve","trace_id":"page-made-up","span_id":"script-span-1","parent_span_id":"x","command_id":"y",
    \\ "attributes":{"selector.kind":"css","selector.hash":"abc123","selector.match_count":"1","attempt.index":"0","duration_ms":3,"raw.selector":"css=#secret-id"}},
    \\{"name":"automation.actionability.check","span_id":"script-span-2","attributes":{"action.name":"click","actionability.passed":"true","attempt.index":"0"}},
    \\{"name":"evil.span","span_id":"script-span-3","attributes":{"x":"y"}}]}
};

test "exactly one root span per command with the required attributes" {
    var h: Harness = undefined;
    h.init(&.{click_ok});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#go\"}", 0);
    defer outcome.deinit(gpa);
    const root = try h.root();
    for (required_root_attrs) |key| {
        if (root.attr(key) == null) {
            std.debug.print("missing root attr {s}\n", .{key});
            return error.TestMissingAttr;
        }
    }
    try std.testing.expectEqualStrings("dom.click", root.attr("rpc.method").?);
    try std.testing.expectEqualStrings("dom", root.attr("rpc.namespace").?);
    try std.testing.expectEqualStrings("page-7", root.attr("page.id").?);
    try std.testing.expectEqualStrings("window-3", root.attr("window.id").?);
    try std.testing.expectEqualStrings("0", root.attr("queue.wait_ms").?);
    try std.testing.expectEqualStrings("ok", root.attr("result.status").?);
    try std.testing.expectEqualStrings("", root.attr("automation.error").?);
    try std.testing.expectEqualStrings("0", root.attr("retry.count").?);
    try std.testing.expectEqualStrings("30000", root.attr("timeout_ms").?);
    try std.testing.expectEqualStrings("click", root.attr("action.name").?);
    try std.testing.expectEqualStrings("css", root.attr("selector.kind").?);
    try std.testing.expect(root.parent_span_id == null);
}

test "root span ids are the ids sent to the script; children hang off the root" {
    var h: Harness = undefined;
    h.init(&.{click_ok});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#go\"}", 0);
    defer outcome.deinit(gpa);
    const root = try h.root();

    const arg = try std.json.parseFromSlice(std.json.Value, gpa, h.fake.eval_calls.items[0].arg, .{});
    defer arg.deinit();
    try std.testing.expectEqualStrings(arg.value.object.get("trace_id").?.string, root.trace_id);
    try std.testing.expectEqualStrings(arg.value.object.get("parent_span_id").?.string, root.span_id);
    try std.testing.expectEqualStrings(arg.value.object.get("command_id").?.string, root.command_id);

    var children: usize = 0;
    for (h.sink.spans.items) |span| {
        if (span.parent_span_id == null) continue;
        children += 1;
        try std.testing.expectEqualStrings(root.trace_id, span.trace_id);
        try std.testing.expectEqualStrings(root.span_id, span.parent_span_id.?);
        try std.testing.expectEqualStrings(root.command_id, span.command_id);
    }
    // selector.resolve + actionability.check (script) + platform.eval (engine);
    // the unknown "evil.span" is dropped.
    try std.testing.expectEqual(@as(usize, 3), children);
    try std.testing.expectEqual(@as(usize, 1), h.sink.countSpans("automation.selector.resolve", root.command_id));
    try std.testing.expectEqual(@as(usize, 1), h.sink.countSpans("automation.actionability.check", root.command_id));
    try std.testing.expectEqual(@as(usize, 1), h.sink.countSpans("automation.platform.eval", root.command_id));
    try std.testing.expect(!h.sink.containsRaw("evil.span"));
}

test "script child attributes are allowlisted; numbers are stringified" {
    var h: Harness = undefined;
    h.init(&.{click_ok});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#go\"}", 0);
    defer outcome.deinit(gpa);
    try std.testing.expect(!h.sink.containsRaw("raw.selector"));
    try std.testing.expect(!h.sink.containsRaw("css=#secret-id"));
    for (h.sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.selector.resolve")) continue;
        try std.testing.expectEqualStrings("3", span.attr("duration_ms").?);
        try std.testing.expectEqualStrings("abc123", span.attr("selector.hash").?);
    }
}

test "platform.eval child span per attempt records sizes, world and attempt index" {
    var h: Harness = undefined;
    h.init(&.{
        .{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":true,\"data\":{\"reason\":\"strict_zero\"}}" },
        .{ .json = "{\"ok\":true,\"value\":{\"text\":\"Ready\"}}" },
    });
    defer h.deinit();

    var outcome = try h.run("dom.getText", "{\"selector\":\"css=#s\"}", 0);
    defer outcome.deinit(gpa);
    const root = try h.root();
    try std.testing.expectEqualStrings("1", root.attr("retry.count").?);
    try std.testing.expectEqual(@as(usize, 2), h.sink.countSpans("automation.platform.eval", root.command_id));

    var index: usize = 0;
    for (h.sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.platform.eval")) continue;
        const expected = try std.fmt.allocPrint(gpa, "{d}", .{index});
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, span.attr("attempt.index").?);
        try std.testing.expectEqualStrings("automation", span.attr("script.world").?);
        try std.testing.expectEqualStrings("evalJson", span.attr("page_port.op").?);
        try std.testing.expect(span.attr("payload.bytes") != null);
        try std.testing.expect(span.attr("result.bytes") != null);
        try std.testing.expect(span.attr("duration_ms") != null);
        index += 1;
    }
}

test "failure root span records error status and automation.error" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":false,\"error\":\"element_disabled\",\"retryable\":false,\"data\":{\"reason\":\"enabled\"}}" }});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\"}", 0);
    defer outcome.deinit(gpa);
    const root = try h.root();
    try std.testing.expectEqualStrings("error", root.attr("result.status").?);
    try std.testing.expectEqualStrings("element_disabled", root.attr("automation.error").?);
    const data = try std.json.parseFromSlice(std.json.Value, gpa, outcome.failure.data_json.?, .{});
    defer data.deinit();
    try std.testing.expectEqualStrings(data.value.object.get("trace_id").?.string, root.trace_id);
}

test "internal failures are recorded as status error with an empty automation.error" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "garbage" }});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\"}", 0);
    defer outcome.deinit(gpa);
    const root = try h.root();
    try std.testing.expectEqualStrings("error", root.attr("result.status").?);
}

test "queue.wait_ms is recorded and counts against the command deadline" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"timeout_ms\":1000}}", 250);
    defer outcome.deinit(gpa);
    const root = try h.root();
    try std.testing.expectEqualStrings("250", root.attr("queue.wait_ms").?);
    try std.testing.expectEqual(@as(u64, 750), h.fake.eval_calls.items[0].timeout_ms);
}

test "a command whose whole deadline was spent queued fails without touching the page" {
    var h: Harness = undefined;
    h.init(&.{});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\",\"options\":{\"timeout_ms\":100}}", 150);
    defer outcome.deinit(gpa);
    try std.testing.expectEqual(@as(i64, -32009), outcome.failure.code);
    try std.testing.expectEqual(@as(usize, 0), h.fake.eval_calls.items.len);
    const root = try h.root();
    try std.testing.expectEqualStrings("action_timeout", root.attr("automation.error").?);
}

test "typed values, selectors and full URLs are never stored raw" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }});
    defer h.deinit();

    var fill = try h.run("dom.fill", "{\"selector\":\"css=#password-field\",\"value\":\"password=abc token=xyz\"}", 0);
    defer fill.deinit(gpa);
    var nav = try h.run("page.navigate", "{\"url\":\"https://example.com/account/reset?token=s3cret#frag\"}", 0);
    defer nav.deinit(gpa);

    for ([_][]const u8{ "password=abc", "token=xyz", "css=#password-field", "s3cret", "/account/reset", "?token" }) |needle| {
        if (h.sink.containsRaw(needle)) {
            std.debug.print("raw value leaked: {s}\n", .{needle});
            return error.TestRawValueLeaked;
        }
    }
    var saw_host = false;
    for (h.sink.spans.items) |span| {
        if (span.attr("target.host")) |host| saw_host = saw_host or std.mem.eql(u8, host, "example.com");
        if (span.attr("typed.class")) |class| try std.testing.expectEqualStrings("secret-like", class);
    }
    try std.testing.expect(saw_host);
}

test "page.evaluate records one root and one platform.eval span in the page world" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":true,\"value\":42}" }});
    defer h.deinit();

    var outcome = try h.run("page.evaluate", "{\"expression\":\"document.cookie\"}", 0);
    defer outcome.deinit(gpa);
    const root = try h.root();
    try std.testing.expectEqual(@as(usize, 1), h.sink.countSpans("automation.platform.eval", root.command_id));
    try std.testing.expect(!h.sink.containsRaw("document.cookie"));
    for (h.sink.spans.items) |span| {
        if (std.mem.eql(u8, span.name, "automation.platform.eval")) try std.testing.expectEqualStrings("page", span.attr("script.world").?);
    }
}

test "no sink configured records nothing and still works" {
    var fake = fakes.FakePagePort.init(gpa);
    defer fake.deinit();
    fake.current_url = "about:blank";
    var clock = fakes.FakeClock.init(gpa);
    defer clock.deinit();
    var eng = engine.Engine.init(fake.port(), clock.clock());
    var command = try router.parse(gpa, "page.url", "{}", .{});
    defer command.deinit();
    var outcome = try eng.executeWith(gpa, &command, .{});
    defer outcome.deinit(gpa);
    try std.testing.expectEqualStrings("{\"url\":\"about:blank\"}", outcome.result);
}
