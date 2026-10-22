//! MS6.5.1 the run ledger (the app-owned recovery store `<runtime_dir>/zigbrowser-agent-runs.json`), parse half.
//! The owner (the macOS agent-run host) reads this at start to recover leftover runs. The parse is VERSIONED,
//! STRICTLY typed, and BOUNDED: an unknown version, an over-cap array, a missing/extra/mistyped field, a bad
//! `state`, a duplicate basename, or any truncated/unparseable input is rejected — a malformed ledger NEVER
//! yields entries that could authorize a signal (the caller census/warns instead). Pure/portable; the atomic
//! publish, the cross-process flock and the fd-level provenance decision (C `zb_reaper_ledger_entry_state`) are
//! separate.
const std = @import("std");
const builtin = @import("builtin");

/// The only accepted schema version. A different value is a malformed read (never silently upgraded/downgraded).
/// v2 (2026-10-22) added the platform-tagged owner-start identity (`start_kind`); v1 is no longer accepted.
pub const SCHEMA_VERSION: u32 = 2;
/// The bounded cap on recovered entries (RoseCat SHOULD: bound the number of startup dirs).
pub const MAX_ENTRIES: usize = 256;
/// The fixed maximum run-dir basename length: "zigbrowser-agent-" (17) + up to 10 pid digits + "-" + 16 hex = 44.
pub const MAX_BASENAME: usize = 44;
/// A finite maximum ledger document size, derived from the fixed field lengths x MAX_ENTRIES plus structural
/// overhead. Any input larger than this is rejected BEFORE allocation, so a corrupt/hostile file (millions of
/// entries, or one huge string) can never allocate/work without bound (RoseCat 7458 #2).
pub const MAX_LEDGER_BYTES: usize = 64 * 1024;

pub const State = enum { active, left };

/// The PLATFORM that produced the recorded owner-start identity, so a start value is only ever compared against a
/// live value of the SAME kind (never converted). `linux_ticks`: `/proc/<pid>/stat` field 22 (starttime ticks),
/// carried in `start_sec` (`start_usec` unused, 0). `darwin_tvsec`: proc_pidinfo PROC_PIDTBSDINFO, carried as
/// `(start_sec, start_usec)` = `(pbi_start_tvsec, pbi_start_tvusec)`. std.json rejects any other string.
pub const StartKind = enum { linux_ticks, darwin_tvsec };

/// One recorded run. Every field is required and strictly typed; std.json rejects a missing/extra/mistyped field,
/// an unknown `state`, and an unknown `start_kind`.
pub const Entry = struct {
    basename: []const u8,
    dev: u64,
    ino: u64,
    uid: u32,
    mode: u32,
    pid: i32,
    start_kind: StartKind,
    start_sec: u64,
    start_usec: u64,
    state: State,
};

const Doc = struct {
    schema_version: u32,
    runs: []Entry,
};

pub const ParseError = error{ Malformed, TooManyEntries, DuplicateBasename } || std.mem.Allocator.Error;

/// A parsed, validated ledger. `entries()` are the recorded runs; `deinit()` frees them.
pub const Ledger = struct {
    parsed: std.json.Parsed(Doc),

    pub fn entries(self: *const Ledger) []const Entry {
        return self.parsed.value.runs;
    }
    pub fn deinit(self: *Ledger) void {
        self.parsed.deinit();
    }
};

/// The fixed-length, single-component run-dir grammar `zigbrowser-agent-<decimal pid>-<16 lowercase hex>`
/// (the Zig twin of C `name_is_sockdir`), length-bounded by MAX_BASENAME. Rejects a wrong prefix, a non-decimal
/// pid, a wrong hex length, uppercase hex, and — being a single component with no interior '.'/'/' — a dot,
/// an embedded slash, an absolute path, and anything oversized. A malformed basename makes the whole ledger a
/// malformed read (RoseCat 0d2e91d #1).
fn basenameOk(s: []const u8) bool {
    const sig = "zigbrowser-agent-";
    if (s.len > MAX_BASENAME) return false;
    if (!std.mem.startsWith(u8, s, sig)) return false;
    var i: usize = sig.len;
    const pid_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == pid_start) return false; // at least one decimal pid digit
    if (i >= s.len or s[i] != '-') return false;
    i += 1;
    if (s.len - i != 16) return false; // exactly 16 hex after the dash, nothing more
    var k: usize = 0;
    while (k < 16) : (k += 1) {
        const c = s[i + k];
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false; // lowercase hex only
    }
    return true;
}

