const std = @import("std");
const common = @import("common");
const ast_formatter = @import("ast_formatter.zig");

pub const QuoteStyle = common.QuoteStyle;
pub const Semicolons = common.Semicolons;
pub const TrailingComma = common.TrailingComma;
pub const QuoteProps = common.QuoteProps;
pub const ProseWrap = common.ProseWrap;
pub const ObjectWrap = common.ObjectWrap;
pub const ArrowParens = common.ArrowParens;
pub const EndOfLine = common.EndOfLine;

pub const FormatResult = struct {
    output: []u8,
    from_ast: bool,
    warnings: []const []const u8,
};

fn hasPragma(source: []const u8, comptime markers: []const []const u8) bool {
    var i: usize = 0;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) i += 1;
    if (i + 1 < source.len and source[i] == '#' and source[i + 1] == '!') {
        while (i < source.len and source[i] != '\n') i += 1;
        if (i < source.len) i += 1;
    }
    while (i + 1 < source.len) {
        if (source[i] == '/' and source[i + 1] == '*') {
            const end = std.mem.indexOf(u8, source[i..], "*/") orelse return false;
            const comment = source[i .. i + end + 2];
            for (markers) |m| {
                if (std.mem.indexOf(u8, comment, m) != null) return true;
            }
            return false;
        }
        if (source[i] == '/' and source[i + 1] == '/') {
            const end = std.mem.indexOfScalar(u8, source[i..], '\n') orelse source.len;
            const comment = source[i .. i + end];
            for (markers) |m| {
                if (std.mem.indexOf(u8, comment, m) != null) return true;
            }
            return false;
        }
        if (source[i] != ' ' and source[i] != '\t' and source[i] != '\n' and source[i] != '\r') return false;
        i += 1;
    }
    return false;
}

fn insertPragmaMarker(source: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var i: usize = 0;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t' or source[i] == '\n' or source[i] == '\r')) i += 1;
    if (i + 1 < source.len and source[i] == '#' and source[i + 1] == '!') {
        while (i < source.len and source[i] != '\n') i += 1;
        if (i < source.len) i += 1;
    }
    var result = std.ArrayListUnmanaged(u8).empty;
    errdefer result.deinit(alloc);
    try result.appendSlice(alloc, source[0..i]);
    try result.appendSlice(alloc, "/** @format */\n");
    try result.appendSlice(alloc, source[i..]);
    return result.toOwnedSlice(alloc);
}

pub fn format(source: []const u8, options: common.FormatterOptions, alloc: std.mem.Allocator) ![]u8 {
    if (options.checkIgnorePragma and hasPragma(source, &.{ "@noprettier", "@noformat" })) {
        return alloc.dupe(u8, source);
    }

    if (options.requirePragma and !hasPragma(source, &.{ "@prettier", "@format" })) {
        return alloc.dupe(u8, source);
    }

    const needs_range = options.rangeStart > 0 or options.rangeEnd < source.len;
    if (needs_range) {
        const rstart = @min(options.rangeStart, source.len);
        const rend = @min(options.rangeEnd, source.len);
        const search_len = @min(rstart + 1, source.len);
        const line_start = if (rstart > 0) (std.mem.lastIndexOfScalar(u8, source[0..search_len], '\n') orelse 0) + 1 else 0;
        const line_end = if (rend < source.len) (std.mem.indexOfScalarPos(u8, source, rend, '\n') orelse source.len) else source.len;
        const prefix = source[0..line_start];
        const mid = source[line_start..line_end];
        const suffix = source[line_end..];
        var range_opts = options;
        range_opts.rangeStart = 0;
        range_opts.rangeEnd = std.math.maxInt(usize);
        const formatted_mid = try format(mid, range_opts, alloc);
        defer alloc.free(formatted_mid);
        return std.mem.concat(alloc, u8, &[_][]const u8{ prefix, formatted_mid, suffix });
    }

    var owned_source: ?[]u8 = null;
    defer if (owned_source) |s| alloc.free(s);

    const effective_source = if (options.insertPragma and !options.requirePragma and !hasPragma(source, &.{ "@prettier", "@format" })) blk: {
        const modified = try insertPragmaMarker(source, alloc);
        owned_source = modified;
        break :blk modified;
    } else source;

    var stripped_source: ?[]u8 = null;
    defer if (stripped_source) |s| alloc.free(s);
    const normalized_source = if (std.mem.indexOfScalar(u8, effective_source, '\r') != null) blk: {
        const stripped = try stripCarriageReturns(effective_source, alloc);
        stripped_source = stripped;
        break :blk stripped;
    } else effective_source;

    for (options.plugins) |plugin| {
        if (plugin.format) |formatPlugin| {
            if (try formatPlugin(normalized_source, options, alloc)) |formatted| {
                return ensureTrailingNewline(alloc, formatted, options.endOfLine);
            }
        }
    }

    const result = blk: {
        if (options.proseWrap != .never) {
            if (ast_formatter.formatAst(normalized_source, options, alloc) catch null) |formatted| {
                break :blk formatted;
            }
        }
        const depths = try computeIndentDepths(normalized_source, alloc);
        defer alloc.free(depths);

        var out = std.ArrayListUnmanaged(u8).empty;
        errdefer out.deinit(alloc);
        // Formatted output is roughly the size of the input; reserve up front.
        try out.ensureTotalCapacity(alloc, normalized_source.len + normalized_source.len / 2);

        var lines = std.mem.splitScalar(u8, normalized_source, '\n');
        var line_idx: usize = 0;
        var first = true;

        var prose_acc = std.ArrayListUnmanaged(u8).empty;
        defer prose_acc.deinit(alloc);
        var prose_depth: usize = 0;
        var pending_prose = false;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            const depth = if (line_idx < depths.len) depths[line_idx] else 0;

            if (options.proseWrap == .never) {
                if (trimmed.len > 0 and !looksLikeCodeStructure(trimmed)) {
                    if (!pending_prose) {
                        prose_depth = depth;
                        prose_acc.clearRetainingCapacity();
                        prose_acc.appendSlice(alloc, trimmed) catch {};
                        pending_prose = true;
                    } else {
                        if (prose_acc.items.len > 0) try prose_acc.append(alloc, ' ');
                        try prose_acc.appendSlice(alloc, trimmed);
                    }
                    line_idx += 1;
                    continue;
                }
                if (pending_prose) {
                    if (!first) try appendEol(&out, options.endOfLine, alloc);
                    first = false;
                    try appendIndent(&out, prose_depth, alloc, options);
                    try out.appendSlice(alloc, prose_acc.items);
                    pending_prose = false;
                }
            }

            if (!first) try appendEol(&out, options.endOfLine, alloc);
            first = false;

            try appendIndent(&out, depth, alloc, options);

            const quoted = try normalizeQuotes(trimmed, resolvedQuoteStyle(options), alloc);
            defer alloc.free(quoted);

            const spaced = try normalizeBracketSpacing(quoted, options.bracketSpacing, alloc);
            defer alloc.free(spaced);

            const processed = normalizeSemicolon(spaced, resolvedSemicolons(options));

            if (options.proseWrap == .always) {
                try appendWrapped(&out, processed, options, depth, alloc);
            } else {
                try out.appendSlice(alloc, processed);
            }

            if (resolvedSemicolons(options) == .always and needsSemicolon(processed) and !std.mem.endsWith(u8, processed, ";")) {
                try out.append(alloc, ';');
            }

            line_idx += 1;
        }

        if (pending_prose) {
            if (!first) try appendEol(&out, options.endOfLine, alloc);
            try appendIndent(&out, prose_depth, alloc, options);
            try out.appendSlice(alloc, prose_acc.items);
        }

        break :blk try out.toOwnedSlice(alloc);
    };

    return result;
}

