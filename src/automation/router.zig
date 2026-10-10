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
    page_navigate,
    page_reload,
    page_url,
    page_title,
    page_evaluate,
    page_screenshot,
};

pub const WaitState = enum { attached, visible, hidden, detached };

/// `options.input`: synthetic DOM events from automation.js (default), or
/// real platform input (PagePort.native*, `event.isTrusted === true`).
/// Native is accepted for dom.click, dom.type and dom.press only (without
/// `force`); any other method with `input: "native"` is BadArgs.
pub const InputMode = enum { synthetic, native };

/// Internal (never parsed from JSON): turns a dom.* command into the
/// automation.js `locate` op that native input uses to find, scroll, check
/// and optionally focus its target.
pub const Locate = struct {
    action: []const u8,
    focus: bool,
};

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
    full_page: bool = false,
    /// dom.press: KeyboardEvent.key value.
    key: ?[]const u8 = null,
    /// dom.press: subset of Shift/Control/Alt/Meta, no duplicates.
    modifiers: []const []const u8 = &.{},
    /// dom.selectOption: option label (`value` holds the option value).
    label: ?[]const u8 = null,
    /// dom.selectOption: 0-based option index.
    option_index: ?u64 = null,
    input: InputMode = .synthetic,
    locate: ?Locate = null,

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
        .page_navigate => {
            command.url = try requiredCString(arena_allocator, obj, "url");
            command.timeout_ms = optionalU64(obj, "timeout_ms") catch return error.BadArgs;
            command.wait_until = try optionalString(arena_allocator, obj, "waitUntil");
        },
        .page_reload => {
            command.timeout_ms = optionalU64(obj, "timeout_ms") catch return error.BadArgs;
            command.wait_until = try optionalString(arena_allocator, obj, "waitUntil");
        },
        .page_url,
        .page_title,
        => {
            if (obj.count() != 0) return error.BadArgs;
        },
        .page_evaluate => {
            command.expression = try requiredCString(arena_allocator, obj, "expression");
        },
        .page_screenshot => {
            command.full_page = optionalBool(obj, "fullPage", false) catch return error.BadArgs;
        },
    }

    // `options.input` exists only on click/type/press: anywhere else even
    // its presence is BadArgs. Native input never takes force (a trusted
    // event at a covered element's centre would land on the cover), and
    // dom.press has no force/trial at all.
    const input = parseInputMode(obj) catch return error.BadArgs;
    switch (verb) {
        .dom_click, .dom_type => if (input == .native and command.force) return error.BadArgs,
        .dom_press => if (hasOption(obj, "force") or hasOption(obj, "trial")) return error.BadArgs,
        else => if (hasOption(obj, "input")) return error.BadArgs,
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
