//! Stubbed macOS VM containment (MS6.5; the user's decision, 2026-10-21): a PLANNED seam for an Apple
//! Virtualization-framework agent sandbox, OFF by default. The user accepted the detached-process escape risk
//! with cleanup + a survivor warning (see `agent_run_reaper`), and asked that a VM containment mode be stubbed
//! "for better security" — a seam and a test that it reports "not available yet", not an implementation.
//!
//! So the backend is NOT built here: `availability()` reports `.not_available_yet`, and `gate()` fails CLOSED
//! when the setting is on — the app refuses to run an agent believing it is VM-contained when it is not. When
//! the real Virtualization backend lands, `availability()` flips and `gate(.on, .available)` proceeds; nothing
//! else about the seam changes. OFF is the shipping default, so this gate is a no-op for every current user.
const std = @import("std");
const env_switch = @import("env_switch.zig");

/// The off-by-default user setting. The env var is honored now; a `--agent-vm-containment on|off` CLI flag is a
/// follow-up (it threads through `cli.zig` exactly as `--agent-drawer` does).
pub const Setting = enum { off, on };
pub const default_setting: Setting = .off;
pub const env_name = "ZIGBROWSER_AGENT_VM_CONTAINMENT";
const flag_or_env = env_switch.Switch(Setting, default_setting);
pub const parse = flag_or_env.parse;
pub const Resolved = flag_or_env.Resolved;
pub const resolve = flag_or_env.resolve;

/// What the VM-containment backend can do right now. Only one state exists until the Apple Virtualization
/// backend is implemented; the enum is the seam where `.available` (and its parameters) will be added.
pub const Availability = enum { not_available_yet };

/// The planned seam: where the real backend reports itself ready. Stubbed to never-ready, so the app can never
/// mistake "requested" for "contained".
pub fn availability() Availability {
    return .not_available_yet;
}

/// The launch gate for the setting. OFF proceeds (containment not requested — the normal Seatbelt path applies).
/// ON fails CLOSED while the backend is not available, so the app refuses rather than run an agent uncontained
/// under the belief it is VM-contained.
pub const Gate = union(enum) { proceed, refuse: []const u8 };
pub const not_available_refusal = "zigBrowser: agent: VM containment is not available yet";
pub fn gate(setting: Setting, avail: Availability) Gate {
    return switch (setting) {
        .off => .proceed,
        .on => switch (avail) {
            .not_available_yet => .{ .refuse = not_available_refusal },
        },
    };
}

pub const invalid_setting_refusal = "zigBrowser: agent: ZIGBROWSER_AGENT_VM_CONTAINMENT must be 'on' or 'off'";

/// The launch decision from a RESOLVED setting — the exact function the app calls (`app.zig` runAgentSetup). A
/// malformed explicit value (`bad_env` set) fails CLOSED with a diagnostic (RoseCat 7199): a security setting
/// must never silently fall back to the default `.off` and run uncontained. Otherwise the ordinary `gate`.
pub fn gateResolved(r: Resolved, avail: Availability) Gate {
    if (r.bad_env != null) return .{ .refuse = invalid_setting_refusal };
    return gate(r.value, avail);
}
