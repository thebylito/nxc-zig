const std = @import("std");
const tok = @import("token.zig");
pub const Token = tok.Token;
pub const TokenKind = tok.TokenKind;
pub const Span = tok.Span;
pub const token = tok;

pub const LexerMode = enum {
    normal,
    jsx,
    jsx_attr,
    type_pos,
};

const CHAR_DIGIT: u8 = 1 << 0;
const CHAR_ALPHA: u8 = 1 << 1;
const CHAR_HEX: u8 = 1 << 2;
const CHAR_IDENT_START: u8 = 1 << 3;
const CHAR_IDENT_CONT: u8 = 1 << 4;
const CHAR_WHITESPACE: u8 = 1 << 5;

const char_table: [256]u8 = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u8 = [_]u8{0} ** 256;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const c: u8 = @intCast(i);
        var flags: u8 = 0;
        if (c >= '0' and c <= '9') {
            flags |= CHAR_DIGIT | CHAR_HEX | CHAR_IDENT_CONT;
        }
        if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) {
            flags |= CHAR_ALPHA | CHAR_HEX | CHAR_IDENT_START | CHAR_IDENT_CONT;
        }
        if (c == '_' or c == '$') {
            flags |= CHAR_IDENT_START | CHAR_IDENT_CONT;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            flags |= CHAR_WHITESPACE;
        }
        table[i] = flags;
    }
    break :blk table;
};

inline fn isIdentStart(c: u8) bool {
    return (char_table[c] & CHAR_IDENT_START) != 0 or c > 127;
}

inline fn isIdentCont(c: u8) bool {
    return (char_table[c] & CHAR_IDENT_CONT) != 0 or c > 127;
}

inline fn isDigit(c: u8) bool {
    return (char_table[c] & CHAR_DIGIT) != 0;
}

inline fn isHex(c: u8) bool {
    return (char_table[c] & CHAR_HEX) != 0;
}

inline fn isAlpha(c: u8) bool {
    return (char_table[c] & CHAR_ALPHA) != 0;
}