/// Read and parse the ledger from the held runtime dir, BOUNDING the input before unbounded allocation (RoseCat
/// 0d2e91d #2): the read is size-limited to MAX_LEDGER_BYTES, so a hostile file (millions of entries, one huge
/// string) is rejected (`TooManyEntries`) rather than read/allocated without bound. Then `parse` the bounded
/// bytes. A missing/unreadable/over-limit file never yields entries.
pub fn load(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, sub_path: []const u8) ParseError!Ledger {
    // Size-limited read: `.limited(MAX_LEDGER_BYTES)` returns error.StreamTooLong once the file reaches the
    // bound, so a hostile file never allocates/reads past it. Over-limit -> TooManyEntries; any other read/open
    // failure (missing, unreadable, ...) -> Malformed (never entries).
    const text = dir.readFileAlloc(io, sub_path, gpa, .limited(MAX_LEDGER_BYTES)) catch |e| switch (e) {
        error.StreamTooLong => return error.TooManyEntries,
        else => return error.Malformed,
    };
    defer gpa.free(text);
    return parse(gpa, text);
}

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Ledger {
    // STRICT: `.{}` keeps ignore_unknown_fields=false, so an extra field, a missing field, a mistyped field, an
    // unknown `state` and any truncated/unparseable input all error -> Malformed. A JSON object with a duplicate
    // key also errors here. The version, cap and duplicate-basename checks are explicit below.
    // .alloc_always so the returned Ledger OWNS copies of every string (basename/state) rather than aliasing
    // `bytes` — `load` frees its read buffer immediately after, so an aliasing parse would dangle.
    const parsed = std.json.parseFromSlice(Doc, gpa, bytes, .{ .allocate = .alloc_always }) catch return error.Malformed;
    if (parsed.value.schema_version != SCHEMA_VERSION) {
        parsed.deinit();
        return error.Malformed; // an unknown version is never silently upgraded/downgraded
    }
    const runs = parsed.value.runs;
    if (runs.len > MAX_ENTRIES) {
        parsed.deinit();
        return error.TooManyEntries; // bounded: a corrupt/hostile over-long ledger is refused, not truncated
    }
    for (runs) |e| {
        if (!basenameOk(e.basename)) {
            parsed.deinit();
            return error.Malformed; // a malformed basename makes the WHOLE ledger a malformed read
        }
        // Each start_kind has ONE legal shape (RoseCat 0e36742): linux_ticks is a bare tick count with NO
        // microseconds (start_usec MUST be 0); darwin_tvsec's start_usec is a real microseconds value in
        // [0, 999999]. An impossible identity is a malformed read — never a trusted owner start.
        const canonical = switch (e.start_kind) {
            .linux_ticks => e.start_usec == 0,
            .darwin_tvsec => e.start_usec <= 999_999,
        };
        if (!canonical) {
            parsed.deinit();
            return error.Malformed;
        }
    }
    var i: usize = 0;
    while (i < runs.len) : (i += 1) {
        var j: usize = i + 1;
        while (j < runs.len) : (j += 1) {
            if (std.mem.eql(u8, runs[i].basename, runs[j].basename)) {
                parsed.deinit();
                return error.DuplicateBasename; // two entries claiming one run dir: neither is trustworthy
            }
        }
    }
    return .{ .parsed = parsed };
}

/// A crash cut for `publishCut`, so a test can stop the atomic publish mid-way and inspect the on-disk store.
pub const Cut = enum { none, after_temp, after_rename };

/// The injectable filesystem-operation seam for the atomic publish (RoseCat 1347b70). The publish performs its
/// durability-critical steps — fsync the temp, rename, fsync the parent dir — THROUGH these methods, so a test's
/// recording fake observes the ACTUAL calls that go through it (not a self-reported log). Deleting a real call
/// in production therefore removes both the effect and the observation, so the omitted-dir-fsync mutant fails.
/// `publish` uses `RealOps`, which does the real work with fsync (NOT fdatasync — matching src/atomic_file.zig).
pub const RealOps = struct {
    pub fn syncFile(_: RealOps, file: std.Io.File, io: std.Io) !void {
        try file.sync(io); // Io.File.sync is fsync (posix.system.fsync), not fdatasync
    }
    pub fn rename(_: RealOps, dir: std.Io.Dir, old_sub: []const u8, new_sub: []const u8, io: std.Io) !void {
        try dir.rename(old_sub, dir, new_sub, io);
    }
    pub fn syncDir(_: RealOps, dir: std.Io.Dir, io: std.Io) !void {
        // Reopen `.iterate` (O_RDONLY) — the held handle may be O_PATH, which fsync refuses — then fsync it.
        var dir_ro = try dir.openDir(io, ".", .{ .iterate = true });
        defer dir_ro.close(io);
        const dir_fsync: std.Io.File = .{ .handle = dir_ro.handle, .flags = .{ .nonblocking = false } };
        try dir_fsync.sync(io);
    }
};

