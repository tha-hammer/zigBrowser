const std = @import("std");
const builtin = @import("builtin");

pub const c = @cImport({
    @cInclude("webkit_shim.h");
});

pub fn versionLine(buffer: []u8) []const u8 {
    if (buffer.len == 0) return "";
    c.zb_version_line(buffer.ptr, buffer.len);
    return std.mem.sliceTo(buffer, 0);
}

pub fn runOpen(uri_z: [:0]const u8, print_title: bool) i32 {
    return c.zb_run_open(uri_z.ptr, if (print_title) 1 else 0);
}

pub fn runScreenshot(uri_z: [:0]const u8, out_z: [:0]const u8, print_title: bool) i32 {
    return c.zb_run_screenshot(uri_z.ptr, out_z.ptr, if (print_title) 1 else 0);
}

// --- Main-thread hand-off tests (GTK backend only) ---
//
// The test thread plays the GTK main thread: it owns the default GMainContext
// and pumps it, while spawned threads act as the automation server thread.

const glib = struct {
    const GMainContext = opaque {};
    extern fn g_main_context_default() *GMainContext;
    extern fn g_main_context_acquire(context: *GMainContext) c_int;
    extern fn g_main_context_release(context: *GMainContext) void;
    extern fn g_main_context_iteration(context: ?*GMainContext, may_block: c_int) c_int;
};

const TestLoop = struct {
    fn acquire() void {
        std.debug.assert(glib.g_main_context_acquire(glib.g_main_context_default()) != 0);
        c.zb_automation_loop_mark(1);
    }

    fn release() void {
        glib.g_main_context_release(glib.g_main_context_default());
    }

    /// Pump the default context until `done` is set or `max_ms` elapses.
    fn pumpUntil(done: *const std.atomic.Value(bool), max_ms: u64) void {
        var waited: u64 = 0;
        while (!done.load(.acquire) and waited < max_ms) : (waited += 1) {
            while (glib.g_main_context_iteration(null, 0) != 0) {}
            sleepMs(1);
        }
        while (glib.g_main_context_iteration(null, 0) != 0) {}
    }

    fn pumpFor(ms: u64) void {
        var waited: u64 = 0;
        while (waited < ms) : (waited += 1) {
            while (glib.g_main_context_iteration(null, 0) != 0) {}
            sleepMs(1);
        }
    }
};

fn wallUs() i64 {
    return gfile.g_get_real_time();
}

fn monotonicMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), std.time.ns_per_ms);
}

fn sleepMs(ms: u64) void {
    var ts: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, &ts);
}

const CountingJob = struct {
    runs: std.atomic.Value(u32) = .{ .raw = 0 },
    ran_on: std.atomic.Value(std.Thread.Id) = .{ .raw = 0 },

    fn run(ctx: ?*anyopaque) callconv(.c) void {
        const self: *CountingJob = @ptrCast(@alignCast(ctx.?));
        self.ran_on.store(std.Thread.getCurrentId(), .release);
        _ = self.runs.fetchAdd(1, .acq_rel);
    }
};

const Submitter = struct {
    job: *CountingJob,
    timeout_ms: c_uint,
    repeat: u32 = 1,
    rc: std.atomic.Value(c_int) = .{ .raw = -1 },
    failures: std.atomic.Value(u32) = .{ .raw = 0 },
    done: std.atomic.Value(bool) = .{ .raw = false },

    fn main(self: *Submitter) void {
        var i: u32 = 0;
        while (i < self.repeat) : (i += 1) {
            const rc = c.zb_main_invoke_sync(CountingJob.run, self.job, self.timeout_ms);
            self.rc.store(rc, .release);
            if (rc != c.ZB_AUTO_OK) _ = self.failures.fetchAdd(1, .acq_rel);
        }
        self.done.store(true, .release);
    }
};

fn skipUnlessGtk() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
}

test "zb_main_invoke_sync runs the job on the loop-owning thread and blocks until it returns" {
    try skipUnlessGtk();
    TestLoop.acquire();
    defer TestLoop.release();

    var job: CountingJob = .{};
    var sub: Submitter = .{ .job = &job, .timeout_ms = 2000 };
    const t = try std.Thread.spawn(.{}, Submitter.main, .{&sub});
    TestLoop.pumpUntil(&sub.done, 3000);
    t.join();

    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_OK), sub.rc.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), job.runs.load(.acquire));
    try std.testing.expectEqual(std.Thread.getCurrentId(), job.ran_on.load(.acquire));
}

test "zb_main_invoke_sync times out and never runs the job when the loop is not pumped" {
    try skipUnlessGtk();
    TestLoop.acquire();
    defer TestLoop.release();

    var job: CountingJob = .{};
    var sub: Submitter = .{ .job = &job, .timeout_ms = 50 };
    const t = try std.Thread.spawn(.{}, Submitter.main, .{&sub});
    t.join();
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_ERR_TIMEOUT), sub.rc.load(.acquire));

    // The queued source may still be dispatched now; it must not touch the job.
    TestLoop.pumpFor(20);
    try std.testing.expectEqual(@as(u32, 0), job.runs.load(.acquire));
    try std.testing.expectEqual(@as(c_int, 0), c.zb_automation_debug_live_jobs());
}

test "zb_main_invoke_sync on the loop-owning thread runs inline instead of deadlocking" {
    try skipUnlessGtk();
    TestLoop.acquire();
    defer TestLoop.release();

    var job: CountingJob = .{};
    const rc = c.zb_main_invoke_sync(CountingJob.run, &job, 1000);
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_OK), rc);
    try std.testing.expectEqual(@as(u32, 1), job.runs.load(.acquire));
}

test "zb_main_invoke_sync completes every job exactly once across concurrent submitters" {
    try skipUnlessGtk();
    TestLoop.acquire();
    defer TestLoop.release();

    const n_threads = 8;
    const per_thread = 25;
    var job: CountingJob = .{};
    var subs: [n_threads]Submitter = undefined;
    var threads: [n_threads]std.Thread = undefined;
    for (&subs, &threads) |*sub, *t| {
        sub.* = .{ .job = &job, .timeout_ms = 5000, .repeat = per_thread };
        t.* = try std.Thread.spawn(.{}, Submitter.main, .{sub});
    }

    var all_done: std.atomic.Value(bool) = .{ .raw = false };
    var waited: u64 = 0;
    while (!all_done.load(.acquire) and waited < 10_000) : (waited += 1) {
        while (glib.g_main_context_iteration(null, 0) != 0) {}
        var done = true;
        for (&subs) |*sub| done = done and sub.done.load(.acquire);
        all_done.store(done, .release);
        sleepMs(1);
    }
    for (threads) |t| t.join();

    for (&subs) |*sub| try std.testing.expectEqual(@as(u32, 0), sub.failures.load(.acquire));
    try std.testing.expectEqual(@as(u32, n_threads * per_thread), job.runs.load(.acquire));
}

test "zb_main_invoke_sync wakes pending waiters with NO_LOOP once the loop has ended" {
    try skipUnlessGtk();
    TestLoop.acquire();
    defer TestLoop.release();

    var job: CountingJob = .{};
    var sub: Submitter = .{ .job = &job, .timeout_ms = 10_000 };
    const t = try std.Thread.spawn(.{}, Submitter.main, .{&sub});
    sleepMs(30);

    const start = monotonicMs();
    c.zb_automation_loop_mark(0);
    t.join();
    const elapsed_ms = monotonicMs() - start;

    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_ERR_NO_LOOP), sub.rc.load(.acquire));
    try std.testing.expect(elapsed_ms < 2000);

    // Ending the loop destroyed the queued source, releasing its job ref
    // without any further dispatch.
    try std.testing.expectEqual(@as(c_int, 0), c.zb_automation_debug_live_jobs());

    // After the loop has ended, new submissions fail fast too.
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_ERR_NO_LOOP), c.zb_main_invoke_sync(CountingJob.run, &job, 10_000));
    TestLoop.pumpFor(10);
    try std.testing.expectEqual(@as(u32, 0), job.runs.load(.acquire));
    c.zb_automation_loop_mark(1);
}

test "a waiter queued before zb_app_run is released when GTK init fails" {
    try skipUnlessGtk();
    c.zb_automation_loop_mark(1);

    var job: CountingJob = .{};
    var sub: Submitter = .{ .job = &job, .timeout_ms = 30_000 };
    const t = try std.Thread.spawn(.{}, Submitter.main, .{&sub});
    sleepMs(30);

    // With an empty DISPLAY, zb_app_run fails before gtk_main(). The value is
    // overwritten rather than unset: unsetenv shifts libc's environ array in
    // place, which breaks Zig's own environment scan later in the process.
    const saved = std.c.getenv("DISPLAY");
    var saved_buf: [256]u8 = undefined;
    const saved_copy: [:0]const u8 = if (saved) |d| try std.fmt.bufPrintZ(&saved_buf, "{s}", .{std.mem.span(d)}) else "";
    // Capture the shim's stderr so the expected message neither leaks into the
    // gate log (where it reads like a failure) nor goes unchecked. Capture
    // starts before DISPLAY is touched, and both are restored on every path.
    var captured = try StderrCapture.begin();
    var message_buf: [512]u8 = undefined;
    var message: []const u8 = "";
    var capture_open = true;
    defer if (capture_open) {
        _ = captured.end(&message_buf);
    };
    try std.testing.expectEqual(@as(c_int, 0), setenv("DISPLAY", "", 1));
    defer std.debug.assert(setenv("DISPLAY", saved_copy.ptr, 1) == 0);
    const start = monotonicMs();
    const rc = c.zb_app_run("about:blank", 0, 0);
    message = captured.end(&message_buf);
    capture_open = false;
    try std.testing.expect(std.mem.indexOf(u8, message, "DISPLAY is required") != null);

    t.join();
    try std.testing.expectEqual(@as(c_int, c.ZB_EXIT_DISPLAY_UNAVAILABLE), rc);
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_ERR_NO_LOOP), sub.rc.load(.acquire));
    try std.testing.expect(monotonicMs() - start < 2000);
    try std.testing.expectEqual(@as(u32, 0), job.runs.load(.acquire));
    try std.testing.expectEqual(@as(c_int, 0), c.zb_automation_debug_live_jobs());
    c.zb_automation_loop_mark(1);
}

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn dup(fd: c_int) c_int;
extern fn dup2(old: c_int, new: c_int) c_int;

/// Redirects fd 2 into a pipe until `end`, which restores it and returns
/// what was written (up to the buffer size; the message here is one line).
const StderrCapture = struct {
    saved: c_int,
    read_fd: c_int,

    fn begin() !StderrCapture {
        var fds: [2]c_int = undefined;
        if (std.c.pipe(&fds) != 0) return error.PipeFailed;
        errdefer _ = std.c.close(fds[0]);
        defer _ = std.c.close(fds[1]);
        const saved = dup(2);
        if (saved < 0) return error.DupFailed;
        errdefer _ = std.c.close(saved);
        if (dup2(fds[1], 2) < 0) return error.DupFailed;
        return .{ .saved = saved, .read_fd = fds[0] };
    }

    fn end(self: *StderrCapture, buf: []u8) []const u8 {
        _ = dup2(self.saved, 2);
        _ = std.c.close(self.saved);
        var len: usize = 0;
        while (len < buf.len) {
            const n = std.c.read(self.read_fd, buf[len..].ptr, buf.len - len);
            if (n <= 0) break;
            len += @intCast(n);
        }
        _ = std.c.close(self.read_fd);
        return buf[0..len];
    }
};

// --- Live WebView bridge test (needs a display; run under xvfb-run) ---
//
// The test thread runs zb_app_run (the GTK main loop) on a file:// fixture;
// a driver thread plays the automation server and exercises every op.

const gtk_port = @import("automation_gtk_port.zig");
const page_port_mod = @import("automation/page_port.zig");

test {
    _ = gtk_port;
    _ = @import("automation_gtk_cookie_port.zig");
    _ = @import("app.zig");
}

const gfile = struct {
    extern fn g_dir_make_tmp(tmpl: ?[*:0]const u8, err: ?*?*anyopaque) ?[*:0]u8;
    extern fn g_file_set_contents(filename: [*:0]const u8, contents: [*]const u8, length: isize, err: ?*?*anyopaque) c_int;
    extern fn g_filename_to_uri(filename: [*:0]const u8, hostname: ?[*:0]const u8, err: ?*?*anyopaque) ?[*:0]u8;
    extern fn g_free(mem: ?*anyopaque) void;
    extern fn gtk_main_quit() void;
    extern fn g_get_real_time() i64;
};

const fixture_a =
    \\<!doctype html><html><head><title>Fixture A</title></head><body>
    \\<p id="msg">Hello fixture</p>
    \\<button id="nb" style="position:fixed;left:20px;top:120px;width:120px;height:40px">Native</button>
    \\<input id="ni" style="position:fixed;left:20px;top:180px;width:200px;height:30px">
    \\<script>window.nativeLog = [];
    \\['mousedown', 'mouseup', 'click'].forEach(function (t) {
    \\  document.getElementById('nb').addEventListener(t, function (e) { nativeLog.push(t + ':' + e.isTrusted); }); });
    \\document.getElementById('ni').addEventListener('keydown', function (e) {
    \\  nativeLog.push('keydown:' + e.key + ':' + e.isTrusted + ':' + e.shiftKey); });
    \\window.lastTrustedClick = 0; window.lastTrustedKeyUp = 0;
    \\function nowUs() { return Math.round((performance.timeOrigin + performance.now()) * 1000); }
    \\document.addEventListener('click', function (e) { if (e.isTrusted) window.lastTrustedClick = nowUs(); });
    \\document.addEventListener('keyup', function (e) { if (e.isTrusted) window.lastTrustedKeyUp = nowUs(); });
    \\window.keyupAt = {}; document.addEventListener('keyup', function (e) { if (e.isTrusted) window.keyupAt[e.key] = nowUs(); });
    \\window.moves = []; document.addEventListener('mousemove', function (e) { window.moves.push([e.clientX, e.clientY, e.isTrusted]); });</script>
    \\<button id="hold" style="position:fixed;left:300px;top:120px;width:120px;height:40px">Hold</button>
    \\<script>window.holdDone = 0; document.getElementById('hold').addEventListener('click', function (e) {
    \\  var until = performance.now() + 40; while (performance.now() < until) {}
    \\  window.holdDone = Math.round((performance.timeOrigin + performance.now()) * 1000); });</script>
    \\<a id="navlink" href="b.html" style="position:fixed;left:20px;top:240px;width:120px;height:30px;display:block">to B</a>
    \\<form action="b.html"><input id="navq" name="q" style="position:fixed;left:20px;top:290px;width:200px;height:30px"></form>
    \\<script>window.pageMarker = 7; setTimeout(function () {
    \\  var p = document.createElement('p'); p.id = 'late'; p.textContent = 'late';
    \\  document.body.appendChild(p); }, 300);</script>
    \\</body></html>
