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

/// The minimize animation (D5): `t` in [0,1] from `a` to `b`, each edge
/// rounded to the nearest pixel.
pub fn lerpRect(a: Rect, b: Rect, t: f64) Rect {
    const u = std.math.clamp(t, 0, 1);
    return .{ .x = lerp(a.x, b.x, u), .y = lerp(a.y, b.y, u), .w = lerp(a.w, b.w, u), .h = lerp(a.h, b.h, u) };
}

fn lerp(a: c_int, b: c_int, t: f64) c_int {
    const fa: f64 = @floatFromInt(a);
    const fb: f64 = @floatFromInt(b);
    return @intFromFloat(@floor(fa + (fb - fa) * t + 0.5));
}

/// Ease-out over [0,1] (cubic): fast start, gentle stop.
pub fn ease(t: f64) f64 {
    const u = 1 - std.math.clamp(t, 0, 1);
    return 1 - u * u * u;
}

pub const anim_ms: i64 = 180;

/// The e2e-only seed `ZIGBROWSER_AGENT_DRAWER_DEMO` (plan section 7):
/// exactly `messages:<n>` with 1 <= n <= 5000; anything else is null.
pub fn parseDemo(text: []const u8) ?u32 {
    const prefix = "messages:";
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    return parseBounded(text[prefix.len..], 1, max_demo_messages);
}

/// Decimal digits only (at most 4), within [lo, hi].
fn parseBounded(digits: []const u8, lo: u32, hi: u32) ?u32 {
    if (digits.len == 0 or digits.len > 4) return null;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
    const n = std.fmt.parseInt(u32, digits, 10) catch return null;
    return if (n >= lo and n <= hi) n else null;
}

pub const demo_env_name = "ZIGBROWSER_AGENT_DRAWER_DEMO";

/// The e2e-only seam `ZIGBROWSER_AGENT_ANIM_MS` (plan S2.2, rev 12): the
/// minimize animation's length, exactly 180..5000 ms in decimal digits.
pub fn parseAnimMs(text: []const u8) ?u32 {
    return parseBounded(text, @intCast(anim_ms), max_anim_ms);
}

pub const max_anim_ms: u32 = 5000;

pub const anim_env_name = "ZIGBROWSER_AGENT_ANIM_MS";
pub const max_demo_messages: u32 = 5000;

/// A DRAWER row's text field holds at most this many bytes, then "…".
pub const row_text_max: usize = 4096;

/// How many bytes of `text` a row keeps: all of it up to `row_text_max`,
/// else the longest prefix that ends on a UTF-8 character boundary.
pub fn rowTextLen(text: []const u8) usize {
    if (text.len <= row_text_max) return text.len;
    var end = row_text_max;
    // Back up over continuation bytes (10xxxxxx) to the start of the
    // character the cut would split.
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return end;
}

/// S5c-1 (plan S5.6, rev 16.20.2; the user's decision 1): a run of more than
/// `break_run_min` characters with no whitespace gets a line break after every
/// `break_every` characters of it, so GTK can lay it out (a long unbroken run froze
/// the bubble's layout). Rev 16.20.9: the break is a line feed, not U+200B, so a run
/// becomes short paragraphs that a text view lays out piece by piece (one 256 KB
/// paragraph took 0.65 s per layout). Copy removes it (originalOffset). Whitespace is ASCII SP, HT, LF, VT, FF and CR; a
/// character is a UTF-8 code point. Nothing else is changed.
/// The most of one reply a bubble shows: the helper's message cap (256 KiB of
/// UTF-8). A streaming reply stops growing there and ends with the marker.
pub const reply_text_max: usize = 256 * 1024;
/// Rev 16.20.12: the marker counts inside reply_text_max, so a capped bubble shows at
/// most reply_content_max bytes of the reply and then the marker.
pub const truncated_marker = "\n[output truncated]";
pub const reply_content_max: usize = reply_text_max - truncated_marker.len;
/// A bubble over this many bytes is a read-only text view, not a label: a label's
/// first layout of 200 KB takes 6-7 s, a text view's under 1 s (rev 16.20.6).
pub const label_text_max: usize = 32 * 1024;
pub const break_run_min: usize = 128;
pub const break_every: usize = 64;
const break_point = "\n";

fn isSpace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\n', 0x0b, 0x0c, '\r' => true,
        else => false,
    };
}

/// The byte length of the character at `text[i]`: its UTF-8 length, or 1 for a
/// stray byte, never past the end.
fn charLen(text: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
    return @min(n, text.len - i);
}

/// One run starting at `start`: its end (byte offset) and its length in characters.
fn runAt(text: []const u8, start: usize) struct { end: usize, chars: usize } {
    var end = start;
    var chars: usize = 0;
    while (end < text.len and !isSpace(text[end])) : (chars += 1) end += charLen(text, end);
    return .{ .end = end, .chars = chars };
}

