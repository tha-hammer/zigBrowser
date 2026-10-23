//! bd zigBrowser-4pa.60, plan R30-MS3 Red 1, MS3.1 — on macOS a fresh --profile-dir
//! must exist, before the WebKit store is bound, so the pacing (daily-cap) state can be saved into it.
//!
//! The macOS branch of app.applyProfileDir only binds the WebKit store (the shim says "No directory is
//! created"), while the pacing store writes <profile>/automation-pacing.json with atomic_file.replaceJson,
//! which does not create parents. So for a fresh --profile-dir every save fails and the X/social daily caps
//! reset on each restart. Linux creates the directory (its shim makes it).
//!
//! This drives the PRODUCTION profile step, not a helper (SilverRidge 5a2b776, cf16730):
//! `profile_step.apply(os, arena, io, dir, binder)` holds every OS branch of app.applyProfileDir, which is one
//! call to it with builtin.os.tag and the shim binder (zb_app_set_profile_dir); here the binder is a recorder and
//! the OS is .macos, so the macOS branch runs on Linux. (It is its own module because importing app.zig into a test pulls in every export of
//! the app and the whole backend shim.) Assertions: the bind happens once, on the given path, and the
//! directory already EXISTS when it does; the step returns the directory; afterwards the fresh nested
//! directory exists and the real pacing writer (profile_step.atomic_file.replaceJson) saves at the production
//! pacing path (profile_step.pacingStatePath, which app.zig uses) and reads back; a second step on the
//! existing directory is fine; without --profile-dir nothing is bound.
//! Mutants: (1) atomic_file.ensureDir creates nothing (the inner step); (2) the macOS branch of
//! profile_step.apply returns the directory without the step (the outer delegation, SilverRidge cf16730). Each
//! must make this test fail. The Windows and Linux branches moved with it are driven too. app.zig's one call is
//! shared by every OS; the real-binary proof on the Mac is Red 2 (tests/e2e/mac_profile_pacing_persist_test.py).
//!
//! Registered in `test` (step test-app-profile-dir-macos) by the green; it was red while the module
//! profile_step did not exist.
const std = @import("std");
const profile_step = @import("profile_step");

const RecordingBinder = struct {
    calls: u32 = 0,
    dir_existed_at_bind: bool = false,
    bound: [std.fs.max_path_bytes]u8 = undefined,
    bound_len: usize = 0,
    fail: bool = false, // bind reports failure (the shim refused the directory)
    default: ?[]const u8 = null, // Linux's default profile directory, if one resolves
    cleared: u32 = 0,

    pub fn bind(self: *RecordingBinder, arena: std.mem.Allocator, dir: []const u8) bool {
        _ = arena;
        self.calls += 1;
        self.dir_existed_at_bind = if (std.Io.Dir.cwd().access(std.testing.io, dir, .{})) |_| true else |_| false;
        @memcpy(self.bound[0..dir.len], dir);
        self.bound_len = dir.len;
        return !self.fail;
    }

    pub fn defaultDir(self: *RecordingBinder, arena: std.mem.Allocator) ?[]const u8 {
        _ = arena;
        return self.default;
    }

    pub fn clear(self: *RecordingBinder) void {
        self.cleared += 1;
    }
};

test "the macOS profile step creates a fresh nested --profile-dir before the bind, and the pacing state saves there" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const profile = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/fresh/zb-profile", .{tmp.sub_path});
    const pacing = try profile_step.pacingStatePath(arena, profile);

    // The defect's mechanism: the pacing writer cannot save into a profile that does not exist yet.
    try std.testing.expectError(error.FileNotFound, profile_step.atomic_file.replaceJson(io, pacing, .{ .actions_today = 1 }));

    var binder: RecordingBinder = .{};
    const used = try profile_step.apply(.macos, arena, io, profile, &binder);
    try std.testing.expectEqualStrings(profile, used.?);
    try std.testing.expectEqual(@as(u32, 1), binder.calls);
    try std.testing.expectEqualStrings(profile, binder.bound[0..binder.bound_len]);
    try std.testing.expect(binder.dir_existed_at_bind); // created BEFORE the WebKit bind

    try std.Io.Dir.cwd().access(io, profile, .{});
    try profile_step.atomic_file.replaceJson(io, pacing, .{ .actions_today = 1 });
    var buf: [64]u8 = undefined;
    const saved = try std.Io.Dir.cwd().readFile(io, pacing, &buf);
    try std.testing.expectEqualStrings("{\"actions_today\":1}", saved);

    // Every restart runs the step on a directory that already exists: not an error.
    var again: RecordingBinder = .{};
    _ = try profile_step.apply(.macos, arena, io, profile, &again);
    try std.testing.expectEqual(@as(u32, 1), again.calls);
}

