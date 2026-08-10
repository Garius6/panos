const std = @import("std");
const ast = @import("ast.zig");
const diagnostic = @import("diagnostic.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const resolver = @import("resolver.zig");
const source = @import("source.zig");

pub const Module = struct {
    file: source.SourceFile,
    tree: ast.Ast,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        self.tree.deinit();
        allocator.free(@constCast(self.file.bytes));
        self.* = undefined;
    }
};

pub const Import = struct {
    importer: usize,
    declaration: ast.DeclId,
    target: ?usize,
    alias: []const u8,
    span: source.Span,
    // Set when `target == null` because this import resolved to a native
    // builtin module (see `resolveAndLoadImport`) instead of failing —
    // holds the module's REAL name (e.g. "ввод_вывод"), which may differ
    // from `alias` (`импорт "ввод_вывод" как ио"`). `module_linker.zig`
    // uses this to bind the alias to the native module's exports, same as
    // it already does for a real file target — without it, an ALIASED
    // native import resolved with no diagnostic (correct) but then the
    // alias itself was never bound to anything (`Resolve Error:
    // неопределённое имя 'ио'`), a real gap found auditing panosiki's
    // `std/слог.ps` (`импорт "ввод_вывод" как ио`).
    native_module: ?[]const u8 = null,
};

pub const ExportKind = enum {
    function,
    constant,
    type,
};

pub const Export = struct {
    module: usize,
    declaration: ast.DeclId,
    name: []const u8,
    kind: ExportKind,
    span: source.Span,
};

// Methods declared via a same-file `реализация Тип ... конец` block (plain
// or interface) on an exported owner type — separate from `Export` because a
// method is never reachable by a qualified name (`модуль.метод`), only by
// dispatch on a value of the owner's nominal type.
pub const MethodExport = struct {
    module: usize,
    owner_declaration: ast.DeclId,
    declaration: ast.DeclId,
    name: []const u8,
    span: source.Span,
};

// Variants of an exported enum type — construction/matching is entirely
// name-string-based at compile time (`compiler.zig`'s `enumVariantName`
// builds "Owner.Variant" from the owner symbol's own `.name`), so no
// declaration/FunctionId re-hosting is needed, only the variant's bare name.
pub const VariantExport = struct {
    module: usize,
    owner_declaration: ast.DeclId,
    name: []const u8,
    span: source.Span,
};

