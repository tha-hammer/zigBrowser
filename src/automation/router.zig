const std = @import("std");
const telemetry = @import("telemetry.zig");

pub const Namespace = enum { dom, page };

pub const Verb = enum {
    dom_query,
    dom_click,
    dom_fill,
    dom_type,
    dom_get_text,
    dom_get_attribute,
    dom_wait_for,
    dom_press,
    dom_select_option,
    dom_set_input_files,
    dom_hover,
    dom_scroll,
    page_navigate,
    page_reload,
    page_url,
    page_title,
    page_evaluate,
    page_screenshot,
};

pub const WaitState = enum { attached, visible, hidden, detached };

/// page.navigate `onBeforeUnload`: what to do when the page asks "Leave
/// site?". `fail` (default) returns dialog_open and leaves the prompt open.
pub const BeforeUnload = enum { fail, accept, dismiss };

/// `options.input`: synthetic DOM events from automation.js (default), or
/// real platform input (PagePort.native*, `event.isTrusted === true`).
/// Accepted for dom.click, dom.type, dom.press, dom.hover and dom.scroll
/// (native never with `force`); on any other method even its presence is
/// BadArgs.
pub const InputMode = enum { synthetic, native };

/// Internal (never parsed from JSON): turns a dom.* command into the
/// automation.js op that native input uses to find its target: `locate`
/// (find, scroll into view, check, optionally focus) or `measure` (find
/// only: native scroll must not scroll the page itself).
pub const Locate = struct {
    op: []const u8 = "locate",
    action: []const u8,
    focus: bool,
};

/// S8 phase A (chat-drawer plan, "S8 in detail" decision 2): an approval card's state of the
/// bound window, checked by the engine inside the run's own FIFO ticket before any page input.
/// `options.expect` on dom.click, dom.fill, dom.type, dom.press, dom.selectOption, page.navigate
/// and page.reload only, never with native input or humanize.
pub const Expect = struct {
    /// The window's page origin as `engine.originOf` gives it.
    origin: []const u8,
    load_serial: u64,
};

/// S8 decision 14: what automation.js re-checks before every page-visible step of an action
/// (each event, focus, value write and insert), in the action's own task. `options.guard` on
/// dom.click, dom.fill, dom.type, dom.press and dom.selectOption, synthetic input only.
pub const Guard = struct {
    pub const Mark = struct {
        /// An automation selector that must match exactly one visible element.
        selector: []const u8,
        /// The attribute compared; null: the element's normalized text.
        attribute: ?[]const u8 = null,
        value: []const u8,
        /// S8 decision 13: the attribute is a URL; it must resolve, against the page, to the
        /// page's own origin with exactly `value` as its pathname. Needs `attribute`.
        path: ?bool = null,
    };
    marks: []const Mark = &.{},
    /// The action's own selector still resolves, strictly, to the same element.
    target: bool = false,
    /// S8 decision 13: the exact `location.pathname` the step requires.
    path: ?[]const u8 = null,
    /// S8 decision 13 (rev 16.20.55): automation.js's token of the document the step must run in.
    document: ?[]const u8 = null,
};

pub const max_guard_marks = 8;

pub const RouteContext = struct {
    page_id: []const u8 = "page-unknown",
    window_id: []const u8 = "window-unknown",
    /// Used by the engine for the root command span and its children
    /// (router.parse never records telemetry).
    telemetry_sink: ?telemetry.TelemetrySink = null,
};

