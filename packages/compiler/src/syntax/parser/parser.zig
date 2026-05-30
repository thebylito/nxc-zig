const std = @import("std");
const Lexer = @import("lexer").Lexer;
const Comment = @import("lexer").Lexer.Comment;
const tok = @import("lexer").token;
pub const ast = @import("ast");
pub const diagnostics = @import("diagnostics");

const Token = tok.Token;
const TokenKind = tok.TokenKind;
const NodeId = ast.NodeId;
const NULL_NODE = ast.NULL_NODE;
const Diag = diagnostics;

pub const ParseOptions = struct {
    typescript: bool = true,
    jsx: bool = true,
    source_type: ast.SourceType = .module,
    check: bool = true,
    max_depth: u32 = 2048,
};

pub const Parser = struct {
    lexer: Lexer,
    arena: *ast.Arena,
    alloc: std.mem.Allocator,
    diags: *Diag.DiagnosticList,
    filename: []const u8,
    opts: ParseOptions,
    src: []const u8,
    comments: std.ArrayListUnmanaged(Comment),
    scopes: std.ArrayListUnmanaged(Scope),
    fn_contexts: std.ArrayListUnmanaged(FnContext),
    labels: std.ArrayListUnmanaged(LabelContext),
    loop_depth: usize,
    switch_depth: usize,
    parse_depth: u32,

    const DeclKind = enum {
        var_binding,
        lexical,
        import_binding,
        function_impl,
        class_decl,
        type_alias,
        enum_decl,
        param,
        type_param,
    };

    const ValueType = enum {
        unknown,
        number,
        string,
        boolean,
        null_value,
        undefined_value,
    };

    const FnContext = struct {
        is_async: bool,
        is_generator: bool,
    };

    const LabelContext = struct {
        name: []const u8,
        span: ast.Span,
        is_loop: bool,
    };

    const Binding = struct {
        name: []const u8,
        span: ast.Span,
        kind: DeclKind,
        inferred_type: ValueType = .unknown,
    };

    const Scope = struct {
        bindings: std.ArrayListUnmanaged(Binding) = .empty,
    };

    const ParsedParams = struct {
        params: []NodeId,
        param_decorators: []const []const NodeId,
        param_types: []const ?NodeId,
        param_access: []const ?ast.Accessibility,
        param_readonly: []const bool,
    };

    const ParamModifiers = struct {
        accessibility: ?ast.Accessibility,
        is_readonly: bool,
    };

    pub fn init(
        src: []const u8,
        filename: []const u8,
        arena: *ast.Arena,
        alloc: std.mem.Allocator,
        diags: *Diag.DiagnosticList,
        opts: ParseOptions,
    ) Parser {
        return .{
            .lexer = Lexer.init(src),
            .arena = arena,
            .alloc = alloc,
            .diags = diags,
            .filename = filename,
            .opts = opts,
            .src = src,
            .comments = .empty,
            .scopes = .empty,
            .fn_contexts = .empty,
            .labels = .empty,
            .loop_depth = 0,
            .switch_depth = 0,
            .parse_depth = 0,
        };
    }

    fn cur(self: *Parser) Token {
        const t = self.lexer.peek();
        self.syncComments() catch unreachable;
        return t;
    }

    fn eat(self: *Parser) Token {
        const t = self.lexer.next();
        self.syncComments() catch unreachable;
        return t;
    }

    fn syncComments(self: *Parser) !void {
        const comments = self.lexer.takePendingComments();
        if (comments.len == 0) return;
        try self.comments.appendSlice(self.alloc, comments);
    }

    fn expect(self: *Parser, kind: TokenKind) !Token {
        const t = self.eat();
        if (t.kind != kind) {
            try self.emitError(t, "unexpected token");
            return error.ParseError;
        }
        return t;
    }

    fn check(self: *Parser, kind: TokenKind) bool {
        return self.cur().kind == kind;
    }

    fn eatIf(self: *Parser, kind: TokenKind) ?Token {
        if (self.check(kind)) return self.eat();
        return null;
    }

    fn peek2Kind(self: *Parser) TokenKind {
        // Full save/restore: peeked, pos, line, line_start
        const saved_peeked = self.lexer.peeked;
        const saved_pos = self.lexer.pos;
        const saved_line = self.lexer.line;
        const saved_line_start = self.lexer.line_start;
        const saved_template_stack = self.lexer.template_stack;
        const saved_template_depth = self.lexer.template_depth;
        const saved_brace_depth = self.lexer.brace_depth;
        const saved_pending_comments_len = self.lexer.pending_comments_len;
        const first = self.lexer.next();
        _ = first;
        const second_kind = self.lexer.peek().kind;
        self.lexer.peeked = saved_peeked;
        self.lexer.pos = saved_pos;
        self.lexer.line = saved_line;
        self.lexer.line_start = saved_line_start;
        self.lexer.template_stack = saved_template_stack;
        self.lexer.template_depth = saved_template_depth;
        self.lexer.brace_depth = saved_brace_depth;
        self.lexer.pending_comments_len = saved_pending_comments_len;
        return second_kind;
    }

    fn peek3Kind(self: *Parser) TokenKind {
        const saved_peeked = self.lexer.peeked;
        const saved_pos = self.lexer.pos;
        const saved_line = self.lexer.line;
        const saved_line_start = self.lexer.line_start;
        const saved_template_stack = self.lexer.template_stack;
        const saved_template_depth = self.lexer.template_depth;
        const saved_brace_depth = self.lexer.brace_depth;
        const saved_pending_comments_len = self.lexer.pending_comments_len;
        const first = self.lexer.next();
        _ = first;
        const second = self.lexer.next();
        _ = second;
        const third_kind = self.lexer.peek().kind;
        self.lexer.peeked = saved_peeked;
        self.lexer.pos = saved_pos;
        self.lexer.line = saved_line;
        self.lexer.line_start = saved_line_start;
        self.lexer.template_stack = saved_template_stack;
        self.lexer.template_depth = saved_template_depth;
        self.lexer.brace_depth = saved_brace_depth;
        self.lexer.pending_comments_len = saved_pending_comments_len;
        return third_kind;
    }

    fn emitError(self: *Parser, t: Token, msg: []const u8) !void {
        try self.emitErrorAtSpan(t.span, msg);
    }

    fn emitErrorAtSpan(self: *Parser, span: ast.Span, msg: []const u8) !void {
        var line_start: usize = 0;
        var l: u32 = 1;
        for (self.src, 0..) |c, i| {
            if (l == span.line) {
                line_start = i;
                break;
            }
            if (c == '\n') l += 1;
        }
        const line_end = std.mem.indexOfScalarPos(u8, self.src, line_start, '\n') orelse self.src.len;
        try self.diags.add(self.alloc, .{
            .severity = .err,
            .message = msg,
            .filename = self.filename,
            .line = span.line,
            .col = span.col,
            .source_line = self.src[line_start..line_end],
            .len = span.len(),
        });
    }

    fn pushScope(self: *Parser) !void {
        try self.scopes.append(self.alloc, .{});
    }

    fn popScope(self: *Parser) void {
        if (self.scopes.items.len == 0) return;

        const idx = self.scopes.items.len - 1;
        var scope = self.scopes.items[idx];
        scope.bindings.deinit(self.alloc);
        self.scopes.items = self.scopes.items[0..idx];
    }

    fn pushFnContext(self: *Parser, is_async: bool, is_generator: bool) !void {
        try self.fn_contexts.append(self.alloc, .{ .is_async = is_async, .is_generator = is_generator });
    }

    fn popFnContext(self: *Parser) void {
        if (self.fn_contexts.items.len == 0) return;
        self.fn_contexts.items.len -= 1;
    }

    fn currentFnContext(self: *Parser) ?FnContext {
        if (self.fn_contexts.items.len == 0) return null;
        return self.fn_contexts.items[self.fn_contexts.items.len - 1];
    }

    fn parseFunctionBodyNode(self: *Parser, is_async: bool, is_generator: bool, is_expr_body: bool) !NodeId {
        try self.pushFnContext(is_async, is_generator);
        const saved_loop_depth = self.loop_depth;
        const saved_switch_depth = self.switch_depth;
        const saved_labels_len = self.labels.items.len;
        self.loop_depth = 0;
        self.switch_depth = 0;
        self.labels.items.len = 0;
        defer {
            self.labels.items.len = saved_labels_len;
            self.switch_depth = saved_switch_depth;
            self.loop_depth = saved_loop_depth;
            self.popFnContext();
        }

        return if (is_expr_body) try self.parseAssignExpr() else try self.parseBlock();
    }

    fn enterLoop(self: *Parser) void {
        self.loop_depth += 1;
    }

    fn leaveLoop(self: *Parser) void {
        std.debug.assert(self.loop_depth > 0);
        self.loop_depth -= 1;
    }

    fn enterSwitch(self: *Parser) void {
        self.switch_depth += 1;
    }

    fn leaveSwitch(self: *Parser) void {
        std.debug.assert(self.switch_depth > 0);
        self.switch_depth -= 1;
    }

    fn pushLabel(self: *Parser, label: NodeId, is_loop: bool) !void {
        const ident = self.arena.get(label).ident;
        for (self.labels.items) |active| {
            if (std.mem.eql(u8, active.name, ident.name)) {
                try self.emitErrorAtSpan(ident.span, "label is already declared");
                return error.ParseError;
            }
        }
        try self.labels.append(self.alloc, .{ .name = ident.name, .span = ident.span, .is_loop = is_loop });
    }

    fn popLabel(self: *Parser) void {
        if (self.labels.items.len == 0) return;
        self.labels.items.len -= 1;
    }

    fn findLabel(self: *Parser, name: []const u8) ?LabelContext {
        var i = self.labels.items.len;
        while (i > 0) {
            i -= 1;
            const label = self.labels.items[i];
            if (std.mem.eql(u8, label.name, name)) return label;
        }
        return null;
    }

    fn nextStatementIsLoop(self: *Parser) bool {
        if (self.check(.kw_for) or self.check(.kw_while) or self.check(.kw_do)) return true;
        return false;
    }

    fn validateRequiredInitializers(self: *Parser, decl_id: NodeId, allow_missing_for_for_in_of_lhs: bool) !void {
        const node = self.arena.get(decl_id);
        if (node.* != .var_decl) return;
        const decl = node.var_decl;
        const requires_init = decl.kind == .@"const" or decl.kind == .using;
        if (!requires_init) return;
        if (allow_missing_for_for_in_of_lhs) return;
        for (decl.declarators) |declarator| {
            if (declarator.init == null) {
                try self.emitErrorAtSpan(declarator.span, "missing initializer in declaration");
                return error.ParseError;
            }
        }
    }

    fn validateForInOfInitializer(self: *Parser, decl_id: NodeId) !void {
        const node = self.arena.get(decl_id);
        if (node.* != .var_decl) return;
        const decl = node.var_decl;
        if (decl.declarators.len != 1) {
            try self.emitErrorAtSpan(decl.span, "for-in/of declaration must have exactly one binding");
            return error.ParseError;
        }
        if (decl.declarators[0].init != null) {
            try self.emitErrorAtSpan(decl.declarators[0].span, "for-in/of declaration cannot have an initializer");
            return error.ParseError;
        }
    }

    fn currentScope(self: *Parser) !*Scope {
        if (self.scopes.items.len == 0) {
            try self.pushScope();
        }

        return &self.scopes.items[self.scopes.items.len - 1];
    }

    fn isLexicalVarKind(kind: ast.VarKind) bool {
        return switch (kind) {
            .let, .@"const", .using => true,
            .@"var" => false,
        };
    }

    fn duplicateMessagePrefix(existing: DeclKind, incoming: DeclKind) []const u8 {
        if (existing == .function_impl and incoming == .function_impl) {
            return "duplicate function implementation";
        }

        return "duplicate identifier";
    }

    fn isAllowedDuplicate(existing: DeclKind, incoming: DeclKind) bool {
        return switch (incoming) {
            .var_binding => existing == .var_binding or existing == .function_impl,
            .function_impl => existing == .var_binding,
            else => false,
        };
    }

    fn emitDuplicateDeclError(self: *Parser, span: ast.Span, name: []const u8, existing: DeclKind, incoming: DeclKind) !void {
        const prefix = duplicateMessagePrefix(existing, incoming);
        const msg = try std.fmt.allocPrint(self.alloc, "{s} '{s}'.", .{ prefix, name });
        try self.emitErrorAtSpan(span, msg);
    }

    fn declareInScope(self: *Parser, scope: *Scope, ident: ast.Ident, kind: DeclKind) !void {
        for (scope.bindings.items) |binding| {
            if (std.mem.eql(u8, binding.name, ident.name)) {
                if (isAllowedDuplicate(binding.kind, kind)) break;
                try self.emitDuplicateDeclError(ident.span, ident.name, binding.kind, kind);
                return;
            }
        }

        try scope.bindings.append(self.alloc, .{
            .name = ident.name,
            .span = ident.span,
            .kind = kind,
        });
    }

    fn declareIdentifier(self: *Parser, ident: ast.Ident, kind: DeclKind) !void {
        const scope = try self.currentScope();
        try self.declareInScope(scope, ident, kind);
    }

    fn declareIdentifierNode(self: *Parser, id: NodeId, kind: DeclKind) !void {
        switch (self.arena.get(id).*) {
            .ident => |ident| try self.declareIdentifier(ident, kind),
            else => {},
        }
    }

    fn declareIdentifierNodeInScope(self: *Parser, scope: *Scope, id: NodeId, kind: DeclKind) !void {
        switch (self.arena.get(id).*) {
            .ident => |ident| try self.declareInScope(scope, ident, kind),
            else => {},
        }
    }

    fn declareBindingPatternInScope(self: *Parser, scope: *Scope, id: NodeId, kind: DeclKind) !void {
        const node = self.arena.get(id);

        switch (node.*) {
            .ident => |ident| {
                try self.declareInScope(scope, ident, kind);
            },
            .rest_elem => |rest| {
                try self.declareBindingPatternInScope(scope, rest.argument, kind);
            },
            .assign_pat => |pat| {
                try self.declareBindingPatternInScope(scope, pat.left, kind);
            },
            .object_pat => |pat| {
                for (pat.props) |prop| {
                    switch (prop) {
                        .assign => |prop_assign| {
                            if (prop_assign.value) |value| {
                                try self.declareBindingPatternInScope(scope, value, kind);
                            } else if (!prop_assign.computed) {
                                try self.declareBindingPatternInScope(scope, prop_assign.key, kind);
                            }
                        },
                        .rest => |rest| {
                            try self.declareBindingPatternInScope(scope, rest, kind);
                        },
                    }
                }

                if (pat.rest) |rest| try self.declareBindingPatternInScope(scope, rest, kind);
            },
            .array_pat => |pat| {
                for (pat.elements) |maybe_elem| {
                    if (maybe_elem) |elem| try self.declareBindingPatternInScope(scope, elem, kind);
                }

                if (pat.rest) |rest| try self.declareBindingPatternInScope(scope, rest, kind);
            },
            else => {},
        }
    }

    fn declareBindingPattern(self: *Parser, id: NodeId, kind: DeclKind) !void {
        const scope = try self.currentScope();
        try self.declareBindingPatternInScope(scope, id, kind);
    }

    fn setBindingTypeInScope(scope: *Scope, name: []const u8, inferred_type: ValueType) void {
        var i: usize = scope.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, scope.bindings.items[i].name, name)) {
                scope.bindings.items[i].inferred_type = inferred_type;
                return;
            }
        }
    }

    fn setBindingPatternType(self: *Parser, id: NodeId, inferred_type: ValueType) !void {
        if (inferred_type == .unknown) return;

        switch (self.arena.get(id).*) {
            .ident => |ident| {
                const scope = try self.currentScope();
                setBindingTypeInScope(scope, ident.name, inferred_type);
            },
            .assign_pat => |pat| try self.setBindingPatternType(pat.left, inferred_type),
            else => {},
        }
    }

    fn lookupBinding(self: *Parser, name: []const u8) ?*Binding {
        var scope_i: usize = self.scopes.items.len;
        while (scope_i > 0) {
            scope_i -= 1;
            var binding_i: usize = self.scopes.items[scope_i].bindings.items.len;
            while (binding_i > 0) {
                binding_i -= 1;
                if (std.mem.eql(u8, self.scopes.items[scope_i].bindings.items[binding_i].name, name)) {
                    return &self.scopes.items[scope_i].bindings.items[binding_i];
                }
            }
        }

        return null;
    }

    fn valueTypeName(value_type: ValueType) []const u8 {
        return switch (value_type) {
            .unknown => "unknown",
            .number => "number",
            .string => "string",
            .boolean => "boolean",
            .null_value => "null",
            .undefined_value => "undefined",
        };
    }

    fn inferTypeFromTypeAnn(self: *Parser, type_ann: ?NodeId) ValueType {
        const ann = type_ann orelse return .unknown;
        return switch (self.arena.get(ann).*) {
            .ts_keyword => |kw| switch (kw.keyword) {
                .number => .number,
                .string => .string,
                .boolean => .boolean,
                .null_kw => .null_value,
                .undefined_kw => .undefined_value,
                else => .unknown,
            },
            else => .unknown,
        };
    }

    fn inferExprType(self: *Parser, expr: NodeId) ValueType {
        return switch (self.arena.get(expr).*) {
            .num_lit => .number,
            .str_lit, .template_lit => .string,
            .bool_lit => .boolean,
            .null_lit => .null_value,
            .undefined_ref => .undefined_value,
            .ident => |ident| if (self.lookupBinding(ident.name)) |binding| binding.inferred_type else .unknown,
            .ts_as_expr => |as_expr| blk: {
                const ann_type = self.inferTypeFromTypeAnn(as_expr.type_ann);
                break :blk if (ann_type != .unknown) ann_type else self.inferExprType(as_expr.expr);
            },
            .ts_satisfies => |satisfies| self.inferExprType(satisfies.expr),
            .ts_non_null => |non_null| self.inferExprType(non_null.expr),
            else => .unknown,
        };
    }

    fn validateTypeAssignable(self: *Parser, span: ast.Span, expected: ValueType, actual: ValueType) !void {
        if (!self.opts.check) return;
        if (expected == .unknown or actual == .unknown or expected == actual) return;

        const msg = try std.fmt.allocPrint(
            self.alloc,
            "type '{s}' is not assignable to type '{s}'",
            .{ valueTypeName(actual), valueTypeName(expected) },
        );
        try self.emitErrorAtSpan(span, msg);
    }

    fn validateAssignment(self: *Parser, left: NodeId, right: NodeId) !void {
        if (!self.opts.check) return;

        switch (self.arena.get(left).*) {
            .ident => |ident| {
                const binding = self.lookupBinding(ident.name) orelse return;
                const expected = binding.inferred_type;
                const actual = self.inferExprType(right);
                try self.validateTypeAssignable(self.arena.get(right).span(), expected, actual);
            },
            else => {},
        }
    }

    fn validateParams(self: *Parser, params: []const NodeId) !void {
        var param_scope: Scope = .{};
        defer param_scope.bindings.deinit(self.alloc);

        for (params, 0..) |param, i| {
            switch (self.arena.get(param).*) {
                .rest_elem => |rest| {
                    if (i != params.len - 1) {
                        try self.emitErrorAtSpan(rest.span, "rest parameter must be last");
                        return error.ParseError;
                    }
                    if (self.arena.get(rest.argument).* == .assign_pat) {
                        try self.emitErrorAtSpan(rest.span, "rest parameter cannot have an initializer");
                        return error.ParseError;
                    }
                },
                else => {},
            }
            try self.declareBindingPatternInScope(&param_scope, param, .param);
        }
    }

    fn validateTypeParams(self: *Parser, params: []const ast.TsTypeParam) !void {
        var type_param_scope: Scope = .{};
        defer type_param_scope.bindings.deinit(self.alloc);

        for (params) |param| {
            try self.declareIdentifierNodeInScope(&type_param_scope, param.name, .type_param);
        }
    }

    fn declareImportSpecifiers(self: *Parser, specs: []const ast.ImportSpecifier) !void {
        for (specs) |spec| {
            try self.declareIdentifierNode(spec.local, .import_binding);
        }
    }

    pub fn parseProgram(self: *Parser) !NodeId {
        defer self.fn_contexts.deinit(self.alloc);
        defer self.labels.deinit(self.alloc);
        try self.pushScope();
        defer self.popScope();

        var body = std.ArrayListUnmanaged(NodeId).empty;
        while (!self.check(.eof)) {
            const stmt = try self.parseModuleItem();
            try body.append(self.alloc, stmt);
        }
        const span = tok.Span{ .start = 0, .end = @intCast(self.src.len), .line = 1, .col = 1 };
        return self.arena.push(.{ .program = .{
            .body = try body.toOwnedSlice(self.alloc),
            .source_type = self.opts.source_type,
            .span = span,
        } });
    }

    fn parseModuleItem(self: *Parser) !NodeId {
        return switch (self.cur().kind) {
            .kw_import => self.parseImport(),
            .kw_export => self.parseExport(),
            else => self.parseStatement(),
        };
    }

    fn parseStatement(self: *Parser) anyerror!NodeId {
        try self.checkDepth();
        defer self.parse_depth -= 1;
        const t = self.cur();
        return switch (t.kind) {
            .lbrace => self.parseBlock(),
            .kw_var, .kw_let => self.parseVarDecl(),
            .kw_const => if (self.opts.typescript and self.peek2Kind() == .kw_enum) self.parseTsEnum() else self.parseVarDecl(),
            .kw_using => if (self.opts.typescript) self.parseUsingDecl(false) else self.parseExprStmt(),
            .kw_await => if (self.opts.typescript and self.peek2Kind() == .kw_using) self.parseAwaitUsingDecl() else self.parseExprStmt(),
            .kw_function => self.parseFnDecl(false),
            .kw_async => blk: {
                if (self.isAsyncAccessorStart()) {
                    try self.emitError(self.cur(), "unexpected token");
                    return error.ParseError;
                }
                if (self.peek2Kind() == .kw_function) {
                    _ = self.eat();
                    break :blk self.parseFnDecl(true);
                }
                break :blk self.parseExprStmt();
            },
            .kw_class => self.parseClassDecl(),
            .kw_abstract => if (self.opts.typescript) self.parseClassDecl() else self.parseExprStmt(),
            .at => self.parseDecoratedClass(),
            .kw_return => self.parseReturn(),
            .kw_if => self.parseIf(),
            .kw_for => self.parseFor(),
            .kw_while => self.parseWhile(),
            .kw_do => self.parseDoWhile(),
            .kw_switch => self.parseSwitch(),
            .kw_try => self.parseTry(),
            .kw_throw => self.parseThrow(),
            .kw_break => self.parseBreakContinue(true),
            .kw_continue => self.parseBreakContinue(false),
            .kw_debugger => self.parseDebugger(),
            .semicolon => blk: {
                const s = self.eat();
                break :blk self.arena.push(.{ .empty_stmt = .{ .span = s.span } });
            },
            .kw_interface => if (self.opts.typescript) self.parseTsInterface() else self.parseExprStmt(),
            .kw_type => if (self.opts.typescript) self.parseTsTypeAlias() else self.parseExprStmt(),
            .kw_enum => if (self.opts.typescript) self.parseTsEnum() else self.parseExprStmt(),
            .kw_declare => if (self.opts.typescript) self.parseTsDeclare() else self.parseExprStmt(),
            .kw_namespace, .kw_module => if (self.opts.typescript) self.parseTsNamespace() else self.parseExprStmt(),
            .ident => if (self.peek2Kind() == .colon) self.parseLabeledStmt() else self.parseExprStmt(),
            else => self.parseExprStmt(),
        };
    }

    fn parseBlock(self: *Parser) anyerror!NodeId {
        const open = try self.expect(.lbrace);
        try self.pushScope();
        defer self.popScope();

        var stmts = std.ArrayListUnmanaged(NodeId).empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            try stmts.append(self.alloc, try self.parseStatement());
        }
        _ = try self.expect(.rbrace);
        return self.arena.push(.{ .block = .{
            .body = try stmts.toOwnedSlice(self.alloc),
            .span = open.span,
        } });
    }

    fn parseVarDeclNoSemi(self: *Parser) !NodeId {
        return self.parseVarDeclInner(false, false);
    }

    fn parseVarDecl(self: *Parser) !NodeId {
        const decl = try self.parseVarDeclInner(true, false);
        try self.validateRequiredInitializers(decl, false);
        return decl;
    }

    fn parseVarDeclInner(self: *Parser, eat_semi: bool, is_await: bool) !NodeId {
        const kw = self.eat();
        const kind: ast.VarKind = switch (kw.kind) {
            .kw_var => .@"var",
            .kw_let => .let,
            .kw_const => .@"const",
            .kw_using => .using,
            else => unreachable,
        };
        var decls = std.ArrayListUnmanaged(ast.VarDeclarator).empty;
        while (true) {
            const id = try self.parseBindingPattern();

            try self.declareBindingPattern(id, if (isLexicalVarKind(kind)) .lexical else .var_binding);

            const type_ann: ?NodeId = if (self.opts.typescript and self.check(.colon)) blk: {
                _ = self.eat();
                break :blk try self.parseTsType();
            } else null;
            const init_val = if (self.eatIf(.eq) != null) try self.parseAssignExpr() else null;
            if (self.opts.check) {
                const declared_type = blk: {
                    const annotated_type = self.inferTypeFromTypeAnn(type_ann);
                    if (annotated_type != .unknown) break :blk annotated_type;
                    if (init_val) |initializer| break :blk self.inferExprType(initializer);
                    break :blk ValueType.unknown;
                };

                try self.setBindingPatternType(id, declared_type);
                if (init_val) |initializer| try self.validateTypeAssignable(self.arena.get(initializer).span(), declared_type, self.inferExprType(initializer));
            }
            try decls.append(self.alloc, .{ .id = id, .init = init_val, .type_ann = type_ann, .span = kw.span });
            if (self.eatIf(.comma) == null) break;
        }
        if (eat_semi) _ = self.eatIf(.semicolon);
        return self.arena.push(.{ .var_decl = .{
            .kind = kind,
            .declarators = try decls.toOwnedSlice(self.alloc),
            .is_await = is_await,
            .span = kw.span,
        } });
    }

    fn parseUsingDecl(self: *Parser, is_await: bool) !NodeId {
        const decl = try self.parseVarDeclInner(true, is_await);
        try self.validateRequiredInitializers(decl, false);
        return decl;
    }

    fn parseAwaitUsingDecl(self: *Parser) !NodeId {
        _ = self.eat(); // eat 'await'
        return self.parseUsingDecl(true);
    }

    fn parseFnDecl(self: *Parser, is_async: bool) !NodeId {
        const kw = try self.expect(.kw_function);
        const is_gen = self.eatIf(.star) != null;
        const id: ?NodeId = if (self.check(.ident) or
            self.check(.kw_get) or
            self.check(.kw_set) or
            isTsContextualIdent(self.cur().kind))
            try self.parseIdentOrKeywordAsIdent()
        else
            null;
        const type_params: []ast.TsTypeParam = if (self.opts.typescript and self.check(.lt)) try self.parseTsTypeParams() else &.{};
        const parsed_params = try self.parseFnParams();
        const return_type: ?NodeId = if (self.opts.typescript and self.check(.colon)) blk: {
            _ = self.eat();
            break :blk try self.parseTsType();
        } else null;
        // TypeScript overload/ambient signature: function without body.
        if (self.opts.typescript and !self.check(.lbrace)) {
            _ = self.eatIf(.semicolon);
            return self.arena.push(.{ .empty_stmt = .{ .span = kw.span } });
        }
        if (id) |fn_id| {
            try self.declareIdentifierNode(fn_id, .function_impl);
        }
        const body = try self.parseFunctionBodyNode(is_async, is_gen, false);
        return self.arena.push(.{ .fn_decl = .{
            .id = id,
            .type_params = type_params,
            .params = parsed_params.params,
            .param_decorators = parsed_params.param_decorators,
            .param_types = parsed_params.param_types,
            .param_access = parsed_params.param_access,
            .param_readonly = parsed_params.param_readonly,
            .body = body,
            .return_type = return_type,
            .is_async = is_async,
            .is_generator = is_gen,
            .span = kw.span,
        } });
    }

    fn parseFnParams(self: *Parser) !ParsedParams {
        _ = try self.expect(.lparen);
        var params = std.ArrayListUnmanaged(NodeId).empty;
        var param_decorators = std.ArrayListUnmanaged([]const NodeId).empty;
        var param_types = std.ArrayListUnmanaged(?NodeId).empty;
        var param_access = std.ArrayListUnmanaged(?ast.Accessibility).empty;
        var param_readonly = std.ArrayListUnmanaged(bool).empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            // TypeScript `this` parameters are type-only and do not exist at runtime.
            if (self.opts.typescript and params.items.len == 0 and self.check(.kw_this)) {
                _ = self.eat();
                if (self.check(.colon)) {
                    _ = self.eat();
                    _ = try self.parseTsType();
                }
                if (self.eatIf(.comma) == null) break;
                continue;
            }

            const decorators: []const NodeId = if (self.check(.at)) try self.parseDecorators() else &.{};
            const param_meta: ParamModifiers = if (self.opts.typescript)
                self.eatTsParamModifiers()
            else
                .{ .accessibility = @as(?ast.Accessibility, null), .is_readonly = false };
            const spread = self.eatIf(.dotdotdot) != null;
            const pat = try self.parseBindingPattern();
            if (self.opts.typescript) _ = self.eatIf(.question);
            var type_ann: ?NodeId = if (self.opts.typescript and self.check(.colon)) blk: {
                _ = self.eat();
                break :blk try self.parseTsType();
            } else null;
            const param = if (self.check(.eq)) blk: {
                _ = self.eat();
                const def = try self.parseAssignExpr();
                const pat_with_default = try self.arena.push(.{ .assign_pat = .{
                    .left = pat,
                    .right = def,
                    .span = self.arena.get(pat).span(),
                } });
                if (self.opts.typescript and type_ann == null and self.check(.colon)) {
                    _ = self.eat();
                    type_ann = try self.parseTsType();
                }
                break :blk pat_with_default;
            } else pat;
            const final = if (spread) try self.arena.push(.{ .rest_elem = .{
                .argument = param,
                .span = self.arena.get(param).span(),
            } }) else param;
            try params.append(self.alloc, final);
            try param_decorators.append(self.alloc, decorators);
            try param_types.append(self.alloc, type_ann);
            try param_access.append(self.alloc, param_meta.accessibility);
            try param_readonly.append(self.alloc, param_meta.is_readonly);
            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.rparen);
        const owned_params = try params.toOwnedSlice(self.alloc);
        try self.validateParams(owned_params);
        return .{
            .params = owned_params,
            .param_decorators = try param_decorators.toOwnedSlice(self.alloc),
            .param_types = try param_types.toOwnedSlice(self.alloc),
            .param_access = try param_access.toOwnedSlice(self.alloc),
            .param_readonly = try param_readonly.toOwnedSlice(self.alloc),
        };
    }

    fn eatTsParamModifiers(self: *Parser) ParamModifiers {
        var accessibility: ?ast.Accessibility = null;
        var is_readonly = false;
        while (true) {
            const raw = self.cur().raw;
            if (std.mem.eql(u8, raw, "public")) {
                accessibility = .public;
                _ = self.eat();
            } else if (std.mem.eql(u8, raw, "private")) {
                accessibility = .private;
                _ = self.eat();
            } else if (std.mem.eql(u8, raw, "protected")) {
                accessibility = .protected;
                _ = self.eat();
            } else if (self.cur().kind == .kw_readonly) {
                is_readonly = true;
                _ = self.eat();
            } else if (self.cur().kind == .kw_override) {
                _ = self.eat();
            } else break;
        }
        return .{ .accessibility = accessibility, .is_readonly = is_readonly };
    }

    fn parseReturn(self: *Parser) !NodeId {
        const kw = self.eat();
        if (self.fn_contexts.items.len == 0) {
            try self.emitError(kw, "return statement is only valid inside a function");
            return error.ParseError;
        }
        const arg: ?NodeId = if (!self.hasLineTerminatorAfter(kw) and
            !self.check(.semicolon) and
            !self.check(.rbrace) and
            !self.check(.eof))
            try self.parseExpr()
        else
            null;
        _ = self.eatIf(.semicolon);
        return self.arena.push(.{ .return_stmt = .{ .argument = arg, .span = kw.span } });
    }

    fn parseIf(self: *Parser) !NodeId {
        const kw = self.eat();
        _ = try self.expect(.lparen);
        const test_expr = try self.parseExpr();
        _ = try self.expect(.rparen);
        const consequent = try self.parseStatement();
        const alternate: ?NodeId = if (self.eatIf(.kw_else) != null) try self.parseStatement() else null;
        return self.arena.push(.{ .if_stmt = .{
            .cond = test_expr,
            .consequent = consequent,
            .alternate = alternate,
            .span = kw.span,
        } });
    }

    fn parseExprStmt(self: *Parser) !NodeId {
        const expr = try self.parseExpr();
        _ = self.eatIf(.semicolon);
        const sp = self.arena.get(expr).span();
        return self.arena.push(.{ .expr_stmt = .{ .expr = expr, .span = sp } });
    }

    const ImportAttributeClause = struct {
        syntax: ast.ImportAttributeSyntax,
        attrs: []ast.ImportAttribute,
    };

    fn parseImportAttributeClause(self: *Parser) !ImportAttributeClause {
        if (self.check(.kw_with)) {
            _ = self.eat();
            return .{ .syntax = .with, .attrs = try self.parseImportAttributes() };
        }

        if (self.check(.ident) and std.mem.eql(u8, self.cur().raw, "assert")) {
            _ = self.eat();
            return .{ .syntax = .assert, .attrs = try self.parseImportAttributes() };
        }

        return .{ .syntax = .none, .attrs = &.{} };
    }

    fn parseImportAttributes(self: *Parser) ![]ast.ImportAttribute {
        var attrs = std.ArrayListUnmanaged(ast.ImportAttribute).empty;
        _ = try self.expect(.lbrace);
        while (!self.check(.rbrace) and !self.check(.eof)) {
            // key: ident or string
            const key = if (self.check(.string)) blk: {
                const t = self.eat();
                break :blk t.raw[1 .. t.raw.len - 1]; // strip quotes
            } else blk: {
                const t = self.eat();
                break :blk t.raw;
            };
            _ = try self.expect(.colon);
            const val_tok = self.eat();
            const val = if (val_tok.kind == .string)
                val_tok.raw[1 .. val_tok.raw.len - 1]
            else
                val_tok.raw;
            try attrs.append(self.alloc, .{ .key = key, .value = val });
            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.rbrace);
        return attrs.toOwnedSlice(self.alloc);
    }

    fn parseImport(self: *Parser) !NodeId {
        const kw = self.eat();
        const is_type = self.opts.typescript and
            std.mem.eql(u8, self.cur().raw, "type") and
            (self.peek2Kind() == .ident or self.peek2Kind() == .lbrace or self.peek2Kind() == .star);
        if (is_type) _ = self.eat();

        // Stage-3 deferred imports use a contextual `defer` before the
        // namespace import marker: `import defer * as ns from "mod";`.
        // Treat it as import metadata, not as a default import named `defer`.
        const is_deferred = !is_type and
            std.mem.eql(u8, self.cur().raw, "defer") and
            self.peek2Kind() == .star;
        if (is_deferred) _ = self.eat();

        var specs = std.ArrayListUnmanaged(ast.ImportSpecifier).empty;

        if (self.check(.string)) {
            const src = try self.parseStrLit();
            const attr_clause = try self.parseImportAttributeClause();
            _ = self.eatIf(.semicolon);
            return self.arena.push(.{ .import_decl = .{
                .specifiers = &.{},
                .source = src,
                .is_type_only = is_type,
                .is_deferred = false,
                .attributes = attr_clause.attrs,
                .attribute_syntax = attr_clause.syntax,
                .span = kw.span,
            } });
        }

        if (self.check(.ident)) {
            const local = try self.parseIdent();
            try specs.append(self.alloc, .{
                .kind = .default,
                .local = local,
                .imported = null,
                .is_type_only = false,
                .span = self.arena.get(local).span(),
            });
            if (self.eatIf(.comma) != null) {
                try self.parseImportNamespaceOrNamed(&specs);
            }
        } else {
            try self.parseImportNamespaceOrNamed(&specs);
        }

        try self.declareImportSpecifiers(specs.items);

        _ = try self.expect(.kw_from);
        const source = try self.parseStrLit();
        const attr_clause = try self.parseImportAttributeClause();
        _ = self.eatIf(.semicolon);

        return self.arena.push(.{ .import_decl = .{
            .specifiers = try specs.toOwnedSlice(self.alloc),
            .source = source,
            .is_type_only = is_type,
            .is_deferred = is_deferred,
            .attributes = attr_clause.attrs,
            .attribute_syntax = attr_clause.syntax,
            .span = kw.span,
        } });
    }

    fn parseImportNamespaceOrNamed(self: *Parser, specs: *std.ArrayListUnmanaged(ast.ImportSpecifier)) !void {
        if (self.eatIf(.star) != null) {
            _ = try self.expect(.kw_as);
            const local = try self.parseIdent();
            try specs.append(self.alloc, .{
                .kind = .namespace,
                .local = local,
                .imported = null,
                .is_type_only = false,
                .span = self.arena.get(local).span(),
            });
        } else if (self.check(.lbrace)) {
            _ = self.eat();
            while (!self.check(.rbrace) and !self.check(.eof)) {
                const is_type_spec = self.opts.typescript and std.mem.eql(u8, self.cur().raw, "type") and
                    self.peek2Kind() == .ident;
                if (is_type_spec) _ = self.eat();
                const imported = try self.parseIdent();
                const local = if (self.eatIf(.kw_as) != null) try self.parseIdent() else imported;
                try specs.append(self.alloc, .{
                    .kind = .named,
                    .local = local,
                    .imported = if (local != imported) imported else null,
                    .is_type_only = is_type_spec,
                    .span = self.arena.get(imported).span(),
                });
                if (self.eatIf(.comma) == null) break;
            }
            _ = try self.expect(.rbrace);
        }
    }

    fn parseExport(self: *Parser) !NodeId {
        const kw = self.eat();
        const is_type = self.opts.typescript and std.mem.eql(u8, self.cur().raw, "type");
        if (is_type) _ = self.eat();

        if (is_type and self.check(.star)) {
            _ = self.eat();
            const exported: ?NodeId = if (self.eatIf(.kw_as) != null) try self.parseIdent() else null;
            _ = try self.expect(.kw_from);
            const source = try self.parseStrLit();
            const attr_clause = try self.parseImportAttributeClause();
            _ = self.eatIf(.semicolon);
            return self.arena.push(.{ .export_decl = .{
                .kind = .{ .all = .{
                    .exported = exported,
                    .source = source,
                    .is_type_only = true,
                    .attributes = attr_clause.attrs,
                    .attribute_syntax = attr_clause.syntax,
                } },
                .span = kw.span,
            } });
        }

        if (is_type and !self.check(.lbrace)) {
            const decl = try self.parseTsTypeAliasAfterTypeKeyword();
            return self.arena.push(.{ .export_decl = .{
                .kind = .{ .decl = decl },
                .span = kw.span,
            } });
        }

        if (self.eatIf(.kw_default) != null) {
            const expr = if (self.check(.kw_function) or self.check(.kw_class) or self.check(.kw_async))
                try self.parseStatement()
            else
                try self.parseExpr();
            _ = self.eatIf(.semicolon);
            return self.arena.push(.{ .export_decl = .{
                .kind = .{ .default_expr = expr },
                .span = kw.span,
            } });
        }

        if (self.check(.star)) {
            _ = self.eat();
            const exported: ?NodeId = if (self.eatIf(.kw_as) != null) try self.parseIdent() else null;
            _ = try self.expect(.kw_from);
            const source = try self.parseStrLit();
            const attr_clause = try self.parseImportAttributeClause();
            _ = self.eatIf(.semicolon);
            return self.arena.push(.{ .export_decl = .{
                .kind = .{ .all = .{
                    .exported = exported,
                    .source = source,
                    .is_type_only = false,
                    .attributes = attr_clause.attrs,
                    .attribute_syntax = attr_clause.syntax,
                } },
                .span = kw.span,
            } });
        }

        if (self.check(.lbrace)) {
            _ = self.eat();
            var specs = std.ArrayListUnmanaged(ast.ExportSpecifier).empty;
            while (!self.check(.rbrace) and !self.check(.eof)) {
                const is_type_spec = self.opts.typescript and std.mem.eql(u8, self.cur().raw, "type") and
                    self.peek2Kind() == .ident;
                if (is_type_spec) _ = self.eat();
                const local = try self.parseIdent();
                const exported = if (self.eatIf(.kw_as) != null) try self.parseIdent() else local;
                try specs.append(self.alloc, .{
                    .local = local,
                    .exported = exported,
                    .is_type_only = is_type or is_type_spec,
                    .span = self.arena.get(local).span(),
                });
                if (self.eatIf(.comma) == null) break;
            }
            _ = try self.expect(.rbrace);
            const source: ?NodeId = if (self.eatIf(.kw_from) != null) try self.parseStrLit() else null;
            const attr_clause: ImportAttributeClause = if (source != null)
                try self.parseImportAttributeClause()
            else
                .{ .syntax = .none, .attrs = &.{} };
            _ = self.eatIf(.semicolon);
            return self.arena.push(.{ .export_decl = .{
                .kind = .{ .named = .{
                    .specifiers = try specs.toOwnedSlice(self.alloc),
                    .source = source,
                    .is_type_only = is_type,
                    .attributes = attr_clause.attrs,
                    .attribute_syntax = attr_clause.syntax,
                } },
                .span = kw.span,
            } });
        }

        const decl = try self.parseStatement();
        return self.arena.push(.{ .export_decl = .{
            .kind = .{ .decl = decl },
            .span = kw.span,
        } });
    }

    pub fn parseExpr(self: *Parser) !NodeId {
        try self.checkDepth();
        defer self.parse_depth -= 1;
        const left = try self.parseAssignExpr();
        if (self.check(.comma)) {
            var exprs = std.ArrayListUnmanaged(NodeId).empty;
            try exprs.append(self.alloc, left);
            while (self.eatIf(.comma) != null) {
                try exprs.append(self.alloc, try self.parseAssignExpr());
            }
            const sp = self.arena.get(left).span();
            return self.arena.push(.{ .seq_expr = .{
                .exprs = try exprs.toOwnedSlice(self.alloc),
                .span = sp,
            } });
        }
        return left;
    }

    fn parseAssignExpr(self: *Parser) anyerror!NodeId {
        // single-param no-paren arrow: `item => body` or `async item => body`
        if (self.check(.ident) and self.peek2Kind() == .arrow) {
            const param = try self.parseIdent();
            _ = try self.expect(.arrow);
            return self.parseArrowBody(&.{param}, &.{null}, &.{}, false);
        }
        const left = try self.parseTernary();
        const op: ?ast.AssignOp = switch (self.cur().kind) {
            .eq => .eq,
            .plus_eq => .plus_eq,
            .minus_eq => .minus_eq,
            .star_eq => .star_eq,
            .slash_eq => .slash_eq,
            .percent_eq => .percent_eq,
            .star2_eq => .star2_eq,
            .amp_eq => .amp_eq,
            .pipe_eq => .pipe_eq,
            .caret_eq => .caret_eq,
            .lt2_eq => .lt2_eq,
            .gt2_eq => .gt2_eq,
            .gt3_eq => .gt3_eq,
            .amp2_eq => .amp2_eq,
            .pipe2_eq => .pipe2_eq,
            .question2_eq => .question2_eq,
            else => null,
        };
        if (op) |o| {
            _ = self.eat();
            const right = try self.parseAssignExpr();
            if (o == .eq) try self.validateAssignment(left, right);
            const sp = self.arena.get(left).span();
            return self.arena.push(.{ .assign_expr = .{ .op = o, .left = left, .right = right, .span = sp } });
        }
        var expr = left;
        while (self.opts.typescript) {
            if (self.cur().kind == .kw_as) {
                _ = self.eat();
                const type_ann = try self.parseTsType();
                const sp = self.arena.get(expr).span();
                expr = try self.arena.push(.{ .ts_as_expr = .{ .expr = expr, .type_ann = type_ann, .span = sp } });
                continue;
            }
            if (self.cur().kind == .kw_satisfies) {
                _ = self.eat();
                const type_ann = try self.parseTsType();
                const sp = self.arena.get(expr).span();
                expr = try self.arena.push(.{ .ts_satisfies = .{ .expr = expr, .type_ann = type_ann, .span = sp } });
                continue;
            }
            break;
        }
        return expr;
    }

    fn parseTernary(self: *Parser) anyerror!NodeId {
        const test_expr = try self.parseBinary(0);
        if (self.eatIf(.question) != null) {
            const consequent = try self.parseAssignExpr();
            _ = try self.expect(.colon);
            const alternate = try self.parseAssignExpr();
            const sp = self.arena.get(test_expr).span();
            return self.arena.push(.{ .cond_expr = .{
                .cond = test_expr,
                .consequent = consequent,
                .alternate = alternate,
                .span = sp,
            } });
        }
        return test_expr;
    }

    const BinPrec = struct { op: ast.BinOp, prec: u8, right_assoc: bool = false };

    fn tokenToBinOp(kind: TokenKind) ?BinPrec {
        return switch (kind) {
            .pipe2 => .{ .op = .pipe2, .prec = 4 },
            .amp2 => .{ .op = .amp2, .prec = 5 },
            .question2 => .{ .op = .question2, .prec = 4 },
            .pipe => .{ .op = .pipe, .prec = 6 },
            .caret => .{ .op = .caret, .prec = 7 },
            .amp => .{ .op = .amp, .prec = 8 },
            .eq2 => .{ .op = .eq2, .prec = 9 },
            .eq3 => .{ .op = .eq3, .prec = 9 },
            .bang_eq => .{ .op = .neq, .prec = 9 },
            .bang_eq2 => .{ .op = .neq2, .prec = 9 },
            .lt => .{ .op = .lt, .prec = 10 },
            .lt_eq => .{ .op = .lte, .prec = 10 },
            .gt => .{ .op = .gt, .prec = 10 },
            .gt_eq => .{ .op = .gte, .prec = 10 },
            .kw_instanceof => .{ .op = .instanceof, .prec = 10 },
            .kw_in => .{ .op = .in, .prec = 10 },
            .lt2 => .{ .op = .lt2, .prec = 11 },
            .gt2 => .{ .op = .gt2, .prec = 11 },
            .gt3 => .{ .op = .gt3, .prec = 11 },
            .plus => .{ .op = .plus, .prec = 12 },
            .minus => .{ .op = .minus, .prec = 12 },
            .star => .{ .op = .star, .prec = 13 },
            .slash => .{ .op = .slash, .prec = 13 },
            .percent => .{ .op = .percent, .prec = 13 },
            .star2 => .{ .op = .star2, .prec = 14, .right_assoc = true },
            else => null,
        };
    }

    fn parseBinary(self: *Parser, min_prec: u8) !NodeId {
        var left = try self.parseUnary();
        while (true) {
            const bp = tokenToBinOp(self.cur().kind) orelse break;
            if (bp.prec <= min_prec) break;
            _ = self.eat();
            const next_prec: u8 = if (bp.right_assoc) bp.prec - 1 else bp.prec;
            const right = try self.parseBinary(next_prec);
            const left_span = self.arena.get(left).span();
            const right_span = self.arena.get(right).span();
            left = try self.arena.push(.{ .binary_expr = .{ .op = bp.op, .left = left, .right = right, .span = .{ .start = left_span.start, .end = right_span.end, .line = left_span.line, .col = left_span.col } } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) !NodeId {
        const t = self.cur();
        switch (t.kind) {
            .bang, .tilde, .plus, .minus => {
                _ = self.eat();
                const op: ast.UnaryOp = switch (t.kind) {
                    .bang => .bang,
                    .tilde => .tilde,
                    .plus => .plus,
                    .minus => .minus,
                    else => unreachable,
                };
                const arg = try self.parseUnary();
                return self.arena.push(.{ .unary_expr = .{ .op = op, .prefix = true, .argument = arg, .span = t.span } });
            },
            .kw_typeof => {
                _ = self.eat();
                const arg = try self.parseUnary();
                return self.arena.push(.{ .unary_expr = .{ .op = .typeof, .prefix = true, .argument = arg, .span = t.span } });
            },
            .kw_void => {
                _ = self.eat();
                const arg = try self.parseUnary();
                return self.arena.push(.{ .unary_expr = .{ .op = .void, .prefix = true, .argument = arg, .span = t.span } });
            },
            .kw_delete => {
                _ = self.eat();
                const arg = try self.parseUnary();
                return self.arena.push(.{ .unary_expr = .{ .op = .delete, .prefix = true, .argument = arg, .span = t.span } });
            },
            .kw_await => {
                _ = self.eat();
                const allow_top_level_await = self.opts.source_type == .module and self.fn_contexts.items.len == 0;
                const allow_async_function_await = if (self.currentFnContext()) |ctx| ctx.is_async else false;
                if (!allow_top_level_await and !allow_async_function_await) {
                    try self.emitError(t, "await expression is only valid inside an async function or at the top level of a module");
                    return error.ParseError;
                }
                const arg = try self.parseUnary();
                return self.arena.push(.{ .await_expr = .{ .argument = arg, .span = t.span } });
            },
            .plus2 => {
                _ = self.eat();
                const arg = try self.parseUnary();
                return self.arena.push(.{ .update_expr = .{ .op = .plus2, .prefix = true, .argument = arg, .span = t.span } });
            },
            .minus2 => {
                _ = self.eat();
                const arg = try self.parseUnary();
                return self.arena.push(.{ .update_expr = .{ .op = .minus2, .prefix = true, .argument = arg, .span = t.span } });
            },
            else => {},
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) !NodeId {
        var node = try self.parseCallMember();
        while (true) {
            switch (self.cur().kind) {
                .plus2 => {
                    const t = self.eat();
                    node = try self.arena.push(.{ .update_expr = .{ .op = .plus2, .prefix = false, .argument = node, .span = t.span } });
                },
                .minus2 => {
                    const t = self.eat();
                    node = try self.arena.push(.{ .update_expr = .{ .op = .minus2, .prefix = false, .argument = node, .span = t.span } });
                },
                else => break,
            }
        }
        return node;
    }

    fn parseCallMember(self: *Parser) anyerror!NodeId {
        var node = try self.parsePrimary();
        while (true) {
            switch (self.cur().kind) {
                .dot => {
                    _ = self.eat();
                    const prop = try self.parseIdentOrKeywordAsIdent();
                    const sp = self.arena.get(node).span();
                    node = try self.arena.push(.{ .member_expr = .{ .object = node, .prop = prop, .computed = false, .optional = false, .span = sp } });
                },
                .question_dot => {
                    _ = self.eat();
                    if (self.check(.lparen)) {
                        const args = try self.parseCallArgs();
                        const sp = self.arena.get(node).span();
                        node = try self.arena.push(.{ .call_expr = .{ .callee = node, .type_args = &.{}, .args = args, .optional = true, .span = sp } });
                    } else if (self.check(.lbracket)) {
                        _ = self.eat();
                        const prop = try self.parseExpr();
                        _ = try self.expect(.rbracket);
                        const sp = self.arena.get(node).span();
                        node = try self.arena.push(.{ .member_expr = .{ .object = node, .prop = prop, .computed = true, .optional = true, .span = sp } });
                    } else {
                        const prop = try self.parseIdentOrKeywordAsIdent();
                        const sp = self.arena.get(node).span();
                        node = try self.arena.push(.{ .member_expr = .{ .object = node, .prop = prop, .computed = false, .optional = true, .span = sp } });
                    }
                },
                .lbracket => {
                    _ = self.eat();
                    const prop = try self.parseExpr();
                    _ = try self.expect(.rbracket);
                    const sp = self.arena.get(node).span();
                    node = try self.arena.push(.{ .member_expr = .{ .object = node, .prop = prop, .computed = true, .optional = false, .span = sp } });
                },
                .lparen => {
                    const lparen = self.cur();
                    if (self.shouldReportAsiCallContinuation(node, lparen)) {
                        try self.emitErrorAtSpan(lparen.span, "unexpected call of previous expression");
                        return error.ParseError;
                    }

                    const args = try self.parseCallArgs();
                    const sp = self.arena.get(node).span();
                    node = try self.arena.push(.{ .call_expr = .{ .callee = node, .type_args = &.{}, .args = args, .optional = false, .span = sp } });
                },
                .bang => if (self.opts.typescript) {
                    _ = self.eat();
                    const sp = self.arena.get(node).span();
                    node = try self.arena.push(.{ .ts_non_null = .{ .expr = node, .span = sp } });
                } else break,
                .lt => if (self.opts.typescript) {
                    if (try self.tryParseTypeArgsBeforeCall()) |type_args| {
                        if (self.check(.lparen)) {
                            const args = try self.parseCallArgs();
                            const sp = self.arena.get(node).span();
                            node = try self.arena.push(.{ .call_expr = .{ .callee = node, .type_args = type_args, .args = args, .optional = false, .span = sp } });
                        } else {
                            const sp = self.arena.get(node).span();
                            node = try self.arena.push(.{ .ts_instantiation = .{ .expr = node, .type_args = type_args, .span = sp } });
                        }
                    } else break;
                } else break,
                .template_head, .template_no_sub => {
                    const quasi = try self.parseTemplateLit();
                    const sp = self.arena.get(node).span();
                    node = try self.arena.push(.{ .tagged_template = .{ .tag = node, .quasi = quasi, .span = sp } });
                },
                else => break,
            }
        }
        return node;
    }

    fn shouldReportAsiCallContinuation(self: *Parser, callee: NodeId, lparen: Token) bool {
        if (!self.opts.check) return false;
        if (!self.hasLineTerminatorBetween(self.arena.get(callee).span(), lparen.span)) return false;
        return self.isPossiblyNonCallableResult(callee);
    }

    fn hasLineTerminatorBetween(self: *Parser, before: ast.Span, after: ast.Span) bool {
        if (after.start <= before.end) return false;
        const start: usize = @intCast(before.end);
        const end: usize = @intCast(after.start);
        return std.mem.indexOfScalar(u8, self.src[start..end], '\n') != null or
            std.mem.indexOfScalar(u8, self.src[start..end], '\r') != null;
    }

    fn isPossiblyNonCallableResult(self: *Parser, node: NodeId) bool {
        return switch (self.arena.get(node).*) {
            .new_expr,
            .await_expr,
            .import_call,
            => true,
            .ts_non_null => |expr| self.isPossiblyNonCallableResult(expr.expr),
            .ts_as_expr => |expr| self.isPossiblyNonCallableResult(expr.expr),
            .ts_satisfies => |expr| self.isPossiblyNonCallableResult(expr.expr),
            .ts_instantiation => |expr| self.isPossiblyNonCallableResult(expr.expr),
            else => false,
        };
    }

    fn parseCallArgs(self: *Parser) ![]ast.Argument {
        _ = try self.expect(.lparen);
        var args = std.ArrayListUnmanaged(ast.Argument).empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            const spread = self.eatIf(.dotdotdot) != null;
            const expr = try self.parseAssignExpr();
            try args.append(self.alloc, .{ .expr = expr, .spread = spread });
            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.rparen);
        return args.toOwnedSlice(self.alloc);
    }

    fn isTsContextualIdent(kind: TokenKind) bool {
        return switch (kind) {
            .kw_type,
            .kw_interface,
            .kw_namespace,
            .kw_declare,
            .kw_abstract,
            .kw_override,
            .kw_accessor,
            .kw_implements,
            .kw_readonly,
            .kw_satisfies,
            .kw_keyof,
            .kw_infer,
            .kw_never,
            .kw_unknown,
            .kw_is,
            .kw_enum,
            .kw_module,
            => true,
            else => false,
        };
    }

    fn isArrowParamIdent(kind: TokenKind) bool {
        return kind == .ident or kind == .kw_this or isTsContextualIdent(kind) or switch (kind) {
            .kw_from, .kw_as, .kw_get, .kw_set, .kw_of => true,
            else => false,
        };
    }

    fn parsePrimary(self: *Parser) anyerror!NodeId {
        const t = self.cur();
        return switch (t.kind) {
            .ident, .private_name => self.parseIdent(),
            .number => blk: {
                _ = self.eat();
                break :blk self.arena.push(.{ .num_lit = .{ .raw = t.raw, .span = t.span } });
            },
            .string => self.parseStrLit(),
            .regex => blk: {
                _ = self.eat();
                break :blk self.arena.push(.{ .regex_lit = .{ .raw = t.raw, .span = t.span } });
            },
            .template_no_sub, .template_head => self.parseTemplateLit(),
            .kw_true => blk: {
                _ = self.eat();
                break :blk self.arena.push(.{ .bool_lit = .{ .value = true, .span = t.span } });
            },
            .kw_false => blk: {
                _ = self.eat();
                break :blk self.arena.push(.{ .bool_lit = .{ .value = false, .span = t.span } });
            },
            .kw_null => blk: {
                _ = self.eat();
                break :blk self.arena.push(.{ .null_lit = .{ .span = t.span } });
            },
            .kw_this, .kw_super => blk: {
                _ = self.eat();
                break :blk self.arena.push(.{ .ident = .{ .name = t.raw, .span = t.span } });
            },
            .kw_new => if (self.peek2Kind() == .dot) self.parseNewTarget() else self.parseNew(),
            .kw_function => self.parseFnExpr(false),
            .kw_class => self.parseClassExpr(),
            .kw_async => self.parseAsyncArrowOrExpr(),
            .kw_yield => self.parseYield(),
            .lparen => self.parseGroupOrArrow(),
            .lbracket => self.parseArrayExpr(),
            .lbrace => self.parseObjectExpr(),
            .lt => if (self.opts.jsx and self.opts.typescript) blk: {
                if (try self.tryParseGenericArrow()) |arrow| break :blk arrow;
                break :blk self.parseJsxElement();
            } else if (self.opts.jsx)
                self.parseJsxElement()
            else if (self.opts.typescript) blk: {
                if (try self.tryParseGenericArrow()) |arrow| break :blk arrow;
                break :blk self.parseTsTypeAssertion();
            } else error.ParseError,
            .kw_import => blk: {
                _ = self.eat();
                if (self.eatIf(.dot) != null) {
                    // import.meta
                    const meta = try self.expect(.ident); // "meta"
                    if (!std.mem.eql(u8, meta.raw, "meta")) {
                        try self.emitError(meta, "expected meta after import.");
                        return error.ParseError;
                    }
                    if (self.opts.source_type != .module) {
                        try self.emitError(t, "import.meta is only valid in modules");
                        return error.ParseError;
                    }
                    break :blk self.arena.push(.{ .import_meta = .{ .span = t.span } });
                }
                // import(source) or import(source, { with: { type: 'json' } })
                _ = try self.expect(.lparen);
                const source = try self.parseAssignExpr();
                // second arg: { with: { key: val } } — parse attributes if present
                var dyn_attrs: []ast.ImportAttribute = &.{};
                if (self.eatIf(.comma) != null and self.check(.lbrace)) {
                    _ = self.eat(); // eat {
                    // expect 'with' key
                    if (self.check(.ident) and std.mem.eql(u8, self.cur().raw, "with")) {
                        _ = self.eat();
                        _ = try self.expect(.colon);
                        dyn_attrs = try self.parseImportAttributes();
                    } else {
                        // skip unknown second-arg object
                        var depth: u32 = 1;
                        while (depth > 0 and !self.check(.eof)) {
                            if (self.check(.lbrace)) depth += 1;
                            if (self.check(.rbrace)) {
                                depth -= 1;
                                if (depth == 0) break;
                            }
                            _ = self.eat();
                        }
                    }
                    _ = try self.expect(.rbrace);
                }
                _ = try self.expect(.rparen);
                break :blk self.arena.push(.{ .import_call = .{ .source = source, .attributes = dyn_attrs, .span = t.span } });
            },
            else => blk: {
                if (switch (t.kind) {
                    .kw_from, .kw_as, .kw_get, .kw_set, .kw_of => true,
                    else => false,
                }) {
                    break :blk self.parseIdentOrKeywordAsIdent();
                }
                if (self.opts.typescript and isTsContextualIdent(t.kind)) {
                    break :blk self.parseIdentOrKeywordAsIdent();
                }
                try self.emitError(t, "unexpected token");
                break :blk error.ParseError;
            },
        };
    }

    fn parseTsTypeAssertion(self: *Parser) !NodeId {
        const start = self.cur();
        try self.skipTypeArgs();
        const expr = try self.parseUnary();
        const type_ann = try self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = start.span } });
        return self.arena.push(.{ .ts_type_assert = .{ .expr = expr, .type_ann = type_ann, .span = start.span } });
    }

    fn parseIdent(self: *Parser) !NodeId {
        const t = self.eat();
        return self.arena.push(.{ .ident = .{ .name = t.raw, .span = t.span } });
    }

    fn parseIdentOrKeywordAsIdent(self: *Parser) !NodeId {
        const t = self.eat();
        return self.arena.push(.{ .ident = .{ .name = t.raw, .span = t.span } });
    }

    fn parseStrLit(self: *Parser) !NodeId {
        const t = try self.expect(.string);
        const inner = if (t.raw.len >= 2) t.raw[1 .. t.raw.len - 1] else t.raw;
        return self.arena.push(.{ .str_lit = .{ .raw = t.raw, .value = inner, .span = t.span } });
    }

    fn parseTemplateLit(self: *Parser) !NodeId {
        var quasis = std.ArrayListUnmanaged(ast.TemplateElem).empty;
        var exprs = std.ArrayListUnmanaged(NodeId).empty;
        const head = self.eat();
        try quasis.append(self.alloc, .{ .raw = head.raw, .span = head.span });
        if (head.kind == .template_no_sub) {
            return self.arena.push(.{ .template_lit = .{
                .quasis = try quasis.toOwnedSlice(self.alloc),
                .exprs = &.{},
                .span = head.span,
            } });
        }
        while (true) {
            try exprs.append(self.alloc, try self.parseExpr());
            const mid = self.eat();
            if (mid.kind != .template_middle and mid.kind != .template_tail) {
                try self.emitError(mid, "unexpected token");
                return error.ParseError;
            }
            try quasis.append(self.alloc, .{ .raw = mid.raw, .span = mid.span });
            if (mid.kind == .template_tail) break;
        }
        return self.arena.push(.{ .template_lit = .{
            .quasis = try quasis.toOwnedSlice(self.alloc),
            .exprs = try exprs.toOwnedSlice(self.alloc),
            .span = head.span,
        } });
    }

    fn parseGroupOrArrow(self: *Parser) !NodeId {
        _ = try self.expect(.lparen);
        if (self.check(.rparen)) {
            _ = self.eat();
            if (self.opts.typescript and self.check(.colon)) {
                _ = self.eat();
                _ = try self.parseTsType();
            }
            _ = try self.expect(.arrow);
            return self.parseArrowBody(&.{}, &.{}, &.{}, false);
        }
        // Parenthesized expressions and arrow params are ambiguous:
        //   (resolve)       -> grouped expression
        //   (resolve) => x  -> arrow params
        //   (a, b) => x     -> parenthesized arrow params in JS/TS
        // Always try the arrow form speculatively first. If there is no `=>`,
        // tryParseParenthesizedArrowParams restores the parser state and we
        // continue parsing this as a normal grouped expression.
        if (try self.tryParseParenthesizedArrowParams(false)) |arrow| return arrow;
        const expr = try self.parseExpr();
        _ = try self.expect(.rparen);
        if (self.opts.typescript and self.check(.colon)) {
            _ = self.eat();
            _ = try self.parseTsType();
        }
        if (self.check(.arrow)) {
            _ = self.eat();
            return self.parseArrowBody(&.{expr}, &.{null}, &.{}, false);
        }
        return expr;
    }

    fn tryParseParenthesizedArrowParams(self: *Parser, is_async: bool) !?NodeId {
        const snap = self.saveLexer();
        const arena_len = self.arena.nodes.items.len;
        const diag_len = self.diags.items.items.len;

        var params = std.ArrayListUnmanaged(NodeId).empty;
        var param_types = std.ArrayListUnmanaged(?NodeId).empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            if (self.opts.typescript) _ = self.eatTsParamModifiers();
            const spread = self.eatIf(.dotdotdot) != null;
            const pat = self.parseBindingPattern() catch {
                self.restoreLexer(snap);
                self.arena.nodes.items.len = arena_len;
                self.diags.items.items.len = diag_len;
                return null;
            };
            if (self.opts.typescript) _ = self.eatIf(.question);
            var type_ann: ?NodeId = if (self.opts.typescript and self.check(.colon)) blk: {
                _ = self.eat();
                break :blk self.parseTsType() catch {
                    self.restoreLexer(snap);
                    self.arena.nodes.items.len = arena_len;
                    self.diags.items.items.len = diag_len;
                    return null;
                };
            } else null;
            const param = if (self.check(.eq)) blk: {
                _ = self.eat();
                const def = self.parseAssignExpr() catch {
                    self.restoreLexer(snap);
                    self.arena.nodes.items.len = arena_len;
                    self.diags.items.items.len = diag_len;
                    return null;
                };
                const pat_with_default = try self.arena.push(.{ .assign_pat = .{ .left = pat, .right = def, .span = self.arena.get(pat).span() } });
                if (self.opts.typescript and type_ann == null and self.check(.colon)) {
                    _ = self.eat();
                    type_ann = self.parseTsType() catch {
                        self.restoreLexer(snap);
                        self.arena.nodes.items.len = arena_len;
                        self.diags.items.items.len = diag_len;
                        return null;
                    };
                }
                break :blk pat_with_default;
            } else pat;
            const final = if (spread) try self.arena.push(.{ .rest_elem = .{ .argument = param, .span = self.arena.get(param).span() } }) else param;
            try params.append(self.alloc, final);
            try param_types.append(self.alloc, type_ann);
            if (self.eatIf(.comma) == null) break;
        }

        _ = self.expect(.rparen) catch {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        };
        if (self.opts.typescript and self.check(.colon)) {
            _ = self.eat();
            _ = self.parseTsType() catch {
                self.restoreLexer(snap);
                self.arena.nodes.items.len = arena_len;
                self.diags.items.items.len = diag_len;
                return null;
            };
        }
        _ = self.expect(.arrow) catch {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        };

        const arrow = try self.parseArrowBody(try params.toOwnedSlice(self.alloc), try param_types.toOwnedSlice(self.alloc), &.{}, is_async);
        return arrow;
    }

    /// Parse `<T>(params) => body` — generic arrow in non-JSX TS mode.
    fn parseGenericArrow(self: *Parser) !NodeId {
        const type_params = try self.parseTsTypeParams();
        return self.parseArrowWithTypeParams(type_params, false);
    }

    fn parseArrowWithTypeParams(self: *Parser, type_params: []ast.TsTypeParam, is_async: bool) !NodeId {
        _ = try self.expect(.lparen);
        var params = std.ArrayListUnmanaged(NodeId).empty;
        var param_types = std.ArrayListUnmanaged(?NodeId).empty;
        while (!self.check(.rparen) and !self.check(.eof)) {
            _ = self.eatTsParamModifiers();
            const spread = self.eatIf(.dotdotdot) != null;
            const pat = try self.parseBindingPattern();
            _ = self.eatIf(.question);
            var type_ann: ?NodeId = if (self.check(.colon)) blk: {
                _ = self.eat();
                break :blk try self.parseTsType();
            } else null;
            const param = if (self.check(.eq)) blk: {
                _ = self.eat();
                const def = try self.parseAssignExpr();
                const pat_with_default = try self.arena.push(.{ .assign_pat = .{ .left = pat, .right = def, .span = self.arena.get(pat).span() } });
                if (type_ann == null and self.check(.colon)) {
                    _ = self.eat();
                    type_ann = try self.parseTsType();
                }
                break :blk pat_with_default;
            } else pat;
            const final = if (spread) try self.arena.push(.{ .rest_elem = .{ .argument = param, .span = self.arena.get(param).span() } }) else param;
            try params.append(self.alloc, final);
            try param_types.append(self.alloc, type_ann);
            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.rparen);
        if (self.check(.colon)) {
            _ = self.eat();
            _ = try self.parseTsType();
        }
        _ = try self.expect(.arrow);
        return self.parseArrowBody(try params.toOwnedSlice(self.alloc), try param_types.toOwnedSlice(self.alloc), type_params, is_async);
    }

    fn parseArrowBody(self: *Parser, params: []const NodeId, param_types: []const ?NodeId, type_params: []const ast.TsTypeParam, is_async: bool) !NodeId {
        const sp = self.cur().span;
        try self.validateParams(params);
        const is_expr = !self.check(.lbrace);
        const body = try self.parseFunctionBodyNode(is_async, false, is_expr);
        return self.arena.push(.{ .arrow_fn = .{
            .type_params = try self.alloc.dupe(ast.TsTypeParam, type_params),
            .params = try self.alloc.dupe(NodeId, params),
            .param_types = try self.alloc.dupe(?NodeId, param_types),
            .body = body,
            .is_async = is_async,
            .is_expr_body = is_expr,
            .span = sp,
        } });
    }

    fn parseMemberOnly(self: *Parser) anyerror!NodeId {
        // Like parseCallMember but stops before consuming call args — for `new` callee
        var node = if (self.check(.kw_new)) try self.parseNew() else try self.parsePrimary();
        while (true) {
            switch (self.cur().kind) {
                .dot => {
                    _ = self.eat();
                    const prop = try self.parseIdentOrKeywordAsIdent();
                    node = try self.arena.push(.{ .member_expr = .{ .object = node, .prop = prop, .computed = false, .optional = false, .span = self.arena.get(node).span() } });
                },
                .lbracket => {
                    _ = self.eat();
                    const prop = try self.parseExpr();
                    _ = try self.expect(.rbracket);
                    node = try self.arena.push(.{ .member_expr = .{ .object = node, .prop = prop, .computed = true, .optional = false, .span = self.arena.get(node).span() } });
                },
                else => break,
            }
        }
        return node;
    }

    fn parseNewTarget(self: *Parser) !NodeId {
        const kw = try self.expect(.kw_new);
        _ = try self.expect(.dot);
        const target = self.eat();
        if (target.kind != .ident or !std.mem.eql(u8, target.raw, "target")) {
            try self.emitError(target, "expected target after new.");
            return error.ParseError;
        }
        return self.arena.push(.{ .new_target = .{ .span = kw.span } });
    }

    fn parseNew(self: *Parser) anyerror!NodeId {
        const kw = self.eat();
        const callee = try self.parseMemberOnly();
        const type_args: []NodeId = if (self.opts.typescript) (try self.tryParseTypeArgsBeforeCall()) orelse &.{} else &.{};
        const args: []ast.Argument = if (self.check(.lparen)) try self.parseCallArgs() else &.{};
        return self.arena.push(.{ .new_expr = .{ .callee = callee, .type_args = type_args, .args = args, .span = kw.span } });
    }

    fn parseYield(self: *Parser) !NodeId {
        const kw = self.eat();
        const in_generator = if (self.currentFnContext()) |ctx| ctx.is_generator else false;
        if (!in_generator) {
            try self.emitError(kw, "yield expression is only valid inside a generator function");
            return error.ParseError;
        }
        const delegate = self.eatIf(.star) != null;
        const arg: ?NodeId = if (!self.hasLineTerminatorAfter(kw) and !self.check(.semicolon) and !self.check(.rbrace) and !self.check(.eof))
            try self.parseAssignExpr()
        else
            null;
        return self.arena.push(.{ .yield_expr = .{ .argument = arg, .delegate = delegate, .span = kw.span } });
    }

    fn parseAsyncArrowOrExpr(self: *Parser) !NodeId {
        const kw = self.eat();
        // In expression position `async function` is a function expression, not a
        // declaration, so the IIFE keeps its wrapping parens and leading semicolon.
        if (self.check(.kw_function)) return self.parseFnExpr(true);
        if (self.opts.typescript and self.check(.lt)) {
            const type_params = try self.parseTsTypeParams();
            return self.parseArrowWithTypeParams(type_params, true);
        }
        if (self.check(.lparen)) {
            _ = self.eat();
            if (self.check(.rparen)) {
                _ = self.eat();
                if (self.opts.typescript and self.check(.colon)) {
                    _ = self.eat();
                    _ = try self.parseTsType();
                }
                _ = try self.expect(.arrow);
                return self.parseArrowBody(&.{}, &.{}, &.{}, true);
            }
            if (self.opts.typescript and (self.check(.lbrace) or self.check(.lbracket))) {
                if (try self.tryParseParenthesizedArrowParams(true)) |arrow_node| {
                    self.arena.getMut(arrow_node).arrow_fn.is_async = true;
                    return arrow_node;
                }
            }
            var params = std.ArrayListUnmanaged(NodeId).empty;
            var param_types = std.ArrayListUnmanaged(?NodeId).empty;
            while (!self.check(.rparen) and !self.check(.eof)) {
                if (self.opts.typescript) _ = self.eatTsParamModifiers();
                const spread = self.eatIf(.dotdotdot) != null;
                const pat = try self.parseBindingPattern();
                if (self.opts.typescript) _ = self.eatIf(.question);
                var type_ann: ?NodeId = if (self.opts.typescript and self.check(.colon)) blk: {
                    _ = self.eat();
                    break :blk try self.parseTsType();
                } else null;
                const param = if (self.check(.eq)) blk: {
                    _ = self.eat();
                    const def = try self.parseAssignExpr();
                    const pat_with_default = try self.arena.push(.{ .assign_pat = .{ .left = pat, .right = def, .span = self.arena.get(pat).span() } });
                    if (self.opts.typescript and type_ann == null and self.check(.colon)) {
                        _ = self.eat();
                        type_ann = try self.parseTsType();
                    }
                    break :blk pat_with_default;
                } else pat;
                const final = if (spread) try self.arena.push(.{ .rest_elem = .{ .argument = param, .span = self.arena.get(param).span() } }) else param;
                try params.append(self.alloc, final);
                try param_types.append(self.alloc, type_ann);
                if (self.eatIf(.comma) == null) break;
            }
            _ = try self.expect(.rparen);
            if (self.opts.typescript and self.check(.colon)) {
                _ = self.eat();
                _ = try self.parseTsType();
            }
            _ = try self.expect(.arrow);
            return self.parseArrowBody(try params.toOwnedSlice(self.alloc), try param_types.toOwnedSlice(self.alloc), &.{}, true);
        }
        if (self.check(.ident) or (self.opts.typescript and isTsContextualIdent(self.cur().kind))) {
            const param = try self.parseIdent();
            if (self.check(.arrow)) {
                _ = self.eat();
                return self.parseArrowBody(&.{param}, &.{null}, &.{}, true);
            }
            return param;
        }
        return self.arena.push(.{ .ident = .{ .name = "async", .span = kw.span } });
    }

    fn parseArrayExpr(self: *Parser) !NodeId {
        const open = self.eat();
        var elems = std.ArrayListUnmanaged(?NodeId).empty;
        while (!self.check(.rbracket) and !self.check(.eof)) {
            if (self.check(.comma)) {
                try elems.append(self.alloc, null);
                _ = self.eat();
                continue;
            }
            const spread = self.eatIf(.dotdotdot) != null;
            const expr = try self.parseAssignExpr();
            const elem = if (spread) try self.arena.push(.{ .spread_elem = .{ .argument = expr, .span = self.arena.get(expr).span() } }) else expr;
            try elems.append(self.alloc, elem);
            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.rbracket);
        return self.arena.push(.{ .array_expr = .{ .elements = try elems.toOwnedSlice(self.alloc), .span = open.span } });
    }

    fn parseObjectExpr(self: *Parser) !NodeId {
        const open = self.eat();
        var props = std.ArrayListUnmanaged(ast.ObjectProp).empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.check(.dotdotdot)) {
                _ = self.eat();
                const arg = try self.parseAssignExpr();
                try props.append(self.alloc, .{ .spread = arg });
            } else {
                if (self.cur().kind == .kw_async and self.isAsyncAccessorStart()) {
                    try self.emitError(self.cur(), "unexpected token");
                    return error.ParseError;
                }
                const is_async = self.cur().kind == .kw_async and (isAsyncMemberModifier(self) or self.peek2Kind() == .star);
                if (is_async) _ = self.eat();
                const is_generator = self.eatIf(.star) != null;

                var accessor_kind: ?ast.ClassMemberKind = null;
                if (!is_async and !is_generator and self.isObjectAccessorPrefix()) {
                    accessor_kind = if (self.cur().kind == .kw_get) .getter else .setter;
                    _ = self.eat(); // get | set
                }

                const pk = try self.parsePropKey();
                const type_params: []ast.TsTypeParam = if (self.opts.typescript and self.check(.lt)) try self.parseTsTypeParams() else &.{};
                if (self.check(.colon)) {
                    _ = self.eat();
                    const val = try self.parseAssignExpr();
                    try props.append(self.alloc, .{ .kv = .{ .key = pk.key, .value = val, .computed = pk.computed, .span = self.arena.get(pk.key).span() } });
                } else if (self.check(.lparen)) {
                    const parsed_params = try self.parseFnParams();
                    const return_type: ?NodeId = if (self.opts.typescript and self.check(.colon)) blk: {
                        _ = self.eat();
                        break :blk try self.parseTsType();
                    } else null;
                    const body = try self.parseFunctionBodyNode(is_async, is_generator, false);
                    const fn_node = try self.arena.push(.{ .fn_expr = .{ .id = null, .type_params = type_params, .params = parsed_params.params, .param_decorators = parsed_params.param_decorators, .param_types = parsed_params.param_types, .param_access = parsed_params.param_access, .param_readonly = parsed_params.param_readonly, .body = body, .return_type = return_type, .is_async = is_async, .is_generator = is_generator, .span = self.arena.get(pk.key).span() } });
                    try props.append(self.alloc, .{ .method = .{ .key = pk.key, .value = fn_node, .kind = accessor_kind orelse .method, .computed = pk.computed, .span = self.arena.get(pk.key).span() } });
                } else {
                    try props.append(self.alloc, .{ .shorthand = pk.key });
                }
            }
            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.rbrace);
        return self.arena.push(.{ .object_expr = .{ .props = try props.toOwnedSlice(self.alloc), .span = open.span } });
    }

    fn isObjectAccessorPrefix(self: *Parser) bool {
        const accessor = self.cur().kind;
        if (accessor != .kw_get and accessor != .kw_set) return false;

        const snap = self.saveLexer();
        defer self.restoreLexer(snap);

        _ = self.eat(); // get | set

        // `{ get() {} }` / `{ set() {} }` são métodos normais chamados
        // "get" / "set", não accessors.
        if (self.check(.lparen)) return false;

        return isClassMemberNameStart(self.cur().kind);
    }

    fn isKeyword(kind: TokenKind) bool {
        return switch (kind) {
            .kw_var,
            .kw_let,
            .kw_const,
            .kw_function,
            .kw_return,
            .kw_if,
            .kw_else,
            .kw_for,
            .kw_while,
            .kw_do,
            .kw_break,
            .kw_continue,
            .kw_switch,
            .kw_case,
            .kw_default,
            .kw_throw,
            .kw_try,
            .kw_catch,
            .kw_finally,
            .kw_new,
            .kw_delete,
            .kw_typeof,
            .kw_instanceof,
            .kw_void,
            .kw_in,
            .kw_of,
            .kw_class,
            .kw_extends,
            .kw_super,
            .kw_this,
            .kw_import,
            .kw_export,
            .kw_from,
            .kw_as,
            .kw_async,
            .kw_await,
            .kw_yield,
            .kw_static,
            .kw_get,
            .kw_set,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_with,
            .kw_debugger,
            .kw_type,
            .kw_interface,
            .kw_namespace,
            .kw_declare,
            .kw_abstract,
            .kw_override,
            .kw_accessor,
            .kw_implements,
            .kw_readonly,
            .kw_satisfies,
            .kw_keyof,
            .kw_infer,
            .kw_never,
            .kw_unknown,
            .kw_is,
            .kw_enum,
            .kw_module,
            => true,
            else => false,
        };
    }

    fn parsePropKey(self: *Parser) !struct { key: ast.NodeId, computed: bool } {
        if (self.check(.lbracket)) {
            _ = self.eat();
            const k = try self.parseAssignExpr();
            _ = try self.expect(.rbracket);
            return .{ .key = k, .computed = true };
        }
        return switch (self.cur().kind) {
            .ident, .private_name => .{ .key = try self.parseIdent(), .computed = false },
            .string => .{ .key = try self.parseStrLit(), .computed = false },
            .number => blk: {
                const t = self.eat();
                break :blk .{ .key = try self.arena.push(.{ .num_lit = .{ .raw = t.raw, .span = t.span } }), .computed = false };
            },
            else => blk: {
                const t = self.cur();
                if (isKeyword(t.kind)) {
                    break :blk .{ .key = try self.parseIdentOrKeywordAsIdent(), .computed = false };
                }
                try self.emitError(t, "unexpected token");
                break :blk error.ParseError;
            },
        };
    }

    fn parseFnExpr(self: *Parser, is_async: bool) !NodeId {
        const kw = try self.expect(.kw_function);
        const is_gen = self.eatIf(.star) != null;
        const id: ?NodeId = if (self.check(.ident) or isTsContextualIdent(self.cur().kind))
            try self.parseIdentOrKeywordAsIdent()
        else
            null;
        const type_params: []ast.TsTypeParam = if (self.opts.typescript and self.check(.lt)) try self.parseTsTypeParams() else &.{};
        const parsed_params = try self.parseFnParams();
        const return_type: ?NodeId = if (self.opts.typescript and self.check(.colon)) blk: {
            _ = self.eat();
            break :blk try self.parseTsType();
        } else null;
        const body = try self.parseFunctionBodyNode(is_async, is_gen, false);
        return self.arena.push(.{ .fn_expr = .{ .id = id, .type_params = type_params, .params = parsed_params.params, .param_decorators = parsed_params.param_decorators, .param_types = parsed_params.param_types, .param_access = parsed_params.param_access, .param_readonly = parsed_params.param_readonly, .body = body, .return_type = return_type, .is_async = is_async, .is_generator = is_gen, .span = kw.span } });
    }

    fn parseDecoratedClass(self: *Parser) !NodeId {
        const decs = try self.parseDecorators();
        if (self.check(.kw_export)) {
            _ = self.eat(); // consume 'export'
            const is_default = self.eatIf(.kw_default) != null;
            const class_id = try self.parseClassDecl();
            self.arena.getMut(class_id).class_decl.decorators = decs;
            const class_span = self.arena.get(class_id).span();
            if (is_default) {
                return self.arena.push(.{ .export_decl = .{
                    .kind = .{ .default_decl = class_id },
                    .span = class_span,
                } });
            }
            return self.arena.push(.{ .export_decl = .{
                .kind = .{ .decl = class_id },
                .span = class_span,
            } });
        }
        const class_id = try self.parseClassDecl();
        self.arena.getMut(class_id).class_decl.decorators = decs;
        return class_id;
    }

    fn parseDecorators(self: *Parser) ![]NodeId {
        var list = std.ArrayListUnmanaged(NodeId).empty;
        while (self.check(.at)) {
            _ = self.eat(); // consume @
            const expr = try self.parseDecoratorExpr();
            try list.append(self.alloc, expr);
        }
        return list.toOwnedSlice(self.alloc);
    }

    fn parseDecoratorExpr(self: *Parser) !NodeId {
        var expr = try self.parseIdent();
        // @Foo.Bar member access
        while (self.eatIf(.dot) != null) {
            const prop = try self.parseIdent();
            expr = try self.arena.push(.{ .member_expr = .{
                .object = expr,
                .prop = prop,
                .computed = false,
                .optional = false,
                .span = self.arena.get(prop).span(),
            } });
        }
        // @Foo() or @Foo.Bar() factory call
        if (self.check(.lparen)) {
            const args = try self.parseCallArgs();
            expr = try self.arena.push(.{ .call_expr = .{
                .callee = expr,
                .type_args = &.{},
                .args = args,
                .optional = false,
                .span = self.arena.get(expr).span(),
            } });
        }
        return expr;
    }

    fn parseClassDecl(self: *Parser) !NodeId {
        const is_abstract = self.cur().kind == .kw_abstract;
        if (is_abstract) _ = self.eat();
        const kw = try self.expect(.kw_class);
        const id: ?NodeId = if (self.check(.ident)) try self.parseIdent() else null;
        const type_params: []ast.TsTypeParam = if (self.opts.typescript and self.check(.lt)) try self.parseTsTypeParams() else &.{};
        if (id) |class_id| {
            try self.declareIdentifierNode(class_id, .class_decl);
        }
        const super_class: ?NodeId = if (self.eatIf(.kw_extends) != null) blk: {
            const sc = try self.parseClassHeritageExpr();
            if (self.opts.typescript and self.check(.lt)) _ = try self.parseTsTypeArgs();
            break :blk sc;
        } else null;
        if (self.opts.typescript and self.check(.kw_implements)) {
            _ = self.eat();
            _ = try self.parseTsTypeList();
        }
        const body = try self.parseClassBody();
        return self.arena.push(.{ .class_decl = .{ .id = id, .type_params = type_params, .super_class = super_class, .body = body, .decorators = &.{}, .span = kw.span } });
    }

    fn parseClassExpr(self: *Parser) !NodeId {
        const kw = self.eat();
        const id: ?NodeId = if (self.check(.ident)) try self.parseIdent() else null;
        const type_params: []ast.TsTypeParam = if (self.opts.typescript and self.check(.lt)) try self.parseTsTypeParams() else &.{};
        const super_class: ?NodeId = if (self.eatIf(.kw_extends) != null) blk: {
            const sc = try self.parseClassHeritageExpr();
            if (self.opts.typescript and self.check(.lt)) _ = try self.parseTsTypeArgs();
            break :blk sc;
        } else null;
        const body = try self.parseClassBody();
        return self.arena.push(.{ .class_expr = .{ .id = id, .type_params = type_params, .super_class = super_class, .body = body, .span = kw.span } });
    }

    fn parseClassHeritageExpr(self: *Parser) !NodeId {
        if (self.eatIf(.lparen) != null) {
            const expr = try self.parseExpr();
            _ = try self.expect(.rparen);
            return expr;
        }

        return self.parseCallMember();
    }

    fn parseClassBody(self: *Parser) ![]ast.ClassMember {
        _ = try self.expect(.lbrace);
        var members = std.ArrayListUnmanaged(ast.ClassMember).empty;
        const SeenClassField = struct {
            name: []const u8,
            is_static: bool,
        };
        var seen_fields = std.ArrayListUnmanaged(SeenClassField).empty;
        defer seen_fields.deinit(self.alloc);
        var has_constructor_impl = false;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            _ = self.eatIf(.semicolon);
            if (self.check(.rbrace)) break;
            const member = try self.parseClassMember();

            if (member.kind == .constructor and !member.is_static and member.value != null) {
                if (has_constructor_impl) {
                    try self.emitErrorAtSpan(member.span, "a class may only have one constructor implementation");
                    return error.ParseError;
                }
                has_constructor_impl = true;
            }

            if (self.classMemberFieldName(member)) |field_name| {
                for (seen_fields.items) |seen| {
                    if (seen.is_static == member.is_static and std.mem.eql(u8, seen.name, field_name)) {
                        try self.emitErrorAtSpan(member.span, "duplicate class field declaration");
                        return error.ParseError;
                    }
                }
                try seen_fields.append(self.alloc, .{ .name = field_name, .is_static = member.is_static });
            }

            try members.append(self.alloc, member);
        }
        _ = try self.expect(.rbrace);
        return members.toOwnedSlice(self.alloc);
    }

    fn classMemberFieldName(self: *Parser, member: ast.ClassMember) ?[]const u8 {
        if (member.is_computed) return null;
        return switch (member.kind) {
            .field, .auto_accessor => switch (self.arena.get(member.key).*) {
                .ident => |i| i.name,
                .str_lit => |s| s.value,
                .num_lit => |n| n.raw,
                else => null,
            },
            else => null,
        };
    }

    const MemberModifiers = struct {
        is_static: bool = false,
        is_async: bool = false,
        is_declare: bool = false,
        accessibility: ?ast.Accessibility = null,
        is_abstract: bool = false,
        is_readonly: bool = false,
        is_auto_accessor: bool = false,
    };

    fn parseMemberModifiers(self: *Parser) !MemberModifiers {
        var mods = MemberModifiers{};
        if (self.cur().kind == .kw_async and self.isAsyncAccessorStart()) {
            try self.emitError(self.cur(), "unexpected token");
            _ = self.eat(); // consume async
            mods.is_async = true;
        }
        while (true) {
            const raw = self.cur().raw;
            if (std.mem.eql(u8, raw, "static") and self.shouldConsumeClassModifier()) {
                mods.is_static = true;
                _ = self.eat();
            } else if (self.cur().kind == .kw_declare and self.shouldConsumeClassModifier()) {
                mods.is_declare = true;
                _ = self.eat();
            } else if (std.mem.eql(u8, raw, "public") and !isMemberNamePunct(self.peek2Kind())) {
                mods.accessibility = .public;
                _ = self.eat();
            } else if (std.mem.eql(u8, raw, "private") and !isMemberNamePunct(self.peek2Kind())) {
                mods.accessibility = .private;
                _ = self.eat();
            } else if (std.mem.eql(u8, raw, "protected") and !isMemberNamePunct(self.peek2Kind())) {
                mods.accessibility = .protected;
                _ = self.eat();
            } else if (self.cur().kind == .kw_async and (self.peek2Kind() == .star or isAsyncMemberModifier(self))) {
                mods.is_async = true;
                _ = self.eat();
            } else if (self.cur().kind == .kw_abstract and self.shouldConsumeClassModifier()) {
                mods.is_abstract = true;
                _ = self.eat();
            } else if (self.cur().kind == .kw_readonly and self.shouldConsumeClassModifier()) {
                mods.is_readonly = true;
                _ = self.eat();
            } else if (self.cur().kind == .kw_override and self.shouldConsumeClassModifier()) {
                _ = self.eat();
            } else if (self.cur().kind == .kw_accessor and self.shouldConsumeClassModifier()) {
                mods.is_auto_accessor = true;
                _ = self.eat();
            } else break;
        }
        return mods;
    }

    fn parseClassMember(self: *Parser) !ast.ClassMember {
        const member_decs: []NodeId = if (self.check(.at)) try self.parseDecorators() else &.{};

        const mods = try self.parseMemberModifiers();
        var is_generator = false;

        if (mods.is_static and self.check(.lbrace)) {
            const body = try self.parseBlock();
            return .{
                .kind = .static_block,
                .key = NULL_NODE,
                .value = body,
                .type_ann = null,
                .is_optional = false,
                .is_declare = false,
                .is_static = true,
                .is_computed = false,
                .accessibility = mods.accessibility,
                .is_abstract = mods.is_abstract,
                .is_readonly = mods.is_readonly,
                .decorators = member_decs,
                .span = self.arena.get(body).span(),
            };
        }

        if (try self.tryParseTsClassIndexSignature(member_decs, mods.is_static, mods.accessibility, mods.is_abstract, mods.is_readonly)) |member| {
            return member;
        }

        const sp = self.cur().span;
        is_generator = self.eatIf(.star) != null;
        var accessor_kind: ?ast.ClassMemberKind = null;
        if (!mods.is_auto_accessor and self.isClassAccessorPrefix()) {
            accessor_kind = if (self.cur().kind == .kw_get) .getter else .setter;
            _ = self.eat();
        }

        const pk = try self.parsePropKey();
        const is_computed = pk.computed;
        const key = pk.key;
        const name = switch (self.arena.get(key).*) {
            .ident => |i| i.name,
            else => "",
        };

        var kind: ast.ClassMemberKind = if (accessor_kind) |ak| ak else if (mods.is_auto_accessor) .auto_accessor else .field;
        var value: ?NodeId = null;
        var type_ann: ?NodeId = null;
        var is_optional = false;

        const type_params: []ast.TsTypeParam = if (self.opts.typescript and self.check(.lt)) try self.parseTsTypeParams() else &.{};

        if (self.check(.lparen)) {
            if (accessor_kind == null) {
                kind = if (std.mem.eql(u8, name, "constructor")) .constructor else .method;
            }
            const parsed_params = try self.parseFnParams();
            const return_type: ?NodeId = if (self.opts.typescript and self.check(.colon)) blk: {
                _ = self.eat();
                break :blk try self.parseTsType();
            } else null;
            if (!mods.is_abstract and !self.check(.semicolon) and self.check(.lbrace)) {
                const body = try self.parseFunctionBodyNode(mods.is_async, is_generator, false);
                value = try self.arena.push(.{ .fn_expr = .{ .id = null, .type_params = type_params, .params = parsed_params.params, .param_decorators = parsed_params.param_decorators, .param_types = parsed_params.param_types, .param_access = parsed_params.param_access, .param_readonly = parsed_params.param_readonly, .body = body, .return_type = return_type, .is_async = mods.is_async, .is_generator = is_generator, .span = sp } });
            } else {
                _ = self.eatIf(.semicolon);
            }
        } else {
            if (self.opts.typescript) is_optional = self.eatIf(.question) != null;
            if (self.opts.typescript) _ = self.eatIf(.bang);
            if (self.opts.typescript and self.check(.colon)) {
                _ = self.eat();
                type_ann = try self.parseTsType();
            }
            if (self.eatIf(.eq) != null) value = try self.parseAssignExpr();
            _ = self.eatIf(.semicolon);
        }

        return .{
            .kind = kind,
            .key = key,
            .value = value,
            .type_ann = type_ann,
            .is_optional = is_optional,
            .is_declare = mods.is_declare,
            .is_static = mods.is_static,
            .is_computed = is_computed,
            .accessibility = mods.accessibility,
            .is_abstract = mods.is_abstract,
            .is_readonly = mods.is_readonly,
            .decorators = member_decs,
            .span = sp,
        };
    }

    fn tryParseTsClassIndexSignature(
        self: *Parser,
        member_decs: []NodeId,
        is_static: bool,
        accessibility: ?ast.Accessibility,
        is_abstract: bool,
        is_readonly: bool,
    ) !?ast.ClassMember {
        if (!self.opts.typescript or !self.check(.lbracket)) return null;

        const snap = self.saveLexer();
        const arena_len = self.arena.nodes.items.len;
        const diag_len = self.diags.items.items.len;
        const sp = self.cur().span;

        _ = self.eat();
        if (!self.check(.ident)) {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        }

        const key = self.parseIdentOrKeywordAsIdent() catch {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        };

        if (self.eatIf(.colon) == null) {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        }

        _ = self.parseTsType() catch {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        };

        _ = self.expect(.rbracket) catch {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        };

        var type_ann: ?NodeId = null;
        if (self.check(.colon)) {
            _ = self.eat();
            type_ann = self.parseTsType() catch {
                self.restoreLexer(snap);
                self.arena.nodes.items.len = arena_len;
                self.diags.items.items.len = diag_len;
                return null;
            };
        }

        _ = self.eatIf(.semicolon);
        return .{
            .kind = .field,
            .key = key,
            .value = null,
            .type_ann = type_ann,
            .is_optional = false,
            .is_declare = true,
            .is_static = is_static,
            .is_computed = false,
            .accessibility = accessibility,
            .is_abstract = is_abstract,
            .is_readonly = is_readonly,
            .decorators = member_decs,
            .span = sp,
        };
    }

    fn isClassAccessorPrefix(self: *Parser) bool {
        const accessor = self.cur().kind;
        if (accessor != .kw_get and accessor != .kw_set) return false;

        const snap = self.saveLexer();
        defer self.restoreLexer(snap);

        _ = self.eat(); // get | set

        // `get()` / `set()` são métodos normais chamados "get"/"set".
        if (self.check(.lparen)) return false;

        return isClassMemberNameStart(self.cur().kind);
    }

    fn isClassMemberNameStart(kind: TokenKind) bool {
        return switch (kind) {
            .ident,
            .private_name,
            .string,
            .number,
            .lbracket,
            => true,
            else => isKeyword(kind),
        };
    }

    // `public()`, `public!: T`, `public?: T`, `public: T`, `public = v`, `public;` — public is the field name, not a modifier
    fn isMemberNamePunct(next: TokenKind) bool {
        return switch (next) {
            .lparen, .bang, .question, .colon, .eq, .semicolon, .rbrace => true,
            else => false,
        };
    }

    fn shouldConsumeClassModifier(self: *Parser) bool {
        const next = self.peek2Kind();
        return next == .lbrace or !isMemberNamePunct(next);
    }

    fn isAsyncAccessorStart(self: *Parser) bool {
        if (self.cur().kind != .kw_async) return false;

        const snap = self.saveLexer();
        defer self.restoreLexer(snap);

        _ = self.eat(); // async

        const accessor = self.cur().kind;
        if (accessor != .kw_get and accessor != .kw_set) return false;

        _ = self.eat(); // get | set

        // `async get()` / `async set()` are normal async methods named
        // "get"/"set"; only `async get name()` and `async set name(...)`
        // are invalid async accessors.
        if (self.check(.lparen)) return false;

        return switch (self.cur().kind) {
            .ident,
            .private_name,
            .string,
            .number,
            .lbracket,
            => true,
            else => if (isKeyword(self.cur().kind)) true else false,
        };
    }

    fn isAsyncMemberModifier(self: *Parser) bool {
        // Check if we have: async NAME ( or async NAME <
        // Current token is `async`, so check next token is a valid method name,
        // and the token after that is `(` or `<` (for type params)

        // Save full lexer state (like peek2Kind does)
        const saved_peeked = self.lexer.peeked;
        const saved_pos = self.lexer.pos;
        const saved_line = self.lexer.line;
        const saved_line_start = self.lexer.line_start;
        const saved_template_stack = self.lexer.template_stack;
        const saved_template_depth = self.lexer.template_depth;
        const saved_brace_depth = self.lexer.brace_depth;
        const saved_pending_comments_len = self.lexer.pending_comments_len;

        // Get the name token (first token after async)
        // If peeked is set, next() returns it without advancing, so we need to handle that
        if (self.lexer.peeked != null) {
            // Clear peeked so next next() call actually advances
            self.lexer.peeked = null;
        }
        const name_tok = self.lexer.next();
        const is_valid_name = isClassMemberNameStart(name_tok.kind);
        if (!is_valid_name) {
            // Restore state and return
            self.lexer.peeked = saved_peeked;
            self.lexer.pos = saved_pos;
            self.lexer.line = saved_line;
            self.lexer.line_start = saved_line_start;
            self.lexer.template_stack = saved_template_stack;
            self.lexer.template_depth = saved_template_depth;
            self.lexer.brace_depth = saved_brace_depth;
            self.lexer.pending_comments_len = saved_pending_comments_len;
            return false;
        }

        // Now peek at the token after the name (don't consume it). For
        // computed methods (`async [expr]()`), the token immediately after
        // `[` belongs to the expression, so scan until the matching `]` and
        // inspect the following token instead.
        var after_name: TokenKind = undefined;
        if (name_tok.kind == .lbracket) {
            var depth: usize = 1;
            while (depth > 0) {
                const next_tok = self.lexer.next();
                switch (next_tok.kind) {
                    .lbracket => depth += 1,
                    .rbracket => depth -= 1,
                    .eof => break,
                    else => {},
                }
            }
            after_name = self.lexer.peek().kind;
        } else {
            after_name = self.lexer.peek().kind;
        }

        // Restore lexer state
        self.lexer.peeked = saved_peeked;
        self.lexer.pos = saved_pos;
        self.lexer.line = saved_line;
        self.lexer.line_start = saved_line_start;
        self.lexer.template_stack = saved_template_stack;
        self.lexer.template_depth = saved_template_depth;
        self.lexer.brace_depth = saved_brace_depth;
        self.lexer.pending_comments_len = saved_pending_comments_len;

        return switch (after_name) {
            .lparen, .lt => true,
            else => false,
        };
    }

    fn parseBindingPattern(self: *Parser) anyerror!NodeId {
        try self.checkDepth();
        defer self.parse_depth -= 1;
        return switch (self.cur().kind) {
            .lbrace => self.parseObjectPat(),
            .lbracket => self.parseArrayPat(),
            .ident => self.parseIdent(),
            else => blk: {
                if (switch (self.cur().kind) {
                    .kw_from, .kw_as, .kw_get, .kw_set, .kw_of => true,
                    else => false,
                } or (self.opts.typescript and isTsContextualIdent(self.cur().kind))) {
                    break :blk self.parseIdentOrKeywordAsIdent();
                }
                try self.emitError(self.cur(), "unexpected token");
                break :blk error.ParseError;
            },
        };
    }

    fn parseBindingPatternWithDefault(self: *Parser) anyerror!NodeId {
        const binding = try self.parseBindingPattern();
        if (self.eatIf(.eq) != null) {
            const def = try self.parseAssignExpr();
            return self.arena.push(.{ .assign_pat = .{
                .left = binding,
                .right = def,
                .span = self.arena.get(binding).span(),
            } });
        }
        return binding;
    }

    fn parseObjectPat(self: *Parser) anyerror!NodeId {
        const open = self.eat();
        var props = std.ArrayListUnmanaged(ast.ObjectPatProp).empty;
        var rest: ?NodeId = null;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            if (self.check(.dotdotdot)) {
                _ = self.eat();
                rest = try self.parseBindingPattern();
                break;
            }
            const pk2 = try self.parsePropKey();
            const key = pk2.key;
            const value: ?NodeId = blk: {
                if (self.eatIf(.colon) != null) {
                    const binding = try self.parseBindingPattern();
                    if (self.check(.eq)) {
                        _ = self.eat();
                        const def = try self.parseAssignExpr();
                        break :blk try self.arena.push(.{ .assign_pat = .{ .left = binding, .right = def, .span = self.arena.get(binding).span() } });
                    }
                    break :blk binding;
                }
                if (self.check(.eq)) {
                    _ = self.eat();
                    const def = try self.parseAssignExpr();
                    break :blk try self.arena.push(.{ .assign_pat = .{ .left = key, .right = def, .span = self.arena.get(key).span() } });
                }
                break :blk null;
            };
            try props.append(self.alloc, .{ .assign = .{ .key = key, .value = value, .computed = pk2.computed, .span = self.arena.get(key).span() } });
            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.rbrace);
        return self.arena.push(.{ .object_pat = .{ .props = try props.toOwnedSlice(self.alloc), .rest = rest, .span = open.span } });
    }

    fn parseArrayPat(self: *Parser) !NodeId {
        const open = self.eat();
        var elems = std.ArrayListUnmanaged(?NodeId).empty;
        var rest: ?NodeId = null;
        while (!self.check(.rbracket) and !self.check(.eof)) {
            if (self.check(.comma)) {
                try elems.append(self.alloc, null);
                _ = self.eat();
                continue;
            }
            if (self.check(.dotdotdot)) {
                _ = self.eat();
                rest = try self.parseBindingPattern();
                break;
            }
            try elems.append(self.alloc, try self.parseBindingPatternWithDefault());
            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.rbracket);
        return self.arena.push(.{ .array_pat = .{ .elements = try elems.toOwnedSlice(self.alloc), .rest = rest, .span = open.span } });
    }

    fn parseTsType(self: *Parser) anyerror!NodeId {
        try self.checkDepth();
        defer self.parse_depth -= 1;
        const base = try self.parseTsUnionType();
        // type predicate: `x is T` or `this is T` (return type annotation)
        if (self.check(.kw_is)) {
            _ = self.eat(); // eat 'is'
            _ = try self.parseTsUnionType(); // eat T
            return base;
        }
        // asserts predicate: `asserts value is T` — two idents before `is`
        if ((self.check(.ident) or self.check(.kw_this)) and self.peek2Kind() == .kw_is) {
            _ = self.eat(); // eat `value`/`this`
            _ = self.eat(); // eat `is`
            _ = try self.parseTsUnionType();
            return base;
        }
        // conditional type: T extends U ? X : Y
        if (self.check(.kw_extends)) {
            _ = self.eat();
            _ = try self.parseTsUnionType();
            _ = try self.expect(.question);
            _ = try self.parseTsType();
            _ = try self.expect(.colon);
            _ = try self.parseTsType();
        }
        return base;
    }

    fn parseTsUnionType(self: *Parser) anyerror!NodeId {
        _ = self.eatIf(.pipe);
        const first = try self.parseTsIntersectionType();
        if (!self.check(.pipe)) return first;
        var types = std.ArrayListUnmanaged(NodeId).empty;
        try types.append(self.alloc, first);
        while (self.eatIf(.pipe) != null) try types.append(self.alloc, try self.parseTsIntersectionType());
        return self.arena.push(.{ .ts_union = .{ .types = try types.toOwnedSlice(self.alloc), .span = self.arena.get(first).span() } });
    }

    fn parseTsIntersectionType(self: *Parser) anyerror!NodeId {
        _ = self.eatIf(.amp);
        const first = try self.parseTsArrayType();
        if (!self.check(.amp)) return first;
        var types = std.ArrayListUnmanaged(NodeId).empty;
        try types.append(self.alloc, first);
        while (self.eatIf(.amp) != null) try types.append(self.alloc, try self.parseTsArrayType());
        return self.arena.push(.{ .ts_intersection = .{ .types = try types.toOwnedSlice(self.alloc), .span = self.arena.get(first).span() } });
    }

    fn parseTsArrayType(self: *Parser) anyerror!NodeId {
        var elem = try self.parseTsPrimaryType();
        while (self.check(.lbracket)) {
            if (self.peek2Kind() == .rbracket) {
                // T[] — array type
                _ = self.eat();
                _ = self.eat();
                elem = try self.arena.push(.{ .ts_array_type = .{ .elem = elem, .span = self.arena.get(elem).span() } });
            } else {
                // T[U] — indexed access type, consume and reuse elem
                _ = self.eat();
                _ = try self.parseTsType();
                _ = try self.expect(.rbracket);
            }
        }
        return elem;
    }

    fn parseTsPrimaryType(self: *Parser) anyerror!NodeId {
        const t = self.cur();
        const sp = t.span;
        switch (t.kind) {
            .ident => {
                if (std.mem.eql(u8, t.raw, "abstract") and self.peek2Kind() == .kw_new) {
                    _ = self.eat(); // eat contextual `abstract` in `abstract new (...) => T`
                    return self.parseTsConstructorType();
                }
                if (std.mem.eql(u8, t.raw, "unique")) {
                    const snap = self.saveLexer();
                    _ = self.eat();
                    if (self.check(.ident) and std.mem.eql(u8, self.cur().raw, "symbol")) {
                        _ = self.eat();
                        return self.arena.push(.{ .ts_keyword = .{ .keyword = .symbol, .span = sp } });
                    }
                    self.restoreLexer(snap);
                }
                const kw: ?ast.TsKeyword = if (std.mem.eql(u8, t.raw, "any")) .any else if (std.mem.eql(u8, t.raw, "string")) .string else if (std.mem.eql(u8, t.raw, "number")) .number else if (std.mem.eql(u8, t.raw, "boolean")) .boolean else if (std.mem.eql(u8, t.raw, "object")) .object else if (std.mem.eql(u8, t.raw, "symbol")) .symbol else if (std.mem.eql(u8, t.raw, "bigint")) .bigint else null;
                if (kw) |k| {
                    _ = self.eat();
                    return self.arena.push(.{ .ts_keyword = .{ .keyword = k, .span = sp } });
                }
                return self.parseTsTypeRef();
            },
            .kw_never => {
                _ = self.eat();
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .never, .span = sp } });
            },
            .kw_unknown => {
                _ = self.eat();
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .unknown, .span = sp } });
            },
            .kw_infer => {
                _ = self.eat(); // eat 'infer'
                _ = self.eatIf(.ident); // eat bound type variable (e.g. U in `infer U`)
                if (self.eatIf(.kw_extends) != null) _ = try self.parseTsType();
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
            },
            .kw_readonly => {
                _ = self.eat();
                return self.parseTsPrimaryType();
            },
            .kw_keyof => {
                _ = self.eat();
                return self.parseTsPrimaryType();
            },
            .kw_typeof => {
                // typeof in type position: eat `typeof` then consume the operand path
                if (self.check(.kw_import)) {
                    _ = self.eat(); // import
                    _ = try self.expect(.lparen);
                    _ = try self.expect(.string);
                    _ = try self.expect(.rparen);

                    while (self.eatIf(.dot) != null) {
                        _ = try self.parseIdent();
                    }

                    if (self.check(.lt)) {
                        _ = try self.parseTsTypeArgs();
                    }

                    return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
                }

                _ = self.eat();

                if (self.check(.kw_import)) {
                    try self.parseTsImportType();
                    return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
                }

                if (self.check(.ident) or self.check(.kw_this)) try self.parseTsTypeQueryPath();

                return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
            },
            .kw_import => {
                try self.parseTsImportType();
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
            },
            .kw_abstract => {
                _ = self.eat();
                if (self.check(.kw_new)) return self.parseTsConstructorType();
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
            },
            .kw_new => return self.parseTsConstructorType(),
            .kw_void => {
                _ = self.eat();
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .void_kw, .span = sp } });
            },
            .kw_null => {
                _ = self.eat();
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .null_kw, .span = sp } });
            },
            .lt => {
                // Generic function type: `<T>(params) => ReturnType`
                // Skip type params `<...>` using angle-bracket depth tracking.
                _ = self.eat(); // eat `<`
                var depth: u32 = 1;
                while (depth > 0 and !self.check(.eof)) {
                    if (self.check(.lt)) depth += 1;
                    if (self.check(.gt)) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    if (self.check(.gt2)) {
                        depth -|= 2;
                        if (depth == 0) break;
                    }
                    if (self.check(.gt3)) {
                        depth -|= 3;
                        break;
                    }
                    _ = self.eat();
                }
                // consume closing `>`, `>>`, or `>>>`
                if (self.check(.gt3)) _ = self.eat() else if (self.check(.gt2)) _ = self.eat() else _ = try self.expect(.gt);
                // Now expect `(params) => ReturnType` (same as lparen case below)
                if (self.check(.lparen)) {
                    _ = self.eat();
                    var pdepth: u32 = 1;
                    while (pdepth > 0 and !self.check(.eof)) {
                        if (self.check(.lparen)) pdepth += 1;
                        if (self.check(.rparen)) {
                            pdepth -= 1;
                            if (pdepth == 0) break;
                        }
                        _ = self.eat();
                    }
                    _ = try self.expect(.rparen);
                    if (self.eatIf(.arrow) != null) _ = try self.parseTsType();
                }
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
            },
            .lparen => {
                // function type `() => T` or `(a: A, b: B) => T` or parenthesized `(T)`
                // skip-parse contents to handle all cases without recursive type-param ambiguity
                _ = self.eat();
                var depth: u32 = 1;
                while (depth > 0 and !self.check(.eof)) {
                    if (self.check(.lparen)) depth += 1;
                    if (self.check(.rparen)) {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    _ = self.eat();
                }
                _ = try self.expect(.rparen);
                if (self.eatIf(.arrow) != null) _ = try self.parseTsType();
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
            },
            .lbracket => return self.parseTsTupleType(),
            .lbrace => return self.parseTsObjectTypeSkip(),
            .template_no_sub => {
                _ = self.eat();
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
            },
            .template_head => {
                _ = self.eat(); // eat template_head (`` `text${ ``)
                while (true) {
                    _ = try self.parseTsType(); // parse type inside `${...}`
                    const chunk = self.eat(); // eat template_middle or template_tail
                    if (chunk.kind == .template_tail) break;
                    if (chunk.kind != .template_middle) return error.ParseError;
                }
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
            },
            else => {
                _ = self.eat();
                return self.arena.push(.{ .ts_keyword = .{ .keyword = .any, .span = sp } });
            },
        }
    }

    fn parseTsTypeQueryPath(self: *Parser) !void {
        _ = self.eat(); // ident | this

        while (self.eatIf(.dot) != null) {
            _ = self.eat(); // ident/keyword/private-ish name; best-effort TS type query path
        }

        if (self.check(.lt)) {
            _ = try self.parseTsTypeArgs();
        }
    }

    fn parseTsImportType(self: *Parser) !void {
        _ = try self.expect(.kw_import);
        _ = try self.expect(.lparen);

        // import("./mod")
        _ = try self.expect(.string);

        _ = try self.expect(.rparen);

        // import("./mod").Foo.Bar
        while (self.eatIf(.dot) != null) {
            _ = self.eat();
        }

        // import("./mod").Foo<T>
        if (self.check(.lt)) {
            _ = try self.parseTsTypeArgs();
        }
    }

    fn parseTsQualifiedName(self: *Parser) !NodeId {
        var name = try self.parseIdent();
        while (self.eatIf(.dot) != null) {
            const right = try self.parseIdent();
            const left_span = self.arena.get(name).span();
            const right_span = self.arena.get(right).span();
            name = try self.arena.push(.{ .ts_qualified_name = .{
                .left = name,
                .right = right,
                .span = .{
                    .start = left_span.start,
                    .end = right_span.end,
                    .line = left_span.line,
                    .col = left_span.col,
                },
            } });
        }
        return name;
    }

    fn parseTsTypeRef(self: *Parser) !NodeId {
        const name = try self.parseTsQualifiedName();
        var type_args: []NodeId = &.{};
        if (self.check(.lt)) type_args = try self.parseTsTypeArgs();
        return self.arena.push(.{ .ts_type_ref = .{ .name = name, .type_args = type_args, .span = self.arena.get(name).span() } });
    }

    fn parseTsConstructorType(self: *Parser) !NodeId {
        _ = try self.expect(.kw_new);
        if (self.check(.lt)) _ = try self.parseTsTypeParams();
        _ = try self.expect(.lparen);
        while (!self.check(.rparen) and !self.check(.eof)) {
            if (self.check(.dotdotdot)) _ = self.eat();

            if (self.check(.ident) or self.check(.kw_this)) {
                _ = self.eat();
                _ = self.eatIf(.question);
                if (self.check(.colon)) {
                    _ = self.eat();
                    _ = try self.parseTsType();
                }
            } else {
                _ = try self.parseTsType();
            }

            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.rparen);
        _ = try self.expect(.arrow);
        return self.parseTsType();
    }

    fn parseTsTypeArgs(self: *Parser) ![]NodeId {
        _ = try self.expect(.lt);
        var args = std.ArrayListUnmanaged(NodeId).empty;
        while (!self.check(.gt) and !self.check(.gt2) and !self.check(.gt3) and !self.check(.eof)) {
            try args.append(self.alloc, try self.parseTsType());
            if (self.eatIf(.comma) == null) break;
        }
        if (self.check(.gt2)) {
            // `>>` — split: consume first `>`, leave second `>` as peeked token
            const t = self.eat();
            self.lexer.peeked = .{ .kind = .gt, .raw = t.raw[1..], .span = .{ .start = t.span.start + 1, .end = t.span.end, .line = t.span.line, .col = t.span.col + 1 } };
        } else if (self.check(.gt3)) {
            // `>>>` — split: consume first `>`, leave `>>` as peeked token
            const t = self.eat();
            self.lexer.peeked = .{ .kind = .gt2, .raw = t.raw[1..], .span = .{ .start = t.span.start + 1, .end = t.span.end, .line = t.span.line, .col = t.span.col + 1 } };
        } else {
            _ = try self.expect(.gt);
        }
        return args.toOwnedSlice(self.alloc);
    }

    fn parseTsTypeParams(self: *Parser) ![]ast.TsTypeParam {
        _ = try self.expect(.lt);
        var params = std.ArrayListUnmanaged(ast.TsTypeParam).empty;
        while (!self.check(.gt) and !self.check(.eof)) {
            _ = self.eatIf(.kw_const); // `const T` modifier in type params
            const name = try self.parseIdent();
            const constraint: ?NodeId = if (self.check(.kw_extends)) blk: {
                _ = self.eat();
                break :blk try self.parseTsType();
            } else null;
            const default_type: ?NodeId = if (self.check(.eq)) blk: {
                _ = self.eat();
                break :blk try self.parseTsType();
            } else null;
            try params.append(self.alloc, .{
                .name = name,
                .constraint = constraint,
                .default_type = default_type,
                .span = self.arena.get(name).span(),
            });
            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.gt);
        const owned_params = try params.toOwnedSlice(self.alloc);
        try self.validateTypeParams(owned_params);
        return owned_params;
    }

    const LexerSnapshot = struct {
        peeked: ?Token,
        pos: u32,
        line: u32,
        line_start: u32,
        last_kind: ?TokenKind,
        template_stack: [16]u8,
        template_depth: u8,
        brace_depth: u8,
        pending_comments_len: u8,
        comments_len: usize,
    };

    fn saveLexer(self: *Parser) LexerSnapshot {
        return .{
            .peeked = self.lexer.peeked,
            .pos = self.lexer.pos,
            .line = self.lexer.line,
            .line_start = self.lexer.line_start,
            .last_kind = self.lexer.last_kind,
            .template_stack = self.lexer.template_stack,
            .template_depth = self.lexer.template_depth,
            .brace_depth = self.lexer.brace_depth,
            .pending_comments_len = self.lexer.pending_comments_len,
            .comments_len = self.comments.items.len,
        };
    }

    fn restoreLexer(self: *Parser, snap: LexerSnapshot) void {
        self.lexer.peeked = snap.peeked;
        self.lexer.pos = snap.pos;
        self.lexer.line = snap.line;
        self.lexer.line_start = snap.line_start;
        self.lexer.last_kind = snap.last_kind;
        self.lexer.template_stack = snap.template_stack;
        self.lexer.template_depth = snap.template_depth;
        self.lexer.brace_depth = snap.brace_depth;
        self.lexer.pending_comments_len = snap.pending_comments_len;
        self.comments.items.len = snap.comments_len;
    }

    /// In JSX+TS mode, `<T>` is ambiguous. Peek past `<ident` to see if the
    /// next token is `extends`, `,`, or `=` — all unambiguously generic arrows.
    fn looksLikeGenericArrowInJsx(self: *Parser) bool {
        const snap = self.saveLexer();
        const diag_len = self.diags.items.items.len;
        defer {
            self.restoreLexer(snap);
            self.diags.items.items.len = diag_len;
        }
        _ = self.lexer.next(); // skip `<`
        const after_lt = self.lexer.peek().kind;
        // first token must be an ident (the type param name)
        if (after_lt != .ident) return false;
        _ = self.lexer.next(); // skip ident
        const after_ident = self.lexer.peek().kind;
        return after_ident == .kw_extends or after_ident == .comma or after_ident == .eq;
    }

    fn tryParseGenericArrow(self: *Parser) !?NodeId {
        if (!self.opts.typescript or !self.check(.lt)) return null;
        if (self.opts.jsx and !self.looksLikeGenericArrowInJsx()) return null;

        const snap = self.saveLexer();
        const arena_len = self.arena.nodes.items.len;
        const diag_len = self.diags.items.items.len;

        const type_params = self.parseTsTypeParams() catch {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        };

        const arrow = self.parseArrowWithTypeParams(type_params, false) catch {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        };

        return arrow;
    }

    fn tryParseTypeArgsBeforeCall(self: *Parser) !?[]NodeId {
        if (!self.check(.lt)) return null;
        const snap = self.saveLexer();
        const arena_len = self.arena.nodes.items.len;
        const diag_len = self.diags.items.items.len;
        const type_args = self.parseTsTypeArgs() catch {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        };
        if (self.check(.lparen)) return type_args;
        if (canFollowTsInstantiationExpr(self.cur().kind)) return type_args;
        self.restoreLexer(snap);
        self.arena.nodes.items.len = arena_len;
        self.diags.items.items.len = diag_len;
        return null;
    }

    fn canFollowTsInstantiationExpr(kind: TokenKind) bool {
        return switch (kind) {
            .ident,
            .number,
            .string,
            .template_no_sub,
            .template_head,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_this,
            .kw_super,
            .kw_new,
            .kw_function,
            .kw_class,
            .kw_async,
            .kw_yield,
            .lparen,
            .lbrace,
            .lbracket,
            .lt,
            => false,
            else => true,
        };
    }

    fn tryParseInstantiationExprTypeArgs(self: *Parser) !?[]NodeId {
        if (!self.check(.lt)) return null;
        const snap = self.saveLexer();
        const arena_len = self.arena.nodes.items.len;
        const diag_len = self.diags.items.items.len;
        const type_args = self.parseTsTypeArgs() catch {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        };
        if (!canFollowTsInstantiationExpr(self.cur().kind)) {
            self.restoreLexer(snap);
            self.arena.nodes.items.len = arena_len;
            self.diags.items.items.len = diag_len;
            return null;
        }
        return type_args;
    }

    fn skipTypeArgs(self: *Parser) !void {
        _ = try self.expect(.lt);
        var depth: u32 = 1;
        while (depth > 0 and !self.check(.eof)) {
            switch (self.cur().kind) {
                .lt => {
                    _ = self.eat();
                    depth += 1;
                },
                .gt => {
                    _ = self.eat();
                    depth -= 1;
                },
                .gt2 => {
                    _ = self.eat();
                    if (depth >= 2) depth -= 2 else depth = 0;
                },
                .eof => return error.ParseError,
                else => {
                    _ = self.eat();
                },
            }
        }
    }

    fn parseTsTypeList(self: *Parser) ![]NodeId {
        var list = std.ArrayListUnmanaged(NodeId).empty;
        try list.append(self.alloc, try self.parseTsType());
        while (self.eatIf(.comma) != null) try list.append(self.alloc, try self.parseTsType());
        return list.toOwnedSlice(self.alloc);
    }

    fn parseTsTupleType(self: *Parser) !NodeId {
        const open = self.eat();
        var types = std.ArrayListUnmanaged(NodeId).empty;
        while (!self.check(.rbracket) and !self.check(.eof)) {
            _ = self.eatIf(.dotdotdot); // rest element: ...T
            // labeled element: `name?:` or `name:` — try to detect and skip label.
            // Labels are IdentifierName, so keywords like `from` are valid here.
            if (self.check(.ident) or isKeyword(self.cur().kind)) {
                const snap = self.saveLexer();
                _ = self.eat(); // consume potential label ident
                _ = self.eatIf(.question); // optional `?`
                if (self.check(.colon)) {
                    _ = self.eat(); // consume ':', it's a label
                } else {
                    self.restoreLexer(snap); // not a label, backtrack
                }
            }
            try types.append(self.alloc, try self.parseTsType());
            _ = self.eatIf(.question); // optional tuple element: T?
            if (self.eatIf(.comma) == null) break;
        }
        _ = try self.expect(.rbracket);
        return self.arena.push(.{ .ts_tuple = .{ .types = try types.toOwnedSlice(self.alloc), .span = open.span } });
    }

    fn parseTsObjectTypeSkip(self: *Parser) !NodeId {
        const open = self.eat();
        var depth: u32 = 1;
        while (depth > 0 and !self.check(.eof)) {
            if (self.check(.lbrace)) depth += 1;
            if (self.check(.rbrace)) depth -= 1;
            _ = self.eat();
        }
        return self.arena.push(.{ .ts_keyword = .{ .keyword = .object, .span = open.span } });
    }

    fn parseTsInterface(self: *Parser) !NodeId {
        const kw = self.eat();
        const id = try self.parseIdent();
        const type_params: []ast.TsTypeParam = if (self.check(.lt)) try self.parseTsTypeParams() else &.{};
        var extends: []NodeId = &.{};
        if (self.eatIf(.kw_extends) != null) extends = try self.parseTsTypeList();
        _ = try self.parseTsObjectTypeSkip();
        return self.arena.push(.{ .ts_interface = .{ .id = id, .extends = extends, .body = &.{}, .type_params = type_params, .span = kw.span } });
    }

    fn parseTsTypeAlias(self: *Parser) !NodeId {
        const kw = self.eat();
        return self.parseTsTypeAliasAfterTypeKeywordWithSpan(kw.span);
    }

    fn parseTsTypeAliasAfterTypeKeyword(self: *Parser) !NodeId {
        return self.parseTsTypeAliasAfterTypeKeywordWithSpan(self.cur().span);
    }

    fn parseTsTypeAliasAfterTypeKeywordWithSpan(self: *Parser, span: tok.Span) !NodeId {
        const id = try self.parseIdent();
        try self.declareIdentifierNode(id, .type_alias);
        const type_params: []ast.TsTypeParam = if (self.check(.lt)) try self.parseTsTypeParams() else &.{};
        _ = try self.expect(.eq);
        const type_ann = try self.parseTsType();
        _ = self.eatIf(.semicolon);
        return self.arena.push(.{ .ts_type_alias = .{ .id = id, .type_params = type_params, .type_ann = type_ann, .span = span } });
    }

    fn parseTsEnum(self: *Parser) !NodeId {
        const is_const = self.eatIf(.kw_const) != null;
        const kw = try self.expect(.kw_enum);
        const id = try self.parseIdent();
        try self.declareIdentifierNode(id, .enum_decl);
        _ = try self.expect(.lbrace);
        var members = std.ArrayListUnmanaged(ast.TsEnumMember).empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            const mid = try self.parseIdent();
            const init_val: ?NodeId = if (self.eatIf(.eq) != null) try self.parseAssignExpr() else null;
            try members.append(self.alloc, .{ .id = mid, .init = init_val, .span = self.arena.get(mid).span() });

            if (self.eatIf(.comma) != null) continue;
            if (self.check(.rbrace)) break;

            try self.emitError(self.cur(), "expected ',' between enum members");
            return error.ParseError;
        }
        _ = try self.expect(.rbrace);
        return self.arena.push(.{ .ts_enum = .{ .id = id, .members = try members.toOwnedSlice(self.alloc), .is_const = is_const, .span = kw.span } });
    }

    fn parseTsDeclare(self: *Parser) !NodeId {
        const kw = self.eat();
        if (self.check(.ident) and std.mem.eql(u8, self.cur().raw, "global") and self.peek2Kind() == .lbrace) {
            _ = self.eat();
            var depth: u32 = 1;
            _ = self.eat();
            while (depth > 0 and !self.check(.eof)) {
                if (self.check(.lbrace)) depth += 1;
                if (self.check(.rbrace)) {
                    depth -= 1;
                    if (depth == 0) break;
                }
                _ = self.eat();
            }
            _ = try self.expect(.rbrace);
            return self.arena.push(.{ .empty_stmt = .{ .span = kw.span } });
        }
        if (self.check(.kw_namespace) or (self.check(.kw_module) and self.peek2Kind() == .ident)) {
            try self.parseTsAmbientNamespaceLike();
            return self.arena.push(.{ .empty_stmt = .{ .span = kw.span } });
        }
        if (self.check(.kw_module) and self.peek2Kind() == .string) {
            try self.parseTsAmbientExternalModule();
            return self.arena.push(.{ .empty_stmt = .{ .span = kw.span } });
        }
        if (self.check(.kw_var) or self.check(.kw_let) or self.check(.kw_const)) {
            try self.parseTsAmbientVarDecl();
            return self.arena.push(.{ .empty_stmt = .{ .span = kw.span } });
        }
        _ = try self.parseStatement();
        return self.arena.push(.{ .empty_stmt = .{ .span = kw.span } });
    }

    fn parseTsAmbientVarDecl(self: *Parser) !void {
        _ = self.eat(); // var | let | const
        while (!self.check(.semicolon) and !self.check(.eof)) {
            _ = try self.parseBindingPattern();
            if (self.eatIf(.bang) != null) {}
            if (self.check(.colon)) {
                _ = self.eat();
                _ = try self.parseTsType();
            }
            if (self.eatIf(.eq) != null) {
                _ = try self.parseAssignExpr();
            }
            if (self.eatIf(.comma) == null) break;
        }
        _ = self.eatIf(.semicolon);
    }

    fn parseTsAmbientNamespaceLike(self: *Parser) !void {
        _ = self.eat();
        _ = try self.parseIdent();
        if (self.eatIf(.semicolon) != null) return;
        _ = try self.expect(.lbrace);
        var depth: u32 = 1;
        while (depth > 0 and !self.check(.eof)) {
            if (self.check(.lbrace)) depth += 1;
            if (self.check(.rbrace)) {
                depth -= 1;
                if (depth == 0) break;
            }
            _ = self.eat();
        }
        _ = try self.expect(.rbrace);
    }

    fn parseTsAmbientExternalModule(self: *Parser) !void {
        _ = try self.expect(.kw_module);
        _ = try self.parseStrLit();
        if (self.eatIf(.semicolon) != null) return;
        _ = try self.expect(.lbrace);
        var depth: u32 = 1;
        while (depth > 0 and !self.check(.eof)) {
            if (self.check(.lbrace)) depth += 1;
            if (self.check(.rbrace)) {
                depth -= 1;
                if (depth == 0) break;
            }
            _ = self.eat();
        }
        _ = try self.expect(.rbrace);
    }

    fn parseTsNamespace(self: *Parser) !NodeId {
        const kw = self.eat();
        const id = try self.parseIdent();
        if (!self.check(.lbrace)) return self.arena.push(.{ .empty_stmt = .{ .span = kw.span } });

        _ = self.eat();
        try self.pushScope();
        defer self.popScope();

        var body = std.ArrayListUnmanaged(NodeId).empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            try body.append(self.alloc, try self.parseModuleItem());
        }
        _ = try self.expect(.rbrace);
        return self.arena.push(.{ .ts_namespace = .{ .id = id, .body = try body.toOwnedSlice(self.alloc), .span = kw.span } });
    }

    fn parseJsxElement(self: *Parser) anyerror!NodeId {
        const prev_mode = self.lexer.mode;
        self.lexer.mode = .jsx;
        defer self.lexer.mode = prev_mode;

        const lt = self.eat();
        if (self.check(.gt)) {
            _ = self.eat();
            return self.parseJsxFragment(lt.span);
        }
        const name = try self.parseJsxName();
        if (self.opts.typescript and self.check(.lt)) {
            // TSX permits type arguments on component tags: <Component<T> />.
            // They are type-only and are stripped by the JSX transform/codegen.
            try self.skipTypeArgs();
        }
        var attrs = std.ArrayListUnmanaged(ast.JsxAttr).empty;
        while (!self.check(.gt) and !self.check(.slash) and !self.check(.eof)) {
            // JSX spread attributes are written as `{...expr}`.  Attribute-list
            // position is still in JSX lexer mode, but the spread target itself
            // is a normal JS/TS assignment expression.  Previously the parser
            // tried to parse the leading `...` as a primary expression, which
            // is what made `<Button {...props} />` fail inside parsePrimary.
            if (self.check(.lbrace)) {
                _ = self.eat();
                if (self.eatIf(.dotdotdot) != null) {
                    const expr_mode = self.lexer.mode;
                    self.lexer.mode = .normal;
                    const expr = try self.parseAssignExpr();
                    self.lexer.mode = expr_mode;
                    _ = try self.expect(.rbrace);
                    try attrs.append(self.alloc, .{ .spread = expr });
                } else {
                    try self.emitError(self.cur(), "expected JSX spread attribute");
                    return error.ParseError;
                }
            } else {
                const attr_name = try self.parseJsxName();
                const value: ?NodeId = if (self.eatIf(.eq) != null) try self.parseJsxAttrValue() else null;
                try attrs.append(self.alloc, .{ .named = .{ .name = attr_name, .value = value, .span = self.arena.get(attr_name).span() } });
            }
        }
        if (self.eatIf(.slash) != null) {
            _ = try self.expect(.gt);
            return self.arena.push(.{ .jsx_element = .{
                .opening = .{ .name = name, .attrs = try attrs.toOwnedSlice(self.alloc), .self_closing = true, .span = lt.span },
                .children = &.{},
                .closing = null,
                .span = lt.span,
            } });
        }
        _ = try self.expect(.gt);
        const children = try self.parseJsxChildren();
        _ = try self.expect(.lt);
        _ = try self.expect(.slash);
        const close_name = try self.parseJsxName();
        _ = try self.expect(.gt);
        return self.arena.push(.{ .jsx_element = .{
            .opening = .{ .name = name, .attrs = try attrs.toOwnedSlice(self.alloc), .self_closing = false, .span = lt.span },
            .children = children,
            .closing = .{ .name = close_name, .span = lt.span },
            .span = lt.span,
        } });
    }

    fn parseJsxFragment(self: *Parser, open_span: tok.Span) !NodeId {
        const children = try self.parseJsxChildren();
        _ = try self.expect(.lt);
        _ = try self.expect(.slash);
        _ = try self.expect(.gt);
        return self.arena.push(.{ .jsx_fragment = .{ .children = children, .span = open_span } });
    }

    fn parseJsxChildren(self: *Parser) anyerror![]NodeId {
        var children = std.ArrayListUnmanaged(NodeId).empty;
        while (true) {
            const pre_check_pos = self.lexer.pos;
            if (self.check(.lt) and self.peek2Kind() == .slash) break;
            if (self.check(.eof)) break;
            if (self.check(.lbrace)) {
                _ = self.eat();
                const expr_mode = self.lexer.mode;
                self.lexer.mode = .normal;
                const expr: ?NodeId = if (self.check(.rbrace)) null else try self.parseExpr();
                self.lexer.mode = expr_mode;
                _ = try self.expect(.rbrace);
                const sp = if (expr) |e| self.arena.get(e).span() else self.cur().span;
                try children.append(self.alloc, try self.arena.push(.{ .jsx_expr_container = .{ .expr = expr, .span = sp } }));
            } else if (self.check(.lt)) {
                try children.append(self.alloc, try self.parseJsxElement());
            } else {
                while (!self.check(.lt) and !self.check(.lbrace) and !self.check(.eof)) {
                    _ = self.eat();
                }
                const text_end: u32 = if (self.check(.eof)) @intCast(self.src.len) else self.cur().span.start;
                if (text_end > pre_check_pos) {
                    try children.append(self.alloc, try self.arena.push(.{ .jsx_text = .{ .raw = self.src[pre_check_pos..text_end], .span = .{ .start = @intCast(pre_check_pos), .end = text_end, .line = 0, .col = 0 } } }));
                }
            }
        }
        return children.toOwnedSlice(self.alloc);
    }

    fn isJsxNamePart(kind: TokenKind) bool {
        return switch (kind) {
            .ident,
            .kw_var,
            .kw_let,
            .kw_const,
            .kw_function,
            .kw_return,
            .kw_if,
            .kw_else,
            .kw_for,
            .kw_while,
            .kw_do,
            .kw_break,
            .kw_continue,
            .kw_switch,
            .kw_case,
            .kw_default,
            .kw_throw,
            .kw_try,
            .kw_catch,
            .kw_finally,
            .kw_new,
            .kw_delete,
            .kw_typeof,
            .kw_instanceof,
            .kw_void,
            .kw_in,
            .kw_of,
            .kw_class,
            .kw_extends,
            .kw_super,
            .kw_this,
            .kw_import,
            .kw_export,
            .kw_from,
            .kw_as,
            .kw_async,
            .kw_await,
            .kw_yield,
            .kw_static,
            .kw_get,
            .kw_set,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_with,
            .kw_debugger,
            .kw_type,
            .kw_interface,
            .kw_namespace,
            .kw_declare,
            .kw_abstract,
            .kw_override,
            .kw_implements,
            .kw_readonly,
            .kw_satisfies,
            .kw_keyof,
            .kw_infer,
            .kw_never,
            .kw_unknown,
            .kw_is,
            .kw_enum,
            .kw_module,
            .kw_using,
            .kw_accessor,
            => true,
            else => false,
        };
    }

    fn parseJsxName(self: *Parser) !NodeId {
        const first = self.cur();
        if (!isJsxNamePart(first.kind)) {
            try self.emitError(first, "expected JSX name");
            return error.ParseError;
        }

        var last = self.eat();

        // JSX names can be simple, member, namespace, or hyphenated names:
        //   <Box />, <Layout.Header />, <svg:path />, <div data-id />.
        // The normal JS lexer tokenizes punctuation separately, so consume the
        // separator plus the next JSX name part while in JSX name position and
        // preserve the original raw source slice.
        while (true) {
            if ((self.check(.minus) or self.check(.colon)) and isJsxNamePart(self.peek2Kind())) {
                _ = self.eat();
                last = self.eat();
                continue;
            }

            if (self.check(.dot) and isJsxNamePart(self.peek2Kind())) {
                _ = self.eat();
                last = self.eat();
                continue;
            }

            break;
        }

        const raw = self.src[first.span.start..last.span.end];
        return self.arena.push(.{ .jsx_name = .{ .name = raw, .span = .{
            .start = first.span.start,
            .end = last.span.end,
            .line = first.span.line,
            .col = first.span.col,
        } } });
    }

    fn parseJsxAttrValue(self: *Parser) !NodeId {
        if (self.check(.lbrace)) {
            _ = self.eat();
            const expr_mode = self.lexer.mode;
            self.lexer.mode = .normal;
            const expr: ?NodeId = if (self.check(.rbrace)) null else try self.parseAssignExpr();
            self.lexer.mode = expr_mode;
            const closing = try self.expect(.rbrace);
            const span = if (expr) |e| self.arena.get(e).span() else closing.span;
            return self.arena.push(.{ .jsx_expr_container = .{ .expr = expr, .span = span } });
        }
        return self.parseStrLit();
    }

    fn parseFor(self: *Parser) !NodeId {
        const kw = self.eat();
        const is_await = self.eatIf(.kw_await) != null;
        _ = try self.expect(.lparen);
        var init_val: ?NodeId = null;
        if (!self.check(.semicolon)) {
            if (self.check(.kw_var) or self.check(.kw_let) or self.check(.kw_const) or self.check(.kw_using)) {
                init_val = try self.parseVarDeclNoSemi();
            } else if (self.opts.typescript and self.check(.kw_await) and self.peek2Kind() == .kw_using) {
                _ = self.eat(); // eat 'await'
                init_val = try self.parseVarDeclInner(false, true);
            } else {
                init_val = try self.parseExpr();
            }
        }
        if (init_val != null) {
            const t = self.cur();
            if (t.kind == .kw_in or t.kind == .kw_of) {
                if (isUsingForInit(self.arena, init_val.?) and t.kind != .kw_of) {
                    try self.emitError(t, "using declarations in for loops are only supported with for...of; use 'for (using name of iterable)' or replace 'using' with 'let'/'const' for a traditional for loop");
                    return error.ParseError;
                }
                const kind: ast.ForKind = if (t.kind == .kw_in) .in else .of;
                _ = self.eat();
                const right = try self.parseExpr();
                _ = try self.expect(.rparen);
                try self.validateForInOfInitializer(init_val.?);
                try self.validateRequiredInitializers(init_val.?, true);
                self.enterLoop();
                defer self.leaveLoop();
                const body = try self.parseStatement();
                return self.arena.push(.{ .for_stmt = .{ .kind = kind, .is_await = is_await, .init = init_val, .cond = null, .update = right, .body = body, .span = kw.span } });
            }

            if (isUsingForInit(self.arena, init_val.?)) {
                try self.emitError(t, "using declarations in for loops are only supported with for...of; use 'for (using name of iterable)' or replace 'using' with 'let'/'const' for a traditional for loop");
                return error.ParseError;
            }
        }
        if (init_val) |init_node| try self.validateRequiredInitializers(init_node, false);
        _ = try self.expect(.semicolon);
        const test_expr: ?NodeId = if (!self.check(.semicolon)) try self.parseExpr() else null;
        _ = try self.expect(.semicolon);
        const update: ?NodeId = if (!self.check(.rparen)) try self.parseExpr() else null;
        _ = try self.expect(.rparen);
        self.enterLoop();
        defer self.leaveLoop();
        const body = try self.parseStatement();
        return self.arena.push(.{ .for_stmt = .{ .kind = .plain, .init = init_val, .cond = test_expr, .update = update, .body = body, .span = kw.span } });
    }

    fn isUsingForInit(arena: *ast.Arena, init_id: NodeId) bool {
        return switch (arena.get(init_id).*) {
            .var_decl => |v| v.kind == .using,
            else => false,
        };
    }

    fn parseWhile(self: *Parser) !NodeId {
        const kw = self.eat();
        _ = try self.expect(.lparen);
        const test_expr = try self.parseExpr();
        _ = try self.expect(.rparen);
        self.enterLoop();
        defer self.leaveLoop();
        const body = try self.parseStatement();
        return self.arena.push(.{ .while_stmt = .{ .cond = test_expr, .body = body, .is_do = false, .span = kw.span } });
    }

    fn parseDoWhile(self: *Parser) !NodeId {
        const kw = self.eat();
        self.enterLoop();
        defer self.leaveLoop();
        const body = try self.parseStatement();
        _ = try self.expect(.kw_while);
        _ = try self.expect(.lparen);
        const test_expr = try self.parseExpr();
        _ = try self.expect(.rparen);
        _ = self.eatIf(.semicolon);
        return self.arena.push(.{ .while_stmt = .{ .cond = test_expr, .body = body, .is_do = true, .span = kw.span } });
    }

    fn parseSwitch(self: *Parser) !NodeId {
        const kw = self.eat();
        _ = try self.expect(.lparen);
        const disc = try self.parseExpr();
        _ = try self.expect(.rparen);
        _ = try self.expect(.lbrace);
        self.enterSwitch();
        defer self.leaveSwitch();
        var cases = std.ArrayListUnmanaged(ast.SwitchCase).empty;
        while (!self.check(.rbrace) and !self.check(.eof)) {
            const case_sp = self.cur().span;
            const test_expr: ?NodeId = if (self.eatIf(.kw_case) != null) blk: {
                const e = try self.parseExpr();
                _ = try self.expect(.colon);
                break :blk e;
            } else blk: {
                _ = try self.expect(.kw_default);
                _ = try self.expect(.colon);
                break :blk null;
            };
            var body = std.ArrayListUnmanaged(NodeId).empty;
            while (!self.check(.kw_case) and !self.check(.kw_default) and !self.check(.rbrace) and !self.check(.eof)) {
                try body.append(self.alloc, try self.parseStatement());
            }
            try cases.append(self.alloc, .{ .cond = test_expr, .body = try body.toOwnedSlice(self.alloc), .span = case_sp });
        }
        _ = try self.expect(.rbrace);
        return self.arena.push(.{ .switch_stmt = .{ .disc = disc, .cases = try cases.toOwnedSlice(self.alloc), .span = kw.span } });
    }

    fn parseTry(self: *Parser) !NodeId {
        const kw = self.eat();
        const block = try self.parseBlock();
        const handler: ?ast.CatchClause = if (self.eatIf(.kw_catch) != null) blk: {
            const param: ?NodeId = if (self.eatIf(.lparen) != null) p: {
                const p = try self.parseBindingPattern();
                if (self.opts.typescript and self.check(.colon)) {
                    _ = self.eat();
                    _ = try self.parseTsType();
                }
                _ = try self.expect(.rparen);
                break :p p;
            } else null;
            break :blk .{ .param = param, .body = try self.parseBlock(), .span = kw.span };
        } else null;
        const finalizer: ?NodeId = if (self.eatIf(.kw_finally) != null) try self.parseBlock() else null;
        return self.arena.push(.{ .try_stmt = .{ .block = block, .handler = handler, .finalizer = finalizer, .span = kw.span } });
    }

    fn parseThrow(self: *Parser) !NodeId {
        const kw = self.eat();
        if (self.hasLineTerminatorAfter(kw)) {
            try self.emitError(kw, "throw statement cannot have a line terminator before its argument");
            return error.ParseError;
        }
        const arg = try self.parseExpr();
        _ = self.eatIf(.semicolon);
        return self.arena.push(.{ .throw_stmt = .{ .argument = arg, .span = kw.span } });
    }

    fn parseLabeledStmt(self: *Parser) !NodeId {
        const label = try self.parseIdent();
        const span = self.arena.get(label).span();
        _ = try self.expect(.colon);
        const label_is_loop = self.nextStatementIsLoop();
        try self.pushLabel(label, label_is_loop);
        defer self.popLabel();
        const body = try self.parseStatement();
        return self.arena.push(.{ .labeled_stmt = .{ .label = label, .body = body, .span = span } });
    }

    fn parseBreakContinue(self: *Parser, is_break: bool) !NodeId {
        const kw = self.eat();
        const label: ?NodeId = if (!self.hasLineTerminatorAfter(kw) and self.check(.ident))
            try self.parseIdent()
        else
            null;

        if (label) |label_node| {
            const ident = self.arena.get(label_node).ident;
            const target = self.findLabel(ident.name) orelse {
                try self.emitErrorAtSpan(ident.span, "label is not defined");
                return error.ParseError;
            };
            if (!is_break and !target.is_loop) {
                try self.emitErrorAtSpan(ident.span, "continue label must reference an enclosing loop");
                return error.ParseError;
            }
        } else if (is_break) {
            if (self.loop_depth == 0 and self.switch_depth == 0) {
                try self.emitError(kw, "break statement is only valid inside a loop or switch");
                return error.ParseError;
            }
        } else if (self.loop_depth == 0) {
            try self.emitError(kw, "continue statement is only valid inside a loop");
            return error.ParseError;
        }

        _ = self.eatIf(.semicolon);
        return self.arena.push(.{ .break_continue = .{ .is_break = is_break, .label = label, .span = kw.span } });
    }

    fn parseDebugger(self: *Parser) !NodeId {
        const kw = self.eat();
        _ = self.eatIf(.semicolon);
        return self.arena.push(.{ .debugger_stmt = .{ .span = kw.span } });
    }

    fn hasLineTerminatorAfter(self: *Parser, prev: Token) bool {
        return self.cur().span.line > prev.span.line;
    }

    fn checkDepth(self: *Parser) !void {
        self.parse_depth += 1;
        if (self.parse_depth > self.opts.max_depth) {
            try self.emitErrorAtSpan(self.cur().span, "parser recursion depth exceeded");
            return error.ParseError;
        }
    }

    pub fn getCurrentDepth(self: *const Parser) u32 {
        return self.parse_depth;
    }
};
