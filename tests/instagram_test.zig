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
    not_found: ?[]const u8 = null,
    /// When set, the answer to the first page.url (story_view's check that
    /// the page is a story, or selfcheck's); later ones follow `rules`.
    start_url: ?[]const u8 = null,
    url_calls: usize = 0,

    fn deinit(self: *FakeRunner) void {
        for (self.steps.items) |s| {
            gpa.free(s.method);
            gpa.free(s.params);
        }
        self.steps.deinit(gpa);
    }

    pub fn run(self: *FakeRunner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        try self.steps.append(gpa, .{ .method = try gpa.dupe(u8, method), .params = try gpa.dupe(u8, params_json) });
        if (std.mem.eql(u8, method, "page.url")) {
            self.url_calls += 1;
            if (self.url_calls == 1) if (self.start_url) |answer| return answer;
        }
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
    pub fn notFound(self: *FakeRunner, reason: []const u8) error{OutOfMemory}!void {
        self.not_found = reason;
    }

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

const profile = "https://www.instagram.com/sam.example/";
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
    gpa.free((try instagram.dm(gpa, &runner, instagram.site, "sam.example", "hi Sam")).?);
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.click", "dom.type", "dom.click" });
    try expectSelector(&runner, 0, "https://www.instagram.com/sam.example/");
    try expectSelector(&runner, 2, instagram.selectors.message_button);
    try expectSelector(&runner, 4, instagram.selectors.dm_input);
    try expectSelector(&runner, 5, instagram.selectors.dm_send);
}

const story_page = "{\"url\":\"http://127.0.0.1:9/stories/sam.example/\"}";

test "live story viewer (probe of 2026-10-11): Next is the role=button around an svg labelled Next outside <main>; media is the viewer's video or unlinked image" {
    // The page behind the viewer (inside <main>) has a zero-size
    // <button aria-label="Next">; the viewer's own Next is an <svg> in a
    // div[role=button], outside <main>. Previews and avatars are links.
    try std.testing.expectEqualStrings(
        "xpath=//*[name()=\"svg\" and @aria-label=\"Next\"][not(ancestor::main)]/ancestor::*[@role=\"button\"][1]",
        instagram.selectors.story_next,
    );
    try std.testing.expectEqualStrings(
        "xpath=//section[not(ancestor::main)]//video | //section[not(ancestor::main)]//img[not(ancestor::a)]",
        instagram.selectors.story_media,
    );
}

test "story_view (on): opens /stories/<username>/, checks it is that user's story on the site, then views the frames" {
    try std.testing.expect(instagram.story_viewer_verified);
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    // One Next, after which the viewer closes (back on the profile).
    var runner = FakeRunner{ .start_url = story_page, .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/sam.example/\"}" }} };
    defer runner.deinit();
    const result = (try instagram.storyView(gpa, &runner, fixture_site, "sam.example")).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", result);
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "page.url", "dom.waitFor", "dom.query", "dom.click", "page.url" });
    try expectSelector(&runner, 0, "http://127.0.0.1:9/stories/sam.example/");
    try expectSelector(&runner, 3, instagram.selectors.story_media);
    try expectSelector(&runner, 5, instagram.selectors.story_next);

    // Another user's stories (a redirect) are not the requested viewer.
    var other = FakeRunner{ .start_url = "{\"url\":\"http://127.0.0.1:9/stories/riley.sample/\"}" };
    defer other.deinit();
    try std.testing.expect((try instagram.storyView(gpa, &other, fixture_site, "sam.example")) == null);
    try std.testing.expectEqualStrings("instagram_no_story_viewer", other.not_found.?);
    try expectMethods(&other, &.{ "page.navigate", "dom.waitFor", "page.url" });

    // A story path on another site (a cross-origin redirect) is no viewer.
    var evil = FakeRunner{ .start_url = "{\"url\":\"https://evil.example/stories/sam.example/\"}" };
    defer evil.deinit();
    try std.testing.expect((try instagram.storyView(gpa, &evil, instagram.site, "sam.example")) == null);
    try std.testing.expectEqualStrings("instagram_no_story_viewer", evil.not_found.?);
}

