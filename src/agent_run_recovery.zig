//! MS6.5.1 whole-recovery blocker bd zigBrowser-3gl, finding RoseCat 9f62ea4 #1/#4: the CONCRETE, capability-
//! carrying `RecoveryLease` + actuator for `ledger.recoverOneUnderLock`. NOT ARMED — no production caller wires
//! this in, and there is still no `reaper_ready` gate. It wraps the already-reviewed reaper/provenance C path
//! (`src/agent_run_reaper.c`): provenance is `zb_reaper_pin_fd` + `zb_reaper_dir_id_eq` on a freshly reopened
//! `O_DIRECTORY|O_NOFOLLOW` run-dir fd; the lease RETAINS that fd (and borrows the pinned runtime-parent fd for
//! `rmdir`), so the provenance check and the destructive teardown cannot be separated by a path swap. The
//! census->kill->fresh-census fixed point runs through an injected `Wiring` that calls the reviewed
//! `zb_reaper_fixed_point` over the HELD fd — production wires libproc + the real kill; tests wire a scripted scan
//! + an INTERCEPTED (counting, never-signalling) kill, which is how the reaper engine is proven on Linux.
const std = @import("std");
const ledger = @import("agent_run_ledger");
const linux = std.os.linux;

const c = @cImport({
    @cInclude("agent_run_reaper.h");
});

pub const DirId = c.struct_zb_reaper_dir_id;

/// Pin a run dir's identity via the reviewed C (open O_DIRECTORY|O_NOFOLLOW relative to `dir`, then
/// `zb_reaper_pin_fd`). Returns the pinned `(dev,ino,uid,mode)` or null. Exposed so a test can seed a ledger entry
/// that matches exactly what `pin` will provenance-check, without a second `@cImport` of its own.
pub fn pinDir(dir: std.Io.Dir, name_z: [:0]const u8) ?DirId {
    const fd = std.posix.openatZ(dir.handle, name_z, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch return null;
    defer _ = std.posix.system.close(fd);
    var id: DirId = undefined;
    if (c.zb_reaper_pin_fd(fd, &id) != 0) return null;
    return id;
}

fn basenameZ(entry: ledger.Entry, buf: []u8) ?[:0]const u8 {
    if (entry.basename.len >= buf.len) return null;
    @memcpy(buf[0..entry.basename.len], entry.basename);
    buf[entry.basename.len] = 0;
    return buf[0..entry.basename.len :0];
}

/// A CONCRETE lease over the HELD run-dir fd. `fixedPoint` runs the reviewed `zb_reaper_fixed_point` (via the
/// injected `Wiring`) over the held fd; `teardown` unlinks the marker and `rmdir`s the run dir through the held fds
/// and is idempotent on `ENOENT` (crash cut C2); `deinit` closes the fd the lease owns (never the borrowed parent).
pub fn ConcreteLease(comptime Wiring: type) type {
    return struct {
        runtime_fd: i32, // BORROWED pinned parent authority (for rmdir by name); never closed here
        run_dir_fd: i32, // OWNED held run-dir fd (O_DIRECTORY|O_NOFOLLOW); closed in deinit
        pinned: DirId,
        wiring: Wiring,
        name_buf: [64]u8,
        name_len: usize,

        const Self = @This();

        fn nameZ(self: *Self) [:0]const u8 {
            self.name_buf[self.name_len] = 0;
            return self.name_buf[0..self.name_len :0];
        }

        pub fn fixedPoint(self: *Self, clock: anytype, deadline_ms: i64) ledger.FixedPoint {
            _ = clock;
            // The census/kill runs through the reviewed engine over the HELD fd + pinned id (so a swapped path can
            // never redirect a kill); the Wiring supplies the scan/inspect/kill (libproc+real kill in production,
            // scripted + intercepted-count in tests) and the real dir-fd revalidation.
            return self.wiring.run(self.run_dir_fd, &self.pinned, deadline_ms);
        }

        pub fn teardown(self: *Self, clock: anytype, deadline_ms: i64) ledger.Teardown {
            _ = clock;
            _ = deadline_ms;
            // marker unlink THROUGH the held run-dir fd; ENOENT is idempotent (crash cut C2), not a failure.
            switch (linux.errno(linux.unlinkat(self.run_dir_fd, "run.marker", 0))) {
                .SUCCESS, .NOENT => {},
                else => return .failed,
            }
            // rmdir the now-empty run dir BY NAME relative to the borrowed pinned parent fd; ENOENT idempotent.
            switch (linux.errno(linux.unlinkat(self.runtime_fd, self.nameZ(), linux.AT.REMOVEDIR))) {
                .SUCCESS, .NOENT => return .done,
                else => return .failed,
            }
        }

        pub fn deinit(self: *Self) void {
            if (self.run_dir_fd >= 0) {
                _ = std.posix.system.close(self.run_dir_fd);
                self.run_dir_fd = -1;
            }
        }
    };
}

/// The CONCRETE actuator. `pin` reopens the run dir `O_DIRECTORY|O_NOFOLLOW` relative to the runtime dir and
/// verifies its pinned `(dev,ino,uid,mode)` equals the recorded entry via the reviewed C. The tagged result
/// distinguishes the crash cut `gone` (ENOENT → C3) from `mismatch`/`unreadable` (never sweep).
pub fn ConcreteActuator(comptime Wiring: type) type {
    return struct {
        wiring: Wiring,
        const Self = @This();
        pub const Lease = ConcreteLease(Wiring);
        pub const Pin = union(enum) { held: Lease, gone, mismatch, unreadable };

        pub fn pin(self: Self, dir: std.Io.Dir, entry: ledger.Entry) Pin {
            var nb: [64]u8 = undefined;
            const name = basenameZ(entry, &nb) orelse return .mismatch;
            const fd = std.posix.openatZ(dir.handle, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch |e| switch (e) {
                error.FileNotFound => return .gone, // ENOENT -> crash cut C3
                error.NotDir, error.SymLinkLoop => return .mismatch, // a non-dir / symlink replaced it -> never sweep
                else => return .unreadable,
            };
            var id: DirId = undefined;
            if (c.zb_reaper_pin_fd(fd, &id) != 0) {
                _ = std.posix.system.close(fd);
                return .mismatch; // not a dir / wrong uid / not 0700
            }
            var rec: DirId = .{ .dev = entry.dev, .ino = entry.ino, .uid = entry.uid, .mode = entry.mode };
            if (c.zb_reaper_dir_id_eq(&id, &rec) == 0) {
                _ = std.posix.system.close(fd);
                return .mismatch; // (dev,ino,uid,mode) != recorded -> never sweep
            }
            var lease = Lease{
                .runtime_fd = dir.handle,
                .run_dir_fd = fd,
                .pinned = id,
                .wiring = self.wiring,
                .name_buf = undefined,
                .name_len = entry.basename.len,
            };
            @memcpy(lease.name_buf[0..entry.basename.len], entry.basename);
            return .{ .held = lease };
        }
    };
}

/// The PRODUCTION census wiring: the reviewed `zb_reaper_fixed_point` over the held fd, with libproc (`scan`) and
/// the REAL kill. Not reachable until armed; defined here so production and the test share one lease shape. The
/// `scan`/`ops` function pointers are supplied by the platform layer that owns libproc; this struct only threads
/// the held fd + pinned id into the real dir-fd revalidation. (Mac-only to actually run; unused on Linux.)
pub const dummy = {}; // placeholder: the production libproc wiring lands with the Darwin reaper hookup, still unarmed.
