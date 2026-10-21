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
    /// When set, the answers to page.url in order (the last one repeats);
    /// takes precedence over `rules`.
    urls: []const []const u8 = &.{},
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
            if (self.urls.len > 0) return self.urls[@min(self.url_calls, self.urls.len) - 1];
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
    // S8 decision 13's per-stage guards: no approval here, so none (flow_runner.Runner's are
    // no-ops without one too; tests/automation_recipient_guard_test.zig covers them).
    pub fn guardOpener(_: *FakeRunner, _: []const u8) error{OutOfMemory}!void {}
    pub fn guardThread(_: *FakeRunner, _: []const u8, _: []const u8) error{OutOfMemory}!void {}
    pub fn approvedRecipient(_: *const FakeRunner) ?[]const u8 {
        return null;
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
    // Exactly one visible state (RoseCat 7c9d68a).
    try std.testing.expect(std.mem.indexOf(u8, runner.steps.items[3].params, "\"state\":\"visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner.steps.items[3].params, "\"strict\":true") != null);
}

test "Following/Requested: a header button whose visible text (svg titles left out) is exactly that (live: \"Following\" plus a chevron svg titled \"Down chevron icon\")" {
    const visible = "[not(ancestor::*[name()=\"svg\"])]";
    try std.testing.expectEqualStrings(
        "xpath=//header//button[" ++
            "(.//text()" ++ visible ++ "[normalize-space(.)=\"Following\"] and not(.//text()" ++ visible ++ "[normalize-space(.)!=\"\" and normalize-space(.)!=\"Following\"]))" ++
            " or (.//text()" ++ visible ++ "[normalize-space(.)=\"Requested\"] and not(.//text()" ++ visible ++ "[normalize-space(.)!=\"\" and normalize-space(.)!=\"Requested\"]))]" ++
            "[not(ancestor-or-self::*[@aria-hidden=\"true\"])]",
        instagram.selectors.following_button,
    );
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
    var runner = FakeRunner{
        .urls = &.{ story_page, story_page, "{\"url\":\"http://127.0.0.1:9/sam.example/\"}" },
        .rules = &.{.{ .method = "dom.query", .contains = "View story", .result = "{\"elements\":[]}" }},
    };
    defer runner.deinit();
    const result = (try instagram.storyView(gpa, &runner, fixture_site, "sam.example")).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", result);
    // No "View story" button in front; whose story it is is checked before
    // Next is counted and clicked.
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "page.url", "dom.query", "dom.waitFor", "page.url", "dom.query", "dom.click", "page.url" });
    try expectSelector(&runner, 0, "http://127.0.0.1:9/stories/sam.example/");
    try expectSelector(&runner, 3, instagram.selectors.story_view_gate);
    try expectSelector(&runner, 4, instagram.selectors.story_media);
    try expectSelector(&runner, 7, instagram.selectors.story_next);

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
    var single = FakeRunner{ .start_url = story_page, .rules = &.{.{ .method = "dom.query", .contains = "Next", .result = "{\"elements\":[]}" }} };
    defer single.deinit();
    const one = (try instagram.viewStoryFrames(gpa, &single, fixture_site, "sam.example")).?;
    defer gpa.free(one);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", one);
    try expectMethods(&single, &.{ "dom.waitFor", "page.url", "dom.query" });
    try expectSelector(&single, 0, instagram.selectors.story_media);

    // Next closes the viewer (the page leaves /stories/): done after that frame.
    var leaving = FakeRunner{ .start_url = story_page, .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/sam.example/\"}" }} };
    defer leaving.deinit();
    const left = (try instagram.viewStoryFrames(gpa, &leaving, fixture_site, "sam.example")).?;
    defer gpa.free(left);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", left);
    // First frame viewed, Next, then the frame time in which the viewer closed.
    try std.testing.expectEqual(@as(u64, 2 * instagram.story_frame_ms), leaving.now_ms);

    // The last Next's click is cut short as the viewer closes (the URL
    // left /stories/): completion.
    var cut = FakeRunner{ .start_url = story_page, .rules = &.{
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
    var runner = FakeRunner{ .start_url = story_page, .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/stories/riley.sample/3141/\"}" }} };
    defer runner.deinit();
    const result = (try instagram.viewStoryFrames(gpa, &runner, fixture_site, "sam.example")).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", result);
    try expectMethods(&runner, &.{ "dom.waitFor", "page.url", "dom.query", "dom.click", "page.url" });
    // The owner's own later frames (/stories/<user>/<id>/) keep going; the
    // match ignores case, as Instagram's paths do.
    try std.testing.expect(instagram.isStoryOf("https://www.instagram.com/stories/sam.example/3141/", "sam.example"));
    try std.testing.expect(instagram.isStoryOf("https://www.instagram.com/stories/Sam.Example/", "sam.example"));
    try std.testing.expect(!instagram.isStoryOf("https://www.instagram.com/stories/sam.example.two/", "sam.example"));
    try std.testing.expect(!instagram.isStoryOf("https://www.instagram.com/stories/sam/", "sam.example"));
    try std.testing.expect(!instagram.isStoryOf("https://www.instagram.com/sam.example/", "sam.example"));
}

