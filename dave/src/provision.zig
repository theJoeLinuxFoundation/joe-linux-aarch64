//! The layout of a joe Linux disk, as data and text.
//!
//! A joe system reaches a disk in two ways, and both are described here so
//! that they cannot drift apart: `dave image build` (image.zig) assembles a
//! disk image offline from files, and `dave install-system` partitions and
//! formats a real disk from a running live system.
//!
//!   partition 1  EFI system partition (FAT32): systemd-boot, kernels, entries
//!   partition 2  btrfs, of the Discoverable Partitions root type of the
//!                architecture ("root-x86-64", "root-arm64"; arch.zig):
//!                  joe/deploy/1   subvolume, the first deployment (mounted at /)
//!                  home           subvolume, shared by all deployments
//!                  var            subvolume, shared by all deployments
//!
//! `joe` and `joe/deploy` are plain directories at the top level, which stays
//! the default subvolume. The root's own mount comes from the kernel command
//! line, never from fstab: there is no initramfs, so the kernel mounts it by
//! the partition's GPT UUID, the one name it can resolve by itself.
//!
//! The partition type matters beyond tidiness: joe-base's repart.d grows the
//! partition of type "root" over free space at every boot. A root that fills
//! its disk is left alone; one of another type would get a sibling.
//!
//! Beside another operating system (`Beside`), joe takes one stretch of free
//! space and touches nothing else. It shares the disk's existing ESP, where
//! systemd-boot finds the other system (Windows' boot manager, by itself) and
//! offers both in its menu; the ESP gets only the boot loader, which is small,
//! and never anything the other system put there. Kernels and boot entries go
//! on an extended boot loader partition (XBOOTLDR) of joe's own, the first
//! part of the free space, which systemd-boot reads as it reads the ESP:
//!
//!   existing     EFI system partition, shared: systemd-boot
//!   free space   XBOOTLDR (FAT32): kernels, entries
//!                btrfs root, laid out as above

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const boot = @import("boot.zig");
const deploy = @import("deploy.zig");
const arch = @import("arch.zig");

pub const esp_type = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
pub const root_type = arch.root_partition_type;
pub const esp_label = "JOE-ESP";
pub const root_label = "joe";
pub const first_deployment: u32 = 1;
pub const first_deployment_path = "joe/deploy/1";
/// Subvolumes the shared state lives in, mounted under every deployment.
pub const shared_subvolumes = deploy.shared_subvolumes;
/// Where the ESP is mounted in every deployment (main.zig expects it there).
pub const esp_mount = "efi";
pub const xbootldr_type = "BC13C2FF-59E6-4262-A352-B275FD6F7172";
pub const xbootldr_label = "JOE-BOOT";
/// Where the XBOOTLDR partition is mounted, when there is one; dave finds it
/// there (main.zig) and systemd looks for it there.
pub const xbootldr_mount = "boot";
pub const default_xbootldr_size: u64 = 1024 * mib;

pub const mib: u64 = 1024 * 1024;
/// Partitions start on a 1 MiB boundary, as every partitioning tool does;
/// the first MiB holds the protective MBR and the primary GPT.
pub const first_offset: u64 = mib;
/// Room after the last partition for the backup GPT.
pub const tail: u64 = mib;
pub const default_esp_size: u64 = 1024 * mib;

/// A GPT partition UUID in its textual form, lower case.
pub const Uuid = [36]u8;

