const std = @import("std");

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

pub const InMemoryTelemetrySink = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayListUnmanaged(Span),
    owned_strings: std.ArrayListUnmanaged([]const u8),
    next_id: u64,

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

    pub fn recordRootCommand(self: *InMemoryTelemetrySink, attrs: RootCommandAttrs) !void {
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

    fn formatInt(self: *InMemoryTelemetrySink, value: usize) ![]const u8 {
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
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return .{ .host = "", .origin = "", .path = "" };
    const authority_start = scheme_end + 3;
    const after_authority_rel = std.mem.indexOfAny(u8, url[authority_start..], "/?#") orelse url[authority_start..].len;
    const authority_end = authority_start + after_authority_rel;
    const host = url[authority_start..authority_end];
    const origin = url[0..authority_end];

    const path_start = authority_end;
    if (path_start >= url.len or url[path_start] != '/') {
        return .{ .host = host, .origin = origin, .path = "/" };
    }
    const query_start_rel = std.mem.indexOfAny(u8, url[path_start..], "?#") orelse url[path_start..].len;
    return .{
        .host = host,
        .origin = origin,
        .path = url[path_start .. path_start + query_start_rel],
    };
}
