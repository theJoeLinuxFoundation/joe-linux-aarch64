//! The installed-package database and the "world" file.
//!
//! The database lives under `usr/lib/dave/db` *inside* the root it describes,
//! one directory per package holding that package's manifest. Because it is
//! part of the root subvolume, every deployment snapshot carries the database
//! that matches its own contents, and a rollback can never desynchronise them.
//!
//! `etc/dave/world` lists what the administrator asked for, one
//! `name [constraint]` per line. Everything else installed is a dependency.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const manifest_mod = @import("manifest.zig");
const Manifest = manifest_mod.Manifest;
const archive = @import("archive.zig");

pub const db_path = "usr/lib/dave/db";
pub const world_path = "etc/dave/world";
const manifest_name = "manifest.zon";
const max_bytes = archive.max_manifest_bytes;

/// Loads the manifest of every installed package, sorted by name.
pub fn load(arena: Allocator, io: Io, root: Io.Dir) ![]Manifest {
    var list: std.ArrayList(Manifest) = .empty;
    var dir = root.openDir(io, db_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list.items,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const sub = try std.fmt.allocPrint(arena, "{s}/" ++ manifest_name, .{entry.name});
        const text = dir.readFileAlloc(io, sub, arena, .limited(max_bytes)) catch |err| switch (err) {
            // A directory without a manifest is a write that never completed.
            error.FileNotFound => continue,
            else => return err,
        };
        const m = try Manifest.parse(arena, text);
        if (!std.mem.eql(u8, m.name, entry.name)) return error.CorruptDatabase;
        try list.append(arena, m);
    }
    std.mem.sort(Manifest, list.items, {}, byName);
    return list.items;
}

/// The manifest of one installed package, or null when it is not installed.
pub fn loadOne(arena: Allocator, io: Io, root: Io.Dir, name: []const u8) !?Manifest {
    if (!manifest_mod.validName(name)) return null;
    const sub = try std.fmt.allocPrint(arena, db_path ++ "/{s}/" ++ manifest_name, .{name});
    const text = root.readFileAlloc(io, sub, arena, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const m = try Manifest.parse(arena, text);
    if (!std.mem.eql(u8, m.name, name)) return error.CorruptDatabase;
    return m;
}

/// The names of the installed packages, sorted, without reading their
/// manifests (which, for a desktop, are many megabytes together).
pub fn names(arena: Allocator, io: Io, root: Io.Dir) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var dir = root.openDir(io, db_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return list.items,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory or !manifest_mod.validName(entry.name)) continue;
        const sub = try std.fmt.allocPrint(arena, "{s}/" ++ manifest_name, .{entry.name});
        _ = dir.statFile(io, sub, .{}) catch continue;
        try list.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return list.items;
}

fn byName(_: void, a: Manifest, b: Manifest) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

pub fn put(arena: Allocator, io: Io, root: Io.Dir, m: Manifest) !void {
    const dir_path = try std.fmt.allocPrint(arena, db_path ++ "/{s}", .{m.name});
    try root.createDirPath(io, dir_path);
    var text: Io.Writer.Allocating = .init(arena);
    try m.write(&text.writer);
    try writeAtomic(arena, io, root, try std.fmt.allocPrint(arena, "{s}/" ++ manifest_name, .{dir_path}), text.written());
}

pub fn remove(arena: Allocator, io: Io, root: Io.Dir, name: []const u8) !void {
    const dir_path = try std.fmt.allocPrint(arena, db_path ++ "/{s}", .{name});
    try root.deleteTree(io, dir_path);
}

/// A digest of exactly which package versions are installed. A staged upgrade
/// records it, and is only applied to a root that still matches.
pub fn stateHash(arena: Allocator, installed: []const Manifest) Allocator.Error!archive.Digest {
    var text: Io.Writer.Allocating = .init(arena);
    for (installed) |m| text.writer.print("{s} {s}\n", .{ m.name, m.version }) catch return error.OutOfMemory;
    return archive.hashBytes(text.written());
}

/// Writes a file so that a crash leaves either the old or the new contents.
pub fn writeAtomic(arena: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) !void {
    return writeAtomicWith(arena, io, dir, sub_path, data, null);
}