// A same-file `реализация Интерфейс для Тип ... конец` block on an exported
// owner type — needed separately from `MethodExport` because interface-bound
// generic dispatch (`T: Сравниваемое`) requires the owner's
// `InterfaceImplementation` entry itself, not just its methods (which
// `MethodExport` already covers as ordinary inherent methods).
pub const ImplExport = struct {
    module: usize,
    owner_declaration: ast.DeclId,
    interface_name: []const u8,
    span: source.Span,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    modules: std.ArrayList(Module) = .empty,
    module_indices: std.StringHashMap(usize),
    loading: std.StringHashMap(void),
    order: std.ArrayList(usize) = .empty,
    imports: std.ArrayList(Import) = .empty,
    exports: std.ArrayList(Export) = .empty,
    methods: std.ArrayList(MethodExport) = .empty,
    variants: std.ArrayList(VariantExport) = .empty,
    impls: std.ArrayList(ImplExport) = .empty,
    diagnostics: diagnostic.DiagnosticList = .{},
    // `PANOS_STDLIB` env dir + the `std/` next to the running `panos`
    // binary, in that priority order, checked AFTER same-directory and
    // `модули/` — set by the caller (`zig/cli/main.zig`) before `.load()`,
    // empty by default so every existing test/synthetic-reader caller
    // (which has no such directories to offer) keeps its exact current
    // behavior. See `docs/src/getting-started/installation.md` §"Поиск
    // модулей" for the full documented 4-tier contract this implements —
    // real gap found auditing panosiki: NONE of tiers 2-4 (nor the
    // native-module fallback below) existed before this, only tier 1
    // (same directory) did, silently breaking every multi-file program
    // that imports a real stdlib module by bare name.
    global_search_roots: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) Graph {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .module_indices = .init(allocator),
            .loading = .init(allocator),
        };
    }

    pub fn deinit(self: *Graph) void {
        for (self.modules.items) |*module| module.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        self.impls.deinit(self.allocator);
        self.variants.deinit(self.allocator);
        self.methods.deinit(self.allocator);
        self.exports.deinit(self.allocator);
        self.imports.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.loading.deinit();
        self.module_indices.deinit();
        self.modules.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn moduleForPath(self: *const Graph, path: []const u8) ?*const Module {
        const index = self.module_indices.get(path) orelse return null;
        return &self.modules.items[index];
    }

    pub fn moduleForFile(self: *const Graph, file_id: source.FileId) ?*const Module {
        const index: usize = file_id;
        if (index >= self.modules.items.len) return null;
        return &self.modules.items[index];
    }

    pub fn importForDeclaration(self: *const Graph, importer: usize, declaration: ast.DeclId) ?Import {
        for (self.imports.items) |entry| {
            if (entry.importer == importer and entry.declaration == declaration) return entry;
        }
        return null;
    }

    pub fn exportForName(self: *const Graph, module: usize, name: []const u8) ?Export {
        for (self.exports.items) |entry| {
            if (entry.module == module and std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    // Bare (extension-less) entry paths get the same `.pns`-then-`.ps`
    // try-both treatment as bare `импорт` names (`appendCandidateBothSuffixes`)
    // — otherwise an unmigrated `.ps`-only project passed as `panos run
    // проект/main` (no explicit extension) would resolve straight to a
    // nonexistent `main.pns` and fail. An entry path with an explicit
    // extension resolves once, as given.
    pub fn load(self: *Graph, reader: anytype, entry_path: []const u8) !void {
        if (hasKnownSourceExtension(entry_path)) {
            const canonical_path = try resolveImportPath(self.allocator, entry_path, "", ".pns");
            defer self.allocator.free(canonical_path);
            _ = try self.loadRecursive(reader, canonical_path, null);
            return;
        }

        const pns_path = try resolveImportPath(self.allocator, entry_path, "", ".pns");
        defer self.allocator.free(pns_path);
        if (self.tryLoadSilently(reader, pns_path, null)) |_| {
            return;
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        const ps_path = try resolveImportPath(self.allocator, entry_path, "", ".ps");
        defer self.allocator.free(ps_path);
        _ = try self.loadRecursive(reader, ps_path, null);
    }

    // Appends embedded prelude source as a module with NO explicit `импорт`
    // — takes the next available file_id, appended AFTER every module
    // already loaded via `load()`, so existing diagnostics' `file_id`
    // expectations for real modules are never shifted. Prepended to
    // `order` (not appended) so it compiles before every real module, which
    // implicitly depends on it. Reuses `collectExports`/`collectMethods`
    // exactly as a real file would, so its types/methods/interfaces flow
    // through the same cross-module machinery — only the merge itself
    // (unqualified, no `импорт` alias) is special-cased, in
    // `module_linker.zig`.
    pub fn appendPreludeModule(self: *Graph, source_text: []const u8) !usize {
        const bytes = try self.allocator.dupe(u8, source_text);
        var owns_bytes = true;
        errdefer if (owns_bytes) self.allocator.free(bytes);

        if (self.modules.items.len > std.math.maxInt(source.FileId)) return error.ModuleLimitReached;
        const file_id: source.FileId = @intCast(self.modules.items.len);
        const stored_path = try self.arena.allocator().dupe(u8, "@prelude");
        const file = source.SourceFile.init(file_id, stored_path, bytes);

        var lexed = try lexer.tokenize(self.allocator, bytes, file_id);
        defer lexed.deinit();
        try self.appendDiagnostics(&lexed.diagnostics);

        var parsed = try parser.parse(self.allocator, lexed.tokens.items);
        errdefer parsed.deinit();
        try self.appendDiagnostics(&parsed.diagnostics);
        const tree = parsed.ast;
        parsed.ast = ast.Ast.init(self.allocator);
        parsed.deinit();
        owns_bytes = false;

        const index = self.modules.items.len;
        try self.modules.append(self.allocator, .{ .file = file, .tree = tree });
        try self.module_indices.put(stored_path, index);
        try self.collectExports(index);
        try self.collectMethods(index);
        try self.order.insert(self.allocator, 0, index);
        return index;
    }

    fn loadRecursive(self: *Graph, reader: anytype, path: []const u8, importer_span: ?source.Span) anyerror!?usize {
        if (self.loading.contains(path)) {
            try self.report(importer_span orelse .{ .file_id = 0, .start = 0, .end = 0 }, "Module Loader Error: обнаружен циклический импорт '{s}'", .{path});
            return null;
        }
        if (self.module_indices.get(path)) |existing| return existing;

        try self.loading.put(path, {});
        defer _ = self.loading.remove(path);

        const bytes = reader.read(self.allocator, path) catch |err| {
            try self.report(importer_span orelse .{ .file_id = 0, .start = 0, .end = 0 }, "Module Loader Error: не удалось загрузить модуль '{s}': {s}", .{ path, @errorName(err) });
            return null;
        };
        return try self.registerModule(reader, path, bytes);
    }

    // Same as `loadRecursive`, but a read failure PROPAGATES instead of
    // being reported — used only by `resolveAndLoadImport`'s fallback
    // chain, which needs to try the next search-root candidate silently
    // and only report once EVERY candidate has failed (or fall back to a
    // native builtin module, which needs no diagnostic at all). A cyclic
    // import is still reported directly here — trying a different search
    // root can never resolve a real cycle, so there is no "next candidate"
    // that would help.
    fn tryLoadSilently(self: *Graph, reader: anytype, path: []const u8, importer_span: ?source.Span) anyerror!?usize {
        if (self.loading.contains(path)) {
            try self.report(importer_span orelse .{ .file_id = 0, .start = 0, .end = 0 }, "Module Loader Error: обнаружен циклический импорт '{s}'", .{path});
            return null;
        }
        if (self.module_indices.get(path)) |existing| return existing;

        try self.loading.put(path, {});
        defer _ = self.loading.remove(path);

        const bytes = try reader.read(self.allocator, path);
        return try self.registerModule(reader, path, bytes);
    }

    // Lex/parse/register a module whose SOURCE BYTES are already read —
    // shared by `loadRecursive` (entry file, reports on its own read
    // failure) and `tryLoadSilently` (import fallback candidates, read
    // failure already propagated by the caller). Recurses into `path`'s
    // OWN imports via `resolveAndLoadImport`, not directly into
    // `loadRecursive`/`tryLoadSilently` — every nested import gets the
    // full search-path fallback too, not just the entry file's direct
    // imports.
    fn registerModule(self: *Graph, reader: anytype, path: []const u8, bytes: []u8) anyerror!usize {
        var owns_bytes = true;
        errdefer if (owns_bytes) self.allocator.free(bytes);

        if (self.modules.items.len > std.math.maxInt(source.FileId)) return error.ModuleLimitReached;
        const file_id: source.FileId = @intCast(self.modules.items.len);
        const stored_path = try self.arena.allocator().dupe(u8, path);
        const file = source.SourceFile.init(file_id, stored_path, bytes);

        var lexed = try lexer.tokenize(self.allocator, bytes, file_id);
        defer lexed.deinit();
        try self.appendDiagnostics(&lexed.diagnostics);

        var parsed = try parser.parse(self.allocator, lexed.tokens.items);
        errdefer parsed.deinit();
        try self.appendDiagnostics(&parsed.diagnostics);
        var tree = parsed.ast;
        parsed.ast = ast.Ast.init(self.allocator);
        parsed.deinit();
        var owns_tree = true;
        errdefer if (owns_tree) tree.deinit();

        const index = self.modules.items.len;
        try self.modules.append(self.allocator, .{ .file = file, .tree = tree });
        owns_bytes = false;
        owns_tree = false;
        errdefer {
            var module = self.modules.pop().?;
            module.deinit(self.allocator);
        }
        try self.module_indices.put(stored_path, index);
        try self.collectExports(index);
        try self.collectMethods(index);

        const declarations = self.modules.items[index].tree.program.?.declarations;
        for (declarations) |declaration| {
            const import = switch (self.modules.items[index].tree.decl(declaration).*) {
                .import => |value| value,
                else => continue,
            };
            const resolved = try self.resolveAndLoadImport(reader, import.path, stored_path, import.span);
            try self.imports.append(self.allocator, .{
                .importer = index,
                .declaration = declaration,
                .target = resolved.target,
                .alias = import.alias orelse moduleBaseName(import.path),
                .span = import.span,
                .native_module = resolved.native_module,
            });
        }
        try self.order.append(self.allocator, index);
        return index;
    }

    // The documented 4-tier search (`docs/src/getting-started/
    // installation.md` §"Поиск модулей"): same directory as the importer,
    // then `модули/` next to the importer, then each of
    // `global_search_roots` in order (`$PANOS_STDLIB`, `std/` next to the
    // `panos` binary — populated by `zig/cli/main.zig`, empty for every
    // other caller, which keeps their exact previous single-tier
    // behavior). If NONE of those have the file AND the bare import name
    // matches a registered native builtin module (`resolver.
    // native_builtin_modules` — the SAME list `installBuiltins` uses, so
    // the two can never drift apart), this resolves to `null` with NO
    // diagnostic — the module is already ambiently available without a
    // file at all, exactly like calling it without ever writing `импорт`
    // in the first place. A genuinely missing module (not native, not
    // found anywhere) reports the SAME "FileNotFound" message the single-
    // tier version always did, against the same-directory candidate (so
    // existing diagnostic-text assertions keep matching).
    const ImportResolution = struct { target: ?usize, native_module: ?[]const u8 = null };

    // Bare (extension-less) import names get tried as `.pns` first, then
    // `.ps` — the FileNotFound-tolerant candidate loop in
    // `resolveAndLoadImport` already treats "not found" as "try the next
    // candidate", so this reuses that machinery rather than adding a
    // second resolution pass. An import path that already names an
    // extension explicitly resolves once, as given (no `.ps` file ever
    // gets probed for an explicit `.pns` import or vice versa).
    fn appendCandidateBothSuffixes(self: *Graph, candidates: *std.ArrayList([]u8), raw_path: []const u8, importer_path: []const u8) !void {
        try candidates.append(self.allocator, try resolveImportPath(self.allocator, raw_path, importer_path, ".pns"));
        if (!hasKnownSourceExtension(raw_path)) {
            try candidates.append(self.allocator, try resolveImportPath(self.allocator, raw_path, importer_path, ".ps"));
        }
    }

    fn resolveAndLoadImport(self: *Graph, reader: anytype, raw_import_path: []const u8, importer_path: []const u8, importer_span: ?source.Span) anyerror!ImportResolution {
        var candidates: std.ArrayList([]u8) = .empty;
        defer {
            for (candidates.items) |candidate| self.allocator.free(candidate);
            candidates.deinit(self.allocator);
        }

        try self.appendCandidateBothSuffixes(&candidates, raw_import_path, importer_path);

        const importer_dir = moduleDirectory(importer_path);
        const modules_relative = if (importer_dir.len != 0)
            try std.fmt.allocPrint(self.allocator, "{s}/модули/{s}", .{ importer_dir, raw_import_path })
        else
            try std.fmt.allocPrint(self.allocator, "модули/{s}", .{raw_import_path});
        defer self.allocator.free(modules_relative);
        try self.appendCandidateBothSuffixes(&candidates, modules_relative, "");

        for (self.global_search_roots) |root| {
            const combined = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ root, raw_import_path });
            defer self.allocator.free(combined);
            try self.appendCandidateBothSuffixes(&candidates, combined, "");
        }

        for (candidates.items) |candidate| {
            if (self.tryLoadSilently(reader, candidate, importer_span)) |result| {
                return .{ .target = result };
            } else |err| {
                if (err != error.FileNotFound) return err;
            }
        }

        if (isBareModuleName(raw_import_path) and isNativeBuiltinModule(raw_import_path)) {
            return .{ .target = null, .native_module = try self.arena.allocator().dupe(u8, raw_import_path) };
        }

        try self.report(importer_span orelse .{ .file_id = 0, .start = 0, .end = 0 }, "Module Loader Error: не удалось загрузить модуль '{s}': FileNotFound", .{candidates.items[0]});
        return .{ .target = null };
    }

    fn collectExports(self: *Graph, module: usize) !void {
        const tree = &self.modules.items[module].tree;
        for (tree.program.?.declarations) |declaration| {
            const entry: ?Export = switch (tree.decl(declaration).*) {
                .function => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .function,
                    .span = value.name_span,
                } else null,
                .constant => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .constant,
                    .span = value.name_span,
                } else null,
                .struct_decl => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .type,
                    .span = value.span,
                } else null,
                .interface_decl => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .type,
                    .span = value.span,
                } else null,
                .enum_decl => |value| if (value.is_exported) blk: {
                    for (value.variants) |variant| {
                        try self.variants.append(self.allocator, .{
                            .module = module,
                            .owner_declaration = declaration,
                            .name = variant.name,
                            .span = variant.span,
                        });
                    }
                    break :blk .{
                        .module = module,
                        .declaration = declaration,
                        .name = value.name,
                        .kind = .type,
                        .span = value.span,
                    };
                } else null,
                .type_alias => |value| if (value.is_exported) .{
                    .module = module,
                    .declaration = declaration,
                    .name = value.name,
                    .kind = .type,
                    .span = value.span,
                } else null,
                else => null,
            };
            if (entry) |value| try self.exports.append(self.allocator, value);
        }
    }

    // Same-file impl blocks (plain OR interface) on an exported owner type:
    // methods are reachable cross-module by dispatch on the owner's value,
    // never by a qualified name, so they never enter `exports` — only
    // `methods`. Interface-impl methods are ordinary inherent methods too
    // (`defineMethodSignature`/`self.result.methods` in type_checker.zig
    // doesn't distinguish), so they're collected here the same way. Also
    // records `ImplExport` for interface-based impls — needed separately for
    // interface-bound generic dispatch (`T: Сравниваемое`) across modules.
    fn collectMethods(self: *Graph, module: usize) !void {
        const tree = &self.modules.items[module].tree;
        for (tree.program.?.declarations) |declaration| {
            const implementation = switch (tree.decl(declaration).*) {
                .impl => |value| value,
                else => continue,
            };
            if (implementation.target_module != null) continue;
            const owner_declaration = self.findExportedTypeDeclaration(module, implementation.target_type) orelse continue;
            for (implementation.methods) |method_declaration| {
                const function = tree.decl(method_declaration).function;
                try self.methods.append(self.allocator, .{
                    .module = module,
                    .owner_declaration = owner_declaration,
                    .declaration = method_declaration,
                    .name = function.name,
                    .span = function.span,
                });
            }
            if (implementation.interface_name) |interface_name| {
                if (implementation.interface_module == null) {
                    try self.impls.append(self.allocator, .{
                        .module = module,
                        .owner_declaration = owner_declaration,
                        .interface_name = interface_name,
                        .span = implementation.span,
                    });
                }
            }
        }
    }

    fn findExportedTypeDeclaration(self: *const Graph, module: usize, name: []const u8) ?ast.DeclId {
        for (self.exports.items) |exported| {
            if (exported.module != module or exported.kind != .type) continue;
            if (std.mem.eql(u8, exported.name, name)) return exported.declaration;
        }
        return null;
    }

    fn appendDiagnostics(self: *Graph, values: *const diagnostic.DiagnosticList) !void {
        for (values.items.items) |value| {
            const message = try self.arena.allocator().dupe(u8, value.message);
            _ = try self.diagnostics.appendUnique(self.allocator, .{
                .phase = value.phase,
                .severity = value.severity,
                .span = value.span,
                .message = message,
            });
        }
    }

    fn report(self: *Graph, span: source.Span, comptime format: []const u8, arguments: anytype) !void {
        const message = try std.fmt.allocPrint(self.arena.allocator(), format, arguments);
        _ = try self.diagnostics.appendUnique(self.allocator, .{
            .phase = .parser,
            .severity = .err,
            .span = span,
            .message = message,
        });
    }
};

