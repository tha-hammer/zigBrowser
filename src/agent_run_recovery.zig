//! MS6.5.1 whole-recovery blocker bd zigBrowser-3gl, finding RoseCat 9f62ea4 #1/#4: the CONCRETE, capability-
//! carrying `RecoveryLease` + actuator for `ledger.recoverOneUnderLock`. NOT ARMED — the `reaper_ready` gate ships
//! false and no production app-startup owner calls `recoverAllAtStartup` yet. It wraps the already-reviewed reaper/provenance C path
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

/// Portable `fstat` of a held fd, returning its link count, or null if the stat itself fails. Linux uses `statx`
/// on the fd (AT_EMPTY_PATH); Darwin uses libc `fstat`. Used both to probe readability (null => unreadable) and to
/// verify a removed directory's inode is gone (nlink == 0).
fn fstatNlink(fd: i32) ?u64 {
    if (builtin.os.tag == .linux) {
        var sx: std.os.linux.Statx = undefined;
        const AT_EMPTY_PATH: u32 = 0x1000;
        if (std.os.linux.errno(std.os.linux.statx(fd, "", AT_EMPTY_PATH, std.os.linux.STATX.BASIC_STATS, &sx)) != .SUCCESS) return null;
        return sx.nlink;
    } else {
        var st: std.c.Stat = undefined;
        if (std.posix.errno(std.c.fstat(fd, &st)) != .SUCCESS) return null;
        return @intCast(st.nlink);
    }
}

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
        window_hook: ?*const fn () void = null, // TEST-ONLY: null in production; a test injects a check/use-window swap

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

        /// True iff the HELD run-dir inode is now unlinked (nlink == 0). After a by-name `rmdir`, this proves it
        /// was OUR inode that went away — not a replacement swapped in during the check/use window (RoseCat
        /// 30afe68 #1). A stat failure is NOT proven-gone -> false (fail closed).
        fn heldInodeGone(self: *Self) bool {
            const nlink = fstatNlink(self.run_dir_fd) orelse return false;
            return nlink == 0;
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
            // Pre-filter: refuse if the name ALREADY resolves to a different inode (an obvious prior swap).
            if (!self.nameMatchesHeld()) return .failed;
            // TEST-ONLY check/use-window hook (null in production): a test injects a swap HERE, after the pre-filter
            // and before the rmdir, to prove the post-rmdir held-inode verification below catches it.
            if (self.window_hook) |h| h();
            // Recheck the absolute deadline IMMEDIATELY before the destructive rmdir -- after the re-open/fstat of
            // the pre-filter, which can itself cross the deadline (RoseCat 30afe68 #2).
            if (clock.nowMs() >= deadline_ms) return .failed;
            // (2) `rmdir` by name (there is no fd form).
            switch (std.posix.errno(std.posix.system.unlinkat(self.runtime_fd, self.nameZ(), AT_REMOVEDIR))) {
                .SUCCESS, .NOENT => {},
                else => return .failed,
            }
            // (3) POST-VERIFY via the HELD fd that OUR inode is the one gone. If a swap happened in the check/use
            // window, the by-name rmdir removed a DIFFERENT inode and ours survives (nlink > 0) -> fail closed, so
            // the caller NEVER retires an entry whose real run dir is still present (RoseCat 30afe68 #1).
            return if (self.heldInodeGone()) .done else .failed;
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
        window_hook: ?*const fn () void = null, // TEST-ONLY: forwarded to the lease; null in production
        probe: *const fn (i32) ?u64 = &fstatNlink, // the post-open readability probe; a test injects a failing one
        const Self = @This();
        pub const Lease = ConcreteLease(Wiring);
        pub const Pin = union(enum) { held: Lease, gone, mismatch, unreadable };

        pub fn pin(self: Self, dir: std.Io.Dir, entry: ledger.Entry) Pin {
            var nb: [320]u8 = undefined;
            const name = basenameZ(entry, &nb) orelse return .mismatch;
            // The unreadable/mismatch distinction (RoseCat 671c986 #4 / 30afe68 #3): ENOENT -> gone (C3); a
            // non-dir/symlink at the name -> mismatch; any OTHER open failure -> unreadable. Then, before the
            // reviewed shape/identity check (whose EINVAL cannot tell fstat-failure from a refusal), probe the
            // opened fd with a plain fstat: a FAILURE there is unreadable (identity cannot be read); only a
            // readable fd that `zb_reaper_pin_fd` then refuses is a shape/identity mismatch.
            const fd = std.posix.openatZ(dir.handle, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch |e| switch (e) {
                error.FileNotFound => return .gone, // ENOENT -> crash cut C3
                error.NotDir, error.SymLinkLoop => return .mismatch, // a non-dir / symlink at the name -> never sweep
                else => return .unreadable, // could not even open the identity
            };
            if (self.probe(fd) == null) {
                _ = std.posix.system.close(fd);
                return .unreadable; // opened, but the identity could not be fstat'd -> unreadable, not mismatch
            }
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
                .window_hook = self.window_hook,
            };
            @memcpy(lease.name_buf[0..entry.basename.len], entry.basename);
            return .{ .held = lease };
        }
    };
}

