//! A startup switch set by a command-line flag or an environment variable:
//! the flag wins, then the variable, then the built-in default. A variable
//! that names no value of `T` is reported (`bad_env`) and the default is
//! used. Shared by media_config.zig and agent_config.zig.
const std = @import("std");

pub fn Switch(comptime T: type, comptime default: T) type {
    return struct {
        /// Command-line or environment text -> T (exactly a tag name of T).
        pub fn parse(text: []const u8) ?T {
            return std.meta.stringToEnum(T, text);
        }

        pub const Resolved = struct {
            value: T,
            /// The variable's value when it was consulted and names no value
            /// of T (the default is used, and startup says so).
            bad_env: ?[]const u8 = null,
        };

        /// The effective setting. `env`: the variable's value (null: unset).
        pub fn resolve(flag: ?T, env: ?[]const u8) Resolved {
            if (flag) |value| return .{ .value = value };
            const text = env orelse return .{ .value = default };
            if (parse(text)) |value| return .{ .value = value };
            return .{ .value = default, .bad_env = text };
        }
    };
}
