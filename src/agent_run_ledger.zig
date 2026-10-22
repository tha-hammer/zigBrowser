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

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Ledger {
    // STRICT: `.{}` keeps ignore_unknown_fields=false, so an extra field, a missing field, a mistyped field, an
    // unknown `state` and any truncated/unparseable input all error -> Malformed. A JSON object with a duplicate
    // key also errors here. The version, cap and duplicate-basename checks are explicit below.
    const parsed = std.json.parseFromSlice(Doc, gpa, bytes, .{}) catch return error.Malformed;
    if (parsed.value.schema_version != SCHEMA_VERSION) {
        parsed.deinit();
        return error.Malformed; // an unknown version is never silently upgraded/downgraded
    }
    const runs = parsed.value.runs;
    if (runs.len > MAX_ENTRIES) {
        parsed.deinit();
        return error.TooManyEntries; // bounded: a corrupt/hostile over-long ledger is refused, not truncated
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
