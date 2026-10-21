//! Builds the JS sent through PagePort.evalJson and parses what comes back.
//!
//! automation.js speaks `{op, selector, ...}` commands and answers
//! `{ok, value, error, retryable, data, telemetry}`. The router speaks
//! `ParsedCommand`. This file is the only place that maps one to the other.
const std = @import("std");
const router = @import("router.zig");

pub const Ids = struct {
    trace_id: []const u8,
    /// Root `automation.command` span id; automation.js uses it as the parent
    /// of its selector/actionability child spans.
    parent_span_id: []const u8,
    command_id: []const u8,
    /// 0-based retry attempt index for child-span telemetry.
    attempt_index: u32 = 0,
    /// N23: `data.reason` for a page that is gone (NoPage), e.g. "no_window"
    /// for a command sent to a window; null = no reason. Never sent to the
    /// script.
    no_page_reason: ?[]const u8 = null,
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
        .dom_press => "press",
        .dom_select_option => "selectOption",
        .dom_set_input_files => "chooseFiles",
        .dom_hover => "hover",
        .dom_scroll => "scroll",
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
    key: ?[]const u8 = null,
    modifiers: ?[]const []const u8 = null,
    label: ?[]const u8 = null,
    index: ?u64 = null,
    /// chooseFiles: how many files the chooser will get (never the paths).
    count: ?usize = null,
    /// scroll by offset: CSS px.
    x: ?f64 = null,
    y: ?f64 = null,
    timeout_ms: ?u64 = null,
    /// `locate` op only: the action whose checks apply, and whether to focus.
    action: ?[]const u8 = null,
    focus: ?bool = null,
    /// S8 decision 14: re-checked by automation.js before every page-visible step.
    guard: ?router.Guard = null,
    /// S8 decision 15: one chunk of a guarded dom.type.
    chunk: ?bool = null,
    trace_id: []const u8,
    parent_span_id: []const u8,
    command_id: []const u8,
    attempt_index: u32,
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
    // Native input locates its target in the page and sends the input
    // itself: the typed text and key never go to the script.
    const locate = command.locate;
    const script_command = ScriptCommand{
        .op = if (locate) |l| l.op else op,
        .selector = command.selector,
        .value = if (locate != null) null else command.value,
        .text = if (locate != null) null else command.text,
        .name = command.name,
        .strict = command.strict,
        .options = .{ .force = command.force, .trial = command.trial },
        .state = if (command.verb == .dom_wait_for) @tagName(command.wait_state) else null,
        .key = if (locate != null) null else command.key,
        .modifiers = if (command.verb == .dom_press and locate == null) command.modifiers else null,
        .label = command.label,
        .index = command.option_index,
        .count = if (command.verb == .dom_set_input_files and locate == null) command.paths.len else null,
        .x = if (locate == null) command.scroll_x else null,
        .y = if (locate == null) command.scroll_y else null,
        .timeout_ms = timeout_ms orelse command.timeout_ms,
        .action = if (locate) |l| l.action else null,
        .focus = if (locate) |l| l.focus else null,
        .guard = if (locate != null) null else command.guard,
        .chunk = if (command.chunk) true else null,
        .trace_id = ids.trace_id,
        .parent_span_id = ids.parent_span_id,
        .command_id = ids.command_id,
        .attempt_index = ids.attempt_index,
    };
    return std.json.Stringify.valueAlloc(gpa, script_command, .{ .emit_null_optional_fields = false });
}

/// Fixed async-function body that calls the injected script with the command
/// JSON bound to the JS variable `arg` (see PagePort.evalJson). It always
/// returns a JSON string, even when the script is missing or throws. Command
/// data is never spliced into this source.
pub const handle_body =
    "try {\n" ++
    "  const h = globalThis.__zbAutomation;\n" ++
    "  if (!h || typeof h.handle !== 'function') return JSON.stringify({ok:false,error:'" ++ script_not_ready ++ "',retryable:true,data:{reason:'" ++ script_not_ready ++ "'}});\n" ++
    "  return JSON.stringify(await h.handle(JSON.parse(arg)));\n" ++
    "} catch (e) {\n" ++
    "  return JSON.stringify({ok:false,error:'" ++ script_exception ++ "',retryable:false,data:{reason:'" ++ script_exception ++ "'}});\n" ++
    "}";

/// Async-function body for page.evaluate. The expression is code by
/// definition, so it is pasted in (not passed to eval), which also keeps page
/// CSP `unsafe-eval` rules out of the way. A syntax error in the expression
/// fails the native call. On a JS exception only the exception's constructor
/// name is reported; the message can carry page data and is not returned.
pub fn buildEvaluateBody(gpa: std.mem.Allocator, expression: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "try {{\n" ++
            "  const __zbValue = await (\n{s}\n);\n" ++
            "  return JSON.stringify({{ok:true,value:__zbValue === undefined ? null : __zbValue}});\n" ++
            "}} catch (e) {{\n" ++
            "  const name = (e && typeof e.name === 'string' && /^[A-Za-z]{{1,64}}$/.test(e.name)) ? e.name : 'Error';\n" ++
            "  return JSON.stringify({{ok:false,error:'" ++ script_exception ++ "',retryable:false,data:{{reason:'" ++ script_exception ++ "',name:name}}}});\n" ++
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
    /// automation.js child span drafts (`telemetry` array), if any.
    telemetry: ?std.json.Value,

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
        .telemetry = obj.get("telemetry"),
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
