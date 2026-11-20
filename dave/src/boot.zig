//! Boot entries on the EFI system partition.
//!
//! One Boot Loader Specification type 1 entry exists per deployment:
//! `loader/entries/joe-<id>.conf`. Every entry has `sort-key joe`, so
//! systemd-boot orders them by `version` alone, and `version` is not a release
//! number but a *priority*: a counter that is bumped each time a deployment is
//! chosen. Activating an upgrade and rolling back are therefore the same act
//! (give the target the highest priority), a rollback is persistent, and the
//! fallback after a failed boot is whatever was chosen before.
//!
//! The boot loader also owns the health state. A new deployment is written as
//! `joe-<id>+3.conf`; systemd-boot counts the suffix down on each attempt
//! (`+2-1`, `+1-2`, `+0-3`), and once the boot check has passed the suffix is
//! removed (`bless`): by dave itself on joe Linux ARM, whose init is dynamod,
//! as systemd-bless-boot does on a systemd system. dave reads the state from
//! the file name and never keeps a second copy that could drift.
//!
//! An entry may also name initrds. joe boots without an initramfs, so the
//! only one is the processor microcode archive (cpu-microcode), which the
//! kernel reads before it mounts the root itself. Kernels and initrds are
//! stored on the ESP under names derived from their contents, and every
//! rewrite of an entry carries its initrds along.
//!
//! All of this was verified against systemd-boot 262 in tests/vm/boot-contract.tomlx.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const archive = @import("archive.zig");
const db = @import("db.zig");
const arch = @import("arch.zig");
const Version = @import("solver/version.zig").Version;

pub const entries_dir = "loader/entries";
pub const kernels_dir = "joe/kernels";
pub const initrds_dir = "joe/initrd";
pub const default_tries = 3;
const prefix = "joe-";
const suffix = ".conf";

pub const Health = enum {
    /// Booted successfully at least once.
    good,
    /// Not yet proven; boot attempts remain.
    trial,
    /// Ran out of attempts without passing its boot check.
    bad,
};

pub const Entry = struct {
    id: u32,
    priority: u64,
    tries_left: ?u32 = null,
    tries_done: u32 = 0,
    /// Path of the kernel image, relative to the ESP root with a leading slash.
    kernel: []const u8,
    /// Paths of the initrds, likewise, in the order they are given.
    initrds: []const []const u8 = &.{},
    options: []const u8,
    file_name: []const u8 = "",

    pub fn health(e: Entry) Health {
        const left = e.tries_left orelse return .good;
        return if (left == 0) .bad else .trial;
    }
};

const ParsedName = struct { id: u32, tries_left: ?u32, tries_done: u32 };

/// Parses `joe-<id>[+<left>[-<done>]].conf`.
fn parseName(name: []const u8) ?ParsedName {
    if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return null;
    const stem = name[prefix.len .. name.len - suffix.len];
    const plus = std.mem.indexOfScalar(u8, stem, '+') orelse
        return .{ .id = std.fmt.parseInt(u32, stem, 10) catch return null, .tries_left = null, .tries_done = 0 };
    const id = std.fmt.parseInt(u32, stem[0..plus], 10) catch return null;
    const counters = stem[plus + 1 ..];
    const dash = std.mem.indexOfScalar(u8, counters, '-');
    const left = std.fmt.parseInt(u32, counters[0 .. dash orelse counters.len], 10) catch return null;
    const done = if (dash) |d| std.fmt.parseInt(u32, counters[d + 1 ..], 10) catch return null else 0;
    return .{ .id = id, .tries_left = left, .tries_done = done };
}

fn field(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len == key.len) return "";
        if (line[key.len] != ' ' and line[key.len] != '\t') continue;
        return std.mem.trim(u8, line[key.len..], " \t");
    }
    return null;
}

/// Every value of a key that may be given more than once ("initrd").
fn fieldAll(arena: Allocator, text: []const u8, key: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key) or line.len == key.len) continue;
        if (line[key.len] != ' ' and line[key.len] != '\t') continue;
        try out.append(arena, std.mem.trim(u8, line[key.len..], " \t"));
    }
    return out.items;
}