test "viewStoryFrames: Instagram moves on to another person BY ITSELF while a frame is viewed -> stop before counting or clicking Next (review 5046)" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    const riley = "{\"url\":\"http://127.0.0.1:9/stories/riley.sample/3141/\"}";
    // During the first frame's pause: nothing is counted or clicked.
    var first = FakeRunner{ .urls = &.{riley} };
    defer first.deinit();
    const one = (try instagram.viewStoryFrames(gpa, &first, fixture_site, "sam.example")).?;
    defer gpa.free(one);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", one);
    try expectMethods(&first, &.{ "dom.waitFor", "page.url" });

    // During a later frame's pause (after our Next showed the user's second
    // frame): exactly the one Next on the user's own story, none after.
    var later = FakeRunner{ .urls = &.{ story_page, story_page, riley } };
    defer later.deinit();
    const two = (try instagram.viewStoryFrames(gpa, &later, fixture_site, "sam.example")).?;
    defer gpa.free(two);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":2}", two);
    try expectMethods(&later, &.{ "dom.waitFor", "page.url", "dom.query", "dom.click", "page.url", "page.url" });
}

test "viewStoryFrames starts a Next only when the whole frame fits the flow budget: pre-check, Next query, click, view, post-check" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    // After the first frame's view: one frame (1.5 s), a click (10 s) and
    // three queries (5 s each: whose story, Next, whose story again).
    const fits = instagram.story_frame_ms + instagram.story_frame_ms + 10_000 + 3 * 5_000;
    var short = FakeRunner{ .budget_ms = fits - 1, .urls = &.{story_page} };
    defer short.deinit();
    const one = (try instagram.viewStoryFrames(gpa, &short, fixture_site, "sam.example")).?;
    defer gpa.free(one);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":1}", one);
    for (short.steps.items) |st| try std.testing.expect(!std.mem.eql(u8, st.method, "dom.click"));

    var enough = FakeRunner{ .budget_ms = fits + 1, .urls = &.{story_page} };
    defer enough.deinit();
    const two = (try instagram.viewStoryFrames(gpa, &enough, fixture_site, "sam.example")).?;
    defer gpa.free(two);
    try std.testing.expectEqualStrings("{\"ok\":true,\"framesViewed\":2}", two);
}

test "story_view never picks one of several Next buttons (a carousel's Next beside the viewer's): fails closed" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    var runner = FakeRunner{ .start_url = story_page, .rules = &.{.{ .method = "dom.query", .contains = "Next", .result = "{\"elements\":[{\"id\":\"a\",\"tag\":\"button\",\"text\":\"\",\"bbox\":{}},{\"id\":\"b\",\"tag\":\"button\",\"text\":\"\",\"bbox\":{}}]}" }} };
    defer runner.deinit();
    try std.testing.expect((try instagram.viewStoryFrames(gpa, &runner, fixture_site, "sam.example")) == null);
    try std.testing.expectEqualStrings("instagram_story_next_ambiguous", runner.not_found.?);
    for (runner.steps.items) |st| try std.testing.expect(!std.mem.eql(u8, st.method, "dom.click"));
}