;
fn fixtureSlow(buf: []u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf,
        \\<!doctype html><html><head><title>Fixture Slow</title></head><body>
        \\<img src="http://127.0.0.1:{d}/never.png"></body></html>
    , .{port}) catch unreachable;
}

/// TCP listener that never accepts: connections complete in the kernel
/// backlog and requests never get a response, so loads that need it stall.
const StalledServer = struct {
    fd: c_int,
    port: u16,

    fn open() !StalledServer {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        var addr: std.c.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.in)) != 0) return error.BindFailed;
        if (std.c.listen(fd, 16) != 0) return error.ListenFailed;
        var len: std.c.socklen_t = @sizeOf(std.c.sockaddr.in);
        if (std.c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.SockNameFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
    }

    fn close(self: StalledServer) void {
        _ = std.c.close(self.fd);
    }
};

/// HTTP server for one request: accepts, holds the response for `hold_ms`,
/// then answers 200 with an empty body. `responded_ms` records when the
/// response went out (monotonic ms), so a test can order events around it.
const DelayServer = struct {
    fd: c_int,
    port: u16,
    hold_ms: u64,
    responded_ms: std.atomic.Value(i64) = .{ .raw = 0 },
    thread: ?std.Thread = null,

    fn open(hold_ms: u64) !DelayServer {
        const stalled = try StalledServer.open();
        return .{ .fd = stalled.fd, .port = stalled.port, .hold_ms = hold_ms };
    }

    fn start(self: *DelayServer) !void {
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn serve(self: *DelayServer) void {
        const conn = std.c.accept(self.fd, null, null);
        if (conn < 0) return;
        defer _ = std.c.close(conn);
        var req: [2048]u8 = undefined;
        _ = std.c.read(conn, &req, req.len);
        sleepMs(self.hold_ms);
        const reply = "HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        self.responded_ms.store(monotonicMs(), .release);
        _ = std.c.write(conn, reply.ptr, reply.len);
    }

    fn close(self: *DelayServer) void {
        _ = std.c.shutdown(self.fd, 2);
        _ = std.c.close(self.fd);
        if (self.thread) |t| t.join();
    }
};

fn fixtureDelay(buf: []u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf,
        \\<!doctype html><html><head><title>Fixture Delay</title></head><body>
        \\<p id="msg">Delayed child</p><img src="http://127.0.0.1:{d}/hold.gif"></body></html>
    , .{port}) catch unreachable;
}

const fixture_b =
    \\<!doctype html><html><head><title>Fixture B</title></head><body><p id="msg">Page B</p>
    \\<button id="danger" style="position:fixed;left:20px;top:120px;width:120px;height:40px" onclick="window.dangerClicked = (window.dangerClicked || 0) + 1">Danger</button>
    \\<script>window.bKeys = []; document.addEventListener('keydown', function (e) { window.bKeys.push(e.key); }, true);
    \\window.bMoves = []; document.addEventListener('mousemove', function (e) { window.bMoves.push([e.clientX, e.clientY]); }, true);</script>
    \\</body></html>
;

