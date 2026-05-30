const lexer_tests = @import("unit/lexer_test.zig");
const module_interop_test = @import("unit/module_interop_test.zig");
const compiler_tests = @import("unit/compiler_test.zig");
const json5_tests = @import("unit/json5_test.zig");
const jsx_tests = @import("unit/jsx_test.zig");
const decorator_tests = @import("unit/decorator_test.zig");
const diagnostics_tests = @import("unit/diagnostics_test.zig");
const elide_imports_tests = @import("unit/elide_imports_test.zig");
const ansi_tests = @import("unit/ansi_test.zig");
const codegen_tests = @import("unit/codegen_test.zig");
const parser_tests = @import("unit/parser_test.zig");
const sourcemaps_tests = @import("unit/sourcemaps_test.zig");
const paths_tests = @import("unit/paths_test.zig");
const formatter_leading_semi_tests = @import("unit/formatter_leading_semi_test.zig");
const regression_coverage_tests = @import("unit/regression_coverage_test.zig");
const cli_tests = @import("integration/cli_test.zig");

comptime {
    _ = lexer_tests;
    _ = module_interop_test;
    _ = compiler_tests;
    _ = json5_tests;
    _ = jsx_tests;
    _ = decorator_tests;
    _ = diagnostics_tests;
    _ = elide_imports_tests;
    _ = ansi_tests;
    _ = codegen_tests;
    _ = parser_tests;
    _ = paths_tests;
    _ = formatter_leading_semi_tests;
    _ = regression_coverage_tests;
    _ = sourcemaps_tests;
    _ = cli_tests;
}