// ---- the reviewed census/kill/fresh-census over the HELD fd (RoseCat 671c986 #5) --------------------------------
// `runFixedPoint` runs `zb_reaper_fixed_point` with the real `dir_ok` revalidation bound to the HELD run-dir fd +
// pinned id, so a swapped path can never redirect a kill. The scan/inspect/killsig are INJECTED: production wires
// libproc + the real kill; tests wire a scripted scan + an INTERCEPTED (counting, never-signalling) kill, which is
// exactly how the reaper engine is proven on Linux. The `user` ctx is passed to inspect/killsig via `OpsCtx.user`.

pub const ReaperId = c.struct_zb_reaper_id;
pub const pid_t = c.pid_t;
pub const ScanFn = *const fn (?*anyopaque, c_int) callconv(.c) c_int;
pub const InspectFn = *const fn (c.pid_t, [*c]const u8, [*c]ReaperId, ?*anyopaque) callconv(.c) void;
pub const KillFn = *const fn (c.pid_t, c_int, ?*anyopaque) callconv(.c) c_int;

/// Threaded through the ops `ctx`: the HELD run-dir fd + pinned id for the real `dir_ok`, plus the injected `user`.
/// `now`/`deadline_ms` thread the ONE absolute deadline THROUGH the kill boundary (RoseCat 0b7805a #1): `dir_ok`
/// runs immediately before each `killsig`, so a deadline crossed mid-census stops the engine there with NO kill.
pub const NowFn = *const fn () callconv(.c) i64;
pub const OpsCtx = extern struct { held_fd: c_int, pinned: DirId, user: ?*anyopaque, now: ?NowFn = null, deadline_ms: i64 = 0 };

fn dirOkThunk(ctx: ?*anyopaque) callconv(.c) c_int {
    const o: *OpsCtx = @ptrCast(@alignCast(ctx.?));
    if (o.now) |nf| if (nf() >= o.deadline_ms) return 0; // deadline crossed before this kill -> engine overflows + breaks
    return c.zb_reaper_dir_fd_ok(o.held_fd, &o.pinned); // revalidate the HELD fd immediately before each kill
}

/// A real CLOCK_MONOTONIC reader in C-callable form, for the production/generic census now-fn. Per-OS so it builds
/// on Darwin (Linux raw syscall; Darwin libc), mirroring the ledger's RealClock.
/// The result of one monotonic clock read: `ok=false` means the syscall failed and the timespec is NOT read.
pub const ClockRead = struct { ok: bool, sec: i64, nsec: i64 };

/// The deadline-safe mapping from a clock read to ms (RoseCat afdffbf #4): a FAILED read saturates, so the deadline
/// always reads as crossed and no signal/Clean can follow. This is the exact branch `realNowMs` uses; an injected
/// failing/succeeding `read` drives both arms causally (the real syscall failure is otherwise unforceable).
pub fn nowMsFrom(read: *const fn () ClockRead) i64 {
    const r = read();
    if (!r.ok) return std.math.maxInt(i64); // clock read failed -> fail closed (deadline crossed)
    return r.sec * 1000 + @divTrunc(r.nsec, 1_000_000);
}

