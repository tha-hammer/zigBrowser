//! Builds the JS sent through PagePort.evalJson and parses what comes back.
//!
//! automation.js speaks `{op, selector, ...}` commands and answers
//! `{ok, value, error, retryable, data, telemetry}`. The router speaks
//! `ParsedCommand`. This file is the only place that maps one to the other.
const std = @import("std");
const router = @import("router.zig");

pub const Ids = struct {
    trace_id: []const u8,
    command_id: []const u8,
};

/// Script error used when `__zbAutomation` is not installed in the page yet.
pub const script_not_ready = "script_not_ready";
/// Script error used when the JS body itself threw.
pub const script_exception = "script_exception";

/// automation.js op for a dom.* verb; null for page.* verbs.
pub fn opName(verb: router.Verb) ?[]const u8 {
    return switch (verb) {
        .dom_query => "query",
        .dom_get_text => "getText",
        .dom_get_attribute => "getAttribute",
        .dom_click => "click",
        .dom_fill => "fill",
        .dom_type => "type",
        .dom_wait_for => "waitFor",
        .page_navigate,
        .page_reload,
        .page_url,
        .page_title,
        .page_evaluate,
        .page_screenshot,
        => null,
    };
}

const ScriptOptions = struct {
    force: bool,
    trial: bool,
};

const ScriptCommand = struct {
    op: []const u8,
    selector: ?[]const u8 = null,
    value: ?[]const u8 = null,
    text: ?[]const u8 = null,
    name: ?[]const u8 = null,
    strict: bool,
    options: ScriptOptions,
    state: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    trace_id: []const u8,
    command_id: []const u8,
};

/// JSON for `__zbAutomation.handle(...)`. `timeout_ms` overrides the parsed
/// command's timeout (the engine passes the remaining deadline for waitFor).
pub fn buildCommandJson(
    gpa: std.mem.Allocator,
    command: *const router.ParsedCommand,
    ids: Ids,
    timeout_ms: ?u64,
) error{ OutOfMemory, NotADomCommand }![]u8 {
    const op = opName(command.verb) orelse return error.NotADomCommand;
    const script_command = ScriptCommand{
        .op = op,
        .selector = command.selector,
        .value = command.value,
        .text = command.text,
        .name = command.name,
        .strict = command.strict,
        .options = .{ .force = command.force, .trial = command.trial },
        .state = if (command.verb == .dom_wait_for) @tagName(command.wait_state) else null,
        .timeout_ms = timeout_ms orelse command.timeout_ms,
        .trace_id = ids.trace_id,
        .command_id = ids.command_id,
    };
    return std.json.Stringify.valueAlloc(gpa, script_command, .{ .emit_null_optional_fields = false });
}

/// Async-function body that calls the injected script and always returns a
/// JSON string, even when the script is missing or throws.
pub fn buildHandleBody(gpa: std.mem.Allocator, command_json: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "try {{\n" ++
            "  const h = globalThis.__zbAutomation;\n" ++
            "  if (!h || typeof h.handle !== 'function') return JSON.stringify({{ok:false,error:'" ++ script_not_ready ++ "',retryable:true,data:{{reason:'" ++ script_not_ready ++ "'}}}});\n" ++
            "  return JSON.stringify(await h.handle({s}));\n" ++
            "}} catch (e) {{\n" ++
            "  return JSON.stringify({{ok:false,error:'" ++ script_exception ++ "',retryable:false,data:{{reason:'" ++ script_exception ++ "'}}}});\n" ++
            "}}",
        .{command_json},
    );
}

/// Async-function body for page.evaluate. The expression is pasted in as code
/// (not passed to eval) so page CSP `unsafe-eval` rules do not apply. A syntax
/// error in the expression fails the whole native call.
pub fn buildEvaluateBody(gpa: std.mem.Allocator, expression: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "try {{\n" ++
            "  const __zbValue = await (\n{s}\n);\n" ++
            "  return JSON.stringify({{ok:true,value:__zbValue === undefined ? null : __zbValue}});\n" ++
            "}} catch (e) {{\n" ++
            "  return JSON.stringify({{ok:false,error:'" ++ script_exception ++ "',retryable:false,data:{{reason:'" ++ script_exception ++ "',name:String(e && e.name || 'Error'),message:String(e && e.message || e)}}}});\n" ++
            "}}",
        .{expression},
    );
}

/// Parsed `{ok, value, error, retryable, data}` script answer. Slices point
/// into `parsed`; call `deinit`.
pub const ScriptResult = struct {
    parsed: std.json.Parsed(std.json.Value),
    ok: bool,
    value: std.json.Value,
    error_name: ?[]const u8,
    reason: ?[]const u8,
    retryable: bool,
    data: ?std.json.Value,

    pub fn deinit(self: *ScriptResult) void {
        self.parsed.deinit();
    }
};

pub fn parseScriptResult(gpa: std.mem.Allocator, text: []const u8) error{ OutOfMemory, MalformedScriptResult }!ScriptResult {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedScriptResult,
    };
    errdefer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedScriptResult,
    };
    const ok = switch (obj.get("ok") orelse return error.MalformedScriptResult) {
        .bool => |b| b,
        else => return error.MalformedScriptResult,
    };

    const data = obj.get("data");
    var result = ScriptResult{
        .parsed = parsed,
        .ok = ok,
        .value = obj.get("value") orelse .null,
        .error_name = null,
        .reason = null,
        .retryable = false,
        .data = data,
    };
    if (ok) return result;

    result.error_name = switch (obj.get("error") orelse return error.MalformedScriptResult) {
        .string => |s| s,
        else => return error.MalformedScriptResult,
    };
    if (obj.get("retryable")) |retryable| switch (retryable) {
        .bool => |b| result.retryable = b,
        else => {},
    };
    if (data) |d| switch (d) {
        .object => |data_obj| if (data_obj.get("reason")) |reason| switch (reason) {
            .string => |s| result.reason = s,
            else => {},
        },
        else => {},
    };
    return result;
}
