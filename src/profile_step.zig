//! The profile step for an explicit --profile-dir on macOS (macOS plan R30-MS3, bd 4pa.60). WebKit's
//! store for the profile lives in WebKit's own location (a path-derived identifier, wkwebview_shim.m), so
//! binding it creates no directory; but the pacing and drawer state files are written INTO the profile
//! directory by atomic_file.replaceJson, which never creates parents. So the directory is created first,
//! then the store is bound, as Linux's shim does. app.applyProfileDir's macOS branch calls `applyMacos`
//! with the shim binder; tests/app_profile_dir_macos_test.zig calls it with a recording one.
const std = @import("std");
/// The state-file writer the profile directory is prepared for (pub for the profile-step test).
pub const atomic_file = @import("atomic_file.zig");

/// N21: the pacing state lives with the profile it belongs to
/// ("<profile>/automation-pacing.json"); without a profile it stays in
/// memory ("").
pub fn pacingStatePath(allocator: std.mem.Allocator, profile_dir: ?[]const u8) ![]const u8 {
    const dir = profile_dir orelse return "";
    return std.fs.path.join(allocator, &.{ dir, "automation-pacing.json" });
}

/// macOS: only an explicit --profile-dir binds a profile store (the path is the identity seed; the shim
/// maps it to an isolated persistent store on macOS 14+, else the shared default). Creates the directory,
/// then calls `binder.bind(arena, dir) bool`. Returns the directory in use, or null without one.
pub fn applyMacos(arena: std.mem.Allocator, io: std.Io, profile_dir: ?[]const u8, binder: anytype) error{WriteFailed}!?[]const u8 {
    const dir = profile_dir orelse return null;
    atomic_file.ensureDir(io, dir) catch |err| {
        std.debug.print("profile: cannot create {s}: {s}\n", .{ dir, @errorName(err) });
        return error.WriteFailed;
    };
    if (binder.bind(arena, dir)) return dir;
    return error.WriteFailed;
}