/// A random (version 4) UUID.
pub fn newUuid(io: Io) Uuid {
    var bytes: [16]u8 = undefined;
    io.random(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return formatUuid(bytes);
}

fn formatUuid(bytes: [16]u8) Uuid {
    const hex = std.fmt.bytesToHex(bytes, .lower);
    var out: Uuid = undefined;
    @memcpy(out[0..8], hex[0..8]);
    out[8] = '-';
    @memcpy(out[9..13], hex[8..12]);
    out[13] = '-';
    @memcpy(out[14..18], hex[12..16]);
    out[18] = '-';
    @memcpy(out[19..23], hex[16..20]);
    out[23] = '-';
    @memcpy(out[24..36], hex[20..32]);
    return out;
}

pub const Plan = struct {
    esp_uuid: Uuid,
    root_uuid: Uuid,
    /// Bytes; a whole number of MiB.
    esp_size: u64 = default_esp_size,
    /// Bytes, a whole number of MiB; null gives the root the rest of the disk.
    root_size: ?u64 = null,

    pub fn new(io: Io, esp_size: u64, root_size: ?u64) Plan {
        return .{ .esp_uuid = newUuid(io), .root_uuid = newUuid(io), .esp_size = esp_size, .root_size = root_size };
    }

    pub fn espOffset(_: Plan) u64 {
        return first_offset;
    }

    pub fn rootOffset(p: Plan) u64 {
        return first_offset + p.esp_size;
    }

    /// The size of a disk image holding exactly this plan. Only meaningful
    /// when the root has a fixed size.
    pub fn imageSize(p: Plan) u64 {
        return p.rootOffset() + p.root_size.? + tail;
    }
};

/// A joe system in the free space of a disk another system already uses.
pub const Beside = struct {
    /// The disk's existing EFI system partition, which joe shares.
    esp_uuid: Uuid,
    xbootldr_uuid: Uuid,
    root_uuid: Uuid,
    /// The free space joe takes, in bytes from the start of the disk; whole
    /// MiB.
    start: u64,
    size: u64,
    xbootldr_size: u64 = default_xbootldr_size,

    pub fn new(io: Io, esp_uuid: Uuid, start: u64, size: u64) Beside {
        return .{ .esp_uuid = esp_uuid, .xbootldr_uuid = newUuid(io), .root_uuid = newUuid(io), .start = start, .size = size };
    }

    pub fn rootOffset(b: Beside) u64 {
        return b.start + b.xbootldr_size;
    }

    pub fn rootSize(b: Beside) u64 {
        return b.size - b.xbootldr_size;
    }
};

/// The smallest free space joe can be installed into: a boot partition and
/// a root a little larger than a whole disk must be.
pub const min_beside_size: u64 = 22 * 1000 * 1000 * 1000;

/// Input for `sfdisk --append` adding joe's two partitions to a disk's
/// existing table, inside the free space and nowhere else.
pub fn sfdiskAppendScript(arena: Allocator, b: Beside) ![]const u8 {
    std.debug.assert(b.start % mib == 0 and b.size % mib == 0 and b.size >= min_beside_size);
    return std.fmt.allocPrint(arena,
        \\start={d}KiB, size={d}KiB, type={s}, uuid={s}, name="joe-boot"
        \\start={d}KiB, size={d}KiB, type={s}, uuid={s}, name="{s}"
        \\
    , .{
        b.start / 1024,        b.xbootldr_size / 1024, xbootldr_type, b.xbootldr_uuid,
        b.rootOffset() / 1024, b.rootSize() / 1024,    root_type,     b.root_uuid,
        root_label,
    });
}

/// Input for sfdisk(8) creating the partition table. Sizes are in KiB rather
/// than sectors so that the same text is right for 512-byte and 4096-byte
/// sector disks.
pub fn sfdiskScript(arena: Allocator, plan: Plan) ![]const u8 {
    std.debug.assert(plan.esp_size % mib == 0);
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("label: gpt\n");
    try w.print("start={d}KiB, size={d}KiB, type={s}, uuid={s}, name=\"esp\"\n", .{
        plan.espOffset() / 1024, plan.esp_size / 1024, esp_type, plan.esp_uuid,
    });
    try w.print("start={d}KiB, ", .{plan.rootOffset() / 1024});
    if (plan.root_size) |size| {
        std.debug.assert(size % mib == 0);
        try w.print("size={d}KiB, ", .{size / 1024});
    }
    try w.print("type={s}, uuid={s}, name=\"{s}\"\n", .{ root_type, plan.root_uuid, root_label });
    return out.written();
}

/// The deployment's fstab. The root itself is deliberately absent: it comes
/// from the kernel command line.
pub fn fstab(arena: Allocator, plan: Plan) ![]const u8 {
    return fstabFor(arena, plan.root_uuid, plan.esp_uuid, null);
}

/// fstab beside another system: the shared ESP, and joe's boot partition.
pub fn fstabBeside(arena: Allocator, b: Beside) ![]const u8 {
    return fstabFor(arena, b.root_uuid, b.esp_uuid, b.xbootldr_uuid);
}

fn fstabFor(arena: Allocator, root: Uuid, esp: Uuid, xbootldr: ?Uuid) ![]const u8 {
    const base = try std.fmt.allocPrint(arena,
        \\PARTUUID={s}  /var   btrfs  subvol=var,noatime   0 0
        \\PARTUUID={s}  /home  btrfs  subvol=home,noatime  0 0
        \\PARTUUID={s}  /efi   vfat   umask=0077           0 2
        \\
    , .{ root, root, esp });
    const x = xbootldr orelse return base;
    return std.fmt.allocPrint(arena, "{s}PARTUUID={s}  /boot  vfat   umask=0077           0 2\n", .{ base, x });
}

/// The first deployment's kernel command line. Later deployments copy it with
/// only the subvolume changed (boot.optionsFor), so whatever is written here
/// stays for the life of the installation. `extra` is appended as given.
/// loglevel=4: errors and worse reach the console; the rest is in the journal.
pub fn cmdline(arena: Allocator, plan: Plan, extra: []const u8) ![]const u8 {
    return cmdlineFor(arena, plan.root_uuid, extra);
}

pub fn cmdlineFor(arena: Allocator, root_uuid: Uuid, extra: []const u8) ![]const u8 {
    const base = try std.fmt.allocPrint(arena, "root=PARTUUID={s} rootfstype=btrfs rootflags=subvol=" ++
        first_deployment_path ++ " rw rootwait panic=10 loglevel=4", .{root_uuid});
    const trimmed = std.mem.trim(u8, extra, " \t\n");
    if (trimmed.len == 0) return base;
    return std.fmt.allocPrint(arena, "{s} {s}", .{ base, trimmed });
}

/// The `console=` arguments of a command line, space-separated. An installer
/// copies these from the system it runs on, so an installation made through
/// a serial console keeps one, and one made at a screen does not get a serial
/// console nobody can see.
pub fn consoleArgs(arena: Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, line, " \t\n");
    while (it.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "console=")) continue;
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, arg);
    }
    return out.items;
}

