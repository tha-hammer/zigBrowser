//! MS7.1 (macOS plan line 2158): the AppKit drawer's dock geometry, all in the portable
//! src/agent_drawer.zig so src/agent_drawer_mac.m holds no geometry of its own.
//! - pageRect(width, height, open): the page's rect in the content area (origin top-left).
//!   Open: the panel docks full width at the bottom (drawerRect) and the page fills exactly
//!   the region above it: never under the panel (no overlay over the GPU-composited page),
//!   and page + panel cover the content with no gap. Closed: the whole content.
//! - appKitFrame(r, height): the same rect as an AppKit frame (origin bottom-left, y up) in a
//!   content view `height` tall. It is its own inverse, so the docked panel's frame sits at
//!   y 0 and the page's frame starts exactly at the panel's height.
//! - the C exports zb_drawer_page_rect / zb_drawer_appkit_frame return exactly those.
//! Properties run over a grid of content sizes, including ones below the panel's 220 px
//! floor, zero and negative.
//! RED until the green adds them; build step `test-agent-drawer-appkit`, not in `test`.
const std = @import("std");
const drawer = @import("agent_drawer");

const Rect = drawer.Rect;

const widths = [_]c_int{ 0, 1, 57, 320, 800, 1024, 1440, 2560, 5120 };
const heights = [_]c_int{ -5, 0, 1, 100, 219, 220, 314, 315, 600, 768, 900, 1600, 2880 };

fn bottom(r: Rect) c_int {
    return r.y + r.h;
}

test "open: the page fills exactly the region above the docked panel, full width, no overlap and no gap" {
    for (widths) |w| for (heights) |h| {
        if (h <= 0) continue;
        const panel = drawer.drawerRect(w, h);
        const page = drawer.pageRect(w, h, true);
        try std.testing.expectEqual(@as(c_int, 0), page.x);
        try std.testing.expectEqual(@as(c_int, 0), page.y);
        try std.testing.expectEqual(w, page.w);
        try std.testing.expectEqual(panel.y, bottom(page)); // touches the panel: no gap, no overlap
        try std.testing.expectEqual(h, page.h + panel.h); // together they cover the content
        try std.testing.expect(page.h >= 0);
    };
}

test "closed: the page is the whole content area" {
    for (widths) |w| for (heights) |h| {
        if (h < 0) continue;
        try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = w, .h = h }, drawer.pageRect(w, h, false));
    };
}

test "appKitFrame flips y into a bottom-left origin and is its own inverse" {
    try std.testing.expectEqual(Rect{ .x = 10, .y = 600 - 20 - 30, .w = 40, .h = 30 }, drawer.appKitFrame(.{ .x = 10, .y = 20, .w = 40, .h = 30 }, 600));
    for (widths) |w| for (heights) |h| {
        if (h <= 0) continue;
        const r = drawer.defaultRect(w, h);
        try std.testing.expectEqual(r, drawer.appKitFrame(drawer.appKitFrame(r, h), h));
        const f = drawer.appKitFrame(r, h);
        try std.testing.expectEqual(r.x, f.x);
        try std.testing.expectEqual(r.w, f.w);
        try std.testing.expectEqual(r.h, f.h);
    };
}

test "in AppKit coordinates the panel sits at y 0 and the page starts at the panel's height" {
    for (widths) |w| for (heights) |h| {
        if (h <= 0) continue;
        const panel = drawer.appKitFrame(drawer.drawerRect(w, h), h);
        const page = drawer.appKitFrame(drawer.pageRect(w, h, true), h);
        try std.testing.expectEqual(@as(c_int, 0), panel.y);
        try std.testing.expectEqual(panel.h, page.y);
        try std.testing.expectEqual(h, page.y + page.h);
    };
}

test "the C exports return exactly the Zig results" {
    for (widths) |w| for (heights) |h| {
        if (h <= 0) continue;
        for ([_]c_int{ 0, 1 }) |open| {
            var out: Rect = undefined;
            drawer.zb_drawer_page_rect(w, h, open, &out);
            try std.testing.expectEqual(drawer.pageRect(w, h, open != 0), out);
        }
        const r = drawer.drawerRect(w, h);
        var f: Rect = undefined;
        drawer.zb_drawer_appkit_frame(&r, h, &f);
        try std.testing.expectEqual(drawer.appKitFrame(r, h), f);
    };
}