/// Atomically publish `entries` as the ledger at `dir`/`sub_path` (RoseCat atomic-publish row): serialize the
/// versioned doc to a fresh 0600 sibling temp (O_EXCL), fsync it, rename it over the store, then fsync the dir —
/// so a reader only ever sees the OLD or the NEW complete store (never torn), a returned publish survives a
/// crash, and a half-written temp never outlives a failed publish. `cut` stops early for the crash-cut tests.
pub fn publish(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, entries: []const Entry) !void {
    return publishCut(io, dir, sub_path, entries, .none, RealOps{});
}

pub fn publishCut(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, entries: []const Entry, cut: Cut, ops: anytype) !void {
    // Atomic: write a fresh 0600 O_EXCL sibling temp, fsync it, rename it over the store, fsync the dir. Mirrors
    // src/atomic_file.zig but relative to the HELD runtime `dir`. The store is only ever replaced whole, so a
    // reader sees old-or-new (never torn); the temp never outlives a failed publish (defer).
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp-{x}", .{ sub_path, std.mem.readInt(u64, &nonce, .little) });
    var file = try dir.createFile(io, tmp, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    var renamed = false;
    defer if (!renamed) dir.deleteFile(io, tmp) catch {};
    {
        defer file.close(io);
        var buf: [1024]u8 = undefined;
        var writer = file.writer(io, &buf);
        try std.json.Stringify.value(.{ .schema_version = SCHEMA_VERSION, .runs = entries }, .{}, &writer.interface);
        try writer.interface.flush();
        try ops.syncFile(file, io); // fsync the temp through the seam, before it can be renamed into place
    }
    if (cut == .after_temp) return; // crash before rename: the old store is untouched; the defer removes the temp
    try ops.rename(dir, tmp, sub_path, io);
    renamed = true;
    if (cut == .after_rename) return; // crash before the dir fsync: store is the new content, not yet durable
    try ops.syncDir(dir, io); // fsync the dir through the seam, so the rename itself survives a crash
}

/// The ledger's cross-process advisory lock file (sibling of the store).
pub const LOCK_NAME = ".zigbrowser-agent-runs.lock";

pub const LockError = error{ LockBusy, LockFailed };

/// Acquire the ledger's cross-process advisory lock with a BOUNDED, CANCELLABLE LOCK_EX|LOCK_NB + retry
/// (RoseCat flock row): at most `max_tries` non-blocking attempts, sleeping `backoff_ms` between them. A held
/// lock — a stalled holder, even in a SEPARATE process — never blocks us indefinitely: after the bound we FAIL
/// CLOSED with error.LockBusy, having mutated nothing (only the lock file is opened). The returned File HOLDS
/// the lock; close it (or process death) releases it. Any non-contention error also fails closed (LockFailed).
pub fn acquireLock(io: std.Io, dir: std.Io.Dir, max_tries: u32, backoff_ms: i64) LockError!std.Io.File {
    // Open/create the lock O_NOFOLLOW|O_CLOEXEC (portable std.posix.openat — Zig 0.16 CreateFileOptions has no
    // no-follow), so a planted/swapped symlink can never redirect the lock to another inode; a symlink (ELOOP) or
    // any other open error fails closed (RoseCat 53a467b #1). Then flock LOCK_EX|LOCK_NB with the bounded,
    // cancellable retry. flock/close/errno go through std.posix.system (the raw syscall on Linux, libc on Darwin)
    // + std.posix.errno so the macOS ledger primitive builds and behaves the same on Darwin (RoseCat 7511b79).
    const fd = std.posix.openat(dir.handle, LOCK_NAME, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600) catch return error.LockFailed;
    var tries: u32 = 0;
    while (true) {
        switch (std.posix.errno(std.posix.system.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
            .SUCCESS => return .{ .handle = fd, .flags = .{ .nonblocking = false } }, // held; caller closes to release
            .AGAIN => { // EWOULDBLOCK (== EAGAIN on both Linux and Darwin): a holder already owns it
                tries += 1;
                if (tries >= max_tries) {
                    _ = std.posix.system.close(fd);
                    return error.LockBusy; // bounded -> fail closed, zero mutation
                }
                io.sleep(.fromMilliseconds(backoff_ms), .awake) catch {
                    _ = std.posix.system.close(fd);
                    return error.LockBusy; // cancelled -> fail closed
                };
            },
            else => {
                _ = std.posix.system.close(fd);
                return error.LockFailed; // any other error -> fail closed
            },
        }
    }
}


// ---- SCOPED (RoseCat c11bff8): one-live-process liveness probe + a portable fail-closed action-label mapping.
// This is the accepted primitive. It is NOT whole-recovery: it performs NO startup-recovery pass, NO other-browser
// exclusion, NO signal, NO retirement and NO ledger mutation. `recoveryFor` returns an action LABEL only; actually
// performing it (census/kill, marker-unlink, rmdir, ledger retirement under one flock) is the OPEN whole-recovery
// blocker (bd). No production recovery transaction or signal path is implemented or armed — there is no
// `reaper_ready` constant yet; it is part of that OPEN blocker. ----

/// The liveness verdict for a recorded owner `(pid, start)` from a single live-process probe.
pub const Liveness = enum { dead, live_same, live_reused, unreadable };
/// The action LABEL a liveness maps to (a classification only — nothing is signalled or retired here).
pub const Recovery = enum { recover, leave, fail_closed };

/// Map a liveness to its action label: a proved-dead owner labels `.recover`; a live matching owner labels
/// `.leave`; PID reuse (live, different start) or an unreadable result labels `.fail_closed`. This is a pure
/// classification — it never signals, retires, or touches the ledger.
pub fn recoveryFor(l: Liveness) Recovery {
    return switch (l) {
        .dead => .recover, // owner proved dead -> label the leftover entry recoverable
        .live_same => .leave, // same live owner -> label leave (no action performed here)
        .live_reused => .fail_closed, // PID reuse (live, different start) -> fail closed
        .unreadable => .fail_closed, // can't prove liveness -> fail closed
    };
}

/// The outcome of reading a recorded owner's start time, keeping ABSENCE distinct from UNREADABILITY so that only
/// a proved-absent process is treated as dead (RoseCat d3b31cb #1). Everything else fails closed.
pub const StartRead = union(enum) {
    absent, // open reported ENOENT/ESRCH -> the process is gone
    unreadable, // any other open error, a read error, truncation, or an unparseable stat -> fail closed
    ticks: u64, // field 22 (starttime) parsed
};

/// Pure liveness classifier from a `StartRead` and the recorded start. Separated from the `/proc` I/O so the
/// absent/unreadable/parse paths are unit-testable with injected inputs (RoseCat d3b31cb #2). An unreadable read
/// is NEVER dead.
pub fn livenessFromRead(r: StartRead, recorded_start: u64) Liveness {
    return switch (r) {
        .absent => .dead, // only a proved-absent process is dead
        .unreadable => .unreadable, // can't prove liveness -> fail closed (recoveryFor -> .fail_closed), never dead
        .ticks => |now| if (now == recorded_start) .live_same else .live_reused,
    };
}

/// Parse field 22 (starttime, clock ticks since boot) from raw /proc/<pid>/stat bytes. Pure; null when the bytes
/// are truncated or the field is missing/non-numeric. comm (field 2) may contain spaces and ')', so parse after
/// the LAST ')'.
pub fn parseStartTicks(data: []const u8) ?u64 {
    const close_paren = std.mem.lastIndexOfScalar(u8, data, ')') orelse return null;
    var it = std.mem.tokenizeScalar(u8, data[close_paren + 1 ..], ' ');
    var i: usize = 0;
    while (i < 19) : (i += 1) { // skip fields 3..21 (19 tokens); the 20th token is field 22 = starttime
        _ = it.next() orelse return null;
    }
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(u64, tok, 10) catch null;
}

/// The LOWER-LEVEL outcome of trying to read /proc/<pid>/stat, before classification. Injectable so the mapping of
/// each open/read/empty/parse outcome into a StartRead is unit-testable WITHOUT a crafted /proc (RoseCat 83d3a0f
/// #2 — the production mapping, not just the pure parser, must be driven).
pub const StatIo = union(enum) {
    open_absent, // open reported ENOENT/ESRCH: the process is gone (the ONLY absence)
    open_error, // open reported any other errno (permission/IO/…): unreadable
    read_error, // opened, but the read failed or returned 0 bytes: unreadable
    bytes: []const u8, // opened and read n>0 bytes
};

/// Pure: classify a `StatIo` outcome into a `StartRead`. ONLY `open_absent` is absence; every other failure — a
/// non-absence open error, a read error, an empty/truncated read, or unparseable bytes — is `.unreadable` (fail
/// closed), never `.absent`. This is the boundary the production `readStart` and the tests share.
pub fn startReadFromIo(o: StatIo) StartRead {
    return switch (o) {
        .open_absent => .absent,
        .open_error => .unreadable,
        .read_error => .unreadable,
        .bytes => |b| if (parseStartTicks(b)) |t| StartRead{ .ticks = t } else .unreadable, // readable but unparseable -> fail closed, never absent
    };
}

/// The real /proc read on Linux -> a `StatIo` outcome (one open). Off Linux -> `.open_error` (fail closed) until a
/// Darwin probe lands. `buf` holds the stat bytes for the returned `.bytes` slice.
fn readStatIo(pid: i32, buf: []u8) StatIo {
    if (builtin.os.tag != .linux) return .open_error;
    const linux = std.os.linux;
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return .open_error;
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY }, 0);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT, .SRCH => return .open_absent, // only a proved-absent process is dead
        else => return .open_error, // permission/IO/etc -> fail closed
    }
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return .read_error; // read failure or empty -> fail closed
    return .{ .bytes = buf[0..n] };
}

