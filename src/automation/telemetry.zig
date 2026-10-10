const std = @import("std");
const builtin = @import("builtin");

const url_scheme_separator = "://";
const url_default_path = "/";

pub const AttrMap = struct {
    entries: std.ArrayListUnmanaged(Entry),

    pub const Entry = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn init() AttrMap {
        return .{ .entries = .empty };
    }

    pub fn deinit(self: *AttrMap, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn put(self: *AttrMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try self.entries.append(allocator, .{ .key = key, .value = value });
    }

    pub fn attr(self: *const AttrMap, key: []const u8) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }

    pub fn containsRaw(self: *const AttrMap, needle: []const u8) bool {
        for (self.entries.items) |entry| {
            if (std.mem.indexOf(u8, entry.key, needle) != null) return true;
            if (std.mem.indexOf(u8, entry.value, needle) != null) return true;
        }
        return false;
    }
};

pub const Span = struct {
    name: []const u8,
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: ?[]const u8,
    command_id: []const u8,
    attributes: AttrMap,

    pub fn attr(self: *const Span, key: []const u8) ?[]const u8 {
        return self.attributes.attr(key);
    }
};

pub const RootCommandAttrs = struct {
    method: []const u8,
    namespace: []const u8,
    page_id: []const u8,
    window_id: []const u8,
    selector: ?[]const u8 = null,
    selector_strict: ?bool = null,
    typed_value: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

/// Root `automation.command` span recorded by the engine after a command
/// finishes. Raw selector/typed values/URLs are hashed or classified by the
/// sink and never stored.
pub const CommandSpanAttrs = struct {
    trace_id: []const u8,
    span_id: []const u8,
    command_id: []const u8,
    method: []const u8,
    namespace: []const u8,
    page_id: []const u8,
    window_id: []const u8,
    selector: ?[]const u8 = null,
    selector_strict: ?bool = null,
    typed_value: ?[]const u8 = null,
    url: ?[]const u8 = null,
    action_name: ?[]const u8 = null,
    action_force: bool = false,
    action_trial: bool = false,
    timeout_ms: u64,
    queue_wait_ms: u64,
    duration_ms: u64,
    retry_count: u32,
    result_status: []const u8,
    automation_error: ?[]const u8 = null,
};

/// Child span attribute keys accepted from automation.js. Anything else the
/// page-side script reports is dropped before it reaches the sink.
pub const script_child_attribute_allowlist = [_][]const u8{
    "selector.kind",              "selector.hash",           "selector.strict",
    "selector.match_count",       "dom.frame_depth",         "attempt.index",
    "script.world",               "result.status",           "duration_ms",
    "action.name",                "action.force",            "action.trial",
    "actionability.check",        "actionability.required_checks", "actionability.passed",
    "actionability.failed_check", "bbox.width",              "bbox.height",
    "automation.error",
};

pub const script_child_span_names = [_][]const u8{ "automation.selector.resolve", "automation.actionability.check" };

pub const InMemoryTelemetrySink = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayListUnmanaged(Span),
    owned_strings: std.ArrayListUnmanaged([]const u8),
    next_id: u64,
    /// Engine threads record concurrently; held only while appending.
    lock: std.atomic.Mutex = .unlocked,

    pub fn init(allocator: std.mem.Allocator) InMemoryTelemetrySink {
        return .{
            .allocator = allocator,
            .spans = .empty,
            .owned_strings = .empty,
            .next_id = 1,
        };
    }

    pub fn deinit(self: *InMemoryTelemetrySink) void {
        for (self.spans.items) |*span| {
            span.attributes.deinit(self.allocator);
        }
        for (self.owned_strings.items) |owned| {
            self.allocator.free(owned);
        }
        self.owned_strings.deinit(self.allocator);
        self.spans.deinit(self.allocator);
    }

    pub fn spanCount(self: *const InMemoryTelemetrySink) usize {
        return self.spans.items.len;
    }

    pub fn spanAt(self: *const InMemoryTelemetrySink, index: usize) *const Span {
        return &self.spans.items[index];
    }

    pub fn containsRaw(self: *const InMemoryTelemetrySink, needle: []const u8) bool {
        for (self.spans.items) |span| {
            if (std.mem.indexOf(u8, span.name, needle) != null) return true;
            if (std.mem.indexOf(u8, span.trace_id, needle) != null) return true;
            if (std.mem.indexOf(u8, span.span_id, needle) != null) return true;
            if (std.mem.indexOf(u8, span.command_id, needle) != null) return true;
            if (span.parent_span_id) |parent| {
                if (std.mem.indexOf(u8, parent, needle) != null) return true;
            }
            if (span.attributes.containsRaw(needle)) return true;
        }
        return false;
    }

    fn acquire(self: *InMemoryTelemetrySink) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn recordCommandSpan(self: *InMemoryTelemetrySink, attrs: CommandSpanAttrs) !void {
        self.acquire();
        defer self.lock.unlock();

        var attributes = AttrMap.init();
        errdefer attributes.deinit(self.allocator);
        try self.putAttr(&attributes, "rpc.method", attrs.method);
        try self.putAttr(&attributes, "rpc.namespace", attrs.namespace);
        try self.putAttr(&attributes, "page.id", attrs.page_id);
        try self.putAttr(&attributes, "window.id", attrs.window_id);
        try self.putAttr(&attributes, "os.name", @tagName(builtin.os.tag));
        try self.putAttr(&attributes, "arch", @tagName(builtin.cpu.arch));
        try self.putOwnedAttr(&attributes, "timeout_ms", try self.formatInt(attrs.timeout_ms));
        try self.putOwnedAttr(&attributes, "queue.wait_ms", try self.formatInt(attrs.queue_wait_ms));
        try self.putOwnedAttr(&attributes, "duration_ms", try self.formatInt(attrs.duration_ms));
        try self.putOwnedAttr(&attributes, "retry.count", try self.formatInt(attrs.retry_count));
        try self.putAttr(&attributes, "result.status", attrs.result_status);
        try self.putAttr(&attributes, "automation.error", attrs.automation_error orelse "");

        if (attrs.selector) |selector| {
            try self.putAttr(&attributes, "selector.kind", selectorKind(selector));
            try self.putOwnedAttr(&attributes, "selector.hash", try self.hashText(selector));
            if (attrs.selector_strict) |strict| {
                try self.putAttr(&attributes, "selector.strict", if (strict) "true" else "false");
            }
        }
        if (attrs.action_name) |action| {
            try self.putAttr(&attributes, "action.name", action);
            try self.putAttr(&attributes, "action.force", if (attrs.action_force) "true" else "false");
            try self.putAttr(&attributes, "action.trial", if (attrs.action_trial) "true" else "false");
        }
        if (attrs.typed_value) |value| {
            try self.putOwnedAttr(&attributes, "typed.length", try self.formatInt(value.len));
            try self.putAttr(&attributes, "typed.class", classifyTypedValue(value));
        }
        if (attrs.url) |url| {
            const parsed = parseUrl(url);
            if (parsed.host.len > 0) try self.putAttr(&attributes, "target.host", parsed.host);
            try self.putOwnedAttr(&attributes, "target.origin_hash", try self.hashText(parsed.origin));
            try self.putOwnedAttr(&attributes, "target.path_hash", try self.hashText(parsed.path));
        }

        try self.spans.append(self.allocator, .{
            .name = "automation.command",
            .trace_id = try self.dupe(attrs.trace_id),
            .span_id = try self.dupe(attrs.span_id),
            .parent_span_id = null,
            .command_id = try self.dupe(attrs.command_id),
            .attributes = attributes,
        });
    }

    /// Child span under a root command span. `span_id == null` assigns one.
    /// Attribute keys/values are copied.
    pub fn recordChildSpan(
        self: *InMemoryTelemetrySink,
        name: []const u8,
        trace_id: []const u8,
        span_id: ?[]const u8,
        parent_span_id: []const u8,
        command_id: []const u8,
        attributes_in: []const AttrMap.Entry,
    ) !void {
        self.acquire();
        defer self.lock.unlock();

        var attributes = AttrMap.init();
        errdefer attributes.deinit(self.allocator);
        for (attributes_in) |entry| try attributes.put(self.allocator, try self.dupe(entry.key), try self.dupe(entry.value));
        try self.spans.append(self.allocator, .{
            .name = try self.dupe(name),
            .trace_id = try self.dupe(trace_id),
            .span_id = if (span_id) |id| try self.dupe(id) else try self.nextId("span"),
            .parent_span_id = try self.dupe(parent_span_id),
            .command_id = try self.dupe(command_id),
            .attributes = attributes,
        });
    }

    /// Spans (root and children) recorded for `command_id`.
    pub fn countSpans(self: *const InMemoryTelemetrySink, name: []const u8, command_id: []const u8) usize {
        var count: usize = 0;
        for (self.spans.items) |span| {
            if (std.mem.eql(u8, span.name, name) and std.mem.eql(u8, span.command_id, command_id)) count += 1;
        }
        return count;
    }

    pub fn recordRootCommand(self: *InMemoryTelemetrySink, attrs: RootCommandAttrs) !void {
        self.acquire();
        defer self.lock.unlock();
        const trace_id = try self.nextId("trace");
        const span_id = try self.nextId("span");
        const command_id = try self.nextId("cmd");
        var attributes = AttrMap.init();
        errdefer attributes.deinit(self.allocator);

        try self.putAttr(&attributes, "rpc.method", attrs.method);
        try self.putAttr(&attributes, "rpc.namespace", attrs.namespace);
        try self.putAttr(&attributes, "page.id", attrs.page_id);
        try self.putAttr(&attributes, "window.id", attrs.window_id);

        if (attrs.selector) |selector| {
            try self.putAttr(&attributes, "selector.kind", selectorKind(selector));
            try self.putOwnedAttr(&attributes, "selector.hash", try self.hashText(selector));
            if (attrs.selector_strict) |strict| {
                try self.putAttr(&attributes, "selector.strict", if (strict) "true" else "false");
            }
        }

        if (attrs.typed_value) |value| {
            try self.putOwnedAttr(&attributes, "typed.length", try self.formatInt(value.len));
            try self.putAttr(&attributes, "typed.class", classifyTypedValue(value));
        }

        if (attrs.url) |url| {
            const parsed = parseUrl(url);
            if (parsed.host.len > 0) try self.putAttr(&attributes, "target.host", parsed.host);
            try self.putOwnedAttr(&attributes, "target.origin_hash", try self.hashText(parsed.origin));
            try self.putOwnedAttr(&attributes, "target.path_hash", try self.hashText(parsed.path));
        }

        try self.spans.append(self.allocator, .{
            .name = "automation.command",
            .trace_id = trace_id,
            .span_id = span_id,
            .parent_span_id = null,
            .command_id = command_id,
            .attributes = attributes,
        });
    }

    fn putAttr(self: *InMemoryTelemetrySink, attrs: *AttrMap, key: []const u8, value: []const u8) !void {
        try attrs.put(self.allocator, key, try self.dupe(value));
    }

    fn putOwnedAttr(self: *InMemoryTelemetrySink, attrs: *AttrMap, key: []const u8, value: []const u8) !void {
        try attrs.put(self.allocator, key, value);
    }

    fn nextId(self: *InMemoryTelemetrySink, prefix: []const u8) ![]const u8 {
        const id = try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ prefix, self.next_id });
        self.next_id += 1;
        try self.owned_strings.append(self.allocator, id);
        return id;
    }

    fn dupe(self: *InMemoryTelemetrySink, value: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, value);
        try self.owned_strings.append(self.allocator, owned);
        return owned;
    }

    fn formatInt(self: *InMemoryTelemetrySink, value: u64) ![]const u8 {
        const owned = try std.fmt.allocPrint(self.allocator, "{d}", .{value});
        try self.owned_strings.append(self.allocator, owned);
        return owned;
    }

    fn hashText(self: *InMemoryTelemetrySink, value: []const u8) ![]const u8 {
        const hash = std.hash.Wyhash.hash(0, value);
        const owned = try std.fmt.allocPrint(self.allocator, "{x}", .{hash});
        try self.owned_strings.append(self.allocator, owned);
        return owned;
    }
};

