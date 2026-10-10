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

// --- Native (trusted) input: the PagePort v3 methods (N7) ---
//
// Each call reads the page's trusted-input acknowledgement counters
// (__zbAutomation.inputAck() in the automation world), sends real GDK events
// through the shim, then waits until the page has acknowledged them - all
// within the one `timeout_ms`. WebKit delivers native events asynchronously
// (and mouse and key queues are not ordered against each other), so without
// the wait a following step could run before the page saw the input.

const ack_body = "const a = globalThis.__zbAutomation; if (!a) return 'null'; const c = a.inputAck(); return JSON.stringify([c.mouseup, c.keyup]);";

fn monotonicMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, &ts);
}

fn remainingMs(deadline: i64) PortError!u64 {
    const left = deadline - monotonicMs();
    if (left <= 0) return error.Timeout;
    return @intCast(left);
}

fn readAck(deadline: i64) PortError![2]i64 {
    const gpa = std.heap.c_allocator;
    const out = try evalJson(&port_tag, gpa, .automation, ack_body, "null", try remainingMs(deadline));
    defer gpa.free(out);
    return std.json.parseFromSliceLeaky([2]i64, gpa, out, .{}) catch error.EvalFailed;
}

/// Wait until the page acknowledged `mouseups` / `keyups` more trusted events.
fn waitAck(base: [2]i64, mouseups: i64, keyups: i64, deadline: i64) PortError!void {
    while (true) {
        const now = try readAck(deadline);
        if (now[0] >= base[0] + mouseups and now[1] >= base[1] + keyups) return;
        _ = try remainingMs(deadline);
        sleepMs(5);
    }
}

/// Real pointer motion + left click at viewport CSS px (x, y).
pub fn nativeClick(_: *anyopaque, x: f64, y: f64, timeout_ms: u64) PortError!void {
    const deadline = monotonicMs() + @as(i64, @intCast(@min(timeout_ms, std.math.maxInt(i32))));
    const base = try readAck(deadline);
    var err: [*c]u8 = null;
    const rc = c.zb_native_click(null, x, y, 1, clampMs(try remainingMs(deadline)), &err);
    c.zb_automation_free(err);
    try mapCode(rc);
    try waitAck(base, 1, 0, deadline);
}

/// One real key press (DOM key name) with modifiers: bit0 Shift, bit1
/// Control, bit2 Alt, bit3 Meta. Unknown keys are EvalFailed.
pub fn nativeKey(_: *anyopaque, key: []const u8, modifiers: u8, timeout_ms: u64) PortError!void {
    const deadline = monotonicMs() + @as(i64, @intCast(@min(timeout_ms, std.math.maxInt(i32))));
    const gpa = std.heap.c_allocator;
    const key_z = try gpa.dupeZ(u8, key);
    defer gpa.free(key_z);
    const base = try readAck(deadline);
    var releases: c_int = 0;
    var err: [*c]u8 = null;
    const rc = c.zb_native_key(null, key_z.ptr, @intCast(modifiers & 0x0f), clampMs(try remainingMs(deadline)), &releases, &err);
    c.zb_automation_free(err);
    try mapCode(rc);
    try waitAck(base, 0, releases, deadline);
}

/// Types `text` with real key events. `sent_chars` is always set, also on
/// error: the code points handed to the page. Timeout with sent_chars > 0 is
/// a partial side effect; callers must not retype the prefix.
pub fn nativeText(_: *anyopaque, text: []const u8, timeout_ms: u64, sent_chars: *usize) PortError!void {
    sent_chars.* = 0;
    const deadline = monotonicMs() + @as(i64, @intCast(@min(timeout_ms, std.math.maxInt(i32))));
    const gpa = std.heap.c_allocator;
    const text_z = try gpa.dupeZ(u8, text);
    defer gpa.free(text_z);
    const base = try readAck(deadline);
    var releases: c_int = 0;
    var chars: c_int = 0;
    var err: [*c]u8 = null;
    const rc = c.zb_native_text(null, text_z.ptr, clampMs(try remainingMs(deadline)), &releases, &chars, &err);
    c.zb_automation_free(err);
    sent_chars.* = @intCast(chars);
    try mapCode(rc);
    try waitAck(base, 0, releases, deadline);
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
