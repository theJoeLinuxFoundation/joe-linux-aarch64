//! The package manifest: the first member of every `.dave` archive and the
//! record kept in the installed database.
//!
//! The manifest is authoritative for every piece of file metadata. The archive
//! payload carries regular-file contents only; directories, symlinks, hard
//! links, modes and ownership are created from this description.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const arch = @import("arch.zig");

pub const current_format: u32 = 1;

pub const FileKind = enum { file, dir, symlink, hardlink };

pub const File = struct {
    /// Path relative to the root, without a leading slash.
    path: []const u8,
    kind: FileKind = .file,
    mode: u32 = 0o644,
    owner: []const u8 = "root",
    group: []const u8 = "root",
    size: u64 = 0,
    /// Lower-case hex SHA-256 of the contents (regular files).
    sha256: ?[]const u8 = null,
    /// Symlink target, or the path of the file a hard link refers to.
    target: ?[]const u8 = null,
    /// A configuration file: local edits are preserved across upgrades.
    config: bool = false,
    /// File capabilities, as the raw `security.capability` value in hex.
    caps: ?[]const u8 = null,
    /// Lower-case hex fs-verity digest of the contents (sealed files).
    verity: ?[]const u8 = null,
    /// Lower-case hex signature binding `verity` to the operations the
    /// package declares for this file; see seal.zig.
    seal: ?[]const u8 = null,
};

/// What privileged programs of a package declare they do. The security module
/// holds each program to its declaration.
pub const Operations = struct {
    /// Paths of the programs this entry is for; empty means every file of the
    /// package that no other entry names.
    programs: []const []const u8 = &.{},
    /// `all`, `net`, `mount`, `module`, `ptrace`, `bpf`, `root-ipc`, `none`,
    /// `cap:<name>`, `write:<path prefix>`, `exec:<path>`; `*` stands for any
    /// in the last three. A file no entry covers is `undeclared`.
    allow: []const []const u8 = &.{},
};

pub const Manifest = struct {
    format: u32 = current_format,
    name: []const u8,
    version: []const u8,
    /// What the package is for. A package made by dave names the
    /// architecture dave manages (arch.name); one that names none is for
    /// x86_64, which is what every package was before dave knew another.
    arch: []const u8 = arch.unstated,
    description: []const u8 = "",
    license: []const u8 = "",
    /// Each entry is `name` or `name constraint`, e.g. `glibc >=2.44`.
    depends: []const []const u8 = &.{},
    conflicts: []const []const u8 = &.{},
    operations: []const Operations = &.{},
    files: []const File = &.{},

    pub const ParseError = Allocator.Error || error{InvalidManifest};

    /// Parses ZON text. All strings are allocated in `arena`.
    pub fn parse(arena: Allocator, source: []const u8) ParseError!Manifest {
        const m = try parseZon(Manifest, arena, source);
        if (m.format > current_format) return error.InvalidManifest;
        if (!validName(m.name)) return error.InvalidManifest;
        for (m.files) |f| if (!validPath(f.path)) return error.InvalidManifest;
        return m;
    }

    pub fn write(m: Manifest, w: *Io.Writer) Io.Writer.Error!void {
        try std.zon.stringify.serialize(m, .{ .emit_default_optional_fields = false }, w);
        try w.writeByte('\n');
    }

    /// The bytes its regular files take; a hard link adds nothing.
    pub fn installedSize(m: Manifest) u64 {
        var total: u64 = 0;
        for (m.files) |f| {
            if (f.kind == .file) total += f.size;
        }
        return total;
    }

    /// `name-version-arch.dave`
    pub fn fileName(m: Manifest, arena: Allocator) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(arena, "{s}-{s}-{s}.dave", .{ m.name, m.version, m.arch });
    }
};

/// Parses any ZON document into `T`, ignoring fields this version does not know.
pub fn parseZon(comptime T: type, arena: Allocator, source: []const u8) (Allocator.Error || error{InvalidManifest})!T {
    const text = try arena.dupeSentinel(u8, source, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{
        .gpa = arena,
        .arena = arena,
        .source = text,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ParseZon => error.InvalidManifest,
    };
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (!std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '+' and c != '.') return false;
    }
    return true;
}

