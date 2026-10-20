//! S7a (chat-drawer plan section 10, S7, rev 16.20.32): shared test helpers for the
//! in-process core and broker tests: two fake windows whose pages say different things,
//! a server built on them, and the socket's framing.
const std = @import("std");
const automation_server = @import("automation_server");
const page_port = automation_server.automation.page_port;

const net = std.Io.net;
const testing = std.testing;

/// A format: the page's greeting as automation.js answers dom.getText.
pub const greeting_reply = "{{\"ok\":true,\"value\":{{\"text\":\"Hello from page {d}\"}}}}";

/// One fake window. Every eval answers `reply` (or the page's greeting), after `delay_ms`.
pub const Window = struct {
    pages: *Pages,
    id: page_port.WindowId,
    reply: ?[]const u8 = null,
    delay_ms: u64 = 0,
    evals: std.atomic.Value(u32) = .init(0),
    /// The thread the last eval ran on.
    eval_thread: std.atomic.Value(std.Thread.Id) = .init(0),
    /// While set, an eval waits (after counting itself in `in_flight`) until it is cleared.
    hold: std.atomic.Value(bool) = .init(false),
    in_flight: std.atomic.Value(u32) = .init(0),
    max_in_flight: std.atomic.Value(u32) = .init(0),

    pub fn port(self: *Window) page_port.PagePort {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = page_port.PagePort.VTable{
        .evalJson = evalJson,
        .navigate = navigate,
        .reload = reload,
        .url = url,
        .title = title,
        .forWindow = forWindow,
        .listWindows = listWindows,
    };

    fn evalJson(ptr: *anyopaque, gpa: std.mem.Allocator, _: page_port.World, _: []const u8, _: []const u8, _: u64) page_port.PortError![]u8 {
        const self: *Window = @ptrCast(@alignCast(ptr));
        self.eval_thread.store(std.Thread.getCurrentId(), .release);
        const now_in_flight = self.pages.in_flight.fetchAdd(1, .acq_rel) + 1;
        defer _ = self.pages.in_flight.fetchSub(1, .acq_rel);
        _ = self.pages.max_in_flight.fetchMax(now_in_flight, .acq_rel);
        _ = self.in_flight.fetchAdd(1, .acq_rel);
        defer _ = self.in_flight.fetchSub(1, .acq_rel);
        _ = self.max_in_flight.fetchMax(self.in_flight.load(.acquire), .acq_rel);
        while (self.hold.load(.acquire)) testing.io.sleep(.fromMilliseconds(2), .awake) catch {};
        if (self.delay_ms > 0) testing.io.sleep(.fromMilliseconds(@intCast(self.delay_ms)), .awake) catch {};
        _ = self.evals.fetchAdd(1, .acq_rel);
        if (self.reply) |reply| return gpa.dupe(u8, reply);
        return std.fmt.allocPrint(gpa, greeting_reply, .{self.id}) catch error.OutOfMemory;
    }
    fn navigate(_: *anyopaque, _: []const u8, _: u64) page_port.PortError!void {}
    fn reload(_: *anyopaque, _: u64) page_port.PortError!void {}
    fn url(ptr: *anyopaque, gpa: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return std.fmt.allocPrint(gpa, "file:///fixture/page{d}.html", .{self.id}) catch error.OutOfMemory;
    }
    fn title(ptr: *anyopaque, gpa: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
        const self: *Window = @ptrCast(@alignCast(ptr));
        return std.fmt.allocPrint(gpa, "Page {d}", .{self.id}) catch error.OutOfMemory;
    }
    /// Both windows, each with its own URL and title (page.list, page.health).
    fn listWindows(ptr: *anyopaque, gpa: std.mem.Allocator, _: u64) page_port.PortError![]page_port.WindowInfo {
        const self: *Window = @ptrCast(@alignCast(ptr));
        const list = gpa.alloc(page_port.WindowInfo, self.pages.windows.len) catch return error.OutOfMemory;
        for (&self.pages.windows, 0..) |*w, i| {
            list[i] = .{
                .id = w.id,
                .url = std.fmt.allocPrint(gpa, "file:///fixture/page{d}.html", .{w.id}) catch return error.OutOfMemory,
                .title = std.fmt.allocPrint(gpa, "Page {d}", .{w.id}) catch return error.OutOfMemory,
                .primary = w.id == 1,
            };
        }
        return list;
    }
    fn forWindow(ptr: *anyopaque, id: page_port.WindowId) page_port.PortError!page_port.PagePort {
        const self: *Window = @ptrCast(@alignCast(ptr));
        if (id < 1 or id > self.pages.windows.len) return error.NoPage;
        return self.pages.windows[id - 1].port();
    }
};

/// Windows 1 and 2; window 1 is the primary port.
pub const Pages = struct {
    windows: [2]Window,
    /// Evals running in either window, now and at most.
    in_flight: std.atomic.Value(u32) = .init(0),
    max_in_flight: std.atomic.Value(u32) = .init(0),

    pub fn init(self: *Pages) void {
        self.* = .{ .windows = .{ .{ .pages = self, .id = 1 }, .{ .pages = self, .id = 2 } } };
    }

    pub fn evals(self: *Pages) u32 {
        return self.windows[0].evals.load(.acquire) + self.windows[1].evals.load(.acquire);
    }
};

/// A server on `pages` with the socket and token sidecar paths set (`tag` keeps them apart).
pub const Fixture = struct {
    pages: Pages = undefined,
    socket_path: []u8,
    token_path: []u8,
    server: automation_server.AutomationApiServer,

    pub fn create(comptime tag: []const u8, token: []const u8) !*Fixture {
        const self = try testing.allocator.create(Fixture);
        errdefer testing.allocator.destroy(self);
        self.pages.init();
        self.socket_path = try std.fmt.allocPrint(testing.allocator, "/tmp/zigbrowser-s7a-" ++ tag ++ "-{x}.sock", .{testing.random_seed});
        errdefer testing.allocator.free(self.socket_path);
        self.token_path = try std.fmt.allocPrint(testing.allocator, "{s}.token", .{self.socket_path});
        errdefer testing.allocator.free(self.token_path);
        remove(self.socket_path);
        remove(self.token_path);
        self.server = try automation_server.AutomationApiServer.init(testing.allocator, testing.io, .{
            .enabled = true,
            .socket_path = self.socket_path,
            .token = token,
            .token_file_path = self.token_path,
            .page_port = self.pages.windows[0].port(),
        });
        return self;
    }

    pub fn connect(self: *Fixture) !net.Stream {
        const address = try net.UnixAddress.init(self.socket_path);
        return address.connect(testing.io);
    }

    pub fn destroy(self: *Fixture) void {
        self.server.deinit();
        remove(self.socket_path);
        remove(self.token_path);
        testing.allocator.free(self.socket_path);
        testing.allocator.free(self.token_path);
        testing.allocator.destroy(self);
    }
};

pub fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(testing.io, path, .{}) catch return false;
    return true;
}

fn remove(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(testing.io, path) catch {};
}

pub fn roundTrip(stream: net.Stream, request: []const u8) ![]u8 {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(request.len), .big);
    var writer_buf: [1024]u8 = undefined;
    var writer = stream.writer(testing.io, &writer_buf);
    try writer.interface.writeAll(&header);
    try writer.interface.writeAll(request);
    try writer.interface.flush();

    var reader_buf: [1024]u8 = undefined;
    var reader = stream.reader(testing.io, &reader_buf);
    try reader.interface.readSliceAll(&header);
    const payload = try testing.allocator.alloc(u8, std.mem.readInt(u32, &header, .big));
    errdefer testing.allocator.free(payload);
    try reader.interface.readSliceAll(payload);
    return payload;
}

pub fn nowMs() i64 {
    return std.Io.Clock.now(.awake, testing.io).toMilliseconds();
}
