//! The S8a `options.expect` tests' fake (chat-drawer plan, "S8 in detail" decision 2): two windows
//! behind one PagePort, every page operation counted per window, driven through
//! `AutomationApiServer.callInProcess` (the broker's entry: the real router, queue and engine).

const std = @import("std");
const automation_server = @import("automation_server");
const page_port = automation_server.automation.page_port;

const testing = std.testing;
const gpa = testing.allocator;

/// Two windows: 1 the primary fixture page, 2 a shop page. Every port reads the same list.
pub const World = struct {
    ports: [2]Page = .{ .{ .id = 1 }, .{ .id = 2 } },
    urls: [2][]const u8 = .{ "file:///fixture/index.html", "https://shop.example/item/7" },
    load_serials: [2]std.atomic.Value(u64) = .{ .init(3), .init(4) },
    dialog_open: [2]bool = .{ false, false },
    crashed: [2]bool = .{ false, false },
    list_calls: std.atomic.Value(u32) = .init(0),
    /// While true, listWindows blocks (and sets `list_held`): the phase-A read held.
    list_hold: std.atomic.Value(bool) = .init(false),
    list_held: std.atomic.Value(bool) = .init(false),
    /// listWindows takes this long (a slow registry read that uses up the command's time).
    list_delay_ms: u64 = 0,

    pub fn init(self: *World) void {
        for (&self.ports) |*p| p.world = self;
    }

    pub fn ops(self: *const World) u32 {
        var n: u32 = 0;
        for (&self.ports) |*p| n += p.ops();
        return n;
    }
};

