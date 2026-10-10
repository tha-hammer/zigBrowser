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

/// Sensitive command inputs after redaction. Produced by `redactCommand`
/// BEFORE anything reaches a `TelemetrySink`; raw selectors, typed values and
/// URLs never cross the sink boundary.
pub const RedactedCommand = struct {
    selector_kind: ?[]const u8 = null,
    selector_hash: ?[]const u8 = null,
    selector_strict: ?bool = null,
    typed_length: ?usize = null,
    typed_class: ?[]const u8 = null,
    /// host[:port] without userinfo.
    target_host: ?[]const u8 = null,
    target_origin_hash: ?[]const u8 = null,
    target_path_hash: ?[]const u8 = null,
};

/// Backing storage for the hashes in a `RedactedCommand`.
pub const RedactionBuffers = struct {
    selector_hash: [16]u8 = undefined,
    origin_hash: [16]u8 = undefined,
    path_hash: [16]u8 = undefined,
};

/// The TelemetryRedactor step: hashes selectors and URL parts, reduces typed
/// values to length + class. Slices in the result point into `bufs` or into
/// static strings, except `target_host` (a sub-slice of `url`).
pub fn redactCommand(
    bufs: *RedactionBuffers,
    selector: ?[]const u8,
    selector_strict: bool,
    typed_value: ?[]const u8,
    url: ?[]const u8,
) RedactedCommand {
    var redacted = RedactedCommand{};
    if (selector) |text| {
        redacted.selector_kind = selectorKind(text);
        redacted.selector_hash = hexHash(&bufs.selector_hash, std.hash.Wyhash.hash(0, text));
        redacted.selector_strict = selector_strict;
    }
    if (typed_value) |value| {
        redacted.typed_length = value.len;
        redacted.typed_class = classifyTypedValue(value);
    }
    if (url) |text| {
        const parsed = parseUrl(text);
        if (parsed.host.len > 0) redacted.target_host = parsed.host;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(parsed.scheme);
        hasher.update(url_scheme_separator);
        hasher.update(parsed.host);
        redacted.target_origin_hash = hexHash(&bufs.origin_hash, hasher.final());
        redacted.target_path_hash = hexHash(&bufs.path_hash, std.hash.Wyhash.hash(0, parsed.path));
    }
    return redacted;
}

fn hexHash(buf: *[16]u8, hash: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{hash}) catch unreachable;
}

/// Root `automation.command` span recorded by the engine after a command
/// finishes. Contains only already-redacted values (see `redactCommand`).
pub const CommandSpanAttrs = struct {
    trace_id: []const u8,
    span_id: []const u8,
    command_id: []const u8,
    method: []const u8,
    namespace: []const u8,
    page_id: []const u8,
    window_id: []const u8,
    redacted: RedactedCommand = .{},
    action_name: ?[]const u8 = null,
    action_force: bool = false,
    action_trial: bool = false,
    /// "synthetic" | "native" (router.InputMode), for action commands.
    input_mode: []const u8 = "synthetic",
    /// options.humanize (N8), for action commands.
    input_humanize: bool = false,
    /// From the script's last selector.resolve span (already a count).
    selector_match_count: ?[]const u8 = null,
    build: BuildInfo = .{},
    timeout_ms: u64,
    queue_wait_ms: u64,
    duration_ms: u64,
    retry_count: u32,
    result_status: []const u8,
    automation_error: ?[]const u8 = null,
};

/// Static dimensions describing the binary/backend. Unknown values stay
/// "unknown" rather than being omitted, so queries can group on them.
pub const BuildInfo = struct {
    backend_name: []const u8 = "unknown",
    backend_version: []const u8 = "unknown",
    app_version: []const u8 = "unknown",
    git_sha: []const u8 = "unknown",
    /// automation.js `version` string.
    script_version: []const u8 = "phase1-m4-actionability",
    api_version: []const u8 = "phase1",
};

