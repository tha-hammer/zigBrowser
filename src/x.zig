//! X (x.com) flows: post now, schedule a post, check login. Each flow is a
//! fixed sequence of ordinary automation commands (page.navigate, dom.*),
//! so it gets the engine's retries, actionability checks and telemetry.
//!
//! The runner is duck-typed; see src/flow_steps.zig for its contract and
//! the shared step helpers.
const std = @import("std");
const flow = @import("flow_steps.zig");

/// Every X selector, in one place. X changes its markup often; update here.
/// data-testid hooks are X's most stable handles.
pub const selectors = struct {
    /// Post composer (a Draft.js contenteditable). When /compose/post opens
    /// as a dialog over the home timeline, both the dialog and the timeline
    /// have one (live, 2026-10-11): this is the dialog's copy whenever a
    /// [role=dialog] holds one, else the page's, so it never matches two.
    pub const composer = dialogFirst("tweetTextarea_0");
    /// "Post" button data-testids, tried in order: tweetButton (compose
    /// dialog/page), tweetButtonInline (home timeline). Every copy of each
    /// is addressed as `xpath=(//*[@data-testid="<id>"])[n]` and probed with
    /// a trial click (full actionability checks, no click); the first copy
    /// that passes is clicked. Hidden, covered or disabled copies are skipped.
    pub const post_button_testids = [_][]const u8{ "tweetButton", "tweetButtonInline" };
    /// Template for one copy of a Post button (testid, 1-based index).
    pub const post_button_copy = "xpath=(//*[@data-testid=\"{s}\"])[{d}]";
    /// Confirmation toast shown after a post is sent or scheduled.
    pub const post_success = "testid=toast";
    /// Calendar icon that opens the schedule dialog (dialog copy first, as
    /// for the composer).
    pub const schedule_option = dialogFirst("scheduleOption");
    /// Native <select> elements in the schedule dialog. Option values: month
    /// 1-12, day 1-31, year YYYY, hour 1-12, minute 0-59, "AM"/"PM". Live
    /// (2026-10-11) they have generated ids (SELECTOR_1..6) and no
    /// aria-label: each is aria-labelledby a label whose text names it, so
    /// they are found by that text.
    pub const schedule_month = labelledSelect("Month");
    pub const schedule_day = labelledSelect("Day");
    pub const schedule_year = labelledSelect("Year");
    pub const schedule_hour = labelledSelect("Hour");
    pub const schedule_minute = labelledSelect("Minute");
    pub const schedule_ampm = labelledSelect("AM/PM");
    /// "Confirm" in the schedule dialog.
    pub const schedule_confirm = "testid=scheduledConfirmationPrimaryAction";
    /// A dialog's close (X) button. Not used by the flows; reported by
    /// x.selfcheck.
    pub const dialog_close = "testid=app-bar-close";
    /// Signs of a logged-out page.
    pub const login_link = "css=a[href=\"/login\"], a[href=\"/i/flow/login\"], [data-testid=\"loginButton\"], [data-testid=\"signupButton\"]";
};

/// `testid` inside a [role=dialog] if a dialog holds one, else anywhere.
fn dialogFirst(comptime testid: []const u8) []const u8 {
    const any = "//*[@data-testid=\"" ++ testid ++ "\"]";
    const in_dialog = "//*[@role=\"dialog\"]" ++ any;
    return "xpath=" ++ in_dialog ++ " | " ++ any ++ "[not(" ++ in_dialog ++ ")]";
}

/// The <select> that is aria-labelledby the element whose text is `label`.
fn labelledSelect(comptime label: []const u8) []const u8 {
    return "xpath=//select[@aria-labelledby = //*[normalize-space(.)=\"" ++ label ++ "\"]/@id]";
}

pub const compose_url = "https://x.com/compose/post";

/// X's limit for a standard account, counted in characters (code points).
pub const max_post_chars = 280;

const navigate_timeout_ms = 30_000;
const composer_timeout_ms = 15_000;
const click_timeout_ms = 10_000;
const confirm_timeout_ms = 15_000;
/// One trial-click probe of a Post button copy.
const probe_timeout_ms = 1_000;
/// How long to look for an actionable Post button: rounds over every copy
/// of every Post testid, pausing between rounds, so a button that appears
/// (or becomes enabled) late is found.
pub const post_button_wait_ms = 10_000;
/// Pause between two Post-button rounds.
pub const post_button_poll_ms = 250;

