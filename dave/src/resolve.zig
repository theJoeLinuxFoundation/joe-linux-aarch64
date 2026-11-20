//! Turns "what the administrator asked for" plus "what the repositories
//! offer" into a transaction, using the PubGrub solver.
//!
//! The model is the one Alpine uses: the world file is the only statement of
//! intent. Solving the world against the repositories yields the complete set
//! of packages that should be installed; the transaction is the difference
//! between that set and what is installed now.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const pubgrub = @import("solver/pubgrub.zig");
const report = @import("solver/report.zig");
const Version = @import("solver/version.zig").Version;
const Range = @import("solver/range.zig").Range;
const manifest_mod = @import("manifest.zig");
const Manifest = manifest_mod.Manifest;
const repo = @import("repo.zig");
const db = @import("db.zig");

pub const Mode = enum {
    /// Change as little as possible: keep installed versions where allowed.
    keep_installed,
    /// Move everything to the newest version the repositories offer.
    newest,
};

pub const Request = struct {
    world: []const db.WorldEntry,
    installed: []const Manifest,
    candidates: []const repo.Candidate,
    mode: Mode,
};

pub const Upgrade = struct {
    candidate: repo.Candidate,
    /// The installed version being replaced, if any.
    from: ?[]const u8,
};

pub const Solution = struct {
    /// Packages to fetch and install (new, or a different version).
    install: []const Upgrade,
    /// Installed packages nothing requires any more.
    remove: []const Manifest,
    /// How many installed packages stay exactly as they are.
    unchanged: usize,

    pub fn isEmpty(s: Solution) bool {
        return s.install.len == 0 and s.remove.len == 0;
    }
};

pub const Error = Allocator.Error || error{ NoSolution, InvalidDependency };

const Option = struct {
    version: Version,
    depends: []const []const u8,
    conflicts: []const []const u8,
    candidate: ?repo.Candidate,
    installed: bool,
};

const Universe = struct {
    arena: Allocator,
    mode: Mode,
    world: []const db.WorldEntry,
    names: std.ArrayList([]const u8) = .empty,
    ids: std.StringHashMapUnmanaged(pubgrub.PkgId) = .empty,
    options: std.ArrayList(std.ArrayList(Option)) = .empty,
    bad_dependency: ?[]const u8 = null,

    fn id(u: *Universe, name: []const u8) Allocator.Error!pubgrub.PkgId {
        const gop = try u.ids.getOrPut(u.arena, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = @intCast(u.names.items.len);
            try u.names.append(u.arena, name);
            try u.options.append(u.arena, .empty);
        }
        return gop.value_ptr.*;
    }

    fn add(u: *Universe, name: []const u8, option: Option) Allocator.Error!void {
        const pkg = try u.id(name);
        const list = &u.options.items[pkg];
        for (list.items) |*existing| {
            if (!existing.version.eql(option.version)) continue;
            // Same version both installed and offered: remember both facts, and
            // trust the installed package's own dependency list.
            if (option.installed) {
                existing.installed = true;
                existing.depends = option.depends;
                existing.conflicts = option.conflicts;
            } else if (existing.candidate == null) {
                existing.candidate = option.candidate;
            }
            return;
        }
        try list.append(u.arena, option);
    }

    fn chooseVersion(ctx: *anyopaque, pkg: pubgrub.PkgId, range: Range) ?Version {
        const u: *Universe = @ptrCast(@alignCast(ctx));
        if (pkg == pubgrub.root_pkg) return pubgrub.root_version;
        var best: ?Option = null;
        for (u.options.items[pkg].items) |o| {
            if (!range.contains(o.version)) continue;
            if (u.mode == .keep_installed and o.installed) return o.version;
            if (best == null or o.version.order(best.?.version) == .gt) best = o;
        }
        return if (best) |b| b.version else null;
    }

    fn dependencies(ctx: *anyopaque, arena: Allocator, pkg: pubgrub.PkgId, version: Version) Allocator.Error![]const pubgrub.Dependency {
        const u: *Universe = @ptrCast(@alignCast(ctx));
        var out: std.ArrayList(pubgrub.Dependency) = .empty;
        if (pkg == pubgrub.root_pkg) {
            for (u.world) |w| try u.addDependency(arena, &out, w.name, w.constraint, .requires);
            return out.items;
        }
        for (u.options.items[pkg].items) |o| {
            if (!o.version.eql(version)) continue;
            for (o.depends) |d| {
                const dep = manifest_mod.splitDependency(d);
                try u.addDependency(arena, &out, dep.name, dep.constraint, .requires);
            }
            for (o.conflicts) |d| {
                const dep = manifest_mod.splitDependency(d);
                try u.addDependency(arena, &out, dep.name, dep.constraint, .conflicts);
            }
            break;
        }
        return out.items;
    }

    fn addDependency(
        u: *Universe,
        arena: Allocator,
        out: *std.ArrayList(pubgrub.Dependency),
        name: []const u8,
        constraint: []const u8,
        kind: pubgrub.DependencyKind,
    ) Allocator.Error!void {
        const range = Range.parse(arena, constraint) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidVersion => {
                // Reported after the solve; an unsatisfiable range keeps the
                // solver from building on a constraint we could not read.
                u.bad_dependency = try std.fmt.allocPrint(u.arena, "{s} {s}", .{ name, constraint });
                try out.append(arena, .{ .pkg = try u.id(name), .range = .empty, .kind = .requires });
                return;
            },
        };
        try out.append(arena, .{ .pkg = try u.id(name), .range = range, .kind = kind });
    }

    fn nameOf(ctx: *anyopaque, pkg: pubgrub.PkgId) []const u8 {
        const u: *Universe = @ptrCast(@alignCast(ctx));
        return u.names.items[pkg];
    }
};