// `.pns` is the primary source extension; `.ps` is accepted permanently
// for backward compatibility (pre-migration files, unmigrated panosiki
// packages) — GitHub Linguist misclassifies `.ps` as PostScript, `.pns`
// doesn't collide with any registered language. An import path that
// already names either extension explicitly is never re-suffixed;
// `preferred_suffix` only applies to bare names (`импорт "модуль"`).
fn hasKnownSourceExtension(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".ps") or std.mem.endsWith(u8, path, ".pns");
}

pub fn resolveImportPath(allocator: std.mem.Allocator, import_path: []const u8, importer_path: []const u8, preferred_suffix: []const u8) ![]u8 {
    const suffixed = if (hasKnownSourceExtension(import_path))
        import_path
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ import_path, preferred_suffix });
    defer if (suffixed.ptr != import_path.ptr) allocator.free(suffixed);

    const combined = if (isAbsolute(suffixed) or importer_path.len == 0) suffixed else blk: {
        const directory = moduleDirectory(importer_path);
        if (directory.len == 0) break :blk suffixed;
        break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, suffixed });
    };
    defer if (combined.ptr != suffixed.ptr) allocator.free(combined);
    return normalizePath(allocator, combined);
}

fn isBareModuleName(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '/') == null;
}

fn isNativeBuiltinModule(name: []const u8) bool {
    for (resolver.native_builtin_modules) |native| {
        if (std.mem.eql(u8, name, native)) return true;
    }
    return false;
}

