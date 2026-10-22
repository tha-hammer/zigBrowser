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
const builtin = @import("builtin");
const ledger = @import("agent_run_ledger");

const c = @cImport({
    @cInclude("agent_run_reaper.h");
});

pub const DirId = c.struct_zb_reaper_dir_id;

// AT_REMOVEDIR differs by platform (Linux 0x200, Darwin 0x02); define it portably so the macOS build is correct.
const AT_REMOVEDIR: u32 = if (builtin.os.tag == .linux) 0x200 else 0x02;

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
        name_buf: [320]u8,
        name_len: usize,

        const Self = @This();

        fn nameZ(self: *Self) [:0]const u8 {
            self.name_buf[self.name_len] = 0;
            return self.name_buf[0..self.name_len :0];
        }

        pub fn fixedPoint(self: *Self, clock: anytype, deadline_ms: i64) ledger.FixedPoint {
            // The census/kill runs through the reviewed engine over the HELD fd + pinned id (so a swapped path can
            // never redirect a kill); the Wiring supplies the clock, scan/inspect/kill (libproc+real kill in
            // production, scripted + intercepted-count in tests) and the real dir-fd revalidation, all bounded by
            // the one absolute deadline.
            return self.wiring.run(clock, self.run_dir_fd, &self.pinned, deadline_ms);
        }

        /// True iff the basename, reopened O_NOFOLLOW under the pinned parent RIGHT NOW, is the SAME inode the lease
        /// holds (same pinned (dev,ino,uid,mode)). Defends the by-name `rmdir` against a rename+empty-replacement
        /// swap, which otherwise resolves to a DIFFERENT inode (RoseCat 671c986 #1). Uses the reviewed C.
        fn nameMatchesHeld(self: *Self) bool {
            const fd = std.posix.openatZ(self.runtime_fd, self.nameZ(), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch return false;
            defer _ = std.posix.system.close(fd);
            var id: DirId = undefined;
            if (c.zb_reaper_pin_fd(fd, &id) != 0) return false;
            return c.zb_reaper_dir_id_eq(&id, &self.pinned) != 0;
        }

        pub fn teardown(self: *Self, clock: anytype, deadline_ms: i64) ledger.Teardown {
            if (clock.nowMs() >= deadline_ms) return .failed; // no destructive mutation past the one absolute deadline
            // (1) marker unlink THROUGH the held run-dir fd (fd-safe: a rename of the dir cannot redirect it);
            // ENOENT is idempotent (crash cut C2), not a failure. `std.posix.system.*` + `std.posix.errno` resolve
            // to the raw syscall on Linux and libc on Darwin, so this builds and behaves the same on macOS.
            switch (std.posix.errno(std.posix.system.unlinkat(self.run_dir_fd, "run.marker", 0))) {
                .SUCCESS, .NOENT => {},
                else => return .failed,
            }
            // Expiry BETWEEN the marker unlink and the rmdir must preserve the C2 state (marker gone, dir kept) and
            // fail closed -- the next recovery finds a marker-less dir and tears it down idempotently.
            if (clock.nowMs() >= deadline_ms) return .failed;
            // (2) `rmdir` has no fd form, so revalidate the NAME against the held pinned identity IMMEDIATELY before
            // removal: a rename + empty-replacement at the same basename resolves to a different inode, which we
            // refuse rather than remove.
            if (!self.nameMatchesHeld()) return .failed;
            switch (std.posix.errno(std.posix.system.unlinkat(self.runtime_fd, self.nameZ(), AT_REMOVEDIR))) {
                .SUCCESS, .NOENT => return .done, // already gone -> idempotent
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
            var nb: [320]u8 = undefined;
            const name = basenameZ(entry, &nb) orelse return .mismatch;
            // The unreadable/mismatch distinction is carried by the OPEN (RoseCat 671c986 #4): ENOENT -> gone (C3);
            // a non-dir/symlink at the name -> mismatch; any OTHER open failure (EBADF/EACCES/EIO/EMFILE/...) means
            // the identity could not be read at all -> unreadable. After a SUCCESSFUL open the fd is readable, so a
            // nonzero `zb_reaper_pin_fd` is a shape/identity REFUSAL (not a dir / wrong uid / not 0700) -> mismatch,
            // never conflated with the unreadable case.
            const fd = std.posix.openatZ(dir.handle, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch |e| switch (e) {
                error.FileNotFound => return .gone, // ENOENT -> crash cut C3
                error.NotDir, error.SymLinkLoop => return .mismatch, // a non-dir / symlink at the name -> never sweep
                else => return .unreadable, // could not even open/read the identity
            };
            var id: DirId = undefined;
            if (c.zb_reaper_pin_fd(fd, &id) != 0) {
                _ = std.posix.system.close(fd);
                return .mismatch; // readable fd, but not a dir / wrong uid / not 0700 -> shape/identity refusal
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