pub const ParsedCommand = struct {
    arena: std.heap.ArenaAllocator,
    method: []const u8,
    namespace: Namespace,
    verb: Verb,
    selector: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    text: ?[]const u8 = null,
    expression: ?[]const u8 = null,
    url: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
    strict: bool = false,
    force: bool = false,
    trial: bool = false,
    delay_ms: ?u64 = null,
    wait_state: WaitState = .visible,
    wait_until: ?[]const u8 = null,
    /// page.navigate `onBeforeUnload`.
    before_unload: BeforeUnload = .fail,
    full_page: bool = false,
    /// dom.press: KeyboardEvent.key value.
    key: ?[]const u8 = null,
    /// dom.press: subset of Shift/Control/Alt/Meta, no duplicates.
    modifiers: []const []const u8 = &.{},
    /// dom.selectOption: option label (`value` holds the option value).
    label: ?[]const u8 = null,
    /// dom.selectOption: 0-based option index.
    option_index: ?u64 = null,
    /// dom.setInputFiles: the files to choose (non-empty strings, no NUL).
    paths: []const []const u8 = &.{},
    /// dom.scroll without a selector: CSS px to scroll by (a missing one
    /// of the two is 0). Null with a selector.
    scroll_x: ?f64 = null,
    scroll_y: ?f64 = null,
    input: InputMode = .synthetic,
    /// `options.humanize` (N8): human-like timing and pointer paths for
    /// native click/type/press; the engine owns the schedule.
    humanize: bool = false,
    locate: ?Locate = null,
    /// S8: `options.expect` (approved runs).
    expect: ?Expect = null,
    /// S8 decision 14: `options.guard`.
    guard: ?Guard = null,
    /// Internal (never parsed): one chunk of a guarded dom.type (S8 decision 15); automation.js
    /// then reports the chunk's own sent counts on success too.
    chunk: bool = false,
    /// Internal: on every chunk after the first, chunk 1's target element token and document
    /// token (RoseCat on 76cb14a); automation.js types only into that element of that document.
    chunk_target: ?[]const u8 = null,
    chunk_document: ?[]const u8 = null,

    pub fn deinit(self: *ParsedCommand) void {
        self.arena.deinit();
    }
};