/// Every deployment entry on the ESP, in the order systemd-boot would try
/// them: usable entries by descending priority, then exhausted ones.
pub fn list(arena: Allocator, io: Io, esp: Io.Dir) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var dir = esp.openDir(io, entries_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.items,
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const parsed = parseName(e.name) orelse continue;
        const text = dir.readFileAlloc(io, e.name, arena, .limited(64 * 1024)) catch continue;
        const priority = std.fmt.parseInt(u64, field(text, "version") orelse continue, 10) catch continue;
        try out.append(arena, .{
            .id = parsed.id,
            .priority = priority,
            .tries_left = parsed.tries_left,
            .tries_done = parsed.tries_done,
            .kernel = field(text, "linux") orelse continue,
            .initrds = try fieldAll(arena, text, "initrd"),
            .options = field(text, "options") orelse "",
            .file_name = try arena.dupe(u8, e.name),
        });
    }
    std.mem.sort(Entry, out.items, {}, bootOrder);
    return out.items;
}

fn bootOrder(_: void, a: Entry, b: Entry) bool {
    const a_bad = a.health() == .bad;
    const b_bad = b.health() == .bad;
    if (a_bad != b_bad) return b_bad;
    if (a.priority != b.priority) return a.priority > b.priority;
    return a.id > b.id;
}

pub fn find(entries: []const Entry, id: u32) ?Entry {
    for (entries) |e| if (e.id == id) return e;
    return null;
}

/// The entry systemd-boot will start next, if any is usable.
pub fn defaultEntry(entries: []const Entry) ?Entry {
    if (entries.len == 0 or entries[0].health() == .bad) return null;
    return entries[0];
}

pub fn highestPriority(entries: []const Entry) u64 {
    var max: u64 = 0;
    for (entries) |e| max = @max(max, e.priority);
    return max;
}

pub const WriteOptions = struct {
    id: u32,
    priority: u64,
    kernel: []const u8,
    initrds: []const []const u8 = &.{},
    options: []const u8,
    /// True for a deployment that has never booted: it gets boot counting.
    counted: bool,
};

/// Writes the entry for a deployment, replacing any existing entry for it.
/// The file appears under its final name only once complete.
pub fn write(arena: Allocator, io: Io, esp: Io.Dir, options: WriteOptions) !void {
    try esp.createDirPath(io, entries_dir);
    var dir = try esp.openDir(io, entries_dir, .{ .iterate = true });
    defer dir.close(io);

    const name = if (options.counted)
        try std.fmt.allocPrint(arena, prefix ++ "{d}+{d}" ++ suffix, .{ options.id, default_tries })
    else
        try std.fmt.allocPrint(arena, prefix ++ "{d}" ++ suffix, .{options.id});
    var text: Io.Writer.Allocating = .init(arena);
    try text.writer.print(
        \\title joe Linux (deployment {d})
        \\sort-key joe
        \\version {d}
        \\linux {s}
        \\
    , .{ options.id, options.priority, options.kernel });
    for (options.initrds) |initrd| try text.writer.print("initrd {s}\n", .{initrd});
    try text.writer.print("options {s}\n", .{options.options});

    // Remove stale names for this deployment first; if we are interrupted in
    // between, the deployment merely has no entry, which is always safe.
    try removeFrom(arena, io, dir, options.id);
    // The temporary name does not end in ".conf", so the loader ignores it.
    const tmp = try std.fmt.allocPrint(arena, ".{s}.tmp", .{name});
    try dir.writeFile(io, .{ .sub_path = tmp, .data = text.written() });
    {
        var f = try dir.openFile(io, tmp, .{});
        defer f.close(io);
        f.sync(io) catch {};
    }
    try dir.rename(tmp, dir, name, io);
}