test "story_view clicks Next strictly (exactly one)" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    var runner = FakeRunner{ .start_url = story_page, .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"http://127.0.0.1:9/sam.example/\"}" }} };
    defer runner.deinit();
    gpa.free((try instagram.viewStoryFrames(gpa, &runner, fixture_site, "sam.example")).?);
    var clicks: usize = 0;
    for (runner.steps.items) |st| {
        if (std.mem.eql(u8, st.method, "dom.click")) clicks += 1;
        if (std.mem.eql(u8, st.method, "dom.click")) try std.testing.expect(std.mem.indexOf(u8, st.params, "\"strict\":true") != null);
    }
    try std.testing.expectEqual(@as(usize, 1), clicks);
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

// ---- Dry run (options.dry_run): everything up to the committing click ----

/// No step of a dry run may act on the page: only dom.click trials, reads
/// and waits; and no frame is viewed (no pause).
fn expectNoInput(runner: *const FakeRunner) !void {
    for (runner.steps.items) |st| {
        for ([_][]const u8{ "dom.fill", "dom.type", "dom.press", "dom.selectOption", "dom.setInputFiles", "dom.hover", "dom.scroll" }) |m| {
            try std.testing.expect(!std.mem.eql(u8, st.method, m));
        }
        if (std.mem.eql(u8, st.method, "dom.click")) {
            try std.testing.expect(std.mem.indexOf(u8, st.params, "\"trial\":true") != null);
        }
    }
    try std.testing.expectEqual(@as(u64, 0), runner.now_ms);
}

const button_box = "{\"elements\":[{\"id\":\"e\",\"tag\":\"button\",\"text\":\"Follow\",\"bbox\":{\"x\":10,\"y\":20,\"width\":80,\"height\":32}}]}";

