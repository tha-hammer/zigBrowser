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
    not_found: ?[]const u8 = null,

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
        if (std.mem.eql(u8, method, "page.title")) return "{\"title\":\"Sam Example | LinkedIn\"}";
        if (std.mem.eql(u8, method, "page.url")) return "{\"url\":\"https://www.linkedin.com/in/sam-example/\"}";
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

const profile = "https://www.linkedin.com/in/sam-example/";

/// The profile's own actions, by their exact labels for "Sam Example", outside
/// any <aside> (suggestion cards); and the same labels anywhere on the page.
const own_connect = "xpath=//*[@aria-label=\"Invite Sam Example to connect\"][not(ancestor::aside)]";
const any_connect = "xpath=//*[@aria-label=\"Invite Sam Example to connect\"]";
const own_follow = "xpath=//*[@aria-label=\"Follow Sam Example\"][not(ancestor::aside)]";
const any_follow = "xpath=//*[@aria-label=\"Follow Sam Example\"]";
const own_message = "xpath=//*[@aria-label=\"Message Sam Example\"][not(ancestor::aside)]";
const own_pending = "xpath=//*[starts-with(@aria-label, \"Pending\") and contains(@aria-label, \"Sam Example\")][not(ancestor::aside)]";
const own_following = "xpath=//*[@aria-label=\"Following Sam Example\" or @aria-label=\"Unfollow Sam Example\"][not(ancestor::aside)]";
const no_elements = "{\"elements\":[]}";
const two_elements = "{\"elements\":[{\"id\":\"a\",\"tag\":\"button\",\"text\":\"\",\"bbox\":{}},{\"id\":\"b\",\"tag\":\"button\",\"text\":\"\",\"bbox\":{}}]}";

test "live markup (2026-10-11): hashed classes, so the signed-in marker is the nav's \"Me\" button" {
    // The top nav's (a "Me" button in page content must not count).
    try std.testing.expectEqualStrings("xpath=(//header | //nav)//button[normalize-space(.)=\"Me\"]", linkedin.selectors.signed_in);
    inline for (@typeInfo(linkedin.selectors).@"struct".decls) |decl| {
        const value: []const u8 = @field(linkedin.selectors, decl.name);
        try std.testing.expect(std.mem.indexOf(u8, value, "global-nav") == null);
        try std.testing.expect(std.mem.indexOf(u8, value, "react-button__trigger") == null);
        try std.testing.expect(std.mem.indexOf(u8, value, "main h1") == null);
    }
    try std.testing.expectEqualStrings("css=button[aria-label=\"Comment\"]", linkedin.selectors.comment_button);
    try std.testing.expectEqualStrings("css=button[aria-label=\"Repost\"]", linkedin.selectors.repost_button);
}

test "like: the first reaction button must say \"no reaction\"; liked when that same button no longer does" {
    try std.testing.expectEqualStrings(
        "xpath=(//button[starts-with(@aria-label, \"Reaction button state: \")])[1][@aria-label=\"Reaction button state: no reaction\"]",
        linkedin.selectors.like_button,
    );
    try std.testing.expectEqualStrings(
        "xpath=(//button[starts-with(@aria-label, \"Reaction button state: \")])[1][not(@aria-label=\"Reaction button state: no reaction\")]",
        linkedin.selectors.liked_button,
    );
}

test "the profile's own name comes from the title \"<Name> | LinkedIn\" (a notification count prefix is dropped)" {
    try std.testing.expectEqualStrings("Sam Example", linkedin.profileNameFromTitle("Sam Example | LinkedIn").?);
    try std.testing.expectEqualStrings("Sam Example", linkedin.profileNameFromTitle("(3) Sam Example | LinkedIn").?);
    try std.testing.expectEqualStrings("Sam Example", linkedin.profileNameFromTitle("  (12)  Sam Example  | LinkedIn ").?);
    try std.testing.expectEqualStrings("(Sam) Example", linkedin.profileNameFromTitle("(Sam) Example | LinkedIn").?);
    try std.testing.expect(linkedin.profileNameFromTitle("Feed | LinkedIn") != null); // not a name check
    try std.testing.expect(linkedin.profileNameFromTitle("LinkedIn") == null);
    try std.testing.expect(linkedin.profileNameFromTitle(" | LinkedIn") == null);
    try std.testing.expect(linkedin.profileNameFromTitle("(3)  | LinkedIn") == null);
    try std.testing.expect(linkedin.profileNameFromTitle("") == null);
    try std.testing.expect(linkedin.profileNameFromTitle("Sam\nExample | LinkedIn") == null);
}

