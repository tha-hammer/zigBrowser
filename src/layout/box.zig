const dom = @import("../html/dom.zig");

pub const ImageRef = struct {
    width: u32 = 0,
    height: u32 = 0,
    bytes: []const u8 = &.{},
};

pub const LineBox = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Box = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    content: Content,
    source: ?*const dom.Node,

    pub const Content = union(enum) {
        block: []Box,
        line: []LineBox,
        replaced: ImageRef,
    };
};
