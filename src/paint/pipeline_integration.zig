const std = @import("std");
const dom = @import("../html/dom.zig");
const tree_builder = @import("../html/tree_builder.zig");
const css_parser = @import("../css/parser.zig");
const cssom = @import("../css/cssom.zig");
const cascade = @import("../css/cascade.zig");
const block = @import("../layout/block.zig");
const inline_layout = @import("../layout/inline.zig");
const float_layout = @import("../layout/float.zig");
const display_list = @import("display_list.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");

test "integration pipeline parses DOM+CSSOM and renders styled output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const html_input =
        \\<div class='container'><p class='title'>alpha beta gamma delta</p></div>
    ;
    const css_input =
        \\.container { width: 200; background-color: blue; }
        \\p.title { color: red; font-size: 10; line-height: 1.5; text-align: right; }
    ;

    const parsed = try tree_builder.parseDocument(arena, html_input, null);
    const css_rules = try css_parser.parseStylesheet(arena, css_input);
    const rules = try buildCascadeRules(arena, css_rules);

    var styles = std.AutoHashMap(*dom.Node, cascade.ComputedStyle).init(std.testing.allocator);
    defer styles.deinit();
    try computeStyleMap(parsed.root, null, rules, &styles);

    const container = findFirstByClass(parsed.root, "container") orelse return error.TestExpectedEqual;
    const paragraph = findFirstByClass(parsed.root, "title") orelse return error.TestExpectedEqual;
    const text_node = paragraph.first_child orelse return error.TestExpectedEqual;
    const paragraph_text = switch (text_node.kind) {
        .text => |t| t,
        else => return error.TestExpectedEqual,
    };

    const container_style = styles.get(container) orelse return error.TestExpectedEqual;
    const paragraph_style = styles.get(paragraph) orelse return error.TestExpectedEqual;

    try std.testing.expectEqual(@as(u32, 0xFF0000FF), container_style.background_color);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), paragraph_style.color);

    const geom = block.layoutBlockGeometry(.{
        .container_width = 300,
        .content_height = 80,
        .style = container_style,
    });
    try std.testing.expectApproxEqAbs(@as(f32, 200), geom.width, 0.001);

    const lines = try inline_layout.layoutTextLines(std.testing.allocator, paragraph_text, .{
        .max_width = geom.width,
        .font_size = paragraph_style.font_size,
        .line_height = paragraph_style.line_height,
        .text_align = paragraph_style.text_align,
    });
    defer std.testing.allocator.free(lines);
    try std.testing.expect(lines.len >= 1);
    try std.testing.expect(lines[0].x_offset >= 0);

    var list = display_list.DisplayList.init(std.testing.allocator);
    defer list.deinit();
    try display_list.addBackground(&list, .{
        .x = geom.x,
        .y = geom.y,
        .width = geom.width,
        .height = geom.height,
    }, container_style.background_color);
    try display_list.addText(&list, geom.x, geom.y + text.lineHeightPx(paragraph_style.font_size, paragraph_style.line_height), paragraph_text, paragraph_style.color);

    var fb = try raster.Framebuffer.init(std.testing.allocator, 256, 128);
    defer fb.deinit();
    raster.clear(&fb, 0xFF101010);
    const baseline = raster.checksum(&fb);
    renderDisplayListToFramebuffer(&fb, list.commands.items);
    try std.testing.expect(raster.checksum(&fb) != baseline);
}

