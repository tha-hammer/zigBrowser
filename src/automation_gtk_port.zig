//! GTK PagePort: implements `page_port.PagePort` (v3.2) over the blocking
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
    .nativeClick = nativeClick,
    .nativeKey = nativeKey,
    .nativeText = nativeText,
    .nativeMove = nativeMove,
    .pointer = pointer,
    .setInputFiles = setInputFiles,
    .nativeScroll = nativeScroll,
    .screenshot = screenshot,
};

fn mapCode(rc: c_int) PortError!void {
    return switch (rc) {
        c.ZB_AUTO_OK => {},
        c.ZB_AUTO_ERR_TIMEOUT => error.Timeout,
        c.ZB_AUTO_ERR_NO_WINDOW => error.NoPage,
        c.ZB_AUTO_ERR_NAV_FAILED => error.NavigationFailed,
        c.ZB_AUTO_ERR_NO_LOOP, c.ZB_AUTO_ERR_CANCELLED => error.Cancelled,
        c.ZB_AUTO_ERR_DOC_CHANGED => error.DocumentChanged,
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

// --- Native (trusted) input: the PagePort v3.1 methods (N7) ---
//
// Each call reads the page's trusted-input acknowledgement counters
// (__zbAutomation.inputAck() in the automation world), sends real GDK events
// through the shim, then waits until the page has acknowledged them - all
// within the one `timeout_ms`. WebKit delivers native events asynchronously
// (and mouse and key queues are not ordered against each other), so without
// the wait a following step could run before the page saw the input.
//
// `document` (the locate op's documentToken) is passed to the shim, which
// compares it on the GTK thread immediately before delivering the events
// (DocumentChanged, nothing sent, if the page moved on).
//
// Ack debt: acknowledgements are counts, not tied to a request. When a call
// gives up (Timeout) after dispatching, its events still reach the page
// later and could satisfy the next call's wait. The counts that call still
// owed are kept as debt, and the next native call drains them within its own
// deadline before it reads its baseline or sends anything.

const ack_body = "const a = globalThis.__zbAutomation; if (!a) return 'null'; return JSON.stringify(a.inputAck());";

/// Length of documentToken: 8 random bytes as lower-case hex.
const doc_len = 16;

const Ack = struct {
    /// Per-document id; a different one means the page navigated.
    doc: [doc_len]u8 = undefined,
    keyup: i64 = 0,
    click: i64 = 0,
    wheel: i64 = 0,
    /// Scroll events seen, and ms since the last one (-1: none yet).
    scrolls: i64 = 0,
    scroll_quiet_ms: f64 = -1,
    /// Cross-document navigations started from this document so far.
    navigations: i64 = 0,
    /// One of them is still in flight (not cancelled, stopped, or ended
    /// without a new document): this document may be going away.
    leaving: bool = false,

    fn isDocument(self: Ack, token: []const u8) bool {
        return std.mem.eql(u8, &self.doc, token);
    }
};


/// Guards `debt`: a few loads/stores, so a spin lock suffices (std.Io.Mutex
/// would need an Io this adapter does not have).
const SpinLock = struct {
    held: std.atomic.Value(bool) = .{ .raw = false },

    fn lock(self: *SpinLock) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.held.store(false, .release);
    }

    /// Acquire within the caller's deadline (Timeout, nothing sent, if a
    /// longer transaction holds it past that).
    fn lockUntil(self: *SpinLock, deadline: i64) PortError!void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            sleepMs(@min(1, try remainingMs(deadline)));
        }
    }
};

/// One native transaction (drain debt, baseline, guarded dispatch, settle) at
/// a time for the WebView: concurrent calls sharing a baseline could each be
/// satisfied by the other's acknowledgement. The adapter targets only the
/// primary window today; per-WebView state comes with multi-window ports.
var txn_lock: SpinLock = .{};

fn monotonicMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, &ts);
}

fn deadlineAfter(timeout_ms: u64) i64 {
    return monotonicMs() + @as(i64, @intCast(@min(timeout_ms, std.math.maxInt(i32))));
}

fn remainingMs(deadline: i64) PortError!u64 {
    const left = deadline - monotonicMs();
    if (left <= 0) return error.Timeout;
    return @intCast(left);
}

