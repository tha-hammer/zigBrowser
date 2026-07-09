const std = @import("std");
const Backend = enum {
    gtk_backend,
    webview2_backend,
    macos_backend,
};

const WebView2Paths = struct {
    include_dir: ?[]const u8,
    winrt_include_dir: ?[]const u8,
    lib_dir: ?[]const u8,
};

const CheckWebView2SdkStep = struct {
    step: std.Build.Step,
    include_dir: ?[]const u8,
    winrt_include_dir: ?[]const u8,
    lib_dir: ?[]const u8,

    fn create(b: *std.Build, paths: WebView2Paths) *CheckWebView2SdkStep {
        const self = b.allocator.create(CheckWebView2SdkStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "check WebView2 SDK",
                .owner = b,
                .makeFn = make,
            }),
            .include_dir = paths.include_dir,
            .winrt_include_dir = paths.winrt_include_dir,
            .lib_dir = paths.lib_dir,
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const self: *CheckWebView2SdkStep = @fieldParentPtr("step", step);

        const include_dir = self.include_dir orelse {
            try fail(step, "missing WebView2 include directory; pass -Dwebview2_include=<dir> or set WEBVIEW2_INCLUDE");
            return error.MakeFailed;
        };
        const lib_dir = self.lib_dir orelse {
            try fail(step, "missing WebView2 library directory; pass -Dwebview2_lib=<dir> or set WEBVIEW2_LIB");
            return error.MakeFailed;
        };
        const winrt_include_dir = self.winrt_include_dir orelse {
            try fail(step, "missing WinRT include directory; pass -Dwinrt_include=<dir> or set WINRT_INCLUDE");
            return error.MakeFailed;
        };

        const header_path = step.owner.fmt("{s}/WebView2.h", .{include_dir});
        std.Io.Dir.cwd().access(step.owner.graph.io, header_path, .{}) catch {
            try fail(step, step.owner.fmt("missing WebView2.h at {s}", .{header_path}));
            return error.MakeFailed;
        };

        const loader_path = step.owner.fmt("{s}/WebView2LoaderStatic.lib", .{lib_dir});
        std.Io.Dir.cwd().access(step.owner.graph.io, loader_path, .{}) catch {
            try fail(step, step.owner.fmt("missing WebView2LoaderStatic.lib at {s}", .{loader_path}));
            return error.MakeFailed;
        };

        const wrl_path = step.owner.fmt("{s}/wrl.h", .{winrt_include_dir});
        std.Io.Dir.cwd().access(step.owner.graph.io, wrl_path, .{}) catch {
            try fail(step, step.owner.fmt("missing wrl.h at {s}", .{wrl_path}));
            return error.MakeFailed;
        };
    }

    fn fail(step: *std.Build.Step, message: []const u8) !void {
        try step.result_error_msgs.append(step.owner.allocator, message);
    }
};

