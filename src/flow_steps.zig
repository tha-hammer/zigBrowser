//! Step helpers shared by the site flows (src/x.zig, src/linkedin.zig,
//! src/instagram.zig). A flow is a fixed sequence of ordinary automation
//! commands run through a duck-typed runner:
//! - `run(method, params_json)` executes one command and returns its
//!   JSON-RPC result, or null when the command failed (the runner keeps that
//!   failure for the caller until a newer failure replaces it).
//! - `nowMs()` and `remainingMs()`: the clock and what is left of the whole
//!   flow's budget. Every step's timeout is clamped to the budget.
//! - `pause(ms)`: waits (cancellable); false if the flow was cancelled.
//! - `malformed()`: records "a step succeeded but its answer was unusable".
//! - `notFound(reason)`: records element_not_found with `reason`.
//! Whenever a flow returns null, the runner holds the failure for it.
const std = @import("std");

pub const Error = error{ OutOfMemory, InvalidParams, LoggedOut };

/// An XPath predicate: the element's text, leaving out what is inside an
/// <svg> (an icon's <title> is text too), is exactly `text`: one such text
/// node, any whitespace around it, and no other non-blank one. Exact, never
/// a prefix (RoseCat 5160).
pub fn visibleTextIs(comptime text: []const u8) []const u8 {
    const visible = ".//text()[not(ancestor::*[name()=\"svg\"])]";
    return "(" ++ visible ++ "[normalize-space(.)=\"" ++ text ++ "\"] and not(" ++ visible ++
        "[normalize-space(.)!=\"\" and normalize-space(.)!=\"" ++ text ++ "\"]))";
}

/// dom.query answers at once (an empty list is a valid answer, never
/// retried); its timeout only bounds the native page call, so it must be a
/// real duration, not 0.
pub const query_timeout_ms = 5_000;
/// The engine gives a waitFor's native call this much on top of its JS
/// timeout; budget clamping leaves room for it.
pub const wait_for_grace_ms = 1_000;

/// `ms`, clamped to what is left of the flow's budget.
pub fn budget(runner: anytype, ms: u64) u64 {
    return @min(ms, runner.remainingMs());
}

/// Like `budget`, leaving room for the engine's waitFor native grace.
pub fn waitBudget(runner: anytype, ms: u64) u64 {
    return @min(ms, runner.remainingMs() -| wait_for_grace_ms);
}

/// Runs one command; true if it succeeded.
pub fn step(gpa: std.mem.Allocator, runner: anytype, method: []const u8, params: anytype) Error!bool {
    const json = try std.json.Stringify.valueAlloc(gpa, params, .{ .emit_null_optional_fields = false });
    defer gpa.free(json);
    return (try runner.run(method, json)) != null;
}

/// Number of elements matching `selector` right now (one attempt), or null
/// when the query itself failed.
/// A successful answer that cannot be used is recorded as malformed, so the
/// caller never sees a stale failure from an earlier step.
pub fn countMatches(gpa: std.mem.Allocator, runner: anytype, selector: []const u8) Error!?usize {
    return countMatchesWithin(gpa, runner, selector, std.math.maxInt(u64));
}

/// countMatches with the query also clamped to end by `until_ms`.
pub fn countMatchesWithin(gpa: std.mem.Allocator, runner: anytype, selector: []const u8, until_ms: u64) Error!?usize {
    const timeout_ms = budget(runner, @min(query_timeout_ms, until_ms -| runner.nowMs()));
    const params = try std.json.Stringify.valueAlloc(gpa, .{ .selector = selector, .timeout_ms = timeout_ms }, .{});
    defer gpa.free(params);
    const result = (try runner.run("dom.query", params)) orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, result, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return try malformed(runner),
    };
    defer parsed.deinit();
    const elements = switch (parsed.value) {
        .object => |o| o.get("elements") orelse return try malformed(runner),
        else => return try malformed(runner),
    };
    return switch (elements) {
        .array => |a| a.items.len,
        else => try malformed(runner),
    };
}