fn isDocumentToken(token: []const u8) bool {
    if (token.len != doc_len) return false;
    for (token) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false;
    return true;
}

/// The page's acknowledgement counters, or null while no automation script
/// answers (the document is being replaced). A malformed answer is EvalFailed.
fn readAckFromPage(_: *anyopaque, deadline: i64) PortError!?Ack {
    const gpa = std.heap.c_allocator;
    const out = try evalJson(&port_tag, gpa, .automation, ack_body, "null", try remainingMs(deadline));
    defer gpa.free(out);
    if (std.mem.eql(u8, out, "null")) return null;
    const Wire = struct { doc: []const u8, mouseup: i64, keyup: i64, click: i64, wheel: i64 = 0, scrolls: i64 = 0, scrollQuietMs: f64 = -1, navigations: i64 = 0, leaving: bool = false };
    const parsed = std.json.parseFromSlice(Wire, gpa, out, .{}) catch return error.EvalFailed;
    defer parsed.deinit();
    if (!isDocumentToken(parsed.value.doc)) return error.EvalFailed;
    var ack: Ack = .{ .keyup = parsed.value.keyup, .click = parsed.value.click, .wheel = parsed.value.wheel, .scrolls = parsed.value.scrolls, .scroll_quiet_ms = parsed.value.scrollQuietMs, .navigations = parsed.value.navigations, .leaving = parsed.value.leaving };
    @memcpy(&ack.doc, parsed.value.doc);
    return ack;
}

const AckOutcome = enum { acknowledged, document_changed, leaving };

/// Acknowledgement reading plus the debt the page still owes for earlier
/// calls that gave up. Production uses one tracker bound to the live page
/// (`page_acks`); tests build their own with a fake reader, so nothing global
/// is ever swapped.
const AckTracker = struct {
    reader: *const fn (ctx: *anyopaque, deadline: i64) PortError!?Ack,
    ctx: *anyopaque,
    debt: ?Ack = null,
    debt_mutex: SpinLock = .{},

    fn read(self: *AckTracker, deadline: i64) PortError!?Ack {
        return self.reader(self.ctx, deadline);
    }

    fn readBaseline(self: *AckTracker, deadline: i64) PortError!Ack {
        while (true) {
            if (try self.read(deadline)) |ack| return ack;
            sleepMs(@min(5, try remainingMs(deadline)));
        }
    }

    /// Wait until the page reached `target`'s counts, or a different
    /// document replaced it.
    fn waitAck(self: *AckTracker, target: Ack, deadline: i64) PortError!AckOutcome {
        while (true) {
            if (try self.read(deadline)) |now| {
                if (!now.isDocument(&target.doc)) return .document_changed;
                // A navigation started since `target`'s baseline (even one
                // the page cancels later) ends the current sequence.
                if (now.click >= target.click and now.keyup >= target.keyup and now.wheel >= target.wheel) return if (now.navigations != target.navigations) .leaving else .acknowledged;
            }
            sleepMs(@min(5, try remainingMs(deadline)));
        }
    }

    fn owed(self: *AckTracker) ?Ack {
        self.debt_mutex.lock();
        defer self.debt_mutex.unlock();
        return self.debt;
    }

    fn clearDebt(self: *AckTracker) void {
        self.debt_mutex.lock();
        defer self.debt_mutex.unlock();
        self.debt = null;
    }

    fn addDebt(self: *AckTracker, target: Ack) void {
        self.debt_mutex.lock();
        defer self.debt_mutex.unlock();
        if (self.debt) |current| {
            if (std.mem.eql(u8, &current.doc, &target.doc)) {
                self.debt = .{ .doc = target.doc, .click = @max(current.click, target.click), .keyup = @max(current.keyup, target.keyup), .wheel = @max(current.wheel, target.wheel), .navigations = target.navigations };
                return;
            }
        }
        self.debt = target;
    }

    /// Before sending anything new: wait out what earlier calls still owe.
    /// A Timeout here means no new input was sent.
    fn drainDebt(self: *AckTracker, deadline: i64) PortError!void {
        const target = self.owed() orelse return;
        _ = try self.waitAck(target, deadline);
        self.clearDebt();
    }

    /// Called right after a successful dispatch: the counts are owed from now
    /// on and stay owed through any failure (Timeout, a failed read, a
    /// cancel), since the events still reach the page. Only an
    /// acknowledgement or a document change settles them.
    fn settle(self: *AckTracker, target: Ack, deadline: i64) PortError!AckOutcome {
        self.addDebt(target);
        const outcome = try self.waitAck(target, deadline);
        self.clearDebt(); // transactions are serialized: the debt was this target's
        return outcome;
    }

    /// Common start: valid token, drained debt, baseline in the expected document.
    fn begin(self: *AckTracker, document: ?[]const u8, deadline: i64) PortError!Ack {
        if (document) |token| {
            if (std.mem.indexOfScalar(u8, token, 0) != null or !isDocumentToken(token)) return error.EvalFailed;
        }
        try self.drainDebt(deadline);
        const base = try self.readBaseline(deadline);
        if (document) |token| if (!base.isDocument(token)) return error.DocumentChanged;
        return base;
    }
};

