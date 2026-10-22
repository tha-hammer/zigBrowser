//! bd zigBrowser-4pa.63: the root of every Darwin cross-compile guard (build.zig `darwinGuardObject`). Zig analyses
//! lazily: an object built from a module's own file analyses only what is exported or referenced, so a Darwin-only
//! error in any other function never shows. This root references every public declaration of the guarded module,
//! recursively through its public container types, so the body of each non-generic function is analysed for the
//! guard's target. A generic function (comptime or anytype parameters) has no body to analyse until a caller
//! instantiates it; those stay outside the guard. `std.testing.refAllDecls` cannot do this: it returns at once
//! outside a test build.
const std = @import("std");
const guarded = @import("guarded");

comptime {
    refAll(guarded);
}

fn refAll(comptime T: type) void {
    @setEvalBranchQuota(100_000);
    inline for (comptime std.meta.declarations(T)) |decl| {
        const value = @field(T, decl.name);
        const V = @TypeOf(value);
        if (V == type) {
            switch (@typeInfo(value)) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAll(value),
                else => {},
            }
        } else if (@typeInfo(V) == .@"fn") {
            if (!@typeInfo(V).@"fn".is_generic) _ = &@field(T, decl.name);
        } else {
            _ = &@field(T, decl.name);
        }
    }
}
