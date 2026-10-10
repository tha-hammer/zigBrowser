//! N21: the social and X pacing state (daily counts, caps, delays) survives
//! a restart in <profile dir>/automation-pacing.json.
//!
//! - Written after every counted action and every social.set_pacing, as a
//!   new 0600 temp file in the same directory that is synced, renamed over
//!   the old one, and then the directory is synced too: readers only ever
//!   see the old or the new file, and once a save returned it survives a
//!   crash.
//! - Loaded once when the server starts. A missing file or one that is
//!   unreadable, oversized, malformed or inconsistent means defaults; the
//!   server logs which (never the contents).
//! - The UTC day resets counts as before: a file saved on another day keeps
//!   its caps and delays but not its counts.
const std = @import("std");
const pacing = @import("pacing.zig");
const social_routes = @import("social_routes.zig");
const x_routes = @import("x_routes.zig");

pub const file_name = "automation-pacing.json";
/// A valid file is about 250 bytes; anything this large is not ours.
pub const max_file_bytes: usize = 4096;
pub const version: u32 = 1;

pub const Part = pacing.Persisted;

pub const Snapshot = struct {
    version: u32 = version,
    /// UTC day number (days since 1970-01-01) the counts belong to.
    day: i32,
    social: Part,
    x: Part,
};

pub const Loaded = union(enum) {
    missing,
    corrupt,
    ok: Snapshot,
};

/// The file's exact schema: every field required, none unknown.
const FilePart = struct { actions_today: u32, daily_cap: u32, min_delay_ms: u32, max_delay_ms: u32 };
const FileSnapshot = struct { version: u32, day: i32, social: FilePart, x: FilePart };

pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Loaded {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        else => .corrupt,
    };
    defer gpa.free(text);
    const parsed = std.json.parseFromSlice(FileSnapshot, gpa, text, .{}) catch return .corrupt;
    defer parsed.deinit();
    const file = parsed.value;
    if (file.version != version or !consistent(file.social) or !consistent(file.x)) return .corrupt;
    return .{ .ok = .{ .version = file.version, .day = file.day, .social = part(file.social), .x = part(file.x) } };
}

fn consistent(p: FilePart) bool {
    return p.min_delay_ms <= p.max_delay_ms;
}

fn part(p: FilePart) Part {
    return .{ .actions_today = p.actions_today, .daily_cap = p.daily_cap, .min_delay_ms = p.min_delay_ms, .max_delay_ms = p.max_delay_ms };
}

/// Atomic replace: a fresh 0600 temp file next to `path`, synced, then
/// renamed over it. The temp file never outlives a failed save.
pub fn save(io: std.Io, path: []const u8, snapshot: Snapshot) !void {
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp-{x}", .{ path, std.mem.readInt(u64, &nonce, .little) });
    const dir = std.Io.Dir.cwd();
    var file = try dir.createFile(io, tmp, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    var renamed = false;
    defer if (!renamed) dir.deleteFile(io, tmp) catch {};
    {
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var writer = file.writer(io, &buf);
        try std.json.Stringify.value(snapshot, .{}, &writer.interface);
        try writer.interface.flush();
        try file.sync(io);
    }
    try dir.rename(tmp, dir, path, io);
    renamed = true;
    try syncParent(io, path);
}

/// fsync of the directory holding `path`, so the rename itself is durable.
fn syncParent(io: std.Io, path: []const u8) !void {
    // `iterate` opens it O_RDONLY (a plain open is O_PATH, which fsync refuses).
    var parent = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(path) orelse ".", .{ .iterate = true });
    defer parent.close(io);
    if (std.c.fsync(parent.handle) != 0) return error.SyncFailed;
}

/// Ties the server's two pacing states to the file: `loadInto` once at
/// start, then `attach` so every change is saved.
pub const Persister = struct {
    io: std.Io,
    path: []const u8,
    social: *social_routes.SocialState,
    x: *x_routes.XState,
    /// Serializes saves: each writes a fresh snapshot of both states, so
    /// the last save always holds the latest counts.
    lock: std.atomic.Mutex = .unlocked,

    pub fn loadInto(self: *Persister, gpa: std.mem.Allocator) std.meta.Tag(Loaded) {
        const loaded = load(self.io, gpa, self.path);
        switch (loaded) {
            .ok => |snapshot| {
                self.social.restore(snapshot.social, snapshot.day);
                self.x.restore(snapshot.x, snapshot.day);
            },
            .missing, .corrupt => {},
        }
        return loaded;
    }

    pub fn attach(self: *Persister) void {
        const hook = pacing.ChangeHook{ .ctx = self, .changed = changed };
        self.social.on_change = hook;
        self.x.on_change = hook;
    }

    fn changed(ctx: *anyopaque) void {
        const self: *Persister = @ptrCast(@alignCast(ctx));
        self.persist();
    }

    /// Writes both states now (failures are logged, never fatal).
    pub fn persist(self: *Persister) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();
        const social = self.social.persisted();
        const x = self.x.persisted();
        save(self.io, self.path, .{ .day = social.day, .social = social.part, .x = x.part }) catch |err| {
            std.log.warn("automation pacing: could not save {s}: {s}", .{ self.path, @errorName(err) });
        };
    }
};