var page_acks: AckTracker = .{ .reader = readAckFromPage, .ctx = &port_tag };

fn mapNativeCode(rc: c_int) PortError!void {
    if (rc == c.ZB_AUTO_ERR_DOC_CHANGED) return error.DocumentChanged;
    return mapCode(rc);
}

const Point = page_port.Point;

/// PagePort v3.2 `pointer`: the last position actually dispatched to the
/// primary window, or null. The shim keeps it per ZbWindow (written by the
/// GTK-thread dispatch itself, cleared with the window), so a window that
/// becomes primary never inherits another window's position.
pub fn pointer(_: *anyopaque) ?Point {
    var x: f64 = 0;
    var y: f64 = 0;
    if (c.zb_native_pointer(null, &x, &y) == 0) return null;
    return .{ .x = x, .y = y };
}

/// One real pointer-motion event to viewport CSS px (x, y), no click (N8
/// humanized paths). Guarded by `document` like nativeClick. Returns once
/// dispatched: motion shares WebKit's FIFO mouse queue with the click that
/// follows it, so it needs no acknowledgement (WebKit may coalesce moves).
pub fn nativeMove(_: *anyopaque, x: f64, y: f64, document: ?[]const u8, timeout_ms: u64) PortError!void {
    const deadline = deadlineAfter(timeout_ms);
    try txn_lock.lockUntil(deadline);
    defer txn_lock.unlock();
    _ = try page_acks.begin(document, deadline);
    var doc_z: [doc_len + 1]u8 = undefined;
    const expected = if (document) |token| docZ(&doc_z, token) else null;
    var err: [*c]u8 = null;
    const rc = c.zb_native_move(null, x, y, expected, clampMs(try remainingMs(deadline)), &err);
    c.zb_automation_free(err);
    try mapNativeCode(rc);
}

/// PagePort v3.4: PNG of the visible viewport, or of the whole document.
/// Bounded by the deadline; an encoded PNG over max_screenshot_bytes is
/// TooLarge. `png` is owned by `gpa`.
pub fn screenshot(_: *anyopaque, gpa: std.mem.Allocator, full_page: bool, timeout_ms: u64) PortError!page_port.Screenshot {
    return screenshotWithLimit(gpa, full_page, page_port.max_screenshot_bytes, timeout_ms);
}

/// screenshot with an explicit encoded-size limit (tests use a tiny one).
pub fn screenshotWithLimit(gpa: std.mem.Allocator, full_page: bool, max_bytes: usize, timeout_ms: u64) PortError!page_port.Screenshot {
    var png: [*c]u8 = null;
    var len: usize = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    var err: [*c]u8 = null;
    const rc = c.zb_screenshot_png(null, @intFromBool(full_page), max_bytes, clampMs(timeout_ms), &png, &len, &width, &height, &err);
    c.zb_automation_free(err);
    defer c.zb_automation_free(png);
    if (rc == c.ZB_AUTO_ERR_TOO_LARGE) return error.TooLarge;
    try mapCode(rc);
    if (png == null or width <= 0 or height <= 0) return error.EvalFailed;
    return .{ .png = try gpa.dupe(u8, png[0..len]), .width = @intCast(width), .height = @intCast(height) };
}

