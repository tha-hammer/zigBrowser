//! WS5 drawer geometry/gesture PROPERTY tests against the REAL src/agent_drawer.zig (plan WS5 lines
//! 1560-1562). UNREGISTERED; run OFFLINE, no VM, no display needed:
//!
//!   zig test -lc --dep agent_drawer \
//!     -Mroot=tests/windows/agent_drawer_props_test.zig -Magent_drawer=src/agent_drawer.zig \
//!     --cache-dir <per-tree-cache>
//!
//! Every expected value is computed INDEPENDENTLY here (never by calling the same helper under test), so a
//! mutation of the implementation makes these fail. These are the [L] properties the WS5 plan requires the
//! behavior reds to reuse; the Python models in win_drawer_behaviors_test.py mirror the same math.
const std = @import("std");
const d = @import("agent_drawer");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// The icon's contract size is the LITERAL 56 (not d.icon_size): using the implementation's own constant in
// the "independent" expected values would let an icon-size mutation move actual and expected together
// (RoseCat b2f474b #4). A dedicated test pins that the public constant equals this literal.
const IW: c_int = 56; // 100% contract size

fn eqRect(r: d.Rect, x: c_int, y: c_int, w: c_int, h: c_int) !void {
    try expectEqual(x, r.x);
    try expectEqual(y, r.y);
    try expectEqual(w, r.w);
    try expectEqual(h, r.h);
}

test "the public icon_size equals the contract literal 56 (independent of the formulas)" {
    try expectEqual(@as(c_int, 56), d.icon_size);
    try expectEqual(@as(c_int, 56), IW);
}

test "clampRect keeps the icon fully inside for generated sizes and DPI-scaled icons (plan 1561-1562)" {
    const sizes = [_][2]c_int{ .{ 640, 480 }, .{ 1008, 729 }, .{ 1920, 1080 }, .{ 100, 80 } };
    const icon_px = [_]c_int{ 56, 84, 112 }; // 100%, 150%, 200%
    const offs = [_]c_int{ -100000, -1, 0, 37, 100000 };
    for (sizes) |s| {
        for (icon_px) |ip| {
            for (offs) |ox| {
                for (offs) |oy| {
                    const r = d.clampRect(.{ .x = ox, .y = oy, .w = ip, .h = ip }, s[0], s[1]);
                    const maxx = @max(@as(c_int, 0), s[0] - ip);
                    const maxy = @max(@as(c_int, 0), s[1] - ip);
                    try expect(r.x >= 0 and r.x <= maxx);
                    try expect(r.y >= 0 and r.y <= maxy);
                    try expectEqual(ip, r.w);
                    try expectEqual(ip, r.h);
                }
            }
        }
    }
}

test "ratios<->rect roundtrip is a stable fixed point (plan 1560 parse(write(ratios))==ratios)" {
    const sizes = [_][2]c_int{ .{ 1008, 729 }, .{ 1920, 1080 }, .{ 640, 480 } };
    const rr = [_]f64{ 0.0, 0.25, 0.5, 0.73, 1.0 };
    for (sizes) |s| {
        for (rr) |rx| {
            for (rr) |ry| {
                const r1 = d.rectFromRatios(.{ .x = rx, .y = ry }, s[0], s[1]);
                const p2 = d.ratiosFromRect(r1, s[0], s[1]);
                const r2 = d.rectFromRatios(p2, s[0], s[1]);
                try expectEqual(r1.x, r2.x);
                try expectEqual(r1.y, r2.y);
            }
        }
    }
}

test "rectFromRatios matches an independent formula" {
    const w: c_int = 1008;
    const h: c_int = 729;
    const cases = [_][2]f64{ .{ 0.5, 0.5 }, .{ 0.0, 0.0 }, .{ 1.0, 1.0 }, .{ 0.25, 0.75 } };
    const half: f64 = @as(f64, @floatFromInt(IW)) / 2.0;
    for (cases) |c| {
        const rxc = std.math.clamp(c[0], 0.0, 1.0);
        const ryc = std.math.clamp(c[1], 0.0, 1.0);
        var ex: c_int = @intFromFloat(@floor(rxc * @as(f64, @floatFromInt(w)) - half + 0.5));
        var ey: c_int = @intFromFloat(@floor(ryc * @as(f64, @floatFromInt(h)) - half + 0.5));
        ex = std.math.clamp(ex, 0, @max(@as(c_int, 0), w - IW));
        ey = std.math.clamp(ey, 0, @max(@as(c_int, 0), h - IW));
        const r = d.rectFromRatios(.{ .x = c[0], .y = c[1] }, w, h);
        try expectEqual(ex, r.x);
        try expectEqual(ey, r.y);
    }
}

test "classifyGesture 6px threshold, independent (WS5.2)" {
    try expect(d.classifyGesture(5, 0) == .click); // 25 <= 36
    try expect(d.classifyGesture(0, 5) == .click);
    try expect(d.classifyGesture(6, 0) == .click); // 36 > 36 is false -> click
    try expect(d.classifyGesture(7, 0) == .drag); // 49 > 36
    try expect(d.classifyGesture(5, 5) == .drag); // 50 > 36
}

test "keyMove steps 16/64, independent (WS5.2)" {
    const r = d.Rect{ .x = 100, .y = 100, .w = IW, .h = IW };
    try expectEqual(@as(c_int, 116), d.keyMove(r, 1, 0, false, 2000, 2000).x);
    try expectEqual(@as(c_int, 164), d.keyMove(r, 1, 0, true, 2000, 2000).x);
    try expectEqual(@as(c_int, 84), d.keyMove(r, 0, -1, false, 2000, 2000).y); // 100 - 16
}

test "drawerRect is 40% of height, clamped to [220, 70%], independent (WS5.1)" {
    // h=729: wanted=floor(729*0.4+0.5)=292; most=floor(729*0.7)=510; tall=min(max(292,220),510)=292
    try eqRect(d.drawerRect(1008, 729), 0, 729 - 292, 1008, 292);
    // h=400: wanted=160 -> max(160,220)=220; most=280; tall=220
    try eqRect(d.drawerRect(800, 400), 0, 400 - 220, 800, 220);
}

test "ease cubic-out and lerpRect rounding, independent (WS5.3)" {
    try expectEqual(@as(f64, 0.0), d.ease(0));
    try expectEqual(@as(f64, 1.0), d.ease(1));
    try expect(@abs(d.ease(0.5) - 0.875) < 1e-9); // 1-(1-0.5)^3
    const a = d.Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const b = d.Rect{ .x = 0, .y = 0, .w = 56, .h = 56 };
    // w at t=0.5: floor(100 + (56-100)*0.5 + 0.5) = floor(78.5) = 78
    try expectEqual(@as(c_int, 78), d.lerpRect(a, b, 0.5).w);
}

test "fold mid-frame is strictly between the icon and the open drawer (WS5.3)" {
    const drawer = d.drawerRect(1008, 729);
    const icon = d.defaultRect(1008, 729);
    const mid = d.lerpRect(drawer, icon, d.ease(0.5)); // fold folds the drawer down into the icon
    try expect(icon.w < mid.w and mid.w < drawer.w);
}

test "anim_ms default in the fold range; override parsed (WS5.3)" {
    try expect(d.anim_ms >= 150 and d.anim_ms < 260);
    try expectEqual(@as(i64, 180), d.anim_ms);
    try expectEqual(@as(?u32, 3000), d.parseAnimMs("3000"));
    try expectEqual(@as(?u32, null), d.parseAnimMs("nope"));
}