/// The real CLOCK_MONOTONIC read; on syscall failure it returns `.ok=false` WITHOUT reading the undefined timespec.
pub fn realClockRead() ClockRead {
    if (builtin.os.tag == .linux) {
        var ts: std.os.linux.timespec = undefined;
        if (std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts) != 0) return .{ .ok = false, .sec = 0, .nsec = 0 };
        return .{ .ok = true, .sec = @as(i64, ts.sec), .nsec = @as(i64, ts.nsec) };
    } else {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return .{ .ok = false, .sec = 0, .nsec = 0 };
        return .{ .ok = true, .sec = @as(i64, @intCast(ts.sec)), .nsec = @as(i64, @intCast(ts.nsec)) };
    }
}

/// The production monotonic now-fn in C-callable form: the real reader through the fail-closed mapping.
pub fn realNowMs() callconv(.c) i64 {
    return nowMsFrom(&realClockRead);
}

/// Run the reviewed `zb_reaper_fixed_point` census->kill->fresh-census over the held fd. Clean iff the complete
/// empty final census; any engine error/overflow -> incomplete; else survivors (never a clean result on doubt).
pub fn runFixedPoint(now: NowFn, deadline_ms: i64, run_dir_fd: i32, pinned: *const DirId, dir_path: [*:0]const u8, max_passes: c_int, scan: ScanFn, inspect: InspectFn, killsig: KillFn, user: ?*anyopaque) ledger.FixedPoint {
    // The ONE absolute deadline bounds the census: past expiry we neither inspect nor act (RoseCat e034dda #1 /
    // 0b7805a #1). Checked pre-engine AND, through `dir_ok`, immediately before each kill. A census past the
    // deadline is NOT clean -> incomplete, so the caller fails closed.
    if (now() >= deadline_ms) return .incomplete;
    var octx = OpsCtx{ .held_fd = run_dir_fd, .pinned = pinned.*, .user = user, .now = now, .deadline_ms = deadline_ms };
    var ops = c.struct_zb_reaper_ops{ .inspect = inspect, .killsig = killsig, .dir_ok = &dirOkThunk, .ctx = &octx };
    var clean: c_int = 0;
    var passes: c_int = 0;
    var overflow: c_int = 0;
    const rc = c.zb_reaper_fixed_point(scan, &ops, dir_path, max_passes, &clean, &passes, &overflow);
    if (rc != 0 or overflow != 0) return .incomplete;
    return if (clean != 0) .clean else .survivors;
}

// ---- the Darwin PRODUCTION census actuator (RoseCat 9e19fd0 / afdffbf) ----------------------------------------
// A thin Mac-only binder over the ONE capability composite `zb_reaper_prod_fixed_point` (RoseCat afdffbf #1): it
// derives the held inode's CURRENT path and calls the composite, which consumes the held fd + pinned identity + the
// ONE absolute deadline, revalidates them before the engine AND again before Clean, and runs the reviewed
// `zb_reaper_fixed_point`. No raw signal is exposed and no second algorithm exists here — the decision, the
// grammar/pin/deadline capability and the kill all live in the reviewed C. The capability logic is portable and is
// exercised on Linux through `prodFixedPoint` with the kill intercepted (RoseCat afdffbf #2/#3). NOT ARMED: the
// `reaper_ready` gate ships false and no app-startup owner calls `recoverAllAtStartup`, so production recovery is
// unreachable. Mac-only; every other target comptime-prunes the body and fails closed.

const PATH_MAX = 4096;

/// Map the composite's (rc, clean, overflow) to the ledger outcome: Clean only on a revalidated empty census; a
/// crossed deadline / incomplete / overflow -> incomplete; any other nonzero or non-clean -> survivors. Never Clean
/// on doubt.
fn mapProd(rc: c_int, clean: c_int, overflow: c_int) ledger.FixedPoint {
    if (overflow != 0) return .incomplete;
    if (rc != 0) return .survivors; // EINVAL (bad grammar/pin) etc: fail closed, never Clean
    return if (clean != 0) .clean else .survivors;
}

