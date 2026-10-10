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
    now_ms: u64 = 0,
    /// Flow budget left at now_ms = 0.
    budget_ms: u64 = 120_000,
    pauses: usize = 0,
    malformed_calls: usize = 0,
    not_found: ?[]const u8 = null,

    pub fn nowMs(self: *const FakeRunner) u64 {
        return self.now_ms;
    }

    pub fn remainingMs(self: *const FakeRunner) u64 {
        return self.budget_ms -| self.now_ms;
    }

    pub fn pause(self: *FakeRunner, ms: u64) bool {
        self.pauses += 1;
        self.now_ms += ms;
        return true;
    }

    pub fn malformed(self: *FakeRunner) error{OutOfMemory}!void {
        self.malformed_calls += 1;
    }

    pub fn notFound(self: *FakeRunner, reason: []const u8) error{OutOfMemory}!void {
        self.not_found = reason;
    }

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
    try std.testing.expectEqualStrings("tweetButton", x.selectors.post_button_testids[0]);
    try std.testing.expectEqualStrings("tweetButtonInline", x.selectors.post_button_testids[1]);
}

/// Scripted page for the Post-button probe: how many copies of each testid
/// exist, and which nth copy passes a trial click (null = none, ever).
const ProbeRunner = struct {
    inner: FakeRunner = .{},
    dialog_copies: usize = 1,
    inline_copies: usize = 0,
    /// No copy of any Post button exists before this time.
    buttons_appear_at_ms: u64 = 0,
    actionable: ?[]const u8 = "xpath=(//*[@data-testid=\"tweetButton\"])[1]",
    /// Trial probes that fail before `actionable` starts passing.
    fail_probes_before: usize = 0,
    probes: usize = 0,
    buf: [1024]u8 = undefined,

    pub fn run(self: *ProbeRunner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        _ = try self.inner.run(method, params_json);
        if (std.mem.eql(u8, method, "dom.query")) {
            const present = self.inner.now_ms >= self.buttons_appear_at_ms;
            const n = if (!present) 0 else if (std.mem.indexOf(u8, params_json, "tweetButtonInline") != null) self.inline_copies else self.dialog_copies;
            var out: std.Io.Writer = .fixed(&self.buf);
            out.writeAll("{\"elements\":[") catch unreachable;
            for (0..n) |i| {
                if (i > 0) out.writeAll(",") catch unreachable;
                out.writeAll("{\"id\":\"e\",\"tag\":\"button\",\"text\":\"Post\",\"bbox\":{}}") catch unreachable;
            }
            out.writeAll("]}") catch unreachable;
            return out.buffered();
        }
        if (std.mem.eql(u8, method, "dom.click") and std.mem.indexOf(u8, params_json, "\"trial\":true") != null) {
            self.probes += 1;
            if (self.probes <= self.fail_probes_before) return null;
            const wanted = self.actionable orelse return null;
            const quoted = try std.json.Stringify.valueAlloc(gpa, wanted, .{});
            defer gpa.free(quoted);
            return if (std.mem.indexOf(u8, params_json, quoted) != null) "{\"ok\":true}" else null;
        }
        return "{\"ok\":true}";
    }

    pub fn nowMs(self: *const ProbeRunner) u64 {
        return self.inner.nowMs();
    }
    pub fn remainingMs(self: *const ProbeRunner) u64 {
        return self.inner.remainingMs();
    }
    pub fn pause(self: *ProbeRunner, ms: u64) bool {
        return self.inner.pause(ms);
    }
    pub fn malformed(self: *ProbeRunner) error{OutOfMemory}!void {
        return self.inner.malformed();
    }
    pub fn notFound(self: *ProbeRunner, reason: []const u8) error{OutOfMemory}!void {
        return self.inner.notFound(reason);
    }
};

fn lastClickSelector(runner: *const FakeRunner) ![]u8 {
    var i = runner.steps.items.len;
    while (i > 0) {
        i -= 1;
        const s = runner.steps.items[i];
        if (!std.mem.eql(u8, s.method, "dom.click")) continue;
        if (std.mem.indexOf(u8, s.params, "\"trial\":true") != null) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, s.params, .{});
        defer parsed.deinit();
        return gpa.dupe(u8, parsed.value.object.get("selector").?.string);
    }
    return error.TestNoClick;
}

