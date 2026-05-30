pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const WrapperRef = struct {
    index: u32,
    generation: u32,
};

pub const Node = struct {
    kind: Kind,
    parent: ?*Node = null,
    first_child: ?*Node = null,
    next_sibling: ?*Node = null,
    script_wrapper: ?WrapperRef = null,

    pub const Kind = union(enum) {
        element: Element,
        text: []const u8,
        comment: []const u8,
        doctype: []const u8,
    };
};

pub const Element = struct {
    tag_name: []const u8,
    attributes: []Attribute,
};