const LiveDriver = struct {
    allocator: std.mem.Allocator,
    uri_a: [:0]const u8,
    uri_b: [:0]const u8,
    uri_missing: [:0]const u8,
    uri_slow: [:0]const u8,
    uri_delay: [:0]const u8 = "",
    delay_server: ?*DelayServer = null,
    pending_eval: ?std.Thread = null,
    pending_eval_rc: std.atomic.Value(c_int) = .{ .raw = -1 },
    pending_cookie: ?std.Thread = null,
    pending_cookie_rc: std.atomic.Value(c_int) = .{ .raw = -1 },
    failures: std.ArrayList([]const u8) = .empty,

    fn diag(_: *LiveDriver, what: []const u8, rc: c_int, err: [*c]u8) void {
        if (rc != c.ZB_AUTO_OK) std.debug.print("live bridge {s}: rc={d} err={s}\n", .{ what, rc, if (err != null) std.mem.span(err) else "" });
    }

    fn check(self: *LiveDriver, ok: bool, comptime what: []const u8) void {
        if (!ok) self.failures.append(self.allocator, what) catch {};
    }

    const Eval = struct { rc: c_int, out: ?[]const u8, err: ?[]const u8 };

    fn eval(self: *LiveDriver, win: ?*c.ZbWindow, body: [:0]const u8, arg: ?[:0]const u8, world: ?[:0]const u8, timeout_ms: c_uint) Eval {
        var out: [*c]u8 = null;
        var err: [*c]u8 = null;
        const rc = c.zb_automation_eval_json(win, body.ptr, if (arg) |a| a.ptr else null, if (world) |w| w.ptr else null, timeout_ms, &out, &err);
        defer c.zb_automation_free(out);
        defer c.zb_automation_free(err);
        return .{
            .rc = rc,
            .out = if (out != null) self.allocator.dupe(u8, std.mem.span(out)) catch null else null,
            .err = if (err != null) self.allocator.dupe(u8, std.mem.span(err)) catch null else null,
        };
    }

    fn str(self: *LiveDriver, rc_out: *c_int, comptime which: enum { url, title }) []const u8 {
        var out: [*c]u8 = null;
        rc_out.* = switch (which) {
            .url => c.zb_automation_get_url(null, 5000, &out),
            .title => c.zb_automation_get_title(null, 5000, &out),
        };
        defer c.zb_automation_free(out);
        if (out == null) return "";
        return self.allocator.dupe(u8, std.mem.span(out)) catch "";
    }

    fn eq(a: ?[]const u8, b: []const u8) bool {
        return a != null and std.mem.eql(u8, a.?, b);
    }

    const handle_body = "return JSON.stringify(await globalThis.__zbAutomation.handle(JSON.parse(arg)));";

    fn pendingEval(self: *LiveDriver) void {
        var out: [*c]u8 = null;
        var err: [*c]u8 = null;
        const rc = c.zb_automation_eval_json(null, "await new Promise(function (resolve) { globalThis.__zbHold2 = resolve; });", null, null, 30_000, &out, &err);
        c.zb_automation_free(out);
        c.zb_automation_free(err);
        self.pending_eval_rc.store(rc, .release);
    }

    fn pendingCookie(self: *LiveDriver) void {
        var out: [*c]u8 = null;
        var err: [*c]u8 = null;
        const rc = c.zb_cookies_get_all(null, null, 30_000, &out, &err);
        c.zb_automation_free(out);
        c.zb_automation_free(err);
        self.pending_cookie_rc.store(rc, .release);
    }

    fn quit(_: ?*anyopaque) callconv(.c) void {
        gfile.gtk_main_quit();
    }

    fn run(self: *LiveDriver) void {
        const automation_world: [:0]const u8 = c.ZB_AUTOMATION_WORLD;
        var rc: c_int = 0;
        var err: [*c]u8 = null;

        // Startup readiness: the driver starts before zb_app_run, so this
        // title request arrives while the start page is still loading. It
        // must wait for that load instead of reading the empty initial page.
        self.check(std.mem.eql(u8, self.str(&rc, .title), "Fixture A"), "page.title during startup waits for the first load");

        // NULL window waits for the primary window (driver starts before zb_app_run).
        rc = c.zb_automation_navigate(null, self.uri_a.ptr, 15000, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK, "navigate to fixture A returns OK");
        self.check(c.zb_automation_main_window() != null, "primary window is registered");

        self.check(std.mem.eql(u8, self.str(&rc, .url), self.uri_a), "page.url is fixture A");
        self.check(std.mem.eql(u8, self.str(&rc, .title), "Fixture A"), "page.title is Fixture A");

        // B: script lives in the isolated world only.
        var r = self.eval(null, "return typeof globalThis.__zbAutomation;", null, automation_world, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and eq(r.out, "object"), "__zbAutomation installed in automation world");
        r = self.eval(null, "return typeof window.__zbAutomation + ':' + window.pageMarker;", null, null, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and eq(r.out, "undefined:7"), "page world sees page globals but not __zbAutomation");

        // C: real command through handle(), argument passed as data.
        r = self.eval(null, handle_body, "{\"op\":\"getText\",\"selector\":\"css=#msg\"}", automation_world, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and r.out != null and std.mem.indexOf(u8, r.out.?, "\"text\":\"Hello fixture\"") != null, "getText returns live fixture text");

        r = self.eval(null, handle_body, "{\"op\":\"waitFor\",\"selector\":\"css=#late\",\"state\":\"attached\",\"timeout_ms\":5000}", automation_world, 8000);
        self.check(r.rc == c.ZB_AUTO_OK and r.out != null and std.mem.indexOf(u8, r.out.?, "\"ok\":true") != null, "waitFor promise resolves before return");

        const tricky = "q\"uote \\ back\nline \u{2028} sep";
        r = self.eval(null, "return arg;", tricky, automation_world, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and eq(r.out, tricky), "arg reaches JS verbatim as data");

        r = self.eval(null, "return 6 * 7;", null, null, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and eq(r.out, "42"), "non-string result is JSON encoded");
        r = self.eval(null, "return undefined;", null, null, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and eq(r.out, "null"), "undefined result is null");
        r = self.eval(null, "return arg;", null, null, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and eq(r.out, "null"), "NULL arg_json binds the string null");

        r = self.eval(null, "throw new Error('boom');", null, null, 5000);
        self.check(r.rc == c.ZB_AUTO_ERR_JS and r.err != null and std.mem.indexOf(u8, r.err.?, "boom") != null, "JS exception maps to ZB_AUTO_ERR_JS");

        // The resolver is kept reachable: an unreferenced pending promise can be
        // garbage-collected, and WebKit then fails the call early.
        r = self.eval(null, "await new Promise(function (resolve) { globalThis.__zbHold1 = resolve; });", null, null, 150);
        self.check(r.rc == c.ZB_AUTO_ERR_TIMEOUT, "never-settling promise times out");
        r = self.eval(null, "return 'alive';", null, null, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and eq(r.out, "alive"), "eval still works after a timeout");

        // D: explicit window pointer, and a bogus one.
        r = self.eval(c.zb_automation_main_window(), "return 'explicit';", null, null, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and eq(r.out, "explicit"), "explicit primary window pointer works");
        var bogus: u8 = 0;
        r = self.eval(@ptrCast(&bogus), "return 1;", null, null, 2000);
        self.check(r.rc == c.ZB_AUTO_ERR_NO_WINDOW, "unknown window pointer is NO_WINDOW");

        // Navigation, failures, reload.
        rc = c.zb_automation_navigate(null, self.uri_b.ptr, 15000, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK, "navigate to fixture B returns OK");
        self.check(std.mem.eql(u8, self.str(&rc, .title), "Fixture B"), "title follows navigation");
        r = self.eval(null, handle_body, "{\"op\":\"getText\",\"selector\":\"css=#msg\"}", automation_world, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and r.out != null and std.mem.indexOf(u8, r.out.?, "Page B") != null, "script re-injected after navigation");

        rc = c.zb_automation_navigate(null, self.uri_missing.ptr, 15000, &err);
        self.check(rc == c.ZB_AUTO_ERR_NAV_FAILED and err != null, "missing file is NAV_FAILED with message");
        c.zb_automation_free(err);
        err = null;

        rc = c.zb_automation_navigate(null, "file:///etc/hostname", 5000, &err);
        self.check(rc == c.ZB_AUTO_ERR_NAV_FAILED, "policy-blocked navigation is NAV_FAILED");
        c.zb_automation_free(err);
        err = null;

        // The PagePort adapter over the same ABI (what the server uses).
        const port = gtk_port.pagePort().?;
        const gpa = self.allocator;
        const handle_cmd = "{\"op\":\"getText\",\"selector\":\"css=#msg\"}";
        const port_text = port.evalJson(gpa, .automation, handle_body, handle_cmd, 5000) catch null;
        self.check(port_text != null and std.mem.indexOf(u8, port_text.?, "Page B") != null, "PagePort.evalJson returns live text");
        const port_page = port.evalJson(gpa, .page, "return typeof window.__zbAutomation;", "null", 5000) catch null;
        self.check(eq(port_page, "undefined"), "PagePort .page world is the page world");
        self.check(if (port.evalJson(gpa, .page, "throw new Error('x');", "null", 5000)) |_| false else |e| e == error.EvalFailed, "PagePort maps JS failure to EvalFailed");
        self.check(if (port.evalJson(gpa, .page, "await new Promise(function () {});", "null", 100)) |_| false else |e| e == error.Timeout, "PagePort maps timeout to Timeout");
        self.check(if (port.navigate(self.uri_missing, 15000)) |_| false else |e| e == error.NavigationFailed, "PagePort maps load failure to NavigationFailed");
        const port_url = port.url(gpa, 5000) catch null;
        self.check(port_url != null, "PagePort.url answers");
        const port_title = port.title(gpa, 5000) catch null;
        self.check(port_title != null, "PagePort.title answers");

        rc = c.zb_automation_navigate(null, self.uri_a.ptr, 15000, &err);
        self.diag("navigate back to A", rc, err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK, "navigate back to fixture A returns OK");
        rc = c.zb_automation_reload(null, 15000, &err);
        self.diag("reload", rc, err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK, "reload returns OK");
        self.check(std.mem.eql(u8, self.str(&rc, .title), "Fixture A"), "title after reload");

        // Fragment-only navigation fires no load events; the URI change completes it.
        const uri_frag = std.fmt.allocPrintSentinel(self.allocator, "{s}#frag", .{self.uri_a}, 0) catch return;
        rc = c.zb_automation_navigate(null, uri_frag.ptr, 5000, &err);
        self.diag("hash navigate", rc, err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK, "same-document hash navigation returns OK");
        self.check(std.mem.eql(u8, self.str(&rc, .url), uri_frag), "url carries the fragment");

        // WebKit canonicalizes the scheme; the job must still match its load.
        const uri_upper = std.fmt.allocPrintSentinel(self.allocator, "FILE{s}", .{self.uri_b["file".len..]}, 0) catch return;
        rc = c.zb_automation_navigate(null, uri_upper.ptr, 15000, &err);
        self.diag("upper-case scheme navigate", rc, err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK, "navigate with non-canonical scheme returns OK");

        // A load that cannot finish: the navigate times out, the shim stops
        // that load, and the next navigate still works.
        rc = c.zb_automation_navigate(null, self.uri_slow.ptr, 500, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_ERR_TIMEOUT, "stalled load times out");
        sleepMs(200);
        r = self.eval(null, "return String(document.readyState);", null, null, 5000);
        self.check(r.rc == c.ZB_AUTO_OK and r.out != null and !std.mem.eql(u8, r.out.?, "loading"), "timed-out load was stopped");
        rc = c.zb_automation_navigate(null, self.uri_a.ptr, 15000, &err);
        self.diag("navigate after stalled load", rc, err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK, "navigate after a timed-out load returns OK");

        self.runCookies();
        self.runNative();
        self.runNativePort();
        self.runChildWindow();

        // Loop end with work in flight: an eval that never settles is still
        // pending when the loop quits; its waiter gets NO_LOOP and the job is
        // released by teardown (checked after zb_app_run returns).
        self.pending_eval = std.Thread.spawn(.{}, pendingEval, .{self}) catch null;
        // ...and a cookie op held in flight (RUNNING) by the test hook.
        c.zb_automation_debug_cookie_delay(60_000);
        const cookie_hits = c.zb_automation_debug_cookie_delay_hits();
        self.pending_cookie = std.Thread.spawn(.{}, pendingCookie, .{self}) catch null;
        var held_wait: u32 = 0;
        while (c.zb_automation_debug_cookie_delay_hits() == cookie_hits and held_wait < 3000) : (held_wait += 5) sleepMs(5);
        self.check(c.zb_automation_debug_cookie_delay_hits() == cookie_hits + 1, "a cookie op is held in flight at loop end");
        c.zb_automation_debug_cookie_delay(0);
        sleepMs(200);
        _ = c.zb_main_invoke_sync(quit, null, 5000);
    }

    fn cookiesJson(self: *LiveDriver, url: ?[*:0]const u8) ?[]const u8 {
        var out: [*c]u8 = null;
        var err: [*c]u8 = null;
        const rc = c.zb_cookies_get_all(null, url, 5000, &out, &err);
        defer c.zb_automation_free(out);
        defer c.zb_automation_free(err);
        if (rc != c.ZB_AUTO_OK or out == null) return null;
        return self.allocator.dupe(u8, std.mem.span(out)) catch null;
    }

    const CookieOut = struct {
        name: []const u8,
        value: []const u8,
        domain: []const u8,
        path: []const u8,
        expires: i64,
        httpOnly: bool,
        secure: bool,
        sameSite: []const u8,
    };

    /// The store's cookies parsed from the shim's JSON (null on failure).
    fn cookies(self: *LiveDriver, url: ?[*:0]const u8) ?[]const CookieOut {
        const json = self.cookiesJson(url) orelse return null;
        const parsed = std.json.parseFromSliceLeaky([]const CookieOut, self.allocator, json, .{}) catch return null;
        return parsed;
    }

    fn find(list: ?[]const CookieOut, name: []const u8) ?CookieOut {
        for (list orelse return null) |cookie| {
            if (std.mem.eql(u8, cookie.name, name)) return cookie;
        }
        return null;
    }

    fn addCookie(self: *LiveDriver, cookie: c.ZbCookie, comptime what: []const u8) void {
        var err: [*c]u8 = null;
        const rc = c.zb_cookies_add(null, &cookie, 5000, &err);
        c.zb_automation_free(err);
        self.check(rc == c.ZB_AUTO_OK, what);
    }

    fn deleteCookie(_: *LiveDriver, name: [*:0]const u8, domain: ?[*:0]const u8) c_int {
        var err: [*c]u8 = null;
        const rc = c.zb_cookies_delete(null, name, domain, 5000, &err);
        c.zb_automation_free(err);
        return rc;
    }

    fn center(self: *LiveDriver, id: []const u8) ?[2]f64 {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrintZ(&buf, "const r = document.getElementById('{s}').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2];", .{id}) catch return null;
        const r = self.eval(null, body, null, null, 5000);
        const out = r.out orelse return null;
        const xy = std.json.parseFromSliceLeaky([2]f64, self.allocator, out, .{}) catch return null;
        return xy;
    }

    fn nativeLog(self: *LiveDriver) []const u8 {
        const r = self.eval(null, "return nativeLog.join(',');", null, null, 5000);
        return r.out orelse "";
    }

    /// Native events reach the page asynchronously: wait (up to 3 s) until
    /// the automation world has acknowledged `mouseups` / `keyups` more events.
    fn waitInputAck(self: *LiveDriver, base: [2]i64, mouseups: i64, keyups: i64) bool {
        return self.waitInputAckFor(base, mouseups, keyups, 3000);
    }

    /// Draining a backlog of hundreds of queued keys can take seconds.
    fn waitInputAckFor(self: *LiveDriver, base: [2]i64, mouseups: i64, keyups: i64, limit_ms: u32) bool {
        var waited: u32 = 0;
        while (waited < limit_ms) : (waited += 10) {
            const now = self.inputAck() orelse return false;
            if (now[0] >= base[0] + mouseups and now[1] >= base[1] + keyups) return true;
            sleepMs(10);
        }
        return false;
    }

    fn inputAck(self: *LiveDriver) ?[2]i64 {
        const r = self.eval(null, "const a = globalThis.__zbAutomation.inputAck(); return [a.mouseup, a.keyup];", null, c.ZB_AUTOMATION_WORLD, 5000);
        const out = r.out orelse return null;
        return std.json.parseFromSliceLeaky([2]i64, self.allocator, out, .{}) catch null;
    }

    // N7: real GDK input delivered to the view; the page must see isTrusted.
    fn runNative(self: *LiveDriver) void {
        var err: [*c]u8 = null;
        _ = self.eval(null, "nativeLog.length = 0; return 0;", null, null, 5000);
        const button = self.center("nb") orelse return self.check(false, "button center");
        var base = self.inputAck() orelse return self.check(false, "inputAck available");
        var rc = c.zb_native_click(null, button[0], button[1], 1, null, 5000, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK, "native click returns OK");
        self.check(self.waitInputAck(base, 1, 0), "page acknowledged the native click");
        self.check(std.mem.eql(u8, self.nativeLog(), "mousedown:true,mouseup:true,click:true"), "native click is trusted and ordered");

        const input = self.center("ni") orelse return self.check(false, "input center");
        _ = self.eval(null, "nativeLog.length = 0; return 0;", null, null, 5000);
        base = self.inputAck() orelse return self.check(false, "inputAck available");
        rc = c.zb_native_click(null, input[0], input[1], 1, null, 5000, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(self.waitInputAck(base, 1, 0), "page acknowledged the focusing click");
        var releases: c_int = 0;
        base = self.inputAck() orelse return self.check(false, "inputAck available");
        var chars: c_int = 0;
        rc = c.zb_native_text(null, "hi", null, 5000, &releases, &chars, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK and releases == 2 and chars == 2, "native text returns OK with 2 releases and 2 chars");
        self.check(self.waitInputAck(base, 0, releases), "page acknowledged the typed keys");
        const typed = self.eval(null, "return document.getElementById('ni').value;", null, null, 5000);
        self.check(eq(typed.out, "hi"), "native text typed into the focused input");

        base = self.inputAck() orelse return self.check(false, "inputAck available");
        rc = c.zb_native_key(null, "a", c.ZB_NATIVE_MOD_SHIFT, null, 5000, &releases, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK and releases == 2, "native Shift+a returns OK with 2 releases");
        var more: c_int = 0;
        rc = c.zb_native_key(null, "Enter", 0, null, 5000, &more, &err);
        c.zb_automation_free(err);
        self.check(rc == c.ZB_AUTO_OK and more == 1, "native Enter returns OK with 1 release");
        self.check(self.waitInputAck(base, 0, releases + more), "page acknowledged Shift+a and Enter");
        const after = self.eval(null, "return document.getElementById('ni').value;", null, null, 5000);
        self.check(eq(after.out, "hiA"), "Shift+a typed an upper-case A");
        self.check(eq(self.nativeLog(), "keydown:h:true:false,keydown:i:true:false,keydown:Shift:true:true,keydown:A:true:true,keydown:Enter:true:false"), "native keys are trusted with key names and shift state");

        // The ack counts trusted events only: page-dispatched fakes cannot
        // satisfy a wait early.
        const ack_before = self.inputAck() orelse return self.check(false, "inputAck available");
        _ = self.eval(null, "document.dispatchEvent(new KeyboardEvent('keyup', {bubbles: true})); document.dispatchEvent(new MouseEvent('mouseup', {bubbles: true})); return 0;", null, null, 5000);
        const ack_after = self.inputAck() orelse return self.check(false, "inputAck available");
        self.check(ack_after[0] == ack_before[0] and ack_after[1] == ack_before[1], "synthetic page events do not count as input acks");

        // Key names are parsed exactly.
        var bad_err: [*c]u8 = null;
        self.check(c.zb_native_key(null, "F1x", 0, null, 5000, null, &bad_err) == c.ZB_AUTO_ERR_INTERNAL, "F1x is not a key");
        c.zb_automation_free(bad_err);
        bad_err = null;
        self.check(c.zb_native_key(null, "F13", 0, null, 5000, null, &bad_err) == c.ZB_AUTO_ERR_INTERNAL, "F13 is not a key");
        c.zb_automation_free(bad_err);
        bad_err = null;
        self.check(c.zb_native_key(null, "F12", 0, null, 5000, null, &bad_err) == c.ZB_AUTO_OK, "F12 is a key");
        c.zb_automation_free(bad_err);

        // Long text is bounded by the deadline: one GTK-thread step per
        // character, so it stops early instead of holding the GTK thread.
        const long_text = "x" ** 2000;
        var long_releases: c_int = 0;
        var long_chars: c_int = 0;
        const long_base = self.inputAck() orelse return self.check(false, "inputAck available");
        const long_start = monotonicMs();
        rc = c.zb_native_text(null, long_text, null, 50, &long_releases, &long_chars, &err);
        const long_ms = monotonicMs() - long_start;
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_ERR_TIMEOUT, "long native text times out at its deadline");
        self.check(long_ms < 500, "long native text returned promptly after the deadline");
        self.check(long_releases > 0 and long_releases < 2000, "long native text was only partially sent");
        self.check(long_chars == long_releases, "chars sent are reported exactly (one release per plain char)");
        // Every reported key was handed to WebKit and still reaches the page
        // after the timeout; wait for them so later steps start clean.
        self.check(self.waitInputAckFor(long_base, 0, long_releases, 20_000), "all keys reported as sent reach the page");
    }

    // N7 port layer: locate gives the actionable centre; the GTK port's native
    // methods return only after the page acknowledged their trusted events.
    fn runNativePort(self: *LiveDriver) void {
        const gpa = self.allocator;
        const port = gtk_port.pagePort().?;
        _ = self.eval(null, "nativeLog.length = 0; document.getElementById('ni').value = ''; return 0;", null, null, 5000);

        const locate_body = "return JSON.stringify(await globalThis.__zbAutomation.handle(JSON.parse(arg)));";
        const located = self.eval(null, locate_body, "{\"op\":\"locate\",\"selector\":\"css=#nb\",\"action\":\"click\"}", c.ZB_AUTOMATION_WORLD, 5000);
        const want = self.center("nb") orelse return self.check(false, "button center");
        const Located = struct { ok: bool, value: struct { x: f64, y: f64, document: []const u8, viewport: struct { width: f64, height: f64 } } };
        const loc = if (located.out) |out| std.json.parseFromSliceLeaky(Located, gpa, out, .{ .ignore_unknown_fields = true }) catch null else null;
        self.check(loc != null and loc.?.ok and @abs(loc.?.value.x - want[0]) < 0.5 and @abs(loc.?.value.y - want[1]) < 0.5, "locate returns the element centre in viewport px");
        const page_token = self.documentToken();
        self.check(loc != null and page_token != null and loc.?.value.document.len == 16 and std.mem.eql(u8, loc.?.value.document, page_token.?), "locate returns this document's 16-hex token");
        const inner = self.eval(null, "return JSON.stringify([innerWidth, innerHeight]);", null, null, 5000);
        const wh = if (inner.out) |out| std.json.parseFromSliceLeaky([2]f64, gpa, out, .{}) catch null else null;
        self.check(loc != null and wh != null and wh.?[0] > 0 and loc.?.value.viewport.width == wh.?[0] and loc.?.value.viewport.height == wh.?[1], "locate returns the viewport size");

        // Obscured target: locate refuses it like an action would.
        _ = self.eval(null, "var o = document.createElement('div'); o.id = 'nbcover'; o.style.cssText = 'position:fixed;left:0;top:100px;width:300px;height:80px;z-index:9'; document.body.appendChild(o); return 0;", null, null, 5000);
        const blocked = self.eval(null, locate_body, "{\"op\":\"locate\",\"selector\":\"css=#nb\",\"action\":\"click\"}", c.ZB_AUTOMATION_WORLD, 5000);
        self.check(blocked.out != null and std.mem.indexOf(u8, blocked.out.?, "element_obscured") != null, "locate refuses an obscured element");
        _ = self.eval(null, "document.getElementById('nbcover').remove(); return 0;", null, null, 5000);

        // Oracle: the page stamps Date.now() on trusted mouseup/keyup; the host
        // stamps the wall clock the instant the port call returns. A port that
        // returned before the page handled the input would have a later (or
        // zero) page stamp. Follow-up evals cannot mask an early return.
        _ = self.eval(null, "window.lastTrustedClick = 0; window.lastTrustedKeyUp = 0; return 0;", null, null, 5000);
        gtk_port.nativeClick(port.ptr, want[0], want[1], null, 5000) catch return self.check(false, "port nativeClick on the button succeeds");
        const click_returned = wallUs();
        self.check(self.pageStampBefore("lastTrustedClick", click_returned), "port nativeClick returned only after the page's click handlers ran");
        self.check(std.mem.eql(u8, self.nativeLog(), "mousedown:true,mouseup:true,click:true"), "port nativeClick delivered a trusted click");

        const input = self.center("ni") orelse return self.check(false, "input center");
        gtk_port.nativeClick(port.ptr, input[0], input[1], null, 5000) catch return self.check(false, "port nativeClick on the input succeeds");
        _ = self.eval(null, "window.lastTrustedKeyUp = 0; return 0;", null, null, 5000);
        var sent: usize = 0;
        gtk_port.nativeText(port.ptr, "ok", null, 5000, &sent) catch return self.check(false, "port nativeText succeeds");
        const text_returned = wallUs();
        self.check(sent == 2, "port nativeText reports 2 chars sent");
        self.check(self.pageStampBefore("lastTrustedKeyUp", text_returned), "port nativeText returned only after the page handled its keyups");
        const value = self.eval(null, "return document.getElementById('ni').value;", null, null, 5000);
        self.check(eq(value.out, "ok"), "port nativeText typed the text");
        _ = self.eval(null, "window.lastTrustedKeyUp = 0; return 0;", null, null, 5000);
        gtk_port.nativeKey(port.ptr, "a", 1, null, 5000) catch return self.check(false, "port nativeKey succeeds");
        const key_returned = wallUs();
        self.check(self.pageStampBefore("lastTrustedKeyUp", key_returned), "port nativeKey returned only after the page handled its keyups");
        const shifted = self.eval(null, "return document.getElementById('ni').value;", null, null, 5000);
        self.check(eq(shifted.out, "okA"), "port nativeKey(Shift+a) typed A");

        // Embedded NUL is refused instead of silently truncated at the C ABI.
        var nul_sent: usize = 99;
        self.check(if (gtk_port.nativeText(port.ptr, "a\x00b", null, 5000, &nul_sent)) |_| false else |e| e == error.EvalFailed, "port nativeText refuses embedded NUL");
        self.check(nul_sent == 0, "nothing was sent for NUL text");
        self.check(if (gtk_port.nativeKey(port.ptr, "a\x00", 0, null, 5000)) |_| false else |e| e == error.EvalFailed, "port nativeKey refuses embedded NUL");
        const after_nul = self.eval(null, "return document.getElementById('ni').value;", null, null, 5000);
        self.check(eq(after_nul.out, "okA"), "NUL input typed nothing");

        // locate honours force (skips actionability) and focus-for-type puts
        // the caret at the end of existing text.
        _ = self.eval(null, "var o = document.createElement('div'); o.id = 'nbcover'; o.style.cssText = 'position:fixed;left:0;top:100px;width:300px;height:80px;z-index:9'; document.body.appendChild(o); return 0;", null, null, 5000);
        const forced = self.eval(null, locate_body, "{\"op\":\"locate\",\"selector\":\"css=#nb\",\"action\":\"click\",\"options\":{\"force\":true}}", c.ZB_AUTOMATION_WORLD, 5000);
        self.check(forced.out != null and std.mem.indexOf(u8, forced.out.?, "\"ok\":true") != null, "locate with force skips actionability");
        _ = self.eval(null, "document.getElementById('nbcover').remove(); var i = document.getElementById('ni'); i.focus(); i.setSelectionRange(0, 0); return 0;", null, null, 5000);
        _ = self.eval(null, locate_body, "{\"op\":\"locate\",\"selector\":\"css=#ni\",\"action\":\"type\",\"focus\":true}", c.ZB_AUTOMATION_WORLD, 5000);
        var tail_sent: usize = 0;
        gtk_port.nativeText(port.ptr, "Z", null, 5000, &tail_sent) catch return self.check(false, "port nativeText after locate succeeds");
        const appended = self.eval(null, "return document.getElementById('ni').value;", null, null, 5000);
        self.check(eq(appended.out, "okAZ"), "locate focus:true for type appends at the end");

        var partial: usize = 0;
        const long_text = "y" ** 2000;
        const partial_result = gtk_port.nativeText(port.ptr, long_text, null, 50, &partial);
        self.check(if (partial_result) |_| false else |e| e == error.Timeout, "port nativeText times out on long text");
        self.check(partial > 0 and partial < 2000, "port nativeText reports partial progress on timeout");
        // Ack debt: the timed-out prefix keeps arriving, and its keyups must
        // not satisfy the next call. The very next key may only return after
        // its own keyup was handled.
        _ = self.eval(null, "window.lastTrustedKeyUp = 0; window.lastKeyUpKey = ''; document.addEventListener('keyup', function (e) { if (e.isTrusted) window.lastKeyUpKey = e.key; }); return 0;", null, null, 5000);
        gtk_port.nativeKey(port.ptr, "q", 0, null, 20_000) catch return self.check(false, "key after a partial type succeeds");
        const q_returned = wallUs();
        const last_key = self.eval(null, "return window.lastKeyUpKey;", null, null, 5000);
        self.check(eq(last_key.out, "q"), "the key after a partial type is the last keyup when it returns");
        self.check(self.pageStampBefore("lastTrustedKeyUp", q_returned), "the key after a partial type returned only after its own keyup");
        self.check(if (gtk_port.nativeKey(port.ptr, "F1x", 0, null, 5000)) |_| false else |e| e == error.EvalFailed, "port nativeKey rejects unknown keys");

        // A guard verdict held past the caller's deadline must not dispatch:
        // the waiter gave up (TIMEOUT), so nothing may reach the page later.
        {
            const token_now = self.documentToken() orelse return self.check(false, "token for the held guard");
            const token_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{token_now}, 0) catch return;
            _ = self.eval(null, "nativeLog.length = 0; return 0;", null, null, 5000);
            const hits = c.zb_automation_debug_native_guard_hold_hits();
            c.zb_automation_debug_native_guard_hold(300);
            var held_err: [*c]u8 = null;
            const held_rc = c.zb_native_click(null, want[0], want[1], 1, token_z.ptr, 50, &held_err);
            c.zb_automation_free(held_err);
            sleepMs(600);
            c.zb_automation_debug_native_guard_hold(0);
            self.check(held_rc == c.ZB_AUTO_ERR_TIMEOUT, "a held guarded click returns TIMEOUT");
            self.check(c.zb_automation_debug_native_guard_hold_hits() == hits + 1, "the guard verdict was held after the token matched");
            self.check(std.mem.eql(u8, self.nativeLog(), ""), "no click reached the page after the timeout");
        }

        // Native transactions are serialized: while one is in flight (its
        // guard held 300 ms by the test hook), a second call cannot start;
        // with a 100 ms deadline it returns Timeout and sends nothing.
        {
            const field = self.center("ni") orelse return self.check(false, "input center");
            gtk_port.nativeClick(port.ptr, field[0], field[1], null, 5000) catch return self.check(false, "focus for the serialization check");
            _ = self.eval(null, "window.keyupAt = {}; nativeLog.length = 0; return 0;", null, null, 5000);
            const token_now = self.documentToken() orelse return self.check(false, "token for the serialization check");
            const token_copy = gpa.dupe(u8, token_now) catch return;
            c.zb_automation_debug_native_guard_hold(300);
            var holder = ClickHolder{ .x = want[0], .y = want[1], .document = token_copy };
            const t = std.Thread.spawn(.{}, ClickHolder.run, .{ &holder, port }) catch return self.check(false, "spawn holder");
            sleepMs(50);
            const blocked_start = monotonicMs();
            const second = gtk_port.nativeKey(port.ptr, "w", 0, null, 100);
            const blocked_ms = monotonicMs() - blocked_start;
            t.join();
            c.zb_automation_debug_native_guard_hold(0);
            self.check(holder.ok, "the transaction holding the lock completes");
            self.check(if (second) |_| false else |e| e == error.Timeout, "a second native call during a transaction times out");
            self.check(blocked_ms < 250, "it gave up at its own deadline, not after the other transaction");
            sleepMs(200);
            const w_up = self.eval(null, "return String(window.keyupAt['w'] || 0);", null, null, 5000);
            self.check(eq(w_up.out, "0"), "the blocked call sent no key");
        }

        // Click completion: a synchronous page click handler that runs for
        // 40 ms has finished (and stamped) before nativeClick returns.
        const hold = self.center("hold") orelse return self.check(false, "hold center");
        gtk_port.nativeClick(port.ptr, hold[0], hold[1], null, 5000) catch return self.check(false, "click on the slow handler succeeds");
        const hold_returned = wallUs();
        self.check(self.pageStampBefore("holdDone", hold_returned), "nativeClick returned only after the page's slow click handler finished");

        // N8 nativeMove: a curved series of real pointer moves, then a click.
        // The page sees trusted mousemoves along the path (WebKit may
        // coalesce some), ending at the target the click then lands on.
        {
            _ = self.eval(null, "window.moves = []; nativeLog.length = 0; return 0;", null, null, 5000);
            const token_move = self.documentToken() orelse return self.check(false, "token for moves");
            const start_x: f64 = 400;
            const start_y: f64 = 400;
            var step: usize = 1;
            while (step <= 12) : (step += 1) {
                const t = @as(f64, @floatFromInt(step)) / 12.0;
                // Quadratic curve bowing away from the straight line.
                const ctrl_x: f64 = 400;
                const ctrl_y: f64 = 140;
                const x = (1 - t) * (1 - t) * start_x + 2 * (1 - t) * t * ctrl_x + t * t * want[0];
                const y = (1 - t) * (1 - t) * start_y + 2 * (1 - t) * t * ctrl_y + t * t * want[1];
                gtk_port.nativeMove(port.ptr, x, y, token_move, 5000) catch return self.check(false, "native move succeeds");
                sleepMs(8);
            }
            gtk_port.nativeClick(port.ptr, want[0], want[1], token_move, 5000) catch return self.check(false, "click after the moves");
            const Move = struct { f64, f64, bool };
            const moves_out = self.eval(null, "return JSON.stringify(window.moves);", null, null, 5000);
            const moves = if (moves_out.out) |out| std.json.parseFromSliceLeaky([]const Move, gpa, out, .{}) catch null else null;
            self.check(moves != null and moves.?.len >= 3, "the page saw several pointer moves");
            if (moves) |list| {
                var all_trusted = true;
                var max_off: f64 = 0;
                for (list) |m| {
                    all_trusted = all_trusted and m[2];
                    // Distance from the straight start->target line.
                    const dx = want[0] - start_x;
                    const dy = want[1] - start_y;
                    const off = @abs(dy * m[0] - dx * m[1] + want[0] * start_y - want[1] * start_x) / @sqrt(dx * dx + dy * dy);
                    max_off = @max(max_off, off);
                }
                self.check(all_trusted, "every mousemove is trusted");
                const last = list[list.len - 1];
                self.check(@abs(last[0] - want[0]) <= 1 and @abs(last[1] - want[1]) <= 1, "the moves end on the target");
                self.check(max_off > 20, "the path is curved, not a straight jump");
            }
            self.check(std.mem.eql(u8, self.nativeLog(), "mousedown:true,mouseup:true,click:true"), "the click after the path lands on the button");
            const cached = gtk_port.pointer(port.ptr);
            self.check(cached != null and cached.?.x == want[0] and cached.?.y == want[1], "the pointer cache holds the last dispatched position");

            // A move whose guard verdict is held past its deadline sends no
            // motion, ever, and leaves the cache alone.
            _ = self.eval(null, "window.moves = []; return 0;", null, null, 5000);
            const token_hold = self.documentToken() orelse return self.check(false, "token for the held move");
            const token_hold_z = std.fmt.allocPrintSentinel(gpa, "{s}", .{token_hold}, 0) catch return;
            c.zb_automation_debug_native_guard_hold(300);
            var move_err: [*c]u8 = null;
            const held_move = c.zb_native_move(null, 30, 30, token_hold_z.ptr, 50, &move_err);
            c.zb_automation_free(move_err);
            sleepMs(600);
            c.zb_automation_debug_native_guard_hold(0);
            self.check(held_move == c.ZB_AUTO_ERR_TIMEOUT, "a held guarded move returns TIMEOUT");
            // Only motion to the held move's own point counts: WebKit may
            // replay the last real pointer position (a trusted mousemove at
            // the previous target) after layout or hover changes.
            const late = self.eval(null, "return String(window.moves.filter(function (m) { return m[0] === 30 && m[1] === 30; }).length);", null, null, 5000);
            if (!eq(late.out, "0")) {
                const seen = self.eval(null, "return JSON.stringify(window.moves);", null, null, 5000);
                std.debug.print("late moves: {s}\n", .{seen.out orelse "?"});
            }
            self.check(eq(late.out, "0"), "no motion reached the page after the timeout");
            const port_held = blk: {
                c.zb_automation_debug_native_guard_hold(300);
                defer c.zb_automation_debug_native_guard_hold(0);
                break :blk gtk_port.nativeMove(port.ptr, 31, 31, token_hold, 50);
            };
            self.check(if (port_held) |_| false else |e| e == error.Timeout, "a held port move times out");
            sleepMs(600);
            const after_hold = gtk_port.pointer(port.ptr);
            self.check(after_hold != null and after_hold.?.x == want[0] and after_hold.?.y == want[1], "a timed-out move leaves the pointer cache unchanged");
        }

        // Document binding (A -> B between locate and dispatch): A's token on
        // page B is refused before anything is sent; B's button at the same
        // coordinates is never clicked.
        const token_a = self.documentToken() orelse return self.check(false, "document token on A");
        var bind_err: [*c]u8 = null;
        _ = c.zb_automation_navigate(null, self.uri_b.ptr, 15000, &bind_err);
        c.zb_automation_free(bind_err);
        bind_err = null;
        const cache_before = gtk_port.pointer(port.ptr);
        const stale_move = gtk_port.nativeMove(port.ptr, want[0] + 5, want[1] + 5, token_a, 5000);
        self.check(if (stale_move) |_| false else |e| e == error.DocumentChanged, "native move with a stale document token is DocumentChanged");
        const cache_after = gtk_port.pointer(port.ptr);
        self.check(cache_before != null and cache_after != null and cache_after.?.x == cache_before.?.x and cache_after.?.y == cache_before.?.y, "a refused move leaves the pointer cache unchanged");
        const stale = gtk_port.nativeClick(port.ptr, want[0], want[1], token_a, 5000);
        self.check(if (stale) |_| false else |e| e == error.DocumentChanged, "native click with a stale document token is DocumentChanged");
        const danger = self.eval(null, "return String(window.dangerClicked || 0);", null, null, 5000);
        self.check(eq(danger.out, "0"), "nothing on the new document was clicked");
        // The refused move's own point: WebKit may replay the last real
        // pointer position (the previous click) into the new document.
        var moves_buf: [256]u8 = undefined;
        const moves_body = std.fmt.bufPrintZ(&moves_buf, "return String(window.bMoves.filter(function (m) {{ return Math.abs(m[0] - {d}) <= 1 && Math.abs(m[1] - {d}) <= 1; }}).length);", .{ want[0] + 5, want[1] + 5 }) catch return;
        const b_moves = self.eval(null, moves_body, null, null, 5000);
        if (!eq(b_moves.out, "0")) {
            const seen = self.eval(null, "return JSON.stringify(window.bMoves);", null, null, 5000);
            std.debug.print("page B moves: {s}\n", .{seen.out orelse "?"});
        }
        self.check(eq(b_moves.out, "0"), "no motion reached the new document");
        var stale_sent: usize = 9;
        self.check(if (gtk_port.nativeText(port.ptr, "zz", token_a, 5000, &stale_sent)) |_| false else |e| e == error.DocumentChanged, "native text with a stale token is DocumentChanged");
        self.check(stale_sent == 0, "nothing was typed into the new document");
        const b_keys = self.eval(null, "return window.bKeys.join(',');", null, null, 5000);
        self.check(eq(b_keys.out, ""), "page B received no keys");
        _ = c.zb_automation_navigate(null, self.uri_a.ptr, 15000, &bind_err);
        c.zb_automation_free(bind_err);
        bind_err = null;

        // "a\nb" into a form whose Enter navigates: the text stops at the
        // document change, so 'b' never reaches page B (whole string, and one
        // code point per call as delay_ms does).
        const navq_box = self.center("navq") orelse return self.check(false, "form input center");
        gtk_port.nativeClick(port.ptr, navq_box[0], navq_box[1], null, 5000) catch return self.check(false, "focus the form input");
        const token_form = self.documentToken() orelse return self.check(false, "document token on A");
        var nl_sent: usize = 0;
        const nl = gtk_port.nativeText(port.ptr, "a\nb", token_form, 10_000, &nl_sent);
        self.check(if (nl) |_| false else |e| e == error.DocumentChanged, "text whose Enter navigates stops with DocumentChanged");
        self.check(nl_sent == 2, "exactly 'a' and Enter were sent");
        self.waitUrlContains("b.html");
        const b_after = self.eval(null, "return window.bKeys.join(',');", null, null, 5000);
        self.check(eq(b_after.out, ""), "'b' never reached page B (whole string)");
        _ = c.zb_automation_navigate(null, self.uri_a.ptr, 15000, &bind_err);
        c.zb_automation_free(bind_err);
        bind_err = null;
        gtk_port.nativeClick(port.ptr, navq_box[0], navq_box[1], null, 5000) catch return self.check(false, "focus the form input again");
        const token_delay = self.documentToken() orelse return self.check(false, "document token on A");
        var one: usize = 0;
        gtk_port.nativeText(port.ptr, "a", token_delay, 5000, &one) catch return self.check(false, "first code point typed");
        var enter_sent: usize = 0;
        const enter_one = gtk_port.nativeText(port.ptr, "\n", token_delay, 10_000, &enter_sent);
        self.check(if (enter_one) |_| false else |e| e == error.DocumentChanged, "a single navigating code point reports DocumentChanged");
        self.check(enter_sent == 1, "that code point was sent");
        var b_sent: usize = 9;
        const b_one = gtk_port.nativeText(port.ptr, "b", token_delay, 10_000, &b_sent);
        self.check(if (b_one) |_| false else |e| e == error.DocumentChanged, "the next code point with the old token is refused");
        self.check(b_sent == 0, "'b' was not sent");
        self.waitUrlContains("b.html");
        const b_delay = self.eval(null, "return window.bKeys.join(',');", null, null, 5000);
        self.check(eq(b_delay.out, ""), "'b' never reached page B (per code point)");
        _ = c.zb_automation_navigate(null, self.uri_a.ptr, 15000, &bind_err);
        c.zb_automation_free(bind_err);

        // Input that navigates resets the per-document ack counters; the port
        // must treat the new document as delivery, not wait to its deadline.
        var nav_err: [*c]u8 = null;
        const nav_start = monotonicMs();
        const link = self.center("navlink") orelse return self.check(false, "link center");
        const link_result = gtk_port.nativeClick(port.ptr, link[0], link[1], null, 5000);
        self.check(if (link_result) |_| true else |_| false, "native click on a navigating link succeeds");
        self.check(monotonicMs() - nav_start < 3000, "navigating click returned without waiting for its deadline");
        var nav_waited: u32 = 0;
        while (nav_waited < 3000) : (nav_waited += 10) {
            if (std.mem.endsWith(u8, self.str(&nav_rc_dummy, .url), "b.html")) break;
            sleepMs(10);
        }
        self.check(std.mem.endsWith(u8, self.str(&nav_rc_dummy, .url), "b.html"), "the link navigated to B");
        _ = c.zb_automation_navigate(null, self.uri_a.ptr, 15000, &nav_err);
        c.zb_automation_free(nav_err);
        nav_err = null;
        const navq = self.center("navq") orelse return self.check(false, "form input center");
        gtk_port.nativeClick(port.ptr, navq[0], navq[1], null, 5000) catch return self.check(false, "focus the form input");
        const enter_start = monotonicMs();
        const enter_result = gtk_port.nativeKey(port.ptr, "Enter", 0, null, 5000);
        self.check(if (enter_result) |_| true else |_| false, "native Enter that submits a form succeeds");
        self.check(monotonicMs() - enter_start < 3000, "navigating Enter returned without waiting for its deadline");
        nav_waited = 0;
        while (nav_waited < 3000) : (nav_waited += 10) {
            if (std.mem.indexOf(u8, self.str(&nav_rc_dummy, .url), "b.html") != null) break;
            sleepMs(10);
        }
        self.check(std.mem.indexOf(u8, self.str(&nav_rc_dummy, .url), "b.html") != null, "Enter submitted the form to B");
        _ = c.zb_automation_navigate(null, self.uri_a.ptr, 15000, &nav_err);
        c.zb_automation_free(nav_err);
    }

    var nav_rc_dummy: c_int = 0;

    const ClickHolder = struct {
        x: f64,
        y: f64,
        document: []const u8,
        ok: bool = false,

        fn run(self: *ClickHolder, port: page_port_mod.PagePort) void {
            gtk_port.nativeClick(port.ptr, self.x, self.y, self.document, 5000) catch return;
            self.ok = true;
        }
    };

    fn documentToken(self: *LiveDriver) ?[]const u8 {
        const r = self.eval(null, "return globalThis.__zbAutomation.documentToken;", null, c.ZB_AUTOMATION_WORLD, 5000);
        return r.out;
    }

    fn waitUrlContains(self: *LiveDriver, comptime needle: []const u8) void {
        var waited: u32 = 0;
        while (waited < 5000) : (waited += 10) {
            if (std.mem.indexOf(u8, self.str(&nav_rc_dummy, .url), needle) != null) return;
            sleepMs(10);
        }
    }

    /// Page stamps are microseconds (performance.timeOrigin + now()); the
    /// host stamp is taken right after the port call returned. Strictly
    /// earlier: an equal coarse stamp could hide an early return.
    fn pageStampBefore(self: *LiveDriver, comptime name: []const u8, returned_us: i64) bool {
        const r = self.eval(null, "return String(window." ++ name ++ ");", null, null, 5000);
        const out = r.out orelse return false;
        const stamp = std.fmt.parseInt(i64, out, 10) catch return false;
        return stamp > 0 and stamp < returned_us;
    }

    // Explicit child windows wait for their own first load, not the primary's.
    // The child page's image is held by DelayServer for 800 ms, so the child
    // is deterministically still loading when the command is issued; the
    // command may only complete after the server responded.
    fn runChildWindow(self: *LiveDriver) void {
        const server = self.delay_server orelse return self.check(false, "delay server available");
        var buf: [1024]u8 = undefined;
        const open_body = std.fmt.bufPrintZ(&buf, "window.open('{s}'); return 0;", .{self.uri_delay}) catch return;
        _ = self.eval(null, open_body, null, null, 5000);
        var child: ?*c.ZbWindow = null;
        var waited: u32 = 0;
        while (waited < 3000) : (waited += 5) {
            child = c.zb_automation_window_at(1);
            if (child != null) break;
            sleepMs(5);
        }
        self.check(child != null, "child window is published");
        if (child == null) return;
        self.check(c.zb_automation_main_window() != child, "primary window stays the first window");

        const responded_at_issue = server.responded_ms.load(.acquire);
        const title = self.eval(child, "return document.title;", null, c.ZB_AUTOMATION_WORLD, 5000);
        const done_ms = monotonicMs();
        const responded_ms = server.responded_ms.load(.acquire);
        self.check(responded_at_issue == 0, "child op was issued while the child was still loading");
        self.check(responded_ms != 0 and done_ms >= responded_ms, "child op completed only after the child's load could finish");
        self.check(eq(title.out, "Fixture Delay"), "explicit child window op sees the child's real page");
        const text = self.eval(child, "return JSON.stringify(await globalThis.__zbAutomation.handle(JSON.parse(arg)));", "{\"op\":\"getText\",\"selector\":\"css=#msg\"}", c.ZB_AUTOMATION_WORLD, 5000);
        self.check(text.out != null and std.mem.indexOf(u8, text.out.?, "Delayed child") != null, "automation.js is injected into the child window");
        // (Page-initiated window.close() is not wired in the shim, so the child
        // stays open until teardown; stale pointers are covered by the bogus
        // window check above.)
    }

    // N5: the cookie store of the primary window's (profile) context. Each
    // cookie is checked as its own parsed object, so attributes cannot be
    // satisfied by a different cookie.
    fn runCookies(self: *LiveDriver) void {
        const expires = @divTrunc(gfile.g_get_real_time(), std.time.us_per_s) + 3600;
        self.addCookie(.{ .name = "zbc", .value = "s3cr\"et", .domain = "example.test", .path = "/", .expires = expires, .http_only = 1, .secure = 0, .same_site = c.ZB_COOKIE_SAME_SITE_LAX }, "add Lax cookie");
        self.addCookie(.{ .name = "zbsession", .value = "v", .domain = "other.test", .path = "/app", .expires = -1, .http_only = 0, .secure = 1, .same_site = c.ZB_COOKIE_SAME_SITE_UNSET }, "add session cookie");
        self.addCookie(.{ .name = "zbstrict", .value = "s", .domain = "example.test", .path = "/", .expires = expires, .http_only = 0, .secure = 0, .same_site = c.ZB_COOKIE_SAME_SITE_STRICT }, "add Strict cookie");
        self.addCookie(.{ .name = "zbnone", .value = "n", .domain = "example.test", .path = "/", .expires = expires, .http_only = 0, .secure = 1, .same_site = c.ZB_COOKIE_SAME_SITE_NONE }, "add None cookie");

        const all = self.cookies(null);
        self.check(all != null, "getAll returns a parsable JSON array");
        if (find(all, "zbc")) |cookie| {
            self.check(std.mem.eql(u8, cookie.value, "s3cr\"et") and std.mem.eql(u8, cookie.domain, "example.test") and
                std.mem.eql(u8, cookie.path, "/") and cookie.expires == expires and cookie.httpOnly and !cookie.secure and
                std.mem.eql(u8, cookie.sameSite, "Lax"), "zbc round-trips value, domain, path, exact expiry, flags, Lax");
        } else self.check(false, "zbc listed");
        if (find(all, "zbsession")) |cookie| {
            self.check(std.mem.eql(u8, cookie.domain, "other.test") and std.mem.eql(u8, cookie.path, "/app") and
                cookie.expires == -1 and !cookie.httpOnly and cookie.secure, "zbsession is a secure session cookie on /app");
        } else self.check(false, "zbsession listed");
        if (find(all, "zbstrict")) |cookie| {
            self.check(std.mem.eql(u8, cookie.sameSite, "Strict") and cookie.expires == expires, "Strict round-trips");
        } else self.check(false, "zbstrict listed");
        if (find(all, "zbnone")) |cookie| {
            self.check(std.mem.eql(u8, cookie.sameSite, "None") and cookie.secure, "None round-trips");
        } else self.check(false, "zbnone listed");

        const for_url = self.cookies("http://example.test/page");
        self.check(find(for_url, "zbc") != null and find(for_url, "zbsession") == null, "getAll(url) returns only cookies for that URL");

        // A failing add with a sentinel value never echoes the value.
        var err: [*c]u8 = null;
        const bad: c.ZbCookie = .{ .name = "zbbad", .value = "SENTINEL-zb-value", .domain = "", .path = "/", .expires = -1, .http_only = 0, .secure = 0, .same_site = 0 };
        const bad_rc = c.zb_cookies_add(null, &bad, 5000, &err);
        self.check(bad_rc != c.ZB_AUTO_OK and (err == null or std.mem.indexOf(u8, std.mem.span(err), "SENTINEL") == null), "failed add reports no cookie value");
        c.zb_automation_free(err);

        self.check(self.deleteCookie("zbc", null) == c.ZB_AUTO_OK, "delete by name returns OK");
        self.check(self.deleteCookie("zbsession", "elsewhere.test") == c.ZB_AUTO_OK, "non-matching domain delete is not an error");
        const after = self.cookies(null);
        self.check(after != null and find(after, "zbc") == null and find(after, "zbsession") != null, "delete removed only the named cookie");
        self.check(self.deleteCookie("zbsession", "other.test") == c.ZB_AUTO_OK and find(self.cookies(null), "zbsession") == null, "delete on the matching domain removes it");
        _ = self.deleteCookie("zbstrict", null);
        _ = self.deleteCookie("zbnone", null);

        // Expiry range: the year-9999 maximum is accepted, one second later
        // is refused (never silently turned into a session cookie).
        self.addCookie(.{ .name = "zbmax", .value = "m", .domain = "example.test", .path = "/", .expires = c.ZB_COOKIE_MAX_EXPIRES, .http_only = 0, .secure = 0, .same_site = 0 }, "maximum expiry accepted");
        self.check(if (find(self.cookies(null), "zbmax")) |cookie| cookie.expires == c.ZB_COOKIE_MAX_EXPIRES else false, "maximum expiry round-trips");
        _ = self.deleteCookie("zbmax", null);
        var range_err: [*c]u8 = null;
        const too_late: c.ZbCookie = .{ .name = "zblate", .value = "l", .domain = "example.test", .path = "/", .expires = c.ZB_COOKIE_MAX_EXPIRES + 1, .http_only = 0, .secure = 0, .same_site = 0 };
        const late_rc = c.zb_cookies_add(null, &too_late, 5000, &range_err);
        self.check(late_rc == c.ZB_AUTO_ERR_INTERNAL and range_err != null and std.mem.indexOf(u8, std.mem.span(range_err), "out of range") != null, "expiry past year 9999 is refused");
        c.zb_automation_free(range_err);
        self.check(find(self.cookies(null), "zblate") == null, "refused cookie was not stored");

        // Timeout while in flight (deterministic): the hook holds each started
        // cookie op for 300 ms, so a 50 ms deadline expires with the job
        // RUNNING; the waiter abandons it, the GTK thread cancels it, and the
        // job is released when the hold ends - without reaching WebKit.
        c.zb_automation_debug_cookie_delay(300);
        const hits_before = c.zb_automation_debug_cookie_delay_hits();
        var held_out: [*c]u8 = null;
        var held_err: [*c]u8 = null;
        const held_start = monotonicMs();
        const held_rc = c.zb_cookies_get_all(null, null, 50, &held_out, &held_err);
        const held_ms = monotonicMs() - held_start;
        c.zb_automation_free(held_out);
        c.zb_automation_free(held_err);
        c.zb_automation_debug_cookie_delay(0);
        self.check(c.zb_automation_debug_cookie_delay_hits() == hits_before + 1, "the timed-out cookie op had started (entered the held RUNNING state)");
        self.check(held_rc == c.ZB_AUTO_ERR_TIMEOUT, "in-flight cookie op returns TIMEOUT at its deadline");
        self.check(held_ms < 250, "TIMEOUT came at the deadline, not after the hold");
        self.check(held_out == null, "a timed-out cookie op returns no result");
        var waited: u32 = 0;
        while (c.zb_automation_debug_live_jobs() != 0 and waited < 3000) : (waited += 10) sleepMs(10);
        self.check(c.zb_automation_debug_live_jobs() == 0, "the abandoned cookie job is released");
        self.check(self.cookies(null) != null, "cookie store still answers after an abandoned op");
    }
};

