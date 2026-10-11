//! LinkedIn (linkedin.com) flows. Each flow is a fixed sequence of ordinary
//! automation commands (page.navigate, dom.*), so it gets the engine's
//! retries, actionability checks and telemetry. The runner is duck-typed;
//! see src/flow_steps.zig for its contract.
//!
//! Every flow opens its page and passes the login gate first: a signed-in
//! marker must appear; if instead the page offers a sign-in link, the
//! account is logged out (error.LoggedOut) and nothing is clicked or typed.
const std = @import("std");
const flow = @import("flow_steps.zig");

/// Every LinkedIn selector, in one place. LinkedIn changes its markup;
/// check with `linkedin.selfcheck` on a logged-in page and update here.
/// Since 2026-10 LinkedIn uses hashed class names, so these anchor on text
/// and aria-labels (probed live on 2026-10-11 unless marked unverified).
pub const selectors = struct {
    /// Signs of a signed-in page: the top nav's "Me" button (its text is
    /// exactly "Me"; it has no aria-label), inside a <header> or <nav> so a
    /// "Me" button in page content does not count. UNVERIFIED live: that the
    /// nav is a <header>/<nav> element (the probe found the button by text).
    pub const signed_in = "xpath=(//header | //nav)//button[normalize-space(.)=\"Me\"]";
    /// Signs of a signed-out page.
    pub const login_link = "css=a[href*=\"/login\"], a[href*=\"/uas/login\"], .sign-in-form";
    /// Profile actions, for x.selfcheck-style counts only. Live, these also
    /// match the "People you may know" cards ("Invite <Name> to connect",
    /// "Follow <Name>"), so the flows never click them: they click the exact
    /// label for the profile's own person (`profileSelector`). Live, Connect
    /// is an <a>, so connect and pending take any element.
    pub const connect_button = "css=main [aria-label^=\"Invite \"][aria-label$=\" to connect\"]";
    pub const pending_button = "css=main [aria-label^=\"Pending\"]";
    pub const follow_button = "css=main button[aria-label^=\"Follow \"]";
    pub const following_button = "css=main button[aria-label^=\"Following \"], main button[aria-label^=\"Unfollow \"]";
    pub const message_button = "css=main a[href*=\"/messaging/compose\"], main button[aria-label^=\"Message \"]";
    /// Suggestion-card actions inside an <aside>, which the profile flows
    /// leave out. UNVERIFIED live: on a profile page this should be about
    /// connect_button + follow_button minus the profile's own; 0 there
    /// means the cards are not in an <aside> and the scoping needs a new
    /// anchor.
    pub const suggested_actions = "xpath=//aside//*[starts-with(@aria-label, \"Invite \") or starts-with(@aria-label, \"Follow \")]";
    /// Connect dialog.
    pub const add_note_button = "css=button[aria-label=\"Add a note\"]";
    pub const note_input = "css=textarea[name=\"message\"]";
    pub const send_invite_button = "css=button[aria-label=\"Send invitation\"], button[aria-label=\"Send now\"]";
    pub const send_without_note_button = "css=button[aria-label=\"Send without a note\"]";
    /// Messaging.
    pub const message_input = "css=.msg-form__contenteditable[contenteditable=\"true\"]";
    pub const message_send_button = "css=button.msg-form__send-button";
    /// Posts (the first social bar on a post page is the post's own). The
    /// reaction button's label states the reaction; its text is the count
    /// and it has no aria-pressed. Like = the first reaction button, still
    /// "no reaction"; liked = that same button no longer says so.
    /// UNVERIFIED: the liked label itself (nothing was liked in the probe).
    pub const like_button = "xpath=(//button[starts-with(@aria-label, \"Reaction button state: \")])[1][@aria-label=\"Reaction button state: no reaction\"]";
    pub const liked_button = "xpath=(//button[starts-with(@aria-label, \"Reaction button state: \")])[1][not(@aria-label=\"Reaction button state: no reaction\")]";
    pub const comment_button = "css=button[aria-label=\"Comment\"]";
    /// Not used by the flows; reported by linkedin.selfcheck.
    pub const repost_button = "css=button[aria-label=\"Repost\"]";
    pub const comment_input = "css=.comments-comment-box__form [contenteditable=\"true\"]";
    pub const comment_submit = "css=button.comments-comment-box__submit-button";
    /// Profile summary (linkedin.extract; the name comes from the page
    /// title, see `profileNameFromTitle`). UNVERIFIED since the hashed
    /// classes: headline and location (absent ones read as null).
    pub const profile_headline = "css=main .text-body-medium.break-words";
    pub const profile_location = "css=main .text-body-small.inline.t-black--light.break-words";
    /// One search result card.
    pub const search_result = "css=.reusable-search__result-container";
};

