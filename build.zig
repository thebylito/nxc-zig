const std = @import("std");

const common_build = @import("packages/common/build.zig");
const linter_build = @import("packages/linter/build.zig");
const compiler_build = @import("packages/compiler/build.zig");
const cli_build = @import("packages/cli/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Build packages ──────────────────────────────

    const common = common_build.addPackage(b, target, optimize);
    const linter = linter_build.addPackage(b, target, optimize, common.module);
    const compiler = compiler_build.addPackage(b, target, optimize);
    const cli = cli_build.addPackage(
        b,
        target,
        optimize,
        .{
            .compiler = compiler.modules.compiler,
            .config = compiler.modules.config,
            .diagnostics = compiler.modules.diagnostics,
            .incremental = compiler.modules.incremental,
        },
        linter.module,
        common.module,
    );

    // ── N-API native addons ─────────────────────────

    linter_build.addLintAddon(b, target, optimize, linter.module, common.module);
    compiler_build.addParserAddon(b, target, optimize, compiler.modules.compiler);
    compiler_build.addTransformAddon(b, target, optimize, compiler.modules.compiler);

    // ── Package test modules ─────────────────────────

    const package_compiler_tests_mod = b.createModule(.{
        .root_source_file = b.path("packages/compiler/tests/compiler_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    package_compiler_tests_mod.addImport("compiler", compiler.modules.compiler);

    const package_linter_tests_mod = b.createModule(.{
        .root_source_file = b.path("packages/linter/tests/linter_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    package_linter_tests_mod.addImport("linter", linter.module);
    package_linter_tests_mod.addImport("common", common.module);

    const formatter_harness_mod = b.createModule(.{
        .root_source_file = b.path("packages/linter/tests/formatter/harness.zig"),
        .target = target,
        .optimize = optimize,
    });
    formatter_harness_mod.addImport("linter", linter.module);
    formatter_harness_mod.addImport("common", common.module);

    const package_formatter_tests_mod = b.createModule(.{
        .root_source_file = b.path("packages/linter/tests/formatter/formatter.zig"),
        .target = target,
        .optimize = optimize,
    });
    package_formatter_tests_mod.addImport("linter", linter.module);
    package_formatter_tests_mod.addImport("common", common.module);
    package_formatter_tests_mod.addImport("harness", formatter_harness_mod);

    const package_cli_tests_mod = b.createModule(.{
        .root_source_file = b.path("packages/cli/tests/cli_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    package_cli_tests_mod.addImport("cli", cli.cli);

    const package_common_tests_mod = b.createModule(.{
        .root_source_file = b.path("packages/common/tests/common_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    package_common_tests_mod.addImport("common", common.module);

    // ── Unit / integration tests (test_root.zig) ─────

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/test_root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    unit_tests.root_module.addImport("lexer", compiler.modules.lexer);
    unit_tests.root_module.addImport("ast", compiler.modules.ast);
    unit_tests.root_module.addImport("diagnostics", compiler.modules.diagnostics);
    unit_tests.root_module.addImport("parser", compiler.modules.parser);
    unit_tests.root_module.addImport("compiler", compiler.modules.compiler);
    unit_tests.root_module.addImport("pipeline", compiler.modules.pipeline);
    unit_tests.root_module.addImport("cli", cli.cli);
    unit_tests.root_module.addImport("paths", compiler.modules.paths);
    unit_tests.root_module.addImport("decorators", compiler.modules.decorators);
    unit_tests.root_module.addImport("json5", compiler.modules.json5);
    unit_tests.root_module.addImport("jsx", compiler.modules.jsx);
    unit_tests.root_module.addImport("sourcemap", compiler.modules.sourcemap);
    unit_tests.root_module.addImport("codegen", compiler.modules.codegen);
    unit_tests.root_module.addImport("config", compiler.modules.config);
    unit_tests.root_module.addImport("linter", linter.module);
    unit_tests.root_module.addImport("common", common.module);

    const cli_main_mod = b.createModule(.{
        .root_source_file = b.path("packages/cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_main_mod.addImport("compiler", compiler.modules.compiler);
    cli_main_mod.addImport("config", compiler.modules.config);
    cli_main_mod.addImport("cli", cli.cli);
    cli_main_mod.addImport("linter", linter.module);
    cli_main_mod.addImport("common", common.module);
    unit_tests.root_module.addImport("cli_main", cli_main_mod);

    // Test modules from tests/unit/ and tests/integration/

    const compiler_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/compiler_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    compiler_tests_mod.addImport("compiler", compiler.modules.compiler);
    compiler_tests_mod.addImport("pipeline", compiler.modules.pipeline);
    compiler_tests_mod.addImport("cli", cli.cli);
    unit_tests.root_module.addImport("compiler_tests", compiler_tests_mod);

    const decorator_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/decorator_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    decorator_tests_mod.addImport("compiler", compiler.modules.compiler);
    unit_tests.root_module.addImport("decorator_tests", decorator_tests_mod);

    const json5_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/json5_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    json5_tests_mod.addImport("pipeline", compiler.modules.pipeline);
    unit_tests.root_module.addImport("json5_tests", json5_tests_mod);

    const jsx_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/jsx_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("jsx_tests", jsx_tests_mod);

    const ansi_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/unit/ansi_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("ansi_tests", ansi_tests_mod);

    const cli_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration/cli_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_tests_mod.addImport("cli", cli.cli);
    cli_tests_mod.addImport("compiler", compiler.modules.compiler);
    unit_tests.root_module.addImport("cli_tests", cli_tests_mod);

    // ── Test step ────────────────────────────────────

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Inline test blocks from source files (not included in test_root.zig)
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = compiler.modules.lexer })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = cli_main_mod })).step);

    // Package test suites run as their own artifacts; test blocks in a separate
    // module are only registered with the runner when that module is the test root.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = package_compiler_tests_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = package_linter_tests_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = package_formatter_tests_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = package_cli_tests_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = package_common_tests_mod })).step);

    // ── Bench step ───────────────────────────────────

    const bench_module = b.createModule(.{
        .root_source_file = b.path("tests/bench/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_module.addImport("compiler", compiler.modules.compiler);
    bench_module.addImport("linter", linter.module);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = bench_module })).step);

    // ── Run step ────────────────────────────────────

    const cli_main_bin = b.createModule(.{
        .root_source_file = b.path("packages/cli/src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_main_bin.addImport("compiler", compiler.modules.compiler);
    cli_main_bin.addImport("config", compiler.modules.config);
    cli_main_bin.addImport("cli", cli.cli);
    cli_main_bin.addImport("linter", linter.module);
    cli_main_bin.addImport("common", common.module);

    const compiler_bin = b.createModule(.{
        .root_source_file = b.path("packages/cli/src/compiler_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    compiler_bin.addImport("cli", cli.cli);
    compiler_bin.addImport("compiler", compiler.modules.compiler);
    compiler_bin.addImport("config", compiler.modules.config);

    const linter_cache_mod = b.createModule(.{
        .root_source_file = b.path("packages/cli/src/cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    linter_cache_mod.addImport("linter", linter.module);
    linter_cache_mod.addImport("common", common.module);

    const linter_bin = b.createModule(.{
        .root_source_file = b.path("packages/cli/src/linter_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linter_bin.addImport("cli", cli.cli);
    linter_bin.addImport("linter", linter.module);
    linter_bin.addImport("cache", linter_cache_mod);

    const compiler_exe = b.addExecutable(.{ .name = "nxc-compiler", .root_module = compiler_bin });
    const linter_exe = b.addExecutable(.{ .name = "nxc-linter", .root_module = linter_bin });
    b.installArtifact(compiler_exe);
    b.installArtifact(linter_exe);

    const run_cmd = b.addRunArtifact(compiler_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run nxc-compiler").dependOn(&run_cmd.step);
}
