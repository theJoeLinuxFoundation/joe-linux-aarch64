//! PubGrub version solving, after Natalie Weizenbaum's description
//! (dart-lang/pub doc/solver.md) and the structure of pubgrub-rs.
//!
//! The solver knows nothing about repositories: a `Provider` supplies the
//! candidate versions and dependencies of each package. Everything is
//! allocated in one arena owned by the caller and released in one go.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Version = @import("version.zig").Version;
const Range = @import("range.zig").Range;

pub const PkgId = u32;
pub const IncompatId = u32;

/// The synthetic package standing for "what the user asked for". It has
/// exactly one version and its dependencies are the user's requests.
pub const root_pkg: PkgId = 0;
pub const root_version: Version = .{ .upstream = "0" };

/// A statement about one package. `positive` with range R means "selected, at
/// a version in R"; negative means "not selected, or at a version outside R".
pub const Term = struct {
    positive: bool,
    range: Range,

    /// True for every state of the package.
    pub const any: Term = .{ .positive = false, .range = .empty };

    pub fn exact(arena: Allocator, v: Version) Allocator.Error!Term {
        return .{ .positive = true, .range = try Range.exact(arena, v) };
    }

    pub fn negate(t: Term) Term {
        return .{ .positive = !t.positive, .range = t.range };
    }

    pub fn isAny(t: Term) bool {
        return !t.positive and t.range.isEmpty();
    }

    pub fn intersect(a: Term, arena: Allocator, b: Term) Allocator.Error!Term {
        if (a.positive and b.positive) return .{ .positive = true, .range = try a.range.intersection(arena, b.range) };
        if (!a.positive and !b.positive) return .{ .positive = false, .range = try a.range.unionWith(arena, b.range) };
        const pos = if (a.positive) a else b;
        const neg = if (a.positive) b else a;
        return .{ .positive = true, .range = try pos.range.intersection(arena, try neg.range.complement(arena)) };
    }

    pub fn unionWith(a: Term, arena: Allocator, b: Term) Allocator.Error!Term {
        return (try a.negate().intersect(arena, b.negate())).negate();
    }

    /// Whether every package state allowed by `a` is also allowed by `b`.
    pub fn subsetOf(a: Term, arena: Allocator, b: Term) Allocator.Error!bool {
        if (a.positive and b.positive) return a.range.subsetOf(arena, b.range);
        if (a.positive and !b.positive) return a.range.isDisjoint(arena, b.range);
        if (!a.positive and b.positive) return false;
        return b.range.subsetOf(arena, a.range);
    }

    /// Whether no package state satisfies both terms.
    pub fn disjointFrom(a: Term, arena: Allocator, b: Term) Allocator.Error!bool {
        const both = try a.intersect(arena, b);
        return both.positive and both.range.isEmpty();
    }
};

pub const PkgTerm = struct {
    pkg: PkgId,
    term: Term,
};

pub const DependencyKind = enum { requires, conflicts };

pub const Dependency = struct {
    pkg: PkgId,
    range: Range,
    kind: DependencyKind = .requires,
};

pub const Cause = union(enum) {
    /// The root package must be selected.
    root,
    /// No version of the package exists in the given range.
    no_versions,
    /// A package version requires (or conflicts with) another package.
    dependency: struct { pkg: PkgId, version: Version, on: PkgId, range: Range, kind: DependencyKind },
    /// Derived from two other incompatibilities by resolution.
    derived: struct { a: IncompatId, b: IncompatId },
};

/// A set of terms that cannot all be true at once. Terms are sorted by package
/// and there is at most one per package.
pub const Incompat = struct {
    terms: []const PkgTerm,
    cause: Cause,

    pub fn get(self: Incompat, pkg: PkgId) ?Term {
        for (self.terms) |t| if (t.pkg == pkg) return t.term;
        return null;
    }
};

pub const Provider = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The version to try for `pkg` among those in `range`, or null if the
        /// repositories hold none.
        chooseVersion: *const fn (ctx: *anyopaque, pkg: PkgId, range: Range) ?Version,
        dependencies: *const fn (ctx: *anyopaque, arena: Allocator, pkg: PkgId, version: Version) Allocator.Error![]const Dependency,
    };

    fn chooseVersion(p: Provider, pkg: PkgId, range: Range) ?Version {
        return p.vtable.chooseVersion(p.ctx, pkg, range);
    }

    fn dependencies(p: Provider, arena: Allocator, pkg: PkgId, version: Version) Allocator.Error![]const Dependency {
        return p.vtable.dependencies(p.ctx, arena, pkg, version);
    }
};

