//! What a change will do, said before it is done.
//!
//! A solution is shown in three groups (what comes in, what moves to another
//! version, what goes), each package marked when it was not asked for: a
//! dependency coming in, a package no longer needed going out. A summary
//! counts them and says what has still to be downloaded and how the disk use
//! changes. The second number needs every incoming package's installed size,
//! which indexes written before dave 0.3 do not give; it is left out then
//! rather than guessed.
//!
//! The same classification decides whether to ask before going ahead. Like
//! apt, dave proceeds without asking when the change is exactly what was
//! named, and asks when it would do more: bring in dependencies, upgrade or
//! remove something else. An upgrade never asks; it changes nothing until
//! the machine shuts down.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Manifest = @import("manifest.zig").Manifest;
const db = @import("db.zig");
const resolve = @import("resolve.zig");
const ui = @import("ui.zig");

pub const Kind = enum { install, remove, upgrade };

pub const Entry = struct {
    name: []const u8,
    version: []const u8,
    /// The version being replaced (an upgrade).
    from: ?[]const u8 = null,
    /// Named on the command line.
    named: bool = false,
    /// In the world file, as it will be after the change.
    requested: bool = false,
    /// The version column: the version, or "old -> new".
    shown: []const u8 = "",
};

pub const Input = struct {
    solution: resolve.Solution,
    installed: []const Manifest,
    world: []const db.WorldEntry,
    named: []const []const u8 = &.{},
    /// For each of solution.install, whether its file has been downloaded
    /// already; empty means none has.
    cached: []const bool = &.{},
};

