//! N16: LinkedIn flows as sequences of page.*/dom.* steps (src/linkedin.zig).
const std = @import("std");
const linkedin = @import("linkedin");

const gpa = std.testing.allocator;

const Step = struct { method: []u8, params: []u8 };

/// Scripted answer: the first rule whose method matches and whose `contains`
/// occurs in the params wins. `result = null` fails the step. A rule with
/// `uses` answers only that many times, then is skipped.
const Rule = struct { method: []const u8, contains: []const u8 = "", result: ?[]const u8, uses: ?usize = null };

const FakeRunner = struct {
    steps: std.ArrayListUnmanaged(Step) = .empty,
    rules: []const Rule = &.{},
    now_ms: u64 = 0,
    budget_ms: u64 = 120_000,
    malformed_calls: usize = 0,
    not_found: ?[]const u8 = null,
    used: [32]usize = [_]usize{0} ** 32,
    /// The last answer, owned: like the real runner's, it is only valid
    /// until the next step (then poisoned and freed).
    last: ?[]u8 = null,

    fn deinit(self: *FakeRunner) void {
        self.dropLast();
        for (self.steps.items) |s| {
            gpa.free(s.method);
            gpa.free(s.params);
        }
        self.steps.deinit(gpa);
    }

    fn dropLast(self: *FakeRunner) void {
        if (self.last) |l| {
            @memset(l, 0xAA);
            gpa.free(l);
        }
        self.last = null;
    }

    pub fn run(self: *FakeRunner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        self.dropLast();
        const reply = (try self.answer(method, params_json)) orelse return null;
        self.last = try gpa.dupe(u8, reply);
        return self.last.?;
    }

    fn answer(self: *FakeRunner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        try self.steps.append(gpa, .{ .method = try gpa.dupe(u8, method), .params = try gpa.dupe(u8, params_json) });
        for (self.rules, 0..) |rule, i| {
            if (!std.mem.eql(u8, rule.method, method) or std.mem.indexOf(u8, params_json, rule.contains) == null) continue;
            if (rule.uses) |n| {
                if (self.used[i] >= n) continue;
                self.used[i] += 1;
            }
            return rule.result;
        }
        if (std.mem.eql(u8, method, "dom.query")) return one_element;
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
    // S8 decision 13's per-stage guards: no approval here, so none (flow_runner.Runner's are
    // no-ops without one too; tests/automation_recipient_guard_test.zig covers them).
    pub fn guardOpener(_: *FakeRunner, _: []const u8, _: anytype) error{OutOfMemory}!void {}
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

const profile = "https://www.linkedin.com/in/sam-example/";

/// The profile's own actions, by their exact labels for "Sam Example", inside
/// the profile's own action area (linkedin.owner_container, pinned from the
/// live probe v2) and under no aria-hidden element.
const area = linkedin.owner_container;
const owner_area = "xpath=" ++ area;
const shown = "[not(ancestor-or-self::*[@aria-hidden=\"true\"])]";
const own_connect = "xpath=" ++ area ++ "//*[@aria-label=\"Invite Sam Example to connect\"]" ++ shown;
const own_connect_2 = "xpath=(" ++ area ++ "//*[@aria-label=\"Invite Sam Example to connect\"]" ++ shown ++ ")[2]";
const own_follow = "xpath=" ++ area ++ "//*[@aria-label=\"Follow Sam Example\"]" ++ shown;
const own_message = "xpath=" ++ area ++ "//*[@aria-label=\"Message Sam Example\"]" ++ shown;
const own_pending = "xpath=" ++ area ++ "//*[starts-with(@aria-label, \"Pending\") and contains(@aria-label, \"Sam Example\")]" ++ shown;
/// Live (the orchestrator's real Connect, 2026-10-11): "Following, click to
/// unfollow <Name>".
const own_following = "xpath=" ++ area ++ "//*[(starts-with(@aria-label, \"Following\") or starts-with(@aria-label, \"Unfollow\")) and contains(@aria-label, \"Sam Example\")]" ++ shown;
/// The owner's More button (live: two in the owner area, one of them hidden)
/// and the Connect item of the menu it opens.
const more_path = "//button[" ++ more_text ++ " or @aria-label=\"More\" or @aria-label=\"More actions\"]" ++ shown;
/// Visible text (svg titles left out) exactly "More" (audit 7c9d68a).
const more_text = "(.//text()[not(ancestor::*[name()=\"svg\"])][normalize-space(.)=\"More\"] and " ++
    "not(.//text()[not(ancestor::*[name()=\"svg\"])][normalize-space(.)!=\"\" and normalize-space(.)!=\"More\"]))";
const own_more = "xpath=" ++ area ++ more_path;
const own_more_2 = "xpath=(" ++ area ++ more_path ++ ")[2]";
/// What a Connect waits for first: the owner's own Connect, or their More.
const connect_or_more = "xpath=" ++ area ++ "//*[@aria-label=\"Invite Sam Example to connect\"]" ++ shown ++ " | " ++ area ++ more_path;
const menu_connect = linkedin.selectors.more_menu_connect;
/// Checked before the owner's More is clicked: any open menu, or a menu
/// Connect item already shown (RoseCat 5157).
const menu_open = linkedin.selectors.open_menu_or_item;
const visible_box = "{\"x\":56,\"y\":513,\"width\":97,\"height\":48}";
const hidden_box = "{\"x\":0,\"y\":0,\"width\":0,\"height\":0}";
const one_element = "{\"elements\":[{\"id\":\"a\",\"tag\":\"a\",\"text\":\"\",\"bbox\":" ++ visible_box ++ "}]}";
/// Live (probe v2): a display:none copy, then the visible one.
const hidden_then_visible = "{\"elements\":[{\"id\":\"a\",\"tag\":\"a\",\"text\":\"\",\"bbox\":" ++ hidden_box ++ "},{\"id\":\"b\",\"tag\":\"a\",\"text\":\"\",\"bbox\":" ++ visible_box ++ "}]}";
const all_hidden = "{\"elements\":[{\"id\":\"a\",\"tag\":\"a\",\"text\":\"\",\"bbox\":" ++ hidden_box ++ "},{\"id\":\"b\",\"tag\":\"a\",\"text\":\"\",\"bbox\":" ++ hidden_box ++ "}]}";
const no_elements = "{\"elements\":[]}";
const two_elements = "{\"elements\":[{\"id\":\"a\",\"tag\":\"button\",\"text\":\"\",\"bbox\":" ++ visible_box ++ "},{\"id\":\"b\",\"tag\":\"button\",\"text\":\"\",\"bbox\":" ++ visible_box ++ "}]}";

test "live markup (2026-10-11): hashed classes, so the signed-in marker is the nav's \"Me\" button" {
    // The top nav's (a "Me" button in page content must not count).
    // By its visible text: a badge or icon <title> is text too (audit 7c9d68a).
    try std.testing.expectEqualStrings("xpath=(//header | //nav)//button[(.//text()[not(ancestor::*[name()=\"svg\"])][normalize-space(.)=\"Me\"] and " ++
        "not(.//text()[not(ancestor::*[name()=\"svg\"])][normalize-space(.)!=\"\" and normalize-space(.)!=\"Me\"]))]", linkedin.selectors.signed_in);
    inline for (@typeInfo(linkedin.selectors).@"struct".decls) |decl| {
        const value: []const u8 = @field(linkedin.selectors, decl.name);
        try std.testing.expect(std.mem.indexOf(u8, value, "global-nav") == null);
        try std.testing.expect(std.mem.indexOf(u8, value, "react-button__trigger") == null);
        try std.testing.expect(std.mem.indexOf(u8, value, "main h1") == null);
    }
    try std.testing.expectEqualStrings("css=button[aria-label=\"Comment\"]", linkedin.selectors.comment_button);
    try std.testing.expectEqualStrings("css=button[aria-label=\"Repost\"]", linkedin.selectors.repost_button);
}

test "like: the first reaction button must say \"no reaction\"; liked only when that same button says exactly \"like\" (audit MED: no other state counts)" {
    try std.testing.expectEqualStrings(
        "xpath=(//button[starts-with(@aria-label, \"Reaction button state: \")])[1][@aria-label=\"Reaction button state: no reaction\"]",
        linkedin.selectors.like_button,
    );
    try std.testing.expectEqualStrings(
        "xpath=(//button[starts-with(@aria-label, \"Reaction button state: \")])[1][@aria-label=\"Reaction button state: like\"]",
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
    const plain = try linkedin.profileSelector(gpa, .follow, "Sam O'Example", null);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("xpath=//*[@aria-label=\"Follow Sam O'Example\"]", plain);
    const double = try linkedin.profileSelector(gpa, .follow, "Sam \"Q\" Example", null);
    defer gpa.free(double);
    try std.testing.expectEqualStrings("xpath=//*[@aria-label='Follow Sam \"Q\" Example']", double);
    const both = try linkedin.profileSelector(gpa, .follow, "Sam \"Q\" O'E", area);
    defer gpa.free(both);
    try std.testing.expectEqualStrings("xpath=" ++ area ++ "//*[@aria-label=concat('Follow Sam ', '\"', 'Q', '\"', ' O', \"'\", 'E')]" ++ shown, both);
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

// The scoped click itself (src/linkedin.zig clickProfileAction).

test "live owner area (probe v2, 2026-10-11): the one <main> section labelled \"Primary content\"" {
    // Not the role=toolbar clone outside <main> (aria-hidden), not the
    // "People you may know" cards (<aside aria-label="Aside"> in <main>).
    try std.testing.expectEqualStrings("//main//section[@aria-label=\"Primary content\"]", linkedin.owner_container);
}

test "scoped click: the exact label exactly once inside the one owner area -> strict click" {
    var runner = FakeRunner{};
    defer runner.deinit();
    try std.testing.expect(try linkedin.clickProfileAction(gpa, &runner, area, .connect, "Sam Example"));
    try expectMethods(&runner, &.{ "dom.waitFor", "dom.query", "dom.query", "dom.click" });
    // Waits until a copy is visible (the profile's buttons render late).
    try std.testing.expect(std.mem.indexOf(u8, runner.steps.items[0].params, "\"state\":\"visible\"") != null);
    try expectSelector(&runner, 0, own_connect);
    try expectSelector(&runner, 1, own_connect);
    try expectSelector(&runner, 2, owner_area);
    try expectSelector(&runner, 3, own_connect);
    try std.testing.expect(std.mem.indexOf(u8, runner.steps.items[3].params, "\"strict\":true") != null);
    try std.testing.expect(runner.not_found == null);
}

test "scoped click: the exact target never appears in the owner area -> linkedin_profile_action_missing, nothing clicked" {
    var runner = FakeRunner{ .rules = &.{
        .{ .method = "dom.waitFor", .contains = "Invite Sam Example", .result = null },
        .{ .method = "dom.query", .contains = "Invite Sam Example", .result = no_elements },
    } };
    defer runner.deinit();
    try std.testing.expect(!(try linkedin.clickProfileAction(gpa, &runner, area, .connect, "Sam Example")));
    try std.testing.expectEqualStrings("linkedin_profile_action_missing", runner.not_found.?);
    try expectMethods(&runner, &.{ "dom.waitFor", "dom.query" });
}

test "scoped click: a display:none copy beside the visible one (live): only the visible copy, clicked strictly by its position" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.query", .contains = "Invite Sam Example", .result = hidden_then_visible }} };
    defer runner.deinit();
    try std.testing.expect(try linkedin.clickProfileAction(gpa, &runner, area, .connect, "Sam Example"));
    try expectMethods(&runner, &.{ "dom.waitFor", "dom.query", "dom.query", "dom.click" });
    try expectSelector(&runner, 3, own_connect_2);
    try std.testing.expect(std.mem.indexOf(u8, runner.steps.items[3].params, "\"strict\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, runner.steps.items[3].params, "trial") == null);
    try std.testing.expect(runner.not_found == null);
}

test "scoped click: every copy hidden (no box) -> linkedin_profile_action_missing, nothing clicked" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.query", .contains = "Invite Sam Example", .result = all_hidden }} };
    defer runner.deinit();
    try std.testing.expect(!(try linkedin.clickProfileAction(gpa, &runner, area, .connect, "Sam Example")));
    try std.testing.expectEqualStrings("linkedin_profile_action_missing", runner.not_found.?);
    for (runner.steps.items) |st| try std.testing.expect(!std.mem.eql(u8, st.method, "dom.click"));
}

test "scoped click: the own label visible twice in the owner area -> linkedin_profile_action_ambiguous, nothing clicked (never picks one)" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.query", .contains = "Follow Sam Example", .result = two_elements }} };
    defer runner.deinit();
    try std.testing.expect(!(try linkedin.clickProfileAction(gpa, &runner, area, .follow, "Sam Example")));
    try std.testing.expectEqualStrings("linkedin_profile_action_ambiguous", runner.not_found.?);
    for (runner.steps.items) |st| try std.testing.expect(!std.mem.eql(u8, st.method, "dom.click"));
}

test "scoped click: an owner area that matches twice is no owner area -> linkedin_profile_action_ambiguous, nothing clicked" {
    var runner = FakeRunner{ .rules = &.{
        .{ .method = "dom.query", .contains = "Sam Example", .result = one_element },
        .{ .method = "dom.query", .result = two_elements },
    } };
    defer runner.deinit();
    try std.testing.expect(!(try linkedin.clickProfileAction(gpa, &runner, area, .follow, "Sam Example")));
    try std.testing.expectEqualStrings("linkedin_profile_action_ambiguous", runner.not_found.?);
    try expectSelector(&runner, 2, owner_area);
    for (runner.steps.items) |st| try std.testing.expect(!std.mem.eql(u8, st.method, "dom.click"));
}

test "scoped click: nothing outside the owner area is waited for, counted or clicked (a same-name card there cannot match, even if it renders first)" {
    var runner = FakeRunner{};
    defer runner.deinit();
    try std.testing.expect(try linkedin.clickProfileAction(gpa, &runner, area, .follow, "Sam Example"));
    for (runner.steps.items, 0..) |_, i| {
        const sel = try runner.selectorOf(i);
        defer gpa.free(sel);
        try std.testing.expect(std.mem.startsWith(u8, sel, owner_area));
    }
}

test "scoped click: a failed wait keeps its own failure when the target is there (e.g. cancelled); only a 0 count says missing" {
    var runner = FakeRunner{ .rules = &.{.{ .method = "dom.waitFor", .contains = "Follow Sam Example", .result = null }} };
    defer runner.deinit();
    try std.testing.expect(!(try linkedin.clickProfileAction(gpa, &runner, area, .follow, "Sam Example")));
    try std.testing.expect(runner.not_found == null);
    try expectMethods(&runner, &.{ "dom.waitFor", "dom.query" });
}

test "the profile's own state labels (after the click) are owner-scoped too" {
    const pending = try linkedin.profileSelector(gpa, .pending, "Sam Example", area);
    defer gpa.free(pending);
    try std.testing.expectEqualStrings(own_pending, pending);
    const following = try linkedin.profileSelector(gpa, .following, "Sam Example", area);
    defer gpa.free(following);
    try std.testing.expectEqualStrings(own_following, following);
    const message = try linkedin.profileSelector(gpa, .message, "Sam Example", area);
    defer gpa.free(message);
    try std.testing.expectEqualStrings(own_message, message);
}

test "connect and follow are on (owner area pinned live); profile message checks the page, then refuses before any click (no live Message seen)" {
    try std.testing.expect(linkedin.ownerActionEnabled(.connect));
    try std.testing.expect(linkedin.ownerActionEnabled(.follow));
    try std.testing.expect(!linkedin.ownerActionEnabled(.message));

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

test "the scoped flows: connect with a typed note and follow (on), profile message (tests: Site.unverified_actions)" {
    var verified = linkedin.site;
    verified.unverified_actions = true;

    var c = FakeRunner{};
    defer c.deinit();
    gpa.free((try linkedin.connect(gpa, &c, linkedin.site, profile, "Hi Sam, loved your notes on the engine.")).?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title", "dom.waitFor", "dom.query", "dom.query", "dom.click", "dom.waitFor", "dom.click", "dom.click", "dom.fill", "dom.type", "dom.click", "dom.waitFor" });
    try expectSelector(&c, 4, connect_or_more);
    try expectSelector(&c, 7, own_connect);
    // The invite dialog comes late (live: 3-5 s): its button is awaited.
    try expectSelector(&c, 8, linkedin.selectors.add_note_button);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[8].params, "\"state\":\"visible\"") != null);
    try expectSelector(&c, 9, linkedin.selectors.add_note_button);
    try expectSelector(&c, 10, linkedin.selectors.note_input);
    // fill only clears; the note text goes through dom.type.
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[11].params, "\"value\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[12].params, "loved your notes") != null);
    try expectSelector(&c, 13, linkedin.selectors.send_invite_button);
    try expectSelector(&c, 14, own_pending);

    var long = FakeRunner{};
    defer long.deinit();
    gpa.free((try linkedin.connect(gpa, &long, linkedin.site, profile, "é" ** 301)).?);
    const typed = try std.json.parseFromSlice(std.json.Value, gpa, long.steps.items[12].params, .{});
    defer typed.deinit();
    try std.testing.expectEqual(@as(usize, 300), try std.unicode.utf8CountCodepoints(typed.value.object.get("text").?.string));

    var f = FakeRunner{};
    defer f.deinit();
    gpa.free((try linkedin.follow(gpa, &f, linkedin.site, profile)).?);
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
    _ = try linkedin.clickProfileAction(gpa, &runner, area, .follow, "Sam Example");
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

// ---- Dry run (options.dry_run): everything up to the committing click ----

/// No step of a dry run may act on the page: only dom.click trials, reads
/// and waits (no real click, fill, type, press or select).
fn expectNoInput(runner: *const FakeRunner) !void {
    for (runner.steps.items) |st| {
        for ([_][]const u8{ "dom.fill", "dom.type", "dom.press", "dom.selectOption", "dom.setInputFiles", "dom.hover", "dom.scroll" }) |m| {
            try std.testing.expect(!std.mem.eql(u8, st.method, m));
        }
        if (std.mem.eql(u8, st.method, "dom.click")) {
            try std.testing.expect(std.mem.indexOf(u8, st.params, "\"trial\":true") != null);
        }
    }
}

test "dry run connect: the real flow's own target resolution (owner area, visible copy), a trial click on it, nothing clicked; the name is <owner>" {
    var r = FakeRunner{ .rules = &.{
        // The visible copy by its position matches only itself.
        .{ .method = "dom.query", .contains = ")[2]", .result = one_element },
        .{ .method = "dom.query", .contains = "Invite Sam Example", .result = hidden_then_visible },
    } };
    defer r.deinit();
    const result = (try linkedin.dryRun(gpa, &r, linkedin.site, .connect, profile)).?;
    defer gpa.free(result);
    try expectMethods(&r, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title", "dom.waitFor", "dom.query", "dom.query", "dom.click", "dom.query" });
    try expectSelector(&r, 5, own_connect);
    try expectSelector(&r, 6, owner_area);
    try expectSelector(&r, 7, own_connect_2);
    try std.testing.expect(std.mem.indexOf(u8, r.steps.items[7].params, "\"strict\":true") != null);
    try expectSelector(&r, 8, own_connect_2);
    try expectNoInput(&r);
    try std.testing.expect(std.mem.indexOf(u8, result, "Sam") == null);
    try std.testing.expectEqualStrings(
        "{\"dry_run\":true,\"would_act\":\"connect\",\"target\":{\"tag\":\"a\",\"label\":\"Invite <owner> to connect\",\"box\":{\"x\":56,\"y\":513,\"width\":97,\"height\":48}}," ++
            "\"checks\":[{\"name\":\"signed_in\",\"result\":\"pass\"},{\"name\":\"profile_owner\",\"result\":\"pass\"},{\"name\":\"owner_area\",\"result\":\"pass\",\"count\":1}," ++
            "{\"name\":\"visible_copies\",\"result\":\"pass\",\"count\":1},{\"name\":\"actionable\",\"result\":\"pass\"}," ++
            "{\"name\":\"invite_dialog\",\"result\":\"not_reached\",\"reason\":\"opens only after the Connect click\"}]}",
        result,
    );
}

test "dry run follow: the owner's Follow, trial only" {
    var r = FakeRunner{};
    defer r.deinit();
    const result = (try linkedin.dryRun(gpa, &r, linkedin.site, .follow, profile)).?;
    defer gpa.free(result);
    try expectSelector(&r, 7, own_follow);
    try expectNoInput(&r);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"would_act\":\"follow\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"label\":\"Follow <owner>\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Sam") == null);
}

test "dry run connect/follow fail closed exactly like the real flow: ambiguous, missing, not a profile, logged out" {
    var two = FakeRunner{ .rules = &.{.{ .method = "dom.query", .contains = "Follow Sam Example", .result = two_elements }} };
    defer two.deinit();
    try std.testing.expect((try linkedin.dryRun(gpa, &two, linkedin.site, .follow, profile)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_action_ambiguous", two.not_found.?);
    for (two.steps.items) |st| try std.testing.expect(!std.mem.eql(u8, st.method, "dom.click"));

    // No own Connect and no More in the owner area.
    var none = FakeRunner{ .rules = &.{
        .{ .method = "dom.waitFor", .contains = "Invite Sam Example", .result = null },
        .{ .method = "dom.query", .contains = "Invite Sam Example", .result = no_elements },
        .{ .method = "dom.query", .contains = "More actions", .result = no_elements },
    } };
    defer none.deinit();
    try std.testing.expect((try linkedin.dryRun(gpa, &none, linkedin.site, .connect, profile)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_action_missing", none.not_found.?);

    var feed = FakeRunner{ .rules = &.{.{ .method = "page.url", .result = "{\"url\":\"https://www.linkedin.com/feed/\"}" }} };
    defer feed.deinit();
    try std.testing.expect((try linkedin.dryRun(gpa, &feed, linkedin.site, .connect, profile)) == null);
    try std.testing.expectEqualStrings("linkedin_not_a_profile", feed.not_found.?);

    var out = FakeRunner{ .rules = &.{.{ .method = "dom.waitFor", .result = null }} };
    defer out.deinit();
    try std.testing.expectError(error.LoggedOut, linkedin.dryRun(gpa, &out, linkedin.site, .follow, profile));

    // A trial that fails (e.g. covered) is the real click's failure too.
    var covered = FakeRunner{ .rules = &.{.{ .method = "dom.click", .result = null }} };
    defer covered.deinit();
    try std.testing.expect((try linkedin.dryRun(gpa, &covered, linkedin.site, .connect, profile)) == null);
    try expectNoInput(&covered);

    // Off-site URLs are refused before any step.
    var off = FakeRunner{};
    defer off.deinit();
    try std.testing.expectError(error.InvalidParams, linkedin.dryRun(gpa, &off, linkedin.site, .like, "https://evil.example/in/x/"));
    try std.testing.expectEqual(@as(usize, 0), off.steps.items.len);
}

test "dry run like: trial on the first reaction button (still \"no reaction\"), nothing clicked" {
    var r = FakeRunner{};
    defer r.deinit();
    const result = (try linkedin.dryRun(gpa, &r, linkedin.site, .like, "https://www.linkedin.com/feed/update/urn:li:activity:1/")).?;
    defer gpa.free(result);
    try expectMethods(&r, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.query" });
    try expectSelector(&r, 2, linkedin.selectors.like_button);
    try expectNoInput(&r);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"would_act\":\"like\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"label\":\"Reaction button state: no reaction\"") != null);
}

test "dry run comment: trial on the Comment button (as the flow clicks it: not strict), the comment box counted, nothing typed" {
    var r = FakeRunner{};
    defer r.deinit();
    const result = (try linkedin.dryRun(gpa, &r, linkedin.site, .comment, "https://www.linkedin.com/feed/update/urn:li:activity:1/")).?;
    defer gpa.free(result);
    try expectMethods(&r, &.{ "page.navigate", "dom.waitFor", "dom.click", "dom.query", "dom.query" });
    try expectSelector(&r, 2, linkedin.selectors.comment_button);
    try std.testing.expect(std.mem.indexOf(u8, r.steps.items[2].params, "\"strict\":false") != null);
    try expectSelector(&r, 4, linkedin.selectors.comment_input);
    try expectNoInput(&r);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"would_act\":\"comment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "{\"name\":\"comment_box\",\"result\":\"pass\",\"count\":1}") != null);
}

// ---- Connect through the owner's More menu (live, 2026-10-11) ----

// Live: the invite dialog sits in an open shadow root, so its buttons are
// found with pierce=, and it appears 3-5 s after the Connect click.
test "the invite dialog's buttons are found inside shadow roots (pierce=), by role and name" {
    try std.testing.expectEqualStrings("pierce=role=button[name=\"Send without a note\"]", linkedin.selectors.send_without_note_button);
    try std.testing.expectEqualStrings("pierce=role=button[name=\"Add a note\"]", linkedin.selectors.add_note_button);
    try std.testing.expect(std.mem.startsWith(u8, linkedin.selectors.note_input, "pierce=css="));
    try std.testing.expect(std.mem.startsWith(u8, linkedin.selectors.send_invite_button, "pierce=css="));
}

test "live post-click labels: \"Following, click to unfollow <Name>\" is the Following state (it was missed before)" {
    try std.testing.expectEqualStrings("css=main button[aria-label^=\"Following\"], main button[aria-label^=\"Unfollow\"]", linkedin.selectors.following_button);
    try std.testing.expectEqualStrings("xpath=//*[@role=\"alert\" or @aria-live][starts-with(normalize-space(.), \"Invitation sent\")]", linkedin.selectors.invite_sent_toast);
}

test "connect, direct route: the owner's own Connect, then the late dialog's Send without a note (awaited), then Pending" {
    var c = FakeRunner{};
    defer c.deinit();
    gpa.free((try linkedin.connect(gpa, &c, linkedin.site, profile, null)).?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title", "dom.waitFor", "dom.query", "dom.query", "dom.click", "dom.waitFor", "dom.click", "dom.waitFor" });
    try expectSelector(&c, 4, connect_or_more);
    try expectSelector(&c, 5, own_connect);
    try expectSelector(&c, 6, owner_area);
    try expectSelector(&c, 7, own_connect);
    try expectSelector(&c, 8, linkedin.selectors.send_without_note_button);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[8].params, "\"state\":\"visible\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[8].params, "\"timeout_ms\":15000") != null);
    try expectSelector(&c, 9, linkedin.selectors.send_without_note_button);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[9].params, "\"strict\":true") != null);
    try expectSelector(&c, 10, own_pending);
}

/// Before the owner's More is clicked no menu item is shown (RoseCat 5157:
/// only an item that appears after the owner's click may be clicked).
const menu_baseline = Rule{ .method = "dom.query", .contains = "menuitem", .result = no_elements, .uses = 1 };

/// The live layout: no own Connect; the owner's visible More (a hidden copy
/// first) opens a menu whose item "Connect" carries no full name.
const more_menu_rules = [_]Rule{
    menu_baseline,
    // The owner's More names no menu (the general path).
    .{ .method = "dom.getAttribute", .contains = "aria-controls", .result = "{\"value\":null}" },
    .{ .method = "dom.query", .contains = ")[2]", .result = one_element },
    .{ .method = "dom.query", .contains = "More actions", .result = hidden_then_visible },
    .{ .method = "dom.query", .contains = "Invite Sam Example", .result = no_elements },
};

test "connect, More route: no own Connect -> the owner's visible More, the menu's one Connect item, the late dialog, then Pending" {
    var c = FakeRunner{ .rules = &more_menu_rules };
    defer c.deinit();
    gpa.free((try linkedin.connect(gpa, &c, linkedin.site, profile, null)).?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title", "dom.waitFor", "dom.query", "dom.query", "dom.query", "dom.query", "dom.click", "dom.getAttribute", "dom.waitFor", "dom.query", "dom.click", "dom.waitFor", "dom.click", "dom.waitFor" });
    try expectSelector(&c, 5, own_connect);
    try expectSelector(&c, 6, own_more);
    try expectSelector(&c, 7, owner_area);
    // No open menu and no menu item shown before the owner's More is clicked.
    try expectSelector(&c, 8, menu_open);
    // The visible copy, strictly by its position.
    try expectSelector(&c, 9, own_more_2);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[9].params, "\"strict\":true") != null);
    // The menu it controls, if it names one (none here).
    try expectSelector(&c, 10, own_more_2);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[10].params, "\"name\":\"aria-controls\"") != null);
    try expectSelector(&c, 11, menu_connect);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[11].params, "\"state\":\"visible\"") != null);
    try expectSelector(&c, 12, menu_connect);
    try expectSelector(&c, 13, menu_connect);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[13].params, "\"strict\":true") != null);
    try expectSelector(&c, 14, linkedin.selectors.send_without_note_button);
    try expectSelector(&c, 15, linkedin.selectors.send_without_note_button);
    try expectSelector(&c, 16, own_pending);
    try std.testing.expect(c.not_found == null);
}

