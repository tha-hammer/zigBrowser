//! N16: Instagram flows as sequences of page.*/dom.* steps (src/instagram.zig).
const std = @import("std");
const instagram = @import("instagram");

const gpa = std.testing.allocator;

const Step = struct { method: []u8, params: []u8 };
const Rule = struct { method: []const u8, contains: []const u8 = "", result: ?[]const u8 };

const FakeRunner = struct {
    steps: std.ArrayListUnmanaged(Step) = .empty,
    rules: []const Rule = &.{},
    now_ms: u64 = 0,
    budget_ms: u64 = 120_000,
    malformed_calls: usize = 0,

    fn deinit(self: *FakeRunner) void {
        for (self.steps.items) |s| {
            gpa.free(s.method);
            gpa.free(s.params);
        }
        self.steps.deinit(gpa);
    }

    pub fn run(self: *FakeRunner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        try self.steps.append(gpa, .{ .method = try gpa.dupe(u8, method), .params = try gpa.dupe(u8, params_json) });
        for (self.rules) |rule| {
            if (std.mem.eql(u8, rule.method, method) and std.mem.indexOf(u8, params_json, rule.contains) != null) return rule.result;
        }
        if (std.mem.eql(u8, method, "dom.query")) return "{\"elements\":[{\"id\":\"e\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{}}]}";
        return "{\"ok\":true}";
    }
    pub fn nowMs(self: *const FakeRunner) u64 {
        return self.now_ms;
    }
    pub fn remainingMs(self: *const FakeRunner) u64 {
        return self.budget_ms -| self.now_ms;
    }
    pub fn pause(self: *FakeRunner, ms: u64) bool {
        self.now_ms += ms;
        return true;
    }
    pub fn malformed(self: *FakeRunner) error{OutOfMemory}!void {
        self.malformed_calls += 1;
    }
    pub fn notFound(_: *FakeRunner, _: []const u8) error{OutOfMemory}!void {}

    fn methods(self: *const FakeRunner, buf: [][]const u8) [][]const u8 {
        for (self.steps.items, 0..) |s, i| buf[i] = s.method;
        return buf[0..self.steps.items.len];
    }

    fn selectorOf(self: *const FakeRunner, index: usize) ![]u8 {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, self.steps.items[index].params, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const value = obj.get("selector") orelse obj.get("url").?;
        return gpa.dupe(u8, value.string);
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

fn expectSelector(runner: *const FakeRunner, index: usize, expected: []const u8) !void {
    const actual = try runner.selectorOf(index);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

const profile = "https://www.instagram.com/ada.lovelace/";
const post = "https://www.instagram.com/p/C0ffee/";

test "method table: every instagram.* the SDKs send, nothing else" {
    for ([_][]const u8{ "follow", "like", "comment", "dm", "story_view", "selfcheck" }) |name| {
        var buf: [32]u8 = undefined;
        const method = try std.fmt.bufPrint(&buf, "instagram.{s}", .{name});
        try std.testing.expect(instagram.verbFromMethod(method) != null);
    }
    try std.testing.expect(instagram.verbFromMethod("instagram.post") == null);
    try std.testing.expect(instagram.verbFromMethod("linkedin.follow") == null);
    try std.testing.expect(!instagram.isAction(.selfcheck) and instagram.isAction(.story_view));
}

test "follow: login gate, Follow in the profile header, wait for Following/Requested" {
    var runner = FakeRunner{};
    defer runner.deinit();
    gpa.free((try instagram.follow(gpa, &runner, instagram.site, profile)).?);
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.waitFor" });
    try expectSelector(&runner, 1, instagram.selectors.signed_in);
    try expectSelector(&runner, 2, instagram.selectors.follow_button);
    try expectSelector(&runner, 3, instagram.selectors.following_button);
}

test "logged out: LoggedOut, nothing clicked" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.waitFor", .result = null }} };
    defer runner.deinit();
    try std.testing.expectError(error.LoggedOut, instagram.like(gpa, &runner, instagram.site, post));
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "dom.query" });
}

