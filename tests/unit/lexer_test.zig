const std = @import("std");

const lexer = @import("lexer");

const Lexer = lexer.Lexer;
const TokenKind = lexer.TokenKind;

test "lex basic tokens" {
    var l = Lexer.init("const x = 42;");
    try std.testing.expectEqual(TokenKind.kw_const, l.next().kind);
    try std.testing.expectEqual(TokenKind.ident, l.next().kind);
    try std.testing.expectEqual(TokenKind.eq, l.next().kind);
    try std.testing.expectEqual(TokenKind.number, l.next().kind);
    try std.testing.expectEqual(TokenKind.semicolon, l.next().kind);
    try std.testing.expectEqual(TokenKind.eof, l.next().kind);
}

test "lex operators" {
    var l = Lexer.init("=== !== ?? ?. >>>");
    try std.testing.expectEqual(TokenKind.eq3, l.next().kind);
    try std.testing.expectEqual(TokenKind.bang_eq2, l.next().kind);
    try std.testing.expectEqual(TokenKind.question2, l.next().kind);
    try std.testing.expectEqual(TokenKind.question_dot, l.next().kind);
    try std.testing.expectEqual(TokenKind.gt3, l.next().kind);
}

test "lex typescript keywords" {
    var l = Lexer.init("interface type enum readonly");
    try std.testing.expectEqual(TokenKind.kw_interface, l.next().kind);
    try std.testing.expectEqual(TokenKind.kw_type, l.next().kind);
    try std.testing.expectEqual(TokenKind.kw_enum, l.next().kind);
    try std.testing.expectEqual(TokenKind.kw_readonly, l.next().kind);
}

test "lex regex literals with modern flags and escapes" {
    var l = Lexer.init("const rx = /(?<=src=\")(.|\\n)*?(?=\")/gu;");
    _ = l.next();
    _ = l.next();
    _ = l.next();
    const regex = l.next();
    try std.testing.expectEqual(TokenKind.regex, regex.kind);
    try std.testing.expectEqualStrings("/(?<=src=\")(.|\\n)*?(?=\")/gu", regex.raw);
}

test "lex division after expression" {
    var l = Lexer.init("const value = total / 2;");
    _ = l.next();
    _ = l.next();
    _ = l.next();
    _ = l.next();
    try std.testing.expectEqual(TokenKind.slash, l.next().kind);
}

test "lex private name #field" {
    var l = Lexer.init("#count #_val");
    const t1 = l.next();
    try std.testing.expectEqual(TokenKind.private_name, t1.kind);
    try std.testing.expectEqualStrings("#count", t1.raw);
    const t2 = l.next();
    try std.testing.expectEqual(TokenKind.private_name, t2.kind);
    try std.testing.expectEqualStrings("#_val", t2.raw);
}

test "lex collects pending comments before next token" {
    var l = Lexer.init(
        "// @ts-ignore\n" ++
            "/** @ts-ignore */\n" ++
            "/* @typescript-disable import-helpers/order-imports */\n" ++
            "const value = 1;",
    );

    try std.testing.expectEqual(TokenKind.kw_const, l.peek().kind);

    const comments = l.takePendingComments();
    try std.testing.expectEqual(@as(usize, 3), comments.len);
    try std.testing.expectEqualStrings("// @ts-ignore", comments[0].raw);
    try std.testing.expectEqualStrings("/** @ts-ignore */", comments[1].raw);
    try std.testing.expectEqualStrings("/* @typescript-disable import-helpers/order-imports */", comments[2].raw);
}

test "lex handles long runs of consecutive line comments without stack overflow" {
    const alloc = std.testing.allocator;
    var src = std.ArrayListUnmanaged(u8).empty;
    defer src.deinit(alloc);

    const n: usize = 200_000;
    for (0..n) |_| try src.appendSlice(alloc, "// comment line\n");
    try src.appendSlice(alloc, "const x = 1;");

    var l = Lexer.init(src.items);
    const kw = l.next();
    try std.testing.expectEqual(TokenKind.kw_const, kw.kind);
    // line tracking must survive the comment loop: token sits on line n + 1
    try std.testing.expectEqual(@as(u32, @intCast(n + 1)), kw.span.line);
    try std.testing.expectEqual(TokenKind.ident, l.next().kind);
    try std.testing.expectEqual(TokenKind.eq, l.next().kind);
    try std.testing.expectEqual(TokenKind.number, l.next().kind);
    try std.testing.expectEqual(TokenKind.semicolon, l.next().kind);
    try std.testing.expectEqual(TokenKind.eof, l.next().kind);
}