test "viewStoryFrames: waits for media, and clicks Next frame by frame until none is left" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    // No Next: one frame.
    var single = FakeRunner{ .rules = &.{.{ .method = "dom.query", .contains = "Next", .result = "{\"elements\":[]}" }} };
    defer single.deinit();
    const one = (try instagram.viewStoryFrames(gpa, &single, fixture_site, "sam.example")).?;
    defer gpa.free(one);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", one);
    try expectMethods(&single, &.{ "dom.waitFor", "dom.query" });
    try expectSelector(&single, 0, instagram.selectors.story_media);

    // Next closes the viewer (the page leaves /stories/): done after that frame.
    var leaving = FakeRunner{ .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/sam.example/\"}" }} };
    defer leaving.deinit();
    const left = (try instagram.viewStoryFrames(gpa, &leaving, fixture_site, "sam.example")).?;
    defer gpa.free(left);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", left);
    // First frame viewed, Next, then the frame time in which the viewer closed.
    try std.testing.expectEqual(@as(u64, 2 * instagram.story_frame_ms), leaving.now_ms);

    // The last Next's click is cut short as the viewer closes (the URL
    // left /stories/): completion.
    var cut = FakeRunner{ .rules = &.{
        .{ .method = "dom.click", .contains = "Next", .result = null },
        .{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/sam.example/\"}" },
    } };
    defer cut.deinit();
    const done = (try instagram.viewStoryFrames(gpa, &cut, fixture_site, "sam.example")).?;
    defer gpa.free(done);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", done);

    // A failed Next while the viewer is still on /stories/ fails the flow,
    // even if no story media is visible (no media is not evidence).
    var still_open = FakeRunner{ .rules = &.{
        .{ .method = "dom.click", .contains = "Next", .result = null },
        .{ .method = "dom.query", .contains = "video", .result = "{\"elements\":[]}" },
        .{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/stories/sam.example/2/\"}" },
    } };
    defer still_open.deinit();
    try std.testing.expect((try instagram.viewStoryFrames(gpa, &still_open, fixture_site, "sam.example")) == null);

    // Next forever: frames until the flow budget would not cover another.
    var endless = FakeRunner{ .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/stories/sam.example/9/\"}" }} };
    defer endless.deinit();
    const many = (try instagram.viewStoryFrames(gpa, &endless, fixture_site, "sam.example")).?;
    defer gpa.free(many);
    const parsed = try std.json.parseFromSlice(struct { ok: bool, framesViewed: u64 }, gpa, many, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.framesViewed > 10 and parsed.value.framesViewed <= instagram.max_story_frames);
    try std.testing.expect(endless.now_ms <= endless.budget_ms);
    // Every step's timeout fits the flow budget at the time it starts.
    for (endless.steps.items) |st| {
        const p = try std.json.parseFromSlice(std.json.Value, gpa, st.params, .{});
        defer p.deinit();
        const obj = p.value.object;
        const ms = if (obj.get("timeout_ms")) |t| t.integer else if (obj.get("options")) |o| o.object.get("timeout_ms").?.integer else return error.TestStepWithoutTimeout;
        try std.testing.expect(ms <= 120_000);
    }

    // A failed page.url step fails the flow.
    var broken = FakeRunner{ .rules = &.{.{ .method = "page.url", .result = null }} };
    defer broken.deinit();
    try std.testing.expect((try instagram.viewStoryFrames(gpa, &broken, fixture_site, "sam.example")) == null);
}

test "story_view off the story viewer (no active stories: Instagram shows the profile) fails closed, nothing waited for or clicked" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    // The profile has a highlights carousel with its own "Next" and avatars.
    var runner = FakeRunner{ .start_url = "{\"url\":\"http://127.0.0.1:9/sam.example/\"}" };
    defer runner.deinit();
    try std.testing.expect((try instagram.storyView(gpa, &runner, fixture_site, "sam.example")) == null);
    try std.testing.expectEqualStrings("instagram_no_story_viewer", runner.not_found.?);
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "page.url" });
}

test "story_view checks the URL's path, not a substring (?next=/stories/... is a profile)" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    var runner = FakeRunner{ .start_url = "{\"url\":\"http://127.0.0.1:9/sam.example/?next=/stories/sam.example/\"}" };
    defer runner.deinit();
    try std.testing.expect((try instagram.storyView(gpa, &runner, fixture_site, "sam.example")) == null);
    try std.testing.expectEqualStrings("instagram_no_story_viewer", runner.not_found.?);
    try std.testing.expect(instagram.isStoryUrl("https://www.instagram.com/stories/sam.example/3141/"));
    try std.testing.expect(!instagram.isStoryUrl("https://www.instagram.com/stories/"));
    try std.testing.expect(!instagram.isStoryUrl("https://www.instagram.com/sam.example/#/stories/x/"));
}

