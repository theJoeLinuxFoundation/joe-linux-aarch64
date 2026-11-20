//! The firmware's boot entries, as `bootctl install --variables=yes` writes
//! them: a Boot#### EFI variable holding an EFI_LOAD_OPTION that names the
//! boot loader's file on the EFI system partition by the partition's GPT
//! identity, first in BootOrder. joe has no bootctl (systemd-boot is built
//! on its own), so dave writes them itself, through efivarfs.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const efivars = "/sys/firmware/efi/efivars";
/// EFI_GLOBAL_VARIABLE, whose Boot#### and BootOrder the firmware reads.
const global_guid = "8be4df61-93ca-11d2-aa0d-00e098032b8c";
/// Non-volatile, readable by boot services and at run time.
const variable_attributes: u32 = 0x7;
/// LOAD_OPTION_ACTIVE: the firmware may boot it.
const load_option_active: u32 = 0x1;

/// An EFI system partition, as a hard drive device path names it.
pub const Partition = struct {
    number: u32,
    /// The first block and the size, in the disk's logical blocks.
    start: u64,
    size: u64,
    /// The partition's unique GUID in the GPT, as text.
    uuid: []const u8,
};

/// The partition `device` (a /dev path or a link to one) from sysfs, with
/// `uuid` its GPT partition GUID, which the caller wrote or read.
pub fn partitionOf(arena: Allocator, io: Io, device: []const u8, uuid: []const u8) !Partition {
    const real = try Io.Dir.cwd().realPathFileAlloc(io, device, arena);
    const name = std.fs.path.basename(real);
    const dir = try std.fmt.allocPrint(arena, "/sys/class/block/{s}", .{name});
    // sysfs counts in 512-byte sectors whatever the disk's block size; the
    // device path counts in the disk's logical blocks (the parent directory,
    // once the link is followed, is the disk's).
    const block = try readNumber(arena, io, try std.fs.path.join(arena, &.{ dir, "../queue/logical_block_size" }));
    if (block == 0 or block % 512 != 0) return error.BadBlockSize;
    const start = try readNumber(arena, io, try std.fs.path.join(arena, &.{ dir, "start" }));
    const size = try readNumber(arena, io, try std.fs.path.join(arena, &.{ dir, "size" }));
    return .{
        .number = @intCast(try readNumber(arena, io, try std.fs.path.join(arena, &.{ dir, "partition" }))),
        .start = start * 512 / block,
        .size = size * 512 / block,
        .uuid = uuid,
    };
}

fn readNumber(arena: Allocator, io: Io, path: []const u8) !u64 {
    const text = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64));
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10);
}

/// The 16 bytes of a GUID written as text: its first three fields are
/// little-endian.
pub fn guidBytes(text: []const u8) error{BadUuid}![16]u8 {
    if (text.len != 36) return error.BadUuid;
    var raw: [16]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '-') {
            if (i != 8 and i != 13 and i != 18 and i != 23) return error.BadUuid;
            i += 1;
            continue;
        }
        if (i + 2 > text.len or n == raw.len) return error.BadUuid;
        raw[n] = std.fmt.parseInt(u8, text[i .. i + 2], 16) catch return error.BadUuid;
        n += 1;
        i += 2;
    }
    if (n != raw.len) return error.BadUuid;
    var out = raw;
    std.mem.reverse(u8, out[0..4]);
    std.mem.reverse(u8, out[4..6]);
    std.mem.reverse(u8, out[6..8]);
    return out;
}

fn appendInt(arena: Allocator, list: *std.ArrayList(u8), comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(arena, &bytes);
}

/// ASCII as UCS-2, with its terminating zero.
fn appendUcs2(arena: Allocator, list: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| try list.appendSlice(arena, &.{ c, 0 });
    try list.appendSlice(arena, &.{ 0, 0 });
}

