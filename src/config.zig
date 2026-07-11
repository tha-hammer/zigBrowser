//! Thin facade over the build-time generated `build_options` module.
//! Only this file knows about `build_options`; the rest of the source tree
//! depends on `config.zig` so the build-system seam stays isolated.
const build_options = @import("build_options");

pub const default_url: []const u8 = build_options.default_url;
pub const config_path: []const u8 = build_options.config_path;

comptime {
    if (default_url.len == 0) {
        @compileError("build_options.default_url must not be empty");
    }
}