test "dry run follow: trial on the header's Follow, its tag and box, nothing clicked" {
    var r = FakeRunner{ .rules = &.{.{ .method = "dom.query", .contains = "Follow", .result = button_box }} };
    defer r.deinit();
    const result = (try instagram.dryRun(gpa, &r, instagram.site, .follow, profile)).?;
    defer gpa.free(result);
    try expectMethods(&r, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.query" });
    try expectSelector(&r, 2, instagram.selectors.follow_button);
    try std.testing.expect(std.mem.indexOf(u8, r.steps.items[2].params, "\"strict\":true") != null);
    try expectNoInput(&r);
    try std.testing.expectEqualStrings(
        "{\"dry_run\":true,\"would_act\":\"follow\",\"target\":{\"tag\":\"button\",\"label\":\"Follow\",\"box\":{\"x\":10,\"y\":20,\"width\":80,\"height\":32}}," ++
            "\"checks\":[{\"name\":\"signed_in\",\"result\":\"pass\"},{\"name\":\"actionable\",\"result\":\"pass\"}," ++
            "{\"name\":\"following_state\",\"result\":\"not_reached\",\"reason\":\"appears only after the Follow click\"}]}",
        result,
    );
}

test "dry run like and comment: trials only; comment never focuses, clears or types into the comment box" {
    var l = FakeRunner{};
    defer l.deinit();
    const liked = (try instagram.dryRun(gpa, &l, instagram.site, .like, post)).?;
    defer gpa.free(liked);
    try expectMethods(&l, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.query" });
    try expectSelector(&l, 2, instagram.selectors.like_button);
    try expectNoInput(&l);
    try std.testing.expect(std.mem.indexOf(u8, liked, "\"would_act\":\"like\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, liked, "\"label\":\"Like\"") != null);

    var c = FakeRunner{};
    defer c.deinit();
    const commented = (try instagram.dryRun(gpa, &c, instagram.site, .comment, post)).?;
    defer gpa.free(commented);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.query", "dom.query" });
    try expectSelector(&c, 2, instagram.selectors.comment_input);
    try expectSelector(&c, 4, instagram.selectors.comment_submit);
    try expectNoInput(&c);
    try std.testing.expect(std.mem.indexOf(u8, commented, "\"would_act\":\"comment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, commented, "{\"name\":\"post_button\",\"result\":\"pass\",\"count\":1}") != null);

    // Fails closed like the real flow: logged out, a failed trial.
    var out = FakeRunner{ .rules = &.{.{ .method = "dom.waitFor", .result = null }} };
    defer out.deinit();
    try std.testing.expectError(error.LoggedOut, instagram.dryRun(gpa, &out, instagram.site, .like, post));
    var covered = FakeRunner{ .rules = &.{.{ .method = "dom.click", .result = null }} };
    defer covered.deinit();
    try std.testing.expect((try instagram.dryRun(gpa, &covered, instagram.site, .follow, profile)) == null);
    try expectNoInput(&covered);
    var off = FakeRunner{};
    defer off.deinit();
    try std.testing.expectError(error.InvalidParams, instagram.dryRun(gpa, &off, instagram.site, .like, "https://evil.example/p/C0ffee/"));
    try std.testing.expectEqual(@as(usize, 0), off.steps.items.len);
}

test "dry run story_view: the real flow's checks (whose story, media), a trial on the one Next; no frame viewed, Next never clicked" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    var r = FakeRunner{
        .urls = &.{story_page},
        .rules = &.{.{ .method = "dom.query", .contains = "View story", .result = "{\"elements\":[]}" }},
    };
    defer r.deinit();
    const result = (try instagram.dryRun(gpa, &r, fixture_site, .story_view, "sam.example")).?;
    defer gpa.free(result);
    try expectMethods(&r, &.{ "page.navigate", "dom.waitFor", "page.url", "dom.query", "dom.waitFor", "dom.query", "dom.click", "dom.query" });
    try expectSelector(&r, 0, "http://127.0.0.1:9/stories/sam.example/");
    try expectSelector(&r, 3, instagram.selectors.story_view_gate);
    try expectSelector(&r, 4, instagram.selectors.story_media);
    try expectSelector(&r, 5, instagram.selectors.story_next);
    try expectSelector(&r, 6, instagram.selectors.story_next);
    try expectNoInput(&r);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"would_act\":\"story_view\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"label\":\"Next\"") != null);
    // Opening the story is the real flow's own first step: said, not hidden.
    try std.testing.expect(std.mem.indexOf(u8, result, "{\"name\":\"first_frame\",\"result\":\"note\",\"reason\":\"opened by the flow's own navigation; Instagram may count it as seen\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "sam.example") == null);
}

test "dry run story_view: a \"View story\" button (viewing needs a click that marks the story seen) stops the dry run before it, with the reason" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    var r = FakeRunner{ .urls = &.{story_page}, .rules = &.{.{ .method = "dom.query", .contains = "View story", .result = button_box }} };
    defer r.deinit();
    const result = (try instagram.dryRun(gpa, &r, fixture_site, .story_view, "sam.example")).?;
    defer gpa.free(result);
    try expectMethods(&r, &.{ "page.navigate", "dom.waitFor", "page.url", "dom.query" });
    try expectNoInput(&r);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"target\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "{\"name\":\"view_story_click\",\"result\":\"not_reached\",\"reason\":\"instagram_story_view_needs_click: opening the viewer needs a click that marks the story seen\"}") != null);
}

test "dry run story_view fails closed like the real flow: not the user's story, several Next; no Next = one frame, no target" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    var other = FakeRunner{ .urls = &.{"{\"url\":\"http://127.0.0.1:9/stories/riley.sample/\"}"} };
    defer other.deinit();
    try std.testing.expect((try instagram.dryRun(gpa, &other, fixture_site, .story_view, "sam.example")) == null);
    try std.testing.expectEqualStrings("instagram_no_story_viewer", other.not_found.?);
    try expectMethods(&other, &.{ "page.navigate", "dom.waitFor", "page.url" });

    const two = "{\"elements\":[{\"id\":\"a\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{}},{\"id\":\"b\",\"tag\":\"div\",\"text\":\"\",\"bbox\":{}}]}";
    var many = FakeRunner{ .urls = &.{story_page}, .rules = &.{
        .{ .method = "dom.query", .contains = "View story", .result = "{\"elements\":[]}" },
        .{ .method = "dom.query", .contains = "Next", .result = two },
    } };
    defer many.deinit();
    try std.testing.expect((try instagram.dryRun(gpa, &many, fixture_site, .story_view, "sam.example")) == null);
    try std.testing.expectEqualStrings("instagram_story_next_ambiguous", many.not_found.?);
    try expectNoInput(&many);

    var single = FakeRunner{ .urls = &.{story_page}, .rules = &.{
        .{ .method = "dom.query", .contains = "View story", .result = "{\"elements\":[]}" },
        .{ .method = "dom.query", .contains = "Next", .result = "{\"elements\":[]}" },
    } };
    defer single.deinit();
    const result = (try instagram.dryRun(gpa, &single, fixture_site, .story_view, "sam.example")).?;
    defer gpa.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"target\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "{\"name\":\"next\",\"result\":\"pass\",\"count\":0,\"reason\":\"no Next: the real flow views one frame and stops\"}") != null);
    try expectNoInput(&single);
}

