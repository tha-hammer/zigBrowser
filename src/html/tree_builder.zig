const std = @import("std");
const dom = @import("dom.zig");
const tokenizer = @import("tokenizer.zig");
const script_mod = @import("../script/engine.zig");

pub const ParseResult = struct {
    root: *dom.Node,
    html: *dom.Node,
    body: *dom.Node,
};

pub fn parseDocument(arena: std.mem.Allocator, input: []const u8, _: ?script_mod.ScriptEngine) !ParseResult {
    const tokens = try tokenizer.tokenize(arena, input);

    const html = try createElement(arena, "html", &.{});
    const body = try createElement(arena, "body", &.{});
    appendChild(html, body);

    var stack = std.ArrayList(*dom.Node).empty;
    defer stack.deinit(arena);
    try stack.append(arena, html);
    try stack.append(arena, body);

    for (tokens) |tok| {
        switch (tok) {
            .doctype => |name| {
                const node = try createDoctype(arena, name);
                appendChild(html, node);
            },
            .comment => |text| {
                const node = try createComment(arena, text);
                appendChild(currentParent(&stack), node);
            },
            .character => |text| {
                if (text.len == 0) continue;
                if (shouldFosterParentCharacter(&stack, text)) {
                    const node = try createText(arena, text);
                    fosterParentInsert(&stack, node);
                } else {
                    const node = try createText(arena, text);
                    appendChild(currentParent(&stack), node);
                }
            },
            .start_tag => |tag| {
                try maybeImplicitClose(&stack, tag.name);
                const node = try createElement(arena, tag.name, tag.attrs);
                if (shouldFosterParentStartTag(&stack, tag.name)) {
                    fosterParentInsert(&stack, node);
                } else {
                    appendChild(currentParent(&stack), node);
                }
                if (!tag.self_closing and !isVoidTag(tag.name)) {
                    try stack.append(arena, node);
                }
            },
            .end_tag => |name| popUntilTag(&stack, name),
            .eof => break,
        }
    }

    return .{
        .root = html,
        .html = html,
        .body = body,
    };
}

fn currentParent(stack: *const std.ArrayList(*dom.Node)) *dom.Node {
    return stack.items[stack.items.len - 1];
}

fn maybeImplicitClose(stack: *std.ArrayList(*dom.Node), incoming_tag: []const u8) !void {
    if (stack.items.len < 2) return;
    const top = stack.items[stack.items.len - 1];
    const top_tag = switch (top.kind) {
        .element => |el| el.tag_name,
        else => return,
    };

    if ((std.mem.eql(u8, incoming_tag, "p") and std.mem.eql(u8, top_tag, "p")) or
        (std.mem.eql(u8, incoming_tag, "li") and std.mem.eql(u8, top_tag, "li")) or
        ((std.mem.eql(u8, incoming_tag, "dt") or std.mem.eql(u8, incoming_tag, "dd")) and
            (std.mem.eql(u8, top_tag, "dt") or std.mem.eql(u8, top_tag, "dd"))))
    {
        _ = stack.pop();
    }
}

fn popUntilTag(stack: *std.ArrayList(*dom.Node), end_tag: []const u8) void {
    if (stack.items.len <= 2) return;
    var i: usize = stack.items.len - 1;
    while (i >= 2) : (i -= 1) {
        const n = stack.items[i];
        const name = switch (n.kind) {
            .element => |el| el.tag_name,
            else => continue,
        };
        if (std.mem.eql(u8, name, end_tag)) {
            while (stack.items.len > i) {
                _ = stack.pop();
            }
            return;
        }
        if (i == 2) break;
    }
}

fn isVoidTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "br") or
        std.mem.eql(u8, tag, "img") or
        std.mem.eql(u8, tag, "hr") or
        std.mem.eql(u8, tag, "meta") or
        std.mem.eql(u8, tag, "link") or
        std.mem.eql(u8, tag, "input");
}