test "x.post: navigate, gate, clear any stale draft, type, probe Post, click it, confirm" {
    var runner = ProbeRunner{};
    defer runner.inner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hello from zigBrowser", .compose_url = "http://127.0.0.1:9/compose" })).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"ok\":true}", result);
    try expectMethods(&runner.inner, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.fill", "dom.type", "dom.query", "dom.click", "dom.click", "dom.waitFor" });

    const nav = try stepParams(&runner.inner, 0);
    defer nav.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:9/compose", nav.value.object.get("url").?.string);
    const cleared = try stepParams(&runner.inner, 3);
    defer cleared.deinit();
    try std.testing.expectEqualStrings(x.selectors.composer, cleared.value.object.get("selector").?.string);
    try std.testing.expectEqualStrings("", cleared.value.object.get("value").?.string);
    const typed = try stepParams(&runner.inner, 4);
    defer typed.deinit();
    try std.testing.expectEqualStrings("hello from zigBrowser", typed.value.object.get("text").?.string);
    const probe = try stepParams(&runner.inner, 6);
    defer probe.deinit();
    try std.testing.expectEqual(true, probe.value.object.get("options").?.object.get("trial").?.bool);
    const clicked = try lastClickSelector(&runner.inner);
    defer gpa.free(clicked);
    try std.testing.expectEqualStrings("xpath=(//*[@data-testid=\"tweetButton\"])[1]", clicked);
    const confirm = try stepParams(&runner.inner, 8);
    defer confirm.deinit();
    try std.testing.expectEqualStrings(x.selectors.post_success, confirm.value.object.get("selector").?.string);
}

test "x.post skips a non-actionable dialog button and clicks the actionable inline one" {
    var runner = ProbeRunner{ .inline_copies = 1, .actionable = "xpath=(//*[@data-testid=\"tweetButtonInline\"])[1]" };
    defer runner.inner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hi" })).?;
    defer gpa.free(result);
    const clicked = try lastClickSelector(&runner.inner);
    defer gpa.free(clicked);
    try std.testing.expectEqualStrings("xpath=(//*[@data-testid=\"tweetButtonInline\"])[1]", clicked);
}

test "x.post probes every duplicate copy and clicks exactly the actionable one" {
    var runner = ProbeRunner{ .dialog_copies = 3, .actionable = "xpath=(//*[@data-testid=\"tweetButton\"])[3]" };
    defer runner.inner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hi" })).?;
    defer gpa.free(result);
    const clicked = try lastClickSelector(&runner.inner);
    defer gpa.free(clicked);
    try std.testing.expectEqualStrings("xpath=(//*[@data-testid=\"tweetButton\"])[3]", clicked);
}

test "x.post keeps probing until a late Post button becomes actionable" {
    var runner = ProbeRunner{ .inline_copies = 1, .actionable = "xpath=(//*[@data-testid=\"tweetButtonInline\"])[1]", .fail_probes_before = 6 };
    defer runner.inner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hi" })).?;
    defer gpa.free(result);
    try std.testing.expect(runner.probes > 6);
}

test "x.post fails (null) when no Post button ever becomes actionable; the last probe failure stands" {
    var runner = ProbeRunner{ .inline_copies = 1, .actionable = null };
    defer runner.inner.deinit();
    try std.testing.expect((try x.post(gpa, &runner, .{ .text = "hi" })) == null);
    // Rounds every post_button_poll_ms for post_button_wait_ms, 2 copies each.
    const rounds = x.post_button_wait_ms / x.post_button_poll_ms;
    try std.testing.expect(runner.probes >= rounds and runner.probes <= (rounds + 1) * 2);
    try std.testing.expect(runner.inner.not_found == null);
}

test "x.post waits for a Post button that does not exist yet (zero copies, then a late one)" {
    var runner = ProbeRunner{ .buttons_appear_at_ms = 3_000 };
    defer runner.inner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hi" })).?;
    defer gpa.free(result);
    try std.testing.expect(runner.inner.pauses >= 3_000 / x.post_button_poll_ms);
    const clicked = try lastClickSelector(&runner.inner);
    defer gpa.free(clicked);
    try std.testing.expectEqualStrings("xpath=(//*[@data-testid=\"tweetButton\"])[1]", clicked);
}

test "x.post with no Post button at all: element_not_found x_post_button_missing, bounded by the wait" {
    var runner = ProbeRunner{ .dialog_copies = 0 };
    defer runner.inner.deinit();
    try std.testing.expect((try x.post(gpa, &runner, .{ .text = "hi" })) == null);
    try std.testing.expectEqualStrings("x_post_button_missing", runner.inner.not_found.?);
    try std.testing.expect(runner.inner.now_ms <= x.post_button_wait_ms);
    try std.testing.expectEqual(@as(usize, 0), runner.probes);
}

test "x.post probes every copy, not only the first few (6 copies, the 5th is actionable)" {
    var runner = ProbeRunner{ .dialog_copies = 6, .actionable = "xpath=(//*[@data-testid=\"tweetButton\"])[5]" };
    defer runner.inner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hi" })).?;
    defer gpa.free(result);
    const clicked = try lastClickSelector(&runner.inner);
    defer gpa.free(clicked);
    try std.testing.expectEqualStrings("xpath=(//*[@data-testid=\"tweetButton\"])[5]", clicked);
    try std.testing.expectEqual(@as(usize, 5), runner.probes);
}

test "a successful query with an unusable answer is reported as malformed" {
    var runner = FakeRunner{};
    runner.answers = &.{.{ .method = "dom.query", .result = "{\"elements\":\"nope\"}" }};
    defer runner.deinit();
    try std.testing.expect((try x.loginCheck(gpa, &runner)) == null);
    try std.testing.expectEqual(@as(usize, 1), runner.malformed_calls);
}

test "every step's timeout is clamped to what is left of the flow budget" {
    var runner = ProbeRunner{};
    runner.inner.budget_ms = 5_000;
    defer runner.inner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hi" })).?;
    defer gpa.free(result);
    for (runner.inner.steps.items) |step_item| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, step_item.params, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const top = if (obj.get("timeout_ms")) |t| t.integer else null;
        const nested = if (obj.get("options")) |o| if (o.object.get("timeout_ms")) |t| t.integer else null else null;
        const ms = top orelse nested orelse {
            std.debug.print("step without a timeout: {s}\n", .{step_item.method});
            return error.TestUnexpectedResult;
        };
        try std.testing.expect(ms <= 5_000);
        if (std.mem.eql(u8, step_item.method, "dom.waitFor")) try std.testing.expect(ms <= 4_000);
    }
}

