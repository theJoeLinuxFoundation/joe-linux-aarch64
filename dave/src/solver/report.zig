//! Turns the incompatibility that proved "no solution" into an explanation a
//! person can follow, by walking the tree of derivations that produced it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const pubgrub = @import("pubgrub.zig");
const Range = @import("range.zig").Range;
const Incompat = pubgrub.Incompat;
const IncompatId = pubgrub.IncompatId;
const PkgId = pubgrub.PkgId;

pub const Names = struct {
    ctx: *anyopaque,
    nameFn: *const fn (ctx: *anyopaque, pkg: PkgId) []const u8,

    fn of(n: Names, pkg: PkgId) []const u8 {
        return n.nameFn(n.ctx, pkg);
    }
};

const Line = struct {
    text: []const u8,
    /// Set when a later line refers back to this one.
    number: ?u32 = null,
};

const Reporter = struct {
    arena: Allocator,
    incompats: []const Incompat,
    names: Names,
    lines: std.ArrayList(Line) = .empty,
    /// Line index at which each derived incompatibility was concluded.
    concluded: std.AutoHashMapUnmanaged(IncompatId, usize) = .empty,
    next_number: u32 = 1,

    const Error = Allocator.Error;

    fn isDerived(r: *Reporter, id: IncompatId) bool {
        return r.incompats[id].cause == .derived;
    }

    /// Emits the lines that establish incompatibility `id`.
    fn explain(r: *Reporter, id: IncompatId) Error!void {
        if (r.concluded.contains(id)) return;
        const d = r.incompats[id].cause.derived;
        const conclusion = try r.describe(id);
        const a_derived = r.isDerived(d.a);
        const b_derived = r.isDerived(d.b);

        if (a_derived and b_derived) {
            try r.explain(d.a);
            try r.explain(d.b);
            const text = try std.fmt.allocPrint(r.arena, "Because {s} and {s}, {s}.", .{
                try r.reference(d.a), try r.reference(d.b), conclusion,
            });
            try r.lines.append(r.arena, .{ .text = text });
        } else if (a_derived or b_derived) {
            const derived = if (a_derived) d.a else d.b;
            const external = if (a_derived) d.b else d.a;
            const already = r.concluded.contains(derived);
            try r.explain(derived);
            const follows_directly = !already and r.concluded.get(derived).? == r.lines.items.len - 1;
            const text = if (follows_directly)
                try std.fmt.allocPrint(r.arena, "And because {s}, {s}.", .{ try r.describe(external), conclusion })
            else
                try std.fmt.allocPrint(r.arena, "Because {s} and {s}, {s}.", .{
                    try r.reference(derived), try r.describe(external), conclusion,
                });
            try r.lines.append(r.arena, .{ .text = text });
        } else {
            // Read better with the dependency first and the missing version second.
            const swap = r.incompats[d.a].cause == .no_versions and r.incompats[d.b].cause != .no_versions;
            const first = if (swap) d.b else d.a;
            const second = if (swap) d.a else d.b;
            const text = try std.fmt.allocPrint(r.arena, "Because {s} and {s}, {s}.", .{
                try r.describe(first), try r.describe(second), conclusion,
            });
            try r.lines.append(r.arena, .{ .text = text });
        }
        try r.concluded.put(r.arena, id, r.lines.items.len - 1);
    }

    /// How to cite an already explained incompatibility from a later line.
    fn reference(r: *Reporter, id: IncompatId) Error![]const u8 {
        const line = &r.lines.items[r.concluded.get(id).?];
        if (line.number == null) {
            line.number = r.next_number;
            r.next_number += 1;
        }
        return std.fmt.allocPrint(r.arena, "{s} ({d})", .{ try r.describe(id), line.number.? });
    }

    /// If `range` is "everything except a few exact versions", lists those versions.
    fn onlyVersions(r: *Reporter, range: Range) Error!?[]const u8 {
        const rest = try range.complement(r.arena);
        if (rest.isEmpty()) return null;
        var out: Writer.Allocating = .init(r.arena);
        for (rest.intervals, 0..) |iv, i| {
            if (iv.lo != .inclusive or iv.hi != .inclusive) return null;
            if (!iv.lo.inclusive.eql(iv.hi.inclusive)) return null;
            if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
            out.writer.print("{f}", .{iv.lo.inclusive}) catch return error.OutOfMemory;
        }
        return out.written();
    }

    fn pkgRange(r: *Reporter, pkg: PkgId, range: Range) Error![]const u8 {
        if (range.isFull()) return r.names.of(pkg);
        return std.fmt.allocPrint(r.arena, "{s} {f}", .{ r.names.of(pkg), range });
    }

    fn describe(r: *Reporter, id: IncompatId) Error![]const u8 {
        const incompat = r.incompats[id];
        switch (incompat.cause) {
            .root => return "your request must be honoured",
            .no_versions => {
                const t = incompat.terms[0];
                if (t.term.range.isFull())
                    return std.fmt.allocPrint(r.arena, "no package named {s} exists", .{r.names.of(t.pkg)});
                if (try r.onlyVersions(t.term.range)) |only|
                    return std.fmt.allocPrint(r.arena, "{s} has no version other than {s}", .{ r.names.of(t.pkg), only });
                return std.fmt.allocPrint(r.arena, "no version of {s} matches {f}", .{ r.names.of(t.pkg), t.term.range });
            },
            .dependency => |dep| {
                if (dep.range.isEmpty() and dep.kind == .requires) {
                    if (dep.pkg == pubgrub.root_pkg)
                        return std.fmt.allocPrint(r.arena, "you asked for a version of {s} that cannot exist", .{r.names.of(dep.on)});
                    return std.fmt.allocPrint(r.arena, "{s} {f} depends on a version of {s} that cannot exist", .{ r.names.of(dep.pkg), dep.version, r.names.of(dep.on) });
                }
                const target = try r.pkgRange(dep.on, dep.range);
                if (dep.pkg == pubgrub.root_pkg) return switch (dep.kind) {
                    .requires => std.fmt.allocPrint(r.arena, "you asked for {s}", .{target}),
                    .conflicts => std.fmt.allocPrint(r.arena, "you excluded {s}", .{target}),
                };
                const verb = if (dep.kind == .requires) "depends on" else "conflicts with";
                return std.fmt.allocPrint(r.arena, "{s} {f} {s} {s}", .{ r.names.of(dep.pkg), dep.version, verb, target });
            },
            .derived => return r.describeTerms(incompat),
        }
    }

    /// States a derived incompatibility in the most natural form its shape allows.
    fn describeTerms(r: *Reporter, incompat: Incompat) Error![]const u8 {
        // The root is always selected, so a positive root term adds no information.
        var terms: std.ArrayList(pubgrub.PkgTerm) = .empty;
        var mentions_root = false;
        for (incompat.terms) |t| {
            if (t.pkg == pubgrub.root_pkg and t.term.positive) {
                mentions_root = true;
                continue;
            }
            try terms.append(r.arena, t);
        }
        const suffix = if (mentions_root) " given what you asked for" else "";

        switch (terms.items.len) {
            0 => return "what you asked for cannot be installed",
            1 => {
                const t = terms.items[0];
                const what = try r.pkgRange(t.pkg, t.term.range);
                if (t.term.positive) return std.fmt.allocPrint(r.arena, "{s} cannot be installed{s}", .{ what, suffix });
                return std.fmt.allocPrint(r.arena, "{s} is required{s}", .{ what, suffix });
            },
            2 => {
                const x = terms.items[0];
                const y = terms.items[1];
                if (x.term.positive != y.term.positive) {
                    const pos = if (x.term.positive) x else y;
                    const neg = if (x.term.positive) y else x;
                    return std.fmt.allocPrint(r.arena, "{s} requires {s}{s}", .{
                        try r.pkgRange(pos.pkg, pos.term.range), try r.pkgRange(neg.pkg, neg.term.range), suffix,
                    });
                }
                if (x.term.positive) return std.fmt.allocPrint(r.arena, "{s} cannot be installed together with {s}{s}", .{
                    try r.pkgRange(x.pkg, x.term.range), try r.pkgRange(y.pkg, y.term.range), suffix,
                });
                return std.fmt.allocPrint(r.arena, "either {s} or {s} is required{s}", .{
                    try r.pkgRange(x.pkg, x.term.range), try r.pkgRange(y.pkg, y.term.range), suffix,
                });
            },
            else => {
                var out: Writer.Allocating = .init(r.arena);
                const w = &out.writer;
                w.writeAll("these cannot all hold at once: ") catch return error.OutOfMemory;
                for (terms.items, 0..) |t, i| {
                    if (i > 0) w.writeAll("; ") catch return error.OutOfMemory;
                    const what = try r.pkgRange(t.pkg, t.term.range);
                    w.print("{s} {s}", .{ what, if (t.term.positive) "installed" else "absent" }) catch return error.OutOfMemory;
                }
                w.writeAll(suffix) catch return error.OutOfMemory;
                return out.written();
            },
        }
    }
};