/// Read `pid`'s start time from /proc in ONE open, keeping absence distinct from unreadability, through the
/// injectable `StatIo` boundary. Linux only; off Linux it is `.unreadable` (fail closed).
pub fn readStart(pid: i32) StartRead {
    var buf: [1024]u8 = undefined;
    return startReadFromIo(readStatIo(pid, &buf));
}

/// The start time of `pid`, or null if absent/unreadable. Kept for callers that only need the tick value.
pub fn readStartTicks(pid: i32) ?u64 {
    return switch (readStart(pid)) {
        .ticks => |t| t,
        else => null,
    };
}

/// Linux liveness probe for a recorded owner `(pid, start_ticks)`: gone (dead), present with the SAME start
/// (live_same), present with a DIFFERENT start = PID reuse (live_reused), or unreadable (fail closed).
pub fn probeLiveness(pid: i32, start_ticks: u64) Liveness {
    return livenessFromRead(readStart(pid), start_ticks);
}

/// The start-identity kind THIS platform's `readStart` produces. A recorded entry of any other kind can never be
/// compared here (no conversion between kinds).
pub const PLATFORM_START_KIND: StartKind = if (builtin.os.tag == .linux) .linux_ticks else .darwin_tvsec;

/// Liveness of a recorded owner keyed on its PLATFORM-TAGGED start identity (RoseCat 0e36742 same-kind-only). A
/// recorded `kind` that differs from this platform's probe kind is NEVER compared — even if its value is
/// numerically equal to a live value — and FAILS CLOSED (`.unreadable`). Same kind compares via `readStart`.
pub fn probeLivenessTagged(pid: i32, kind: StartKind, start_sec: u64, start_usec: u64) Liveness {
    _ = start_usec; // linux_ticks carries no usec; the darwin (sec,usec) compare lands with a darwin readStart
    if (kind != PLATFORM_START_KIND) return .unreadable; // cross-kind: never compared, fails closed (no conversion)
    return livenessFromRead(readStart(pid), start_sec);
}

