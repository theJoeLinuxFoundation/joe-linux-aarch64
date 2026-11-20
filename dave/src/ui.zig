//! Talking to a person at a terminal, and staying quiet when nobody is there.
//!
//! What dave may do is decided once, from facts about where its output goes
//! (decide() is a pure function of them, so the rules are tested): colour
//! only on a terminal that understands it, and never with NO_COLOR; a line
//! that redraws itself (downloads, progress) only on such a terminal; a
//! question only when a person can both see and answer it. Output to a pipe,
//! a file, the installer (--json) or the test console (TERM=dumb) stays plain
//! lines, so scripts see what they always saw and nothing waits for input.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

pub const Facts = struct {
    stdin_tty: bool = false,
    stdout_tty: bool = false,
    stderr_tty: bool = false,
    term: ?[]const u8 = null,
    no_color: bool = false,
    force_color: bool = false,
    json: bool = false,
};

pub const Caps = struct {
    /// Colour on standard output.
    color: bool = false,
    /// Colour on standard error (the "dave:" of a failure).
    err_color: bool = false,
    /// A line on standard output that is drawn over as work proceeds.
    live: bool = false,
    /// A question may be asked and answered.
    ask: bool = false,
};

pub fn decide(f: Facts) Caps {
    if (f.json) return .{};
    const capable = if (f.term) |t| t.len > 0 and !std.mem.eql(u8, t, "dumb") else false;
    return .{
        .color = f.force_color or (f.stdout_tty and capable and !f.no_color),
        .err_color = f.force_color or (f.stderr_tty and capable and !f.no_color),
        .live = f.stdout_tty and capable,
        .ask = f.stdin_tty and f.stdout_tty,
    };
}

pub fn detect(io: Io, env: ?*const std.process.Environ.Map, json: bool) Caps {
    const get = struct {
        fn get(e: ?*const std.process.Environ.Map, key: []const u8) ?[]const u8 {
            const m = e orelse return null;
            return m.get(key);
        }
    }.get;
    const no_color = if (get(env, "NO_COLOR")) |v| v.len > 0 else false;
    const force = if (get(env, "CLICOLOR_FORCE")) |v| v.len > 0 and !std.mem.eql(u8, v, "0") else false;
    return decide(.{
        .stdin_tty = Io.File.stdin().isTty(io) catch false,
        .stdout_tty = Io.File.stdout().isTty(io) catch false,
        .stderr_tty = Io.File.stderr().isTty(io) catch false,
        .term = get(env, "TERM"),
        .no_color = no_color,
        .force_color = force,
        .json = json,
    });
}

/// The width of the terminal on standard output, or 80 when it is not known.
pub fn width() u16 {
    var ws: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = linux.ioctl(1, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (linux.errno(rc) != .SUCCESS or ws.col == 0) return 80;
    return ws.col;
}

// -- colour -------------------------------------------------------------------

pub const Style = enum {
    heading,
    install,
    upgrade,
    remove,
    dim,
    failure,
    note,

    fn code(s: Style) []const u8 {
        return switch (s) {
            .heading => "\x1b[1m",
            .install => "\x1b[32m",
            .upgrade => "\x1b[33m",
            .remove => "\x1b[31m",
            .dim => "\x1b[2m",
            .failure => "\x1b[1;31m",
            .note => "\x1b[36m",
        };
    }
};

pub const Painted = struct {
    on: bool,
    style: Style,
    text: []const u8,

    pub fn format(p: Painted, w: *Io.Writer) Io.Writer.Error!void {
        if (!p.on) return w.writeAll(p.text);
        try w.writeAll(p.style.code());
        try w.writeAll(p.text);
        try w.writeAll("\x1b[0m");
    }
};

/// `text` in `style` when `on`, for printing with {f}.
pub fn paint(on: bool, style: Style, text: []const u8) Painted {
    return .{ .on = on, .style = style, .text = text };
}

// -- sizes ----------------------------------------------------------------------

pub const Size = struct {
    bytes: u64,

    pub fn format(s: Size, w: *Io.Writer) Io.Writer.Error!void {
        if (s.bytes < 1024) return w.print("{d} B", .{s.bytes});
        const units = [_][]const u8{ "KiB", "MiB", "GiB", "TiB", "PiB" };
        var unit: u128 = 1024;
        for (units, 0..) |name, i| {
            const tenths = (@as(u128, s.bytes) * 10 + unit / 2) / unit;
            if (tenths < 10240 or i == units.len - 1)
                return w.print("{d}.{d} {s}", .{ tenths / 10, tenths % 10, name });
            unit *= 1024;
        }
        unreachable;
    }
};

/// A byte count for people: "512 B", "1.5 KiB", "12.3 MiB".
pub fn size(bytes: u64) Size {
    return .{ .bytes = bytes };
}

// -- a line drawn over -------------------------------------------------------------

/// The first `columns` characters of UTF-8 `text`, cut between characters.
pub fn fit(text: []const u8, columns: usize) []const u8 {
    var shown: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (shown == columns) return text[0..i];
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i = @min(text.len, i + n);
        shown += 1;
    }
    return text;
}

