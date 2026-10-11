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
    /// Profile header actions (live, 2026-10-11: Follow is a <button>,
    /// Message a div[role=button]). They render a few seconds after the
    /// page loads; the flows' clicks wait for them (missing elements are
    /// retried until the step's deadline).
    pub const follow_button = "xpath=//header//button[normalize-space(.)=\"Follow\"]";
    /// After Follow (live, 2026-10-11: a real follow): the same header
    /// button reads "Following" (or "Requested" for a private account)
    /// plus a chevron <svg> whose <title> "Down chevron icon" is text too,
    /// so its textContent is "FollowingDown chevron icon". It matches when
    /// its visible text, svg titles left out, is exactly that, under no
    /// aria-hidden element; the flow requires exactly one visible copy. The
    /// suggested accounts' Follow buttons below the header never match.
    pub const following_button = "xpath=//header//button[" ++ flow.visibleTextIs("Following") ++ " or " ++ flow.visibleTextIs("Requested") ++ "][not(ancestor-or-self::*[@aria-hidden=\"true\"])]";
    pub const message_button = "xpath=//header//*[self::button or @role=\"button\"][normalize-space(.)=\"Message\"]";
    /// Post page: the post's own action bar (the first <section>); comment
    /// likes sit in lists, not in it.
    pub const like_button = "xpath=(//section//*[name()=\"svg\" and @aria-label=\"Like\"])[1]";
    pub const unlike_marker = "xpath=(//section//*[name()=\"svg\" and @aria-label=\"Unlike\"])[1]";
    pub const comment_input = "css=textarea[aria-label=\"Add a comment\u{2026}\"]";
    pub const comment_submit = "xpath=//form//*[self::button or @role=\"button\"][normalize-space(.)=\"Post\"]";
    /// Direct message composer.
    pub const dm_input = "css=div[aria-label=\"Message\"][contenteditable=\"true\"]";
    /// Send, by its visible text (an icon's <title> is text too), only
    /// inside the DM box's own container: its parent element, a fixed
    /// boundary that does not depend on finding a Send (walking up to the
    /// first ancestor holding any Send could reach a share sheet's; RoseCat
    /// 5194, audit 7c9d68a). UNVERIFIED live: that Send sits under the box's
    /// parent (if not, the DM fails closed, nothing else is clicked), and no
    /// check that the message arrived.
    pub const dm_send = "xpath=(//div[@aria-label=\"Message\"][@contenteditable=\"true\"])/parent::*//" ++
        dm_send_button ++ "[not(ancestor-or-self::*[@aria-hidden=\"true\"])]";
    /// Story viewer media, and its Next control, from the live viewer
    /// (probe of 2026-10-11): the page behind the viewer is in <main> and
    /// has a zero-size <button aria-label="Next">; the viewer is outside
    /// <main>, its controls are <svg aria-label="Next|Previous|Close|Pause">
    /// inside a div[role=button], its frame a <video> (story previews and
    /// avatars are images inside links). A profile's highlights carousel has
    /// a "Next" and avatars too, so these only count on a /stories/ page:
    /// story_view checks the URL's path before using them, and selfcheck
    /// reports them as 0 anywhere else. Next must match exactly once: a
    /// second one fails the flow closed instead of being clicked.
    pub const story_media = "xpath=//section[not(ancestor::main)]//video | //section[not(ancestor::main)]//img[not(ancestor::a)]";
    pub const story_next = "xpath=//*[name()=\"svg\" and @aria-label=\"Next\"][not(ancestor::main)]/ancestor::*[@role=\"button\"][1]";
    /// A "View story" button in front of the viewer: viewing would need a
    /// click that marks the story seen, so a dry run stops before it.
    /// UNVERIFIED live (not seen in the 2026-10-11 probe, whose viewer was
    /// already playing); used only to stop, never clicked.
    /// Matched by its visible text anywhere on the page (an icon <title>
    /// must not hide it): a stop check may stop too often, never too
    /// seldom (audit 7c9d68a).
    pub const story_view_gate = "xpath=//*[self::button or @role=\"button\"][" ++ flow.visibleTextIs("View story") ++ "]";
};