fn hasTrailingNewline(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s.len > 1 and s[s.len - 2] == '\r' and s[s.len - 1] == '\n') return true;
    if (s[s.len - 1] == '\n' or s[s.len - 1] == '\r') return true;
    return false;
}

fn stripCarriageReturns(source: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    errdefer buf.deinit(alloc);
    for (source) |c| {
        if (c != '\r') try buf.append(alloc, c);
    }
    return buf.toOwnedSlice(alloc);
}

fn ensureTrailingNewline(alloc: std.mem.Allocator, result: []u8, eol: EndOfLine) ![]u8 {
    if (hasTrailingNewline(result)) return result;
    const suffix = switch (eol) {
        .lf, .auto => "\n",
        .crlf => "\r\n",
        .cr => "\r",
    };
    const extended = try alloc.realloc(result, result.len + suffix.len);
    @memcpy(extended[result.len..], suffix);
    return extended;
}

fn computeIndentDepths(source: []const u8, alloc: std.mem.Allocator) ![]usize {
    var depths = std.ArrayListUnmanaged(usize).empty;
    errdefer depths.deinit(alloc);

    var brace_depth: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');

    while (lines.next()) |raw_line| {
        const leading_spaces = countLeadingSpaces(raw_line);
        const existing_depth = if (leading_spaces > 0) leading_spaces / 2 else std.math.maxInt(usize);

        const line = std.mem.trim(u8, raw_line, " \t\r");
        const starts_with_close = line.len > 0 and line[0] == '}';

        var open_count: usize = 0;
        var close_count: usize = 0;
        var in_string: u8 = 0;
        var in_template = false;
        var escape = false;
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            if (escape) {
                escape = false;
                continue;
            }
            if (line[i] == '\\') {
                escape = true;
                continue;
            }
            if (in_string != 0) {
                if (line[i] == in_string) in_string = 0;
                continue;
            }
            if (in_template) {
                if (line[i] == '`') in_template = false;
                continue;
            }
            if (line[i] == '"' or line[i] == '\'') {
                in_string = line[i];
                continue;
            }
            if (line[i] == '`') {
                in_template = true;
                continue;
            }
            if (line[i] == '/' and i + 1 < line.len) {
                if (line[i + 1] == '/') break;
                if (line[i + 1] == '*') {
                    i += 1;
                    while (i + 1 < line.len and !(line[i] == '*' and line[i + 1] == '/')) i += 1;
                    i += 1;
                    continue;
                }
            }
            if (line[i] == '{') open_count += 1;
            if (line[i] == '}') close_count += 1;
        }

        const effective_close = @min(close_count, brace_depth);
        const depth = if (existing_depth != std.math.maxInt(usize))
            existing_depth
        else if (starts_with_close)
            brace_depth - effective_close
        else
            brace_depth;
        try depths.append(alloc, depth);
        brace_depth = brace_depth - effective_close + open_count;
    }

    return depths.toOwnedSlice(alloc);
}