test "a name with quotes becomes a valid XPath literal (XPath 1.0 has no escapes)" {
    const plain = try linkedin.profileSelector(gpa, .follow, "Sam O'Example", .document);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("xpath=//*[@aria-label=\"Follow Sam O'Example\"]", plain);
    const double = try linkedin.profileSelector(gpa, .follow, "Sam \"Q\" Example", .document);
    defer gpa.free(double);
    try std.testing.expectEqualStrings("xpath=//*[@aria-label='Follow Sam \"Q\" Example']", double);
    const both = try linkedin.profileSelector(gpa, .follow, "Sam \"Q\" O'E", .owner);
    defer gpa.free(both);
    try std.testing.expectEqualStrings("xpath=//*[@aria-label=concat('Follow Sam ', '\"', 'Q', '\"', ' O', \"'\", 'E')][not(ancestor::aside)]", both);
}

test "profile actions refuse a page that is not a profile (e.g. redirected to the feed): linkedin_not_a_profile, nothing clicked" {
    for ([_][]const u8{
        "{\"url\":\"https://www.linkedin.com/feed/\"}",
        "{\"url\":\"https://www.linkedin.com/in/\"}",
        "{\"url\":\"https://www.linkedin.com/company/in/x/\"}",
        // A profile path on another site (a cross-origin redirect).
        "{\"url\":\"https://evil.example/in/sam-example/\"}",
        "{\"url\":\"https://www.linkedin.com.evil.example/in/sam-example/\"}",
        "{\"url\":\"http://www.linkedin.com/in/sam-example/\"}",
    }) |answer| {
        var runner = FakeRunner{ .rules = &.{.{ .method = "page.url", .result = answer }} };
        defer runner.deinit();
        try std.testing.expect((try linkedin.follow(gpa, &runner, linkedin.site, profile)) == null);
        try std.testing.expectEqualStrings("linkedin_not_a_profile", runner.not_found.?);
        try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "page.url" });
    }
    try std.testing.expect(linkedin.isProfileUrl("https://www.linkedin.com/in/sam-example/"));
    try std.testing.expect(linkedin.isProfileUrl("http://127.0.0.1:9/in/sam/?x=1"));
    try std.testing.expect(!linkedin.isProfileUrl("https://www.linkedin.com/feed/?in/x"));
}