pub const Verb = enum { post, schedule_post, login_check, selfcheck };

pub fn verbFromMethod(method: []const u8) ?Verb {
    if (std.mem.eql(u8, method, "x.post")) return .post;
    if (std.mem.eql(u8, method, "x.schedule_post")) return .schedule_post;
    if (std.mem.eql(u8, method, "x.login_check")) return .login_check;
    if (std.mem.eql(u8, method, "x.selfcheck")) return .selfcheck;
    return null;
}

pub const Error = flow.Error;

/// How the flow's input steps are delivered (x.* `options`): synthetic
/// (default) or native trusted events, optionally humanized. Applies to the
/// composer click and typing, the Post click and the schedule clicks; the
/// draft clear (dom.fill ""), the Post-button trial probes and the queries
/// stay as they are (they send no input).
pub const Input = struct {
    native: bool = false,
    humanize: bool = false,
};

const ActionOptions = struct {
    timeout_ms: u64,
    input: ?[]const u8 = null,
    humanize: ?bool = null,
};

fn act(input: Input, timeout_ms: u64) ActionOptions {
    return .{
        .timeout_ms = timeout_ms,
        .input = if (input.native) "native" else null,
        .humanize = if (input.humanize) true else null,
    };
}

pub const PostParams = struct {
    text: []const u8,
    /// Public override of the page the flow opens (the x.* `compose_url`
    /// param: fixtures, mirrors). Defaults to the real `compose_url`.
    compose_url: []const u8 = compose_url,
    input: Input = .{},
};

/// Years the schedule dialog's Year select can plausibly offer. Whether a
/// given moment is in the past (or too far ahead) is decided by X's own
/// dialog, which rejects it; the flow then fails on the Confirm step.
pub const min_schedule_year = 2000;
pub const max_schedule_year = 2100;

pub const ScheduleParams = struct {
    text: []const u8,
    /// "YYYY-MM-DD"
    date: []const u8,
    /// "HH:MM", 24-hour
    time: []const u8,
    compose_url: []const u8 = compose_url,
    input: Input = .{},
};

/// Posts `text` now. Returns `{"ok":true}` (owned), null if a step failed,
/// or error.LoggedOut / error.InvalidParams.
pub fn post(gpa: std.mem.Allocator, runner: anytype, params: PostParams) Error!?[]u8 {
    try validateText(params.text);
    if (params.input.humanize and !params.input.native) return error.InvalidParams;
    if (!(try openComposer(gpa, runner, params.compose_url))) return null;
    if (!(try typeText(gpa, runner, params.text, params.input))) return null;
    if (!(try submit(gpa, runner, params.input))) return null;
    return try gpa.dupe(u8, "{\"ok\":true}");
}

/// Schedules `text` for `date` `time` (local time of the X account).
/// Returns `{"ok":true,"scheduledFor":"YYYY-MM-DDTHH:MM"}` (owned).
pub fn schedulePost(gpa: std.mem.Allocator, runner: anytype, params: ScheduleParams) Error!?[]u8 {
    try validateText(params.text);
    const when = try parseWhen(params.date, params.time);
    if (params.input.humanize and !params.input.native) return error.InvalidParams;
    if (!(try openComposer(gpa, runner, params.compose_url))) return null;
    if (!(try typeText(gpa, runner, params.text, params.input))) return null;

    if (!(try step(gpa, runner, "dom.click", .{ .selector = selectors.schedule_option, .options = act(params.input, budget(runner, click_timeout_ms)) }))) return null;
    if (!(try step(gpa, runner, "dom.waitFor", .{ .selector = selectors.schedule_month, .state = "visible", .timeout_ms = waitBudget(runner, composer_timeout_ms) }))) return null;

    var bufs: [6][8]u8 = undefined;
    const choices = [_]struct { selector: []const u8, value: []const u8 }{
        .{ .selector = selectors.schedule_month, .value = number(&bufs[0], when.month) },
        .{ .selector = selectors.schedule_day, .value = number(&bufs[1], when.day) },
        .{ .selector = selectors.schedule_year, .value = number(&bufs[2], when.year) },
        .{ .selector = selectors.schedule_hour, .value = number(&bufs[3], when.hour12) },
        .{ .selector = selectors.schedule_minute, .value = number(&bufs[4], when.minute) },
        .{ .selector = selectors.schedule_ampm, .value = if (when.pm) "PM" else "AM" },
    };
    for (choices) |choice| {
        if (!(try step(gpa, runner, "dom.selectOption", .{ .selector = choice.selector, .value = choice.value, .timeout_ms = budget(runner, click_timeout_ms) }))) return null;
    }
    if (!(try step(gpa, runner, "dom.click", .{ .selector = selectors.schedule_confirm, .options = act(params.input, budget(runner, click_timeout_ms)) }))) return null;
    if (!(try submit(gpa, runner, params.input))) return null;
    return try std.fmt.allocPrint(gpa, "{{\"ok\":true,\"scheduledFor\":\"{s}T{s}\"}}", .{ params.date, params.time });
}

