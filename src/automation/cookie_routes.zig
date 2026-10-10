//! N5: cookies.getAll / set / delete / import over a CookiePort.
//!
//! - cookies.getAll {url?}                   -> {cookies:[cookie...]}
//! - cookies.set {name, value, domain, path?, expires?, httpOnly?, secure?,
//!                sameSite?}                 -> {ok:true}
//! - cookies.delete {name, domain?}          -> {ok:true} (no domain = all)
//! - cookies.import {path, format:"netscape"|"json"} -> {imported, skipped}
//!   reads a cookies.txt (Netscape) or JSON export (browser extensions'
//!   [{name,value,domain,path,expirationDate,httpOnly,secure,sameSite,
//!   session}] or our own cookie shape) and sets each valid cookie.
//! Cookie values are never logged, put in error data, or sent to telemetry.
const std = @import("std");
const cookie_port_mod = @import("cookie_port.zig");
const engine_mod = @import("engine.zig");
const script_command = @import("script_command.zig");

pub const Verb = enum { get_all, set, delete, import };

pub fn verbFromMethod(method: []const u8) ?Verb {
    const table = [_]struct { method: []const u8, verb: Verb }{
        .{ .method = "cookies.getAll", .verb = .get_all },
        .{ .method = "cookies.set", .verb = .set },
        .{ .method = "cookies.delete", .verb = .delete },
        .{ .method = "cookies.import", .verb = .import },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.method, method)) return entry.verb;
    }
    return null;
}

const port_timeout_ms: u64 = 10_000;
const max_import_bytes = 4 * 1024 * 1024;
const max_name_len = 256;
const max_value_len = 4096;
const max_domain_len = 253;
const max_path_len = 1024;

/// Normalized cookie as sent to CookiePort.set (field order is the wire order).
const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8 = "/",
    expires: i64 = -1,
    httpOnly: bool = false,
    secure: bool = false,
    sameSite: ?[]const u8 = null,
};

pub fn handle(
    gpa: std.mem.Allocator,
    io: std.Io,
    port: ?cookie_port_mod.CookiePort,
    /// From Engine.executeExternal: ids for failures + child spans.
    ext: *engine_mod.External,
    verb: Verb,
    params_json: []const u8,
) error{OutOfMemory}!engine_mod.Outcome {
    const ids = ext.ids();
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, params_json, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalidParams(gpa, null, ids),
    };
    defer parsed.deinit();
    const params = switch (parsed.value) {
        .object => |object| object,
        else => return invalidParams(gpa, null, ids),
    };
    const allowed: []const []const u8 = switch (verb) {
        .get_all => &.{"url"},
        .set => &set_keys,
        .delete => &.{ "name", "domain" },
        .import => &.{ "path", "format" },
    };
    var keys = params.iterator();
    while (keys.next()) |entry| {
        if (!inList(allowed, entry.key_ptr.*)) return invalidParams(gpa, "unknown_param", ids);
    }

    const store = port orelse return engine_mod.automationFailure(gpa, .session_invalid, null, ids);
    return switch (verb) {
        .get_all => getAll(gpa, store, params, ids),
        .set => {
            const cookie = cookieFromSetParams(params) orelse return invalidParams(gpa, "invalid_cookie", ids);
            if (try setOne(gpa, store, cookie, ids)) |failure| return failure;
            return okResult(gpa);
        },
        .delete => {
            const name = stringField(params, "name") orelse return invalidParams(gpa, "invalid_cookie", ids);
            if (!validName(name)) return invalidParams(gpa, "invalid_cookie", ids);
            const domain: ?[]const u8 = if (params.get("domain")) |_| (stringField(params, "domain") orelse return invalidParams(gpa, "invalid_cookie", ids)) else null;
            if (domain) |d| if (!validDomain(d)) return invalidParams(gpa, "invalid_cookie", ids);
            store.delete(name, domain, port_timeout_ms) catch |err| return portFailure(gpa, err, ids);
            return okResult(gpa);
        },
        .import => importFile(gpa, io, store, params, ids),
    };
}

const set_keys = [_][]const u8{ "name", "value", "domain", "path", "expires", "httpOnly", "secure", "sameSite" };

fn getAll(gpa: std.mem.Allocator, store: cookie_port_mod.CookiePort, params: std.json.ObjectMap, ids: script_command.Ids) error{OutOfMemory}!engine_mod.Outcome {
    const url: ?[]const u8 = if (params.get("url")) |_| (stringField(params, "url") orelse return invalidParams(gpa, null, ids)) else null;
    if (url) |u| if (std.mem.indexOfScalar(u8, u, 0) != null) return invalidParams(gpa, null, ids);
    const text = store.getAll(gpa, url, port_timeout_ms) catch |err| return portFailure(gpa, err, ids);
    defer gpa.free(text);

    // The store must answer a JSON array; never echo it otherwise.
    var check = std.json.parseFromSlice(std.json.Value, gpa, text, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return internal("Malformed cookie store result"),
    };
    defer check.deinit();
    if (check.value != .array) return internal("Malformed cookie store result");
    return .{ .result = try std.fmt.allocPrint(gpa, "{{\"cookies\":{s}}}", .{text}) };
}

