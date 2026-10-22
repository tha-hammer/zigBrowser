//! 4pa.66 (plan R29-MS6 D2, R30-MS6): the macOS seatbelt readiness is ONE fact, and it cannot say "ready" while the
//! generated profile is still broad.
//!
//! `seatbelt_facts` is generated at build time by agent/host/tests/seatbelt_readiness_facts.py from the PRODUCTION
//! profile generator (`sandbox_macos`): its readiness source `PROFILE_CURATION`, the derived `LAUNCH_SPEC_CONSUMABLE`,
//! and every profile it renders. This test judges them beside `agent_setup.seatbelt_ready`:
//!   seatbelt_ready  =>  PROFILE_CURATION == CURATED  and  no bare allow in any rendered profile  and  the macOS gate runs.
//! The "no bare allow" clause reads profile TEXT, so it is a tripwire (plan Rev 31, L3), not the closing proof; that is
//! the kernel denial of tests/mac/ms6_generated_profile_test.sh on both Macs. Mutants this must catch: readiness
//! flipped alone (accepted_commit set, or seatbelt_ready forced true), curation flipped to CURATED without the profile
//! change, and LAUNCH_SPEC_CONSUMABLE turned back into an independent boolean.
const std = @import("std");
const agent_setup = @import("agent_setup");
const facts = @import("seatbelt_facts");

/// A bare `(allow <op>)` is an allow with no filter: every file read, every exec, every mach service. Only
/// process-fork is exempt: Seatbelt has no filter that narrows it, and a fork gains no access its parent lacks
/// (exec is what loads new code, and exec is not exempt).
const bare_allow_exempt = [_][]const u8{"process-fork"};

/// The first non-exempt bare allow in `text`, or null. Comments (`;` to end of line) are skipped, and whitespace
/// between tokens is free, so a reformatted profile cannot hide one.
fn bareAllow(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == ';') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (text[i] != '(') continue;
        var j = skipSpace(text, i + 1);
        if (!std.mem.startsWith(u8, text[j..], "allow")) continue;
        j += "allow".len;
        if (j >= text.len or !isSpace(text[j])) continue;
        j = skipSpace(text, j);
        const op_start = j;
        while (j < text.len and !isSpace(text[j]) and text[j] != '(' and text[j] != ')') j += 1;
        const op = text[op_start..j];
        j = skipSpace(text, j);
        if (j < text.len and text[j] == ')' and !exempt(op)) return op;
    }
    return null;
}

fn exempt(op: []const u8) bool {
    for (bare_allow_exempt) |e| if (std.mem.eql(u8, op, e)) return true;
    return false;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn skipSpace(text: []const u8, from: usize) usize {
    var j = from;
    while (j < text.len and isSpace(text[j])) j += 1;
    return j;
}

fn curated() bool {
    const c = facts.curation orelse return false;
    const want = facts.curated_name orelse return false;
    return std.mem.eql(u8, c, want);
}

test "the bare-allow reader finds a bare allow however it is laid out, and passes filtered ones" {
    try std.testing.expectEqualStrings("file-read*", bareAllow("(version 1)\n(allow file-read*)\n").?);
    try std.testing.expectEqualStrings("mach-lookup", bareAllow("(allow\n   mach-lookup  )").?);
    try std.testing.expectEqualStrings("process-exec", bareAllow("( allow process-exec)").?);
    try std.testing.expect(bareAllow("(allow process-fork)\n(allow file-read* (subpath \"/usr\"))\n") == null);
    try std.testing.expect(bareAllow(";; (allow file-read*) is gone\n(allow mach-lookup (global-name \"x\"))") == null);
    try std.testing.expect(bareAllow("(allowance file-read*)") == null);
}

test "the Zig readiness is derived from the one acceptance fact, never set by hand" {
    if (!@hasDecl(agent_setup, "seatbelt_gate")) {
        std.debug.print("agent_setup has no seatbelt_gate: seatbelt_ready is an independent boolean\n", .{});
        return error.ReadinessNotDerived;
    }
    try std.testing.expectEqual(agent_setup.seatbelt_gate.accepted_commit != null, agent_setup.seatbelt_ready);
}

test "the Python readiness is one source: LAUNCH_SPEC_CONSUMABLE is a function of PROFILE_CURATION" {
    if (facts.curation == null) {
        std.debug.print("sandbox_macos has no PROFILE_CURATION: the profile's readiness has no single source\n", .{});
        return error.NoCurationSource;
    }
    try std.testing.expect(facts.curated_name != null);
    try std.testing.expectEqualStrings("function", facts.launch_spec_consumable_kind);
    try std.testing.expectEqual(curated(), facts.launch_spec_consumable);
}

test "LAUNCH_SPEC_CONSUMABLE follows PROFILE_CURATION in both states: false when BROAD, true when CURATED" {
    // SilverRidge 1915e0d: a constant function agrees with the derivation at the current state; driving the
    // production function with PROFILE_CURATION set to each value tells them apart.
    try std.testing.expectEqual(false, facts.consumable_when_broad);
    try std.testing.expectEqual(true, facts.consumable_when_curated);
}

test "a CURATED profile has no bare allow in any profile the generator renders" {
    try std.testing.expect(facts.profiles.len == 5);
    if (!curated()) return;
    for (facts.profiles) |p| {
        if (bareAllow(p.text)) |op| {
            std.debug.print("curation says CURATED but the {s} profile still has (allow {s})\n", .{ p.name, op });
            return error.CuratedProfileHasBareAllow;
        }
    }
}

test "seatbelt_ready implies a CURATED profile with no bare allow, and only then does the macOS gate run" {
    const gate = agent_setup.platformGate(.macos, agent_setup.seatbelt_ready);
    if (!agent_setup.seatbelt_ready) {
        try std.testing.expect(gate == .refuse);
    try std.testing.expectEqualStrings(agent_setup.macos_unsandboxed_refusal, gate.refuse);
        return;
    }
    if (!curated()) {
        std.debug.print("seatbelt_ready is true but PROFILE_CURATION is {s}\n", .{facts.curation orelse "absent"});
        return error.ReadyWhileBroad;
    }
    for (facts.profiles) |p| {
        if (bareAllow(p.text)) |op| {
            std.debug.print("seatbelt_ready is true but the {s} profile still has (allow {s})\n", .{ p.name, op });
            return error.ReadyWithBareAllow;
        }
    }
    try std.testing.expect(gate == .run);
}