pub const Line = struct {
    shown: bool = false,
    last_ns: i96 = 0,

    const interval_ns = 100 * std.time.ns_per_ms;

    /// Draws `text` over the line, cut to the terminal's width. Unless
    /// `force`, does nothing when the last drawing was very recent.
    pub fn draw(l: *Line, w: *Io.Writer, columns: u16, now_ns: i96, force: bool, text: []const u8) void {
        if (!force and l.shown and now_ns - l.last_ns < interval_ns) return;
        l.last_ns = now_ns;
        // The last column is left free: writing to it makes some terminals wrap.
        w.writeByte('\r') catch return;
        w.writeAll(fit(text, columns -| 1)) catch return;
        w.writeAll("\x1b[K") catch return;
        w.flush() catch return;
        l.shown = true;
    }

    /// Removes the line, so that what is written next starts at its beginning.
    pub fn clear(l: *Line, w: *Io.Writer) void {
        if (!l.shown) return;
        l.shown = false;
        w.writeAll("\r\x1b[K") catch return;
        w.flush() catch return;
    }
};

// -- questions ------------------------------------------------------------------------

pub const Answer = enum { yes, no };

/// Enter alone means yes; so do y and yes. The end of input, and anything
/// else, mean no.
pub fn parseAnswer(line: ?[]const u8) Answer {
    const text = std.mem.trim(u8, line orelse return .no, " \t\r");
    if (text.len == 0 or std.ascii.eqlIgnoreCase(text, "y") or std.ascii.eqlIgnoreCase(text, "yes")) return .yes;
    return .no;
}

/// Writes `question` and reads the answer from standard input.
pub fn ask(io: Io, out: *Io.Writer, question: []const u8) Answer {
    out.writeAll(question) catch return .no;
    out.flush() catch return .no;
    var buf: [256]u8 = undefined;
    var reader = Io.File.stdin().readerStreaming(io, &buf);
    const line = reader.interface.takeDelimiter('\n') catch return .no;
    if (line == null) {
        // The end of input leaves the cursor after the question.
        out.writeByte('\n') catch {};
        out.flush() catch {};
    }
    return parseAnswer(line);
}

// -- shell words ------------------------------------------------------------------------

/// The arguments as they could be typed into a shell.
pub fn shellQuote(arena: Allocator, argv: []const []const u8) Allocator.Error![]const u8 {
    var text: Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    for (argv, 0..) |arg, i| {
        if (i > 0) w.writeByte(' ') catch return error.OutOfMemory;
        const plain = arg.len > 0 and for (arg) |c| {
            if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "_@%+=:,./-", c) == null) break false;
        } else true;
        if (plain) {
            w.writeAll(arg) catch return error.OutOfMemory;
            continue;
        }
        w.writeByte('\'') catch return error.OutOfMemory;
        for (arg) |c| {
            if (c == '\'') {
                w.writeAll("'\\''") catch return error.OutOfMemory;
            } else {
                w.writeByte(c) catch return error.OutOfMemory;
            }
        }
        w.writeByte('\'') catch return error.OutOfMemory;
    }
    return text.written();
}