/// Marks a deployment's boot good: renames `joe-<id>+L-D.conf` to
/// `joe-<id>.conf`, as systemd-bless-boot does once a counted boot has been
/// checked. Returns whether there was a counter to remove; an entry that is
/// already good is left alone, and a missing one is an error.
pub fn bless(arena: Allocator, io: Io, boot_dir: Io.Dir, id: u32) !bool {
    var dir = try boot_dir.openDir(io, entries_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var counted: ?[]const u8 = null;
    while (try it.next(io)) |e| {
        const parsed = parseName(e.name) orelse continue;
        if (parsed.id != id) continue;
        if (parsed.tries_left == null) return false;
        counted = try arena.dupe(u8, e.name);
    }
    const from = counted orelse return error.FileNotFound;
    const to = try std.fmt.allocPrint(arena, prefix ++ "{d}" ++ suffix, .{id});
    try dir.rename(from, dir, to, io);
    return true;
}

/// Whether a deployment's entry still counts its boots (has not been blessed).
pub fn isCounted(arena: Allocator, io: Io, boot_dir: Io.Dir, id: u32) !bool {
    const entry = find(try list(arena, io, boot_dir), id) orelse return error.FileNotFound;
    return entry.tries_left != null;
}

/// Removes every entry file belonging to a deployment.
pub fn remove(arena: Allocator, io: Io, esp: Io.Dir, id: u32) !void {
    var dir = esp.openDir(io, entries_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    try removeFrom(arena, io, dir, id);
}

fn removeFrom(arena: Allocator, io: Io, dir: Io.Dir, id: u32) !void {
    var doomed: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const parsed = parseName(e.name) orelse continue;
        if (parsed.id == id) try doomed.append(arena, try arena.dupe(u8, e.name));
    }
    for (doomed.items) |name| try dir.deleteFile(io, name);
}

/// Copies a kernel image to the ESP under a name derived from its contents and
/// returns its loader path. An image already present is not rewritten, so an
/// existing entry can never end up pointing at different bytes.
pub fn installKernel(arena: Allocator, io: Io, esp: Io.Dir, src_dir: Io.Dir, src_path: []const u8) ![]const u8 {
    return installByContent(arena, io, esp, src_dir, src_path, kernels_dir, ".efi");
}

/// An initrd, stored and named the same way as kernels.
pub fn installInitrd(arena: Allocator, io: Io, esp: Io.Dir, src_dir: Io.Dir, src_path: []const u8) ![]const u8 {
    return installByContent(arena, io, esp, src_dir, src_path, initrds_dir, ".img");
}

fn installByContent(arena: Allocator, io: Io, esp: Io.Dir, src_dir: Io.Dir, src_path: []const u8, dir: []const u8, ext: []const u8) ![]const u8 {
    const digest = try archive.hashFile(io, src_dir, src_path);
    const rel = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ dir, digest[0..16], ext });
    const loader_path = try std.fmt.allocPrint(arena, "/{s}", .{rel});
    if (esp.statFile(io, rel, .{})) |_| return loader_path else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try esp.createDirPath(io, dir);
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{rel});
    try src_dir.copyFile(src_path, esp, tmp, io, .{});
    try esp.rename(tmp, esp, rel, io);
    return loader_path;
}

/// Deletes kernel images and initrds no remaining entry refers to.
pub fn pruneKernels(arena: Allocator, io: Io, esp: Io.Dir, entries: []const Entry, also_keep: []const []const u8) !void {
    var referenced: std.ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        try referenced.append(arena, entry.kernel);
        try referenced.appendSlice(arena, entry.initrds);
    }
    try referenced.appendSlice(arena, also_keep);
    for ([_][]const u8{ kernels_dir, initrds_dir }) |dir_path| {
        var dir = esp.openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);
        var doomed: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        outer: while (try it.next(io)) |e| {
            const loader_path = try std.fmt.allocPrint(arena, "/{s}/{s}", .{ dir_path, e.name });
            for (referenced.items) |keep| if (std.mem.eql(u8, keep, loader_path)) continue :outer;
            try doomed.append(arena, try arena.dupe(u8, e.name));
        }
        for (doomed.items) |name| try dir.deleteFile(io, name);
    }
}

/// Where a root keeps the systemd-boot it ships.
pub const loader_source = "usr/lib/systemd/boot/efi/" ++ arch.systemd_boot;
/// The firmware's removable-media fallback path.
pub const fallback_loader = "EFI/BOOT/" ++ arch.efi_fallback;
/// Where the firmware finds it: the loader's own path and the removable-media
/// fallback path, both written when the image was made.
pub const loader_targets = [_][]const u8{ "EFI/systemd/" ++ arch.systemd_boot, fallback_loader };

/// Whether a file on the ESP is systemd-boot (and so joe's to replace).
pub fn isLoader(image: []const u8) bool {
    return loaderVersion(image) != null;
}

/// The version a systemd-boot image states about itself ("262.1").
fn loaderVersion(image: []const u8) ?[]const u8 {
    const marker = "#### LoaderInfo: systemd-boot ";
    const at = std.mem.indexOf(u8, image, marker) orelse return null;
    const rest = image[at + marker.len ..];
    return rest[0 .. std.mem.indexOf(u8, rest, " ####") orelse return null];
}

fn newerLoader(new: []const u8, old: []const u8) bool {
    // Distributions append their own release ("262.1-1-arch").
    const upstream = struct {
        fn part(v: []const u8) []const u8 {
            return v[0 .. std.mem.indexOfAny(u8, v, "-~") orelse v.len];
        }
    };
    const a = Version.parse(upstream.part(new)) catch return false;
    const b = Version.parse(upstream.part(old)) catch return false;
    return a.order(b) == .gt;
}