test "without --profile-dir the macOS profile step binds nothing and creates nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var binder: RecordingBinder = .{ .default = "/must/not/be/used" }; // macOS has no default profile
    try std.testing.expectEqual(@as(?[]const u8, null), try profile_step.apply(.macos, arena_state.allocator(), std.testing.io, null, &binder));
    try std.testing.expectEqual(@as(u32, 0), binder.calls);
    try std.testing.expectEqual(@as(u32, 0), binder.cleared);
}

test "a macOS bind the shim refuses is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const profile = try std.fmt.allocPrint(arena_state.allocator(), ".zig-cache/tmp/{s}/refused", .{tmp.sub_path});
    var binder: RecordingBinder = .{ .fail = true };
    try std.testing.expectError(error.WriteFailed, profile_step.apply(.macos, arena_state.allocator(), std.testing.io, profile, &binder));
    try std.testing.expectEqual(@as(u32, 1), binder.calls);
}

test "the Windows branch binds an explicit --profile-dir as given (the store creates it) and nothing without one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const profile = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/win/zb-profile", .{tmp.sub_path});
    var binder: RecordingBinder = .{};
    try std.testing.expectEqualStrings(profile, (try profile_step.apply(.windows, arena, std.testing.io, profile, &binder)).?);
    try std.testing.expectEqual(@as(u32, 1), binder.calls);
    try std.testing.expect(!binder.dir_existed_at_bind); // unchanged WS5.2 behavior: no directory made here
    var none: RecordingBinder = .{ .default = "/must/not/be/used" };
    try std.testing.expectEqual(@as(?[]const u8, null), try profile_step.apply(.windows, arena, std.testing.io, null, &none));
    try std.testing.expectEqual(@as(u32, 0), none.calls);
    var refused: RecordingBinder = .{ .fail = true };
    try std.testing.expectError(error.WriteFailed, profile_step.apply(.windows, arena, std.testing.io, profile, &refused));
}

test "the Linux branch: explicit dir, else the default, else clear; only an explicit refusal is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var explicit: RecordingBinder = .{ .default = "/default/profile" };
    try std.testing.expectEqualStrings("/explicit/profile", (try profile_step.apply(.linux, arena, io, "/explicit/profile", &explicit)).?);
    try std.testing.expectEqualStrings("/explicit/profile", explicit.bound[0..explicit.bound_len]);
    var by_default: RecordingBinder = .{ .default = "/default/profile" };
    try std.testing.expectEqualStrings("/default/profile", (try profile_step.apply(.linux, arena, io, null, &by_default)).?);
    try std.testing.expectEqualStrings("/default/profile", by_default.bound[0..by_default.bound_len]);
    var no_default: RecordingBinder = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), try profile_step.apply(.linux, arena, io, null, &no_default));
    try std.testing.expectEqual(@as(u32, 0), no_default.calls);
    try std.testing.expectEqual(@as(u32, 1), no_default.cleared);
    var refused_explicit: RecordingBinder = .{ .fail = true };
    try std.testing.expectError(error.WriteFailed, profile_step.apply(.linux, arena, io, "/explicit/profile", &refused_explicit));
    var refused_default: RecordingBinder = .{ .fail = true, .default = "/default/profile" };
    try std.testing.expectEqual(@as(?[]const u8, null), try profile_step.apply(.linux, arena, io, null, &refused_default));
}
