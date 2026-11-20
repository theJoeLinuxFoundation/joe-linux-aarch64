//! joe Linux package versions: `<upstream>[-r<release>]`.
//!
//! `upstream` is made of ASCII letters, digits and the separators `.`, `_`, `+`.
//! It is compared run by run: digit runs numerically, letter runs
//! lexicographically, a digit run sorts after a letter run, and a version that
//! merely adds a trailing letter run is older ("1.0rc1" < "1.0" < "1.0.1").
//! Separators only delimit runs. `release` is the packaging revision; a missing
//! release is release 0.

const std = @import("std");
const Order = std.math.Order;

pub const Version = struct {
    upstream: []const u8,
    release: u32 = 0,

    pub const ParseError = error{InvalidVersion};

    pub fn parse(text: []const u8) ParseError!Version {
        var upstream = text;
        var release: u32 = 0;
        if (std.mem.lastIndexOf(u8, text, "-r")) |i| {
            const digits = text[i + 2 ..];
            if (digits.len == 0) return error.InvalidVersion;
            release = std.fmt.parseInt(u32, digits, 10) catch return error.InvalidVersion;
            upstream = text[0..i];
        }
        if (upstream.len == 0) return error.InvalidVersion;
        for (upstream) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '+')
                return error.InvalidVersion;
        }
        if (!std.ascii.isAlphanumeric(upstream[0])) return error.InvalidVersion;
        return .{ .upstream = upstream, .release = release };
    }

    pub fn order(a: Version, b: Version) Order {
        const up = orderUpstream(a.upstream, b.upstream);
        if (up != .eq) return up;
        return std.math.order(a.release, b.release);
    }

    pub fn eql(a: Version, b: Version) bool {
        return a.order(b) == .eq;
    }

    pub fn format(v: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}-r{d}", .{ v.upstream, v.release });
    }
};

const Run = struct {
    text: []const u8,
    numeric: bool,
};

const RunIterator = struct {
    rest: []const u8,

    fn next(it: *RunIterator) ?Run {
        while (it.rest.len > 0 and !std.ascii.isAlphanumeric(it.rest[0])) it.rest = it.rest[1..];
        if (it.rest.len == 0) return null;
        const numeric = std.ascii.isDigit(it.rest[0]);
        var end: usize = 1;
        while (end < it.rest.len and std.ascii.isAlphanumeric(it.rest[end]) and
            std.ascii.isDigit(it.rest[end]) == numeric) end += 1;
        const run: Run = .{ .text = it.rest[0..end], .numeric = numeric };
        it.rest = it.rest[end..];
        return run;
    }
};

fn orderUpstream(a: []const u8, b: []const u8) Order {
    var ia: RunIterator = .{ .rest = a };
    var ib: RunIterator = .{ .rest = b };
    while (true) {
        const ra = ia.next();
        const rb = ib.next();
        if (ra == null and rb == null) return .eq;
        // The longer version is newer unless its extra run is letters.
        if (ra == null) return if (rb.?.numeric) .lt else .gt;
        if (rb == null) return if (ra.?.numeric) .gt else .lt;
        const x = ra.?;
        const y = rb.?;
        if (x.numeric != y.numeric) return if (x.numeric) .gt else .lt;
        const o = if (x.numeric) orderNumeric(x.text, y.text) else std.mem.order(u8, x.text, y.text);
        if (o != .eq) return o;
    }
}

/// Compares digit strings of any length as numbers.
fn orderNumeric(a: []const u8, b: []const u8) Order {
    const x = std.mem.trimStart(u8, a, "0");
    const y = std.mem.trimStart(u8, b, "0");
    if (x.len != y.len) return std.math.order(x.len, y.len);
    return std.mem.order(u8, x, y);
}

fn expectOrder(expected: Order, a: []const u8, b: []const u8) !void {
    const va = try Version.parse(a);
    const vb = try Version.parse(b);
    try std.testing.expectEqual(expected, va.order(vb));
    try std.testing.expectEqual(expected.invert(), vb.order(va));
}

test "ordering" {
    try expectOrder(.eq, "1.0", "1.0");
    try expectOrder(.eq, "1.0", "1.0-r0");
    try expectOrder(.lt, "1.0-r1", "1.0-r2");
    try expectOrder(.lt, "1.0-r9", "1.0.1-r1");
    try expectOrder(.lt, "1.9", "1.10");
    try expectOrder(.lt, "2.44", "2.44.1");
    try expectOrder(.lt, "1.0rc1", "1.0");
    try expectOrder(.lt, "1.0rc1", "1.0rc2");
    try expectOrder(.lt, "1.0a", "1.0b");
    try expectOrder(.lt, "1.0a", "1.0.1");
    try expectOrder(.eq, "1.01", "1.1");
    try expectOrder(.lt, "9", "10");
    try expectOrder(.gt, "99999999999999999999999999", "99999999999999999999999998");
    try expectOrder(.lt, "20240101", "20240102");
    try expectOrder(.eq, "1_0", "1.0");
}

test "parse" {
    const v = try Version.parse("262.1-r3");
    try std.testing.expectEqualStrings("262.1", v.upstream);
    try std.testing.expectEqual(@as(u32, 3), v.release);
    try std.testing.expectError(error.InvalidVersion, Version.parse(""));
    try std.testing.expectError(error.InvalidVersion, Version.parse("-r1"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("1.0-r"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("1.0-rx"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("1 0"));
    try std.testing.expectError(error.InvalidVersion, Version.parse(".1"));
}