pub fn parse(
    allocator: std.mem.Allocator,
    method: []const u8,
    params_json: []const u8,
    context: RouteContext,
) (error{ UnknownCommand, BadArgs })!ParsedCommand {
    _ = context;
    const verb = verbFromMethod(method) orelse return error.UnknownCommand;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, normalizedParams(params_json), .{}) catch return error.BadArgs;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |object| object,
        else => return error.BadArgs,
    };

    var command = ParsedCommand{
        .arena = undefined,
        .method = arena_allocator.dupe(u8, method) catch return error.BadArgs,
        .namespace = namespaceFromVerb(verb),
        .verb = verb,
    };

    switch (verb) {
        .dom_query => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.strict = optionalBool(obj, "strict", false) catch return error.BadArgs;
            command.timeout_ms = optionalU64(obj, "timeout_ms") catch return error.BadArgs;
        },
        .dom_click => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            applyActionOptions(&command, obj, true) catch return error.BadArgs;
        },
        .dom_fill => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.value = try requiredString(arena_allocator, obj, "value");
            applyActionOptions(&command, obj, true) catch return error.BadArgs;
        },
        .dom_type => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.text = try requiredString(arena_allocator, obj, "text");
            command.delay_ms = optionalU64(obj, "delay_ms") catch return error.BadArgs;
            applyActionOptions(&command, obj, true) catch return error.BadArgs;
            // Native text crosses the C ABI: an embedded NUL would truncate it.
            if (command.input == .native and std.mem.indexOfScalar(u8, command.text.?, 0) != null) return error.BadArgs;
        },
        .dom_get_text => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
            command.timeout_ms = optionU64(obj, "timeout_ms") catch return error.BadArgs;
        },
        .dom_get_attribute => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.name = try requiredString(arena_allocator, obj, "name");
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
            command.timeout_ms = optionU64(obj, "timeout_ms") catch return error.BadArgs;
        },
        .dom_wait_for => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
            command.timeout_ms = optionalU64(obj, "timeout_ms") catch return error.BadArgs;
            command.wait_state = parseWaitState(optionalStringRaw(obj, "state") orelse "visible") orelse return error.BadArgs;
        },
        .dom_press => {
            command.selector = try optionalString(arena_allocator, obj, "selector");
            command.key = try requiredString(arena_allocator, obj, "key");
            if (command.key.?.len == 0) return error.BadArgs;
            command.modifiers = try parseModifiers(arena_allocator, obj);
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
            command.timeout_ms = optionU64(obj, "timeout_ms") catch return error.BadArgs;
            command.input = parseInputMode(obj) catch return error.BadArgs;
            if (command.input == .native and !isNativeKey(command.key.?)) return error.BadArgs;
        },
        .dom_select_option => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.value = try optionalString(arena_allocator, obj, "value");
            command.label = try optionalString(arena_allocator, obj, "label");
            command.option_index = optionalU64(obj, "index") catch return error.BadArgs;
            const choices = @as(u8, @intFromBool(command.value != null)) + @intFromBool(command.label != null) + @intFromBool(command.option_index != null);
            if (choices != 1) return error.BadArgs;
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
            command.timeout_ms = optionU64(obj, "timeout_ms") catch return error.BadArgs;
        },
        .dom_set_input_files => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.paths = try parsePaths(arena_allocator, obj);
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
            command.timeout_ms = optionU64(obj, "timeout_ms") catch return error.BadArgs;
        },
        .dom_hover => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
            command.timeout_ms = optionU64(obj, "timeout_ms") catch return error.BadArgs;
        },
        .dom_scroll => {
            command.selector = try optionalString(arena_allocator, obj, "selector");
            const x = optionalFiniteNumber(obj, "x") catch return error.BadArgs;
            const y = optionalFiniteNumber(obj, "y") catch return error.BadArgs;
            // Exactly one of: a target to bring into view, or an offset.
            const by_offset = x != null or y != null;
            if (by_offset == (command.selector != null)) return error.BadArgs;
            if (by_offset) {
                command.scroll_x = x orelse 0;
                command.scroll_y = y orelse 0;
            }
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
            command.timeout_ms = optionU64(obj, "timeout_ms") catch return error.BadArgs;
        },
        .page_navigate => {
            command.url = try requiredCString(arena_allocator, obj, "url");
            command.timeout_ms = optionalU64(obj, "timeout_ms") catch return error.BadArgs;
            command.wait_until = try optionalString(arena_allocator, obj, "waitUntil");
            if (obj.get("onBeforeUnload")) |value| {
                const text = switch (value) {
                    .string => |t| t,
                    else => return error.BadArgs,
                };
                command.before_unload = std.meta.stringToEnum(BeforeUnload, text) orelse return error.BadArgs;
            }
        },
        .page_reload => {
            command.timeout_ms = optionalU64(obj, "timeout_ms") catch return error.BadArgs;
            command.wait_until = try optionalString(arena_allocator, obj, "waitUntil");
        },
        .page_url,
        .page_title,
        => {
            // Only an optional deadline (site flows clamp it to their budget).
            var keys = obj.iterator();
            while (keys.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.*, "timeout_ms")) return error.BadArgs;
            }
            command.timeout_ms = optionalU64(obj, "timeout_ms") catch return error.BadArgs;
        },
        .page_evaluate => {
            command.expression = try requiredCString(arena_allocator, obj, "expression");
            command.timeout_ms = optionU64(obj, "timeout_ms") catch return error.BadArgs;
        },
        .page_screenshot => {
            command.full_page = optionalBool(obj, "fullPage", false) catch return error.BadArgs;
            command.timeout_ms = optionalU64(obj, "timeout_ms") catch return error.BadArgs;
        },
    }

    // `options.input` exists only on click/type/press/hover/scroll:
    // anywhere else even its presence is BadArgs. Native input never takes
    // force (a trusted event at a covered element's centre would land on
    // the cover); press, hover and scroll have no force/trial at all, and
    // scroll no humanize.
    const input = parseInputMode(obj) catch return error.BadArgs;
    switch (verb) {
        .dom_click, .dom_type => if (input == .native and command.force) return error.BadArgs,
        .dom_press, .dom_hover => if (hasOption(obj, "force") or hasOption(obj, "trial")) return error.BadArgs,
        .dom_scroll => if (hasOption(obj, "force") or hasOption(obj, "trial") or hasOption(obj, "humanize")) return error.BadArgs,
        else => if (hasOption(obj, "input") or hasOption(obj, "humanize")) return error.BadArgs,
    }
    if (verb == .dom_hover or verb == .dom_scroll) command.input = input;
    // humanize: native input only (synthetic events have no pointer path)
    // and never with delay_ms (humanize owns the timing).
    command.humanize = humanizeOption(obj) catch return error.BadArgs;
    // delay_ms is only parsed for dom.type, so check its presence directly.
    if (command.humanize and (input != .native or obj.get("delay_ms") != null)) return error.BadArgs;

    command.expect = try parseExpect(arena_allocator, obj);
    if (command.expect != null) {
        switch (verb) {
            .dom_click, .dom_fill, .dom_type, .dom_press, .dom_select_option, .page_navigate, .page_reload => {},
            else => return error.BadArgs,
        }
        // Only synthetic input is checked in the same task as its event (decision 4).
        if (input == .native or command.humanize) return error.BadArgs;
    }

    command.guard = try parseGuard(arena_allocator, obj);
    if (command.guard != null) {
        switch (verb) {
            .dom_click, .dom_fill, .dom_type, .dom_press, .dom_select_option => {},
            else => return error.BadArgs,
        }
        if (input == .native or command.humanize) return error.BadArgs;
        // A selectorless press has no target of its own to re-resolve (RoseCat on 9295b0b).
        if (verb == .dom_press and command.selector == null and command.guard.?.target) return error.BadArgs;
        // A guarded type runs in chunks (decision 15); per-character delays are another schedule,
        // so any delay_ms is refused, 0 included (as humanize does; RoseCat on 76cb14a).
        if (command.delay_ms != null) return error.BadArgs;
    }

    command.arena = arena;

    return command;
}