/// The real site. The automation server may swap in a fixture origin for
/// tests (flow_steps.Site); requests cannot.
pub const site = flow.Site{ .host = "www.linkedin.com", .origin = "https://www.linkedin.com" };

/// The profile's own actions, by their exact labels for the profile
/// owner's name (see `profileNameFromTitle`). UNVERIFIED live: the pending
/// and following labels (taken from the earlier markup) and actions that
/// LinkedIn moves under the profile's "More" menu, which these flows do not
/// open: they fail closed as linkedin_profile_action_missing.
pub const ProfileAction = enum { connect, follow, message, pending, following };

/// The profile's own action area, as an XPath expression that must match
/// exactly one element: profile actions click only inside it. Pinned from
/// the live owner probe v2 (2026-10-11, names redacted; reviews 4971,
/// 5019/5020): <main> has one section, labelled "Primary content", holding
/// the owner's visible Connect and Follow and a display:none copy of
/// Connect; a clone of the owner's Connect sits outside <main> under an
/// aria-hidden role=toolbar; the "People you may know" cards sit in
/// <aside aria-label="Aside"> inside <main>, outside that section. (A page
/// in another language has no such label: 0 areas, so the flows refuse.)
pub const owner_container = "//main//section[@aria-label=\"Primary content\"]";

/// Whether a profile action may click at all. Connect and follow: on, in
/// owner_container. Message: OFF, since the profile's own Message was not
/// on the probed profile; the flow opens and checks the profile, then stops
/// before any click: element_not_found linkedin_profile_owner_unverified
/// (tests run it through flow_steps.Site.unverified_actions). UNVERIFIED
/// live: the labels after the click (pending, following) and the invite
/// dialog's buttons.
pub fn ownerActionEnabled(action: ProfileAction) bool {
    return switch (action) {
        .connect, .follow => true,
        .message, .pending, .following => false,
    };
}

/// `action`'s exact selector for `name`, inside `container` (an XPath
/// expression for the owner's area) and under no aria-hidden element, or
/// anywhere when `container` is null (owned).
pub fn profileSelector(gpa: std.mem.Allocator, action: ProfileAction, name: []const u8, container: ?[]const u8) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "xpath=");
    if (container) |c| try out.appendSlice(gpa, c);
    try out.appendSlice(gpa, "//*[");
    switch (action) {
        .connect => try labelEquals(gpa, &out, "Invite ", name, " to connect"),
        .follow => try labelEquals(gpa, &out, "Follow ", name, ""),
        .message => try labelEquals(gpa, &out, "Message ", name, ""),
        .pending => {
            try out.appendSlice(gpa, "starts-with(@aria-label, \"Pending\") and contains(@aria-label, ");
            try xpathLiteral(gpa, &out, &.{name});
            try out.append(gpa, ')');
        },
        .following => {
            try labelEquals(gpa, &out, "Following ", name, "");
            try out.appendSlice(gpa, " or ");
            try labelEquals(gpa, &out, "Unfollow ", name, "");
        },
    }
    try out.append(gpa, ']');
    if (container != null) try out.appendSlice(gpa, "[not(ancestor-or-self::*[@aria-hidden=\"true\"])]");
    return try out.toOwnedSlice(gpa);
}