pub const loader_conf = "timeout 0\neditor no\n";
/// Beside another system the menu shows, so that it can be chosen.
pub const beside_loader_conf = "timeout 5\neditor no\n";
pub const entries_srel = "type1\n";

pub const EspSource = struct {
    /// The root the first deployment is made from; the kernel and the boot
    /// loader are taken from it.
    root: Io.Dir,
    kernel_path: []const u8,
    loader_path: []const u8 = boot.loader_source,
};

/// Writes everything the EFI system partition holds for a new installation
/// into `esp`, a directory (the staging tree of an image, or the mounted ESP
/// of a disk being installed). boot.updateLoader only ever replaces a loader
/// that is already there, so the first copies are placed here.
pub fn writeEsp(arena: Allocator, io: Io, esp: Io.Dir, source: EspSource, options: []const u8) !void {
    try writeEntries(arena, io, esp, source, options);
    for (boot.loader_targets) |target| {
        try boot.copyFile(io, esp, target, source.root, source.loader_path);
    }
    try boot.writeFile(io, esp, "loader/loader.conf", loader_conf);
}

/// Writes a new installation's boot files beside another system: on the
/// shared `esp`, systemd-boot where the ESP has none (or an older one, which
/// boot.updateLoader replaces) and loader.conf where there is none; on
/// joe's own `xbootldr`, the kernel and the first entry. Nothing another
/// system put on the ESP is replaced: the firmware's fallback path, another
/// boot loader, another systemd-boot's settings.
pub fn writeBeside(arena: Allocator, io: Io, esp: Io.Dir, xbootldr: Io.Dir, source: EspSource, options: []const u8) !void {
    try writeEntries(arena, io, xbootldr, source, options);
    for (boot.loader_targets) |target| {
        if (esp.statFile(io, target, .{})) |_| continue else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        try boot.copyFile(io, esp, target, source.root, source.loader_path);
    }
    _ = try boot.updateLoader(arena, io, esp, source.root);
    if (esp.statFile(io, "loader/loader.conf", .{})) |_| {} else |err| switch (err) {
        error.FileNotFound => try boot.writeFile(io, esp, "loader/loader.conf", beside_loader_conf),
        else => return err,
    }
}