fn isAbsolute(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

fn moduleDirectory(path: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "";
    return path[0..separator];
}

fn moduleBaseName(path: []const u8) []const u8 {
    const file_name = if (std.mem.lastIndexOfScalar(u8, path, '/')) |separator| path[separator + 1 ..] else path;
    if (std.mem.endsWith(u8, file_name, ".pns")) return file_name[0 .. file_name.len - 4];
    if (std.mem.endsWith(u8, file_name, ".ps")) return file_name[0 .. file_name.len - 3];
    return file_name;
}

fn normalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const absolute = isAbsolute(path);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var start: usize = 0;
    var index: usize = 0;
    while (index <= path.len) : (index += 1) {
        if (index != path.len and path[index] != '/') continue;
        const part = path[start..index];
        start = index + 1;
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len != 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else if (!absolute) {
                try parts.append(allocator, part);
            }
            continue;
        }
        try parts.append(allocator, part);
    }

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    if (absolute) try result.append(allocator, '/');
    for (parts.items, 0..) |part, part_index| {
        if (part_index != 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }
    if (result.items.len == 0) try result.append(allocator, '.');
    return result.toOwnedSlice(allocator);
}

const MemoryReader = struct {
    files: []const File,

    const File = struct {
        path: []const u8,
        bytes: []const u8,
    };

    fn read(self: *const MemoryReader, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) return allocator.dupe(u8, file.bytes);
        }
        return error.FileNotFound;
    }
};

