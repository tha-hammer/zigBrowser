test "track-c module reachability hooks" {
    _ = @import("css/cascade.zig");
    _ = @import("layout/block.zig");
    _ = @import("layout/inline.zig");
    _ = @import("layout/float.zig");
    _ = @import("paint/display_list.zig");
    _ = @import("paint/pipeline_integration.zig");
    _ = @import("paint/raster.zig");
    _ = @import("paint/snapshot_gate.zig");
    _ = @import("paint/text.zig");
    _ = @import("platform/window.zig");
    _ = @import("platform/event_loop.zig");
    _ = @import("image/decode.zig");
}
