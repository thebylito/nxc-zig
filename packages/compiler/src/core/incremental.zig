const std = @import("std");
const cache = @import("cache");
const compiler = @import("compiler");
const config = @import("config");
const diagnostics = @import("diagnostics");

const CacheEntry = cache.CacheEntry;
const CacheStore = cache.CacheStore;
const Config = config.Config;
const CompileResult = compiler.CompileResult;
const Diagnostic = diagnostics.Diagnostic;

pub const IncrementalCompiler = struct {
    cache: CacheStore,
    config: Config,

    pub fn init(cache_dir: []const u8, cfg: Config) IncrementalCompiler {
        return .{
            .cache = CacheStore.init(cache_dir),
            .config = cfg,
        };
    }

    pub fn compileFile(
        self: *IncrementalCompiler,
        path: []const u8,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) !CompileResult {
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, std.Io.Limit.limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.StreamTooLong => return error.FileTooLarge,
            else => return err,
        };
        defer alloc.free(source);

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(source);
        const source_hash = hasher.final();

        if (self.cache.get(path)) |entry| {
            if (entry.source_hash == source_hash) {
                const result = loadCachedOutput(path, io, alloc) catch {
                    return self.compileAndCache(path, source_hash, io, alloc);
                };
                return result;
            }
        }

        return self.compileAndCache(path, source_hash, io, alloc);
    }

    fn compileAndCache(
        self: *IncrementalCompiler,
        path: []const u8,
        source_hash: u64,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) !CompileResult {
        const result = try compiler.compileFile(path, self.config, io, alloc);

        var out_hasher = std.hash.Wyhash.init(0);
        out_hasher.update(result.code);
        if (result.map) |m| out_hasher.update(m);
        if (result.declarations) |d| out_hasher.update(d);
        const output_hash = out_hasher.final();

        const ts = std.Io.Timestamp.now(io, .realtime);
        const entry = CacheEntry{
            .source_hash = source_hash,
            .deps = try alloc.dupe(u8, ""),
            .dep_hashes = try alloc.dupe(u64, &.{}),
            .output_hash = output_hash,
            .last_modified = ts.nanoseconds,
            .source_path = try alloc.dupe(u8, path),
        };
        try self.cache.put(alloc, path, entry);

        return result;
    }

    pub fn deinit(self: *IncrementalCompiler, io: std.Io, alloc: std.mem.Allocator) void {
        self.cache.save(io, alloc) catch {};
        self.cache.deinit(alloc);
    }

    pub fn load(self: *IncrementalCompiler, io: std.Io, alloc: std.mem.Allocator) !void {
        try self.cache.load(io, alloc);
    }

    pub fn save(self: *IncrementalCompiler, io: std.Io, alloc: std.mem.Allocator) !void {
        try self.cache.save(io, alloc);
    }
};

fn loadCachedOutput(path: []const u8, io: std.Io, alloc: std.mem.Allocator) !CompileResult {
    const js_path = jsPathFromSourcePath(path, alloc);
    defer alloc.free(js_path);

    const code = std.Io.Dir.cwd().readFileAlloc(io, js_path, alloc, std.Io.Limit.limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.StreamTooLong => return error.FileTooLarge,
        else => return err,
    };
    errdefer alloc.free(code);

    const map_path = try std.fmt.allocPrint(alloc, "{s}.map", .{js_path});
    defer alloc.free(map_path);
    const map = std.Io.Dir.cwd().readFileAlloc(io, map_path, alloc, std.Io.Limit.limited(64 * 1024 * 1024)) catch null;
    errdefer if (map) |m| alloc.free(m);

    const decl_path = try compiler.declarationPathFromJsPath(alloc, js_path);
    defer alloc.free(decl_path);
    const declarations = std.Io.Dir.cwd().readFileAlloc(io, decl_path, alloc, std.Io.Limit.limited(64 * 1024 * 1024)) catch null;
    errdefer if (declarations) |d| alloc.free(d);

    return CompileResult{
        .code = code,
        .map = map,
        .declarations = declarations,
        .diagnostics = try alloc.dupe(Diagnostic, &.{}),
    };
}

fn jsPathFromSourcePath(path: []const u8, alloc: std.mem.Allocator) []u8 {
    if (std.mem.endsWith(u8, path, ".ts")) {
        return std.fmt.allocPrint(alloc, "{s}.js", .{path[0 .. path.len - 3]}) catch unreachable;
    }
    if (std.mem.endsWith(u8, path, ".tsx")) {
        return std.fmt.allocPrint(alloc, "{s}.js", .{path[0 .. path.len - 4]}) catch unreachable;
    }
    if (std.mem.endsWith(u8, path, ".mts")) {
        return std.fmt.allocPrint(alloc, "{s}.mjs", .{path[0 .. path.len - 4]}) catch unreachable;
    }
    if (std.mem.endsWith(u8, path, ".cts")) {
        return std.fmt.allocPrint(alloc, "{s}.cjs", .{path[0 .. path.len - 4]}) catch unreachable;
    }
    return std.fmt.allocPrint(alloc, "{s}.js", .{path}) catch unreachable;
}