/// A manifest path must stay inside the root it is installed into.
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return std.mem.indexOfScalar(u8, path, 0) == null;
}

/// Splits a dependency string into the package name and its constraint text.
pub fn splitDependency(dep: []const u8) struct { name: []const u8, constraint: []const u8 } {
    const trimmed = std.mem.trim(u8, dep, " ");
    const end = std.mem.indexOfAny(u8, trimmed, " <>=") orelse trimmed.len;
    return .{ .name = trimmed[0..end], .constraint = std.mem.trim(u8, trimmed[end..], " ") };
}

const testing = std.testing;

test "round trip" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original: Manifest = .{
        .name = "hello",
        .version = "1.0-r1",
        .description = "says hello",
        .depends = &.{"glibc >=2.44"},
        .files = &.{
            .{ .path = "usr", .kind = .dir, .mode = 0o755 },
            .{ .path = "usr/bin/hello", .mode = 0o755, .size = 5, .sha256 = "abc" },
            .{ .path = "usr/bin/hi", .kind = .symlink, .target = "hello" },
        },
    };
    var out: Io.Writer.Allocating = .init(arena);
    try original.write(&out.writer);
    const parsed = try Manifest.parse(arena, out.written());
    try testing.expectEqualStrings("hello", parsed.name);
    try testing.expectEqualStrings("glibc >=2.44", parsed.depends[0]);
    try testing.expectEqual(@as(usize, 3), parsed.files.len);
    try testing.expectEqual(FileKind.symlink, parsed.files[2].kind);
    try testing.expectEqualStrings("hello", parsed.files[2].target.?);
    try testing.expectEqual(@as(u32, 0o755), parsed.files[1].mode);
    try testing.expectEqual(@as(u64, 5), parsed.installedSize());
}

test "a manifest names its architecture, unless it is x86_64" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // What every package was before dave managed another architecture.
    const old = try Manifest.parse(arena, ".{ .name = \"x\", .version = \"1-r1\" }");
    try testing.expectEqualStrings("x86_64", old.arch);
    try testing.expectEqualStrings("x86_64", (try Manifest.parse(arena, ".{ .name = \"x\", .version = \"1-r1\", .arch = \"x86_64\" }")).arch);

    const made: Manifest = .{ .name = "x", .version = "1-r1", .arch = arch.name };
    var out: Io.Writer.Allocating = .init(arena);
    try made.write(&out.writer);
    try testing.expectEqual(arch.managed != .x86_64, std.mem.indexOf(u8, out.written(), ".arch") != null);
    const back = try Manifest.parse(arena, out.written());
    try testing.expectEqualStrings(arch.name, back.arch);
    try testing.expectEqualStrings("x-1-r1-" ++ arch.name ++ ".dave", try back.fileName(arena));
}

test "rejects hostile input" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.InvalidManifest, Manifest.parse(arena, "not zon"));
    try testing.expectError(error.InvalidManifest, Manifest.parse(arena,
        \\.{ .name = "x", .version = "1", .files = .{ .{ .path = "../etc/passwd" } } }
    ));
    try testing.expectError(error.InvalidManifest, Manifest.parse(arena,
        \\.{ .name = "x", .version = "1", .files = .{ .{ .path = "/etc/passwd" } } }
    ));
    try testing.expectError(error.InvalidManifest, Manifest.parse(arena,
        \\.{ .name = "../x", .version = "1" }
    ));
    try testing.expectError(error.InvalidManifest, Manifest.parse(arena,
        \\.{ .format = 999, .name = "x", .version = "1" }
    ));
    // Unknown fields from a newer writer are tolerated.
    _ = try Manifest.parse(arena,
        \\.{ .name = "x", .version = "1", .some_future_field = 3 }
    );
}

test "splitDependency" {
    const a = splitDependency("glibc >=2.44");
    try testing.expectEqualStrings("glibc", a.name);
    try testing.expectEqualStrings(">=2.44", a.constraint);
    const b = splitDependency("zlib");
    try testing.expectEqualStrings("zlib", b.name);
    try testing.expectEqualStrings("", b.constraint);
    const c = splitDependency("gcc>=16 <17");
    try testing.expectEqualStrings("gcc", c.name);
    try testing.expectEqualStrings(">=16 <17", c.constraint);
}