/// Turns a hung live test into a fast, visible failure. On expiry it writes
/// with raw write(2) and _exit()s: Zig's panic/print path takes locks that a
/// wedged thread may hold, which is how an earlier hang became permanent.
const Watchdog = struct {
    done: std.atomic.Value(bool) = .{ .raw = false },

    fn run(self: *Watchdog, limit_ms: u64) void {
        var waited: u64 = 0;
        while (!self.done.load(.acquire)) : (waited += 50) {
            if (waited >= limit_ms) {
                const msg = "live bridge watchdog: test exceeded its time limit; aborting\n";
                _ = std.c.write(2, msg.ptr, msg.len);
                std.c._exit(124);
            }
            sleepMs(50);
        }
    }
};

test "automation bridge drives a live WebKitGTK page" {
    try skipUnlessGtk();
    if (std.c.getenv("DISPLAY") == null) return error.SkipZigTest;
    const allocator = std.heap.c_allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = gfile.g_dir_make_tmp("zb-bridge-XXXXXX", null) orelse return error.TmpDirFailed;
    defer gfile.g_free(dir);
    const path_a = try std.fmt.allocPrintSentinel(arena, "{s}/a.html", .{dir}, 0);
    const path_b = try std.fmt.allocPrintSentinel(arena, "{s}/b.html", .{dir}, 0);
    const path_missing = try std.fmt.allocPrintSentinel(arena, "{s}/missing.html", .{dir}, 0);
    try std.testing.expect(gfile.g_file_set_contents(path_a, fixture_a.ptr, fixture_a.len, null) != 0);
    try std.testing.expect(gfile.g_file_set_contents(path_b, fixture_b.ptr, fixture_b.len, null) != 0);
    const stalled = try StalledServer.open();
    defer stalled.close();
    var slow_buf: [512]u8 = undefined;
    const slow_html = fixtureSlow(&slow_buf, stalled.port);
    const path_slow = try std.fmt.allocPrintSentinel(arena, "{s}/slow.html", .{dir}, 0);
    try std.testing.expect(gfile.g_file_set_contents(path_slow, slow_html.ptr, @intCast(slow_html.len), null) != 0);
    var delay_server = try DelayServer.open(800);
    defer delay_server.close();
    try delay_server.start();
    var delay_buf: [512]u8 = undefined;
    const delay_html = fixtureDelay(&delay_buf, delay_server.port);
    const path_delay = try std.fmt.allocPrintSentinel(arena, "{s}/delay.html", .{dir}, 0);
    try std.testing.expect(gfile.g_file_set_contents(path_delay, delay_html.ptr, @intCast(delay_html.len), null) != 0);

    const uriOf = struct {
        fn f(a: std.mem.Allocator, path: [:0]const u8) ![:0]const u8 {
            const raw = gfile.g_filename_to_uri(path, null, null) orelse return error.UriFailed;
            defer gfile.g_free(raw);
            return a.dupeZ(u8, std.mem.span(raw));
        }
    }.f;

    var driver: LiveDriver = .{
        .allocator = arena,
        .uri_a = try uriOf(arena, path_a),
        .uri_b = try uriOf(arena, path_b),
        .uri_missing = try uriOf(arena, path_missing),
        .uri_slow = try uriOf(arena, path_slow),
        .uri_delay = try uriOf(arena, path_delay),
        .delay_server = &delay_server,
    };

    gtk_port.installScript();
    defer c.zb_automation_set_script(null, 0);
    // Run the whole scenario on a profile-backed (non-default) WebKit context.
    const profile_dir = try std.fmt.allocPrintSentinel(arena, "{s}/profile", .{dir}, 0);
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_OK), c.zb_app_set_profile_dir(profile_dir.ptr, null));
    defer _ = c.zb_app_set_profile_dir(null, null);

    var watchdog: Watchdog = .{};
    const w = try std.Thread.spawn(.{}, Watchdog.run, .{ &watchdog, @as(u64, 90_000) });
    var watchdog_joined = false;
    errdefer if (!watchdog_joined) {
        watchdog.done.store(true, .release);
        w.join();
    };
    const t = try std.Thread.spawn(.{}, LiveDriver.run, .{&driver});
    _ = c.zb_app_run(driver.uri_a.ptr, 0, 0);
    t.join();
    watchdog.done.store(true, .release);
    w.join();
    watchdog_joined = true;

    if (driver.pending_eval) |pending| pending.join();
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_ERR_NO_LOOP), driver.pending_eval_rc.load(.acquire));
    if (driver.pending_cookie) |pending| pending.join();
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_ERR_NO_LOOP), driver.pending_cookie_rc.load(.acquire));
    for (driver.failures.items) |f| std.debug.print("live bridge check failed: {s}\n", .{f});
    try std.testing.expectEqual(@as(usize, 0), driver.failures.items.len);

    // After the loop has ended there is no primary window and ops fail fast.
    try std.testing.expect(c.zb_automation_main_window() == null);
    var out: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_ERR_NO_LOOP), c.zb_automation_get_url(null, 5000, &out));
    // Every bridge job (including the abandoned eval and load) was released.
    try std.testing.expectEqual(@as(c_int, 0), c.zb_automation_debug_live_jobs());
    // The profile-backed context stored its data under the profile directory.
    for ([_][]const u8{ "cookies.sqlite", "data", "cache" }) |entry| {
        const path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ profile_dir, entry }, 0);
        try std.testing.expect(gio.mode(path.ptr) != null);
    }
    c.zb_automation_loop_mark(1);
}