/// Its visible text, svg titles left out, is exactly "Connect" (RoseCat 5160).
const connect_text = "(.//text()[not(ancestor::*[name()=\"svg\"])][normalize-space(.)=\"Connect\"] and " ++
    "not(.//text()[not(ancestor::*[name()=\"svg\"])][normalize-space(.)!=\"\" and normalize-space(.)!=\"Connect\"]))";

test "the menu's Connect item: visible text exactly \"Connect\" (svg titles left out), the innermost clickable, inside the owner area or a role=menu, never aria-hidden" {
    try std.testing.expectEqualStrings(
        "xpath=(" ++ area ++ " | //*[@role=\"menu\"])//*[self::button or self::a or @role=\"button\" or @role=\"menuitem\"][" ++ connect_text ++ "]" ++
            "[not(.//*[self::button or self::a or @role=\"button\" or @role=\"menuitem\"][" ++ connect_text ++ "])]" ++ shown,
        menu_connect,
    );
    try std.testing.expectEqualStrings(own_more, linkedin.selectors.owner_more_button);
}

test "connect, More route with a note: Add a note, the note, Send; all in the dialog" {
    var c = FakeRunner{ .rules = &more_menu_rules };
    defer c.deinit();
    gpa.free((try linkedin.connect(gpa, &c, linkedin.site, profile, "Hi Sam")).?);
    try expectSelector(&c, 13, menu_connect);
    try expectSelector(&c, 14, linkedin.selectors.add_note_button);
    try expectSelector(&c, 15, linkedin.selectors.add_note_button);
    try expectSelector(&c, 16, linkedin.selectors.note_input);
    try expectSelector(&c, 19, linkedin.selectors.send_invite_button);
    try expectSelector(&c, 20, own_pending);
}

