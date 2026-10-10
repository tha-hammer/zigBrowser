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
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try out.append(gpa, '{');
    var first = true;
    inline for (@typeInfo(Table).@"struct".decls) |decl| {
        const value = @field(Table, decl.name);
        if (@TypeOf(value) != *const [value.len:0]u8) continue;
        const count = (try countMatches(gpa, runner, value)) orelse return null;
        if (!first) try out.append(gpa, ',');
        first = false;
        try out.print(gpa, "\"{s}\":{d}", .{ decl.name, count });
    }
    try out.append(gpa, '}');
    return try out.toOwnedSlice(gpa);
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