/// Returns null on success, or the failure outcome.
fn setOne(gpa: std.mem.Allocator, store: cookie_port_mod.CookiePort, cookie: Cookie, ids: script_command.Ids) error{OutOfMemory}!?engine_mod.Outcome {
    const json = try std.json.Stringify.valueAlloc(gpa, cookie, .{ .emit_null_optional_fields = false });
    defer gpa.free(json);
    store.set(json, port_timeout_ms) catch |err| return try portFailure(gpa, err, ids);
    return null;
}

fn importFile(gpa: std.mem.Allocator, io: std.Io, store: cookie_port_mod.CookiePort, params: std.json.ObjectMap, ids: script_command.Ids) error{OutOfMemory}!engine_mod.Outcome {
    const path = stringField(params, "path") orelse return invalidParams(gpa, "missing_path", ids);
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return invalidParams(gpa, "missing_path", ids);
    const format_name = stringField(params, "format") orelse return invalidParams(gpa, "unknown_format", ids);
    const Format = enum { netscape, json };
    const format: Format = if (std.mem.eql(u8, format_name, "netscape")) .netscape else if (std.mem.eql(u8, format_name, "json")) .json else return invalidParams(gpa, "unknown_format", ids);

    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_import_bytes)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalidParams(gpa, "unreadable_file", ids),
    };
    defer gpa.free(text);

    var counts = Counts{};
    switch (format) {
        .netscape => {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |raw_line| {
                const cookie = parseNetscapeLine(std.mem.trimEnd(u8, raw_line, "\r")) orelse continue;
                if (cookie) |valid| {
                    if (try setOne(gpa, store, valid, ids)) |failure| return failure;
                    counts.imported += 1;
                } else counts.skipped += 1;
            }
        },
        .json => {
            var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalidParams(gpa, "unparsable_file", ids),
            };
            defer parsed.deinit();
            const items = switch (parsed.value) {
                .array => |array| array.items,
                else => return invalidParams(gpa, "unparsable_file", ids),
            };
            for (items) |item| {
                const cookie = switch (item) {
                    .object => |object| cookieFromJsonExport(object),
                    else => null,
                };
                if (cookie) |valid| {
                    if (try setOne(gpa, store, valid, ids)) |failure| return failure;
                    counts.imported += 1;
                } else counts.skipped += 1;
            }
        },
    }
    return .{ .result = try std.json.Stringify.valueAlloc(gpa, counts, .{}) };
}

const Counts = struct { imported: u32 = 0, skipped: u32 = 0 };

/// null: not a cookie line (blank/comment); ?Cookie null: malformed cookie.
fn parseNetscapeLine(line_in: []const u8) ??Cookie {
    var line = line_in;
    var http_only = false;
    const http_only_prefix = "#HttpOnly_";
    if (std.mem.startsWith(u8, line, http_only_prefix)) {
        http_only = true;
        line = line[http_only_prefix.len..];
    } else if (line.len == 0 or line[0] == '#') {
        return null;
    }
    if (std.mem.trim(u8, line, " \t").len == 0) return null;

    var fields: [7][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, '\t');
    var n: usize = 0;
    while (it.next()) |field| : (n += 1) {
        if (n == fields.len) return @as(?Cookie, null);
        fields[n] = field;
    }
    if (n != fields.len) return @as(?Cookie, null);

    const expires = std.fmt.parseInt(i64, fields[4], 10) catch return @as(?Cookie, null);
    const cookie = Cookie{
        .domain = fields[0],
        .path = fields[2],
        .secure = std.ascii.eqlIgnoreCase(fields[3], "TRUE"),
        .expires = if (expires <= 0) -1 else expires,
        .name = fields[5],
        .value = fields[6],
        .httpOnly = http_only,
    };
    return if (validCookie(cookie)) cookie else @as(?Cookie, null);
}

fn cookieFromSetParams(params: std.json.ObjectMap) ?Cookie {
    var cookie = Cookie{
        .name = stringField(params, "name") orelse return null,
        .value = stringField(params, "value") orelse return null,
        .domain = stringField(params, "domain") orelse return null,
    };
    if (params.get("path")) |_| cookie.path = stringField(params, "path") orelse return null;
    if (params.get("expires")) |value| cookie.expires = switch (value) {
        .integer => |n| if (n >= -1) n else return null,
        else => return null,
    };
    if (params.get("httpOnly")) |value| cookie.httpOnly = boolValue(value) orelse return null;
    if (params.get("secure")) |value| cookie.secure = boolValue(value) orelse return null;
    if (params.get("sameSite")) |value| cookie.sameSite = canonicalSameSite(switch (value) {
        .string => |s| s,
        else => return null,
    }) orelse return null;
    return if (validCookie(cookie)) cookie else null;
}

