//! S1.4 (chat-drawer plan): the floating icon's pure logic in
//! src/agent_drawer.zig — gestures, clamping, ratios, keyboard moves, the
//! drawer's rectangle, and agent-drawer.json.
const std = @import("std");
const drawer = @import("agent_drawer");

const Rect = drawer.Rect;
const Ratios = drawer.Ratios;
const gpa = std.testing.allocator;

fn inside(r: Rect, width: c_int, height: c_int) bool {
    return r.x >= 0 and r.y >= 0 and r.x + r.w <= width and r.y + r.h <= height;
}

test "a movement of 6 px is a click and 7 px is a drag, in any direction" {
    try std.testing.expectEqual(drawer.Gesture.click, drawer.classifyGesture(0, 0));
    try std.testing.expectEqual(drawer.Gesture.click, drawer.classifyGesture(6, 0));
    try std.testing.expectEqual(drawer.Gesture.click, drawer.classifyGesture(0, -6));
    try std.testing.expectEqual(drawer.Gesture.click, drawer.classifyGesture(4, 4));
    try std.testing.expectEqual(drawer.Gesture.drag, drawer.classifyGesture(7, 0));
    try std.testing.expectEqual(drawer.Gesture.drag, drawer.classifyGesture(0, -7));
    try std.testing.expectEqual(drawer.Gesture.drag, drawer.classifyGesture(-5, 5));
    try std.testing.expectEqual(drawer.Gesture.drag, drawer.classifyGesture(-300, -200));
}

test "the default icon sits bottom-right, 24 px from both edges" {
    try std.testing.expectEqual(Rect{ .x = 1024 - 24 - 56, .y = 768 - 24 - 56, .w = 56, .h = 56 }, drawer.defaultRect(1024, 768));
    try std.testing.expectEqual(Rect{ .x = 500 - 80, .y = 400 - 80, .w = 56, .h = 56 }, drawer.defaultRect(500, 400));
}

test "clamping keeps the icon's size and moves it fully inside; a window smaller than the icon pins it at 0,0" {
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 56, .h = 56 }, drawer.clampRect(.{ .x = -40, .y = -1, .w = 56, .h = 56 }, 500, 400));
    try std.testing.expectEqual(Rect{ .x = 444, .y = 344, .w = 56, .h = 56 }, drawer.clampRect(.{ .x = 900, .y = 700, .w = 56, .h = 56 }, 500, 400));
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 56, .h = 56 }, drawer.clampRect(.{ .x = 10, .y = 20, .w = 56, .h = 56 }, 500, 400));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 56, .h = 56 }, drawer.clampRect(.{ .x = 30, .y = 30, .w = 56, .h = 56 }, 40, 30));
}

test "ratios are the icon's centre over the content size" {
    const r = drawer.ratiosFromRect(.{ .x = 100, .y = 50, .w = 56, .h = 56 }, 1000, 500);
    try std.testing.expectApproxEqAbs(@as(f64, 0.128), r.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.156), r.y, 1e-9);
    try std.testing.expectEqual(Rect{ .x = 100, .y = 50, .w = 56, .h = 56 }, drawer.rectFromRatios(r, 1000, 500));
    // Out-of-range ratios still give a rect inside the window.
    try std.testing.expectEqual(Rect{ .x = 944, .y = 444, .w = 56, .h = 56 }, drawer.rectFromRatios(.{ .x = 1, .y = 1 }, 1000, 500));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 56, .h = 56 }, drawer.rectFromRatios(.{ .x = 0, .y = 0 }, 1000, 500));
}

test "arrow keys move the icon 16 px, or 64 px with Shift, and stay inside" {
    const start = Rect{ .x = 100, .y = 100, .w = 56, .h = 56 };
    try std.testing.expectEqual(Rect{ .x = 116, .y = 100, .w = 56, .h = 56 }, drawer.keyMove(start, 1, 0, false, 1024, 768));
    try std.testing.expectEqual(Rect{ .x = 100, .y = 36, .w = 56, .h = 56 }, drawer.keyMove(start, 0, -1, true, 1024, 768));
    try std.testing.expectEqual(Rect{ .x = 36, .y = 100, .w = 56, .h = 56 }, drawer.keyMove(start, -1, 0, true, 1024, 768));
    try std.testing.expectEqual(Rect{ .x = 100, .y = 0, .w = 56, .h = 56 }, drawer.keyMove(.{ .x = 100, .y = 10, .w = 56, .h = 56 }, 0, -1, true, 1024, 768));
}

test "the drawer spans the full width at the bottom, 40% tall within 220 px and 70%" {
    try std.testing.expectEqual(Rect{ .x = 0, .y = 768 - 307, .w = 1024, .h = 307 }, drawer.drawerRect(1024, 768));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 400 - 220, .w = 500, .h = 220 }, drawer.drawerRect(500, 400));
    // Smaller than 220 / 0.7 tall: 70% wins.
    try std.testing.expectEqual(Rect{ .x = 0, .y = 200 - 140, .w = 300, .h = 140 }, drawer.drawerRect(300, 200));
}