// --- Persistent profile (N4) ---

const gio = struct {
    extern fn g_file_new_for_path(path: [*:0]const u8) *anyopaque;
    extern fn g_file_query_info(file: *anyopaque, attributes: [*:0]const u8, flags: c_int, cancellable: ?*anyopaque, err: ?*?*anyopaque) ?*anyopaque;
    extern fn g_file_info_get_attribute_uint32(info: *anyopaque, attribute: [*:0]const u8) u32;
    extern fn g_object_unref(object: *anyopaque) void;

    /// Unix mode bits of `path`, or null when it does not exist.
    fn mode(path: [*:0]const u8) ?u32 {
        const file = g_file_new_for_path(path);
        defer g_object_unref(file);
        const info = g_file_query_info(file, "unix::mode", 0, null, null) orelse return null;
        defer g_object_unref(info);
        return g_file_info_get_attribute_uint32(info, "unix::mode");
    }
};

test "zb_app_set_profile_dir creates the directory 0700 and reports failures" {
    try skipUnlessGtk();
    const base = gfile.g_dir_make_tmp("zb-profile-XXXXXX", null) orelse return error.TmpDirFailed;
    defer gfile.g_free(base);
    var buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&buf, "{s}/nested/profile", .{base});

    var err: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_OK), c.zb_app_set_profile_dir(dir.ptr, &err));
    try std.testing.expect(err == null);
    const mode = gio.mode(dir.ptr) orelse return error.ProfileDirMissing;
    try std.testing.expectEqual(@as(u32, 0o700), mode & 0o777);

    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_ERR_INTERNAL), c.zb_app_set_profile_dir("/proc/zb-not-creatable/profile", &err));
    try std.testing.expect(err != null);
    c.zb_automation_free(err);

    // NULL / "" go back to the default (non-profile) context.
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_OK), c.zb_app_set_profile_dir(null, null));
}