/// Browser-extension export ({expirationDate, session, sameSite:
/// no_restriction|lax|strict|unspecified, ...}) or our own shape. Unknown
/// extra keys (hostOnly, storeId, id) are ignored.
fn cookieFromJsonExport(object: std.json.ObjectMap) ?Cookie {
    var cookie = Cookie{
        .name = stringField(object, "name") orelse return null,
        .value = stringField(object, "value") orelse return null,
        .domain = stringField(object, "domain") orelse return null,
    };
    if (object.get("path")) |_| cookie.path = stringField(object, "path") orelse return null;
    if (object.get("httpOnly")) |value| cookie.httpOnly = boolValue(value) orelse false;
    if (object.get("secure")) |value| cookie.secure = boolValue(value) orelse false;

    const session = if (object.get("session")) |value| boolValue(value) orelse false else false;
    const expiry_value = object.get("expirationDate") orelse object.get("expires");
    if (!session) {
        if (expiry_value) |value| cookie.expires = switch (value) {
            .integer => |n| if (n > 0) n else -1,
            .float => |f| if (f > 0 and f < 9.0e15) @intFromFloat(@floor(f)) else -1,
            else => -1,
        };
    }
    if (object.get("sameSite")) |value| switch (value) {
        .string => |s| cookie.sameSite = canonicalSameSite(s),
        else => {},
    };
    return if (validCookie(cookie)) cookie else null;
}

fn canonicalSameSite(text: []const u8) ?[]const u8 {
    if (std.ascii.eqlIgnoreCase(text, "lax")) return "Lax";
    if (std.ascii.eqlIgnoreCase(text, "strict")) return "Strict";
    if (std.ascii.eqlIgnoreCase(text, "none") or std.ascii.eqlIgnoreCase(text, "no_restriction")) return "None";
    return null;
}

fn validCookie(cookie: Cookie) bool {
    return validName(cookie.name) and validValue(cookie.value) and validDomain(cookie.domain) and validPath(cookie.path);
}

/// RFC 6265 token: visible ASCII except separators.
fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    for (name) |c| {
        if (c <= 0x20 or c >= 0x7f) return false;
        if (std.mem.indexOfScalar(u8, "()<>@,;:\\\"/[]?={}", c) != null) return false;
    }
    return true;
}

fn validValue(value: []const u8) bool {
    if (value.len > max_value_len) return false;
    for (value) |c| {
        if (c < 0x20 or c == 0x7f or c == ';') return false;
    }
    return true;
}

fn validDomain(domain: []const u8) bool {
    if (domain.len == 0 or domain.len > max_domain_len) return false;
    for (domain) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_')) return false;
    }
    return true;
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or path.len > max_path_len or path[0] != '/') return false;
    for (path) |c| {
        if (c < 0x20 or c == 0x7f or c == ';') return false;
    }
    return true;
}

fn boolValue(value: std.json.Value) ?bool {
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (object.get(key) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn inList(list: []const []const u8, item: []const u8) bool {
    for (list) |entry| {
        if (std.mem.eql(u8, entry, item)) return true;
    }
    return false;
}

fn okResult(gpa: std.mem.Allocator) error{OutOfMemory}!engine_mod.Outcome {
    return .{ .result = try gpa.dupe(u8, "{\"ok\":true}") };
}

fn internal(message: []const u8) engine_mod.Outcome {
    return .{ .failure = .{ .code = engine_mod.internal_error_code, .message = message } };
}

/// -32602 with a fixed, value-free reason plus the command ids.
fn invalidParams(gpa: std.mem.Allocator, reason: ?[]const u8, ids: script_command.Ids) error{OutOfMemory}!engine_mod.Outcome {
    const Data = struct { reason: ?[]const u8, trace_id: []const u8, command_id: []const u8 };
    return .{ .failure = .{
        .code = -32602,
        .message = "Invalid params",
        .data_json = try std.json.Stringify.valueAlloc(gpa, Data{ .reason = reason, .trace_id = ids.trace_id, .command_id = ids.command_id }, .{ .emit_null_optional_fields = false }),
    } };
}

fn portFailure(gpa: std.mem.Allocator, err: cookie_port_mod.PortError, ids: script_command.Ids) error{OutOfMemory}!engine_mod.Outcome {
    return engine_mod.automationFailure(gpa, switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoPage => .session_invalid,
        error.Cancelled => .cancelled,
        error.Timeout => .action_timeout,
        error.NavigationFailed, error.EvalFailed => return internal("Cookie store failed"),
    }, null, ids);
}
