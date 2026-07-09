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
    page_navigate,
    page_reload,
    page_url,
    page_title,
    page_evaluate,
    page_screenshot,
};

pub const WaitState = enum { attached, visible, hidden, detached };

pub const RouteContext = struct {
    page_id: []const u8 = "page-unknown",
    window_id: []const u8 = "window-unknown",
    telemetry_sink: ?*telemetry.InMemoryTelemetrySink = null,
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
        },
        .dom_get_text => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
        },
        .dom_get_attribute => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.name = try requiredString(arena_allocator, obj, "name");
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
        },
        .dom_wait_for => {
            command.selector = try requiredString(arena_allocator, obj, "selector");
            command.strict = optionBool(obj, "strict", true) catch return error.BadArgs;
            command.timeout_ms = optionalU64(obj, "timeout_ms") catch return error.BadArgs;
            command.wait_state = parseWaitState(optionalStringRaw(obj, "state") orelse "visible") orelse return error.BadArgs;
        },
        .page_navigate => {
            command.url = try requiredString(arena_allocator, obj, "url");
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
            command.expression = try requiredString(arena_allocator, obj, "expression");
        },
        .page_screenshot => {
            command.full_page = optionalBool(obj, "fullPage", false) catch return error.BadArgs;
        },
    }

    command.arena = arena;

    if (context.telemetry_sink) |sink| {
        sink.recordRootCommand(.{
            .method = method,
            .namespace = @tagName(command.namespace),
            .page_id = context.page_id,
            .window_id = context.window_id,
            .selector = command.selector,
            .selector_strict = command.strict,
            .typed_value = command.value orelse command.text,
            .url = command.url,
        }) catch {};
    }

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
}

fn parseWaitState(text: []const u8) ?WaitState {
    if (std.mem.eql(u8, text, "attached")) return .attached;
    if (std.mem.eql(u8, text, "visible")) return .visible;
    if (std.mem.eql(u8, text, "hidden")) return .hidden;
    if (std.mem.eql(u8, text, "detached")) return .detached;
    return null;
}