fn normalizedParams(params_json: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, params_json, &std.ascii.whitespace);
    if (trimmed.len == 0) return "{}";
    return trimmed;
}

fn verbFromMethod(method: []const u8) ?Verb {
    const table = [_]struct { method: []const u8, verb: Verb }{
        .{ .method = "dom.query", .verb = .dom_query },
        .{ .method = "dom.click", .verb = .dom_click },
        .{ .method = "dom.fill", .verb = .dom_fill },
        .{ .method = "dom.type", .verb = .dom_type },
        .{ .method = "dom.getText", .verb = .dom_get_text },
        .{ .method = "dom.getAttribute", .verb = .dom_get_attribute },
        .{ .method = "dom.waitFor", .verb = .dom_wait_for },
        .{ .method = "dom.press", .verb = .dom_press },
        .{ .method = "dom.selectOption", .verb = .dom_select_option },
        .{ .method = "dom.setInputFiles", .verb = .dom_set_input_files },
        .{ .method = "dom.hover", .verb = .dom_hover },
        .{ .method = "dom.scroll", .verb = .dom_scroll },
        .{ .method = "page.navigate", .verb = .page_navigate },
        .{ .method = "page.reload", .verb = .page_reload },
        .{ .method = "page.url", .verb = .page_url },
        .{ .method = "page.title", .verb = .page_title },
        .{ .method = "page.evaluate", .verb = .page_evaluate },
        .{ .method = "page.screenshot", .verb = .page_screenshot },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry.method, method)) return entry.verb;
    }
    return null;
}

fn namespaceFromVerb(verb: Verb) Namespace {
    return switch (verb) {
        .dom_query,
        .dom_click,
        .dom_fill,
        .dom_type,
        .dom_get_text,
        .dom_get_attribute,
        .dom_wait_for,
        .dom_press,
        .dom_select_option,
        .dom_set_input_files,
        .dom_hover,
        .dom_scroll,
        => .dom,
        .page_navigate,
        .page_reload,
        .page_url,
        .page_title,
        .page_evaluate,
        .page_screenshot,
        => .page,
    };
}

fn requiredString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) error{BadArgs}![]const u8 {
    const value = obj.get(key) orelse return error.BadArgs;
    return switch (value) {
        .string => |text| allocator.dupe(u8, text) catch return error.BadArgs,
        else => error.BadArgs,
    };
}

const allowed_modifiers = [_][]const u8{ "Shift", "Control", "Alt", "Meta" };

