//! RED (UNREGISTERED; bd zigBrowser-4pa.60, plan R30-MS3 Red 1, MS3.1) — on macOS a fresh --profile-dir
//! must exist after the profile step, so the pacing (daily-cap) state can be saved into it.
//!
//! The macOS branch of app.applyProfileDir only binds the WebKit store (the shim says "No directory is
//! created"), while the pacing store writes <profile>/automation-pacing.json with atomic_file.replaceJson,
//! which does not create parents. So for a fresh --profile-dir every save fails and the X/social daily caps
//! reset on each restart. Linux creates the directory (its shim makes it).
//!
//! The macOS branch is selected at compile time and calls the C shim, so this Linux test drives the step
//! the green adds to it: `atomic_file.ensureDir(io, dir)`, the directory half of the macOS profile step,
//! which the macOS branch of applyProfileDir calls before binding the store. It lives beside replaceJson
//! (the module that owns the profile's state files; a test cannot import app.zig and atomic_file.zig as two
//! modules, since app.zig imports atomic_file.zig). The test proves the consumer, not only the directory:
//! the real pacing writer (atomic_file.replaceJson) fails on the fresh path first and succeeds after the
//! step. The wiring (the macOS branch calls it) is proven by the Mac Red 2 (restart keeps actions_today == 1,
//! `ms3-gate`). Mutant (green): remove the createDirPath from ensureDir.
//!
//! Red today: compile error (atomic_file has no member "ensureDir"). Built and run only in a scratch
//! export, in no build.zig step until the green registers it in `test`.
const std = @import("std");
const atomic_file = @import("atomic_file");

test "a fresh nested --profile-dir exists after the macOS profile step and takes the pacing state" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const profile = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/fresh/zb-profile", .{tmp.sub_path});
    defer gpa.free(profile);
    const pacing = try std.fs.path.join(gpa, &.{ profile, "automation-pacing.json" });
    defer gpa.free(pacing);

    // The defect's mechanism: the pacing writer cannot save into a profile that does not exist yet.
    try std.testing.expectError(error.FileNotFound, atomic_file.replaceJson(io, pacing, .{ .actions_today = 1 }));

    try atomic_file.ensureDir(io, profile);

    try std.Io.Dir.cwd().access(io, profile, .{});
    try atomic_file.replaceJson(io, pacing, .{ .actions_today = 1 });
    var buf: [64]u8 = undefined;
    const saved = try std.Io.Dir.cwd().readFile(io, pacing, &buf);
    try std.testing.expectEqualStrings("{\"actions_today\":1}", saved);

    // A profile directory that already exists (every restart) is not an error.
    try atomic_file.ensureDir(io, profile);
}