fn appendChild(parent: *dom.Node, child: *dom.Node) void {
    child.parent = parent;
    if (parent.first_child == null) {
        parent.first_child = child;
        return;
    }
    var last = parent.first_child.?;
    while (last.next_sibling) |next| {
        last = next;
    }
    last.next_sibling = child;
}

fn insertBefore(parent: *dom.Node, reference: *dom.Node, child: *dom.Node) void {
    child.parent = parent;
    if (parent.first_child == null or parent.first_child.? == reference) {
        child.next_sibling = reference;
        parent.first_child = child;
        return;
    }

    var cursor = parent.first_child.?;
    while (cursor.next_sibling) |next| {
        if (next == reference) {
            cursor.next_sibling = child;
            child.next_sibling = reference;
            return;
        }
        cursor = next;
    }

    // Reference wasn't found among parent's children; append as a safe fallback.
    appendChild(parent, child);
}

fn fosterParentInsert(stack: *std.ArrayList(*dom.Node), node: *dom.Node) void {
    var i = stack.items.len;
    while (i > 0) : (i -= 1) {
        const candidate = stack.items[i - 1];
        if (candidate.kind != .element) continue;
        const tag = candidate.kind.element.tag_name;
        if (std.mem.eql(u8, tag, "table")) {
            if (candidate.parent) |p| {
                insertBefore(p, candidate, node);
                return;
            }
        }
    }
    appendChild(currentParent(stack), node);
}

fn shouldFosterParentCharacter(stack: *const std.ArrayList(*dom.Node), text: []const u8) bool {
    if (!isInTableInsertionContext(stack)) return false;
    for (text) |ch| {
        if (!std.ascii.isWhitespace(ch)) return true;
    }
    return false;
}

fn shouldFosterParentStartTag(stack: *const std.ArrayList(*dom.Node), tag: []const u8) bool {
    if (!isInTableInsertionContext(stack)) return false;
    return !isTableStructuralTag(tag);
}

fn isInTableInsertionContext(stack: *const std.ArrayList(*dom.Node)) bool {
    if (stack.items.len == 0) return false;
    const top = stack.items[stack.items.len - 1];
    if (top.kind != .element) return false;
    const tag = top.kind.element.tag_name;
    return std.mem.eql(u8, tag, "table") or
        std.mem.eql(u8, tag, "tbody") or
        std.mem.eql(u8, tag, "tfoot") or
        std.mem.eql(u8, tag, "thead") or
        std.mem.eql(u8, tag, "tr");
}

fn isTableStructuralTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "table") or
        std.mem.eql(u8, tag, "caption") or
        std.mem.eql(u8, tag, "colgroup") or
        std.mem.eql(u8, tag, "col") or
        std.mem.eql(u8, tag, "tbody") or
        std.mem.eql(u8, tag, "thead") or
        std.mem.eql(u8, tag, "tfoot") or
        std.mem.eql(u8, tag, "tr") or
        std.mem.eql(u8, tag, "td") or
        std.mem.eql(u8, tag, "th");
}

fn createElement(arena: std.mem.Allocator, tag_name: []const u8, attrs: []const dom.Attribute) !*dom.Node {
    const node = try arena.create(dom.Node);
    const name = try arena.dupe(u8, tag_name);
    const attrs_copy = try arena.dupe(dom.Attribute, attrs);
    node.* = .{
        .kind = .{
            .element = .{
                .tag_name = name,
                .attributes = attrs_copy,
            },
        },
    };
    return node;
}

fn createText(arena: std.mem.Allocator, text: []const u8) !*dom.Node {
    const node = try arena.create(dom.Node);
    node.* = .{
        .kind = .{ .text = try arena.dupe(u8, text) },
    };
    return node;
}

fn createComment(arena: std.mem.Allocator, text: []const u8) !*dom.Node {
    const node = try arena.create(dom.Node);
    node.* = .{
        .kind = .{ .comment = try arena.dupe(u8, text) },
    };
    return node;
}