/// Replaces systemd-boot on the ESP with the one `root` ships, if that one is
/// newer; returns whether anything was replaced. The rules are those of
/// `bootctl update`: the loader is shared by every deployment, so it only
/// ever moves forward, and a file that is not systemd-boot is left alone.
/// Each copy appears under its final name only once complete.
pub fn updateLoader(arena: Allocator, io: Io, esp: Io.Dir, root: Io.Dir) !bool {
    const limit: Io.Limit = .limited(64 * 1024 * 1024);
    const new = root.readFileAlloc(io, loader_source, arena, limit) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    const new_version = loaderVersion(new) orelse return false;
    var replaced = false;
    for (loader_targets) |target| {
        const old = esp.readFileAlloc(io, target, arena, limit) catch continue;
        if (!newerLoader(new_version, loaderVersion(old) orelse continue)) continue;
        const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{target});
        try esp.writeFile(io, .{ .sub_path = tmp, .data = new });
        {
            var f = try esp.openFile(io, tmp, .{});
            defer f.close(io);
            f.sync(io) catch {};
        }
        try esp.rename(tmp, esp, target, io);
        replaced = true;
    }
    return replaced;
}

/// Rewrites kernel options for another deployment: only the subvolume changes.
pub fn optionsFor(arena: Allocator, options: []const u8, id: u32) ![]const u8 {
    const marker = "subvol=joe/deploy/";
    const at = std.mem.indexOf(u8, options, marker) orelse return error.NoSubvolumeOption;
    var end = at + marker.len;
    while (end < options.len and std.ascii.isDigit(options[end])) end += 1;
    return std.fmt.allocPrint(arena, "{s}{s}{d}{s}", .{ options[0..at], marker, id, options[end..] });
}

/// The deployment named by a kernel command line, if it is a joe deployment.
pub fn deploymentOf(cmdline: []const u8) ?u32 {
    const marker = "subvol=joe/deploy/";
    const at = std.mem.indexOf(u8, cmdline, marker) orelse return null;
    var end = at + marker.len;
    while (end < cmdline.len and std.ascii.isDigit(cmdline[end])) end += 1;
    return std.fmt.parseInt(u32, cmdline[at + marker.len .. end], 10) catch null;
}

const testing = std.testing;

test "entry file names" {
    try testing.expectEqual(@as(?u32, null), parseName("joe-7.conf").?.tries_left);
    try testing.expectEqual(@as(u32, 7), parseName("joe-7.conf").?.id);
    const fresh = parseName("joe-12+3.conf").?;
    try testing.expectEqual(@as(u32, 12), fresh.id);
    try testing.expectEqual(@as(?u32, 3), fresh.tries_left);
    try testing.expectEqual(@as(u32, 0), fresh.tries_done);
    const used = parseName("joe-12+0-3.conf").?;
    try testing.expectEqual(@as(?u32, 0), used.tries_left);
    try testing.expectEqual(@as(u32, 3), used.tries_done);
    try testing.expect(parseName("arch.conf") == null);
    try testing.expect(parseName("joe-x.conf") == null);
    try testing.expect(parseName("joe-1.conf.tmp") == null);
    try testing.expect(parseName(".joe-1+3.conf.tmp") == null);
}