/// The EFI_LOAD_OPTION that boots `loader`, a path on the ESP such as
/// "EFI/systemd/systemd-bootaa64.efi", shown as `description`.
pub fn loadOption(arena: Allocator, esp: Partition, loader: []const u8, description: []const u8) ![]u8 {
    var path: std.ArrayList(u8) = .empty;
    // Media device path, hard drive: the partition by its GPT GUID.
    try path.appendSlice(arena, &.{ 0x04, 0x01 });
    try appendInt(arena, &path, u16, 42);
    try appendInt(arena, &path, u32, esp.number);
    try appendInt(arena, &path, u64, esp.start);
    try appendInt(arena, &path, u64, esp.size);
    try path.appendSlice(arena, &(try guidBytes(esp.uuid)));
    try path.appendSlice(arena, &.{ 0x02, 0x02 }); // GPT; the signature is a GUID
    // Media device path, file path: the loader, with backslashes.
    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(arena, &.{ '\\', 0 });
    for (loader) |c| try file.appendSlice(arena, &.{ if (c == '/') '\\' else c, 0 });
    try file.appendSlice(arena, &.{ 0, 0 });
    try path.appendSlice(arena, &.{ 0x04, 0x04 });
    try appendInt(arena, &path, u16, @intCast(4 + file.items.len));
    try path.appendSlice(arena, file.items);
    // The end of the device path.
    try path.appendSlice(arena, &.{ 0x7f, 0xff, 0x04, 0x00 });

    var option: std.ArrayList(u8) = .empty;
    try appendInt(arena, &option, u32, load_option_active);
    try appendInt(arena, &option, u16, @intCast(path.items.len));
    try appendUcs2(arena, &option, description);
    try option.appendSlice(arena, path.items);
    return option.items;
}

/// The number of a Boot#### variable's file in efivarfs, or null for
/// another variable.
fn bootNumber(name: []const u8) ?u16 {
    const suffix = "-" ++ global_guid;
    if (name.len != 8 + suffix.len or !std.mem.startsWith(u8, name, "Boot") or !std.mem.endsWith(u8, name, suffix)) return null;
    const digits = name[4..8];
    for (digits) |c| if (!std.ascii.isDigit(c) and !(c >= 'A' and c <= 'F')) return null;
    return std.fmt.parseInt(u16, digits, 16) catch null;
}

/// Makes `loader` on `esp` a boot entry, first in the firmware's boot
/// order, and returns its number. An entry the same as this one is reused,
/// so that installing twice adds no second entry.
pub fn register(arena: Allocator, io: Io, esp: Partition, loader: []const u8, description: []const u8) !u16 {
    const option = try loadOption(arena, esp, loader, description);
    var dir = Io.Dir.cwd().openDir(io, efivars, .{ .iterate = true }) catch return error.NoEfiVariables;
    defer dir.close(io);

    const used = try arena.alloc(bool, 0x10000);
    @memset(used, false);
    var number: ?u16 = null;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        const n = bootNumber(e.name) orelse continue;
        used[n] = true;
        const data = dir.readFileAlloc(io, e.name, arena, .limited(64 * 1024)) catch continue;
        if (data.len >= 4 and std.mem.eql(u8, data[4..], option)) number = n;
    }
    const chosen = number orelse for (used, 0..) |u, n| {
        if (!u) break @as(u16, @intCast(n));
    } else return error.NoFreeEntry;

    var name_buf: [64]u8 = undefined;
    const entry_name = try std.fmt.bufPrint(&name_buf, "Boot{X:0>4}-" ++ global_guid, .{chosen});
    if (number == null) try setVariable(arena, io, dir, entry_name, option);

    // BootOrder: this entry first, the others after it as they were.
    const order_name = "BootOrder-" ++ global_guid;
    var order: std.ArrayList(u8) = .empty;
    try appendInt(arena, &order, u16, chosen);
    if (dir.readFileAlloc(io, order_name, arena, .limited(64 * 1024))) |old| {
        var i: usize = 4;
        while (i + 2 <= old.len) : (i += 2) {
            const n = std.mem.readInt(u16, old[i..][0..2], .little);
            if (n != chosen) try appendInt(arena, &order, u16, n);
        }
    } else |_| {}
    try setVariable(arena, io, dir, order_name, order.items);
    return chosen;
}