/// Whether story_view may wait for story media and click Next at all. On
/// since the live viewer was probed (2026-10-11): story_media and story_next
/// are scoped to the viewer, outside the page behind it (review 4975). While
/// off, story_view would open the story URL, check it, then stop:
/// element_not_found instagram_story_viewer_unverified (tests could still
/// run the frames through flow_steps.Site.unverified_actions).
pub const story_viewer_verified = true;

/// A clickable whose visible text is exactly "Send".
const dm_send_button = "*[self::button or @role=\"button\"][" ++ flow.visibleTextIs("Send") ++ "]";

/// The real site. The automation server may swap in a fixture origin for
/// tests (flow_steps.Site); requests cannot.
pub const site = flow.Site{ .host = "www.instagram.com", .origin = "https://www.instagram.com" };

/// Instagram's session cookie: without it the account is logged out, and
/// an action fails before navigating (checked by the automation server).
pub const session_cookie = "sessionid";

/// Story viewing: time on each frame, and a bound on frames.
pub const story_frame_ms = 1_500;
pub const max_story_frames = 100;
/// Budget kept, beside the frame's viewing time, for one Next click and a
/// frame's three queries: whose story it is (before Next), the Next query,
/// and whose story it is after the click.
const reserve_ms = click_timeout_ms + 3 * flow.query_timeout_ms;

/// Instagram's limits for a comment and a direct message.
pub const max_comment_chars = 2200;
pub const max_dm_chars = 1000;

const navigate_timeout_ms = 30_000;
const page_ready_timeout_ms = 15_000;
const click_timeout_ms = 10_000;
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
    // Exactly one visible Following/Requested state (RoseCat 7c9d68a).
    if (!(try flow.step(gpa, runner, "dom.waitFor", .{ .selector = selectors.following_button, .state = "visible", .strict = true, .timeout_ms = flow.waitBudget(runner, confirm_timeout_ms) }))) return null;
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
    if (!(try flow.step(gpa, runner, "dom.type", .{ .selector = selectors.comment_input, .text = text, .options = .{ .timeout_ms = flow.budget(runner, flow.typingTimeoutMs(text, false)) } }))) return null;
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
    if (!(try flow.step(gpa, runner, "dom.type", .{ .selector = selectors.dm_input, .text = text, .options = .{ .timeout_ms = flow.budget(runner, flow.typingTimeoutMs(text, false)) } }))) return null;
    if (!(try click(gpa, runner, selectors.dm_send, true))) return null;
    return try gpa.dupe(u8, ok_json);
}

/// Opens `username`'s stories and views them (viewStoryFrames) while
/// story_viewer_verified; otherwise it stops after checking the page.
/// Returns `{"ok":true,"framesViewed":n}`.
pub fn storyView(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, username: []const u8) Error!?[]u8 {
    const url = try userUrl(gpa, s.base(), "stories/", username);
    defer gpa.free(url);
    if (!(try openPage(gpa, runner, url))) return null;
    // Without active stories Instagram shows the profile instead; its
    // highlights would match the story selectors, so fail closed. Another
    // person's stories are not the requested viewer either.
    const in_viewer = (try onStories(gpa, runner, s, username)) orelse return null;
    if (!in_viewer) {
        try runner.notFound("instagram_no_story_viewer");
        return null;
    }
    if (!story_viewer_verified and !s.unverified_actions) {
        try runner.notFound("instagram_story_viewer_unverified");
        return null;
    }
    // Viewing would need a click that marks the story seen: never click it.
    const gates = (try flow.countMatches(gpa, runner, selectors.story_view_gate)) orelse return null;
    if (gates > 0) {
        try runner.notFound("instagram_story_view_needs_click");
        return null;
    }
    return viewStoryFrames(gpa, runner, s, username);
}