/// Scrolling that a wheel started is over once no scroll event came for
/// this long (WebKit animates smooth scrolls over several frames).
const scroll_quiet_ms: f64 = 100;
/// A wheel that scrolls nothing (already at the end) never fires scroll
/// events: done after this long without one.
const scroll_start_ms: i64 = 250;

/// One real smooth-scroll event at viewport CSS px (x, y) by (delta_x,
/// delta_y) CSS px. Guarded by `document` like nativeClick. Returns once
/// the page acknowledged the trusted wheel event and the scrolling it
/// started has finished, so the next command sees the final offsets (or
/// a navigation replaced the page). Timeout after dispatch is never
/// retried.
pub fn nativeScroll(_: *anyopaque, x: f64, y: f64, delta_x: f64, delta_y: f64, document: ?[]const u8, timeout_ms: u64) PortError!page_port.ScrollOffsets {
    for ([_]f64{ x, y, delta_x, delta_y }) |v| if (!std.math.isFinite(v)) return error.EvalFailed;
    const deadline = deadlineAfter(timeout_ms);
    try txn_lock.lockUntil(deadline);
    defer txn_lock.unlock();
    const base = try page_acks.begin(document, deadline);
    var doc_z: [doc_len + 1]u8 = undefined;
    const expected = if (document) |token| docZ(&doc_z, token) else null;
    var err: [*c]u8 = null;
    const rc = c.zb_native_scroll(null, x, y, delta_x, delta_y, expected, clampMs(try remainingMs(deadline)), &err);
    c.zb_automation_free(err);
    try mapNativeCode(rc);
    return finishScroll(&page_acks, base, readScrollOffsets, deadline);
}

/// Offsets as read from the page, with the provenance read in the same
/// eval: the document, its navigation count and whether it is leaving.
const OffsetsRead = struct { x: f64, y: f64, doc: [doc_len]u8, navigations: i64 = 0, leaving: bool = false };

/// After a dispatched wheel: its acknowledgement, the scrolling it started
/// settling, then the offsets, all in the document the wheel went to. A
/// replaced (or leaving) document at any of those points is
/// DocumentReplaced: the wheel happened, and nothing from the replacement
/// page is ever returned (RoseCat 4756).
fn finishScroll(acks: *AckTracker, base: Ack, offsets: *const fn (deadline: i64) PortError!OffsetsRead, deadline: i64) PortError!page_port.ScrollOffsets {
    var target = base;
    target.wheel += 1;
    if (try acks.settle(target, deadline) != .acknowledged) return error.DocumentReplaced;
    try waitScrollSettled(acks, base, deadline);
    const read = try offsets(deadline);
    if (!base.isDocument(&read.doc) or read.navigations != base.navigations or read.leaving) return error.DocumentReplaced;
    return .{ .x = read.x, .y = read.y };
}

/// The page's scrollX/scrollY and document token (same deadline).
fn readScrollOffsets(deadline: i64) PortError!OffsetsRead {
    const gpa = std.heap.c_allocator;
    const body =
        \\const a = globalThis.__zbAutomation;
        \\if (!a) return JSON.stringify([globalThis.scrollX, globalThis.scrollY, '', 0, true]);
        \\const ack = a.inputAck();
        \\return JSON.stringify([globalThis.scrollX, globalThis.scrollY, ack.doc, ack.navigations, ack.leaving]);
    ;
    const out = try evalJson(&port_tag, gpa, .automation, body, "null", try remainingMs(deadline));
    defer gpa.free(out);
    const Wire = struct { f64, f64, []const u8, i64, bool };
    const parsed = std.json.parseFromSlice(Wire, gpa, out, .{}) catch return error.EvalFailed;
    defer parsed.deinit();
    // No automation script answering: the document is being replaced.
    if (!isDocumentToken(parsed.value[2])) return error.DocumentReplaced;
    var read: OffsetsRead = .{ .x = parsed.value[0], .y = parsed.value[1], .doc = undefined, .navigations = parsed.value[3], .leaving = parsed.value[4] };
    @memcpy(&read.doc, parsed.value[2]);
    return read;
}

