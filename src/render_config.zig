//! Startup rendering configuration: WebKit's hardware-acceleration policy
//! and the renderer path (environment WebKit and EGL read at startup).
//! Pure: cli.zig parses into these types; webkit.zig applies them.
//!
//! Why this exists (2026-10-11, NVIDIA RTX 3080, driver 550.163.01, X11,
//! WebKitGTK 2.54.0): with policy NEVER (our default since a78fa5c) and
//! every other non-DMABUF path, a YouTube watch page's web process died
//! within 10-35 s and the window stayed blank. WebKit's own policy kept
//! it alive but drew nothing (GBM buffer allocation failures). WebKit's
//! policy plus WEBKIT_DMABUF_RENDERER_FORCE_SHM=1 ("shm") or plus Mesa's
//! EGL vendor ("mesa-egl") survived with video playing. The default stays
//! NEVER until a person has confirmed on screen which of those draws.

const std = @import("std");

/// WebKit's hardware-acceleration policy for every window. `webkit`
/// leaves WebKit's own default (it decides per page).
pub const HwPolicy = enum { never, always, webkit };

/// How WebKit hands rendered frames to the UI process. `default` sets
/// nothing; `shm` forces shared-memory buffers instead of GPU (GBM/DMABUF)
/// ones; `mesa_egl` makes libglvnd load Mesa's EGL instead of the NVIDIA
/// one (its GPU work then runs on Mesa's drivers or software).
pub const Renderer = enum { default, shm, mesa_egl };

pub const RenderConfig = struct {
    hw_policy: HwPolicy,
    renderer: Renderer,
};

/// The built-in choice when no flag is given. The candidate replacement,
/// pending on-screen confirmation, is `.{ .hw_policy = .webkit,
/// .renderer = .shm }` (or `.mesa_egl`): a one-line change here.
pub const default_render: RenderConfig = .{ .hw_policy = .never, .renderer = .default };

/// Mesa's libglvnd EGL vendor file (Debian/Ubuntu path).
pub const mesa_egl_vendor = "/usr/share/glvnd/egl_vendor.d/50_mesa.json";

/// Command-line value -> HwPolicy (`never`, `always`, `webkit`).
pub fn parseHwPolicy(text: []const u8) ?HwPolicy {
    return std.meta.stringToEnum(HwPolicy, text);
}

/// Command-line value -> Renderer (`default`, `shm`, `mesa-egl`).
pub fn parseRenderer(text: []const u8) ?Renderer {
    if (std.mem.eql(u8, text, "mesa-egl")) return .mesa_egl;
    if (std.mem.eql(u8, text, "mesa_egl")) return null;
    return std.meta.stringToEnum(Renderer, text);
}

pub fn rendererName(renderer: Renderer) []const u8 {
    return switch (renderer) {
        .default => "default",
        .shm => "shm",
        .mesa_egl => "mesa-egl",
    };
}

pub const EnvVar = struct { name: [:0]const u8, value: [:0]const u8 };

/// The environment variable a renderer sets (null: none). It must be in
/// place before WebKit and EGL start, and child processes inherit it.
pub fn rendererEnv(renderer: Renderer) ?EnvVar {
    return switch (renderer) {
        .default => null,
        .shm => .{ .name = "WEBKIT_DMABUF_RENDERER_FORCE_SHM", .value = "1" },
        .mesa_egl => .{ .name = "__EGL_VENDOR_LIBRARY_FILENAMES", .value = mesa_egl_vendor },
    };
}

/// A variable the user already set (to anything, even empty) is theirs:
/// a renderer never overrides it.
pub fn shouldSetEnv(existing: ?[]const u8) bool {
    return existing == null;
}

test "flag values parse; anything else is rejected" {
    try std.testing.expectEqual(HwPolicy.never, parseHwPolicy("never").?);
    try std.testing.expectEqual(HwPolicy.always, parseHwPolicy("always").?);
    try std.testing.expectEqual(HwPolicy.webkit, parseHwPolicy("webkit").?);
    try std.testing.expect(parseHwPolicy("on-demand") == null);
    try std.testing.expect(parseHwPolicy("") == null);
    try std.testing.expectEqual(Renderer.default, parseRenderer("default").?);
    try std.testing.expectEqual(Renderer.shm, parseRenderer("shm").?);
    try std.testing.expectEqual(Renderer.mesa_egl, parseRenderer("mesa-egl").?);
    try std.testing.expect(parseRenderer("mesa_egl") == null);
    try std.testing.expect(parseRenderer("gbm") == null);
    for ([_]Renderer{ .default, .shm, .mesa_egl }) |r| try std.testing.expectEqual(r, parseRenderer(rendererName(r)).?);
}

test "each renderer's environment, and a user's own value always wins" {
    try std.testing.expect(rendererEnv(.default) == null);
    const shm = rendererEnv(.shm).?;
    try std.testing.expectEqualStrings("WEBKIT_DMABUF_RENDERER_FORCE_SHM", shm.name);
    try std.testing.expectEqualStrings("1", shm.value);
    const mesa = rendererEnv(.mesa_egl).?;
    try std.testing.expectEqualStrings("__EGL_VENDOR_LIBRARY_FILENAMES", mesa.name);
    try std.testing.expectEqualStrings(mesa_egl_vendor, mesa.value);
    try std.testing.expect(shouldSetEnv(null));
    try std.testing.expect(!shouldSetEnv(""));
    try std.testing.expect(!shouldSetEnv("0"));
    try std.testing.expect(!shouldSetEnv("/somewhere/else.json"));
}

test "the built-in default is today's: policy NEVER, no renderer environment" {
    try std.testing.expectEqual(HwPolicy.never, default_render.hw_policy);
    try std.testing.expectEqual(Renderer.default, default_render.renderer);
}
