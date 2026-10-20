//! macOS WKWebView PagePort (MS2a): implements `page_port.PagePort` over the same blocking
//! `zb_automation_*` C ABI (webkit_shim.h) that the GTK port uses — on macOS the ABI is
//! implemented by src/wkwebview_shim.m (WKWebView) instead of webkit_shim.c (WebKitGTK).
//!
//! Like the GTK adapter, every call blocks the calling (server) thread while the shim runs the
//! work on the macOS main thread (NSApp run loop); the shim owns its result buffers, this adapter
//! duplicates results into the caller's `gpa` on the calling thread and frees the shim copy. Shim
//! error text may carry page data and is dropped here, never forwarded.
//!
//! MS2a.1 implements the mandatory routed-command methods (evalJson, navigate[WithPolicy], reload,
//! url, title). MS2b wires nativeClick (a trusted in-process NSEvent) now that the shim enforces its
//! invariants — the phase-model ownership/no-late-dispatch guard, the documentToken DOC_CHANGED guard,
//! and ack-error mapping. The rest of native input, windows, dialogs, screenshot etc. keep the
//! PagePort `unsupported` defaults until their slices land.
const std = @import("std");
const builtin = @import("builtin");
const page_port = @import("automation/page_port.zig");
const js_embed = @import("automation_script/js_embed.zig");

const c = @cImport({
    @cInclude("webkit_shim.h");
});

const PagePort = page_port.PagePort;
const PortError = page_port.PortError;

pub const supported = builtin.os.tag == .macos;

comptime {
    if (supported) std.debug.assert(std.mem.eql(u8, c.ZB_AUTOMATION_WORLD, page_port.automation_world_name));
}

/// Install automation.js for every window zb_app_run creates. Call before zb_app_run. No-op off
/// macOS.
pub fn installScript() void {
    if (!supported) return;
    c.zb_automation_set_script(js_embed.source.ptr, js_embed.source.len);
}

/// Port targeting the primary window (id 1). Null off macOS.
pub fn pagePort() ?PagePort {
    if (!supported) return null;
    return portFor(1);
}

fn portFor(id: page_port.WindowId) PagePort {
    return .{ .ptr = @ptrFromInt(id), .vtable = &vtable };
}

fn windowOf(ptr: *anyopaque) c_uint {
    return @intCast(@intFromPtr(ptr));
}

