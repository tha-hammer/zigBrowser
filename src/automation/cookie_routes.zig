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
/// cookies.import reads at most this many bytes (bounded allocation).
pub const max_import_bytes = 4 * 1024 * 1024;
/// cookies.import refuses files with more cookie entries than this, before
/// any cookie is set.
pub const max_import_cookies = 5000;
/// One deadline for a whole cookies.import: each set gets only the time
/// left, so a stalled store cannot hold the command (or server shutdown)
/// for longer than this.
pub const import_budget_ms: u64 = 30_000;
/// Latest representable expiry (9999-12-31T23:59:59Z): GLib's GDateTime
/// cannot represent later dates, so later values are rejected everywhere.
pub const max_expires_s: i64 = 253402300799;
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
    const started = ext.nowMs();
    var span = SpanInfo{ .operation = operationName(verb) };
    const outcome = try handleInner(gpa, io, port, ext, verb, params_json, &span);
    span.record(ext, &outcome, started);
    return outcome;
}

fn operationName(verb: Verb) []const u8 {
    return switch (verb) {
        .get_all => "getAll",
        .set => "set",
        .delete => "delete",
        .import => "import",
    };
}

/// The automation.cookie.command child span: operation, hashed name/domain,
/// count and scope only -- never values, URLs or file paths.
const SpanInfo = struct {
    operation: []const u8,
    name_hash: ?[]const u8 = null,
    domain_hash: ?[]const u8 = null,
    count: u32 = 0,
    scope: []const u8 = "",
    error_class: []const u8 = "",
    name_buf: [16]u8 = undefined,
    domain_buf: [16]u8 = undefined,

    fn hashName(self: *SpanInfo, name: []const u8) void {
        self.name_hash = std.fmt.bufPrint(&self.name_buf, "{x:0>16}", .{std.hash.Wyhash.hash(0, name)}) catch unreachable;
    }

    fn hashDomain(self: *SpanInfo, domain: []const u8) void {
        self.domain_hash = std.fmt.bufPrint(&self.domain_buf, "{x:0>16}", .{std.hash.Wyhash.hash(0, domain)}) catch unreachable;
    }

    fn record(self: *const SpanInfo, ext: *engine_mod.External, outcome: *const engine_mod.Outcome, started: u64) void {
        var bufs: [2][24]u8 = undefined;
        const ok = outcome.* == .result;
        const route = ext.route();
        const entries = [_]@import("telemetry.zig").AttrMap.Entry{
            .{ .key = "cookie.operation", .value = self.operation },
            .{ .key = "page.id", .value = route.page_id },
            .{ .key = "window.id", .value = route.window_id },
            .{ .key = "backend.name", .value = ext.build().backend_name },
            .{ .key = "cookie.name_hash", .value = self.name_hash orelse "" },
            .{ .key = "cookie.domain_hash", .value = self.domain_hash orelse "" },
            .{ .key = "cookie.count", .value = std.fmt.bufPrint(&bufs[0], "{d}", .{self.count}) catch unreachable },
            .{ .key = "cookie.scope", .value = self.scope },
            .{ .key = "result.status", .value = if (ok) "ok" else "error" },
            .{ .key = "platform.error_class", .value = if (ok) "" else self.error_class },
            .{ .key = "duration_ms", .value = std.fmt.bufPrint(&bufs[1], "{d}", .{ext.nowMs() -| started}) catch unreachable },
        };
        ext.childSpan("automation.cookie.command", &entries);
    }
};

fn handleInner(
    gpa: std.mem.Allocator,
    io: std.Io,
    port: ?cookie_port_mod.CookiePort,
    ext: *engine_mod.External,
    verb: Verb,
    params_json: []const u8,
    span: *SpanInfo,
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

    const store = port orelse {
        span.error_class = "NoPage";
        return engine_mod.automationFailure(gpa, .session_invalid, null, ids);
    };
    return switch (verb) {
        .get_all => getAll(gpa, store, params, ids, span),
        .set => {
            const cookie = cookieFromSetParams(params) orelse return invalidParams(gpa, "invalid_cookie", ids);
            span.hashName(cookie.name);
            span.hashDomain(cookie.domain);
            span.scope = "single";
            if (try setOne(gpa, store, cookie, port_timeout_ms, ids, span)) |failure| return failure;
            span.count = 1;
            return okResult(gpa);
        },
        .delete => {
            const name = stringField(params, "name") orelse return invalidParams(gpa, "invalid_cookie", ids);
            if (!validName(name)) return invalidParams(gpa, "invalid_cookie", ids);
            const domain: ?[]const u8 = if (params.get("domain")) |_| (stringField(params, "domain") orelse return invalidParams(gpa, "invalid_cookie", ids)) else null;
            if (domain) |d| if (!validDomain(d)) return invalidParams(gpa, "invalid_cookie", ids);
            span.hashName(name);
            if (domain) |d| span.hashDomain(d);
            span.scope = if (domain != null) "domain" else "all_domains";
            store.delete(name, domain, port_timeout_ms) catch |err| {
                span.error_class = @errorName(err);
                return portFailure(gpa, err, ids);
            };
            span.count = 1;
            return okResult(gpa);
        },
        .import => importFile(gpa, io, store, params, ext, span),
    };
}

