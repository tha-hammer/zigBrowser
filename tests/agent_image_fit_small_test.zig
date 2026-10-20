//! S7b (chat-drawer plan section 10, S7, rev 16.20.35; RoseCat fb75e11, Agent Mail 6696): a
//! PNG small enough to go as is must still decode first. Bytes that only look like a PNG (its
//! signature and a closing IEND, junk between) or a PNG whose header is corrupt are
//! "the screenshot could not be read", never sent as `image/png`; a valid small PNG still goes
//! as is, its bytes unchanged.
const std = @import("std");
const common = @import("agent_image_common.zig");

const testing = std.testing;
const signature = "\x89PNG\r\n\x1a\n";
const iend = "\x00\x00\x00\x00IEND\xae\x42\x60\x82";

fn expectUnreadable(bytes: []const u8) !void {
    const out = try common.fit(bytes, common.max_b64);
    defer out.deinit();
    if (out.rc != common.fit_unreadable) std.debug.print("{d} bytes: rc {d}\n", .{ bytes.len, out.rc });
    try testing.expectEqual(common.fit_unreadable, out.rc);
    try testing.expect(out.b64 == null and out.mime == null);
}

test "the signature and IEND alone, or with junk between, are unreadable however small" {
    try expectUnreadable(signature ++ iend);
    try expectUnreadable(signature ++ ("\x5a" ** 64) ++ iend);
}

test "a small PNG whose header is corrupt is unreadable; the valid one still goes as is" {
    const png = try common.pngOf(64, 48, null);
    defer testing.allocator.free(png);
    {
        const out = try common.fit(png, common.max_b64);
        defer out.deinit();
        try testing.expectEqual(common.fit_ok, out.rc);
        try testing.expectEqualStrings("image/png", std.mem.span(out.mime.?));
    }
    // IHDR's width (bytes 16..20) set to 0: a PNG no decoder accepts, its IEND still in place.
    const bad = try testing.allocator.dupe(u8, png);
    defer testing.allocator.free(bad);
    try testing.expectEqualStrings("IHDR", bad[12..16]);
    @memset(bad[16..20], 0);
    try expectUnreadable(bad);
}