test "module loader orders local imports before their importers" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./арифметика\"\nэкспорт функ старт() -> Число\nарифметика.ответ()\nконец" },
        .{ .path = "проект/арифметика.ps", .bytes = "импорт \"./детали/числа\"\nэкспорт функ ответ() -> Число\nчисла.значение()\nконец" },
        .{ .path = "проект/детали/числа.ps", .bytes = "экспорт функ значение() -> Число\n42\nконец" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.load(&reader, "проект/./main");

    try std.testing.expectEqual(@as(usize, 3), graph.modules.items.len);
    try std.testing.expectEqual(@as(usize, 3), graph.order.items.len);
    try std.testing.expectEqualStrings("проект/детали/числа.ps", graph.modules.items[graph.order.items[0]].file.path);
    try std.testing.expectEqualStrings("проект/арифметика.ps", graph.modules.items[graph.order.items[1]].file.path);
    try std.testing.expectEqualStrings("проект/main.ps", graph.modules.items[graph.order.items[2]].file.path);
    try std.testing.expectEqual(@as(usize, 2), graph.imports.items.len);
    try std.testing.expectEqualStrings("арифметика", graph.imports.items[1].alias);
    try std.testing.expectEqual(@as(?usize, 1), graph.imports.items[1].target);
    const answer = graph.exportForName(1, "ответ").?;
    try std.testing.expectEqual(ExportKind.function, answer.kind);
    try std.testing.expectEqual(@as(usize, 1), answer.module);
    try std.testing.expectEqual(@as(usize, 3), graph.exports.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.diagnostics.items.items.len);
}

