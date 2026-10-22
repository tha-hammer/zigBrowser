//! MS6.5.1 — RED-FIRST for the OPEN integration blocker (bd zigBrowser-3gl): the real app-startup OWNER must call
//! the startup-recovery core `agent_run_recovery.recoverAllAtStartup`. UNREGISTERED (built by no gate step),
//! signal-free, no display, no Macs. `reaper_ready` stays false — this slice only WIRES the call site; it does not
//! arm anything (with the gate false the call is a disabled no-op, so nothing is recovered or signalled).
//!
//! WHY A SOURCE ORACLE: in a build where `reaper_ready == false`, a startup owner that calls `recoverAllAtStartup`
//! and one that skips it are behaviorally identical (both recover nothing) — no runtime row can separate them. And
//! `app.runWithIo` is the real entry point doing heavy process/network I/O, not a unit-drivable seam. So the
//! call-site oracle is bound to the real startup path by reading `src/app.zig` and asserting the two-link chain
//! runWithIo -> owner helper -> recoverAllAtStartup. The "skip the call" mutant removes either link and turns this
//! red. It is RED now because `app.zig` has no such call yet (the integration is the open blocker).
const std = @import("std");

/// The body of `decl` (a top-level `[pub ]fn <name>(` prefix) in `src`, bounded to the next top-level declaration
/// (a line beginning `fn ` or `pub fn `). Empty slice if `decl` is absent.
fn fnBody(src: []const u8, decl: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, src, decl) orelse return "";
    const rest = src[start..];
    const a = std.mem.indexOfPos(u8, rest, decl.len, "\nfn ") orelse rest.len;
    const b = std.mem.indexOfPos(u8, rest, decl.len, "\npub fn ") orelse rest.len;
    return rest[0..@min(a, b)];
}

test "integration RED: app.runWithIo wires recoverAllAtStartup on the real startup path" {
    const gpa = std.testing.allocator;
    const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "src/app.zig", gpa, .limited(1 << 20));
    defer gpa.free(src);

    // (0) app.zig imports the startup-recovery core module.
    try std.testing.expect(std.mem.indexOf(u8, src, "@import(\"agent_run_recovery\")") != null);

    // (1) the real startup entry runWithIo calls the startup-recovery owner helper (bound to the real path).
    const run_body = fnBody(src, "pub fn runWithIo(");
    try std.testing.expect(run_body.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, run_body, "recoverLeftoverAgentRuns(") != null);

    // (2) that owner helper reaches the gated startup-recovery core.
    const owner_body = fnBody(src, "fn recoverLeftoverAgentRuns(");
    try std.testing.expect(owner_body.len != 0);
    try std.testing.expect(std.mem.indexOf(u8, owner_body, "recoverAllAtStartup(") != null);
}