test "integration float-flow from parsed DOM+CSSOM narrows line width and honors clear" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const html_input =
        \\<div class='wrap'><div class='infobox'>box</div><p class='body'>
        \\lorem ipsum dolor sit amet consectetur adipiscing elit
        \\</p></div>
    ;
    const css_input =
        \\.wrap { width: 500; }
        \\.infobox { float: right; width: 120; height: 80; }
        \\p.body { clear: both; font-size: 10; }
    ;

    const parsed = try tree_builder.parseDocument(arena, html_input, null);
    const css_rules = try css_parser.parseStylesheet(arena, css_input);
    const rules = try buildCascadeRules(arena, css_rules);

    var styles = std.AutoHashMap(*dom.Node, cascade.ComputedStyle).init(std.testing.allocator);
    defer styles.deinit();
    try computeStyleMap(parsed.root, null, rules, &styles);

    const wrap = findFirstByClass(parsed.root, "wrap") orelse return error.TestExpectedEqual;
    const infobox_node = findFirstByClass(parsed.root, "infobox") orelse return error.TestExpectedEqual;
    const body_node = findFirstByClass(parsed.root, "body") orelse return error.TestExpectedEqual;
    const body_text_node = body_node.first_child orelse return error.TestExpectedEqual;
    const body_text = switch (body_text_node.kind) {
        .text => |t| t,
        else => return error.TestExpectedEqual,
    };

    const wrap_style = styles.get(wrap) orelse return error.TestExpectedEqual;
    const infobox_style = styles.get(infobox_node) orelse return error.TestExpectedEqual;
    const body_style = styles.get(body_node) orelse return error.TestExpectedEqual;

    const wrap_geom = block.layoutBlockGeometry(.{
        .container_width = 500,
        .content_height = 200,
        .style = wrap_style,
    });
    const infobox_geom = block.layoutBlockGeometry(.{
        .container_width = wrap_geom.width,
        .content_height = infobox_style.height orelse 80,
        .style = infobox_style,
    });

    const float_box = float_layout.FloatBox{
        .x = wrap_geom.x + (wrap_geom.width - infobox_geom.width),
        .y = wrap_geom.y,
        .width = infobox_geom.width,
        .height = infobox_geom.height,
        .side = infobox_style.float,
    };

    try std.testing.expectEqual(cascade.FloatVal.right, infobox_style.float);
    const available = float_layout.availableLineWidth(wrap_geom.width, wrap_geom.y + 10, &.{float_box});
    try std.testing.expectApproxEqAbs(@as(f32, 380), available, 0.001);

    const no_float_lines = try inline_layout.layoutTextLines(std.testing.allocator, body_text, .{
        .max_width = wrap_geom.width,
        .font_size = body_style.font_size,
        .line_height = body_style.line_height,
        .text_align = body_style.text_align,
    });
    defer std.testing.allocator.free(no_float_lines);

    const float_lines = try inline_layout.layoutTextLines(std.testing.allocator, body_text, .{
        .max_width = available,
        .font_size = body_style.font_size,
        .line_height = body_style.line_height,
        .text_align = body_style.text_align,
    });
    defer std.testing.allocator.free(float_lines);

    try std.testing.expect(float_lines.len >= no_float_lines.len);
    try std.testing.expectEqual(cascade.ClearVal.both, body_style.clear);
    const cleared_y = float_layout.clearOffset(body_style.clear, wrap_geom.y, &.{float_box});
    try std.testing.expectApproxEqAbs(@as(f32, wrap_geom.y + 80), cleared_y, 0.001);
}

fn computeStyleMap(
    node: *dom.Node,
    parent_style: ?cascade.ComputedStyle,
    rules: []const cascade.Rule,
    out: *std.AutoHashMap(*dom.Node, cascade.ComputedStyle),
) !void {
    var current_parent = parent_style;

    if (node.kind == .element) {
        const style = cascade.computeStyle(node, parent_style, rules);
        try out.put(node, style);
        current_parent = style;
    }

    if (node.first_child) |child| try computeStyleMap(child, current_parent, rules, out);
    if (node.next_sibling) |sibling| try computeStyleMap(sibling, parent_style, rules, out);
}

fn findFirstByClass(root: *dom.Node, class_name: []const u8) ?*dom.Node {
    var cursor: ?*dom.Node = root;
    while (cursor) |node| {
        if (node.kind == .element) {
            const attrs = node.kind.element.attributes;
            for (attrs) |attr| {
                if (std.mem.eql(u8, attr.name, "class")) {
                    var tokens = std.mem.tokenizeScalar(u8, attr.value, ' ');
                    while (tokens.next()) |t| {
                        if (std.mem.eql(u8, t, class_name)) return node;
                    }
                }
            }
        }
        if (node.first_child) |child| {
            if (findFirstByClass(child, class_name)) |found| return found;
        }
        cursor = node.next_sibling;
    }
    return null;
}

fn buildCascadeRules(arena: std.mem.Allocator, stylesheet: []const cssom.Rule) ![]cascade.Rule {
    var out = std.ArrayList(cascade.Rule).empty;
    errdefer out.deinit(arena);

    var source_order: usize = 0;
    for (stylesheet) |css_rule| {
        for (css_rule.selectors) |selector_chain| {
            const selector_parts = try convertSelectorParts(arena, selector_chain);
            const declarations = try convertDeclarations(arena, css_rule.decls);
            try out.append(arena, .{
                .selector_parts = selector_parts,
                .declarations = declarations,
                .source_order = source_order,
            });
            source_order += 1;
        }
    }

    return out.toOwnedSlice(arena);
}