/// PagePort v3.3: answer the file chooser that `function_body`'s op (the
/// automation.js chooseFiles command in `arg_json`) opens with `paths`.
/// Returns the op's JSON answer. Paths that are not absolute, readable
/// regular files: BadFile, nothing run. Chosen but unconfirmed (deadline,
/// a failed op, a lost page): FilesUnconfirmed, never to be repeated.
pub fn setInputFiles(_: *anyopaque, gpa: std.mem.Allocator, function_body: []const u8, arg_json: []const u8, paths: []const []const u8, timeout_ms: u64) PortError![]u8 {
    if (paths.len == 0 or paths.len > std.math.maxInt(c_int)) return error.BadFile;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const body_z = try arena.dupeZ(u8, function_body);
    const arg_z = try arena.dupeZ(u8, arg_json);
    const paths_z = try arena.alloc([*c]const u8, paths.len);
    for (paths, paths_z) |path, *slot| {
        // The C ABI is NUL-terminated: an embedded NUL would name another file.
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.BadFile;
        slot.* = (try arena.dupeZ(u8, path)).ptr;
    }
    var out: [*c]u8 = null;
    var err: [*c]u8 = null;
    const rc = c.zb_set_input_files(null, body_z.ptr, arg_z.ptr, paths_z.ptr, @intCast(paths.len), clampMs(timeout_ms), &out, &err);
    c.zb_automation_free(err);
    defer c.zb_automation_free(out);
    switch (rc) {
        c.ZB_AUTO_ERR_BAD_FILE => return error.BadFile,
        c.ZB_AUTO_ERR_FILES_UNCONFIRMED => return error.FilesUnconfirmed,
        else => try mapCode(rc),
    }
    if (out == null) return error.EvalFailed;
    return gpa.dupe(u8, std.mem.span(out));
}

/// After the wheel was acknowledged: wait until the scrolling it started
/// (scroll events past `scrolls_before`) has been quiet for
/// scroll_quiet_ms, or none started within scroll_start_ms.
fn waitScrollSettled(acks: *AckTracker, base: Ack, deadline: i64) PortError!void {
    const acked_at = monotonicMs();
    while (true) {
        const now = (try acks.read(deadline)) orelse return error.DocumentReplaced;
        if (!now.isDocument(&base.doc) or now.navigations != base.navigations) return error.DocumentReplaced;
        if (now.scrolls > base.scrolls) {
            if (now.scroll_quiet_ms >= scroll_quiet_ms) return;
        } else if (monotonicMs() - acked_at >= scroll_start_ms) return;
        sleepMs(@min(10, try remainingMs(deadline)));
    }
}

/// Real pointer motion + left click at viewport CSS px (x, y). Returns once
/// the page's click dispatch has finished, or the click navigated.
pub fn nativeClick(_: *anyopaque, x: f64, y: f64, document: ?[]const u8, timeout_ms: u64) PortError!void {
    const deadline = deadlineAfter(timeout_ms);
    try txn_lock.lockUntil(deadline);
    defer txn_lock.unlock();
    const base = try page_acks.begin(document, deadline);
    var doc_z: [doc_len + 1]u8 = undefined;
    const expected = if (document) |token| docZ(&doc_z, token) else null;
    var err: [*c]u8 = null;
    const rc = c.zb_native_click(null, x, y, 1, expected, clampMs(try remainingMs(deadline)), &err);
    c.zb_automation_free(err);
    try mapNativeCode(rc);
    _ = try page_acks.settle(.{ .doc = base.doc, .click = base.click + 1, .keyup = base.keyup, .navigations = base.navigations }, deadline);
}

/// One real key press (DOM key name) with modifiers: bit0 Shift, bit1
/// Control, bit2 Alt, bit3 Meta. Unknown keys are EvalFailed. A navigation
/// caused by the key (Enter submitting a form) is success.
pub fn nativeKey(_: *anyopaque, key: []const u8, modifiers: u8, document: ?[]const u8, timeout_ms: u64) PortError!void {
    if (std.mem.indexOfScalar(u8, key, 0) != null) return error.EvalFailed;
    const deadline = deadlineAfter(timeout_ms);
    const gpa = std.heap.c_allocator;
    const key_z = try gpa.dupeZ(u8, key);
    defer gpa.free(key_z);
    try txn_lock.lockUntil(deadline);
    defer txn_lock.unlock();
    const base = try page_acks.begin(document, deadline);
    var doc_z: [doc_len + 1]u8 = undefined;
    const expected = if (document) |token| docZ(&doc_z, token) else null;
    var releases: c_int = 0;
    var err: [*c]u8 = null;
    const rc = c.zb_native_key(null, key_z.ptr, @intCast(modifiers & 0x0f), expected, clampMs(try remainingMs(deadline)), &releases, &err);
    c.zb_automation_free(err);
    try mapNativeCode(rc);
    _ = try page_acks.settle(.{ .doc = base.doc, .click = base.click, .keyup = base.keyup + releases, .navigations = base.navigations }, deadline);
}