fn parseModifiers(allocator: std.mem.Allocator, obj: std.json.ObjectMap) error{BadArgs}![]const []const u8 {
    const value = obj.get("modifiers") orelse return &.{};
    const items = switch (value) {
        .array => |array| array.items,
        else => return error.BadArgs,
    };
    if (items.len > allowed_modifiers.len) return error.BadArgs;
    const out = allocator.alloc([]const u8, items.len) catch return error.BadArgs;
    for (items, 0..) |item, i| {
        const name = switch (item) {
            .string => |text| text,
            else => return error.BadArgs,
        };
        const canonical = for (allowed_modifiers) |allowed| {
            if (std.mem.eql(u8, allowed, name)) break allowed;
        } else return error.BadArgs;
        for (out[0..i]) |seen| if (std.mem.eql(u8, seen, canonical)) return error.BadArgs;
        out[i] = canonical;
    }
    return out;
}

/// Like requiredString, but rejects embedded NUL: these values are passed to
/// the native layer as C strings.
fn requiredCString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) error{BadArgs}![]const u8 {
    const text = try requiredString(allocator, obj, key);
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.BadArgs;
    return text;
}

fn optionalString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) error{BadArgs}!?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| allocator.dupe(u8, text) catch return error.BadArgs,
        else => error.BadArgs,
    };
}

fn optionalStringRaw(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => "",
    };
}

fn optionalU64(obj: std.json.ObjectMap, key: []const u8) !?u64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |int| if (int >= 0) @as(u64, @intCast(int)) else error.BadArgs,
        .number_string => |text| std.fmt.parseInt(u64, text, 10) catch error.BadArgs,
        else => error.BadArgs,
    };
}

/// A finite JSON number, or null when absent (strings, bools, and numbers
/// that overflow to infinity are BadArgs).
fn optionalFiniteNumber(obj: std.json.ObjectMap, key: []const u8) !?f64 {
    const value = obj.get(key) orelse return null;
    const number: f64 = switch (value) {
        .integer => |int| @floatFromInt(int),
        .float => |f| f,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch return error.BadArgs,
        else => return error.BadArgs,
    };
    if (!std.math.isFinite(number)) return error.BadArgs;
    return number;
}

/// dom.setInputFiles `paths`: a non-empty array of non-empty strings
/// without NUL (they reach the C ABI). Whether each is an absolute,
/// readable regular file is the backend's check (PortError.BadFile).
fn parsePaths(allocator: std.mem.Allocator, obj: std.json.ObjectMap) error{BadArgs}![]const []const u8 {
    const items = switch (obj.get("paths") orelse return error.BadArgs) {
        .array => |array| array.items,
        else => return error.BadArgs,
    };
    if (items.len == 0) return error.BadArgs;
    const paths = allocator.alloc([]const u8, items.len) catch return error.BadArgs;
    for (items, paths) |item, *path| {
        const text = switch (item) {
            .string => |t| t,
            else => return error.BadArgs,
        };
        if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return error.BadArgs;
        path.* = allocator.dupe(u8, text) catch return error.BadArgs;
    }
    return paths;
}

fn optionalBool(obj: std.json.ObjectMap, key: []const u8, default: bool) !bool {
    const value = obj.get(key) orelse return default;
    return switch (value) {
        .bool => |b| b,
        else => error.BadArgs,
    };
}

fn optionBool(obj: std.json.ObjectMap, key: []const u8, default: bool) !bool {
    const options = obj.get("options") orelse return optionalBool(obj, key, default);
    const options_obj = switch (options) {
        .object => |object| object,
        else => return error.BadArgs,
    };
    return optionalBool(options_obj, key, default);
}

/// `key` from `options` when present, else from the top level.
fn optionU64(obj: std.json.ObjectMap, key: []const u8) !?u64 {
    const options = obj.get("options") orelse return optionalU64(obj, key);
    const options_obj = switch (options) {
        .object => |object| object,
        else => return error.BadArgs,
    };
    return (try optionalU64(options_obj, key)) orelse optionalU64(obj, key);
}