fn countLeadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

fn resolvedQuoteStyle(options: common.FormatterOptions) QuoteStyle {
    return if (options.singleQuote) .single else .double;
}

fn resolvedSemicolons(options: common.FormatterOptions) Semicolons {
    return if (options.semi) .always else .never;
}

fn normalizeBracketSpacing(line: []const u8, enabled: bool, alloc: std.mem.Allocator) ![]u8 {
    if (enabled) return alloc.dupe(u8, line);

    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if ((line[i] == '{' or line[i] == '[') and i + 1 < line.len and line[i + 1] == ' ') {
            try out.append(alloc, line[i]);
            i += 1;
            continue;
        }
        if (line[i] == ' ' and i + 1 < line.len and (line[i + 1] == '}' or line[i + 1] == ']')) continue;
        try out.append(alloc, line[i]);
    }
    return out.toOwnedSlice(alloc);
}

fn normalizeQuotes(line: []const u8, style: QuoteStyle, alloc: std.mem.Allocator) ![]u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] == '\\') {
            try out.append(alloc, '\\');
            i += 1;
            if (i < line.len) {
                try out.append(alloc, line[i]);
                i += 1;
            }
        } else {
            const should_change = switch (style) {
                .single => line[i] == '"',
                .double => line[i] == '\'',
            };
            if (should_change) {
                try out.append(alloc, if (style == .single) '\'' else '"');
            } else {
                try out.append(alloc, line[i]);
            }
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

fn normalizeSemicolon(line: []const u8, semicolons: Semicolons) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    return switch (semicolons) {
        .preserve => trimmed,
        .never => trimTrailingSemicolons(trimmed),
        .always => trimmed,
    };
}

fn trimTrailingSemicolons(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0 and line[end - 1] == ';') end -= 1;
    return line[0..end];
}

fn needsSemicolon(line: []const u8) bool {
    if (line.len == 0) return false;
    if (line[0] == '#') return false;
    const last = line[line.len - 1];
    return last != '{' and last != '}' and last != ';' and last != ',' and last != '`';
}

fn looksLikeCodeStructure(line: []const u8) bool {
    if (line.len == 0) return false;
    const first_word_end = std.mem.indexOfAny(u8, line, " ({[") orelse line.len;
    const first_word = line[0..first_word_end];
    const code_keywords = [_][]const u8{
        "function", "const",  "let",   "var",    "if",    "else",   "for",   "while",
        "do",       "switch", "case",  "return", "throw", "try",    "catch", "import",
        "export",   "class",  "new",   "typeof", "void",  "delete", "break", "continue",
        "debugger", "with",   "yield", "async",  "await",
    };
    for (code_keywords) |kw| {
        if (std.mem.eql(u8, first_word, kw)) return true;
    }
    if (line[0] == '{' or line[0] == '}' or line[0] == '[' or line[0] == ']' or line[0] == '(' or line[0] == ')') return true;
    if (line[0] == '/' and line.len > 1 and (line[1] == '/' or line[1] == '*')) return true;
    if (line[0] == '#') return true;
    return false;
}

fn appendIndent(out: *std.ArrayListUnmanaged(u8), depth: usize, alloc: std.mem.Allocator, options: common.FormatterOptions) !void {
    if (options.useTabs) {
        for (0..depth) |_| try out.append(alloc, '\t');
    } else {
        for (0..(depth * options.tabWidth)) |_| try out.append(alloc, ' ');
    }
}

fn appendWrapped(out: *std.ArrayListUnmanaged(u8), line: []const u8, options: common.FormatterOptions, depth: usize, alloc: std.mem.Allocator) !void {
    const indent_width = if (options.useTabs) depth else depth * options.tabWidth;
    if (indent_width + line.len <= options.printWidth) {
        try out.appendSlice(alloc, line);
        return;
    }
    var start: usize = 0;
    while (start < line.len) {
        const remaining = line.len - start;
        if (start > 0) {
            try appendEol(out, options.endOfLine, alloc);
            try appendIndent(out, depth, alloc, options);
        }
        if (indent_width + remaining <= options.printWidth) {
            try out.appendSlice(alloc, line[start..]);
            return;
        }
        const avail = if (options.printWidth > indent_width) options.printWidth - indent_width else remaining;
        const end = start + avail;
        if (end >= line.len) {
            try out.appendSlice(alloc, line[start..]);
            return;
        }
        const break_pos = std.mem.lastIndexOfScalar(u8, line[start..end], ' ') orelse end;
        if (break_pos <= start or break_pos == end) {
            try out.appendSlice(alloc, line[start..end]);
            start = end;
        } else {
            try out.appendSlice(alloc, line[start .. start + break_pos]);
            start = start + break_pos + 1;
        }
    }
}

fn appendEol(out: *std.ArrayListUnmanaged(u8), eol: EndOfLine, alloc: std.mem.Allocator) !void {
    switch (eol) {
        .lf, .auto => try out.append(alloc, '\n'),
        .crlf => try out.appendSlice(alloc, "\r\n"),
        .cr => try out.append(alloc, '\r'),
    }
}

