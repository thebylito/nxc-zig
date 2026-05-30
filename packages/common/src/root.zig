const std = @import("std");

pub const Severity = enum { off, err, warn, info };

pub const SourcePosition = struct {
    index: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
};

pub const SourceRange = struct {
    start: SourcePosition,
    end: SourcePosition,
};

pub const Diagnostic = struct {
    message: []const u8,
    severity: Severity,
    filename: []const u8,
    range: SourceRange,
    rule_code: []const u8,
};

pub const LintEnvironment = struct {
    node: bool = false,
    deno: bool = false,
    bun: bool = false,
};

pub const LintContext = struct {
    source: []const u8,
    filename: []const u8,
    env: LintEnvironment = .{},
    alloc: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(Diagnostic),
    fixes: *std.ArrayListUnmanaged(LintFix) = undefined,
    ast_arena: ?*const anyopaque = null,
    ast_program_id: ?u32 = null,

    pub fn report(self: LintContext, rule_code: []const u8, severity: Severity, message: []const u8, start: usize, end: usize) !void {
        try self.diagnostics.append(self.alloc, .{
            .message = try self.alloc.dupe(u8, message),
            .severity = severity,
            .filename = try self.alloc.dupe(u8, self.filename),
            .range = sourceRange(self.source, start, end),
            .rule_code = try self.alloc.dupe(u8, rule_code),
        });
    }
};

pub const LintFix = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

pub const LintRule = struct {
    code: []const u8,
    severity: Severity = .warn,
    run: *const fn (LintContext, LintRule) anyerror!void,
    fix: ?*const fn (LintContext, LintRule) anyerror!void = null,
    options: ?RuleOptions = null,
};

pub const RuleOptions = union(enum) {
    bool_val: bool,
    string_val: []const u8,
    int_val: i64,
};

pub const QuoteStyle = enum { single, double };
pub const Semicolons = enum { preserve, always, never };
pub const TrailingComma = enum { none, es5, all };
pub const QuoteProps = enum { as_needed, consistent, preserve };
pub const ProseWrap = enum { always, never, preserve };
pub const ObjectWrap = enum { preserve, collapse };
pub const ArrowParens = enum { always, avoid };
pub const EndOfLine = enum { lf, crlf, cr, auto };
pub const OperatorPosition = enum { start, end };
pub const TernaryStyle = enum { classic, linear };
pub const EmbeddedLanguageFormatting = enum { auto, off };

pub const FormatterOptions = struct {
    singleQuote: bool = false,
    trailingComma: TrailingComma = .all,
    bracketSpacing: bool = true,
    semi: bool = true,
    printWidth: usize = 80,
    quoteProps: QuoteProps = .as_needed,
    proseWrap: ProseWrap = .preserve,
    objectWrap: ObjectWrap = .preserve,
    arrowParens: ArrowParens = .always,
    bracketSameLine: bool = false,
    endOfLine: EndOfLine = .lf,
    singleAttributePerLine: bool = false,
    jsxSingleQuote: bool = false,
    operatorPosition: OperatorPosition = .end,
    ternaryStyle: TernaryStyle = .classic,
    embeddedLanguageFormatting: EmbeddedLanguageFormatting = .auto,
    rangeStart: usize = 0,
    rangeEnd: usize = std.math.maxInt(usize),
    useTabs: bool = false,
    tabWidth: usize = 2,
    requirePragma: bool = false,
    insertPragma: bool = false,
    checkIgnorePragma: bool = false,
    plugins: []const Plugin = &.{},
};

pub const Plugin = struct {
    name: []const u8,
    version: []const u8 = "",
    lint_rules: []const LintRule = &.{},
    format: ?*const fn ([]const u8, FormatterOptions, std.mem.Allocator) anyerror!?[]u8 = null,
    setup_linter: ?*const fn (registry: *anyopaque, alloc: std.mem.Allocator) anyerror!void = null,
};

pub fn readFileAlloc(path: []const u8, io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => error.FileTooLarge,
        else => err,
    };
}

pub fn normalizePathSeparators(path: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const out = try alloc.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

pub fn sourcePosition(source: []const u8, index: usize) SourcePosition {
    var pos = SourcePosition{};
    const end = @min(index, source.len);
    for (source[0..end], 0..) |c, i| {
        pos.index = i + 1;
        if (c == '\n') {
            pos.line += 1;
            pos.column = 1;
        } else {
            pos.column += 1;
        }
    }
    pos.index = end;
    return pos;
}

pub fn sourceRange(source: []const u8, start: usize, end: usize) SourceRange {
    const start_clamped = @min(start, source.len);
    const end_clamped = @min(end, source.len);
    if (start_clamped > end_clamped) {
        return .{
            .start = sourcePosition(source, start),
            .end = sourcePosition(source, end),
        };
    }

    // Single forward scan: walk to `start`, capture it, then continue to `end`
    // instead of rescanning the [0..start] prefix twice.
    var line: u32 = 1;
    var column: u32 = 1;
    for (source[0..start_clamped]) |c| {
        if (c == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    const start_pos = SourcePosition{ .index = start_clamped, .line = line, .column = column };
    for (source[start_clamped..end_clamped]) |c| {
        if (c == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{
        .start = start_pos,
        .end = .{ .index = end_clamped, .line = line, .column = column },
    };
}

pub fn cloneDiagnostic(alloc: std.mem.Allocator, diag: Diagnostic) !Diagnostic {
    return .{
        .message = try alloc.dupe(u8, diag.message),
        .severity = diag.severity,
        .filename = try alloc.dupe(u8, diag.filename),
        .range = diag.range,
        .rule_code = try alloc.dupe(u8, diag.rule_code),
    };
}

pub fn freeDiagnostic(alloc: std.mem.Allocator, diag: Diagnostic) void {
    alloc.free(diag.message);
    alloc.free(diag.filename);
    alloc.free(diag.rule_code);
}

pub fn freeDiagnostics(alloc: std.mem.Allocator, diagnostics: []Diagnostic) void {
    for (diagnostics) |diag| freeDiagnostic(alloc, diag);
    alloc.free(diagnostics);
}

pub fn logError(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("error: " ++ fmt ++ "\n", args);
}

pub fn loadConfig(path: []const u8, io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    return readFileAlloc(path, io, alloc);
}