/// The kernel, microcode and first boot entry, on the partition systemd-boot
/// reads entries from.
fn writeEntries(arena: Allocator, io: Io, dir: Io.Dir, source: EspSource, options: []const u8) !void {
    try boot.writeFile(io, dir, "loader/entries.srel", entries_srel);
    const kernel = try boot.installKernel(arena, io, dir, source.root, source.kernel_path);
    // The processor's microcode, if the root has it, is the only initrd.
    var initrds: []const []const u8 = &.{};
    if (source.root.statFile(io, deploy.microcode_path, .{})) |_| {
        initrds = try arena.dupe([]const u8, &.{try boot.installInitrd(arena, io, dir, source.root, deploy.microcode_path)});
    } else |_| {}
    // Uncounted: the first deployment is good by definition, and a rollback
    // point needs a good entry to fall back to.
    try boot.write(arena, io, dir, .{
        .id = first_deployment,
        .priority = 1,
        .kernel = kernel,
        .initrds = initrds,
        .options = options,
        .counted = false,
    });
}

const testing = std.testing;

fn fixedPlan() Plan {
    return .{
        .esp_uuid = "11111111-2222-4333-8444-555555555555".*,
        .root_uuid = "66666666-7777-4888-9999-aaaaaaaaaaaa".*,
        .esp_size = default_esp_size,
        .root_size = 8 * 1024 * mib,
    };
}

test "uuids are random version 4" {
    const a = newUuid(testing.io);
    const b = newUuid(testing.io);
    try testing.expect(!std.mem.eql(u8, &a, &b));
    try testing.expectEqual(@as(u8, '4'), a[14]);
    try testing.expect(std.mem.indexOfScalar(u8, "89ab", a[19]) != null);
    try testing.expectEqual(@as(u8, '-'), a[8]);
    try testing.expectEqual(@as(u8, '-'), a[23]);
}