fn createDoctype(arena: std.mem.Allocator, name: []const u8) !*dom.Node {
    const node = try arena.create(dom.Node);
    node.* = .{
        .kind = .{ .doctype = try arena.dupe(u8, name) },
    };
    return node;
}

fn firstElementByTag(root: *dom.Node, tag: []const u8) ?*dom.Node {
    var stack = std.ArrayList(*dom.Node).initCapacity(std.heap.page_allocator, 16) catch return null;
    defer stack.deinit(std.heap.page_allocator);
    stack.append(std.heap.page_allocator, root) catch return null;
    while (stack.pop()) |n| {
        if (n.kind == .element and std.mem.eql(u8, n.kind.element.tag_name, tag)) return n;
        if (n.next_sibling) |sib| stack.append(std.heap.page_allocator, sib) catch return null;
        if (n.first_child) |child| stack.append(std.heap.page_allocator, child) catch return null;
    }
    return null;
}

fn walkAll(root: *dom.Node, f: *const fn (*dom.Node) anyerror!void) !void {
    try f(root);
    if (root.first_child) |child| try walkAll(child, f);
    if (root.next_sibling) |sib| try walkAll(sib, f);
}

const CuratedTreeCase = struct {
    name: []const u8,
    input: []const u8,
    required_tags: []const []const u8,
};

const CuratedTreeSuite = struct {
    version: u32,
    suite: []const u8,
    cases: []CuratedTreeCase,
};

fn loadCuratedTreeSuite(arena: std.mem.Allocator) !std.json.Parsed(CuratedTreeSuite) {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "tests/html5lib/tree_construction_curated.json",
        arena,
        .limited(1024 * 1024),
    );
    return std.json.parseFromSlice(CuratedTreeSuite, arena, raw, .{ .allocate = .alloc_always });
}

test "cycle 2.3 script captured raw and trailing paragraph parses" {
    const spy_mod = @import("spy_engine");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var spy = spy_mod.SpyScriptEngine.init(std.testing.allocator);
    defer spy.deinit();

    const spy_vtable = script_mod.ScriptEngine.VTable{
        .stopScript = spy_mod.SpyScriptEngine.stopScript,
        .severHandles = spy_mod.SpyScriptEngine.severHandles,
        .drainFinalizers = spy_mod.SpyScriptEngine.drainFinalizers,
        .teardownIsolate = spy_mod.SpyScriptEngine.teardownIsolate,
        .runScript = spy_mod.SpyScriptEngine.runScript,
        .pumpMicrotasks = spy_mod.SpyScriptEngine.pumpMicrotasks,
    };
    const spy_engine = script_mod.ScriptEngine{
        .ptr = @ptrCast(&spy),
        .vtable = &spy_vtable,
    };

    const res = try parseDocument(arena, "<script>let x=1<p></script><p>after</p>", spy_engine);
    const script = firstElementByTag(res.root, "script") orelse return error.TestExpectedEqual;
    const script_text_node = script.first_child orelse return error.TestExpectedEqual;
    switch (script_text_node.kind) {
        .text => |txt| try std.testing.expectEqualStrings("let x=1<p>", txt),
        else => return error.TestExpectedEqual,
    }

    const p = firstElementByTag(res.root, "p") orelse return error.TestExpectedEqual;
    const p_text = p.first_child orelse return error.TestExpectedEqual;
    switch (p_text.kind) {
        .text => |txt| try std.testing.expectEqualStrings("after", txt),
        else => return error.TestExpectedEqual,
    }

    for (spy.calls.items) |step| {
        try std.testing.expect(step != .run_script);
    }
}

