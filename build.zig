const std = @import("std");

const test_targets = [_]std.Target.Query{
    .{},
};

const curl_object: std.Build.LazyPath = .{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/libcurl.so.4" };

const TestSupportSpec = struct {
    name: []const u8,
    path: []const u8,
};

const root_test_support_specs = [_]TestSupportSpec{
    .{ .name = "fixture_static", .path = "tests/fixtures/static_server.zig" },
    .{ .name = "fixture_tls", .path = "tests/fixtures/tls_server.zig" },
    .{ .name = "fixture_blackhole", .path = "tests/fixtures/blackhole_server.zig" },
    .{ .name = "spy_engine", .path = "tests/spies/spy_engine.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const browser_module = createBrowserModule(b, target, optimize);

    const exe = b.addExecutable(.{
        .name = "zigBrowser",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigBrowser", .module = browser_module },
                .{ .name = "curl_c", .module = createCurlModule(b, target, optimize) },
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

        const root_suite = buildRootTestSuite(b, test_target, optimize);
        const run_root = b.addRunArtifact(root_suite);
        run_root.skip_foreign_checks = true;
        test_step.dependOn(&run_root.step);

        const harness_suite = buildHarnessTestSuite(b, test_target, optimize);
        const run_harness = b.addRunArtifact(harness_suite);
        run_harness.skip_foreign_checks = true;
        test_step.dependOn(&run_harness.step);
    }
}

fn createCurlModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const curl_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/net/c_headers.h"),
        .target = target,
        .optimize = optimize,
    });
    return curl_translate.createModule();
}

fn createBrowserModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const curl_c_module = createCurlModule(b, target, optimize);

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
    return browser_module;
}

fn buildRootTestSuite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const curl_c_module = createCurlModule(b, target, optimize);
    const browser_module = createBrowserModule(b, target, optimize);

    var support_modules: [root_test_support_specs.len]*std.Build.Module = undefined;
    inline for (root_test_support_specs, 0..) |spec, idx| {
        support_modules[idx] = b.createModule(.{
            .root_source_file = b.path(spec.path),
            .target = target,
            .optimize = optimize,
        });
    }

    var imports: [2 + root_test_support_specs.len]std.Build.Module.Import = undefined;
    imports[0] = .{ .name = "zigBrowser", .module = browser_module };
    imports[1] = .{ .name = "curl_c", .module = curl_c_module };
    inline for (root_test_support_specs, 0..) |spec, idx| {
        imports[idx + 2] = .{ .name = spec.name, .module = support_modules[idx] };
    }

    const test_root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
        .link_libc = true,
    });
    test_root.addObjectFile(curl_object);

    return b.addTest(.{ .root_module = test_root });
}

fn buildHarnessTestSuite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const harness_root = b.createModule(.{
        .root_source_file = b.path("tests/harness/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    return b.addTest(.{ .root_module = harness_root });
}