test "x.post defaults to the real compose URL" {
    var runner = ProbeRunner{};
    defer runner.inner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hi" })).?;
    defer gpa.free(result);
    const nav = try stepParams(&runner.inner, 0);
    defer nav.deinit();
    try std.testing.expectEqualStrings(x.compose_url, nav.value.object.get("url").?.string);
}

test "x.post validates text: empty, over 280 characters" {
    var runner = ProbeRunner{};
    defer runner.inner.deinit();
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
    var wrapper = ProbeRunner{};
    defer wrapper.inner.deinit();
    const result = (try x.schedulePost(gpa, &wrapper, .{ .text = "later", .date = "2026-11-05", .time = "14:07", .compose_url = "http://f/compose" })).?;
    defer gpa.free(result);
    const runner = &wrapper.inner;
    try std.testing.expectEqualStrings("{\"ok\":true,\"scheduledFor\":\"2026-11-05T14:07\"}", result);
    try expectMethods(runner, &.{
        "page.navigate",     "dom.waitFor",       "dom.click",         "dom.fill",
        "dom.type",          "dom.click",         "dom.waitFor",       "dom.selectOption",
        "dom.selectOption",  "dom.selectOption",  "dom.selectOption",  "dom.selectOption",
        "dom.selectOption",  "dom.click",         "dom.query",         "dom.click",
        "dom.click",         "dom.waitFor",
    });
    const expected = [_]struct { selector: []const u8, value: []const u8 }{
        .{ .selector = x.selectors.schedule_month, .value = "11" },
        .{ .selector = x.selectors.schedule_day, .value = "5" },
        .{ .selector = x.selectors.schedule_year, .value = "2026" },
        .{ .selector = x.selectors.schedule_hour, .value = "2" },
        .{ .selector = x.selectors.schedule_minute, .value = "7" },
        .{ .selector = x.selectors.schedule_ampm, .value = "PM" },
    };
    for (expected, 7..) |e, i| {
        const p = try stepParams(runner, i);
        defer p.deinit();
        try std.testing.expectEqualStrings(e.selector, p.value.object.get("selector").?.string);
        try std.testing.expectEqualStrings(e.value, p.value.object.get("value").?.string);
    }
    const opened = try stepParams(runner, 5);
    defer opened.deinit();
    try std.testing.expectEqualStrings(x.selectors.schedule_option, opened.value.object.get("selector").?.string);
    const confirm = try stepParams(runner, 13);
    defer confirm.deinit();
    try std.testing.expectEqualStrings(x.selectors.schedule_confirm, confirm.value.object.get("selector").?.string);
    // The probed copy is clicked by its exact (strict) selector.
    const submit = try stepParams(runner, 16);
    defer submit.deinit();
    try std.testing.expectEqualStrings("xpath=(//*[@data-testid=\"tweetButton\"])[1]", submit.value.object.get("selector").?.string);
    try std.testing.expect(submit.value.object.get("options").?.object.get("trial") == null);
    const success = try stepParams(runner, 17);
    defer success.deinit();
    try std.testing.expectEqualStrings(x.selectors.post_success, success.value.object.get("selector").?.string);
}