// ---- bounded cross-process lock ACQUISITION primitive (RoseCat c11bff8; cdedf98 #1) ----
// This acquires (and immediately releases) the one global ledger flock within a bounded deadline. It performs NO
// startup recovery: no liveness pass, census/kill, signal, retirement or ledger mutation, and it makes NO claim
// about whether any run may start. A no-op acquire never means "startup recovery completed".

/// Whether the bounded acquire surfaced a fixed incident.
pub const AcquireIncident = enum { none, lock_unavailable };
/// The outcome of a bounded acquire attempt: whether the flock was taken within the deadline, and any incident.
pub const AcquireOutcome = struct { acquired: bool, incident: AcquireIncident };

/// One non-blocking acquire attempt's outcome: got the lock, contended (retry), or a hard error (fail closed).
pub const AcquireResult = enum { acquired, busy, failed };

/// The real monotonic clock + cancellable sleep seam. Tests inject a fake clock to drive the deadline
/// deterministically (RoseCat e665676 #1).
pub const RealClock = struct {
    io: std.Io,
    pub fn nowMs(self: RealClock) i64 {
        _ = self;
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }
    pub fn sleepMs(self: RealClock, ms: i64) void {
        self.io.sleep(.fromMilliseconds(ms), .awake) catch {};
    }
};

