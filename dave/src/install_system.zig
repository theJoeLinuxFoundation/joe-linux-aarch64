//! Installing joe Linux onto a disk: `dave install-system`, the back end of
//! the graphical installer (installer/), run as root on the live medium.
//!
//! An installation is the same thing as a disk image (provision.zig) made on
//! a real disk instead of from files: the disk gets a new GPT with an EFI
//! system partition and a btrfs root, the first deployment is one dave
//! transaction, and the ESP is written as for an image. Or, with --beside,
//! joe goes into the free space of a disk another system uses, sharing its
//! ESP (provision.Beside): nothing that is there is resized, moved or written
//! over, so the space must be made first, by the other system (Windows' Disk
//! Management shrinks its volume). What an image cannot do and an
//! installation can, because it runs as root on the machine it installs: the
//! files are sealed as they are installed (so the first boot has nothing to
//! seal), and the firmware is told where the boot loader is.
//!
//! The medium (iso.zig) says what to install, in joe/install.zon, and the
//! packages come from the medium's own root image, where they are already
//! installed: the transaction copies each one out of it (txn.Copy) by the
//! manifest that root's database keeps, checking every file against it as it
//! would a file from a package. So the medium carries each package once, as
//! the live system, and not a second time as package files. The few files the
//! live root holds changed (its /etc/passwd, its host name) are on the medium
//! as they were packaged, in joe/originals/, named by their SHA-256; the image
//! build finds them (changedFiles) and refuses a root it could not install
//! from. The installed system is configured with the repositories the live
//! system itself uses (its own /etc/dave/repos.zon and keys), so it takes
//! upgrades from where the live system would have.
//!
//! This file holds what an installation needs that is not dave's ordinary
//! work: finding the disks it may use, partitioning, formatting and mounting.
//! main.zig runs the steps in order, with the transaction and sealing in
//! between, and reports progress.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const provision = @import("provision.zig");
const command = @import("command.zig");
const btrfs = @import("btrfs.zig");
const deploy = @import("deploy.zig");
const manifest = @import("manifest.zig");
const repo = @import("repo.zig");
const archive = @import("archive.zig");

pub const medium_mount = "/run/live/medium";
pub const medium_dir = medium_mount ++ "/joe";
pub const install_file = "install.zon";
/// On the medium, beside install.zon: the originals of the files the live
/// root holds changed, each named by its SHA-256.
pub const originals_dir = "originals";
/// The medium's root image, mounted read-only by its initramfs
/// (image/initrd/etc/systemd/system/run-live-lower.mount): the live root as
/// it was built, without the session's changes.
pub const live_root = "/run/live/lower";
pub const min_disk_size: u64 = 20 * 1000 * 1000 * 1000;
pub const top_mount = "/run/dave/install/top";
pub const target_mount = "/run/dave/install/target";

/// joe/install.zon on the medium.
pub const Medium = struct {
    /// What the installer installs: the image spec's `.iso.payload`.
    packages: []const []const u8,
};

pub fn parseMedium(arena: Allocator, text: []const u8) !Medium {
    return manifest.parseZon(Medium, arena, text) catch error.InvalidMedium;
}

/// A file system found on a disk, so that a person choosing a disk can
/// recognise what they would lose.
pub const Content = struct {
    name: []const u8,
    fstype: []const u8,
    label: []const u8,
    size: u64,
};

/// A partition of a disk, where it lies and what it seems to be.
pub const Partition = struct {
    name: []const u8,
    /// Bytes from the start of the disk.
    start: u64,
    size: u64,
    fstype: []const u8,
    label: []const u8,
    /// "esp", "windows", "linux" or "other", from its GPT type and file
    /// system, for drawing it and naming the systems a disk holds.
    kind: []const u8,
    partuuid: []const u8,
};

/// A stretch of the disk no partition uses.
pub const Region = struct {
    start: u64,
    size: u64,
};

/// Whether joe could be installed in a disk's free space, beside what is
/// there.
pub const Beside = struct {
    possible: bool = false,
    /// Why not, for the person choosing.
    reason: []const u8 = "",
    /// The free space joe would take: the largest on the disk.
    start: u64 = 0,
    size: u64 = 0,
    /// The disk's EFI system partition, which joe would share.
    esp: []const u8 = "",
    /// The systems already on the disk, as a person would name them
    /// ("Windows", "Linux").
    systems: []const []const u8 = &.{},
};

pub const Disk = struct {
    /// What to pass as --disk: a /dev/disk/by-id path where the disk has
    /// one, which names this disk and no other however devices are numbered.
    path: []const u8,
    device: []const u8,
    size: u64,
    model: []const u8,
    transport: []const u8,
    removable: bool,
    /// Whether the whole disk may be erased and installed on.
    usable: bool,
    /// Why it is not usable, for the person choosing.
    reason: []const u8 = "",
    contents: []const Content = &.{},
    /// "gpt", "dos" (MBR) or "" when the disk has no partition table.
    table: []const u8 = "",
    partitions: []const Partition = &.{},
    free: []const Region = &.{},
    beside: Beside = .{},
};

