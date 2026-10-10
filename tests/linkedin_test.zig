//! N16: LinkedIn flows as sequences of page.*/dom.* steps (src/linkedin.zig).
const std = @import("std");
const linkedin = @import("linkedin");

const gpa = std.testing.allocator;

const Step = struct { method: []u8, params: []u8 };

/// Scripted answer: the first rule whose method matches and whose `contains`
/// occurs in the params wins. `result = null` fails the step.
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

const profile = "https://www.linkedin.com/in/ada-lovelace/";

test "method table: every linkedin.* the SDKs send, nothing else" {
    for ([_][]const u8{ "visit", "connect", "message", "like", "comment", "follow", "search", "extract", "selfcheck" }) |name| {
        var buf: [32]u8 = undefined;
        const method = try std.fmt.bufPrint(&buf, "linkedin.{s}", .{name});
        try std.testing.expect(linkedin.verbFromMethod(method) != null);
    }
    try std.testing.expect(linkedin.verbFromMethod("linkedin.post") == null);
    try std.testing.expect(linkedin.verbFromMethod("instagram.follow") == null);
    try std.testing.expect(!linkedin.isAction(.extract) and !linkedin.isAction(.selfcheck));
    try std.testing.expect(linkedin.isAction(.connect) and linkedin.isAction(.search));
}

test "visit: navigate, login gate, ok" {
    var runner = FakeRunner{};
    defer runner.deinit();
    const result = (try linkedin.visit(gpa, &runner, linkedin.site, profile)).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"ok\":true}", result);
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor" });
    try expectSelector(&runner, 0, profile);
    try expectSelector(&runner, 1, linkedin.selectors.signed_in);
}

test "logged out (no signed-in marker, a sign-in link): LoggedOut, nothing clicked" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.waitFor", .result = null }} };
    defer runner.deinit();
    try std.testing.expectError(error.LoggedOut, linkedin.connect(gpa, &runner, linkedin.site, profile, null));
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "dom.query" });
    try expectSelector(&runner, 2, linkedin.selectors.login_link);
}

test "no signed-in marker and no sign-in link: the wait failure stands (null)" {
    var runner = FakeRunner{ .rules = &.{
        .{ .method = "dom.waitFor", .result = null },
        .{ .method = "dom.query", .result = "{\"elements\":[]}" },
    } };
    defer runner.deinit();
    try std.testing.expect((try linkedin.follow(gpa, &runner, linkedin.site, profile)) == null);
}

test "connect without a note: Connect, Send without a note, wait for Pending" {
    var runner = FakeRunner{};
    defer runner.deinit();
    const result = (try linkedin.connect(gpa, &runner, linkedin.site, profile, null)).?;
    gpa.free(result);
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.click", "dom.waitFor" });
    try expectSelector(&runner, 2, linkedin.selectors.connect_button);
    try expectSelector(&runner, 3, linkedin.selectors.send_without_note_button);
    try expectSelector(&runner, 4, linkedin.selectors.pending_button);
}

test "connect with a note: Add a note, type it (never fill it), Send; notes over 300 characters are truncated (C42)" {
    var runner = FakeRunner{};
    defer runner.deinit();
    const result = (try linkedin.connect(gpa, &runner, linkedin.site, profile, "Hi Ada, loved your notes on the Engine.")).?;
    gpa.free(result);
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.click", "dom.click", "dom.fill", "dom.type", "dom.click", "dom.waitFor" });
    try expectSelector(&runner, 3, linkedin.selectors.add_note_button);
    try expectSelector(&runner, 4, linkedin.selectors.note_input);
    // fill only clears; the note text goes through dom.type.
    try std.testing.expect(std.mem.indexOf(u8, runner.steps.items[5].params, "\"value\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner.steps.items[6].params, "loved your notes") != null);
    for (runner.steps.items) |st| {
        if (std.mem.eql(u8, st.method, "dom.fill")) try std.testing.expect(std.mem.indexOf(u8, st.params, "loved") == null);
    }
    try expectSelector(&runner, 7, linkedin.selectors.send_invite_button);

    var long = FakeRunner{};
    defer long.deinit();
    gpa.free((try linkedin.connect(gpa, &long, linkedin.site, profile, "é" ** 301)).?);
    const typed = try std.json.parseFromSlice(std.json.Value, gpa, long.steps.items[6].params, .{});
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 300), try std.unicode.utf8CountCodepoints(typed.value.object.get("text").?.string));
    try std.testing.expectEqualStrings("é" ** 300, linkedin.truncateNote("é" ** 301));
    try std.testing.expectEqualStrings("short", linkedin.truncateNote("short"));

    var strict = FakeRunner{};
    defer strict.deinit();
    try std.testing.expectError(error.InvalidParams, linkedin.connect(gpa, &strict, linkedin.site, profile, "   "));
    try std.testing.expectEqual(@as(usize, 0), strict.steps.items.len);
}