pub fn buildFmtOptsFromRule(code: []const u8, opt: common.RuleOptions) common.FormatterOptions {
    var opts = common.FormatterOptions{};
    if (std.mem.eql(u8, code, "formatter/quotes")) {
        if (opt == .bool_val) {
            opts.singleQuote = opt.bool_val;
        } else if (opt == .string_val) {
            opts.singleQuote = std.mem.eql(u8, opt.string_val, "single");
        }
    } else if (std.mem.eql(u8, code, "formatter/semi")) {
        if (opt == .bool_val) opts.semi = opt.bool_val;
    } else if (std.mem.eql(u8, code, "formatter/trailing-comma")) {
        if (opt == .string_val) opts.trailingComma = std.meta.stringToEnum(TrailingComma, opt.string_val) orelse .all;
    } else if (std.mem.eql(u8, code, "formatter/bracket-spacing")) {
        if (opt == .bool_val) opts.bracketSpacing = opt.bool_val;
    } else if (std.mem.eql(u8, code, "formatter/use-tabs")) {
        if (opt == .bool_val) opts.useTabs = opt.bool_val;
    } else if (std.mem.eql(u8, code, "formatter/tab-width")) {
        if (opt == .int_val) opts.tabWidth = @intCast(@max(opt.int_val, 0));
    } else if (std.mem.eql(u8, code, "formatter/print-width")) {
        if (opt == .int_val) opts.printWidth = @intCast(@max(opt.int_val, 0));
    } else if (std.mem.eql(u8, code, "formatter/arrow-parens")) {
        if (opt == .string_val) opts.arrowParens = std.meta.stringToEnum(ArrowParens, opt.string_val) orelse .always;
    } else if (std.mem.eql(u8, code, "formatter/end-of-line")) {
        if (opt == .string_val) opts.endOfLine = std.meta.stringToEnum(EndOfLine, opt.string_val) orelse .lf;
    } else if (std.mem.eql(u8, code, "formatter/bracket-same-line")) {
        if (opt == .bool_val) opts.bracketSameLine = opt.bool_val;
    }
    return opts;
}

pub fn fmtRuleMessage(code: []const u8, opts: common.FormatterOptions) []const u8 {
    if (std.mem.eql(u8, code, "formatter/quotes")) {
        return if (opts.singleQuote) "Strings must use single quotes" else "Strings must use double quotes";
    } else if (std.mem.eql(u8, code, "formatter/semi")) {
        return if (opts.semi) "Missing semicolon" else "Unexpected semicolon";
    } else if (std.mem.eql(u8, code, "formatter/trailing-comma")) {
        return "Trailing comma style does not match configuration";
    } else if (std.mem.eql(u8, code, "formatter/bracket-spacing")) {
        return if (opts.bracketSpacing) "Missing space between braces and content" else "Unexpected space between braces and content";
    } else if (std.mem.eql(u8, code, "formatter/use-tabs")) {
        return if (opts.useTabs) "Indentation must use tabs" else "Indentation must use spaces";
    } else if (std.mem.eql(u8, code, "formatter/tab-width")) {
        return "Indentation width does not match configuration";
    } else if (std.mem.eql(u8, code, "formatter/print-width")) {
        return "Line exceeds print width";
    } else if (std.mem.eql(u8, code, "formatter/arrow-parens")) {
        return if (opts.arrowParens == .always) "Arrow function parameters must be wrapped in parentheses" else "Arrow function parameters must omit parentheses";
    } else if (std.mem.eql(u8, code, "formatter/end-of-line")) {
        return "End of line does not match configuration";
    } else if (std.mem.eql(u8, code, "formatter/bracket-same-line")) {
        return if (opts.bracketSameLine) "JSX closing bracket must be on the same line" else "JSX closing bracket must be on a new line";
    }
    return "Formatting does not match configuration";
}

pub const FormatDiagnostic = struct {
    line_start: usize,
    line_end: usize,
    message: []const u8,
};

pub fn checkFormat(source: []const u8, code: []const u8, opt: common.RuleOptions, alloc: std.mem.Allocator) ![]FormatDiagnostic {
    const opts = buildFmtOptsFromRule(code, opt);
    const msg = fmtRuleMessage(code, opts);

    var diags = std.ArrayListUnmanaged(FormatDiagnostic).empty;
    errdefer diags.deinit(alloc);

    if (std.mem.eql(u8, code, "formatter/end-of-line")) {
        try checkEndOfLine(source, opts, msg, &diags, alloc);
        return try diags.toOwnedSlice(alloc);
    }

    if (std.mem.eql(u8, code, "formatter/print-width")) {
        try checkPrintWidth(source, opts, msg, &diags, alloc);
        return try diags.toOwnedSlice(alloc);
    }

    if (std.mem.eql(u8, code, "formatter/use-tabs")) {
        try checkUseTabs(source, opts, msg, &diags, alloc);
        return try diags.toOwnedSlice(alloc);
    }

    if (std.mem.eql(u8, code, "formatter/tab-width")) {
        try checkTabWidth(source, opts, msg, &diags, alloc);
        return try diags.toOwnedSlice(alloc);
    }

    if (std.mem.eql(u8, code, "formatter/quotes")) {
        try checkQuotes(source, opts, msg, &diags, alloc);
        return try diags.toOwnedSlice(alloc);
    }

    if (std.mem.eql(u8, code, "formatter/semi")) {
        try checkSemi(source, opts, msg, &diags, alloc);
        return try diags.toOwnedSlice(alloc);
    }

    if (std.mem.eql(u8, code, "formatter/trailing-comma")) {
        try checkTrailingComma(source, opts, msg, &diags, alloc);
        return try diags.toOwnedSlice(alloc);
    }

    if (std.mem.eql(u8, code, "formatter/bracket-spacing")) {
        try checkBracketSpacing(source, opts, msg, &diags, alloc);
        return try diags.toOwnedSlice(alloc);
    }

    if (std.mem.eql(u8, code, "formatter/arrow-parens")) {
        try checkArrowParens(source, opts, msg, &diags, alloc);
        return try diags.toOwnedSlice(alloc);
    }

    if (std.mem.eql(u8, code, "formatter/bracket-same-line")) {
        try checkBracketSameLine(source, opts, msg, &diags, alloc);
        return try diags.toOwnedSlice(alloc);
    }

    return try diags.toOwnedSlice(alloc);
}