/// A /dev/disk/by-id link and the device name it points at ("vda").
pub const Link = struct {
    device: []const u8,
    path: []const u8,
};

/// Every /dev/disk/by-id link to a whole disk.
pub fn readById(arena: Allocator, io: Io) ![]Link {
    var out: std.ArrayList(Link) = .empty;
    var dir = Io.Dir.cwd().openDir(io, "/dev/disk/by-id", .{ .iterate = true }) catch return out.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.indexOf(u8, e.name, "-part") != null) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = dir.readLink(io, e.name, &buf) catch continue;
        try out.append(arena, .{
            .device = try arena.dupe(u8, std.fs.path.basename(buf[0..n])),
            .path = try std.fmt.allocPrint(arena, "/dev/disk/by-id/{s}", .{e.name}),
        });
    }
    return out.items;
}

/// The most telling stable name of a disk: one built from its model and
/// serial number rather than a WWN or EUI, which say nothing to a person.
fn stablePath(links: []const Link, device: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (links) |l| {
        if (!std.mem.eql(u8, l.device, device)) continue;
        const name = std.fs.path.basename(l.path);
        const opaque_name = std.mem.startsWith(u8, name, "wwn-") or std.mem.startsWith(u8, name, "nvme-eui.") or
            std.mem.startsWith(u8, name, "nvme-nvme.");
        if (best == null or (!opaque_name and std.mem.order(u8, l.path, best.?) == .lt) or
            (!opaque_name and isOpaque(best.?))) best = l.path;
    }
    return best;
}

fn isOpaque(path: []const u8) bool {
    const name = std.fs.path.basename(path);
    return std.mem.startsWith(u8, name, "wwn-") or std.mem.startsWith(u8, name, "nvme-eui.") or
        std.mem.startsWith(u8, name, "nvme-nvme.");
}

fn field(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (obj.get(key) orelse return "") {
        .string => |s| s,
        else => "",
    };
}

/// lsblk prints booleans as true/false or, in older versions, "0"/"1".
fn flag(obj: std.json.ObjectMap, key: []const u8) bool {
    return switch (obj.get(key) orelse return false) {
        .bool => |b| b,
        .string => |s| std.mem.eql(u8, s, "1"),
        .integer => |i| i != 0,
        else => false,
    };
}

fn number(obj: std.json.ObjectMap, key: []const u8) u64 {
    return switch (obj.get(key) orelse return 0) {
        .integer => |i| @intCast(@max(i, 0)),
        .string => |s| std.fmt.parseInt(u64, s, 10) catch 0,
        else => 0,
    };
}

fn mountPoints(obj: std.json.ObjectMap) []const std.json.Value {
    const v = obj.get("mountpoints") orelse return &.{};
    return switch (v) {
        .array => |a| a.items,
        else => &.{},
    };
}

/// The output lsblk(8) is asked for.
/// START is in 512-byte units whatever the disk's sector size, as the
/// kernel reports it.
pub const lsblk_argv = [_][]const u8{ "lsblk", "--json", "--bytes", "--output", "NAME,PATH,SIZE,TYPE,MODEL,TRAN,RM,RO,FSTYPE,LABEL,MOUNTPOINTS,PTTYPE,PARTTYPE,PARTUUID,START" };

