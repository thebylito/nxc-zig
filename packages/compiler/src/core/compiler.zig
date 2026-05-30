const std = @import("std");

const parser = @import("parser");
const ast = @import("ast");
const pipeline = @import("pipeline");
const class_names = @import("class_names");
const jsx = @import("jsx");
const modules = @import("modules");
const codegen = @import("codegen");
const diagnostics = @import("diagnostics");
const declarations = @import("declarations");

const Diagnostic = diagnostics.Diagnostic;
const DiagnosticList = diagnostics.DiagnosticList;

pub const Config = @import("config").Config;
pub const PathAlias = @import("config").PathAlias;
pub const config = @import("config");

pub const CompileResult = struct {
    code: []const u8,
    map: ?[]const u8,
    declarations: ?[]const u8,
    diagnostics: []const Diagnostic,

    pub fn deinit(self: CompileResult, alloc: std.mem.Allocator) void {
        alloc.free(self.code);
        if (self.map) |m| alloc.free(m);
        if (self.declarations) |d| alloc.free(d);
        for (self.diagnostics) |d| {
            alloc.free(d.message);
            alloc.free(d.filename);
            if (d.source_line) |line| alloc.free(line);
        }
        alloc.free(self.diagnostics);
    }
};

/// Writes every artifact produced by compile/compileFile.
///
/// `js_path` is the final JavaScript output path, for example:
///   dist/index.js
///
/// When result.declarations is non-null, this also writes:
///   dist/index.d.ts
///
/// When result.map is non-null, this also writes:
///   dist/index.js.map
pub fn writeCompileResultFiles(
    alloc: std.mem.Allocator,
    js_path: []const u8,
    result: CompileResult,
) !void {
    try writeFileCreatingParents(js_path, result.code);

    if (result.map) |map| {
        const map_path = try std.fmt.allocPrint(alloc, "{s}.map", .{js_path});
        defer alloc.free(map_path);
        try writeFileCreatingParents(map_path, map);
    }

    if (result.declarations) |dts| {
        const dts_path = try declarationPathFromJsPath(alloc, js_path);
        defer alloc.free(dts_path);
        try writeFileCreatingParents(dts_path, dts);
    }
}

pub fn declarationPathFromJsPath(alloc: std.mem.Allocator, js_path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, js_path, ".js")) {
        return std.fmt.allocPrint(alloc, "{s}.d.ts", .{js_path[0 .. js_path.len - 3]});
    }
    if (std.mem.endsWith(u8, js_path, ".mjs")) {
        return std.fmt.allocPrint(alloc, "{s}.d.mts", .{js_path[0 .. js_path.len - 4]});
    }
    if (std.mem.endsWith(u8, js_path, ".cjs")) {
        return std.fmt.allocPrint(alloc, "{s}.d.cts", .{js_path[0 .. js_path.len - 4]});
    }
    return std.fmt.allocPrint(alloc, "{s}.d.ts", .{js_path});
}

fn writeFileCreatingParents(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
}

pub fn compileFile(
    path: []const u8,
    cfg: Config,
    io: std.Io,
    alloc: std.mem.Allocator,
) !CompileResult {
    const source = try readSourceFile(path, io, alloc);
    defer alloc.free(source);
    return compile(source, path, cfg, io, alloc);
}

pub fn dupeDiags(list: *std.ArrayListUnmanaged(Diagnostic), alloc: std.mem.Allocator) ![]const Diagnostic {
    if (list.items.len == 0) return try alloc.dupe(Diagnostic, &.{});

    var out = try alloc.alloc(Diagnostic, list.items.len);
    errdefer alloc.free(out);

    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |d| {
            alloc.free(d.message);
            alloc.free(d.filename);
            if (d.source_line) |line| alloc.free(line);
        }
    }

    for (list.items, 0..) |d, i| {
        out[i] = .{
            .severity = d.severity,
            .message = try alloc.dupe(u8, d.message),
            .filename = try alloc.dupe(u8, d.filename),
            .line = d.line,
            .col = d.col,
            .source_line = if (d.source_line) |line| try alloc.dupe(u8, line) else null,
            .len = d.len,
        };
        initialized += 1;
    }

    return out;
}

fn readSourceFile(path: []const u8, io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    if (pathIsDir(path, io)) return error.IsDir;

    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => error.FileTooLarge,
        else => err,
    };
}

fn pathIsDir(path: []const u8, io: std.Io) bool {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.kind == .directory;
}