pub const Selected = struct {
    pkg: PkgId,
    version: Version,
};

const Assignment = struct {
    pkg: PkgId,
    term: Term,
    level: u32,
    /// Null for a decision; otherwise the incompatibility that forced it.
    cause: ?IncompatId,
};

const Relation = union(enum) {
    satisfied,
    contradicted,
    almost_satisfied: PkgId,
    inconclusive,
};

pub const Solver = struct {
    arena: Allocator,
    provider: Provider,

    incompats: std.ArrayList(Incompat) = .empty,
    /// For each package, the incompatibilities that mention it.
    by_pkg: std.AutoArrayHashMapUnmanaged(PkgId, std.ArrayList(IncompatId)) = .empty,

    trail: std.ArrayList(Assignment) = .empty,
    /// Intersection of every assignment on the trail, per package.
    accumulated: std.AutoArrayHashMapUnmanaged(PkgId, Term) = .empty,
    decisions: std.AutoArrayHashMapUnmanaged(PkgId, Version) = .empty,
    level: u32 = 0,

    /// Package versions whose dependencies are already recorded.
    expanded: std.ArrayList(Selected) = .empty,

    /// Set when `solve` fails: the incompatibility proving there is no solution.
    failure: ?IncompatId = null,

    pub const Error = Allocator.Error || error{NoSolution};

    pub fn init(arena: Allocator, provider: Provider) Solver {
        return .{ .arena = arena, .provider = provider };
    }

    /// Returns the selected version of every package except the root, in the
    /// order they were decided.
    pub fn solve(s: *Solver) Error![]const Selected {
        const not_root = try s.arena.alloc(PkgTerm, 1);
        not_root[0] = .{ .pkg = root_pkg, .term = (try Term.exact(s.arena, root_version)).negate() };
        _ = try s.addIncompat(.{ .terms = not_root, .cause = .root });

        var next: PkgId = root_pkg;
        while (true) {
            try s.unitPropagation(next);

            const pkg = s.pickPackage() orelse break;
            const wanted = s.accumulated.get(pkg).?.range;

            const version = s.provider.chooseVersion(pkg, wanted) orelse {
                const terms = try s.arena.alloc(PkgTerm, 1);
                terms[0] = .{ .pkg = pkg, .term = .{ .positive = true, .range = wanted } };
                _ = try s.addIncompat(.{ .terms = terms, .cause = .no_versions });
                next = pkg;
                continue;
            };
            std.debug.assert(wanted.contains(version));

            var conflict = false;
            if (!s.isExpanded(pkg, version)) {
                try s.expanded.append(s.arena, .{ .pkg = pkg, .version = version });
                const first_new: IncompatId = @intCast(s.incompats.items.len);
                const deps = try s.provider.dependencies(s.arena, pkg, version);
                for (deps) |dep| {
                    if (dep.pkg == pkg) continue;
                    try s.addDependencyIncompat(pkg, version, dep);
                }
                // If selecting this version would immediately satisfy one of its
                // own incompatibilities, do not decide; let propagation rule it out.
                const decision_term = try Term.exact(s.arena, version);
                var id = first_new;
                while (id < s.incompats.items.len) : (id += 1) {
                    if (try s.relationWith(s.incompats.items[id], pkg, decision_term) == .satisfied) {
                        conflict = true;
                        break;
                    }
                }
            }
            if (!conflict) try s.decide(pkg, version);
            next = pkg;
        }

        const out = try s.arena.alloc(Selected, s.decisions.count() - 1);
        var n: usize = 0;
        var it = s.decisions.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* == root_pkg) continue;
            out[n] = .{ .pkg = e.key_ptr.*, .version = e.value_ptr.* };
            n += 1;
        }
        return out;
    }

    fn isExpanded(s: *Solver, pkg: PkgId, version: Version) bool {
        for (s.expanded.items) |e| {
            if (e.pkg == pkg and e.version.eql(version)) return true;
        }
        return false;
    }

    fn addDependencyIncompat(s: *Solver, pkg: PkgId, version: Version, dep: Dependency) Allocator.Error!void {
        const cause: Cause = .{ .dependency = .{ .pkg = pkg, .version = version, .on = dep.pkg, .range = dep.range, .kind = dep.kind } };
        const self_term: PkgTerm = .{ .pkg = pkg, .term = try Term.exact(s.arena, version) };
        if (dep.range.isEmpty()) {
            // Conflicting with nothing constrains nothing. Requiring a version
            // from an empty range can never be met, so this package version is
            // unusable on its own; a term that is always true must not be
            // recorded, because nothing on the trail would ever account for it.
            if (dep.kind == .conflicts) return;
            const only = try s.arena.alloc(PkgTerm, 1);
            only[0] = self_term;
            _ = try s.addIncompat(.{ .terms = only, .cause = cause });
            return;
        }
        const terms = try s.arena.alloc(PkgTerm, 2);
        // "requires": pkg@version together with "dep not in range" is impossible.
        // "conflicts": pkg@version together with "dep in range" is impossible.
        const dep_term: PkgTerm = .{ .pkg = dep.pkg, .term = .{ .positive = dep.kind == .conflicts, .range = dep.range } };
        if (pkg < dep.pkg) {
            terms[0] = self_term;
            terms[1] = dep_term;
        } else {
            terms[0] = dep_term;
            terms[1] = self_term;
        }
        _ = try s.addIncompat(.{ .terms = terms, .cause = cause });
    }

    fn addIncompat(s: *Solver, incompat: Incompat) Allocator.Error!IncompatId {
        const id: IncompatId = @intCast(s.incompats.items.len);
        try s.incompats.append(s.arena, incompat);
        for (incompat.terms) |t| {
            const gop = try s.by_pkg.getOrPut(s.arena, t.pkg);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(s.arena, id);
        }
        return id;
    }

    /// The next package to decide: one that must be selected but has no version yet.
    fn pickPackage(s: *Solver) ?PkgId {
        var it = s.accumulated.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.positive and !s.decisions.contains(e.key_ptr.*)) return e.key_ptr.*;
        }
        return null;
    }

    fn decide(s: *Solver, pkg: PkgId, version: Version) Allocator.Error!void {
        s.level += 1;
        try s.decisions.put(s.arena, pkg, version);
        try s.assign(.{ .pkg = pkg, .term = try Term.exact(s.arena, version), .level = s.level, .cause = null });
    }

    fn derive(s: *Solver, pkg: PkgId, cause: IncompatId) Allocator.Error!void {
        const term = s.incompats.items[cause].get(pkg).?.negate();
        try s.assign(.{ .pkg = pkg, .term = term, .level = s.level, .cause = cause });
    }

    fn assign(s: *Solver, a: Assignment) Allocator.Error!void {
        try s.trail.append(s.arena, a);
        const gop = try s.accumulated.getOrPut(s.arena, a.pkg);
        gop.value_ptr.* = if (gop.found_existing) try gop.value_ptr.intersect(s.arena, a.term) else a.term;
    }

    fn backtrack(s: *Solver, level: u32) Allocator.Error!void {
        while (s.trail.items.len > 0 and s.trail.items[s.trail.items.len - 1].level > level) {
            _ = s.trail.pop();
        }
        s.level = level;
        s.accumulated.clearRetainingCapacity();
        s.decisions.clearRetainingCapacity();
        for (s.trail.items) |a| {
            const gop = try s.accumulated.getOrPut(s.arena, a.pkg);
            gop.value_ptr.* = if (gop.found_existing) try gop.value_ptr.intersect(s.arena, a.term) else a.term;
            if (a.cause == null) try s.decisions.put(s.arena, a.pkg, a.term.range.intervals[0].lo.inclusive);
        }
    }

    fn relation(s: *Solver, incompat: Incompat) Allocator.Error!Relation {
        return s.relationWith(incompat, null, undefined);
    }

    /// Relation of the partial solution to `incompat`, optionally pretending
    /// that `extra_pkg` additionally has `extra_term` assigned.
    fn relationWith(s: *Solver, incompat: Incompat, extra_pkg: ?PkgId, extra_term: Term) Allocator.Error!Relation {
        var unsatisfied: ?PkgId = null;
        for (incompat.terms) |t| {
            var have: Term = s.accumulated.get(t.pkg) orelse .any;
            if (extra_pkg != null and extra_pkg.? == t.pkg) have = try have.intersect(s.arena, extra_term);
            if (try have.subsetOf(s.arena, t.term)) continue;
            if (try have.disjointFrom(s.arena, t.term)) return .contradicted;
            if (unsatisfied != null) return .inconclusive;
            unsatisfied = t.pkg;
        }
        return if (unsatisfied) |pkg| .{ .almost_satisfied = pkg } else .satisfied;
    }

    fn unitPropagation(s: *Solver, start: PkgId) Error!void {
        var changed: std.ArrayList(PkgId) = .empty;
        try changed.append(s.arena, start);
        while (changed.pop()) |pkg| {
            var conflict: ?IncompatId = null;
            const list = s.by_pkg.get(pkg) orelse continue;
            var i = list.items.len;
            while (i > 0) {
                i -= 1;
                const id = list.items[i];
                switch (try s.relation(s.incompats.items[id])) {
                    .satisfied => {
                        conflict = id;
                        break;
                    },
                    .almost_satisfied => |other| {
                        try s.derive(other, id);
                        if (std.mem.indexOfScalar(PkgId, changed.items, other) == null) try changed.append(s.arena, other);
                    },
                    .contradicted, .inconclusive => {},
                }
            }
            if (conflict) |id| {
                const resolved = try s.resolveConflict(id);
                changed.clearRetainingCapacity();
                try s.derive(resolved.pkg, resolved.incompat);
                try changed.append(s.arena, resolved.pkg);
            }
        }
    }

    const Resolved = struct { pkg: PkgId, incompat: IncompatId };

    fn resolveConflict(s: *Solver, conflict: IncompatId) Error!Resolved {
        var current = conflict;
        while (true) {
            const incompat = s.incompats.items[current];
            if (isTerminal(incompat)) {
                s.failure = current;
                return error.NoSolution;
            }
            const found = try s.findSatisfier(incompat);
            const satisfier = s.trail.items[found.index];
            if (satisfier.cause == null or found.previous_level < satisfier.level) {
                try s.backtrack(found.previous_level);
                return .{ .pkg = satisfier.pkg, .incompat = current };
            }
            current = try s.addIncompat(try s.priorCause(current, satisfier.cause.?, satisfier.pkg));
        }
    }

    fn isTerminal(incompat: Incompat) bool {
        if (incompat.terms.len == 0) return true;
        if (incompat.terms.len > 1) return false;
        const t = incompat.terms[0];
        return t.pkg == root_pkg and t.term.positive and t.term.range.contains(root_version);
    }

    const Satisfier = struct {
        /// Trail index of the earliest assignment after which the
        /// incompatibility is satisfied.
        index: usize,
        /// Decision level of the earliest assignment that, together with the
        /// satisfier, satisfies the incompatibility (at least 1).
        previous_level: u32,
    };

    fn findSatisfier(s: *Solver, incompat: Incompat) Allocator.Error!Satisfier {
        var index: usize = 0;
        for (incompat.terms) |t| {
            index = @max(index, (try s.satisfierOf(t, null)).?);
        }
        const satisfier = s.trail.items[index];

        var previous_level: u32 = 1;
        for (incompat.terms) |t| {
            const prev = if (t.pkg == satisfier.pkg)
                try s.satisfierOf(t, index)
            else
                try s.satisfierOf(t, null);
            if (prev) |p| previous_level = @max(previous_level, s.trail.items[p].level);
        }
        return .{ .index = index, .previous_level = previous_level };
    }

    /// Index of the earliest assignment after which the trail satisfies `t`.
    /// With `given`, that assignment is assumed from the start and only earlier
    /// ones are searched; null then means it satisfies `t` on its own.
    fn satisfierOf(s: *Solver, t: PkgTerm, given: ?usize) Allocator.Error!?usize {
        var acc: Term = .any;
        var end = s.trail.items.len;
        if (given) |g| {
            acc = s.trail.items[g].term;
            end = g;
            if (try acc.subsetOf(s.arena, t.term)) return null;
        }
        for (s.trail.items[0..end], 0..) |a, i| {
            if (a.pkg != t.pkg) continue;
            acc = try acc.intersect(s.arena, a.term);
            if (try acc.subsetOf(s.arena, t.term)) return i;
        }
        // Callers only ask about incompatibilities the trail satisfies.
        unreachable;
    }

    /// Resolution: combines an incompatibility with the cause of its satisfier,
    /// eliminating the satisfier's package where the two cover every case.
    fn priorCause(s: *Solver, a_id: IncompatId, b_id: IncompatId, pivot: PkgId) Allocator.Error!Incompat {
        const a = s.incompats.items[a_id];
        const b = s.incompats.items[b_id];
        var terms: std.ArrayList(PkgTerm) = .empty;
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.terms.len or j < b.terms.len) {
            const take_a = j >= b.terms.len or (i < a.terms.len and a.terms[i].pkg <= b.terms[j].pkg);
            const take_b = i >= a.terms.len or (j < b.terms.len and b.terms[j].pkg <= a.terms[i].pkg);
            const pkg = if (take_a) a.terms[i].pkg else b.terms[j].pkg;
            var term: Term = undefined;
            if (take_a and take_b) {
                term = if (pkg == pivot)
                    try a.terms[i].term.unionWith(s.arena, b.terms[j].term)
                else
                    try a.terms[i].term.intersect(s.arena, b.terms[j].term);
            } else if (take_a) {
                term = a.terms[i].term;
            } else {
                term = b.terms[j].term;
            }
            if (take_a) i += 1;
            if (take_b) j += 1;
            if (pkg == pivot and term.isAny()) continue;
            try terms.append(s.arena, .{ .pkg = pkg, .term = term });
        }
        return .{ .terms = terms.items, .cause = .{ .derived = .{ .a = a_id, .b = b_id } } };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// An in-memory repository for tests. Package 0 is the root.