test "message: in a conversation, or from a profile's Message button" {
    var conv = FakeRunner{};
    defer conv.deinit();
    const a = (try linkedin.message(gpa, &conv, linkedin.site, .{ .conversation_url = "https://www.linkedin.com/messaging/thread/2-abc/" }, "Hello there")).?;
    gpa.free(a);
    try expectMethods(&conv, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.fill", "dom.type", "dom.click" });
    try expectSelector(&conv, 2, linkedin.selectors.message_input);
    try expectSelector(&conv, 5, linkedin.selectors.message_send_button);

    var prof = FakeRunner{};
    defer prof.deinit();
    const b = (try linkedin.message(gpa, &prof, linkedin.site, .{ .profile_url = profile }, "Hello there")).?;
    gpa.free(b);
    try expectSelector(&prof, 2, linkedin.selectors.message_button);
}

test "like waits for the pressed state; comment types into the comment box; follow waits for Following" {
    var l = FakeRunner{};
    defer l.deinit();
    gpa.free((try linkedin.like(gpa, &l, linkedin.site, "https://www.linkedin.com/feed/update/urn:li:activity:1/")).?);
    try expectMethods(&l, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.waitFor" });
    try expectSelector(&l, 3, linkedin.selectors.liked_button);

    var c = FakeRunner{};
    defer c.deinit();
    gpa.free((try linkedin.comment(gpa, &c, linkedin.site, "https://www.linkedin.com/feed/update/urn:li:activity:1/", "Great post")).?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.click", "dom.fill", "dom.type", "dom.click" });
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[4].params, "Great post") == null);
    try expectSelector(&c, 3, linkedin.selectors.comment_input);
    try expectSelector(&c, 6, linkedin.selectors.comment_submit);

    var f = FakeRunner{};
    defer f.deinit();
    gpa.free((try linkedin.follow(gpa, &f, linkedin.site, profile)).?);
    try expectSelector(&f, 2, linkedin.selectors.follow_button);
    try expectSelector(&f, 3, linkedin.selectors.following_button);
}

test "search builds the real URL from query and searchType (percent-encoded) and counts results" {
    const url = try linkedin.searchUrl(gpa, " Zig dev & café ", "people", linkedin.site.origin);
    defer gpa.free(url);
    try std.testing.expectEqualStrings("https://www.linkedin.com/search/results/people/?keywords=Zig%20dev%20%26%20caf%C3%A9", url);
    const companies = try linkedin.searchUrl(gpa, "anthropic", "companies", "http://127.0.0.1:9/");
    defer gpa.free(companies);
    try std.testing.expectEqualStrings("http://127.0.0.1:9/search/results/companies/?keywords=anthropic", companies);
    try std.testing.expectError(error.InvalidParams, linkedin.searchUrl(gpa, "x", "groups", linkedin.site.origin));
    try std.testing.expectError(error.InvalidParams, linkedin.searchUrl(gpa, "  ", "people", linkedin.site.origin));
    try std.testing.expectError(error.InvalidParams, linkedin.searchUrl(gpa, "x", "people", "ftp://example.com"));
    try std.testing.expectError(error.InvalidParams, linkedin.searchUrl(gpa, "x" ** 201, "people", linkedin.site.origin));
    try std.testing.expectError(error.InvalidParams, linkedin.searchUrl(gpa, "\xff\xfe", "people", linkedin.site.origin));

    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.query", .contains = "reusable-search", .result = "{\"elements\":[{\"id\":\"a\",\"tag\":\"li\",\"text\":\"\",\"bbox\":{}},{\"id\":\"b\",\"tag\":\"li\",\"text\":\"\",\"bbox\":{}}]}" }} };
    defer runner.deinit();
    const result = (try linkedin.search(gpa, &runner, linkedin.site, "zig", "people")).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"ok\":true,\"url\":\"https://www.linkedin.com/search/results/people/?keywords=zig\",\"resultCount\":2}", result);
}

