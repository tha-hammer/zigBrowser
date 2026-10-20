//! S7b (chat-drawer plan section 10, S7, rev 16.20.35): the screenshot fit seam,
//! `zb_agent_image_fit(png, len, max_b64, &out_b64, &out_mime)` in src/agent_image.c
//! (GdkPixbuf, no main loop, on the broker's worker):
//! - a PNG whose base64 is at most `max_b64` goes as is, `image/png`;
//! - else it is decoded and re-encoded as JPEG at scale 1, 0.75, 0.5, 0.35, 0.25, each at
//!   quality 85, 70, 50; the first whose base64 is at most `max_b64` is sent, `image/jpeg`;
//! - else "result too large" (ZB_IMAGE_FIT_TOO_LARGE); bytes that are no PNG, a PNG cut short
//!   (no IEND chunk at its end: GdkPixbuf would decode it, the rest blank), or a PNG that
//!   cannot be decoded, "the screenshot could not be read" (ZB_IMAGE_FIT_UNREADABLE).
//! `out_b64` is NUL-terminated base64, freed with `zb_agent_image_free`; `out_mime` is static.
//! Before the green it links tests/agent_image_fit_stub.c, which answers -1 (not built), so
//! every test fails; the green links src/agent_image.c and removes the stub.
const std = @import("std");
const common = @import("agent_image_common.zig");

const testing = std.testing;
const fit = common.fit;
const pngOf = common.pngOf;
const decodeB64 = common.decodeB64;
const decodedSize = common.decodedSize;
const fit_ok = common.fit_ok;
const fit_too_large = common.fit_too_large;
const fit_unreadable = common.fit_unreadable;
const max_b64 = common.max_b64;

test "a small PNG goes as is: image/png, the identical bytes" {
    const png = try pngOf(64, 48, null);
    defer testing.allocator.free(png);
    const out = try fit(png, max_b64);
    defer out.deinit();
    try testing.expectEqual(fit_ok, out.rc);
    try testing.expectEqualStrings("image/png", std.mem.span(out.mime.?));
    const back = try decodeB64(out.text());
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, png, back);
}

test "an incompressible 1600x1200 capture becomes a decodable JPEG within the bound, its aspect kept" {
    const png = try pngOf(1600, 1200, 0x5eed);
    defer testing.allocator.free(png);
    try testing.expect(std.base64.standard.Encoder.calcSize(png.len) > max_b64); // several MiB
    const out = try fit(png, max_b64);
    defer out.deinit();
    try testing.expectEqual(fit_ok, out.rc);
    try testing.expectEqualStrings("image/jpeg", std.mem.span(out.mime.?));
    try testing.expect(out.text().len <= max_b64);
    const jpeg = try decodeB64(out.text());
    defer testing.allocator.free(jpeg);
    try testing.expect(jpeg.len > 3 and jpeg[0] == 0xFF and jpeg[1] == 0xD8 and jpeg[2] == 0xFF);
    const size = try decodedSize(jpeg);
    try testing.expect(size[0] <= 1600 and size[0] >= 1600 / 4 and size[1] <= 1200);
    try testing.expect(@abs(size[0] * 3 - size[1] * 4) <= 4); // 4:3, rounding aside
}

test "a bound no JPEG step can meet is \"result too large\", with nothing out" {
    const png = try pngOf(1600, 1200, 0xbad);
    defer testing.allocator.free(png);
    const out = try fit(png, 1000);
    defer out.deinit();
    try testing.expectEqual(fit_too_large, out.rc);
    try testing.expect(out.b64 == null);
}

test "bytes that are no PNG, a PNG cut short, or one that cannot be decoded are \"the screenshot could not be read\"" {
    const big = try pngOf(1600, 1200, 0xc0de);
    defer testing.allocator.free(big);
    const small = try pngOf(64, 48, null);
    defer testing.allocator.free(small);
    const iend = "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    try testing.expect(std.mem.endsWith(u8, small, iend));
    // The signature, then 2 MiB that are no PNG chunks, then IEND: too big to go as is.
    const garbage = try testing.allocator.alloc(u8, 8 + (2 << 20) + iend.len);
    defer testing.allocator.free(garbage);
    @memcpy(garbage[0..8], "\x89PNG\r\n\x1a\n");
    @memset(garbage[8 .. garbage.len - iend.len], 0x5a);
    @memcpy(garbage[garbage.len - iend.len ..], iend);
    for ([_][]const u8{
        "not a png at all",
        "",
        "\x89PNG\r\n\x1a",
        big[0 .. big.len / 2], // cut short, too big to go as is
        small[0 .. small.len - 1], // cut short, small enough to go as is
        garbage,
    }) |bytes| {
        const out = try fit(bytes, max_b64);
        defer out.deinit();
        try testing.expectEqual(fit_unreadable, out.rc);
        try testing.expect(out.b64 == null);
    }
}
