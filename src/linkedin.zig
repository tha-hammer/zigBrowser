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
    /// Live (2026-10-11): "Following, click to unfollow <Name>".
    pub const following_button = "css=main button[aria-label^=\"Following\"], main button[aria-label^=\"Unfollow\"]";
    pub const message_button = "css=main a[href*=\"/messaging/compose\"], main button[aria-label^=\"Message \"]";
    /// Suggestion-card actions inside an <aside>, which the profile flows
    /// leave out. UNVERIFIED live: on a profile page this should be about
    /// connect_button + follow_button minus the profile's own; 0 there
    /// means the cards are not in an <aside> and the scoping needs a new
    /// anchor.
    pub const suggested_actions = "xpath=//aside//*[starts-with(@aria-label, \"Invite \") or starts-with(@aria-label, \"Follow \")]";
    /// The owner's "More" button (in owner_container, under no aria-hidden
    /// element). Live: two in the owner area, one of them hidden (the
    /// sticky header's copy). UNVERIFIED live: its label (text "More" seen).
    pub const owner_more_button = "xpath=" ++ owner_container ++ more_button_path;
    /// The Connect item of the menu the owner's More opens: the innermost
    /// clickable whose visible text (svg titles left out) is exactly
    /// "Connect" (live; its label has only the first name), inside the
    /// owner area or a role=menu. UNVERIFIED
    /// live: where the open menu sits (inside the owner area, or a
    /// role=menu elsewhere); neither -> the flow finds no item and refuses.
    /// When the owner's More names its menu (aria-controls), only that menu
    /// is searched instead (see `clickMenuConnect`).
    pub const more_menu_connect = "xpath=(" ++ owner_container ++ " | //*[@role=\"menu\"])" ++ menu_connect_item;
    /// Checked before the owner's More is clicked, and must show nothing: any
    /// open role=menu, or a menu Connect item already shown (another
    /// person's menu could hold it; RoseCat 5157).
    pub const open_menu_or_item = "xpath=//*[@role=\"menu\"]" ++ not_hidden ++ " | " ++ more_menu_connect["xpath=".len..];
    /// Connect dialog. Live (2026-10-11): it opens 3-5 s after the Connect
    /// click, inside an open shadow root (pierce=), with the buttons
    /// Dismiss, Add a note and Send without a note. UNVERIFIED live: the
    /// note box and its Send button.
    pub const add_note_button = "pierce=role=button[name=\"Add a note\"]";
    pub const note_input = "pierce=css=textarea[name=\"message\"]";
    pub const send_invite_button = "pierce=css=button[aria-label=\"Send invitation\"], button[aria-label=\"Send now\"]";
    pub const send_without_note_button = "pierce=role=button[name=\"Send without a note\"]";
    /// The toast after an invitation (live: role=alert, "Invitation sent to
    /// <first name>."). For linkedin.selfcheck only: the owner's Pending
    /// label decides, since a toast can come from anything.
    pub const invite_sent_toast = "xpath=//*[@role=\"alert\" or @aria-live][starts-with(normalize-space(.), \"Invitation sent\")]";
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
/// owner's name (see `profileNameFromTitle`). Live (2026-10-11): "Pending,
/// click to withdraw invitation sent to <Name>" and "Following, click to
/// unfollow <Name>". Connect may sit under the owner's "More" menu instead
/// (see `connect`); follow and message are never looked for there.
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

/// Under no aria-hidden element (the sticky toolbar's clone is aria-hidden).
const not_hidden = "[not(ancestor-or-self::*[@aria-hidden=\"true\"])]";
const clickable = "self::button or self::a or @role=\"button\" or @role=\"menuitem\"";
/// A menu's Connect item below a menu: the innermost clickable whose visible
/// text is exactly "Connect", under no aria-hidden element.
const menu_connect_item = "//*[" ++ clickable ++ "][" ++ flow.visibleTextIs("Connect") ++ "][not(.//*[" ++ clickable ++ "][" ++ flow.visibleTextIs("Connect") ++ "])]" ++ not_hidden;
/// The owner's More button, below an owner area.
const more_button_path = "//button[normalize-space(.)=\"More\" or @aria-label=\"More\" or @aria-label=\"More actions\"]" ++ not_hidden;