/// Sets a variable in efivarfs: its attributes and data in one write, to a
/// file opened without truncating it, as efivarfs takes them.
fn setVariable(arena: Allocator, io: Io, dir: Io.Dir, name: []const u8, data: []const u8) !void {
    var bytes: std.ArrayList(u8) = .empty;
    try appendInt(arena, &bytes, u32, variable_attributes);
    try bytes.appendSlice(arena, data);
    var file = try dir.createFile(io, name, .{ .truncate = false });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes.items);
}

const testing = std.testing;

test "a GUID's first three fields are little-endian" {
    const g = try guidBytes("ccda9a54-a5e3-416a-b07f-8227391fcc2c");
    try testing.expectEqualSlices(u8, &.{ 0x54, 0x9a, 0xda, 0xcc, 0xe3, 0xa5, 0x6a, 0x41, 0xb0, 0x7f, 0x82, 0x27, 0x39, 0x1f, 0xcc, 0x2c }, &g);
    try testing.expectError(error.BadUuid, guidBytes("ccda9a54a5e3-416a-b07f-8227391fcc2c-"));
    try testing.expectError(error.BadUuid, guidBytes("not a guid"));
}

test "a load option names the partition and the loader" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const esp: Partition = .{ .number = 1, .start = 2048, .size = 2097152, .uuid = "ccda9a54-a5e3-416a-b07f-8227391fcc2c" };
    const option = try loadOption(arena, esp, "EFI/systemd/systemd-bootaa64.efi", "joe");
    // Attributes, the device path's length, the description.
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, option[0..4], .little));
    const path_len = std.mem.readInt(u16, option[4..6], .little);
    try testing.expectEqualSlices(u8, &.{ 'j', 0, 'o', 0, 'e', 0, 0, 0 }, option[6..14]);
    const path = option[14..];
    try testing.expectEqual(@as(usize, path_len), path.len);
    // The hard drive node.
    try testing.expectEqualSlices(u8, &.{ 0x04, 0x01, 42, 0 }, path[0..4]);
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, path[4..8], .little));
    try testing.expectEqual(@as(u64, 2048), std.mem.readInt(u64, path[8..16], .little));
    try testing.expectEqual(@as(u64, 2097152), std.mem.readInt(u64, path[16..24], .little));
    try testing.expectEqualSlices(u8, &(try guidBytes(esp.uuid)), path[24..40]);
    try testing.expectEqualSlices(u8, &.{ 0x02, 0x02 }, path[40..42]);
    // The file path node: "\EFI\systemd\systemd-bootaa64.efi" and its zero.
    const file = path[42..];
    try testing.expectEqualSlices(u8, &.{ 0x04, 0x04 }, file[0..2]);
    const file_len = std.mem.readInt(u16, file[2..4], .little);
    try testing.expectEqual(@as(usize, 4 + 2 * ("\\EFI\\systemd\\systemd-bootaa64.efi".len + 1)), file_len);
    try testing.expectEqualSlices(u8, &.{ '\\', 0, 'E', 0, 'F', 0, 'I', 0, '\\', 0 }, file[4..14]);
    // The end node.
    try testing.expectEqualSlices(u8, &.{ 0x7f, 0xff, 0x04, 0x00 }, file[file_len..]);
}

test "Boot#### variables and nothing else" {
    try testing.expectEqual(@as(?u16, 0x1a), bootNumber("Boot001A-" ++ global_guid));
    try testing.expectEqual(@as(?u16, null), bootNumber("BootOrder-" ++ global_guid));
    try testing.expectEqual(@as(?u16, null), bootNumber("Boot0001-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"));
    try testing.expectEqual(@as(?u16, null), bootNumber("Boot001a-" ++ global_guid));
}
