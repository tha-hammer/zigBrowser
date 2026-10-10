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
    \\  nativeLog.push('keydown:' + e.key + ':' + e.isTrusted + ':' + e.shiftKey); });</script>
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
    \\<!doctype html><html><head><title>Fixture B</title></head><body><p id="msg">Page B</p></body></html>
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
        var waited: u32 = 0;
        while (waited < 3000) : (waited += 10) {
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
        var rc = c.zb_native_click(null, button[0], button[1], 1, 5000, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK, "native click returns OK");
        self.check(self.waitInputAck(base, 1, 0), "page acknowledged the native click");
        self.check(std.mem.eql(u8, self.nativeLog(), "mousedown:true,mouseup:true,click:true"), "native click is trusted and ordered");

        const input = self.center("ni") orelse return self.check(false, "input center");
        _ = self.eval(null, "nativeLog.length = 0; return 0;", null, null, 5000);
        base = self.inputAck() orelse return self.check(false, "inputAck available");
        rc = c.zb_native_click(null, input[0], input[1], 1, 5000, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(self.waitInputAck(base, 1, 0), "page acknowledged the focusing click");
        var releases: c_int = 0;
        base = self.inputAck() orelse return self.check(false, "inputAck available");
        rc = c.zb_native_text(null, "hi", 5000, &releases, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK and releases == 2, "native text returns OK with 2 releases");
        self.check(self.waitInputAck(base, 0, releases), "page acknowledged the typed keys");
        const typed = self.eval(null, "return document.getElementById('ni').value;", null, null, 5000);
        self.check(eq(typed.out, "hi"), "native text typed into the focused input");

        base = self.inputAck() orelse return self.check(false, "inputAck available");
        rc = c.zb_native_key(null, "a", c.ZB_NATIVE_MOD_SHIFT, 5000, &releases, &err);
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_OK and releases == 2, "native Shift+a returns OK with 2 releases");
        var more: c_int = 0;
        rc = c.zb_native_key(null, "Enter", 0, 5000, &more, &err);
        c.zb_automation_free(err);
        self.check(rc == c.ZB_AUTO_OK and more == 1, "native Enter returns OK with 1 release");
        self.check(self.waitInputAck(base, 0, releases + more), "page acknowledged Shift+a and Enter");
        const after = self.eval(null, "return document.getElementById('ni').value;", null, null, 5000);
        self.check(eq(after.out, "hiA"), "Shift+a typed an upper-case A");
        self.check(eq(self.nativeLog(), "keydown:h:true:false,keydown:i:true:false,keydown:Shift:true:true,keydown:A:true:true,keydown:Enter:true:false"), "native keys are trusted with key names and shift state");

        // Long text is bounded by the deadline: one GTK-thread step per
        // character, so it stops early instead of holding the GTK thread.
        const long_text = "x" ** 2000;
        var long_releases: c_int = 0;
        const long_start = monotonicMs();
        rc = c.zb_native_text(null, long_text, 50, &long_releases, &err);
        const long_ms = monotonicMs() - long_start;
        c.zb_automation_free(err);
        err = null;
        self.check(rc == c.ZB_AUTO_ERR_TIMEOUT, "long native text times out at its deadline");
        self.check(long_ms < 500, "long native text returned promptly after the deadline");
        self.check(long_releases > 0 and long_releases < 2000, "long native text was only partially sent");
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
    try delay_server.start();
    defer delay_server.close();
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