pub const TestRepo = struct {
    arena: Allocator,
    names: std.ArrayList([]const u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    prefer_oldest: bool = false,

    pub const Entry = struct {
        pkg: PkgId,
        version: Version,
        deps: std.ArrayList(Dependency) = .empty,
    };

    pub fn init(arena: Allocator) !TestRepo {
        var r: TestRepo = .{ .arena = arena };
        try r.names.append(arena, "root");
        try r.entries.append(arena, .{ .pkg = root_pkg, .version = root_version });
        return r;
    }

    pub fn id(r: *TestRepo, name: []const u8) !PkgId {
        for (r.names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
        try r.names.append(r.arena, name);
        return @intCast(r.names.items.len - 1);
    }

    /// `spec` is "name version"; each dep is "name constraint" or "!name constraint".
    pub fn add(r: *TestRepo, spec: []const u8, deps: []const []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, spec, ' ');
        const pkg = try r.id(it.next().?);
        var entry: Entry = .{ .pkg = pkg, .version = try Version.parse(it.next().?) };
        for (deps) |d| try entry.deps.append(r.arena, try r.dep(d));
        try r.entries.append(r.arena, entry);
    }

    pub fn request(r: *TestRepo, deps: []const []const u8) !void {
        for (deps) |d| try r.entries.items[0].deps.append(r.arena, try r.dep(d));
    }

    fn dep(r: *TestRepo, text: []const u8) !Dependency {
        const conflicts = text[0] == '!';
        const body = if (conflicts) text[1..] else text;
        const space = std.mem.indexOfScalar(u8, body, ' ') orelse body.len;
        return .{
            .pkg = try r.id(body[0..space]),
            .range = try Range.parse(r.arena, body[space..]),
            .kind = if (conflicts) .conflicts else .requires,
        };
    }

    pub fn provider(r: *TestRepo) Provider {
        return .{ .ctx = r, .vtable = &.{ .chooseVersion = chooseVersion, .dependencies = dependencies } };
    }

    fn chooseVersion(ctx: *anyopaque, pkg: PkgId, range: Range) ?Version {
        const r: *TestRepo = @ptrCast(@alignCast(ctx));
        var best: ?Version = null;
        for (r.entries.items) |e| {
            if (e.pkg != pkg or !range.contains(e.version)) continue;
            if (best == null or (e.version.order(best.?) == .gt) != r.prefer_oldest) best = e.version;
        }
        return best;
    }

    fn dependencies(ctx: *anyopaque, arena: Allocator, pkg: PkgId, version: Version) Allocator.Error![]const Dependency {
        _ = arena;
        const r: *TestRepo = @ptrCast(@alignCast(ctx));
        for (r.entries.items) |e| {
            if (e.pkg == pkg and e.version.eql(version)) return e.deps.items;
        }
        unreachable;
    }

    /// Whether a complete selection (null = not installed) is a valid solution.
    fn valid(r: *TestRepo, chosen: []const ?Version) bool {
        for (r.entries.items) |e| {
            const sel = chosen[e.pkg] orelse continue;
            if (!sel.eql(e.version)) continue;
            for (e.deps.items) |d| {
                const have = chosen[d.pkg];
                const in_range = have != null and d.range.contains(have.?);
                if ((d.kind == .requires) != in_range) return false;
            }
        }
        return true;
    }

    /// Exhaustive search, for checking the solver on small repositories.
    fn bruteForce(r: *TestRepo, chosen: []?Version, pkg: usize) bool {
        if (pkg == chosen.len) return r.valid(chosen);
        if (pkg != root_pkg) {
            chosen[pkg] = null;
            if (r.bruteForce(chosen, pkg + 1)) return true;
        }
        for (r.entries.items) |e| {
            if (e.pkg != pkg) continue;
            chosen[pkg] = e.version;
            if (r.bruteForce(chosen, pkg + 1)) return true;
        }
        return false;
    }
};

fn expectSolution(repo: *TestRepo, expected: []const []const u8) !void {
    var solver: Solver = .init(repo.arena, repo.provider());
    const solution = try solver.solve();
    try testing.expectEqual(expected.len, solution.len);
    for (expected) |spec| {
        var it = std.mem.tokenizeScalar(u8, spec, ' ');
        const pkg = try repo.id(it.next().?);
        const version = try Version.parse(it.next().?);
        var found = false;
        for (solution) |sel| {
            if (sel.pkg == pkg) {
                try testing.expect(sel.version.eql(version));
                found = true;
            }
        }
        try testing.expect(found);
    }
}

test "simple chain picks newest versions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var repo: TestRepo = try .init(arena_state.allocator());
    try repo.add("a 1.0-r1", &.{"b >=1"});
    try repo.add("a 2.0-r1", &.{"b >=2"});
    try repo.add("b 1.0-r1", &.{});
    try repo.add("b 2.0-r1", &.{});
    try repo.add("b 3.0-r1", &.{});
    try repo.add("unrelated 1.0-r1", &.{});
    try repo.request(&.{"a"});
    try expectSolution(&repo, &.{ "a 2.0-r1", "b 3.0-r1" });
}