/// A deadline-bounded, clock-driven acquisition loop: retry the non-blocking `attempt.tryOnce()` ONLY while the
/// monotonic `clock` is before the absolute `deadline_ms`, sleeping `backoff_ms` via the clock between tries; at
/// the deadline, fail closed with `.busy`. ONE absolute deadline — NO try-count arithmetic (RoseCat e665676 #1).
pub fn acquireWithinDeadline(clock: anytype, deadline_ms: i64, backoff_ms: i64, attempt: anytype) AcquireResult {
    while (true) {
        switch (attempt.tryOnce()) {
            .acquired => return .acquired,
            .failed => return .failed, // a hard error -> fail closed
            .busy => {
                if (clock.nowMs() >= deadline_ms) return .busy; // at/past the absolute deadline -> fail closed
                clock.sleepMs(backoff_ms); // cancellable backoff via the clock, then re-check the deadline
            },
        }
    }
}

/// The outcome of a bounded wait for a child/pipe to become ready.
pub const WaitResult = enum { ready, timed_out, poll_error };
/// One poll attempt's outcome: data ready, a slice elapsed (retry), interrupted (EINTR, retry), or a hard error.
pub const PollOutcome = enum { ready, again, eintr, err };

/// A bounded, EINTR-safe wait for readiness within an absolute monotonic deadline (RoseCat e665676 #3): retry the
/// injected `poll.pollOnce()` and return `.ready` on data or `.poll_error` on a hard error. Crucially, the
/// monotonic `clock` deadline is checked BEFORE each poll, so an EINTR storm (or a storm of empty slices) is
/// bounded by wall-clock and can NEVER keep a watchdog alive indefinitely; reaching the deadline returns
/// `.timed_out`.
pub fn waitWithinDeadline(clock: anytype, deadline_ms: i64, poll: anytype) WaitResult {
    while (true) {
        if (clock.nowMs() >= deadline_ms) return .timed_out; // deadline FIRST -> an EINTR/empty-slice storm is bounded
        switch (poll.pollOnce()) {
            .ready => return .ready,
            .err => return .poll_error, // a hard poll error -> fail closed
            .again, .eintr => {}, // a slice elapsed or an interruption -> loop; the top deadline check bounds it
        }
    }
}

/// One non-blocking flock attempt on an already-open lock fd.
const FlockAttempt = struct {
    fd: i32,
    pub fn tryOnce(self: FlockAttempt) AcquireResult {
        return switch (std.posix.errno(std.posix.system.flock(self.fd, std.posix.LOCK.EX | std.posix.LOCK.NB))) {
            .SUCCESS => .acquired,
            .AGAIN => .busy,
            else => .failed,
        };
    }
};

/// SCOPED (RoseCat c11bff8; cdedf98 #1): the BOUNDED, cancellable flock ACQUISITION under ONE absolute monotonic
/// deadline (`clock.nowMs() + budget_ms`). On success the flock is taken and IMMEDIATELY released
/// (`acquired=true`); acquire-failure/deadline/cancel => `acquired=false` with a `lock_unavailable` incident, so a
/// live holder that stalls can never wedge the acquire. It performs NO recovery work — no liveness revalidation,
/// census/kill, signal, retirement, marker-unlink or ledger mutation — and makes NO claim that any run may start.
/// The whole-recovery transaction is the OPEN blocker bd zigBrowser-3gl; no production recovery or signal path is
/// implemented or armed.
pub fn acquireRunLockBounded(io: std.Io, dir: std.Io.Dir, budget_ms: i64, backoff_ms: i64, clock: anytype) AcquireOutcome {
    _ = io; // no work is done under the lock in this acquisition primitive
    const unavailable = AcquireOutcome{ .acquired = false, .incident = .lock_unavailable };
    const deadline = clock.nowMs() + budget_ms; // one absolute deadline bounds the acquire
    const fd = std.posix.openat(dir.handle, LOCK_NAME, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600) catch return unavailable;
    switch (acquireWithinDeadline(clock, deadline, backoff_ms, FlockAttempt{ .fd = fd })) {
        .acquired => {},
        .busy, .failed => {
            _ = std.posix.system.close(fd);
            return unavailable;
        },
    }
    defer _ = std.posix.system.close(fd); // release immediately; nothing is done while the lock is held
    if (clock.nowMs() >= deadline) return unavailable; // the acquire exhausted the budget -> fail closed
    return .{ .acquired = true, .incident = .none };
}

