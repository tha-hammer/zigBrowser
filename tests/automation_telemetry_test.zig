//! M11: the engine records exactly one root automation.command span per
//! command, child spans share its trace, and raw values never reach the sink.
const std = @import("std");
const automation = @import("automation");
const fakes = @import("automation/fake_page_port.zig");

const router = automation.router;
const engine = automation.engine;
const telemetry = automation.telemetry;

const gpa = std.testing.allocator;

/// Plan M11 root attributes (session.id_hash is optional and there is no
/// session concept yet; target.* only exist for URL commands).
const required_root_attrs = [_][]const u8{
    "rpc.method",      "rpc.namespace",   "page.id",         "window.id",                 "platform.name", "backend.name",
    "backend.version", "os.name",         "arch",            "app.version",               "git.sha",       "automation.script.version",
    "api.version",     "queue.wait_ms",   "duration_ms",     "timeout_ms",                "retry.count",   "result.status",
    "automation.error", "selector.kind",  "selector.hash",   "selector.strict",           "selector.match_count", "action.name",
    "action.force",    "action.trial",    "input.mode",    "input.humanize",
};

const required_platform_attrs = [_][]const u8{
    "page_port.op", "script.world", "attempt.index", "payload.bytes", "result.bytes", "duration_ms",
    "result.status", "platform.error_class", "timeout_ms", "backend.name", "backend.version", "page.id", "window.id",
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
            .route = .{ .page_id = "page-7", .window_id = "window-3", .telemetry_sink = self.sink.sink() },
            .build = .{ .backend_name = "webkitgtk", .backend_version = "2.52", .app_version = "0.1.0", .git_sha = "abc1234" },
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
    try std.testing.expectEqualStrings("synthetic", root.attr("input.mode").?);
    try std.testing.expectEqualStrings("css", root.attr("selector.kind").?);
    try std.testing.expectEqualStrings("1", root.attr("selector.match_count").?);
    try std.testing.expectEqualStrings("webkitgtk", root.attr("backend.name").?);
    try std.testing.expectEqualStrings("abc1234", root.attr("git.sha").?);
    try std.testing.expect(root.parent_span_id == null);

    for (h.sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.platform.eval")) continue;
        for (required_platform_attrs) |key| {
            if (span.attr(key) == null) {
                std.debug.print("missing platform attr {s}\n", .{key});
                return error.TestMissingAttr;
            }
        }
        try std.testing.expectEqualStrings("page-7", span.attr("page.id").?);
        try std.testing.expectEqualStrings("30000", span.attr("timeout_ms").?);
        try std.testing.expectEqualStrings("", span.attr("platform.error_class").?);
    }
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

test "URL credentials, query and fragment never reach the sink" {
    var h: Harness = undefined;
    h.init(&.{});
    defer h.deinit();

    const urls = [_][]const u8{
        "https://alice:hunter2@example.com/path?token=q1#frag1",
        "https://bob@example.com:8443/a%2Fb?x=y",
        "http://user:pw@[::1]:8080/v6?s=1",
    };
    for (urls) |url| {
        const params = try std.json.Stringify.valueAlloc(gpa, .{ .url = url }, .{});
        defer gpa.free(params);
        var outcome = try h.run("page.navigate", params, 0);
        outcome.deinit(gpa);
    }
    for ([_][]const u8{ "alice", "hunter2", "bob@", "user:pw", "token=q1", "frag1", "x=y", "s=1", "/path", "a%2Fb" }) |needle| {
        if (h.sink.containsRaw(needle)) {
            std.debug.print("leaked: {s}\n", .{needle});
            return error.TestRawValueLeaked;
        }
    }
    var hosts: [3][]const u8 = undefined;
    var i: usize = 0;
    for (h.sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.command")) continue;
        hosts[i] = span.attr("target.host").?;
        i += 1;
    }
    try std.testing.expectEqualStrings("example.com", hosts[0]);
    try std.testing.expectEqualStrings("example.com:8443", hosts[1]);
    try std.testing.expectEqualStrings("[::1]:8080", hosts[2]);
}

test "same origin with and without credentials hashes identically" {
    var h: Harness = undefined;
    h.init(&.{});
    defer h.deinit();

    var a = try h.run("page.navigate", "{\"url\":\"https://u:p@example.com/x\"}", 0);
    a.deinit(gpa);
    var b = try h.run("page.navigate", "{\"url\":\"https://example.com/y\"}", 0);
    b.deinit(gpa);
    var origins: [2][]const u8 = undefined;
    var i: usize = 0;
    for (h.sink.spans.items) |span| {
        if (!std.mem.eql(u8, span.name, "automation.command")) continue;
        origins[i] = span.attr("target.origin_hash").?;
        i += 1;
    }
    try std.testing.expectEqualStrings(origins[0], origins[1]);
}

test "root duration covers queue wait plus execution" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true}}" }});
    defer h.deinit();
    h.fake.clock = &h.clock;
    h.fake.eval_cost_ms = 7;

    var outcome = try h.run("dom.click", "{\"selector\":\"css=#b\"}", 40);
    defer outcome.deinit(gpa);
    const root = try h.root();
    try std.testing.expectEqualStrings("47", root.attr("duration_ms").?);
}

