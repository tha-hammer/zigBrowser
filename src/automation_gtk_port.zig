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
    .nativeClick = nativeClick,
    .nativeKey = nativeKey,
    .nativeText = nativeText,
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

    fn isDocument(self: Ack, token: []const u8) bool {
        return std.mem.eql(u8, &self.doc, token);
    }
};

/// Counts the page still owes for earlier calls that gave up (per document).
var debt: ?Ack = null;
var debt_mutex: SpinLock = .{};

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
fn readAck(deadline: i64) PortError!?Ack {
    const gpa = std.heap.c_allocator;
    const out = try evalJson(&port_tag, gpa, .automation, ack_body, "null", try remainingMs(deadline));
    defer gpa.free(out);
    if (std.mem.eql(u8, out, "null")) return null;
    const Wire = struct { doc: []const u8, mouseup: i64, keyup: i64, click: i64 };
    const parsed = std.json.parseFromSlice(Wire, gpa, out, .{}) catch return error.EvalFailed;
    defer parsed.deinit();
    if (!isDocumentToken(parsed.value.doc)) return error.EvalFailed;
    var ack: Ack = .{ .keyup = parsed.value.keyup, .click = parsed.value.click };
    @memcpy(&ack.doc, parsed.value.doc);
    return ack;
}

fn readBaseline(deadline: i64) PortError!Ack {
    while (true) {
        if (try readAck(deadline)) |ack| return ack;
        sleepMs(@min(5, try remainingMs(deadline)));
    }
}

const AckOutcome = enum { acknowledged, document_changed };

/// Wait until the page reached `target`'s counts, or a different document
/// replaced it.
fn waitAck(target: Ack, deadline: i64) PortError!AckOutcome {
    while (true) {
        if (try readAck(deadline)) |now| {
            if (!now.isDocument(&target.doc)) return .document_changed;
            if (now.click >= target.click and now.keyup >= target.keyup) return .acknowledged;
        }
        sleepMs(@min(5, try remainingMs(deadline)));
    }
}

/// Before sending anything new: wait out what earlier calls still owe.
/// A Timeout here means no new input was sent.
fn drainDebt(deadline: i64) PortError!void {
    debt_mutex.lock();
    const owed = debt;
    debt_mutex.unlock();
    const target = owed orelse return;
    _ = try waitAck(target, deadline);
    debt_mutex.lock();
    if (debt) |current| {
        if (std.mem.eql(u8, &current.doc, &target.doc) and current.click <= target.click and current.keyup <= target.keyup) debt = null;
    }
    debt_mutex.unlock();
}

fn addDebt(target: Ack) void {
    debt_mutex.lock();
    defer debt_mutex.unlock();
    if (debt) |current| {
        if (std.mem.eql(u8, &current.doc, &target.doc)) {
            debt = .{ .doc = target.doc, .click = @max(current.click, target.click), .keyup = @max(current.keyup, target.keyup) };
            return;
        }
    }
    debt = target;
}

/// Called right after a successful dispatch: the counts are owed from now on
/// and stay owed through any failure (Timeout, a failed read, a cancel),
/// since the events still reach the page. Only an acknowledgement or a
/// document change settles them.
fn settle(target: Ack, deadline: i64) PortError!AckOutcome {
    addDebt(target);
    const outcome = try waitAck(target, deadline);
    debt_mutex.lock();
    debt = null; // transactions are serialized: the debt was this target's
    debt_mutex.unlock();
    return outcome;
}

fn mapNativeCode(rc: c_int) PortError!void {
    if (rc == c.ZB_AUTO_ERR_DOC_CHANGED) return error.DocumentChanged;
    return mapCode(rc);
}

/// Common start: no NUL, drained debt, baseline in the expected document.
fn begin(document: ?[]const u8, deadline: i64) PortError!Ack {
    if (document) |token| {
        if (std.mem.indexOfScalar(u8, token, 0) != null or !isDocumentToken(token)) return error.EvalFailed;
    }
    try drainDebt(deadline);
    const base = try readBaseline(deadline);
    if (document) |token| if (!base.isDocument(token)) return error.DocumentChanged;
    return base;
}

/// Real pointer motion + left click at viewport CSS px (x, y). Returns once
/// the page's click dispatch has finished, or the click navigated.
pub fn nativeClick(_: *anyopaque, x: f64, y: f64, document: ?[]const u8, timeout_ms: u64) PortError!void {
    const deadline = deadlineAfter(timeout_ms);
    try txn_lock.lockUntil(deadline);
    defer txn_lock.unlock();
    const base = try begin(document, deadline);
    var doc_z: [doc_len + 1]u8 = undefined;
    const expected = if (document) |token| docZ(&doc_z, token) else null;
    var err: [*c]u8 = null;
    const rc = c.zb_native_click(null, x, y, 1, expected, clampMs(try remainingMs(deadline)), &err);
    c.zb_automation_free(err);
    try mapNativeCode(rc);
    _ = try settle(.{ .doc = base.doc, .click = base.click + 1, .keyup = base.keyup }, deadline);
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
    const base = try begin(document, deadline);
    var doc_z: [doc_len + 1]u8 = undefined;
    const expected = if (document) |token| docZ(&doc_z, token) else null;
    var releases: c_int = 0;
    var err: [*c]u8 = null;
    const rc = c.zb_native_key(null, key_z.ptr, @intCast(modifiers & 0x0f), expected, clampMs(try remainingMs(deadline)), &releases, &err);
    c.zb_automation_free(err);
    try mapNativeCode(rc);
    _ = try settle(.{ .doc = base.doc, .click = base.click, .keyup = base.keyup + releases }, deadline);
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
    var acked = try begin(document, deadline);
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
        if (try settle(acked, deadline) == .document_changed) return error.DocumentChanged;
    }
}

fn docZ(buf: *[doc_len + 1]u8, token: []const u8) [*:0]const u8 {
    @memcpy(buf[0..doc_len], token[0..doc_len]);
    buf[doc_len] = 0;
    return @ptrCast(buf);
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