test "backtracks from the newest version when it cannot work" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var repo: TestRepo = try .init(arena_state.allocator());
    // The classic example from the PubGrub write-up.
    try repo.add("menu 1.5", &.{"dropdown >=2"});
    try repo.add("menu 1.0", &.{"dropdown <2"});
    try repo.add("dropdown 2.3", &.{"icons >=2"});
    try repo.add("dropdown 1.8", &.{"intl >=3"});
    try repo.add("icons 2.0", &.{});
    try repo.add("icons 1.0", &.{});
    try repo.add("intl 5.0", &.{});
    try repo.add("intl 3.0", &.{});
    try repo.request(&.{ "menu", "icons <2", "intl <4" });
    try expectSolution(&repo, &.{ "menu 1.0", "dropdown 1.8", "icons 1.0", "intl 3.0" });
}

test "conflicts are honoured" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var repo: TestRepo = try .init(arena_state.allocator());
    try repo.add("a 2.0", &.{"!b >=2"});
    try repo.add("a 1.0", &.{});
    try repo.add("b 2.0", &.{});
    try repo.add("b 1.0", &.{});
    try repo.request(&.{ "a", "b >=2" });
    try expectSolution(&repo, &.{ "a 1.0", "b 2.0" });
}

test "unsolvable requests fail" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var repo: TestRepo = try .init(arena_state.allocator());
    try repo.add("a 1.0", &.{"shared >=2"});
    try repo.add("b 1.0", &.{"shared <2"});
    try repo.add("shared 1.0", &.{});
    try repo.add("shared 2.0", &.{});
    try repo.request(&.{ "a", "b" });
    var solver: Solver = .init(repo.arena, repo.provider());
    try testing.expectError(error.NoSolution, solver.solve());
    try testing.expect(solver.failure != null);

    var missing: TestRepo = try .init(arena_state.allocator());
    try missing.request(&.{"ghost"});
    var solver2: Solver = .init(missing.arena, missing.provider());
    try testing.expectError(error.NoSolution, solver2.solve());
}