// The pointer cache belongs to a window: when the primary window goes away,
// the window that becomes primary does not inherit its position. Its own
// zb_app_run, because closing a window also ends the web process its
// window.open() children share.
const ReplaceDriver = struct {
    uri_b: [:0]const u8,
    failures: u32 = 0,

    fn check(self: *ReplaceDriver, ok: bool, comptime what: []const u8) void {
        if (!ok) {
            std.debug.print("primary replacement check failed: {s}\n", .{what});
            self.failures += 1;
        }
    }

    fn run(self: *ReplaceDriver) void {
        const port = gtk_port.pagePort().?;
        var err: [*c]u8 = null;
        _ = c.zb_automation_eval_json(null, "return 1;", null, null, 15_000, null, &err);
        c.zb_automation_free(err);
        gtk_port.nativeMove(port.ptr, 50, 60, null, 5000) catch return self.check(false, "move on the primary window");
        var px: f64 = 0;
        var py: f64 = 0;
        self.check(c.zb_native_pointer(null, &px, &py) != 0 and px == 50 and py == 60, "the primary window caches its pointer");

        var buf: [1024]u8 = undefined;
        const open_body = std.fmt.bufPrintZ(&buf, "window.open('{s}'); return 0;", .{self.uri_b}) catch return;
        _ = c.zb_automation_eval_json(null, open_body.ptr, null, null, 5000, null, &err);
        c.zb_automation_free(err);
        err = null;
        var waited: u32 = 0;
        while (c.zb_automation_window_at(1) == null and waited < 5000) : (waited += 5) sleepMs(5);
        const child = c.zb_automation_window_at(1) orelse return self.check(false, "a child window opened");
        self.check(c.zb_native_pointer(child, &px, &py) == 0, "the child window has no pointer of its own");

        const main = c.zb_automation_window_at(0) orelse return self.check(false, "the primary window exists");
        self.check(c.zb_automation_debug_destroy_window(main, 5000) == c.ZB_AUTO_OK, "the primary window was closed");
        self.check(c.zb_automation_main_window() == child, "the child is now the primary window");
        self.check(c.zb_native_pointer(null, &px, &py) == 0, "the new primary does not inherit the old pointer");
        self.check(gtk_port.pointer(port.ptr) == null, "the port's pointer follows the new primary");
        _ = c.zb_main_invoke_sync(LiveDriver.quit, null, 5000);
    }
};

test "the native pointer cache belongs to its window" {
    try skipUnlessGtk();
    if (std.c.getenv("DISPLAY") == null) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = gfile.g_dir_make_tmp("zb-pointer-XXXXXX", null) orelse return error.TmpDirFailed;
    defer gfile.g_free(dir);
    const path_a = try std.fmt.allocPrintSentinel(arena, "{s}/a.html", .{dir}, 0);
    const path_b = try std.fmt.allocPrintSentinel(arena, "{s}/b.html", .{dir}, 0);
    try std.testing.expect(gfile.g_file_set_contents(path_a, fixture_a.ptr, fixture_a.len, null) != 0);
    try std.testing.expect(gfile.g_file_set_contents(path_b, fixture_b.ptr, fixture_b.len, null) != 0);
    const raw_a = gfile.g_filename_to_uri(path_a, null, null) orelse return error.UriFailed;
    defer gfile.g_free(raw_a);
    const raw_b = gfile.g_filename_to_uri(path_b, null, null) orelse return error.UriFailed;
    defer gfile.g_free(raw_b);
    const uri_a = try arena.dupeZ(u8, std.mem.span(raw_a));
    var driver: ReplaceDriver = .{ .uri_b = try arena.dupeZ(u8, std.mem.span(raw_b)) };

    gtk_port.installScript();
    defer c.zb_automation_set_script(null, 0);
    c.zb_automation_loop_mark(1);
    var watchdog: Watchdog = .{};
    const w = try std.Thread.spawn(.{}, Watchdog.run, .{ &watchdog, @as(u64, 60_000) });
    defer {
        watchdog.done.store(true, .release);
        w.join();
    }
    const t = try std.Thread.spawn(.{}, ReplaceDriver.run, .{&driver});
    _ = c.zb_app_run(uri_a.ptr, 0, 0);
    t.join();
    try std.testing.expectEqual(@as(u32, 0), driver.failures);
    c.zb_automation_loop_mark(1);
}

