const std = @import("std");
const errors = @import("errors.zig");
const fetch_mod = @import("net/fetch.zig");
const origin_mod = @import("security/origin.zig");
const dom = @import("html/dom.zig");
const tree_builder = @import("html/tree_builder.zig");
const css_parser = @import("css/parser.zig");
const cssom = @import("css/cssom.zig");
const style = @import("css/cascade.zig");
const layout = @import("layout/box.zig");
const layout_block = @import("layout/block.zig");
const layout_inline = @import("layout/inline.zig");
const paint_display_list = @import("paint/display_list.zig");
const paint_raster = @import("paint/raster.zig");
const paint_text = @import("paint/text.zig");
const script = @import("script/engine.zig");
const url_mod = @import("net/url.zig");

pub const Origin = origin_mod.Origin;
pub const Node = dom.Node;
pub const ComputedStyle = style.ComputedStyle;
pub const Box = layout.Box;
pub const ScriptEngine = script.ScriptEngine;
pub const ParsedUrl = url_mod.ParsedUrl;
pub const NavError = errors.NavError;

const PipelineState = struct {
    dom_root: *Node,
    style_map: *std.AutoHashMap(*Node, ComputedStyle),
    box_root: *Box,
    render_checksum: u64,
};

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
    render_checksum: u64 = 0,
    current_url: ?ParsedUrl = null,

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
        const response = try fetch_mod.fetch(arena_allocator, io, url);

        self.origin = origin_mod.fromUrl(url);
        self.current_url = url;

        const pipeline = buildRenderPipeline(arena_allocator, response.bytes) catch return error.MalformedDocument;

        self.dom_root = pipeline.dom_root;
        self.style_for = pipeline.style_map;
        self.box_root = pipeline.box_root;
        self.render_checksum = pipeline.render_checksum;
        self.has_loaded = true;
    }

    pub fn navigateLink(self: *Page, io: std.Io, href: []const u8) NavError!void {
        if (std.mem.startsWith(u8, href, "http://") or std.mem.startsWith(u8, href, "https://")) {
            const absolute = url_mod.parse(self.process_allocator, href) catch return error.InvalidUrl;
            return self.navigate(io, absolute);
        }

        const base = self.current_url orelse return error.InvalidUrl;
        const resolved = url_mod.resolve(self.process_allocator, base, href) catch return error.InvalidUrl;
        return self.navigate(io, resolved);
    }

    fn teardown(self: *Page) void {
        self.engine.stopScript();
        self.engine.severHandles();
        self.engine.drainFinalizers();
        self.arena.deinit();
        self.engine.teardownIsolate();
        self.dom_root = null;
        self.style_for = null;
        self.box_root = null;
        self.has_loaded = false;
        self.render_checksum = 0;
        self.current_url = null;
    }
};