/// The disks of `lsblk_json`, each with whether it may be installed on.
/// `medium` is the device the live medium is mounted from (a disk or one of
/// its partitions); that disk is never offered.
pub fn parseDisks(arena: Allocator, lsblk_json: []const u8, links: []const Link, medium: ?[]const u8) ![]Disk {
    const doc = std.json.parseFromSliceLeaky(std.json.Value, arena, lsblk_json, .{}) catch return error.InvalidLsblk;
    const devices = switch (doc) {
        .object => |o| switch (o.get("blockdevices") orelse return error.InvalidLsblk) {
            .array => |a| a.items,
            else => return error.InvalidLsblk,
        },
        else => return error.InvalidLsblk,
    };
    var out: std.ArrayList(Disk) = .empty;
    for (devices) |v| {
        const obj = switch (v) {
            .object => |o| o,
            else => continue,
        };
        if (!std.mem.eql(u8, field(obj, "type"), "disk")) continue;
        const name = field(obj, "name");
        if (std.mem.startsWith(u8, name, "zram")) continue;
        const device = field(obj, "path");

        var contents: std.ArrayList(Content) = .empty;
        var partitions: std.ArrayList(Partition) = .empty;
        var holds_medium = medium != null and std.mem.eql(u8, medium.?, device);
        var in_use: ?[]const u8 = null;
        if (fsOf(obj)) |c| try contents.append(arena, c);
        in_use = mountedAt(obj);
        if (obj.get("children")) |children| if (children == .array) for (children.array.items) |cv| {
            const child = switch (cv) {
                .object => |o| o,
                else => continue,
            };
            if (medium != null and std.mem.eql(u8, medium.?, field(child, "path"))) holds_medium = true;
            if (fsOf(child)) |c| try contents.append(arena, c);
            if (in_use == null) in_use = mountedAt(child);
            if (std.mem.eql(u8, field(child, "type"), "part")) try partitions.append(arena, .{
                .name = field(child, "name"),
                .start = number(child, "start") * 512,
                .size = number(child, "size"),
                .fstype = field(child, "fstype"),
                .label = field(child, "label"),
                .kind = kindOf(field(child, "parttype"), field(child, "fstype")),
                .partuuid = field(child, "partuuid"),
            });
        };
        std.mem.sort(Partition, partitions.items, {}, struct {
            fn lessThan(_: void, a: Partition, b: Partition) bool {
                return a.start < b.start;
            }
        }.lessThan);

        const size = number(obj, "size");
        var disk: Disk = .{
            .path = stablePath(links, name) orelse device,
            .device = device,
            .size = size,
            .model = std.mem.trim(u8, field(obj, "model"), " "),
            .transport = field(obj, "tran"),
            .removable = flag(obj, "rm"),
            .usable = true,
            .contents = contents.items,
            .table = field(obj, "pttype"),
            .partitions = partitions.items,
            .free = try freeRegions(arena, size, partitions.items),
        };
        if (holds_medium) {
            disk.usable = false;
            disk.reason = "it holds the medium this system is running from";
        } else if (flag(obj, "ro")) {
            disk.usable = false;
            disk.reason = "it is read-only";
        } else if (size < min_disk_size) {
            disk.usable = false;
            disk.reason = "it is smaller than 20 GB";
        } else if (in_use) |point| {
            disk.usable = false;
            disk.reason = try std.fmt.allocPrint(arena, "part of it is in use ({s})", .{point});
        }
        disk.beside = try besideOf(arena, disk);
        try out.append(arena, disk);
    }
    return out.items;
}

/// What a partition seems to be, from its GPT type (lsblk prints it in lower
/// case) and its file system.
fn kindOf(parttype: []const u8, fstype: []const u8) []const u8 {
    const is = struct {
        fn any(t: []const u8, list: []const []const u8) bool {
            for (list) |x| if (std.ascii.eqlIgnoreCase(t, x)) return true;
            return false;
        }
    }.any;
    if (is(parttype, &.{"c12a7328-f81f-11d2-ba4b-00a0c93ec93b"})) return "esp";
    // Microsoft reserved and recovery; basic data holding NTFS or BitLocker.
    if (is(parttype, &.{ "e3c9e316-0b5c-4db8-817d-f92df00215ae", "de94bba4-06d1-4d40-a16a-bfd50179d6ac" }) or
        is(fstype, &.{ "ntfs", "BitLocker" })) return "windows";
    // Linux file system data, root, home, swap and XBOOTLDR; the usual file
    // systems of a Linux whatever its partition types.
    if (is(parttype, &.{
        "0fc63daf-8483-4772-8e79-3d69d8477de4", provision.root_type,
        "933ac7e1-2eb4-4f13-b844-0e14e2aef915", "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f",
        "bc13c2ff-59e6-4262-a352-b275fd6f7172",
    }) or is(fstype, &.{ "ext2", "ext3", "ext4", "btrfs", "xfs", "f2fs", "swap" })) return "linux";
    return "other";
}

/// The stretches of a disk no partition uses, of at least 1 MiB, aligned to
/// 1 MiB as partitions are: from after the primary GPT to before the backup.
pub fn freeRegions(arena: Allocator, disk_size: u64, partitions: []const Partition) ![]const Region {
    var out: std.ArrayList(Region) = .empty;
    const mib = provision.mib;
    var cursor: u64 = provision.first_offset;
    const end = (disk_size -| provision.tail) / mib * mib;
    for (partitions) |p| {
        if (p.start > cursor) try add(arena, &out, cursor, @min(p.start, end));
        cursor = @max(cursor, p.start + p.size);
    }
    if (end > cursor) try add(arena, &out, cursor, end);
    return out.items;
}

fn add(arena: Allocator, out: *std.ArrayList(Region), from: u64, to: u64) !void {
    const mib = provision.mib;
    const start = (from + mib - 1) / mib * mib;
    const stop = to / mib * mib;
    if (stop > start) try out.append(arena, .{ .start = start, .size = stop - start });
}