/// The Linux-testable production seam (RoseCat afdffbf #3): drive the REAL capability composite
/// `zb_reaper_prod_fixed_point` with injected scan/inspect/killsig (the kill intercepted on Linux) so the grammar,
/// up-front + final pin/deadline revalidation and callback selection are all causally exercised. Production (Darwin)
/// reaches the same composite through `zb_reaper_prod_recover`, which binds the file-private real callbacks.
pub fn prodFixedPoint(scan: ScanFn, inspect: InspectFn, killsig: KillFn, run_dir_fd: i32, pinned: *const DirId, now: NowFn, deadline_ms: i64, dir_path: [*:0]const u8, max_passes: c_int) ledger.FixedPoint {
    return prodFixedPointRc(scan, inspect, killsig, run_dir_fd, pinned, now, deadline_ms, dir_path, max_passes).@"1";
}

/// As `prodFixedPoint`, but takes an OPTIONAL clock and returns the raw C rc alongside the mapped outcome, so the
/// null-clock boundary row (RoseCat afdffbf #1) can assert the composite rejects a null deadline capability with
/// EINVAL before any callback runs.
pub fn prodFixedPointRc(scan: ScanFn, inspect: InspectFn, killsig: KillFn, run_dir_fd: i32, pinned: *const DirId, now: ?NowFn, deadline_ms: i64, dir_path: [*:0]const u8, max_passes: c_int) struct { c_int, ledger.FixedPoint } {
    var clean: c_int = 0;
    var passes: c_int = 0;
    var overflow: c_int = 0;
    const rc = c.zb_reaper_prod_fixed_point(scan, inspect, killsig, run_dir_fd, pinned, now, deadline_ms, dir_path, max_passes, &clean, &passes, &overflow);
    return .{ rc, mapProd(rc, clean, overflow) };
}

/// The Darwin production census/sweep over the HELD run-dir fd. `max_passes` bounds the fixed point; the real kill
/// only runs on a Mac (every Linux signal is intercepted, and no caller invokes this yet).
pub fn darwinCensus(run_dir_fd: i32, pinned: *const DirId, deadline_ms: i64, max_passes: c_int) ledger.FixedPoint {
    if (builtin.os.tag == .macos) {
        var buf: [PATH_MAX]u8 = undefined;
        const F_GETPATH: i32 = 50; // Darwin: the held inode's CURRENT path (swap-immune); the composite grammar-checks it
        if (std.posix.errno(std.posix.system.fcntl(run_dir_fd, F_GETPATH, @as(usize, @intFromPtr(&buf)))) != .SUCCESS) return .incomplete;
        const dir: [*:0]const u8 = @ptrCast(&buf);
        var clean: c_int = 0;
        var passes: c_int = 0;
        var overflow: c_int = 0;
        const rc = c.zb_reaper_prod_recover(run_dir_fd, pinned, &realNowMs, deadline_ms, dir, max_passes, &clean, &passes, &overflow);
        return mapProd(rc, clean, overflow);
    }
    return .incomplete; // unreachable off Darwin
}

// ---- MS6.5.1 reaper_ready arming gate + startup-recovery CORE (bd zigBrowser-3gl). UNARMED (reaper_ready default
// false). SCOPE: startup-recovery CORE; a real app-startup owner calling recoverAllAtStartup is an OPEN integration
// blocker, not this slice. ----

/// IMMUTABLE arming gate: a literal source constant, default FALSE. Readiness is bound SOLELY to this constant — no
/// environment variable, command-line argument or build flag can arm it. Flipping it is a reviewed SOURCE edit.
pub const reaper_ready: bool = false;

/// Per-start entry cap (positive, bounded): at most this many ACTIVE entries are recovered in one startup pass; the
/// rest are DEFERRED (retained + reported). The plan selects 64.
pub const MAX_RECOVER_PER_START: usize = 64;

