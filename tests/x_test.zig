//! N11: X (x.com) flows as sequences of dom.*/page.* steps.
const std = @import("std");
const x = @import("x");

const gpa = std.testing.allocator;

const Step = struct { method: []u8, params: []u8 };

/// Records every step; answers from a script keyed by method (default {"ok":true}).
const FakeRunner = struct {
    steps: std.ArrayListUnmanaged(Step) = .empty,
    /// method -> result JSON (null = the step fails).
    answers: []const struct { method: []const u8, result: ?[]const u8 } = &.{},
    fail_at: ?usize = null,

    fn deinit(self: *FakeRunner) void {
        for (self.steps.items) |s| {
            gpa.free(s.method);
            gpa.free(s.params);
        }
        self.steps.deinit(gpa);
    }

    pub fn run(self: *FakeRunner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        const index = self.steps.items.len;
        try self.steps.append(gpa, .{ .method = try gpa.dupe(u8, method), .params = try gpa.dupe(u8, params_json) });
        if (self.fail_at) |i| if (i == index) return null;
        for (self.answers) |a| {
            if (std.mem.eql(u8, a.method, method)) return a.result;
        }
        return "{\"ok\":true}";
    }

    fn methods(self: *const FakeRunner, buf: [][]const u8) [][]const u8 {
        for (self.steps.items, 0..) |s, i| buf[i] = s.method;
        return buf[0..self.steps.items.len];
    }
};

fn expectMethods(runner: *const FakeRunner, expected: []const []const u8) !void {
    var buf: [64][]const u8 = undefined;
    const actual = runner.methods(&buf);
    if (actual.len != expected.len) {
        std.debug.print("steps: {any}\n", .{actual});
        return error.TestUnexpectedStepCount;
    }
    for (expected, actual) |e, a| try std.testing.expectEqualStrings(e, a);
}

fn stepParams(runner: *const FakeRunner, index: usize) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, gpa, runner.steps.items[index].params, .{});
}

test "every selector lives in the one table at the top of x.zig" {
    try std.testing.expectEqualStrings("testid=tweetTextarea_0", x.selectors.composer);
    try std.testing.expectEqualStrings("testid=scheduleOption", x.selectors.schedule_option);
    try std.testing.expectEqualStrings("testid=scheduledConfirmationPrimaryAction", x.selectors.schedule_confirm);
    try std.testing.expect(std.mem.indexOf(u8, x.selectors.post_button, "tweetButtonInline") != null);
    try std.testing.expect(std.mem.indexOf(u8, x.selectors.post_button, "tweetButton\"") != null);
}

test "x.post: navigate, gate on the composer, click, type, post, confirm" {
    var runner = FakeRunner{};
    defer runner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hello from zigBrowser", .compose_url = "http://127.0.0.1:9/compose" })).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"ok\":true}", result);
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.type", "dom.click", "dom.waitFor" });

    const nav = try stepParams(&runner, 0);
    defer nav.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:9/compose", nav.value.object.get("url").?.string);
    const typed = try stepParams(&runner, 3);
    defer typed.deinit();
    try std.testing.expectEqualStrings(x.selectors.composer, typed.value.object.get("selector").?.string);
    try std.testing.expectEqualStrings("hello from zigBrowser", typed.value.object.get("text").?.string);
    const post_click = try stepParams(&runner, 4);
    defer post_click.deinit();
    try std.testing.expectEqualStrings(x.selectors.post_button, post_click.value.object.get("selector").?.string);
    const confirm = try stepParams(&runner, 5);
    defer confirm.deinit();
    try std.testing.expectEqualStrings(x.selectors.post_success, confirm.value.object.get("selector").?.string);
}

test "x.post defaults to the real compose URL" {
    var runner = FakeRunner{};
    defer runner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hi" })).?;
    defer gpa.free(result);
    const nav = try stepParams(&runner, 0);
    defer nav.deinit();
    try std.testing.expectEqualStrings(x.compose_url, nav.value.object.get("url").?.string);
}

