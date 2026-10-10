//! GTK PagePort: implements `page_port.PagePort` (v2) over the blocking
//! `zb_automation_*` C ABI in webkit_shim.c.
//!
//! Every call blocks the calling (server) thread while the shim runs the work
//! on the GTK main thread. The shim copies all inputs before queuing and owns
//! its result buffers; this adapter duplicates results into the caller's
//! `gpa` on the calling thread and frees the shim copy, so no Zig allocator is
//! touched on the GTK thread. Shim error text (`out_err`) may contain page
//! data and is dropped here, never forwarded.
const std = @import("std");
const builtin = @import("builtin");
const page_port = @import("automation/page_port.zig");
const js_embed = @import("automation_script/js_embed.zig");

const c = @cImport({
    @cInclude("webkit_shim.h");
});

const PagePort = page_port.PagePort;
const PortError = page_port.PortError;

pub const supported = builtin.os.tag == .linux;

comptime {
    if (supported) std.debug.assert(std.mem.eql(u8, c.ZB_AUTOMATION_WORLD, page_port.automation_world_name));
}

/// Install automation.js for every window zb_app_run creates. Call before
/// zb_app_run. No-op on backends without the GTK bridge.
pub fn installScript() void {
    if (!supported) return;
    c.zb_automation_set_script(js_embed.source.ptr, js_embed.source.len);
}

/// Port targeting the primary window. Safe to create before zb_app_run: ops
/// wait for the window up to their deadline. Null on backends without the
/// GTK bridge.
pub fn pagePort() ?PagePort {
    if (!supported) return null;
    return .{ .ptr = &port_tag, .vtable = &vtable };
}

var port_tag: u8 = 0;

const vtable: PagePort.VTable = .{
    .evalJson = evalJson,
    .navigate = navigate,
    .reload = reload,
    .url = url,
    .title = title,
};

fn mapCode(rc: c_int) PortError!void {
    return switch (rc) {
        c.ZB_AUTO_OK => {},
        c.ZB_AUTO_ERR_TIMEOUT => error.Timeout,
        c.ZB_AUTO_ERR_NO_WINDOW => error.NoPage,
        c.ZB_AUTO_ERR_NAV_FAILED => error.NavigationFailed,
        c.ZB_AUTO_ERR_NO_LOOP, c.ZB_AUTO_ERR_CANCELLED => error.Cancelled,
        else => error.EvalFailed,
    };
}

/// The C ABI takes 32-bit milliseconds; larger deadlines saturate.
fn clampMs(timeout_ms: u64) c_uint {
    return @intCast(@min(timeout_ms, std.math.maxInt(c_uint)));
}

/// Move a shim-owned string into `gpa`, freeing the shim copy.
fn takeString(gpa: std.mem.Allocator, raw: [*c]u8) PortError![]u8 {
    defer c.zb_automation_free(raw);
    if (raw == null) return error.EvalFailed;
    return gpa.dupe(u8, std.mem.span(raw));
}

fn evalJson(_: *anyopaque, gpa: std.mem.Allocator, world: page_port.World, function_body: []const u8, arg_json: []const u8, timeout_ms: u64) PortError![]u8 {
    const body_z = try gpa.dupeZ(u8, function_body);
    defer gpa.free(body_z);
    const arg_z = try gpa.dupeZ(u8, arg_json);
    defer gpa.free(arg_z);
    const world_z: ?[*:0]const u8 = switch (world) {
        .automation => c.ZB_AUTOMATION_WORLD,
        .page => null,
    };

    var out: [*c]u8 = null;
    var err: [*c]u8 = null;
    const rc = c.zb_automation_eval_json(null, body_z.ptr, arg_z.ptr, world_z, clampMs(timeout_ms), &out, &err);
    c.zb_automation_free(err);
    mapCode(rc) catch |e| {
        c.zb_automation_free(out);
        return e;
    };
    return takeString(gpa, out);
}

fn navigate(_: *anyopaque, url_text: []const u8, timeout_ms: u64) PortError!void {
    const url_z = try std.heap.c_allocator.dupeZ(u8, url_text);
    defer std.heap.c_allocator.free(url_z);

    var err: [*c]u8 = null;
    const rc = c.zb_automation_navigate(null, url_z.ptr, clampMs(timeout_ms), &err);
    c.zb_automation_free(err);
    return mapCode(rc);
}

fn reload(_: *anyopaque, timeout_ms: u64) PortError!void {
    var err: [*c]u8 = null;
    const rc = c.zb_automation_reload(null, clampMs(timeout_ms), &err);
    c.zb_automation_free(err);
    return mapCode(rc);
}

fn url(_: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]u8 {
    var out: [*c]u8 = null;
    const rc = c.zb_automation_get_url(null, clampMs(timeout_ms), &out);
    mapCode(rc) catch |e| {
        c.zb_automation_free(out);
        return e;
    };
    return takeString(gpa, out);
}

fn title(_: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]u8 {
    var out: [*c]u8 = null;
    const rc = c.zb_automation_get_title(null, clampMs(timeout_ms), &out);
    mapCode(rc) catch |e| {
        c.zb_automation_free(out);
        return e;
    };
    return takeString(gpa, out);
}

test "C error codes map onto PortError" {
    if (!supported) return error.SkipZigTest;
    try mapCode(c.ZB_AUTO_OK);
    try std.testing.expectError(error.Timeout, mapCode(c.ZB_AUTO_ERR_TIMEOUT));
    try std.testing.expectError(error.NoPage, mapCode(c.ZB_AUTO_ERR_NO_WINDOW));
    try std.testing.expectError(error.NavigationFailed, mapCode(c.ZB_AUTO_ERR_NAV_FAILED));
    try std.testing.expectError(error.EvalFailed, mapCode(c.ZB_AUTO_ERR_JS));
    try std.testing.expectError(error.EvalFailed, mapCode(c.ZB_AUTO_ERR_INTERNAL));
    try std.testing.expectError(error.Cancelled, mapCode(c.ZB_AUTO_ERR_NO_LOOP));
    try std.testing.expectError(error.Cancelled, mapCode(c.ZB_AUTO_ERR_CANCELLED));
}

test "deadlines beyond 32 bits saturate instead of wrapping" {
    try std.testing.expectEqual(@as(c_uint, 250), clampMs(250));
    try std.testing.expectEqual(@as(c_uint, std.math.maxInt(c_uint)), clampMs(std.math.maxInt(u64)));
}
