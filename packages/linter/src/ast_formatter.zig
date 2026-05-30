const std = @import("std");
const common = @import("common");

const ast = @import("ast.zig");
const parser = @import("parser.zig");
const lexer = @import("lexer.zig");

const Arena = ast.Arena;
const Node = ast.Node;
const NodeId = ast.NodeId;
const NULL_NODE = ast.NULL_NODE;
const Comment = lexer.Lexer.Comment;

const FormatterOptions = common.FormatterOptions;
const QuoteStyle = common.QuoteStyle;
const Semicolons = common.Semicolons;
const TrailingComma = common.TrailingComma;
const EndOfLine = common.EndOfLine;

pub fn format(source: []const u8, options: common.FormatterOptions, alloc: std.mem.Allocator) !?[]u8 {
    return formatAst(source, options, alloc);
}

pub fn formatAst(source: []const u8, options: FormatterOptions, alloc: std.mem.Allocator) !?[]u8 {
    var arena_backing = std.heap.ArenaAllocator.init(alloc);
    const a = arena_backing.allocator();

    var diags = parser.diagnostics.DiagnosticList{};
    var node_arena = Arena.init(a);
    const parse_opts = parser.ParseOptions{
        .typescript = true,
        .jsx = true,
        .source_type = .module,
        .check = false,
    };

    var p = parser.Parser.init(source, "formatter", &node_arena, a, &diags, parse_opts);
    const program_id = p.parseProgram() catch {
        arena_backing.deinit();
        return null;
    };
    var buf = std.ArrayListUnmanaged(u8).empty;
    try buf.ensureTotalCapacity(alloc, source.len + source.len / 2);
    var fmtr = Formatter{
        .arena = &node_arena,
        .buf = buf,
        .alloc = alloc,
        .indent_level = 0,
        .col = 0,
        .opts = options,
        .src = source,
        .comments = try alloc.dupe(lexer.Lexer.Comment, p.comments.items),
        .comment_index = 0,
        .pending_newlines = 0,
    };
    errdefer {
        alloc.free(fmtr.comments);
        fmtr.buf.deinit(alloc);
    }
    try fmtr.gen(program_id);
    try fmtr.emitRemainingComments();
    const result = try fmtr.buf.toOwnedSlice(alloc);
    alloc.free(fmtr.comments);
    arena_backing.deinit();
    return result;
}