/// Writes the explanation for a failed solve. `failure` is `Solver.failure`.
pub fn write(
    arena: Allocator,
    w: *Writer,
    incompats: []const Incompat,
    failure: IncompatId,
    names: Names,
) (Allocator.Error || Writer.Error)!void {
    var r: Reporter = .{ .arena = arena, .incompats = incompats, .names = names };
    if (incompats[failure].cause != .derived) {
        try w.print("Cannot proceed: {s}.\n", .{try r.describe(failure)});
        return;
    }
    try r.explain(failure);
    for (r.lines.items, 0..) |line, i| {
        const last = i == r.lines.items.len - 1;
        var text = line.text;
        // The last line concludes the whole proof.
        if (last and std.mem.startsWith(u8, text, "And because ")) {
            text = try std.fmt.allocPrint(arena, "So, because {s}", .{text["And because ".len..]});
        }
        if (line.number) |n| {
            try w.print("{s} ({d})\n", .{ text, n });
        } else {
            try w.print("{s}\n", .{text});
        }
    }
}

const testing = std.testing;

fn testName(ctx: *anyopaque, pkg: PkgId) []const u8 {
    const repo: *pubgrub.TestRepo = @ptrCast(@alignCast(ctx));
    return repo.names.items[pkg];
}

fn explainFailure(repo: *pubgrub.TestRepo) ![]const u8 {
    var solver: pubgrub.Solver = .init(repo.arena, repo.provider());
    try testing.expectError(error.NoSolution, solver.solve());
    var out: Writer.Allocating = .init(repo.arena);
    try write(repo.arena, &out.writer, solver.incompats.items, solver.failure.?, .{ .ctx = repo, .nameFn = testName });
    return out.written();
}

