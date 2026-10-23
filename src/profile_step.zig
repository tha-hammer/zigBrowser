//! The profile step for an explicit --profile-dir on macOS (macOS plan R30-MS3, bd 4pa.60). WebKit's
//! store for the profile lives in WebKit's own location (a path-derived identifier, wkwebview_shim.m), so
//! binding it creates no directory; but the pacing and drawer state files are written INTO the profile
//! directory by atomic_file.replaceJson, which never creates parents. So the directory is created first,
//! then the store is bound, as Linux's shim does. app.applyProfileDir is one call to `apply` with the OS and the
//! shim binder, so every OS branch, the macOS one above all, runs in tests/app_profile_dir_macos_test.zig with a
//! recording binder (SilverRidge cf16730: the outer delegation is driven, not pinned).
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

/// app.applyProfileDir for `os`: persistent profile for cookies and site data. The binder gives
/// `bind(arena, dir) bool` (the shim's zb_app_set_profile_dir) and, for Linux, `defaultDir(arena) ?[]const u8`
/// (the default under $XDG_DATA_HOME or ~/.local/share) and `clear()` (no profile at all). Returns the profile
/// directory in use, or null when there is none.
pub fn apply(comptime os: std.Target.Os.Tag, arena: std.mem.Allocator, io: std.Io, profile_dir: ?[]const u8, binder: anytype) error{WriteFailed}!?[]const u8 {
    switch (os) {
        // MS3.1 + 4pa.60: create the profile directory, then bind the WebKit store.
        .macos => return applyMacos(arena, io, profile_dir, binder),
        // WS5.2: an explicit --profile-dir binds the drawer's persistence store (<profile>/agent-drawer.json) on
        // Windows, like macOS; without one there is no persistent store (configure gets null). This lets the "S"
        // icon's position survive a restart (zb_drawer_remember -> save; zb_drawer_start_ratios -> load).
        .windows => {
            const dir = profile_dir orelse return null;
            if (binder.bind(arena, dir)) return dir;
            return error.WriteFailed;
        },
        // Linux's shim creates the directory itself. An explicit directory that cannot be bound is an error; when
        // the default cannot be resolved or bound, the browser runs on WebKit's default context.
        .linux => {
            const dir = profile_dir orelse binder.defaultDir(arena) orelse {
                binder.clear(); // no profile resolved: make sure no earlier run's profile lingers
                return null;
            };
            if (binder.bind(arena, dir)) return dir;
            if (profile_dir != null) return error.WriteFailed;
            return null;
        },
        else => return null,
    }
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