/// Whether joe could go in the free space of `disk`, beside what is there.
fn besideOf(arena: Allocator, disk: Disk) !Beside {
    var b: Beside = .{};
    var systems: std.ArrayList([]const u8) = .empty;
    for (disk.partitions) |p| {
        const name: ?[]const u8 = if (std.mem.eql(u8, p.kind, "windows")) "Windows" else if (std.mem.eql(u8, p.kind, "linux")) "Linux" else null;
        const n = name orelse continue;
        for (systems.items) |have| {
            if (std.mem.eql(u8, have, n)) break;
        } else try systems.append(arena, n);
    }
    b.systems = systems.items;
    for (disk.free) |r| {
        if (r.size > b.size) {
            b.start = r.start;
            b.size = r.size;
        }
    }
    for (disk.partitions) |p| {
        if (std.mem.eql(u8, p.kind, "esp") and p.partuuid.len == 36) {
            b.esp = p.partuuid;
            break;
        }
    }
    // A disk that cannot be erased because of what it holds or how it is
    // used cannot be shared either; being too small is another matter.
    if (!disk.usable and !std.mem.startsWith(u8, disk.reason, "it is smaller")) {
        b.reason = disk.reason;
    } else if (disk.table.len == 0) {
        b.reason = "it has no partitions to keep";
    } else if (!std.mem.eql(u8, disk.table, "gpt")) {
        b.reason = "its partition table is the old MBR kind, which joe cannot share";
    } else if (b.esp.len == 0) {
        b.reason = "it has no EFI system partition to share";
    } else if (b.size < provision.min_beside_size) {
        b.reason = "it has no free space of 22 GB or more";
    } else {
        b.possible = true;
    }
    return b;
}

fn fsOf(obj: std.json.ObjectMap) ?Content {
    const fstype = field(obj, "fstype");
    if (fstype.len == 0) return null;
    return .{ .name = field(obj, "name"), .fstype = fstype, .label = field(obj, "label"), .size = number(obj, "size") };
}

/// Where a device is mounted, if anywhere; lsblk lists null for a device
/// that is not.
fn mountedAt(obj: std.json.ObjectMap) ?[]const u8 {
    for (mountPoints(obj)) |p| switch (p) {
        .string => |s| return if (std.mem.eql(u8, s, "[SWAP]")) "swap" else s,
        else => {},
    };
    return null;
}

/// The device a mount point is mounted from, from /proc/self/mountinfo.
pub fn mountSource(mountinfo: []const u8, mount_point: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, mountinfo, '\n');
    while (lines.next()) |line| {
        const sep = std.mem.indexOf(u8, line, " - ") orelse continue;
        var head = std.mem.tokenizeScalar(u8, line[0..sep], ' ');
        var n: usize = 0;
        var point: []const u8 = "";
        while (head.next()) |f| : (n += 1) {
            if (n == 4) point = f;
        }
        if (!std.mem.eql(u8, point, mount_point)) continue;
        var tail = std.mem.tokenizeScalar(u8, line[sep + 3 ..], ' ');
        _ = tail.next() orelse continue;
        found = tail.next() orelse continue;
    }
    return found;
}