test "explains a direct conflict" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var repo: pubgrub.TestRepo = try .init(arena_state.allocator());
    try repo.add("editor 1.0-r1", &.{"libui >=2"});
    try repo.add("libui 1.4-r2", &.{});
    try repo.request(&.{"editor"});
    try testing.expectEqualStrings(
        \\Because editor 1.0-r1 depends on libui >=2 and editor has no version other than 1.0-r1, editor requires libui >=2.
        \\And because no version of libui matches >=2, editor cannot be installed.
        \\So, because you asked for editor, what you asked for cannot be installed.
        \\
    , try explainFailure(&repo));
}

test "explains a missing package" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var repo: pubgrub.TestRepo = try .init(arena_state.allocator());
    try repo.request(&.{"ghost"});
    try testing.expectEqualStrings(
        \\Because you asked for ghost and no package named ghost exists, what you asked for cannot be installed.
        \\
    , try explainFailure(&repo));
}

test "explains two requests that cannot coexist" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var repo: pubgrub.TestRepo = try .init(arena_state.allocator());
    try repo.add("a 1.0-r1", &.{"shared >=2"});
    try repo.add("b 1.0-r1", &.{"shared <2"});
    try repo.add("shared 1.0-r1", &.{});
    try repo.add("shared 2.0-r1", &.{});
    try repo.request(&.{ "a", "b" });
    const text = try explainFailure(&repo);
    // The exact wording depends on derivation order; the facts must all be there.
    try testing.expect(std.mem.indexOf(u8, text, "a 1.0-r1 depends on shared >=2") != null);
    try testing.expect(std.mem.indexOf(u8, text, "b 1.0-r1 depends on shared <2") != null);
    try testing.expect(std.mem.endsWith(u8, text, "what you asked for cannot be installed.\n"));
}