pub const Page = struct {
    id: page_port.WindowId,
    world: *World = undefined,
    evals: std.atomic.Value(u32) = .init(0),
    navigates: std.atomic.Value(u32) = .init(0),
    reloads: std.atomic.Value(u32) = .init(0),
    natives: std.atomic.Value(u32) = .init(0),
    hold: std.atomic.Value(bool) = .init(false),
    held: std.atomic.Value(bool) = .init(false),
    /// The timeout the last page operation was given (eval, navigate or reload).
    last_timeout_ms: std.atomic.Value(u64) = .init(0),

    pub fn ops(self: *const Page) u32 {
        return self.evals.load(.acquire) + self.navigates.load(.acquire) + self.reloads.load(.acquire) + self.natives.load(.acquire);
    }

    pub fn port(self: *Page) page_port.PagePort {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn from(ptr: *anyopaque) *Page {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable = page_port.PagePort.VTable{
        .evalJson = evalJson,
        .navigate = navigate,
        .reload = reload,
        .url = url,
        .title = title,
        .listWindows = listWindows,
        .forWindow = forWindow,
        .nativeClick = nativeClick,
        .nativeKey = nativeKey,
        .nativeText = nativeText,
        .nativeMove = nativeMove,
    };

    fn evalJson(ptr: *anyopaque, alloc: std.mem.Allocator, _: page_port.World, _: []const u8, arg: []const u8, timeout_ms: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        self.last_timeout_ms.store(timeout_ms, .release);
        while (self.hold.load(.acquire)) {
            self.held.store(true, .release);
            testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        _ = self.evals.fetchAdd(1, .acq_rel);
        // Native input first locates its target; answer with a point.
        if (std.mem.indexOf(u8, arg, "\"op\":\"locate\"") != null) {
            return alloc.dupe(u8, "{\"ok\":true,\"value\":{\"x\":10,\"y\":10,\"document\":\"d1\"}}");
        }
        return alloc.dupe(u8, "{\"ok\":true,\"value\":{\"ok\":true}}");
    }
    fn navigate(ptr: *anyopaque, _: []const u8, timeout_ms: u64) page_port.PortError!void {
        from(ptr).last_timeout_ms.store(timeout_ms, .release);
        _ = from(ptr).navigates.fetchAdd(1, .acq_rel);
    }
    fn reload(ptr: *anyopaque, timeout_ms: u64) page_port.PortError!void {
        from(ptr).last_timeout_ms.store(timeout_ms, .release);
        _ = from(ptr).reloads.fetchAdd(1, .acq_rel);
    }
    fn url(ptr: *anyopaque, alloc: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
        const self = from(ptr);
        return alloc.dupe(u8, self.world.urls[self.id - 1]);
    }
    fn title(_: *anyopaque, alloc: std.mem.Allocator, _: u64) page_port.PortError![]u8 {
        return alloc.dupe(u8, "Fixture");
    }
    fn listWindows(ptr: *anyopaque, alloc: std.mem.Allocator, _: u64) page_port.PortError![]page_port.WindowInfo {
        const world = from(ptr).world;
        _ = world.list_calls.fetchAdd(1, .acq_rel);
        while (world.list_hold.load(.acquire)) {
            world.list_held.store(true, .release);
            testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        if (world.list_delay_ms > 0) testing.io.sleep(.fromMilliseconds(@intCast(world.list_delay_ms)), .awake) catch {};
        var list: std.ArrayListUnmanaged(page_port.WindowInfo) = .empty;
        errdefer {
            for (list.items) |w| {
                alloc.free(w.url);
                alloc.free(w.title);
            }
            list.deinit(alloc);
        }
        for (0..2) |i| {
            try list.append(alloc, .{
                .id = @intCast(i + 1),
                .url = try alloc.dupe(u8, world.urls[i]),
                .title = try alloc.dupe(u8, "Fixture"),
                .primary = i == 0,
                .opener = if (i == 0) null else 1,
                .terminated = if (world.crashed[i]) .crashed else null,
                .dialog_open = world.dialog_open[i],
                .load_serial = world.load_serials[i].load(.acquire),
            });
        }
        return list.toOwnedSlice(alloc);
    }
    fn forWindow(ptr: *anyopaque, id: page_port.WindowId) page_port.PortError!page_port.PagePort {
        const world = from(ptr).world;
        if (id < 1 or id > world.ports.len) return error.NoPage;
        return world.ports[id - 1].port();
    }
    fn nativeClick(ptr: *anyopaque, _: f64, _: f64, _: ?[]const u8, _: u64) page_port.PortError!void {
        _ = from(ptr).natives.fetchAdd(1, .acq_rel);
    }
    fn nativeMove(ptr: *anyopaque, _: f64, _: f64, _: ?[]const u8, _: u64) page_port.PortError!void {
        _ = from(ptr).natives.fetchAdd(1, .acq_rel);
    }
    fn nativeKey(ptr: *anyopaque, _: []const u8, _: u8, _: ?[]const u8, _: u64) page_port.PortError!void {
        _ = from(ptr).natives.fetchAdd(1, .acq_rel);
    }
    fn nativeText(ptr: *anyopaque, text: []const u8, _: ?[]const u8, _: u64, sent: *usize) page_port.PortError!void {
        _ = from(ptr).natives.fetchAdd(1, .acq_rel);
        sent.* = text.len;
    }
};

pub const Harness = struct {
    world: World = .{},
    server: automation_server.AutomationApiServer,

    pub fn start() !*Harness {
        const self = try gpa.create(Harness);
        errdefer gpa.destroy(self);
        self.world = .{};
        self.world.init();
        self.server = try automation_server.AutomationApiServer.init(gpa, testing.io, .{
            .enabled = true,
            .socket_path = "",
            .token = "",
            .page_port = self.world.ports[0].port(),
            .pacing_state_path = "",
        });
        try self.server.startCore();
        return self;
    }

    pub fn deinit(self: *Harness) void {
        self.server.deinit();
        gpa.destroy(self);
    }

    pub fn call(self: *Harness, method: []const u8, params: []const u8) !Reply {
        const raw = try self.server.callInProcess(gpa, method, params);
        defer gpa.free(raw);
        return Reply.of(raw);
    }
};

pub const Reply = struct {
    code: ?i64 = null,
    reason_buf: [48]u8 = undefined,
    reason_len: usize = 0,

    pub fn reason(self: *const Reply) []const u8 {
        return self.reason_buf[0..self.reason_len];
    }

    pub fn of(raw: []const u8) !Reply {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, raw, .{});
        defer parsed.deinit();
        var out = Reply{};
        const err = parsed.value.object.get("error") orelse return out;
        out.code = err.object.get("code").?.integer;
        if (err.object.get("data")) |data| if (data == .object) if (data.object.get("reason")) |r| if (r == .string) {
            out.reason_len = @min(r.string.len, out.reason_buf.len);
            @memcpy(out.reason_buf[0..out.reason_len], r.string[0..out.reason_len]);
        };
        return out;
    }
};

pub const expect_ok = "\"options\":{\"expect\":{\"origin\":\"https://shop.example\",\"load_serial\":4}}";

/// The acting verbs, each with a matching expectation on window 2.
pub const acting = [_]struct { method: []const u8, args: []const u8 }{
    .{ .method = "dom.click", .args = "\"selector\":\"css=#buy\"" },
    .{ .method = "dom.fill", .args = "\"selector\":\"css=#q\",\"value\":\"v\"" },
    .{ .method = "dom.type", .args = "\"selector\":\"css=#q\",\"text\":\"hi\"" },
    .{ .method = "dom.press", .args = "\"selector\":\"css=#q\",\"key\":\"Enter\"" },
    .{ .method = "dom.selectOption", .args = "\"selector\":\"css=#s\",\"value\":\"a\"" },
    .{ .method = "page.navigate", .args = "\"url\":\"https://shop.example/next\"" },
    .{ .method = "page.reload", .args = "" },
};

pub fn paramsFor(buf: []u8, args: []const u8, window: []const u8, expect: []const u8) ![]const u8 {
    const sep = if (args.len > 0) "," else "";
    return std.fmt.bufPrint(buf, "{{{s}{s}\"window_id\":\"{s}\",{s}}}", .{ args, sep, window, expect });
}