test "profile actions refuse a page whose title names nobody: element_not_found linkedin_profile_name_missing" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "page.title", .result = "{\"title\":\"LinkedIn\"}" }} };
    defer runner.deinit();
    try std.testing.expect((try linkedin.follow(gpa, &runner, linkedin.site, profile)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_name_missing", runner.not_found.?);
    try expectMethods(&runner, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title" });
}

// The scoped click itself (src/linkedin.zig clickProfileAction); the flows
// call it only once linkedin.owner_actions_enabled is on.

test "scoped click: own label outside any <aside>, exactly once, and nowhere else on the page -> strict click" {
    var runner = FakeRunner{};
    defer runner.deinit();
    try std.testing.expect(try linkedin.clickProfileAction(gpa, &runner, .connect, "Sam Example"));
    try expectMethods(&runner, &.{ "dom.waitFor", "dom.query", "dom.query", "dom.click" });
    try expectSelector(&runner, 0, own_connect);
    try expectSelector(&runner, 1, own_connect);
    try expectSelector(&runner, 2, any_connect);
    try expectSelector(&runner, 3, own_connect);
    try std.testing.expect(std.mem.indexOf(u8, runner.steps.items[3].params, "\"strict\":true") != null);
    try std.testing.expect(runner.not_found == null);
}

test "scoped click: the exact target never appears -> linkedin_profile_action_missing, nothing clicked" {
    var runner = FakeRunner{ .rules = &.{
        .{ .method = "dom.waitFor", .contains = "Invite Sam Example", .result = null },
        .{ .method = "dom.query", .contains = "Invite Sam Example", .result = no_elements },
    } };
    defer runner.deinit();
    try std.testing.expect(!(try linkedin.clickProfileAction(gpa, &runner, .connect, "Sam Example")));
    try std.testing.expectEqualStrings("linkedin_profile_action_missing", runner.not_found.?);
    try expectMethods(&runner, &.{ "dom.waitFor", "dom.query" });
}

test "scoped click: the own label twice -> linkedin_profile_action_ambiguous, nothing clicked" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.query", .contains = "Follow Sam Example", .result = two_elements }} };
    defer runner.deinit();
    try std.testing.expect(!(try linkedin.clickProfileAction(gpa, &runner, .follow, "Sam Example")));
    try std.testing.expectEqualStrings("linkedin_profile_action_ambiguous", runner.not_found.?);
    try expectMethods(&runner, &.{ "dom.waitFor", "dom.query", "dom.query" });
}

test "scoped click: a same-name card elsewhere on the page -> linkedin_profile_action_ambiguous, nothing clicked" {
    // Own region: one match; the whole page: two (a card for another person
    // with the same name).
    var runner = FakeRunner{ .rules = &.{
        .{ .method = "dom.query", .contains = "not(ancestor::aside)", .result = "{\"elements\":[{\"id\":\"a\",\"tag\":\"button\",\"text\":\"\",\"bbox\":{}}]}" },
        .{ .method = "dom.query", .contains = "Follow Sam Example", .result = two_elements },
    } };
    defer runner.deinit();
    try std.testing.expect(!(try linkedin.clickProfileAction(gpa, &runner, .follow, "Sam Example")));
    try std.testing.expectEqualStrings("linkedin_profile_action_ambiguous", runner.not_found.?);
    try expectSelector(&runner, 1, own_follow);
    try expectSelector(&runner, 2, any_follow);
    for (runner.steps.items) |st| try std.testing.expect(!std.mem.eql(u8, st.method, "dom.click"));
}

test "scoped click: a failed wait keeps its own failure when the target is there (e.g. cancelled); only a 0 count says missing" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.waitFor", .contains = "Follow Sam Example", .result = null }} };
    defer runner.deinit();
    try std.testing.expect(!(try linkedin.clickProfileAction(gpa, &runner, .follow, "Sam Example")));
    try std.testing.expect(runner.not_found == null);
    try expectMethods(&runner, &.{ "dom.waitFor", "dom.query" });
}

test "the profile's own state labels (after the click) are owner-scoped too" {
    const pending = try linkedin.profileSelector(gpa, .pending, "Sam Example", .owner);
    defer gpa.free(pending);
    try std.testing.expectEqualStrings(own_pending, pending);
    const following = try linkedin.profileSelector(gpa, .following, "Sam Example", .owner);
    defer gpa.free(following);
    try std.testing.expectEqualStrings(own_following, following);
    const message = try linkedin.profileSelector(gpa, .message, "Sam Example", .owner);
    defer gpa.free(message);
    try std.testing.expectEqualStrings(own_message, message);
}

