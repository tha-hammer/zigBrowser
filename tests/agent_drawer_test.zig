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

// --- S2: the minimize animation, the demo seed, row text --------------------

fn between(v: c_int, a: c_int, b: c_int) bool {
    return v >= @min(a, b) and v <= @max(a, b);
}

fn area(r: Rect) i64 {
    return @as(i64, r.w) * @as(i64, r.h);
}

test "lerpRect: t=0 is the start, t=1 the end, halfway is the midpoint" {
    const a = Rect{ .x = 0, .y = 461, .w = 1024, .h = 307 };
    const b = Rect{ .x = 944, .y = 688, .w = 56, .h = 56 };
    try std.testing.expectEqual(a, drawer.lerpRect(a, b, 0));
    try std.testing.expectEqual(b, drawer.lerpRect(a, b, 1));
    try std.testing.expectEqual(Rect{ .x = 472, .y = 575, .w = 540, .h = 182 }, drawer.lerpRect(a, b, 0.5));
}

test "ease: 0 -> 0, 1 -> 1, an ease-out (ahead of linear inside)" {
    try std.testing.expectEqual(@as(f64, 0), drawer.ease(0));
    try std.testing.expectEqual(@as(f64, 1), drawer.ease(1));
    try std.testing.expect(drawer.ease(0.5) > 0.5);
    try std.testing.expectEqual(@as(f64, 0), drawer.ease(-1));
    try std.testing.expectEqual(@as(f64, 1), drawer.ease(2));
}

test "property (invariant): every lerpRect component lies between the ends for t in [0,1]" {
    var prng = std.Random.DefaultPrng.init(0xD1A3_0004);
    const random = prng.random();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const a = Rect{ .x = random.intRangeAtMost(c_int, -2000, 4000), .y = random.intRangeAtMost(c_int, -2000, 4000), .w = random.intRangeAtMost(c_int, 0, 4000), .h = random.intRangeAtMost(c_int, 0, 4000) };
        const b = Rect{ .x = random.intRangeAtMost(c_int, -2000, 4000), .y = random.intRangeAtMost(c_int, -2000, 4000), .w = random.intRangeAtMost(c_int, 0, 4000), .h = random.intRangeAtMost(c_int, 0, 4000) };
        const r = drawer.lerpRect(a, b, random.float(f64));
        try std.testing.expect(between(r.x, a.x, b.x) and between(r.y, a.y, b.y) and between(r.w, a.w, b.w) and between(r.h, a.h, b.h));
    }
}

test "property (metamorphic): shrinking to a rect no larger each way, the area never grows as t grows" {
    // Domain: b.w <= a.w and b.h <= a.h (the drawer folding into the icon).
    // With only area(b) <= area(a), a tall-thin -> wide-flat pair grows
    // in the middle, so the plan's wider statement does not hold.
    var prng = std.Random.DefaultPrng.init(0xD1A3_0005);
    const random = prng.random();
    var i: usize = 0;
    while (i < 2_000) : (i += 1) {
        const a = Rect{ .x = random.intRangeAtMost(c_int, 0, 2000), .y = random.intRangeAtMost(c_int, 0, 2000), .w = random.intRangeAtMost(c_int, 1, 4000), .h = random.intRangeAtMost(c_int, 1, 4000) };
        const b = Rect{ .x = random.intRangeAtMost(c_int, 0, 2000), .y = random.intRangeAtMost(c_int, 0, 2000), .w = random.intRangeAtMost(c_int, 0, a.w), .h = random.intRangeAtMost(c_int, 0, a.h) };
        var previous = area(a);
        var step: usize = 1;
        while (step <= 50) : (step += 1) {
            const now = area(drawer.lerpRect(a, b, drawer.ease(@as(f64, @floatFromInt(step)) / 50)));
            try std.testing.expect(now <= previous);
            previous = now;
        }
    }
}

test "property (invariant): ease is monotone on [0,1] (10k seeded samples)" {
    var prng = std.Random.DefaultPrng.init(0xD1A3_0006);
    const random = prng.random();
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const p = random.float(f64);
        const q = random.float(f64);
        const lo = @min(p, q);
        const hi = @max(p, q);
        try std.testing.expect(drawer.ease(lo) <= drawer.ease(hi));
        try std.testing.expect(drawer.ease(lo) >= 0 and drawer.ease(hi) <= 1);
    }
}

test "the demo seed is exactly messages:<1..5000>" {
    try std.testing.expectEqual(@as(?u32, 200), drawer.parseDemo("messages:200"));
    try std.testing.expectEqual(@as(?u32, 1), drawer.parseDemo("messages:1"));
    try std.testing.expectEqual(@as(?u32, 5000), drawer.parseDemo("messages:5000"));
    for ([_][]const u8{ "", "messages:", "messages:0", "messages:5001", "messages:-1", "messages:2x", "messages: 2", "message:2", "MESSAGES:2", "messages:200 " }) |text| {
        try std.testing.expectEqual(@as(?u32, null), drawer.parseDemo(text));
    }
}

test "row text keeps everything up to 4 KiB, else the longest prefix ending on a character" {
    try std.testing.expectEqual(@as(usize, 5), drawer.rowTextLen("hello"));
    const exact = "a" ** 4096;
    try std.testing.expectEqual(@as(usize, 4096), drawer.rowTextLen(exact));
    try std.testing.expectEqual(@as(usize, 4096), drawer.rowTextLen(exact ++ "b"));
    // "é" is 2 bytes: a cut at 4096 would split the one starting at 4095.
    const split = "a" ** 4095 ++ "\u{e9}" ++ "z";
    try std.testing.expectEqual(@as(usize, 4095), drawer.rowTextLen(split));
}

test "property (invariant): the kept prefix is valid UTF-8, at most 4 KiB, and all of short text" {
    var prng = std.Random.DefaultPrng.init(0xD1A3_0007);
    const random = prng.random();
    const pieces = [_][]const u8{ "a", "\u{e9}", "\u{2193}", "\u{1f600}", " ", "\n" };
    var buf: [6000]u8 = undefined;
    var i: usize = 0;
    while (i < 2_000) : (i += 1) {
        var len: usize = 0;
        const target = random.uintAtMost(usize, 5990);
        while (len < target) {
            const piece = pieces[random.uintLessThan(usize, pieces.len)];
            @memcpy(buf[len..][0..piece.len], piece);
            len += piece.len;
        }
        const text = buf[0..len];
        const kept = drawer.rowTextLen(text);
        try std.testing.expect(kept <= drawer.row_text_max);
        try std.testing.expect(std.unicode.utf8ValidateSlice(text[0..kept]));
        if (text.len <= drawer.row_text_max) try std.testing.expectEqual(text.len, kept);
        if (text.len > drawer.row_text_max) try std.testing.expect(kept > drawer.row_text_max - 4);
    }
}

test "the animation-length seam is exactly 180..5000 ms in decimal digits" {
    try std.testing.expectEqual(@as(?u32, 3000), drawer.parseAnimMs("3000"));
    try std.testing.expectEqual(@as(?u32, 180), drawer.parseAnimMs("180"));
    try std.testing.expectEqual(@as(?u32, 5000), drawer.parseAnimMs("5000"));
    for ([_][]const u8{ "", "179", "5001", "0", "-1", "3000ms", " 3000", "3e3", "99999999999" }) |text| {
        try std.testing.expectEqual(@as(?u32, null), drawer.parseAnimMs(text));
    }
}
