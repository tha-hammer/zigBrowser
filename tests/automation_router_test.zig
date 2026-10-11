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

test "options.input: synthetic by default, native for click/type/press only, anything else BadArgs" {
    const allocator = std.testing.allocator;
    var plain = try router.parse(allocator, "dom.click", "{\"selector\":\"css=#b\"}", .{});
    defer plain.deinit();
    try std.testing.expectEqual(router.InputMode.synthetic, plain.input);
    try std.testing.expect(plain.locate == null);

    for ([_]struct { method: []const u8, params: []const u8 }{
        .{ .method = "dom.click", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "dom.type", .params = "{\"selector\":\"css=#q\",\"text\":\"hi\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "dom.press", .params = "{\"key\":\"Enter\",\"options\":{\"input\":\"native\"}}" },
    }) |case| {
        var command = try router.parse(allocator, case.method, case.params, .{});
        defer command.deinit();
        try std.testing.expectEqual(router.InputMode.native, command.input);
    }
    var synthetic = try router.parse(allocator, "dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"synthetic\"}}", .{});
    defer synthetic.deinit();
    try std.testing.expectEqual(router.InputMode.synthetic, synthetic.input);

    for ([_]struct { method: []const u8, params: []const u8 }{
        .{ .method = "dom.click", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"trusted\"}}" },
        .{ .method = "dom.click", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":true}}" },
        .{ .method = "dom.click", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"Native\"}}" },
        .{ .method = "dom.fill", .params = "{\"selector\":\"css=#q\",\"value\":\"x\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "dom.selectOption", .params = "{\"selector\":\"css=#s\",\"value\":\"a\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "dom.press", .params = "{\"key\":\"Enter\",\"options\":{\"input\":\"x\"}}" },
    }) |case| {
        try std.testing.expectError(error.BadArgs, router.parse(allocator, case.method, case.params, .{}));
    }
}

test "native dom.press accepts exactly the shim's key names or one code point" {
    const allocator = std.testing.allocator;
    for (router.native_key_names) |name| try std.testing.expect(router.isNativeKey(name));
    for ([_][]const u8{ "a", "Z", "1", " ", "\n", "é", "✓", "😀" }) |key| try std.testing.expect(router.isNativeKey(key));
    for ([_][]const u8{ "F0", "F13", "F1x", "F01", "enter", "ENTER", "Enter ", "ab", "aé", "\x00", "Spacebar", "Return", "Esc", "\xff" }) |key| {
        try std.testing.expect(!router.isNativeKey(key));
    }

    var ok = try router.parse(allocator, "dom.press", "{\"key\":\"F12\",\"modifiers\":[\"Shift\"],\"options\":{\"input\":\"native\"}}", .{});
    defer ok.deinit();
    try std.testing.expectEqualStrings("F12", ok.key.?);
    for ([_][]const u8{
        "{\"key\":\"F13\",\"options\":{\"input\":\"native\"}}",
        "{\"key\":\"ab\",\"options\":{\"input\":\"native\"}}",
        "{\"key\":\"\\u0000\",\"options\":{\"input\":\"native\"}}",
        "{\"key\":\"a\\u0000\",\"options\":{\"input\":\"native\"}}",
    }) |params| {
        try std.testing.expectError(error.BadArgs, router.parse(allocator, "dom.press", params, .{}));
    }
    // Synthetic keys keep their wider KeyboardEvent.key contract.
    var synthetic = try router.parse(allocator, "dom.press", "{\"key\":\"MediaPlayPause\"}", .{});
    defer synthetic.deinit();
}

test "native dom.type rejects text with an embedded NUL (it would truncate at the C ABI)" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.BadArgs, router.parse(allocator, "dom.type", "{\"selector\":\"css=#q\",\"text\":\"a\\u0000b\",\"options\":{\"input\":\"native\"}}", .{}));
    var synthetic = try router.parse(allocator, "dom.type", "{\"selector\":\"css=#q\",\"text\":\"a\\u0000b\"}", .{});
    defer synthetic.deinit();
    try std.testing.expectEqual(@as(usize, 3), synthetic.text.?.len);
}

test "options.input only exists on click/type/press (presence elsewhere is BadArgs); native never with force; press has no force/trial" {
    const allocator = std.testing.allocator;
    for ([_]struct { method: []const u8, params: []const u8 }{
        .{ .method = "dom.query", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "dom.getText", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "dom.getAttribute", .params = "{\"selector\":\"css=#b\",\"name\":\"id\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "dom.waitFor", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "dom.fill", .params = "{\"selector\":\"css=#b\",\"value\":\"x\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "dom.selectOption", .params = "{\"selector\":\"css=#s\",\"value\":\"a\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "page.evaluate", .params = "{\"expression\":\"1\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "page.navigate", .params = "{\"url\":\"about:blank\",\"options\":{\"input\":\"native\"}}" },
        .{ .method = "dom.query", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"bogus\"}}" },
        .{ .method = "dom.query", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"synthetic\"}}" },
        .{ .method = "dom.fill", .params = "{\"selector\":\"css=#b\",\"value\":\"x\",\"options\":{\"input\":\"synthetic\"}}" },
        .{ .method = "dom.selectOption", .params = "{\"selector\":\"css=#s\",\"value\":\"a\",\"options\":{\"input\":\"synthetic\"}}" },
        .{ .method = "dom.getText", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"synthetic\"}}" },
        .{ .method = "page.navigate", .params = "{\"url\":\"about:blank\",\"options\":{\"input\":\"synthetic\"}}" },
        .{ .method = "dom.press", .params = "{\"key\":\"a\",\"options\":{\"input\":\"native\",\"force\":true}}" },
        .{ .method = "dom.press", .params = "{\"key\":\"a\",\"options\":{\"force\":false}}" },
        .{ .method = "dom.press", .params = "{\"key\":\"a\",\"options\":{\"trial\":true}}" },
        .{ .method = "dom.click", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"force\":true}}" },
        .{ .method = "dom.type", .params = "{\"selector\":\"css=#b\",\"text\":\"x\",\"options\":{\"input\":\"native\",\"force\":true}}" },
    }) |case| {
        var accepted = router.parse(allocator, case.method, case.params, .{}) catch |err| {
            try std.testing.expectEqual(error.BadArgs, err);
            continue;
        };
        accepted.deinit();
        std.debug.print("accepted {s} {s}\n", .{ case.method, case.params });
        return error.TestUnexpectedResult;
    }
    var synthetic_type = try router.parse(allocator, "dom.type", "{\"selector\":\"css=#b\",\"text\":\"x\",\"options\":{\"input\":\"synthetic\"}}", .{});
    defer synthetic_type.deinit();
    var forced_synthetic = try router.parse(allocator, "dom.click", "{\"selector\":\"css=#b\",\"options\":{\"force\":true}}", .{});
    defer forced_synthetic.deinit();
    try std.testing.expect(forced_synthetic.force);
}

test "options.humanize: native click/type/press only, never with delay_ms or synthetic input" {
    const allocator = std.testing.allocator;
    for ([_]struct { method: []const u8, params: []const u8 }{
        .{ .method = "dom.click", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":true}}" },
        .{ .method = "dom.type", .params = "{\"selector\":\"css=#q\",\"text\":\"hi\",\"options\":{\"input\":\"native\",\"humanize\":true}}" },
        .{ .method = "dom.press", .params = "{\"key\":\"Enter\",\"options\":{\"input\":\"native\",\"humanize\":true}}" },
    }) |case| {
        var command = try router.parse(allocator, case.method, case.params, .{});
        defer command.deinit();
        try std.testing.expect(command.humanize);
    }
    var off = try router.parse(allocator, "dom.click", "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":false}}", .{});
    defer off.deinit();
    try std.testing.expect(!off.humanize);

    for ([_]struct { method: []const u8, params: []const u8 }{
        // synthetic (explicit or default) + humanize
        .{ .method = "dom.click", .params = "{\"selector\":\"css=#b\",\"options\":{\"humanize\":true}}" },
        .{ .method = "dom.type", .params = "{\"selector\":\"css=#q\",\"text\":\"hi\",\"options\":{\"input\":\"synthetic\",\"humanize\":true}}" },
        // delay_ms + humanize (any verb; click/press do not use delay_ms)
        .{ .method = "dom.type", .params = "{\"selector\":\"css=#q\",\"text\":\"hi\",\"delay_ms\":40,\"options\":{\"input\":\"native\",\"humanize\":true}}" },
        .{ .method = "dom.click", .params = "{\"selector\":\"css=#b\",\"delay_ms\":40,\"options\":{\"input\":\"native\",\"humanize\":true}}" },
        .{ .method = "dom.press", .params = "{\"key\":\"Enter\",\"delay_ms\":40,\"options\":{\"input\":\"native\",\"humanize\":true}}" },
        .{ .method = "dom.type", .params = "{\"selector\":\"css=#q\",\"text\":\"hi\",\"delay_ms\":0,\"options\":{\"input\":\"native\",\"humanize\":true}}" },
        // wrong type
        .{ .method = "dom.click", .params = "{\"selector\":\"css=#b\",\"options\":{\"input\":\"native\",\"humanize\":1}}" },
        // other methods
        .{ .method = "dom.fill", .params = "{\"selector\":\"css=#q\",\"value\":\"x\",\"options\":{\"humanize\":false}}" },
        .{ .method = "dom.query", .params = "{\"selector\":\"css=#q\",\"options\":{\"humanize\":true}}" },
    }) |case| {
        var accepted = router.parse(allocator, case.method, case.params, .{}) catch |err| {
            try std.testing.expectEqual(error.BadArgs, err);
            continue;
        };
        accepted.deinit();
        std.debug.print("accepted {s} {s}\n", .{ case.method, case.params });
        return error.TestUnexpectedResult;
    }
}

fn expectRejected(allocator: std.mem.Allocator, method: []const u8, params: []const u8) !void {
    var accepted = router.parse(allocator, method, params, .{}) catch |err| {
        try std.testing.expectEqual(error.BadArgs, err);
        return;
    };
    accepted.deinit();
    std.debug.print("accepted {s} {s}\n", .{ method, params });
    return error.TestUnexpectedResult;
}

test "dom.setInputFiles: selector plus a non-empty array of non-empty paths; no input option" {
    const allocator = std.testing.allocator;
    var command = try router.parse(allocator, "dom.setInputFiles", "{\"selector\":\"css=#f\",\"paths\":[\"/tmp/a.txt\",\"/tmp/b.png\"],\"options\":{\"timeout_ms\":5000}}", .{});
    defer command.deinit();
    try std.testing.expectEqual(router.Verb.dom_set_input_files, command.verb);
    try std.testing.expectEqual(router.Namespace.dom, command.namespace);
    try std.testing.expectEqual(@as(usize, 2), command.paths.len);
    try std.testing.expectEqualStrings("/tmp/b.png", command.paths[1]);
    try std.testing.expectEqual(@as(?u64, 5000), command.timeout_ms);
    try std.testing.expect(command.strict);

    for ([_][]const u8{
        "{\"selector\":\"css=#f\"}",
        "{\"selector\":\"css=#f\",\"paths\":[]}",
        "{\"selector\":\"css=#f\",\"paths\":\"/tmp/a\"}",
        "{\"selector\":\"css=#f\",\"paths\":[\"\"]}",
        "{\"selector\":\"css=#f\",\"paths\":[1]}",
        "{\"selector\":\"css=#f\",\"paths\":[\"/tmp/a\\u0000b\"]}",
        "{\"paths\":[\"/tmp/a\"]}",
        "{\"selector\":\"css=#f\",\"paths\":[\"/tmp/a\"],\"options\":{\"input\":\"native\"}}",
        "{\"selector\":\"css=#f\",\"paths\":[\"/tmp/a\"],\"options\":{\"humanize\":true}}",
    }) |params| try expectRejected(allocator, "dom.setInputFiles", params);
}

test "dom.hover: synthetic or native (humanize native only); no force or trial" {
    const allocator = std.testing.allocator;
    var plain = try router.parse(allocator, "dom.hover", "{\"selector\":\"css=#m\"}", .{});
    defer plain.deinit();
    try std.testing.expectEqual(router.Verb.dom_hover, plain.verb);
    try std.testing.expectEqual(router.InputMode.synthetic, plain.input);
    try std.testing.expect(plain.strict);
    var native = try router.parse(allocator, "dom.hover", "{\"selector\":\"css=#m\",\"options\":{\"input\":\"native\",\"humanize\":true,\"timeout_ms\":4000}}", .{});
    defer native.deinit();
    try std.testing.expectEqual(router.InputMode.native, native.input);
    try std.testing.expect(native.humanize);
    try std.testing.expectEqual(@as(?u64, 4000), native.timeout_ms);

    for ([_][]const u8{
        "{}",
        "{\"selector\":\"css=#m\",\"options\":{\"force\":true}}",
        "{\"selector\":\"css=#m\",\"options\":{\"trial\":true}}",
        "{\"selector\":\"css=#m\",\"options\":{\"input\":\"native\",\"force\":false}}",
        "{\"selector\":\"css=#m\",\"options\":{\"humanize\":true}}",
        "{\"selector\":\"css=#m\",\"options\":{\"input\":\"bogus\"}}",
    }) |params| try expectRejected(allocator, "dom.hover", params);
}

test "dom.scroll: exactly one of selector or x/y (finite numbers); input yes, humanize no" {
    const allocator = std.testing.allocator;
    var by = try router.parse(allocator, "dom.scroll", "{\"x\":0,\"y\":300.5}", .{});
    defer by.deinit();
    try std.testing.expectEqual(router.Verb.dom_scroll, by.verb);
    try std.testing.expect(by.selector == null);
    try std.testing.expectEqual(@as(?f64, 0), by.scroll_x);
    try std.testing.expectEqual(@as(?f64, 300.5), by.scroll_y);
    var only_y = try router.parse(allocator, "dom.scroll", "{\"y\":-120,\"options\":{\"input\":\"native\"}}", .{});
    defer only_y.deinit();
    try std.testing.expectEqual(@as(?f64, 0), only_y.scroll_x);
    try std.testing.expectEqual(@as(?f64, -120), only_y.scroll_y);
    try std.testing.expectEqual(router.InputMode.native, only_y.input);
    var to = try router.parse(allocator, "dom.scroll", "{\"selector\":\"css=#far\",\"options\":{\"input\":\"native\",\"timeout_ms\":9000}}", .{});
    defer to.deinit();
    try std.testing.expectEqualStrings("css=#far", to.selector.?);
    try std.testing.expect(to.scroll_x == null and to.scroll_y == null);
    try std.testing.expectEqual(@as(?u64, 9000), to.timeout_ms);

    for ([_][]const u8{
        "{}",
        "{\"selector\":\"css=#far\",\"y\":10}",
        "{\"x\":\"10\"}",
        "{\"y\":true}",
        "{\"y\":1e400}",
        "{\"selector\":\"css=#far\",\"options\":{\"input\":\"native\",\"humanize\":true}}",
        "{\"y\":10,\"options\":{\"force\":true}}",
        "{\"y\":10,\"options\":{\"trial\":true}}",
    }) |params| try expectRejected(allocator, "dom.scroll", params);
}

test "page.navigate onBeforeUnload: fail by default, accept or dismiss, anything else is BadArgs" {
    const allocator = std.testing.allocator;
    var plain = try router.parse(allocator, "page.navigate", "{\"url\":\"http://a/\"}", .{});
    defer plain.deinit();
    try std.testing.expectEqual(router.BeforeUnload.fail, plain.before_unload);
    inline for (.{ .{ "fail", router.BeforeUnload.fail }, .{ "accept", router.BeforeUnload.accept }, .{ "dismiss", router.BeforeUnload.dismiss } }) |case| {
        var command = try router.parse(allocator, "page.navigate", "{\"url\":\"http://a/\",\"onBeforeUnload\":\"" ++ case[0] ++ "\"}", .{});
        defer command.deinit();
        try std.testing.expectEqual(case[1], command.before_unload);
    }
    for ([_][]const u8{ "\"Accept\"", "\"leave\"", "\"\"", "true", "1", "null" }) |value| {
        const params = try std.fmt.allocPrint(allocator, "{{\"url\":\"http://a/\",\"onBeforeUnload\":{s}}}", .{value});
        defer allocator.free(params);
        try std.testing.expectError(error.BadArgs, router.parse(allocator, "page.navigate", params, .{}));
    }
}
