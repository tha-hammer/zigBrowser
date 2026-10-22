//! MS6.5.1 red (plan atomic-publish row). `publish` must write the ledger crash-safely: a fresh synced sibling
//! temp renamed over the store, then the dir fsynced — so a reader only ever sees the OLD or the NEW complete
//! store (never torn), and a mid-publish crash leaves the old store intact. Real files — no signals.
//! UNREGISTERED until green.
//!
//! The mutant this catches: a write-in-place publish (truncate the live store, then write) leaves a torn/empty
//! store if it is interrupted mid-write, instead of leaving the old content intact.
const std = @import("std");
const ledger = @import("agent_run_ledger");

const A = [_]ledger.Entry{.{ .basename = "zigbrowser-agent-1-00aa00aa00aa00aa", .dev = 10, .ino = 20, .uid = 0, .mode = 16832, .pid = 100, .start_kind = .linux_ticks, .start_sec = 5, .start_usec = 0, .state = .active }};
const B = [_]ledger.Entry{.{ .basename = "zigbrowser-agent-2-00bb00bb00bb00bb", .dev = 11, .ino = 21, .uid = 0, .mode = 16832, .pid = 200, .start_kind = .linux_ticks, .start_sec = 9, .start_usec = 0, .state = .left }};

fn expectStore(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, want: []const u8) !void {
    var l = try ledger.load(io, std.testing.allocator, dir, sub_path);
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.entries().len);
    try std.testing.expectEqualStrings(want, l.entries()[0].basename);
}

test "publish writes a ledger that loads back" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try ledger.publish(io, td.dir, "runs.json", &A);
    try expectStore(io, td.dir, "runs.json", A[0].basename);
}

test "a mid-publish crash leaves the OLD store intact (never torn)" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try ledger.publish(io, td.dir, "runs.json", &A); // store = A
    // crash while publishing B, before it could atomically replace the store:
    try ledger.publishCut(io, td.dir, "runs.json", &B, .after_temp, ledger.RealOps{});
    // the store must still be the OLD, complete A — not a torn/empty/partial file:
    try expectStore(io, td.dir, "runs.json", A[0].basename);
}

test "a stray leftover temp never masquerades as the store" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try ledger.publish(io, td.dir, "runs.json", &A);
    // a half-written temp from an earlier crashed publish:
    try td.dir.writeFile(io, .{ .sub_path = "runs.json.tmp-deadbeef", .data = "{ this is not json" });
    try expectStore(io, td.dir, "runs.json", A[0].basename); // load reads the store, not the temp
}

test "a second publish atomically replaces the store" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try ledger.publish(io, td.dir, "runs.json", &A);
    try ledger.publish(io, td.dir, "runs.json", &B);
    try expectStore(io, td.dir, "runs.json", B[0].basename);
}

test "a crash AFTER rename (before dir fsync) leaves the complete NEW store" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    try ledger.publish(io, td.dir, "runs.json", &A); // store = A
    // rename has happened; the dir fsync has not. The store must be the COMPLETE new B — so the temp MUST have
    // been fully written and synced BEFORE the rename (a rename-before-write would leave an empty/torn store):
    try ledger.publishCut(io, td.dir, "runs.json", &B, .after_rename, ledger.RealOps{});
    try expectStore(io, td.dir, "runs.json", B[0].basename);
}

// A recording fs-ops fake: it observes the ACTUAL ops that go through it (then delegates to RealOps to do the
// real work), so an omitted call in production removes both the effect and the observation.
const Kind = enum { sync_file, rename, sync_dir };
const Log = struct { buf: [8]Kind = undefined, n: usize = 0 };
const RecOps = struct {
    log: *Log,
    pub fn syncFile(self: RecOps, file: std.Io.File, io: std.Io) !void {
        self.log.buf[self.log.n] = .sync_file;
        self.log.n += 1;
        try (ledger.RealOps{}).syncFile(file, io);
    }
    pub fn rename(self: RecOps, dir: std.Io.Dir, old_sub: []const u8, new_sub: []const u8, io: std.Io) !void {
        self.log.buf[self.log.n] = .rename;
        self.log.n += 1;
        try (ledger.RealOps{}).rename(dir, old_sub, new_sub, io);
    }
    pub fn syncDir(self: RecOps, dir: std.Io.Dir, io: std.Io) !void {
        self.log.buf[self.log.n] = .sync_dir;
        self.log.n += 1;
        try (ledger.RealOps{}).syncDir(dir, io);
    }
};

test "publish routes fsync(temp), rename, fsync(dir) through the ops seam IN THAT ORDER" {
    const io = std.testing.io;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    var log: Log = .{};
    try ledger.publishCut(io, td.dir, "runs.json", &A, .none, RecOps{ .log = &log });
    const expected = [_]Kind{ .sync_file, .rename, .sync_dir };
    try std.testing.expectEqualSlices(Kind, &expected, log.buf[0..log.n]);
    try expectStore(io, td.dir, "runs.json", A[0].basename); // and it actually produced a loadable store
}