const set_keys = [_][]const u8{ "name", "value", "domain", "path", "expires", "httpOnly", "secure", "sameSite" };

fn getAll(gpa: std.mem.Allocator, store: cookie_port_mod.CookiePort, params: std.json.ObjectMap, ids: script_command.Ids, span: *SpanInfo) error{OutOfMemory}!engine_mod.Outcome {
    const url: ?[]const u8 = if (params.get("url")) |_| (stringField(params, "url") orelse return invalidParams(gpa, null, ids)) else null;
    if (url) |u| if (u.len == 0 or hasControl(u)) return invalidParams(gpa, "invalid_url", ids);
    span.scope = if (url != null) "url" else "all";
    const text = store.getAll(gpa, url, port_timeout_ms) catch |err| {
        span.error_class = @errorName(err);
        return portFailure(gpa, err, ids);
    };
    defer gpa.free(text);

    // The store must answer an array of cookie-shaped objects; never echo it
    // otherwise.
    var check = std.json.parseFromSlice(std.json.Value, gpa, text, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return internal("Malformed cookie store result"),
    };
    defer check.deinit();
    const items = switch (check.value) {
        .array => |array| array.items,
        else => return internal("Malformed cookie store result"),
    };
    for (items) |item| {
        const object = switch (item) {
            .object => |o| o,
            else => return internal("Malformed cookie store result"),
        };
        for ([_][]const u8{ "name", "value", "domain" }) |key| {
            if (stringField(object, key) == null) return internal("Malformed cookie store result");
        }
    }
    span.count = @intCast(@min(items.len, std.math.maxInt(u32)));
    return .{ .result = try std.fmt.allocPrint(gpa, "{{\"cookies\":{s}}}", .{text}) };
}

fn hasControl(text: []const u8) bool {
    for (text) |c| {
        if (c < 0x20 or c == 0x7f) return true;
    }
    return false;
}

/// Returns null on success, or the failure outcome.
fn setOne(gpa: std.mem.Allocator, store: cookie_port_mod.CookiePort, cookie: Cookie, timeout_ms: u64, ids: script_command.Ids, span: *SpanInfo) error{OutOfMemory}!?engine_mod.Outcome {
    const json = try std.json.Stringify.valueAlloc(gpa, cookie, .{ .emit_null_optional_fields = false });
    defer gpa.free(json);
    store.set(json, timeout_ms) catch |err| {
        span.error_class = @errorName(err);
        return try portFailure(gpa, err, ids);
    };
    return null;
}