test "viewStoryFrames stops when Instagram moves on to another person's stories: only the requested user's frames are viewed" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    var runner = FakeRunner{ .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/stories/riley.sample/3141/\"}" }} };
    defer runner.deinit();
    const result = (try instagram.viewStoryFrames(gpa, &runner, fixture_site, "sam.example")).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", result);
    try expectMethods(&runner, &.{ "dom.waitFor", "dom.query", "dom.click", "page.url" });
    // The owner's own later frames (/stories/<user>/<id>/) keep going; the
    // match ignores case, as Instagram's paths do.
    try std.testing.expect(instagram.isStoryOf("https://www.instagram.com/stories/sam.example/3141/", "sam.example"));
    try std.testing.expect(instagram.isStoryOf("https://www.instagram.com/stories/Sam.Example/", "sam.example"));
    try std.testing.expect(!instagram.isStoryOf("https://www.instagram.com/stories/sam.example.two/", "sam.example"));
    try std.testing.expect(!instagram.isStoryOf("https://www.instagram.com/stories/sam/", "sam.example"));
    try std.testing.expect(!instagram.isStoryOf("https://www.instagram.com/sam.example/", "sam.example"));
}

test "story_view never picks one of several Next buttons (a carousel's Next beside the viewer's): fails closed" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.query", .contains = "Next", .result = "{\"elements\":[{\"id\":\"a\",\"tag\":\"button\",\"text\":\"\",\"bbox\":{}},{\"id\":\"b\",\"tag\":\"button\",\"text\":\"\",\"bbox\":{}}]}" }} };
    defer runner.deinit();
    try std.testing.expect((try instagram.viewStoryFrames(gpa, &runner, fixture_site, "sam.example")) == null);
    try std.testing.expectEqualStrings("instagram_story_next_ambiguous", runner.not_found.?);
    for (runner.steps.items) |st| try std.testing.expect(!std.mem.eql(u8, st.method, "dom.click"));
}

test "story_view clicks Next strictly (exactly one)" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    var runner = FakeRunner{ .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/sam.example/\"}" }} };
    defer runner.deinit();
    gpa.free((try instagram.viewStoryFrames(gpa, &runner, fixture_site, "sam.example")).?);
    for (runner.steps.items) |st| {
        if (std.mem.eql(u8, st.method, "dom.click")) try std.testing.expect(std.mem.indexOf(u8, st.params, "\"strict\":true") != null);
    }
}

test "usernames and URLs are validated before any step" {
    var runner = FakeRunner{};
    defer runner.deinit();
    for ([_][]const u8{ "", "a/b", "sam example", "x" ** 31, "../etc" }) |bad| {
        try std.testing.expectError(error.InvalidParams, instagram.storyView(gpa, &runner, instagram.site, bad));
    }
    for ([_][]const u8{ "instagram.com/sam", "https://www.instagram.com.evil.example/sam/", "https://evil@www.instagram.com/sam/", "http://www.instagram.com/sam/", "https://www.linkedin.com/in/sam/", "https://www.instagram.com:444/sam/" }) |bad| {
        try std.testing.expectError(error.InvalidParams, instagram.follow(gpa, &runner, instagram.site, bad));
    }
    try std.testing.expectError(error.InvalidParams, instagram.dm(gpa, &runner, instagram.site, "sam", ""));
    try std.testing.expectEqual(@as(usize, 0), runner.steps.items.len);
}

test "selfcheck reports every selector-table entry, read-only" {
    var runner = FakeRunner{ .start_url = story_page };
    defer runner.deinit();
    const result = (try instagram.selfCheck(gpa, &runner)).?;
    defer gpa.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@typeInfo(instagram.selectors).@"struct".decls.len, parsed.value.object.count());
    // Read-only: the URL, then queries.
    try std.testing.expectEqualStrings("page.url", runner.steps.items[0].method);
    for (runner.steps.items[1..]) |s| try std.testing.expectEqualStrings("dom.query", s.method);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("story_next").?.integer);
}

test "selfcheck off the story viewer reports the story entries as 0 without querying them (highlights would match)" {
    var runner = FakeRunner{ .start_url = "{\"url\":\"https://www.instagram.com/sam.example/\"}" };
    defer runner.deinit();
    const result = (try instagram.selfCheck(gpa, &runner)).?;
    defer gpa.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@typeInfo(instagram.selectors).@"struct".decls.len, parsed.value.object.count());
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("story_media").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("story_next").?.integer);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("follow_button").?.integer);
    for (runner.steps.items) |s| {
        if (std.mem.eql(u8, s.method, "dom.query")) {
            try std.testing.expect(std.mem.indexOf(u8, s.params, "Next") == null);
            try std.testing.expect(std.mem.indexOf(u8, s.params, "section video") == null);
        }
    }
}