fn buildRenderPipeline(arena: std.mem.Allocator, html_input: []const u8) !PipelineState {
    const parsed = try tree_builder.parseDocument(arena, html_input, null);
    const css_sources = try collectStyleSources(arena, parsed.root);
    try css_parser.parseCssCorpusNoCrash(arena, css_sources);

    const rules = try buildCascadeRulesFromCss(arena, css_sources);

    const style_map = try arena.create(std.AutoHashMap(*Node, ComputedStyle));
    style_map.* = std.AutoHashMap(*Node, ComputedStyle).init(arena);
    try computeStyleMap(parsed.root, null, rules, style_map);

    const body_style = style_map.get(parsed.body) orelse ComputedStyle{ .display = .block };
    const body_text = try collectTextContent(arena, parsed.body);
    const body_geom = layout_block.layoutBlockGeometry(.{
        .container_width = body_style.width orelse 800,
        .content_height = body_style.height orelse 0,
        .style = body_style,
    });

    const lines = try layout_inline.layoutTextLines(arena, body_text, .{
        .max_width = body_geom.width,
        .font_size = body_style.font_size,
        .line_height = body_style.line_height,
        .text_align = body_style.text_align,
    });

    const line_boxes = try arena.alloc(layout.LineBox, lines.len);
    for (lines, 0..) |line, idx| {
        line_boxes[idx] = .{
            .x = body_geom.x + line.x_offset,
            .y = body_geom.y + (@as(f32, @floatFromInt(idx)) * line.height),
            .width = line.width,
            .height = line.height,
        };
    }

    const text_box = try arena.create(layout.Box);
    text_box.* = .{
        .x = body_geom.x,
        .y = body_geom.y,
        .width = body_geom.width,
        .height = if (lines.len == 0) 0 else (line_boxes[lines.len - 1].y - body_geom.y) + line_boxes[lines.len - 1].height,
        .content = .{ .line = line_boxes },
        .source = parsed.body,
    };

    const children = try arena.alloc(layout.Box, 1);
    children[0] = text_box.*;

    const root_box = try arena.create(layout.Box);
    root_box.* = .{
        .x = body_geom.x,
        .y = body_geom.y,
        .width = body_geom.width,
        .height = if (body_geom.height > 0) body_geom.height else text_box.height,
        .content = .{ .block = children },
        .source = parsed.body,
    };

    var display = paint_display_list.DisplayList.init(arena);
    const bg_rect = paint_display_list.Rect{
        .x = root_box.x,
        .y = root_box.y,
        .width = root_box.width,
        .height = root_box.height,
    };
    try paint_display_list.addBackground(&display, bg_rect, body_style.background_color);

    if (body_text.len > 0) {
        try paint_display_list.addText(
            &display,
            root_box.x,
            root_box.y + paint_text.lineHeightPx(body_style.font_size, body_style.line_height),
            body_text,
            body_style.color,
        );
    }

    const framebuffer = try arena.create(paint_raster.Framebuffer);
    framebuffer.* = try paint_raster.Framebuffer.init(arena, 1024, 768);
    paint_raster.clear(framebuffer, 0xFFFFFFFF);
    renderDisplayListToFramebuffer(framebuffer, display.commands.items);

    return .{
        .dom_root = parsed.root,
        .style_map = style_map,
        .box_root = root_box,
        .render_checksum = paint_raster.checksum(framebuffer),
    };
}

fn collectStyleSources(arena: std.mem.Allocator, root: *Node) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try collectStyleSourcesWalk(arena, root, &out);
    return out.toOwnedSlice(arena);
}

fn collectStyleSourcesWalk(arena: std.mem.Allocator, node: *Node, out: *std.ArrayList([]const u8)) !void {
    switch (node.kind) {
        .element => |el| {
            if (std.mem.eql(u8, el.tag_name, "style")) {
                if (node.first_child) |child| {
                    switch (child.kind) {
                        .text => |txt| try out.append(arena, txt),
                        else => {},
                    }
                }
            }
        },
        else => {},
    }

    if (node.first_child) |child| try collectStyleSourcesWalk(arena, child, out);
    if (node.next_sibling) |sibling| try collectStyleSourcesWalk(arena, sibling, out);
}

fn collectTextContent(arena: std.mem.Allocator, root: *Node) ![]const u8 {
    var buffer = std.ArrayList(u8).empty;
    try collectTextContentWalk(arena, &buffer, root);
    return buffer.toOwnedSlice(arena);
}

fn collectTextContentWalk(arena: std.mem.Allocator, buffer: *std.ArrayList(u8), node: *Node) !void {
    switch (node.kind) {
        .text => |txt| {
            if (buffer.items.len > 0 and txt.len > 0) try buffer.append(arena, ' ');
            try buffer.appendSlice(arena, txt);
        },
        else => {},
    }

    if (node.first_child) |child| try collectTextContentWalk(arena, buffer, child);
    if (node.next_sibling) |sibling| try collectTextContentWalk(arena, buffer, sibling);
}

fn computeStyleMap(
    node: *Node,
    parent_style: ?ComputedStyle,
    rules: []const style.Rule,
    out: *std.AutoHashMap(*Node, ComputedStyle),
) !void {
    var current_parent = parent_style;

    switch (node.kind) {
        .element => {
            const computed = style.computeStyle(node, parent_style, rules);
            try out.put(node, computed);
            current_parent = computed;
        },
        else => {},
    }

    if (node.first_child) |child| try computeStyleMap(child, current_parent, rules, out);
    if (node.next_sibling) |sibling| try computeStyleMap(sibling, parent_style, rules, out);
}

