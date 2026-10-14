//! Startup media configuration: whether WebKit's Media Source Extensions
//! (MSE, `window.MediaSource`) are on for every window.
//! Pure: cli.zig parses the flag; webkit.zig reads the environment and
//! applies the result.
//!
//! Why a switch (2026-10-11, WebKitGTK 2.54.0, GStreamer 1.26.2): an
//! Instagram window froze twice. Its web process's main thread was stuck in
//! WebKit's MSE seek flush, in a lock cycle with a GStreamer streaming
//! thread (review log, "Instagram media deadlock investigation"; WebKit
//! bugs 320336 and 272975). No environment variable avoided it. With MSE
//! off, sites fall back to plain media. The default stays `on` until the
//! user decides from evidence.

const std = @import("std");
const env_switch = @import("env_switch.zig");

pub const MediaSource = enum { on, off };

/// The built-in choice when neither the flag nor the variable is given.
pub const default_media_source: MediaSource = .on;

/// The environment variable read when no `--media-source` flag is given.
pub const env_name = "ZIGBROWSER_MEDIA_SOURCE";

const flag_or_env = env_switch.Switch(MediaSource, default_media_source);

/// Command-line or environment value -> MediaSource (exactly `on`, `off`).
pub const parse = flag_or_env.parse;

/// The value plus, when the variable was consulted and is not `on` or
/// `off`, that text (the default is used, and startup says so).
pub const Resolved = flag_or_env.Resolved;

/// The effective setting: the flag, else the variable, else the default.
pub const resolve = flag_or_env.resolve;

test "only on and off parse" {
    try std.testing.expectEqual(MediaSource.on, parse("on").?);
    try std.testing.expectEqual(MediaSource.off, parse("off").?);
    for ([_][]const u8{ "", "0", "1", "false", "OFF", "On", " off" }) |text| {
        try std.testing.expect(parse(text) == null);
    }
}

test "the built-in default keeps MSE on" {
    try std.testing.expectEqual(MediaSource.on, default_media_source);
    try std.testing.expectEqual(Resolved{ .value = .on }, resolve(null, null));
}

test "the flag wins over the variable, which wins over the default" {
    try std.testing.expectEqual(Resolved{ .value = .off }, resolve(null, "off"));
    try std.testing.expectEqual(Resolved{ .value = .on }, resolve(null, "on"));
    try std.testing.expectEqual(Resolved{ .value = .on }, resolve(.on, "off"));
    try std.testing.expectEqual(Resolved{ .value = .off }, resolve(.off, "on"));
    try std.testing.expectEqual(Resolved{ .value = .off }, resolve(.off, null));
}

test "a variable that is not on or off keeps the default and is reported; a flag makes it irrelevant" {
    const bad = resolve(null, "0");
    try std.testing.expectEqual(MediaSource.on, bad.value);
    try std.testing.expectEqualStrings("0", bad.bad_env.?);
    try std.testing.expectEqualStrings("", resolve(null, "").bad_env.?);
    try std.testing.expectEqual(Resolved{ .value = .off }, resolve(.off, "bogus"));
}
