//! XDG Base Directory lookups shared by the profile and the agent home.
const std = @import("std");

/// $XDG_DATA_HOME/<sub>, else $HOME/.local/share/<sub>. A relative or empty
/// XDG_DATA_HOME is ignored (XDG Base Directory spec). Null when neither is
/// usable.
pub fn dataSubdir(allocator: std.mem.Allocator, xdg_data_home: ?[]const u8, home: ?[]const u8, sub: []const u8) !?[]u8 {
    if (xdg_data_home) |dir| {
        if (std.fs.path.isAbsolute(dir)) return try std.fs.path.join(allocator, &.{ dir, sub });
    }
    const home_dir = home orelse return null;
    if (home_dir.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ home_dir, ".local/share", sub });
}
