const std = @import("std");
const config_schema = @import("src/config_schema.zig");

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
    const site_config_path = b.option(
        []const u8,
        "site_config",
        "Path to zigBrowser JSON site config (default: zigbrowser.json)",
    ) orelse "zigbrowser.json";
    const site_config = loadSiteConfig(b, site_config_path);
    const site_options = b.addOptions();
    site_options.addOption([]const u8, "default_url", site_config.url);
    site_options.addOption([]const u8, "config_path", site_config_path);
    const site_options_module = site_options.createModule();

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
        .imports = &.{
            .{ .name = "build_options", .module = site_options_module },
        },
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

    // The Claude Agent helper runtime beside the binary (chat-drawer plan
    // D6, rev 15.2): <prefix>/lib/zigbrowser/agent-host.
    const agent_runtime = b.addSystemCommand(&.{ "sh", "tools/install_agent_runtime.sh", b.install_prefix });
    b.step("agent-runtime", "Install the Claude Agent helper runtime into the install prefix").dependOn(&agent_runtime.step);

    const run_step = b.step("run", "Run zigBrowser");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(pkg_guard);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .imports = &.{
            .{ .name = "build_options", .module = site_options_module },
        },
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

    // N12: a WebView2/WKWebView build must not need a GTK-only shim symbol
    // (zb_automation_*, zb_cookies_*, zb_native_*, ...). Compile src/main.zig
    // to an object for each non-GTK target (no SDK, no link) and check that
    // every zb_* symbol it leaves undefined is defined by that target's shim.
    // --require: the core symbols must show up, so a parser or object-layout
    // change cannot make the check pass vacuously.
    const cross_check = b.addSystemCommand(&.{ "python3", "tools/check_cross_symbols.py", "--require", "zb_app_run", "--require", "zb_version_line" });
    cross_check.addFileInput(b.path("tools/check_cross_symbols.py"));
    // Self-test per object format: a fixture needing a symbol no shim
    // defines must be reported as exactly that one missing symbol.
    const cross_self_test = b.addSystemCommand(&.{ "python3", "tools/check_cross_symbols.py", "--require", "zb_app_run", "--expect-missing", "zb_cross_fixture_probe" });
    cross_self_test.addFileInput(b.path("tools/check_cross_symbols.py"));
    const cross_targets = [_]struct { query: std.Target.Query, shim: []const u8 }{
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu }, .shim = "src/webview2_shim.cpp" },
        .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .shim = "src/wkwebview_shim.m" },
        .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .shim = "src/wkwebview_shim.m" },
    };
    for (cross_targets) |cross| {
        const cross_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "build_options", .module = site_options_module },
            },
            .target = b.resolveTargetQuery(cross.query),
            .optimize = optimize,
            .link_libc = true,
        });
        cross_module.addIncludePath(b.path("src"));
        const cross_object = b.addObject(.{ .name = "zigBrowser-cross", .root_module = cross_module });
        cross_check.addFileArg(cross_object.getEmittedBin());
        cross_check.addFileArg(b.path(cross.shim));

        const fixture_module = b.createModule(.{
            .root_source_file = b.path("tests/fixtures/cross/missing_symbol.zig"),
            .target = b.resolveTargetQuery(cross.query),
            .optimize = optimize,
        });
        const fixture_object = b.addObject(.{ .name = "cross-fixture", .root_module = fixture_module });
        cross_self_test.addFileArg(fixture_object.getEmittedBin());
        cross_self_test.addFileArg(b.path(cross.shim));
    }
    const cross_check_step = b.step("cross-check", "Check that Windows/macOS builds need only zb_* symbols their shims define");
    cross_check_step.dependOn(&cross_check.step);
    cross_check_step.dependOn(&cross_self_test.step);

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

    // Chat drawer S3.3: the native validator of helper frames.
    const agent_protocol_module = b.createModule(.{
        .root_source_file = b.path("src/agent_protocol.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_protocol_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_protocol_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_protocol_tests_module.addImport("agent_protocol", agent_protocol_module);
    const run_agent_protocol_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_protocol_tests_module }));
    run_agent_protocol_tests.skip_foreign_checks = true;

    // Chat drawer S1: the floating icon's pure logic (src/agent_drawer.zig).
    const agent_drawer_module = b.createModule(.{
        .root_source_file = b.path("src/agent_drawer.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const agent_drawer_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_drawer_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_drawer_tests_module.addImport("agent_drawer", agent_drawer_module);
    const agent_drawer_tests = b.addTest(.{ .root_module = agent_drawer_tests_module });
    const run_agent_drawer_tests = b.addRunArtifact(agent_drawer_tests);
    run_agent_drawer_tests.skip_foreign_checks = true;

    // Chat drawer S3n2, native spawn wiring: netd's socket directory, the e2e
    // seams' grammar and netd's argv and environment (src/agent_net.zig).
    const agent_net_module = b.createModule(.{
        .root_source_file = b.path("src/agent_net.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const agent_net_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_net_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_net_tests_module.addImport("agent_net", agent_net_module);
    const run_agent_net_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_net_tests_module }));
    run_agent_net_tests.skip_foreign_checks = true;

    // Chat drawer S3b: the helper's launch argv and environment, the app's
    // frames, the runtime-lock check and the backoff (src/agent_helper.zig).
    const agent_helper_module = b.createModule(.{
        .root_source_file = b.path("src/agent_helper.zig"),
        .target = target,
        .optimize = optimize,
    });
    const agent_helper_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_helper_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent_helper_tests_module.addImport("agent_helper", agent_helper_module);
    const run_agent_helper_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_helper_tests_module }));
    run_agent_helper_tests.skip_foreign_checks = true;

    // Chat drawer S4a: the token's shape and the explicit file store, read and
    // write (src/agent_secrets.zig).
    const agent_secrets_module = b.createModule(.{
        .root_source_file = b.path("src/agent_secrets.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const agent_secrets_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/agent_secrets_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_secrets_tests_module.addImport("agent_secrets", agent_secrets_module);
    const run_agent_secrets_tests = b.addRunArtifact(b.addTest(.{ .root_module = agent_secrets_tests_module }));
    run_agent_secrets_tests.skip_foreign_checks = true;
    // S4.1 edge: the libsecret dlopen fails (built against a missing library;
    // in the browser WebKitGTK has it loaded already). GTK hosts only.
    const agent_secrets_dlopen_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    agent_secrets_dlopen_module.addIncludePath(b.path("src"));
    agent_secrets_dlopen_module.addCSourceFile(.{ .file = b.path("tests/agent_secrets_dlopen_test.c"), .flags = &.{"-std=gnu11"} });
    agent_secrets_dlopen_module.addCSourceFile(.{
        .file = b.path("src/agent_secrets.c"),
        .flags = &.{ "-std=gnu11", "-DZB_LIBSECRET_SONAME=\"libzb-missing-secret.so.0\"" },
    });
    agent_secrets_dlopen_module.linkSystemLibrary("gio-2.0", .{ .use_pkg_config = .force });
    const run_agent_secrets_dlopen_test = b.addRunArtifact(b.addExecutable(.{
        .name = "agent-secrets-dlopen-test",
        .root_module = agent_secrets_dlopen_module,
    }));
    run_agent_secrets_dlopen_test.skip_foreign_checks = true;

    const config_schema_module = b.createModule(.{
        .root_source_file = b.path("src/config_schema.zig"),
        .target = target,
        .optimize = optimize,
    });
    const config_schema_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/config_schema_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    config_schema_tests_module.addImport("config_schema", config_schema_module);
    const config_schema_tests = b.addTest(.{ .root_module = config_schema_tests_module });
    const run_config_schema_tests = b.addRunArtifact(config_schema_tests);
    run_config_schema_tests.skip_foreign_checks = true;

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

    const automation_engine_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_engine_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_engine_tests_module.addImport("automation", automation_module);
    const automation_engine_tests = b.addTest(.{ .root_module = automation_engine_tests_module });
    const run_automation_engine_tests = b.addRunArtifact(automation_engine_tests);
    run_automation_engine_tests.skip_foreign_checks = true;

    const automation_retry_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_retry_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_retry_tests_module.addImport("automation", automation_module);
    const automation_retry_tests = b.addTest(.{ .root_module = automation_retry_tests_module });
    const run_automation_retry_tests = b.addRunArtifact(automation_retry_tests);
    run_automation_retry_tests.skip_foreign_checks = true;

    const automation_queue_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_queue_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_queue_tests_module.addImport("automation", automation_module);
    const automation_queue_tests = b.addTest(.{ .root_module = automation_queue_tests_module });
    const run_automation_queue_tests = b.addRunArtifact(automation_queue_tests);
    run_automation_queue_tests.skip_foreign_checks = true;

    const automation_telemetry_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_telemetry_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_telemetry_tests_module.addImport("automation", automation_module);
    const automation_telemetry_tests = b.addTest(.{ .root_module = automation_telemetry_tests_module });
    const run_automation_telemetry_tests = b.addRunArtifact(automation_telemetry_tests);
    run_automation_telemetry_tests.skip_foreign_checks = true;

    const automation_social_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_social_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_social_tests_module.addImport("automation", automation_module);
    const automation_social_tests = b.addTest(.{ .root_module = automation_social_tests_module });
    const run_automation_social_tests = b.addRunArtifact(automation_social_tests);
    run_automation_social_tests.skip_foreign_checks = true;

    const automation_cookie_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_cookie_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_cookie_tests_module.addImport("automation", automation_module);
    const automation_cookie_tests = b.addTest(.{ .root_module = automation_cookie_tests_module });
    const run_automation_cookie_tests = b.addRunArtifact(automation_cookie_tests);
    run_automation_cookie_tests.skip_foreign_checks = true;

    const automation_x_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_x_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_x_tests_module.addImport("automation", automation_module);
    const automation_x_tests = b.addTest(.{ .root_module = automation_x_tests_module });
    const run_automation_x_tests = b.addRunArtifact(automation_x_tests);
    run_automation_x_tests.skip_foreign_checks = true;

    const automation_server_module = b.createModule(.{
        .root_source_file = b.path("src/automation_server.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const automation_server_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation_server_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    automation_server_tests_module.addImport("automation_server", automation_server_module);
    const automation_server_tests = b.addTest(.{ .root_module = automation_server_tests_module });
    const run_automation_server_tests = b.addRunArtifact(automation_server_tests);
    run_automation_server_tests.skip_foreign_checks = true;

    const automation_api_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_api_lifecycle_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-api-e2e",
    });
    automation_api_e2e.addArtifactArg(exe);

    // M12: external socket client drives the live page (fixture server).
    const automation_core_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_core_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-core-e2e",
    });
    automation_core_e2e.addArtifactArg(exe);

    // First-RPC dom.waitFor during a slow first load keeps the JS timeout authoritative.
    const automation_readiness_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_readiness_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-readiness-e2e",
    });
    automation_readiness_e2e.addArtifactArg(exe);

    // Python SDK driving the real binary (navigate -> type -> click -> getText).
    const sdk_python_live_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/sdk_python_live_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "sdk-python-live-e2e",
    });
    sdk_python_live_e2e.addArtifactArg(exe);

    // N11: x.post / x.schedule_post / x.login_check on the X composer fixture.
    const x_flows_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/x_flows_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "x-flows-e2e",
    });
    x_flows_e2e.addArtifactArg(exe);

    // N14: x.post / x.schedule_post with native, humanized input (isTrusted).
    const x_native_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/x_native_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "x-native-e2e",
    });
    x_native_e2e.addArtifactArg(exe);

    // N16: linkedin.* / instagram.* through the Python SDK on site-modelled fixtures.
    const social_flows_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/social_flows_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "social-flows-e2e",
    });
    social_flows_e2e.addArtifactArg(exe);

    // N18: synthetic dom.scroll / dom.hover through the Python SDK; offsets
    // read back in the next command.
    const automation_scroll_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_scroll_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-scroll-e2e",
    });
    automation_scroll_e2e.addArtifactArg(exe);

    // PagePort v3.3/v3.4 on the real GTK adapter: screenshot PNG, file
    // chooser, native wheel scrolling.
    const automation_native_ports_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_native_ports_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-native-ports-e2e",
    });
    automation_native_ports_e2e.addArtifactArg(exe);

    // N21: pacing survives a restart on the same --profile-dir (real binary).
    const automation_pacing_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_pacing_persist_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-pacing-e2e",
    });
    automation_pacing_e2e.addArtifactArg(exe);

    // libsoup 3.6.5 HTTP/2 GOAWAY workaround: a local TLS HTTP/2 server ends each response
    // with GOAWAY(NO_ERROR); the page's fetch must succeed (SOUP_FORCE_HTTP1=1 by default).
    const http2_goaway_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/http2_goaway_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "http2-goaway-e2e",
    });
    http2_goaway_e2e.addArtifactArg(exe);

    // E2E harness hygiene: a browser started through the shared launcher
    // (tests/e2e/xsession.py) never outlives a test driver that dies mid-test.
    const harness_group_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/harness_group_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "harness-group-e2e",
    });
    harness_group_e2e.addArtifactArg(exe);

    // A window whose web process died says so in page.list and on stderr.
    const web_process_crash_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/web_process_crash_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "web-process-crash-e2e",
    });
    web_process_crash_e2e.addArtifactArg(exe);

    // --hardware-acceleration / --renderer reach WebKit's web process.
    const render_config_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/render_config_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "render-config-e2e",
    });
    render_config_e2e.addArtifactArg(exe);

    // The 15-second load timer never kills a committed page, nor a web
    // process related windows share.
    const slow_load_watchdog_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/slow_load_watchdog_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "slow-load-watchdog-e2e",
    });
    slow_load_watchdog_e2e.addArtifactArg(exe);

    // --media-source off / ZIGBROWSER_MEDIA_SOURCE=off: pages in every window,
    // popups and the screenshot see no MediaSource.
    const media_source_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/media_source_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "media-source-e2e",
    });
    media_source_e2e.addArtifactArg(exe);

    // Chat drawer S1: --agent-drawer, the overlay and the floating "S" icon,
    // driven by real X input on a private Xvfb (closure test S1). Missing
    // Xvfb, xwd or libXtst fails it (exit 1): no skip to green.
    const agent_drawer_icon_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_drawer_icon_test.py --binary \"$1\"",
        "agent-drawer-icon-e2e",
    });
    agent_drawer_icon_e2e.addArtifactArg(exe);

    // Chat drawer S2: the drawer shell (layout, '-' minimize animation,
    // keyboard, scrolling, Send with no agent) and threat test T1 (hostile
    // pages cannot reach or cover it). Real X input; never skips to green.
    const agent_drawer_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_drawer_test.py --binary \"$1\"",
        "agent-drawer-e2e",
    });
    agent_drawer_e2e.addArtifactArg(exe);
    const agent_isolation_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_isolation_test.py --binary \"$1\"",
        "agent-isolation-e2e",
    });
    agent_isolation_e2e.addArtifactArg(exe);

    // zbHost: the IPC rows, and the page's own promise settling (chat drawer
    // S1.6), on a private Xvfb.
    const ipc_roundtrip_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/ipc_roundtrip_test.py --prefer-xvfb --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "ipc-roundtrip-e2e",
    });
    ipc_roundtrip_e2e.addArtifactArg(exe);

    // page.health: a frozen page turns responsive:false, out of band, while
    // another window stays responsive (watchdog slice 1).
    const page_health_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/page_health_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "page-health-e2e",
    });
    page_health_e2e.addArtifactArg(exe);

    // page.recover: a confirmed recovery ends a frozen web process and
    // reloads its windows; refusals end nothing (watchdog slice 2).
    const page_recover_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/page_recover_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "page-recover-e2e",
    });
    page_recover_e2e.addArtifactArg(exe);

    // Claude Agent helper (chat drawer P0): unit tests, and the boundary
    // contracts that run the real SDK and bundled CLI against a fake Messages
    // API. Both fail closed when the helper venv is missing (run
    // tools/agent_host_env.sh first); neither starts the browser.
    const agent_host_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_unit",
    });
    // Chat drawer S3.1: --agent-setup's provisioning (unit and property
    // tests of the helper's setup command); fails closed without the venv.
    const agent_host_provision_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_provision",
    });
    // Chat drawer S3b: the helper's `chat` (real SDK and CLI against the fake
    // Messages API, token on fd 3, R1 only) and `launch` (the sandbox with its
    // own network, the outer relay as its command); fails closed without the venv.
    const agent_host_chat = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_chat",
    });
    // Chat drawer S3.1/S3.7: the real `zigBrowser --agent-setup` against a
    // decoy HOME, with the real token-route probe on the bundled CLI.
    const agent_setup_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_setup_test.py --binary \"$1\"",
        "agent-setup-e2e",
    });
    agent_setup_e2e.addArtifactArg(exe);
    // Chat drawer S3n2: the browser starts netd on the first Send (with a
    // provisioned agent home), reports its failures and stops it at quit.
    const agent_netd_spawn_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_netd_spawn_test.py --binary \"$1\"",
        "agent-netd-spawn-e2e",
    });
    agent_netd_spawn_e2e.addArtifactArg(exe);
    // Chat drawer S3b: the first Send starts a confined helper, its frames are
    // validated natively, and every exit path cleans it up (Closure Test S3).
    // The whole run sits in a network namespace of its own: nothing real is reachable.
    const agent_host_lifecycle_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_host_lifecycle_test.py --binary \"$1\"",
        "agent-host-lifecycle-e2e",
    });
    agent_host_lifecycle_e2e.addArtifactArg(exe);
    // Chat drawer S4a: the Secrets window stores a typed token in a private
    // keyring or the explicit 0600 file, and Send with no token opens it. The
    // S4b cases (handoff, remove-session, hooks) join after S3b's helper.
    const agent_secrets_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/agent_secrets_test.py --binary \"$1\" --only secret-service,file-flag,rejected,no-keyring,remove,unreachable,fallback-persists,stale-store,lookup-race,remove-both",
        "agent-secrets-e2e",
    });
    agent_secrets_e2e.addArtifactArg(exe);
    // Plan §7.1: the real-screen check's verdict and environment, with fake
    // captures (no display, no browser). The check itself runs only on the
    // user's screen, by the orchestrator.
    const real_screen_check_unit = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/manual && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_real_screen_check",
    });
    // The same check's input guard against a real X server: decoy windows on
    // a private Xvfb (xsession.py) must receive no click or key.
    const real_screen_input_xvfb = b.addSystemCommand(&.{
        "sh",
        "-c",
        "cd tests/manual && env -u DISPLAY -u WAYLAND_DISPLAY -u XAUTHORITY python3 ../e2e/xsession.py --xvfb -- env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v test_real_screen_input",
    });
    const agent_host_contract = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_contract",
    });
    // MS0 (macOS launch plan, rev 6): the shared SandboxBackend seam — the
    // behaviour-preserving golden-argv oracle (LinuxBwrapBackend reproduces
    // helper_argv byte-for-byte) and the backend-supplied network capability
    // (egress endpoint + bridge policy); fails closed without the venv.
    const agent_host_backend_contract = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_backend_contract",
    });
    // Chat drawer S3n1 (plan rev 16.2 §3c): the host-side network helper and the
    // two relays, driven through their command lines, offline (private fakes on
    // 127.0.0.1 and short /tmp/zbn-* socket directories only).
    const agent_host_netd = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_netd",
    });
    const agent_host_relay = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" \"$py\" -m unittest -v test_relay",
    });
    // Chat drawer S3n2 (plan rev 16.2 §3c.8b): each hook's own sealed network, from a
    // real outer sandbox through the real zb-hook-run. The module runs in a disposable
    // network namespace with only loopback (it fails rather than skips elsewhere).
    const agent_host_hook_net = b.addSystemCommand(&.{
        "sh",
        "-c",
        "py=$(tools/agent_host_env.sh --check) || exit 1; cd agent/host/tests && env -i PATH=/usr/bin:/bin LANG=C.UTF-8 PYTHONDONTWRITEBYTECODE=1 ZB_AGENT_HOST_PYTHON=\"$py\" /usr/bin/bwrap --unshare-net --die-with-parent --dev-bind / / --proc /proc -- \"$py\" -m unittest -v test_hook_net",
    });

    // Page dialogs (alert/confirm/prompt/beforeunload) in the primary window
    // and a popup: dialog.get / dialog.respond, page.navigate onBeforeUnload.
    const automation_dialogs_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_dialogs_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-dialogs-e2e",
    });
    automation_dialogs_e2e.addArtifactArg(exe);

    // N23: popup window targeting through the socket (page.list, window_id,
    // page.close, then no_window for the closed popup).
    const automation_windows_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_windows_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-windows-e2e",
    });
    automation_windows_e2e.addArtifactArg(exe);

    // Input verbs (contenteditable type/fill, ...) against the live page.
    const automation_input_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_input_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-input-e2e",
    });
    automation_input_e2e.addArtifactArg(exe);

    // --profile-dir keeps cookies across restarts (real binary, local HTTP).
    const automation_profile_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_profile_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-profile-e2e",
    });
    automation_profile_e2e.addArtifactArg(exe);

    // cookies.* against the real cookie store (local HTTP, restart on profile).
    const automation_cookies_e2e = b.addSystemCommand(&.{
        "sh",
        "-c",
        "python3 tests/e2e/automation_cookies_test.py --binary \"$1\"; rc=$?; if [ \"$rc\" = 77 ]; then exit 0; fi; exit \"$rc\"",
        "automation-cookies-e2e",
    });
    automation_cookies_e2e.addArtifactArg(exe);

    // --- Phase 4: Gaussian tests ---
    const gaussian_module = b.createModule(.{
        .root_source_file = b.path("src/automation/gaussian.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gaussian_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/gaussian_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gaussian_tests_module.addImport("gaussian", gaussian_module);
    const gaussian_tests = b.addTest(.{ .root_module = gaussian_tests_module });
    const run_gaussian_tests = b.addRunArtifact(gaussian_tests);

    // --- Phase 4: Bezier tests ---
    const bezier_module = b.createModule(.{
        .root_source_file = b.path("src/automation/bezier.zig"),
        .target = target,
        .optimize = optimize,
    });
    const bezier_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/bezier_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    bezier_tests_module.addImport("bezier", bezier_module);
    const bezier_tests = b.addTest(.{ .root_module = bezier_tests_module });
    const run_bezier_tests = b.addRunArtifact(bezier_tests);

    const stealth_module = b.createModule(.{
        .root_source_file = b.path("src/automation/stealth.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Phase 4: Pacing tests ---
    const pacing_module = b.createModule(.{
        .root_source_file = b.path("src/automation/pacing.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pacing_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/pacing_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    pacing_tests_module.addImport("pacing", pacing_module);
    pacing_tests_module.addImport("stealth", stealth_module);
    const pacing_tests = b.addTest(.{ .root_module = pacing_tests_module });
    const run_pacing_tests = b.addRunArtifact(pacing_tests);

    // --- Phase 4: Session tests ---
    const session_module = b.createModule(.{
        .root_source_file = b.path("src/automation/session.zig"),
        .target = target,
        .optimize = optimize,
    });
    const session_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/session_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    session_tests_module.addImport("session", session_module);
    const session_tests = b.addTest(.{ .root_module = session_tests_module });
    const run_session_tests = b.addRunArtifact(session_tests);

    // --- Phase 4: Stealth telemetry tests ---
    const stealth_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/stealth_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    stealth_tests_module.addImport("stealth", stealth_module);
    const stealth_tests = b.addTest(.{ .root_module = stealth_tests_module });
    const run_stealth_tests = b.addRunArtifact(stealth_tests);

    // --- Phase 5: Social contracts ---
    const social_module = b.createModule(.{
        .root_source_file = b.path("src/social.zig"),
        .target = target,
        .optimize = optimize,
    });
    const social_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/social_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    social_tests_module.addImport("social", social_module);
    const social_tests = b.addTest(.{ .root_module = social_tests_module });
    const run_social_tests = b.addRunArtifact(social_tests);
    run_social_tests.skip_foreign_checks = true;

    const x_module = b.createModule(.{
        .root_source_file = b.path("src/x.zig"),
        .target = target,
        .optimize = optimize,
    });
    const x_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/x_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    x_tests_module.addImport("x", x_module);
    const x_tests = b.addTest(.{ .root_module = x_tests_module });
    const run_x_tests = b.addRunArtifact(x_tests);
    run_x_tests.skip_foreign_checks = true;

    const linkedin_module = b.createModule(.{
        .root_source_file = b.path("src/linkedin.zig"),
        .target = target,
        .optimize = optimize,
    });
    const linkedin_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/linkedin_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkedin_tests_module.addImport("linkedin", linkedin_module);
    const linkedin_tests = b.addTest(.{ .root_module = linkedin_tests_module });
    const run_linkedin_tests = b.addRunArtifact(linkedin_tests);
    run_linkedin_tests.skip_foreign_checks = true;

    const instagram_module = b.createModule(.{
        .root_source_file = b.path("src/instagram.zig"),
        .target = target,
        .optimize = optimize,
    });
    const instagram_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/instagram_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    instagram_tests_module.addImport("instagram", instagram_module);
    const instagram_tests = b.addTest(.{ .root_module = instagram_tests_module });
    const run_instagram_tests = b.addRunArtifact(instagram_tests);
    run_instagram_tests.skip_foreign_checks = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_ipc_tests.step);
    test_step.dependOn(&run_nav_policy_tests.step);
    test_step.dependOn(&run_agent_drawer_tests.step);
    test_step.dependOn(&run_agent_net_tests.step);
    test_step.dependOn(&run_agent_secrets_tests.step);
    if (target.result.os.tag == .linux) test_step.dependOn(&run_agent_secrets_dlopen_test.step);
    const agent_secrets_step = b.step("test-agent-secrets", "Run the Claude Agent token store's unit tests");
    agent_secrets_step.dependOn(&run_agent_secrets_tests.step);
    if (target.result.os.tag == .linux) agent_secrets_step.dependOn(&run_agent_secrets_dlopen_test.step);
    test_step.dependOn(&run_agent_protocol_tests.step);
    test_step.dependOn(&run_agent_helper_tests.step);
    test_step.dependOn(&run_config_schema_tests.step);
    test_step.dependOn(&run_automation_smoke_tests.step);
    test_step.dependOn(&run_automation_error_tests.step);
    test_step.dependOn(&run_automation_router_tests.step);
    test_step.dependOn(&run_automation_engine_tests.step);
    test_step.dependOn(&run_automation_retry_tests.step);
    test_step.dependOn(&run_automation_queue_tests.step);
    test_step.dependOn(&run_automation_telemetry_tests.step);
    test_step.dependOn(&run_automation_social_tests.step);
    test_step.dependOn(&run_automation_cookie_tests.step);
    test_step.dependOn(&run_x_tests.step);
    test_step.dependOn(&run_automation_x_tests.step);
    test_step.dependOn(&run_automation_server_tests.step);
    test_step.dependOn(&automation_api_e2e.step);
    test_step.dependOn(&automation_core_e2e.step);
    test_step.dependOn(&automation_readiness_e2e.step);
    test_step.dependOn(&sdk_python_live_e2e.step);
    test_step.dependOn(&x_flows_e2e.step);
    test_step.dependOn(&x_native_e2e.step);
    test_step.dependOn(&social_flows_e2e.step);
    test_step.dependOn(&automation_input_e2e.step);
    test_step.dependOn(&automation_windows_e2e.step);
    test_step.dependOn(&automation_scroll_e2e.step);
    test_step.dependOn(&automation_native_ports_e2e.step);
    test_step.dependOn(&automation_pacing_e2e.step);
    test_step.dependOn(&automation_profile_e2e.step);
    test_step.dependOn(&automation_cookies_e2e.step);
    test_step.dependOn(&http2_goaway_e2e.step);
    test_step.dependOn(&harness_group_e2e.step);
    test_step.dependOn(&web_process_crash_e2e.step);
    test_step.dependOn(&render_config_e2e.step);
    test_step.dependOn(&slow_load_watchdog_e2e.step);
    test_step.dependOn(&media_source_e2e.step);
    test_step.dependOn(&agent_drawer_icon_e2e.step);
    test_step.dependOn(&agent_drawer_e2e.step);
    test_step.dependOn(&agent_isolation_e2e.step);
    test_step.dependOn(&ipc_roundtrip_e2e.step);
    test_step.dependOn(&page_health_e2e.step);
    test_step.dependOn(&page_recover_e2e.step);
    test_step.dependOn(&agent_host_unit.step);
    test_step.dependOn(&agent_host_contract.step);
    test_step.dependOn(&agent_host_backend_contract.step);
    test_step.dependOn(&agent_host_provision_unit.step);
    test_step.dependOn(&agent_host_chat.step);
    test_step.dependOn(&agent_host_netd.step);
    test_step.dependOn(&agent_host_relay.step);
    test_step.dependOn(&agent_host_hook_net.step);
    test_step.dependOn(&agent_setup_e2e.step);
    test_step.dependOn(&agent_netd_spawn_e2e.step);
    test_step.dependOn(&agent_host_lifecycle_e2e.step);
    test_step.dependOn(&agent_secrets_e2e.step);
    test_step.dependOn(&real_screen_check_unit.step);
    test_step.dependOn(&real_screen_input_xvfb.step);
    test_step.dependOn(&automation_dialogs_e2e.step);
    test_step.dependOn(&ipc_windows_compile.step);
    test_step.dependOn(&cross_check.step);
    test_step.dependOn(&cross_self_test.step);
    test_step.dependOn(&run_gaussian_tests.step);
    test_step.dependOn(&run_bezier_tests.step);
    test_step.dependOn(&run_pacing_tests.step);
    test_step.dependOn(&run_session_tests.step);
    test_step.dependOn(&run_stealth_tests.step);
    // --- Phase 4: JS contract tests ---
    const js_embed_module = b.createModule(.{
        .root_source_file = b.path("src/automation_script/js_embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const js_contract_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/automation/js_contract_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    js_contract_tests_module.addImport("js_embed", js_embed_module);
    const js_contract_tests = b.addTest(.{ .root_module = js_contract_tests_module });
    const run_js_contract_tests = b.addRunArtifact(js_contract_tests);

    test_step.dependOn(&run_social_tests.step);
    test_step.dependOn(&run_linkedin_tests.step);
    test_step.dependOn(&run_instagram_tests.step);
    test_step.dependOn(&run_js_contract_tests.step);

    // --- Track C: Sequences client facade + EV70 observability ---
    const sequences_module = b.createModule(.{
        .root_source_file = b.path("src/sequences.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sequences_client_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/sequences/client_facade_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sequences_client_tests_module.addImport("sequences", sequences_module);
    const sequences_client_tests = b.addTest(.{ .root_module = sequences_client_tests_module });
    const run_sequences_client_tests = b.addRunArtifact(sequences_client_tests);
    run_sequences_client_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_sequences_client_tests.step);

    const sequences_ev70_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/sequences/ev70_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    sequences_ev70_tests_module.addImport("sequences", sequences_module);
    const sequences_ev70_tests = b.addTest(.{ .root_module = sequences_ev70_tests_module });
    const run_sequences_ev70_tests = b.addRunArtifact(sequences_ev70_tests);
    run_sequences_ev70_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_sequences_ev70_tests.step);

    // --- Track D: Dashboard UI — embed + IPC + mock data ---
    const dashboard_embed_module = b.createModule(.{
        .root_source_file = b.path("src/dashboard/embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dashboard_embed_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/dashboard/dashboard_embed_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dashboard_embed_tests_module.addImport("dashboard_embed", dashboard_embed_module);
    const dashboard_embed_tests = b.addTest(.{ .root_module = dashboard_embed_tests_module });
    const run_dashboard_embed_tests = b.addRunArtifact(dashboard_embed_tests);
    run_dashboard_embed_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_dashboard_embed_tests.step);

    const dashboard_ipc_module = b.createModule(.{
        .root_source_file = b.path("src/dashboard/ipc.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dashboard_ipc_tests_module = b.createModule(.{
        .root_source_file = b.path("tests/dashboard/dashboard_ipc_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    dashboard_ipc_tests_module.addImport("dashboard_ipc", dashboard_ipc_module);
    const dashboard_ipc_tests = b.addTest(.{ .root_module = dashboard_ipc_tests_module });
    const run_dashboard_ipc_tests = b.addRunArtifact(dashboard_ipc_tests);
    run_dashboard_ipc_tests.skip_foreign_checks = true;
    test_step.dependOn(&run_dashboard_ipc_tests.step);

    // --- Dashboard visual-regression check (Playwright + Chromium via Node) ---
    // Renders src/dashboard/content/index.html in connected + disconnected states
    // and asserts on the rendered DOM, guarding against a blank error state.
    // Kept out of `zig build test` (needs Node/Playwright/Chromium); run in CI as
    // its own step: `zig build dashboard-visual`.
    const dashboard_visual = b.addSystemCommand(&.{ "node", "tools/dashboard_visual_check.mjs" });
    dashboard_visual.setCwd(b.path("."));
    const dashboard_visual_step = b.step("dashboard-visual", "Visual-regression check for the automation dashboard (Node+Playwright)");
    dashboard_visual_step.dependOn(&dashboard_visual.step);

    // The display guard (orchestrator HARD RULE, 2026-10-15): a harmless step
    // that only prints, so tests/display_guard_test.py can show that the guard
    // stops a step on a display that is not a private Xvfb.
    const display_guard_probe = b.addSystemCommand(&.{ "sh", "-c", "echo display-guard-probe ran" });
    b.step("display-guard-probe", "Print one line (the display guard's test target)").dependOn(&display_guard_probe.step);
    // The nested builds share this build's cache (`zig build run` compiles the browser).
    const display_guard_test = b.addSystemCommand(&.{ "python3", "tests/display_guard_test.py", "--zig", b.graph.zig_exe, "--cache-dir", b.cache_root.path orelse ".zig-cache" });
    test_step.dependOn(&display_guard_test.step);

    guardDisplay(b);
}

/// The display guard (orchestrator HARD RULE, 2026-10-15): every step that a
/// top-level step depends on waits for tools/display_guard.py, which refuses a
/// display that is not a private Xvfb (and any WAYLAND_DISPLAY) unless
/// ZB_ALLOW_REAL_DISPLAY=1. `run` is guarded too (RoseCat 5625): on the real
/// screen it needs the override. Only the install steps, `agent-runtime` and
/// `mac-gate` (no window on this host) are left out. Called last, so every
/// step registered above is covered.
fn guardDisplay(b: *std.Build) void {
    const guard = b.addSystemCommand(&.{ "python3", "tools/display_guard.py" });
    guard.has_side_effects = true; // the environment is read on every run, never cached
    const unguarded = [_][]const u8{ "install", "uninstall", "agent-runtime", "mac-gate" };
    next: for (b.top_level_steps.keys(), b.top_level_steps.values()) |name, top| {
        for (unguarded) |skip| if (std.mem.eql(u8, name, skip)) continue :next;
        for (top.step.dependencies.items) |dep| dep.dependOn(&guard.step);
    }
}

fn loadSiteConfig(b: *std.Build, path: []const u8) config_schema.SiteConfig {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        path,
        b.allocator,
        .limited(64 * 1024),
    ) catch |err| {
        std.debug.panic("failed to read site config '{s}': {s}", .{ path, @errorName(err) });
    };

    return config_schema.parse(b.allocator, bytes) catch |err| {
        std.debug.panic("invalid site config '{s}': {s}", .{ path, @errorName(err) });
    };
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
    module.addCSourceFile(.{
        .file = b.path("src/agent_drawer.c"),
        .flags = &.{"-std=c11"},
    });
    module.addCSourceFile(.{
        .file = b.path("src/agent_host.c"),
        .flags = &.{"-std=gnu11"},
    });
    module.addCSourceFile(.{
        .file = b.path("src/agent_secrets.c"),
        .flags = &.{"-std=gnu11"},
    });
    module.addCSourceFile(.{
        .file = b.path("src/agent_secrets_window.c"),
        .flags = &.{"-std=gnu11"},
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