/// Types `text` one code point at a time with real key events. `sent_chars`
/// is always set, also on error: code points dispatched. Each character is
/// guarded against `document` on the GTK thread and acknowledged before the
/// next; as soon as an acknowledgement shows a new document it stops with
/// DocumentChanged, even if every code point was sent.
pub fn nativeText(_: *anyopaque, text: []const u8, document: ?[]const u8, timeout_ms: u64, sent_chars: *usize) PortError!void {
    sent_chars.* = 0;
    // The C ABI is NUL-terminated: refuse rather than silently truncate.
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.EvalFailed;
    if (!std.unicode.utf8ValidateSlice(text)) return error.EvalFailed;
    const deadline = deadlineAfter(timeout_ms);
    try txn_lock.lockUntil(deadline);
    defer txn_lock.unlock();
    var acked = try page_acks.begin(document, deadline);
    // A navigation that earlier input started is still in flight: type
    // nothing into a document that may be going away. It clears once that
    // navigation is cancelled or ends without a new document.
    if (acked.leaving) return error.DocumentChanged;
    var doc_z: [doc_len + 1]u8 = undefined;
    // Without an explicit token the baseline document is the one to stay in.
    const expected = docZ(&doc_z, document orelse &acked.doc);

    var it = (std.unicode.Utf8View.init(text) catch return error.EvalFailed).iterator();
    while (it.nextCodepointSlice()) |code_point| {
        var one: [5]u8 = undefined;
        @memcpy(one[0..code_point.len], code_point);
        one[code_point.len] = 0;
        var releases: c_int = 0;
        var chars: c_int = 0;
        var err: [*c]u8 = null;
        const rc = c.zb_native_text(null, @ptrCast(&one), expected, clampMs(try remainingMs(deadline)), &releases, &chars, &err);
        c.zb_automation_free(err);
        sent_chars.* += @intCast(chars);
        try mapNativeCode(rc);
        acked.keyup += releases;
        switch (try page_acks.settle(acked, deadline)) {
            .acknowledged => {},
            .document_changed, .leaving => return error.DocumentChanged,
        }
    }
}

fn docZ(buf: *[doc_len + 1]u8, token: []const u8) [*:0]const u8 {
    @memcpy(buf[0..doc_len], token[0..doc_len]);
    buf[doc_len] = 0;
    return @ptrCast(buf);
}

/// Scripted acknowledgement reads for a test-local AckTracker.
const FakeAcks = struct {
    steps: []const Step,
    index: usize = 0,

    const Step = union(enum) { ack: Ack, fail: PortError };

    fn read(ctx: *anyopaque, _: i64) PortError!?Ack {
        const self: *FakeAcks = @ptrCast(@alignCast(ctx));
        const step = self.steps[@min(self.index, self.steps.len - 1)];
        self.index += 1;
        return switch (step) {
            .ack => |a| a,
            .fail => |e| e,
        };
    }

    fn tracker(self: *FakeAcks) AckTracker {
        return .{ .reader = read, .ctx = self };
    }
};

fn testAck(keyup: i64) Ack {
    var a: Ack = .{ .keyup = keyup };
    @memcpy(&a.doc, "0123456789abcdef");
    return a;
}