/// The steps of an installation that touch the disk. Each failure leaves a
/// sentence in `diag`.
pub const Disks = struct {
    arena: Allocator,
    io: Io,
    diag: command.Diagnostic = .{},

    fn fail(d: *Disks, comptime fmt: []const u8, args: anytype) error{InstallFailed} {
        d.diag.message = std.fmt.allocPrint(d.arena, fmt, args) catch "out of memory";
        return error.InstallFailed;
    }

    fn run(d: *Disks, argv: []const []const u8, input: ?[]const u8) !void {
        _ = command.run(d.arena, d.io, argv, .{ .input = input }, &d.diag) catch return error.InstallFailed;
    }

    /// Erases `device` and writes the plan's partition table. Returns the
    /// paths of the new ESP and root partitions, by their GPT UUIDs, which
    /// is how udev names them however the disk's partitions are numbered.
    pub fn partition(d: *Disks, device: []const u8, plan: provision.Plan) !struct { esp: []const u8, root: []const u8 } {
        // Old signatures would otherwise be found again by blkid and udev
        // (an old file system's label, an old RAID member) and confuse what
        // comes next, in this system or the installed one.
        try d.run(&.{ "wipefs", "--all", "--force", device }, null);
        try d.run(&.{ "sfdisk", "--quiet", "--wipe", "always", device }, try provision.sfdiskScript(d.arena, plan));
        const esp = try std.fmt.allocPrint(d.arena, "/dev/disk/by-partuuid/{s}", .{plan.esp_uuid});
        const root = try std.fmt.allocPrint(d.arena, "/dev/disk/by-partuuid/{s}", .{plan.root_uuid});
        try d.waitFor(device, &.{ esp, root });
        return .{ .esp = esp, .root = root };
    }

    /// Adds joe's partitions to the free space `b` describes, leaving every
    /// other partition and the table's own signature as they are, and
    /// returns their paths. Signatures left in the free space by a partition
    /// deleted earlier are wiped from the new ones.
    pub fn addBeside(d: *Disks, device: []const u8, b: provision.Beside) !struct { xbootldr: []const u8, root: []const u8 } {
        try d.run(&.{ "sfdisk", "--quiet", "--append", "--wipe", "never", "--wipe-partitions", "always", device }, try provision.sfdiskAppendScript(d.arena, b));
        const xbootldr = try std.fmt.allocPrint(d.arena, "/dev/disk/by-partuuid/{s}", .{b.xbootldr_uuid});
        const root = try std.fmt.allocPrint(d.arena, "/dev/disk/by-partuuid/{s}", .{b.root_uuid});
        try d.waitFor(device, &.{ xbootldr, root });
        return .{ .xbootldr = xbootldr, .root = root };
    }

    /// Waits for udev to have made the links to new partitions.
    fn waitFor(d: *Disks, device: []const u8, paths: []const []const u8) !void {
        var tries: usize = 0;
        while (tries < 30) : (tries += 1) {
            d.run(&.{ "udevadm", "settle", "--timeout=10" }, null) catch {};
            for (paths) |p| {
                if (Io.Dir.cwd().statFile(d.io, p, .{})) |_| {} else |_| break;
            } else return;
            try d.io.sleep(.fromMilliseconds(500), .awake);
        }
        return d.fail("the new partitions of {s} did not appear", .{device});
    }

    pub fn formatBeside(d: *Disks, xbootldr: []const u8, root: []const u8) !void {
        try d.run(&.{ "mkfs.vfat", "-F", "32", "-n", provision.xbootldr_label, xbootldr }, null);
        try d.run(&.{ "mkfs.btrfs", "--quiet", "--force", "--label", provision.root_label, root }, null);
    }

    /// Mounts the boot partition where the installed system will mount it.
    pub fn mountBoot(d: *Disks, xbootldr: []const u8) !void {
        try d.mountAt(xbootldr, target_mount ++ "/" ++ provision.xbootldr_mount, "vfat", 0, "umask=0077");
    }

    pub fn format(d: *Disks, esp: []const u8, root: []const u8) !void {
        try d.run(&.{ "mkfs.vfat", "-F", "32", "-n", provision.esp_label, esp }, null);
        try d.run(&.{ "mkfs.btrfs", "--quiet", "--force", "--label", provision.root_label, root }, null);
    }

    /// `options` are the file system's own; flags such as noatime are
    /// `flags` (mount(8) separates the two; the system call does not).
    fn mountAt(d: *Disks, source: []const u8, point: []const u8, fstype: []const u8, flags: u32, options: []const u8) !void {
        Io.Dir.cwd().createDirPath(d.io, point) catch |err| return d.fail("cannot create {s}: {t}", .{ point, err });
        const rc = linux.mount(
            try d.arena.dupeSentinel(u8, source, 0),
            try d.arena.dupeSentinel(u8, point, 0),
            try d.arena.dupeSentinel(u8, fstype, 0),
            flags,
            @intFromPtr((try d.arena.dupeSentinel(u8, options, 0)).ptr),
        );
        if (linux.errno(rc) != .SUCCESS) return d.fail("cannot mount {s} at {s}: {t}", .{ source, point, linux.errno(rc) });
    }

    /// Lays out the btrfs file system as provision.zig describes and mounts
    /// the first deployment at `target_mount`, with /var, /home and /efi
    /// mounted in it where they will be mounted when it runs.
    pub fn mountTarget(d: *Disks, esp: []const u8, root: []const u8) !void {
        try d.mountAt(root, top_mount, "btrfs", 0, "subvolid=5");
        {
            var top = Io.Dir.cwd().openDir(d.io, top_mount, .{ .iterate = true }) catch |err|
                return d.fail("cannot open {s}: {t}", .{ top_mount, err });
            defer top.close(d.io);
            try top.createDirPath(d.io, deploy.deploy_dir);
            var parent = try top.openDir(d.io, deploy.deploy_dir, .{ .iterate = true });
            defer parent.close(d.io);
            btrfs.createSubvolume(parent, std.fs.path.basename(provision.first_deployment_path)) catch |err|
                return d.fail("cannot create the subvolume {s}: {t}", .{ provision.first_deployment_path, err });
            for (provision.shared_subvolumes) |name| {
                btrfs.createSubvolume(top, name) catch |err| return d.fail("cannot create the subvolume {s}: {t}", .{ name, err });
            }
        }
        try d.mountAt(root, target_mount, "btrfs", 0, "subvol=" ++ provision.first_deployment_path);
        for (provision.shared_subvolumes) |name| {
            const point = try std.fs.path.join(d.arena, &.{ target_mount, name });
            try d.mountAt(root, point, "btrfs", linux.MS.NOATIME, try std.fmt.allocPrint(d.arena, "subvol={s}", .{name}));
        }
        try d.mountAt(esp, target_mount ++ "/" ++ provision.esp_mount, "vfat", 0, "umask=0077");
    }

    /// Unmounts whatever of the target is mounted, innermost first.
    pub fn unmountTarget(d: *Disks) void {
        const points = [_][]const u8{
            target_mount ++ "/" ++ provision.xbootldr_mount,
            target_mount ++ "/" ++ provision.esp_mount,
            target_mount ++ "/home",
            target_mount ++ "/var",
            target_mount,
            top_mount,
        };
        for (points) |point| _ = linux.umount2(@ptrCast(d.arena.dupeSentinel(u8, point, 0) catch continue), 0);
    }
};