test "cycle 2.4 implicit close and implied containers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseDocument(arena, "<p>Hi<b>x", null);
    try std.testing.expectEqualStrings("html", res.html.kind.element.tag_name);
    try std.testing.expectEqualStrings("body", res.body.kind.element.tag_name);

    const p = firstElementByTag(res.root, "p") orelse return error.TestExpectedEqual;
    const p_text = p.first_child orelse return error.TestExpectedEqual;
    switch (p_text.kind) {
        .text => |txt| try std.testing.expectEqualStrings("Hi", txt),
        else => return error.TestExpectedEqual,
    }
    const b = p_text.next_sibling orelse return error.TestExpectedEqual;
    switch (b.kind) {
        .element => |el| try std.testing.expectEqualStrings("b", el.tag_name),
        else => return error.TestExpectedEqual,
    }
}

test "cycle 2.5 misnest recovery subset preserves nested formatting nodes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseDocument(arena, "<b><i></b></i>", null);
    const b = firstElementByTag(res.root, "b") orelse return error.TestExpectedEqual;
    const i = firstElementByTag(b, "i") orelse return error.TestExpectedEqual;
    _ = i;
}

test "phase 2 conformance: foster parenting moves stray table text before table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseDocument(arena, "<table>1</table>", null);
    const first = res.body.first_child orelse return error.TestExpectedEqual;
    switch (first.kind) {
        .text => |txt| try std.testing.expectEqualStrings("1", txt),
        else => return error.TestExpectedEqual,
    }
    const second = first.next_sibling orelse return error.TestExpectedEqual;
    switch (second.kind) {
        .element => |el| try std.testing.expectEqualStrings("table", el.tag_name),
        else => return error.TestExpectedEqual,
    }
}

test "phase 2 conformance: foster parenting moves non-structural tags before table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseDocument(arena, "<table><b>x</b></table>", null);
    const first = res.body.first_child orelse return error.TestExpectedEqual;
    switch (first.kind) {
        .element => |el| try std.testing.expectEqualStrings("b", el.tag_name),
        else => return error.TestExpectedEqual,
    }
    const b_text = first.first_child orelse return error.TestExpectedEqual;
    switch (b_text.kind) {
        .text => |txt| try std.testing.expectEqualStrings("x", txt),
        else => return error.TestExpectedEqual,
    }
    const second = first.next_sibling orelse return error.TestExpectedEqual;
    switch (second.kind) {
        .element => |el| try std.testing.expectEqualStrings("table", el.tag_name),
        else => return error.TestExpectedEqual,
    }
}

test "phase 2 conformance: curated misnest adoption subset remains stable" {
    const Case = struct {
        input: []const u8,
        required_outer: []const u8,
        required_inner: []const u8,
    };
    const cases = [_]Case{
        .{ .input = "<b><i>z</b>t</i>", .required_outer = "b", .required_inner = "i" },
        .{ .input = "<i><b>x</i>y</b>", .required_outer = "i", .required_inner = "b" },
        .{ .input = "<p><b>x</p>y</b>", .required_outer = "p", .required_inner = "b" },
    };

    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const res = try parseDocument(arena, case.input, null);
        const outer = firstElementByTag(res.root, case.required_outer) orelse return error.TestExpectedEqual;
        const inner = firstElementByTag(outer, case.required_inner) orelse return error.TestExpectedEqual;
        _ = inner;
    }
}

test "phase 2 conformance: html5lib curated suite required tags all present" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed_suite = try loadCuratedTreeSuite(arena);
    defer parsed_suite.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed_suite.value.version);
    try std.testing.expectEqualStrings("tree-construction-curated", parsed_suite.value.suite);

    for (parsed_suite.value.cases) |case| {
        const res = try parseDocument(arena, case.input, null);
        for (case.required_tags) |required_tag| {
            const node = firstElementByTag(res.root, required_tag) orelse {
                std.log.err("missing required tag '{s}' in case '{s}'", .{ required_tag, case.name });
                return error.TestExpectedEqual;
            };
            _ = node;
        }
    }
}

