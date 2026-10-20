//! The shared backend-flag decision (Windows plan WS3 coordination; RoseCat 6389, 6405): for a
//! command-line rendering or media flag and its value, whether the backend of `os` applies it or
//! the app refuses it ("--<flag>=<value> is not supported on <os>", exit nonzero, no C ABI).
//! Pure and all-OS, so Linux tests it for Linux, macOS and Windows alike; each target's apply
//! (webkit.zig) calls it first, for its own OS only.
//!
//! The values are production's own parsing, not a second list:
//! - `media-source`: render_config's sibling media_config.parse (`on`, `off`), on every OS;
//! - `hardware-acceleration`: render_config.parseHwPolicy (`never`, `always`, `webkit`), on every OS;
//! - `renderer`: render_config.parseRenderer (`default`, `shm`, `mesa-egl`), Linux only (macOS and
//!   Windows have no renderer choice);
//! - any other flag, or any other OS: refuse.
//! It decides a flag that is PRESENT on the command line, only (RoseCat 6415, 6451). An absent flag
//! makes no call here and no present-flag apply, but the effective startup defaults are still applied
//! on every start: on Linux app.zig always calls webkit.applyRender and webkit.applyMediaSource,
//! which set WEBKIT_DMABUF_RENDERER_FORCE_SHM=1 (renderer `shm`) and call the native hardware
//! (`webkit`) and MSE (`on`) setters. macOS and Windows have no renderer decision, and their startup
//! path applies their hardware and media defaults the same way, without this call. An empty value is
//! an explicit, invalid value, and is refused.
//!
//! `startup` (j76) is the order around it: decide every present flag, then apply the resolved
//! configuration once; `presentFlags` and `refusalMessage` are its pieces.
const std = @import("std");
/// Production's parsers, which the decision reuses (re-exported so tests compare against the
/// very same functions).
pub const render_config = @import("render_config.zig");
pub const media_config = @import("media_config.zig");

pub const Decision = enum { apply, refuse };

pub fn backendFlagDecision(os: std.Target.Os.Tag, flag: []const u8, value: []const u8) Decision {
    switch (os) {
        .linux, .macos, .windows => {},
        else => return .refuse,
    }
    const supported = if (std.mem.eql(u8, flag, "media-source"))
        media_config.parse(value) != null
    else if (std.mem.eql(u8, flag, "hardware-acceleration"))
        render_config.parseHwPolicy(value) != null
    else if (std.mem.eql(u8, flag, "renderer"))
        os == .linux and render_config.parseRenderer(value) != null
    else
        false;
    return if (supported) .apply else .refuse;
}

/// One flag present on the command line, as production spells it (cli.zig parsed it).
pub const Present = struct { flag: []const u8, value: []const u8 };

/// The flags present on the command line, in a fixed order (hardware-acceleration, renderer,
/// media-source), each with production's own spelling of its value, which its parser reads
/// back. An absent flag is not listed: it is no decision (RoseCat 6415).
pub fn presentFlags(
    hw: ?render_config.HwPolicy,
    renderer: ?render_config.Renderer,
    media: ?media_config.MediaSource,
    buf: *[3]Present,
) []const Present {
    var n: usize = 0;
    if (hw) |v| {
        buf[n] = .{ .flag = "hardware-acceleration", .value = @tagName(v) };
        n += 1;
    }
    if (renderer) |v| {
        buf[n] = .{ .flag = "renderer", .value = render_config.rendererName(v) };
        n += 1;
    }
    if (media) |v| {
        buf[n] = .{ .flag = "media-source", .value = @tagName(v) };
        n += 1;
    }
    return buf[0..n];
}

/// The startup's flag step, the one order every backend follows (j76; RoseCat 6451, 6473):
/// each present flag goes to `sink.decide(flag, value)` (the app's: webkit.applyBackendFlag
/// for its own OS); a refusal returns error.UnsupportedFlag before anything is applied; then
/// `sink.applyResolved(config, media)` runs exactly once with the resolved effective
/// configuration, defaults included (on Linux, webkit.applyRender and applyMediaSource: the one
/// native apply). An absent flag never reaches `decide`, but its default is applied.
pub fn startup(
    sink: anytype,
    hw: ?render_config.HwPolicy,
    renderer: ?render_config.Renderer,
    media: ?media_config.MediaSource,
) error{UnsupportedFlag}!void {
    var buf: [3]Present = undefined;
    for (presentFlags(hw, renderer, media, &buf)) |p| try sink.decide(p.flag, p.value);
    sink.applyResolved(render_config.resolve(hw, renderer), media);
}

/// What the app prints for a refused flag, then it exits nonzero (Windows plan WS3.2):
/// `zigBrowser: --<flag>=<value> is not supported on <OS>`.
pub fn refusalMessage(buf: []u8, os: std.Target.Os.Tag, flag: []const u8, value: []const u8) ![]const u8 {
    const name = switch (os) {
        .linux => "Linux",
        .macos => "macOS",
        .windows => "Windows",
        else => @tagName(os),
    };
    return std.fmt.bufPrint(buf, "zigBrowser: --{s}={s} is not supported on {s}", .{ flag, value, name });
}
