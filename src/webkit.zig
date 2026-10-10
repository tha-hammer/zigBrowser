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

    // After the loop has ended, new submissions fail fast too.
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_ERR_NO_LOOP), c.zb_main_invoke_sync(CountingJob.run, &job, 10_000));
    TestLoop.pumpFor(10);
    try std.testing.expectEqual(@as(u32, 0), job.runs.load(.acquire));
    c.zb_automation_loop_mark(1);
}

// --- Live WebView bridge test (needs a display; run under xvfb-run) ---
//
// The test thread runs zb_app_run (the GTK main loop) on a file:// fixture;
// a driver thread plays the automation server and exercises every op.

const gtk_port = @import("automation_gtk_port.zig");

test {
    _ = gtk_port;
}

const gfile = struct {
    extern fn g_dir_make_tmp(tmpl: ?[*:0]const u8, err: ?*?*anyopaque) ?[*:0]u8;
    extern fn g_file_set_contents(filename: [*:0]const u8, contents: [*]const u8, length: isize, err: ?*?*anyopaque) c_int;
    extern fn g_filename_to_uri(filename: [*:0]const u8, hostname: ?[*:0]const u8, err: ?*?*anyopaque) ?[*:0]u8;
    extern fn g_free(mem: ?*anyopaque) void;
    extern fn gtk_main_quit() void;
};

const fixture_a =
    \\<!doctype html><html><head><title>Fixture A</title></head><body>
    \\<p id="msg">Hello fixture</p>
    \\<script>window.pageMarker = 7; setTimeout(function () {
    \\  var p = document.createElement('p'); p.id = 'late'; p.textContent = 'late';
    \\  document.body.appendChild(p); }, 300);</script>
    \\</body></html>
;
const fixture_b =
    \\<!doctype html><html><head><title>Fixture B</title></head><body><p id="msg">Page B</p></body></html>
;

const LiveDriver = struct {
    allocator: std.mem.Allocator,
    uri_a: [:0]const u8,
    uri_b: [:0]const u8,
    uri_missing: [:0]const u8,
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

    fn quit(_: ?*anyopaque) callconv(.c) void {
        gfile.gtk_main_quit();
    }

    fn run(self: *LiveDriver) void {
        const automation_world: [:0]const u8 = c.ZB_AUTOMATION_WORLD;
        var rc: c_int = 0;
        var err: [*c]u8 = null;

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

        r = self.eval(null, "await new Promise(function () {});", null, null, 150);
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

        _ = c.zb_main_invoke_sync(quit, null, 5000);
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
    };

    gtk_port.installScript();
    defer c.zb_automation_set_script(null, 0);

    const t = try std.Thread.spawn(.{}, LiveDriver.run, .{&driver});
    _ = c.zb_app_run(driver.uri_a.ptr, 0, 0);
    t.join();

    for (driver.failures.items) |f| std.debug.print("live bridge check failed: {s}\n", .{f});
    try std.testing.expectEqual(@as(usize, 0), driver.failures.items.len);

    // After the loop has ended there is no primary window and ops fail fast.
    try std.testing.expect(c.zb_automation_main_window() == null);
    var out: [*c]u8 = null;
    try std.testing.expectEqual(@as(c_int, c.ZB_AUTO_ERR_NO_LOOP), c.zb_automation_get_url(null, 5000, &out));
    c.zb_automation_loop_mark(1);
}
