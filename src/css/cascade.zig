const std = @import("std");
const dom = @import("../html/dom.zig");

pub const Display = enum { block, @"inline", inline_block, none };
pub const TextAlign = enum { left, right, center, justify };
pub const FloatVal = enum { none, left, right };
pub const ClearVal = enum { none, left, right, both };

pub const ComputedStyle = struct {
    display: Display = .@"inline",
    color: u32 = 0xFF000000,
    background_color: u32 = 0x00000000,
    font_size: f32 = 16.0,
    font_weight: u16 = 400,
    line_height: f32 = 1.2,
    text_align: TextAlign = .left,
    margin: [4]f32 = .{ 0, 0, 0, 0 },
    padding: [4]f32 = .{ 0, 0, 0, 0 },
    border: [4]f32 = .{ 0, 0, 0, 0 },
    width: ?f32 = null,
    height: ?f32 = null,
    float: FloatVal = .none,
    clear: ClearVal = .none,
};

pub const Combinator = enum { descendant, child };

pub const SimpleSelector = struct {
    tag_name: ?[]const u8 = null,
    id: ?[]const u8 = null,
    class: ?[]const u8 = null,
};

pub const SelectorPart = struct {
    simple: SimpleSelector,
    combinator_to_right: ?Combinator = null,
};

pub const Property = enum {
    display,
    color,
    background_color,
    font_size,
    font_weight,
    line_height,
    text_align,
    margin,
    padding,
    border,
    width,
    height,
    float,
    clear,
};

pub const Keyword = enum { inherit, initial };

pub const Value = union(enum) {
    display: Display,
    color: u32,
    font_size: f32,
    font_weight: u16,
    line_height: f32,
    text_align: TextAlign,
    edges: [4]f32,
    size: f32,
    float_val: FloatVal,
    clear_val: ClearVal,
    keyword: Keyword,
};

pub const Declaration = struct {
    property: Property,
    value: Value,
    important: bool = false,
};

pub const Rule = struct {
    selector_parts: []const SelectorPart,
    declarations: []const Declaration,
    source_order: usize = 0,
    inline_style: bool = false,
};

pub const Specificity = struct {
    ids: u16 = 0,
    classes: u16 = 0,
    types: u16 = 0,
};

pub fn matchesSelector(node: *const dom.Node, parts: []const SelectorPart) bool {
    if (parts.len == 0) return false;
    return matchPart(node, parts, parts.len - 1);
}

pub fn computeStyle(
    node: *const dom.Node,
    parent_style: ?ComputedStyle,
    rules: []const Rule,
) ComputedStyle {
    var computed = ComputedStyle{};
    const properties = [_]Property{
        .display,
        .color,
        .background_color,
        .font_size,
        .font_weight,
        .line_height,
        .text_align,
        .margin,
        .padding,
        .border,
        .width,
        .height,
        .float,
        .clear,
    };

    inline for (properties) |property| {
        if (pickWinningDeclaration(node, rules, property)) |winner| {
            applyDeclaration(&computed, parent_style, winner);
        } else if (isInheritedProperty(property) and parent_style != null) {
            copyProperty(&computed, parent_style.?, property);
        }
    }

    return computed;
}

fn matchPart(node: *const dom.Node, parts: []const SelectorPart, right_index: usize) bool {
    if (!matchesSimple(node, parts[right_index].simple)) return false;
    if (right_index == 0) return true;

    const left_index = right_index - 1;
    const left = parts[left_index];
    const combinator = left.combinator_to_right orelse .descendant;

    switch (combinator) {
        .child => {
            if (node.parent) |p| return matchPart(p, parts, left_index);
            return false;
        },
        .descendant => {
            var cursor = node.parent;
            while (cursor) |ancestor| : (cursor = ancestor.parent) {
                if (matchPart(ancestor, parts, left_index)) return true;
            }
            return false;
        },
    }
}