/// The packages installed in a root, offered as a repository would offer
/// them: what an installation from the medium is solved against.
pub fn candidatesOf(arena: Allocator, installed: []const manifest.Manifest) ![]repo.Candidate {
    const out = try arena.alloc(repo.Candidate, installed.len);
    for (installed, out) |m, *c| c.* = .{
        .entry = .{
            .name = m.name,
            .version = m.version,
            .arch = m.arch,
            .description = m.description,
            .depends = m.depends,
            .conflicts = m.conflicts,
            .filename = try m.fileName(arena),
            .size = 0,
            .sha256 = "",
            .license = m.license,
            .installed_size = m.installedSize(),
        },
        .repo_url = live_root,
        .repo_name = "medium",
    };
    return out;
}

/// A regular file of a package that a root holds other than as packaged.
pub const Changed = struct {
    package: manifest.Manifest,
    file: manifest.File,
};

/// The regular files of `packages` that `root` holds changed or not at all:
/// what an installation copying them out of `root` needs from elsewhere.
pub fn changedFiles(arena: Allocator, io: Io, root: Io.Dir, packages: []const manifest.Manifest) ![]Changed {
    var out: std.ArrayList(Changed) = .empty;
    for (packages) |m| {
        for (m.files) |f| {
            if (f.kind != .file) continue;
            const want = f.sha256 orelse return error.InvalidPackage;
            const same = if (archive.hashFile(io, root, f.path)) |have|
                std.mem.eql(u8, &have, want)
            else |err| switch (err) {
                error.FileNotFound, error.NotDir, error.IsDir => false,
                else => return err,
            };
            if (!same) try out.append(arena, .{ .package = m, .file = f });
        }
    }
    return out.items;
}

const testing = std.testing;
const arch = @import("arch.zig");

const sample_lsblk =
    \\{"blockdevices": [
    \\  {"name":"sr0","path":"/dev/sr0","size":2147483648,"type":"rom","model":"QEMU DVD-ROM","tran":"sata","rm":true,"ro":false,"fstype":"iso9660","label":"JOE_LIVE","mountpoints":["/run/live/medium"]},
    \\  {"name":"vda","path":"/dev/vda","size":42949672960,"type":"disk","model":null,"tran":null,"rm":false,"ro":false,"fstype":null,"label":null,"mountpoints":[null],
    \\   "children":[{"name":"vda1","path":"/dev/vda1","size":1073741824,"type":"part","model":null,"tran":null,"rm":false,"ro":false,"fstype":"ntfs","label":"Windows","mountpoints":[null]}]},
    \\  {"name":"sda","path":"/dev/sda","size":16008609792,"type":"disk","model":"Flash Disk  ","tran":"usb","rm":"1","ro":"0","fstype":"iso9660","label":"JOE_LIVE","mountpoints":[],
    \\   "children":[{"name":"sda1","path":"/dev/sda1","size":2147483648,"type":"part","fstype":"iso9660","label":"JOE_LIVE","mountpoints":["/run/live/medium"]}]},
    \\  {"name":"nvme0n1","path":"/dev/nvme0n1","size":512110190592,"type":"disk","model":"Some SSD","tran":"nvme","rm":false,"ro":false,"fstype":null,"label":null,"mountpoints":[],
    \\   "children":[{"name":"nvme0n1p2","path":"/dev/nvme0n1p2","size":511000000000,"type":"part","fstype":"swap","label":null,"mountpoints":["[SWAP]"]}]},
    \\  {"name":"vdb","path":"/dev/vdb","size":8589934592,"type":"disk","model":null,"tran":null,"rm":false,"ro":false,"fstype":null,"label":null,"mountpoints":[]},
    \\  {"name":"zram0","path":"/dev/zram0","size":8589934592,"type":"disk","rm":false,"ro":false,"fstype":"swap","mountpoints":["[SWAP]"]}
    \\]}
;