fn expectNoMenuItemClick(runner: *const FakeRunner) !void {
    for (runner.steps.items, 0..) |st, i| {
        if (!std.mem.eql(u8, st.method, "dom.click")) continue;
        const sel = try runner.selectorOf(i);
        defer gpa.free(sel);
        try std.testing.expect(std.mem.indexOf(u8, sel, "Connect") == null);
    }
}

test "connect, More route: no Connect in the owner's menu (connected, pending, Follow-only) -> Escape closes it, linkedin_profile_connect_not_in_menu" {
    var c = FakeRunner{ .rules = &([_]Rule{
        menu_baseline,
        .{ .method = "dom.waitFor", .contains = "menuitem", .result = null },
        .{ .method = "dom.query", .contains = "menuitem", .result = no_elements },
    } ++ more_menu_rules) };
    defer c.deinit();
    try std.testing.expect((try linkedin.connect(gpa, &c, linkedin.site, profile, null)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_connect_not_in_menu", c.not_found.?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title", "dom.waitFor", "dom.query", "dom.query", "dom.query", "dom.query", "dom.click", "dom.getAttribute", "dom.waitFor", "dom.query", "dom.press" });
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[13].params, "\"key\":\"Escape\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[13].params, "selector") == null);
    try expectNoMenuItemClick(&c);
}