/// writeAtomic, giving the file exactly `permissions` (when not null)
/// whatever the umask.
pub fn writeAtomicWith(arena: Allocator, io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8, permissions: ?Io.File.Permissions) !void {
    const tmp = try std.fmt.allocPrint(arena, "{s}.dave-tmp", .{sub_path});
    {
        var file = try dir.createFile(io, tmp, .{});
        defer file.close(io);
        errdefer dir.deleteFile(io, tmp) catch {};
        if (permissions) |p| try file.setPermissions(io, p);
        var buf: [16 * 1024]u8 = undefined;
        var w = file.writer(io, &buf);
        try w.interface.writeAll(data);
        try w.interface.flush();
        try file.sync(io);
    }
    try dir.rename(tmp, dir, sub_path, io);
}

pub const WorldEntry = struct {
    name: []const u8,
    constraint: []const u8 = "",
};

pub fn loadWorld(arena: Allocator, io: Io, root: Io.Dir) ![]WorldEntry {
    var list: std.ArrayList(WorldEntry) = .empty;
    const text = root.readFileAlloc(io, world_path, arena, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return list.items,
        else => return err,
    };
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const dep = manifest_mod.splitDependency(line);
        if (!manifest_mod.validName(dep.name)) return error.InvalidWorld;
        try list.append(arena, .{ .name = dep.name, .constraint = dep.constraint });
    }
    return list.items;
}

pub fn saveWorld(arena: Allocator, io: Io, root: Io.Dir, entries: []const WorldEntry) !void {
    const sorted = try arena.dupe(WorldEntry, entries);
    std.mem.sort(WorldEntry, sorted, {}, struct {
        fn lessThan(_: void, a: WorldEntry, b: WorldEntry) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    var text: Io.Writer.Allocating = .init(arena);
    for (sorted) |e| {
        if (e.constraint.len == 0) {
            try text.writer.print("{s}\n", .{e.name});
        } else {
            try text.writer.print("{s} {s}\n", .{ e.name, e.constraint });
        }
    }
    try root.createDirPath(io, std.fs.path.dirname(world_path).?);
    try writeAtomic(arena, io, root, world_path, text.written());
}

const testing = std.testing;

test "database round trip" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try testing.expectEqual(@as(usize, 0), (try load(arena, io, tmp.dir)).len);
    try put(arena, io, tmp.dir, .{ .name = "zlib", .version = "1.3-r1" });
    try put(arena, io, tmp.dir, .{ .name = "bash", .version = "5.3-r1", .depends = &.{"glibc"} });
    const first = try load(arena, io, tmp.dir);
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqualStrings("bash", first[0].name);
    try testing.expectEqualStrings("zlib", first[1].name);

    const before = try stateHash(arena, first);
    try put(arena, io, tmp.dir, .{ .name = "zlib", .version = "1.3-r2" });
    const second = try load(arena, io, tmp.dir);
    try testing.expectEqualStrings("1.3-r2", second[1].version);
    try testing.expect(!std.mem.eql(u8, &before, &try stateHash(arena, second)));

    const listed = try names(arena, io, tmp.dir);
    try testing.expectEqual(@as(usize, 2), listed.len);
    try testing.expectEqualStrings("bash", listed[0]);
    try testing.expectEqualStrings("5.3-r1", (try loadOne(arena, io, tmp.dir, "bash")).?.version);
    try testing.expect(try loadOne(arena, io, tmp.dir, "nope") == null);
    try testing.expect(try loadOne(arena, io, tmp.dir, "../etc") == null);

    try remove(arena, io, tmp.dir, "bash");
    try testing.expectEqual(@as(usize, 1), (try load(arena, io, tmp.dir)).len);
    try testing.expectEqual(@as(usize, 1), (try names(arena, io, tmp.dir)).len);
}

test "world round trip" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectEqual(@as(usize, 0), (try loadWorld(arena, io, tmp.dir)).len);
    try saveWorld(arena, io, tmp.dir, &.{ .{ .name = "joe-base" }, .{ .name = "hello", .constraint = ">=1.0" } });
    const world = try loadWorld(arena, io, tmp.dir);
    try testing.expectEqual(@as(usize, 2), world.len);
    try testing.expectEqualStrings("hello", world[0].name);
    try testing.expectEqualStrings(">=1.0", world[0].constraint);
    try testing.expectEqualStrings("joe-base", world[1].name);
}
