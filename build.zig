const std = @import("std");

const test_targets = [_]std.Target.Query{
    .{},
};

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

const harness_support_specs = [_]TestSupportSpec{
    .{ .name = "html5lib_loader", .path = "tests/html5lib/html5lib_loader.zig" },
    .{ .name = "css_corpus_loader", .path = "tests/corpus_css/css_corpus_loader.zig" },
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
    exe.root_module.addIncludePath(b.path("src"));
    linkCurl(exe.root_module);
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

    const spike_step = b.step("spikes", "Run v2a spike test suite");
    for (test_targets) |query| {
        const test_target = b.resolveTargetQuery(query);
        const spike_suite = buildSpikeTestSuite(b, test_target, optimize);
        const run_spike = b.addRunArtifact(spike_suite);
        run_spike.skip_foreign_checks = true;
        spike_step.dependOn(&run_spike.step);
    }

    const smoke_step = b.step("smoke", "Run live-web smoke harness (SMOKE=1)");
    const smoke_exe = buildSmokeExecutable(b, target, optimize);
    const run_smoke = b.addRunArtifact(smoke_exe);
    run_smoke.skip_foreign_checks = true;
    smoke_step.dependOn(&run_smoke.step);
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
    curl_translate.linkSystemLibrary("curl", .{ .use_pkg_config = .yes });
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
    browser_module.addIncludePath(b.path("src"));
    linkCurl(browser_module);
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
    test_root.addIncludePath(b.path("src"));
    linkCurl(test_root);

    return b.addTest(.{ .root_module = test_root });
}

fn buildHarnessTestSuite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    var support_modules: [harness_support_specs.len]*std.Build.Module = undefined;
    inline for (harness_support_specs, 0..) |spec, idx| {
        support_modules[idx] = b.createModule(.{
            .root_source_file = b.path(spec.path),
            .target = target,
            .optimize = optimize,
        });
    }

    var imports: [harness_support_specs.len]std.Build.Module.Import = undefined;
    inline for (harness_support_specs, 0..) |spec, idx| {
        imports[idx] = .{ .name = spec.name, .module = support_modules[idx] };
    }

    const harness_root = b.createModule(.{
        .root_source_file = b.path("tests/harness/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });

    return b.addTest(.{ .root_module = harness_root });
}

fn buildSpikeTestSuite(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const dom_module = b.createModule(.{
        .root_source_file = b.path("src/html/dom.zig"),
        .target = target,
        .optimize = optimize,
    });

    const counting_alloc_module = b.createModule(.{
        .root_source_file = b.path("spikes/shared/counting_alloc.zig"),
        .target = target,
        .optimize = optimize,
    });

    const handle_table_module = b.createModule(.{
        .root_source_file = b.path("spikes/shared/handle_table.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dom", .module = dom_module },
        },
    });

    const quickjs_module = b.createModule(.{
        .root_source_file = b.path("spikes/quickjs/spike.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dom", .module = dom_module },
            .{ .name = "handle_table", .module = handle_table_module },
            .{ .name = "counting_alloc", .module = counting_alloc_module },
        },
    });

    const xs_module = b.createModule(.{
        .root_source_file = b.path("spikes/xs/spike.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dom", .module = dom_module },
            .{ .name = "handle_table", .module = handle_table_module },
            .{ .name = "counting_alloc", .module = counting_alloc_module },
        },
    });

    const wasm_module = b.createModule(.{
        .root_source_file = b.path("spikes/wasm/spike.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dom", .module = dom_module },
            .{ .name = "handle_table", .module = handle_table_module },
            .{ .name = "counting_alloc", .module = counting_alloc_module },
        },
    });

    const doc_lint_module = b.createModule(.{
        .root_source_file = b.path("spikes/doc_lint.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root = b.createModule(.{
        .root_source_file = b.path("spikes/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "spike_quickjs", .module = quickjs_module },
            .{ .name = "spike_xs", .module = xs_module },
            .{ .name = "spike_wasm", .module = wasm_module },
            .{ .name = "spike_doc_lint", .module = doc_lint_module },
        },
    });

    return b.addTest(.{ .root_module = root });
}

fn buildSmokeExecutable(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const curl_c_module = createCurlModule(b, target, optimize);
    const browser_module = createBrowserModule(b, target, optimize);
    const smoke_root = b.createModule(.{
        .root_source_file = b.path("tests/smoke/real_web.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigBrowser", .module = browser_module },
            .{ .name = "curl_c", .module = curl_c_module },
        },
        .link_libc = true,
    });
    smoke_root.addIncludePath(b.path("src"));
    linkCurl(smoke_root);

    return b.addExecutable(.{
        .name = "zigBrowser-smoke",
        .root_module = smoke_root,
    });
}

fn linkCurl(module: anytype) void {
    const Candidate = struct {
        path: []const u8,
        mode: enum { system_library, object_file },
    };

    const candidates = [_]Candidate{
        .{ .path = "/usr/lib/x86_64-linux-gnu/libcurl.so", .mode = .system_library },
        .{ .path = "/usr/local/lib/libcurl.so", .mode = .system_library },
        .{ .path = "/usr/lib/libcurl.so", .mode = .system_library },
        .{ .path = "/opt/homebrew/lib/libcurl.dylib", .mode = .system_library },
        .{ .path = "/opt/homebrew/opt/curl/lib/libcurl.dylib", .mode = .system_library },
        .{ .path = "/usr/local/opt/curl/lib/libcurl.dylib", .mode = .system_library },
        .{ .path = "/usr/lib/x86_64-linux-gnu/libcurl.so.4", .mode = .object_file },
        .{ .path = "/usr/lib/x86_64-linux-gnu/libcurl-gnutls.so.4", .mode = .object_file },
        .{ .path = "/usr/lib64/libcurl.so.4", .mode = .object_file },
        .{ .path = "/usr/lib/libcurl.so.4", .mode = .object_file },
    };

    for (candidates) |candidate| {
        if (!absolutePathExists(candidate.path)) continue;
        switch (candidate.mode) {
            .system_library => module.linkSystemLibrary("curl", .{ .use_pkg_config = .yes }),
            .object_file => module.addObjectFile(.{ .cwd_relative = candidate.path }),
        }
        return;
    }

    // Keep pkg-config/system discovery as the default for CI and dev boxes
    // where an unversioned libcurl symlink is installed.
    module.linkSystemLibrary("curl", .{ .use_pkg_config = .yes });
}

fn absolutePathExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}