// ---- MS6.5.1 whole-recovery transaction (OPEN blocker bd zigBrowser-3gl). NOT IMPLEMENTED / NOT ARMED. --------
// No production caller wires this in and there is NO `reaper_ready` gate yet. The approved held-flock design
// (RoseCat b2f474b; plan rev 28) is: ONE global flock held from the authoritative load through the fresh owner
// check, held-fd `(dev,ino,uid,mode)` provenance, the typed census->kill->fresh-census FIXED POINT, marker unlink,
// `rmdir` and the atomic ledger retirement (released ONLY after the terminal publish result is known), all under
// ONE absolute monotonic deadline over acquire AND held work. Any unreadable identity/provenance, incomplete
// census, survivor, action error, deadline or publish error FAILS CLOSED and must never report a clean recovery
// or `.already_gone`. The `actuator` is INJECTABLE: the production actuator is the already-reviewed reaper /
// provenance C path (`zb_reaper_dir_fd_ok` + `zb_reaper_fixed_point`), never a second Zig implementation; tests
// inject deterministic, signal-free fakes.

/// The outcome of recovering ONE recorded entry under the held flock.
pub const RecoveryAction = enum {
    signalled, // proved dead, provenance matched, run censused->killed to a clean fixed point, dir torn down, entry retired
    left, // a live same-owner entry (or a `left` entry) -> leave untouched
    already_gone, // the entry was already retired by whichever recoverer held the flock before us
    reconciled, // crash cut C3: the entry names NO dir (removed before a prior recoverer retired it) -> dropped idempotently, no signal
    fail_closed, // unreadable identity/provenance, provenance mismatch, incomplete census, survivor, teardown/publish error, or deadline
};

/// The census->kill->fresh-census fixed-point verdict from the held-fd lease (production: `zb_reaper_fixed_point`).
pub const FixedPoint = enum { clean, survivors, incomplete };

/// The idempotent teardown verdict from the held-fd lease: `done` includes crash cut C2 (the marker was already
/// unlinked before the crash — `ENOENT` on the marker unlink is finished, not failed, then `rmdir` completes).
pub const Teardown = enum { done, failed };

// The destructive action is reached ONLY through a typed lease that RETAINS the pinned run-dir fd, so the
// provenance check and the teardown cannot be separated by a path swap (RoseCat 62888b1). The injected `actuator`
// exposes ONE pin/check step whose result is a TAGGED union distinguishing the crash cuts from a failure
// (RoseCat 9f62ea4 #3):
//
//     actuator.pin(dir, entry) -> union(enum) {
//         held: Lease,   // the run dir reopened O_DIRECTORY|O_NOFOLLOW and its pinned (dev,ino,uid,mode) equals
//                        //   the recorded entry; the lease RETAINS that fd (+ the parent authority for rmdir)
//         gone,          // ENOENT: the entry names no dir -> crash cut C3 (removed before ledger retirement)
//         mismatch,      // reopened a non-dir/symlink, or (dev,ino,uid,mode) != recorded -> NEVER sweep
//         unreadable,    // could not open/fstat -> fail closed
//     }
//
// and the returned `Lease` operates ONLY through that held fd and ends its lifetime at `deinit`:
//
//     lease.fixedPoint(clock, deadline_ms) FixedPoint  // census -> kill -> fresh-census, clean iff a complete
//                                                       //   empty final census (via the held fd); else survivors/incomplete
//     lease.teardown(deadline_ms) Teardown             // unlinkat(run.marker) then unlinkat(name, AT_REMOVEDIR)
//                                                       //   through the held fds, idempotent on ENOENT (crash cut C2)
//     lease.deinit() void                              // close the held fd(s)
//
// The production actuator/lease wrap the already-reviewed reaper/provenance C path (`zb_reaper_pin_fd` +
// `zb_reaper_dir_fd_ok` + `zb_reaper_fixed_point`) over the held fd — never a second Zig implementation; tests
// inject a deterministic, signal-free fake. Nothing here is armed: no production caller wires an actuator in, and
// there is still no `reaper_ready` gate.

fn indexOfEntry(l: *const Ledger, basename: []const u8) ?usize {
    for (l.entries(), 0..) |e, i| if (std.mem.eql(u8, e.basename, basename)) return i;
    return null;
}

/// Publish the current ledger MINUS `basename` (the atomic retirement), under the caller's held flock.
fn publishWithout(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, l: *const Ledger, basename: []const u8) !void {
    var buf: [MAX_ENTRIES]Entry = undefined;
    var n: usize = 0;
    for (l.entries()) |e| {
        if (std.mem.eql(u8, e.basename, basename)) continue;
        buf[n] = e;
        n += 1;
    }
    try publish(io, dir, sub_path, buf[0..n]);
}