fn buildCascadeRulesFromCss(arena: std.mem.Allocator, css_sources: []const []const u8) ![]style.Rule {
    var out = std.ArrayList(style.Rule).empty;
    errdefer out.deinit(arena);

    var source_order: usize = 0;
    for (css_sources) |source| {
        const parsed_rules = try css_parser.parseStylesheet(arena, source);
        for (parsed_rules) |parsed_rule| {
            for (parsed_rule.selectors) |selector_chain| {
                const selector_parts = try convertSelectorParts(arena, selector_chain);
                const declarations = try convertDeclarations(arena, parsed_rule.decls);
                try out.append(arena, .{
                    .selector_parts = selector_parts,
                    .declarations = declarations,
                    .source_order = source_order,
                });
                source_order += 1;
            }
        }
    }

    return out.toOwnedSlice(arena);
}

fn convertSelectorParts(arena: std.mem.Allocator, in: []const cssom.SelectorPart) ![]style.SelectorPart {
    const parts = try arena.alloc(style.SelectorPart, in.len);
    for (in, 0..) |part, idx| {
        var out_part = style.SelectorPart{ .simple = .{}, .combinator_to_right = null };

        for (part.simple) |simple| {
            switch (simple) {
                .type_sel => |t| out_part.simple.tag_name = t,
                .id => |id| out_part.simple.id = id,
                .class => |cls| out_part.simple.class = cls,
                else => {},
            }
        }

        if (part.combinator) |comb| {
            out_part.combinator_to_right = switch (comb) {
                .descendant => .descendant,
                .child => .child,
                .adjacent => .descendant,
            };
        }

        parts[idx] = out_part;
    }
    return parts;
}

fn convertDeclarations(arena: std.mem.Allocator, in: []const cssom.Declaration) ![]style.Declaration {
    var decls = std.ArrayList(style.Declaration).empty;
    errdefer decls.deinit(arena);

    for (in) |decl| {
        const property = parseProperty(decl.name) orelse continue;
        const value = parseValue(property, decl.value) orelse continue;
        try decls.append(arena, .{
            .property = property,
            .value = value,
        });
    }

    return decls.toOwnedSlice(arena);
}

fn parseProperty(name: []const u8) ?style.Property {
    if (std.mem.eql(u8, name, "display")) return .display;
    if (std.mem.eql(u8, name, "color")) return .color;
    if (std.mem.eql(u8, name, "background-color")) return .background_color;
    if (std.mem.eql(u8, name, "font-size")) return .font_size;
    if (std.mem.eql(u8, name, "font-weight")) return .font_weight;
    if (std.mem.eql(u8, name, "line-height")) return .line_height;
    if (std.mem.eql(u8, name, "text-align")) return .text_align;
    if (std.mem.eql(u8, name, "margin")) return .margin;
    if (std.mem.eql(u8, name, "padding")) return .padding;
    if (std.mem.eql(u8, name, "border")) return .border;
    if (std.mem.eql(u8, name, "width")) return .width;
    if (std.mem.eql(u8, name, "height")) return .height;
    if (std.mem.eql(u8, name, "float")) return .float;
    if (std.mem.eql(u8, name, "clear")) return .clear;
    return null;
}

fn parseValue(property: style.Property, raw: []const u8) ?style.Value {
    if (std.mem.eql(u8, raw, "inherit")) return .{ .keyword = .inherit };
    if (std.mem.eql(u8, raw, "initial")) return .{ .keyword = .initial };

    return switch (property) {
        .display => parseDisplay(raw),
        .color, .background_color => parseColor(raw),
        .font_size, .line_height, .width, .height => parseNumberValue(property, raw),
        .font_weight => parseWeight(raw),
        .text_align => parseTextAlign(raw),
        .margin, .padding, .border => parseEdges(raw),
        .float => parseFloatValue(raw),
        .clear => parseClear(raw),
    };
}