pub const ChildSpan = struct {
    name: []const u8,
    trace_id: []const u8,
    /// null: the sink assigns one.
    span_id: ?[]const u8 = null,
    parent_span_id: []const u8,
    command_id: []const u8,
    attributes: []const AttrMap.Entry,
};

/// Production sink contract (BC11). The engine only talks to this; the
/// in-memory sink below is the test implementation. Implementations receive
/// already-redacted attributes and must be thread-safe.
pub const TelemetrySink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        recordCommandSpan: *const fn (ptr: *anyopaque, attrs: CommandSpanAttrs) anyerror!void,
        recordChildSpan: *const fn (ptr: *anyopaque, span: ChildSpan) anyerror!void,
    };

    pub fn recordCommandSpan(self: TelemetrySink, attrs: CommandSpanAttrs) anyerror!void {
        return self.vtable.recordCommandSpan(self.ptr, attrs);
    }

    pub fn recordChildSpan(self: TelemetrySink, span: ChildSpan) anyerror!void {
        return self.vtable.recordChildSpan(self.ptr, span);
    }
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

    pub fn sink(self: *InMemoryTelemetrySink) TelemetrySink {
        return .{ .ptr = self, .vtable = &sink_vtable };
    }

    const sink_vtable = TelemetrySink.VTable{
        .recordCommandSpan = sinkRecordCommandSpan,
        .recordChildSpan = sinkRecordChildSpan,
    };

    fn sinkRecordCommandSpan(ptr: *anyopaque, attrs: CommandSpanAttrs) anyerror!void {
        const self: *InMemoryTelemetrySink = @ptrCast(@alignCast(ptr));
        return self.recordCommandSpan(attrs);
    }

    fn sinkRecordChildSpan(ptr: *anyopaque, span: ChildSpan) anyerror!void {
        const self: *InMemoryTelemetrySink = @ptrCast(@alignCast(ptr));
        return self.recordChildSpan(span.name, span.trace_id, span.span_id, span.parent_span_id, span.command_id, span.attributes);
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
        try self.putAttr(&attributes, "platform.name", @tagName(builtin.os.tag));
        try self.putAttr(&attributes, "backend.name", attrs.build.backend_name);
        try self.putAttr(&attributes, "backend.version", attrs.build.backend_version);
        try self.putAttr(&attributes, "app.version", attrs.build.app_version);
        try self.putAttr(&attributes, "git.sha", attrs.build.git_sha);
        try self.putAttr(&attributes, "automation.script.version", attrs.build.script_version);
        try self.putAttr(&attributes, "api.version", attrs.build.api_version);
        if (attrs.selector_match_count) |count| try self.putAttr(&attributes, "selector.match_count", count);

        const redacted = attrs.redacted;
        if (redacted.selector_kind) |kind| try self.putAttr(&attributes, "selector.kind", kind);
        if (redacted.selector_hash) |hash| try self.putAttr(&attributes, "selector.hash", hash);
        if (redacted.selector_strict) |strict| try self.putAttr(&attributes, "selector.strict", if (strict) "true" else "false");
        if (attrs.action_name) |action| {
            try self.putAttr(&attributes, "action.name", action);
            try self.putAttr(&attributes, "action.force", if (attrs.action_force) "true" else "false");
            try self.putAttr(&attributes, "action.trial", if (attrs.action_trial) "true" else "false");
            try self.putAttr(&attributes, "input.mode", attrs.input_mode);
            try self.putAttr(&attributes, "input.humanize", if (attrs.input_humanize) "true" else "false");
        }
        if (redacted.typed_length) |length| try self.putOwnedAttr(&attributes, "typed.length", try self.formatInt(length));
        if (redacted.typed_class) |class| try self.putAttr(&attributes, "typed.class", class);
        if (redacted.target_host) |host| try self.putAttr(&attributes, "target.host", host);
        if (redacted.target_origin_hash) |hash| try self.putAttr(&attributes, "target.origin_hash", hash);
        if (redacted.target_path_hash) |hash| try self.putAttr(&attributes, "target.path_hash", hash);

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
};