test "story_view (real) stops before a \"View story\" button too: instagram_story_view_needs_click, nothing clicked, no frame viewed" {
    var fixture_site = instagram.site;
    fixture_site.fixture_origin = "http://127.0.0.1:9";
    var r = FakeRunner{ .urls = &.{story_page}, .rules = &.{.{ .method = "dom.query", .contains = "View story", .result = button_box }} };
    defer r.deinit();
    try std.testing.expect((try instagram.storyView(gpa, &r, fixture_site, "sam.example")) == null);
    try std.testing.expectEqualStrings("instagram_story_view_needs_click", r.not_found.?);
    try expectMethods(&r, &.{ "page.navigate", "dom.waitFor", "page.url", "dom.query" });
    try expectSelector(&r, 3, instagram.selectors.story_view_gate);
    try std.testing.expectEqual(@as(u64, 0), r.now_ms);
}

// RoseCat's audit 7c9d68a: an icon's <title> is text too, so text-only
// controls match by their visible text (svg titles left out), exactly.
fn visibleIs(comptime text: []const u8) []const u8 {
    const v = ".//text()[not(ancestor::*[name()=\"svg\"])]";
    return "(" ++ v ++ "[normalize-space(.)=\"" ++ text ++ "\"] and not(" ++ v ++ "[normalize-space(.)!=\"\" and normalize-space(.)!=\"" ++ text ++ "\"]))";
}

const vis_send = visibleIs("Send");
const vis_follow = visibleIs("Follow");
const vis_message = visibleIs("Message");
const vis_post = visibleIs("Post");
const vis_view_story = visibleIs("View story");

test "DM Send (audit HIGH, RoseCat 5194): only inside the DM box's own container (its parent), never found by walking up to any Send" {
    const clickable = "*[self::button or @role=\"button\"]";
    const input = "//div[@aria-label=\"Message\"][@contenteditable=\"true\"]";
    try std.testing.expectEqualStrings(
        "xpath=(" ++ input ++ ")/parent::*//" ++ clickable ++ "[" ++ vis_send ++ "][not(ancestor-or-self::*[@aria-hidden=\"true\"])]",
        instagram.selectors.dm_send,
    );
    // No "contains a Send" walk: the container does not depend on a Send.
    try std.testing.expect(std.mem.indexOf(u8, instagram.selectors.dm_send, "ancestor::*[.//") == null);
}

test "the View story stop gate (audit HIGH) matches its visible text anywhere (svg titles left out): a stop check may over-detect, never under-detect" {
    try std.testing.expectEqualStrings(
        "xpath=//*[self::button or @role=\"button\"][" ++ vis_view_story ++ "]",
        instagram.selectors.story_view_gate,
    );
}

test "audit MED: Follow and Message in the owner header, and the comment's Post in the comment box's own form, by visible text (svg titles left out)" {
    const shown = "[not(ancestor-or-self::*[@aria-hidden=\"true\"])]";
    try std.testing.expectEqualStrings("xpath=//header//button[" ++ vis_follow ++ "]" ++ shown, instagram.selectors.follow_button);
    try std.testing.expectEqualStrings("xpath=//header//*[self::button or @role=\"button\"][" ++ vis_message ++ "]" ++ shown, instagram.selectors.message_button);
    try std.testing.expectEqualStrings(
        "xpath=//form[.//textarea[@aria-label=\"Add a comment\u{2026}\"]]//*[self::button or @role=\"button\"][" ++ vis_post ++ "]" ++ shown,
        instagram.selectors.comment_submit,
    );
}
