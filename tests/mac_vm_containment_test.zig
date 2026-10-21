//! The stubbed macOS VM-containment seam (MS6.5; the user's decision, 2026-10-21). Pins: OFF by default; the
//! backend reports "not available yet"; and the launch gate fails CLOSED when the setting is on — a mutant that
//! lets `.on` proceed (fails OPEN) reds the "fails closed" test. Linux unit; no OS calls, so it runs anywhere.
const std = @import("std");
const vm = @import("mac_vm_containment");

test "the setting is off by default, and parse/resolve round-trip the two tags" {
    try std.testing.expectEqual(vm.Setting.off, vm.default_setting);
    try std.testing.expectEqual(@as(?vm.Setting, .on), vm.parse("on"));
    try std.testing.expectEqual(@as(?vm.Setting, .off), vm.parse("off"));
    try std.testing.expectEqual(@as(?vm.Setting, null), vm.parse("yes"));
    // unset env + no flag -> the default (off); an unknown env value -> default, and startup is told via bad_env
    try std.testing.expectEqual(vm.Setting.off, vm.resolve(null, null).value);
    try std.testing.expectEqual(vm.Setting.on, vm.resolve(null, "on").value);
    const bad = vm.resolve(null, "virtualize");
    try std.testing.expectEqual(vm.Setting.off, bad.value);
    try std.testing.expect(bad.bad_env != null);
}

test "the backend reports not available yet (the stub never claims containment)" {
    try std.testing.expectEqual(vm.Availability.not_available_yet, vm.availability());
}

test "gate: OFF proceeds; ON fails CLOSED while the backend is not available" {
    try std.testing.expectEqual(vm.Gate.proceed, vm.gate(.off, .not_available_yet));
    switch (vm.gate(.on, .not_available_yet)) {
        .proceed => return error.FailedOpen, // a fail-OPEN mutant (ON proceeds) must red here
        .refuse => |line| try std.testing.expectEqualStrings(vm.not_available_refusal, line),
    }
}

test "gate: OFF proceeds regardless, so the shipping default is never blocked" {
    try std.testing.expectEqual(vm.Gate.proceed, vm.gate(.off, .not_available_yet));
}