pub const Lexer = struct {
    pub const Comment = struct {
        raw: []const u8,
        span: Span,
    };

    src: []const u8,
    pos: u32,
    line: u32,
    line_start: u32,
    mode: LexerMode,
    peeked: ?Token,
    last_kind: ?TokenKind,
    template_stack: [16]u8 = [_]u8{0} ** 16,
    template_depth: u8 = 0,
    brace_depth: u8 = 0,
    pending_comments: [32]Comment = undefined,
    pending_comments_len: u8 = 0,

    pub fn init(src: []const u8) Lexer {
        return .{
            .src = src,
            .pos = 0,
            .line = 1,
            .line_start = 0,
            .mode = .normal,
            .peeked = null,
            .last_kind = null,
        };
    }

    pub fn peek(self: *Lexer) Token {
        if (self.peeked == null) {
            self.peeked = self.nextInner();
        }
        return self.peeked.?;
    }

    pub fn next(self: *Lexer) Token {
        if (self.peeked) |t| {
            self.peeked = null;
            self.last_kind = t.kind;
            return t;
        }
        const t = self.nextInner();
        self.last_kind = t.kind;
        return t;
    }

    pub fn expect(self: *Lexer, kind: TokenKind) !Token {
        const t = self.next();
        if (t.kind != kind) return error.UnexpectedToken;
        return t;
    }

    pub fn takePendingComments(self: *Lexer) []const Comment {
        const comments = self.pending_comments[0..self.pending_comments_len];
        self.pending_comments_len = 0;
        return comments;
    }

    pub const State = struct {
        peeked: ?Token,
        pos: u32,
        line: u32,
        line_start: u32,
        template_stack: [16]u8,
        template_depth: u8,
        brace_depth: u8,
        pending_comments_len: u8,
    };

    pub fn save(self: *const Lexer) State {
        return .{
            .peeked = self.peeked,
            .pos = self.pos,
            .line = self.line,
            .line_start = self.line_start,
            .template_stack = self.template_stack,
            .template_depth = self.template_depth,
            .brace_depth = self.brace_depth,
            .pending_comments_len = self.pending_comments_len,
        };
    }

    pub fn restore(self: *Lexer, state: State) void {
        self.peeked = state.peeked;
        self.pos = state.pos;
        self.line = state.line;
        self.line_start = state.line_start;
        self.template_stack = state.template_stack;
        self.template_depth = state.template_depth;
        self.brace_depth = state.brace_depth;
        self.pending_comments_len = state.pending_comments_len;
    }

    fn col(self: *const Lexer) u32 {
        return self.pos - self.line_start + 1;
    }

    fn spanFrom(self: *const Lexer, start: u32, start_line: u32, start_col: u32) Span {
        return .{
            .start = start,
            .end = self.pos,
            .line = start_line,
            .col = start_col,
        };
    }

    inline fn at(self: *const Lexer, offset: u32) u8 {
        const idx = self.pos + offset;
        if (idx >= self.src.len) return 0;
        return self.src[idx];
    }

    fn cur(self: *const Lexer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn peek1(self: *const Lexer) u8 {
        if (self.pos + 1 >= self.src.len) return 0;
        return self.src[self.pos + 1];
    }

    fn advance(self: *Lexer) void {
        if (self.pos < self.src.len) self.pos += 1;
    }

    fn skipWhitespace(self: *Lexer) void {
        const len = self.src.len;
        while (self.pos < len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
                if (self.pos < len) {
                    const c2 = self.src[self.pos];
                    if (c2 == ' ' or c2 == '\t' or c2 == '\r') {
                        self.pos += 1;
                    }
                }
                continue;
            }
            if (c == '\n') {
                self.pos += 1;
                self.line += 1;
                self.line_start = self.pos;
                continue;
            }
            if (c >= 0xE0 and self.pos + 2 < len) {
                const b1 = self.src[self.pos + 1];
                const b2 = self.src[self.pos + 2];
                if (c == 0xEF and b1 == 0xBB and b2 == 0xBF) {
                    self.pos += 3;
                    continue;
                }
                if (c == 0xE2 and b1 == 0x80 and b2 == 0x8B) {
                    self.pos += 3;
                    continue;
                }
            }
            break;
        }
    }

    fn skipLineComment(self: *Lexer) void {
        const rest = self.src[self.pos..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        self.pos += @intCast(nl);
    }

    fn skipBlockComment(self: *Lexer) bool {
        self.pos += 2;
        const len = self.src.len;
        while (self.pos + 1 < len) {
            if (self.src[self.pos] == '\n') {
                self.line += 1;
                self.line_start = self.pos + 1;
            }
            if (self.src[self.pos] == '*' and self.src[self.pos + 1] == '/') {
                self.pos += 2;
                return true;
            }
            self.pos += 1;
        }
        return false;
    }

    fn pushPendingComment(self: *Lexer, start: u32, start_line: u32, start_col: u32) void {
        if (self.pending_comments_len >= self.pending_comments.len) return;
        self.pending_comments[self.pending_comments_len] = .{
            .raw = self.src[start..self.pos],
            .span = self.spanFrom(start, start_line, start_col),
        };
        self.pending_comments_len += 1;
    }

    fn readString(self: *Lexer, quote: u8) Token {
        const start = self.pos;
        const sl = self.line;
        const sc = self.col();
        self.pos += 1;
        const len = self.src.len;
        var closed = false;
        while (self.pos < len) {
            const c = self.src[self.pos];
            if (c == '\\') {
                self.pos += 2;
                continue;
            }
            if (c == '\n' or c == '\r') break;
            self.pos += 1;
            if (c == quote) {
                closed = true;
                break;
            }
        }
        if (!closed) {
            self.pos = start + 1;
            return .{
                .kind = .invalid,
                .span = self.spanFrom(start, sl, sc),
                .raw = self.src[start..self.pos],
            };
        }
        return .{
            .kind = .string,
            .span = self.spanFrom(start, sl, sc),
            .raw = self.src[start..self.pos],
        };
    }

    fn readTemplate(self: *Lexer) Token {
        const start = self.pos;
        const sl = self.line;
        const sc = self.col();
        self.pos += 1;
        const len = self.src.len;
        var has_expr = false;
        var closed = false;
        while (self.pos < len) {
            const c = self.src[self.pos];
            if (c == '\\') {
                self.pos += 2;
                continue;
            }
            if (c == '\n') {
                self.line += 1;
                self.line_start = self.pos + 1;
            }
            if (c == '$' and self.pos + 1 < len and self.src[self.pos + 1] == '{') {
                self.pos += 2;
                has_expr = true;
                break;
            }
            self.pos += 1;
            if (c == '`') {
                closed = true;
                break;
            }
        }
        if (!has_expr and !closed) {
            self.pos = start + 1;
            return .{
                .kind = .invalid,
                .span = self.spanFrom(start, sl, sc),
                .raw = self.src[start..self.pos],
            };
        }
        const kind: TokenKind = if (has_expr) .template_head else .template_no_sub;
        if (kind == .template_head) {
            if (self.template_depth < 16) {
                self.template_stack[self.template_depth] = self.brace_depth;
                self.template_depth += 1;
            }
        }
        return .{
            .kind = kind,
            .span = self.spanFrom(start, sl, sc),
            .raw = self.src[start..self.pos],
        };
    }

    fn readTemplateMiddleOrTail(self: *Lexer) Token {
        const start = self.pos;
        const sl = self.line;
        const sc = self.col();
        const len = self.src.len;
        var has_expr = false;
        while (self.pos < len) {
            const c = self.src[self.pos];
            if (c == '\\') {
                self.pos += 2;
                continue;
            }
            if (c == '\n') {
                self.line += 1;
                self.line_start = self.pos + 1;
            }
            if (c == '$' and self.pos + 1 < len and self.src[self.pos + 1] == '{') {
                self.pos += 2;
                has_expr = true;
                break;
            }
            self.pos += 1;
            if (c == '`') break;
        }
        const kind: TokenKind = if (has_expr) .template_middle else .template_tail;
        if (kind == .template_middle) {
            if (self.template_depth < 16) {
                self.template_stack[self.template_depth] = self.brace_depth;
                self.template_depth += 1;
            }
        }
        return .{
            .kind = kind,
            .span = self.spanFrom(start, sl, sc),
            .raw = self.src[start..self.pos],
        };
    }

    fn readNumber(self: *Lexer) Token {
        const start = self.pos;
        const sl = self.line;
        const sc = self.col();
        const len = self.src.len;
        if (self.src[self.pos] == '0' and self.pos + 1 < len) {
            const nc = self.src[self.pos + 1];
            if (nc == 'x' or nc == 'X') {
                self.pos += 2;
                while (self.pos < len and isHex(self.src[self.pos])) self.pos += 1;
                return .{ .kind = .number, .span = self.spanFrom(start, sl, sc), .raw = self.src[start..self.pos] };
            }
            if (nc == 'b' or nc == 'B') {
                self.pos += 2;
                while (self.pos < len and (self.src[self.pos] == '0' or self.src[self.pos] == '1')) self.pos += 1;
                if (self.pos < len and self.src[self.pos] == 'n') self.pos += 1;
                return .{ .kind = .number, .span = self.spanFrom(start, sl, sc), .raw = self.src[start..self.pos] };
            }
            if (nc == 'o' or nc == 'O') {
                self.pos += 2;
                while (self.pos < len and self.src[self.pos] >= '0' and self.src[self.pos] <= '7') self.pos += 1;
                if (self.pos < len and self.src[self.pos] == 'n') self.pos += 1;
                return .{ .kind = .number, .span = self.spanFrom(start, sl, sc), .raw = self.src[start..self.pos] };
            }
        }
        while (self.pos < len and (isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) self.pos += 1;
        if (self.pos < len and self.src[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < len and isDigit(self.src[self.pos])) self.pos += 1;
        }
        if (self.pos < len and (self.src[self.pos] == 'e' or self.src[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < len and (self.src[self.pos] == '+' or self.src[self.pos] == '-')) self.pos += 1;
            while (self.pos < len and isDigit(self.src[self.pos])) self.pos += 1;
        }
        if (self.pos < len and self.src[self.pos] == 'n') self.pos += 1;
        return .{
            .kind = .number,
            .span = self.spanFrom(start, sl, sc),
            .raw = self.src[start..self.pos],
        };
    }

    fn readPrivateName(self: *Lexer) Token {
        const start = self.pos;
        const sl = self.line;
        const sc = self.col();
        self.pos += 1;
        const len = self.src.len;
        while (self.pos < len and isIdentCont(self.src[self.pos])) {
            self.pos += 1;
        }
        return .{ .kind = .private_name, .span = self.spanFrom(start, sl, sc), .raw = self.src[start..self.pos] };
    }

    fn readIdent(self: *Lexer) Token {
        const start = self.pos;
        const sl = self.line;
        const sc = self.col();
        const len = self.src.len;
        while (self.pos < len) {
            const c = self.src[self.pos];
            if ((char_table[c] & CHAR_IDENT_CONT) != 0) {
                self.pos += 1;
                continue;
            }
            if (c > 127) {
                self.pos += 1;
                continue;
            }
            break;
        }
        const raw = self.src[start..self.pos];
        const kind = tok.lookupKeyword(raw) orelse .ident;
        return .{
            .kind = kind,
            .span = self.spanFrom(start, sl, sc),
            .raw = raw,
        };
    }

    fn canStartRegex(self: *const Lexer) bool {
        const kind = self.last_kind orelse return true;
        return switch (kind) {
            .ident,
            .private_name,
            .number,
            .string,
            .regex,
            .kw_true,
            .kw_false,
            .kw_null,
            .kw_this,
            .kw_super,
            .kw_import,
            .template_tail,
            .template_no_sub,
            .rparen,
            .rbracket,
            .rbrace,
            .plus2,
            .minus2,
            => false,
            else => true,
        };
    }

    fn readRegex(self: *Lexer) Token {
        const start = self.pos;
        const sl = self.line;
        const sc = self.col();
        self.pos += 1;
        const len = self.src.len;

        var in_class = false;
        var closed = false;
        while (self.pos < len) {
            const c = self.src[self.pos];
            if (c == '\\') {
                if (self.pos + 1 < len) {
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
                continue;
            }
            if (c == '\n' or c == '\r') break;
            if (c == '[') {
                in_class = true;
                self.pos += 1;
                continue;
            }
            if (c == ']' and in_class) {
                in_class = false;
                self.pos += 1;
                continue;
            }
            if (c == '/' and !in_class) {
                self.pos += 1;
                closed = true;
                while (self.pos < len and isAlpha(self.src[self.pos])) {
                    self.pos += 1;
                }
                break;
            }
            self.pos += 1;
        }

        if (!closed) {
            self.pos = start + 1;
            return .{
                .kind = .invalid,
                .span = self.spanFrom(start, sl, sc),
                .raw = self.src[start..self.pos],
            };
        }

        return .{
            .kind = .regex,
            .span = self.spanFrom(start, sl, sc),
            .raw = self.src[start..self.pos],
        };
    }

    fn nextInner(self: *Lexer) Token {
        // Loop over leading comments iteratively; recursing here would overflow
        // the stack on inputs with long runs of consecutive comments.
        while (true) {
            self.skipWhitespace();

            if (self.pos >= self.src.len) {
                return .{
                    .kind = .eof,
                    .span = .{ .start = self.pos, .end = self.pos, .line = self.line, .col = self.col() },
                    .raw = "",
                };
            }

            const c0 = self.src[self.pos];

            if (c0 == '/') {
                if (self.pos + 1 < self.src.len) {
                    const c1 = self.src[self.pos + 1];
                    if (c1 == '/') {
                        const start = self.pos;
                        const sl = self.line;
                        const sc = self.col();
                        self.skipLineComment();
                        self.pushPendingComment(start, sl, sc);
                        continue;
                    }
                    if (c1 == '*') {
                        const start = self.pos;
                        const sl = self.line;
                        const sc = self.col();
                        const closed = self.skipBlockComment();
                        if (!closed) {
                            self.pos = start + 2;
                            return .{ .kind = .invalid, .span = self.spanFrom(start, sl, sc), .raw = self.src[start..self.pos] };
                        }
                        self.pushPendingComment(start, sl, sc);
                        continue;
                    }
                }
            }

            return self.nextInnerToken(c0);
        }
    }

    fn nextInnerToken(self: *Lexer, c0: u8) Token {

        const start = self.pos;
        const sl = self.line;
        const sc = self.col();

        if (self.mode == .jsx and c0 == '/') {
            self.pos += 1;
            return .{ .kind = .slash, .span = self.spanFrom(start, sl, sc), .raw = self.src[start..self.pos] };
        }

        if (c0 == '"' or c0 == '\'') return self.readString(c0);
        if (c0 == '`') return self.readTemplate();
        if (c0 == '/' and self.canStartRegex()) return self.readRegex();

        if (isDigit(c0) or (c0 == '.' and self.pos + 1 < self.src.len and isDigit(self.src[self.pos + 1]))) {
            return self.readNumber();
        }

        if (isIdentStart(c0)) {
            return self.readIdent();
        }

        if (c0 == '#' and self.pos + 1 < self.src.len and isIdentStart(self.src[self.pos + 1])) {
            return self.readPrivateName();
        }

        if (c0 == '}' and self.template_depth > 0 and self.brace_depth == self.template_stack[self.template_depth - 1]) {
            self.template_depth -= 1;
            return self.readTemplateMiddleOrTail();
        }

        self.pos += 1;
        const sp = self.spanFrom(start, sl, sc);

        const kind: TokenKind = switch (c0) {
            '(' => .lparen,
            ')' => .rparen,
            '{' => blk: {
                self.brace_depth +|= 1;
                break :blk .lbrace;
            },
            '}' => blk: {
                if (self.brace_depth > 0) self.brace_depth -= 1;
                break :blk .rbrace;
            },
            '[' => .lbracket,
            ']' => .rbracket,
            ';' => .semicolon,
            ':' => .colon,
            ',' => .comma,
            '~' => .tilde,
            '@' => .at,
            '.' => blk: {
                if (self.cur() == '.' and self.peek1() == '.') {
                    self.pos += 2;
                    break :blk .dotdotdot;
                }
                break :blk .dot;
            },
            '?' => blk: {
                const n = self.cur();
                if (n == '.') {
                    self.pos += 1;
                    break :blk .question_dot;
                }
                if (n == '?') {
                    self.pos += 1;
                    if (self.cur() == '=') {
                        self.pos += 1;
                        break :blk .question2_eq;
                    }
                    break :blk .question2;
                }
                break :blk .question;
            },
            '=' => blk: {
                const n = self.cur();
                if (n == '>') {
                    self.pos += 1;
                    break :blk .arrow;
                }
                if (n == '=') {
                    self.pos += 1;
                    if (self.cur() == '=') {
                        self.pos += 1;
                        break :blk .eq3;
                    }
                    break :blk .eq2;
                }
                break :blk .eq;
            },
            '!' => blk: {
                const n = self.cur();
                if (n == '=') {
                    self.pos += 1;
                    if (self.cur() == '=') {
                        self.pos += 1;
                        break :blk .bang_eq2;
                    }
                    break :blk .bang_eq;
                }
                break :blk .bang;
            },
            '+' => blk: {
                const n = self.cur();
                if (n == '+') {
                    self.pos += 1;
                    break :blk .plus2;
                }
                if (n == '=') {
                    self.pos += 1;
                    break :blk .plus_eq;
                }
                break :blk .plus;
            },
            '-' => blk: {
                const n = self.cur();
                if (n == '-') {
                    self.pos += 1;
                    break :blk .minus2;
                }
                if (n == '=') {
                    self.pos += 1;
                    break :blk .minus_eq;
                }
                break :blk .minus;
            },
            '*' => blk: {
                const n = self.cur();
                if (n == '*') {
                    self.pos += 1;
                    if (self.cur() == '=') {
                        self.pos += 1;
                        break :blk .star2_eq;
                    }
                    break :blk .star2;
                }
                if (n == '=') {
                    self.pos += 1;
                    break :blk .star_eq;
                }
                break :blk .star;
            },
            '/' => blk: {
                if (self.cur() == '=') {
                    self.pos += 1;
                    break :blk .slash_eq;
                }
                break :blk .slash;
            },
            '%' => blk: {
                if (self.cur() == '=') {
                    self.pos += 1;
                    break :blk .percent_eq;
                }
                break :blk .percent;
            },
            '<' => blk: {
                const n = self.cur();
                if (n == '<') {
                    self.pos += 1;
                    if (self.cur() == '=') {
                        self.pos += 1;
                        break :blk .lt2_eq;
                    }
                    break :blk .lt2;
                }
                if (n == '=') {
                    self.pos += 1;
                    break :blk .lt_eq;
                }
                break :blk .lt;
            },
            '>' => blk: {
                const n = self.cur();
                if (n == '>') {
                    self.pos += 1;
                    const n2 = self.cur();
                    if (n2 == '>') {
                        self.pos += 1;
                        if (self.cur() == '=') {
                            self.pos += 1;
                            break :blk .gt3_eq;
                        }
                        break :blk .gt3;
                    }
                    if (n2 == '=') {
                        self.pos += 1;
                        break :blk .gt2_eq;
                    }
                    break :blk .gt2;
                }
                if (n == '=') {
                    self.pos += 1;
                    break :blk .gt_eq;
                }
                break :blk .gt;
            },
            '&' => blk: {
                const n = self.cur();
                if (n == '&') {
                    self.pos += 1;
                    if (self.cur() == '=') {
                        self.pos += 1;
                        break :blk .amp2_eq;
                    }
                    break :blk .amp2;
                }
                if (n == '=') {
                    self.pos += 1;
                    break :blk .amp_eq;
                }
                break :blk .amp;
            },
            '|' => blk: {
                const n = self.cur();
                if (n == '|') {
                    self.pos += 1;
                    if (self.cur() == '=') {
                        self.pos += 1;
                        break :blk .pipe2_eq;
                    }
                    break :blk .pipe2;
                }
                if (n == '=') {
                    self.pos += 1;
                    break :blk .pipe_eq;
                }
                break :blk .pipe;
            },
            '^' => blk: {
                if (self.cur() == '=') {
                    self.pos += 1;
                    break :blk .caret_eq;
                }
                break :blk .caret;
            },
            else => .invalid,
        };

        return .{ .kind = kind, .span = sp, .raw = self.src[start..self.pos] };
    }
};