/// Logged in when the composer is on the current page. Does not navigate.
/// Returns `{"loggedIn":bool,"platform":"x"}` (owned) or null on a failed step.
pub fn loginCheck(gpa: std.mem.Allocator, runner: anytype) Error!?[]u8 {
    const composer_count = (try countMatches(gpa, runner, selectors.composer)) orelse return null;
    return try std.fmt.allocPrint(gpa, "{{\"loggedIn\":{},\"platform\":\"x\"}}", .{composer_count > 0});
}

/// Read-only: how many elements match each entry of `selectors` on the
/// current page (no navigation, no input). Post buttons are reported per
/// testid ("post_button.tweetButton"); the copy template is not a selector.
/// Returns `{"<name>":count,...}` (owned) in table order, or null if a
/// query failed or answered something unusable.
pub fn selfCheck(gpa: std.mem.Allocator, runner: anytype) Error!?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try out.append(gpa, '{');
    var first = true;
    inline for (@typeInfo(selectors).@"struct".decls) |decl| {
        const value = @field(selectors, decl.name);
        if (comptime std.mem.eql(u8, decl.name, "post_button_copy")) continue;
        if (comptime std.mem.eql(u8, decl.name, "post_button_testids")) {
            for (value) |testid| {
                var buf: [64]u8 = undefined;
                const selector = std.fmt.bufPrint(&buf, "testid={s}", .{testid}) catch unreachable;
                const count = (try countMatches(gpa, runner, selector)) orelse return null;
                try appendCount(gpa, &out, &first, "post_button.", testid, count);
            }
        } else {
            const count = (try countMatches(gpa, runner, value)) orelse return null;
            try appendCount(gpa, &out, &first, "", decl.name, count);
        }
    }
    try out.append(gpa, '}');
    return try out.toOwnedSlice(gpa);
}

fn appendCount(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), first: *bool, prefix: []const u8, name: []const u8, count: usize) Error!void {
    if (!first.*) try out.append(gpa, ',');
    first.* = false;
    try out.print(gpa, "\"{s}{s}\":{d}", .{ prefix, name, count });
}

fn validateText(text: []const u8) Error!void {
    if (text.len == 0) return error.InvalidParams;
    const chars = std.unicode.utf8CountCodepoints(text) catch return error.InvalidParams;
    if (chars > max_post_chars) return error.InvalidParams;
}

/// Navigate to the composer and wait for it. If it never shows up and the
/// page offers a login link instead, the account is logged out.
fn openComposer(gpa: std.mem.Allocator, runner: anytype, url: []const u8) Error!bool {
    if (!(try step(gpa, runner, "page.navigate", .{ .url = url, .timeout_ms = budget(runner, navigate_timeout_ms) }))) return false;
    if (try step(gpa, runner, "dom.waitFor", .{ .selector = selectors.composer, .state = "visible", .timeout_ms = waitBudget(runner, composer_timeout_ms) })) return true;
    const login_links = (try countMatches(gpa, runner, selectors.login_link)) orelse return false;
    if (login_links > 0) return error.LoggedOut;
    return false;
}

/// X may restore an unsent draft into the composer, so clear it first
/// (dom.fill "" replaces the content in one edit), then type the text.
fn typeText(gpa: std.mem.Allocator, runner: anytype, text: []const u8, input: Input) Error!bool {
    if (!(try step(gpa, runner, "dom.click", .{ .selector = selectors.composer, .options = act(input, budget(runner, click_timeout_ms)) }))) return false;
    if (!(try step(gpa, runner, "dom.fill", .{ .selector = selectors.composer, .value = "", .options = .{ .timeout_ms = budget(runner, click_timeout_ms) } }))) return false;
    const type_ms = flow.typingTimeoutMs(text, input.humanize);
    return step(gpa, runner, "dom.type", .{ .selector = selectors.composer, .text = text, .options = act(input, budget(runner, type_ms)) });
}