test "selector.kind is a bounded enum, never a raw client prefix" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":false,\"error\":\"element_not_found\",\"retryable\":false,\"data\":{\"reason\":\"malformed_selector\"}}" }});
    defer h.deinit();

    var outcome = try h.run("dom.click", "{\"selector\":\"token_secret=abc\"}", 0);
    defer outcome.deinit(gpa);
    const root = try h.root();
    try std.testing.expectEqualStrings("invalid", root.attr("selector.kind").?);
    try std.testing.expect(!h.sink.containsRaw("token_secret"));
}

/// Records the JSON of every value that crosses the TelemetrySink vtable, so
/// redaction is checked at the boundary rather than inside one sink.
const SpySink = struct {
    seen: std.ArrayListUnmanaged(u8) = .empty,

    fn sink(self: *SpySink) telemetry.TelemetrySink {
        return .{ .ptr = self, .vtable = &.{ .recordCommandSpan = recordCommand, .recordChildSpan = recordChild } };
    }

    fn recordCommand(ptr: *anyopaque, attrs: telemetry.CommandSpanAttrs) anyerror!void {
        const self: *SpySink = @ptrCast(@alignCast(ptr));
        const json = try std.json.Stringify.valueAlloc(gpa, attrs, .{});
        defer gpa.free(json);
        try self.seen.appendSlice(gpa, json);
    }

    fn recordChild(ptr: *anyopaque, span: telemetry.ChildSpan) anyerror!void {
        const self: *SpySink = @ptrCast(@alignCast(ptr));
        const json = try std.json.Stringify.valueAlloc(gpa, span, .{});
        defer gpa.free(json);
        try self.seen.appendSlice(gpa, json);
    }
};

test "nothing raw crosses the TelemetrySink boundary (spy sink)" {
    var fake = fakes.FakePagePort.init(gpa);
    defer fake.deinit();
    fake.eval_replies = &.{.{ .json = "{\"ok\":true,\"value\":{\"ok\":true},\"telemetry\":[{\"name\":\"automation.selector.resolve\",\"attributes\":{\"selector.hash\":\"h\",\"raw\":\"css=#password-field\"}}]}" }};
    var clock = fakes.FakeClock.init(gpa);
    defer clock.deinit();
    var spy: SpySink = .{};
    defer spy.seen.deinit(gpa);
    var eng = engine.Engine.init(fake.port(), clock.clock());

    const commands = [_][2][]const u8{
        .{ "dom.fill", "{\"selector\":\"css=#password-field\",\"value\":\"password=abc\"}" },
        .{ "dom.type", "{\"selector\":\"text=token_xyz\",\"text\":\"hunter2\"}" },
        .{ "page.navigate", "{\"url\":\"https://alice:pw@example.com/reset?token=s3cret#frag\"}" },
        .{ "page.evaluate", "{\"expression\":\"document.cookie\"}" },
    };
    for (commands) |c| {
        var command = try router.parse(gpa, c[0], c[1], .{});
        defer command.deinit();
        var outcome = try eng.executeWith(gpa, &command, .{ .route = .{ .telemetry_sink = spy.sink() } });
        outcome.deinit(gpa);
    }
    try std.testing.expect(spy.seen.items.len > 0);
    for ([_][]const u8{ "#password-field", "password=abc", "token_xyz", "hunter2", "alice", ":pw@", "/reset", "s3cret", "frag", "document.cookie" }) |needle| {
        if (std.mem.indexOf(u8, spy.seen.items, needle) != null) {
            std.debug.print("raw value crossed the sink boundary: {s}\n", .{needle});
            return error.TestRawValueLeaked;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, spy.seen.items, "\"target_host\":\"example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spy.seen.items, "\"typed_class\":\"secret-like\"") != null);
}