test "until the owner area is verified live, connect/follow/message on a profile check the page, then refuse before any click" {
    try std.testing.expect(!linkedin.owner_actions_enabled);
    var c = FakeRunner{};
    defer c.deinit();
    try std.testing.expect((try linkedin.connect(gpa, &c, linkedin.site, profile, "hi")) == null);
    try std.testing.expectEqualStrings("linkedin_profile_owner_unverified", c.not_found.?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title" });

    var f = FakeRunner{};
    defer f.deinit();
    try std.testing.expect((try linkedin.follow(gpa, &f, linkedin.site, profile)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_owner_unverified", f.not_found.?);
    try expectMethods(&f, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title" });

    var m = FakeRunner{};
    defer m.deinit();
    try std.testing.expect((try linkedin.message(gpa, &m, linkedin.site, .{ .profile_url = profile }, "hi")) == null);
    try std.testing.expectEqualStrings("linkedin_profile_owner_unverified", m.not_found.?);
    try expectMethods(&m, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title" });

    // A conversation needs no profile owner.
    var conv = FakeRunner{};
    defer conv.deinit();
    gpa.free((try linkedin.message(gpa, &conv, linkedin.site, .{ .conversation_url = "https://www.linkedin.com/messaging/thread/2-abc/" }, "hi")).?);
}

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

test "the scoped flows as they will run once verified (tests: Site.unverified_actions): connect with a typed note, follow, profile message" {
    var verified = linkedin.site;
    verified.unverified_actions = true;

    var c = FakeRunner{};
    defer c.deinit();
    gpa.free((try linkedin.connect(gpa, &c, verified, profile, "Hi Sam, loved your notes on the engine.")).?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title", "dom.waitFor", "dom.query", "dom.query", "dom.click", "dom.click", "dom.click", "dom.fill", "dom.type", "dom.click", "dom.waitFor" });
    try expectSelector(&c, 7, own_connect);
    try expectSelector(&c, 8, linkedin.selectors.add_note_button);
    try expectSelector(&c, 9, linkedin.selectors.note_input);
    // fill only clears; the note text goes through dom.type.
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[10].params, "\"value\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[11].params, "loved your notes") != null);
    try expectSelector(&c, 12, linkedin.selectors.send_invite_button);
    try expectSelector(&c, 13, own_pending);

    var long = FakeRunner{};
    defer long.deinit();
    gpa.free((try linkedin.connect(gpa, &long, verified, profile, "é" ** 301)).?);
    const typed = try std.json.parseFromSlice(std.json.Value, gpa, long.steps.items[11].params, .{});
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 300), try std.unicode.utf8CountCodepoints(typed.value.object.get("text").?.string));

    var f = FakeRunner{};
    defer f.deinit();
    gpa.free((try linkedin.follow(gpa, &f, verified, profile)).?);
    try expectSelector(&f, 7, own_follow);
    try expectSelector(&f, 8, own_following);

    var m = FakeRunner{};
    defer m.deinit();
    gpa.free((try linkedin.message(gpa, &m, verified, .{ .profile_url = profile }, "Hello there")).?);
    try expectSelector(&m, 7, own_message);
    try expectSelector(&m, 8, linkedin.selectors.message_input);
}

test "connect: notes over 300 characters are truncated (C42); a blank note is refused before any step" {
    try std.testing.expectEqualStrings("é" ** 300, linkedin.truncateNote("é" ** 301));
    try std.testing.expectEqualStrings("short", linkedin.truncateNote("short"));
    var strict = FakeRunner{};
    defer strict.deinit();
    try std.testing.expectError(error.InvalidParams, linkedin.connect(gpa, &strict, linkedin.site, profile, "   "));
    try std.testing.expectEqual(@as(usize, 0), strict.steps.items.len);
}

test "message in a conversation: type into the message box and send" {
    var conv = FakeRunner{};
    defer conv.deinit();
    const a = (try linkedin.message(gpa, &conv, linkedin.site, .{ .conversation_url = "https://www.linkedin.com/messaging/thread/2-abc/" }, "Hello there")).?;
    gpa.free(a);
    try expectMethods(&conv, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.fill", "dom.type", "dom.click" });
    try expectSelector(&conv, 2, linkedin.selectors.message_input);
    try expectSelector(&conv, 5, linkedin.selectors.message_send_button);
}

test "like waits for the reacted state; comment types into the comment box" {
    var l = FakeRunner{};
    defer l.deinit();
    gpa.free((try linkedin.like(gpa, &l, linkedin.site, "https://www.linkedin.com/feed/update/urn:li:activity:1/")).?);
    try expectMethods(&l, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.waitFor" });
    try expectSelector(&l, 2, linkedin.selectors.like_button);
    try expectSelector(&l, 3, linkedin.selectors.liked_button);

    var c = FakeRunner{};
    defer c.deinit();
    gpa.free((try linkedin.comment(gpa, &c, linkedin.site, "https://www.linkedin.com/feed/update/urn:li:activity:1/", "Great post")).?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.click", "dom.fill", "dom.type", "dom.click" });
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[4].params, "Great post") == null);
    try expectSelector(&c, 3, linkedin.selectors.comment_input);
    try expectSelector(&c, 6, linkedin.selectors.comment_submit);
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

test "extract: name from the page title, headline, location; absent optional fields are null" {
    var runner = FakeRunner{ .rules = &.{
        .{ .method = "page.title", .result = "{\"title\":\"(2) Sam Example | LinkedIn\"}" },
        .{ .method = "dom.getText", .contains = "text-body-medium", .result = "{\"text\":\"Engineer at Example Co\"}" },
        .{ .method = "dom.query", .contains = "t-black--light", .result = "{\"elements\":[]}" },
    } };
    defer runner.deinit();
    const result = (try linkedin.extract(gpa, &runner, linkedin.site, profile)).?;
    defer gpa.free(result);
    try std.testing.expectEqualStrings("{\"name\":\"Sam Example\",\"headline\":\"Engineer at Example Co\",\"location\":null}", result);
    for (runner.steps.items) |s| try std.testing.expect(!std.mem.eql(u8, s.method, "dom.click"));
    try std.testing.expectEqualStrings("page.url", runner.steps.items[2].method);
    try std.testing.expectEqualStrings("page.title", runner.steps.items[3].method);
}

test "extract: a title naming nobody is linkedin_profile_name_missing" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "page.title", .result = "{\"title\":\"LinkedIn\"}" }} };
    defer runner.deinit();
    try std.testing.expect((try linkedin.extract(gpa, &runner, linkedin.site, profile)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_name_missing", runner.not_found.?);
}

test "extract: an unusable page.title or getText answer is malformed" {
    var bad_title = FakeRunner{ .rules = &.{.{ .method = "page.title", .result = "{\"value\":1}" }} };
    defer bad_title.deinit();
    try std.testing.expect((try linkedin.extract(gpa, &bad_title, linkedin.site, profile)) == null);
    try std.testing.expectEqual(@as(usize, 1), bad_title.malformed_calls);

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
    gpa.free((try linkedin.visit(gpa, &runner, linkedin.site, "https://WWW.LinkedIn.com/in/sam/")).?);

    // A fixture origin (server configuration, tests only) is accepted
    // exactly, nothing else is.
    var fixture_site = linkedin.site;
    fixture_site.fixture_origin = "http://127.0.0.1:41234";
    try std.testing.expect(fixture_site.allows("http://127.0.0.1:41234/in/sam/"));
    try std.testing.expect(!fixture_site.allows("http://127.0.0.1:41234.evil/in/sam/"));
    try std.testing.expect(!fixture_site.allows("http://127.0.0.1:4123/in/sam/"));
    try std.testing.expect(!linkedin.site.allows("http://127.0.0.1:41234/in/sam/"));
}

test "every step's timeout is clamped to the flow budget" {
    var runner = FakeRunner{ .budget_ms = 4_000 };
    defer runner.deinit();
    gpa.free((try linkedin.comment(gpa, &runner, linkedin.site, "https://www.linkedin.com/feed/update/urn:li:activity:1/", "note")).?);
    // The scoped click and the profile reads too.
    _ = try linkedin.clickProfileAction(gpa, &runner, .follow, "Sam Example");
    if (try linkedin.extract(gpa, &runner, linkedin.site, profile)) |result| gpa.free(result);
    for (runner.steps.items) |s| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, s.params, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const ms = if (obj.get("timeout_ms")) |t| t.integer else obj.get("options").?.object.get("timeout_ms").?.integer;
        try std.testing.expect(ms <= 4_000);
        if (std.mem.eql(u8, s.method, "dom.waitFor")) try std.testing.expect(ms <= 3_000);
    }
}