fn parseDisplay(raw: []const u8) ?style.Value {
    if (std.mem.eql(u8, raw, "block")) return .{ .display = .block };
    if (std.mem.eql(u8, raw, "inline")) return .{ .display = .@"inline" };
    if (std.mem.eql(u8, raw, "inline-block")) return .{ .display = .inline_block };
    if (std.mem.eql(u8, raw, "none")) return .{ .display = .none };
    return null;
}

fn parseColor(raw: []const u8) ?style.Value {
    if (std.mem.eql(u8, raw, "black")) return .{ .color = 0xFF000000 };
    if (std.mem.eql(u8, raw, "white")) return .{ .color = 0xFFFFFFFF };
    if (std.mem.eql(u8, raw, "red")) return .{ .color = 0xFFFF0000 };
    if (std.mem.eql(u8, raw, "green")) return .{ .color = 0xFF00FF00 };
    if (std.mem.eql(u8, raw, "blue")) return .{ .color = 0xFF0000FF };
    if (std.mem.startsWith(u8, raw, "#")) {
        const hex = raw[1..];
        if (hex.len == 6) {
            const parsed = std.fmt.parseInt(u32, hex, 16) catch return null;
            return .{ .color = 0xFF000000 | parsed };
        }
    }
    return null;
}

fn parseNumberValue(property: style.Property, raw: []const u8) ?style.Value {
    const n = parseFloat(raw) orelse return null;
    return switch (property) {
        .font_size => .{ .font_size = n },
        .line_height => .{ .line_height = n },
        .width, .height => .{ .size = n },
        else => null,
    };
}

fn parseWeight(raw: []const u8) ?style.Value {
    const parsed = std.fmt.parseInt(u16, raw, 10) catch return null;
    return .{ .font_weight = parsed };
}

fn parseTextAlign(raw: []const u8) ?style.Value {
    if (std.mem.eql(u8, raw, "left")) return .{ .text_align = .left };
    if (std.mem.eql(u8, raw, "right")) return .{ .text_align = .right };
    if (std.mem.eql(u8, raw, "center")) return .{ .text_align = .center };
    if (std.mem.eql(u8, raw, "justify")) return .{ .text_align = .justify };
    return null;
}

fn parseEdges(raw: []const u8) ?style.Value {
    const n = parseFloat(raw) orelse return null;
    return .{ .edges = .{ n, n, n, n } };
}

fn parseFloat(raw: []const u8) ?f32 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;

    var end = trimmed.len;
    while (end > 0) : (end -= 1) {
        const ch = trimmed[end - 1];
        if ((ch >= '0' and ch <= '9') or ch == '.' or ch == '-') break;
    }
    if (end == 0) return null;
    return std.fmt.parseFloat(f32, trimmed[0..end]) catch null;
}

fn parseFloatValue(raw: []const u8) ?style.Value {
    if (std.mem.eql(u8, raw, "none")) return .{ .float_val = .none };
    if (std.mem.eql(u8, raw, "left")) return .{ .float_val = .left };
    if (std.mem.eql(u8, raw, "right")) return .{ .float_val = .right };
    return null;
}

fn parseClear(raw: []const u8) ?style.Value {
    if (std.mem.eql(u8, raw, "none")) return .{ .clear_val = .none };
    if (std.mem.eql(u8, raw, "left")) return .{ .clear_val = .left };
    if (std.mem.eql(u8, raw, "right")) return .{ .clear_val = .right };
    if (std.mem.eql(u8, raw, "both")) return .{ .clear_val = .both };
    return null;
}

fn renderDisplayListToFramebuffer(
    framebuffer: *paint_raster.Framebuffer,
    commands: []const paint_display_list.Command,
) void {
    for (commands) |command| {
        switch (command) {
            .rect => |rect| paint_raster.drawRect(framebuffer, rect.rect, rect.color),
            .text => |text_cmd| {
                const width = paint_text.measureTextWidth(text_cmd.text, 10);
                paint_raster.drawRect(framebuffer, .{
                    .x = text_cmd.x,
                    .y = text_cmd.y - 8,
                    .width = width,
                    .height = 10,
                }, text_cmd.color);
            },
            .image => {},
        }
    }
}
