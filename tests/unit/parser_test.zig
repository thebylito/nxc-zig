const std = @import("std");

const ast = @import("ast");
const diagnostics = @import("diagnostics");
const parser = @import("parser");
const compiler = @import("compiler");
const codegen = @import("codegen");
const util = @import("../util.zig");

const Parser = parser.Parser;
const Codegen = codegen.Codegen;
const trimText = util.trimText;
const normalizedOutput = util.normalizedOutput;
const equalIgnoringWhitespace = util.equalIgnoringWhitespace;

fn compile(src: []const u8) ![]const u8 {
    const alloc = std.testing.allocator;
    const result = try compiler.compile(src, "test.js", .{ .parser = .{ .syntax = .ecmascript }, .jsx = false }, std.testing.io, alloc);
    defer result.deinit(alloc);
    if (result.diagnostics.len > 0) {
        for (result.diagnostics) |d| {
            std.debug.print("diag: {s}\n", .{d.message});
        }
        if (result.diagnostics[0].severity == .err) {
            return error.ParseError;
        }
    }
    return try alloc.dupe(u8, result.code);
}

fn compileTs(src: []const u8) ![]const u8 {
    const alloc = std.testing.allocator;
    const result = try compiler.compile(src, "test.ts", .{ .parser = .{ .syntax = .typescript }, .jsx = false }, std.testing.io, alloc);
    defer result.deinit(alloc);
    if (result.diagnostics.len > 0) {
        for (result.diagnostics) |d| std.debug.print("diag: {s}\n", .{d.message});
        if (result.diagnostics[0].severity == .err) {
            return error.ParseError;
        }
    }
    return try alloc.dupe(u8, result.code);
}

fn expectOutput(src: []const u8, expected: []const u8) !void {
    const out = try compile(src);
    defer std.testing.allocator.free(out);
    const trimmed = normalizedOutput(out, expected);
    const exp_trimmed = trimText(expected);
    if (!std.mem.eql(u8, trimmed, exp_trimmed) and !equalIgnoringWhitespace(trimmed, exp_trimmed)) {
        std.debug.print("\n=== EXPECTED ===\n{s}\n=== GOT ===\n{s}\n", .{ exp_trimmed, trimmed });
        return error.TestExpectedEqual;
    }
}

fn expectTsOutput(src: []const u8, expected: []const u8) !void {
    const out = try compileTs(src);
    defer std.testing.allocator.free(out);
    const trimmed = normalizedOutput(out, expected);
    const exp_trimmed = trimText(expected);
    if (!std.mem.eql(u8, trimmed, exp_trimmed) and !equalIgnoringWhitespace(trimmed, exp_trimmed)) {
        std.debug.print("\n=== EXPECTED ===\n{s}\n=== GOT ===\n{s}\n", .{ exp_trimmed, trimmed });
        return error.TestExpectedEqual;
    }
}

test "typescript function may use contextual keyword module as name" {
    const source =
        \\function module(args: { imports: string[] }): ClassDecorator {
        \\  return function (target) {
        \\  }
        \\}
    ;

    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const alloc = arena_alloc.allocator();

    var node_arena = ast.Arena.init(alloc);
    var diags = diagnostics.DiagnosticList{};

    var p = Parser.init(source, "test.ts", &node_arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });

    _ = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 0), diags.items.items.len);
}

test "typescript decorator call supports object literal with array property" {
    const source =
        \\@module({
        \\  imports: []
        \\})
        \\export class AppModule {}
    ;

    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();
    const alloc = arena_alloc.allocator();

    var node_arena = ast.Arena.init(alloc);
    var diags = diagnostics.DiagnosticList{};

    var p = Parser.init(source, "test.ts", &node_arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });

    _ = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 0), diags.items.items.len);
}

test "asi: return before try statement on next line" {
    const source =
        \\function run(interaction) {
        \\  if (!interaction.isChatInputCommand()) return
        \\
        \\  try {
        \\  } catch {}
        \\}
    ;

    const expected =
        \\"use strict";
        \\function run(interaction) {
        \\  if (!interaction.isChatInputCommand()) return;
        \\  try {} catch {}
        \\}
    ;

    try expectOutput(source, expected);
}

test "asi: return before const destructuring on next line" {
    const source =
        \\function run(channel) {
        \\  if (!channel || !channel.isVoiceBased()) return
        \\
        \\  const { guild } = channel
        \\}
    ;

    const expected =
        \\"use strict";
        \\function run(channel) {
        \\  if (!channel || !channel.isVoiceBased()) return;
        \\  const { guild } = channel;
        \\}
    ;

    try expectOutput(source, expected);
}