test "extract: name, headline, location; absent optional fields are null" {
    var runner = FakeRunner{ .rules = &.{
        .{ .method = "dom.getText", .contains = "main h1", .result = "{\"text\":\" Ada Lovelace \"}" },
        .{ .method = "dom.getText", .contains = "text-body-medium", .result = "{\"text\":\"Analyst at the Analytical Engine\"}" },
        .{ .method = "dom.query", .contains = "t-black--light", .result = "{\"elements\":[]}" },
    } };
    defer runner.deinit();
    const result = (try linkedin.extract(gpa, &runner, linkedin.site, profile)).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"name\":\"Ada Lovelace\",\"headline\":\"Analyst at the Analytical Engine\",\"location\":null}", result);
    for (runner.steps.items) |s| try std.testing.expect(!std.mem.eql(u8, s.method, "dom.click"));
}

test "extract: an unusable getText answer is malformed" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.getText", .result = "{\"value\":1}" }} };
    defer runner.deinit();
    try std.testing.expect((try linkedin.extract(gpa, &runner, linkedin.site, profile)) == null);
    try std.testing.expectEqual(@as(usize, 1), runner.malformed_calls);
}

test "selfcheck reports every selector-table entry, read-only" {
    var runner = FakeRunner{};
    defer runner.deinit();
    const result = (try linkedin.selfCheck(gpa, &runner)).?;
    defer gpa.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@typeInfo(linkedin.selectors).@"struct".decls.len, parsed.value.object.count());
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("connect_button").?.integer);
    for (runner.steps.items) |s| try std.testing.expectEqualStrings("dom.query", s.method);
}

test "URLs must be on https://www.linkedin.com (C43): no other host, scheme, port, user info or lookalike" {
    var runner = FakeRunner{};
    defer runner.deinit();
    for ([_][]const u8{
        "linkedin.com/in/x",                         "ftp://www.linkedin.com/in/x",
        "http://www.linkedin.com/in/x",              "https:///in/x",
        "https://www.linkedin.com/in/a b/",          "",
        "https://evil.example/in/x",                 "https://www.linkedin.com.evil.example/in/x",
        "https://www.linkedin.com@evil.example/in/", "https://user@www.linkedin.com/in/x",
        "https://www.linkedin.com:8443/in/x",        "https://linkedin.com/in/x",
        "https://www.instagram.com/x/",              "https://www.linkedin.com",
        "https://wwwXlinkedin.com/in/x",             "https://www.linkedin.co/in/x",
    }) |bad| {
        try std.testing.expectError(error.InvalidParams, linkedin.visit(gpa, &runner, linkedin.site, bad));
    }
    try std.testing.expectEqual(@as(usize, 0), runner.steps.items.len);
    gpa.free((try linkedin.visit(gpa, &runner, linkedin.site, "https://WWW.LinkedIn.com/in/ada/")).?);

    // A fixture origin (server configuration, tests only) is accepted
    // exactly, nothing else is.
    var fixture_site = linkedin.site;
    fixture_site.fixture_origin = "http://127.0.0.1:41234";
    try std.testing.expect(fixture_site.allows("http://127.0.0.1:41234/in/ada/"));
    try std.testing.expect(!fixture_site.allows("http://127.0.0.1:41234.evil/in/ada/"));
    try std.testing.expect(!fixture_site.allows("http://127.0.0.1:4123/in/ada/"));
    try std.testing.expect(!linkedin.site.allows("http://127.0.0.1:41234/in/ada/"));
}

test "every step's timeout is clamped to the flow budget" {
    var runner = FakeRunner{ .budget_ms = 4_000 };
    defer runner.deinit();
    gpa.free((try linkedin.connect(gpa, &runner, linkedin.site, profile, "note")).?);
    for (runner.steps.items) |s| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, s.params, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const ms = if (obj.get("timeout_ms")) |t| t.integer else obj.get("options").?.object.get("timeout_ms").?.integer;
        try std.testing.expect(ms <= 4_000);
        if (std.mem.eql(u8, s.method, "dom.waitFor")) try std.testing.expect(ms <= 3_000);
    }
}