/// Solves `request`. On `error.NoSolution`, an explanation has been written to
/// `explain`.
pub fn resolve(arena: Allocator, request: Request, explain: *Io.Writer) (Error || Io.Writer.Error)!Solution {
    var u: Universe = .{ .arena = arena, .mode = request.mode, .world = request.world };
    _ = try u.id("(your request)");

    for (request.candidates) |c| {
        const version = Version.parse(c.entry.version) catch continue;
        try u.add(c.entry.name, .{
            .version = version,
            .depends = c.entry.depends,
            .conflicts = c.entry.conflicts,
            .candidate = c,
            .installed = false,
        });
    }
    for (request.installed) |m| {
        const version = Version.parse(m.version) catch continue;
        try u.add(m.name, .{
            .version = version,
            .depends = m.depends,
            .conflicts = m.conflicts,
            .candidate = null,
            .installed = true,
        });
    }

    var solver: pubgrub.Solver = .init(arena, .{
        .ctx = &u,
        .vtable = &.{ .chooseVersion = Universe.chooseVersion, .dependencies = Universe.dependencies },
    });
    const selected = solver.solve() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoSolution => {
            if (u.bad_dependency) |bad| {
                try explain.print("A package declares a dependency that cannot be understood: '{s}'.\n", .{bad});
                return error.InvalidDependency;
            }
            try report.write(arena, explain, solver.incompats.items, solver.failure.?, .{ .ctx = &u, .nameFn = Universe.nameOf });
            return error.NoSolution;
        },
    };

    var installed_by_name: std.StringHashMapUnmanaged(Manifest) = .empty;
    for (request.installed) |m| try installed_by_name.put(arena, m.name, m);
    var wanted: std.StringHashMapUnmanaged(void) = .empty;

    var install: std.ArrayList(Upgrade) = .empty;
    var unchanged: usize = 0;
    for (selected) |sel| {
        const name = u.names.items[sel.pkg];
        try wanted.put(arena, name, {});
        const current = installed_by_name.get(name);
        if (current) |m| {
            const have = Version.parse(m.version) catch unreachable;
            if (have.eql(sel.version)) {
                unchanged += 1;
                continue;
            }
        }
        for (u.options.items[sel.pkg].items) |o| {
            if (!o.version.eql(sel.version)) continue;
            // The solver only selects a version that is installed or offered,
            // and an installed one was handled above.
            try install.append(arena, .{ .candidate = o.candidate.?, .from = if (current) |m| m.version else null });
            break;
        }
    }
    var remove: std.ArrayList(Manifest) = .empty;
    for (request.installed) |m| {
        if (!wanted.contains(m.name)) try remove.append(arena, m);
    }
    return .{ .install = install.items, .remove = remove.items, .unchanged = unchanged };
}

const testing = std.testing;

fn cand(name: []const u8, version: []const u8, depends: []const []const u8) repo.Candidate {
    return .{ .entry = .{ .name = name, .version = version, .depends = depends, .filename = "x.dave", .size = 0, .sha256 = "" }, .repo_url = "" };
}

