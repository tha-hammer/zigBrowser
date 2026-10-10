//! X (x.com) flows: post now, schedule a post, check login. Each flow is a
//! fixed sequence of ordinary automation commands (page.navigate, dom.*),
//! so it gets the engine's retries, actionability checks and telemetry.
//!
//! The runner is duck-typed: `runner.run(method, params_json)` executes one
//! command and returns its JSON-RPC result, or null when the command failed
//! (the runner keeps that failure for the caller).
const std = @import("std");

/// Every X selector, in one place. X changes its markup often; update here.
/// data-testid hooks are X's most stable handles.
pub const selectors = struct {
    /// Post composer (a Draft.js contenteditable).
    pub const composer = "testid=tweetTextarea_0";
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
    /// Calendar icon that opens the schedule dialog.
    pub const schedule_option = "testid=scheduleOption";
    /// Native <select> elements in the schedule dialog. Option values: month
    /// 1-12, day 1-31, year YYYY, hour 1-12, minute 0-59, "AM"/"PM".
    pub const schedule_month = "css=select[aria-label=\"Month\"]";
    pub const schedule_day = "css=select[aria-label=\"Day\"]";
    pub const schedule_year = "css=select[aria-label=\"Year\"]";
    pub const schedule_hour = "css=select[aria-label=\"Hour\"]";
    pub const schedule_minute = "css=select[aria-label=\"Minute\"]";
    pub const schedule_ampm = "css=select[aria-label=\"AM/PM\"]";
    /// "Confirm" in the schedule dialog.
    pub const schedule_confirm = "testid=scheduledConfirmationPrimaryAction";
    /// Signs of a logged-out page.
    pub const login_link = "css=a[href=\"/login\"], a[href=\"/i/flow/login\"], [data-testid=\"loginButton\"], [data-testid=\"signupButton\"]";
};

pub const compose_url = "https://x.com/compose/post";

/// X's limit for a standard account, counted in characters (code points).
pub const max_post_chars = 280;

const navigate_timeout_ms = 30_000;
const composer_timeout_ms = 15_000;
const click_timeout_ms = 10_000;
const confirm_timeout_ms = 15_000;
/// dom.query answers at once (an empty list is a valid answer, never
/// retried); its timeout only bounds the native page call, so it must be a
/// real duration, not 0.
const query_timeout_ms = 5_000;
/// One trial-click probe of a Post button copy.
const probe_timeout_ms = 1_000;
/// Probe rounds over all candidates before giving up (each round waits up
/// to probe_timeout_ms per copy, so a button that appears late is found).
pub const max_post_probe_rounds = 5;
/// Copies of one testid probed per round.
const max_copies_per_testid = 4;

pub const Verb = enum { post, schedule_post, login_check };

pub fn verbFromMethod(method: []const u8) ?Verb {
    if (std.mem.eql(u8, method, "x.post")) return .post;
    if (std.mem.eql(u8, method, "x.schedule_post")) return .schedule_post;
    if (std.mem.eql(u8, method, "x.login_check")) return .login_check;
    return null;
}

pub const Error = error{ OutOfMemory, InvalidParams, LoggedOut };

pub const PostParams = struct {
    text: []const u8,
    /// Public override of the page the flow opens (the x.* `compose_url`
    /// param: fixtures, mirrors). Defaults to the real `compose_url`.
    compose_url: []const u8 = compose_url,
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
};

/// Posts `text` now. Returns `{"ok":true}` (owned), null if a step failed,
/// or error.LoggedOut / error.InvalidParams.
pub fn post(gpa: std.mem.Allocator, runner: anytype, params: PostParams) Error!?[]u8 {
    try validateText(params.text);
    if (!(try openComposer(gpa, runner, params.compose_url))) return null;
    if (!(try typeText(gpa, runner, params.text))) return null;
    if (!(try submit(gpa, runner))) return null;
    return try gpa.dupe(u8, "{\"ok\":true}");
}

/// Schedules `text` for `date` `time` (local time of the X account).
/// Returns `{"ok":true,"scheduledFor":"YYYY-MM-DDTHH:MM"}` (owned).
pub fn schedulePost(gpa: std.mem.Allocator, runner: anytype, params: ScheduleParams) Error!?[]u8 {
    try validateText(params.text);
    const when = try parseWhen(params.date, params.time);
    if (!(try openComposer(gpa, runner, params.compose_url))) return null;
    if (!(try typeText(gpa, runner, params.text))) return null;

    if (!(try step(gpa, runner, "dom.click", .{ .selector = selectors.schedule_option, .options = .{ .timeout_ms = click_timeout_ms } }))) return null;
    if (!(try step(gpa, runner, "dom.waitFor", .{ .selector = selectors.schedule_month, .state = "visible", .timeout_ms = composer_timeout_ms }))) return null;

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
        if (!(try step(gpa, runner, "dom.selectOption", .{ .selector = choice.selector, .value = choice.value, .timeout_ms = click_timeout_ms }))) return null;
    }
    if (!(try step(gpa, runner, "dom.click", .{ .selector = selectors.schedule_confirm, .options = .{ .timeout_ms = click_timeout_ms } }))) return null;
    if (!(try submit(gpa, runner))) return null;
    return try std.fmt.allocPrint(gpa, "{{\"ok\":true,\"scheduledFor\":\"{s}T{s}\"}}", .{ params.date, params.time });
}

