pub const errors = @import("automation/error.zig");
pub const router = @import("automation/router.zig");
pub const telemetry = @import("automation/telemetry.zig");
pub const page_port = @import("automation/page_port.zig");
pub const script_command = @import("automation/script_command.zig");
pub const engine = @import("automation/engine.zig");
pub const queue = @import("automation/queue.zig");
pub const social_routes = @import("automation/social_routes.zig");
pub const cookie_port = @import("automation/cookie_port.zig");
pub const cookie_routes = @import("automation/cookie_routes.zig");

pub const phase1_command_verbs = [_][]const u8{
    "dom.query",
    "dom.click",
    "dom.fill",
    "dom.type",
    "dom.getText",
    "dom.getAttribute",
    "dom.waitFor",
    "page.navigate",
    "page.reload",
    "page.url",
    "page.title",
    "page.evaluate",
    "page.screenshot",
};

pub fn isPhase1CommandVerb(method: []const u8) bool {
    for (phase1_command_verbs) |verb| {
        if (std.mem.eql(u8, verb, method)) return true;
    }
    return false;
}

const std = @import("std");