test "write, list, order and remove entries" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const esp = tmp.dir;
    const opts = "root=PARTUUID=abc rootfstype=btrfs rootflags=subvol=joe/deploy/1 rw rootwait panic=10";

    try testing.expectEqual(@as(usize, 0), (try list(arena, io, esp)).len);
    try write(arena, io, esp, .{ .id = 1, .priority = 1, .kernel = "/joe/kernels/a.efi", .options = opts, .counted = false });
    try write(arena, io, esp, .{ .id = 2, .priority = 2, .kernel = "/joe/kernels/a.efi", .options = try optionsFor(arena, opts, 2), .counted = true });

    var entries = try list(arena, io, esp);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u32, 2), defaultEntry(entries).?.id);
    try testing.expectEqual(Health.trial, entries[0].health());
    try testing.expectEqual(Health.good, entries[1].health());
    try testing.expect(std.mem.indexOf(u8, entries[0].options, "subvol=joe/deploy/2 rw") != null);
    try testing.expectEqualStrings("joe-2+3.conf", entries[0].file_name);

    // What systemd-boot does after three failed attempts.
    try esp.rename(entries_dir ++ "/joe-2+3.conf", esp, entries_dir ++ "/joe-2+0-3.conf", io);
    entries = try list(arena, io, esp);
    try testing.expectEqual(Health.bad, find(entries, 2).?.health());
    try testing.expectEqual(@as(u32, 1), defaultEntry(entries).?.id);

    // Rollback and activation are the same primitive: take the top priority.
    try write(arena, io, esp, .{ .id = 3, .priority = 3, .kernel = "/joe/kernels/b.efi", .options = try optionsFor(arena, opts, 3), .counted = false });
    try write(arena, io, esp, .{ .id = 1, .priority = highestPriority(try list(arena, io, esp)) + 1, .kernel = "/joe/kernels/a.efi", .options = opts, .counted = false });
    entries = try list(arena, io, esp);
    try testing.expectEqual(@as(u32, 1), defaultEntry(entries).?.id);
    try testing.expectEqual(@as(u64, 4), find(entries, 1).?.priority);

    // Rewriting an entry leaves exactly one file for that deployment.
    try write(arena, io, esp, .{ .id = 2, .priority = 9, .kernel = "/joe/kernels/a.efi", .options = opts, .counted = false });
    entries = try list(arena, io, esp);
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqual(Health.good, find(entries, 2).?.health());

    try remove(arena, io, esp, 2);
    try testing.expect(find(try list(arena, io, esp), 2) == null);
}

test "blessing removes the boot counter once" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const esp = tmp.dir;
    const opts = "root=PARTUUID=abc rootflags=subvol=joe/deploy/1 rw";

    try write(arena, io, esp, .{ .id = 1, .priority = 1, .kernel = "/joe/kernels/a.efi", .options = opts, .counted = false });
    try write(arena, io, esp, .{ .id = 2, .priority = 2, .kernel = "/joe/kernels/a.efi", .options = try optionsFor(arena, opts, 2), .counted = true });
    // systemd-boot has counted one attempt.
    try esp.rename(entries_dir ++ "/joe-2+3.conf", esp, entries_dir ++ "/joe-2+2-1.conf", io);
    try testing.expect(try isCounted(arena, io, esp, 2));

    try testing.expect(try bless(arena, io, esp, 2));
    const entries = try list(arena, io, esp);
    try testing.expectEqual(Health.good, find(entries, 2).?.health());
    try testing.expectEqualStrings("joe-2.conf", find(entries, 2).?.file_name);
    try testing.expect(!try isCounted(arena, io, esp, 2));

    // Blessing again, or blessing an entry that never counted, changes nothing.
    try testing.expect(!try bless(arena, io, esp, 2));
    try testing.expect(!try bless(arena, io, esp, 1));
    try testing.expectError(error.FileNotFound, bless(arena, io, esp, 7));
}