fn importFile(gpa: std.mem.Allocator, io: std.Io, store: cookie_port_mod.CookiePort, params: std.json.ObjectMap, ext: *engine_mod.External, span: *SpanInfo) error{OutOfMemory}!engine_mod.Outcome {
    const ids = ext.ids();
    const path = stringField(params, "path") orelse return invalidParams(gpa, "missing_path", ids);
    if (path.len == 0 or hasControl(path)) return invalidParams(gpa, "missing_path", ids);
    const format_name = stringField(params, "format") orelse return invalidParams(gpa, "unknown_format", ids);
    const Format = enum { netscape, json };
    const format: Format = if (std.mem.eql(u8, format_name, "netscape")) .netscape else if (std.mem.eql(u8, format_name, "json")) .json else return invalidParams(gpa, "unknown_format", ids);
    span.scope = @tagName(format);

    // One deadline for the whole import, starting before any file I/O.
    const deadline = ext.nowMs() +| import_budget_ms;
    if (ext.cancelled()) return cancelledImport(gpa, span, ids);

    _ = io;
    const text = readRegularFile(gpa, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge => return invalidParams(gpa, "file_too_large", ids),
        error.NotRegularFile => return invalidParams(gpa, "not_regular_file", ids),
        error.Unreadable => return invalidParams(gpa, "unreadable_file", ids),
    };
    defer gpa.free(text);

    // Collect and validate every entry first so caps apply before any set.
    var cookies: std.ArrayListUnmanaged(Cookie) = .empty;
    defer cookies.deinit(gpa);
    var counts = Counts{};
    var json_doc: ?std.json.Parsed(std.json.Value) = null;
    defer if (json_doc) |*doc| doc.deinit();
    switch (format) {
        .netscape => {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |raw_line| {
                const entry = parseNetscapeLine(std.mem.trimEnd(u8, raw_line, "\r")) orelse continue;
                if (cookies.items.len + counts.skipped >= max_import_cookies) return invalidParams(gpa, "too_many_cookies", ids);
                if (entry) |valid| try cookies.append(gpa, valid) else counts.skipped += 1;
            }
        },
        .json => {
            json_doc = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return invalidParams(gpa, "unparsable_file", ids),
            };
            const items = switch (json_doc.?.value) {
                .array => |array| array.items,
                else => return invalidParams(gpa, "unparsable_file", ids),
            };
            if (items.len > max_import_cookies) return invalidParams(gpa, "too_many_cookies", ids);
            for (items) |item| {
                const entry = switch (item) {
                    .object => |object| cookieFromJsonExport(object),
                    else => null,
                };
                if (entry) |valid| try cookies.append(gpa, valid) else counts.skipped += 1;
            }
        },
    }

    if (ext.cancelled()) return cancelledImport(gpa, span, ids);
    for (cookies.items, 0..) |cookie, index| {
        const remaining = deadline -| ext.nowMs();
        const failure: ?engine_mod.Outcome = if (ext.cancelled()) blk: {
            span.error_class = "Cancelled";
            break :blk try engine_mod.automationFailure(gpa, .cancelled, null, ids);
        } else if (remaining == 0) blk: {
            span.error_class = "Timeout";
            break :blk try engine_mod.automationFailure(gpa, .action_timeout, null, ids);
        } else try setOne(gpa, store, cookie, remaining, ids, span);
        if (failure) |f| {
            var owned = f;
            defer owned.deinit(gpa);
            span.count = counts.imported;
            return partialFailure(gpa, owned.failure, counts.imported, index, ids);
        }
        counts.imported += 1;
    }
    span.count = counts.imported;
    return .{ .result = try std.json.Stringify.valueAlloc(gpa, counts, .{}) };
}

/// Reads at most max_import_bytes of a REGULAR file. The path is opened
/// non-blocking (a FIFO cannot block the open) and the type is checked on the
/// opened handle (no stat-then-open race), so FIFOs, devices and directories
/// are refused before any read that could wait forever.
fn readRegularFile(gpa: std.mem.Allocator, path: []const u8) error{ OutOfMemory, TooLarge, NotRegularFile, Unreadable }![]u8 {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const fd = std.c.open(path_z, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true });
    if (fd < 0) return error.Unreadable;
    defer _ = std.c.close(fd);

    if (!(try isRegularFd(fd))) return error.NotRegularFile;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &chunk, chunk.len);
        if (n < 0) return error.Unreadable;
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > max_import_bytes) return error.TooLarge;
        try out.appendSlice(gpa, chunk[0..@intCast(n)]);
    }
    return out.toOwnedSlice(gpa);
}

fn isRegularFd(fd: std.c.fd_t) error{Unreadable}!bool {
    if (@import("builtin").os.tag == .linux) {
        const linux = std.os.linux;
        var sx: linux.Statx = undefined;
        const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &sx);
        if (linux.errno(rc) != .SUCCESS) return error.Unreadable;
        return linux.S.ISREG(sx.mode);
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstat(fd, &st) != 0) return error.Unreadable;
    return std.c.S.ISREG(st.mode);
}

fn cancelledImport(gpa: std.mem.Allocator, span: *SpanInfo, ids: script_command.Ids) error{OutOfMemory}!engine_mod.Outcome {
    span.error_class = "Cancelled";
    return engine_mod.automationFailure(gpa, .cancelled, null, ids);
}