test "partition table, fstab and command line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const plan = fixedPlan();

    try testing.expectEqualStrings(try std.fmt.allocPrint(arena,
        \\label: gpt
        \\start=1024KiB, size=1048576KiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=11111111-2222-4333-8444-555555555555, name="esp"
        \\start=1049600KiB, size=8388608KiB, type={s}, uuid=66666666-7777-4888-9999-aaaaaaaaaaaa, name="joe"
        \\
    , .{root_type}), try sfdiskScript(arena, plan));
    try testing.expectEqual(@as(u64, (1 + 1024 + 8192 + 1) * mib), plan.imageSize());

    var whole_disk = plan;
    whole_disk.root_size = null;
    try testing.expect(std.mem.indexOf(u8, try sfdiskScript(arena, whole_disk), "start=1049600KiB, type=" ++ root_type) != null);

    const table = try fstab(arena, plan);
    try testing.expect(std.mem.indexOf(u8, table, "PARTUUID=66666666-7777-4888-9999-aaaaaaaaaaaa  /var   btrfs  subvol=var,noatime") != null);
    try testing.expect(std.mem.indexOf(u8, table, "PARTUUID=11111111-2222-4333-8444-555555555555  /efi   vfat") != null);
    try testing.expect(std.mem.indexOf(u8, table, " / ") == null);

    const serial = "console=" ++ arch.serial_console ++ ",115200";
    const line = try cmdline(arena, plan, " " ++ serial ++ " ");
    try testing.expectEqualStrings("root=PARTUUID=66666666-7777-4888-9999-aaaaaaaaaaaa rootfstype=btrfs " ++
        "rootflags=subvol=joe/deploy/1 rw rootwait panic=10 loglevel=4 " ++ serial, line);
    // What dave later reads back to find the running deployment, and how it
    // derives the next one's options.
    try testing.expectEqual(@as(?u32, first_deployment), boot.deploymentOf(line));
    try testing.expect(std.mem.indexOf(u8, try boot.optionsFor(arena, line, 2), "subvol=joe/deploy/2 rw") != null);
    try testing.expectEqualStrings(try cmdline(arena, plan, ""), (try cmdline(arena, plan, "  "))[0..]);
}

test "console arguments are copied and nothing else" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("", try consoleArgs(arena, "joe=log loglevel=4 quiet\n"));
    const serial = "console=" ++ arch.serial_console ++ ",115200";
    try testing.expectEqualStrings("console=tty0 " ++ serial, try consoleArgs(arena, "quiet console=tty0 x=1 " ++ serial ++ "\n"));
}

test "the ESP of a new installation" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/usr/lib/modules/7.3.1-joe");
    try tmp.dir.createDirPath(io, "root/usr/lib/systemd/boot/efi");
    try tmp.dir.createDirPath(io, "esp");
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    var esp = try tmp.dir.openDir(io, "esp", .{ .iterate = true });
    defer esp.close(io);
    try root.writeFile(io, .{ .sub_path = "usr/lib/modules/7.3.1-joe/vmlinuz", .data = "kernel" });
    try root.writeFile(io, .{ .sub_path = boot.loader_source, .data = "MZ #### LoaderInfo: systemd-boot 262.1 ####" });

    const options = try cmdline(arena, fixedPlan(), "");
    try writeEsp(arena, io, esp, .{ .root = root, .kernel_path = "usr/lib/modules/7.3.1-joe/vmlinuz" }, options);

    for (boot.loader_targets) |target| _ = try esp.statFile(io, target, .{});
    const read = struct {
        fn file(a: Allocator, dir: Io.Dir, path: []const u8) ![]const u8 {
            return dir.readFileAlloc(testing.io, path, a, .limited(1 << 20));
        }
    }.file;
    try testing.expectEqualStrings(loader_conf, try read(arena, esp, "loader/loader.conf"));
    try testing.expectEqualStrings(entries_srel, try read(arena, esp, "loader/entries.srel"));
    const entries = try boot.list(arena, io, esp);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(boot.Health.good, entries[0].health());
    try testing.expectEqualStrings("joe-1.conf", entries[0].file_name);
    try testing.expectEqualStrings(options, entries[0].options);
    try testing.expectEqualStrings("kernel", try read(arena, esp, entries[0].kernel[1..]));
}