test "asi: continue before expression statement on next line" {
    const source =
        \\async function run(rows, guild, entries) {
        \\  for (const row of rows) {
        \\    const channel = await guild.channels.fetch(row.id).catch(() => null)
        \\    if (!channel || !channel.isVoiceBased()) continue
        \\    entries.push({ id: row.id, isPrimary: row.isPrimary, channel })
        \\  }
        \\}
    ;

    const expected =
        \\"use strict";
        \\async function run(rows, guild, entries) {
        \\  for (const row of rows) {
        \\    const channel = await guild.channels.fetch(row.id).catch(() => null);
        \\    if (!channel || !channel.isVoiceBased()) continue;
        \\    entries.push({ id: row.id, isPrimary: row.isPrimary, channel });
        \\  }
        \\}
    ;

    try expectOutput(source, expected);
}

test "asi: break before expression statement on next line" {
    const source =
        \\function run(items) {
        \\  while (true) {
        \\    if (items.length === 0) break
        \\    items.pop()
        \\  }
        \\}
    ;

    const expected =
        \\"use strict";
        \\function run(items) {
        \\  while (true) {
        \\    if (items.length === 0) break;
        \\    items.pop();
        \\  }
        \\}
    ;

    try expectOutput(source, expected);
}

test "asi: continue and break labels still work on same line" {
    const source =
        \\function run(items) {
        \\  outer: for (const item of items) {
        \\    while (true) {
        \\      continue outer
        \\      break outer
        \\    }
        \\  }
        \\}
    ;

    const expected =
        \\"use strict";
        \\function run(items) {
        \\  outer: for (const item of items) {
        \\    while (true) {
        \\      continue outer;
        \\      break outer;
        \\    }
        \\  }
        \\}
    ;

    try expectOutput(source, expected);
}

test "parser supports async private class methods" {
    const source =
        \\class Service {
        \\  async #removeOrphanRows() {
        \\    return 1
        \\  }
        \\
        \\  async run() {
        \\    return await this.#removeOrphanRows()
        \\  }
        \\}
    ;

    const expected =
        \\"use strict";
        \\class Service {
        \\  async #removeOrphanRows() {
        \\    return 1;
        \\  }
        \\  async run() {
        \\    return await this.#removeOrphanRows();
        \\  }
        \\}
    ;

    try expectOutput(source, expected);
}

test "parser supports static async private class methods" {
    const source =
        \\class Service {
        \\  static async #removeOrphanRows() {
        \\    return 1
        \\  }
        \\}
    ;

    const expected =
        \\"use strict";
        \\class Service {
        \\  static async #removeOrphanRows() {
        \\    return 1;
        \\  }
        \\}
    ;

    try expectOutput(source, expected);
}

test "parses for-await-of with await using declaration" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\async function main(resources: AsyncIterable<Disposable>) {
        \\  for await (await using resource of resources) {
        \\    resource.use();
        \\  }
        \\}
    ;

    var p = Parser.init(source, "await_using_for_of.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });
    const program_id = try p.parseProgram();

    try std.testing.expect(!diags.hasErrors());

    const program = arena.get(program_id).program;
    try std.testing.expectEqual(@as(usize, 1), program.body.len);

    const fn_decl = arena.get(program.body[0]).fn_decl;
    const body = arena.get(fn_decl.body).block;
    try std.testing.expectEqual(@as(usize, 1), body.body.len);

    const for_stmt = arena.get(body.body[0]).for_stmt;
    try std.testing.expectEqual(ast.ForKind.of, for_stmt.kind);
    try std.testing.expect(for_stmt.is_await);
    try std.testing.expect(for_stmt.init != null);
    try std.testing.expect(for_stmt.update != null);

    const init = arena.get(for_stmt.init.?).var_decl;
    try std.testing.expectEqual(ast.VarKind.using, init.kind);
    try std.testing.expect(init.is_await);
    try std.testing.expectEqual(@as(usize, 1), init.declarators.len);
    try std.testing.expect(init.declarators[0].init == null);
}

test "parses for-of with using declaration" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\for (using resource of resources) {
        \\  resource.use();
        \\}
    ;

    var p = Parser.init(source, "using_for_of.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });
    const program_id = try p.parseProgram();

    try std.testing.expect(!diags.hasErrors());

    const program = arena.get(program_id).program;
    try std.testing.expectEqual(@as(usize, 1), program.body.len);

    const for_stmt = arena.get(program.body[0]).for_stmt;
    try std.testing.expectEqual(ast.ForKind.of, for_stmt.kind);
    try std.testing.expect(!for_stmt.is_await);

    const init = arena.get(for_stmt.init.?).var_decl;
    try std.testing.expectEqual(ast.VarKind.using, init.kind);
    try std.testing.expect(!init.is_await);
    try std.testing.expectEqual(@as(usize, 1), init.declarators.len);
    try std.testing.expect(init.declarators[0].init == null);
}

