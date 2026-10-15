//! The per-session configuration check (chat-drawer plan §2 "Per-session
//! integrity", S3.10; S3c). `--agent-setup` writes runtime/config-manifest.json:
//! the SHA-256 of every file in the agent home's read-only `.claude`, except
//! the writable state directories named in runtime/writable.json
//! (setup.py `manifest`). Before each session the app re-hashes that tree;
//! any difference (a file changed, added or removed), or a manifest it cannot
//! read, refuses the session: a change made outside the sandbox, by any other
//! same-user process, never reaches a CLI.

const std = @import("std");

pub const Check = enum { ok, changed };

/// `home` is the agent home. The tree must hash to exactly the manifest.
pub fn check(gpa: std.mem.Allocator, io: std.Io, home: []const u8) Check {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    return compare(arena.allocator(), io, home) catch .changed;
}

fn compare(a: std.mem.Allocator, io: std.Io, home: []const u8) !Check {
    const cwd = std.Io.Dir.cwd();
    const manifest_text = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ home, "runtime", "config-manifest.json" }), a, .limited(16 * 1024 * 1024));
    const manifest = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]const u8), a, manifest_text, .{});
    const writable_text = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ home, "runtime", "writable.json" }), a, .limited(64 * 1024));
    const state_dirs = try std.json.parseFromSliceLeaky([]const []const u8, a, writable_text, .{});

    var claude = try cwd.openDir(io, try std.fs.path.join(a, &.{ home, ".claude" }), .{ .iterate = true });
    defer claude.close(io);
    var walker = try claude.walkSelectively(a);
    defer walker.deinit();
    var seen: usize = 0;
    while (try walker.next(io)) |entry| {
        // As setup.py: a top-level name in the state set is not configuration.
        if (entry.depth() == 1 and isStateDir(state_dirs, entry.basename)) continue;
        switch (entry.kind) {
            .directory => try walker.enter(io, entry),
            .file, .sym_link => {
                // A symlink counts as the file it names (setup.py's is_file());
                // one to a directory is neither hashed nor entered.
                const want = manifest.map.get(entry.path) orelse {
                    if (entry.kind == .sym_link and isDir(io, entry)) continue;
                    return .changed;
                };
                var got: [std.crypto.hash.sha2.Sha256.digest_length * 2]u8 = undefined;
                hashFile(io, entry.dir, entry.basename, &got) catch return .changed;
                if (!std.mem.eql(u8, want, &got)) return .changed;
                seen += 1;
            },
            else => return .changed,
        }
    }
    return if (seen == manifest.map.count()) .ok else .changed;
}

fn isStateDir(state_dirs: []const []const u8, name: []const u8) bool {
    for (state_dirs) |dir| {
        if (std.mem.eql(u8, dir, name)) return true;
    }
    return false;
}

fn isDir(io: std.Io, entry: std.Io.Dir.Walker.Entry) bool {
    const st = entry.dir.statFile(io, entry.basename, .{}) catch return false;
    return st.kind == .directory;
}

/// Lowercase hex SHA-256 of the file `name` in `dir`, read in chunks.
fn hashFile(io: std.Io, dir: std.Io.Dir, name: []const u8, out: *[64]u8) !void {
    var file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        sha.update(chunk);
        reader.interface.toss(chunk.len);
    }
    out.* = std.fmt.bytesToHex(sha.finalResult(), .lower);
}