pub const Plan = struct {
    install: []const Entry,
    upgrade: []const Entry,
    remove: []const Entry,
    /// Bytes still to download.
    download: u64,
    /// How much more disk space the packages will take (negative: less),
    /// when every size is known.
    disk: ?i64,

    pub fn isEmpty(p: Plan) bool {
        return p.install.len == 0 and p.upgrade.len == 0 and p.remove.len == 0;
    }

    /// Whether a person should confirm the change before it is made.
    pub fn needsQuestion(p: Plan, kind: Kind) bool {
        switch (kind) {
            .install => {
                if (p.remove.len > 0) return true;
                for (p.install) |e| if (!e.named) return true;
                for (p.upgrade) |e| if (!e.named) return true;
                return false;
            },
            .remove => {
                if (p.install.len > 0 or p.upgrade.len > 0) return true;
                for (p.remove) |e| if (!e.named) return true;
                return false;
            },
            .upgrade => return false,
        }
    }

    pub fn write(p: Plan, w: *Io.Writer, color: bool) Io.Writer.Error!void {
        var name_width: usize = 0;
        var version_width: usize = 0;
        for ([_][]const Entry{ p.install, p.upgrade, p.remove }) |group| {
            for (group) |e| {
                name_width = @max(name_width, e.name.len);
                version_width = @max(version_width, e.shown.len);
            }
        }
        const groups = [_]struct { []const u8, []const Entry, ui.Style }{
            .{ "Install", p.install, .install },
            .{ "Upgrade", p.upgrade, .upgrade },
            .{ "Remove", p.remove, .remove },
        };
        for (groups) |g| {
            if (g[1].len == 0) continue;
            try w.print("{f}\n", .{ui.paint(color, .heading, g[0])});
            for (g[1]) |e| {
                try w.print("  {f}", .{ui.paint(color, g[2], e.name)});
                try w.splatByteAll(' ', name_width - e.name.len + 2);
                try w.writeAll(e.shown);
                const mark: ?[]const u8 = switch (g[2]) {
                    .install => if (e.requested) null else "(dependency)",
                    .remove => if (e.named) null else "(no longer needed)",
                    else => null,
                };
                if (mark) |m| {
                    try w.splatByteAll(' ', version_width - e.shown.len + 2);
                    try w.print("{f}", .{ui.paint(color, .dim, m)});
                }
                try w.writeByte('\n');
            }
        }
        try w.writeByte('\n');
        try p.writeSummary(w);
    }

    fn writeSummary(p: Plan, w: *Io.Writer) Io.Writer.Error!void {
        var parts: [3][]const u8 = undefined;
        var bufs: [3][32]u8 = undefined;
        var n: usize = 0;
        const counts = [_]struct { usize, []const u8 }{
            .{ p.install.len, "install" },
            .{ p.upgrade.len, "upgrade" },
            .{ p.remove.len, "remove" },
        };
        for (counts) |c| {
            if (c[0] == 0) continue;
            parts[n] = std.fmt.bufPrint(&bufs[n], "{d} to {s}", .{ c[0], c[1] }) catch unreachable;
            n += 1;
        }
        for (parts[0..n], 0..) |part, i| {
            if (i > 0) try w.writeAll(if (i == n - 1) " and " else ", ");
            try w.writeAll(part);
        }
        try w.writeByte('.');
        const disk: i64 = p.disk orelse 0;
        if (p.download > 0) {
            try w.print(" {f} to download", .{ui.size(p.download)});
            try w.writeAll(if (disk != 0) ";" else ".");
        }
        if (disk > 0) try w.print(" {f} more disk space will be used.", .{ui.size(@intCast(disk))});
        if (disk < 0) try w.print(" {f} of disk space will be freed.", .{ui.size(@intCast(-disk))});
        try w.writeByte('\n');
    }
};

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn byName(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

pub fn of(arena: Allocator, input: Input) Allocator.Error!Plan {
    var installed_by_name: std.StringHashMapUnmanaged(Manifest) = .empty;
    for (input.installed) |m| try installed_by_name.put(arena, m.name, m);
    var world: std.ArrayList([]const u8) = .empty;
    for (input.world) |w| try world.append(arena, w.name);

    var install: std.ArrayList(Entry) = .empty;
    var upgrade: std.ArrayList(Entry) = .empty;
    var remove: std.ArrayList(Entry) = .empty;
    var download: u64 = 0;
    var disk: ?i64 = 0;
    for (input.solution.install, 0..) |u, i| {
        const e = u.candidate.entry;
        const entry: Entry = .{
            .name = e.name,
            .version = e.version,
            .from = u.from,
            .named = contains(input.named, e.name),
            .requested = contains(world.items, e.name),
            .shown = if (u.from) |from| try std.fmt.allocPrint(arena, "{s} -> {s}", .{ from, e.version }) else e.version,
        };
        if (u.from != null) try upgrade.append(arena, entry) else try install.append(arena, entry);
        const cached = i < input.cached.len and input.cached[i];
        if (!cached) download += e.size;
        if (disk) |d| {
            if (e.installed_size) |s| {
                var change: i64 = d + @as(i64, @intCast(s));
                if (u.from != null) {
                    if (installed_by_name.get(e.name)) |old| change -= @intCast(old.installedSize());
                }
                disk = change;
            } else disk = null;
        }
    }
    for (input.solution.remove) |m| {
        try remove.append(arena, .{
            .name = m.name,
            .version = m.version,
            .named = contains(input.named, m.name),
            .requested = contains(world.items, m.name),
            .shown = m.version,
        });
        if (disk) |d| disk = d - @as(i64, @intCast(m.installedSize()));
    }
    std.mem.sort(Entry, install.items, {}, byName);
    std.mem.sort(Entry, upgrade.items, {}, byName);
    std.mem.sort(Entry, remove.items, {}, byName);
    return .{ .install = install.items, .upgrade = upgrade.items, .remove = remove.items, .download = download, .disk = disk };
}

const testing = std.testing;
const repo = @import("repo.zig");

fn candidate(name: []const u8, version: []const u8, size: u64, installed_size: ?u64) repo.Candidate {
    return .{ .entry = .{ .name = name, .version = version, .filename = "x", .size = size, .sha256 = "", .installed_size = installed_size }, .repo_url = "" };
}

test "a plan, and when to ask" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const installed = [_]Manifest{
        .{ .name = "tree", .version = "2.1-r1", .files = &.{.{ .path = "usr/bin/tree", .size = 1000 }} },
        .{ .name = "oldlib", .version = "0.9-r1", .files = &.{.{ .path = "usr/lib/oldlib.so", .size = 3000 }} },
    };
    const solution: resolve.Solution = .{
        .install = &.{
            .{ .candidate = candidate("libgreet", "1.0-r1", 2048, 4096), .from = null },
            .{ .candidate = candidate("hello", "1.0-r1", 1024, 2048), .from = null },
            .{ .candidate = candidate("tree", "2.2-r1", 512, 1500), .from = "2.1-r1" },
        },
        .remove = &.{installed[1]},
        .unchanged = 0,
    };
    const p = try of(arena, .{
        .solution = solution,
        .installed = &installed,
        .world = &.{ .{ .name = "hello" }, .{ .name = "tree" } },
        .named = &.{"hello"},
        .cached = &.{ true, false, false },
    });
    try testing.expectEqual(@as(u64, 1536), p.download);
    try testing.expectEqual(@as(?i64, 4096 + 2048 + 1500 - 1000 - 3000), p.disk);
    try testing.expect(p.needsQuestion(.install));
    try testing.expect(p.needsQuestion(.remove));
    try testing.expect(!p.needsQuestion(.upgrade));

    var out: Io.Writer.Allocating = .init(arena);
    try p.write(&out.writer, false);
    try testing.expectEqualStrings(
        \\Install
        \\  hello     1.0-r1
        \\  libgreet  1.0-r1            (dependency)
        \\Upgrade
        \\  tree      2.1-r1 -> 2.2-r1
        \\Remove
        \\  oldlib    0.9-r1            (no longer needed)
        \\
        \\2 to install, 1 to upgrade and 1 to remove. 1.5 KiB to download; 3.6 KiB more disk space will be used.
        \\
    , out.written());
}

