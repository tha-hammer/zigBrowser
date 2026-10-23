//! The shim-answer parsers both PagePort adapters share (bd zigBrowser-4pa.62, V03-F14): the window list, the dialog
//! list and the recovery list the C ABI returns as JSON, and the ZB_AUTO_* code map of src/webkit_shim.h. The GTK
//! (automation_gtk_port.zig) and macOS (automation_macos_port.zig) adapters held identical copies; only the GTK ones
//! were tested. Pure Zig over the shared header, so tests/automation_port_parse_test.zig runs it on Linux.
const std = @import("std");
pub const page_port = @import("automation/page_port.zig");

const c = @cImport({
    @cInclude("webkit_shim.h");
});

const PortError = page_port.PortError;

pub fn parseDialogs(gpa: std.mem.Allocator, json: []const u8) PortError![]page_port.DialogInfo {
    const Wire = struct { window: u32, type: page_port.DialogType, message: []const u8, default_text: ?[]const u8 = null };
    const parsed = std.json.parseFromSlice([]const Wire, gpa, json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EvalFailed, // malformed shim JSON
    };
    defer parsed.deinit();
    const dialogs = try gpa.alloc(page_port.DialogInfo, parsed.value.len);
    var filled: usize = 0;
    // The whole array goes on failure (freeDialogs on dialogs[0..filled] freed it with the wrong length, or not
    // at all before the first entry; found by the shared parser's allocation-failure test, 4pa.62).
    errdefer {
        for (dialogs[0..filled]) |d| {
            gpa.free(d.message);
            if (d.default_text) |text| gpa.free(text);
        }
        gpa.free(dialogs);
    }
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

/// The shim's window list JSON as WindowInfo (owned by `gpa`). Malformed
/// JSON or an unknown termination reason is EvalFailed.
pub fn parseWindows(gpa: std.mem.Allocator, json: []const u8) PortError![]page_port.WindowInfo {
    const Wire = struct {
        id: u32,
        url: []const u8,
        title: []const u8,
        primary: bool,
        opener: u32,
        crashed: ?[]const u8 = null,
        responsive: bool = true,
        unresponsive_ms: u64 = 0,
        loading: bool = false,
        dialog_open: bool = false,
        incident: u32 = 0,
        process_group: u32 = 0,
        load_serial: u64 = 0,
    };
    const parsed = std.json.parseFromSlice([]const Wire, gpa, json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EvalFailed, // malformed shim JSON
    };
    defer parsed.deinit();
    const windows = try gpa.alloc(page_port.WindowInfo, parsed.value.len);
    var filled: usize = 0;
    errdefer {
        for (windows[0..filled]) |w| {
            gpa.free(w.url);
            gpa.free(w.title);
        }
        gpa.free(windows);
    }
    for (parsed.value, windows) |wire, *info| {
        const url_copy = try gpa.dupe(u8, wire.url);
        const title_copy = gpa.dupe(u8, wire.title) catch |e| {
            gpa.free(url_copy);
            return e;
        };
        const terminated: ?page_port.Termination = if (wire.crashed) |reason|
            std.meta.stringToEnum(page_port.Termination, reason) orelse {
                gpa.free(url_copy);
                gpa.free(title_copy);
                return error.EvalFailed;
            }
        else
            null;
        info.* = .{
            .id = wire.id,
            .url = url_copy,
            .title = title_copy,
            .primary = wire.primary,
            .opener = if (wire.opener == 0) null else wire.opener,
            .terminated = terminated,
            .web_process_responsive = wire.responsive,
            .unresponsive_ms = wire.unresponsive_ms,
            .loading = wire.loading,
            .dialog_open = wire.dialog_open,
            .incident = wire.incident,
            .process_group = wire.process_group,
            .load_serial = wire.load_serial,
        };
        filled += 1;
    }
    return windows;
}

pub fn parseRecovered(gpa: std.mem.Allocator, json: []const u8) PortError![]page_port.RecoveredWindow {
    const Wire = struct { id: u32, url: []const u8, ended: bool, reloaded: bool };
    const parsed = std.json.parseFromSlice([]const Wire, gpa, json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.EvalFailed,
    };
    defer parsed.deinit();
    const windows = try gpa.alloc(page_port.RecoveredWindow, parsed.value.len);
    var filled: usize = 0;
    errdefer {
        for (windows[0..filled]) |w| gpa.free(w.url);
        gpa.free(windows);
    }
    for (parsed.value, windows) |wire, *w| {
        w.* = .{ .id = wire.id, .url = try gpa.dupe(u8, wire.url), .ended = wire.ended, .reloaded = wire.reloaded };
        filled += 1;
    }
    return windows;
}

pub fn mapCode(rc: c_int) PortError!void {
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
