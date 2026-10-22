//! MS6.5.1 red (orchestrator decision 2026-10-22: Option A, platform-tagged owner-start identity). The ledger
//! records the owner's start identity EXACTLY as the platform's probe returns it, tagged by KIND, in a versioned
//! schema bump (v2): Linux = /proc starttime ticks (`linux_ticks`), Darwin = proc_pidinfo PROC_PIDTBSDINFO
//! pbi_start_tvsec/pbi_start_tvusec (`darwin_tvsec`, the existing sec/usec pair). No conversion between kinds.
//! Pure parse — no fs, no signals. UNREGISTERED until green.
//!
//! The mutant this catches: a schema that stays at v1 / ignores the new `start_kind` field cannot record which
//! platform's identity a start value is, so a cross-kind comparison (or an unknown kind) could be mistaken for a
//! live/dead match. The parse must accept a well-formed v2 entry WITH a known `start_kind`, and reject a missing
//! or unknown kind.
const std = @import("std");
const ledger = @import("agent_run_ledger");

fn expectMalformed(s: []const u8) !void {
    const r = ledger.parse(std.testing.allocator, s);
    if (r) |l| {
        var m = l;
        m.deinit();
        return error.TestExpectedError;
    } else |e| {
        try std.testing.expectEqual(ledger.ParseError.Malformed, e);
    }
}

test "a v2 ledger with a known linux_ticks start_kind parses" {
    const s =
        \\{"schema_version":2,"runs":[{"basename":"zigbrowser-agent-100-0011223344556677","dev":10,"ino":20,"uid":0,"mode":16832,"pid":100,"start_kind":"linux_ticks","start_sec":987654,"start_usec":0,"state":"active"}]}
    ;
    var l = try ledger.parse(std.testing.allocator, s); // the v1 parser rejects v2 -> this is the red
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.entries().len);
}

test "a v2 darwin_tvsec entry parses with its (sec,usec) pair" {
    const s =
        \\{"schema_version":2,"runs":[{"basename":"zigbrowser-agent-7-00aa00aa00aa00aa","dev":1,"ino":2,"uid":0,"mode":16832,"pid":7,"start_kind":"darwin_tvsec","start_sec":1700000000,"start_usec":123456,"state":"active"}]}
    ;
    var l = try ledger.parse(std.testing.allocator, s);
    defer l.deinit();
    try std.testing.expectEqual(@as(usize, 1), l.entries().len);
}

test "a v2 entry with an unknown start_kind is Malformed" {
    try expectMalformed(
        \\{"schema_version":2,"runs":[{"basename":"zigbrowser-agent-100-0011223344556677","dev":10,"ino":20,"uid":0,"mode":16832,"pid":100,"start_kind":"solaris_ns","start_sec":1,"start_usec":0,"state":"active"}]}
    );
}

test "a v2 entry missing start_kind is Malformed" {
    try expectMalformed(
        \\{"schema_version":2,"runs":[{"basename":"zigbrowser-agent-100-0011223344556677","dev":10,"ino":20,"uid":0,"mode":16832,"pid":100,"start_sec":1,"start_usec":0,"state":"active"}]}
    );
}

test "a v1 ledger is now Malformed (the bump is never silently downgraded)" {
    try expectMalformed(
        \\{"schema_version":1,"runs":[{"basename":"zigbrowser-agent-100-0011223344556677","dev":10,"ino":20,"uid":0,"mode":16832,"pid":100,"start_sec":5,"start_usec":7,"state":"active"}]}
    );
}

// Canonical per-kind shape (RoseCat 0e36742): each kind has ONE legal representation. linux_ticks is a single
// tick count with NO microseconds, so start_usec MUST be 0; darwin_tvsec's start_usec is a real microseconds
// field, so it MUST be in [0, 999999]. A violation is a malformed read (an impossible identity is never trusted).
test "linux_ticks with a nonzero start_usec is Malformed (ticks carry no microseconds)" {
    try expectMalformed(
        \\{"schema_version":2,"runs":[{"basename":"zigbrowser-agent-100-0011223344556677","dev":10,"ino":20,"uid":0,"mode":16832,"pid":100,"start_kind":"linux_ticks","start_sec":987654,"start_usec":7,"state":"active"}]}
    );
}

test "darwin_tvsec with an out-of-range start_usec (>= 1_000_000) is Malformed" {
    try expectMalformed(
        \\{"schema_version":2,"runs":[{"basename":"zigbrowser-agent-7-00aa00aa00aa00aa","dev":1,"ino":2,"uid":0,"mode":16832,"pid":7,"start_kind":"darwin_tvsec","start_sec":1700000000,"start_usec":1000000,"state":"active"}]}
    );
}

test "the parsed identity (kind, sec, usec) is preserved exactly" {
    const lin =
        \\{"schema_version":2,"runs":[{"basename":"zigbrowser-agent-100-0011223344556677","dev":10,"ino":20,"uid":0,"mode":16832,"pid":100,"start_kind":"linux_ticks","start_sec":987654,"start_usec":0,"state":"active"}]}
    ;
    var l = try ledger.parse(std.testing.allocator, lin);
    defer l.deinit();
    const e = l.entries()[0];
    try std.testing.expectEqual(ledger.StartKind.linux_ticks, e.start_kind);
    try std.testing.expectEqual(@as(u64, 987654), e.start_sec);
    try std.testing.expectEqual(@as(u64, 0), e.start_usec);

    const dar =
        \\{"schema_version":2,"runs":[{"basename":"zigbrowser-agent-7-00aa00aa00aa00aa","dev":1,"ino":2,"uid":0,"mode":16832,"pid":7,"start_kind":"darwin_tvsec","start_sec":1700000000,"start_usec":123456,"state":"active"}]}
    ;
    var d = try ledger.parse(std.testing.allocator, dar);
    defer d.deinit();
    const de = d.entries()[0];
    try std.testing.expectEqual(ledger.StartKind.darwin_tvsec, de.start_kind);
    try std.testing.expectEqual(@as(u64, 1700000000), de.start_sec);
    try std.testing.expectEqual(@as(u64, 123456), de.start_usec);
}
