//! The MS6.5 run-survivor classification core (src/agent_run_reaper.c, compiled in by build.zig). Pure, no OS
//! calls, so it runs anywhere: it pins the component-aware "under the run dir" test and the kill-safety refusals
//! (root/empty run dir match nothing). A mutant that does a naive strncmp prefix, or drops the root guard, reds.
const std = @import("std");

extern fn zb_reaper_path_under(path: ?[*:0]const u8, dir: ?[*:0]const u8) c_int;
extern fn zb_reaper_run_dir_ok(dir: ?[*:0]const u8) c_int;
extern fn zb_reaper_classify(
    cwd: ?[*:0]const u8,
    exe: ?[*:0]const u8,
    fd_paths: ?[*]const ?[*:0]const u8,
    nfds: c_int,
    run_dir: ?[*:0]const u8,
) c_int;

const RUN = "/run/zb-net/zigbrowser-agent-123-0011223344556677";

test "path_under matches the dir itself and children, by whole components" {
    try std.testing.expectEqual(@as(c_int, 1), zb_reaper_path_under(RUN ++ "/egress/proxy.sock", RUN));
    try std.testing.expectEqual(@as(c_int, 1), zb_reaper_path_under(RUN, RUN)); // the dir itself
    try std.testing.expectEqual(@as(c_int, 1), zb_reaper_path_under(RUN ++ "/x", RUN ++ "/")); // trailing slash on dir
}

test "path_under rejects a sibling that only shares a string prefix (component boundary)" {
    // The decisive case for the component boundary: another run dir whose name EXTENDS this one with no slash.
    // `RUN` is a whole-string prefix of it, so a naive strncmp would wrongly match it; the boundary check rejects.
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_path_under(RUN ++ "deadbeef", RUN));
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_path_under(RUN ++ "-2/egress/x", RUN));
    // siblings that differ within the name, and the parent, are also not under it.
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_path_under("/run/zb-net/zigbrowser-agent-123-00112233445566FF", RUN));
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_path_under("/run/zb-net/zigbrowser-agent-123-001122334455", RUN)); // shorter
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_path_under("/run/zb-net", RUN)); // the parent is not "under"
}

test "path_under fails closed on root/empty/null (never a whole-system sweep)" {
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_path_under("/anything/at/all", "/"));
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_path_under("/anything", "///")); // collapses to root
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_path_under("/anything", ""));
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_path_under(null, RUN));
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_path_under(RUN ++ "/x", null));
}

test "classify is a survivor when cwd, exe, or an open file is under the run dir" {
    const outside = [_]?[*:0]const u8{ "/usr/lib/x.dylib", "/dev/null" };
    const with_sock = [_]?[*:0]const u8{ "/dev/null", RUN ++ "/bridges/a.sock" };
    // cwd under
    try std.testing.expectEqual(@as(c_int, 1), zb_reaper_classify(RUN ++ "/cwd", "/usr/bin/python3", &outside, 2, RUN));
    // exe under
    try std.testing.expectEqual(@as(c_int, 1), zb_reaper_classify("/tmp", RUN ++ "/bin/hook", &outside, 2, RUN));
    // an open file under
    try std.testing.expectEqual(@as(c_int, 1), zb_reaper_classify("/tmp", "/usr/bin/python3", &with_sock, 2, RUN));
    // none under -> not a survivor
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_classify("/tmp", "/usr/bin/python3", &outside, 2, RUN));
    // null cwd/exe + no fds -> not a survivor
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_classify(null, null, null, 0, RUN));
}

test "classify fails closed on a root/empty run dir" {
    const fds = [_]?[*:0]const u8{"/anything/x"};
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_classify("/anything", "/anything", &fds, 1, "/"));
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_classify("/anything", "/anything", &fds, 1, ""));
}

test "run_dir_ok accepts only the exact sockdirPath grammar, canonical and deep (RoseCat f907e95 #2)" {
    // zigbrowser-agent-<pid: 1+ digits>-<exactly 16 lowercase hex>, depth >= 2, under any resolved parent.
    try std.testing.expectEqual(@as(c_int, 1), zb_reaper_run_dir_ok("/var/folders/qx/T/zigbrowser-agent-123-0011223344556677"));
    try std.testing.expectEqual(@as(c_int, 1), zb_reaper_run_dir_ok("/private/tmp/zb/zigbrowser-agent-1-0123456789abcdef"));
    try std.testing.expectEqual(@as(c_int, 1), zb_reaper_run_dir_ok("/Users/bob/Library/Caches/zigbrowser-agent-99999-ffffffffffffffff"));
}

test "run_dir_ok rejects a loose prefix, wrong hex length/case, broad ancestors, root children, non-canonical" {
    const P = "/var/folders/qx/T/"; // a valid resolved parent
    // the exact grammar: a short name, wrong hex length, uppercase hex, a missing pid, or a trailing suffix:
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok(P ++ "zigbrowser-agent-1-ff"));                 // 2 hex (too short)
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok(P ++ "zigbrowser-agent-123-00112233")); // 8 hex
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok(P ++ "zigbrowser-agent-123-0011223344556677ff")); // 18 hex
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok(P ++ "zigbrowser-agent-123-00112233445566AB")); // uppercase
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok(P ++ "zigbrowser-agent--0011223344556677"));     // no pid
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok(P ++ "zigbrowser-agent-123-0011223344556677-x")); // trailing
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok(P ++ "some-other-dir"));                          // no signature
    // broad ancestors a naive marker would let sweep the user's real processes:
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok("/"));
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok("/tmp"));
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok("/Users/bob"));
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok("/zigbrowser-agent-123-0011223344556677")); // root child (depth < 2)
    // not absolute / not canonical:
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok("zigbrowser-agent-123-0011223344556677"));
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok("/a//zigbrowser-agent-123-0011223344556677"));  // "//"
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok("/a/./zigbrowser-agent-123-0011223344556677")); // "/."
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok("/a/../zigbrowser-agent-123-0011223344556677")); // "/.."
    try std.testing.expectEqual(@as(c_int, 0), zb_reaper_run_dir_ok(null));
}