const selector_kinds = [_][]const u8{ "role", "testid", "text", "css", "xpath" };

/// One of the supported selector engines, or "invalid"; never the raw
/// client-supplied prefix.
fn selectorKind(selector: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, selector, '=') orelse return "invalid";
    for (selector_kinds) |kind| {
        if (std.mem.eql(u8, selector[0..idx], kind)) return kind;
    }
    return "invalid";
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
    scheme: []const u8,
    /// host[:port] with any `user:password@` userinfo removed.
    host: []const u8,
    path: []const u8,
};

fn parseUrl(url: []const u8) ParsedUrl {
    const scheme_end = std.mem.indexOf(u8, url, url_scheme_separator) orelse return .{ .scheme = "", .host = "", .path = "" };
    const authority_start = scheme_end + url_scheme_separator.len;
    const after_authority_rel = std.mem.indexOfAny(u8, url[authority_start..], "/?#") orelse url[authority_start..].len;
    const authority_end = authority_start + after_authority_rel;
    const authority = url[authority_start..authority_end];
    const host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority[at + 1 ..] else authority;

    const path_start = authority_end;
    if (path_start >= url.len or url[path_start] != '/') {
        return .{ .scheme = url[0..scheme_end], .host = host, .path = url_default_path };
    }
    const query_start_rel = std.mem.indexOfAny(u8, url[path_start..], "?#") orelse url[path_start..].len;
    return .{
        .scheme = url[0..scheme_end],
        .host = host,
        .path = url[path_start .. path_start + query_start_rel],
    };
}