fn labelEquals(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), prefix: []const u8, name: []const u8, suffix: []const u8) Error!void {
    try out.appendSlice(gpa, "@aria-label=");
    try xpathLiteral(gpa, out, &.{ prefix, name, suffix });
}

/// The concatenation of `parts` as an XPath 1.0 string literal (which has
/// no escapes): "..." or '...', else concat() of quoted runs.
fn xpathLiteral(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), parts: []const []const u8) Error!void {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(gpa);
    for (parts) |part| try text.appendSlice(gpa, part);
    const value = text.items;
    if (std.mem.indexOfScalar(u8, value, '"') == null) return out.print(gpa, "\"{s}\"", .{value});
    if (std.mem.indexOfScalar(u8, value, '\'') == null) return out.print(gpa, "'{s}'", .{value});
    try out.appendSlice(gpa, "concat(");
    var first = true;
    var rest = value;
    while (rest.len > 0) {
        if (!first) try out.appendSlice(gpa, ", ");
        first = false;
        if (rest[0] == '"') {
            try out.appendSlice(gpa, "'\"'");
            rest = rest[1..];
        } else if (rest[0] == '\'') {
            try out.appendSlice(gpa, "\"'\"");
            rest = rest[1..];
        } else {
            const run = std.mem.indexOfAny(u8, rest, "\"'") orelse rest.len;
            try out.print(gpa, "'{s}'", .{rest[0..run]});
            rest = rest[run..];
        }
    }
    try out.append(gpa, ')');
}

/// `url` is a profile page: its path starts with /in/<something>.
pub fn isProfileUrl(url: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
    const after = url[scheme_end + 3 ..];
    const path_start = std.mem.indexOfAny(u8, after, "/?#") orelse return false;
    const path = after[path_start..];
    if (!std.mem.startsWith(u8, path, "/in/")) return false;
    return path.len > 4 and path[4] != '/' and path[4] != '?' and path[4] != '#';
}

/// The profile owner's name from a profile page title, "<Name> | LinkedIn"
/// (LinkedIn may prefix "(<n>) " for unread notifications). Null when the
/// title has no such name or holds a control character.
pub fn profileNameFromTitle(title: []const u8) ?[]const u8 {
    const suffix = " | LinkedIn";
    var rest = std.mem.trim(u8, title, " \t");
    if (!std.mem.endsWith(u8, rest, suffix)) return null;
    rest = rest[0 .. rest.len - suffix.len];
    if (rest.len > 0 and rest[0] == '(') {
        if (std.mem.indexOfScalar(u8, rest, ')')) |close| {
            const count = rest[1..close];
            var all_digits = count.len > 0;
            for (count) |c| all_digits = all_digits and std.ascii.isDigit(c);
            if (all_digits) rest = rest[close + 1 ..];
        }
    }
    const name = std.mem.trim(u8, rest, " \t");
    if (name.len == 0) return null;
    for (name) |c| if (c < ' ' or c == 0x7f) return null;
    return name;
}

/// LinkedIn's session cookie: without it the account is logged out, and an
/// action fails before navigating (checked by the automation server).
pub const session_cookie = "li_at";

/// LinkedIn's limits for an invitation note (longer notes are truncated to
/// this, C42), a message and a comment.
pub const max_note_chars = 300;
pub const max_message_chars = 8000;
pub const max_comment_chars = 1250;
pub const max_query_chars = 200;

/// `searchType` values and their /search/results/<path>/ segment.
pub const search_types = [_][]const u8{ "people", "companies", "jobs", "content", "all" };

const navigate_timeout_ms = 30_000;
const page_ready_timeout_ms = 15_000;
const click_timeout_ms = 10_000;
const confirm_timeout_ms = 15_000;
const read_timeout_ms = 10_000;

pub const Verb = enum { visit, connect, message, like, comment, follow, search, extract, selfcheck };