test "connect, More route: two visible Connect items -> Escape, linkedin_profile_action_ambiguous, neither clicked" {
    var c = FakeRunner{ .rules = &([_]Rule{
        menu_baseline,
        .{ .method = "dom.query", .contains = "menuitem", .result = two_elements },
    } ++ more_menu_rules) };
    defer c.deinit();
    try std.testing.expect((try linkedin.connect(gpa, &c, linkedin.site, profile, null)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_action_ambiguous", c.not_found.?);
    try std.testing.expectEqualStrings("dom.press", c.steps.items[c.steps.items.len - 1].method);
    try expectNoMenuItemClick(&c);
}

test "connect, More route: a failed menu wait with an item there keeps its own failure (e.g. cancelled); nothing clicked" {
    var c = FakeRunner{ .rules = &([_]Rule{
        .{ .method = "dom.waitFor", .contains = "menuitem", .result = null },
    } ++ more_menu_rules) };
    defer c.deinit();
    try std.testing.expect((try linkedin.connect(gpa, &c, linkedin.site, profile, null)) == null);
    try std.testing.expect(c.not_found == null);
    try expectNoMenuItemClick(&c);
}

test "connect: neither the own Connect nor a More in the owner area -> linkedin_profile_action_missing, nothing clicked" {
    var c = FakeRunner{ .rules = &.{
        .{ .method = "dom.waitFor", .contains = "More actions", .result = null },
        .{ .method = "dom.query", .contains = "More actions", .result = no_elements },
        .{ .method = "dom.query", .contains = "Invite Sam Example", .result = no_elements },
    } };
    defer c.deinit();
    try std.testing.expect((try linkedin.connect(gpa, &c, linkedin.site, profile, null)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_action_missing", c.not_found.?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title", "dom.waitFor", "dom.query", "dom.query" });
}

test "connect, More route: two visible More buttons in the owner area -> linkedin_profile_action_ambiguous, nothing clicked" {
    var c = FakeRunner{ .rules = &.{
        .{ .method = "dom.query", .contains = "More actions", .result = two_elements },
        .{ .method = "dom.query", .contains = "Invite Sam Example", .result = no_elements },
    } };
    defer c.deinit();
    try std.testing.expect((try linkedin.connect(gpa, &c, linkedin.site, profile, null)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_action_ambiguous", c.not_found.?);
    for (c.steps.items) |st| try std.testing.expect(!std.mem.eql(u8, st.method, "dom.click"));
}

test "connect, More route: only the owner area is looked in for More (never a suggestion card's More)" {
    var c = FakeRunner{ .rules = &more_menu_rules };
    defer c.deinit();
    gpa.free((try linkedin.connect(gpa, &c, linkedin.site, profile, null)).?);
    // (Step 8, the open-menu check, looks at the whole page on purpose.)
    for ([_]usize{ 4, 5, 6, 7, 9 }) |i| {
        const sel = try c.selectorOf(i);
        defer gpa.free(sel);
        try std.testing.expect(std.mem.startsWith(u8, sel, owner_area) or std.mem.startsWith(u8, sel, "xpath=(" ++ area));
    }
}

test "dry run connect, More route: a trial on the owner's visible More only (the menu is never opened); more_menu not reached" {
    var r = FakeRunner{ .rules = &more_menu_rules };
    defer r.deinit();
    const result = (try linkedin.dryRun(gpa, &r, linkedin.site, .connect, profile)).?;
    defer gpa.free(result);
    try expectMethods(&r, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title", "dom.waitFor", "dom.query", "dom.query", "dom.query", "dom.query", "dom.click", "dom.query" });
    try expectSelector(&r, 8, menu_open);
    try expectSelector(&r, 9, own_more_2);
    try expectNoInput(&r);
    try std.testing.expect(std.mem.indexOf(u8, result, "Sam") == null);
    try std.testing.expectEqualStrings(
        "{\"dry_run\":true,\"would_act\":\"connect\",\"target\":{\"tag\":\"a\",\"label\":\"More\",\"box\":{\"x\":56,\"y\":513,\"width\":97,\"height\":48}}," ++
            "\"checks\":[{\"name\":\"signed_in\",\"result\":\"pass\"},{\"name\":\"profile_owner\",\"result\":\"pass\"},{\"name\":\"owner_area\",\"result\":\"pass\",\"count\":1}," ++
            "{\"name\":\"visible_copies\",\"result\":\"pass\",\"count\":1},{\"name\":\"actionable\",\"result\":\"pass\"}," ++
            "{\"name\":\"more_menu\",\"result\":\"not_reached\",\"reason\":\"Connect is inside the owner's More menu; opening it needs a click\"}," ++
            "{\"name\":\"invite_dialog\",\"result\":\"not_reached\",\"reason\":\"opens only after the Connect click\"}]}",
        result,
    );
}

test "More route (RoseCat 5157): the check before the More click is any visible role=menu or any menu Connect item" {
    const item_body = menu_connect["xpath=(".len + area.len + " | //*[@role=\"menu\"])".len ..];
    try std.testing.expectEqualStrings("xpath=//*[@role=\"menu\"]" ++ shown ++ " | " ++ menu_connect["xpath=".len..], menu_open);
    try std.testing.expect(std.mem.startsWith(u8, item_body, "//*[self::button"));
}

test "More route: a More that names its menu (aria-controls) binds the Connect item to that menu only" {
    var c = FakeRunner{ .rules = &([_]Rule{
        .{ .method = "dom.getAttribute", .contains = "aria-controls", .result = "{\"value\":\"menu-7\"}" },
    } ++ more_menu_rules) };
    defer c.deinit();
    gpa.free((try linkedin.connect(gpa, &c, linkedin.site, profile, null)).?);
    const item_body = menu_connect["xpath=(".len + area.len + " | //*[@role=\"menu\"])".len ..];
    const bound = try std.fmt.allocPrint(gpa, "xpath=//*[@id=\"menu-7\"]{s}", .{item_body});
    defer gpa.free(bound);
    // The named element must be there exactly once.
    try expectSelector(&c, 11, "xpath=//*[@id=\"menu-7\"]");
    try expectSelector(&c, 12, bound);
    try expectSelector(&c, 13, bound);
    try expectSelector(&c, 14, bound);
    try std.testing.expect(std.mem.indexOf(u8, c.steps.items[14].params, "\"strict\":true") != null);
}

test "More route (RoseCat 5169): aria-controls naming several ids binds to exactly those ids (never every menu)" {
    var c = FakeRunner{ .rules = &([_]Rule{
        .{ .method = "dom.getAttribute", .contains = "aria-controls", .result = "{\"value\":\" owner-menu  auxiliary \"}" },
    } ++ more_menu_rules) };
    defer c.deinit();
    gpa.free((try linkedin.connect(gpa, &c, linkedin.site, profile, null)).?);
    const item_body = menu_connect["xpath=(".len + area.len + " | //*[@role=\"menu\"])".len ..];
    const bound = try std.fmt.allocPrint(gpa, "xpath=//*[@id=\"owner-menu\" or @id=\"auxiliary\"]{s}", .{item_body});
    defer gpa.free(bound);
    try expectSelector(&c, 11, "xpath=//*[@id=\"owner-menu\"]");
    try expectSelector(&c, 12, "xpath=//*[@id=\"auxiliary\"]");
    try expectSelector(&c, 13, bound);
    try expectSelector(&c, 15, bound);
}

fn expectUnbound(rules: []const Rule) !void {
    var c = FakeRunner{ .rules = rules };
    defer c.deinit();
    try std.testing.expect((try linkedin.connect(gpa, &c, linkedin.site, profile, null)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_menu_unbound", c.not_found.?);
    try std.testing.expectEqualStrings("dom.press", c.steps.items[c.steps.items.len - 1].method);
    try expectNoMenuItemClick(&c);
}

test "More route (RoseCat 5169): a named menu id that is missing or not unique, or too many ids -> Escape, linkedin_profile_menu_unbound, no item clicked" {
    const named = Rule{ .method = "dom.getAttribute", .contains = "aria-controls", .result = "{\"value\":\"menu-7\"}" };
    try expectUnbound(&([_]Rule{ menu_baseline, named, .{ .method = "dom.query", .contains = "menu-7", .result = two_elements } } ++ more_menu_rules));
    try expectUnbound(&([_]Rule{ menu_baseline, named, .{ .method = "dom.query", .contains = "menu-7", .result = no_elements } } ++ more_menu_rules));
    try expectUnbound(&([_]Rule{.{ .method = "dom.getAttribute", .contains = "aria-controls", .result = "{\"value\":\"a b c d e f g h i\"}" }} ++ more_menu_rules));
}

test "More route (RoseCat 5170): an unusable aria-controls read is malformed and stops before any item click (never the general path)" {
    for ([_][]const u8{ "{\"ok\":true}", "{\"value\":7}" }) |reply| {
        const rules = [_]Rule{.{ .method = "dom.getAttribute", .contains = "aria-controls", .result = reply }} ++ more_menu_rules;
        var c = FakeRunner{ .rules = &rules };
        defer c.deinit();
        try std.testing.expect((try linkedin.connect(gpa, &c, linkedin.site, profile, null)) == null);
        try std.testing.expectEqual(@as(usize, 1), c.malformed_calls);
        try std.testing.expectEqualStrings("dom.getAttribute", c.steps.items[c.steps.items.len - 1].method);
        try expectNoMenuItemClick(&c);
    }
}

test "More route (RoseCat 5157): a Connect item already shown before the owner's More is clicked (another menu open) -> linkedin_profile_menu_already_open, nothing clicked" {
    // Every menu query sees one visible item, the first one included.
    const open_menu = [_]Rule{.{ .method = "dom.query", .contains = "menuitem", .result = one_element }} ++ more_menu_rules;
    var c = FakeRunner{ .rules = &open_menu };
    defer c.deinit();
    try std.testing.expect((try linkedin.connect(gpa, &c, linkedin.site, profile, null)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_menu_already_open", c.not_found.?);
    try expectMethods(&c, &.{ "page.navigate", "dom.waitFor", "page.url", "page.title", "dom.waitFor", "dom.query", "dom.query", "dom.query", "dom.query" });
    try expectSelector(&c, 8, menu_open);

    // The dry run refuses at the same point (no trial on More either).
    var r = FakeRunner{ .rules = &open_menu };
    defer r.deinit();
    try std.testing.expect((try linkedin.dryRun(gpa, &r, linkedin.site, .connect, profile)) == null);
    try std.testing.expectEqualStrings("linkedin_profile_menu_already_open", r.not_found.?);
    for (r.steps.items) |st| try std.testing.expect(!std.mem.eql(u8, st.method, "dom.click"));
}
