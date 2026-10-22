//! MS6.5.1 the run ledger (the app-owned recovery store `<runtime_dir>/zigbrowser-agent-runs.json`), parse half.
//! The owner (the macOS agent-run host) reads this at start to recover leftover runs. The parse is VERSIONED,
//! STRICTLY typed, and BOUNDED: an unknown version, an over-cap array, a missing/extra/mistyped field, a bad
//! `state`, a duplicate basename, or any truncated/unparseable input is rejected — a malformed ledger NEVER
//! yields entries that could authorize a signal (the caller census/warns instead). Pure/portable; the atomic
//! publish, the cross-process flock and the fd-level provenance decision (C `zb_reaper_ledger_entry_state`) are
//! separate.
const std = @import("std");

/// The only accepted schema version. A different value is a malformed read (never silently upgraded/downgraded).
pub const SCHEMA_VERSION: u32 = 1;
/// The bounded cap on recovered entries (RoseCat SHOULD: bound the number of startup dirs).
pub const MAX_ENTRIES: usize = 256;
/// The fixed maximum run-dir basename length: "zigbrowser-agent-" (17) + up to 10 pid digits + "-" + 16 hex = 44.
pub const MAX_BASENAME: usize = 44;
/// A finite maximum ledger document size, derived from the fixed field lengths x MAX_ENTRIES plus structural
/// overhead. Any input larger than this is rejected BEFORE allocation, so a corrupt/hostile file (millions of
/// entries, or one huge string) can never allocate/work without bound (RoseCat 7458 #2).
pub const MAX_LEDGER_BYTES: usize = 64 * 1024;

pub const State = enum { active, left };

/// One recorded run. Every field is required and strictly typed; std.json rejects a missing/extra/mistyped field
/// and an unknown `state` string.
pub const Entry = struct {
    basename: []const u8,
    dev: u64,
    ino: u64,
    uid: u32,
    mode: u32,
    pid: i32,
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
    // RED STUB — NO size bound: reads with a large limit, so a file past MAX_LEDGER_BYTES is fully read and
    // becomes a Malformed (truncated) parse instead of a clean, pre-allocation-bounded TooManyEntries. The green
    // reads with `.limited(MAX_LEDGER_BYTES)` and maps the over-limit StreamTooLong to TooManyEntries.
    const text = dir.readFileAlloc(io, sub_path, gpa, .limited(64 * 1024 * 1024)) catch return error.Malformed;
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
