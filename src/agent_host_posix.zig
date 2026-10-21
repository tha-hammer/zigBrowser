//! macOS host spawner (MS8 glue; BlackRobin 7035, Q1): the Zig POSIX side that starts netd, learns its
//! ephemeral egress port from the first stdout line, and hands that port to the `launch` helper as
//! `--egress-port <port>`. On Linux `src/agent_host.c` (GLib + prctl) does the equivalent; `agent_host.c` is
//! Linux-only, so macOS gets its own small module here (NOT in `wkwebview_shim.m`, which stays UI glue).
//!
//! Lifecycle (mirrors the Linux ready wait in `agent_host.c`; owner JadeBeacon, MS8):
//!   1. start netd in its OWN process group with stdout on a pipe (via `agent_spawn_posix.c`);
//!   2. read ONLY the first stdout line, under `ready_wait_ms` (10 s, as Linux);
//!   3. `agent_net.parseDarwinReadyPort` that line -> the port, or null;
//!   4. a null parse, the deadline passing, or netd exiting first is the EXISTING drawer "status … network"
//!      failure: SIGKILL netd's group, NO fallback port, do not start the helper;
//!   5. only on a good port, start the helper with `--egress-port <port>` appended to its launch argv.
//! The sign-in netd (Linux `agent_login.c`) uses the same reader from this module.
//!
//! THIS FILE holds the pure, host-independent core (ready-line parse reuse + the helper-argv construction +
//! the fail-closed lifecycle decision), unit-tested on Linux below. The process orchestration (spawn + pipe +
//! deadline + kill) is the both-Mac e2e (7035) and depends on an `agent_spawn_posix` stdout-pipe seam — pending
//! the diff round with BlackRobin before it lands.

const std = @import("std");
const agent_net = @import("agent_net.zig");

/// The browser's wait for netd's `netd ready …` line, matching the Linux ready wait.
pub const ready_wait_ms: u32 = 10_000;

/// The exact flag the `launch` helper parses on Darwin (BlackRobin 7035, Q2): required on Darwin, refused off
/// it, decimal 1..65535 with no leading zero — the same grammar as netd's port and `parseDarwinReadyPort`.
pub const egress_port_flag = "--egress-port";

/// What the spawner does after reading netd's stdout. `network_failure` is the EXISTING drawer "status … network"
/// failure: netd's group is SIGKILLed and the helper is NOT started — there is NO fallback port (BlackRobin 7035).
pub const Outcome = enum { start_helper, network_failure };

// RED STUB (red-then-green pair): the real bodies land in the green commit; these fail the tests below on purpose.

pub fn readyPort(first_line: []const u8) ?u16 {
    _ = first_line;
    return null; // STUB
}

pub fn decide(port: ?u16, timed_out: bool, netd_exited_early: bool) Outcome {
    _ = port;
    _ = timed_out;
    _ = netd_exited_early;
    return .start_helper; // STUB
}

pub fn appendEgressPort(a: std.mem.Allocator, base_argv: []const []const u8, port: u16) ![]const []const u8 {
    _ = a;
    _ = port;
    return base_argv; // STUB
}

pub fn firstLine(buf: []const u8) []const u8 {
    return buf; // STUB
}

test "decide is fail-closed: the helper starts only on a good port, in time, with netd alive" {
    try std.testing.expectEqual(Outcome.start_helper, decide(50607, false, false));
    try std.testing.expectEqual(Outcome.network_failure, decide(null, false, false)); // malformed/absent port
    try std.testing.expectEqual(Outcome.network_failure, decide(50607, true, false)); // deadline passed
    try std.testing.expectEqual(Outcome.network_failure, decide(50607, false, true)); // netd exited first
    try std.testing.expectEqual(Outcome.network_failure, decide(null, true, true)); // everything wrong
    try std.testing.expectEqual(Outcome.network_failure, decide(1, true, false));
}

test "readyPort reuses the Darwin ready grammar" {
    try std.testing.expectEqual(@as(?u16, 50607), readyPort("netd ready 127.0.0.1:50607"));
    try std.testing.expectEqual(@as(?u16, null), readyPort("netd ready 127.0.0.1:0")); // zero
    try std.testing.expectEqual(@as(?u16, null), readyPort("netd ready 127.0.0.1:050607")); // leading zero
    try std.testing.expectEqual(@as(?u16, null), readyPort("netd ready 127.0.0.1:50607 ")); // trailing byte
    try std.testing.expectEqual(@as(?u16, null), readyPort("netd ready ::1:50607")); // wrong host
    try std.testing.expectEqual(@as(?u16, null), readyPort("netd ready")); // no port
}

test "firstLine takes exactly the first line" {
    try std.testing.expectEqualStrings("netd ready 127.0.0.1:5", firstLine("netd ready 127.0.0.1:5\nextra\n"));
    try std.testing.expectEqualStrings("no newline yet", firstLine("no newline yet"));
    try std.testing.expectEqualStrings("", firstLine("\nsecond"));
}

test "appendEgressPort appends the flag + decimal port and leaves the base untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "python", "-m", "zb_agent_host", "launch", "--home", "/h", "--command", "chat" };
    const out = try appendEgressPort(a, &base, 50607);
    try std.testing.expectEqual(@as(usize, base.len + 2), out.len);
    try std.testing.expectEqualStrings("--egress-port", out[base.len]);
    try std.testing.expectEqualStrings("50607", out[base.len + 1]);
    try std.testing.expectEqualStrings("python", out[0]);
    try std.testing.expectEqualStrings("chat", out[base.len - 1]);
}

test "appendEgressPort renders the full u16 range as plain decimal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{"x"};
    const out = try appendEgressPort(a, &base, 65535);
    try std.testing.expectEqualStrings("65535", out[2]);
    try std.testing.expectEqual(@as(?u16, 65535), readyPort("netd ready 127.0.0.1:65535"));
}
