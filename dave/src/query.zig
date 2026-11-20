//! Questions about packages, answered from what dave already has: the
//! installed database, the world file and the cached indexes. Nothing here
//! needs root or the network, so anyone can ask.
//!
//! "Why is this here" is the shortest chain of dependencies from something in
//! the world file, found breadth first; ties go to the world entry that sorts
//! first and to dependencies in the order a package declares them, so the
//! answer is the same every time. "Who owns this file" looks a path up in
//! every manifest after resolving the symbolic links of its directories
//! inside the root, because on a usr-merged system `/bin/sh` is recorded as
//! `usr/bin/sh`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const manifest_mod = @import("manifest.zig");
const Manifest = manifest_mod.Manifest;
const db = @import("db.zig");
const repo = @import("repo.zig");
const Version = @import("solver/version.zig").Version;

fn dependsOn(m: Manifest, name: []const u8) bool {
    for (m.depends) |d| {
        if (std.mem.eql(u8, manifest_mod.splitDependency(d).name, name)) return true;
    }
    return false;
}

/// The installed packages that depend on `name`, sorted.
pub fn requiredBy(arena: Allocator, installed: []const Manifest, name: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (installed) |m| {
        if (dependsOn(m, name)) try out.append(arena, m.name);
    }
    return out.items;
}

pub const Reason = union(enum) {
    /// It is in the world file.
    requested,
    /// From a world entry to the package itself, both included.
    chain: []const []const u8,
    /// Installed, but nothing asked for needs it.
    orphan,
    not_installed,
};

