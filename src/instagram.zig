//! Instagram (instagram.com) flows. Each flow is a fixed sequence of
//! ordinary automation commands (page.navigate, dom.*), so it gets the
//! engine's retries, actionability checks and telemetry. The runner is
//! duck-typed; see src/flow_steps.zig for its contract.
//!
//! Every flow opens its page and passes the login gate first: a signed-in
//! marker must appear; if instead the page offers a login form or link, the
//! account is logged out (error.LoggedOut) and nothing is clicked or typed.
const std = @import("std");
const flow = @import("flow_steps.zig");

/// Every Instagram selector, in one place. Instagram changes its markup;
/// check with `instagram.selfcheck` on a logged-in page and update here.
pub const selectors = struct {
    /// Signs of a signed-in page: the navigation's Home icon or inbox link.
    pub const signed_in = "css=svg[aria-label=\"Home\"], a[href=\"/direct/inbox/\"]";
    /// Signs of a logged-out page.
    pub const login_link = "css=a[href^=\"/accounts/login\"], input[name=\"username\"]";
    /// Profile header actions.
    pub const follow_button = "xpath=//header//button[normalize-space(.)=\"Follow\"]";
    pub const following_button = "xpath=//header//button[normalize-space(.)=\"Following\" or normalize-space(.)=\"Requested\"]";
    pub const message_button = "xpath=//header//*[self::button or @role=\"button\"][normalize-space(.)=\"Message\"]";
    /// Post page: the post's own action bar (the first <section>); comment
    /// likes sit in lists, not in it.
    pub const like_button = "xpath=(//section//*[name()=\"svg\" and @aria-label=\"Like\"])[1]";
    pub const unlike_marker = "xpath=(//section//*[name()=\"svg\" and @aria-label=\"Unlike\"])[1]";
    pub const comment_input = "css=textarea[aria-label=\"Add a comment\u{2026}\"]";
    pub const comment_submit = "xpath=//form//*[self::button or @role=\"button\"][normalize-space(.)=\"Post\"]";
    /// Direct message composer.
    pub const dm_input = "css=div[aria-label=\"Message\"][contenteditable=\"true\"]";
    pub const dm_send = "xpath=//*[self::button or @role=\"button\"][normalize-space(.)=\"Send\"]";
    /// Story viewer media, and its Next control.
    pub const story_media = "css=section video, section img";
    pub const story_next = "css=button[aria-label=\"Next\"]";
};

/// The real site. The automation server may swap in a fixture origin for
/// tests (flow_steps.Site); requests cannot.
pub const site = flow.Site{ .host = "www.instagram.com", .origin = "https://www.instagram.com" };

/// Instagram's session cookie: without it the account is logged out, and
/// an action fails before navigating (checked by the automation server).
pub const session_cookie = "sessionid";

/// Story viewing: time on each frame, and a bound on frames.
pub const story_frame_ms = 1_500;
pub const max_story_frames = 100;
/// Budget kept for one Next click, the Next query and the URL check of a
/// frame.
const reserve_ms = click_timeout_ms + 2 * flow.query_timeout_ms;

/// Instagram's limits for a comment and a direct message.
pub const max_comment_chars = 2200;
pub const max_dm_chars = 1000;

const navigate_timeout_ms = 30_000;
const page_ready_timeout_ms = 15_000;
const click_timeout_ms = 10_000;
const type_timeout_ms = 30_000;
const confirm_timeout_ms = 15_000;

pub const Verb = enum { follow, like, comment, dm, story_view, selfcheck };

pub fn verbFromMethod(method: []const u8) ?Verb {
    const prefix = "instagram.";
    if (!std.mem.startsWith(u8, method, prefix)) return null;
    return std.meta.stringToEnum(Verb, method[prefix.len..]);
}

/// Verbs that act on Instagram (paced and capped); selfcheck only reads.
pub fn isAction(verb: Verb) bool {
    return verb != .selfcheck;
}

pub const Error = flow.Error;

const ok_json = "{\"ok\":true}";

