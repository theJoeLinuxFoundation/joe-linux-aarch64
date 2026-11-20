//! Running the programs that building images and installing systems need
//! (mkfs, sfdisk, xorriso, ...): a failure names the program and how it
//! ended, in a sentence fit for the person who started dave.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const Error = error{CommandFailed} || Allocator.Error;

pub const Options = struct {
    /// Written to the program's standard input, which is closed afterwards.
    input: ?[]const u8 = null,
    /// Keep the program's standard output (it is discarded otherwise).
    capture: bool = false,
};

/// Runs `argv` and waits for it. With `capture`, returns what the program
/// wrote to its standard output; its standard error always goes to dave's.
pub fn run(arena: Allocator, io: Io, argv: []const []const u8, options: Options, diag: *Diagnostic) Error![]const u8 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (options.input == null) .ignore else .pipe,
        .stdout = if (options.capture) .pipe else .ignore,
    }) catch |err| return fail(arena, diag, "cannot run {s}: {t}", .{ argv[0], err });
    errdefer child.kill(io);
    if (options.input) |data| {
        var stdin = child.stdin.?;
        child.stdin = null;
        stdin.writeStreamingAll(io, data) catch {};
        stdin.close(io);
    }
    var output: []const u8 = "";
    if (options.capture) {
        var stdout = child.stdout.?;
        child.stdout = null;
        defer stdout.close(io);
        var buf: [4096]u8 = undefined;
        var reader = stdout.readerStreaming(io, &buf);
        output = reader.interface.allocRemaining(arena, .limited(64 * 1024 * 1024)) catch |err|
            return fail(arena, diag, "cannot read the output of {s}: {t}", .{ argv[0], err });
    }
    const term = child.wait(io) catch |err| return fail(arena, diag, "{s} did not finish: {t}", .{ argv[0], err });
    if (!term.success()) {
        return fail(arena, diag, "{s} failed ({f})", .{ try std.mem.join(arena, " ", argv), term });
    }
    return output;
}

fn fail(arena: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = std.fmt.allocPrint(arena, fmt, args) catch "out of memory";
    return error.CommandFailed;
}

const testing = std.testing;

test "programs are run, their output kept, and their failures described" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    try testing.expectEqualStrings("hello\n", try run(arena, testing.io, &.{ "cat", "-" }, .{ .input = "hello\n", .capture = true }, &diag));
    _ = try run(arena, testing.io, &.{"true"}, .{}, &diag);
    try testing.expectError(error.CommandFailed, run(arena, testing.io, &.{"false"}, .{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "false failed (exited with code 1)") != null);
    try testing.expectError(error.CommandFailed, run(arena, testing.io, &.{"/nonexistent/program"}, .{}, &diag));
    try testing.expect(std.mem.startsWith(u8, diag.message, "cannot run /nonexistent/program"));
}