test "x.post validates text: empty, over 280 characters" {
    var runner = FakeRunner{};
    defer runner.deinit();
    try std.testing.expectError(error.InvalidParams, x.post(gpa, &runner, .{ .text = "" }));
    const long = "é" ** 281;
    try std.testing.expectError(error.InvalidParams, x.post(gpa, &runner, .{ .text = long }));
    const ok_len = "é" ** 280;
    const result = (try x.post(gpa, &runner, .{ .text = ok_len })).?;
    gpa.free(result);
}

test "logged-out page (login link, no composer) is reported as LoggedOut, nothing typed" {
    var runner = FakeRunner{ .fail_at = 1 }; // composer waitFor fails
    runner.answers = &.{.{ .method = "dom.query", .result = "{\"elements\":[{\"id\":\"zb-1\",\"tag\":\"a\",\"text\":\"Log in\",\"bbox\":{}}]}" }};
    defer runner.deinit();
    try std.testing.expectError(error.LoggedOut, x.post(gpa, &runner, .{ .text = "hi" }));
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "dom.query" });
    const probe = try stepParams(&runner, 2);
    defer probe.deinit();
    try std.testing.expectEqualStrings(x.selectors.login_link, probe.value.object.get("selector").?.string);
}

test "a missing composer without a login link surfaces the step failure (null)" {
    var runner = FakeRunner{ .fail_at = 1 };
    runner.answers = &.{.{ .method = "dom.query", .result = "{\"elements\":[]}" }};
    defer runner.deinit();
    try std.testing.expect((try x.post(gpa, &runner, .{ .text = "hi" })) == null);
}

test "x.schedule_post converts 24h time and selects month/day/year/hour/minute/AM-PM" {
    var runner = FakeRunner{};
    defer runner.deinit();
    const result = (try x.schedulePost(gpa, &runner, .{ .text = "later", .date = "2026-11-05", .time = "14:07", .compose_url = "http://f/compose" })).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"ok\":true,\"scheduledFor\":\"2026-11-05T14:07\"}", result);
    try expectMethods(&runner, &.{
        "page.navigate",     "dom.waitFor",       "dom.click",         "dom.type",
        "dom.click",         "dom.waitFor",       "dom.selectOption",  "dom.selectOption",
        "dom.selectOption",  "dom.selectOption",  "dom.selectOption",  "dom.selectOption",
        "dom.click",         "dom.click",         "dom.waitFor",
    });
    const expected = [_]struct { selector: []const u8, value: []const u8 }{
        .{ .selector = x.selectors.schedule_month, .value = "11" },
        .{ .selector = x.selectors.schedule_day, .value = "5" },
        .{ .selector = x.selectors.schedule_year, .value = "2026" },
        .{ .selector = x.selectors.schedule_hour, .value = "2" },
        .{ .selector = x.selectors.schedule_minute, .value = "7" },
        .{ .selector = x.selectors.schedule_ampm, .value = "PM" },
    };
    for (expected, 6..) |e, i| {
        const p = try stepParams(&runner, i);
        defer p.deinit();
        try std.testing.expectEqualStrings(e.selector, p.value.object.get("selector").?.string);
        try std.testing.expectEqualStrings(e.value, p.value.object.get("value").?.string);
    }
    const opened = try stepParams(&runner, 4);
    defer opened.deinit();
    try std.testing.expectEqualStrings(x.selectors.schedule_option, opened.value.object.get("selector").?.string);
    const confirm = try stepParams(&runner, 12);
    defer confirm.deinit();
    try std.testing.expectEqualStrings(x.selectors.schedule_confirm, confirm.value.object.get("selector").?.string);
}