// ---- RecentTraceStore (telemetry.query backing store) ----

fn rootAttrs(trace_id: []const u8, span_id: []const u8) telemetry.CommandSpanAttrs {
    return .{
        .trace_id = trace_id,
        .span_id = span_id,
        .command_id = "cmd-1",
        .method = "dom.click",
        .namespace = "dom",
        .page_id = "page-1",
        .window_id = "window-1",
        .timeout_ms = 30000,
        .queue_wait_ms = 0,
        .duration_ms = 42,
        .retry_count = 0,
        .result_status = "error",
        .automation_error = "element_disabled",
    };
}

test "RecentTraceStore returns a trace's spans, root first, in the CLI shape" {
    var store = telemetry.RecentTraceStore.init(gpa, 4);
    defer store.deinit();
    const sink = store.sink();
    try sink.recordChildSpan(.{ .name = "automation.platform.eval", .trace_id = "t1", .span_id = "c1", .parent_span_id = "r1", .command_id = "cmd-1", .attributes = &.{.{ .key = "duration_ms", .value = "7" }} });
    try sink.recordCommandSpan(rootAttrs("t1", "r1"));

    const json = (try store.queryJson(gpa, "t1"));
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const spans = parsed.value.object.get("spans").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), spans.len);
    try std.testing.expectEqualStrings("automation.command", spans[0].object.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 42), spans[0].object.get("duration_ms").?.integer);
    try std.testing.expectEqualStrings("dom.click", spans[0].object.get("attributes").?.object.get("rpc.method").?.string);
    try std.testing.expectEqualStrings("element_disabled", spans[0].object.get("attributes").?.object.get("automation.error").?.string);
    try std.testing.expectEqualStrings("automation.platform.eval", spans[1].object.get("name").?.string);
    try std.testing.expectEqualStrings("r1", spans[1].object.get("parent_span_id").?.string);
    try std.testing.expectEqual(@as(i64, 7), spans[1].object.get("duration_ms").?.integer);
}

test "RecentTraceStore: unknown trace is empty; oldest traces are evicted at capacity" {
    var store = telemetry.RecentTraceStore.init(gpa, 2);
    defer store.deinit();
    const sink = store.sink();
    try sink.recordCommandSpan(rootAttrs("a", "ra"));
    try sink.recordCommandSpan(rootAttrs("b", "rb"));
    try sink.recordCommandSpan(rootAttrs("c", "rc"));

    for ([_][]const u8{ "a", "zzz" }) |missing| {
        const json = try store.queryJson(gpa, missing);
        defer gpa.free(json);
        try std.testing.expectEqualStrings("{\"spans\":[]}", json);
    }
    const kept = try store.queryJson(gpa, "c");
    defer gpa.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"trace_id\":\"c\"") != null);
}

test "RecentTraceStore caps spans per trace" {
    var store = telemetry.RecentTraceStore.init(gpa, 2);
    defer store.deinit();
    const sink = store.sink();
    for (0..telemetry.RecentTraceStore.max_spans_per_trace + 10) |_| {
        try sink.recordChildSpan(.{ .name = "automation.platform.eval", .trace_id = "t", .parent_span_id = "r", .command_id = "c", .attributes = &.{} });
    }
    const json = try store.queryJson(gpa, "t");
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(telemetry.RecentTraceStore.max_spans_per_trace, parsed.value.object.get("spans").?.array.items.len);
}