test "beside another system: two partitions in the free space, the boot partition mounted" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const b: Beside = .{
        .esp_uuid = "11111111-2222-4333-8444-555555555555".*,
        .xbootldr_uuid = "77777777-8888-4999-aaaa-bbbbbbbbbbbb".*,
        .root_uuid = "66666666-7777-4888-9999-aaaaaaaaaaaa".*,
        .start = 101 * 1024 * mib,
        .size = 30 * 1024 * mib,
    };
    try testing.expectEqualStrings(try std.fmt.allocPrint(arena,
        \\start=105906176KiB, size=1048576KiB, type=BC13C2FF-59E6-4262-A352-B275FD6F7172, uuid=77777777-8888-4999-aaaa-bbbbbbbbbbbb, name="joe-boot"
        \\start=106954752KiB, size=30408704KiB, type={s}, uuid=66666666-7777-4888-9999-aaaaaaaaaaaa, name="joe"
        \\
    , .{root_type}), try sfdiskAppendScript(arena, b));
    const table = try fstabBeside(arena, b);
    try testing.expect(std.mem.indexOf(u8, table, "PARTUUID=11111111-2222-4333-8444-555555555555  /efi   vfat") != null);
    try testing.expect(std.mem.indexOf(u8, table, "PARTUUID=77777777-8888-4999-aaaa-bbbbbbbbbbbb  /boot  vfat   umask=0077") != null);
    try testing.expect(std.mem.indexOf(u8, try fstab(arena, fixedPlan()), "/boot") == null);
}

test "beside another system, nothing of the other's is replaced" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    for ([_][]const u8{ "root/usr/lib/modules/7.3.1-joe", "root/usr/lib/systemd/boot/efi", "esp/EFI/BOOT", "esp/EFI/Microsoft/Boot", "xbootldr" }) |d|
        try tmp.dir.createDirPath(io, d);
    var root = try tmp.dir.openDir(io, "root", .{ .iterate = true });
    defer root.close(io);
    var esp = try tmp.dir.openDir(io, "esp", .{ .iterate = true });
    defer esp.close(io);
    var xbootldr = try tmp.dir.openDir(io, "xbootldr", .{ .iterate = true });
    defer xbootldr.close(io);
    try root.writeFile(io, .{ .sub_path = "usr/lib/modules/7.3.1-joe/vmlinuz", .data = "kernel" });
    try root.writeFile(io, .{ .sub_path = boot.loader_source, .data = "MZ #### LoaderInfo: systemd-boot 262.1 ####" });
    // Windows' boot manager, and its copy at the firmware's fallback path.
    try esp.writeFile(io, .{ .sub_path = "EFI/Microsoft/Boot/bootmgfw.efi", .data = "MZ windows" });
    try esp.writeFile(io, .{ .sub_path = boot.fallback_loader, .data = "MZ windows" });

    const options = try cmdline(arena, fixedPlan(), "");
    try writeBeside(arena, io, esp, xbootldr, .{ .root = root, .kernel_path = "usr/lib/modules/7.3.1-joe/vmlinuz" }, options);
    const read = struct {
        fn file(a: Allocator, dir: Io.Dir, path: []const u8) ![]const u8 {
            return dir.readFileAlloc(testing.io, path, a, .limited(1 << 20));
        }
    }.file;
    try testing.expectEqualStrings("MZ windows", try read(arena, esp, boot.fallback_loader));
    try testing.expectEqualStrings("MZ windows", try read(arena, esp, "EFI/Microsoft/Boot/bootmgfw.efi"));
    try testing.expect(std.mem.indexOf(u8, try read(arena, esp, boot.loader_targets[0]), "systemd-boot 262.1") != null);
    try testing.expectEqualStrings(beside_loader_conf, try read(arena, esp, "loader/loader.conf"));
    // Entries and kernels are on joe's own partition, not the shared one.
    try testing.expectEqual(@as(usize, 0), (try boot.list(arena, io, esp)).len);
    const entries = try boot.list(arena, io, xbootldr);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("kernel", try read(arena, xbootldr, entries[0].kernel[1..]));

    // Another system's systemd-boot settings stay as they are.
    try esp.writeFile(io, .{ .sub_path = "loader/loader.conf", .data = "timeout 3\n" });
    try writeBeside(arena, io, esp, xbootldr, .{ .root = root, .kernel_path = "usr/lib/modules/7.3.1-joe/vmlinuz" }, options);
    try testing.expectEqualStrings("timeout 3\n", try read(arena, esp, "loader/loader.conf"));
}
