//! Sets of versions, represented as a sorted list of disjoint, non-adjacent
//! intervals. All results are allocated in the arena passed in and are never
//! freed individually; the solver owns one arena for its whole run.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Version = @import("version.zig").Version;

pub const Bound = union(enum) {
    unbounded,
    inclusive: Version,
    exclusive: Version,
};

pub const Interval = struct {
    lo: Bound,
    hi: Bound,
};

pub const Range = struct {
    intervals: []const Interval,

    pub const empty: Range = .{ .intervals = &.{} };
    pub const full: Range = .{ .intervals = &.{.{ .lo = .unbounded, .hi = .unbounded }} };

    pub fn exact(arena: Allocator, v: Version) Allocator.Error!Range {
        return one(arena, .{ .inclusive = v }, .{ .inclusive = v });
    }

    pub fn atLeast(arena: Allocator, v: Version) Allocator.Error!Range {
        return one(arena, .{ .inclusive = v }, .unbounded);
    }

    pub fn greaterThan(arena: Allocator, v: Version) Allocator.Error!Range {
        return one(arena, .{ .exclusive = v }, .unbounded);
    }

    pub fn atMost(arena: Allocator, v: Version) Allocator.Error!Range {
        return one(arena, .unbounded, .{ .inclusive = v });
    }

    pub fn lessThan(arena: Allocator, v: Version) Allocator.Error!Range {
        return one(arena, .unbounded, .{ .exclusive = v });
    }

    /// A single interval; yields the empty range if the bounds admit nothing.
    pub fn one(arena: Allocator, lo: Bound, hi: Bound) Allocator.Error!Range {
        if (!validInterval(lo, hi)) return empty;
        const list = try arena.alloc(Interval, 1);
        list[0] = .{ .lo = lo, .hi = hi };
        return .{ .intervals = list };
    }

    pub fn isEmpty(r: Range) bool {
        return r.intervals.len == 0;
    }

    pub fn isFull(r: Range) bool {
        return r.intervals.len == 1 and r.intervals[0].lo == .unbounded and r.intervals[0].hi == .unbounded;
    }

    pub fn contains(r: Range, v: Version) bool {
        for (r.intervals) |iv| {
            if (aboveLo(iv.lo, v) and belowHi(iv.hi, v)) return true;
        }
        return false;
    }

    pub fn complement(r: Range, arena: Allocator) Allocator.Error!Range {
        var out: std.ArrayList(Interval) = .empty;
        var lo: ?Bound = .unbounded; // null once the previous interval reached +infinity
        for (r.intervals) |iv| {
            const hi: ?Bound = switch (iv.lo) {
                .unbounded => null,
                .inclusive => |v| .{ .exclusive = v },
                .exclusive => |v| .{ .inclusive = v },
            };
            if (hi) |h| {
                if (validInterval(lo.?, h)) try out.append(arena, .{ .lo = lo.?, .hi = h });
            }
            lo = switch (iv.hi) {
                .unbounded => null,
                .inclusive => |v| .{ .exclusive = v },
                .exclusive => |v| .{ .inclusive = v },
            };
        }
        if (lo) |l| try out.append(arena, .{ .lo = l, .hi = .unbounded });
        return .{ .intervals = out.items };
    }

    pub fn intersection(a: Range, arena: Allocator, b: Range) Allocator.Error!Range {
        var out: std.ArrayList(Interval) = .empty;
        var i: usize = 0;
        var j: usize = 0;
        while (i < a.intervals.len and j < b.intervals.len) {
            const x = a.intervals[i];
            const y = b.intervals[j];
            const lo = if (loLess(x.lo, y.lo)) y.lo else x.lo;
            const hi = if (hiLess(x.hi, y.hi)) x.hi else y.hi;
            if (validInterval(lo, hi)) try out.append(arena, .{ .lo = lo, .hi = hi });
            // Advance whichever interval ends first.
            if (hiLess(x.hi, y.hi)) i += 1 else j += 1;
        }
        return .{ .intervals = out.items };
    }

    pub fn unionWith(a: Range, arena: Allocator, b: Range) Allocator.Error!Range {
        const na = try a.complement(arena);
        const nb = try b.complement(arena);
        return (try na.intersection(arena, nb)).complement(arena);
    }

    pub fn eql(a: Range, b: Range) bool {
        if (a.intervals.len != b.intervals.len) return false;
        for (a.intervals, b.intervals) |x, y| {
            if (!boundEql(x.lo, y.lo) or !boundEql(x.hi, y.hi)) return false;
        }
        return true;
    }

    pub fn subsetOf(a: Range, arena: Allocator, b: Range) Allocator.Error!bool {
        return (try a.intersection(arena, b)).eql(a);
    }

    pub fn isDisjoint(a: Range, arena: Allocator, b: Range) Allocator.Error!bool {
        return (try a.intersection(arena, b)).isEmpty();
    }

    /// Parses a constraint such as `>=2.44`, `<3`, `=1.2-r1`, `>=1.0 <2.0`
    /// (space or comma separated terms are intersected) or `*` / empty for any.
    /// `=X` without a release matches every release of X.
    pub fn parse(arena: Allocator, text: []const u8) (Allocator.Error || Version.ParseError)!Range {
        var result: Range = full;
        var it = std.mem.tokenizeAny(u8, text, " ,");
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "*")) continue;
            const term: Range = if (std.mem.startsWith(u8, tok, ">="))
                try atLeast(arena, try Version.parse(tok[2..]))
            else if (std.mem.startsWith(u8, tok, "<="))
                try atMost(arena, try upperOf(tok[2..]))
            else if (std.mem.startsWith(u8, tok, ">"))
                try greaterThan(arena, try upperOf(tok[1..]))
            else if (std.mem.startsWith(u8, tok, "<"))
                try lessThan(arena, try Version.parse(tok[1..]))
            else blk: {
                const body = if (std.mem.startsWith(u8, tok, "=")) tok[1..] else tok;
                break :blk try one(arena, .{ .inclusive = try Version.parse(body) }, .{ .inclusive = try upperOf(body) });
            };
            result = try result.intersection(arena, term);
        }
        return result;
    }

    /// The highest version a release-less constraint refers to: `1.0` means
    /// "any release of 1.0", so its upper end is the largest release.
    fn upperOf(text: []const u8) Version.ParseError!Version {
        var v = try Version.parse(text);
        if (std.mem.lastIndexOf(u8, text, "-r") == null) v.release = std.math.maxInt(u32);
        return v;
    }

    pub fn format(r: Range, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (r.isEmpty()) return w.writeAll("no version");
        if (r.isFull()) return w.writeAll("any version");
        for (r.intervals, 0..) |iv, n| {
            if (n > 0) try w.writeAll(" or ");
            if (iv.lo == .inclusive and iv.hi == .inclusive) {
                const lo = iv.lo.inclusive;
                const hi = iv.hi.inclusive;
                if (lo.eql(hi)) {
                    try w.print("{f}", .{lo});
                    continue;
                }
                if (lo.release == 0 and hi.release == std.math.maxInt(u32) and
                    (Version{ .upstream = lo.upstream }).eql(.{ .upstream = hi.upstream }))
                {
                    try w.writeAll(lo.upstream);
                    continue;
                }
            }
            var wrote = false;
            switch (iv.lo) {
                .unbounded => {},
                .inclusive => |v| {
                    try w.writeAll(">=");
                    try writeBoundVersion(w, v);
                    wrote = true;
                },
                .exclusive => |v| {
                    try w.writeAll(">");
                    try writeBoundVersion(w, v);
                    wrote = true;
                },
            }
            switch (iv.hi) {
                .unbounded => {},
                .inclusive => |v| {
                    if (wrote) try w.writeAll(" ");
                    try w.writeAll("<=");
                    try writeBoundVersion(w, v);
                },
                .exclusive => |v| {
                    if (wrote) try w.writeAll(" ");
                    try w.writeAll("<");
                    try writeBoundVersion(w, v);
                },
            }
        }
    }
};