const testing = std.testing;

test "decide" {
    const term: Facts = .{ .stdin_tty = true, .stdout_tty = true, .stderr_tty = true, .term = "xterm-256color" };
    try testing.expectEqual(Caps{ .color = true, .err_color = true, .live = true, .ask = true }, decide(term));

    var f = term;
    f.no_color = true;
    try testing.expectEqual(Caps{ .live = true, .ask = true }, decide(f));

    f = term;
    f.term = "dumb";
    try testing.expectEqual(Caps{ .ask = true }, decide(f));
    f.term = null;
    try testing.expectEqual(Caps{ .ask = true }, decide(f));

    f = term;
    f.stdout_tty = false;
    try testing.expectEqual(Caps{ .err_color = true }, decide(f));

    f = term;
    f.stdin_tty = false;
    try testing.expectEqual(Caps{ .color = true, .err_color = true, .live = true }, decide(f));

    f = term;
    f.json = true;
    try testing.expectEqual(Caps{}, decide(f));

    try testing.expectEqual(Caps{ .color = true, .err_color = true }, decide(.{ .force_color = true }));
}

test "sizes" {
    var buf: [32]u8 = undefined;
    const cases = [_]struct { u64, []const u8 }{
        .{ 0, "0 B" },           .{ 1023, "1023 B" },                      .{ 1024, "1.0 KiB" },
        .{ 1536, "1.5 KiB" },    .{ 1048575, "1.0 MiB" },                  .{ 12_900_000, "12.3 MiB" },
        .{ 5 << 30, "5.0 GiB" }, .{ std.math.maxInt(u64), "16384.0 PiB" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], try std.fmt.bufPrint(&buf, "{f}", .{size(c[0])}));
}

test "paint" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("x", try std.fmt.bufPrint(&buf, "{f}", .{paint(false, .install, "x")}));
    try testing.expectEqualStrings("\x1b[32mx\x1b[0m", try std.fmt.bufPrint(&buf, "{f}", .{paint(true, .install, "x")}));
}

test "a line drawn over" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var line: Line = .{};
    line.draw(&out.writer, 6, 1_000_000_000, false, "abcdefgh");
    try testing.expectEqualStrings("\rabcde\x1b[K", out.written());
    // Too soon: nothing is drawn, unless forced.
    line.draw(&out.writer, 6, 1_050_000_000, false, "xyz");
    try testing.expectEqualStrings("\rabcde\x1b[K", out.written());
    line.draw(&out.writer, 6, 1_060_000_000, true, "xyz");
    try testing.expectEqualStrings("\rabcde\x1b[K\rxyz\x1b[K", out.written());
    line.clear(&out.writer);
    line.clear(&out.writer);
    try testing.expectEqualStrings("\rabcde\x1b[K\rxyz\x1b[K\r\x1b[K", out.written());
    try testing.expectEqualStrings("hé", fit("héllo", 2));
}

test "answers" {
    try testing.expectEqual(Answer.yes, parseAnswer(""));
    try testing.expectEqual(Answer.yes, parseAnswer("Y\r"));
    try testing.expectEqual(Answer.yes, parseAnswer(" yes "));
    try testing.expectEqual(Answer.no, parseAnswer("n"));
    try testing.expectEqual(Answer.no, parseAnswer("maybe"));
    try testing.expectEqual(Answer.no, parseAnswer(null));
}

test "shell words" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("dave install hello", try shellQuote(arena, &.{ "dave", "install", "hello" }));
    try testing.expectEqualStrings("dave install 'hello>=2' ''", try shellQuote(arena, &.{ "dave", "install", "hello>=2", "" }));
    try testing.expectEqualStrings("'it'\\''s'", try shellQuote(arena, &.{"it's"}));
}