test "phase 2 conformance: implicit close for li siblings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseDocument(arena, "<ul><li>one<li>two</ul>", null);
    const ul = firstElementByTag(res.root, "ul") orelse return error.TestExpectedEqual;
    const li1 = ul.first_child orelse return error.TestExpectedEqual;
    const li2 = li1.next_sibling orelse return error.TestExpectedEqual;
    try std.testing.expect(li2.next_sibling == null);
    switch (li1.kind) {
        .element => |el| try std.testing.expectEqualStrings("li", el.tag_name),
        else => return error.TestExpectedEqual,
    }
    switch ((li1.first_child orelse return error.TestExpectedEqual).kind) {
        .text => |txt| try std.testing.expectEqualStrings("one", txt),
        else => return error.TestExpectedEqual,
    }
    switch ((li2.first_child orelse return error.TestExpectedEqual).kind) {
        .text => |txt| try std.testing.expectEqualStrings("two", txt),
        else => return error.TestExpectedEqual,
    }
}

test "phase 2 conformance: implicit close for dt and dd siblings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseDocument(arena, "<dl><dt>a<dd>b<dt>c</dl>", null);
    const dl = firstElementByTag(res.root, "dl") orelse return error.TestExpectedEqual;

    const n1 = dl.first_child orelse return error.TestExpectedEqual;
    const n2 = n1.next_sibling orelse return error.TestExpectedEqual;
    const n3 = n2.next_sibling orelse return error.TestExpectedEqual;
    try std.testing.expect(n3.next_sibling == null);

    switch (n1.kind) {
        .element => |el| try std.testing.expectEqualStrings("dt", el.tag_name),
        else => return error.TestExpectedEqual,
    }
    switch (n2.kind) {
        .element => |el| try std.testing.expectEqualStrings("dd", el.tag_name),
        else => return error.TestExpectedEqual,
    }
    switch (n3.kind) {
        .element => |el| try std.testing.expectEqualStrings("dt", el.tag_name),
        else => return error.TestExpectedEqual,
    }
}

test "phase 2 conformance: whitespace inside table context is not foster parented" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseDocument(arena, "<table> \n</table>", null);
    const first = res.body.first_child orelse return error.TestExpectedEqual;
    switch (first.kind) {
        .element => |el| try std.testing.expectEqualStrings("table", el.tag_name),
        else => return error.TestExpectedEqual,
    }
    const table_text = first.first_child orelse return error.TestExpectedEqual;
    switch (table_text.kind) {
        .text => |txt| try std.testing.expectEqualStrings(" \n", txt),
        else => return error.TestExpectedEqual,
    }
}

test "phase 2 conformance: non-whitespace character in tr context is foster parented" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseDocument(arena, "<table><tr>x<td>1</td></tr></table>", null);
    const first = res.body.first_child orelse return error.TestExpectedEqual;
    switch (first.kind) {
        .text => |txt| try std.testing.expectEqualStrings("x", txt),
        else => return error.TestExpectedEqual,
    }
    const second = first.next_sibling orelse return error.TestExpectedEqual;
    switch (second.kind) {
        .element => |el| try std.testing.expectEqualStrings("table", el.tag_name),
        else => return error.TestExpectedEqual,
    }
}

test "cycle 2.6 every node kind has null script wrapper slot" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try parseDocument(arena, "<!doctype html><!--note--><p>txt</p>", null);

    const Checker = struct {
        var saw_element: bool = false;
        var saw_text: bool = false;
        var saw_comment: bool = false;
        var saw_doctype: bool = false;

        pub fn checkNode(node: *dom.Node) !void {
            try std.testing.expect(node.script_wrapper == null);
            switch (node.kind) {
                .element => saw_element = true,
                .text => saw_text = true,
                .comment => saw_comment = true,
                .doctype => saw_doctype = true,
            }
        }
    };

    try walkAll(res.root, Checker.checkNode);
    try std.testing.expect(Checker.saw_element);
    try std.testing.expect(Checker.saw_text);
    try std.testing.expect(Checker.saw_comment);
    try std.testing.expect(Checker.saw_doctype);
}