test "module loader collects methods only for an exported same-file impl owner" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Число\n1\nконец" },
        .{ .path = "проект/точки.ps", .bytes = "экспорт тип Точка = структура\nx: Число\nконец\nтип Скрытая = структура\ny: Число\nконец\nреализация Точка\nфунк увеличить(это: Точка) -> Число\nэто.x + 1\nконец\nконец\nреализация Скрытая\nфунк читать(это: Скрытая) -> Число\nэто.y\nконец\nконец" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    try graph.load(&reader, "проект/точки");

    try std.testing.expectEqual(@as(usize, 1), graph.methods.items.len);
    try std.testing.expectEqualStrings("увеличить", graph.methods.items[0].name);
}

test "module loader collects variants only for an exported enum type" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Число\n1\nконец" },
        .{ .path = "проект/цвета.ps", .bytes = "экспорт тип Цвет = перечисление\nКрасный\nЗелёный\nконец\nтип Скрытый = перечисление\nОдин\nконец" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    try graph.load(&reader, "проект/цвета");

    try std.testing.expectEqual(@as(usize, 2), graph.variants.items.len);
    try std.testing.expectEqualStrings("Красный", graph.variants.items[0].name);
    try std.testing.expectEqualStrings("Зелёный", graph.variants.items[1].name);
}

