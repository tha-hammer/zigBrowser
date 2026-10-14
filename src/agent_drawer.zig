//! The Claude Agent drawer's pure logic (plan D3/D4): the floating "S"
//! icon's gestures, keyboard moves, clamping, the ratios its position is
//! kept in, and `<profile>/agent-drawer.json`. The GTK glue in
//! src/agent_drawer.c calls the `zb_drawer_*` exports below; it holds no
//! geometry of its own.
//!
//! Coordinates are logical pixels in the window's content area (the
//! overlay), origin top-left.

const std = @import("std");
const builtin = @import("builtin");
const atomic_file = @import("atomic_file.zig");

pub const icon_size: c_int = 56;
/// The default position: bottom-right, this far from both edges.
pub const icon_margin: c_int = 24;
/// A press and release that moved at most this far (in px) is a click.
pub const drag_threshold: f64 = 6;
pub const key_step: c_int = 16;
pub const key_step_big: c_int = 64;

pub const Rect = extern struct { x: c_int, y: c_int, w: c_int, h: c_int };
/// The icon's centre as a fraction (0..1) of the content area.
pub const Ratios = extern struct { x: f64, y: f64 };
pub const Gesture = enum(c_int) { click = 0, drag = 1 };

pub fn classifyGesture(dx: f64, dy: f64) Gesture {
    return if (dx * dx + dy * dy > drag_threshold * drag_threshold) .drag else .click;
}

/// `r` moved (not resized) fully inside a `width` x `height` area; an area
/// smaller than `r` pins it at 0,0.
pub fn clampRect(r: Rect, width: c_int, height: c_int) Rect {
    return .{
        .x = std.math.clamp(r.x, 0, @max(0, width - r.w)),
        .y = std.math.clamp(r.y, 0, @max(0, height - r.h)),
        .w = r.w,
        .h = r.h,
    };
}

pub fn defaultRect(width: c_int, height: c_int) Rect {
    const far = icon_margin + icon_size;
    return clampRect(.{ .x = width - far, .y = height - far, .w = icon_size, .h = icon_size }, width, height);
}

pub fn rectFromRatios(p: Ratios, width: c_int, height: c_int) Rect {
    const half = @as(f64, @floatFromInt(icon_size)) / 2;
    const x = @floor(unitRatio(p.x) * @as(f64, @floatFromInt(width)) - half + 0.5);
    const y = @floor(unitRatio(p.y) * @as(f64, @floatFromInt(height)) - half + 0.5);
    return clampRect(.{ .x = @intFromFloat(x), .y = @intFromFloat(y), .w = icon_size, .h = icon_size }, width, height);
}

pub fn ratiosFromRect(r: Rect, width: c_int, height: c_int) Ratios {
    return .{ .x = centreRatio(r.x, r.w, width), .y = centreRatio(r.y, r.h, height) };
}

/// A ratio usable as a position: in [0,1], and the centre for NaN or infinity.
fn unitRatio(v: f64) f64 {
    return if (std.math.isFinite(v)) std.math.clamp(v, 0, 1) else 0.5;
}

fn centreRatio(start: c_int, size: c_int, extent: c_int) f64 {
    if (extent <= 0) return 0.5;
    return unitRatio((@as(f64, @floatFromInt(start)) + @as(f64, @floatFromInt(size)) / 2) / @as(f64, @floatFromInt(extent)));
}

/// One arrow-key press: `dx`, `dy` in steps (-1, 0, 1).
pub fn keyMove(r: Rect, dx: c_int, dy: c_int, big: bool, width: c_int, height: c_int) Rect {
    const step = if (big) key_step_big else key_step;
    return clampRect(.{ .x = r.x + dx * step, .y = r.y + dy * step, .w = r.w, .h = r.h }, width, height);
}

/// The open drawer (D2): full width at the bottom; 40% of the height,
/// at least 220 px and at most 70%.
pub fn drawerRect(width: c_int, height: c_int) Rect {
    const h: f64 = @floatFromInt(@max(0, height));
    const wanted: c_int = @intFromFloat(@floor(h * 0.4 + 0.5));
    const most: c_int = @intFromFloat(@floor(h * 0.7));
    const tall = @min(@max(wanted, 220), most);
    return .{ .x = 0, .y = height - tall, .w = width, .h = tall };
}

pub const file_name = "agent-drawer.json";
pub const max_file_bytes: usize = 1024;
pub const version: u32 = 1;

pub const Loaded = union(enum) {
    missing,
    corrupt,
    ok: Ratios,
};

/// The file's exact schema: every field required, none unknown.
const FileState = struct { version: u32, x: f64, y: f64 };

pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Loaded {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        else => .corrupt,
    };
    defer gpa.free(text);
    const parsed = std.json.parseFromSlice(FileState, gpa, text, .{}) catch return .corrupt;
    defer parsed.deinit();
    const file = parsed.value;
    if (file.version != version or !inUnit(file.x) or !inUnit(file.y)) return .corrupt;
    return .{ .ok = .{ .x = file.x, .y = file.y } };
}

fn inUnit(v: f64) bool {
    return std.math.isFinite(v) and v >= 0 and v <= 1;
}

/// Atomic replace (atomic_file.zig).
pub fn save(io: std.Io, path: []const u8, ratios: Ratios) !void {
    try atomic_file.replaceJson(io, path, FileState{ .version = version, .x = ratios.x, .y = ratios.y });
}

/// The process-wide starting position: the last user move (or the file's,
/// at startup), shared by every window; saved to the profile when there
/// is one. Touched only by `configure` (before any window) and by the GTK
/// thread.
const Store = struct {
    io: ?std.Io = null,
    path: ?[]const u8 = null,
    last: ?Ratios = null,
};
var store: Store = .{};

/// Startup: where agent-drawer.json lives (`profile_dir` null: nowhere,
/// nothing is persisted), and the position it holds. A corrupt file means
/// the default, and stderr says so. `gpa` must outlive the process's
/// windows (the path is kept).
pub fn configure(io: std.Io, gpa: std.mem.Allocator, profile_dir: ?[]const u8) void {
    store = .{ .io = io };
    const dir = profile_dir orelse return;
    const path = std.fs.path.join(gpa, &.{ dir, file_name }) catch return;
    store.path = path;
    switch (load(io, gpa, path)) {
        .ok => |p| store.last = p,
        .missing => {},
        .corrupt => std.debug.print("zigBrowser: {s} unreadable; using default\n", .{file_name}),
    }
}

// --- C glue (src/agent_drawer.c) --------------------------------------------

// Exported only where src/agent_drawer.c is built (the GTK backend); the
// other backends have no drawer.
comptime {
    if (builtin.os.tag == .linux) {
        @export(&zb_drawer_classify, .{ .name = "zb_drawer_classify" });
        @export(&zb_drawer_place, .{ .name = "zb_drawer_place" });
        @export(&zb_drawer_ratios_of, .{ .name = "zb_drawer_ratios_of" });
        @export(&zb_drawer_clamp, .{ .name = "zb_drawer_clamp" });
        @export(&zb_drawer_key_move, .{ .name = "zb_drawer_key_move" });
        @export(&zb_drawer_panel_rect, .{ .name = "zb_drawer_panel_rect" });
        @export(&zb_drawer_start_ratios, .{ .name = "zb_drawer_start_ratios" });
        @export(&zb_drawer_remember, .{ .name = "zb_drawer_remember" });
    }
}

fn zb_drawer_classify(dx: f64, dy: f64) callconv(.c) c_int {
    return @intFromEnum(classifyGesture(dx, dy));
}

/// A window's icon rect: from its ratios, or the default when `ratios` is null.
fn zb_drawer_place(ratios: ?*const Ratios, width: c_int, height: c_int, out: *Rect) callconv(.c) void {
    out.* = if (ratios) |p| rectFromRatios(p.*, width, height) else defaultRect(width, height);
}

fn zb_drawer_ratios_of(r: *const Rect, width: c_int, height: c_int, out: *Ratios) callconv(.c) void {
    out.* = ratiosFromRect(r.*, width, height);
}

fn zb_drawer_clamp(r: *Rect, width: c_int, height: c_int) callconv(.c) void {
    r.* = clampRect(r.*, width, height);
}

fn zb_drawer_key_move(r: *Rect, dx: c_int, dy: c_int, big: c_int, width: c_int, height: c_int) callconv(.c) void {
    r.* = keyMove(r.*, dx, dy, big != 0, width, height);
}

fn zb_drawer_panel_rect(width: c_int, height: c_int, out: *Rect) callconv(.c) void {
    out.* = drawerRect(width, height);
}

/// 1 and `out` set: new windows start at this position; 0: the default.
fn zb_drawer_start_ratios(out: *Ratios) callconv(.c) c_int {
    out.* = store.last orelse return 0;
    return 1;
}

/// A user move: new windows start here, and the profile keeps it.
fn zb_drawer_remember(ratios: *const Ratios) callconv(.c) void {
    store.last = ratios.*;
    const io = store.io orelse return;
    const path = store.path orelse return;
    save(io, path, ratios.*) catch |err| std.debug.print("zigBrowser: {s} not saved: {s}\n", .{ file_name, @errorName(err) });
}