test "parses async keyword-named class methods" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\class AsyncIteratorLike {
        \\  async return() {
        \\    return { value: "finished", done: true };
        \\  }
        \\
        \\  async throw(error?: unknown) {
        \\    throw error;
        \\  }
        \\
        \\  async delete() {}
        \\  async if() {}
        \\}
    ;

    var p = Parser.init(source, "async_keyword_methods.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });
    const program_id = try p.parseProgram();

    try std.testing.expect(!diags.hasErrors());

    const program = arena.get(program_id).program;
    try std.testing.expectEqual(@as(usize, 1), program.body.len);

    const class_decl = arena.get(program.body[0]).class_decl;
    try std.testing.expectEqual(@as(usize, 4), class_decl.body.len);

    for (class_decl.body) |member| {
        try std.testing.expectEqual(ast.ClassMemberKind.method, member.kind);
        try std.testing.expect(member.value != null);
        try std.testing.expect(arena.get(member.value.?).fn_expr.is_async);
    }
}

test "parses contextual keywords as class method names" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\class KeywordNames {
        \\  static() {}
        \\  public() {}
        \\  private() {}
        \\  protected() {}
        \\  readonly() {}
        \\  accessor() {}
        \\  declare() {}
        \\  abstract() {}
        \\  override() {}
        \\}
    ;

    var p = Parser.init(source, "contextual_keyword_methods.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });
    const program_id = try p.parseProgram();

    try std.testing.expect(!diags.hasErrors());

    const program = arena.get(program_id).program;
    const class_decl = arena.get(program.body[0]).class_decl;
    try std.testing.expectEqual(@as(usize, 9), class_decl.body.len);

    for (class_decl.body) |member| {
        try std.testing.expectEqual(ast.ClassMemberKind.method, member.kind);
        try std.testing.expect(!member.is_static);
        try std.testing.expect(member.accessibility == null);
        try std.testing.expect(!member.is_readonly);
        try std.testing.expect(!member.is_abstract);
    }
}

test "parses async keyword-named object methods" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\const iterator = {
        \\  async return() {
        \\    return { value: "finished", done: true };
        \\  },
        \\  async throw(error?: unknown) {
        \\    throw error;
        \\  },
        \\  async if() {}
        \\};
    ;

    var p = Parser.init(source, "async_keyword_object_methods.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });
    _ = try p.parseProgram();

    try std.testing.expect(!diags.hasErrors());
}

test "rejects duplicate class constructor implementations" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\class Aa {
        \\  constructor() {
        \\    return Object.create(new.target.prototype);
        \\  }
        \\
        \\  constructor() {
        \\    this.actualConstructorName = new.target.name;
        \\  }
        \\}
    ;

    var p = Parser.init(source, "duplicate_constructor.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });

    try std.testing.expectError(error.ParseError, p.parseProgram());
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqualStrings("a class may only have one constructor implementation", diags.items.items[0].message);
}

test "allows constructor overload signatures with one implementation" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\class Aa {
        \\  constructor(value: string);
        \\  constructor(value: number);
        \\  constructor(value: string | number) {}
        \\}
    ;

    var p = Parser.init(source, "constructor_overloads.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });
    const program_id = try p.parseProgram();

    try std.testing.expect(!diags.hasErrors());

    const program = arena.get(program_id).program;
    const class_decl = arena.get(program.body[0]).class_decl;
    try std.testing.expectEqual(@as(usize, 3), class_decl.body.len);
    try std.testing.expect(class_decl.body[0].value == null);
    try std.testing.expect(class_decl.body[1].value == null);
    try std.testing.expect(class_decl.body[2].value != null);
}

test "allows static method named constructor with instance constructor" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\class Aa {
        \\  static constructor() {}
        \\  constructor() {}
        \\}
    ;

    var p = Parser.init(source, "static_constructor_method.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });
    const program_id = try p.parseProgram();

    try std.testing.expect(!diags.hasErrors());

    const program = arena.get(program_id).program;
    const class_decl = arena.get(program.body[0]).class_decl;
    try std.testing.expectEqual(@as(usize, 2), class_decl.body.len);
    try std.testing.expect(class_decl.body[0].is_static);
    try std.testing.expect(!class_decl.body[1].is_static);
}

test "rejects duplicate class fields with different accessibility modifiers" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\class Aa {
        \\  private red: string
        \\  public red: string
        \\  protected red: string
        \\}
    ;

    var p = Parser.init(source, "duplicate_class_fields.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });

    try std.testing.expectError(error.ParseError, p.parseProgram());
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqualStrings("duplicate class field declaration", diags.items.items[0].message);
}