test "a dependency on an empty range makes only that version unusable" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var repo: TestRepo = try .init(arena_state.allocator());
    try repo.add("a 2.0", &.{"b >=3 <2"});
    try repo.add("a 1.0", &.{ "b", "!c >=3 <2" });
    try repo.add("b 1.0", &.{});
    try repo.add("c 1.0", &.{});
    try repo.request(&.{ "a", "c" });
    try expectSolution(&repo, &.{ "a 1.0", "b 1.0", "c 1.0" });

    var hopeless: TestRepo = try .init(arena_state.allocator());
    try hopeless.add("a 1.0", &.{"b >=3 <2"});
    try hopeless.add("b 1.0", &.{});
    try hopeless.request(&.{"a"});
    var solver: Solver = .init(hopeless.arena, hopeless.provider());
    try testing.expectError(error.NoSolution, solver.solve());
}

test "agrees with exhaustive search on random repositories" {
    var prng: std.Random.DefaultPrng = .init(0xdabe);
    const rand = prng.random();
    const names = [_][]const u8{ "a", "b", "c", "d", "e" };
    const versions = [_][]const u8{ "1", "2", "3" };
    const constraints = [_][]const u8{ "", ">=2", "<2", "=1", "=2", "=3", ">=3", "<3", ">1 <3", ">=3 <2" };

    var solvable: usize = 0;
    var unsolvable: usize = 0;
    for (0..3000) |round| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var repo: TestRepo = try .init(arena);
        repo.prefer_oldest = round % 2 == 1;
        const pkg_count = 2 + rand.uintLessThan(usize, names.len - 1);
        for (names[0..pkg_count]) |name| {
            _ = try repo.id(name);
            for (versions) |ver| {
                if (rand.uintLessThan(u8, 4) == 0) continue;
                var deps: std.ArrayList([]const u8) = .empty;
                for (names[0..pkg_count]) |other| {
                    if (std.mem.eql(u8, other, name) or rand.uintLessThan(u8, 3) != 0) continue;
                    const bang = if (rand.uintLessThan(u8, 5) == 0) "!" else "";
                    const c = constraints[rand.uintLessThan(usize, constraints.len)];
                    try deps.append(arena, try std.fmt.allocPrint(arena, "{s}{s} {s}", .{ bang, other, c }));
                }
                try repo.add(try std.fmt.allocPrint(arena, "{s} {s}", .{ name, ver }), deps.items);
            }
        }
        var wants: std.ArrayList([]const u8) = .empty;
        for (names[0..pkg_count]) |name| {
            if (rand.uintLessThan(u8, 2) == 0) continue;
            const c = constraints[rand.uintLessThan(usize, constraints.len)];
            try wants.append(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ name, c }));
        }
        try repo.request(wants.items);

        const chosen = try arena.alloc(?Version, repo.names.items.len);
        @memset(chosen, null);
        const exists = repo.bruteForce(chosen, 0);

        var solver: Solver = .init(arena, repo.provider());
        if (solver.solve()) |solution| {
            try testing.expect(exists);
            @memset(chosen, null);
            chosen[root_pkg] = root_version;
            for (solution) |sel| chosen[sel.pkg] = sel.version;
            try testing.expect(repo.valid(chosen));
            solvable += 1;
        } else |err| {
            try testing.expectEqual(error.NoSolution, err);
            try testing.expect(!exists);
            unsolvable += 1;
        }
    }
    // The generator must exercise both outcomes for the comparison to mean anything.
    try testing.expect(solvable > 300);
    try testing.expect(unsolvable > 300);
}