const CheckMacosBackendStep = struct {
    step: std.Build.Step,

    fn create(b: *std.Build) *CheckMacosBackendStep {
        const self = b.allocator.create(CheckMacosBackendStep) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "check macOS WKWebView backend",
                .owner = b,
                .makeFn = make,
            }),
        };
        return self;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        std.Io.Dir.cwd().access(step.owner.graph.io, "src/wkwebview_shim.m", .{}) catch {
            try step.result_error_msgs.append(
                step.owner.allocator,
                "missing wkwebview_shim.m at src/wkwebview_shim.m; macOS backend selected but the WKWebView shim has not landed",
            );
            return error.MakeFailed;
        };
    }
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
    const winrt_include = b.option(
        []const u8,
        "winrt_include",
        "Directory containing wrl.h (or set WINRT_INCLUDE)",
    );
    const webview2_paths: WebView2Paths = .{
        .include_dir = webview2_include orelse b.graph.environ_map.get("WEBVIEW2_INCLUDE"),
        .winrt_include_dir = winrt_include orelse b.graph.environ_map.get("WINRT_INCLUDE"),
        .lib_dir = webview2_lib orelse b.graph.environ_map.get("WEBVIEW2_LIB"),
    };

    const pkg_guard: *std.Build.Step = switch (backend) {
        .gtk_backend => &b.addSystemCommand(&.{
            "sh",
            "-c",
            "pkg-config --exists webkit2gtk-4.1 gtk+-3.0 || { echo 'ERROR: missing required packages: webkit2gtk-4.1 gtk+-3.0 (install libwebkit2gtk-4.1-dev libgtk-3-dev)' >&2; exit 1; }",
        }).step,
        .webview2_backend => &CheckWebView2SdkStep.create(b, webview2_paths).step,
        .macos_backend => &CheckMacosBackendStep.create(b).step,
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
    exe.step.dependOn(pkg_guard);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run zigBrowser");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(pkg_guard);
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
    unit_tests.step.dependOn(pkg_guard);

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

    const afunix_spike_module = b.createModule(.{
        .root_source_file = b.path("tests/spikes/af_unix_roundtrip.zig"),
        .target = target,
        .optimize = optimize,
    });
    const afunix_spike_tests = b.addTest(.{ .root_module = afunix_spike_module });
    const run_afunix_spike_tests = b.addRunArtifact(afunix_spike_tests);
    run_afunix_spike_tests.skip_foreign_checks = true;
    const afunix_spike_step = b.step("automation-afunix-spike-win", "Run AF_UNIX automation transport spike");
    afunix_spike_step.dependOn(&run_afunix_spike_tests.step);

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

    const automation_module = b.createModule(.{
        .root_source_file = b.path("src/automation.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const automation_smoke_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_smoke_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_smoke_tests_module.addImport("automation", automation_module);
    const automation_smoke_tests = b.addTest(.{ .root_module = automation_smoke_tests_module });
    const run_automation_smoke_tests = b.addRunArtifact(automation_smoke_tests);
    run_automation_smoke_tests.skip_foreign_checks = true;

    const automation_error_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_error_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_error_tests_module.addImport("automation", automation_module);
    const automation_error_tests = b.addTest(.{ .root_module = automation_error_tests_module });
    const run_automation_error_tests = b.addRunArtifact(automation_error_tests);
    run_automation_error_tests.skip_foreign_checks = true;

    const automation_router_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_router_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_router_tests_module.addImport("automation", automation_module);
    const automation_router_tests = b.addTest(.{ .root_module = automation_router_tests_module });
    const run_automation_router_tests = b.addRunArtifact(automation_router_tests);
    run_automation_router_tests.skip_foreign_checks = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_ipc_tests.step);
    test_step.dependOn(&run_nav_policy_tests.step);
    test_step.dependOn(&run_automation_smoke_tests.step);
    test_step.dependOn(&run_automation_error_tests.step);
    test_step.dependOn(&run_automation_router_tests.step);
    test_step.dependOn(&ipc_windows_compile.step);
}

fn resolveBackend(target: std.Build.ResolvedTarget) Backend {
    return switch (target.result.os.tag) {
        .linux => .gtk_backend,
        .windows => .webview2_backend,
        .macos => .macos_backend,
        else => std.debug.panic("NoBackendLinked: no backend for target os '{s}'", .{@tagName(target.result.os.tag)}),
    };
}

fn configureBackend(
    module: *std.Build.Module,
    b: *std.Build,
    backend: Backend,
    webview2_paths: WebView2Paths,
) void {
    switch (backend) {
        .gtk_backend => configureGtkBackend(module, b),
        .webview2_backend => configureWebView2Backend(module, b, webview2_paths),
        .macos_backend => configureMacosBackend(module, b),
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
    if (paths.include_dir) |include_dir| {
        module.addSystemIncludePath(.{ .cwd_relative = include_dir });
    }
    if (paths.winrt_include_dir) |winrt_include_dir| {
        module.addSystemIncludePath(.{ .cwd_relative = winrt_include_dir });
    }
    if (paths.lib_dir) |lib_dir| {
        module.addLibraryPath(.{ .cwd_relative = lib_dir });
    }
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
    module.linkSystemLibrary("advapi32", .{ .use_pkg_config = .no });
}

fn configureMacosBackend(module: *std.Build.Module, b: *std.Build) void {
    module.addIncludePath(b.path("src"));
    module.addCSourceFile(.{
        .file = b.path("src/wkwebview_shim.m"),
        .flags = &.{"-fobjc-arc"},
    });

    module.linkFramework("WebKit", .{});
    module.linkFramework("Cocoa", .{});
    module.linkFramework("Foundation", .{});
}
