const std = @import("std");
const Backend = enum {
    gtk_backend,
    webview2_backend,
};

const WebView2Paths = struct {
    include_dir: []const u8,
    lib_dir: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = resolveBackend(target);
    const webview2_include = b.option(
        []const u8,
        "webview2_include",
        "Directory containing WebView2.h (or set WEBVIEW2_INCLUDE)",
    );
    const webview2_lib = b.option(
        []const u8,
        "webview2_lib",
        "Directory containing WebView2LoaderStatic.lib (or set WEBVIEW2_LIB)",
    );
    const webview2_paths: ?WebView2Paths = if (backend == .webview2_backend)
        .{
            .include_dir = webview2_include orelse envOrPanic(b, "WEBVIEW2_INCLUDE"),
            .lib_dir = webview2_lib orelse envOrPanic(b, "WEBVIEW2_LIB"),
        }
    else
        null;

    const pkg_guard = switch (backend) {
        .gtk_backend => b.addSystemCommand(&.{
            "sh",
            "-c",
            "pkg-config --exists webkit2gtk-4.1 gtk+-3.0 || { echo 'ERROR: missing required packages: webkit2gtk-4.1 gtk+-3.0 (install libwebkit2gtk-4.1-dev libgtk-3-dev)' >&2; exit 1; }",
        }),
        .webview2_backend => webView2PkgGuard(b, webview2_paths.?),
    };

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    configureBackend(root_module, b, backend, webview2_paths);

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
    configureBackend(test_module, b, backend, webview2_paths);

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

    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
    });
    const ipc_windows_compile_module = b.createModule(.{
        .root_source_file = b.path("src/ipc.zig"),
        .target = windows_target,
        .optimize = optimize,
    });
    const ipc_windows_compile = b.addTest(.{ .root_module = ipc_windows_compile_module });
    const ipc_windows_step = b.step("ipc-test-win", "Compile backend-free IPC module for x86_64-windows");
    ipc_windows_step.dependOn(&ipc_windows_compile.step);

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
    test_step.dependOn(&ipc_windows_compile.step);
}

fn resolveBackend(target: std.Build.ResolvedTarget) Backend {
    return switch (target.result.os.tag) {
        .linux => .gtk_backend,
        .windows => .webview2_backend,
        else => std.debug.panic("NoBackendLinked: no backend for target os '{s}'", .{@tagName(target.result.os.tag)}),
    };
}

fn configureBackend(
    module: *std.Build.Module,
    b: *std.Build,
    backend: Backend,
    webview2_paths: ?WebView2Paths,
) void {
    switch (backend) {
        .gtk_backend => configureGtkBackend(module, b),
        .webview2_backend => configureWebView2Backend(module, b, webview2_paths.?),
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

fn configureWebView2Backend(module: *std.Build.Module, b: *std.Build, paths: WebView2Paths) void {
    module.addIncludePath(b.path("src"));
    module.addSystemIncludePath(.{ .cwd_relative = paths.include_dir });
    module.addLibraryPath(.{ .cwd_relative = paths.lib_dir });
    module.addCSourceFile(.{
        .file = b.path("src/webview2_shim.cpp"),
        .flags = &.{"-std=c++17"},
    });

    module.linkSystemLibrary("WebView2LoaderStatic", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("ole32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("oleaut32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("user32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("gdi32", .{ .use_pkg_config = .no });
    module.linkSystemLibrary("shell32", .{ .use_pkg_config = .no });
}

fn envOrPanic(b: *std.Build, name: []const u8) []const u8 {
    return b.graph.environ_map.get(name) orelse
        std.debug.panic("missing {s}; pass -Dwebview2_include/-Dwebview2_lib or set WEBVIEW2_INCLUDE/WEBVIEW2_LIB", .{name});
}

fn webView2PkgGuard(b: *std.Build, paths: WebView2Paths) *std.Build.Step.Run {
    const script = b.fmt(
        "if not exist \"{s}\\WebView2.h\" (echo ERROR: missing WebView2.h under {s} 1>&2 & exit /b 1) else if not exist \"{s}\\WebView2LoaderStatic.lib\" (echo ERROR: missing WebView2LoaderStatic.lib under {s} 1>&2 & exit /b 1)",
        .{ paths.include_dir, paths.include_dir, paths.lib_dir, paths.lib_dir },
    );
    return b.addSystemCommand(&.{ "cmd.exe", "/C", script });
}