/// The text a bubble shows: `text` with the break points added. Caller frees.
pub fn breakRuns(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, text.len);
    var i: usize = 0;
    while (i < text.len) {
        if (isSpace(text[i])) {
            try out.append(gpa, text[i]);
            i += 1;
            continue;
        }
        const run = runAt(text, i);
        if (run.chars <= break_run_min) {
            try out.appendSlice(gpa, text[i..run.end]);
            i = run.end;
            continue;
        }
        var k: usize = 0;
        while (i < run.end) {
            const n = charLen(text, i);
            try out.appendSlice(gpa, text[i .. i + n]);
            i += n;
            k += 1;
            if (k % break_every == 0 and i < run.end) try out.appendSlice(gpa, break_point);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Copy's map: the byte offset in the original `text` of the shown text's
/// character offset `shown` (an added break point maps to the offset after the
/// character before it). Past the end: `text.len`.
pub fn originalOffset(text: []const u8, shown: usize) usize {
    var at: usize = 0; // characters of the shown text passed so far
    var i: usize = 0;
    while (i < text.len) {
        if (at == shown) return i;
        if (isSpace(text[i])) {
            at += 1;
            i += 1;
            continue;
        }
        const run = runAt(text, i);
        var k: usize = 0;
        while (i < run.end) {
            if (at == shown) return i;
            i += charLen(text, i);
            at += 1;
            k += 1;
            if (run.chars > break_run_min and k % break_every == 0 and i < run.end) {
                if (at == shown) return i;
                at += 1;
            }
        }
    }
    return text.len;
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
    /// The e2e-only seed: system messages each new drawer starts with.
    demo_messages: u32 = 0,
    /// The minimize animation's length (the e2e-only seam can stretch it).
    anim_ms: u32 = @intCast(anim_ms),
};

/// The e2e-only seams this module reads (plan section 7): honoured only
/// with --e2e-protocol.
pub const Seams = struct {
    demo: ?[]const u8 = null,
    anim_ms: ?[]const u8 = null,
};

/// An e2e-only seam's value: parsed with --e2e-protocol, else refused; a
/// bad value is refused. Either refusal is reported on stderr.
fn honour(name: []const u8, text: ?[]const u8, e2e_protocol: bool, parse: *const fn ([]const u8) ?u32) ?u32 {
    const value = text orelse return null;
    if (!e2e_protocol) {
        std.debug.print("zigBrowser: {s} ignored without --e2e-protocol\n", .{name});
        return null;
    }
    return parse(value) orelse {
        std.debug.print("zigBrowser: {s}={s} ignored\n", .{ name, value });
        return null;
    };
}
var store: Store = .{};

/// Startup: where agent-drawer.json lives (`profile_dir` null: nowhere,
/// nothing is persisted), and the position it holds. A corrupt file means
/// the default, and stderr says so. `gpa` must outlive the process's
/// windows (the path is kept). `seams`: the e2e-only variables' values,
/// honoured only with `e2e_protocol`.
pub fn configure(io: std.Io, gpa: std.mem.Allocator, profile_dir: ?[]const u8, seams: Seams, e2e_protocol: bool) void {
    store = .{ .io = io };
    if (honour(demo_env_name, seams.demo, e2e_protocol, parseDemo)) |n| store.demo_messages = n;
    if (honour(anim_env_name, seams.anim_ms, e2e_protocol, parseAnimMs)) |ms| store.anim_ms = ms;
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
        @export(&zb_drawer_lerp, .{ .name = "zb_drawer_lerp" });
        @export(&zb_drawer_ease, .{ .name = "zb_drawer_ease" });
        @export(&zb_drawer_row_text_len, .{ .name = "zb_drawer_row_text_len" });
        @export(&zb_drawer_break_runs, .{ .name = "zb_drawer_break_runs" });
        @export(&zb_drawer_original_offset, .{ .name = "zb_drawer_original_offset" });
        @export(&zb_drawer_reply_text_max, .{ .name = "zb_drawer_reply_text_max" });
        @export(&zb_drawer_reply_content_max, .{ .name = "zb_drawer_reply_content_max" });
        @export(&zb_drawer_label_text_max, .{ .name = "zb_drawer_label_text_max" });
        @export(&zb_drawer_demo_messages, .{ .name = "zb_drawer_demo_messages" });
        @export(&zb_drawer_anim_ms, .{ .name = "zb_drawer_anim_ms" });
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

fn zb_drawer_lerp(a: *const Rect, b: *const Rect, t: f64, out: *Rect) callconv(.c) void {
    out.* = lerpRect(a.*, b.*, t);
}

fn zb_drawer_ease(t: f64) callconv(.c) f64 {
    return ease(t);
}

fn zb_drawer_row_text_len(text: [*]const u8, len: usize) callconv(.c) usize {
    return rowTextLen(text[0..len]);
}

/// The shown text of a bubble (breakRuns), NUL-terminated, from malloc: the
/// caller frees it with free(). Null when out of memory.
fn zb_drawer_break_runs(text: [*]const u8, len: usize, out_len: *usize) callconv(.c) ?[*:0]u8 {
    const shown = breakRuns(std.heap.c_allocator, text[0..len]) catch return null;
    defer std.heap.c_allocator.free(shown);
    const z = std.heap.c_allocator.dupeZ(u8, shown) catch return null;
    out_len.* = shown.len;
    return z.ptr;
}

fn zb_drawer_label_text_max() callconv(.c) usize {
    return label_text_max;
}

fn zb_drawer_reply_text_max() callconv(.c) usize {
    return reply_text_max;
}

fn zb_drawer_reply_content_max() callconv(.c) usize {
    return reply_content_max;
}

fn zb_drawer_original_offset(text: [*]const u8, len: usize, shown: usize) callconv(.c) usize {
    return originalOffset(text[0..len], shown);
}

/// How many seeded system messages a new drawer starts with (0: none).
fn zb_drawer_demo_messages() callconv(.c) c_uint {
    return store.demo_messages;
}

/// The minimize animation's length in ms (180 unless the e2e-only seam
/// stretched it).
fn zb_drawer_anim_ms() callconv(.c) c_uint {
    return store.anim_ms;
}