pub fn malformed(runner: anytype) Error!?usize {
    try runner.malformed();
    return null;
}

/// dom.getText of a strict selector: the text (owned), or null when the
/// step failed or answered something unusable (recorded as malformed).
pub fn getText(gpa: std.mem.Allocator, runner: anytype, selector: []const u8, timeout_ms: u64) Error!?[]u8 {
    const params = try std.json.Stringify.valueAlloc(gpa, .{ .selector = selector, .timeout_ms = budget(runner, timeout_ms) }, .{});
    defer gpa.free(params);
    const result = (try runner.run("dom.getText", params)) orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, result, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try runner.malformed();
            return null;
        },
    };
    defer parsed.deinit();
    const text = switch (parsed.value) {
        .object => |o| switch (o.get("text") orelse .null) {
            .string => |s| s,
            else => null,
        },
        else => null,
    } orelse {
        try runner.malformed();
        return null;
    };
    return try gpa.dupe(u8, text);
}

/// `{"<name>":count,...}` (owned) for every string declaration of the
/// selector table `Table`, in declaration order; null if a query failed or
/// answered something unusable. Read-only: only dom.query steps.
pub fn selectorReport(gpa: std.mem.Allocator, runner: anytype, comptime Table: type) Error!?[]u8 {
    return selectorReportExcept(gpa, runner, Table, &.{});
}

/// selectorReport, with the entries named in `zero` reported as 0 without
/// a query (selectors that only mean something on another page).
pub fn selectorReportExcept(gpa: std.mem.Allocator, runner: anytype, comptime Table: type, zero: []const []const u8) Error!?[]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try out.append(gpa, '{');
    var first = true;
    inline for (@typeInfo(Table).@"struct".decls) |decl| {
        const value = @field(Table, decl.name);
        if (@TypeOf(value) != *const [value.len:0]u8) continue;
        const skipped = for (zero) |name| {
            if (std.mem.eql(u8, name, decl.name)) break true;
        } else false;
        const count = if (skipped) 0 else (try countMatches(gpa, runner, value)) orelse return null;
        if (!first) try out.append(gpa, ',');
        first = false;
        try out.print(gpa, "\"{s}\":{d}", .{ decl.name, count });
    }
    try out.append(gpa, '}');
    return try out.toOwnedSlice(gpa);
}

// ---- Dry runs (options.dry_run on the acting flows) ----
//
// A dry run does what the real flow does up to its committing action, then
// stops: it navigates, passes the login gate (and the runner's rate-limit
// scans), resolves exactly the target the real flow would act on and runs a
// dom.click trial on it (actionability checks, no event). It sends no input
// at all: no real click, fill, type, press or select.

/// A dry run's box of its target (CSS px, as dom.query reports it).
pub const Box = struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };

/// What a dry run would act on. `label` is the label its selector pins,
/// with the profile owner's name written "<owner>" (never read back from
/// the page).
pub const Target = struct { tag: []const u8, label: []const u8, box: Box };

/// One step a dry run checked: "pass" (with a count when it counted
/// something), "not_reached" (it needs the committing action first), or
/// "note".
pub const Check = struct {
    name: []const u8,
    result: []const u8 = "pass",
    count: ?usize = null,
    reason: ?[]const u8 = null,
};

pub fn pass(name: []const u8) Check {
    return .{ .name = name };
}

pub fn counted(name: []const u8, count: usize) Check {
    return .{ .name = name, .count = count };
}

pub fn notReached(name: []const u8, reason: []const u8) Check {
    return .{ .name = name, .result = "not_reached", .reason = reason };
}