const vtable: PagePort.VTable = .{
    .evalJson = evalJson,
    .navigate = navigate,
    .navigateWithPolicy = navigateWithPolicy,
    .reload = reload,
    .url = url,
    .title = title,
    // nativeClick is wired now that its invariants are in the shim (RoseCat 6253/6244): the phase-model
    // ownership/no-late-dispatch guard, the documentToken DOC_CHANGED guard, and ack-error mapping.
    .nativeClick = nativeClick,
    // MS2b.1b: native key + text, same phase model/guard, via trusted NSEvent key events.
    .nativeKey = nativeKey,
    .nativeText = nativeText,
    // MS2b.2 page dialogs: capture alert/confirm/prompt via WKUIDelegate; list + answer them.
    .listDialogs = listDialogs,
    .respondDialog = respondDialog,
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
    // beforeunload is UNSUPPORTED on macOS (MS2b.2 probe, 2026-10-20): WKWebView surfaces no beforeunload
    // prompt to any public WKUIDelegate method (with or without a user gesture), so it needs private
    // WebKit SPI, which the user ruled out. accept/dismiss are rejected as error.Unsupported. `.fail`
    // ALSO cannot honor the shared DialogOpen-and-leave-prompt-open contract (page_port.zig:161-165) —
    // with no prompt, the navigate just loads — a documented cross-platform divergence (plan :339/:732).
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

/// MS2b 2b-i: a real left click at viewport CSS px (x, y). The shim synthesizes a trusted NSEvent
/// and delivers it in-process; `document` is forwarded as the DOC_CHANGED guard token (enforced by
/// the matrix slices). Blocks the calling thread until the page's click dispatch has finished.
fn nativeClick(ptr: *anyopaque, x: f64, y: f64, document: ?[]const u8, timeout_ms: u64) PortError!void {
    const doc_z: ?[:0]u8 = if (document) |token| try std.heap.c_allocator.dupeZ(u8, token) else null;
    defer if (doc_z) |b| std.heap.c_allocator.free(b);
    const expected: [*c]const u8 = if (doc_z) |b| b.ptr else null;

    var err: [*c]u8 = null;
    const rc = c.zb_native_click(windowOf(ptr), x, y, 1, expected, clampMs(timeout_ms), &err);
    c.zb_automation_free(err);
    return mapCode(rc);
}

/// MS2b.1b: one real key press (DOM key name + modifier bits), guarded by `document` like nativeClick.
fn nativeKey(ptr: *anyopaque, key: []const u8, modifiers: u8, document: ?[]const u8, timeout_ms: u64) PortError!void {
    const key_z = try std.heap.c_allocator.dupeZ(u8, key);
    defer std.heap.c_allocator.free(key_z);
    const doc_z: ?[:0]u8 = if (document) |token| try std.heap.c_allocator.dupeZ(u8, token) else null;
    defer if (doc_z) |b| std.heap.c_allocator.free(b);
    const expected: [*c]const u8 = if (doc_z) |b| b.ptr else null;

    var releases: c_int = 0;
    var err: [*c]u8 = null;
    const rc = c.zb_native_key(windowOf(ptr), key_z.ptr, @intCast(modifiers & 0x0f), expected, clampMs(timeout_ms), &releases, &err);
    c.zb_automation_free(err);
    return mapCode(rc);
}

/// MS2b.1b: real typing — one trusted key event per code point. `sent_chars` is the code points
/// dispatched (set even on error, for partial-typing reporting). Guarded by `document` like nativeClick.
fn nativeText(ptr: *anyopaque, text: []const u8, document: ?[]const u8, timeout_ms: u64, sent_chars: *usize) PortError!void {
    sent_chars.* = 0;
    const text_z = try std.heap.c_allocator.dupeZ(u8, text);
    defer std.heap.c_allocator.free(text_z);
    const doc_z: ?[:0]u8 = if (document) |token| try std.heap.c_allocator.dupeZ(u8, token) else null;
    defer if (doc_z) |b| std.heap.c_allocator.free(b);
    const expected: [*c]const u8 = if (doc_z) |b| b.ptr else null;

    var releases: c_int = 0;
    var chars: c_int = 0;
    var err: [*c]u8 = null;
    const rc = c.zb_native_text(windowOf(ptr), text_z.ptr, expected, clampMs(timeout_ms), &releases, &chars, &err);
    c.zb_automation_free(err);
    if (chars > 0) sent_chars.* = @intCast(chars);
    return mapCode(rc);
}

/// MS2b.2: every open page dialog (the shim lists all windows' dialogs as JSON). `gpa` owns the result
/// (see page_port.freeDialogs).
fn listDialogs(_: *anyopaque, gpa: std.mem.Allocator, timeout_ms: u64) PortError![]page_port.DialogInfo {
    var out: [*c]u8 = null;
    const rc = c.zb_automation_list_dialogs(clampMs(timeout_ms), &out);
    defer c.zb_automation_free(out);
    try mapCode(rc);
    if (out == null) return error.EvalFailed;
    return parseDialogs(gpa, std.mem.span(out));
}

/// Shim dialog JSON [{window, type, message, default_text?}] -> DialogInfo (mirrors the GTK port).
fn parseDialogs(gpa: std.mem.Allocator, json: []const u8) PortError![]page_port.DialogInfo {
    const Wire = struct { window: u32, type: page_port.DialogType, message: []const u8, default_text: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice([]const Wire, gpa, json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EvalFailed,
    };
    defer parsed.deinit();
    const dialogs = try gpa.alloc(page_port.DialogInfo, parsed.value.len);
    var filled: usize = 0;
    errdefer page_port.freeDialogs(gpa, dialogs[0..filled]);
    for (parsed.value, dialogs) |wire, *info| {
        const message = try gpa.dupe(u8, wire.message);
        const default_text: ?[]u8 = if (wire.default_text) |text| gpa.dupe(u8, text) catch |e| {
            gpa.free(message);
            return e;
        } else null;
        info.* = .{ .window = wire.window, .type = wire.type, .message = message, .default_text = default_text };
        filled += 1;
    }
    return dialogs;
}

/// MS2b.2: answer window `id`'s dialog (accept = OK/Leave, else Cancel/Stay; `text` answers an accepted
/// prompt, null = its default). An embedded NUL in `text` is refused before the ABI (EvalFailed).
fn respondDialog(_: *anyopaque, id: page_port.WindowId, accept: bool, text: ?[]const u8, timeout_ms: u64) PortError!void {
    var text_z: ?[:0]u8 = null;
    defer if (text_z) |z| std.heap.c_allocator.free(z);
    if (text) |t| {
        if (std.mem.indexOfScalar(u8, t, 0) != null) return error.EvalFailed;
        text_z = try std.heap.c_allocator.dupeZ(u8, t);
    }
    const rc = c.zb_automation_respond_dialog(@intCast(id), @intFromBool(accept), if (text_z) |z| z.ptr else null, clampMs(timeout_ms));
    return mapCode(rc);
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
