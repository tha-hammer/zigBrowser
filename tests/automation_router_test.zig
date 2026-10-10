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

test "router.parse never records telemetry; the engine owns the root span" {
    var sink = telemetry.InMemoryTelemetrySink.init(std.testing.allocator);
    defer sink.deinit();

    var fill = try router.parse(std.testing.allocator, "dom.fill",
        "{\"selector\":\"css=#password\",\"value\":\"password=abc\"}",
        .{
            .page_id = "page-123",
            .window_id = "window-456",
            .telemetry_sink = sink.sink(),
        },
    );
    defer fill.deinit();

    try std.testing.expectEqual(@as(usize, 0), sink.spanCount());
    // Redaction of these same params is covered through the engine in
    // tests/automation_telemetry_test.zig.
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

test "embedded NUL in url or expression is BadArgs (they reach C strings)" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.BadArgs, router.parse(allocator, "page.navigate", "{\"url\":\"http://a/\\u0000evil\"}", .{}));
    try std.testing.expectError(error.BadArgs, router.parse(allocator, "page.evaluate", "{\"expression\":\"1\\u0000+2\"}", .{}));
    var ok = try router.parse(allocator, "page.navigate", "{\"url\":\"http://a/\"}", .{});
    ok.deinit();
}

test "dom.press: key required, selector optional, modifiers validated" {
    const allocator = std.testing.allocator;
    var focused = try router.parse(allocator, "dom.press", "{\"key\":\"Enter\"}", .{});
    defer focused.deinit();
    try std.testing.expectEqual(router.Verb.dom_press, focused.verb);
    try std.testing.expect(focused.selector == null);
    try std.testing.expectEqualStrings("Enter", focused.key.?);
    try std.testing.expectEqual(@as(usize, 0), focused.modifiers.len);

    var chord = try router.parse(allocator, "dom.press", "{\"selector\":\"css=#q\",\"key\":\"a\",\"modifiers\":[\"Control\",\"Shift\"],\"timeout_ms\":500}", .{});
    defer chord.deinit();
    try std.testing.expectEqualStrings("css=#q", chord.selector.?);
    try std.testing.expectEqual(@as(usize, 2), chord.modifiers.len);
    try std.testing.expectEqualStrings("Shift", chord.modifiers[1]);
    try std.testing.expectEqual(@as(?u64, 500), chord.timeout_ms);

    for ([_][]const u8{
        "{}",
        "{\"key\":\"\"}",
        "{\"key\":1}",
        "{\"key\":\"a\",\"modifiers\":[\"Hyper\"]}",
        "{\"key\":\"a\",\"modifiers\":\"Shift\"}",
        "{\"key\":\"a\",\"modifiers\":[\"Shift\",\"Shift\"]}",
    }) |params| {
        try std.testing.expectError(error.BadArgs, router.parse(allocator, "dom.press", params, .{}));
    }
}

test "dom.selectOption: selector plus exactly one of value/label/index" {
    const allocator = std.testing.allocator;
    var by_value = try router.parse(allocator, "dom.selectOption", "{\"selector\":\"css=#c\",\"value\":\"fr\"}", .{});
    defer by_value.deinit();
    try std.testing.expectEqual(router.Verb.dom_select_option, by_value.verb);
    try std.testing.expectEqualStrings("fr", by_value.value.?);

    var by_label = try router.parse(allocator, "dom.selectOption", "{\"selector\":\"css=#c\",\"label\":\"France\",\"timeout_ms\":250}", .{});
    defer by_label.deinit();
    try std.testing.expectEqualStrings("France", by_label.label.?);
    try std.testing.expectEqual(@as(?u64, 250), by_label.timeout_ms);

    var by_index = try router.parse(allocator, "dom.selectOption", "{\"selector\":\"css=#c\",\"index\":2}", .{});
    defer by_index.deinit();
    try std.testing.expectEqual(@as(?u64, 2), by_index.option_index);

    for ([_][]const u8{
        "{\"value\":\"fr\"}",
        "{\"selector\":\"css=#c\"}",
        "{\"selector\":\"css=#c\",\"value\":\"fr\",\"label\":\"France\"}",
        "{\"selector\":\"css=#c\",\"value\":\"fr\",\"index\":1}",
        "{\"selector\":\"css=#c\",\"index\":-1}",
        "{\"selector\":\"css=#c\",\"value\":3}",
    }) |params| {
        try std.testing.expectError(error.BadArgs, router.parse(allocator, "dom.selectOption", params, .{}));
    }
}