fn writeBoundVersion(w: *std.Io.Writer, v: Version) std.Io.Writer.Error!void {
    if (v.release == 0 or v.release == std.math.maxInt(u32)) return w.writeAll(v.upstream);
    try w.print("{f}", .{v});
}

fn boundEql(a: Bound, b: Bound) bool {
    return switch (a) {
        .unbounded => b == .unbounded,
        .inclusive => |v| b == .inclusive and v.eql(b.inclusive),
        .exclusive => |v| b == .exclusive and v.eql(b.exclusive),
    };
}

fn aboveLo(lo: Bound, v: Version) bool {
    return switch (lo) {
        .unbounded => true,
        .inclusive => |l| v.order(l) != .lt,
        .exclusive => |l| v.order(l) == .gt,
    };
}

fn belowHi(hi: Bound, v: Version) bool {
    return switch (hi) {
        .unbounded => true,
        .inclusive => |h| v.order(h) != .gt,
        .exclusive => |h| v.order(h) == .lt,
    };
}

/// True if a lower bound `a` starts strictly before lower bound `b`.
fn loLess(a: Bound, b: Bound) bool {
    return switch (a) {
        .unbounded => b != .unbounded,
        .inclusive => |x| switch (b) {
            .unbounded => false,
            .inclusive => |y| x.order(y) == .lt,
            .exclusive => |y| x.order(y) != .gt,
        },
        .exclusive => |x| switch (b) {
            .unbounded => false,
            .inclusive, .exclusive => |y| x.order(y) == .lt,
        },
    };
}