test "like waits for Unlike; comment fills the comment box and posts" {
    var l = FakeRunner{};
    defer l.deinit();
    gpa.free((try instagram.like(gpa, &l, instagram.site, post)).?);
    try expectSelector(&l, 2, instagram.selectors.like_button);
    try expectSelector(&l, 3, instagram.selectors.unlike_marker);

    var c = FakeRunner{};
    defer c.deinit();
    gpa.free((try instagram.comment(gpa, &c, instagram.site, post, "So good")).?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.fill", "dom.type", "dom.click" });
    try expectSelector(&c, 3, instagram.selectors.comment_input);
    // fill only clears; the comment is typed.
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[3].params, "So good") == null);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[4].params, "So good") != null);
    try expectSelector(&c, 5, instagram.selectors.comment_submit);
    try std.testing.expectError(error.InvalidParams, instagram.comment(gpa, &c, instagram.site, post, "x" ** 2201));
}

test "dm opens the profile, presses Message, types and sends" {
    var runner = FakeRunner{};
    defer runner.deinit();
    gpa.free((try instagram.dm(gpa, &runner, instagram.site, "ada.lovelace", "hi Ada")).?);
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.click", "dom.type", "dom.click" });
    try expectSelector(&runner, 0, "https://www.instagram.com/ada.lovelace/");
    try expectSelector(&runner, 2, instagram.selectors.message_button);
    try expectSelector(&runner, 4, instagram.selectors.dm_input);
    try expectSelector(&runner, 5, instagram.selectors.dm_send);
}

test "story_view opens /stories/<username>/, waits for media, and clicks Next frame by frame until none is left" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    // No Next: one frame.
    var single = FakeRunner{ .rules = &.{.{ .method = "dom.query", .contains = "Next", .result = "{\"elements\":[]}" }} };
    defer single.deinit();
    const one = (try instagram.storyView(gpa, &single, fixture_site, "ada.lovelace")).?;
    defer gpa.free(one);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", one);
    try expectSelector(&single, 0, "http://127.0.0.1:9/stories/ada.lovelace/");
    try expectSelector(&single, 2, instagram.selectors.story_media);

    // Next leaves the viewer: the click counts, then it stops.
    var leaving = FakeRunner{ .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/ada.lovelace/\"}" }} };
    defer leaving.deinit();
    const left = (try instagram.storyView(gpa, &leaving, fixture_site, "ada.lovelace")).?;
    defer gpa.free(left);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", left);
    try std.testing.expectEqual(@as(u64, instagram.story_frame_ms), leaving.now_ms);

    // Next forever: frames until the flow budget would not cover another.
    var endless = FakeRunner{ .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/stories/ada.lovelace/9/\"}" }} };
    defer endless.deinit();
    const many = (try instagram.storyView(gpa, &endless, fixture_site, "ada.lovelace")).?;
    defer gpa.free(many);
    const parsed = try std.json.parseFromSlice(struct { ok: bool, framesViewed: u64 }, gpa, many, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.framesViewed > 10 and parsed.value.framesViewed <= instagram.max_story_frames);
    try std.testing.expect(endless.now_ms <= endless.budget_ms);

    // A failing page.url step fails the flow (not a silent stop).
    var broken = FakeRunner{ .rules = &.{.{ .method = "page.url", .result = null }} };
    defer broken.deinit();
    try std.testing.expect((try instagram.storyView(gpa, &broken, fixture_site, "ada.lovelace")) == null);
}

test "usernames and URLs are validated before any step" {
    var runner = FakeRunner{};
    defer runner.deinit();
    for ([_][]const u8{ "", "a/b", "ada lovelace", "x" ** 31, "../etc" }) |bad| {
        try std.testing.expectError(error.InvalidParams, instagram.storyView(gpa, &runner, instagram.site, bad));
    }
    for ([_][]const u8{ "instagram.com/ada", "https://www.instagram.com.evil.example/ada/", "https://evil@www.instagram.com/ada/", "http://www.instagram.com/ada/", "https://www.linkedin.com/in/ada/", "https://www.instagram.com:444/ada/" }) |bad| {
        try std.testing.expectError(error.InvalidParams, instagram.follow(gpa, &runner, instagram.site, bad));
    }
    try std.testing.expectError(error.InvalidParams, instagram.dm(gpa, &runner, instagram.site, "ada", ""));
    try std.testing.expectEqual(@as(usize, 0), runner.steps.items.len);
}

test "selfcheck reports every selector-table entry, read-only" {
    var runner = FakeRunner{};
    defer runner.deinit();
    const result = (try instagram.selfCheck(gpa, &runner)).?;
    defer gpa.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@typeInfo(instagram.selectors).@"struct".decls.len, parsed.value.object.count());
    for (runner.steps.items) |s| try std.testing.expectEqualStrings("dom.query", s.method);
}