/// Recover one recorded entry under the one global ledger flock (bd zigBrowser-3gl; RoseCat b2f474b/62888b1).
///
/// The ONE flock is held across the WHOLE recovery: authoritative load → fresh owner check → held-fd provenance
/// (the lease) → census/kill fixed point → marker unlink → `rmdir` → ledger retirement, released ONLY after the
/// terminal publish result is known. One absolute monotonic `deadline_ms` bounds acquire AND held work. Outcomes:
///   `.already_gone` — the entry was retired by whichever recoverer held the flock before us;
///   `.left`         — a `left` entry, or a live same-owner entry → leave untouched, entry RETAINED;
///   `.signalled`    — proved dead, provenance matched, census→clean fixed point, dir torn down, entry retired;
///   `.fail_closed`  — any unreadable store/identity, provenance mismatch, incomplete census, survivor, teardown
///                     error, or publish error → entry RETAINED, never a clean recovery, never `.already_gone`.
///
/// NOT ARMED: no production caller passes a destructive actuator, so nothing is signalled in production yet.
pub fn recoverOneUnderLock(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, basename: []const u8, clock: anytype, deadline_ms: i64, actuator: anytype) RecoveryAction {
    const lock_fd = std.posix.openat(dir.handle, LOCK_NAME, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600) catch return .fail_closed;
    switch (acquireWithinDeadline(clock, deadline_ms, 5, FlockAttempt{ .fd = lock_fd })) {
        .acquired => {},
        .busy, .failed => {
            _ = std.posix.system.close(lock_fd);
            return .fail_closed;
        },
    }
    defer _ = std.posix.system.close(lock_fd); // released ONLY after the terminal publish result is known
    // Deadline AUTHORITY (RoseCat 9f62ea4 #2): `acquireWithinDeadline` tries once before checking time, so a FREE
    // lock at an already-expired deadline would otherwise proceed. Fail closed here, and re-check at every held-work
    // boundary below, so no action or disk mutation happens past the single absolute deadline.
    if (clock.nowMs() >= deadline_ms) return .fail_closed;

    var l = load(io, gpa, dir, "runs.json") catch return .fail_closed; // malformed/unreadable store -> fail closed
    defer l.deinit();
    const idx = indexOfEntry(&l, basename) orelse return .already_gone; // retired by a prior recoverer under the lock
    const e = l.entries()[idx];
    if (e.state != .active) return .left; // a `left` entry is never swept

    switch (recoveryFor(probeLivenessTagged(e.pid, e.start_kind, e.start_sec, e.start_usec))) {
        .leave => return .left, // live same owner -> leave untouched, entry retained
        .fail_closed => return .fail_closed, // reuse / unreadable -> fail closed, entry retained
        .recover => {}, // proved dead -> proceed to the pinned, held-fd teardown
    }

    if (clock.nowMs() >= deadline_ms) return .fail_closed; // pre-pin
    // Pin + provenance in one step; the `held` lease RETAINS the run-dir fd and all later actions go through it.
    switch (actuator.pin(dir, e)) {
        .mismatch, .unreadable => return .fail_closed, // never sweep; entry retained
        .gone => {
            // Crash cut C3: the entry names no dir (a prior recoverer removed it, then crashed before retiring the
            // entry). Drop the entry idempotently, signal-free -- NOT fail-closed, so it never wedges forever.
            if (clock.nowMs() >= deadline_ms) return .fail_closed; // pre-publish
            publishWithout(io, dir, "runs.json", &l, basename) catch return .fail_closed;
            return .reconciled;
        },
        .held => |held| {
            var lease = held;
            defer lease.deinit();
            switch (lease.fixedPoint(clock, deadline_ms)) {
                .clean => {}, // a complete, empty final census -> proceed to teardown
                .survivors, .incomplete => return .fail_closed, // never a clean recovery, entry retained
            }
            if (clock.nowMs() >= deadline_ms) return .fail_closed; // pre-teardown
            switch (lease.teardown(deadline_ms)) { // idempotent on ENOENT (crash cut C2)
                .done => {},
                .failed => return .fail_closed, // teardown error -> fail closed, entry retained
            }
            if (clock.nowMs() >= deadline_ms) return .fail_closed; // pre-publish
            publishWithout(io, dir, "runs.json", &l, basename) catch return .fail_closed; // atomic retirement under the flock
            return .signalled;
        },
    }
}
