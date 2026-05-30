pub const Combinator = enum { descendant, child, adjacent };

pub const SimpleSelector = union(enum) {
    type_sel: []const u8,
    class: []const u8,
    id: []const u8,
    pseudo: []const u8,
    universal,
};

pub const SelectorPart = struct {
    simple: []SimpleSelector,
    combinator: ?Combinator,
};

pub const Declaration = struct {
    name: []const u8,
    value: []const u8,
};

pub const Rule = struct {
    selectors: [][]SelectorPart,
    decls: []Declaration,
};