/// Logged in when the composer is on the current page. Does not navigate.
/// Returns `{"loggedIn":bool,"platform":"x"}` (owned) or null on a failed step.
pub fn loginCheck(gpa: std.mem.Allocator, runner: anytype) Error!?[]u8 {
    const composer_count = (try countMatches(gpa, runner, selectors.composer)) orelse return null;
    return try std.fmt.allocPrint(gpa, "{{\"loggedIn\":{},\"platform\":\"x\"}}", .{composer_count > 0});
}

fn validateText(text: []const u8) Error!void {
    if (text.len == 0) return error.InvalidParams;
    const chars = std.unicode.utf8CountCodepoints(text) catch return error.InvalidParams;
    if (chars > max_post_chars) return error.InvalidParams;
}

/// Navigate to the composer and wait for it. If it never shows up and the
/// page offers a login link instead, the account is logged out.
fn openComposer(gpa: std.mem.Allocator, runner: anytype, url: []const u8) Error!bool {
    if (!(try step(gpa, runner, "page.navigate", .{ .url = url, .timeout_ms = navigate_timeout_ms }))) return false;
    if (try step(gpa, runner, "dom.waitFor", .{ .selector = selectors.composer, .state = "visible", .timeout_ms = composer_timeout_ms })) return true;
    const login_links = (try countMatches(gpa, runner, selectors.login_link)) orelse return false;
    if (login_links > 0) return error.LoggedOut;
    return false;
}

/// X may restore an unsent draft into the composer, so clear it first
/// (dom.fill "" replaces the content in one edit), then type the text.
fn typeText(gpa: std.mem.Allocator, runner: anytype, text: []const u8) Error!bool {
    if (!(try step(gpa, runner, "dom.click", .{ .selector = selectors.composer, .options = .{ .timeout_ms = click_timeout_ms } }))) return false;
    if (!(try step(gpa, runner, "dom.fill", .{ .selector = selectors.composer, .value = "" }))) return false;
    return step(gpa, runner, "dom.type", .{ .selector = selectors.composer, .text = text });
}

/// Click Post (it stays disabled until there is text) and wait for X's
/// confirmation toast.
fn submit(gpa: std.mem.Allocator, runner: anytype) Error!bool {
    var selector_buf: [128]u8 = undefined;
    const button = (try findPostButton(gpa, runner, &selector_buf)) orelse return false;
    if (!(try step(gpa, runner, "dom.click", .{ .selector = button, .options = .{ .timeout_ms = click_timeout_ms } }))) return false;
    return step(gpa, runner, "dom.waitFor", .{ .selector = selectors.post_success, .state = "attached", .timeout_ms = confirm_timeout_ms });
}

/// The first Post button copy that passes a trial click, as an exact
/// single-element selector written into `buf`; null if none became
/// actionable within the probe rounds (the last probe's failure is kept by
/// the runner) or a query failed.
fn findPostButton(gpa: std.mem.Allocator, runner: anytype, buf: []u8) Error!?[]const u8 {
    var round: usize = 0;
    while (round < max_post_probe_rounds) : (round += 1) {
        for (selectors.post_button_testids) |testid| {
            var testid_buf: [64]u8 = undefined;
            const all = std.fmt.bufPrint(&testid_buf, "testid={s}", .{testid}) catch unreachable;
            const copies = (try countMatches(gpa, runner, all)) orelse return null;
            for (1..@min(copies, max_copies_per_testid) + 1) |n| {
                const copy = std.fmt.bufPrint(buf, selectors.post_button_copy, .{ testid, n }) catch unreachable;
                if (try step(gpa, runner, "dom.click", .{ .selector = copy, .options = .{ .trial = true, .timeout_ms = probe_timeout_ms } })) return copy;
            }
        }
    }
    return null;
}

/// Runs one command; true if it succeeded.
fn step(gpa: std.mem.Allocator, runner: anytype, method: []const u8, params: anytype) Error!bool {
    const json = try std.json.Stringify.valueAlloc(gpa, params, .{});
    defer gpa.free(json);
    return (try runner.run(method, json)) != null;
}

/// Number of elements matching `selector` right now (one attempt), or null
/// when the query itself failed.
fn countMatches(gpa: std.mem.Allocator, runner: anytype, selector: []const u8) Error!?usize {
    const params = try std.json.Stringify.valueAlloc(gpa, .{ .selector = selector, .timeout_ms = query_timeout_ms }, .{});
    defer gpa.free(params);
    const result = (try runner.run("dom.query", params)) orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, result, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    const elements = switch (parsed.value) {
        .object => |o| o.get("elements") orelse return null,
        else => return null,
    };
    return switch (elements) {
        .array => |a| a.items.len,
        else => null,
    };
}

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