test "property (invariant + idempotent): for every window at least icon-sized and every ratio pair, the rect is inside and clamp is idempotent" {
    var prng = std.Random.DefaultPrng.init(0xD1A3_0001);
    const random = prng.random();
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        const width = random.intRangeAtMost(c_int, drawer.icon_size, 4000);
        const height = random.intRangeAtMost(c_int, drawer.icon_size, 4000);
        const p = Ratios{ .x = random.float(f64), .y = random.float(f64) };
        const r = drawer.rectFromRatios(p, width, height);
        try std.testing.expect(inside(r, width, height));
        try std.testing.expectEqual(drawer.clampRect(r, width, height), drawer.clampRect(drawer.clampRect(r, width, height), width, height));
        const wild = Rect{ .x = random.intRangeAtMost(c_int, -5000, 5000), .y = random.intRangeAtMost(c_int, -5000, 5000), .w = drawer.icon_size, .h = drawer.icon_size };
        const once = drawer.clampRect(wild, width, height);
        try std.testing.expect(inside(once, width, height));
        try std.testing.expectEqual(once, drawer.clampRect(once, width, height));
    }
}

test "property (roundtrip): rectFromRatios(ratiosFromRect(r)) is r within 1 px for every rect inside the window" {
    var prng = std.Random.DefaultPrng.init(0xD1A3_0002);
    const random = prng.random();
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        const width = random.intRangeAtMost(c_int, drawer.icon_size, 4000);
        const height = random.intRangeAtMost(c_int, drawer.icon_size, 4000);
        const r = Rect{
            .x = random.intRangeAtMost(c_int, 0, width - drawer.icon_size),
            .y = random.intRangeAtMost(c_int, 0, height - drawer.icon_size),
            .w = drawer.icon_size,
            .h = drawer.icon_size,
        };
        const back = drawer.rectFromRatios(drawer.ratiosFromRect(r, width, height), width, height);
        try std.testing.expect(@abs(back.x - r.x) <= 1 and @abs(back.y - r.y) <= 1);
        try std.testing.expectEqual(r.w, back.w);
        try std.testing.expectEqual(r.h, back.h);
    }
}

/// Absolute path of agent-drawer.json inside a fresh test dir.
const StoreDir = struct {
    tmp: std.testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    path: []const u8 = "",

    fn init(self: *StoreDir) !void {
        self.tmp = std.testing.tmpDir(.{ .iterate = true });
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try self.tmp.dir.realPath(std.testing.io, &dir_buf);
        self.path = try std.fmt.bufPrint(&self.buf, "{s}/{s}", .{ dir_buf[0..n], drawer.file_name });
    }

    fn deinit(self: *StoreDir) void {
        self.tmp.cleanup();
    }

    fn write(self: *StoreDir, text: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = drawer.file_name, .data = text });
    }

    fn entries(self: *StoreDir) !usize {
        var it = self.tmp.dir.iterate();
        var n: usize = 0;
        while (try it.next(std.testing.io)) |_| n += 1;
        return n;
    }
};

test "store: missing, then save and load round-trip; the file is 0600 and no temp file is left" {
    var d: StoreDir = .{ .tmp = undefined };
    try d.init();
    defer d.deinit();
    const io = std.testing.io;
    try std.testing.expect(drawer.load(io, gpa, d.path) == .missing);
    try drawer.save(io, d.path, .{ .x = 0.25, .y = 0.75 });
    const loaded = drawer.load(io, gpa, d.path);
    try std.testing.expect(loaded == .ok);
    try std.testing.expectEqual(Ratios{ .x = 0.25, .y = 0.75 }, loaded.ok);
    const stat = try d.tmp.dir.statFile(io, drawer.file_name, .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    try std.testing.expectEqual(@as(usize, 1), try d.entries());
    try drawer.save(io, d.path, .{ .x = 1, .y = 0 });
    try std.testing.expectEqual(Ratios{ .x = 1, .y = 0 }, drawer.load(io, gpa, d.path).ok);
    try std.testing.expectEqual(@as(usize, 1), try d.entries());
}

test "store: garbage, a wrong version, out-of-range or missing ratios, extra fields or an oversized file are corrupt" {
    var d: StoreDir = .{ .tmp = undefined };
    try d.init();
    defer d.deinit();
    const io = std.testing.io;
    for ([_][]const u8{
        "not json",
        "",
        "{\"version\":2,\"x\":0.5,\"y\":0.5}",
        "{\"version\":1,\"x\":1.5,\"y\":0.5}",
        "{\"version\":1,\"x\":0.5,\"y\":-0.1}",
        "{\"version\":1,\"x\":0.5}",
        "{\"x\":0.5,\"y\":0.5}",
        "{\"version\":1,\"x\":0.5,\"y\":0.5,\"extra\":1}",
        "{\"version\":1,\"x\":0.5,\"y\":0.5}" ++ " " ** 2000,
    }) |text| {
        try d.write(text);
        try std.testing.expect(drawer.load(io, gpa, d.path) == .corrupt);
    }
}

test "property (roundtrip): load(save(p)) == p for every ratio pair in [0,1]^2" {
    var d: StoreDir = .{ .tmp = undefined };
    try d.init();
    defer d.deinit();
    const io = std.testing.io;
    var prng = std.Random.DefaultPrng.init(0xD1A3_0003);
    const random = prng.random();
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        const p = Ratios{ .x = random.float(f64), .y = random.float(f64) };
        try drawer.save(io, d.path, p);
        try std.testing.expectEqual(p, drawer.load(io, gpa, d.path).ok);
    }
}