test "a failed acknowledgement read after dispatch keeps the debt for the next call" {
    // Dispatched one key (target keyup 6); the read then fails.
    var failing: FakeAcks = .{ .steps = &.{.{ .fail = error.EvalFailed }} };
    var acks = failing.tracker();
    try std.testing.expectError(error.EvalFailed, acks.settle(testAck(6), deadlineAfter(1000)));
    try std.testing.expectEqual(@as(i64, 6), acks.owed().?.keyup);

    // The next call drains it first: the page still shows 5 twice, then 6;
    // only then is its baseline read (keyup 6), and the debt is gone.
    var page: FakeAcks = .{ .steps = &.{ .{ .ack = testAck(5) }, .{ .ack = testAck(5) }, .{ .ack = testAck(6) }, .{ .ack = testAck(6) } } };
    acks.reader = FakeAcks.read;
    acks.ctx = &page;
    const base = try acks.begin(null, deadlineAfter(1000));
    try std.testing.expectEqual(@as(i64, 6), base.keyup);
    try std.testing.expectEqual(@as(usize, 4), page.index);
    try std.testing.expect(acks.owed() == null);
}

test "debt is settled by an acknowledgement or a document change" {
    var acked: FakeAcks = .{ .steps = &.{.{ .ack = testAck(6) }} };
    var acks = acked.tracker();
    try std.testing.expectEqual(AckOutcome.acknowledged, try acks.settle(testAck(6), deadlineAfter(1000)));
    try std.testing.expect(acks.owed() == null);

    var other = testAck(0);
    @memcpy(&other.doc, "fedcba9876543210");
    var moved: FakeAcks = .{ .steps = &.{.{ .ack = other }} };
    var acks2 = moved.tracker();
    try std.testing.expectEqual(AckOutcome.document_changed, try acks2.settle(testAck(6), deadlineAfter(1000)));
    try std.testing.expect(acks2.owed() == null);
}

test "a navigation started during a sequence ends it, even after the page cancelled it" {
    var base = testAck(5);
    base.navigations = 2;
    // Started and cancelled between two reads: nothing is pending any more,
    // but the count moved, so this sequence stops.
    var cancelled = testAck(6);
    cancelled.navigations = 3;
    var page: FakeAcks = .{ .steps = &.{.{ .ack = cancelled }} };
    var acks = page.tracker();
    var target = base;
    target.keyup = 6;
    try std.testing.expectEqual(AckOutcome.leaving, try acks.settle(target, deadlineAfter(1000)));

    // The next sequence's baseline carries the new count: the same document,
    // with nothing in flight, acknowledges normally.
    var calm: FakeAcks = .{ .steps = &.{.{ .ack = cancelled }} };
    var acks2 = calm.tracker();
    try std.testing.expectEqual(AckOutcome.acknowledged, try acks2.settle(cancelled, deadlineAfter(1000)));
}

test "a scroll is acknowledged only by the page's trusted wheel count" {
    var before = testAck(5);
    before.wheel = 2;
    var after = before;
    after.wheel = 3;
    var page: FakeAcks = .{ .steps = &.{ .{ .ack = before }, .{ .ack = before }, .{ .ack = after } } };
    var acks = page.tracker();
    var target = before;
    target.wheel = 3;
    try std.testing.expectEqual(AckOutcome.acknowledged, try acks.settle(target, deadlineAfter(1000)));
    try std.testing.expectEqual(@as(usize, 3), page.index);
}

test "a scroll returns only once its scrolling went quiet" {
    var acked = testAck(5);
    acked.wheel = 1;
    var moving = acked;
    moving.scrolls = 3;
    moving.scroll_quiet_ms = 5;
    var quiet = moving;
    quiet.scrolls = 6;
    quiet.scroll_quiet_ms = 120;
    var page: FakeAcks = .{ .steps = &.{ .{ .ack = moving }, .{ .ack = moving }, .{ .ack = quiet } } };
    var acks = page.tracker();
    try waitScrollSettled(&acks, testAck(5), deadlineAfter(1000));
    try std.testing.expectEqual(@as(usize, 3), page.index);
}

/// Offsets reader for finishScroll tests: counts calls, answers `doc`
/// with the given navigation provenance.
const FakeOffsets = struct {
    var calls: usize = 0;
    var doc: [doc_len]u8 = "0123456789abcdef".*;
    var navigations: i64 = 0;
    var leaving: bool = false;

    fn read(_: i64) PortError!OffsetsRead {
        calls += 1;
        return .{ .x = 0, .y = 300, .doc = doc, .navigations = navigations, .leaving = leaving };
    }
};

