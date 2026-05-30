const std = @import("std");
const errors = @import("../errors.zig");
const origin_mod = @import("../security/origin.zig");

pub const StoreError = errors.StoreError;
pub const Origin = origin_mod.Origin;

pub const Store = struct {
    allocator: std.mem.Allocator,
    origin: Origin,
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator, origin: Origin) Store {
        return .{
            .allocator = allocator,
            .origin = origin,
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        self.map.deinit();
    }

    pub fn get(self: *Store, origin: Origin, key: []const u8) StoreError!?[]const u8 {
        if (!origin_mod.eql(self.origin, origin)) return error.CrossOriginDenied;
        return self.map.get(key);
    }

    pub fn set(self: *Store, origin: Origin, key: []const u8, val: []const u8) (StoreError || std.mem.Allocator.Error)!void {
        if (!origin_mod.eql(self.origin, origin)) return error.CrossOriginDenied;
        try self.map.put(key, val);
    }

    pub fn delete(self: *Store, origin: Origin, key: []const u8) void {
        if (!origin_mod.eql(self.origin, origin)) return;
        _ = self.map.remove(key);
    }
};

test "origin-keyed store denies cross-origin read and returns null for missing key" {
    const allocator = std.testing.allocator;
    const origin_a = Origin{ .scheme = "https", .host = "a.example", .port = 443 };
    const origin_b = Origin{ .scheme = "https", .host = "b.example", .port = 443 };

    var store = Store.init(allocator, origin_a);
    defer store.deinit();

    try std.testing.expectError(error.CrossOriginDenied, store.get(origin_b, "k"));
    try std.testing.expect((try store.get(origin_a, "missing")) == null);

    try store.set(origin_a, "k", "v");
    try std.testing.expectEqualStrings("v", (try store.get(origin_a, "k")).?);
}