fn convertSelectorParts(arena: std.mem.Allocator, in: []const cssom.SelectorPart) ![]cascade.SelectorPart {
    var parts = try arena.alloc(cascade.SelectorPart, in.len);
    for (in, 0..) |part, idx| {
        var out_part = cascade.SelectorPart{ .simple = .{}, .combinator_to_right = null };

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
        } else {
            out_part.combinator_to_right = null;
        }
        parts[idx] = out_part;
    }
    return parts;
}

fn convertDeclarations(arena: std.mem.Allocator, in: []const cssom.Declaration) ![]cascade.Declaration {
    var decls = std.ArrayList(cascade.Declaration).empty;
    errdefer decls.deinit(arena);

    for (in) |decl| {
        const prop = parseProperty(decl.name) orelse continue;
        const value = parseValue(prop, decl.value) orelse continue;
        try decls.append(arena, .{
            .property = prop,
            .value = value,
        });
    }

    return decls.toOwnedSlice(arena);
}

fn parseProperty(name: []const u8) ?cascade.Property {
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

fn parseValue(property: cascade.Property, raw: []const u8) ?cascade.Value {
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

fn parseDisplay(raw: []const u8) ?cascade.Value {
    if (std.mem.eql(u8, raw, "block")) return .{ .display = .block };
    if (std.mem.eql(u8, raw, "inline")) return .{ .display = .@"inline" };
    if (std.mem.eql(u8, raw, "inline-block")) return .{ .display = .inline_block };
    if (std.mem.eql(u8, raw, "none")) return .{ .display = .none };
    return null;
}

fn parseColor(raw: []const u8) ?cascade.Value {
    if (std.mem.eql(u8, raw, "black")) return .{ .color = 0xFF000000 };
    if (std.mem.eql(u8, raw, "white")) return .{ .color = 0xFFFFFFFF };
    if (std.mem.eql(u8, raw, "red")) return .{ .color = 0xFFFF0000 };
    if (std.mem.eql(u8, raw, "green")) return .{ .color = 0xFF00FF00 };
    if (std.mem.eql(u8, raw, "blue")) return .{ .color = 0xFF0000FF };
    return null;
}

fn parseNumberValue(property: cascade.Property, raw: []const u8) ?cascade.Value {
    const n = parseFloat(raw) orelse return null;
    return switch (property) {
        .font_size => .{ .font_size = n },
        .line_height => .{ .line_height = n },
        .width, .height => .{ .size = n },
        else => null,
    };
}

fn parseWeight(raw: []const u8) ?cascade.Value {
    const parsed = std.fmt.parseInt(u16, raw, 10) catch return null;
    return .{ .font_weight = parsed };
}

fn parseTextAlign(raw: []const u8) ?cascade.Value {
    if (std.mem.eql(u8, raw, "left")) return .{ .text_align = .left };
    if (std.mem.eql(u8, raw, "right")) return .{ .text_align = .right };
    if (std.mem.eql(u8, raw, "center")) return .{ .text_align = .center };
    if (std.mem.eql(u8, raw, "justify")) return .{ .text_align = .justify };
    return null;
}

fn parseEdges(raw: []const u8) ?cascade.Value {
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

fn parseFloatValue(raw: []const u8) ?cascade.Value {
    if (std.mem.eql(u8, raw, "none")) return .{ .float_val = .none };
    if (std.mem.eql(u8, raw, "left")) return .{ .float_val = .left };
    if (std.mem.eql(u8, raw, "right")) return .{ .float_val = .right };
    return null;
}

fn parseClear(raw: []const u8) ?cascade.Value {
    if (std.mem.eql(u8, raw, "none")) return .{ .clear_val = .none };
    if (std.mem.eql(u8, raw, "left")) return .{ .clear_val = .left };
    if (std.mem.eql(u8, raw, "right")) return .{ .clear_val = .right };
    if (std.mem.eql(u8, raw, "both")) return .{ .clear_val = .both };
    return null;
}

fn renderDisplayListToFramebuffer(fb: *raster.Framebuffer, commands: []const display_list.Command) void {
    for (commands) |cmd| {
        switch (cmd) {
            .rect => |r| raster.drawRect(fb, r.rect, r.color),
            .text => |t| {
                const width = text.measureTextWidth(t.text, 10);
                raster.drawRect(fb, .{
                    .x = t.x,
                    .y = t.y - 8,
                    .width = width,
                    .height = 10,
                }, t.color);
            },
            .image => {},
        }
    }
}
