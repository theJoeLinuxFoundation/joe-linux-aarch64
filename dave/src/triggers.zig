//! Declarative triggers.
//!
//! Packages never carry install scripts. Instead, a package may ship files in
//! `usr/lib/dave/triggers/*.zon` describing a program to run once at the end of
//! any transaction that touched paths under given prefixes: the dynamic linker
//! cache after libraries change, module dependencies after kernel modules
//! change, and so on. Triggers run inside the root being modified.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const manifest_mod = @import("manifest.zig");

pub const dir_path = "usr/lib/dave/triggers";

pub const Trigger = struct {
    name: []const u8 = "",
    /// Path prefixes relative to the root, without a leading slash.
    paths: []const []const u8,
    /// Program and arguments; the program is an absolute path inside the root.
    exec: []const []const u8,
    /// A trigger whose failure does not fail the transaction. For work that
    /// the system repeats by itself at boot and that cannot always succeed
    /// where a root is being assembled without privileges.
    optional: bool = false,
};

/// Loads every trigger definition present in `root`, in file-name order.
pub fn load(arena: Allocator, io: Io, root: Io.Dir) ![]Trigger {
    var names: std.ArrayList([]const u8) = .empty;
    var out: std.ArrayList(Trigger) = .empty;
    var dir = root.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return out.items,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.endsWith(u8, e.name, ".zon")) try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    for (names.items) |name| {
        const text = try dir.readFileAlloc(io, name, arena, .limited(1024 * 1024));
        var t = manifest_mod.parseZon(Trigger, arena, text) catch return error.InvalidTrigger;
        if (t.exec.len == 0 or t.exec[0].len == 0 or t.exec[0][0] != '/') return error.InvalidTrigger;
        if (t.name.len == 0) t.name = name[0 .. name.len - ".zon".len];
        try out.append(arena, t);
    }
    return out.items;
}

/// The triggers interested in at least one of the changed paths.
pub fn matching(arena: Allocator, all: []const Trigger, changed: []const []const u8) Allocator.Error![]Trigger {
    var out: std.ArrayList(Trigger) = .empty;
    for (all) |t| {
        if (matches(t, changed)) try out.append(arena, t);
    }
    return out.items;
}

fn matches(t: Trigger, changed: []const []const u8) bool {
    for (changed) |path| {
        for (t.paths) |p| if (std.mem.startsWith(u8, path, p)) return true;
    }
    return false;
}

pub const RunOptions = struct {
    root: Io.Dir,
    /// Absolute path of the root to change into, or null when it is the
    /// running system's own root.
    chroot_path: ?[]const u8,
    /// Path of the dave executable, used to enter the chroot.
    self_exe: []const u8,
    /// Directories of the chroot, relative to it, that a booted system has
    /// other file systems mounted on (a deployment's /var and /home). Trigger
    /// programs find an empty tmpfs there, as they would find the shared
    /// subvolume at boot: what they write there is not left behind in the
    /// root, hidden under the mount, and systemd-tmpfiles cannot make a
    /// nested subvolume of a directory there. Ignored without `chroot_path`.
    shared: []const []const u8 = &.{},
    /// The environment trigger programs get; dave's own when null.
    environ_map: ?*const std.process.Environ.Map = null,
};

/// Runs the given triggers. A trigger whose program is not present in the root
/// is skipped; one that runs and fails is an error.
pub fn run(arena: Allocator, io: Io, triggers: []const Trigger, options: RunOptions) !void {
    for (triggers) |t| {
        _ = options.root.statFile(io, t.exec[0][1..], .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        var argv: std.ArrayList([]const u8) = .empty;
        if (options.chroot_path) |path| {
            try argv.appendSlice(arena, &.{ options.self_exe, chroot_command, path });
            for (options.shared) |dir| try argv.append(arena, try std.fmt.allocPrint(arena, tmpfs_flag ++ "{s}", .{dir}));
        }
        try argv.appendSlice(arena, t.exec);
        var child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .environ_map = options.environ_map });
        const term = try child.wait(io);
        if (!term.success() and !t.optional) return error.TriggerFailed;
    }
}

/// Hidden subcommand: `dave --chroot-exec <dir> [--tmpfs=PATH]... <program> [args...]`.
/// The program is an absolute path, so it cannot be taken for an option.
pub const chroot_command = "--chroot-exec";
pub const tmpfs_flag = "--tmpfs=";

const testing = std.testing;

test "load and match" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try testing.expectEqual(@as(usize, 0), (try load(arena, io, tmp.dir)).len);
    try tmp.dir.createDirPath(io, dir_path);
    try tmp.dir.writeFile(io, .{ .sub_path = dir_path ++ "/20-depmod.zon", .data =
        \\.{ .paths = .{"usr/lib/modules/"}, .exec = .{ "/usr/bin/depmod", "-a" } }
    });
    try tmp.dir.writeFile(io, .{ .sub_path = dir_path ++ "/10-ldconfig.zon", .data =
        \\.{ .name = "linker cache", .paths = .{ "usr/lib/", "etc/ld.so.conf" }, .exec = .{"/usr/bin/ldconfig"} }
    });
    const all = try load(arena, io, tmp.dir);
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("linker cache", all[0].name);
    try testing.expectEqualStrings("20-depmod", all[1].name);

    try testing.expectEqual(@as(usize, 0), (try matching(arena, all, &.{"usr/bin/hello"})).len);
    try testing.expectEqual(@as(usize, 1), (try matching(arena, all, &.{"usr/lib/libz.so.1"})).len);
    try testing.expectEqual(@as(usize, 2), (try matching(arena, all, &.{ "usr/bin/x", "usr/lib/modules/7/kernel/a.ko" })).len);

    // A trigger whose program is absent from the root is skipped, not an error.
    try run(arena, io, all, .{ .root = tmp.dir, .chroot_path = null, .self_exe = "/proc/self/exe" });

    try tmp.dir.writeFile(io, .{ .sub_path = dir_path ++ "/30-bad.zon", .data =
        \\.{ .paths = .{"usr/"}, .exec = .{"relative/path"} }
    });
    try testing.expectError(error.InvalidTrigger, load(arena, io, tmp.dir));
}