test "a scroll whose document is replaced after the wheel is DocumentReplaced, never the new page's offsets" {
    const base = testAck(5);
    var other = testAck(5);
    other.wheel = 1;
    @memcpy(&other.doc, "fedcba9876543210");
    var leaving = testAck(5);
    leaving.wheel = 1;
    leaving.navigations = 1;
    leaving.leaving = true;
    var settled = testAck(5);
    settled.wheel = 1;
    settled.scrolls = 2;
    settled.scroll_quiet_ms = 150;

    // The acknowledgement already shows document B: no offsets are read.
    FakeOffsets.calls = 0;
    var replaced: FakeAcks = .{ .steps = &.{.{ .ack = other }} };
    var acks = replaced.tracker();
    try std.testing.expectError(error.DocumentReplaced, finishScroll(&acks, base, FakeOffsets.read, deadlineAfter(1000)));
    try std.testing.expectEqual(@as(usize, 0), FakeOffsets.calls);

    // The page started navigating away during the wheel: the same.
    var going: FakeAcks = .{ .steps = &.{.{ .ack = leaving }} };
    var acks2 = going.tracker();
    try std.testing.expectError(error.DocumentReplaced, finishScroll(&acks2, base, FakeOffsets.read, deadlineAfter(1000)));
    try std.testing.expectEqual(@as(usize, 0), FakeOffsets.calls);

    // Replaced between the settle and the read: the read's own token says so.
    FakeOffsets.doc = "fedcba9876543210".*;
    defer FakeOffsets.doc = "0123456789abcdef".*;
    var late: FakeAcks = .{ .steps = &.{ .{ .ack = settled }, .{ .ack = settled } } };
    var acks3 = late.tracker();
    try std.testing.expectError(error.DocumentReplaced, finishScroll(&acks3, base, FakeOffsets.read, deadlineAfter(1000)));

    // Settled in document A, but A started a navigation before the offsets
    // eval: same token, each provenance field on its own -> replaced.
    FakeOffsets.doc = "0123456789abcdef".*;
    FakeOffsets.navigations = 1;
    FakeOffsets.leaving = false;
    var navigated: FakeAcks = .{ .steps = &.{ .{ .ack = settled }, .{ .ack = settled } } };
    var acks_nav = navigated.tracker();
    try std.testing.expectError(error.DocumentReplaced, finishScroll(&acks_nav, base, FakeOffsets.read, deadlineAfter(1000)));
    FakeOffsets.navigations = 0;
    FakeOffsets.leaving = true;
    var going_away: FakeAcks = .{ .steps = &.{ .{ .ack = settled }, .{ .ack = settled } } };
    var acks_leave = going_away.tracker();
    try std.testing.expectError(error.DocumentReplaced, finishScroll(&acks_leave, base, FakeOffsets.read, deadlineAfter(1000)));
    FakeOffsets.leaving = false;

    // Same document throughout: the settled offsets.
    var same: FakeAcks = .{ .steps = &.{ .{ .ack = settled }, .{ .ack = settled } } };
    var acks4 = same.tracker();
    const offsets = try finishScroll(&acks4, base, FakeOffsets.read, deadlineAfter(1000));
    try std.testing.expectEqual(@as(f64, 300), offsets.y);
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

test "the GTK vtable implements the v3.2 pointer seam, not the Unsupported defaults" {
    if (!supported) return error.SkipZigTest;
    const port = pagePort().?;
    try std.testing.expect(port.vtable.nativeMove == &nativeMove);
    try std.testing.expect(port.vtable.pointer == &pointer);
}

test "the GTK vtable implements every PagePort method, none is left at its Unsupported default" {
    if (!supported) return error.SkipZigTest;
    // Any field added to PagePort.VTable with a default (the "not
    // supported" answer) must be wired here in the same slice.
    inline for (@typeInfo(PagePort.VTable).@"struct".fields) |field| {
        if (field.default_value_ptr) |default_ptr| {
            const default = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
            if (@field(vtable, field.name) == default) {
                std.debug.print("PagePort.{s} is not implemented by the GTK adapter\n", .{field.name});
                return error.TestUnexpectedResult;
            }
        }
    }
}