test "fresh install pulls in dependencies" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var sink: Io.Writer.Allocating = .init(arena_state.allocator());
    const s = try resolve(arena_state.allocator(), .{
        .world = &.{.{ .name = "editor" }},
        .installed = &.{},
        .candidates = &.{
            cand("editor", "1.0-r1", &.{"libui >=2"}),
            cand("libui", "2.1-r1", &.{"glibc"}),
            cand("libui", "1.0-r1", &.{}),
            cand("glibc", "2.44-r1", &.{}),
            cand("unrelated", "1-r1", &.{}),
        },
        .mode = .keep_installed,
    }, &sink.writer);
    try testing.expectEqual(@as(usize, 3), s.install.len);
    try testing.expectEqual(@as(usize, 0), s.remove.len);
}

test "install keeps installed versions, upgrade moves to newest" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sink: Io.Writer.Allocating = .init(arena);
    const installed = [_]Manifest{
        .{ .name = "glibc", .version = "2.44-r1" },
        .{ .name = "hello", .version = "1.0-r1", .depends = &.{"glibc"} },
    };
    const candidates = [_]repo.Candidate{
        cand("glibc", "2.44-r1", &.{}),
        cand("glibc", "2.44-r2", &.{}),
        cand("hello", "1.0-r1", &.{"glibc"}),
        cand("hello", "2.0-r1", &.{"glibc >=2.44-r2"}),
        cand("tree", "2.2-r1", &.{"glibc"}),
    };

    // Adding a package does not drag unrelated upgrades along.
    const add = try resolve(arena, .{
        .world = &.{ .{ .name = "hello" }, .{ .name = "tree" } },
        .installed = &installed,
        .candidates = &candidates,
        .mode = .keep_installed,
    }, &sink.writer);
    try testing.expectEqual(@as(usize, 1), add.install.len);
    try testing.expectEqualStrings("tree", add.install[0].candidate.entry.name);
    try testing.expectEqual(@as(usize, 2), add.unchanged);

    const up = try resolve(arena, .{
        .world = &.{.{ .name = "hello" }},
        .installed = &installed,
        .candidates = &candidates,
        .mode = .newest,
    }, &sink.writer);
    try testing.expectEqual(@as(usize, 2), up.install.len);
    for (up.install) |i| try testing.expect(i.from != null);
    try testing.expectEqual(@as(usize, 0), up.unchanged);
}

test "dropping a package from the world removes it and its orphans" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var sink: Io.Writer.Allocating = .init(arena_state.allocator());
    const s = try resolve(arena_state.allocator(), .{
        .world = &.{.{ .name = "base" }},
        .installed = &.{
            .{ .name = "base", .version = "1-r1", .depends = &.{"glibc"} },
            .{ .name = "glibc", .version = "2.44-r1" },
            .{ .name = "editor", .version = "1-r1", .depends = &.{ "glibc", "libui" } },
            .{ .name = "libui", .version = "2-r1", .depends = &.{"glibc"} },
        },
        .candidates = &.{},
        .mode = .keep_installed,
    }, &sink.writer);
    try testing.expectEqual(@as(usize, 0), s.install.len);
    try testing.expectEqual(@as(usize, 2), s.remove.len);
    try testing.expectEqual(@as(usize, 2), s.unchanged);
}

test "an installed version the repository no longer carries is still usable" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var sink: Io.Writer.Allocating = .init(arena_state.allocator());
    const s = try resolve(arena_state.allocator(), .{
        .world = &.{.{ .name = "local-tool" }},
        .installed = &.{.{ .name = "local-tool", .version = "0.1-r1" }},
        .candidates = &.{},
        .mode = .newest,
    }, &sink.writer);
    try testing.expect(s.isEmpty());
}

test "failure comes with an explanation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var sink: Io.Writer.Allocating = .init(arena_state.allocator());
    try testing.expectError(error.NoSolution, resolve(arena_state.allocator(), .{
        .world = &.{.{ .name = "editor" }},
        .installed = &.{},
        .candidates = &.{ cand("editor", "1.0-r1", &.{"libui >=2"}), cand("libui", "1.4-r2", &.{}) },
        .mode = .keep_installed,
    }, &sink.writer));
    try testing.expect(std.mem.indexOf(u8, sink.written(), "editor 1.0-r1 depends on libui >=2") != null);
    try testing.expect(std.mem.indexOf(u8, sink.written(), "you asked for editor") != null);

    var sink2: Io.Writer.Allocating = .init(arena_state.allocator());
    try testing.expectError(error.InvalidDependency, resolve(arena_state.allocator(), .{
        .world = &.{.{ .name = "broken" }},
        .installed = &.{},
        .candidates = &.{cand("broken", "1-r1", &.{"glibc >=!!"})},
        .mode = .keep_installed,
    }, &sink2.writer));
    try testing.expect(std.mem.indexOf(u8, sink2.written(), "glibc >=!!") != null);
}
