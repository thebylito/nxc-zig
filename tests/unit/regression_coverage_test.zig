const std = @import("std");

const common = @import("common");
const linter = @import("linter");

// ── common.sourceRange ───────────────────────────────
// Guards the single-pass rewrite of sourceRange against the reference
// two-call sourcePosition implementation across boundary inputs.
test "sourceRange matches independent sourcePosition across edge cases" {
    const Case = struct { src: []const u8, start: usize, end: usize };
    const cases = [_]Case{
        .{ .src = "", .start = 0, .end = 0 },
        .{ .src = "abc", .start = 0, .end = 0 },
        .{ .src = "abc", .start = 0, .end = 3 },
        .{ .src = "abc", .start = 1, .end = 2 },
        .{ .src = "a\nb\nc", .start = 2, .end = 4 },
        .{ .src = "a\nbb\nccc\n", .start = 0, .end = 8 },
        .{ .src = "line1\nline2\nline3", .start = 6, .end = 11 },
        .{ .src = "\n\n\n", .start = 1, .end = 3 },
        // empty range at a non-zero offset
        .{ .src = "x", .start = 1, .end = 1 },
        // out-of-bounds indices must be clamped to source length
        .{ .src = "abc", .start = 10, .end = 20 },
        .{ .src = "a\nb", .start = 2, .end = 100 },
        // inverted range (start > end) takes the fallback branch
        .{ .src = "a\nb\nc", .start = 4, .end = 1 },
    };

    for (cases) |c| {
        const range = common.sourceRange(c.src, c.start, c.end);
        const want_start = common.sourcePosition(c.src, c.start);
        const want_end = common.sourcePosition(c.src, c.end);
        try std.testing.expectEqual(want_start.index, range.start.index);
        try std.testing.expectEqual(want_start.line, range.start.line);
        try std.testing.expectEqual(want_start.column, range.start.column);
        try std.testing.expectEqual(want_end.index, range.end.index);
        try std.testing.expectEqual(want_end.line, range.end.line);
        try std.testing.expectEqual(want_end.column, range.end.column);
    }
}

// ── linter lexer: comment-run DoS ────────────────────
// The linter lexer is a separate compiled copy of the lexer; recursing on
// comments would overflow the stack on long comment runs.
test "linter lexer handles long runs of comments without stack overflow" {
    const alloc = std.testing.allocator;
    var src = std.ArrayListUnmanaged(u8).empty;
    defer src.deinit(alloc);

    const n: usize = 200_000;
    for (0..n) |_| try src.appendSlice(alloc, "// comment\n");
    try src.appendSlice(alloc, "const x = 1;");

    var l = linter.lexer.Lexer.init(src.items);
    try std.testing.expectEqual(linter.lexer.TokenKind.kw_const, l.next().kind);
    try std.testing.expectEqual(linter.lexer.TokenKind.ident, l.next().kind);
}

// ── linter parser: depth-counter leak ────────────────
// parseBindingPattern + parseTsType each call checkDepth(); without a matching
// decrement the counter grows per declaration and trips a false depth error.
test "linter parser does not leak depth counter across many declarations" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();
    const alloc = backing_alloc.allocator();

    var src = std.ArrayListUnmanaged(u8).empty;
    const n: usize = 3000; // safely beyond the default max_depth of 2048
    for (0..n) |i| try src.print(alloc, "const a{d}: number = {d};\n", .{ i, i });

    var arena = linter.ast.Arena.init(alloc);
    var diags = linter.parser.diagnostics.DiagnosticList{};

    var p = linter.parser.Parser.init(src.items, "depth.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });

    _ = try p.parseProgram();
    try std.testing.expect(!diags.hasErrors());
}