/// Bounded store of the most recent traces, serving `telemetry.query`.
/// Keeps at most `capacity` traces (oldest evicted first) and
/// `max_spans_per_trace` spans per trace. It only ever receives spans that
/// already crossed the TelemetrySink boundary, i.e. redacted ones.
pub const RecentTraceStore = struct {
    pub const max_spans_per_trace = 64;

    allocator: std.mem.Allocator,
    capacity: usize,
    lock: std.atomic.Mutex = .unlocked,
    /// Oldest first.
    traces: std.ArrayListUnmanaged(Trace) = .empty,

    const Trace = struct {
        trace_id: []u8,
        /// Serialized spans; the root (automation.command) is kept first.
        spans: std.ArrayListUnmanaged([]u8) = .empty,
        has_root: bool = false,

        fn deinit(self: *Trace, allocator: std.mem.Allocator) void {
            for (self.spans.items) |span| allocator.free(span);
            self.spans.deinit(allocator);
            allocator.free(self.trace_id);
        }
    };

    pub fn init(allocator: std.mem.Allocator, capacity: usize) RecentTraceStore {
        return .{ .allocator = allocator, .capacity = @max(capacity, 1) };
    }

    pub fn deinit(self: *RecentTraceStore) void {
        for (self.traces.items) |*trace| trace.deinit(self.allocator);
        self.traces.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn sink(self: *RecentTraceStore) TelemetrySink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = TelemetrySink.VTable{ .recordCommandSpan = recordCommand, .recordChildSpan = recordChild };

    fn acquire(self: *RecentTraceStore) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn recordCommand(ptr: *anyopaque, attrs: CommandSpanAttrs) anyerror!void {
        const self: *RecentTraceStore = @ptrCast(@alignCast(ptr));
        // Reuse the in-memory sink's attribute assembly so both agree.
        var scratch = InMemoryTelemetrySink.init(self.allocator);
        defer scratch.deinit();
        try scratch.recordCommandSpan(attrs);
        const span = scratch.spanAt(0);
        const json = try spanJson(self.allocator, span.name, span.trace_id, span.span_id, null, span.command_id, span.attributes.entries.items);
        errdefer self.allocator.free(json);
        try self.add(attrs.trace_id, json, true);
    }

    fn recordChild(ptr: *anyopaque, child: ChildSpan) anyerror!void {
        const self: *RecentTraceStore = @ptrCast(@alignCast(ptr));
        const json = try spanJson(self.allocator, child.name, child.trace_id, child.span_id orelse "", child.parent_span_id, child.command_id, child.attributes);
        errdefer self.allocator.free(json);
        try self.add(child.trace_id, json, false);
    }

    fn add(self: *RecentTraceStore, trace_id: []const u8, json: []u8, is_root: bool) !void {
        self.acquire();
        defer self.lock.unlock();
        const trace = try self.traceFor(trace_id);
        if (is_root and !trace.has_root and trace.spans.items.len >= max_spans_per_trace) {
            // The root (command outcome) arrives last; make room by dropping
            // the newest child rather than losing the root.
            self.allocator.free(trace.spans.pop().?);
        }
        if (trace.spans.items.len >= max_spans_per_trace) {
            self.allocator.free(json);
            return;
        }
        if (is_root and !trace.has_root) {
            try trace.spans.insert(self.allocator, 0, json);
            trace.has_root = true;
        } else {
            try trace.spans.append(self.allocator, json);
        }
    }

    fn traceFor(self: *RecentTraceStore, trace_id: []const u8) !*Trace {
        for (self.traces.items) |*trace| {
            if (std.mem.eql(u8, trace.trace_id, trace_id)) return trace;
        }
        if (self.traces.items.len >= self.capacity) {
            var oldest = self.traces.orderedRemove(0);
            oldest.deinit(self.allocator);
        }
        const owned_id = try self.allocator.dupe(u8, trace_id);
        errdefer self.allocator.free(owned_id);
        try self.traces.append(self.allocator, .{ .trace_id = owned_id });
        return &self.traces.items[self.traces.items.len - 1];
    }

    /// `{"spans":[...]}` for `trace_id` (empty array when unknown/evicted).
    pub fn queryJson(self: *RecentTraceStore, gpa: std.mem.Allocator, trace_id: []const u8) ![]u8 {
        self.acquire();
        defer self.lock.unlock();
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, "{\"spans\":[");
        for (self.traces.items) |trace| {
            if (!std.mem.eql(u8, trace.trace_id, trace_id)) continue;
            for (trace.spans.items, 0..) |span, i| {
                if (i > 0) try out.append(gpa, ',');
                try out.appendSlice(gpa, span);
            }
        }
        try out.appendSlice(gpa, "]}");
        return out.toOwnedSlice(gpa);
    }
};

/// One span in the telemetry.query / CLI `trace` shape:
/// {name, trace_id, span_id, parent_span_id, command_id, duration_ms,
///  attributes:{...}}.
fn spanJson(
    allocator: std.mem.Allocator,
    name: []const u8,
    trace_id: []const u8,
    span_id: []const u8,
    parent_span_id: ?[]const u8,
    command_id: []const u8,
    entries: []const AttrMap.Entry,
) ![]u8 {
    var attributes: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer attributes.deinit(allocator);
    var duration_ms: u64 = 0;
    for (entries) |entry| {
        try attributes.put(allocator, entry.key, entry.value);
        if (std.mem.eql(u8, entry.key, "duration_ms")) duration_ms = std.fmt.parseInt(u64, entry.value, 10) catch 0;
    }
    const Shape = struct {
        name: []const u8,
        trace_id: []const u8,
        span_id: []const u8,
        parent_span_id: ?[]const u8,
        command_id: []const u8,
        duration_ms: u64,
        attributes: std.json.ArrayHashMap([]const u8),
    };
    return std.json.Stringify.valueAlloc(allocator, Shape{
        .name = name,
        .trace_id = trace_id,
        .span_id = span_id,
        .parent_span_id = parent_span_id,
        .command_id = command_id,
        .duration_ms = duration_ms,
        .attributes = .{ .map = attributes },
    }, .{});
}
