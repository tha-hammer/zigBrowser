const std = @import("std");
const automation = @import("automation");

const router = automation.router;
const telemetry = automation.telemetry;

test "router accepts every Phase 1 command verb" {
    const cases = [_]struct {
        method: []const u8,
        params: []const u8,
        namespace: router.Namespace,
        verb: router.Verb,
    }{
        .{ .method = "dom.query", .params = "{\"selector\":\"text=Ready\"}", .namespace = .dom, .verb = .dom_query },
        .{ .method = "dom.click", .params = "{\"selector\":\"role=button[name=Save]\"}", .namespace = .dom, .verb = .dom_click },
        .{ .method = "dom.fill", .params = "{\"selector\":\"css=input\",\"value\":\"hello\"}", .namespace = .dom, .verb = .dom_fill },
        .{ .method = "dom.type", .params = "{\"selector\":\"css=input\",\"text\":\"hello\"}", .namespace = .dom, .verb = .dom_type },
        .{ .method = "dom.getText", .params = "{\"selector\":\"testid=message\"}", .namespace = .dom, .verb = .dom_get_text },
        .{ .method = "dom.getAttribute", .params = "{\"selector\":\"css=a\",\"name\":\"href\"}", .namespace = .dom, .verb = .dom_get_attribute },
        .{ .method = "dom.waitFor", .params = "{\"selector\":\"text=Ready\"}", .namespace = .dom, .verb = .dom_wait_for },
        .{ .method = "page.navigate", .params = "{\"url\":\"https://example.test/path\"}", .namespace = .page, .verb = .page_navigate },
        .{ .method = "page.reload", .params = "{}", .namespace = .page, .verb = .page_reload },
        .{ .method = "page.url", .params = "{}", .namespace = .page, .verb = .page_url },
        .{ .method = "page.title", .params = "{}", .namespace = .page, .verb = .page_title },
        .{ .method = "page.evaluate", .params = "{\"expression\":\"1 + 1\"}", .namespace = .page, .verb = .page_evaluate },
        .{ .method = "page.screenshot", .params = "{}", .namespace = .page, .verb = .page_screenshot },
    };

    for (cases) |case| {
        var command = try router.parse(std.testing.allocator, case.method, case.params, .{
            .page_id = "page-router-table",
            .window_id = "window-router-table",
        });
        defer command.deinit();

        try std.testing.expectEqual(case.namespace, command.namespace);
        try std.testing.expectEqual(case.verb, command.verb);
        try std.testing.expectEqualStrings(case.method, command.method);
    }
}

test "router rejects unknown methods, invalid params, and non-Phase 1 namespaces" {
    const invalid = [_]struct {
        method: []const u8,
        params: []const u8,
        expected: anyerror,
    }{
        .{ .method = "dom.nope", .params = "{}", .expected = error.UnknownCommand },
        .{ .method = "page.nope", .params = "{}", .expected = error.UnknownCommand },
        .{ .method = "cookies.get", .params = "{}", .expected = error.UnknownCommand },
        .{ .method = "session.create", .params = "{}", .expected = error.UnknownCommand },
        .{ .method = "social.post", .params = "{}", .expected = error.UnknownCommand },
        .{ .method = "linkedin.connect", .params = "{}", .expected = error.UnknownCommand },
        .{ .method = "instagram.follow", .params = "{}", .expected = error.UnknownCommand },
        .{ .method = "dom.query", .params = "{}", .expected = error.BadArgs },
        .{ .method = "dom.fill", .params = "{\"selector\":\"css=input\"}", .expected = error.BadArgs },
        .{ .method = "dom.getAttribute", .params = "{\"selector\":\"css=a\"}", .expected = error.BadArgs },
        .{ .method = "page.navigate", .params = "{\"url\":42}", .expected = error.BadArgs },
        .{ .method = "page.evaluate", .params = "{\"expression\":false}", .expected = error.BadArgs },
        .{ .method = "page.url", .params = "{\"extra\":true}", .expected = error.BadArgs },
    };

    for (invalid) |case| {
        try std.testing.expectError(case.expected, router.parse(std.testing.allocator, case.method, case.params, .{}));
    }
}