test "lex handles long runs of block comments without stack overflow" {
    const alloc = std.testing.allocator;
    var src = std.ArrayListUnmanaged(u8).empty;
    defer src.deinit(alloc);

    const n: usize = 200_000;
    for (0..n) |_| try src.appendSlice(alloc, "/* c */ ");
    try src.appendSlice(alloc, "42");

    var l = Lexer.init(src.items);
    try std.testing.expectEqual(TokenKind.number, l.next().kind);
    try std.testing.expectEqual(TokenKind.eof, l.next().kind);
}

test "lex source consisting only of comments yields eof" {
    const alloc = std.testing.allocator;
    var src = std.ArrayListUnmanaged(u8).empty;
    defer src.deinit(alloc);

    const n: usize = 100_000;
    for (0..n) |_| try src.appendSlice(alloc, "// only comments\n");

    var l = Lexer.init(src.items);
    try std.testing.expectEqual(TokenKind.eof, l.next().kind);
}

test "lex template middle/tail with trailing backslash at EOF does not overflow" {
    // Regression: a backslash as the final byte of a template middle/tail used to
    // overshoot the source length and trigger an out-of-bounds slice panic.
    var l = Lexer.init("`${1}\\");
    var t = l.next();
    var guard: usize = 0;
    while (t.kind != .eof and guard < 16) : (guard += 1) {
        t = l.next();
    }
    try std.testing.expectEqual(TokenKind.eof, t.kind);
}

test "lex skips utf8 bom and zero-width spaces" {
    var l = Lexer.init("const \xEF\xBB\xBFx\xE2\x80\x8B = \xEF\xBB\xBF1;");
    try std.testing.expectEqual(TokenKind.kw_const, l.next().kind);
    try std.testing.expectEqual(TokenKind.ident, l.next().kind);
    try std.testing.expectEqual(TokenKind.eq, l.next().kind);
    try std.testing.expectEqual(TokenKind.number, l.next().kind);
    try std.testing.expectEqual(TokenKind.semicolon, l.next().kind);
    try std.testing.expectEqual(TokenKind.eof, l.next().kind);
}

test "lex template literal with angle brackets around interpolation" {
    var l = Lexer.init("`${senderName} <${senderEmail}>`");
    const t1 = l.next();
    try std.testing.expectEqual(TokenKind.template_head, t1.kind);
    try std.testing.expectEqualStrings("`${", t1.raw);

    const t2 = l.next();
    try std.testing.expectEqual(TokenKind.ident, t2.kind);
    try std.testing.expectEqualStrings("senderName", t2.raw);

    const t3 = l.next();
    try std.testing.expectEqual(TokenKind.template_middle, t3.kind);
    try std.testing.expectEqualStrings("} <${", t3.raw);

    const t4 = l.next();
    try std.testing.expectEqual(TokenKind.ident, t4.kind);
    try std.testing.expectEqualStrings("senderEmail", t4.raw);

    const t5 = l.next();
    try std.testing.expectEqual(TokenKind.template_tail, t5.kind);
    try std.testing.expectEqualStrings(">`", t5.raw[1..]);
}

test "lex template literal with call expression and angle brackets" {
    var l = Lexer.init("`${htmlEscape(senderName)} <${senderEmail}>`");

    const t1 = l.next();
    try std.testing.expectEqual(TokenKind.template_head, t1.kind);

    try std.testing.expectEqual(TokenKind.ident, l.next().kind);
    try std.testing.expectEqual(TokenKind.lparen, l.next().kind);
    try std.testing.expectEqual(TokenKind.ident, l.next().kind);
    try std.testing.expectEqual(TokenKind.rparen, l.next().kind);

    const t6 = l.next();
    try std.testing.expectEqual(TokenKind.template_middle, t6.kind);
    try std.testing.expectEqualStrings("} <${", t6.raw);

    try std.testing.expectEqual(TokenKind.ident, l.next().kind);

    const t8 = l.next();
    try std.testing.expectEqual(TokenKind.template_tail, t8.kind);
    try std.testing.expectEqualStrings("}>`", t8.raw);
}
