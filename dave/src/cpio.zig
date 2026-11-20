//! The "newc" cpio format, which is what the kernel unpacks an initramfs
//! from.
//!
//! An initramfs is written directly from a directory tree rather than by
//! cpio(1), for two reasons. Every entry is owned by root and has the same
//! modification time whoever builds it, so the same tree always gives the same
//! bytes. And entries the builder could not create on disk without privileges
//! can still be written: /dev/console, which the kernel opens for /init's
//! standard streams before anything has mounted /dev.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const magic = "070701";
const trailer = "TRAILER!!!";

pub const S_IFDIR: u32 = 0o040000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFLNK: u32 = 0o120000;
pub const S_IFCHR: u32 = 0o020000;

pub const Writer = struct {
    out: *Io.Writer,
    /// Seconds since the epoch, for every entry.
    mtime: u32 = 0,
    next_ino: u32 = 1,

    const Header = struct {
        mode: u32,
        size: u32 = 0,
        nlink: u32 = 1,
        rdev_major: u32 = 0,
        rdev_minor: u32 = 0,
    };

    fn header(w: *Writer, name: []const u8, h: Header) !void {
        const ino = w.next_ino;
        w.next_ino += 1;
        const fields = [_]u32{
            ino, h.mode, 0,            0,            h.nlink,                w.mtime, h.size,
            0,   0,      h.rdev_major, h.rdev_minor, @intCast(name.len + 1), 0,
        };
        try w.out.writeAll(magic);
        for (fields) |f| try w.out.print("{x:0>8}", .{f});
        try w.out.writeAll(name);
        try w.out.writeByte(0);
        try pad(w.out, 110 + name.len + 1);
    }

    pub fn directory(w: *Writer, name: []const u8, permissions: u32) !void {
        try w.header(name, .{ .mode = S_IFDIR | (permissions & 0o7777), .nlink = 2 });
    }

    pub fn file(w: *Writer, name: []const u8, permissions: u32, contents: []const u8) !void {
        try w.header(name, .{ .mode = S_IFREG | (permissions & 0o7777), .size = @intCast(contents.len) });
        try w.out.writeAll(contents);
        try pad(w.out, contents.len);
    }

    /// A regular file whose contents are streamed from `reader`.
    pub fn fileFrom(w: *Writer, name: []const u8, permissions: u32, size: u64, reader: *Io.Reader) !void {
        if (size > std.math.maxInt(u32)) return error.FileTooBig;
        try w.header(name, .{ .mode = S_IFREG | (permissions & 0o7777), .size = @intCast(size) });
        try reader.streamExact64(w.out, size);
        try pad(w.out, size);
    }

    pub fn symlink(w: *Writer, name: []const u8, target: []const u8) !void {
        try w.header(name, .{ .mode = S_IFLNK | 0o777, .size = @intCast(target.len) });
        try w.out.writeAll(target);
        try pad(w.out, target.len);
    }

    pub fn charDevice(w: *Writer, name: []const u8, permissions: u32, major: u32, minor: u32) !void {
        try w.header(name, .{ .mode = S_IFCHR | (permissions & 0o7777), .rdev_major = major, .rdev_minor = minor });
    }

    pub fn finish(w: *Writer) !void {
        try w.header(trailer, .{ .mode = 0 });
    }
};

/// Entries are padded to four bytes.
fn pad(out: *Io.Writer, len: u64) !void {
    const rem: usize = @intCast(len % 4);
    if (rem != 0) try out.splatByteAll(0, 4 - rem);
}

/// Writes every entry under `root` (directories, regular files and symbolic
/// links), sorted by path so that the archive does not depend on the order
/// the file system lists them in. Paths are relative ("usr/bin/x").
pub fn writeTree(arena: Allocator, io: Io, root: Io.Dir, w: *Writer) !void {
    try writeDir(arena, io, root, "", w);
}

fn writeDir(arena: Allocator, io: Io, dir: Io.Dir, prefix: []const u8, w: *Writer) !void {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| try names.append(arena, try arena.dupe(u8, e.name));
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    for (names.items) |name| {
        const path = if (prefix.len == 0) name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
        const st = try dir.statFile(io, name, .{ .follow_symlinks = false });
        const permissions: u32 = @intCast(st.permissions.toMode() & 0o7777);
        switch (st.kind) {
            .directory => {
                try w.directory(path, permissions);
                var sub = try dir.openDir(io, name, .{ .iterate = true });
                defer sub.close(io);
                try writeDir(arena, io, sub, path, w);
            },
            .file => {
                var f = try dir.openFile(io, name, .{});
                defer f.close(io);
                var buf: [64 * 1024]u8 = undefined;
                var reader = f.reader(io, &buf);
                try w.fileFrom(path, permissions, st.size, &reader.interface);
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = try dir.readLink(io, name, &buf);
                try w.symlink(path, buf[0..n]);
            },
            // Sockets and pipes have no place in an initramfs.
            else => {},
        }
    }
}

const testing = std.testing;

test "newc entries are what the kernel and cpio(1) expect" {
    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var w: Writer = .{ .out = &out.writer, .mtime = 0x5f5e100 };
    try w.directory("dev", 0o755);
    try w.charDevice("dev/console", 0o600, 5, 1);
    try w.file("init", 0o755, "#!/bin/sh\n");
    try w.symlink("bin", "usr/bin");
    try w.finish();
    const bytes = out.written();

    // The first header: magic, inode 1, a directory 0755, owned by 0:0.
    try testing.expectEqualStrings("070701" ++ "00000001" ++ "000041ed" ++ "00000000" ++ "00000000", bytes[0..38]);
    // Every header starts on a four-byte boundary.
    var at: usize = 0;
    var count: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, at, "070701")) |pos| : (count += 1) {
        try testing.expectEqual(@as(usize, 0), pos % 4);
        at = pos + 6;
    }
    try testing.expectEqual(@as(usize, 5), count);
    try testing.expect(std.mem.indexOf(u8, bytes, "dev/console\x00") != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, bytes, "\x00"), "TRAILER!!!"));
    try testing.expectEqual(@as(usize, 0), bytes.len % 4);
}

test "a tree is written sorted, with links and modes" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/b", .data = "bee", .flags = .{ .permissions = .fromMode(0o755) } });
    try tmp.dir.writeFile(io, .{ .sub_path = "usr/bin/a", .data = "ay" });
    try tmp.dir.symLink(io, "usr//bin", "bin", .{});

    var out: Io.Writer.Allocating = .init(arena);
    var w: Writer = .{ .out = &out.writer };
    try writeTree(arena, io, tmp.dir, &w);
    try w.finish();
    const bytes = out.written();
    const order = [_][]const u8{ "bin\x00", "usr\x00", "usr/bin\x00", "usr/bin/a\x00", "usr/bin/b\x00" };
    var last: usize = 0;
    for (order) |name| {
        const pos = std.mem.indexOf(u8, bytes, name) orelse return error.EntryMissing;
        try testing.expect(pos >= last);
        last = pos;
    }
    // The executable kept its mode: 0100755.
    try testing.expect(std.mem.indexOf(u8, bytes, "000081ed") != null);
}