test "module loader reports import cycles at the importing declaration" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "a.ps", .bytes = "импорт \"b\"" },
        .{ .path = "b.ps", .bytes = "импорт \"a\"" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.load(&reader, "a");

    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Module Loader Error: обнаружен циклический импорт 'a.ps'", graph.diagnostics.items.items[0].message);
    try std.testing.expectEqual(@as(source.FileId, 1), graph.diagnostics.items.items[0].span.file_id);
}

test "module loader reports missing local modules" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "импорт \"./нет\"" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.load(&reader, "проект/main.ps");

    try std.testing.expectEqual(@as(usize, 1), graph.diagnostics.items.items.len);
    try std.testing.expectEqualStrings("Module Loader Error: не удалось загрузить модуль 'проект/нет.pns': FileNotFound", graph.diagnostics.items.items[0].message);
    try std.testing.expectEqual(@as(source.FileId, 0), graph.diagnostics.items.items[0].span.file_id);
}

test "module loader normalizes relative import paths" {
    const path = try resolveImportPath(std.testing.allocator, "./детали/../математика", "проект/main.ps", ".ps");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("проект/математика.ps", path);
}

test "module loader normalizes relative import paths with .pns suffix" {
    const path = try resolveImportPath(std.testing.allocator, "./детали/../математика", "проект/main.pns", ".pns");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("проект/математика.pns", path);
}

test "module loader appends a prelude module after real modules without shifting their file_ids" {
    const reader = MemoryReader{ .files = &.{
        .{ .path = "проект/main.ps", .bytes = "экспорт функ старт() -> Число\n1\nконец" },
    } };
    var graph = Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.load(&reader, "проект/main");
    try std.testing.expectEqual(@as(usize, 1), graph.modules.items.len);

    const prelude_index = try graph.appendPreludeModule("экспорт тип Штука = структура\nx: Число\nконец");
    try std.testing.expectEqual(@as(usize, 1), prelude_index);
    try std.testing.expectEqual(@as(usize, 2), graph.modules.items.len);
    try std.testing.expectEqual(@as(source.FileId, 0), graph.modules.items[0].file.id);
    try std.testing.expectEqual(@as(source.FileId, 1), graph.modules.items[1].file.id);
    try std.testing.expectEqual(@as(usize, 2), graph.order.items.len);
    try std.testing.expectEqual(prelude_index, graph.order.items[0]);
    try std.testing.expectEqual(@as(usize, 0), graph.order.items[1]);
}