/// On `username`'s open story viewer: views the frames in order, each for
/// story_frame_ms, then Next, until there is no Next, the viewer closes or
/// moves on to someone else's stories (the page leaves
/// /stories/<username>/), max_story_frames, or the flow budget would not
/// cover another frame. Instagram also moves on by itself when a frame ends,
/// so the URL is checked before every Next, not only after it (review
/// 5046): Next is never counted or clicked on someone else's story. Every
/// step is clamped to the flow budget. More than one Next fails closed
/// (instagram_story_next_ambiguous).
pub fn viewStoryFrames(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, username: []const u8) Error!?[]u8 {
    if (!(try waitAttached(gpa, runner, selectors.story_media))) return null;
    // View the first frame, then Next + view until the viewer closes.
    if (!runner.pause(@min(story_frame_ms, runner.remainingMs() -| reserve_ms))) return null;
    var frames: usize = 1;
    while (frames < max_story_frames) {
        if (runner.remainingMs() <= story_frame_ms + reserve_ms) break;
        // Still `username`'s story after the frame's viewing time?
        const still_theirs = (try onStories(gpa, runner, s, username)) orelse return null;
        if (!still_theirs) break;
        const next = (try flow.countMatches(gpa, runner, selectors.story_next)) orelse return null;
        if (next == 0) break;
        if (next > 1) {
            try runner.notFound("instagram_story_next_ambiguous");
            return null;
        }
        const clicked = try click(gpa, runner, selectors.story_next, true);
        // The frame's viewing time also lets a closing viewer leave.
        if (!runner.pause(story_frame_ms)) return null;
        // Positive evidence only: the viewer closed (or went on to another
        // person) when the page left /stories/<username>/ (the last Next does
        // that). A failed click on a viewer that is still open keeps its own
        // failure.
        const on_stories = (try onStories(gpa, runner, s, username)) orelse return null;
        if (!on_stories) break;
        // (The runner still holds the click's failure: a successful URL
        // check does not replace it.)
        if (!clicked) return null;
        frames += 1;
    }
    return try std.json.Stringify.valueAlloc(gpa, .{ .ok = true, .framesViewed = frames }, .{});
}

/// Still in the story viewer: the URL is a story (/stories/<x>) on `s`, and
/// `username`'s when given (any origin and user when null: selfcheck only
/// reports), with the page call clamped to the flow budget; null when the
/// step failed or answered something unusable.
fn onStories(gpa: std.mem.Allocator, runner: anytype, s: ?flow.Site, username: ?[]const u8) Error!?bool {
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
    if (s) |site_| if (!site_.allows(parsed.value.url)) return false;
    if (username) |user| return isStoryOf(parsed.value.url, user);
    return isStoryUrl(parsed.value.url);
}

/// `url`'s path is `username`'s story: /stories/<username>[/...], the name
/// compared ignoring ASCII case.
pub fn isStoryOf(url: []const u8, username: []const u8) bool {
    if (!isStoryUrl(url)) return false;
    const scheme_end = std.mem.indexOf(u8, url, "://").?;
    const after = url[scheme_end + 3 ..];
    const path = after[std.mem.indexOfAny(u8, after, "/?#").?..];
    const rest = path["/stories/".len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return std.ascii.eqlIgnoreCase(rest[0..end], username);
}

/// `url`'s path is a story: /stories/<something>.
pub fn isStoryUrl(url: []const u8) bool {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return false;
    const after = url[scheme_end + 3 ..];
    const path_start = std.mem.indexOfAny(u8, after, "/?#") orelse return false;
    const path = after[path_start..];
    const prefix = "/stories/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len > prefix.len and std.mem.indexOfScalar(u8, "/?#", path[prefix.len]) == null;
}

/// `{"<selector name>":count,...}` for the whole table on the current page;
/// the story entries are 0 off a /stories/ URL (not queried).
pub fn selfCheck(gpa: std.mem.Allocator, runner: anytype) Error!?[]u8 {
    const in_viewer = (try onStories(gpa, runner, null, null)) orelse return null;
    const story_entries = [_][]const u8{ "story_media", "story_next", "story_view_gate" };
    return flow.selectorReportExcept(gpa, runner, selectors, if (in_viewer) &.{} else &story_entries);
}

/// The acting flows a dry run (options.dry_run) covers.
pub const DryVerb = enum { follow, like, comment, story_view };

/// Dry run of `verb` (see flow_steps' "Dry runs"): the real flow's steps up
/// to its committing click, then a trial click on that click's exact target
/// instead. `target` is the profile URL (follow), the post URL (like,
/// comment) or the username (story_view). Returns `{"dry_run":true,...}`
/// (owned), or null / an error exactly where the real flow fails. Targets:
/// Follow, the like button, the comment box (its Post button stays
/// disabled until there is text, so it is only counted), and the viewer's
/// Next. story_view opens only the story URL the real flow opens (Instagram
/// may count that first frame as seen: reported as a note), never pauses on
/// a frame, and stops before a "View story" click.
pub fn dryRun(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, verb: DryVerb, target: []const u8) Error!?[]u8 {
    if (verb == .story_view) return dryStoryView(gpa, runner, s, target);
    if (!s.allows(target)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, target))) return null;
    switch (verb) {
        .follow => {
            const element = (try flow.trialTarget(gpa, runner, selectors.follow_button, true, click_timeout_ms)) orelse return null;
            defer gpa.free(element.tag);
            return try flow.dryRunResult(gpa, "follow", .{ .tag = element.tag, .label = "Follow", .box = element.box }, &.{
                flow.pass("signed_in"),
                flow.pass("actionable"),
                flow.notReached("following_state", "appears only after the Follow click"),
            });
        },
        .like => {
            const element = (try flow.trialTarget(gpa, runner, selectors.like_button, true, click_timeout_ms)) orelse return null;
            defer gpa.free(element.tag);
            return try flow.dryRunResult(gpa, "like", .{ .tag = element.tag, .label = "Like", .box = element.box }, &.{
                flow.pass("signed_in"),
                flow.pass("actionable"),
                flow.notReached("unlike_state", "appears only after the Like click"),
            });
        },
        .comment => {
            const element = (try flow.trialTarget(gpa, runner, selectors.comment_input, true, click_timeout_ms)) orelse return null;
            defer gpa.free(element.tag);
            const posts = (try flow.countMatches(gpa, runner, selectors.comment_submit)) orelse return null;
            return try flow.dryRunResult(gpa, "comment", .{ .tag = element.tag, .label = "Add a comment\u{2026}", .box = element.box }, &.{
                flow.pass("signed_in"),
                flow.pass("actionable"),
                flow.counted("post_button", posts),
                flow.notReached("post_click", "Post is used only after the comment is typed"),
            });
        },
        .story_view => unreachable,
    }
}

