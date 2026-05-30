const std = @import("std");

const test_targets = [_]std.Target.Query{
    .{},
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const curl_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/net/c_headers.h"),
        .target = target,
        .optimize = optimize,
    });
    const curl_c_module = curl_translate.createModule();

    const curl_object: std.Build.LazyPath = .{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/libcurl.so.4" };

    const browser_module = b.addModule("zigBrowser", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "curl_c", .module = curl_c_module },
        },
        .link_libc = true,
    });
    browser_module.addObjectFile(curl_object);

    const exe = b.addExecutable(.{
        .name = "zigBrowser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigBrowser", .module = browser_module },
                .{ .name = "curl_c", .module = curl_c_module },
            },
            .link_libc = true,
        }),
    });
    exe.root_module.addObjectFile(curl_object);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the browser executable");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const test_step = b.step("test", "Run tests");
    for (test_targets) |query| {
        const test_target = b.resolveTargetQuery(query);
        const suite = addTestSuite(b, test_target, optimize, curl_c_module);
        const run_suite = b.addRunArtifact(suite);
        run_suite.skip_foreign_checks = true;
        test_step.dependOn(&run_suite.step);
    }
}

fn addTestSuite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    curl_c_module: *std.Build.Module,
) *std.Build.Step.Compile {
    const curl_object: std.Build.LazyPath = .{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/libcurl.so.4" };
    const fixture_static = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/static_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fixture_tls = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/tls_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fixture_blackhole = b.createModule(.{
        .root_source_file = b.path("tests/fixtures/blackhole_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spy_engine = b.createModule(.{
        .root_source_file = b.path("tests/spies/spy_engine.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "curl_c", .module = curl_c_module },
            .{ .name = "fixture_static", .module = fixture_static },
            .{ .name = "fixture_tls", .module = fixture_tls },
            .{ .name = "fixture_blackhole", .module = fixture_blackhole },
            .{ .name = "spy_engine", .module = spy_engine },
        },
        .link_libc = true,
    });
    test_root.addObjectFile(curl_object);

    return b.addTest(.{
        .root_module = test_root,
    });
}