pub fn why(arena: Allocator, installed: []const Manifest, world: []const db.WorldEntry, name: []const u8) Allocator.Error!Reason {
    var by_name: std.StringHashMapUnmanaged(Manifest) = .empty;
    for (installed) |m| try by_name.put(arena, m.name, m);
    if (!by_name.contains(name)) return .not_installed;
    for (world) |w| if (std.mem.eql(u8, w.name, name)) return .requested;

    const roots = try arena.dupe(db.WorldEntry, world);
    std.mem.sort(db.WorldEntry, roots, {}, struct {
        fn lessThan(_: void, a: db.WorldEntry, b: db.WorldEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    // Each reached package, and the one it was reached from.
    var parent: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    for (roots) |w| {
        if (!by_name.contains(w.name) or parent.contains(w.name)) continue;
        try parent.put(arena, w.name, null);
        try queue.append(arena, w.name);
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const at = queue.items[head];
        for (by_name.get(at).?.depends) |d| {
            const dep = manifest_mod.splitDependency(d).name;
            if (!by_name.contains(dep) or parent.contains(dep)) continue;
            try parent.put(arena, dep, at);
            if (std.mem.eql(u8, dep, name)) {
                var chain: std.ArrayList([]const u8) = .empty;
                var step: ?[]const u8 = dep;
                while (step) |s| : (step = parent.get(s).?) try chain.append(arena, s);
                std.mem.reverse([]const u8, chain.items);
                return .{ .chain = chain.items };
            }
            try queue.append(arena, dep);
        }
    }
    return .orphan;
}

// -- files ---------------------------------------------------------------------------

/// `path` (absolute or relative to the root) as the root itself would
/// resolve it, relative to the root and without a leading slash ("" for the
/// root itself). `.` and `..` are taken lexically and never leave the root;
/// a symbolic link among the directories is followed, an absolute target
/// within the root. The last component is left alone, so that a link is
/// found as itself.
pub fn resolveInRoot(arena: Allocator, io: Io, root: Io.Dir, path: []const u8) ![]const u8 {
    // Components still to walk, the next one last.
    var pending: std.ArrayList([]const u8) = .empty;
    try pushPath(arena, &pending, path);
    var done: std.ArrayList([]const u8) = .empty;
    var hops: usize = 0;
    var buf: [4096]u8 = undefined;
    while (pending.pop()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            _ = done.pop();
            continue;
        }
        try done.append(arena, part);
        if (pending.items.len == 0) break;
        const so_far = try std.mem.join(arena, "/", done.items);
        const n = root.readLink(io, so_far, &buf) catch continue;
        hops += 1;
        if (hops > 40) return error.SymLinkLoop;
        const target = try arena.dupe(u8, buf[0..n]);
        _ = done.pop();
        if (std.fs.path.isAbsolute(target)) done.clearRetainingCapacity();
        try pushPath(arena, &pending, target);
    }
    return std.mem.join(arena, "/", done.items);
}

fn pushPath(arena: Allocator, pending: *std.ArrayList([]const u8), path: []const u8) Allocator.Error!void {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |p| try parts.append(arena, p);
    std.mem.reverse([]const u8, parts.items);
    try pending.appendSlice(arena, parts.items);
}

pub const Owner = struct {
    package: []const u8,
    version: []const u8,
    kind: manifest_mod.FileKind,
};

/// The packages whose manifests list `rel` (relative to the root).
pub fn owners(arena: Allocator, installed: []const Manifest, rel: []const u8) Allocator.Error![]const Owner {
    var out: std.ArrayList(Owner) = .empty;
    for (installed) |m| {
        for (m.files) |f| {
            if (!std.mem.eql(u8, f.path, rel)) continue;
            try out.append(arena, .{ .package = m.name, .version = m.version, .kind = f.kind });
            break;
        }
    }
    return out.items;
}

// -- search -----------------------------------------------------------------------------

pub const Match = struct {
    name: []const u8,
    /// The newest version offered, or the installed one if none is.
    version: []const u8,
    description: []const u8,
    installed: ?[]const u8,
    /// 0: a term is the name; 1: the name begins with one; 2: contains one;
    /// 3: only the descriptions match.
    rank: u8,
};

/// The packages that every term matches, by name or description, ignoring
/// case: the closest names first, then alphabetically. Installed packages no
/// repository offers are found too.
pub fn search(arena: Allocator, candidates: []const repo.Candidate, installed: []const Manifest, terms: []const []const u8) Allocator.Error![]const Match {
    var newest: std.StringArrayHashMapUnmanaged(repo.Candidate) = .empty;
    for (candidates) |c| {
        const v = Version.parse(c.entry.version) catch continue;
        const slot = try newest.getOrPut(arena, c.entry.name);
        if (slot.found_existing) {
            const have = Version.parse(slot.value_ptr.entry.version) catch unreachable;
            if (v.order(have) != .gt) continue;
        }
        slot.value_ptr.* = c;
    }
    var installed_by_name: std.StringHashMapUnmanaged(Manifest) = .empty;
    for (installed) |m| try installed_by_name.put(arena, m.name, m);

    var out: std.ArrayList(Match) = .empty;
    for (newest.values()) |c| {
        const here = installed_by_name.get(c.entry.name);
        try consider(arena, &out, terms, c.entry.name, c.entry.version, c.entry.description, if (here) |m| m.version else null);
    }
    for (installed) |m| {
        if (newest.contains(m.name)) continue;
        try consider(arena, &out, terms, m.name, m.version, m.description, m.version);
    }
    std.mem.sort(Match, out.items, {}, struct {
        fn lessThan(_: void, a: Match, b: Match) bool {
            if (a.rank != b.rank) return a.rank < b.rank;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    return out.items;
}

fn consider(arena: Allocator, out: *std.ArrayList(Match), terms: []const []const u8, name: []const u8, version: []const u8, description: []const u8, installed: ?[]const u8) Allocator.Error!void {
    var rank: u8 = 3;
    for (terms) |t| {
        const r: u8 = if (std.ascii.eqlIgnoreCase(name, t))
            0
        else if (std.ascii.startsWithIgnoreCase(name, t))
            1
        else if (std.ascii.findIgnoreCase(name, t) != null)
            2
        else if (std.ascii.findIgnoreCase(description, t) != null)
            3
        else
            return;
        rank = @min(rank, r);
    }
    try out.append(arena, .{ .name = name, .version = version, .description = description, .installed = installed, .rank = rank });
}

const testing = std.testing;

fn pkg(name: []const u8, version: []const u8, depends: []const []const u8) Manifest {
    return .{ .name = name, .version = version, .depends = depends };
}

test "why: the shortest chain from the world" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // app -> gui -> toolkit -> zlib, and app -> zlib directly; base -> zlib.
    const installed = [_]Manifest{
        pkg("app", "1-r1", &.{ "gui", "zlib >=1" }),
        pkg("base", "1-r1", &.{"zlib"}),
        pkg("gui", "1-r1", &.{"toolkit"}),
        pkg("leftover", "1-r1", &.{}),
        pkg("toolkit", "1-r1", &.{"zlib"}),
        pkg("zlib", "1-r1", &.{}),
    };
    const world = [_]db.WorldEntry{ .{ .name = "base" }, .{ .name = "app" } };
    const z = try why(arena, &installed, &world, "zlib");
    // Both app and base reach zlib in one step; app sorts first.
    try testing.expectEqual(@as(usize, 2), z.chain.len);
    try testing.expectEqualStrings("app", z.chain[0]);
    try testing.expectEqualStrings("zlib", z.chain[1]);
    const t = try why(arena, &installed, &world, "toolkit");
    try testing.expectEqual(@as(usize, 3), t.chain.len);
    try testing.expectEqualStrings("gui", t.chain[1]);
    try testing.expect(try why(arena, &installed, &world, "app") == .requested);
    try testing.expect(try why(arena, &installed, &world, "leftover") == .orphan);
    try testing.expect(try why(arena, &installed, &world, "nothing") == .not_installed);

    const needing = try requiredBy(arena, &installed, "zlib");
    try testing.expectEqual(@as(usize, 3), needing.len);
    try testing.expectEqualStrings("app", needing[0]);
}

test "owners" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const installed = [_]Manifest{
        .{ .name = "bash", .version = "5.3-r1", .files = &.{ .{ .path = "usr/bin", .kind = .dir }, .{ .path = "usr/bin/bash" } } },
        .{ .name = "coreutils", .version = "9.7-r1", .files = &.{ .{ .path = "usr/bin", .kind = .dir }, .{ .path = "usr/bin/ls" } } },
    };
    try testing.expectEqualStrings("bash", (try owners(arena, &installed, "usr/bin/bash"))[0].package);
    try testing.expectEqual(@as(usize, 2), (try owners(arena, &installed, "usr/bin")).len);
    try testing.expectEqual(@as(usize, 0), (try owners(arena, &installed, "etc/hostname")).len);
}

test "resolveInRoot follows the root's own links" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "usr/bin");
    try tmp.dir.createDirPath(io, "usr/lib");
    try tmp.dir.symLink(io, "usr/bin", "bin", .{});
    try tmp.dir.symLink(io, "/usr/lib", "lib", .{});
    try tmp.dir.symLink(io, "loop2", "loop1", .{});
    try tmp.dir.symLink(io, "loop1", "loop2", .{});
    try tmp.dir.symLink(io, "bash", "usr/bin/sh", .{});

    try testing.expectEqualStrings("usr/bin/bash", try resolveInRoot(arena, io, tmp.dir, "/bin/bash"));
    try testing.expectEqualStrings("usr/lib/libc.so", try resolveInRoot(arena, io, tmp.dir, "/lib/libc.so"));
    // The last component is not followed: /bin/sh is the link itself.
    try testing.expectEqualStrings("usr/bin/sh", try resolveInRoot(arena, io, tmp.dir, "/bin/sh"));
    try testing.expectEqualStrings("etc/passwd", try resolveInRoot(arena, io, tmp.dir, "/../../etc/./passwd"));
    try testing.expectEqualStrings("usr", try resolveInRoot(arena, io, tmp.dir, "/usr/bin/.."));
    try testing.expectEqualStrings("", try resolveInRoot(arena, io, tmp.dir, "/"));
    try testing.expectEqualStrings("missing/file", try resolveInRoot(arena, io, tmp.dir, "missing/file"));
    try testing.expectError(error.SymLinkLoop, resolveInRoot(arena, io, tmp.dir, "/loop1/x"));
}

test "search" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entry = struct {
        fn of(name: []const u8, version: []const u8, description: []const u8) repo.Candidate {
            return .{ .entry = .{ .name = name, .version = version, .description = description, .filename = "x", .size = 0, .sha256 = "" }, .repo_url = "" };
        }
    }.of;
    const cands = [_]repo.Candidate{
        entry("hello", "1.0-r1", "says hello"),
        entry("hello", "2.0-r1", "says hello"),
        entry("libgreet", "1.0-r1", "greetings for hello"),
        entry("hello-extra", "1.0-r1", "more"),
        entry("othello", "1.0-r1", "a game"),
        entry("tree", "2.2-r1", "lists directories"),
    };
    const installed = [_]Manifest{ pkg("hello", "1.0-r1", &.{}), .{ .name = "local", .version = "1-r1", .description = "built here, says hello" } };
    const found = try search(arena, &cands, &installed, &.{"hello"});
    try testing.expectEqual(@as(usize, 5), found.len);
    try testing.expectEqualStrings("hello", found[0].name);
    try testing.expectEqualStrings("2.0-r1", found[0].version);
    try testing.expectEqualStrings("1.0-r1", found[0].installed.?);
    try testing.expectEqualStrings("hello-extra", found[1].name);
    try testing.expectEqualStrings("othello", found[2].name);
    try testing.expectEqualStrings("libgreet", found[3].name);
    try testing.expectEqualStrings("local", found[4].name);
    // Every term must match.
    const both = try search(arena, &cands, &installed, &.{ "hello", "GREET" });
    try testing.expectEqual(@as(usize, 1), both.len);
    try testing.expectEqualStrings("libgreet", both[0].name);
}