test "RecentTraceStore keeps a late root even after the child cap is reached" {
    var store = telemetry.RecentTraceStore.init(gpa, 2);
    defer store.deinit();
    const sink = store.sink();
    for (0..telemetry.RecentTraceStore.max_spans_per_trace + 6) |_| {
        try sink.recordChildSpan(.{ .name = "automation.platform.eval", .trace_id = "t", .parent_span_id = "r", .command_id = "c", .attributes = &.{} });
    }
    try sink.recordCommandSpan(rootAttrs("t", "r"));
    const json = try store.queryJson(gpa, "t");
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const spans = parsed.value.object.get("spans").?.array.items;
    try std.testing.expectEqual(telemetry.RecentTraceStore.max_spans_per_trace, spans.len);
    try std.testing.expectEqualStrings("automation.command", spans[0].object.get("name").?.string);
}

test "RecentTraceStore keeps a late social compound span (pinned after the root) past the child cap" {
    var store = telemetry.RecentTraceStore.init(gpa, 2);
    defer store.deinit();
    const sink = store.sink();
    for (0..telemetry.RecentTraceStore.max_spans_per_trace + 6) |_| {
        try sink.recordChildSpan(.{ .name = "automation.social.action", .trace_id = "t", .parent_span_id = "k", .command_id = "c", .attributes = &.{} });
    }
    try sink.recordChildSpan(.{ .name = "automation.social.compound", .trace_id = "t", .span_id = "k", .parent_span_id = "r", .command_id = "c", .attributes = &.{} });
    try sink.recordCommandSpan(rootAttrs("t", "r"));
    const json = try store.queryJson(gpa, "t");
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    const spans = parsed.value.object.get("spans").?.array.items;
    try std.testing.expectEqual(telemetry.RecentTraceStore.max_spans_per_trace, spans.len);
    try std.testing.expectEqualStrings("automation.command", spans[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("automation.social.compound", spans[1].object.get("name").?.string);
    // More children after both: still capped, root and compound stay.
    try sink.recordChildSpan(.{ .name = "automation.social.action", .trace_id = "t", .parent_span_id = "k", .command_id = "c", .attributes = &.{} });
    const again = try store.queryJson(gpa, "t");
    defer gpa.free(again);
    try std.testing.expect(std.mem.indexOf(u8, again, "automation.social.compound") != null);
}

test "native input is visible on the root span as input.mode=native" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":true,\"value\":{\"x\":1,\"y\":2,\"document\":\"0123456789abcdef\"}}" }});
    defer h.deinit();
    var outcome = try h.run("dom.click", "{\"selector\":\"css=#go\",\"options\":{\"input\":\"native\"}}", 0);
    defer outcome.deinit(gpa);
    const root = try h.root();
    try std.testing.expectEqualStrings("native", root.attr("input.mode").?);
    try std.testing.expectEqualStrings("false", root.attr("input.humanize").?);
    var saw_native_span = false;
    for (h.sink.spans.items) |span| {
        const op = span.attr("page_port.op") orelse continue;
        if (std.mem.eql(u8, op, "nativeClick")) saw_native_span = true;
    }
    try std.testing.expect(saw_native_span);
}

test "a humanized command records input.humanize=true, also when rejected before dispatch" {
    var h: Harness = undefined;
    h.init(&.{.{ .json = "{\"ok\":true,\"value\":{\"x\":500,\"y\":400,\"document\":\"0123456789abcdef\",\"viewport\":{\"width\":1000,\"height\":800}}}" }});
    defer h.deinit();
    var outcome = try h.run("dom.type", "{\"selector\":\"css=#q\",\"text\":\"hello\",\"options\":{\"input\":\"native\",\"humanize\":true,\"timeout_ms\":100}}", 0);
    defer outcome.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, outcome.failure.data_json.?, "humanize_budget") != null);
    const root = try h.root();
    try std.testing.expectEqualStrings("true", root.attr("input.humanize").?);
    try std.testing.expectEqualStrings("native", root.attr("input.mode").?);
    try std.testing.expectEqualStrings("error", root.attr("result.status").?);
}
