const cascade = @import("css/cascade.zig");
const layout_box = @import("layout/box.zig");

// Aggregates Track C tests behind a single stable root import.
test {
    _ = cascade.ComputedStyle;
    _ = layout_box.Box;
}
