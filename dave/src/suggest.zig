//! "Did you mean": the names closest to one somebody mistyped.
//!
//! Closeness is the optimal string alignment distance (insertions, deletions,
//! substitutions and swaps of two neighbouring letters, each costing one),
//! ignoring case. A short word may be one edit away, a longer one more, so
//! that `isntall` finds `install` but `ls` does not find `gc`. A word that
//! begins or (when it is long enough to mean something) appears within a name
//! also counts, since people often type part of a package name.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Longer words are never close to anything (package names are at most 128).
const max_len = 128;
const far = std.math.maxInt(usize) / 2;

pub fn distance(a: []const u8, b: []const u8) usize {
    if (a.len > max_len or b.len > max_len) return far;
    var rows: [3][max_len + 1]usize = undefined;
    var before = &rows[0];
    var prev = &rows[1];
    var cur = &rows[2];
    for (0..b.len + 1) |j| prev[j] = j;
    for (1..a.len + 1) |i| {
        cur[0] = i;
        for (1..b.len + 1) |j| {
            const cost: usize = if (lower(a[i - 1]) == lower(b[j - 1])) 0 else 1;
            var d = @min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost);
            if (i > 1 and j > 1 and lower(a[i - 1]) == lower(b[j - 2]) and lower(a[i - 2]) == lower(b[j - 1]))
                d = @min(d, before[j - 2] + 1);
            cur[j] = d;
        }
        const t = before;
        before = prev;
        prev = cur;
        cur = t;
    }
    return prev[b.len];
}

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

/// How many edits a word of this length may be from what was meant.
fn allowance(len: usize) usize {
    if (len <= 4) return 1;
    if (len <= 8) return 2;
    return 3;
}

/// Up to three of `candidates` close to `word`, closest first. Duplicates
/// and `word` itself are left out.
pub fn closest(arena: Allocator, word: []const u8, candidates: []const []const u8) Allocator.Error![]const []const u8 {
    const Scored = struct { name: []const u8, score: usize };
    var found: std.ArrayList(Scored) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const limit = allowance(word.len);
    for (candidates) |c| {
        if (std.ascii.eqlIgnoreCase(c, word)) continue;
        var score = distance(word, c);
        if (score > limit) {
            const prefix = word.len >= 3 and std.ascii.startsWithIgnoreCase(c, word);
            const inside = word.len >= 4 and std.ascii.findIgnoreCase(c, word) != null;
            if (!prefix and !inside) continue;
            score = limit + 1;
        }
        const entry = try seen.getOrPut(arena, c);
        if (entry.found_existing) continue;
        try found.append(arena, .{ .name = c, .score = score });
    }
    std.mem.sort(Scored, found.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            if (a.score != b.score) return a.score < b.score;
            if (a.name.len != b.name.len) return a.name.len < b.name.len;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);
    const n = @min(found.items.len, 3);
    const out = try arena.alloc([]const u8, n);
    for (found.items[0..n], out) |s, *o| o.* = s.name;
    return out;
}

/// "; did you mean 'install'?", "; did you mean hello or help?", or "".
pub fn phrase(arena: Allocator, names: []const []const u8, quoted: bool) Allocator.Error![]const u8 {
    if (names.len == 0) return "";
    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    w.writeAll("; did you mean ") catch return error.OutOfMemory;
    for (names, 0..) |n, i| {
        if (i > 0) w.writeAll(if (i == names.len - 1) " or " else ", ") catch return error.OutOfMemory;
        if (quoted) {
            w.print("'{s}'", .{n}) catch return error.OutOfMemory;
        } else {
            w.writeAll(n) catch return error.OutOfMemory;
        }
    }
    w.writeByte('?') catch return error.OutOfMemory;
    return text.written();
}

/// closest() and phrase() together.
pub fn didYouMean(arena: Allocator, word: []const u8, candidates: []const []const u8, quoted: bool) Allocator.Error![]const u8 {
    return phrase(arena, try closest(arena, word, candidates), quoted);
}

const testing = std.testing;

test "distance" {
    try testing.expectEqual(@as(usize, 0), distance("install", "install"));
    try testing.expectEqual(@as(usize, 1), distance("isntall", "install"));
    try testing.expectEqual(@as(usize, 1), distance("instal", "install"));
    try testing.expectEqual(@as(usize, 0), distance("Install", "install"));
    try testing.expectEqual(@as(usize, 3), distance("", "abc"));
    try testing.expectEqual(@as(usize, 1), distance("hello", "hlelo"));
    const long: [200]u8 = @splat('a');
    try testing.expectEqual(far, distance(&long, "a"));
}

test "closest" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const commands = [_][]const u8{ "install", "info", "list", "remove", "rollback", "search", "status" };
    try testing.expectEqualStrings("install", (try closest(arena, "isntall", &commands))[0]);
    try testing.expectEqualStrings("remove", (try closest(arena, "rmeove", &commands))[0]);
    try testing.expectEqual(@as(usize, 0), (try closest(arena, "xyzzy", &commands)).len);
    // A short word must be very close.
    try testing.expectEqual(@as(usize, 0), (try closest(arena, "gc", &commands)).len);
    const short = [_][]const u8{ "dash", "lame", "make", "dave-tools" };
    try testing.expectEqualStrings("dave-tools", (try closest(arena, "dave", &short))[0]);
    try testing.expectEqual(@as(usize, 1), (try closest(arena, "dave", &short)).len);

    const packages = [_][]const u8{ "firefox", "firefox", "libreoffice", "fire", "hello", "help2man" };
    const fire = try closest(arena, "firefx", &packages);
    try testing.expectEqualStrings("firefox", fire[0]);
    try testing.expectEqual(@as(usize, 2), fire.len); // firefox once, then fire
    try testing.expectEqualStrings("libreoffice", (try closest(arena, "office", &packages))[0]);
    try testing.expectEqualStrings("hello", (try closest(arena, "helo", &packages))[0]);
}

test "phrase" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("", try phrase(arena, &.{}, true));
    try testing.expectEqualStrings("; did you mean 'install'?", try phrase(arena, &.{"install"}, true));
    try testing.expectEqualStrings("; did you mean hello or help?", try phrase(arena, &.{ "hello", "help" }, false));
    try testing.expectEqualStrings("; did you mean a, b or c?", try phrase(arena, &.{ "a", "b", "c" }, false));
}