fn checkEndOfLine(source: []const u8, opts: common.FormatterOptions, msg: []const u8, diags: *std.ArrayListUnmanaged(FormatDiagnostic), alloc: std.mem.Allocator) !void {
    const want_crlf = opts.endOfLine == .crlf;
    const want_cr = opts.endOfLine == .cr;
    var i: usize = 0;
    var line_start: usize = 0;
    while (i < source.len) {
        if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') {
            if (!want_crlf) {
                try diags.append(alloc, .{ .line_start = line_start, .line_end = i + 2, .message = msg });
            }
            line_start = i + 2;
            i += 2;
            continue;
        }
        if (source[i] == '\r') {
            if (!want_cr) {
                try diags.append(alloc, .{ .line_start = line_start, .line_end = i + 1, .message = msg });
            }
            line_start = i + 1;
            i += 1;
            continue;
        }
        if (source[i] == '\n') {
            if (want_crlf) {
                try diags.append(alloc, .{ .line_start = line_start, .line_end = i + 1, .message = msg });
            }
            line_start = i + 1;
            i += 1;
            continue;
        }
        i += 1;
    }
}

fn checkPrintWidth(source: []const u8, opts: common.FormatterOptions, msg: []const u8, diags: *std.ArrayListUnmanaged(FormatDiagnostic), alloc: std.mem.Allocator) !void {
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\n' or source[i] == '\r') {
            const line_end = i;
            const line = source[line_start..line_end];
            const display_width = lineVisibleWidth(line, opts.useTabs, opts.tabWidth);
            if (display_width > opts.printWidth) {
                try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
            }
            if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') {
                line_start = i + 2;
                i += 2;
            } else {
                line_start = i + 1;
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    if (line_start < source.len) {
        const line = source[line_start..];
        const display_width = lineVisibleWidth(line, opts.useTabs, opts.tabWidth);
        if (display_width > opts.printWidth) {
            try diags.append(alloc, .{ .line_start = line_start, .line_end = source.len, .message = msg });
        }
    }
}

fn lineVisibleWidth(line: []const u8, use_tabs: bool, tab_width: usize) usize {
    var width: usize = 0;
    var in_indent = true;
    for (line) |c| {
        if (c == '\t') {
            if (in_indent and !use_tabs) {
                width += tab_width;
            } else {
                width += 1;
            }
        } else if (c == ' ') {
            width += 1;
        } else {
            in_indent = false;
            width += 1;
        }
    }
    return width;
}

fn checkUseTabs(source: []const u8, opts: common.FormatterOptions, msg: []const u8, diags: *std.ArrayListUnmanaged(FormatDiagnostic), alloc: std.mem.Allocator) !void {
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\n' or source[i] == '\r') {
            const line = source[line_start..i];
            if (line.len > 0) {
                const has_indent = hasIndentChar(line, opts.useTabs);
                if (has_indent) {
                    try diags.append(alloc, .{ .line_start = line_start, .line_end = i, .message = msg });
                }
            }
            if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') {
                line_start = i + 2;
                i += 2;
            } else {
                line_start = i + 1;
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    if (line_start < source.len) {
        const line = source[line_start..];
        if (line.len > 0) {
            const has_indent = hasIndentChar(line, opts.useTabs);
            if (has_indent) {
                try diags.append(alloc, .{ .line_start = line_start, .line_end = source.len, .message = msg });
            }
        }
    }
}

fn hasIndentChar(line: []const u8, use_tabs: bool) bool {
    var j: usize = 0;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t')) {
        if (use_tabs and line[j] == ' ') return true;
        if (!use_tabs and line[j] == '\t') return true;
        j += 1;
    }
    return false;
}

fn checkTabWidth(source: []const u8, opts: common.FormatterOptions, msg: []const u8, diags: *std.ArrayListUnmanaged(FormatDiagnostic), alloc: std.mem.Allocator) !void {
    if (opts.useTabs) return;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\n' or source[i] == '\r') {
            const line = source[line_start..i];
            if (line.len > 0 and indentWidthMismatch(line, opts.tabWidth)) {
                try diags.append(alloc, .{ .line_start = line_start, .line_end = i, .message = msg });
            }
            if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') {
                line_start = i + 2;
                i += 2;
            } else {
                line_start = i + 1;
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    if (line_start < source.len) {
        const line = source[line_start..];
        if (line.len > 0 and indentWidthMismatch(line, opts.tabWidth)) {
            try diags.append(alloc, .{ .line_start = line_start, .line_end = source.len, .message = msg });
        }
    }
}