fn validateImportAttributeTarget(
    arena: *const ast.Arena,
    alloc: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    target: config.Target,
    program_id: ast.NodeId,
    diags: *DiagnosticList,
) !void {
    const program = arena.get(program_id).program;
    for (program.body) |stmt_id| {
        try validateImportAttributeTargetNode(arena, alloc, source, filename, target, stmt_id, diags);
    }
}

fn validateImportAttributeTargetNode(
    arena: *const ast.Arena,
    alloc: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    target: config.Target,
    node_id: ast.NodeId,
    diags: *DiagnosticList,
) !void {
    const node = arena.get(node_id).*;
    switch (node) {
        .import_decl => |imp| {
            if (imp.attributes.len > 0) {
                try validateImportAttributeSyntax(alloc, source, filename, target, imp.attribute_syntax, imp.span, diags);
            }
        },
        .export_decl => |exp| switch (exp.kind) {
            .named => |n| {
                if (n.attributes.len > 0) {
                    try validateImportAttributeSyntax(alloc, source, filename, target, n.attribute_syntax, exp.span, diags);
                }
            },
            .all => |a| {
                if (a.attributes.len > 0) {
                    try validateImportAttributeSyntax(alloc, source, filename, target, a.attribute_syntax, exp.span, diags);
                }
            },
            else => {},
        },
        else => {},
    }
}

fn validateImportAttributeSyntax(
    alloc: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    target: config.Target,
    syntax: ast.ImportAttributeSyntax,
    span: ast.Span,
    diags: *DiagnosticList,
) !void {
    const msg: ?[]const u8 = switch (target) {
        .es2020, .es2022 => if (syntax == .with)
            "import attributes with `with` require target es2024 or esnext; use `assert` or raise the target"
        else
            null,
        .es2024, .esnext => if (syntax == .assert)
            "import assertions with `assert` are not supported for target es2024/esnext; use `with`"
        else
            null,
    };

    if (msg) |m| {
        var line_start: usize = 0;
        var line: u32 = 1;
        for (source, 0..) |c, i| {
            if (line == span.line) {
                line_start = i;
                break;
            }
            if (c == '\n') line += 1;
        }
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;

        try diags.add(alloc, .{
            .severity = .err,
            .message = m,
            .filename = filename,
            .line = span.line,
            .col = span.col,
            .source_line = source[line_start..line_end],
            .len = span.len(),
        });
    }
}

fn sourceLineForSpan(source: []const u8, span: ast.Span) ?[]const u8 {
    var line_start: usize = 0;
    var line: u32 = 1;

    for (source, 0..) |c, i| {
        if (line == span.line) {
            line_start = i;
            break;
        }
        if (c == '\n') line += 1;
    }

    if (line != span.line) return null;
    const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
    return source[line_start..line_end];
}

fn addDuplicateIdentifierDiagnostic(
    alloc: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    name: []const u8,
    span: ast.Span,
    diags: *DiagnosticList,
) !void {
    const msg = try std.fmt.allocPrint(alloc, "Duplicate identifier '{s}'", .{name});

    try diags.add(alloc, .{
        .severity = .err,
        .message = msg,
        .filename = filename,
        .line = span.line,
        .col = span.col,
        .source_line = sourceLineForSpan(source, span),
        .len = span.len(),
    });
}

fn validateDuplicateImportBindings(
    arena: *const ast.Arena,
    alloc: std.mem.Allocator,
    source: []const u8,
    filename: []const u8,
    program_id: ast.NodeId,
    diags: *DiagnosticList,
) !void {
    var seen = std.StringHashMap(ast.Span).init(alloc);
    defer seen.deinit();

    const program = arena.get(program_id).program;

    for (program.body) |stmt_id| {
        switch (arena.get(stmt_id).*) {
            .import_decl => |imp| {
                for (imp.specifiers) |spec| {
                    if (spec.is_type_only) continue;

                    const local_node = arena.get(spec.local).*;
                    if (local_node != .ident) continue;

                    const name = local_node.ident.name;
                    const span = local_node.ident.span;

                    if (seen.contains(name)) {
                        try addDuplicateIdentifierDiagnostic(
                            alloc,
                            source,
                            filename,
                            name,
                            span,
                            diags,
                        );
                    } else {
                        try seen.put(name, span);
                    }
                }
            },
            else => {},
        }
    }
}

