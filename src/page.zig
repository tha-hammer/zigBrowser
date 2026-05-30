const std = @import("std");
const errors = @import("errors.zig");
const fetch_mod = @import("net/fetch.zig");
const origin_mod = @import("security/origin.zig");
const dom = @import("html/dom.zig");
const style = @import("css/cascade.zig");
const layout = @import("layout/box.zig");
const script = @import("script/engine.zig");
const url_mod = @import("net/url.zig");

pub const Origin = origin_mod.Origin;
pub const Node = dom.Node;
pub const ComputedStyle = style.ComputedStyle;
pub const Box = layout.Box;
pub const ScriptEngine = script.ScriptEngine;
pub const ParsedUrl = url_mod.ParsedUrl;
pub const NavError = errors.NavError;

pub const Page = struct {
    process_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    origin: Origin,
    dom_root: ?*Node = null,
    style_for: ?*std.AutoHashMap(*Node, ComputedStyle) = null,
    box_root: ?*Box = null,
    scroll_y: f32 = 0,
    engine: ScriptEngine,
    has_loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator, engine: ScriptEngine) Page {
        return .{
            .process_allocator = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .origin = .{ .scheme = "", .host = "", .port = 0 },
            .engine = engine,
        };
    }

    pub fn deinit(self: *Page) void {
        self.teardown();
    }

    pub fn navigate(self: *Page, io: std.Io, url: ParsedUrl) NavError!void {
        if (self.has_loaded) {
            self.teardown();
            self.arena = std.heap.ArenaAllocator.init(self.process_allocator);
        }

        const arena_allocator = self.arena.allocator();
        _ = try fetch_mod.fetch(arena_allocator, io, url);

        self.origin = origin_mod.fromUrl(url);
        self.has_loaded = true;
    }

    fn teardown(self: *Page) void {
        self.engine.stopScript();
        self.engine.severHandles();
        self.engine.drainFinalizers();
        self.arena.deinit();
        self.engine.teardownIsolate();
    }
};
