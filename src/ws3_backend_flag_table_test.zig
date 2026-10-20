//! WS3.2 / MS3.2 flag-decision property (UNREGISTERED red — the shared backend-flag seam).
//!
//! This is the [L] oracle the WS3 coordination proposal pins: `backendFlagDecision(os, flag, value)`
//! must, for every (flag, value) in the generated cross-product of known flags x {known-good,
//! known-bad, unknown}, return `.apply` or `.refuse` matching the documented table — with **no C ABI**
//! (a pure decision, separable from `webkit.zig`'s backend code so it tests on Linux).
//!
//! To be [L]-unit-testable the pure decision must live in its own pure module `src/backend_flag.zig`
//! (imported by `webkit.zig`'s `applyBackendFlag`); this test imports exactly that. It is **RED today**
//! because `src/backend_flag.zig` / `backendFlagDecision` do not exist yet (only the Linux apply path,
//! `webkit.zig:47-72`). It goes GREEN when BlueBeaver lands the backend-flag seam pre-slice and the
//! WS3 `.windows` arm. Mutant: accept an unknown value ⇒ red.
//!
//! Intentionally NOT registered in build.zig until green (a red must not live in a gate step).
//! Prove red:  zig test src/ws3_backend_flag_table_test.zig

const std = @import("std");
const bf = @import("backend_flag.zig"); // RED: this module does not exist yet (the seam BlueBeaver owns)

const Case = struct { flag: []const u8, value: []const u8, apply: bool };

// The documented table for the `.windows` arm (WS3.2). `apply` = true means the value is applied;
// false means the seam returns error.UnsupportedFlag and the binary exits nonzero with the exact message.
const windows_table = [_]Case{
    .{ .flag = "media-source", .value = "off", .apply = true },
    .{ .flag = "media-source", .value = "on", .apply = true },
    .{ .flag = "media-source", .value = "bogus", .apply = false },
    .{ .flag = "hardware-acceleration", .value = "never", .apply = true },
    .{ .flag = "hardware-acceleration", .value = "always", .apply = true },
    // The production-literal table (BlueBeaver 6413; RoseCat 6405, 6416): `webkit` is the
    // default and there is no `auto`, which is refused.
    .{ .flag = "hardware-acceleration", .value = "webkit", .apply = true },
    .{ .flag = "hardware-acceleration", .value = "auto", .apply = false },
    .{ .flag = "hardware-acceleration", .value = "bogus", .apply = false },
    // --renderer has no supported value on Windows (WS3.2: "--renderer=<v> is not supported on Windows").
    .{ .flag = "renderer", .value = "webview2", .apply = false },
    .{ .flag = "renderer", .value = "bogus", .apply = false },
    // an unknown flag is always refused.
    .{ .flag = "no-such-flag", .value = "x", .apply = false },
};

test "windows backend-flag decisions match the documented table (no C ABI)" {
    for (windows_table) |c| {
        const decision = bf.backendFlagDecision(.windows, c.flag, c.value);
        const applied = decision == .apply;
        try std.testing.expectEqual(c.apply, applied);
    }
}

test "an unsupported value refuses rather than silently accepting (mutant guard)" {
    // The load-bearing property: an unknown value must NOT be accepted (a silent accept is the mutant).
    try std.testing.expect(bf.backendFlagDecision(.windows, "media-source", "garbage") == .refuse);
    try std.testing.expect(bf.backendFlagDecision(.windows, "renderer", "anything") == .refuse);
}