/// True if an upper bound `a` ends strictly before upper bound `b`.
fn hiLess(a: Bound, b: Bound) bool {
    return switch (a) {
        .unbounded => false,
        .inclusive => |x| switch (b) {
            .unbounded => true,
            .inclusive, .exclusive => |y| x.order(y) == .lt,
        },
        .exclusive => |x| switch (b) {
            .unbounded => true,
            .inclusive => |y| x.order(y) != .gt,
            .exclusive => |y| x.order(y) == .lt,
        },
    };
}

fn validInterval(lo: Bound, hi: Bound) bool {
    const l = switch (lo) {
        .unbounded => return true,
        .inclusive, .exclusive => |v| v,
    };
    const h = switch (hi) {
        .unbounded => return true,
        .inclusive, .exclusive => |v| v,
    };
    return switch (l.order(h)) {
        .lt => true,
        .gt => false,
        .eq => lo == .inclusive and hi == .inclusive,
    };
}

const testing = std.testing;

fn ver(text: []const u8) Version {
    return Version.parse(text) catch unreachable;
}

test "parse and contains" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try Range.parse(arena, ">=1.0 <2.0");
    try testing.expect(r.contains(ver("1.0-r1")));
    try testing.expect(r.contains(ver("1.9.9-r4")));
    try testing.expect(!r.contains(ver("2.0-r0")));
    try testing.expect(!r.contains(ver("0.9-r9")));

    const eq = try Range.parse(arena, "=2.44");
    try testing.expect(eq.contains(ver("2.44-r0")));
    try testing.expect(eq.contains(ver("2.44-r7")));
    try testing.expect(!eq.contains(ver("2.44.1-r1")));

    const pinned = try Range.parse(arena, "=2.44-r2");
    try testing.expect(pinned.contains(ver("2.44-r2")));
    try testing.expect(!pinned.contains(ver("2.44-r3")));

    // ">1.0" excludes every release of 1.0; "<=1.0" includes every release.
    try testing.expect(!(try Range.parse(arena, ">1.0")).contains(ver("1.0-r5")));
    try testing.expect((try Range.parse(arena, "<=1.0")).contains(ver("1.0-r5")));

    try testing.expect((try Range.parse(arena, "")).isFull());
    try testing.expect((try Range.parse(arena, "*")).isFull());
    try testing.expect((try Range.parse(arena, ">=2 <1")).isEmpty());
}

