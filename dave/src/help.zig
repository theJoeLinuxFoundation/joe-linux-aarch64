//! What `dave help` says, made from cli.zig's tables.
//!
//! The overview lists every command a person runs, by group, with a line
//! each; `dave help <command>` (or `--help` after any command) explains one
//! command, whether it needs root, and every option it takes. Commands run
//! only by the system's own services are left out of the overview but can
//! still be asked about.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const ui = @import("ui.zig");

pub fn overview(w: *Io.Writer, color: bool) Io.Writer.Error!void {
    try w.writeAll("Usage: dave <command> [options]\n");
    // Wide enough for most; the few longer ones push their summary along.
    var width: usize = 0;
    for (cli.commands) |c| {
        if (c.hidden) continue;
        width = @max(width, @min(leftColumn(c), 28));
    }
    var group: ?cli.Group = null;
    for (cli.commands) |c| {
        if (c.hidden) continue;
        if (group != c.group) {
            group = c.group;
            try w.print("\n{f}\n", .{ui.paint(color, .heading, c.group.title())});
        }
        const rest = c.overviewLine();
        try w.print("  {s}", .{@tagName(c.command)});
        if (rest.len > 0) try w.print(" {s}", .{rest});
        try w.splatByteAll(' ', (width -| leftColumn(c)) + 3);
        try w.print("{s}\n", .{c.summary});
    }
    try w.print("\n{f}\n", .{ui.paint(color, .heading, "Every command takes")});
    try writeOptions(w, null, optionWidth(null));
    try w.writeAll("\nRun 'dave help <command>' for what a command does and the options it takes.\n");
}

fn leftColumn(c: cli.CommandInfo) usize {
    const rest = c.overviewLine();
    return @tagName(c.command).len + if (rest.len > 0) rest.len + 1 else 0;
}

pub fn command(w: *Io.Writer, cmd: cli.Command, color: bool) Io.Writer.Error!void {
    const c = cli.infoOf(cmd);
    try w.print("Usage: dave {s}", .{@tagName(cmd)});
    if (c.synopsis.len > 0) try w.print(" {s}", .{c.synopsis});
    try w.print("\n\n{s}.\n\n{s}\n", .{ c.summary, c.about });
    if (c.root_note) |note| {
        try w.print("\n{s}\n", .{note});
    } else if (c.root_for) |what| {
        try w.print("\n{c}{s} needs root.\n", .{ std.ascii.toUpper(what[0]), what[1..] });
    }
    var any = false;
    for (cli.options) |o| {
        if (o.commands.len > 0 and cli.appliesTo(o, cmd)) any = true;
    }
    // One column for both lists.
    const width = @max(optionWidth(cmd), optionWidth(null));
    if (any) {
        try w.print("\n{f}\n", .{ui.paint(color, .heading, "Options")});
        try writeOptions(w, cmd, width);
    }
    try w.print("\n{f}\n", .{ui.paint(color, .heading, "Every command takes")});
    try writeOptions(w, null, width);
    if (c.examples.len > 0) {
        try w.print("\n{f}\n", .{ui.paint(color, .heading, "Examples")});
        for (c.examples) |e| try w.print("  {s}\n", .{e});
    }
}

fn optionWidth(cmd: ?cli.Command) usize {
    var width: usize = 0;
    for (cli.options) |o| {
        if (shows(o, cmd)) width = @max(width, optionColumn(o));
    }
    return width;
}

/// The options `cmd` takes of its own, or with null those every command takes.
fn writeOptions(w: *Io.Writer, cmd: ?cli.Command, width: usize) Io.Writer.Error!void {
    for (cli.options) |o| {
        if (!shows(o, cmd)) continue;
        if (o.short) |s| {
            try w.print("  -{c}, --{s}", .{ s, o.long });
        } else {
            try w.print("      --{s}", .{o.long});
        }
        if (o.value) |v| try w.print(" {s}", .{v});
        try w.splatByteAll(' ', width - optionColumn(o) + 3);
        try w.print("{s}\n", .{o.help});
    }
}

fn shows(o: cli.OptionSpec, cmd: ?cli.Command) bool {
    if (cmd) |c| return o.commands.len > 0 and cli.appliesTo(o, c);
    return o.commands.len == 0;
}

fn optionColumn(o: cli.OptionSpec) usize {
    return 4 + o.long.len + if (o.value) |v| v.len + 1 else 0;
}

const testing = std.testing;

test "the overview names every visible command and no hidden one" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try overview(&out.writer, false);
    const text = out.written();
    for (cli.commands) |c| {
        var buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "\n  {s}", .{@tagName(c.command)});
        try testing.expectEqual(!c.hidden, std.mem.indexOf(u8, text, needle) != null);
    }
    try testing.expect(std.mem.indexOf(u8, text, "  -h, --help") != null);
}

test "every option appears in the help of a command that takes it" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    for (cli.commands) |c| try command(&out.writer, c.command, false);
    const text = out.written();
    for (cli.options) |o| {
        var buf: [64]u8 = undefined;
        try testing.expect(std.mem.indexOf(u8, text, try std.fmt.bufPrint(&buf, "--{s}", .{o.long})) != null);
    }
    out.clearRetainingCapacity();
    try command(&out.writer, .install, false);
    try testing.expect(std.mem.startsWith(u8, out.written(), "Usage: dave install [options] <package>...\n"));
    try testing.expect(std.mem.indexOf(u8, out.written(), "  -y, --yes") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "--disk") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Installing packages needs root") != null);
}
