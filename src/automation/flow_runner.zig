//! The runner the site flows (x.*, linkedin.*, instagram.*) execute their
//! steps through: one router command per step via Engine.External, so every
//! step gets retries, actionability checks and telemetry under the flow
//! command's single root span.
const std = @import("std");
const engine_mod = @import("engine.zig");
const script_command = @import("script_command.zig");

/// Runner for the site flows (src/x.zig, src/linkedin.zig, src/instagram.zig;
/// contract in src/flow_steps.zig): one command per
/// call, keeping the last result (borrowed by the flow until the next call)
/// and the latest failure. A failure stays until a newer one replaces it
/// (a later successful lookup, like the login-link probe after a failed
/// composer wait, must not erase the failure that stopped the flow). Every
/// failure it hands out carries the x.* command's trace_id/command_id.
pub const Runner = struct {
    gpa: std.mem.Allocator,
    ext: *engine_mod.External,
    deadline_ms: u64,
    /// data.reason when the flow budget runs out (e.g. "x_flow_deadline").
    deadline_reason: []const u8,
    last_result: ?engine_mod.Outcome = null,
    failure: ?engine_mod.Outcome = null,
    /// Set once the flow budget stopped a step: every later step fails too
    /// (no fallback probe may run, or reinterpret the stop).
    expired: bool = false,

    pub fn run(self: *Runner, method: []const u8, params_json: []const u8) error{OutOfMemory}!?[]const u8 {
        // No step starts without budget; a waitFor also needs room for the
        // engine's native grace on top of its (clamped) JS timeout.
        if (self.expired) return null;
        const needed: u64 = if (std.mem.eql(u8, method, "dom.waitFor")) engine_mod.wait_for_native_grace_ms else 0;
        if (self.remainingMs() <= needed) {
            self.setFailure(try engine_mod.automationFailure(self.gpa, .action_timeout, self.deadline_reason, self.ext.ids()));
            self.expired = true;
            return null;
        }
        const outcome = try self.ext.runCommand(self.gpa, method, params_json);
        switch (outcome) {
            .result => |json| {
                self.dropResult();
                self.last_result = outcome;
                return json;
            },
            .failure => {
                self.setFailure(outcome);
                return null;
            },
        }
    }

    pub fn nowMs(self: *const Runner) u64 {
        return self.ext.nowMs();
    }

    pub fn remainingMs(self: *const Runner) u64 {
        return self.deadline_ms -| self.ext.nowMs();
    }

    pub fn pause(self: *Runner, ms: u64) bool {
        if (self.ext.pause(ms)) return true;
        const cancelled = engine_mod.automationFailure(self.gpa, .cancelled, null, self.ext.ids()) catch {
            self.clearFailure();
            return false;
        };
        self.setFailure(cancelled);
        return false;
    }

    /// The latest step succeeded but its answer was unusable.
    pub fn malformed(self: *Runner) error{OutOfMemory}!void {
        self.setFailure(try internalFailure(self.gpa, self.ext.ids()));
    }

    pub fn notFound(self: *Runner, reason: []const u8) error{OutOfMemory}!void {
        self.setFailure(try engine_mod.automationFailure(self.gpa, .element_not_found, reason, self.ext.ids()));
    }

    fn setFailure(self: *Runner, outcome: engine_mod.Outcome) void {
        self.clearFailure();
        self.failure = outcome;
    }

    fn clearFailure(self: *Runner) void {
        if (self.failure) |*old| old.deinit(self.gpa);
        self.failure = null;
    }

    fn dropResult(self: *Runner) void {
        if (self.last_result) |*old| old.deinit(self.gpa);
        self.last_result = null;
    }

    pub fn deinit(self: *Runner) void {
        self.dropResult();
        if (self.failure) |*f| f.deinit(self.gpa);
    }

    /// Hands the recorded failure to the caller. src/x.zig records one for
    /// every null it returns; if a flow ever stops without one, that is an
    /// internal error (still with ids), never a stale or missing failure.
    pub fn takeFailure(self: *Runner) error{OutOfMemory}!engine_mod.Outcome {
        const f = self.failure orelse return internalFailure(self.gpa, self.ext.ids());
        self.failure = null;
        return f;
    }
};

/// -32603 "Unexpected page answer" with `data.{trace_id, command_id}`.
pub fn internalFailure(gpa: std.mem.Allocator, ids: script_command.Ids) error{OutOfMemory}!engine_mod.Outcome {
    const Data = struct { trace_id: []const u8, command_id: []const u8 };
    return .{ .failure = .{
        .code = engine_mod.internal_error_code,
        .message = "Unexpected page answer",
        .data_json = try std.json.Stringify.valueAlloc(gpa, Data{ .trace_id = ids.trace_id, .command_id = ids.command_id }, .{}),
    } };
}
