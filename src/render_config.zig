//! Startup rendering configuration: WebKit's hardware-acceleration policy
//! and the renderer path (environment WebKit and EGL read at startup).
//! Pure: cli.zig parses into these types; webkit.zig applies them.
//!
//! Why this default (2026-10-11, NVIDIA RTX 3080, driver 550.163.01, X11,
//! WebKitGTK 2.54.0, a YouTube video, checked on the real screen): with
//! policy NEVER (our default from a78fa5c to this change) the thumbnail
//! showed, then the window went blank and its web process died (as it did
//! in the tested WEBKIT_DISABLE_DMABUF_RENDERER=1 combinations). WebKit's
//! own policy alone kept the page alive but drew nothing (GBM buffer
//! failures). WebKit's policy plus WEBKIT_DMABUF_RENDERER_FORCE_SHM=1
//! ("shm", case J) drew the page and played the video in real time.
//! WebKit's policy plus Mesa's EGL ("mesa-egl", case L) drew it too, but
//! the video's time jumped back and forth. The user chose J.

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

/// The built-in choice when no flag is given (case J above). Opt out with
/// `--hardware-acceleration never` or `--renderer default|mesa-egl`.
pub const default_render: RenderConfig = .{ .hw_policy = .webkit, .renderer = .shm };

/// The effective config: each flag the user gave, else the default.
pub fn resolve(hw_policy: ?HwPolicy, renderer: ?Renderer) RenderConfig {
    return .{
        .hw_policy = hw_policy orelse default_render.hw_policy,
        .renderer = renderer orelse default_render.renderer,
    };
}

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

/// What startup does with a renderer's environment variable.
pub const EnvAction = union(enum) {
    /// The renderer sets no variable.
    none,
    /// Set it (overwrite=0, so a value set meanwhile still wins).
    set: EnvVar,
    /// The user already set it, to anything: leave it.
    keep_user: EnvVar,
    /// mesa-egl without Mesa's vendor file: set nothing and say so.
    missing_vendor,
};

/// `existing`: the variable's current value (null: unset).
/// `mesa_vendor_present`: whether `mesa_egl_vendor` exists.
pub fn envAction(renderer: Renderer, existing: ?[]const u8, mesa_vendor_present: bool) EnvAction {
    const env = rendererEnv(renderer) orelse return .none;
    if (!shouldSetEnv(existing)) return .{ .keep_user = env };
    if (renderer == .mesa_egl and !mesa_vendor_present) return .missing_vendor;
    return .{ .set = env };
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

test "the built-in default is case J: WebKit's own policy and shared-memory frames" {
    try std.testing.expectEqual(HwPolicy.webkit, default_render.hw_policy);
    try std.testing.expectEqual(Renderer.shm, default_render.renderer);
}

test "flags override the default one at a time; no flag keeps it" {
    try std.testing.expectEqual(default_render, resolve(null, null));
    try std.testing.expectEqual(RenderConfig{ .hw_policy = .never, .renderer = .shm }, resolve(.never, null));
    try std.testing.expectEqual(RenderConfig{ .hw_policy = .webkit, .renderer = .default }, resolve(null, .default));
    try std.testing.expectEqual(RenderConfig{ .hw_policy = .always, .renderer = .mesa_egl }, resolve(.always, .mesa_egl));
}

test "startup environment: the default sets FORCE_SHM=1 only when the user has not set it" {
    const shm = envAction(default_render.renderer, null, true);
    try std.testing.expectEqualStrings("WEBKIT_DMABUF_RENDERER_FORCE_SHM", shm.set.name);
    try std.testing.expectEqualStrings("1", shm.set.value);
    // Any value the user exported is theirs, even "0" or empty.
    try std.testing.expectEqualStrings("WEBKIT_DMABUF_RENDERER_FORCE_SHM", envAction(.shm, "0", true).keep_user.name);
    try std.testing.expectEqualStrings("WEBKIT_DMABUF_RENDERER_FORCE_SHM", envAction(.shm, "", true).keep_user.name);
    // --renderer default sets nothing (and leaves any user value alone).
    try std.testing.expect(envAction(.default, null, true) == .none);
    try std.testing.expect(envAction(.default, "1", true) == .none);
    // mesa-egl needs Mesa's vendor file; a user's own vendor list wins.
    try std.testing.expectEqualStrings(mesa_egl_vendor, envAction(.mesa_egl, null, true).set.value);
    try std.testing.expect(envAction(.mesa_egl, null, false) == .missing_vendor);
    try std.testing.expectEqualStrings("__EGL_VENDOR_LIBRARY_FILENAMES", envAction(.mesa_egl, "/x.json", false).keep_user.name);
}