const Formatter = struct {
    arena: *const Arena,
    buf: std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    indent_level: usize,
    col: usize,
    opts: FormatterOptions,
    src: []const u8,
    comments: []const Comment,
    comment_index: usize,
    pending_newlines: usize,
    in_jsx_attr: bool = false,
    needs_leading_semicolon: bool = false,
    skip_next_newline: bool = false,

    fn flushPendingNewlines(self: *Formatter) !void {
        if (self.pending_newlines == 0) return;

        const eol: []const u8 = switch (self.opts.endOfLine) {
            .lf, .auto => "\n",
            .crlf => "\r\n",
            .cr => "\r",
        };
        if (eol.len == 1) {
            try self.buf.appendNTimes(self.alloc, eol[0], self.pending_newlines);
        } else {
            var i: usize = 0;
            while (i < self.pending_newlines) : (i += 1) {
                try self.buf.appendSlice(self.alloc, eol);
            }
        }

        self.pending_newlines = 0;
        self.col = 0;

        const indent_count = if (self.opts.useTabs) self.indent_level else self.indent_level * self.opts.tabWidth;
        if (indent_count > 0) {
            const indent_char: u8 = if (self.opts.useTabs) '\t' else ' ';
            try self.buf.appendNTimes(self.alloc, indent_char, indent_count);
        }
        self.col = indent_count;
    }

    fn w(self: *Formatter, s: []const u8) !void {
        try self.flushPendingNewlines();
        try self.buf.appendSlice(self.alloc, s);
        self.col = advanceCol(self.col, s);
    }

    fn wb(self: *Formatter, b: u8) !void {
        try self.flushPendingNewlines();
        try self.buf.append(self.alloc, b);
        self.col += 1;
    }

    fn ws(self: *Formatter) !void {
        try self.wb(' ');
    }

    fn nl(self: *Formatter) void {
        self.pending_newlines += 1;
    }

    /// Last non-whitespace byte already written to the buffer, or 0 if none.
    /// Used to decide whether a defensive leading semicolon is still needed.
    fn lastWrittenByte(self: *const Formatter) u8 {
        var i = self.buf.items.len;
        while (i > 0) : (i -= 1) {
            const c = self.buf.items[i - 1];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return c;
        }
        return 0;
    }

    fn indent(self: *Formatter) void {
        self.indent_level += 1;
    }

    fn dedent(self: *Formatter) void {
        if (self.indent_level > 0) self.indent_level -= 1;
    }

    fn colAfterStr(s: []const u8) usize {
        var col: usize = 0;
        for (s) |c| {
            if (c == '\n') {
                col = 0;
            } else {
                col += 1;
            }
        }
        return col;
    }

    fn advanceCol(start_col: usize, s: []const u8) usize {
        var col = start_col;
        for (s) |c| {
            if (c == '\n') {
                col = 0;
            } else {
                col += 1;
            }
        }
        return col;
    }

    fn colAfter(self: *const Formatter, s: []const u8) usize {
        return advanceCol(self.col, s);
    }

    fn fitsOnLine(self: *const Formatter, extra: usize) bool {
        return self.col + extra <= self.opts.printWidth;
    }

    fn shouldBreak(self: *const Formatter, extra: usize) bool {
        return !self.fitsOnLine(extra);
    }

    fn emitCommentsBefore(self: *Formatter, pos: u32) !void {
        while (self.comment_index < self.comments.len and self.comments[self.comment_index].span.start <= pos) {
            const c = self.comments[self.comment_index];
            if (c.raw.len > 0) {
                const inline_before = self.hasCodeBeforeOnLine(c.span.start);
                const inline_after = self.hasCodeAfterOnLine(c.span.end);

                if (inline_before and self.pending_newlines > 0) {
                    self.pending_newlines = 0;
                }

                if (!inline_before and self.pending_newlines == 0 and self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] != '\n') {
                    self.nl();
                }

                if (inline_before) try self.ensureInlineSpace();
                try self.w(c.raw);

                if (self.isBlockComment(c.raw) and inline_after) {
                    try self.ensureInlineSpace();
                } else if (!inline_after) {
                    self.nl();
                }
            }
            self.comment_index += 1;
        }
    }

    fn ensureInlineSpace(self: *Formatter) !void {
        if (self.pending_newlines > 0 or self.buf.items.len == 0) return;

        const last = self.buf.items[self.buf.items.len - 1];
        if (last != ' ' and last != '\n' and last != '\t') {
            try self.ws();
        }
    }

    fn isBlockComment(self: *const Formatter, raw: []const u8) bool {
        _ = self;
        return std.mem.startsWith(u8, raw, "/*");
    }

    fn hasCodeBeforeOnLine(self: *const Formatter, pos: u32) bool {
        var i: usize = @min(@as(usize, pos), self.src.len);
        while (i > 0) {
            const c = self.src[i - 1];
            if (c == '\n') break;
            if (c != ' ' and c != '\t' and c != '\r') return true;
            i -= 1;
        }
        return false;
    }

    fn hasCodeAfterOnLine(self: *const Formatter, pos: u32) bool {
        var i: usize = @min(@as(usize, pos), self.src.len);
        while (i < self.src.len) : (i += 1) {
            const c = self.src[i];
            if (c == '\n') break;
            if (c != ' ' and c != '\t' and c != '\r') return true;
        }
        return false;
    }

    fn findClosingDelimiter(self: *const Formatter, open_pos: u32, open: u8, close: u8) ?u32 {
        const start = @as(usize, open_pos);
        if (start >= self.src.len or self.src[start] != open) return null;

        var depth: usize = 0;
        var i: usize = start;
        const len = self.src.len;
        while (i < len) : (i += 1) {
            const c = self.src[i];
            if (c == '"' or c == '\'') {
                const q = c;
                i += 1;
                while (i < len and self.src[i] != q) {
                    if (self.src[i] == '\\') i += 1;
                    i += 1;
                }
                continue;
            }
            if (c == '`') {
                i += 1;
                while (i < len and self.src[i] != '`') {
                    if (self.src[i] == '\\') i += 1;
                    i += 1;
                }
                continue;
            }
            if (c == '/' and i + 1 < len) {
                if (self.src[i + 1] == '/') {
                    while (i < len and self.src[i] != '\n') i += 1;
                    continue;
                }
                if (self.src[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < len and !(self.src[i] == '*' and self.src[i + 1] == '/')) i += 1;
                    i += 1;
                    continue;
                }
            }
            if (c == open) depth += 1;
            if (c == close) {
                depth -= 1;
                if (depth == 0) return @intCast(i);
            }
        }
        return null;
    }

    fn findClosingBrace(self: *const Formatter, p: u32) ?u32 {
        return self.findClosingDelimiter(p, '{', '}');
    }

    fn findClosingBracket(self: *const Formatter, p: u32) ?u32 {
        return self.findClosingDelimiter(p, '[', ']');
    }

    fn lineOf(self: *const Formatter, pos: u32) usize {
        var line: usize = 0;
        const limit = @min(@as(usize, pos), self.src.len);
        for (self.src[0..limit]) |c| {
            if (c == '\n') line += 1;
        }
        return line;
    }

    fn countBlankLines(self: *const Formatter, from: usize, to: usize) usize {
        var count: usize = 0;
        var i = from;
        while (i < to) {
            if (self.src[i] == '\n') {
                var j = i + 1;
                while (j < to and (self.src[j] == ' ' or self.src[j] == '\t' or self.src[j] == '\r')) j += 1;
                if (j < to and self.src[j] == '\n') {
                    count += 1;
                }
            }
            i += 1;
        }
        return count;
    }

    fn separateStatements(self: *Formatter, prev_start: u32, next_start: u32) !void {
        const to = @min(@as(usize, next_start), self.src.len);
        const from = @min(@as(usize, prev_start), to);
        if (from >= to) { self.pending_newlines = @max(1, self.pending_newlines); return; }

        const skip_newline = self.skip_next_newline;
        self.skip_next_newline = false;

        var pos = from;
        var emitted_any = false;

        while (self.comment_index < self.comments.len and self.comments[self.comment_index].span.start < to) {
            const c = self.comments[self.comment_index];
            if (c.raw.len == 0) {
                self.comment_index += 1;
                continue;
            }

            const inline_before = self.hasCodeBeforeOnLine(c.span.start);
            const inline_after = self.hasCodeAfterOnLine(c.span.end);

            const blanks_before = self.countBlankLines(pos, c.span.start);

            if (inline_before) {
                if (!emitted_any) {
                    const needed: usize = 1 + blanks_before;
                    if (self.pending_newlines < needed) self.pending_newlines = needed;
                } else if (blanks_before > 0) {
                    if (self.pending_newlines < 1 + blanks_before) self.pending_newlines = 1 + blanks_before;
                }
                if (self.pending_newlines > 0) self.pending_newlines = 0;
                try self.ensureInlineSpace();
                try self.w(c.raw);
                if (self.isBlockComment(c.raw) and inline_after) {
                    try self.ensureInlineSpace();
                } else if (!inline_after) {
                    self.nl();
                }
                self.comment_index += 1;
                pos = @min(@as(usize, c.span.end), to);
                emitted_any = true;
                continue;
            }

            if (!emitted_any) {
                const needed: usize = 1 + blanks_before;
                if (self.pending_newlines < needed) self.pending_newlines = needed;
            } else {
                if (blanks_before > 0) {
                    const needed: usize = 1 + blanks_before;
                    if (self.pending_newlines < needed) self.pending_newlines = needed;
                }
                if (self.pending_newlines < 1) self.pending_newlines = 1;
            }

            try self.w(c.raw);

            if (self.isBlockComment(c.raw) and inline_after) {
                try self.ensureInlineSpace();
            } else if (!inline_after) {
                self.nl();
            }

            self.comment_index += 1;
            pos = @min(@as(usize, c.span.end), to);
            emitted_any = true;
        }

        const trailing_blanks = self.countBlankLines(pos, to);

        if (!emitted_any) {
            if (trailing_blanks > 0) {
                self.pending_newlines = @max(self.pending_newlines, 1 + trailing_blanks);
            } else if (!skip_newline) {
                self.pending_newlines = @max(self.pending_newlines, 1);
            }
        } else {
            if (trailing_blanks > 0) {
                self.pending_newlines = @max(self.pending_newlines, 1 + trailing_blanks);
            }
        }
    }

    fn emitRemainingComments(self: *Formatter) !void {
        while (self.comment_index < self.comments.len) {
            const c = self.comments[self.comment_index];
            if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] != '\n') {
                self.nl();
            }
            try self.w(c.raw);
            self.comment_index += 1;
        }
    }

    fn gen(self: *Formatter, id: NodeId) anyerror!void {
        const node = self.arena.get(id);
        try self.emitCommentsBefore(node.span().start);
        switch (node.*) {
            .program => |p| try self.genProgram(p),
            .block => |b| try self.genBlock(b),
            .expr_stmt => |s| {
                try self.gen(s.expr);
                if (self.opts.semi) try self.w(";");
            },
            .empty_stmt => {
                if (self.needs_leading_semicolon) try self.w(";");
            },
            .raw_js => |r| try self.w(r.code),
            .var_decl => |v| try self.genVarDecl(v),
            .fn_decl => |f| try self.genFnDecl(f),
            .class_decl => |c| try self.genClassDecl(c),
            .return_stmt => |r| try self.genReturn(r),
            .if_stmt => |s| try self.genIf(s),
            .for_stmt => |s| try self.genFor(s),
            .while_stmt => |s| try self.genWhile(s),
            .switch_stmt => |s| try self.genSwitch(s),
            .try_stmt => |s| try self.genTry(s),
            .throw_stmt => |s| {
                try self.w("throw ");
                try self.gen(s.argument);
                if (self.opts.semi) try self.w(";");
            },
            .break_continue => |s| try self.genBreakContinue(s),
            .debugger_stmt => try self.w("debugger;"),
            .labeled_stmt => |s| {
                try self.gen(s.label);
                try self.w(": ");
                try self.gen(s.body);
            },
            .import_decl => |imp| try self.genImport(imp),
            .export_decl => |exp| try self.genExport(exp),
            .ident => |i| try self.w(i.name),
            .num_lit => |n| try self.w(n.raw),
            .str_lit => |s| try self.genStrLit(s.raw),
            .bool_lit => |b| try self.w(if (b.value) "true" else "false"),
            .null_lit => try self.w("null"),
            .undefined_ref => try self.w("undefined"),
            .regex_lit => |r| try self.w(r.raw),
            .binary_expr => |b| try self.genBinary(b),
            .unary_expr => |u| try self.genUnary(u),
            .update_expr => |u| try self.genUpdate(u),
            .assign_expr => |a| try self.genAssign(a),
            .call_expr => |c| try self.genCall(c),
            .member_expr => |m| try self.genMember(m),
            .new_expr => |n| try self.genNew(n),
            .new_target => try self.w("new.target"),
            .seq_expr => |s| try self.genSeq(s),
            .cond_expr => |c| try self.genCond(c),
            .arrow_fn => |f| try self.genArrow(f),
            .fn_expr => |f| try self.genFnExpr(f),
            .class_expr => |c| try self.genClassExpr(c),
            .object_expr => |o| try self.genObject(o),
            .array_expr => |a| try self.genArray(a),
            .template_lit => |t| try self.genTemplate(t),
            .tagged_template => |t| {
                try self.gen(t.tag);
                try self.genTemplate(self.arena.get(t.quasi).template_lit);
            },
            .spread_elem => |s| {
                try self.w("...");
                if (self.arena.get(s.argument).* == .cond_expr) {
                    try self.w("(");
                    try self.gen(s.argument);
                    try self.w(")");
                } else try self.gen(s.argument);
            },
            .yield_expr => |y| try self.genYield(y),
            .await_expr => |a| {
                try self.w("await ");
                try self.gen(a.argument);
            },
            .rest_elem => |r| {
                try self.w("...");
                try self.gen(r.argument);
            },
            .assign_pat => |p| {
                try self.gen(p.left);
                try self.w(" = ");
                try self.gen(p.right);
            },
            .object_pat => |p| try self.genObjectPat(p),
            .array_pat => |p| try self.genArrayPat(p),
            .ts_type_annotation => |t| try self.genTsTypeAnnotation(t),
            .ts_type_ref => |t| try self.genTsTypeRef(t),
            .ts_qualified_name => |t| try self.genTsQualifiedName(t),
            .ts_union => |t| try self.genTsUnion(t),
            .ts_intersection => |t| try self.genTsIntersection(t),
            .ts_array_type => |t| try self.genTsArrayType(t),
            .ts_tuple => |t| try self.genTsTuple(t),
            .ts_keyword => |t| try self.genTsKeyword(t),
            .ts_interface => |t| try self.genTsInterface(t),
            .ts_type_alias => |t| try self.genTsTypeAlias(t),
            .ts_enum => |t| try self.genTsEnum(t),
            .ts_namespace => |t| try self.genTsNamespace(t),
            .ts_non_null => |e| {
                try self.gen(e.expr);
                try self.w("!");
            },
            .ts_as_expr => |e| {
                try self.w("(");
                try self.gen(e.expr);
                try self.w(" as ");
                try self.gen(e.type_ann);
                try self.w(")");
            },
            .ts_satisfies => |e| {
                try self.gen(e.expr);
                try self.w(" satisfies ");
                try self.gen(e.type_ann);
            },
            .ts_instantiation => |e| {
                try self.gen(e.expr);
                try self.w("<");
                for (e.type_args, 0..) |ta, i| {
                    if (i > 0) try self.w(", ");
                    try self.gen(ta);
                }
                try self.w(">");
            },
            .ts_type_assert => |e| {
                try self.w("<");
                try self.gen(e.type_ann);
                try self.w(">");
                try self.gen(e.expr);
            },
            .jsx_element => |e| try self.genJsxElement(e),
            .jsx_fragment => |e| try self.genJsxFragment(e),
            .jsx_expr_container => |e| try self.genJsxExprContainer(e),
            .jsx_text => |e| try self.w(e.raw),
            .jsx_name => |e| try self.w(e.name),
            .jsx_member_expr => |e| {
                try self.gen(e.object);
                try self.w(".");
                try self.gen(e.prop);
            },
            .import_meta => try self.w("import.meta"),
            .import_call => |c| {
                try self.w("import(");
                try self.gen(c.source);
                try self.w(")");
            },
        }
    }

    fn genProgram(self: *Formatter, p: ast.Program) !void {
        var prev_stmt_start: u32 = 0;
        var emitted = false;
        for (p.body, 0..) |stmt, i| {
            const stmt_node = self.arena.get(stmt);
            const stmt_start = stmt_node.span().start;

            if (stmt_node.* == .empty_stmt) {
                // Keep an empty statement only as an ASI guard: when the next
                // statement starts with an ASI-sensitive token and the preceding
                // output does not already terminate with a semicolon. Otherwise
                // drop it so a bare `;` never leaves a blank line or a redundant
                // leading semicolon.
                const guard = i + 1 < p.body.len and
                    self.needsLeadingSemicolon(self.arena.get(p.body[i + 1])) and
                    self.lastWrittenByte() != ';';
                if (!guard) continue;
                if (emitted) try self.separateStatements(prev_stmt_start, stmt_start);
                self.needs_leading_semicolon = true;
                self.skip_next_newline = true;
                try self.gen(stmt);
                self.needs_leading_semicolon = false;
                prev_stmt_start = stmt_start;
                emitted = true;
                continue;
            }

            if (emitted) try self.separateStatements(prev_stmt_start, stmt_start);
            try self.gen(stmt);
            prev_stmt_start = stmt_start;
            emitted = true;
        }
        try self.emitRemainingComments();
    }

    fn genBlock(self: *Formatter, b: ast.Block) !void {
        try self.w("{");
        self.indent();
        var prev_stmt_start: u32 = 0;
        for (b.body, 0..) |stmt, i| {
            const stmt_node = self.arena.get(stmt);
            const stmt_start = stmt_node.span().start;
            if (i == 0) {
                self.nl();
            } else {
                try self.separateStatements(prev_stmt_start, stmt_start);
            }
            if (stmt_node.* == .empty_stmt and i + 1 < b.body.len) {
                const next_node = self.arena.get(b.body[i + 1]);
                self.needs_leading_semicolon = self.needsLeadingSemicolon(next_node);
                if (self.needs_leading_semicolon) {
                    self.skip_next_newline = true;
                }
            }
            try self.gen(stmt);
            self.needs_leading_semicolon = false;
            prev_stmt_start = stmt_start;
        }
        if (self.findClosingBrace(b.span.start)) |close_brace| {
            try self.emitCommentsBefore(close_brace);
        }
        self.dedent();
        if (b.body.len == 0 and self.pending_newlines > 0) {
        } else if (b.body.len > 0 and self.pending_newlines == 0) {
            self.nl();
        }
        try self.w("}");
    }

    fn genVarDecl(self: *Formatter, v: ast.VarDecl) !void {
        if (v.is_await) try self.w("await ");
        try self.w(switch (v.kind) {
            .@"var" => "var",
            .let => "let",
            .@"const" => "const",
            .using => "using",
        });
        try self.w(" ");
        const decl_width = v.declarators.len * 20;
        const wrap = v.declarators.len > 1 and self.shouldBreak(decl_width);
        if (wrap) {
            self.indent();
            for (v.declarators, 0..) |d, i| {
                if (i > 0) try self.w(",");
                self.nl();
                try self.genVarDeclarator(d);
            }
            self.dedent();
        } else {
            for (v.declarators, 0..) |d, i| {
                if (i > 0) try self.w(", ");
                try self.genVarDeclarator(d);
            }
        }
        if (self.opts.semi) try self.w(";");
    }

    fn genVarDeclarator(self: *Formatter, d: ast.VarDeclarator) !void {
        try self.gen(d.id);
        if (d.type_ann) |ta| {
            try self.w(": ");
            try self.gen(ta);
        }
        if (d.init) |init_val| {
            try self.w(" = ");
            try self.gen(init_val);
        }
    }

    fn genFnDecl(self: *Formatter, f: ast.FnDecl) !void {
        if (f.is_async) try self.w("async ");
        try self.w("function");
        if (f.is_generator) try self.w("*");
        if (f.id) |id| {
            try self.w(" ");
            try self.gen(id);
        }
        try self.genTsTypeParams(f.type_params);
        try self.genFnParamsWithTypes(f.params, f.param_types);
        if (f.return_type) |rt| {
            try self.w(": ");
            try self.gen(rt);
        }
        try self.w(" ");
        try self.gen(f.body);
    }

    fn genFnParamsWithTypes(self: *Formatter, params: []const NodeId, param_types: []const ?NodeId) !void {
        const wrap = params.len > 1 and self.shouldBreak(params.len * 10);
        try self.w("(");
        if (wrap) {
            self.indent();
            for (params, 0..) |p, i| {
                if (i > 0) try self.w(",");
                self.nl();
                try self.gen(p);
                if (i < param_types.len) {
                    if (param_types[i]) |ta| {
                        try self.w(": ");
                        try self.gen(ta);
                    }
                }
            }
            if (self.opts.trailingComma == .all) {
                try self.w(",");
            }
            self.dedent();
            self.nl();
        } else {
            for (params, 0..) |p, i| {
                if (i > 0) try self.w(", ");
                try self.gen(p);
                if (i < param_types.len) {
                    if (param_types[i]) |ta| {
                        try self.w(": ");
                        try self.gen(ta);
                    }
                }
            }
        }
        try self.w(")");
    }

    fn genClassDecl(self: *Formatter, c: ast.ClassDecl) !void {
        try self.w("class");
        if (c.id) |id| {
            try self.w(" ");
            try self.gen(id);
        }
        try self.genTsTypeParams(c.type_params);
        if (c.super_class) |sc| {
            try self.w(" extends ");
            const wrap_super = switch (self.arena.get(sc).*) {
                .cond_expr, .seq_expr, .assign_expr, .arrow_fn => true,
                else => false,
            };
            if (wrap_super) try self.w("(");
            try self.gen(sc);
            if (wrap_super) try self.w(")");
        }
        try self.w(" {");
        self.indent();
        for (c.body) |m| {
            self.nl();
            try self.genClassMember(m);
        }
        self.dedent();
        if (c.body.len > 0) self.nl();
        try self.w("}");
    }

    fn genClassExpr(self: *Formatter, c: ast.ClassExpr) !void {
        try self.w("class");
        if (c.id) |id| {
            try self.w(" ");
            try self.gen(id);
        }
        try self.genTsTypeParams(c.type_params);
        if (c.super_class) |sc| {
            try self.w(" extends ");
            const wrap_super = switch (self.arena.get(sc).*) {
                .cond_expr, .seq_expr, .assign_expr, .arrow_fn => true,
                else => false,
            };
            if (wrap_super) try self.w("(");
            try self.gen(sc);
            if (wrap_super) try self.w(")");
        }
        try self.w(" {");
        self.indent();
        for (c.body) |m| {
            self.nl();
            try self.genClassMember(m);
        }
        self.dedent();
        if (c.body.len > 0) self.nl();
        try self.w("}");
    }

    fn genClassMember(self: *Formatter, m: ast.ClassMember) !void {
        for (m.decorators) |d| {
            try self.w("@");
            try self.gen(d);
            self.nl();
        }
        if (m.accessibility) |acc| {
            try self.w(switch (acc) {
                .public => "public ",
                .private => "private ",
                .protected => "protected ",
            });
        }
        if (m.is_static) try self.w("static ");
        if (m.is_readonly) try self.w("readonly ");
        if (m.is_abstract) try self.w("abstract ");
        switch (m.kind) {
            .constructor => {
                try self.w("constructor(");
                if (m.value) |v| {
                    const f = self.arena.get(v).fn_expr;
                    for (f.params, 0..) |p, i| {
                        if (i > 0) try self.w(", ");
                        try self.gen(p);
                    }
                }
                try self.w(") ");
                if (m.value) |v| {
                    try self.gen(self.arena.get(v).fn_expr.body);
                } else {
                    try self.w("{}");
                }
            },
            .method, .getter, .setter => {
                if (m.value) |v| {
                    const f = self.arena.get(v).fn_expr;
                    if (f.is_async) try self.w("async ");
                    if (f.is_generator) try self.w("*");
                }
                if (m.kind == .getter) try self.w("get ");
                if (m.kind == .setter) try self.w("set ");
                if (m.is_computed) try self.w("[");
                try self.gen(m.key);
                if (m.is_computed) try self.w("]");
                if (m.value) |v| {
                    const f = self.arena.get(v).fn_expr;
                    try self.w("(");
                    for (f.params, 0..) |p, i| {
                        if (i > 0) try self.w(", ");
                        try self.gen(p);
                    }
                    try self.w(") ");
                    try self.gen(f.body);
                } else {
                    if (self.opts.semi) try self.w(";");
                }
            },
            .field, .auto_accessor => {
                if (m.kind == .auto_accessor) try self.w("accessor ");
                if (m.is_computed) try self.w("[");
                try self.gen(m.key);
                if (m.is_computed) try self.w("]");
                if (m.is_optional) try self.w("?");
                if (m.type_ann) |ta| {
                    try self.w(": ");
                    try self.gen(ta);
                }
                if (m.value) |v| {
                    try self.w(" = ");
                    try self.gen(v);
                }
                if (self.opts.semi) try self.w(";");
            },
            .static_block => {
                if (m.value) |v| try self.gen(v);
            },
        }
    }

    fn genReturn(self: *Formatter, r: ast.ReturnStmt) !void {
        try self.w("return");
        if (r.argument) |a| {
            try self.w(" ");
            try self.gen(a);
        }
        if (self.opts.semi) try self.w(";");
    }

    fn genIf(self: *Formatter, s: ast.IfStmt) !void {
        try self.w("if (");
        try self.gen(s.cond);
        try self.w(") ");
        try self.genConsequent(s.consequent);
        if (s.alternate) |alt| {
            try self.w(" else ");
            if (self.arena.get(alt).* == .if_stmt) {
                try self.gen(alt);
            } else {
                try self.genConsequent(alt);
            }
        }
    }

    fn genConsequent(self: *Formatter, node: NodeId) !void {
        const n = self.arena.get(node);
        if (n.* == .block) {
            try self.gen(node);
        } else {
            self.indent();
            self.nl();
            try self.gen(node);
            self.dedent();
        }
    }

    fn genForInit(self: *Formatter, id: NodeId) !void {
        const node = self.arena.get(id);
        if (node.* == .var_decl) {
            try self.genVarDeclNoSemi(node.var_decl);
        } else {
            try self.gen(id);
        }
    }

    fn genVarDeclNoSemi(self: *Formatter, v: ast.VarDecl) !void {
        if (v.is_await) try self.w("await ");
        try self.w(switch (v.kind) {
            .@"var" => "var",
            .let => "let",
            .@"const" => "const",
            .using => "using",
        });
        try self.w(" ");
        for (v.declarators, 0..) |d, i| {
            if (i > 0) try self.w(", ");
            try self.gen(d.id);
            if (d.type_ann) |ta| {
                try self.w(": ");
                try self.gen(ta);
            }
            if (d.init) |init_val| {
                try self.w(" = ");
                try self.gen(init_val);
            }
        }
    }

    fn genFor(self: *Formatter, s: ast.ForStmt) !void {
        switch (s.kind) {
            .plain => {
                try self.w("for (");
                if (s.init) |i| {
                    try self.genForInit(i);
                    try self.w(";");
                } else try self.w(";");
                if (s.cond) |t| {
                    try self.w(" ");
                    try self.gen(t);
                }
                try self.w(";");
                if (s.update) |u| {
                    try self.w(" ");
                    try self.gen(u);
                }
                try self.w(") ");
            },
            .in => {
                try self.w("for (");
                if (s.init) |i| try self.genForInit(i);
                try self.w(" in ");
                if (s.update) |r| try self.gen(r);
                try self.w(") ");
            },
            .of => {
                if (s.is_await) try self.w("for await (") else try self.w("for (");
                if (s.init) |i| try self.genForInit(i);
                try self.w(" of ");
                if (s.update) |r| try self.gen(r);
                try self.w(") ");
            },
        }
        try self.genConsequent(s.body);
    }

    fn genWhile(self: *Formatter, s: ast.WhileStmt) !void {
        if (s.is_do) {
            try self.w("do ");
            try self.genConsequent(s.body);
            try self.w(" while (");
            try self.gen(s.cond);
            try self.w(");");
        } else {
            try self.w("while (");
            try self.gen(s.cond);
            try self.w(") ");
            try self.genConsequent(s.body);
        }
    }

    fn genSwitch(self: *Formatter, s: ast.SwitchStmt) !void {
        try self.w("switch (");
        try self.gen(s.disc);
        try self.w(") {");
        self.indent();
        for (s.cases) |c| {
            self.nl();
            if (c.cond) |t| {
                try self.w("case ");
                try self.gen(t);
                try self.w(":");
            } else {
                try self.w("default:");
            }
            self.indent();
            for (c.body) |stmt| {
                self.nl();
                try self.gen(stmt);
            }
            self.dedent();
        }
        self.dedent();
        self.nl();
        try self.w("}");
    }

    fn genTry(self: *Formatter, s: ast.TryStmt) !void {
        try self.w("try ");
        try self.gen(s.block);
        if (s.handler) |h| {
            try self.w(" catch");
            if (h.param) |p| {
                try self.w(" (");
                try self.gen(p);
                try self.w(")");
            }
            try self.w(" ");
            try self.gen(h.body);
        }
        if (s.finalizer) |f| {
            try self.w(" finally ");
            try self.gen(f);
        }
    }

    fn genBreakContinue(self: *Formatter, s: ast.BreakContinue) !void {
        try self.w(if (s.is_break) "break" else "continue");
        if (s.label) |l| {
            try self.w(" ");
            try self.gen(l);
        }
        if (self.opts.semi) try self.w(";");
    }

    fn genImport(self: *Formatter, imp: ast.ImportDecl) !void {
        try self.w("import ");
        if (imp.is_type_only) try self.w("type ");
        if (imp.is_deferred) try self.w("defer ");
        if (imp.specifiers.len == 0) {
            try self.gen(imp.source);
        } else {
            var named_start: usize = 0;
            for (imp.specifiers, 0..) |s, i| {
                switch (s.kind) {
                    .default => {
                        try self.gen(s.local);
                        named_start = i + 1;
                    },
                    .namespace => {
                        if (i > 0) try self.w(", ");
                        try self.w("* as ");
                        try self.gen(s.local);
                        named_start = i + 1;
                    },
                    .named => {},
                }
            }
            const named = imp.specifiers[named_start..];
            if (named.len > 0) {
                if (named_start > 0) try self.w(", ");
                try self.w("{");
                for (named, 0..) |s, i| {
                    if (i > 0) try self.w(", ");
                    if (s.imported) |im| {
                        try self.gen(im);
                        try self.w(" as ");
                    }
                    try self.gen(s.local);
                }
                try self.w("}");
            }
            try self.w(" from ");
            try self.gen(imp.source);
        }
        if (imp.attributes.len > 0) {
            try self.w(switch (imp.attribute_syntax) {
                .assert => " assert { ",
                .with => " with { ",
                .none => " { ",
            });
            for (imp.attributes, 0..) |a, i| {
                if (i > 0) try self.w(", ");
                try self.w(a.key);
                try self.w(": \"");
                try self.w(a.value);
                try self.w("\"");
            }
            try self.w(" }");
        }
        if (self.opts.semi) try self.w(";");
    }

    fn genExport(self: *Formatter, exp: ast.ExportDecl) !void {
        switch (exp.kind) {
            .decl => |d| {
                try self.w("export ");
                try self.gen(d);
            },
            .default_expr => |e| {
                try self.w("export default ");
                const is_decl = switch (self.arena.get(e).*) {
                    .fn_decl, .class_decl => true,
                    else => false,
                };
                if (is_decl) {
                    try self.gen(e);
                } else {
                    try self.gen(e);
                    if (self.opts.semi) try self.w(";");
                }
            },
            .default_decl => |d| {
                try self.w("export default ");
                try self.gen(d);
            },
            .named => |n| {
                try self.w("export ");
                if (n.is_type_only) try self.w("type ");
                try self.w("{");
                for (n.specifiers, 0..) |s, i| {
                    if (i > 0) try self.w(", ");
                    try self.gen(s.local);
                    const local_name = self.arena.get(s.local).ident.name;
                    const exported_name = self.arena.get(s.exported).ident.name;
                    if (!std.mem.eql(u8, local_name, exported_name)) {
                        try self.w(" as ");
                        try self.gen(s.exported);
                    }
                }
                try self.w("}");
                if (n.source) |src| {
                    try self.w(" from ");
                    try self.gen(src);
                }
                if (self.opts.semi) try self.w(";");
            },
            .all => |a| {
                try self.w("export ");
                if (a.is_type_only) try self.w("type ");
                try self.w("*");
                if (a.exported) |e| {
                    try self.w(" as ");
                    try self.gen(e);
                }
                try self.w(" from ");
                try self.gen(a.source);
                if (self.opts.semi) try self.w(";");
            },
        }
    }

    fn binPrecedence(op: ast.BinOp) u8 {
        return switch (op) {
            .comma => 1,
            .pipe2, .question2 => 3,
            .amp2 => 4,
            .pipe => 5,
            .caret => 6,
            .amp => 7,
            .eq2, .eq3, .neq, .neq2 => 8,
            .lt, .lte, .gt, .gte, .in, .instanceof => 9,
            .lt2, .gt2, .gt3 => 10,
            .plus, .minus => 11,
            .star, .slash, .percent => 12,
            .star2 => 13,
        };
    }

    fn binaryChildNeedsParens(self: *Formatter, child_id: NodeId, parent_op: ast.BinOp, is_right: bool) bool {
        const child = self.arena.get(child_id);
        return switch (child.*) {
            .assign_expr, .seq_expr, .cond_expr, .arrow_fn, .yield_expr => true,
            .binary_expr => |b| {
                const child_prec = binPrecedence(b.op);
                const parent_prec = binPrecedence(parent_op);
                if (child_prec < parent_prec) return true;
                if (child_prec > parent_prec) return false;
                if (parent_op == .star2) return !is_right;
                if (!is_right) return false;
                return switch (parent_op) {
                    .minus, .slash, .percent, .lt2, .gt2, .gt3, .lt, .lte, .gt, .gte, .in, .instanceof, .eq2, .eq3, .neq, .neq2 => true,
                    else => false,
                };
            },
            else => false,
        };
    }

    fn genBinaryChild(self: *Formatter, child_id: NodeId, parent_op: ast.BinOp, is_right: bool) !void {
        const wrap = self.binaryChildNeedsParens(child_id, parent_op, is_right);
        if (wrap) try self.w("(");
        try self.gen(child_id);
        if (wrap) try self.w(")");
    }

    fn genBinary(self: *Formatter, b: ast.BinaryExpr) !void {
        try self.genBinaryChild(b.left, b.op, false);

        const op_sym = switch (b.op) {
            .eq2 => "==",
            .eq3 => "===",
            .neq => "!=",
            .neq2 => "!==",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .star2 => "**",
            .amp => "&",
            .pipe => "|",
            .caret => "^",
            .amp2 => "&&",
            .pipe2 => "||",
            .question2 => "??",
            .lt2 => "<<",
            .gt2 => ">>",
            .gt3 => ">>>",
            .in => "in",
            .instanceof => "instanceof",
            .comma => ",",
        };

        const right_node = self.arena.get(b.right);
        const right_len = right_node.span().end - right_node.span().start;

        const need_wrap = b.op != .comma and self.shouldBreak(op_sym.len + 2 + right_len);

        if (need_wrap) {
            switch (self.opts.operatorPosition) {
                .end => {
                    try self.ws();
                    try self.w(op_sym);
                    self.indent();
                    self.nl();
                    try self.genBinaryChild(b.right, b.op, true);
                    self.dedent();
                },
                .start => {
                    self.indent();
                    self.nl();
                    try self.w(op_sym);
                    try self.ws();
                    try self.genBinaryChild(b.right, b.op, true);
                    self.dedent();
                },
            }
        } else {
            try self.ws();
            try self.w(op_sym);
            try self.ws();
            try self.genBinaryChild(b.right, b.op, true);
        }
    }

    fn unaryArgNeedsParens(node: *const Node) bool {
        return switch (node.*) {
            .binary_expr, .assign_expr, .seq_expr, .cond_expr, .arrow_fn, .yield_expr => true,
            else => false,
        };
    }

    fn genUnary(self: *Formatter, u: ast.UnaryExpr) !void {
        const op = switch (u.op) {
            .plus => "+",
            .minus => "-",
            .bang => "!",
            .tilde => "~",
            .typeof => "typeof ",
            .void => "void ",
            .delete => "delete ",
        };
        const wrap_arg = unaryArgNeedsParens(self.arena.get(u.argument));
        if (u.prefix) {
            try self.w(op);
            if (wrap_arg) try self.w("(");
            try self.gen(u.argument);
            if (wrap_arg) try self.w(")");
        } else {
            if (wrap_arg) try self.w("(");
            try self.gen(u.argument);
            if (wrap_arg) try self.w(")");
            try self.w(op);
        }
    }

    fn genUpdate(self: *Formatter, u: ast.UpdateExpr) !void {
        const op = if (u.op == .plus2) "++" else "--";
        if (u.prefix) {
            try self.w(op);
            try self.gen(u.argument);
        } else {
            try self.gen(u.argument);
            try self.w(op);
        }
    }

    fn genAssign(self: *Formatter, a: ast.AssignExpr) !void {
        try self.gen(a.left);
        try self.w(switch (a.op) {
            .eq => " = ",
            .plus_eq => " += ",
            .minus_eq => " -= ",
            .star_eq => " *= ",
            .slash_eq => " /= ",
            .percent_eq => " %= ",
            .star2_eq => " **= ",
            .amp_eq => " &= ",
            .pipe_eq => " |= ",
            .caret_eq => " ^= ",
            .lt2_eq => " <<= ",
            .gt2_eq => " >>= ",
            .gt3_eq => " >>>= ",
            .amp2_eq => " &&= ",
            .pipe2_eq => " ||= ",
            .question2_eq => " ??= ",
        });
        try self.gen(a.right);
    }

    fn calleeNeedsParens(node: *const Node) bool {
        return switch (node.*) {
            .object_expr, .fn_expr, .class_expr, .arrow_fn, .binary_expr, .unary_expr, .update_expr, .assign_expr, .seq_expr, .cond_expr, .yield_expr, .await_expr => true,
            else => false,
        };
    }

    fn memberObjectNeedsParens(node: *const Node) bool {
        return switch (node.*) {
            .object_expr, .fn_expr, .class_expr, .binary_expr, .unary_expr, .update_expr, .assign_expr, .seq_expr, .cond_expr, .arrow_fn, .yield_expr, .await_expr => true,
            else => false,
        };
    }

    fn needsLeadingSemicolon(self: *const Formatter, stmt_node: *const Node) bool {
        const expr = switch (stmt_node.*) {
            .expr_stmt => |s| self.arena.get(s.expr),
            .var_decl => |v| if (v.declarators.len > 0) self.arena.get(v.declarators[0].id) else return false,
            else => return false,
        };
        return self.exprStartsWithASISensitive(expr);
    }

    fn exprStartsWithASISensitive(self: *const Formatter, node: *const Node) bool {
        return switch (node.*) {
            .call_expr => |c| blk: {
                const callee = self.arena.get(c.callee);
                break :blk calleeNeedsParens(callee) or self.exprStartsWithASISensitive(callee);
            },
            .member_expr => |m| self.exprStartsWithASISensitive(self.arena.get(m.object)),
            .array_expr => true,
            .template_lit => true,
            .tagged_template => true,
            .seq_expr => |s| if (s.exprs.len > 0) self.exprStartsWithASISensitive(self.arena.get(s.exprs[0])) else false,
            .unary_expr => |u| switch (u.op) {
                .plus, .minus => true,
                else => false,
            },
            .update_expr => |u| u.prefix,
            else => false,
        };
    }

    fn genCall(self: *Formatter, c: ast.CallExpr) !void {
        const wrap_callee = calleeNeedsParens(self.arena.get(c.callee));
        if (wrap_callee) try self.w("(");
        try self.gen(c.callee);
        if (wrap_callee) try self.w(")");
        if (c.optional) try self.w("?.");
        const wrap = c.args.len > 1 and self.shouldBreak(c.args.len * 8);
        try self.w("(");
        if (wrap) {
            self.indent();
            for (c.args, 0..) |a, i| {
                if (i > 0) try self.w(",");
                self.nl();
                if (a.spread) try self.w("...");
                try self.gen(a.expr);
            }
            if (self.opts.trailingComma == .all) {
                try self.w(",");
            }
            self.dedent();
            self.nl();
        } else {
            for (c.args, 0..) |a, i| {
                if (i > 0) try self.w(", ");
                if (a.spread) try self.w("...");
                try self.gen(a.expr);
            }
        }
        try self.w(")");
    }

    fn genMember(self: *Formatter, m: ast.MemberExpr) !void {
        const wrap_object = memberObjectNeedsParens(self.arena.get(m.object));
        if (wrap_object) try self.w("(");
        try self.gen(m.object);
        if (wrap_object) try self.w(")");
        if (m.computed) {
            if (m.optional) try self.w("?.");
            try self.w("[");
            try self.gen(m.prop);
            try self.w("]");
        } else {
            if (m.optional) try self.w("?.") else try self.w(".");
            try self.gen(m.prop);
        }
    }

    fn genNew(self: *Formatter, n: ast.NewExpr) !void {
        const wrap = calleeNeedsParens(self.arena.get(n.callee));
        try self.w("new ");
        if (wrap) try self.w("(");
        try self.gen(n.callee);
        if (wrap) try self.w(")");
        try self.w("(");
        for (n.args, 0..) |a, i| {
            if (i > 0) try self.w(", ");
            if (a.spread) try self.w("...");
            try self.gen(a.expr);
        }
        try self.w(")");
    }

    fn genSeq(self: *Formatter, s: ast.SeqExpr) !void {
        for (s.exprs, 0..) |e, i| {
            if (i > 0) try self.w(", ");
            try self.gen(e);
        }
    }

    fn genCond(self: *Formatter, c: ast.CondExpr) !void {
        const consequent_node = self.arena.get(c.consequent);
        const alternate_node = self.arena.get(c.alternate);
        const consequent_len = consequent_node.span().end - consequent_node.span().start;
        const alternate_len = alternate_node.span().end - alternate_node.span().start;
        const inline_extra = " ? ".len + " : ".len + consequent_len + alternate_len;
        const need_wrap = self.shouldBreak(inline_extra);

        if (need_wrap) {
            switch (self.opts.ternaryStyle) {
                .classic => {
                    try self.gen(c.cond);
                    self.indent();
                    self.nl();
                    try self.w("? ");
                    try self.gen(c.consequent);
                    self.nl();
                    try self.w(": ");
                    try self.gen(c.alternate);
                    self.dedent();
                },
                .linear => {
                    try self.gen(c.cond);
                    try self.w(" ?");
                    self.indent();
                    self.nl();
                    try self.gen(c.consequent);
                    try self.w(" :");
                    self.nl();
                    try self.gen(c.alternate);
                    self.dedent();
                },
            }
        } else {
            try self.gen(c.cond);
            try self.w(" ? ");
            try self.gen(c.consequent);
            try self.w(" : ");
            try self.gen(c.alternate);
        }
    }

    fn genArrow(self: *Formatter, f: ast.ArrowFn) !void {
        if (f.is_async) try self.w("async ");
        const single_has_type = f.param_types.len == 1 and f.param_types[0] != null;
        const single_needs_parens = f.params.len == 1 and switch (self.arena.get(f.params[0]).*) {
            .object_pat, .array_pat, .assign_pat, .rest_elem, .object_expr, .array_expr => true,
            else => single_has_type,
        };
        const omit_single_parens = self.opts.arrowParens == .avoid and f.params.len == 1 and !single_needs_parens;
        if (omit_single_parens) {
            try self.genArrowParam(f.params[0], if (f.param_types.len > 0) f.param_types[0] else null);
        } else {
            try self.w("(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try self.w(", ");
                try self.genArrowParam(p, if (i < f.param_types.len) f.param_types[i] else null);
            }
            try self.w(")");
        }
        try self.w(" => ");
        if (!f.is_expr_body) {
            try self.gen(f.body);
        } else {
            const is_obj = switch (self.arena.get(f.body).*) {
                .object_expr => true,
                else => false,
            };
            if (is_obj) try self.w("(");
            try self.gen(f.body);
            if (is_obj) try self.w(")");
        }
    }

    fn genArrowParam(self: *Formatter, param: NodeId, type_ann: ?NodeId) !void {
        try self.gen(param);
        if (type_ann) |ta| {
            try self.w(": ");
            try self.gen(ta);
        }
    }

    fn genFnExpr(self: *Formatter, f: ast.FnExpr) !void {
        if (f.is_async) try self.w("async ");
        try self.w("function");
        if (f.is_generator) try self.w("*");
        if (f.id) |id| {
            try self.w(" ");
            try self.gen(id);
        }
        try self.w("(");
        for (f.params, 0..) |p, i| {
            if (i > 0) try self.w(", ");
            try self.gen(p);
        }
        try self.w(") ");
        try self.gen(f.body);
    }

    fn hasNewlineBeforeFirstProp(self: *const Formatter, o: ast.ObjectExpr) bool {
        if (o.props.len == 0) return false;
        var i = o.span.start + 1;
        while (i < self.src.len) {
            const c = self.src[i];
            if (c == '\n') return true;
            if (c != ' ' and c != '\t' and c != '\r') break;
            i += 1;
        }
        return false;
    }

    fn hasNestedMultilineObject(self: *const Formatter, o: ast.ObjectExpr) bool {
        for (o.props) |prop| {
            switch (prop) {
                .kv => |kv| {
                    const node = self.arena.get(kv.value);
                    if (node.* == .object_expr) {
                        const nested = node.object_expr;
                        if (self.hasNewlineBeforeFirstProp(nested)) return true;
                        if (self.hasNestedMultilineObject(nested)) return true;
                    }
                },
                .spread => |s| {
                    const node = self.arena.get(s);
                    if (node.* == .object_expr) {
                        const nested = node.object_expr;
                        if (self.hasNewlineBeforeFirstProp(nested)) return true;
                        if (self.hasNestedMultilineObject(nested)) return true;
                    }
                },
                else => {},
            }
        }
        return false;
    }

    fn hasCommentsBeforeClose(self: *const Formatter, close_pos: u32) bool {
        return self.comment_index < self.comments.len and self.comments[self.comment_index].span.start < close_pos;
    }

    fn genObject(self: *Formatter, o: ast.ObjectExpr) !void {
        const close_brace = self.findClosingBrace(o.span.start) orelse return self.w("{}");
        const quote_all_props = self.shouldQuoteAllObjectProps(o.props);
        if (o.props.len == 0) {
            if (!self.hasCommentsBeforeClose(close_brace)) {
                try self.w("{}");
                return;
            }
            try self.w("{");
            self.indent();
            try self.emitCommentsBefore(close_brace);
            self.dedent();
            self.nl();
            try self.w("}");
            return;
        }
        const obj_width = close_brace - o.span.start + 1;
        const wrap = if (self.opts.objectWrap == .preserve and (self.hasNewlineBeforeFirstProp(o) or self.hasNestedMultilineObject(o)))
            true
        else
            self.shouldBreak(obj_width);
        try self.w("{");
        if (wrap) {
            self.indent();
            for (o.props, 0..) |prop, i| {
                if (i > 0) try self.w(",");
                self.nl();
                try self.genObjectProp(prop, quote_all_props);
            }
            if (self.opts.trailingComma == .all or self.opts.trailingComma == .es5) {
                try self.w(",");
            }
            try self.emitCommentsBefore(close_brace);
            self.dedent();
            self.nl();
        } else {
            if (self.opts.bracketSpacing and o.props.len > 0) try self.w(" ");
            for (o.props, 0..) |prop, i| {
                if (i > 0) try self.w(", ");
                try self.genObjectProp(prop, quote_all_props);
            }
            try self.emitCommentsBefore(close_brace);
            if (self.opts.bracketSpacing and o.props.len > 0) try self.w(" ");
        }
        try self.w("}");
    }

    fn genObjectProp(self: *Formatter, prop: ast.ObjectProp, quote_all_props: bool) !void {
        switch (prop) {
            .kv => |kv| {
                if (kv.computed) try self.w("[");
                try self.genObjectKey(kv.key, quote_all_props and !kv.computed);
                if (kv.computed) try self.w("]");
                try self.w(": ");
                try self.gen(kv.value);
            },
            .shorthand => |s| try self.gen(s),
            .spread => |s| {
                try self.w("...");
                if (self.arena.get(s).* == .cond_expr) {
                    try self.w("(");
                    try self.gen(s);
                    try self.w(")");
                } else try self.gen(s);
            },
            .method => |m| {
                const f = self.arena.get(m.value).fn_expr;
                if (f.is_async) try self.w("async ");
                if (f.is_generator) try self.w("*");
                if (m.kind == .getter) try self.w("get ");
                if (m.kind == .setter) try self.w("set ");
                if (m.computed) try self.w("[");
                try self.genObjectKey(m.key, quote_all_props and !m.computed);
                if (m.computed) try self.w("]");
                try self.w("(");
                for (f.params, 0..) |p, j| {
                    if (j > 0) try self.w(", ");
                    try self.gen(p);
                }
                try self.w(") ");
                try self.gen(f.body);
            },
        }
    }

    fn shouldQuoteAllObjectProps(self: *const Formatter, props: []const ast.ObjectProp) bool {
        if (self.opts.quoteProps != .consistent) return false;

        for (props) |prop| {
            switch (prop) {
                .kv => |kv| if (!kv.computed and self.objectKeyRequiresQuotes(kv.key)) return true,
                .method => |m| if (!m.computed and self.objectKeyRequiresQuotes(m.key)) return true,
                else => {},
            }
        }
        return false;
    }

    fn objectKeyRequiresQuotes(self: *const Formatter, key: NodeId) bool {
        return switch (self.arena.get(key).*) {
            .str_lit => |s| !isValidBarePropertyName(s.value),
            else => false,
        };
    }

    fn genObjectKey(self: *Formatter, key: NodeId, quote_if_possible: bool) !void {
        const node = self.arena.get(key);
        switch (node.*) {
            .ident => |i| {
                if (quote_if_possible) {
                    try self.genQuotedKey(i.name);
                } else {
                    try self.w(i.name);
                }
            },
            .str_lit => |s| {
                if (self.opts.quoteProps != .preserve and !quote_if_possible and isValidBarePropertyName(s.value)) {
                    try self.w(s.value);
                } else {
                    try self.genStrLit(s.raw);
                }
            },
            else => try self.gen(key),
        }
    }

    fn genQuotedKey(self: *Formatter, key: []const u8) !void {
        const quote: u8 = if (self.opts.singleQuote) '\'' else '"';
        try self.wb(quote);
        try self.w(key);
        try self.wb(quote);
    }

    fn isValidBarePropertyName(name: []const u8) bool {
        if (name.len == 0 or !isIdentStart(name[0])) return false;
        for (name[1..]) |c| {
            if (!isIdentCont(c)) return false;
        }
        return true;
    }

    fn isIdentStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
    }

    fn isIdentCont(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
    }

    fn genArray(self: *Formatter, a: ast.ArrayExpr) !void {
        if (a.elements.len == 0) {
            try self.w("[]");
            return;
        }
        const close_bracket = self.findClosingBracket(a.span.start) orelse a.span.start;
        const arr_width = close_bracket - a.span.start + 1;
        const wrap = self.shouldBreak(arr_width);
        try self.w("[");
        if (wrap) {
            self.indent();
            for (a.elements, 0..) |elem, i| {
                if (i > 0) try self.w(",");
                self.nl();
                if (elem) |e| try self.gen(e);
            }
            if (self.opts.trailingComma == .all or self.opts.trailingComma == .es5) {
                try self.w(",");
            }
            self.dedent();
            self.nl();
        } else {
            for (a.elements, 0..) |elem, i| {
                if (i > 0) try self.w(", ");
                if (elem) |e| try self.gen(e);
            }
        }
        try self.w("]");
    }

    fn genTemplate(self: *Formatter, t: ast.TemplateLit) !void {
        if (self.opts.embeddedLanguageFormatting == .off) {
            if (t.quasis.len == 0) return;
            const start = t.quasis[0].span.start;
            const end = t.quasis[t.quasis.len - 1].span.end;
            try self.w(self.src[start..end]);
            return;
        }
        try self.w("`");
        for (t.quasis, 0..) |q, i| {
            const raw = q.raw;
            const inner = if (i == 0 and i == t.quasis.len - 1)
                if (raw.len >= 2) raw[1 .. raw.len - 1] else ""
            else if (i == 0)
                if (raw.len >= 3) raw[1 .. raw.len - 2] else ""
            else if (i == t.quasis.len - 1)
                if (raw.len >= 2) raw[1 .. raw.len - 1] else ""
            else
                if (raw.len >= 3) raw[1 .. raw.len - 2] else "";
            try self.w(inner);
            if (i < t.exprs.len) {
                try self.w("${");
                try self.gen(t.exprs[i]);
                try self.w("}");
            }
        }
        try self.w("`");
    }

    fn genYield(self: *Formatter, y: ast.YieldExpr) !void {
        try self.w("yield");
        if (y.delegate) try self.w("*");
        if (y.argument) |a| {
            try self.w(" ");
            try self.gen(a);
        }
    }

    fn genObjectPat(self: *Formatter, p: ast.ObjectPat) !void {
        try self.w("{");
        if (self.opts.bracketSpacing and (p.props.len > 0 or p.rest != null)) try self.w(" ");
        for (p.props, 0..) |prop, i| {
            if (i > 0) try self.w(", ");
            switch (prop) {
                .assign => |a| {
                    try self.gen(a.key);
                    if (a.value) |v| {
                        const node = self.arena.get(v);
                        if (node.* == .assign_pat and node.assign_pat.left == a.key) {
                            try self.w(" = ");
                            try self.gen(node.assign_pat.right);
                        } else {
                            try self.w(": ");
                            try self.gen(v);
                        }
                    }
                },
                .rest => |r| {
                    try self.w("...");
                    try self.gen(r);
                },
            }
        }
        if (p.rest) |r| {
            if (p.props.len > 0) try self.w(", ");
            try self.w("...");
            try self.gen(r);
        }
        if (self.opts.bracketSpacing and (p.props.len > 0 or p.rest != null)) try self.w(" ");
        try self.w("}");
    }

    fn genArrayPat(self: *Formatter, p: ast.ArrayPat) !void {
        try self.w("[");
        for (p.elements, 0..) |elem, i| {
            if (i > 0) try self.w(", ");
            if (elem) |e| try self.gen(e);
        }
        if (p.rest) |r| {
            if (p.elements.len > 0) try self.w(", ");
            try self.w("...");
            try self.gen(r);
        }
        try self.w("]");
    }

    fn genTsTypeAnnotation(self: *Formatter, t: ast.TsTypeAnnotation) !void {
        try self.gen(t.type_node);
    }

    fn genTsTypeRef(self: *Formatter, t: ast.TsTypeRef) !void {
        try self.gen(t.name);
        if (t.type_args.len > 0) {
            try self.w("<");
            for (t.type_args, 0..) |ta, i| {
                if (i > 0) try self.w(", ");
                try self.gen(ta);
            }
            try self.w(">");
        }
    }

    fn genTsQualifiedName(self: *Formatter, t: ast.TsQualifiedName) !void {
        try self.gen(t.left);
        try self.w(".");
        try self.gen(t.right);
    }

    fn genTsUnion(self: *Formatter, t: ast.TsUnionType) !void {
        for (t.types, 0..) |typ, i| {
            if (i > 0) try self.w(" | ");
            try self.gen(typ);
        }
    }

    fn genTsIntersection(self: *Formatter, t: ast.TsIntersectionType) !void {
        for (t.types, 0..) |typ, i| {
            if (i > 0) try self.w(" & ");
            try self.gen(typ);
        }
    }

    fn genTsArrayType(self: *Formatter, t: ast.TsArrayType) !void {
        try self.gen(t.elem);
        try self.w("[]");
    }

    fn genTsTuple(self: *Formatter, t: ast.TsTupleType) !void {
        try self.w("[");
        for (t.types, 0..) |typ, i| {
            if (i > 0) try self.w(", ");
            try self.gen(typ);
        }
        try self.w("]");
    }

    fn genTsKeyword(self: *Formatter, t: ast.TsKeywordType) !void {
        try self.w(switch (t.keyword) {
            .any => "any",
            .unknown => "unknown",
            .never => "never",
            .void_kw => "void",
            .undefined_kw => "undefined",
            .null_kw => "null",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .bigint => "bigint",
            .symbol => "symbol",
            .object => "object",
        });
    }

    fn genTsTypeParams(self: *Formatter, params: []const ast.TsTypeParam) !void {
        if (params.len == 0) return;
        try self.w("<");
        for (params, 0..) |p, i| {
            if (i > 0) try self.w(", ");
            try self.gen(p.name);
            if (p.constraint) |c| {
                try self.w(" extends ");
                try self.gen(c);
            }
            if (p.default_type) |d| {
                try self.w(" = ");
                try self.gen(d);
            }
        }
        try self.w(">");
    }

    fn genTsInterface(self: *Formatter, t: ast.TsInterfaceDecl) !void {
        try self.w("interface ");
        try self.gen(t.id);
        try self.genTsTypeParams(t.type_params);
        if (t.extends.len > 0) {
            try self.w(" extends ");
            for (t.extends, 0..) |ext, i| {
                if (i > 0) try self.w(", ");
                try self.gen(ext);
            }
        }
        try self.w(" {");
        self.indent();
        for (t.body) |m| {
            self.nl();
            try self.genTsTypeMember(m);
            if (self.opts.semi) try self.w(";");
        }
        self.dedent();
        if (t.body.len > 0) self.nl();
        try self.w("}");
    }

    fn genTsTypeMember(self: *Formatter, m: ast.TsTypeMember) !void {
        switch (m.kind) {
            .prop => |p| {
                if (p.readonly) try self.w("readonly ");
                try self.gen(p.key);
                if (p.optional) try self.w("?");
                if (p.type_ann) |ta| {
                    try self.w(": ");
                    try self.gen(ta);
                }
            },
            .method => |mth| {
                try self.gen(mth.key);
                try self.w("(");
                for (mth.params, 0..) |p, i| {
                    if (i > 0) try self.w(", ");
                    try self.gen(p);
                }
                try self.w(")");
                if (mth.ret) |r| {
                    try self.w(": ");
                    try self.gen(r);
                }
            },
            .index => |idx| {
                try self.w("[");
                try self.gen(idx.param);
                try self.w("]: ");
                try self.gen(idx.type_ann);
            },
        }
    }

    fn genTsTypeAlias(self: *Formatter, t: ast.TsTypeAliasDecl) !void {
        try self.w("type ");
        try self.gen(t.id);
        try self.genTsTypeParams(t.type_params);
        try self.w(" = ");
        try self.gen(t.type_ann);
        if (self.opts.semi) try self.w(";");
    }

    fn genTsEnum(self: *Formatter, e: ast.TsEnumDecl) !void {
        if (e.is_const) try self.w("const ");
        try self.w("enum ");
        try self.gen(e.id);
        try self.w(" {");
        self.indent();
        for (e.members, 0..) |m, i| {
            if (i > 0) try self.w(",");
            self.nl();
            try self.gen(m.id);
            if (m.init) |init_val| {
                try self.w(" = ");
                try self.gen(init_val);
            }
        }
        self.dedent();
        if (e.members.len > 0) self.nl();
        try self.w("}");
    }

    fn genTsNamespace(self: *Formatter, ns: ast.TsNamespaceDecl) !void {
        try self.w("namespace ");
        try self.gen(ns.id);
        try self.w(" {");
        self.indent();
        for (ns.body) |stmt| {
            self.nl();
            try self.gen(stmt);
        }
        self.dedent();
        if (ns.body.len > 0) self.nl();
        try self.w("}");
    }

    fn genJsxElement(self: *Formatter, e: ast.JsxElement) !void {
        try self.w("<");
        try self.gen(e.opening.name);
        if (self.opts.singleAttributePerLine and e.opening.attrs.len > 1) {
            self.indent();
            for (e.opening.attrs) |attr| {
                self.nl();
                try self.genJsxAttr(attr);
            }
            self.dedent();
            if (e.opening.self_closing) {
                if (self.opts.bracketSameLine) {
                    try self.w(" />");
                } else {
                    self.nl();
                    try self.w("/>");
                }
                return;
            }
            if (self.opts.bracketSameLine) {
                try self.w(">");
            } else {
                self.nl();
                try self.w(">");
            }
        } else {
            for (e.opening.attrs) |attr| {
                try self.w(" ");
                try self.genJsxAttr(attr);
            }
            if (e.opening.self_closing) {
                try self.w(" />");
                return;
            }
            try self.w(">");
        }
        for (e.children) |child| {
            try self.gen(child);
        }
        if (e.closing) |closing| {
            try self.w("</");
            try self.gen(closing.name);
            try self.w(">");
        }
    }

    fn genJsxFragment(self: *Formatter, f: ast.JsxFragment) !void {
        try self.w("<>");
        for (f.children) |child| {
            try self.gen(child);
        }
        try self.w("</>");
    }

    fn genJsxExprContainer(self: *Formatter, e: ast.JsxExprContainer) !void {
        try self.w("{");
        if (e.expr) |expr| try self.gen(expr);
        try self.w("}");
    }

    fn genJsxAttr(self: *Formatter, attr: ast.JsxAttr) !void {
        switch (attr) {
            .named => |n| {
                try self.gen(n.name);
                if (n.value) |v| {
                    try self.w("=");
                    self.in_jsx_attr = true;
                    defer self.in_jsx_attr = false;
                    try self.gen(v);
                }
            },
            .spread => |s| {
                try self.w("{...");
                try self.gen(s);
                try self.w("}");
            },
        }
    }

    fn genStrLit(self: *Formatter, raw: []const u8) !void {
        if (raw.len < 2) return self.w(raw);
        const quote = raw[0];
        const end_quote = raw[raw.len - 1];
        if (quote != '\'' and quote != '"') return self.w(raw);
        if (end_quote != '\'' and end_quote != '"') return self.w(raw);
        const target_quote: u8 = if (self.in_jsx_attr) blk: {
            break :blk if (self.opts.jsxSingleQuote) '\'' else '"';
        } else if (self.opts.singleQuote) '\'' else '"';
        if (quote == target_quote) return self.w(raw);
        const inner = raw[1 .. raw.len - 1];
        try self.wb(target_quote);
        try self.w(inner);
        try self.wb(target_quote);
    }
};