test "set algebra" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try Range.parse(arena, ">=1 <3");
    const b = try Range.parse(arena, ">=2 <4");
    const i = try a.intersection(arena, b);
    try testing.expect(i.eql(try Range.parse(arena, ">=2 <3")));
    const u = try a.unionWith(arena, b);
    try testing.expect(u.eql(try Range.parse(arena, ">=1 <4")));

    const c = try a.complement(arena);
    try testing.expect(c.contains(ver("0.5")));
    try testing.expect(!c.contains(ver("1")));
    try testing.expect(c.contains(ver("3")));
    try testing.expect((try c.complement(arena)).eql(a));
    try testing.expect((try a.intersection(arena, c)).isEmpty());
    try testing.expect((try a.unionWith(arena, c)).isFull());

    try testing.expect((try Range.full.complement(arena)).isEmpty());
    try testing.expect((try Range.empty.complement(arena)).isFull());
    try testing.expect(try i.subsetOf(arena, a));
    try testing.expect(!try a.subsetOf(arena, i));

    // Adjacent pieces merge into one interval.
    const lo = try Range.parse(arena, "<2");
    const hi = try Range.parse(arena, ">=2");
    try testing.expect((try lo.unionWith(arena, hi)).isFull());
}

test "algebra laws on random ranges" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var prng: std.Random.DefaultPrng = .init(0x6a6f65);
    const rand = prng.random();
    const points = [_][]const u8{ "1", "2", "3", "4", "5", "6" };

    const gen = struct {
        fn range(al: Allocator, r: std.Random, pts: []const []const u8) !Range {
            var out: Range = .empty;
            const n = r.uintLessThan(u8, 3);
            for (0..n) |_| {
                const x = ver(pts[r.uintLessThan(usize, pts.len)]);
                const y = ver(pts[r.uintLessThan(usize, pts.len)]);
                const lo: Bound = switch (r.uintLessThan(u8, 3)) {
                    0 => .unbounded,
                    1 => .{ .inclusive = x },
                    else => .{ .exclusive = x },
                };
                const hi: Bound = switch (r.uintLessThan(u8, 3)) {
                    0 => .unbounded,
                    1 => .{ .inclusive = y },
                    else => .{ .exclusive = y },
                };
                out = try out.unionWith(al, try Range.one(al, lo, hi));
            }
            return out;
        }
    };

    for (0..2000) |_| {
        const a = try gen.range(arena, rand, &points);
        const b = try gen.range(arena, rand, &points);
        const inter = try a.intersection(arena, b);
        const uni = try a.unionWith(arena, b);
        const na = try a.complement(arena);
        // Membership agrees with the set definition at and between every point.
        const probes = [_][]const u8{ "0", "1", "1.5", "2", "2.5", "3", "3.5", "4", "4.5", "5", "5.5", "6", "7" };
        for (probes) |p| {
            const pv = ver(p);
            try testing.expectEqual(a.contains(pv) and b.contains(pv), inter.contains(pv));
            try testing.expectEqual(a.contains(pv) or b.contains(pv), uni.contains(pv));
            try testing.expectEqual(!a.contains(pv), na.contains(pv));
        }
        // Canonical form: equal sets have equal representations.
        try testing.expect((try na.complement(arena)).eql(a));
        try testing.expect((try b.intersection(arena, a)).eql(inter));
        _ = arena_state.reset(.retain_capacity);
    }
}

test "format" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [128]u8 = undefined;

    try testing.expectEqualStrings(">=1.0 <2.0", try std.fmt.bufPrint(&buf, "{f}", .{try Range.parse(arena, ">=1.0 <2.0")}));
    try testing.expectEqualStrings("2.44", try std.fmt.bufPrint(&buf, "{f}", .{try Range.parse(arena, "=2.44")}));
    try testing.expectEqualStrings("2.44-r2", try std.fmt.bufPrint(&buf, "{f}", .{try Range.parse(arena, "=2.44-r2")}));
    try testing.expectEqualStrings("any version", try std.fmt.bufPrint(&buf, "{f}", .{Range.full}));
}