/// Whether a profile action may click at all. Connect and follow: on, in
/// owner_container. Message: OFF, since the profile's own Message was not
/// on the probed profile; the flow opens and checks the profile, then stops
/// before any click: element_not_found linkedin_profile_owner_unverified
/// (tests run it through flow_steps.Site.unverified_actions). UNVERIFIED
/// live: the note box of the invite dialog.
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
            try out.appendSlice(gpa, "(starts-with(@aria-label, \"Following\") or starts-with(@aria-label, \"Unfollow\")) and contains(@aria-label, ");
            try xpathLiteral(gpa, &out, &.{name});
            try out.append(gpa, ')');
        },
    }
    try out.append(gpa, ']');
    if (container != null) try out.appendSlice(gpa, not_hidden);
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

/// A cold profile load on the live site took more than 30 s (live dry run,
/// 2026-10-11); the flow's budget still bounds it.
const navigate_timeout_ms = 60_000;
const page_ready_timeout_ms = 15_000;
const click_timeout_ms = 10_000;
const confirm_timeout_ms = 15_000;
/// The invite dialog took 3-5 s to open live (2026-10-11).
const dialog_timeout_ms = 15_000;
/// A menu opens at once; its items render with it.
const menu_timeout_ms = 5_000;
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
/// Connect is the owner's own button, or (when the owner area has none, a
/// standard live layout) the "Connect" item of the owner's "More" menu
/// (see `resolveConnect`). Either opens the invite dialog, late and inside
/// a shadow root: its button is awaited.
pub fn connect(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, profile_url: []const u8, note: ?[]const u8) Error!?[]u8 {
    if (!s.allows(profile_url)) return error.InvalidParams;
    if (note) |text| try validateText(text, std.math.maxInt(usize));
    if (!(try openPage(gpa, runner, profile_url))) return null;
    const name = (try profileName(gpa, runner, s)) orelse return null;
    defer gpa.free(name);
    const area = (try ownerArea(runner, s, .connect)) orelse return null;
    const target = (try resolveConnect(gpa, runner, area, name)) orelse return null;
    defer gpa.free(target.selector);
    if (!(try click(gpa, runner, target.selector, true))) return null;
    if (target.route == .more_menu and !(try clickMenuConnect(gpa, runner, target.selector))) return null;
    const first = if (note != null) selectors.add_note_button else selectors.send_without_note_button;
    if (!(try flow.step(gpa, runner, "dom.waitFor", .{ .selector = first, .state = "visible", .strict = false, .timeout_ms = flow.waitBudget(runner, dialog_timeout_ms) }))) return null;
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

/// The acting flows a dry run (options.dry_run) covers.
pub const DryVerb = enum { connect, follow, like, comment };

/// Dry run of `verb` on `url` (a profile for connect and follow, a post for
/// like and comment): the real flow's steps up to its committing click,
/// then a trial click on that click's exact target instead (see
/// flow_steps' "Dry runs"). Returns `{"dry_run":true,...}` (owned), or null
/// / an error exactly where the real flow fails. Targets: the profile's own
/// Connect or Follow (resolved like clickProfileAction), the like button,
/// and for comment the Comment button (the comment box is typed into after
/// it).
pub fn dryRun(gpa: std.mem.Allocator, runner: anytype, s: flow.Site, verb: DryVerb, url: []const u8) Error!?[]u8 {
    if (!s.allows(url)) return error.InvalidParams;
    if (!(try openPage(gpa, runner, url))) return null;
    switch (verb) {
        .connect, .follow => {
            const action: ProfileAction = if (verb == .connect) .connect else .follow;
            const name = (try profileName(gpa, runner, s)) orelse return null;
            defer gpa.free(name);
            const area = (try ownerArea(runner, s, action)) orelse return null;
            const target: ConnectTarget = if (verb == .connect)
                (try resolveConnect(gpa, runner, area, name)) orelse return null
            else
                .{ .route = .own_button, .selector = (try resolveProfileAction(gpa, runner, area, action, name)) orelse return null };
            defer gpa.free(target.selector);
            const element = (try flow.trialTarget(gpa, runner, target.selector, true, click_timeout_ms)) orelse return null;
            defer gpa.free(element.tag);
            const label = if (verb == .follow) "Follow <owner>" else switch (target.route) {
                .own_button => "Invite <owner> to connect",
                .more_menu => "More",
            };
            const checks = [_]flow.Check{
                flow.pass("signed_in"),
                flow.pass("profile_owner"),
                flow.counted("owner_area", 1),
                flow.counted("visible_copies", 1),
                flow.pass("actionable"),
                // Opening the menu is a click: a dry run never makes it.
                flow.notReached("more_menu", "Connect is inside the owner's More menu; opening it needs a click"),
                if (verb == .connect)
                    flow.notReached("invite_dialog", "opens only after the Connect click")
                else
                    flow.notReached("following_state", "appears only after the Follow click"),
            };
            const shown_checks: []const flow.Check = if (target.route == .more_menu) &checks else &.{ checks[0], checks[1], checks[2], checks[3], checks[4], checks[6] };
            return try flow.dryRunResult(gpa, @tagName(verb), .{ .tag = element.tag, .label = label, .box = element.box }, shown_checks);
        },
        .like => {
            const element = (try flow.trialTarget(gpa, runner, selectors.like_button, true, click_timeout_ms)) orelse return null;
            defer gpa.free(element.tag);
            return try flow.dryRunResult(gpa, "like", .{ .tag = element.tag, .label = "Reaction button state: no reaction", .box = element.box }, &.{
                flow.pass("signed_in"),
                flow.pass("actionable"),
                flow.notReached("liked_state", "appears only after the Like click"),
            });
        },
        .comment => {
            const element = (try flow.trialTarget(gpa, runner, selectors.comment_button, false, click_timeout_ms)) orelse return null;
            defer gpa.free(element.tag);
            const boxes = (try flow.countMatches(gpa, runner, selectors.comment_input)) orelse return null;
            return try flow.dryRunResult(gpa, "comment", .{ .tag = element.tag, .label = "Comment", .box = element.box }, &.{
                flow.pass("signed_in"),
                flow.pass("actionable"),
                flow.counted("comment_box", boxes),
                flow.notReached("comment_submit", "used only after the comment is typed"),
            });
        },
    }
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
    const target = (try resolveProfileAction(gpa, runner, container, action, name)) orelse return false;
    defer gpa.free(target);
    return click(gpa, runner, target, true);
}

/// The strict selector clickProfileAction clicks (owned): the exact label
/// itself when it matches once, else its one visible copy by position; null
/// (the runner holds why) when that target is missing or ambiguous.
fn resolveProfileAction(gpa: std.mem.Allocator, runner: anytype, container: []const u8, action: ProfileAction, name: []const u8) Error!?[]u8 {
    const own = try profileSelector(gpa, action, name, container);
    defer gpa.free(own);
    const appeared = try flow.step(gpa, runner, "dom.waitFor", .{ .selector = own, .state = "visible", .strict = false, .timeout_ms = flow.waitBudget(runner, page_ready_timeout_ms) });
    const copies = (try visibleCopies(gpa, runner, own)) orelse return null;
    if (copies.total == 0) {
        try runner.notFound("linkedin_profile_action_missing");
        return null;
    }
    return pickVisibleCopy(gpa, runner, container, own, copies, appeared);
}

/// `selector`'s one visible copy in the one owner area `container` (owned;
/// itself when it matches once, else by position), given its `copies` (at
/// least one) and whether the wait for it succeeded. Null, the runner
/// holding why: the wait failed (its own failure: e.g. cancelled), the
/// area is not there exactly once or two copies are visible
/// (linkedin_profile_action_ambiguous), or none is
/// (linkedin_profile_action_missing).
fn pickVisibleCopy(gpa: std.mem.Allocator, runner: anytype, container: []const u8, selector: []const u8, copies: Copies, appeared: bool) Error!?[]u8 {
    // A failed wait with the target present (e.g. cancelled) keeps its failure.
    if (!appeared) return null;
    const area = try std.fmt.allocPrint(gpa, "xpath={s}", .{container});
    defer gpa.free(area);
    const areas = (try flow.countMatches(gpa, runner, area)) orelse return null;
    if (copies.visible > 1 or areas != 1) {
        try runner.notFound("linkedin_profile_action_ambiguous");
        return null;
    }
    if (copies.visible == 0) {
        try runner.notFound("linkedin_profile_action_missing");
        return null;
    }
    return try indexedCopy(gpa, selector, copies);
}

/// `selector` itself when it matches once, else its first visible copy by
/// position (owned).
fn indexedCopy(gpa: std.mem.Allocator, selector: []const u8, copies: Copies) Error![]u8 {
    if (copies.total == 1) return try gpa.dupe(u8, selector);
    return try std.fmt.allocPrint(gpa, "xpath=({s})[{d}]", .{ selector["xpath=".len..], copies.first_visible });
}

/// How a Connect starts: the owner's own Connect button, or their More
/// button, whose menu holds Connect.
pub const ConnectRoute = enum { own_button, more_menu };
pub const ConnectTarget = struct { route: ConnectRoute, selector: []u8 };

/// What `connect` clicks first (selector owned), or null (the runner holds
/// why). Profile buttons render late, so it first waits for a visible copy
/// of either the owner's own Connect (the exact label for `name`) or the
/// owner's More button, both inside the owner area. When the own Connect
/// is there at all, it is the target exactly as in clickProfileAction.
/// Otherwise the target is the owner's one visible More button, by the
/// same rules (live: the area holds two, one of them hidden): no More
/// either -> linkedin_profile_action_missing; two visible ->
/// linkedin_profile_action_ambiguous. No menu Connect item may be shown
/// before the owner's More is clicked (the item clicked later must be one
/// that click opened): otherwise linkedin_profile_menu_already_open.
pub fn resolveConnect(gpa: std.mem.Allocator, runner: anytype, container: []const u8, name: []const u8) Error!?ConnectTarget {
    const own = try profileSelector(gpa, .connect, name, container);
    defer gpa.free(own);
    const more = try std.fmt.allocPrint(gpa, "xpath={s}{s}", .{ container, more_button_path });
    defer gpa.free(more);
    const either = try std.fmt.allocPrint(gpa, "{s} | {s}", .{ own, more["xpath=".len..] });
    defer gpa.free(either);
    const appeared = try flow.step(gpa, runner, "dom.waitFor", .{ .selector = either, .state = "visible", .strict = false, .timeout_ms = flow.waitBudget(runner, page_ready_timeout_ms) });
    const own_copies = (try visibleCopies(gpa, runner, own)) orelse return null;
    if (own_copies.total > 0) {
        const selector = (try pickVisibleCopy(gpa, runner, container, own, own_copies, appeared)) orelse return null;
        return .{ .route = .own_button, .selector = selector };
    }
    const more_copies = (try visibleCopies(gpa, runner, more)) orelse return null;
    if (more_copies.total == 0) {
        try runner.notFound("linkedin_profile_action_missing");
        return null;
    }
    const selector = (try pickVisibleCopy(gpa, runner, container, more, more_copies, appeared)) orelse return null;
    errdefer gpa.free(selector);
    // Only an item that the owner's click opens may be clicked: one already
    // shown (another person's open menu, a role=menu elsewhere) could be
    // anyone's Connect (RoseCat 5157). Fail closed before any click.
    const shown = (try visibleCopies(gpa, runner, selectors.open_menu_or_item)) orelse {
        gpa.free(selector);
        return null;
    };
    if (shown.visible > 0) {
        try runner.notFound("linkedin_profile_menu_already_open");
        gpa.free(selector);
        return null;
    }
    return .{ .route = .more_menu, .selector = selector };
}

/// After the owner's More (`more`) was clicked: clicks the one visible
/// "Connect" item of the menu it opened: in the element its aria-controls
/// names, when it names one, else selectors.more_menu_connect (nothing of
/// which was shown before the click: resolveConnect checked). No item
/// (already connected or pending, or Follow-only) -> Escape closes the
/// menu, then linkedin_profile_connect_not_in_menu; two visible -> Escape,
/// then linkedin_profile_action_ambiguous. A failed wait with an item there
/// (e.g. cancelled) keeps its own failure.
fn clickMenuConnect(gpa: std.mem.Allocator, runner: anytype, more: []const u8) Error!bool {
    const item = (try ownerMenuItem(gpa, runner, more)) orelse return false;
    defer gpa.free(item);
    const appeared = try flow.step(gpa, runner, "dom.waitFor", .{ .selector = item, .state = "visible", .strict = false, .timeout_ms = flow.waitBudget(runner, menu_timeout_ms) });
    const copies = (try visibleCopies(gpa, runner, item)) orelse return false;
    if (copies.visible == 0 and copies.total == 0) return closeMenu(gpa, runner, "linkedin_profile_connect_not_in_menu");
    if (!appeared) return false;
    if (copies.visible > 1) return closeMenu(gpa, runner, "linkedin_profile_action_ambiguous");
    if (copies.visible == 0) return closeMenu(gpa, runner, "linkedin_profile_connect_not_in_menu");
    const target = try indexedCopy(gpa, item, copies);
    defer gpa.free(target);
    return click(gpa, runner, target, true);
}

/// The Connect item selector for the menu `more` opened (owned): bound to
/// the element its aria-controls names (one id), else the general one.
/// Null when the read failed (the runner holds why).
fn ownerMenuItem(gpa: std.mem.Allocator, runner: anytype, more: []const u8) Error!?[]u8 {
    const params = try std.json.Stringify.valueAlloc(gpa, .{ .selector = more, .name = "aria-controls", .timeout_ms = flow.budget(runner, flow.query_timeout_ms) }, .{});
    defer gpa.free(params);
    const result = (try runner.run("dom.getAttribute", params)) orelse return null;
    const parsed = std.json.parseFromSlice(struct { value: ?[]const u8 = null }, gpa, result, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try runner.malformed();
            return null;
        },
    };
    defer parsed.deinit();
    const id = std.mem.trim(u8, parsed.value.value orelse "", " \t\r\n");
    if (id.len == 0 or std.mem.indexOfAny(u8, id, " \t\r\n") != null) return try gpa.dupe(u8, selectors.more_menu_connect);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "xpath=//*[@id=");
    try xpathLiteral(gpa, &out, &.{id});
    try out.append(gpa, ']');
    try out.appendSlice(gpa, menu_connect_item);
    return try out.toOwnedSlice(gpa);
}

/// Escape (to the focused element: the menu closes), then fails as
/// `reason`. A failed Escape keeps its own failure.
fn closeMenu(gpa: std.mem.Allocator, runner: anytype, reason: []const u8) Error!bool {
    if (!(try flow.step(gpa, runner, "dom.press", .{ .key = "Escape", .options = .{ .timeout_ms = flow.budget(runner, click_timeout_ms) } }))) return false;
    try runner.notFound(reason);
    return false;
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