test "12-hour conversion edges: midnight, noon, 23:59" {
    for ([_]struct { time: []const u8, hour: []const u8, minute: []const u8, ampm: []const u8 }{
        .{ .time = "00:00", .hour = "12", .minute = "0", .ampm = "AM" },
        .{ .time = "12:30", .hour = "12", .minute = "30", .ampm = "PM" },
        .{ .time = "23:59", .hour = "11", .minute = "59", .ampm = "PM" },
        .{ .time = "09:05", .hour = "9", .minute = "5", .ampm = "AM" },
    }) |case| {
        var wrapper = ProbeRunner{};
        defer wrapper.inner.deinit();
        const result = (try x.schedulePost(gpa, &wrapper, .{ .text = "t", .date = "2027-01-31", .time = case.time })).?;
        gpa.free(result);
        const runner = &wrapper.inner;
        const hour = try stepParams(runner, 10);
        defer hour.deinit();
        try std.testing.expectEqualStrings(case.hour, hour.value.object.get("value").?.string);
        const minute = try stepParams(runner, 11);
        defer minute.deinit();
        try std.testing.expectEqualStrings(case.minute, minute.value.object.get("value").?.string);
        const ampm = try stepParams(runner, 12);
        defer ampm.deinit();
        try std.testing.expectEqualStrings(case.ampm, ampm.value.object.get("value").?.string);
    }
}

test "schedule_post rejects malformed or impossible date/time before any step" {
    var wrapper = ProbeRunner{};
    defer wrapper.inner.deinit();
    const runner = &wrapper;
    for ([_][2][]const u8{
        .{ "2026-13-01", "10:00" }, .{ "2026-02-30", "10:00" }, .{ "2026-1-01", "10:00" },
        .{ "26-01-01", "10:00" },   .{ "2026-01-01", "24:00" }, .{ "2026-01-01", "10:60" },
        .{ "2026-01-01", "9:00" },  .{ "2026/01/01", "10:00" }, .{ "2026-01-01", "10:00:00" },
        .{ "0000-01-01", "10:00" }, .{ "1999-12-31", "10:00" }, .{ "2101-01-01", "10:00" },
    }) |c| {
        try std.testing.expectError(error.InvalidParams, x.schedulePost(gpa, runner, .{ .text = "t", .date = c[0], .time = c[1] }));
    }
    try std.testing.expectEqual(@as(usize, 0), wrapper.inner.steps.items.len);
    // Leap day is a real date.
    const ok = (try x.schedulePost(gpa, runner, .{ .text = "t", .date = "2028-02-29", .time = "10:00" })).?;
    gpa.free(ok);
}

test "a failing step stops the flow and returns null" {
    var runner = FakeRunner{ .fail_at = 4 }; // the type step
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

test "x.zig never sends a 0 ms deadline (the native page call needs real time)" {
    var runner = ProbeRunner{ .inline_copies = 1, .actionable = "xpath=(//*[@data-testid=\"tweetButtonInline\"])[1]" };
    defer runner.inner.deinit();
    const result = (try x.post(gpa, &runner, .{ .text = "hi" })).?;
    defer gpa.free(result);
    for (runner.inner.steps.items) |step_item| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, step_item.params, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const top = if (obj.get("timeout_ms")) |t| t.integer else null;
        const nested = if (obj.get("options")) |o| if (o.object.get("timeout_ms")) |t| t.integer else null else null;
        for ([_]?i64{ top, nested }) |maybe| {
            if (maybe) |ms| try std.testing.expect(ms >= 1000);
        }
    }
}