/// Same error code as the failing set, with data saying how far the import
/// got (no cookie names or values). `failed_index` counts valid entries only
/// (skipped malformed lines/objects are not numbered), so it equals
/// `imported`.
fn partialFailure(gpa: std.mem.Allocator, failure: engine_mod.Failure, imported: u32, failed_index: usize, ids: script_command.Ids) error{OutOfMemory}!engine_mod.Outcome {
    const Data = struct { reason: []const u8, imported: u32, failed_index: usize, trace_id: []const u8, command_id: []const u8 };
    return .{ .failure = .{
        .code = failure.code,
        .message = failure.message,
        .data_json = try std.json.Stringify.valueAlloc(gpa, Data{
            .reason = "import_partial",
            .imported = imported,
            .failed_index = failed_index,
            .trace_id = ids.trace_id,
            .command_id = ids.command_id,
        }, .{}),
    } };
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
    if (expires < 0 or expires > max_expires_s) return @as(?Cookie, null);
    // The include-subdomains column must agree with the domain's leading dot
    // (TRUE <-> ".example.com"); a mismatch would change the cookie's scope.
    const include_subdomains = netscapeBool(fields[1]) orelse return @as(?Cookie, null);
    if (include_subdomains != std.mem.startsWith(u8, fields[0], ".")) return @as(?Cookie, null);
    const cookie = Cookie{
        .domain = fields[0],
        .path = fields[2],
        .secure = netscapeBool(fields[3]) orelse return @as(?Cookie, null),
        .expires = if (expires == 0) -1 else expires,
        .name = fields[5],
        .value = fields[6],
        .httpOnly = http_only,
    };
    return if (validCookie(cookie)) cookie else @as(?Cookie, null);
}

/// Netscape TRUE/FALSE column (case-insensitive); anything else is malformed.
fn netscapeBool(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "TRUE")) return true;
    if (std.ascii.eqlIgnoreCase(text, "FALSE")) return false;
    return null;
}

fn cookieFromSetParams(params: std.json.ObjectMap) ?Cookie {
    var cookie = Cookie{
        .name = stringField(params, "name") orelse return null,
        .value = stringField(params, "value") orelse return null,
        .domain = stringField(params, "domain") orelse return null,
    };
    if (params.get("path")) |_| cookie.path = stringField(params, "path") orelse return null;
    if (params.get("expires")) |value| cookie.expires = switch (value) {
        .integer => |n| if (n >= -1 and n <= max_expires_s) n else return null,
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
/// extra keys (hostOnly, storeId, id) are ignored, but a known field with a
/// wrong type or value makes the whole entry malformed (it is skipped rather
/// than imported with weaker flags).
fn cookieFromJsonExport(object: std.json.ObjectMap) ?Cookie {
    var cookie = Cookie{
        .name = stringField(object, "name") orelse return null,
        .value = stringField(object, "value") orelse return null,
        .domain = stringField(object, "domain") orelse return null,
    };
    if (object.get("path")) |_| cookie.path = stringField(object, "path") orelse return null;
    if (object.get("httpOnly")) |value| cookie.httpOnly = boolValue(value) orelse return null;
    if (object.get("secure")) |value| cookie.secure = boolValue(value) orelse return null;
    const session_value = object.get("session");
    const session = if (session_value) |value| boolValue(value) orelse return null else false;
    const expiration_date = object.get("expirationDate");
    const expires_value = object.get("expires");
    // Two expiry fields can disagree; refuse rather than pick one.
    if (expiration_date != null and expires_value != null) return null;

    var expiry: ?i64 = null; // null = session
    if (expiration_date) |value| expiry = exportSeconds(value) orelse return null;
    if (expires_value) |value| expiry = switch (value) {
        .integer => |n| if (n == -1) null else if (n > 0 and n <= max_expires_s) n else return null,
        else => return null,
    };
    if (session_value != null) {
        // session must agree with the expiry: session:true has none,
        // session:false must have a real one.
        if (session and expiry != null) return null;
        if (!session and expiry == null) return null;
    }
    if (!session) cookie.expires = expiry orelse -1;
    if (object.get("sameSite")) |value| {
        const text = switch (value) {
            .string => |s| s,
            else => return null,
        };
        if (!std.ascii.eqlIgnoreCase(text, "unspecified")) cookie.sameSite = canonicalSameSite(text) orelse return null;
    }
    return if (validCookie(cookie)) cookie else null;
}

/// expirationDate: positive unix seconds (fractional allowed).
fn exportSeconds(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |n| if (n > 0 and n <= max_expires_s) n else null,
        .float => |f| if (f > 0 and f < @as(f64, @floatFromInt(max_expires_s + 1))) @as(i64, @intFromFloat(@floor(f))) else null,
        else => null,
    };
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
        error.NavigationFailed, error.EvalFailed, error.DocumentChanged, error.DocumentReplaced, error.BadFile, error.FilesUnconfirmed, error.TooLarge, error.DialogOpen, error.NoDialog, error.BeforeUnloadDismissed => return internal("Cookie store failed"),
        error.Unsupported => return engine_mod.automationFailure(gpa, .session_invalid, "unsupported", ids),
    }, null, ids);
}
