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
//! It decides a flag that is PRESENT on the command line, only (RoseCat 6415). An absent flag makes
//! no call here and no backend apply: the existing config defaults resolve it (media-source `on`,
//! hardware-acceleration `webkit`, the Linux renderer `shm`; no renderer decision on macOS or
//! Windows). An empty value is an explicit, invalid value, and is refused.
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
