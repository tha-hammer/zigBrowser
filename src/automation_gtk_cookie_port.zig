//! GTK CookiePort: implements `cookie_port.CookiePort` over the blocking
//! `zb_cookies_*` C ABI in webkit_shim.c (the primary window's cookie store,
//! i.e. the profile's).
//!
//! Same rules as the GTK PagePort: calls block the server thread while the
//! shim works on the GTK thread; inputs are copied before queuing; results are
//! duplicated into the caller's `gpa` and the shim copy freed. Shim error text
//! is dropped, and nothing here logs: cookie values must never leave the store
//! except through getAll's result.
const std = @import("std");
const builtin = @import("builtin");
const cookie_port = @import("automation/cookie_port.zig");

const c = @cImport({
    @cInclude("webkit_shim.h");
});

const CookiePort = cookie_port.CookiePort;
const PortError = cookie_port.PortError;

pub const supported = builtin.os.tag == .linux;

/// Port for the primary window's cookie store. Null on backends without the
/// GTK bridge.
pub fn cookiePort() ?CookiePort {
    if (!supported) return null;
    return .{ .ptr = &port_tag, .vtable = &vtable };
}

var port_tag: u8 = 0;

const vtable: CookiePort.VTable = .{
    .getAll = getAll,
    .set = set,
    .delete = delete,
};

fn mapCode(rc: c_int) PortError!void {
    return switch (rc) {
        c.ZB_AUTO_OK => {},
        c.ZB_AUTO_ERR_TIMEOUT => error.Timeout,
        c.ZB_AUTO_ERR_NO_WINDOW => error.NoPage,
        c.ZB_AUTO_ERR_NO_LOOP, c.ZB_AUTO_ERR_CANCELLED => error.Cancelled,
        else => error.EvalFailed,
    };
}

fn clampMs(timeout_ms: u64) c_uint {
    return @intCast(@min(timeout_ms, std.math.maxInt(c_uint)));
}

/// The normalized cookie object cc_2's routes pass to `set`.
const CookieJson = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8 = "/",
    expires: i64 = -1,
    httpOnly: bool = false,
    secure: bool = false,
    sameSite: ?[]const u8 = null,
};

fn sameSiteCode(same_site: ?[]const u8) c_int {
    const name = same_site orelse return c.ZB_COOKIE_SAME_SITE_UNSET;
    if (std.ascii.eqlIgnoreCase(name, "Lax")) return c.ZB_COOKIE_SAME_SITE_LAX;
    if (std.ascii.eqlIgnoreCase(name, "Strict")) return c.ZB_COOKIE_SAME_SITE_STRICT;
    if (std.ascii.eqlIgnoreCase(name, "None")) return c.ZB_COOKIE_SAME_SITE_NONE;
    return c.ZB_COOKIE_SAME_SITE_UNSET;
}

fn getAll(_: *anyopaque, gpa: std.mem.Allocator, url: ?[]const u8, timeout_ms: u64) PortError![]u8 {
    const url_z: ?[:0]u8 = if (url) |text| try gpa.dupeZ(u8, text) else null;
    defer if (url_z) |z| gpa.free(z);

    var out: [*c]u8 = null;
    var err: [*c]u8 = null;
    const rc = c.zb_cookies_get_all(0, if (url_z) |z| z.ptr else null, clampMs(timeout_ms), &out, &err);
    c.zb_automation_free(err);
    defer c.zb_automation_free(out);
    try mapCode(rc);
    if (out == null) return error.EvalFailed;
    return gpa.dupe(u8, std.mem.span(out));
}

fn set(_: *anyopaque, cookie_json: []const u8, timeout_ms: u64) PortError!void {
    const gpa = std.heap.c_allocator;
    const parsed = std.json.parseFromSlice(CookieJson, gpa, cookie_json, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EvalFailed,
    };
    defer parsed.deinit();
    const cookie = parsed.value;

    const name = try gpa.dupeZ(u8, cookie.name);
    defer gpa.free(name);
    const value = try gpa.dupeZ(u8, cookie.value);
    defer gpa.free(value);
    const domain = try gpa.dupeZ(u8, cookie.domain);
    defer gpa.free(domain);
    const path = try gpa.dupeZ(u8, cookie.path);
    defer gpa.free(path);

    const native: c.ZbCookie = .{
        .name = name.ptr,
        .value = value.ptr,
        .domain = domain.ptr,
        .path = path.ptr,
        .expires = cookie.expires,
        .http_only = @intFromBool(cookie.httpOnly),
        .secure = @intFromBool(cookie.secure),
        .same_site = sameSiteCode(cookie.sameSite),
    };
    var err: [*c]u8 = null;
    const rc = c.zb_cookies_add(0, &native, clampMs(timeout_ms), &err);
    c.zb_automation_free(err);
    return mapCode(rc);
}

fn delete(_: *anyopaque, name: []const u8, domain: ?[]const u8, timeout_ms: u64) PortError!void {
    const gpa = std.heap.c_allocator;
    const name_z = try gpa.dupeZ(u8, name);
    defer gpa.free(name_z);
    const domain_z: ?[:0]u8 = if (domain) |d| try gpa.dupeZ(u8, d) else null;
    defer if (domain_z) |z| gpa.free(z);

    var err: [*c]u8 = null;
    const rc = c.zb_cookies_delete(0, name_z.ptr, if (domain_z) |z| z.ptr else null, clampMs(timeout_ms), &err);
    c.zb_automation_free(err);
    return mapCode(rc);
}

test "sameSite names map onto the shim's codes" {
    if (!supported) return error.SkipZigTest;
    try std.testing.expectEqual(@as(c_int, c.ZB_COOKIE_SAME_SITE_UNSET), sameSiteCode(null));
    try std.testing.expectEqual(@as(c_int, c.ZB_COOKIE_SAME_SITE_LAX), sameSiteCode("Lax"));
    try std.testing.expectEqual(@as(c_int, c.ZB_COOKIE_SAME_SITE_STRICT), sameSiteCode("strict"));
    try std.testing.expectEqual(@as(c_int, c.ZB_COOKIE_SAME_SITE_NONE), sameSiteCode("None"));
    try std.testing.expectEqual(@as(c_int, c.ZB_COOKIE_SAME_SITE_UNSET), sameSiteCode("bogus"));
}

test "cookie store errors map onto PortError" {
    if (!supported) return error.SkipZigTest;
    try mapCode(c.ZB_AUTO_OK);
    try std.testing.expectError(error.Timeout, mapCode(c.ZB_AUTO_ERR_TIMEOUT));
    try std.testing.expectError(error.NoPage, mapCode(c.ZB_AUTO_ERR_NO_WINDOW));
    try std.testing.expectError(error.Cancelled, mapCode(c.ZB_AUTO_ERR_NO_LOOP));
    try std.testing.expectError(error.EvalFailed, mapCode(c.ZB_AUTO_ERR_INTERNAL));
}
