//! Windows WebView2 PagePort (WS2a.1, Closure A): implements `page_port.PagePort` over the same blocking
//! `zb_automation_*` C ABI (webkit_shim.h) that the GTK and macOS ports use — on Windows the ABI is
//! implemented by src/webview2_shim.cpp (WebView2 + CDP) instead of webkit_shim.c.
//!
//! Like the other adapters, every call blocks the calling (server) thread while the shim runs the work on
//! the UI thread that owns the WebView (a WM_ZB_JOB marshal with a deadline); the shim owns its result
//! buffers, this adapter duplicates results into the caller's `gpa` on the calling thread and frees the shim
//! copy. Shim error text may carry page data and is dropped here, never forwarded.
//!
//! WS2a.1 implements the routed-command methods (evalJson, navigate[WithPolicy], reload, url, title). Native
//! input, dialogs, windows, screenshot and recovery keep the PagePort `unsupported` defaults until their
//! slices (WS2b, WS2c) land.
const std = @import("std");
const builtin = @import("builtin");
const page_port = @import("automation/page_port.zig");
const js_embed = @import("automation_script/js_embed.zig");

const c = @cImport({
    @cInclude("webkit_shim.h");
});

const PagePort = page_port.PagePort;
const PortError = page_port.PortError;

pub const supported = builtin.os.tag == .windows;

comptime {
    if (supported) std.debug.assert(std.mem.eql(u8, c.ZB_AUTOMATION_WORLD, page_port.automation_world_name));
}

/// Install automation.js into the private CDP world for the window zb_app_run creates. Call before
/// zb_app_run. No-op off Windows.
pub fn installScript() void {
    if (!supported) return;
    c.zb_automation_set_script(js_embed.source.ptr, js_embed.source.len);
}

/// Port targeting the primary window (id 1, as on GTK and macOS). Null off Windows.
pub fn pagePort() ?PagePort {
    if (!supported) return null;
    return portFor(1);
}

fn portFor(id: page_port.WindowId) PagePort {
    return .{ .ptr = @ptrFromInt(id), .vtable = &vtable };
}

/// The Windows shell has one window, which the shim names 0 (ABI: "0 = the original primary"); the port's
/// primary id 1 is that window. Any other id reaches the shim unchanged and is ZB_AUTO_ERR_NO_WINDOW there.
fn windowOf(ptr: *anyopaque) c_uint {
    const id: c_uint = @intCast(@intFromPtr(ptr));
    return if (id == 1) 0 else id;
}

const vtable: PagePort.VTable = .{
    .evalJson = evalJson,
    .navigate = navigate,
    .navigateWithPolicy = navigateWithPolicy,
    .reload = reload,
    .url = url,
    .title = title,
};

fn evalJson(ptr: *anyopaque, gpa: std.mem.Allocator, world: page_port.World, function_body: []const u8, arg_json: []const u8, timeout_ms: u64) PortError![]u8 {
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
    const rc = c.zb_automation_eval_json(windowOf(ptr), body_z.ptr, arg_z.ptr, world_z, clampMs(timeout_ms), &out, &err);
    c.zb_automation_free(err);
    mapCode(rc) catch |e| {
        c.zb_automation_free(out);
        return e;
    };
    return takeString(gpa, out);
}

fn navigate(ptr: *anyopaque, url_text: []const u8, timeout_ms: u64) PortError!void {
    return navigateWithPolicy(ptr, url_text, .fail, timeout_ms);
}

fn navigateWithPolicy(ptr: *anyopaque, url_text: []const u8, before_unload: page_port.BeforeUnload, timeout_ms: u64) PortError!void {
    // beforeunload accept/dismiss arrive with the WebView2 dialog slice (WS2b.2); until then they are
    // rejected as error.Unsupported, as on macOS.
    if (before_unload != .fail) return error.Unsupported;
    const url_z = try std.heap.c_allocator.dupeZ(u8, url_text);
    defer std.heap.c_allocator.free(url_z);

    var err: [*c]u8 = null;
    const rc = c.zb_automation_navigate_guarded(windowOf(ptr), url_z.ptr, c.ZB_BEFORE_UNLOAD_FAIL, clampMs(timeout_ms), &err);
    c.zb_automation_free(err);
    return mapCode(rc);
}

fn reload(ptr: *anyopaque, timeout_ms: u64) PortError!void {
    var err: [*c]u8 = null;
    const rc = c.zb_automation_reload(windowOf(ptr), clampMs(timeout_ms), &err);
    c.zb_automation_free(err);
    return mapCode(rc);
}

fn url(ptr: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]u8 {
    var out: [*c]u8 = null;
    const rc = c.zb_automation_get_url(windowOf(ptr), clampMs(timeout_ms), &out);
    mapCode(rc) catch |e| {
        c.zb_automation_free(out);
        return e;
    };
    return takeString(gpa, out);
}

fn title(ptr: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]u8 {
    var out: [*c]u8 = null;
    const rc = c.zb_automation_get_title(windowOf(ptr), clampMs(timeout_ms), &out);
    mapCode(rc) catch |e| {
        c.zb_automation_free(out);
        return e;
    };
    return takeString(gpa, out);
}

fn mapCode(rc: c_int) PortError!void {
    return switch (rc) {
        c.ZB_AUTO_OK => {},
        c.ZB_AUTO_ERR_TIMEOUT => error.Timeout,
        c.ZB_AUTO_ERR_NO_WINDOW => error.NoPage,
        c.ZB_AUTO_ERR_NAV_FAILED => error.NavigationFailed,
        c.ZB_AUTO_ERR_NO_LOOP, c.ZB_AUTO_ERR_CANCELLED => error.Cancelled,
        c.ZB_AUTO_ERR_DOC_CHANGED => error.DocumentChanged,
        c.ZB_AUTO_ERR_DIALOG_OPEN => error.DialogOpen,
        c.ZB_AUTO_ERR_NO_DIALOG => error.NoDialog,
        c.ZB_AUTO_ERR_DIALOG_DISMISSED => error.BeforeUnloadDismissed,
        else => error.EvalFailed,
    };
}

fn clampMs(timeout_ms: u64) c_uint {
    return @intCast(@min(timeout_ms, std.math.maxInt(c_uint)));
}

fn takeString(gpa: std.mem.Allocator, raw: [*c]u8) PortError![]u8 {
    defer c.zb_automation_free(raw);
    if (raw == null) return error.EvalFailed;
    return gpa.dupe(u8, std.mem.span(raw));
}
