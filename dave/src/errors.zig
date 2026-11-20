//! Plain words for the errors people meet.
//!
//! dave reports most failures with an explanation of its own, but some reach
//! the user as an error from the standard library: a refused connection, a
//! full disk. Those are said here the way a person would say them, with a
//! hint where one helps. Anything not listed keeps its Zig name, which is
//! better than a wrong guess and is what a bug report needs.

const std = @import("std");

/// What went wrong, in words, or null for errors that have none here.
pub fn describe(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ConnectionRefused => "the connection was refused",
        error.UnknownHostName => "there is no host by that name",
        error.NameServerFailure,
        error.NoAddressReturned,
        error.DetectingNetworkConfigurationFailed,
        error.ResolvConfParseFailed,
        => "the name could not be looked up",
        error.NetworkUnreachable, error.NetworkDown, error.HostUnreachable => "the network is unreachable",
        error.Timeout, error.ConnectionTimedOut => "the connection timed out",
        error.ConnectionResetByPeer, error.EndOfStream, error.BrokenPipe, error.HttpConnectionClosing => "the connection was cut off",
        error.NoSpaceLeft, error.DiskQuota => "there is no space left on the disk",
        error.AccessDenied, error.PermissionDenied => "permission was denied",
        error.ReadOnlyFileSystem => "the file system is read-only",
        error.FileNotFound => "it does not exist",
        error.NotDir => "a part of the path is not a directory",
        error.RepositoryNotFound => "the repository's directory does not exist",
        else => null,
    };
}

/// A suggestion to follow the description, or null.
pub fn hint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.ConnectionRefused => "is the repository's server running?",
        error.UnknownHostName,
        error.NameServerFailure,
        error.NoAddressReturned,
        error.DetectingNetworkConfigurationFailed,
        error.NetworkUnreachable,
        error.NetworkDown,
        error.HostUnreachable,
        error.Timeout,
        error.ConnectionTimedOut,
        => "is this computer online?",
        error.NoSpaceLeft, error.DiskQuota => "free some space; 'dave deployments gc' removes old deployments",
        else => null,
    };
}

/// describe(), followed by the hint after a semicolon; the error's name when
/// there are no words for it.
pub fn text(buf: []u8, err: anyerror) []const u8 {
    const what = describe(err) orelse return @errorName(err);
    const more = hint(err) orelse return what;
    return std.fmt.bufPrint(buf, "{s}; {s}", .{ what, more }) catch what;
}

const testing = std.testing;

test "errors in words" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("the connection was refused; is the repository's server running?", text(&buf, error.ConnectionRefused));
    try testing.expectEqualStrings("permission was denied", text(&buf, error.AccessDenied));
    try testing.expectEqualStrings("there is no host by that name; is this computer online?", text(&buf, error.UnknownHostName));
    // The security module's vocabulary check is reported by name.
    try testing.expectEqualStrings("InvalidOperation", text(&buf, error.InvalidOperation));
    try testing.expect(describe(error.OutOfMemory) == null);
}