/// `{"dry_run":true,"would_act":...,"target":{tag,label,box}|null,"checks":[...]}` (owned).
pub fn dryRunResult(gpa: std.mem.Allocator, would_act: []const u8, target: ?Target, checks: []const Check) Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "{{\"dry_run\":true,\"would_act\":\"{s}\",\"target\":", .{would_act});
    try appendJson(gpa, &out, target);
    try out.appendSlice(gpa, ",\"checks\":");
    try appendJson(gpa, &out, checks);
    try out.append(gpa, '}');
    return try out.toOwnedSlice(gpa);
}

fn appendJson(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), value: anytype) Error!void {
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
    defer gpa.free(json);
    try out.appendSlice(gpa, json);
}

/// A dom.click trial of `selector` (resolve, scroll into view, the
/// actionability checks; no event): true if the real click would start.
pub fn trial(gpa: std.mem.Allocator, runner: anytype, selector: []const u8, strict: bool, timeout_ms: u64) Error!bool {
    return step(gpa, runner, "dom.click", .{ .selector = selector, .options = .{ .strict = strict, .trial = true, .timeout_ms = budget(runner, timeout_ms) } });
}

pub const Element = struct { tag: []u8, box: Box };

/// Tag (owned) and box of the first element `selector` matches now (the one
/// a click acts on), or null: the query failed, answered something unusable
/// (malformed), or matched nothing (element_not_found `missing_reason`).
pub fn firstElement(gpa: std.mem.Allocator, runner: anytype, selector: []const u8, missing_reason: []const u8) Error!?Element {
    const params = try std.json.Stringify.valueAlloc(gpa, .{ .selector = selector, .timeout_ms = budget(runner, query_timeout_ms) }, .{});
    defer gpa.free(params);
    const result = (try runner.run("dom.query", params)) orelse return null;
    const Item = struct { tag: []const u8, bbox: Box = .{} };
    const parsed = std.json.parseFromSlice(struct { elements: []const Item }, gpa, result, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try runner.malformed();
            return null;
        },
    };
    defer parsed.deinit();
    if (parsed.value.elements.len == 0) {
        try runner.notFound(missing_reason);
        return null;
    }
    const first = parsed.value.elements[0];
    return .{ .tag = try gpa.dupe(u8, first.tag), .box = first.bbox };
}

/// The dry run of a target clicked as `selector`: a trial click, then its
/// tag and box; null when either step failed (the runner holds why).
pub fn trialTarget(gpa: std.mem.Allocator, runner: anytype, selector: []const u8, strict: bool, timeout_ms: u64) Error!?Element {
    if (!(try trial(gpa, runner, selector, strict, timeout_ms))) return null;
    // Gone between the trial and the query: the page changed under it.
    return firstElement(gpa, runner, selector, "dry_run_target_gone");
}

/// An absolute http(s) URL without NUL or whitespace (flows navigate to it
/// as given).
pub fn isPageUrl(url: []const u8) bool {
    if (url.len > 2048) return false;
    const rest = if (std.mem.startsWith(u8, url, "https://")) url[8..] else if (std.mem.startsWith(u8, url, "http://")) url[7..] else return false;
    if (rest.len == 0 or rest[0] == '/') return false;
    for (url) |c| if (c <= ' ' or c == 0x7f) return false;
    return true;
}

/// Percent-encodes `text` for a URL query value (RFC 3986 unreserved
/// characters stay as they are).
pub fn appendQueryValue(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) Error!void {
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(gpa, c);
        } else {
            try out.print(gpa, "%{X:0>2}", .{c});
        }
    }
}