fn selectorKind(selector: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, selector, '=')) |idx| {
        return selector[0..idx];
    }
    return "unknown";
}

fn classifyTypedValue(value: []const u8) []const u8 {
    if (containsIgnoreCase(value, "password") or
        containsIgnoreCase(value, "token") or
        containsIgnoreCase(value, "secret"))
    {
        return "secret-like";
    }
    return "text";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const ParsedUrl = struct {
    host: []const u8,
    origin: []const u8,
    path: []const u8,
};

fn parseUrl(url: []const u8) ParsedUrl {
    const scheme_end = std.mem.indexOf(u8, url, url_scheme_separator) orelse return .{ .host = "", .origin = "", .path = "" };
    const authority_start = scheme_end + url_scheme_separator.len;
    const after_authority_rel = std.mem.indexOfAny(u8, url[authority_start..], "/?#") orelse url[authority_start..].len;
    const authority_end = authority_start + after_authority_rel;
    const host = url[authority_start..authority_end];
    const origin = url[0..authority_end];

    const path_start = authority_end;
    if (path_start >= url.len or url[path_start] != '/') {
        return .{ .host = host, .origin = origin, .path = url_default_path };
    }
    const query_start_rel = std.mem.indexOfAny(u8, url[path_start..], "?#") orelse url[path_start..].len;
    return .{
        .host = host,
        .origin = origin,
        .path = url[path_start .. path_start + query_start_rel],
    };
}