test "kernels are stored by content and pruned when unreferenced" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "esp");
    var esp = try tmp.dir.openDir(io, "esp", .{ .iterate = true });
    defer esp.close(io);

    try tmp.dir.writeFile(io, .{ .sub_path = "vmlinuz-a", .data = "kernel a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "vmlinuz-b", .data = "kernel b" });
    const a = try installKernel(arena, io, esp, tmp.dir, "vmlinuz-a");
    const a_again = try installKernel(arena, io, esp, tmp.dir, "vmlinuz-a");
    const b = try installKernel(arena, io, esp, tmp.dir, "vmlinuz-b");
    try testing.expectEqualStrings(a, a_again);
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(std.mem.startsWith(u8, a, "/joe/kernels/"));

    try write(arena, io, esp, .{ .id = 1, .priority = 1, .kernel = a, .options = "subvol=joe/deploy/1", .counted = false });
    try pruneKernels(arena, io, esp, try list(arena, io, esp), &.{});
    _ = try esp.statFile(io, a[1..], .{});
    try testing.expectError(error.FileNotFound, esp.statFile(io, b[1..], .{}));
}

test "initrds are written, read back and kept while referenced" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "esp");
    var esp = try tmp.dir.openDir(io, "esp", .{ .iterate = true });
    defer esp.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = "vmlinuz", .data = "kernel" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ucode-1", .data = "microcode 1" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ucode-2", .data = "microcode 2" });
    const kernel = try installKernel(arena, io, esp, tmp.dir, "vmlinuz");
    const one = try installInitrd(arena, io, esp, tmp.dir, "ucode-1");
    const two = try installInitrd(arena, io, esp, tmp.dir, "ucode-2");
    try testing.expect(std.mem.startsWith(u8, one, "/joe/initrd/") and std.mem.endsWith(u8, one, ".img"));

    try write(arena, io, esp, .{ .id = 1, .priority = 1, .kernel = kernel, .initrds = &.{one}, .options = "subvol=joe/deploy/1", .counted = false });
    try write(arena, io, esp, .{ .id = 2, .priority = 2, .kernel = kernel, .options = "subvol=joe/deploy/2", .counted = false });
    const text = try esp.readFileAlloc(io, entries_dir ++ "/joe-1.conf", arena, .limited(4096));
    // The order systemd-boot reads: initrd lines between linux and options.
    try testing.expect(std.mem.indexOf(u8, text, "linux /joe/kernels/").? < std.mem.indexOf(u8, text, "initrd /joe/initrd/").?);
    try testing.expect(std.mem.indexOf(u8, text, "initrd /joe/initrd/").? < std.mem.indexOf(u8, text, "options ").?);

    const entries = try list(arena, io, esp);
    try testing.expectEqual(@as(usize, 1), find(entries, 1).?.initrds.len);
    try testing.expectEqualStrings(one, find(entries, 1).?.initrds[0]);
    try testing.expectEqual(@as(usize, 0), find(entries, 2).?.initrds.len);

    try pruneKernels(arena, io, esp, entries, &.{});
    _ = try esp.statFile(io, one[1..], .{});
    _ = try esp.statFile(io, kernel[1..], .{});
    try testing.expectError(error.FileNotFound, esp.statFile(io, two[1..], .{}));
}

test "the boot loader on the ESP only moves forward" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "esp/EFI/systemd");
    try tmp.dir.createDirPath(io, "esp/EFI/BOOT");
    try tmp.dir.createDirPath(io, "root/usr/lib/systemd/boot/efi");
    var esp = try tmp.dir.openDir(io, "esp", .{ .iterate = true });
    defer esp.close(io);
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    const read = struct {
        fn file(a: Allocator, dir: Io.Dir, path: []const u8) ![]const u8 {
            return dir.readFileAlloc(testing.io, path, a, .limited(1 << 20));
        }
    }.file;

    const v262 = "MZ #### LoaderInfo: systemd-boot 262.1-1-arch #### old";
    const v263 = "MZ #### LoaderInfo: systemd-boot 263 #### new";
    try esp.writeFile(io, .{ .sub_path = loader_targets[0], .data = v262 });
    // The fallback path holds some other system's loader: not ours to replace.
    try esp.writeFile(io, .{ .sub_path = loader_targets[1], .data = "MZ grub" });

    // A root that ships no loader, the same one, or an older one changes nothing.
    try testing.expect(!try updateLoader(arena, io, esp, root));
    try root.writeFile(io, .{ .sub_path = loader_source, .data = "MZ #### LoaderInfo: systemd-boot 262.1 ####" });
    try testing.expect(!try updateLoader(arena, io, esp, root));
    try root.writeFile(io, .{ .sub_path = loader_source, .data = "MZ #### LoaderInfo: systemd-boot 261.4 ####" });
    try testing.expect(!try updateLoader(arena, io, esp, root));
    try testing.expectEqualStrings(v262, try read(arena, esp, loader_targets[0]));

    try root.writeFile(io, .{ .sub_path = loader_source, .data = v263 });
    try testing.expect(try updateLoader(arena, io, esp, root));
    try testing.expectEqualStrings(v263, try read(arena, esp, loader_targets[0]));
    try testing.expectEqualStrings("MZ grub", try read(arena, esp, loader_targets[1]));
    try testing.expectError(error.FileNotFound, esp.statFile(io, loader_targets[0] ++ ".tmp", .{}));
}

test "command line helpers" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(?u32, 14), deploymentOf("root=PARTUUID=x rootflags=subvol=joe/deploy/14 rw"));
    try testing.expectEqual(@as(?u32, null), deploymentOf("root=/dev/sda2 rw"));
    try testing.expectEqualStrings(
        "root=PARTUUID=x rootflags=subvol=joe/deploy/205 rw quiet",
        try optionsFor(arena, "root=PARTUUID=x rootflags=subvol=joe/deploy/9 rw quiet", 205),
    );
    try testing.expectError(error.NoSubvolumeOption, optionsFor(arena, "root=/dev/sda2", 2));
}