test "12-hour conversion edges: midnight, noon, 23:59" {
    for ([_]struct { time: []const u8, hour: []const u8, minute: []const u8, ampm: []const u8 }{
        .{ .time = "00:00", .hour = "12", .minute = "0", .ampm = "AM" },
        .{ .time = "12:30", .hour = "12", .minute = "30", .ampm = "PM" },
        .{ .time = "23:59", .hour = "11", .minute = "59", .ampm = "PM" },
        .{ .time = "09:05", .hour = "9", .minute = "5", .ampm = "AM" },
    }) |case| {
        var runner = FakeRunner{};
        defer runner.deinit();
        const result = (try x.schedulePost(gpa, &runner, .{ .text = "t", .date = "2027-01-31", .time = case.time })).?;
        gpa.free(result);
        const hour = try stepParams(&runner, 9);
        defer hour.deinit();
        try std.testing.expectEqualStrings(case.hour, hour.value.object.get("value").?.string);
        const minute = try stepParams(&runner, 10);
        defer minute.deinit();
        try std.testing.expectEqualStrings(case.minute, minute.value.object.get("value").?.string);
        const ampm = try stepParams(&runner, 11);
        defer ampm.deinit();
        try std.testing.expectEqualStrings(case.ampm, ampm.value.object.get("value").?.string);
    }
}

test "schedule_post rejects malformed or impossible date/time before any step" {
    var runner = FakeRunner{};
    defer runner.deinit();
    for ([_][2][]const u8{
        .{ "2026-13-01", "10:00" }, .{ "2026-02-30", "10:00" }, .{ "2026-1-01", "10:00" },
        .{ "26-01-01", "10:00" },   .{ "2026-01-01", "24:00" }, .{ "2026-01-01", "10:60" },
        .{ "2026-01-01", "9:00" },  .{ "2026/01/01", "10:00" }, .{ "2026-01-01", "10:00:00" },
    }) |c| {
        try std.testing.expectError(error.InvalidParams, x.schedulePost(gpa, &runner, .{ .text = "t", .date = c[0], .time = c[1] }));
    }
    try std.testing.expectEqual(@as(usize, 0), runner.steps.items.len);
    // Leap day is a real date.
    const ok = (try x.schedulePost(gpa, &runner, .{ .text = "t", .date = "2028-02-29", .time = "10:00" })).?;
    gpa.free(ok);
}

test "a failing step stops the flow and returns null" {
    var runner = FakeRunner{ .fail_at = 4 }; // the post click
    defer runner.deinit();
    try std.testing.expect((try x.post(gpa, &runner, .{ .text = "hi" })) == null);
    try std.testing.expectEqual(@as(usize, 5), runner.steps.items.len);
}

test "x.login_check: composer present -> logged in; login link and no composer -> logged out" {
    var logged_in = FakeRunner{};
    logged_in.answers = &.{.{ .method = "dom.query", .result = "{\"elements\":[{\"id\":\"zb-1\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{}}]}" }};
    defer logged_in.deinit();
    const a = (try x.loginCheck(gpa, &logged_in)).?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("{\"loggedIn\":true,\"platform\":\"x\"}", a);

    var logged_out = FakeRunner{};
    logged_out.answers = &.{.{ .method = "dom.query", .result = "{\"elements\":[]}" }};
    defer logged_out.deinit();
    const b = (try x.loginCheck(gpa, &logged_out)).?;
    defer gpa.free(b);
    try std.testing.expectEqualStrings("{\"loggedIn\":false,\"platform\":\"x\"}", b);
}

test "x method table" {
    try std.testing.expectEqual(x.Verb.post, x.verbFromMethod("x.post").?);
    try std.testing.expectEqual(x.Verb.schedule_post, x.verbFromMethod("x.schedule_post").?);
    try std.testing.expectEqual(x.Verb.login_check, x.verbFromMethod("x.login_check").?);
    try std.testing.expect(x.verbFromMethod("x.delete") == null);
    try std.testing.expect(x.verbFromMethod("dom.click") == null);
}