fn matchesSimple(node: *const dom.Node, simple: SimpleSelector) bool {
    const el = elementOf(node) orelse return false;

    if (simple.tag_name) |tag_name| {
        if (!std.mem.eql(u8, el.tag_name, tag_name)) return false;
    }
    if (simple.id) |id_value| {
        const found = attributeValue(el, "id") orelse return false;
        if (!std.mem.eql(u8, found, id_value)) return false;
    }
    if (simple.class) |class_name| {
        if (!hasClass(el, class_name)) return false;
    }

    return true;
}

fn elementOf(node: *const dom.Node) ?dom.Element {
    return switch (node.kind) {
        .element => |el| el,
        else => null,
    };
}

fn attributeValue(el: dom.Element, name: []const u8) ?[]const u8 {
    for (el.attributes) |attr| {
        if (std.mem.eql(u8, attr.name, name)) return attr.value;
    }
    return null;
}

fn hasClass(el: dom.Element, class_name: []const u8) bool {
    const classes = attributeValue(el, "class") orelse return false;
    var tokens = std.mem.tokenizeScalar(u8, classes, ' ');
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, class_name)) return true;
    }
    return false;
}

fn pickWinningDeclaration(
    node: *const dom.Node,
    rules: []const Rule,
    property: Property,
) ?Declaration {
    var winner: ?Candidate = null;
    for (rules) |rule| {
        if (!matchesSelector(node, rule.selector_parts)) continue;

        const specificity = ruleSpecificity(rule);
        for (rule.declarations) |decl| {
            if (decl.property != property) continue;
            const candidate = Candidate{
                .declaration = decl,
                .important = decl.important,
                .specificity = specificity,
                .source_order = rule.source_order,
            };
            if (winner == null or candidateWins(candidate, winner.?)) winner = candidate;
        }
    }
    return if (winner) |w| w.declaration else null;
}

const Candidate = struct {
    declaration: Declaration,
    important: bool,
    specificity: Specificity,
    source_order: usize,
};

fn candidateWins(candidate: Candidate, incumbent: Candidate) bool {
    if (candidate.important != incumbent.important) return candidate.important;

    const spec_cmp = compareSpecificity(candidate.specificity, incumbent.specificity);
    if (spec_cmp != 0) return spec_cmp > 0;

    return candidate.source_order > incumbent.source_order;
}

fn compareSpecificity(a: Specificity, b: Specificity) i8 {
    if (a.ids != b.ids) return if (a.ids > b.ids) 1 else -1;
    if (a.classes != b.classes) return if (a.classes > b.classes) 1 else -1;
    if (a.types != b.types) return if (a.types > b.types) 1 else -1;
    return 0;
}

fn ruleSpecificity(rule: Rule) Specificity {
    if (rule.inline_style) return .{ .ids = std.math.maxInt(u16) };

    var spec = Specificity{};
    for (rule.selector_parts) |part| {
        if (part.simple.id != null) spec.ids += 1;
        if (part.simple.class != null) spec.classes += 1;
        if (part.simple.tag_name != null) spec.types += 1;
    }
    return spec;
}

fn isInheritedProperty(property: Property) bool {
    return switch (property) {
        .color, .font_size, .font_weight, .line_height, .text_align => true,
        else => false,
    };
}

fn applyDeclaration(style: *ComputedStyle, parent: ?ComputedStyle, decl: Declaration) void {
    switch (decl.value) {
        .keyword => |keyword| {
            applyKeyword(style, parent, decl.property, keyword);
        },
        else => {
            applyConcreteValue(style, decl);
        },
    }
}

fn applyKeyword(
    style: *ComputedStyle,
    parent: ?ComputedStyle,
    property: Property,
    keyword: Keyword,
) void {
    if (keyword == .initial or parent == null) {
        copyProperty(style, ComputedStyle{}, property);
        return;
    }
    copyProperty(style, parent.?, property);
}