fn applyActionOptions(command: *ParsedCommand, obj: std.json.ObjectMap, strict_default: bool) !void {
    command.strict = optionBool(obj, "strict", strict_default) catch return error.BadArgs;
    const options = obj.get("options") orelse {
        command.force = false;
        command.trial = false;
        return;
    };
    const options_obj = switch (options) {
        .object => |object| object,
        else => return error.BadArgs,
    };
    command.force = optionalBool(options_obj, "force", false) catch return error.BadArgs;
    command.trial = optionalBool(options_obj, "trial", false) catch return error.BadArgs;
    command.timeout_ms = optionalU64(options_obj, "timeout_ms") catch return error.BadArgs;
    command.input = try parseInputMode(obj);
}

/// `options.expect`: absent -> null; else exactly `{origin: non-empty string, load_serial:
/// integer >= 0}`. Anything else is BadArgs. A non-object `options` is left to the verb's own
/// parse.
fn parseExpect(arena: std.mem.Allocator, obj: std.json.ObjectMap) error{BadArgs}!?Expect {
    const options = obj.get("options") orelse return null;
    const options_obj = switch (options) {
        .object => |object| object,
        else => return null,
    };
    const value = options_obj.get("expect") orelse return null;
    const expect_obj = switch (value) {
        .object => |object| object,
        else => return error.BadArgs,
    };
    var keys = expect_obj.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "origin") and !std.mem.eql(u8, key, "load_serial")) return error.BadArgs;
    }
    const origin = switch (expect_obj.get("origin") orelse return error.BadArgs) {
        .string => |text| if (text.len > 0) text else return error.BadArgs,
        else => return error.BadArgs,
    };
    const load_serial: u64 = switch (expect_obj.get("load_serial") orelse return error.BadArgs) {
        .integer => |n| std.math.cast(u64, n) orelse return error.BadArgs,
        else => return error.BadArgs,
    };
    return .{ .origin = arena.dupe(u8, origin) catch return error.BadArgs, .load_serial = load_serial };
}

/// `options.guard`: absent -> null; else `{marks?: [{selector, attribute?, value}] (1..8),
/// target?: bool}` with at least one check, no other key; anything else is BadArgs.
fn parseGuard(arena: std.mem.Allocator, obj: std.json.ObjectMap) error{BadArgs}!?Guard {
    const options = obj.get("options") orelse return null;
    const options_obj = switch (options) {
        .object => |object| object,
        else => return null,
    };
    const value = options_obj.get("guard") orelse return null;
    const guard_obj = switch (value) {
        .object => |object| object,
        else => return error.BadArgs,
    };
    var guard = Guard{};
    var keys = guard_obj.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "target")) {
            guard.target = switch (entry.value_ptr.*) {
                .bool => |b| b,
                else => return error.BadArgs,
            };
        } else if (std.mem.eql(u8, key, "marks")) {
            const items = switch (entry.value_ptr.*) {
                .array => |a| a.items,
                else => return error.BadArgs,
            };
            if (items.len == 0 or items.len > max_guard_marks) return error.BadArgs;
            const marks = arena.alloc(Guard.Mark, items.len) catch return error.BadArgs;
            for (items, marks) |item, *mark| mark.* = try parseMark(arena, item);
            guard.marks = marks;
        } else if (std.mem.eql(u8, key, "document")) {
            guard.document = switch (entry.value_ptr.*) {
                .string => |d| if (d.len > 0) arena.dupe(u8, d) catch return error.BadArgs else return error.BadArgs,
                else => return error.BadArgs,
            };
        } else if (std.mem.eql(u8, key, "path")) {
            guard.path = switch (entry.value_ptr.*) {
                .string => |p| if (isPath(p)) arena.dupe(u8, p) catch return error.BadArgs else return error.BadArgs,
                else => return error.BadArgs,
            };
        } else return error.BadArgs;
    }
    if (guard.marks.len == 0 and !guard.target and guard.path == null and guard.document == null) return error.BadArgs;
    return guard;
}