fn indentWidthMismatch(line: []const u8, tab_width: usize) bool {
    var spaces: usize = 0;
    var j: usize = 0;
    while (j < line.len and line[j] == ' ') {
        spaces += 1;
        j += 1;
    }
    if (j < line.len and line[j] == '\t') return false;
    if (spaces == 0) return false;
    return @rem(spaces, tab_width) != 0;
}

fn checkQuotes(source: []const u8, opts: common.FormatterOptions, msg: []const u8, diags: *std.ArrayListUnmanaged(FormatDiagnostic), alloc: std.mem.Allocator) !void {
    const want_single = opts.singleQuote;
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\\' and i + 1 < source.len) {
            i += 2;
            continue;
        }
        if (source[i] == '`') {
            i += 1;
            while (i < source.len and source[i] != '`') {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
                i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }
        if (source[i] == '"' or source[i] == '\'') {
            const quote_char = source[i];
            const is_wrong = if (want_single) quote_char != '\'' else quote_char != '"';
            if (is_wrong) {
                const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..i], '\n')) |nl| nl + 1 else @as(usize, 0);
                const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
                var already = false;
                for (diags.items) |d| {
                    if (d.line_start == line_start) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                }
            }
            i += 1;
            while (i < source.len and source[i] != quote_char) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
                i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }
        i += 1;
    }
}

fn trimRightFn(slice: []const u8, chars: []const u8) []const u8 {
    var end = slice.len;
    while (end > 0) {
        var found = false;
        for (chars) |c| {
            if (slice[end - 1] == c) {
                found = true;
                break;
            }
        }
        if (!found) break;
        end -= 1;
    }
    return slice[0..end];
}

fn checkSemi(source: []const u8, opts: common.FormatterOptions, msg: []const u8, diags: *std.ArrayListUnmanaged(FormatDiagnostic), alloc: std.mem.Allocator) !void {
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\n' or source[i] == '\r') {
            const line_end = i;
            const line = source[line_start..line_end];
            const trimmed = trimRightFn(line, " \t\r");
            if (trimmed.len > 0) {
                if (opts.semi) {
                    const needs = needsSemicolonCheck(trimmed);
                    if (needs and trimmed[trimmed.len - 1] != ';') {
                        try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                    }
                } else {
                    if (trimmed[trimmed.len - 1] == ';') {
                        try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                    }
                }
            }
            if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') {
                line_start = i + 2;
                i += 2;
            } else {
                line_start = i + 1;
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    if (line_start < source.len) {
        const line = source[line_start..];
        const trimmed = trimRightFn(line, " \t\r");
        if (trimmed.len > 0) {
            if (opts.semi) {
                const needs = needsSemicolonCheck(trimmed);
                if (needs and trimmed[trimmed.len - 1] != ';') {
                    try diags.append(alloc, .{ .line_start = line_start, .line_end = source.len, .message = msg });
                }
            } else {
                if (trimmed[trimmed.len - 1] == ';') {
                    try diags.append(alloc, .{ .line_start = line_start, .line_end = source.len, .message = msg });
                }
            }
        }
    }
}

fn needsSemicolonCheck(line: []const u8) bool {
    if (line.len == 0) return false;
    const last = line[line.len - 1];
    if (last == '{' or last == '}' or last == ';' or last == ',' or last == '`' or last == ')' or last == ']') return false;
    const code_keywords = [_][]const u8{ "else", "if", "try", "catch", "finally", "do", "while", "for", "switch", "case", "default", "break", "continue", "return", "throw", "yield", "await" };
    var j: usize = 0;
    while (j < line.len and line[j] == ' ') j += 1;
    const first_word_end = std.mem.indexOfAnyPos(u8, line, j, " ({[;") orelse line.len;
    const first_word = line[j..first_word_end];
    for (code_keywords) |kw| {
        if (std.mem.eql(u8, first_word, kw)) return false;
    }
    return true;
}