fn applyConcreteValue(style: *ComputedStyle, decl: Declaration) void {
    switch (decl.property) {
        .display => {
            if (decl.value == .display) style.display = decl.value.display;
        },
        .color => {
            if (decl.value == .color) style.color = decl.value.color;
        },
        .background_color => {
            if (decl.value == .color) style.background_color = decl.value.color;
        },
        .font_size => {
            if (decl.value == .font_size) style.font_size = decl.value.font_size;
        },
        .font_weight => {
            if (decl.value == .font_weight) style.font_weight = decl.value.font_weight;
        },
        .line_height => {
            if (decl.value == .line_height) style.line_height = decl.value.line_height;
        },
        .text_align => {
            if (decl.value == .text_align) style.text_align = decl.value.text_align;
        },
        .margin => {
            if (decl.value == .edges) style.margin = decl.value.edges;
        },
        .padding => {
            if (decl.value == .edges) style.padding = decl.value.edges;
        },
        .border => {
            if (decl.value == .edges) style.border = decl.value.edges;
        },
        .width => {
            if (decl.value == .size) style.width = decl.value.size;
        },
        .height => {
            if (decl.value == .size) style.height = decl.value.size;
        },
        .float => {
            if (decl.value == .float_val) style.float = decl.value.float_val;
        },
        .clear => {
            if (decl.value == .clear_val) style.clear = decl.value.clear_val;
        },
    }
}

fn copyProperty(dst: *ComputedStyle, src: ComputedStyle, property: Property) void {
    switch (property) {
        .display => dst.display = src.display,
        .color => dst.color = src.color,
        .background_color => dst.background_color = src.background_color,
        .font_size => dst.font_size = src.font_size,
        .font_weight => dst.font_weight = src.font_weight,
        .line_height => dst.line_height = src.line_height,
        .text_align => dst.text_align = src.text_align,
        .margin => dst.margin = src.margin,
        .padding => dst.padding = src.padding,
        .border => dst.border = src.border,
        .width => dst.width = src.width,
        .height => dst.height = src.height,
        .float => dst.float = src.float,
        .clear => dst.clear = src.clear,
    }
}

test "cascade-specificity and important precedence" {
    var root_attrs = [_]dom.Attribute{.{ .name = "id", .value = "hero" }};
    var root = dom.Node{
        .kind = .{ .element = .{
            .tag_name = "div",
            .attributes = root_attrs[0..],
        } },
    };

    var child_attrs = [_]dom.Attribute{.{ .name = "class", .value = "title" }};
    var child = dom.Node{
        .kind = .{ .element = .{
            .tag_name = "span",
            .attributes = child_attrs[0..],
        } },
        .parent = &root,
    };
    root.first_child = &child;

    const desc_parts = [_]SelectorPart{
        .{ .simple = .{ .tag_name = "div" }, .combinator_to_right = .descendant },
        .{ .simple = .{ .tag_name = "span" } },
    };
    const id_child_parts = [_]SelectorPart{
        .{ .simple = .{ .id = "hero" }, .combinator_to_right = .child },
        .{ .simple = .{ .tag_name = "span" } },
    };
    const class_parts = [_]SelectorPart{
        .{ .simple = .{ .class = "title" } },
    };

    const rules = [_]Rule{
        .{
            .selector_parts = desc_parts[0..],
            .declarations = &.{.{ .property = .color, .value = .{ .color = 0xFFFF0000 } }},
            .source_order = 1,
        },
        .{
            .selector_parts = id_child_parts[0..],
            .declarations = &.{.{ .property = .color, .value = .{ .color = 0xFF00FF00 } }},
            .source_order = 2,
        },
        .{
            .selector_parts = class_parts[0..],
            .declarations = &.{.{ .property = .color, .value = .{ .color = 0xFF0000FF }, .important = true }},
            .source_order = 3,
        },
    };

    const style = computeStyle(&child, null, rules[0..]);
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), style.color);
}