/// Click Post (it stays disabled until there is text) and wait for X's
/// confirmation toast.
fn submit(gpa: std.mem.Allocator, runner: anytype, input: Input) Error!bool {
    var selector_buf: [128]u8 = undefined;
    const button = (try findPostButton(gpa, runner, &selector_buf)) orelse return false;
    if (!(try step(gpa, runner, "dom.click", .{ .selector = button, .options = act(input, budget(runner, click_timeout_ms)) }))) return false;
    return step(gpa, runner, "dom.waitFor", .{ .selector = selectors.post_success, .state = "attached", .timeout_ms = waitBudget(runner, confirm_timeout_ms) });
}

/// The first Post button copy that passes a trial click, as an exact
/// single-element selector written into `buf`. Each round queries every
/// Post testid and probes every copy found; rounds repeat (pausing
/// post_button_poll_ms) for post_button_wait_ms, so a button that is
/// missing or disabled at first is still found. Null when none became
/// actionable (the runner holds the last probe's failure, or
/// element_not_found "x_post_button_missing" when no copy ever existed),
/// a query failed, or the flow was cancelled.
fn findPostButton(gpa: std.mem.Allocator, runner: anytype, buf: []u8) Error!?[]const u8 {
    // A hard bound: every query and probe is clamped to what is left of the
    // search (and of the flow), and nothing starts once it is spent.
    const give_up_at = runner.nowMs() +| post_button_wait_ms;
    var probed_any = false;
    search: while (true) {
        for (selectors.post_button_testids) |testid| {
            if (runner.nowMs() >= give_up_at) break :search;
            var testid_buf: [64]u8 = undefined;
            const all = std.fmt.bufPrint(&testid_buf, "testid={s}", .{testid}) catch unreachable;
            const copies = (try countMatchesWithin(gpa, runner, all, give_up_at)) orelse return null;
            for (1..copies + 1) |n| {
                const left = give_up_at -| runner.nowMs();
                if (left == 0) break :search;
                const copy = std.fmt.bufPrint(buf, selectors.post_button_copy, .{ testid, n }) catch unreachable;
                probed_any = true;
                if (try step(gpa, runner, "dom.click", .{ .selector = copy, .options = .{ .trial = true, .timeout_ms = budget(runner, @min(probe_timeout_ms, left)) } })) return copy;
            }
        }
        if (runner.nowMs() +| post_button_poll_ms >= give_up_at or runner.remainingMs() <= post_button_poll_ms) break;
        if (!runner.pause(post_button_poll_ms)) return null;
    }
    // The last probe's failure is the evidence; with no copy ever found,
    // say so explicitly (the queries themselves succeeded).
    if (!probed_any) try runner.notFound("x_post_button_missing");
    return null;
}

const budget = flow.budget;
const waitBudget = flow.waitBudget;
const step = flow.step;
const countMatches = flow.countMatches;
const countMatchesWithin = flow.countMatchesWithin;

const When = struct { year: u32, month: u32, day: u32, hour12: u32, minute: u32, pm: bool };

/// "YYYY-MM-DD" + "HH:MM" (24h), strictly formatted and a real calendar date.
fn parseWhen(date: []const u8, time: []const u8) Error!When {
    if (date.len != 10 or date[4] != '-' or date[7] != '-') return error.InvalidParams;
    if (time.len != 5 or time[2] != ':') return error.InvalidParams;
    const year = digits(date[0..4]) orelse return error.InvalidParams;
    const month = digits(date[5..7]) orelse return error.InvalidParams;
    const day = digits(date[8..10]) orelse return error.InvalidParams;
    const hour = digits(time[0..2]) orelse return error.InvalidParams;
    const minute = digits(time[3..5]) orelse return error.InvalidParams;
    if (year < min_schedule_year or year > max_schedule_year) return error.InvalidParams;
    if (month < 1 or month > 12 or hour > 23 or minute > 59) return error.InvalidParams;
    if (day < 1 or day > daysInMonth(year, month)) return error.InvalidParams;
    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour12 = if (hour % 12 == 0) 12 else hour % 12,
        .minute = minute,
        .pm = hour >= 12,
    };
}

fn digits(text: []const u8) ?u32 {
    var value: u32 = 0;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        2 => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn number(buf: *[8]u8, value: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{value}) catch unreachable;
}
