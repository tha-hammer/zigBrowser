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
pub const selectors = struct {
    /// Signs of a signed-in page: the global nav "Me" control.
    pub const signed_in = "css=.global-nav__me, .global-nav__me-photo";
    /// Signs of a signed-out page.
    pub const login_link = "css=a[href*=\"/login\"], a[href*=\"/uas/login\"], .sign-in-form";
    /// Profile actions (inside <main>, so suggestion cards do not match).
    pub const connect_button = "css=main button[aria-label^=\"Invite \"][aria-label$=\" to connect\"]";
    pub const pending_button = "css=main button[aria-label^=\"Pending\"]";
    pub const follow_button = "css=main button[aria-label^=\"Follow \"]";
    pub const following_button = "css=main button[aria-label^=\"Following \"], main button[aria-label^=\"Unfollow \"]";
    pub const message_button = "css=main a[href*=\"/messaging/compose\"], main button[aria-label^=\"Message \"]";
    /// Connect dialog.
    pub const add_note_button = "css=button[aria-label=\"Add a note\"]";
    pub const note_input = "css=textarea[name=\"message\"]";
    pub const send_invite_button = "css=button[aria-label=\"Send invitation\"], button[aria-label=\"Send now\"]";
    pub const send_without_note_button = "css=button[aria-label=\"Send without a note\"]";
    /// Messaging.
    pub const message_input = "css=.msg-form__contenteditable[contenteditable=\"true\"]";
    pub const message_send_button = "css=button.msg-form__send-button";
    /// Posts (the first social bar on a post page is the post's own).
    pub const like_button = "css=button.react-button__trigger[aria-pressed=\"false\"]";
    pub const liked_button = "css=button.react-button__trigger[aria-pressed=\"true\"]";
    pub const comment_button = "css=button[aria-label=\"Comment\"]";
    pub const comment_input = "css=.comments-comment-box__form [contenteditable=\"true\"]";
    pub const comment_submit = "css=button.comments-comment-box__submit-button";
    /// Profile summary (linkedin.extract).
    pub const profile_name = "css=main h1";
    pub const profile_headline = "css=main .text-body-medium.break-words";
    pub const profile_location = "css=main .text-body-small.inline.t-black--light.break-words";
    /// One search result card.
    pub const search_result = "css=.reusable-search__result-container";
};

/// The real site. The automation server may swap in a fixture origin for
/// tests (flow_steps.Site); requests cannot.
pub const site = flow.Site{ .host = "www.linkedin.com", .origin = "https://www.linkedin.com" };

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
    if (!(try click(gpa, runner, selectors.connect_button, true))) return null;
    if (note) |text| {
        if (!(try click(gpa, runner, selectors.add_note_button, true))) return null;
        if (!(try typeInto(gpa, runner, selectors.note_input, truncateNote(text)))) return null;
        if (!(try click(gpa, runner, selectors.send_invite_button, false))) return null;
    } else {
        if (!(try click(gpa, runner, selectors.send_without_note_button, true))) return null;
    }
    if (!(try waitAttached(gpa, runner, selectors.pending_button))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Follows a profile and waits for the Following state.
pub fn follow(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, profile_url: []const u8) Error!?[]u8 {
    if (!s.allows(profile_url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, profile_url))) return null;
    if (!(try click(gpa, runner, selectors.follow_button, true))) return null;
    if (!(try waitAttached(gpa, runner, selectors.following_button))) return null;
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
        if (!(try click(gpa, runner, selectors.message_button, false))) return null;
    }
    if (!(try typeInto(gpa, runner, selectors.message_input, text))) return null;
    if (!(try click(gpa, runner, selectors.message_send_button, true))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Likes a post (its first reaction button) and waits for the pressed state.
pub fn like(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, post_url: []const u8) Error!?[]u8 {
    if (!s.allows(post_url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, post_url))) return null;
    if (!(try click(gpa, runner, selectors.like_button, false))) return null;
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
    const name = (try flow.getText(gpa, runner, selectors.profile_name, read_timeout_ms)) orelse return null;
    defer gpa.free(name);
    const headline = try optionalText(gpa, runner, selectors.profile_headline) orelse return null;
    defer if (headline.text) |t| gpa.free(t);
    const location = try optionalText(gpa, runner, selectors.profile_location) orelse return null;
    defer if (location.text) |t| gpa.free(t);
    return try std.json.Stringify.valueAlloc(gpa, .{
        .name = std.mem.trim(u8, name, " \t\r\n"),
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
