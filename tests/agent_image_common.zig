//! The screenshot fit seam's test helpers (S7b, rev 16.20.35): the seam's C ABI, and the
//! little of GdkPixbuf the tests use to make inputs and read outputs. No tests of its own.
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

pub const fit_ok: c_int = 0;
pub const fit_too_large: c_int = 1;
pub const fit_unreadable: c_int = 2;
/// The broker's bound: the base64 of one image block, with room left for its frame.
pub const max_b64: usize = (1 << 20) - 4096;

extern fn zb_agent_image_fit(png: [*]const u8, len: usize, max: usize, out_b64: *?[*:0]u8, out_mime: *?[*:0]const u8) c_int;
extern fn zb_agent_image_free(p: ?*anyopaque) void;

pub const Fitted = struct {
    rc: c_int,
    b64: ?[*:0]u8,
    mime: ?[*:0]const u8,

    pub fn deinit(self: Fitted) void {
        if (self.b64) |p| zb_agent_image_free(p);
    }

    pub fn text(self: Fitted) []const u8 {
        return std.mem.span(self.b64.?);
    }
};

pub fn fit(png: []const u8, max: usize) !Fitted {
    var out: Fitted = .{ .rc = -1, .b64 = null, .mime = null };
    out.rc = zb_agent_image_fit(png.ptr, png.len, max, &out.b64, &out.mime);
    return out;
}

/// A `w`×`h` RGB image as PNG bytes (testing allocator), its pixels from `pixel`.
pub fn pngOf(w: c_int, h: c_int, seed: ?u64) ![]u8 {
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

pub fn decodeB64(text: []const u8) ![]u8 {
    const d = std.base64.standard.Decoder;
    const out = try testing.allocator.alloc(u8, try d.calcSizeForSlice(text));
    errdefer testing.allocator.free(out);
    try d.decode(out, text);
    return out;
}

/// The width and height GdkPixbuf reads from `bytes`, or an error if it cannot.
pub fn decodedSize(bytes: []const u8) ![2]c_int {
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