// A window closed by its own input event: a GTK-level motion handler
// destroys (and frees) the ZbWindow inside gtk_main_do_event. The pointer
// cache write after dispatch must find the window gone instead of writing
// through the stale pointer, and a click sends nothing after the motion that
// closed its window.
const SelfCloseDriver = struct {
    uri_b: [:0]const u8,
    failures: u32 = 0,

    fn check(self: *SelfCloseDriver, ok: bool, comptime what: []const u8) void {
        if (!ok) {
            std.debug.print("self-closing window check failed: {s}\n", .{what});
            self.failures += 1;
        }
    }

    fn openChild(self: *SelfCloseDriver, index: c_int) ?*c.ZbWindow {
        var buf: [1024]u8 = undefined;
        const open_body = std.fmt.bufPrintZ(&buf, "window.open('{s}'); return 0;", .{self.uri_b}) catch return null;
        var err: [*c]u8 = null;
        _ = c.zb_automation_eval_json(null, open_body.ptr, null, null, 5000, null, &err);
        c.zb_automation_free(err);
        var waited: u32 = 0;
        while (c.zb_automation_window_at(index) == null and waited < 5000) : (waited += 5) sleepMs(5);
        const child = c.zb_automation_window_at(index) orelse return null;
        err = null;
        // Waits for the child's first load, so its view is realized.
        _ = c.zb_automation_eval_json(child, "return 1;", null, null, 10_000, null, &err);
        c.zb_automation_free(err);
        return child;
    }

    fn run(self: *SelfCloseDriver) void {
        var err: [*c]u8 = null;
        _ = c.zb_automation_eval_json(null, "return 1;", null, null, 15_000, null, &err);
        c.zb_automation_free(err);
        err = null;
        const moved = self.openChild(1) orelse return self.check(false, "first child opened");
        const clicked = self.openChild(2) orelse return self.check(false, "second child opened");
        const keyed = self.openChild(3) orelse return self.check(false, "third child opened");
        const lost_before = c.zb_automation_debug_pointer_lost();

        self.check(c.zb_automation_debug_close_on_motion(moved, 5000) == c.ZB_AUTO_OK, "arm close-on-motion (move)");
        const move_rc = c.zb_native_move(moved, 10, 10, null, 5000, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(move_rc == c.ZB_AUTO_ERR_NO_WINDOW, "a move that closed its window reports NO_WINDOW");
        self.check(c.zb_automation_debug_pointer_lost() == lost_before + 1, "the cache write found the moved window gone");
        self.check(c.zb_native_pointer(moved, null, null) == 0, "no pointer is cached for the closed window");

        self.check(c.zb_automation_debug_close_on_motion(clicked, 5000) == c.ZB_AUTO_OK, "arm close-on-motion (click)");
        const click_rc = c.zb_native_click(clicked, 10, 10, 1, null, 5000, &err);
        c.zb_automation_free(err);
        self.check(click_rc == c.ZB_AUTO_ERR_NO_WINDOW, "a click whose motion closed its window reports NO_WINDOW");
        self.check(c.zb_automation_debug_pointer_lost() == lost_before + 2, "the cache write found the clicked window gone");

        // A key press whose own handler closes the window: its release (and
        // anything after it) is not sent to the destroyed window.
        const skipped_before = c.zb_automation_debug_native_skipped();
        self.check(c.zb_automation_debug_close_on_key(keyed, 5000) == c.ZB_AUTO_OK, "arm close-on-key");
        var releases: c_int = 0;
        err = null;
        const key_rc = c.zb_native_key(keyed, "a", 0, null, 5000, &releases, &err);
        c.zb_automation_free(err);
        self.check(key_rc == c.ZB_AUTO_ERR_NO_WINDOW, "a key whose press closed its window reports NO_WINDOW");
        self.check(c.zb_automation_debug_native_skipped() > skipped_before, "the key release was not sent to the destroyed window");
        self.check(c.zb_automation_window_at(1) == null, "every child is gone, the primary remains");
        _ = c.zb_main_invoke_sync(LiveDriver.quit, null, 5000);
    }
};

test "a window closed by its own input event is never touched afterwards" {
    try skipUnlessGtk();
    if (std.c.getenv("DISPLAY") == null) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = gfile.g_dir_make_tmp("zb-selfclose-XXXXXX", null) orelse return error.TmpDirFailed;
    defer gfile.g_free(dir);
    const path_a = try std.fmt.allocPrintSentinel(arena, "{s}/a.html", .{dir}, 0);
    const path_b = try std.fmt.allocPrintSentinel(arena, "{s}/b.html", .{dir}, 0);
    try std.testing.expect(gfile.g_file_set_contents(path_a, fixture_a.ptr, fixture_a.len, null) != 0);
    try std.testing.expect(gfile.g_file_set_contents(path_b, fixture_b.ptr, fixture_b.len, null) != 0);
    const raw_a = gfile.g_filename_to_uri(path_a, null, null) orelse return error.UriFailed;
    defer gfile.g_free(raw_a);
    const raw_b = gfile.g_filename_to_uri(path_b, null, null) orelse return error.UriFailed;
    defer gfile.g_free(raw_b);
    const uri_a = try arena.dupeZ(u8, std.mem.span(raw_a));
    var driver: SelfCloseDriver = .{ .uri_b = try arena.dupeZ(u8, std.mem.span(raw_b)) };

    gtk_port.installScript();
    defer c.zb_automation_set_script(null, 0);
    c.zb_automation_loop_mark(1);
    var watchdog: Watchdog = .{};
    const w = try std.Thread.spawn(.{}, Watchdog.run, .{ &watchdog, @as(u64, 60_000) });
    defer {
        watchdog.done.store(true, .release);
        w.join();
    }
    const t = try std.Thread.spawn(.{}, SelfCloseDriver.run, .{&driver});
    _ = c.zb_app_run(uri_a.ptr, 0, 0);
    t.join();
    try std.testing.expectEqual(@as(u32, 0), driver.failures);
    c.zb_automation_loop_mark(1);
}

// Native text and navigations that never replace the document. Typing that
// starts a cross-document navigation stops that sequence; when the
// navigation then ends without a new document (the page cancels it, or the
// response is a 204), a fresh native text call in the same document types
// normally instead of being refused forever.
const nav_fixture =
    \\<!doctype html><html><head><title>Nav</title></head><body>
    \\<form action="/next"><input id="q" name="q" style="position:fixed;left:20px;top:40px;width:200px;height:30px"></form>
    \\<form action="/204"><input id="r" name="r" style="position:fixed;left:20px;top:100px;width:200px;height:30px"></form>
    \\<form action="/hold"><input id="s" name="s" style="position:fixed;left:20px;top:160px;width:200px;height:30px"></form>
    \\<script>window.cancelNav = false; window.cancelled = 0;
    \\navigation.addEventListener('navigate', function (e) {
    \\  if (window.cancelNav && !e.destination.sameDocument) { e.preventDefault(); window.cancelled += 1; } });</script>
    \\</body></html>
;

/// HTTP server: "GET /204..." answers 204 No Content, "GET /hold..." the
/// same after 1.5 s, anything else the nav fixture. One request per
/// connection, one connection at a time, until closed.
const NoContentServer = struct {
    fd: c_int,
    port: u16,
    thread: ?std.Thread = null,

    fn open() !NoContentServer {
        const listener = try StalledServer.open();
        return .{ .fd = listener.fd, .port = listener.port };
    }

    fn start(self: *NoContentServer) !void {
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn serve(self: *NoContentServer) void {
        while (true) {
            const conn = std.c.accept(self.fd, null, null);
            if (conn < 0) return;
            defer _ = std.c.close(conn);
            var req: [4096]u8 = undefined;
            const n = std.c.read(conn, &req, req.len);
            if (n <= 0) continue;
            var head: [256]u8 = undefined;
            const hold = std.mem.startsWith(u8, req[0..@intCast(n)], "GET /hold");
            if (hold) sleepMs(1500);
            const reply = if (hold or std.mem.startsWith(u8, req[0..@intCast(n)], "GET /204"))
                "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
            else
                std.fmt.bufPrint(&head, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{nav_fixture.len}) catch continue;
            // The browser may have dropped a held request: no SIGPIPE.
            _ = std.c.send(conn, reply.ptr, reply.len, std.c.MSG.NOSIGNAL);
            if (!std.mem.startsWith(u8, reply, "HTTP/1.1 204")) _ = std.c.send(conn, nav_fixture.ptr, nav_fixture.len, std.c.MSG.NOSIGNAL);
        }
    }

    fn close(self: *NoContentServer) void {
        _ = std.c.shutdown(self.fd, 2);
        _ = std.c.close(self.fd);
        if (self.thread) |t| t.join();
    }
};

const NavEndDriver = struct {
    failures: u32 = 0,
    buf: [512]u8 = undefined,

    fn check(self: *NavEndDriver, ok: bool, comptime what: []const u8) void {
        if (!ok) {
            std.debug.print("ended-navigation check failed: {s}\n", .{what});
            self.failures += 1;
        }
    }

    /// Page-world (or automation-world) eval; the answer is copied into
    /// `self.buf` ("" on failure).
    fn eval(self: *NavEndDriver, body: [:0]const u8, world: ?[*:0]const u8) []const u8 {
        var out: [*c]u8 = null;
        var err: [*c]u8 = null;
        const rc = c.zb_automation_eval_json(null, body.ptr, null, world, 5000, &out, &err);
        defer c.zb_automation_free(out);
        c.zb_automation_free(err);
        if (rc != c.ZB_AUTO_OK or out == null) return "";
        const text = std.mem.span(out);
        const n = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..n], text[0..n]);
        return self.buf[0..n];
    }

    fn token(self: *NavEndDriver, out: *[17]u8) ?[*:0]const u8 {
        const t = self.eval("return globalThis.__zbAutomation.documentToken;", c.ZB_AUTOMATION_WORLD);
        if (t.len != 16) return null;
        @memcpy(out[0..16], t);
        out[16] = 0;
        return @ptrCast(out);
    }

    fn waitNotLeaving(self: *NavEndDriver) bool {
        var waited: u32 = 0;
        while (waited < 8000) : (waited += 20) {
            const r = self.eval("return String(globalThis.__zbAutomation.inputAck().leaving);", c.ZB_AUTOMATION_WORLD);
            if (std.mem.eql(u8, r, "false")) return true;
            sleepMs(20);
        }
        return false;
    }

    /// The pending navigation's arrival number once the shell answered it,
    /// when it differs from `not` (0 = any).
    fn pendingId(self: *NavEndDriver, not: i64) ?i64 {
        var waited: u32 = 0;
        while (waited < 3000) : (waited += 10) {
            const r = self.eval("const p = globalThis.__zbAutomation.debugPendingNavigation(); return String(p && p.seq !== null ? p.seq : 0);", c.ZB_AUTOMATION_WORLD);
            const id = std.fmt.parseInt(i64, r, 10) catch 0;
            if (id != 0 and id != not) return id;
            sleepMs(10);
        }
        return null;
    }

    fn run(self: *NavEndDriver) void {
        const port = gtk_port.pagePort().?;
        _ = self.eval("return 1;", null);
        var tok: [17]u8 = undefined;

        // 1. The page cancels the navigation its Enter starts.
        _ = self.eval("window.cancelNav = true; return 0;", null);
        gtk_port.nativeClick(port.ptr, 120, 55, null, 5000) catch return self.check(false, "focus #q");
        const t1 = self.token(&tok) orelse return self.check(false, "token");
        var sent: usize = 0;
        const stopped = gtk_port.nativeText(port.ptr, "a\nb", std.mem.span(t1), 10_000, &sent);
        self.check(if (stopped) |_| false else |e| e == error.DocumentChanged, "the sequence whose Enter started a navigation stops");
        self.check(sent == 2, "'a' and Enter were sent, 'b' was not");
        self.check(std.mem.eql(u8, self.eval("return String(window.cancelled);", null), "1"), "the page cancelled the navigation");
        self.check(std.mem.eql(u8, self.eval("return location.pathname;", null), "/"), "the document stayed");
        var fresh: usize = 0;
        gtk_port.nativeText(port.ptr, "cd", std.mem.span(t1), 5000, &fresh) catch self.check(false, "a fresh native text after the cancelled navigation types");
        self.check(fresh == 2, "both characters of the fresh call were sent");
        self.check(std.mem.eql(u8, self.eval("return document.getElementById('q').value;", null), "acd"), "the fresh call typed into the same document");

        // 2. A navigation whose response is 204: the browser ends it, the
        // document stays.
        _ = self.eval("window.cancelNav = false; return 0;", null);
        gtk_port.nativeClick(port.ptr, 120, 115, null, 5000) catch return self.check(false, "focus #r");
        const t2 = self.token(&tok) orelse return self.check(false, "token");
        sent = 0;
        const stopped_204 = gtk_port.nativeText(port.ptr, "x\ny", std.mem.span(t2), 10_000, &sent);
        self.check(if (stopped_204) |_| false else |e| e == error.DocumentChanged, "the sequence whose Enter started a 204 navigation stops");
        self.check(sent == 2, "'x' and Enter were sent, 'y' was not");
        self.check(self.waitNotLeaving(), "the 204 navigation ended in the page");
        self.check(std.mem.eql(u8, self.eval("return location.pathname;", null), "/"), "the document stayed after the 204");
        fresh = 0;
        gtk_port.nativeText(port.ptr, "z", std.mem.span(t2), 5000, &fresh) catch self.check(false, "a fresh native text after the 204 navigation types");
        self.check(std.mem.eql(u8, self.eval("return document.getElementById('r').value;", null), "xz"), "the fresh call after the 204 typed into the same document");

        // 3. An older navigation's end never clears a newer one to the same
        // URL. Navigation A (held 1.5 s, then 204) gets arrival number a;
        // the page then starts B to the same URL, which supersedes A (A's
        // abort must not clear B) and gets b > a. An end the shell sent
        // before it heard of B leaves B pending; only B's own 204 clears it.
        gtk_port.nativeClick(port.ptr, 120, 175, null, 5000) catch return self.check(false, "focus #s");
        const t3 = self.token(&tok) orelse return self.check(false, "token");
        sent = 0;
        const stopped_hold = gtk_port.nativeText(port.ptr, "u\nv", std.mem.span(t3), 10_000, &sent);
        self.check(if (stopped_hold) |_| false else |e| e == error.DocumentChanged, "the sequence whose Enter started a held navigation stops");
        const id_a = self.pendingId(0) orelse return self.check(false, "navigation A got an arrival number");
        _ = self.eval("location.href = '/hold?s=u'; return 0;", null);
        const id_b = self.pendingId(id_a) orelse return self.check(false, "navigation B got its own arrival number");
        var stale: [96]u8 = undefined;
        const stale_body = std.fmt.bufPrintZ(&stale, "globalThis.__zbAutomation.navigationEnded({d}); return 0;", .{id_a}) catch return;
        _ = self.eval(stale_body, c.ZB_AUTOMATION_WORLD);
        self.check(std.mem.eql(u8, self.eval("return String(globalThis.__zbAutomation.inputAck().leaving);", c.ZB_AUTOMATION_WORLD), "true"), "A's late end leaves B pending");
        self.check(id_b > id_a, "B arrived after A");
        self.check(self.waitNotLeaving(), "B's own 204 ends it");
        self.check(std.mem.eql(u8, self.eval("return location.pathname;", null), "/"), "the document stayed after both held navigations");

        // 4. Same-URL supersession at once: C and D start in the same task,
        // before any arrival number is back. D keeps its own number, not
        // C's; an end sent before the shell heard of D leaves D pending;
        // D's own 204 clears it.
        const navs_before = self.eval("return String(globalThis.__zbAutomation.inputAck().navigations);", c.ZB_AUTOMATION_WORLD);
        const before = std.fmt.parseInt(i64, navs_before, 10) catch -1;
        _ = self.eval("location.href = '/hold?s=cd'; location.href = '/hold?s=cd'; return 0;", null);
        const id_d = self.pendingId(id_b) orelse return self.check(false, "navigation D got an arrival number");
        const navs_after = self.eval("return String(globalThis.__zbAutomation.inputAck().navigations);", c.ZB_AUTOMATION_WORLD);
        // Both C and D started and reported: D's number is two past B's,
        // so id_d - 1 is C's own arrival, not an older one.
        self.check((std.fmt.parseInt(i64, navs_after, 10) catch -1) == before + 2, "C and D both started a navigation");
        self.check(id_d == id_b + 2, "C and D both reported, D last");
        var stale_c: [96]u8 = undefined;
        const stale_c_body = std.fmt.bufPrintZ(&stale_c, "globalThis.__zbAutomation.navigationEnded({d}); return 0;", .{id_d - 1}) catch return;
        _ = self.eval(stale_c_body, c.ZB_AUTOMATION_WORLD);
        self.check(std.mem.eql(u8, self.eval("return String(globalThis.__zbAutomation.inputAck().leaving);", c.ZB_AUTOMATION_WORLD), "true"), "an older request's end leaves D pending");
        self.check(self.waitNotLeaving(), "D's own 204 ends it");
        self.check(std.mem.eql(u8, self.eval("return location.pathname;", null), "/"), "the document stayed after C and D");
        _ = c.zb_main_invoke_sync(LiveDriver.quit, null, 5000);
    }
};

test "native text: a navigation that ends without a new document stops one sequence, not later ones" {
    try skipUnlessGtk();
    if (std.c.getenv("DISPLAY") == null) return error.SkipZigTest;
    var server = try NoContentServer.open();
    try server.start();
    defer server.close();
    var uri_buf: [64]u8 = undefined;
    const uri = try std.fmt.bufPrintZ(&uri_buf, "http://127.0.0.1:{d}/", .{server.port});
    var driver: NavEndDriver = .{};

    gtk_port.installScript();
    defer c.zb_automation_set_script(null, 0);
    c.zb_automation_loop_mark(1);
    var watchdog: Watchdog = .{};
    const w = try std.Thread.spawn(.{}, Watchdog.run, .{ &watchdog, @as(u64, 60_000) });
    defer {
        watchdog.done.store(true, .release);
        w.join();
    }
    const t = try std.Thread.spawn(.{}, NavEndDriver.run, .{&driver});
    _ = c.zb_app_run(uri.ptr, 0, 0);
    t.join();
    try std.testing.expectEqual(@as(u32, 0), driver.failures);
    c.zb_automation_loop_mark(1);
}

// A navigation the shell's policy blocks (a file:// page posting to http)
// never replaces the document: once blocked, a fresh native text call in
// the same document types again, whatever order WebKit uses between the
// page's 'navigate' report and the policy decision.
const blocked_fixture =
    \\<!doctype html><html><head><title>Blocked</title></head><body>
    \\<form action="http://127.0.0.1:9/blocked"><input id="q" name="q" style="position:fixed;left:20px;top:40px;width:200px;height:30px"></form>
    \\</body></html>