pub fn verbFromMethod(method: []const u8) ?Verb {
    const prefix = "linkedin.";
    if (!std.mem.startsWith(u8, method, prefix)) return null;
    return std.meta.stringToEnum(Verb, method[prefix.len..]);
}

/// Verbs that act on LinkedIn (paced and capped); the rest only read.
pub fn isAction(verb: Verb) bool {
    return switch (verb) {
        .visit, .connect, .message, .like, .comment, .follow, .search => true,
        .extract, .selfcheck => false,
    };
}

pub const Error = flow.Error;

const ok_json = "{\"ok\":true}";

/// The first `max_note_chars` code points of `note` (C42: truncated, not
/// rejected).
pub fn truncateNote(note: []const u8) []const u8 {
    var view = (std.unicode.Utf8View.init(note) catch return note).iterator();
    var count: usize = 0;
    while (view.nextCodepointSlice()) |_| {
        count += 1;
        if (count == max_note_chars) return note[0..view.i];
    }
    return note;
}

/// Opens a profile. Returns `{"ok":true}`.
pub fn visit(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, profile_url: []const u8) Error!?[]u8 {
    if (!s.allows(profile_url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, profile_url))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Sends a connection invitation, with an optional note (typed; truncated
/// to 300 characters), and waits until the profile shows it as pending.
pub fn connect(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, profile_url: []const u8, note: ?[]const u8) Error!?[]u8 {
    if (!s.allows(profile_url)) return error.InvalidParams;
    if (note) |text| try validateText(text, std.math.maxInt(usize));
    if (!(try openPage(gpa, runner, profile_url))) return null;
    const name = (try profileName(gpa, runner, s)) orelse return null;
    defer gpa.free(name);
    const area = (try ownerArea(runner, s, .connect)) orelse return null;
    if (!(try clickProfileAction(gpa, runner, area, .connect, name))) return null;
    if (note) |text| {
        if (!(try click(gpa, runner, selectors.add_note_button, true))) return null;
        if (!(try typeInto(gpa, runner, selectors.note_input, truncateNote(text)))) return null;
        if (!(try click(gpa, runner, selectors.send_invite_button, false))) return null;
    } else {
        if (!(try click(gpa, runner, selectors.send_without_note_button, true))) return null;
    }
    if (!(try waitProfileState(gpa, runner, area, .pending, name))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Follows a profile and waits for the Following state.
pub fn follow(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, profile_url: []const u8) Error!?[]u8 {
    if (!s.allows(profile_url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, profile_url))) return null;
    const name = (try profileName(gpa, runner, s)) orelse return null;
    defer gpa.free(name);
    const area = (try ownerArea(runner, s, .follow)) orelse return null;
    if (!(try clickProfileAction(gpa, runner, area, .follow, name))) return null;
    if (!(try waitProfileState(gpa, runner, area, .following, name))) return null;
    return try gpa.dupe(u8, ok_json);
}

pub const MessageTarget = union(enum) { conversation_url: []const u8, profile_url: []const u8 };

/// Sends `text` in an existing conversation, or from a profile's Message
/// button.
pub fn message(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, target: MessageTarget, text: []const u8) Error!?[]u8 {
    try validateText(text, max_message_chars);
    const url = switch (target) {
        inline else => |u| u,
    };
    if (!s.allows(url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, url))) return null;
    if (target == .profile_url) {
        const name = (try profileName(gpa, runner, s)) orelse return null;
        defer gpa.free(name);
        const area = (try ownerArea(runner, s, .message)) orelse return null;
        if (!(try clickProfileAction(gpa, runner, area, .message, name))) return null;
    }
    if (!(try typeInto(gpa, runner, selectors.message_input, text))) return null;
    if (!(try click(gpa, runner, selectors.message_send_button, true))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Likes a post (its first reaction button) and waits for the pressed state.
pub fn like(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, post_url: []const u8) Error!?[]u8 {
    if (!s.allows(post_url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, post_url))) return null;
    if (!(try click(gpa, runner, selectors.like_button, true))) return null;
    if (!(try waitAttached(gpa, runner, selectors.liked_button))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Comments on a post.
pub fn comment(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, post_url: []const u8, text: []const u8) Error!?[]u8 {
    try validateText(text, max_comment_chars);
    if (!s.allows(post_url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, post_url))) return null;
    if (!(try click(gpa, runner, selectors.comment_button, false))) return null;
    if (!(try typeInto(gpa, runner, selectors.comment_input, text))) return null;
    if (!(try click(gpa, runner, selectors.comment_submit, false))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Opens LinkedIn's search for `query` (`search_type`: people, companies,
/// jobs, content or all). Returns `{"ok":true,"url":...,"resultCount":n}`
/// (result cards on the first page).
pub fn search(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, query: []const u8, search_type: []const u8) Error!?[]u8 {
    const url = try searchUrl(gpa, query, search_type, s.base());
    defer gpa.free(url);
    if (!(try openPage(gpa, runner, url))) return null;
    const count = (try flow.countMatches(gpa, runner, selectors.search_result)) orelse return null;
    return try std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .url = url, .resultCount = count }, .{});
}

/// `<base>/search/results/<type>/?keywords=<query>` (owned).
pub fn searchUrl(gpa: std.mem.Allocator, query: []const u8, search_type: []const u8, base: []const u8) Error![]u8 {
    if (!flow.isPageUrl(base)) return error.InvalidParams;
    const trimmed = std.mem.trim(u8, query, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidParams;
    const chars = std.unicode.utf8CountCodepoints(trimmed) catch return error.InvalidParams;
    if (chars > max_query_chars) return error.InvalidParams;
    for (search_types) |known| {
        if (std.mem.eql(u8, known, search_type)) break;
    } else return error.InvalidParams;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, std.mem.trimEnd(u8, base, "/"));
    try out.print(gpa, "/search/results/{s}/?keywords=", .{search_type});
    try flow.appendQueryValue(gpa, &out, trimmed);
    return try out.toOwnedSlice(gpa);
}

/// Read-only profile summary: `{"name":...,"headline":...|null,"location":...|null}`.
/// The name is required; headline and location are null when the profile
/// shows none.
pub fn extract(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, profile_url: []const u8) Error!?[]u8 {
    if (!s.allows(profile_url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, profile_url))) return null;
    const name = (try profileName(gpa, runner, s)) orelse return null;
    defer gpa.free(name);
    const headline = try optionalText(gpa, runner, selectors.profile_headline) orelse return null;
    defer if (headline.text) |t| gpa.free(t);
    const location = try optionalText(gpa, runner, selectors.profile_location) orelse return null;
    defer if (location.text) |t| gpa.free(t);
    return try std.json.Stringify.valueAlloc(gpa, .{
        .name = name,
        .headline = if (headline.text) |t| std.mem.trim(u8, t, " \t\r\n") else null,
        .location = if (location.text) |t| std.mem.trim(u8, t, " \t\r\n") else null,
    }, .{});
}

/// `{"<selector name>":count,...}` for the whole table on the current page.
pub fn selfCheck(gpa: std.mem.Allocator, runner: anytype) Error!?[]u8 {
    return flow.selectorReport(gpa, runner, selectors);
}

const Optional = struct { text: ?[]u8 };

/// The element's text, or `.text = null` when it is absent; null when a
/// step failed.
fn optionalText(gpa: std.mem.Allocator, runner: anytype, selector: []const u8) Error!?Optional {
    const count = (try flow.countMatches(gpa, runner, selector)) orelse return null;
    if (count == 0) return .{ .text = null };
    const text = (try flow.getText(gpa, runner, selector, read_timeout_ms)) orelse return null;
    return .{ .text = text };
}

pub fn validateText(text: []const u8, max_chars: usize) Error!void {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InvalidParams;
    const chars = std.unicode.utf8CountCodepoints(text) catch return error.InvalidParams;
    if (chars > max_chars) return error.InvalidParams;
}

/// Navigate and pass the login gate.
fn openPage(gpa: std.mem.Allocator, runner: anytype, url: []const u8) Error!bool {
    if (!(try flow.step(gpa, runner, "page.navigate", .{ .url = url, .timeout_ms = flow.budget(runner, navigate_timeout_ms) }))) return false;
    if (try flow.step(gpa, runner, "dom.waitFor", .{ .selector = selectors.signed_in, .state = "attached", .strict = false, .timeout_ms = flow.waitBudget(runner, page_ready_timeout_ms) })) return true;
    const login_links = (try flow.countMatches(gpa, runner, selectors.login_link)) orelse return false;
    if (login_links > 0) return error.LoggedOut;
    return false;
}

/// The profile owner's name from the page title (owned), or null: a step
/// failed, its answer was unusable (malformed), the page is not a profile on
/// the site, e.g. after a redirect (element_not_found linkedin_not_a_profile), or the
/// title names nobody (linkedin_profile_name_missing).
fn profileName(gpa: std.mem.Allocator, runner: anytype, s: flow.Site) Error!?[]u8 {
    {
        const params = try std.json.Stringify.valueAlloc(gpa, .{ .timeout_ms = flow.budget(runner, flow.query_timeout_ms) }, .{});
        defer gpa.free(params);
        const result = (try runner.run("page.url", params)) orelse return null;
        const parsed = std.json.parseFromSlice(struct { url: []const u8 }, gpa, result, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try runner.malformed();
                return null;
            },
        };
        defer parsed.deinit();
        if (!s.allows(parsed.value.url) or !isProfileUrl(parsed.value.url)) {
            try runner.notFound("linkedin_not_a_profile");
            return null;
        }
    }
    const params = try std.json.Stringify.valueAlloc(gpa, .{ .timeout_ms = flow.budget(runner, flow.query_timeout_ms) }, .{});
    defer gpa.free(params);
    const result = (try runner.run("page.title", params)) orelse return null;
    const parsed = std.json.parseFromSlice(struct { title: []const u8 }, gpa, result, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try runner.malformed();
            return null;
        },
    };
    defer parsed.deinit();
    const name = profileNameFromTitle(parsed.value.title) orelse {
        try runner.notFound("linkedin_profile_name_missing");
        return null;
    };
    return try gpa.dupe(u8, name);
}

/// Clicks the profile's own `action` control and nothing else (the flows
/// pass owner_container). Profile buttons render late, so it first waits
/// for a visible copy of the exact label inside the owner area (under no
/// aria-hidden element). The area must be on the page exactly once, and
/// exactly one copy there may have a box: live, the area also holds a
/// display:none copy of Connect, which has none (XPath cannot see
/// display:none; dom.query reports each match's box). That copy is clicked
/// strictly by its position among the matches; every match is the owner's
/// own label inside the owner's area, and the click's own visibility check
/// refuses a hidden one. Nothing outside the area is looked at, so a
/// suggestion card for someone with the same name cannot match, even if it
/// renders first. Fails closed: no visible copy ->
/// linkedin_profile_action_missing; two visible copies, or the area twice
/// -> linkedin_profile_action_ambiguous.
pub fn clickProfileAction(gpa: std.mem.Allocator, runner: anytype, container: []const u8, action: ProfileAction, name: []const u8) Error!bool {
    const own = try profileSelector(gpa, action, name, container);
    defer gpa.free(own);
    const appeared = try flow.step(gpa, runner, "dom.waitFor", .{ .selector = own, .state = "visible", .strict = false, .timeout_ms = flow.waitBudget(runner, page_ready_timeout_ms) });
    const copies = (try visibleCopies(gpa, runner, own)) orelse return false;
    if (copies.total == 0) {
        try runner.notFound("linkedin_profile_action_missing");
        return false;
    }
    // A failed wait with the target present (e.g. cancelled) keeps its failure.
    if (!appeared) return false;
    const area = try std.fmt.allocPrint(gpa, "xpath={s}", .{container});
    defer gpa.free(area);
    const areas = (try flow.countMatches(gpa, runner, area)) orelse return false;
    if (copies.visible > 1 or areas != 1) {
        try runner.notFound("linkedin_profile_action_ambiguous");
        return false;
    }
    if (copies.visible == 0) {
        try runner.notFound("linkedin_profile_action_missing");
        return false;
    }
    if (copies.total == 1) return click(gpa, runner, own, true);
    const copy = try std.fmt.allocPrint(gpa, "xpath=({s})[{d}]", .{ own["xpath=".len..], copies.first_visible });
    defer gpa.free(copy);
    return click(gpa, runner, copy, true);
}

const Copies = struct { total: usize, visible: usize, first_visible: usize };

/// How many elements `selector` matches, how many of them have a box
/// (width and height above 0; a display:none element has none), and the
/// 1-based position of the first that does. Null when the query failed or
/// answered something unusable.
fn visibleCopies(gpa: std.mem.Allocator, runner: anytype, selector: []const u8) Error!?Copies {
    const params = try std.json.Stringify.valueAlloc(gpa, .{ .selector = selector, .timeout_ms = flow.budget(runner, flow.query_timeout_ms) }, .{});
    defer gpa.free(params);
    const result = (try runner.run("dom.query", params)) orelse return null;
    const Box = struct { width: f64 = 0, height: f64 = 0 };
    const Element = struct { bbox: Box = .{} };
    const parsed = std.json.parseFromSlice(struct { elements: []const Element }, gpa, result, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try runner.malformed();
            return null;
        },
    };
    defer parsed.deinit();
    var copies = Copies{ .total = parsed.value.elements.len, .visible = 0, .first_visible = 0 };
    for (parsed.value.elements, 1..) |element, n| {
        if (!(element.bbox.width > 0 and element.bbox.height > 0)) continue;
        if (copies.visible == 0) copies.first_visible = n;
        copies.visible += 1;
    }
    return copies;
}