fn dryStoryView(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, username: []const u8) Error!?[]u8 {
    const url = try userUrl(gpa, s.base(), "stories/", username);
    defer gpa.free(url);
    if (!(try openPage(gpa, runner, url))) return null;
    // The real flow's checks, in its order.
    const in_viewer = (try onStories(gpa, runner, s, username)) orelse return null;
    if (!in_viewer) {
        try runner.notFound("instagram_no_story_viewer");
        return null;
    }
    if (!story_viewer_verified and !s.unverified_actions) {
        try runner.notFound("instagram_story_viewer_unverified");
        return null;
    }
    const first_frame = flow.Check{ .name = "first_frame", .result = "note", .reason = "opened by the flow's own navigation; Instagram may count it as seen" };
    const gates = (try flow.countMatches(gpa, runner, selectors.story_view_gate)) orelse return null;
    if (gates > 0) {
        return try flow.dryRunResult(gpa, "story_view", null, &.{
            flow.pass("signed_in"),
            flow.pass("story_url"),
            flow.notReached("view_story_click", "instagram_story_view_needs_click: opening the viewer needs a click that marks the story seen"),
        });
    }
    if (!(try waitAttached(gpa, runner, selectors.story_media))) return null;
    const next = (try flow.countMatches(gpa, runner, selectors.story_next)) orelse return null;
    if (next > 1) {
        try runner.notFound("instagram_story_next_ambiguous");
        return null;
    }
    if (next == 0) {
        return try flow.dryRunResult(gpa, "story_view", null, &.{
            flow.pass("signed_in"),
            flow.pass("story_url"),
            flow.pass("story_media"),
            .{ .name = "next", .count = 0, .reason = "no Next: the real flow views one frame and stops" },
            first_frame,
        });
    }
    const element = (try flow.trialTarget(gpa, runner, selectors.story_next, true, click_timeout_ms)) orelse return null;
    defer gpa.free(element.tag);
    return try flow.dryRunResult(gpa, "story_view", .{ .tag = element.tag, .label = "Next", .box = element.box }, &.{
        flow.pass("signed_in"),
        flow.pass("story_url"),
        flow.pass("story_media"),
        flow.counted("next", 1),
        flow.pass("actionable"),
        first_frame,
    });
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