pub fn compile(
    source: []const u8,
    filename: []const u8,
    cfg: Config,
    io: std.Io,
    alloc: std.mem.Allocator,
) !CompileResult {
    var arena_backing = std.heap.ArenaAllocator.init(alloc);
    defer arena_backing.deinit();
    const a = arena_backing.allocator();

    var diags = DiagnosticList{};
    var node_arena = ast.Arena.init(a);

    const typescript = cfg.parser.syntax == .typescript;

    const parse_opts = parser.ParseOptions{
        .typescript = typescript,
        .jsx = cfg.jsx,
        .source_type = .module,
        .check = cfg.check,
    };

    var p = parser.Parser.init(source, filename, &node_arena, a, &diags, parse_opts);
    const program_id = p.parseProgram() catch |err| {
        if (err == error.ParseError) {
            return CompileResult{
                .code = try alloc.dupe(u8, ""),
                .map = null,
                .declarations = null,
                .diagnostics = try dupeDiags(&diags.items, alloc),
            };
        }
        return err;
    };

    try validateDuplicateImportBindings(&node_arena, a, source, filename, program_id, &diags);
    if (diags.hasErrors()) {
        return CompileResult{
            .code = try alloc.dupe(u8, ""),
            .map = null,
            .declarations = null,
            .diagnostics = try dupeDiags(&diags.items, alloc),
        };
    }

    try validateImportAttributeTarget(&node_arena, a, source, filename, cfg.target, program_id, &diags);
    if (diags.hasErrors()) {
        return CompileResult{
            .code = try alloc.dupe(u8, ""),
            .map = null,
            .declarations = null,
            .diagnostics = try dupeDiags(&diags.items, alloc),
        };
    }

    const declaration_code: ?[]const u8 = if (cfg.declaration and typescript)
        try declarations.generate(&node_arena, alloc, source, program_id)
    else
        null;
    errdefer if (declaration_code) |d| alloc.free(d);

    if (cfg.keep_class_names) {
        try class_names.keepClassNames(&node_arena, a, filename, program_id);
    }

    try pipeline.run(&node_arena, a, io, .{
        .typescript = typescript,
        .jsx = cfg.jsx,
        .jsx_cfg = .{
            .runtime = cfg.transform.react.jsx_runtime,
            .factory = cfg.transform.react.jsx_factory,
            .fragment = cfg.transform.react.jsx_fragment,
            .import_source = cfg.transform.react.jsx_import_source,
        },
        .src_file = filename,
        .module_strict = cfg.module.strict,
        .esmodule_interop = cfg.module.es_module_interop,
        .import_interop = cfg.module.import_interop,
        .decorators = cfg.parser.decorators,
        .legacy_decorator = cfg.transform.legacy_decorator,
        .decorator_metadata = cfg.transform.decorator_metadata,
        .aliases_cfg = .{
            .aliases = cfg.paths,
            .src_file = filename,
        },
        .paths_cfg = .{
            .add_js_extension = cfg.module.resolve_full_paths,
            .src_file = filename,
            .src_dir = std.fs.path.dirname(filename) orelse ".",
            .base_url = cfg.base_url,
        },
        .remove_comments = cfg.remove_comments,
        .target = switch (cfg.target) {
            .es2020 => .es2020,
            .es2022 => .es2022,
            .es2024 => .es2024,
            .esnext => .esnext,
        },
    }, program_id);

    if (cfg.module.strict) {
        try modules.ensureUseStrict(&node_arena, a, program_id);
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const source_root: ?[]const u8 = if (cfg.source_maps) blk: {
        const len = std.process.currentPath(io, &cwd_buf) catch break :blk null;
        break :blk cwd_buf[0..len];
    } else null;

    var cg = try codegen.Codegen.init(&node_arena, a, .{
        .pretty = true,
        .source_map = cfg.source_maps,
        .source_name = filename,
        .source_root = source_root,
        .keep_import_attributes = cfg.keep_import_attributes,
        .import_attribute_syntax = switch (cfg.target) {
            .es2020, .es2022 => .assert,
            .es2024, .esnext => .with,
        },
        .remove_comments = cfg.remove_comments,
        .comments = p.comments.items,
    });
    // Emitted JS is roughly the size of the source; reserve up front to avoid
    // repeated reallocations as the output buffer grows.
    try cg.buf.ensureTotalCapacity(a, source.len + source.len / 2);
    try cg.gen(program_id);
    const code = try cg.finish();
    const map = try cg.finishSourceMap();

    return CompileResult{
        .code = try alloc.dupe(u8, code),
        .map = if (map) |m| try alloc.dupe(u8, m) else null,
        .declarations = declaration_code,
        .diagnostics = try dupeDiags(&diags.items, alloc),
    };
}