/// The owner area `action` may click in (owner_container), or null after
/// element_not_found linkedin_profile_owner_unverified while the action is
/// not ownerActionEnabled and no test set `s.unverified_actions`: the flow
/// stops before any click.
fn ownerArea(runner: anytype, s: flow.Site, action: ProfileAction) Error!?[]const u8 {
    if (ownerActionEnabled(action) or s.unverified_actions) return owner_container;
    try runner.notFound("linkedin_profile_owner_unverified");
    return null;
}

/// Waits for the profile's own `state` (pending, following) in `container`.
fn waitProfileState(gpa: std.mem.Allocator, runner: anytype, container: []const u8, state: ProfileAction, name: []const u8) Error!bool {
    const selector = try profileSelector(gpa, state, name, container);
    defer gpa.free(selector);
    return waitAttached(gpa, runner, selector);
}

fn click(gpa: std.mem.Allocator, runner: anytype, selector: []const u8, strict: bool) Error!bool {
    return flow.step(gpa, runner, "dom.click", .{ .selector = selector, .options = .{ .strict = strict, .timeout_ms = flow.budget(runner, click_timeout_ms) } });
}

fn waitAttached(gpa: std.mem.Allocator, runner: anytype, selector: []const u8) Error!bool {
    return flow.step(gpa, runner, "dom.waitFor", .{ .selector = selector, .state = "attached", .strict = false, .timeout_ms = flow.waitBudget(runner, confirm_timeout_ms) });
}

/// Focus a rich editor, clear what is there, type `text`.
fn typeInto(gpa: std.mem.Allocator, runner: anytype, selector: []const u8, text: []const u8) Error!bool {
    if (!(try click(gpa, runner, selector, true))) return false;
    if (!(try flow.step(gpa, runner, "dom.fill", .{ .selector = selector, .value = "", .options = .{ .timeout_ms = flow.budget(runner, click_timeout_ms) } }))) return false;
    return flow.step(gpa, runner, "dom.type", .{ .selector = selector, .text = text, .options = .{ .timeout_ms = flow.budget(runner, flow.typingTimeoutMs(text, false)) } });
}