test "exactly what was named is not asked about" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tree: Manifest = .{ .name = "tree", .version = "2.2-r1" };
    const just_tree = try of(arena, .{
        .solution = .{ .install = &.{.{ .candidate = candidate("tree", "2.2-r1", 10, null), .from = null }}, .remove = &.{}, .unchanged = 0 },
        .installed = &.{},
        .world = &.{.{ .name = "tree" }},
        .named = &.{"tree"},
    });
    try testing.expect(!just_tree.needsQuestion(.install));
    // An index without installed sizes: no disk figure at all.
    try testing.expectEqual(@as(?i64, null), just_tree.disk);
    var out: Io.Writer.Allocating = .init(arena);
    try just_tree.write(&out.writer, false);
    try testing.expectEqualStrings("Install\n  tree  2.2-r1\n\n1 to install. 10 B to download.\n", out.written());

    const removing = try of(arena, .{
        .solution = .{ .install = &.{}, .remove = &.{tree}, .unchanged = 0 },
        .installed = &.{tree},
        .world = &.{},
        .named = &.{"tree"},
    });
    try testing.expect(!removing.needsQuestion(.remove));
    out.clearRetainingCapacity();
    try removing.write(&out.writer, false);
    try testing.expectEqualStrings("Remove\n  tree  2.2-r1\n\n1 to remove.\n", out.written());

    // Naming a package that is installed and upgrading it is what was asked.
    const named_upgrade = try of(arena, .{
        .solution = .{ .install = &.{.{ .candidate = candidate("tree", "2.3-r1", 10, 0), .from = "2.2-r1" }}, .remove = &.{}, .unchanged = 0 },
        .installed = &.{tree},
        .world = &.{.{ .name = "tree" }},
        .named = &.{"tree"},
    });
    try testing.expect(!named_upgrade.needsQuestion(.install));
}