test "router applies omitted optional params and strict selector defaults" {
    var query = try router.parse(std.testing.allocator, "dom.query", "{\"selector\":\"text=Ready\"}", .{});
    defer query.deinit();
    try std.testing.expectEqual(@as(?u64, null), query.timeout_ms);
    try std.testing.expectEqual(false, query.strict);

    var click = try router.parse(std.testing.allocator, "dom.click", "{\"selector\":\"text=Ready\"}", .{});
    defer click.deinit();
    try std.testing.expectEqual(true, click.strict);
    try std.testing.expectEqual(false, click.force);
    try std.testing.expectEqual(false, click.trial);

    var wait = try router.parse(std.testing.allocator, "dom.waitFor", "{\"selector\":\"text=Ready\"}", .{});
    defer wait.deinit();
    try std.testing.expectEqual(router.WaitState.visible, wait.wait_state);

    var screenshot = try router.parse(std.testing.allocator, "page.screenshot", "{}", .{});
    defer screenshot.deinit();
    try std.testing.expectEqual(false, screenshot.full_page);
}

test "router records root telemetry context without raw params" {
    var sink = telemetry.InMemoryTelemetrySink.init(std.testing.allocator);
    defer sink.deinit();

    var fill = try router.parse(std.testing.allocator, "dom.fill",
        "{\"selector\":\"css=#password\",\"value\":\"password=abc\"}",
        .{
            .page_id = "page-123",
            .window_id = "window-456",
            .telemetry_sink = &sink,
        },
    );
    defer fill.deinit();

    var nav = try router.parse(std.testing.allocator, "page.navigate",
        "{\"url\":\"https://example.test/inbox?token=xyz\",\"timeout_ms\":1000}",
        .{
            .page_id = "page-123",
            .window_id = "window-456",
            .telemetry_sink = &sink,
        },
    );
    defer nav.deinit();

    try std.testing.expectEqual(@as(usize, 2), sink.spanCount());

    const fill_span = sink.spanAt(0);
    try std.testing.expectEqualStrings("automation.command", fill_span.name);
    try std.testing.expect(fill_span.trace_id.len > 0);
    try std.testing.expect(fill_span.command_id.len > 0);
    try std.testing.expectEqualStrings("dom.fill", fill_span.attr("rpc.method").?);
    try std.testing.expectEqualStrings("dom", fill_span.attr("rpc.namespace").?);
    try std.testing.expectEqualStrings("page-123", fill_span.attr("page.id").?);
    try std.testing.expect(fill_span.attr("selector.hash") != null);
    try std.testing.expectEqualStrings("12", fill_span.attr("typed.length").?);
    try std.testing.expectEqualStrings("secret-like", fill_span.attr("typed.class").?);

    const nav_span = sink.spanAt(1);
    try std.testing.expectEqualStrings("page.navigate", nav_span.attr("rpc.method").?);
    try std.testing.expectEqualStrings("page", nav_span.attr("rpc.namespace").?);
    try std.testing.expectEqualStrings("example.test", nav_span.attr("target.host").?);
    try std.testing.expect(nav_span.attr("target.origin_hash") != null);
    try std.testing.expect(nav_span.attr("target.path_hash") != null);

    try std.testing.expect(!sink.containsRaw("css=#password"));
    try std.testing.expect(!sink.containsRaw("password=abc"));
    try std.testing.expect(!sink.containsRaw("token=xyz"));
    try std.testing.expect(!sink.containsRaw("https://example.test/inbox?token=xyz"));
}

test "getText and getAttribute accept timeout_ms at top level or in options" {
    const allocator = std.testing.allocator;
    var top = try automation.router.parse(allocator, "dom.getText", "{\"selector\":\"css=#a\",\"timeout_ms\":250}", .{});
    defer top.deinit();
    try std.testing.expectEqual(@as(?u64, 250), top.timeout_ms);

    var nested = try automation.router.parse(allocator, "dom.getAttribute", "{\"selector\":\"css=a\",\"name\":\"href\",\"options\":{\"timeout_ms\":75}}", .{});
    defer nested.deinit();
    try std.testing.expectEqual(@as(?u64, 75), nested.timeout_ms);

    try std.testing.expectError(error.BadArgs, automation.router.parse(allocator, "dom.getText", "{\"selector\":\"css=#a\",\"timeout_ms\":-1}", .{}));
}