/// Follows a profile and waits for Following (or Requested, for a private
/// account).
pub fn follow(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, profile_url: []const u8) Error!?[]u8 {
    if (!s.allows(profile_url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, profile_url))) return null;
    if (!(try click(gpa, runner, selectors.follow_button, true))) return null;
    if (!(try waitAttached(gpa, runner, selectors.following_button))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Likes a post and waits for the Unlike state.
pub fn like(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, post_url: []const u8) Error!?[]u8 {
    if (!s.allows(post_url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, post_url))) return null;
    if (!(try click(gpa, runner, selectors.like_button, true))) return null;
    if (!(try waitAttached(gpa, runner, selectors.unlike_marker))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Comments on a post (the text is typed).
pub fn comment(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, post_url: []const u8, text: []const u8) Error!?[]u8 {
    try validateText(text, max_comment_chars);
    if (!s.allows(post_url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, post_url))) return null;
    if (!(try click(gpa, runner, selectors.comment_input, true))) return null;
    if (!(try flow.step(gpa, runner, "dom.fill", .{ .selector = selectors.comment_input, .value = "", .options = .{ .timeout_ms = flow.budget(runner, click_timeout_ms) } }))) return null;
    if (!(try flow.step(gpa, runner, "dom.type", .{ .selector = selectors.comment_input, .text = text, .options = .{ .timeout_ms = flow.budget(runner, type_timeout_ms) } }))) return null;
    if (!(try click(gpa, runner, selectors.comment_submit, true))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Opens `username`'s profile, presses Message and sends `text`.
pub fn dm(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, username: []const u8, text: []const u8) Error!?[]u8 {
    try validateText(text, max_dm_chars);
    const url = try userUrl(gpa, s.base(), "", username);
    defer gpa.free(url);
    if (!(try openPage(gpa, runner, url))) return null;
    if (!(try click(gpa, runner, selectors.message_button, true))) return null;
    if (!(try click(gpa, runner, selectors.dm_input, true))) return null;
    if (!(try flow.step(gpa, runner, "dom.type", .{ .selector = selectors.dm_input, .text = text, .options = .{ .timeout_ms = flow.budget(runner, type_timeout_ms) } }))) return null;
    if (!(try click(gpa, runner, selectors.dm_send, true))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Opens `username`'s stories and views them in order: each frame for
/// story_frame_ms, then Next, until there is no Next, the viewer closes (no
/// story media left), max_story_frames, or the flow budget would not cover
/// another frame. Every step is clamped to the flow budget. Returns
/// `{"ok":true,"framesViewed":n}`.
pub fn storyView(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, username: []const u8) Error!?[]u8 {
    const url = try userUrl(gpa, s.base(), "stories/", username);
    defer gpa.free(url);
    if (!(try openPage(gpa, runner, url))) return null;
    if (!(try waitAttached(gpa, runner, selectors.story_media))) return null;
    // View the first frame, then Next + view until the viewer closes.
    if (!runner.pause(@min(story_frame_ms, runner.remainingMs() -| reserve_ms))) return null;
    var frames: usize = 1;
    while (frames < max_story_frames) {
        if (runner.remainingMs() <= story_frame_ms + reserve_ms) break;
        const next = (try flow.countMatches(gpa, runner, selectors.story_next)) orelse return null;
        if (next == 0) break;
        const clicked = try click(gpa, runner, selectors.story_next, false);
        // The frame's viewing time also lets a closing viewer leave.
        if (!runner.pause(story_frame_ms)) return null;
        // Positive evidence only: the viewer closed when the page left
        // /stories/ (the last Next does that). A failed click on a viewer
        // that is still open keeps its own failure.
        const on_stories = (try onStories(gpa, runner)) orelse return null;
        if (!on_stories) break;
        // (The runner still holds the click's failure: a successful URL
        // check does not replace it.)
        if (!clicked) return null;
        frames += 1;
    }
    return try std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .framesViewed = frames }, .{});
}

/// Still in the story viewer (the URL is on /stories/), with the page call
/// clamped to the flow budget; null when the step failed or answered
/// something unusable.
fn onStories(gpa: std.mem.Allocator, runner: anytype) Error!?bool {
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
    return std.mem.indexOf(u8, parsed.value.url, "/stories/") != null;
}

/// `{"<selector name>":count,...}` for the whole table on the current page.
pub fn selfCheck(gpa: std.mem.Allocator, runner: anytype) Error!?[]u8 {
    return flow.selectorReport(gpa, runner, selectors);
}

/// Instagram usernames: 1-30 of letters, digits, '.' and '_'.
pub fn isUsername(name: []const u8) bool {
    if (name.len == 0 or name.len > 30) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_') return false;
    return true;
}

/// `<base>/<prefix><username>/` (owned).
pub fn userUrl(gpa: std.mem.Allocator, base: []const u8, prefix: []const u8, username: []const u8) Error![]u8 {
    if (!flow.isPageUrl(base) or !isUsername(username)) return error.InvalidParams;
    return std.fmt.allocPrint(gpa, "{s}/{s}{s}/", .{ std.mem.trimEnd(u8, base, "/"), prefix, username });
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