fn checkTrailingComma(source: []const u8, opts: common.FormatterOptions, msg: []const u8, diags: *std.ArrayListUnmanaged(FormatDiagnostic), alloc: std.mem.Allocator) !void {
    if (opts.trailingComma == .es5 or opts.trailingComma == .all) {
        var i: usize = 0;
        while (i < source.len) {
            if (source[i] == '\\' and i + 1 < source.len) {
                i += 2;
                continue;
            }
            if (source[i] == '"' or source[i] == '\'') {
                const q = source[i];
                i += 1;
                while (i < source.len and source[i] != q) {
                    if (source[i] == '\\' and i + 1 < source.len) i += 1;
                    i += 1;
                }
                if (i < source.len) i += 1;
                continue;
            }
            if (source[i] == '`') {
                i += 1;
                while (i < source.len and source[i] != '`') {
                    if (source[i] == '\\' and i + 1 < source.len) i += 1;
                    i += 1;
                }
                if (i < source.len) i += 1;
                continue;
            }
            if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
                continue;
            }
            if (source[i] == '/' and i + 1 < source.len and source[i + 1] == '*') {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i += 2;
                continue;
            }
            if (source[i] == '\n' or source[i] == '\r') {
                var j = i;
                while (j > 0 and (source[j - 1] == ' ' or source[j - 1] == '\t')) j -= 1;
                if (j > 0) {
                    const before = source[j - 1];
                    if (before == ',' or before == '[' or before == '{' or before == '(') {
                        if (before != ',') {
                            if (before == '{' and j > 1) {
                                var k: usize = j - 1;
                                while (k > 0 and (source[k - 1] == ' ' or source[k - 1] == '\t')) k -= 1;
                                if (k > 0 and source[k - 1] == ')') {
                                    if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') i += 2 else i += 1;
                                    continue;
                                }
                                const word_end = k;
                                var word_start = word_end;
                                while (word_start > 0 and (std.ascii.isAlphanumeric(source[word_start - 1]) or source[word_start - 1] == '$')) word_start -= 1;
                                const word = source[word_start..word_end];
                                 if (std.mem.eql(u8, word, "else") or
                                    std.mem.eql(u8, word, "do") or
                                    std.mem.eql(u8, word, "try") or
                                    std.mem.eql(u8, word, "finally")) {
                                    if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') i += 2 else i += 1;
                                    continue;
                                }
                                while (word_start > 0 and (source[word_start - 1] == ' ' or source[word_start - 1] == '\t')) word_start -= 1;
                                const prev_word_end = word_start;
                                var prev_word_start = prev_word_end;
                                while (prev_word_start > 0 and (std.ascii.isAlphanumeric(source[prev_word_start - 1]) or source[prev_word_start - 1] == '$')) prev_word_start -= 1;
                                if (std.mem.eql(u8, source[prev_word_start..prev_word_end], "class")) {
                                    if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') i += 2 else i += 1;
                                    continue;
                                }
                            }
                            try diags.append(alloc, .{ .line_start = if (std.mem.lastIndexOfScalar(u8, source[0..j], '\n')) |nl| nl + 1 else @as(usize, 0), .line_end = i, .message = msg });
                        }
                    }
                }
                if (source[i] == '\r' and i + 1 < source.len and source[i + 1] == '\n') i += 2 else i += 1;
                continue;
            }
            i += 1;
        }
    }
}

fn checkBracketSpacing(source: []const u8, opts: common.FormatterOptions, msg: []const u8, diags: *std.ArrayListUnmanaged(FormatDiagnostic), alloc: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\\' and i + 1 < source.len) {
            i += 2;
            continue;
        }
        if (source[i] == '"' or source[i] == '\'' or source[i] == '`') {
            const q = source[i];
            i += 1;
            while (i < source.len and source[i] != q) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
                i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }
        if (source[i] == '/' and i + 1 < source.len and (source[i + 1] == '/' or source[i + 1] == '*')) {
            if (source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
            } else {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i += 2;
            }
            continue;
        }
        if (source[i] == '{' and i + 1 < source.len and source[i + 1] != '}' and source[i + 1] != '\n' and source[i + 1] != '\r') {
            const has_space = source[i + 1] == ' ';
            if (opts.bracketSpacing and !has_space) {
                const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..i], '\n')) |nl| nl + 1 else @as(usize, 0);
                const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
                var already = false;
                for (diags.items) |d| {
                    if (d.line_start == line_start) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                }
            }
            if (!opts.bracketSpacing and has_space and i + 2 < source.len and source[i + 2] != '}') {
                const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..i], '\n')) |nl| nl + 1 else @as(usize, 0);
                const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
                var already = false;
                for (diags.items) |d| {
                    if (d.line_start == line_start) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                }
            }
        }
        if (source[i] == '}' and i > 0 and source[i - 1] != '{' and source[i - 1] != '\n' and source[i - 1] != '\r') {
            const has_space = i > 0 and source[i - 1] == ' ';
            if (opts.bracketSpacing and !has_space) {
                const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..i], '\n')) |nl| nl + 1 else @as(usize, 0);
                const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
                var already = false;
                for (diags.items) |d| {
                    if (d.line_start == line_start) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                }
            }
            if (!opts.bracketSpacing and has_space) {
                const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..i], '\n')) |nl| nl + 1 else @as(usize, 0);
                const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
                var already = false;
                for (diags.items) |d| {
                    if (d.line_start == line_start) {
                        already = true;
                        break;
                    }
                }
                if (!already) {
                    try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                }
            }
        }
        i += 1;
    }
}