test "disks are offered with what is on them, and refused with a reason" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const links = [_]Link{
        .{ .device = "nvme0n1", .path = "/dev/disk/by-id/nvme-eui.0025385b71b0" },
        .{ .device = "nvme0n1", .path = "/dev/disk/by-id/nvme-Some_SSD_S4EVNF0M" },
        .{ .device = "sda", .path = "/dev/disk/by-id/usb-Flash_Disk-0:0" },
    };
    const disks = try parseDisks(arena, sample_lsblk, &links, "/dev/sda1");
    try testing.expectEqual(@as(usize, 4), disks.len);

    // A virtual disk with no serial number has no by-id name.
    try testing.expectEqualStrings("/dev/vda", disks[0].path);
    try testing.expect(disks[0].usable);
    try testing.expectEqual(@as(usize, 1), disks[0].contents.len);
    try testing.expectEqualStrings("Windows", disks[0].contents[0].label);

    try testing.expectEqualStrings("/dev/disk/by-id/usb-Flash_Disk-0:0", disks[1].path);
    try testing.expect(!disks[1].usable);
    try testing.expect(disks[1].removable);
    try testing.expectEqualStrings("Flash Disk", disks[1].model);
    try testing.expect(std.mem.indexOf(u8, disks[1].reason, "medium") != null);

    try testing.expectEqualStrings("/dev/disk/by-id/nvme-Some_SSD_S4EVNF0M", disks[2].path);
    try testing.expect(!disks[2].usable);
    try testing.expectEqualStrings("part of it is in use (swap)", disks[2].reason);

    try testing.expect(!disks[3].usable);
    try testing.expectEqualStrings("it is smaller than 20 GB", disks[3].reason);
}

// A laptop's disk: Windows with its ESP, reserved and recovery partitions,
// shrunk to leave 60 GiB free before its recovery partition; and an MBR disk.
const windows_lsblk =
    \\{"blockdevices": [
    \\  {"name":"nvme0n1","path":"/dev/nvme0n1","size":256060514304,"type":"disk","model":"Laptop SSD","tran":"nvme","rm":false,"ro":false,"fstype":null,"label":null,"mountpoints":[null],"pttype":"gpt","parttype":null,"partuuid":null,"start":null,
    \\   "children":[
    \\     {"name":"nvme0n1p1","path":"/dev/nvme0n1p1","size":104857600,"type":"part","fstype":"vfat","label":"SYSTEM","mountpoints":[null],"pttype":"gpt","parttype":"c12a7328-f81f-11d2-ba4b-00a0c93ec93b","partuuid":"0a1b2c3d-0000-4000-8000-000000000001","start":2048},
    \\     {"name":"nvme0n1p2","path":"/dev/nvme0n1p2","size":16777216,"type":"part","fstype":null,"label":null,"mountpoints":[null],"pttype":"gpt","parttype":"e3c9e316-0b5c-4db8-817d-f92df00215ae","partuuid":"0a1b2c3d-0000-4000-8000-000000000002","start":206848},
    \\     {"name":"nvme0n1p3","path":"/dev/nvme0n1p3","size":189458432000,"type":"part","fstype":"BitLocker","label":null,"mountpoints":[null],"pttype":"gpt","parttype":"ebd0a0a2-b9e5-4433-87c0-68b6b72699c7","partuuid":"0a1b2c3d-0000-4000-8000-000000000003","start":239616},
    \\     {"name":"nvme0n1p4","path":"/dev/nvme0n1p4","size":786432000,"type":"part","fstype":"ntfs","label":"Recovery","mountpoints":[null],"pttype":"gpt","parttype":"de94bba4-06d1-4d40-a16a-bfd50179d6ac","partuuid":"0a1b2c3d-0000-4000-8000-000000000004","start":496523264}
    \\   ]},
    \\  {"name":"sda","path":"/dev/sda","size":500107862016,"type":"disk","model":"Old Disk","tran":"sata","rm":false,"ro":false,"fstype":null,"label":null,"mountpoints":[null],"pttype":"dos","parttype":null,"partuuid":null,"start":null,
    \\   "children":[{"name":"sda1","path":"/dev/sda1","size":104857600000,"type":"part","fstype":"ntfs","label":"Data","mountpoints":[null],"pttype":"dos","parttype":"0x7","partuuid":"1234abcd-01","start":2048}]}
    \\]}
;

