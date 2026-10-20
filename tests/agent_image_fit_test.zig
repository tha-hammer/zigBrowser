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

/// The little of GdkPixbuf the test uses to make inputs and read outputs (translate-c cannot
/// read the glib headers).
const c = struct {
    const Pixbuf = opaque {};
    const Loader = opaque {};
    const GError = opaque {};
    const colorspace_rgb: c_int = 0;
    extern fn gdk_pixbuf_new(colorspace: c_int, has_alpha: c_int, bits: c_int, w: c_int, h: c_int) ?*Pixbuf;
    extern fn gdk_pixbuf_get_rowstride(pb: *Pixbuf) c_int;
    extern fn gdk_pixbuf_get_pixels(pb: *Pixbuf) [*]u8;
    extern fn gdk_pixbuf_get_width(pb: *Pixbuf) c_int;
    extern fn gdk_pixbuf_get_height(pb: *Pixbuf) c_int;
    extern fn gdk_pixbuf_save_to_bufferv(pb: *Pixbuf, buf: *?[*]u8, size: *usize, kind: [*:0]const u8, keys: ?[*]const ?[*:0]const u8, values: ?[*]const ?[*:0]const u8, err: *?*GError) c_int;
    extern fn gdk_pixbuf_loader_new() ?*Loader;
    extern fn gdk_pixbuf_loader_write(l: *Loader, buf: [*]const u8, count: usize, err: *?*GError) c_int;
    extern fn gdk_pixbuf_loader_close(l: *Loader, err: *?*GError) c_int;
    extern fn gdk_pixbuf_loader_get_pixbuf(l: *Loader) ?*Pixbuf;
    extern fn g_object_unref(object: *anyopaque) void;
    extern fn g_free(mem: ?*anyopaque) void;
    extern fn g_error_free(err: *GError) void;
};

const testing = std.testing;

const fit_ok: c_int = 0;
const fit_too_large: c_int = 1;
const fit_unreadable: c_int = 2;
/// The broker's bound: the base64 of one image block, with room left for its frame.
const max_b64: usize = (1 << 20) - 4096;

extern fn zb_agent_image_fit(png: [*]const u8, len: usize, max: usize, out_b64: *?[*:0]u8, out_mime: *?[*:0]const u8) c_int;
extern fn zb_agent_image_free(p: ?*anyopaque) void;

const Fitted = struct {
    rc: c_int,
    b64: ?[*:0]u8,
    mime: ?[*:0]const u8,

    fn deinit(self: Fitted) void {
        if (self.b64) |p| zb_agent_image_free(p);
    }

    fn text(self: Fitted) []const u8 {
        return std.mem.span(self.b64.?);
    }
};

fn fit(png: []const u8, max: usize) !Fitted {
    var out: Fitted = .{ .rc = -1, .b64 = null, .mime = null };
    out.rc = zb_agent_image_fit(png.ptr, png.len, max, &out.b64, &out.mime);
    return out;
}

/// A `w`×`h` RGB image as PNG bytes (testing allocator), its pixels from `pixel`.
fn pngOf(w: c_int, h: c_int, seed: ?u64) ![]u8 {
    const pb = c.gdk_pixbuf_new(c.colorspace_rgb, 0, 8, w, h) orelse return error.NoPixbuf;
    defer c.g_object_unref(pb);
    const stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(pb));
    const pixels: [*]u8 = c.gdk_pixbuf_get_pixels(pb);
    var prng = std.Random.DefaultPrng.init(seed orelse 0);
    for (0..@intCast(h)) |y| {
        for (0..@intCast(w)) |x| {
            const p = pixels + y * stride + x * 3;
            if (seed != null) {
                prng.random().bytes(p[0..3]);
            } else {
                p[0] = @truncate(x * 4);
                p[1] = @truncate(y * 5);
                p[2] = 90;
            }
        }
    }
    var buf: ?[*]u8 = null;
    var len: usize = 0;
    var err: ?*c.GError = null;
    if (c.gdk_pixbuf_save_to_bufferv(pb, &buf, &len, "png", null, null, &err) == 0) {
        if (err) |e| c.g_error_free(e);
        return error.NoPng;
    }
    defer c.g_free(buf);
    return testing.allocator.dupe(u8, buf.?[0..len]);
}

fn decodeB64(text: []const u8) ![]u8 {
    const d = std.base64.standard.Decoder;
    const out = try testing.allocator.alloc(u8, try d.calcSizeForSlice(text));
    errdefer testing.allocator.free(out);
    try d.decode(out, text);
    return out;
}

/// The width and height GdkPixbuf reads from `bytes`, or an error if it cannot.
fn decodedSize(bytes: []const u8) ![2]c_int {
    const loader = c.gdk_pixbuf_loader_new() orelse return error.NoLoader;
    defer c.g_object_unref(loader);
    var err: ?*c.GError = null;
    if (c.gdk_pixbuf_loader_write(loader, bytes.ptr, bytes.len, &err) == 0 or c.gdk_pixbuf_loader_close(loader, &err) == 0) {
        if (err) |e| c.g_error_free(e);
        return error.NotDecodable;
    }
    const pb = c.gdk_pixbuf_loader_get_pixbuf(loader) orelse return error.NotDecodable;
    return .{ c.gdk_pixbuf_get_width(pb), c.gdk_pixbuf_get_height(pb) };
}

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