fn checkArrowParens(source: []const u8, opts: common.FormatterOptions, msg: []const u8, diags: *std.ArrayListUnmanaged(FormatDiagnostic), alloc: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i + 1 < source.len) {
        if (source[i] == '\\' and i + 1 < source.len) {
            i += 2;
            continue;
        }
        if (source[i] == '"' or source[i] == '\'' or source[i] == '`') {
            const q = source[i];
            i += 1;
            while (i < source.len and source[i] != q) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
                i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }
        if (source[i] == '/' and i + 1 < source.len and (source[i + 1] == '/' or source[i + 1] == '*')) {
            if (source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
            } else {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i += 2;
            }
            continue;
        }
        if (source[i] == '=' and source[i + 1] == '>') {
            var j: usize = if (i > 0) i - 1 else 0;
            while (j > 0 and source[j] == ' ') j -= 1;
            if (j > 0 and source[j] == ')') {
                if (opts.arrowParens != .always) {
                    var depth: usize = 0;
                    var k: usize = j;
                    var has_comma = false;
                    var inner_start: usize = j;
                    while (k > 0) {
                        if (source[k] == ')') {
                            if (depth == 0) inner_start = k;
                            depth += 1;
                        }
                        if (source[k] == '(') depth -= 1;
                        if (depth == 0 and source[k] == ',') has_comma = true;
                        if (depth == 0) break;
                        k -= 1;
                    }
                    if (!has_comma) {
                        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..j], '\n')) |nl| nl + 1 else @as(usize, 0);
                        const line_end = std.mem.indexOfScalarPos(u8, source, i + 2, '\n') orelse source.len;
                        try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                    }
                }
            } else if (j > 0 and (std.mem.indexOfScalar(u8, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$", source[j]) != null)) {
                if (opts.arrowParens == .always) {
                    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..j], '\n')) |nl| nl + 1 else @as(usize, 0);
                    const line_end = std.mem.indexOfScalarPos(u8, source, i + 2, '\n') orelse source.len;
                    try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                }
            }
        }
        i += 1;
    }
}

fn checkBracketSameLine(source: []const u8, opts: common.FormatterOptions, msg: []const u8, diags: *std.ArrayListUnmanaged(FormatDiagnostic), alloc: std.mem.Allocator) !void {
    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\\' and i + 1 < source.len) {
            i += 2;
            continue;
        }
        if (source[i] == '"' or source[i] == '\'' or source[i] == '`') {
            const q = source[i];
            i += 1;
            while (i < source.len and source[i] != q) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
                i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }
        if (source[i] == '/' and i + 1 < source.len and (source[i + 1] == '/' or source[i + 1] == '*')) {
            if (source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') i += 1;
            } else {
                i += 2;
                while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
                i += 2;
            }
            continue;
        }
        if (source[i] == '>' and i > 0) {
            if (i > 0 and source[i - 1] == '=') {
                i += 1;
                continue;
            }
            if (i + 1 < source.len and (source[i + 1] == '=' or source[i + 1] == '>')) {
                i += 1;
                continue;
            }
            var before = i - 1;
            while (before > 0 and source[before] == ' ') before -= 1;
            if (before > 0 and source[before] == '\n') {
                if (opts.bracketSameLine) {
                    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..before], '\n')) |nl| nl + 1 else @as(usize, 0);
                    const line_end = std.mem.indexOfScalarPos(u8, source, i + 1, '\n') orelse source.len;
                    try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                }
            } else if (before > 0 and source[before] != '\n') {
                if (!opts.bracketSameLine) {
                    var is_jsx_close = false;
                    if (before > 0 and source[before] == '/') {
                        is_jsx_close = true;
                    } else {
                        var k: usize = i + 1;
                        while (k < source.len and source[k] == ' ') k += 1;
                        if (k < source.len and source[k] == '<') {
                            is_jsx_close = true;
                        }
                    }
                    if (is_jsx_close) {
                        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..i], '\n')) |nl| nl + 1 else @as(usize, 0);
                        const line_end = std.mem.indexOfScalarPos(u8, source, i + 1, '\n') orelse source.len;
                        try diags.append(alloc, .{ .line_start = line_start, .line_end = line_end, .message = msg });
                    }
                }
            }
        }
        i += 1;
    }
}

pub fn freeCheckDiagnostics(alloc: std.mem.Allocator, diags: []FormatDiagnostic) void {
    alloc.free(diags);
}

pub fn registerFormatterRules(registry: anytype, alloc: std.mem.Allocator) !void {
    const formatter_rules = [_]common.LintRule{
        .{ .code = "formatter/quotes", .severity = .off, .run = runFormatterRule },
        .{ .code = "formatter/semi", .severity = .off, .run = runFormatterRule },
        .{ .code = "formatter/trailing-comma", .severity = .off, .run = runFormatterRule },
        .{ .code = "formatter/bracket-spacing", .severity = .off, .run = runFormatterRule },
        .{ .code = "formatter/use-tabs", .severity = .off, .run = runFormatterRule },
        .{ .code = "formatter/tab-width", .severity = .off, .run = runFormatterRule },
        .{ .code = "formatter/print-width", .severity = .off, .run = runFormatterRule },
        .{ .code = "formatter/arrow-parens", .severity = .off, .run = runFormatterRule },
        .{ .code = "formatter/end-of-line", .severity = .off, .run = runFormatterRule },
        .{ .code = "formatter/bracket-same-line", .severity = .off, .run = runFormatterRule },
    };
    for (formatter_rules) |rule| {
        try registry.register(alloc, rule);
    }
}

fn runFormatterRule(ctx: common.LintContext, rule: common.LintRule) !void {
    const opt = rule.options orelse return;
    const check_diags = checkFormat(ctx.source, rule.code, opt, ctx.alloc) catch return;
    defer freeCheckDiagnostics(ctx.alloc, check_diags);
    for (check_diags) |d| {
        try ctx.report(rule.code, rule.severity, d.message, d.line_start, d.line_end);
    }
}
