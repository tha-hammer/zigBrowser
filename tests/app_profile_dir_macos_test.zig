//! bd zigBrowser-4pa.60, plan R30-MS3 Red 1, MS3.1 — on macOS a fresh --profile-dir
//! must exist, before the WebKit store is bound, so the pacing (daily-cap) state can be saved into it.
//!
//! The macOS branch of app.applyProfileDir only binds the WebKit store (the shim says "No directory is
//! created"), while the pacing store writes <profile>/automation-pacing.json with atomic_file.replaceJson,
//! which does not create parents. So for a fresh --profile-dir every save fails and the X/social daily caps
//! reset on each restart. Linux creates the directory (its shim makes it).
//!
//! This drives the PRODUCTION profile step, not a helper (SilverRidge 5a2b776 exact minimum):
//! `profile_step.applyMacos(arena, io, dir, binder)` is the macOS branch of app.applyProfileDir, which is a
//! one-line call to it with the shim binder (zb_app_set_profile_dir); here the binder is a recorder, so the
//! step runs on Linux. (It is its own module because importing app.zig into a test pulls in every export of
//! the app and the whole backend shim.) Assertions: the bind happens once, on the given path, and the
//! directory already EXISTS when it does; the step returns the directory; afterwards the fresh nested
//! directory exists and the real pacing writer (profile_step.atomic_file.replaceJson) saves at the production
//! pacing path (profile_step.pacingStatePath, which app.zig uses) and reads back; a second step on the
//! existing directory is fine; without --profile-dir nothing is bound.
//! Mutants (green): (1) remove the createDirPath from atomic_file.ensureDir; (2) remove the ensureDir call
//! from profile_step.applyMacos. Each must make this test fail. The one-line app.zig call is covered by the
//! Mac Red 2 (tests/e2e/mac_profile_pacing_persist_test.py) and compiled by `cross-check`.
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

    pub fn bind(self: *RecordingBinder, arena: std.mem.Allocator, dir: []const u8) bool {
        _ = arena;
        self.calls += 1;
        self.dir_existed_at_bind = if (std.Io.Dir.cwd().access(std.testing.io, dir, .{})) |_| true else |_| false;
        @memcpy(self.bound[0..dir.len], dir);
        self.bound_len = dir.len;
        return true;
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
    const used = try profile_step.applyMacos(arena, io, profile, &binder);
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
    _ = try profile_step.applyMacos(arena, io, profile, &again);
    try std.testing.expectEqual(@as(u32, 1), again.calls);
}

test "without --profile-dir the macOS profile step binds nothing and creates nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var binder: RecordingBinder = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), try profile_step.applyMacos(arena_state.allocator(), std.testing.io, null, &binder));
    try std.testing.expectEqual(@as(u32, 0), binder.calls);
}