test "allows class method overloads with the same name" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\class Reader {
        \\  read(value: string): string;
        \\  read(value: number): number;
        \\  read(value: string | number) {
        \\    return value;
        \\  }
        \\}
    ;

    var p = Parser.init(source, "class_method_overloads.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });

    _ = try p.parseProgram();
    try std.testing.expect(!diags.hasErrors());
}

test "allows instance and static fields with the same name" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\class Aa {
        \\  static red: string
        \\  red: string
        \\}
    ;

    var p = Parser.init(source, "static_and_instance_fields.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });

    _ = try p.parseProgram();
    try std.testing.expect(!diags.hasErrors());
}

test "reports clear error for using in traditional for initializer" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();

    const alloc = backing_alloc.allocator();

    var arena = ast.Arena.init(alloc);
    defer arena.deinit();

    var diags = diagnostics.DiagnosticList{};
    defer diags.items.deinit(alloc);

    const source =
        \\for (using resource = new LoopResource("for-init"); Math.random() > 2; ) {
        \\  resource.use();
        \\}
    ;

    var p = Parser.init(source, "using_plain_for.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });

    try std.testing.expectError(error.ParseError, p.parseProgram());
    try std.testing.expect(diags.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), diags.items.items.len);
    try std.testing.expectEqualStrings(
        "using declarations in for loops are only supported with for...of; use 'for (using name of iterable)' or replace 'using' with 'let'/'const' for a traditional for loop",
        diags.items.items[0].message,
    );
    try std.testing.expectEqualStrings(
        "for (using resource = new LoopResource(\"for-init\"); Math.random() > 2; ) {",
        diags.items.items[0].source_line.?,
    );
}

test "generics: abstract constructor type constraint is stripped" {
    try expectTsOutput(
        \\function classDecorator<T extends abstract new (...args: any[]) => any>(
        \\  value: T,
        \\  context: ClassDecoratorContext<T>,
        \\) {
        \\  context.addInitializer(function () {
        \\    Reflect.defineProperty(value, "decorated", {
        \\      value: true,
        \\      configurable: true
        \\    });
        \\  });
        \\}
    ,
        \\"use strict";
        \\function classDecorator(value, context) {
        \\  context.addInitializer(function () {
        \\    Reflect.defineProperty(value, "decorated", {
        \\      value: true,
        \\      configurable: true
        \\    });
        \\  });
        \\}
    );
}

test "generics: abstract constructor type alias is stripped" {
    try expectTsOutput(
        \\type AbstractCtor<T> = abstract new (...args: any[]) => T;
        \\const ok = true;
    ,
        \\"use strict";
        \\const ok = true;
    );
}

test "ts-support: conditional type with abstract constructor infer is stripped" {
    try expectTsOutput(
        \\type ConstructorArgs<T> =
        \\  T extends abstract new (...args: infer Args) => any ? Args : never;
        \\export const x = 1;
    ,
        \\export const x = 1;
    );
}

// Regression: `async function` in expression position was parsed as a
// declaration (fn_decl), so the IIFE lost its wrapping parens in codegen
// (`(async function(){})()` -> `async function(){}()`, semantically broken).
test "async function IIFE keeps its wrapping parens" {
    const out = try compile(";(async function () {})()");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(async function") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "})()") != null);
}

// Regression: parseTsType used to call checkDepth() without decrementing
// parse_depth, so the recursion counter grew across sequential annotations
// and tripped a spurious "recursion depth exceeded" past max_depth (2048).
test "parser does not leak depth counter across many type annotations" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();
    const alloc = backing_alloc.allocator();

    var src = std.ArrayListUnmanaged(u8).empty;
    const n: usize = 3000; // safely beyond the default max_depth of 2048
    for (0..n) |i| try src.print(alloc, "const a{d}: number = {d};\n", .{ i, i });

    var arena = ast.Arena.init(alloc);
    var diags = diagnostics.DiagnosticList{};

    var p = Parser.init(src.items, "depth_types.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });

    _ = try p.parseProgram();
    try std.testing.expect(!diags.hasErrors());
}

// Regression: same missing-decrement bug in parseBindingPattern.
test "parser does not leak depth counter across many binding patterns" {
    var backing_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer backing_alloc.deinit();
    const alloc = backing_alloc.allocator();

    var src = std.ArrayListUnmanaged(u8).empty;
    const n: usize = 3000;
    for (0..n) |i| try src.print(alloc, "const [a{d}] = arr;\n", .{i});

    var arena = ast.Arena.init(alloc);
    var diags = diagnostics.DiagnosticList{};

    var p = Parser.init(src.items, "depth_patterns.ts", &arena, alloc, &diags, .{
        .typescript = true,
        .jsx = false,
        .source_type = .module,
    });

    _ = try p.parseProgram();
    try std.testing.expect(!diags.hasErrors());
}