test "cascade-source-order tie-breaks equal specificity" {
    var attrs = [_]dom.Attribute{.{ .name = "class", .value = "title" }};
    const node = dom.Node{
        .kind = .{ .element = .{
            .tag_name = "span",
            .attributes = attrs[0..],
        } },
    };

    const class_parts = [_]SelectorPart{
        .{ .simple = .{ .class = "title" } },
    };
    const rules = [_]Rule{
        .{
            .selector_parts = class_parts[0..],
            .declarations = &.{.{ .property = .color, .value = .{ .color = 0xFF111111 } }},
            .source_order = 10,
        },
        .{
            .selector_parts = class_parts[0..],
            .declarations = &.{.{ .property = .color, .value = .{ .color = 0xFF222222 } }},
            .source_order = 11,
        },
    };

    const style = computeStyle(&node, null, rules[0..]);
    try std.testing.expectEqual(@as(u32, 0xFF222222), style.color);
}

test "cascade right-to-left matching honors child vs descendant combinators" {
    var root = dom.Node{
        .kind = .{ .element = .{ .tag_name = "div", .attributes = &.{} } },
    };
    var middle = dom.Node{
        .kind = .{ .element = .{ .tag_name = "section", .attributes = &.{} } },
        .parent = &root,
    };
    var leaf = dom.Node{
        .kind = .{ .element = .{ .tag_name = "span", .attributes = &.{} } },
        .parent = &middle,
    };
    root.first_child = &middle;
    middle.first_child = &leaf;

    const div_child_span = [_]SelectorPart{
        .{ .simple = .{ .tag_name = "div" }, .combinator_to_right = .child },
        .{ .simple = .{ .tag_name = "span" } },
    };
    const div_desc_span = [_]SelectorPart{
        .{ .simple = .{ .tag_name = "div" }, .combinator_to_right = .descendant },
        .{ .simple = .{ .tag_name = "span" } },
    };
    const section_child_span = [_]SelectorPart{
        .{ .simple = .{ .tag_name = "section" }, .combinator_to_right = .child },
        .{ .simple = .{ .tag_name = "span" } },
    };

    try std.testing.expect(!matchesSelector(&leaf, div_child_span[0..]));
    try std.testing.expect(matchesSelector(&leaf, div_desc_span[0..]));
    try std.testing.expect(matchesSelector(&leaf, section_child_span[0..]));
}

test "cascade inheritance uses inherited set with inherit/initial keywords" {
    const parent_style = ComputedStyle{
        .color = 0xFF123456,
        .background_color = 0xFFEEEEEE,
        .font_size = 18.0,
        .font_weight = 700,
        .line_height = 1.6,
        .text_align = .right,
    };

    var parent = dom.Node{
        .kind = .{ .element = .{ .tag_name = "div", .attributes = &.{} } },
    };
    var child = dom.Node{
        .kind = .{ .element = .{ .tag_name = "span", .attributes = &.{} } },
        .parent = &parent,
    };

    const child_selector = [_]SelectorPart{
        .{ .simple = .{ .tag_name = "span" } },
    };
    const rules = [_]Rule{
        .{
            .selector_parts = child_selector[0..],
            .declarations = &.{
                .{ .property = .color, .value = .{ .keyword = .initial } },
                .{ .property = .background_color, .value = .{ .keyword = .inherit } },
            },
            .source_order = 0,
        },
    };

    const style = computeStyle(&child, parent_style, rules[0..]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), style.color);
    try std.testing.expectEqual(@as(u32, 0xFFEEEEEE), style.background_color);
    try std.testing.expectEqual(@as(f32, 18.0), style.font_size);
    try std.testing.expectEqual(@as(u16, 700), style.font_weight);
    try std.testing.expectEqual(@as(f32, 1.6), style.line_height);
    try std.testing.expectEqual(TextAlign.right, style.text_align);
}
