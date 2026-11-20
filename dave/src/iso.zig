//! The live medium: what `dave image build` makes of a spec with
//! `.format = .iso`.
//!
//! The medium is one ISO 9660 file system that boots on UEFI computers from a
//! CD (El Torito) and, written to a USB stick, as a disk (its GPT has the EFI
//! system partition appended). It holds:
//!
//!   joe/root.squashfs     the live root: the spec's tree as a compressed
//!                         read-only SquashFS image
//!   joe/install.zon       what the installer installs (the spec's payload),
//!                         which it copies out of the live root, where it is
//!                         installed already, so that the medium carries every
//!                         package once (install_system.zig)
//!   joe/originals/        the files of those packages the live root holds
//!                         changed, as they were packaged, by SHA-256
//!
//! and the EFI system partition holds systemd-boot, the kernel, the initramfs
//! and two entries (the second with `nomodeset`, for graphics that do not
//! come up). joe's installed systems boot without an initramfs; the live
//! medium cannot, because its root is a file on a file system on the medium,
//! with a writable layer in memory over it. Its initramfs is itself made by
//! dave: a transaction of a few packages (systemd and what it needs) into a
//! directory, plus the units of image/initrd/ that mount the medium, the
//! image and the layer, archived as a zstd-compressed newc cpio.
//!
//! Nothing on the medium is sealed (SquashFS and overlayfs have no
//! fs-verity),
//! so the security module runs in log mode there, stated on the command line
//! so that a kernel built to enforce by default still boots it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const cpio = @import("cpio.zig");
const archive = @import("archive.zig");

pub const Options = struct {
    /// The ISO 9660 volume label; the initramfs finds the medium by it, so it
    /// must match image/initrd's run-live-medium.mount.
    label: []const u8 = "JOE_LIVE",
    initrd: Initrd = .{},
    /// What the installer installs. These packages and everything they
    /// depend on are put on the medium.
    payload: []const []const u8 = &.{},
    /// mksquashfs's -comp argument for the live root: xz, the smallest
    /// download, as other distributions' media use (with the filter for the
    /// architecture's code, arch.xz_bcj, and 1 MiB blocks); zstd
    /// decompresses faster.
    compression: []const u8 = "xz",
};

pub const Initrd = struct {
    packages: []const []const u8 = &.{},
    /// Copied over the installed packages (relative to the spec).
    overlay: ?[]const u8 = null,
    /// Paths deleted from the initramfs tree afterwards: what only takes
    /// space there (headers, manuals, translations, the package database).
    remove: []const []const u8 = &.{},
};

/// The live system's command line, before the spec's own additions.
/// - No root=: the initramfs's init (dynamod-init, in its live mode, which
///   the spec's command line asks for) finds the medium and makes the root.
/// - joe=log: see the file comment.
/// - loglevel=4: the module's reports and other notices stay off the screen.
pub const live_cmdline = "joe=log loglevel=4";

pub const loader_conf = "timeout 5\ndefault joe-live.conf\neditor no\n";

pub const Entry = struct {
    file: []const u8,
    title: []const u8,
    sort_key: []const u8,
    extra: []const u8 = "",
};

pub const entries = [_]Entry{
    .{ .file = "joe-live.conf", .title = "{s}", .sort_key = "joe-live-1" },
    .{ .file = "joe-live-safe.conf", .title = "{s} (safe graphics)", .sort_key = "joe-live-2", .extra = "nomodeset" },
};

/// A boot entry of the medium. `name` is the system's PRETTY_NAME.
pub fn entryText(arena: Allocator, e: Entry, name: []const u8, kernel: []const u8, initrd: []const u8, options: []const u8) ![]const u8 {
    const title = if (std.mem.eql(u8, e.title, "{s}"))
        name
    else
        try std.fmt.allocPrint(arena, "{s} (safe graphics)", .{name});
    const all = if (e.extra.len == 0) options else try std.fmt.allocPrint(arena, "{s} {s}", .{ options, e.extra });
    return std.fmt.allocPrint(arena,
        \\title {s}
        \\sort-key {s}
        \\linux {s}
        \\initrd {s}
        \\options {s}
        \\
    , .{ title, e.sort_key, kernel, initrd, all });
}

/// The PRETTY_NAME of an os-release file, or a fallback.
pub fn prettyName(os_release: []const u8) []const u8 {
    var lines = std.mem.tokenizeScalar(u8, os_release, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "PRETTY_NAME=")) continue;
        return std.mem.trim(u8, line["PRETTY_NAME=".len..], "\"' \t\r");
    }
    return "joe Linux";
}