pub const StartupStatus = enum { disabled, ran };

pub const StartupReport = struct {
    status: StartupStatus,
    scanned: usize = 0,
    signalled: usize = 0,
    left: usize = 0,
    already_gone: usize = 0,
    reconciled: usize = 0,
    fail_closed: usize = 0,
    deferred: usize = 0,
    load_failed: bool = false,
    pub fn ok(self: StartupReport) bool {
        return !self.load_failed and self.fail_closed == 0;
    }
};

/// The production ledger loader; the injectable seam lets a test prove gate-off performs NO read (zero loads).
pub const RealLoader = struct {
    pub fn load(_: RealLoader, io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ledger.ParseError!ledger.Ledger {
        return ledger.load(io, gpa, dir, sub_path);
    }
};

/// The PRODUCTION startup caller: readiness is `reaper_ready` and nothing else.
pub fn recoverAllAtStartup(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8, clock: anytype, deadline_ms: i64, actuator: anytype) StartupReport {
    return recoverAllAtStartupFull(reaper_ready, io, gpa, dir, sub_path, clock, deadline_ms, actuator, RealLoader{}, null);
}
pub fn recoverAllAtStartupGated(ready: bool, io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8, clock: anytype, deadline_ms: i64, actuator: anytype) StartupReport {
    return recoverAllAtStartupFull(ready, io, gpa, dir, sub_path, clock, deadline_ms, actuator, RealLoader{}, null);
}
pub fn recoverAllAtStartupGatedH(ready: bool, io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8, clock: anytype, deadline_ms: i64, actuator: anytype, window_hook: ?*const fn () void) StartupReport {
    return recoverAllAtStartupFull(ready, io, gpa, dir, sub_path, clock, deadline_ms, actuator, RealLoader{}, window_hook);
}

/// The gated core. Startup ORDER: (1) consult the gate — while false, return `.disabled` BEFORE any load or actuator
/// touch (the injected `loader` is never called); (2) load via the loader — a parse/read error fails closed; (3) for
/// each ACTIVE entry, bounded by the per-start cap AND the one absolute deadline (checked every iteration against the
/// SAME `deadline_ms`, never reset per entry), run `recoverOneUnderLock`; a cap/deadline stop DEFERS the remaining
/// active entries (retained + reported); (4) tally; a `.fail_closed` entry keeps the entry and makes the report
/// non-ok, never hidden by `ran`. `window_hook` fires once after the snapshot (test seam for the concurrent-retire
/// window); production passes null.
pub fn recoverAllAtStartupFull(ready: bool, io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8, clock: anytype, deadline_ms: i64, actuator: anytype, loader: anytype, window_hook: ?*const fn () void) StartupReport {
    if (!ready) return .{ .status = .disabled }; // (1) GATE FIRST: no load, no actuator, no mutation

    var rep = StartupReport{ .status = .ran };
    var l = loader.load(io, gpa, dir, sub_path) catch {
        rep.load_failed = true; // (2) missing/corrupt/unreadable -> fail closed, no entry acted upon
        return rep;
    };
    defer l.deinit();

    if (window_hook) |h| h();

    const ents = l.entries();
    for (ents, 0..) |e, i| {
        if (e.state != .active) continue;
        if (rep.scanned >= MAX_RECOVER_PER_START or clock.nowMs() >= deadline_ms) { // (3) cap + ONE absolute deadline
            var j = i;
            while (j < ents.len) : (j += 1) {
                if (ents[j].state == .active) rep.deferred += 1;
            }
            break;
        }
        rep.scanned += 1;
        switch (ledger.recoverOneUnderLock(io, gpa, dir, sub_path, e.basename, clock, deadline_ms, actuator)) { // (4)
            .signalled => rep.signalled += 1,
            .left => rep.left += 1,
            .already_gone => rep.already_gone += 1,
            .reconciled => rep.reconciled += 1,
            .fail_closed => rep.fail_closed += 1,
        }
    }
    return rep;
}