test "free space beside Windows is found, and its reasons when there is none" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const disks = try parseDisks(arena, windows_lsblk, &.{}, null);
    try testing.expectEqual(@as(usize, 2), disks.len);

    const laptop = disks[0];
    try testing.expectEqualStrings("gpt", laptop.table);
    try testing.expectEqual(@as(usize, 4), laptop.partitions.len);
    try testing.expectEqualStrings("esp", laptop.partitions[0].kind);
    try testing.expectEqualStrings("windows", laptop.partitions[1].kind);
    try testing.expectEqualStrings("windows", laptop.partitions[2].kind);
    try testing.expectEqualStrings("windows", laptop.partitions[3].kind);
    // The gap between Windows and its recovery partition, and the tail.
    const b = laptop.beside;
    try testing.expect(b.possible);
    // Windows' volume ends part-way through a MiB; joe starts on the next.
    const windows_end: u64 = 239616 * 512 + 189458432000;
    try testing.expectEqual((windows_end + provision.mib - 1) / provision.mib * provision.mib, b.start);
    try testing.expectEqual(@as(u64, 496523264 * 512) - b.start, b.size);
    try testing.expectEqual(@as(u64, 0), b.start % provision.mib);
    try testing.expectEqualStrings("0a1b2c3d-0000-4000-8000-000000000001", b.esp);
    try testing.expectEqual(@as(usize, 1), b.systems.len);
    try testing.expectEqualStrings("Windows", b.systems[0]);
    try testing.expectEqual(@as(usize, 2), laptop.free.len);
    // The whole disk could still be erased.
    try testing.expect(laptop.usable);

    const old = disks[1];
    try testing.expect(!old.beside.possible);
    try testing.expectEqualStrings("its partition table is the old MBR kind, which joe cannot share", old.beside.reason);
}

test "free regions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mib = provision.mib;
    // An empty table: everything between the GPTs.
    const empty = try freeRegions(arena, 100 * mib, &.{});
    try testing.expectEqual(@as(usize, 1), empty.len);
    try testing.expectEqual(mib, empty[0].start);
    try testing.expectEqual(98 * mib, empty[0].size);
    // A partition that ends off a MiB boundary leaves the next whole MiB.
    const parts = [_]Partition{
        .{ .name = "a", .start = mib, .size = 10 * mib + 512, .fstype = "", .label = "", .kind = "other", .partuuid = "" },
        .{ .name = "b", .start = 50 * mib, .size = 49 * mib, .fstype = "", .label = "", .kind = "other", .partuuid = "" },
    };
    const gaps = try freeRegions(arena, 100 * mib, &parts);
    try testing.expectEqual(@as(usize, 1), gaps.len);
    try testing.expectEqual(12 * mib, gaps[0].start);
    try testing.expectEqual(38 * mib, gaps[0].size);
}

test "the device a mount point comes from" {
    const info =
        \\24 1 0:22 / / rw,relatime - overlay overlay rw,lowerdir=/run/live/lower
        \\30 24 11:0 / /run/live/medium ro,relatime - iso9660 /dev/sr0 ro
        \\31 24 7:0 / /run/live/lower ro,relatime - erofs /dev/loop0 ro
        \\
    ;
    try testing.expectEqualStrings("/dev/sr0", mountSource(info, medium_mount).?);
    try testing.expect(mountSource(info, "/nowhere") == null);
}

test "the medium says what to install" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const m = try parseMedium(arena_state.allocator(), ".{ .packages = .{ \"joe-desktop\" } }");
    try testing.expectEqualStrings("joe-desktop", m.packages[0]);
}

test "the disk steps compile" {
    _ = &Disks.partition;
    _ = &Disks.format;
    _ = &Disks.mountTarget;
    _ = &Disks.unmountTarget;
    _ = &Disks.addBeside;
    _ = &Disks.formatBeside;
    _ = &Disks.mountBoot;
    _ = &readById;
}

test "a root's packages, offered and checked" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "etc");
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/hostname", .data = "joe-live\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "etc/issue", .data = "joe\n" });

    const packages = [_]manifest.Manifest{.{ .name = "joe-filesystem", .version = "1-r1", .arch = arch.name, .depends = &.{"glibc"}, .files = &.{
        .{ .path = "etc", .kind = .dir, .mode = 0o755 },
        .{ .path = "etc/hostname", .size = 4, .sha256 = &archive.hashBytes("joe\n"), .config = true },
        .{ .path = "etc/issue", .size = 4, .sha256 = &archive.hashBytes("joe\n") },
        .{ .path = "etc/motd", .size = 4, .sha256 = &archive.hashBytes("joe\n") },
        .{ .path = "etc/os-release", .kind = .symlink, .target = "../usr/lib/os-release" },
    } }};
    const offered = try candidatesOf(arena, &packages);
    try testing.expectEqualStrings("joe-filesystem-1-r1-" ++ arch.name ++ ".dave", offered[0].entry.filename);
    try testing.expectEqualStrings("glibc", offered[0].entry.depends[0]);
    try testing.expectEqual(@as(?u64, 12), offered[0].entry.installed_size);

    const changed = try changedFiles(arena, io, tmp.dir, &packages);
    try testing.expectEqual(@as(usize, 2), changed.len);
    try testing.expectEqualStrings("etc/hostname", changed[0].file.path);
    try testing.expectEqualStrings("etc/motd", changed[1].file.path);
}