;

const BlockedDriver = struct {
    nav: NavEndDriver = .{},

    fn run(self: *BlockedDriver) void {
        const d = &self.nav;
        const port = gtk_port.pagePort().?;
        _ = d.eval("return 1;", null);
        var tok: [17]u8 = undefined;
        gtk_port.nativeClick(port.ptr, 120, 55, null, 5000) catch return d.check(false, "focus #q");
        const t = d.token(&tok) orelse return d.check(false, "token");
        var sent: usize = 0;
        const typed = gtk_port.nativeText(port.ptr, "a\nb", std.mem.span(t), 10_000, &sent);
        // Stopped after Enter (the page saw the navigation start), or not
        // stopped at all (WebKit refused it before its 'navigate' event).
        const stopped_after_enter = if (typed) |_| false else |e| e == error.DocumentChanged and sent == 2;
        const not_started = if (typed) |_| sent == 3 else |_| false;
        d.check(stopped_after_enter or not_started, "the blocked submit either stops the sequence after Enter or never starts");
        d.check(d.waitNotLeaving(), "the blocked navigation is not pending");
        d.check(std.mem.eql(u8, d.eval("return location.protocol;", null), "file:"), "the document stayed");
        var fresh: usize = 0;
        gtk_port.nativeText(port.ptr, "c", std.mem.span(t), 5000, &fresh) catch d.check(false, "a fresh native text after the blocked navigation types");
        const value = d.eval("return document.getElementById('q').value;", null);
        d.check(std.mem.endsWith(u8, value, "c") and std.mem.startsWith(u8, value, "a"), "the fresh call typed into the same document");
        std.debug.print("blocked submit: {s}, sent {d}, value {s}\n", .{ if (stopped_after_enter) "stopped after Enter" else "never started", sent, value });

        // A script navigation fires 'navigate' (and reports it) before the
        // policy decision blocks it: the end the shell sends at the block
        // must already cover that report.
        const navs_before = std.fmt.parseInt(i64, d.eval("return String(globalThis.__zbAutomation.inputAck().navigations);", c.ZB_AUTOMATION_WORLD), 10) catch -1;
        _ = d.eval("location.href = 'http://127.0.0.1:9/blocked'; return 0;", null);
        d.check(d.waitNotLeaving(), "the blocked script navigation is not pending");
        const navs_after = std.fmt.parseInt(i64, d.eval("return String(globalThis.__zbAutomation.inputAck().navigations);", c.ZB_AUTOMATION_WORLD), 10) catch -1;
        d.check(navs_after == navs_before + 1, "the blocked script navigation started in the page");
        d.check(std.mem.eql(u8, d.eval("return location.protocol;", null), "file:"), "the document stayed after the blocked script navigation");
        gtk_port.nativeText(port.ptr, "d", std.mem.span(t), 5000, &fresh) catch d.check(false, "native text after the blocked script navigation types");
        d.check(std.mem.endsWith(u8, d.eval("return document.getElementById('q').value;", null), "cd"), "it typed into the same document");
        _ = c.zb_main_invoke_sync(LiveDriver.quit, null, 5000);
    }
};

test "native text: a navigation blocked by policy does not refuse later typing" {
    try skipUnlessGtk();
    if (std.c.getenv("DISPLAY") == null) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = gfile.g_dir_make_tmp("zb-blocked-XXXXXX", null) orelse return error.TmpDirFailed;
    defer gfile.g_free(dir);
    const path = try std.fmt.allocPrintSentinel(arena, "{s}/blocked.html", .{dir}, 0);
    try std.testing.expect(gfile.g_file_set_contents(path, blocked_fixture.ptr, blocked_fixture.len, null) != 0);
    const raw = gfile.g_filename_to_uri(path, null, null) orelse return error.UriFailed;
    defer gfile.g_free(raw);
    const uri = try arena.dupeZ(u8, std.mem.span(raw));
    var driver: BlockedDriver = .{};

    gtk_port.installScript();
    defer c.zb_automation_set_script(null, 0);
    c.zb_automation_loop_mark(1);
    var watchdog: Watchdog = .{};
    const w = try std.Thread.spawn(.{}, Watchdog.run, .{ &watchdog, @as(u64, 60_000) });
    defer {
        watchdog.done.store(true, .release);
        w.join();
    }
    const t = try std.Thread.spawn(.{}, BlockedDriver.run, .{&driver});
    _ = c.zb_app_run(uri.ptr, 0, 0);
    t.join();
    try std.testing.expectEqual(@as(u32, 0), driver.nav.failures);
    c.zb_automation_loop_mark(1);
}

// N17: file inputs through WebKit's file chooser.
const files_fixture =
    \\<!doctype html><html><head><title>Files</title></head><body>
    \\<input type="file" id="multi" multiple>
    \\<input type="file" id="one" style="display:none">
    \\<input type="file" id="off" disabled>
    \\<input type="text" id="text">
    \\<script>window.fileLog = [];
    \\document.addEventListener('change', function (e) {
    \\  if (e.target.type !== 'file') return;
    \\  window.fileLog.push(e.target.id + ':' + e.isTrusted + ':' + Array.from(e.target.files).map(function (f) { return f.name + '/' + f.size; }).join(','));
    \\}, true);</script>
    \\</body></html>
;

const FilesDriver = struct {
    nav: NavEndDriver = .{},
    a: [:0]const u8,
    b: [:0]const u8,
    dir: [:0]const u8,

    const handle_body = "return JSON.stringify(await globalThis.__zbAutomation.handle(JSON.parse(arg)));";

    fn set(self: *FilesDriver, arg: [:0]const u8, body: [:0]const u8, paths: []const [*:0]const u8, timeout_ms: c_uint, out: *[512]u8) c_int {
        _ = self;
        var result: [*c]u8 = null;
        var err: [*c]u8 = null;
        const rc = c.zb_set_input_files(null, body.ptr, arg.ptr, @ptrCast(paths.ptr), @intCast(paths.len), timeout_ms, &result, &err);
        c.zb_automation_free(err);
        defer c.zb_automation_free(result);
        @memset(out, 0);
        if (result != null) {
            const text = std.mem.span(result);
            @memcpy(out[0..@min(text.len, out.len - 1)], text[0..@min(text.len, out.len - 1)]);
        }
        return rc;
    }

    fn log(self: *FilesDriver) []const u8 {
        return self.nav.eval("return window.fileLog.join('|');", null);
    }

    fn check(self: *FilesDriver, ok: bool, comptime what: []const u8) void {
        if (!ok) {
            std.debug.print("set-files check failed: {s}\n", .{what});
            self.nav.failures += 1;
        }
    }

    fn run(self: *FilesDriver) void {
        const d = &self.nav;
        _ = d.eval("return 1;", null);
        var out: [512]u8 = undefined;
        const both = [_][*:0]const u8{ self.a.ptr, self.b.ptr };
        const one = [_][*:0]const u8{self.a.ptr};

        // A visible multiple input takes both files: trusted change, names and sizes.
        var rc = self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#multi\",\"count\":2}", handle_body, &both, 5000, &out);
        self.check(rc == c.ZB_AUTO_OK and std.mem.startsWith(u8, &out, "{\"ok\":true"), "both files set on the multiple input");
        self.check(std.mem.eql(u8, self.log(), "multi:true:a.txt/5,b.bin/8"), "the page saw a trusted change with both files");

        // A hidden single input takes one.
        _ = d.eval("window.fileLog = []; return 0;", null);
        rc = self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#one\",\"count\":1}", handle_body, &one, 5000, &out);
        self.check(rc == c.ZB_AUTO_OK and std.mem.startsWith(u8, &out, "{\"ok\":true"), "one file set on the hidden input");
        self.check(std.mem.eql(u8, self.log(), "one:true:a.txt/5"), "the hidden input got a trusted change");

        // Refusals by the op: nothing clicked, nothing changed.
        _ = d.eval("window.fileLog = []; return 0;", null);
        rc = self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#one\",\"count\":2}", handle_body, &both, 5000, &out);
        self.check(rc == c.ZB_AUTO_OK and std.mem.indexOf(u8, &out, "not_multiple") != null, "two files for a single input are refused");
        rc = self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#text\",\"count\":1}", handle_body, &one, 5000, &out);
        self.check(rc == c.ZB_AUTO_OK and std.mem.indexOf(u8, &out, "not_file_input") != null, "a text input is refused");
        rc = self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#off\",\"count\":1}", handle_body, &one, 5000, &out);
        self.check(rc == c.ZB_AUTO_OK and std.mem.indexOf(u8, &out, "element_disabled") != null, "a disabled input is refused");

        // Bad paths: refused before anything runs.
        const relative = [_][*:0]const u8{"a.txt"};
        const missing = [_][*:0]const u8{"/nonexistent/zb-file"};
        const directory = [_][*:0]const u8{self.dir.ptr};
        self.check(self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#multi\",\"count\":1}", handle_body, &relative, 5000, &out) == c.ZB_AUTO_ERR_BAD_FILE, "a relative path is refused");
        self.check(self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#multi\",\"count\":1}", handle_body, &missing, 5000, &out) == c.ZB_AUTO_ERR_BAD_FILE, "a missing file is refused");
        self.check(self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#multi\",\"count\":1}", handle_body, &directory, 5000, &out) == c.ZB_AUTO_ERR_BAD_FILE, "a directory is refused");

        // Backstop: a body that clicks a single input directly with two
        // files; the shim cancels the chooser.
        rc = self.set("{}", "globalThis.webkit.messageHandlers.zbFiles.postMessage(JSON.parse(arg).token); document.getElementById('one').click(); return JSON.stringify({ ok: true });", &both, 5000, &out);
        self.check(rc == c.ZB_AUTO_ERR_BAD_FILE, "the shim refuses two files for a single-file chooser");
        self.check(std.mem.eql(u8, self.log(), ""), "no refusal changed any input");

        // A job whose click never happens times out and does not stay armed:
        // the next one works.
        rc = self.set("{}", "return JSON.stringify({ ok: true });", &one, 300, &out);
        self.check(rc == c.ZB_AUTO_ERR_TIMEOUT, "no chooser before the deadline is a timeout");
        sleepMs(100);
        rc = self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#multi\",\"count\":1}", handle_body, &one, 5000, &out);
        self.check(rc == c.ZB_AUTO_OK, "a later set-files call is not blocked by the timed-out one");
        self.check(std.mem.eql(u8, self.log(), "multi:true:a.txt/5"), "and its file arrives");

        // The op's answer withheld past the deadline after the chooser was
        // answered: a bounded, defined outcome, and the files are applied
        // exactly once.
        _ = d.eval("window.fileLog = []; return 0;", null);
        const started = monotonicMs();
        rc = self.set("{}", "globalThis.webkit.messageHandlers.zbFiles.postMessage(JSON.parse(arg).token); document.getElementById('multi').click(); await new Promise(function (r) { setTimeout(r, 2000); }); return JSON.stringify({ ok: true });", &both, 500, &out);
        self.check(rc == c.ZB_AUTO_ERR_FILES_UNCONFIRMED, "chosen but unconfirmed by the deadline is FILES_UNCONFIRMED");
        self.check(monotonicMs() - started < 1500, "the call ends at its deadline, not when the page answers");
        sleepMs(2500);
        self.check(std.mem.eql(u8, self.log(), "multi:true:a.txt/5,b.bin/8"), "the files were applied once");

        // A chooser the op did not open (page script clicks another input
        // after the job is armed, before the op runs) never gets the files.
        // WebKit keeps one chooser per page, so the op's own click opens
        // none while that one is pending: the call times out, and no input
        // received anything.
        _ = d.eval("window.fileLog = []; return 0;", null);
        const unmatched_before = c.zb_automation_debug_files_unmatched_hits();
        c.zb_automation_debug_files_preclick("document.getElementById('one').click()");
        rc = self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#multi\",\"count\":1}", handle_body, &one, 1000, &out);
        c.zb_automation_debug_files_preclick(null);
        self.check(c.zb_automation_debug_files_unmatched_hits() == unmatched_before + 1, "the page's chooser was not this job's");
        self.check(rc == c.ZB_AUTO_ERR_TIMEOUT, "the op's click opened no chooser of its own: timeout");
        sleepMs(300);
        self.check(std.mem.eql(u8, self.log(), ""), "no input received the files");
        // And the next call works normally.
        rc = self.set("{\"op\":\"chooseFiles\",\"selector\":\"css=#multi\",\"count\":1}", handle_body, &one, 5000, &out);
        self.check(rc == c.ZB_AUTO_OK and std.mem.eql(u8, self.log(), "multi:true:a.txt/5"), "a later call sets the file");
        _ = c.zb_main_invoke_sync(LiveDriver.quit, null, 5000);
    }
};

test "set input files answers the file chooser the input's click opens" {
    try skipUnlessGtk();
    if (std.c.getenv("DISPLAY") == null) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir_raw = gfile.g_dir_make_tmp("zb-files-XXXXXX", null) orelse return error.TmpDirFailed;
    defer gfile.g_free(dir_raw);
    const dir = try arena.dupeZ(u8, std.mem.span(dir_raw));
    const page = try std.fmt.allocPrintSentinel(arena, "{s}/files.html", .{dir}, 0);
    const a = try std.fmt.allocPrintSentinel(arena, "{s}/a.txt", .{dir}, 0);
    const b = try std.fmt.allocPrintSentinel(arena, "{s}/b.bin", .{dir}, 0);
    try std.testing.expect(gfile.g_file_set_contents(page, files_fixture.ptr, files_fixture.len, null) != 0);
    try std.testing.expect(gfile.g_file_set_contents(a, "hello", 5, null) != 0);
    try std.testing.expect(gfile.g_file_set_contents(b, "abcdefgh", 8, null) != 0);
    const raw = gfile.g_filename_to_uri(page, null, null) orelse return error.UriFailed;
    defer gfile.g_free(raw);
    const uri = try arena.dupeZ(u8, std.mem.span(raw));
    var driver: FilesDriver = .{ .a = a, .b = b, .dir = dir };

    gtk_port.installScript();
    defer c.zb_automation_set_script(null, 0);
    // No GTK dialog in tests: unclaimed choosers are cancelled and counted.
    c.zb_automation_debug_files_unmatched(1);
    defer c.zb_automation_debug_files_unmatched(0);
    c.zb_automation_loop_mark(1);
    var watchdog: Watchdog = .{};
    const w = try std.Thread.spawn(.{}, Watchdog.run, .{ &watchdog, @as(u64, 60_000) });
    defer {
        watchdog.done.store(true, .release);
        w.join();
    }
    const t = try std.Thread.spawn(.{}, FilesDriver.run, .{&driver});
    _ = c.zb_app_run(uri.ptr, 0, 0);
    t.join();
    try std.testing.expectEqual(@as(u32, 0), driver.nav.failures);
    c.zb_automation_loop_mark(1);
}
