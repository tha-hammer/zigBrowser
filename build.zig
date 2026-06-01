const std = @import("std");
const Backend = enum {
    gtk_backend,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = resolveBackend(target);

    const pkg_guard = switch (backend) {
        .gtk_backend => b.addSystemCommand(&.{
            "sh",
            "-c",
            "pkg-config --exists webkit2gtk-4.1 gtk+-3.0 || { echo 'ERROR: missing required packages: webkit2gtk-4.1 gtk+-3.0 (install libwebkit2gtk-4.1-dev libgtk-3-dev)' >&2; exit 1; }",
        }),
    };

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureBackend(root_module, b, backend);

    const exe = b.addExecutable(.{
        .name = "zigBrowser",
        .root_module = root_module,
    });
    exe.step.dependOn(&pkg_guard.step);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run zigBrowser");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(&pkg_guard.step);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureBackend(test_module, b, backend);

    const unit_tests = b.addTest(.{ .root_module = test_module });
    unit_tests.step.dependOn(&pkg_guard.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.skip_foreign_checks = true;

    const ipc_module = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const ipc_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/ipc_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    ipc_tests_module.addImport("ipc", ipc_module);
    const ipc_tests = b.addTest(.{ .root_module = ipc_tests_module });
    const run_ipc_tests = b.addRunArtifact(ipc_tests);
    run_ipc_tests.skip_foreign_checks = true;

    const nav_policy_module = b.createModule(.{
        .root_source_file = b.path("src/nav_policy.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const nav_policy_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/nav_policy_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nav_policy_tests_module.addImport("nav_policy", nav_policy_module);
    const nav_policy_tests = b.addTest(.{ .root_module = nav_policy_tests_module });
    const run_nav_policy_tests = b.addRunArtifact(nav_policy_tests);
    run_nav_policy_tests.skip_foreign_checks = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_ipc_tests.step);
    test_step.dependOn(&run_nav_policy_tests.step);
}

fn resolveBackend(target: std.Build.ResolvedTarget) Backend {
    return switch (target.result.os.tag) {
        .linux => .gtk_backend,
        else => std.debug.panic("NoBackendLinked: no backend for target os '{s}'", .{@tagName(target.result.os.tag)}),
    };
}

fn configureBackend(module: *std.Build.Module, b: *std.Build, backend: Backend) void {
    switch (backend) {
        .gtk_backend => configureGtkBackend(module, b),
    }
}

fn configureGtkBackend(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("src"));
    module.addCSourceFile(.{
        .file = b.path("src/webkit_shim.c"),
        .flags = &.{"-std=c11"},
    });

    module.linkSystemLibrary("webkit2gtk-4.1", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("gio-unix-2.0", .{ .use_pkg_config = .force });
}