/// The size of a FAT image with room for `content` bytes: a fifth more for
/// the file system's own structures and rounding, in whole MiB.
pub fn espImageSize(content: u64) u64 {
    const mib: u64 = 1024 * 1024;
    const wanted = content + content / 5 + 8 * mib;
    return (wanted + mib - 1) / mib * mib;
}

/// Writes `tree` as the medium's initramfs at `out_path`: a newc cpio,
/// compressed by the zstd program. /dev/console is added, since the kernel
/// opens it for /init before anything has mounted /dev.
pub fn writeInitrd(arena: Allocator, io: Io, tree: Io.Dir, out_path: []const u8) !void {
    var out_file = try Io.Dir.cwd().createFile(io, out_path, .{ .truncate = true });
    defer out_file.close(io);
    var child = try std.process.spawn(io, .{
        .argv = &.{ "zstd", "-q", "-T0", "-19", "-c" },
        .stdin = .pipe,
        .stdout = .{ .file = out_file },
    });
    errdefer child.kill(io);
    var pipe_buf: [64 * 1024]u8 = undefined;
    var pipe = child.stdin.?.writer(io, &pipe_buf);
    var w: cpio.Writer = .{ .out = &pipe.interface };
    var has_dev = true;
    _ = tree.statFile(io, "dev", .{}) catch {
        has_dev = false;
    };
    if (!has_dev) try w.directory("dev", 0o755);
    try w.charDevice("dev/console", 0o600, 5, 1);
    try cpio.writeTree(arena, io, tree, &w);
    try w.finish();
    try pipe.interface.flush();
    child.stdin.?.close(io);
    child.stdin = null;
    const term = try child.wait(io);
    if (!term.success()) return error.CompressionFailed;
}

/// The xorriso command that writes the medium: an ISO 9660 file system with
/// Rock Ridge (long names, modes, links) and Joliet, booting on UEFI only.
/// The ESP image is appended as GPT partition 2, which is what a computer
/// booting the medium as a USB disk finds, and El Torito's EFI boot entry
/// points at the same bytes, which is what it finds booting it as a CD.
pub fn xorrisoArgv(arena: Allocator, staging: []const u8, esp_image: []const u8, label: []const u8, out: []const u8) ![]const []const u8 {
    const argv = [_][]const u8{
        "xorriso",               "-as",                   "mkisofs",                               "-quiet",
        "-iso-level",            "3",                     "-full-iso9660-filenames",               "-joliet",
        "-joliet-long",          "-rational-rock",        "-volid",                                label,
        "-appid",                "joe Linux live medium", "-publisher",                            "joe Linux",
        "-preparer",             "dave image build",      "-partition_offset",                     "16",
        "-append_partition",     "2",                     "C12A7328-F81F-11D2-BA4B-00A0C93EC93B",  esp_image,
        "-appended_part_as_gpt", "-e",                    "--interval:appended_partition_2:all::", "-no-emul-boot",
        "-output",               out,                     staging,
    };
    return arena.dupe([]const u8, &argv);
}

const testing = std.testing;

test "the medium's boot entries" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const name = prettyName("NAME=\"joe Linux\"\nPRETTY_NAME=\"joe Linux J1-7.3.1-0.2.0-alpha1\"\nID=joe\n");
    try testing.expectEqualStrings("joe Linux J1-7.3.1-0.2.0-alpha1", name);
    try testing.expectEqualStrings("joe Linux", prettyName("ID=joe\n"));

    const normal = try entryText(arena, entries[0], name, "/joe/kernels/a.efi", "/joe/initrd/b.img", live_cmdline);
    try testing.expect(std.mem.startsWith(u8, normal, "title joe Linux J1-7.3.1-0.2.0-alpha1\n"));
    try testing.expect(std.mem.indexOf(u8, normal, "initrd /joe/initrd/b.img\n") != null);
    try testing.expect(std.mem.indexOf(u8, normal, "root=") == null);
    try testing.expect(std.mem.indexOf(u8, normal, "nomodeset") == null);
    const safe = try entryText(arena, entries[1], name, "/joe/kernels/a.efi", "/joe/initrd/b.img", live_cmdline);
    try testing.expect(std.mem.indexOf(u8, safe, "(safe graphics)") != null);
    try testing.expect(std.mem.endsWith(u8, safe, "loglevel=4 nomodeset\n"));
    try testing.expect(std.mem.indexOf(u8, loader_conf, "default " ++ entries[0].file) != null);
}

test "ESP image sizes" {
    const mib: u64 = 1024 * 1024;
    try testing.expectEqual(@as(u64, 0), espImageSize(60 * mib) % mib);
    try testing.expect(espImageSize(60 * mib) >= 72 * mib);
}

test "the medium's writers compile" {
    _ = &writeInitrd;
    _ = &xorrisoArgv;
}