/// Where a platform's flows may navigate: its real https site, or - for
/// tests only, set by the automation server's configuration, never by a
/// request - a fixture origin standing in for it.
pub const Site = struct {
    /// e.g. "www.linkedin.com"
    host: []const u8,
    /// e.g. "https://www.linkedin.com"
    origin: []const u8,
    /// e.g. "http://127.0.0.1:41234" (no trailing slash).
    fixture_origin: ?[]const u8 = null,
    /// Tests only, like fixture_origin: run the steps whose live markup is
    /// not yet verified (LinkedIn profile actions, Instagram story frames)
    /// instead of failing closed. Never set in production.
    unverified_actions: bool = false,

    /// The origin URLs are built from (search, profile and story URLs).
    pub fn base(self: Site) []const u8 {
        return self.fixture_origin orelse self.origin;
    }

    /// `url` is on this site: https, exactly `host` (no user info, no port,
    /// no lookalike or longer host), with a path; or on the fixture origin.
    pub fn allows(self: Site, url: []const u8) bool {
        if (!isPageUrl(url)) return false;
        if (self.fixture_origin) |origin| {
            if (url.len > origin.len and std.mem.startsWith(u8, url, origin) and url[origin.len] == '/') return true;
        }
        const uri = std.Uri.parse(url) catch return false;
        if (!std.mem.eql(u8, uri.scheme, "https")) return false;
        if (uri.user != null or uri.password != null or uri.port != null) return false;
        const host = switch (uri.host orelse return false) {
            .raw, .percent_encoded => |h| h,
        };
        if (!std.ascii.eqlIgnoreCase(host, self.host)) return false;
        const path = switch (uri.path) {
            .raw, .percent_encoded => |p| p,
        };
        return path.len > 0 and path[0] == '/';
    }
};

// ---- Flow budgets (x.*, linkedin.*, instagram.* `timeout_ms`) ----

/// A flow's whole budget when the request gives no `timeout_ms`.
pub const default_flow_budget_ms: u64 = 120_000;
/// The most a request (or humanized sizing) may give a flow.
pub const max_flow_budget_ms: u64 = 600_000;
/// Room for a flow's humanized clicks (paths + dwell) on top of its typing.
const humanized_clicks_ms: u64 = 10_000;

/// `timeout_ms` of a flow request: absent -> null; an integer in
/// 1..max_flow_budget_ms -> it; anything else is InvalidParams.
pub fn flowTimeoutParam(value: ?std.json.Value) error{InvalidParams}!?u64 {
    const v = value orelse return null;
    const ms: u64 = switch (v) {
        .integer => |n| if (n >= 1) @intCast(n) else return error.InvalidParams,
        else => return error.InvalidParams,
    };
    if (ms > max_flow_budget_ms) return error.InvalidParams;
    return ms;
}

/// Worst case of the N8 humanized typing schedule for `text` (200 ms per
/// character, 600 ms before a space) plus 50 ms of page-call time per
/// character and a 5 s margin.
pub fn humanizedTypingMs(text: []const u8) u64 {
    var total: u64 = 5_000;
    var view = (std.unicode.Utf8View.init(text) catch return 5_000 + 650 * @as(u64, text.len)).iterator();
    while (view.nextCodepointSlice()) |cp| {
        total += if (std.mem.eql(u8, cp, " ")) 650 else 250;
    }
    return total;
}

/// Timeout for one typing step: the humanized worst case, or (plain
/// typing) 100 ms per character plus 5 s, at least 30 s. The flow budget
/// still caps it.
pub fn typingTimeoutMs(text: []const u8, humanize: bool) u64 {
    if (humanize) return humanizedTypingMs(text);
    const chars = std.unicode.utf8CountCodepoints(text) catch text.len;
    return @max(30_000, 100 * @as(u64, chars) + 5_000);
}

/// A flow's budget: the request's `timeout_ms`; else, when it types
/// `humanized_text` with humanize, `default_ms` plus that typing's worst
/// case plus room for humanized clicks; else `default_ms`. Never above
/// max_flow_budget_ms.
pub fn flowBudgetMs(default_ms: u64, explicit_ms: ?u64, humanized_text: ?[]const u8) u64 {
    if (explicit_ms) |ms| return @min(ms, max_flow_budget_ms);
    if (humanized_text) |t| return @min(default_ms +| humanizedTypingMs(t) +| humanized_clicks_ms, max_flow_budget_ms);
    return @min(default_ms, max_flow_budget_ms);
}