fn parseMark(arena: std.mem.Allocator, value: std.json.Value) error{BadArgs}!Guard.Mark {
    const object = switch (value) {
        .object => |o| o,
        else => return error.BadArgs,
    };
    var keys = object.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "selector") and !std.mem.eql(u8, key, "attribute") and !std.mem.eql(u8, key, "value") and !std.mem.eql(u8, key, "path")) return error.BadArgs;
    }
    const path: ?bool = if (object.get("path")) |p| switch (p) {
        .bool => |b| if (b) true else null,
        else => return error.BadArgs,
    } else null;
    const selector = switch (object.get("selector") orelse return error.BadArgs) {
        .string => |s| if (s.len > 0) s else return error.BadArgs,
        else => return error.BadArgs,
    };
    const attribute: ?[]const u8 = if (object.get("attribute")) |a| switch (a) {
        .string => |s| if (s.len > 0) s else return error.BadArgs,
        else => return error.BadArgs,
    } else null;
    const text = switch (object.get("value") orelse return error.BadArgs) {
        .string => |s| s,
        else => return error.BadArgs,
    };
    if (path != null and (attribute == null or !isPath(text))) return error.BadArgs;
    return .{
        .selector = arena.dupe(u8, selector) catch return error.BadArgs,
        .attribute = if (attribute) |a| arena.dupe(u8, a) catch return error.BadArgs else null,
        .value = arena.dupe(u8, text) catch return error.BadArgs,
        .path = path,
    };
}

/// A guard path: absolute, non-empty (`/` and more).
fn isPath(text: []const u8) bool {
    return text.len > 0 and text[0] == '/';
}

/// `options.input`: absent or "synthetic" -> synthetic, "native" -> native,
/// anything else is BadArgs.
fn parseInputMode(obj: std.json.ObjectMap) error{BadArgs}!InputMode {
    const options = obj.get("options") orelse return .synthetic;
    const options_obj = switch (options) {
        .object => |object| object,
        else => return error.BadArgs,
    };
    const value = options_obj.get("input") orelse return .synthetic;
    const text = switch (value) {
        .string => |t| t,
        else => return error.BadArgs,
    };
    if (std.mem.eql(u8, text, "synthetic")) return .synthetic;
    if (std.mem.eql(u8, text, "native")) return .native;
    return error.BadArgs;
}

fn humanizeOption(obj: std.json.ObjectMap) error{BadArgs}!bool {
    const options = obj.get("options") orelse return false;
    return switch (options) {
        .object => |object| optionalBool(object, "humanize", false) catch error.BadArgs,
        else => error.BadArgs,
    };
}

fn hasOption(obj: std.json.ObjectMap, key: []const u8) bool {
    const options = obj.get("options") orelse return false;
    return switch (options) {
        .object => |object| object.get(key) != null,
        else => false,
    };
}

/// Key names the native backend can press (mirrors the shim's table).
pub const native_key_names = [_][]const u8{
    "Enter",     "Tab",        "Escape",  "Backspace", "Delete",   "Insert",
    "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home",     "End",
    "PageUp",    "PageDown",   "Space",   "Shift",     "Control",  "Alt",
    "Meta",      "F1",         "F2",      "F3",        "F4",       "F5",
    "F6",        "F7",         "F8",      "F9",        "F10",      "F11",
    "F12",
};

/// Native dom.press key: one of `native_key_names`, or exactly one Unicode
/// code point other than NUL (NUL would truncate the C string).
pub fn isNativeKey(key: []const u8) bool {
    for (native_key_names) |name| {
        if (std.mem.eql(u8, name, key)) return true;
    }
    const len = std.unicode.utf8ByteSequenceLength(key[0]) catch return false;
    if (len != key.len) return false;
    const code_point = std.unicode.utf8Decode(key) catch return false;
    return code_point != 0;
}

fn parseWaitState(text: []const u8) ?WaitState {
    if (std.mem.eql(u8, text, "attached")) return .attached;
    if (std.mem.eql(u8, text, "visible")) return .visible;
    if (std.mem.eql(u8, text, "hidden")) return .hidden;
    if (std.mem.eql(u8, text, "detached")) return .detached;
    return null;
}
