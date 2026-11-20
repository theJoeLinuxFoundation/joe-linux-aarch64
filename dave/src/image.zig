//! Disk images, live media and container images built from declarative
//! specifications: `dave image build`.
//!
//! A specification (image/*.zon) states what an image is: the packages of its
//! root (or a prepared tree to start from), an overlay of files copied over
//! the result, the sizes of its partitions and what is added to the kernel
//! command line, and for a live medium, its initramfs and what its installer
//! installs. Everything that differs between one build of a spec and the next
//! (where the repositories are read from, the URLs the system will use,
//! whether it is a test image) is given on the command line, so that no host
//! name is ever written into the repository.
//!
//! The build runs in stages:
//!
//!   tree   the root. With packages, one dave transaction into an empty
//!          directory (main.zig runs it: it is the same code as
//!          `dave install`); then the overlay, and the repository
//!          configuration the system will use.
//!   disk   that tree laid out as provision.zig describes, in a raw GPT disk
//!          image. Nothing is mounted: mkfs.btrfs --rootdir and mtools fill
//!          the file systems from directories.
//!   iso    a live medium, as iso.zig describes: the tree as a compressed
//!          image, an initramfs made by a second transaction, and what the
//!          installer installs from it.
//!   oci    a container image, as oci.zig describes: the tree as one layer.
//!
//! An image is assembled without privileges. main.zig runs the whole build in
//! a user namespace in which the invoking user is root, so that every file
//! the image holds is owned by root.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const provision = @import("provision.zig");
const deploy = @import("deploy.zig");
const boot = @import("boot.zig");
const repo = @import("repo.zig");
const manifest = @import("manifest.zig");
const archive = @import("archive.zig");
const command = @import("command.zig");
const iso = @import("iso.zig");
const install_system = @import("install_system.zig");
const oci = @import("oci.zig");
const arch = @import("arch.zig");

pub const Format = enum { disk, iso, oci };

pub const Spec = struct {
    name: []const u8,
    format: Format = .disk,
    /// What the root is made of.
    packages: []const []const u8 = &.{},
    /// A prepared root to start from instead of an empty directory; the
    /// packages, if any, are installed on top of a copy of it.
    tree: ?[]const u8 = null,
    /// A directory whose contents are copied over the finished root.
    overlay: ?[]const u8 = null,
    root_size: []const u8 = "8G",
    esp_size: []const u8 = "1G",
    /// Added to the kernel command line the format itself needs.
    cmdline: []const u8 = "",
    /// For `.format = .iso`.
    iso: ?iso.Options = null,
    /// For `.format = .oci`, a container image (oci.zig).
    oci: ?oci.Options = null,
};

pub const Diagnostic = struct {
    message: []const u8 = "",
};

/// Parses a specification. Unlike package manifests, a field this version of
/// dave does not know is an error: a misspelt field would otherwise be
/// dropped without a word, and the image built without it.
pub fn parseSpec(arena: Allocator, source: []const u8, file_name: []const u8, diag: *Diagnostic) !Spec {
    const text = try arena.dupeSentinel(u8, source, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const spec = std.zon.parse.fromSlice(Spec, .{
        .gpa = arena,
        .arena = arena,
        .source = text,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            diag.message = try std.fmt.allocPrint(arena, "{f}", .{diagnostics.fmt(file_name)});
            return error.InvalidSpec;
        },
    };
    const invalid = struct {
        fn say(a: Allocator, d: *Diagnostic, comptime fmt: []const u8, args: anytype) !Spec {
            d.message = try std.fmt.allocPrint(a, fmt, args);
            return error.InvalidSpec;
        }
    }.say;
    for ([_][]const u8{ spec.root_size, spec.esp_size }) |size| {
        _ = parseSize(size) catch return invalid(arena, diag, "{s}: '{s}' is not a size (a whole number of MiB, such as 512M or 16G)", .{ file_name, size });
    }
    var names: std.ArrayList([]const u8) = .empty;
    try names.appendSlice(arena, spec.packages);
    if (spec.iso) |o| {
        try names.appendSlice(arena, o.payload);
        try names.appendSlice(arena, o.initrd.packages);
    }
    for (names.items) |name| if (!manifest.validName(name))
        return invalid(arena, diag, "{s}: '{s}' is not a package name", .{ file_name, name });
    if (spec.packages.len == 0 and spec.tree == null)
        return invalid(arena, diag, "{s}: an image needs packages or a tree", .{file_name});
    if (spec.iso != null and spec.format != .iso) return invalid(arena, diag, "{s}: .iso is for .format = .iso", .{file_name});
    if (spec.oci != null and spec.format != .oci) return invalid(arena, diag, "{s}: .oci is for .format = .oci", .{file_name});
    switch (spec.format) {
        .disk, .oci => {},
        .iso => {
            const o = spec.iso orelse return invalid(arena, diag, "{s}: a live medium needs .iso", .{file_name});
            if (o.initrd.packages.len == 0) return invalid(arena, diag, "{s}: a live medium needs .iso.initrd.packages", .{file_name});
            if (o.payload.len == 0) return invalid(arena, diag, "{s}: a live medium needs .iso.payload: what its installer installs", .{file_name});
            if (o.label.len == 0 or o.label.len > 32) return invalid(arena, diag, "{s}: .iso.label must have 1 to 32 characters", .{file_name});
        },
    }
    return spec;
}

/// "16G", "512M", "1024K" or a number of bytes; binary units; a whole
/// number of MiB, since partitions start and end on MiB boundaries.
pub fn parseSize(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidSize;
    const unit: u64 = switch (text[text.len - 1]) {
        'K' => 1024,
        'M' => provision.mib,
        'G' => 1024 * provision.mib,
        'T' => 1024 * 1024 * provision.mib,
        else => 1,
    };
    const digits = if (unit == 1) text else text[0 .. text.len - 1];
    const n = std.fmt.parseInt(u64, digits, 10) catch return error.InvalidSize;
    const bytes = std.math.mul(u64, n, unit) catch return error.InvalidSize;
    if (bytes == 0 or bytes % provision.mib != 0) return error.InvalidSize;
    return bytes;
}

/// `--repo NAME,DIR,URL,KEY`: a repository read from DIR while the image is
/// built, configured as URL in the image, and trusted through KEY.
pub const RepoArg = struct {
    name: []const u8,
    dir: []const u8,
    url: []const u8,
    key: []const u8,
};

pub fn parseRepoArg(text: []const u8) !RepoArg {
    var it = std.mem.splitScalar(u8, text, ',');
    var fields: [4][]const u8 = undefined;
    for (&fields) |*f| {
        f.* = it.next() orelse return error.InvalidRepo;
        if (f.len == 0) return error.InvalidRepo;
    }
    if (it.next() != null) return error.InvalidRepo;
    if (!manifest.validName(fields[0])) return error.InvalidRepo;
    return .{ .name = fields[0], .dir = fields[1], .url = fields[2], .key = fields[3] };
}

pub const Location = enum {
    /// Where the build reads the repository.
    build,
    /// Where the installed system will find it.
    installed,
};

pub fn reposZon(arena: Allocator, repos: []const RepoArg, location: Location) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(".{ .repos = .{\n");
    for (repos) |r| {
        const where = switch (location) {
            .build => r.dir,
            .installed => r.url,
        };
        try w.print("    .{{ .name = \"{f}\", .url = \"{f}\" }},\n", .{ std.zig.fmtString(r.name), std.zig.fmtString(where) });
    }
    try w.writeAll("} }\n");
    return out.written();
}

/// The medium's joe/install.zon: what its installer installs.
pub fn installZon(arena: Allocator, packages: []const []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll(".{ .packages = .{");
    for (packages) |p| try w.print(" \"{f}\",", .{std.zig.fmtString(p)});
    try w.writeAll(" } }\n");
    return out.written();
}

pub const Builder = struct {
    arena: Allocator,
    io: Io,
    spec: Spec,
    /// Directory of the spec file: relative paths in the spec start here.
    spec_dir: []const u8,
    /// Absolute path of the image to write.
    out: []const u8,
    /// Absolute path of a scratch directory, removed afterwards.
    work: []const u8,
    repos: []const RepoArg = &.{},
    /// Adds joe-test-console, and the password "joe" for accounts that test
    /// packages create; a live medium also gets a serial console.
    test_image: bool = false,
    /// Replaces the spec's tree (`--tree`).
    tree_override: ?[]const u8 = null,
    /// Installed with the spec's packages (`--with`).
    extra_packages: []const []const u8 = &.{},
    diag: Diagnostic = .{},

    /// systemd-sysusers, run as a trigger, takes passwords for the accounts
    /// it creates from credentials. Triggers run inside the new root, so that
    /// is where the directory is, and how its path is given
    /// (CREDENTIALS_DIRECTORY, set by main.zig for the transaction).
    pub const credentials_dir = "run/dave-image-credentials";
    pub const credentials_path = "/" ++ credentials_dir;
    const test_password_file = credentials_dir ++ "/passwd.plaintext-password.joe";
    const test_console = "console=" ++ arch.serial_console ++ ",115200";

    fn fail(b: *Builder, comptime fmt: []const u8, args: anytype) error{ImageFailed} {
        b.diag.message = std.fmt.allocPrint(b.arena, fmt, args) catch "out of memory";
        return error.ImageFailed;
    }

    fn resolve(b: *Builder, path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(path)) return path;
        return std.fs.path.join(b.arena, &.{ b.spec_dir, path });
    }

    fn join(b: *Builder, parts: []const []const u8) ![]const u8 {
        return std.fs.path.join(b.arena, parts);
    }

    pub fn treePath(b: *Builder) ![]const u8 {
        return b.join(&.{ b.work, "tree" });
    }

    pub fn initrdPath(b: *Builder) ![]const u8 {
        return b.join(&.{ b.work, "initrd" });
    }

    /// Where the originals of the files the live root holds changed are
    /// gathered, for the medium's joe/originals.
    pub fn originalsPath(b: *Builder) ![]const u8 {
        return b.join(&.{ b.work, "originals" });
    }

    /// The packages the root's transaction installs.
    pub fn packages(b: *Builder) ![]const []const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.appendSlice(b.arena, b.spec.packages);
        try all.appendSlice(b.arena, b.extra_packages);
        // The automated tests need a root prompt on the serial console; no
        // real installation should have one.
        if (b.test_image and all.items.len > 0) try all.append(b.arena, "joe-test-console");
        return all.items;
    }

    /// What a live medium's installer installs.
    pub fn payload(b: *Builder) ![]const []const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        try all.appendSlice(b.arena, b.spec.iso.?.payload);
        // The installed system of a test medium is examined the same way.
        if (b.test_image) try all.append(b.arena, "joe-test-console");
        return all.items;
    }

    /// Runs a program the build needs, with `input` on its standard input.
    fn exec(b: *Builder, argv: []const []const u8, input: ?[]const u8) !void {
        var diag: command.Diagnostic = .{};
        _ = command.run(b.arena, b.io, argv, .{ .input = input }, &diag) catch |err| switch (err) {
            error.CommandFailed => return b.fail("{s}", .{diag.message}),
            else => return err,
        };
    }

    /// A root the repositories can be installed from: their configuration
    /// (where the build reads them) and keys.
    fn configureRepos(b: *Builder, root: Io.Dir) !void {
        const cwd = Io.Dir.cwd();
        try root.createDirPath(b.io, repo.keys_path);
        for (b.repos) |r| {
            const dest = try std.fmt.allocPrint(b.arena, repo.keys_path ++ "/{s}.pub", .{r.name});
            cwd.copyFile(r.key, root, dest, b.io, .{}) catch |err|
                return b.fail("cannot copy the key {s}: {t}", .{ r.key, err });
        }
        try root.writeFile(b.io, .{ .sub_path = repo.config_path, .data = try reposZon(b.arena, b.repos, .build) });
    }

    fn emptyRoot(b: *Builder, path: []const u8) !Io.Dir {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(b.io, path);
        const root = try cwd.openDir(b.io, path, .{ .iterate = true });
        try b.configureRepos(root);
        return root;
    }

    /// Empties the scratch directory and starts the root: a copy of the
    /// spec's tree, or nothing. The repositories it is built from are
    /// configured in it, and their keys trusted.
    pub fn prepareTree(b: *Builder) !void {
        const cwd = Io.Dir.cwd();
        cwd.deleteTree(b.io, b.work) catch {};
        try cwd.createDirPath(b.io, b.work);
        const tree = try b.treePath();
        if (b.tree_override orelse b.spec.tree) |source| {
            const from = if (b.tree_override != null) source else try b.resolve(source);
            _ = cwd.statFile(b.io, from, .{}) catch return b.fail("the tree {s} does not exist", .{from});
            try b.exec(&.{ "cp", "-a", "--reflink=auto", from, tree }, null);
        } else {
            try cwd.createDirPath(b.io, tree);
        }
        var root = try cwd.openDir(b.io, tree, .{ .iterate = true });
        defer root.close(b.io);
        if (b.repos.len > 0) try b.configureRepos(root);
        if (b.test_image and (try b.packages()).len > 0) {
            try root.createDirPath(b.io, credentials_dir);
            try root.writeFile(b.io, .{ .sub_path = test_password_file, .data = "joe" });
        }
    }

    /// After the transaction: the overlay, and the repositories as the
    /// installed system will reach them.
    pub fn finishTree(b: *Builder) !void {
        const cwd = Io.Dir.cwd();
        const tree = try b.treePath();
        var root = try cwd.openDir(b.io, tree, .{ .iterate = true });
        defer root.close(b.io);
        root.deleteTree(b.io, credentials_dir) catch {};
        if (b.spec.overlay) |overlay| try b.copyOverlay(overlay, tree);
        if (b.repos.len > 0) {
            try root.writeFile(b.io, .{ .sub_path = repo.config_path, .data = try reposZon(b.arena, b.repos, .installed) });
        }
    }

    /// The package files fetched while building the root (a live medium's
    /// build still reads originals from them), which have no use in the
    /// image.
    pub fn dropCache(b: *Builder) !void {
        var root = try Io.Dir.cwd().openDir(b.io, try b.treePath(), .{ .iterate = true });
        defer root.close(b.io);
        root.deleteTree(b.io, "var/cache/dave") catch {};
    }

    fn copyOverlay(b: *Builder, overlay: []const u8, into: []const u8) !void {
        const from = try b.resolve(overlay);
        _ = Io.Dir.cwd().statFile(b.io, from, .{}) catch return b.fail("the overlay {s} does not exist", .{from});
        try b.exec(&.{ "cp", "-a", "--no-preserve=ownership", try std.fmt.allocPrint(b.arena, "{s}/.", .{from}), into }, null);
    }

    // -- disk ---------------------------------------------------------------

    /// Lays the tree out as provision.zig describes and writes the disk image.
    pub fn buildDisk(b: *Builder) !void {
        const io = b.io;
        const arena = b.arena;
        const cwd = Io.Dir.cwd();
        const esp_size = try parseSize(b.spec.esp_size);
        const root_size = try parseSize(b.spec.root_size);
        const plan = provision.Plan.new(io, esp_size, root_size);

        // The top level of the btrfs file system, as a directory tree.
        const layout = try b.join(&.{ b.work, "layout" });
        try cwd.createDirPath(io, try b.join(&.{ layout, deploy.deploy_dir }));
        for (provision.shared_subvolumes) |shared| try cwd.createDirPath(io, try b.join(&.{ layout, shared }));
        const deployment = try b.join(&.{ layout, provision.first_deployment_path });
        try b.exec(&.{ "cp", "-a", "--reflink=auto", try b.treePath(), deployment }, null);
        var top = try cwd.openDir(io, layout, .{ .iterate = true });
        defer top.close(io);
        var dep = try cwd.openDir(io, deployment, .{ .iterate = true });
        defer dep.close(io);

        // /var and /home are shared subvolumes, so their contents live
        // outside the deployment; the deployment keeps empty mount points.
        for (provision.shared_subvolumes) |shared| {
            try moveContents(arena, io, dep, shared, top, shared);
            try dep.createDirPath(io, shared);
        }
        try dep.createDirPath(io, provision.esp_mount);
        try dep.createDirPath(io, "etc");
        try dep.writeFile(io, .{ .sub_path = "etc/fstab", .data = try provision.fstab(arena, plan) });

        const kernel = try b.kernelOf(dep);
        const root_img = try b.join(&.{ b.work, "root.img" });
        try sized(io, root_img, root_size);
        try b.exec(&.{
            "mkfs.btrfs", "-q",       "-f",       "-L",                                     provision.root_label,
            "--rootdir",  layout,     "--subvol", "rw:" ++ provision.first_deployment_path, "--subvol",
            "rw:home",    "--subvol", "rw:var",   root_img,
        }, null);

        const esp_dir = try b.join(&.{ b.work, "esp" });
        try cwd.createDirPath(io, esp_dir);
        var esp = try cwd.openDir(io, esp_dir, .{ .iterate = true });
        defer esp.close(io);
        provision.writeEsp(arena, io, esp, .{ .root = dep, .kernel_path = kernel }, try provision.cmdline(arena, plan, b.spec.cmdline)) catch |err|
            return b.fail("cannot assemble the EFI system partition: {t}", .{err});
        const esp_img = try b.join(&.{ b.work, "esp.img" });
        try b.fatImage(esp_img, esp_size, provision.esp_label, esp_dir, esp);

        cwd.deleteFile(io, b.out) catch {};
        try sized(io, b.out, plan.imageSize());
        try b.exec(&.{ "sfdisk", "-q", b.out }, try provision.sfdiskScript(arena, plan));
        try b.place(esp_img, plan.espOffset());
        try b.place(root_img, plan.rootOffset());
    }

    fn kernelOf(b: *Builder, root: Io.Dir) ![]const u8 {
        const kernel = deploy.findKernelIn(b.arena, b.io, root) catch |err| switch (err) {
            error.NoKernel => return b.fail("the image has no kernel (usr/lib/modules/*/vmlinuz)", .{}),
            else => return err,
        };
        _ = root.statFile(b.io, boot.loader_source, .{}) catch return b.fail("the image has no systemd-boot ({s})", .{boot.loader_source});
        return kernel;
    }

    /// A FAT file system image holding the contents of `dir`.
    fn fatImage(b: *Builder, image: []const u8, size: u64, label: []const u8, dir_path: []const u8, dir: Io.Dir) !void {
        try sized(b.io, image, size);
        try b.exec(&.{ "mkfs.vfat", "-F", "32", "-n", label, image }, null);
        // mcopy -s copies directories recursively, but each top-level entry
        // has to be named.
        var mcopy: std.ArrayList([]const u8) = .empty;
        try mcopy.appendSlice(b.arena, &.{ "mcopy", "-i", image, "-s" });
        var it = dir.iterate();
        while (try it.next(b.io)) |e| try mcopy.append(b.arena, try b.join(&.{ dir_path, e.name }));
        try mcopy.append(b.arena, "::");
        try b.exec(mcopy.items, null);
    }

    /// Writes a partition's file system into the image at its offset,
    /// leaving the image sparse.
    fn place(b: *Builder, image: []const u8, offset: u64) !void {
        std.debug.assert(offset % provision.mib == 0);
        try b.exec(&.{
            "dd",
            try std.fmt.allocPrint(b.arena, "if={s}", .{image}),
            try std.fmt.allocPrint(b.arena, "of={s}", .{b.out}),
            "bs=1M",
            try std.fmt.allocPrint(b.arena, "seek={d}", .{offset / provision.mib}),
            "conv=notrunc,sparse",
            "status=none",
        }, null);
    }

    // -- live medium --------------------------------------------------------

    /// Starts the initramfs's root: its repositories, nothing else. main.zig
    /// installs the spec's initrd packages into it.
    pub fn prepareInitrd(b: *Builder) !void {
        var root = try b.emptyRoot(try b.initrdPath());
        root.close(b.io);
    }

    /// The initramfs after its transaction: the units that mount the medium
    /// (the spec's initrd overlay), and without what takes only space.
    pub fn finishInitrd(b: *Builder) !void {
        const options = b.spec.iso.?.initrd;
        const path = try b.initrdPath();
        var root = try Io.Dir.cwd().openDir(b.io, path, .{ .iterate = true });
        defer root.close(b.io);
        if (options.overlay) |overlay| try b.copyOverlay(overlay, path);
        for (options.remove) |doomed| {
            const rel = std.mem.trimStart(u8, doomed, "/");
            if (rel.len == 0 or std.mem.indexOf(u8, rel, "..") != null) return b.fail("cannot remove '{s}' from the initramfs", .{doomed});
            removeMatching(b.arena, b.io, root, rel) catch |err| return b.fail("cannot remove {s} from the initramfs: {t}", .{ rel, err });
        }
        // The initramfs is not a system dave manages.
        root.deleteTree(b.io, "var/cache/dave") catch {};
        root.deleteTree(b.io, "etc/dave") catch {};
        root.deleteTree(b.io, "usr/lib/dave/db") catch {};
        // dynamod-init knows it runs in an initramfs from its root (ramfs or
        // tmpfs) and the command line (root=, dynamod.live): no
        // /etc/initrd-release to require, as systemd needs one.
        _ = root.statFile(b.io, "init", .{}) catch return b.fail("the initramfs has no /init (the spec's initrd overlay should link it to dynamod-init)", .{});
    }

    /// Writes the live medium: everything else is ready by now, the
    /// originals (originalsPath) included.
    pub fn buildIso(b: *Builder) !void {
        const io = b.io;
        const arena = b.arena;
        const cwd = Io.Dir.cwd();
        const options = b.spec.iso.?;
        var tree = try cwd.openDir(io, try b.treePath(), .{ .iterate = true });
        defer tree.close(io);
        const kernel = try b.kernelOf(tree);

        // The ISO 9660 file system's contents. The installer installs from
        // the live root itself (install_system.zig), so the medium carries
        // no package files: only what to install, and the originals of the
        // files the live root changed.
        const staging = try b.join(&.{ b.work, "medium" });
        try cwd.createDirPath(io, try b.join(&.{ staging, "joe" }));
        var medium = try cwd.openDir(io, try b.join(&.{ staging, "joe" }), .{ .iterate = true });
        defer medium.close(io);
        try medium.writeFile(io, .{ .sub_path = install_system.install_file, .data = try installZon(arena, try b.payload()) });
        try b.exec(&.{ "cp", "-a", try b.originalsPath(), try b.join(&.{ staging, "joe", install_system.originals_dir }) }, null);

        // The live root, a SquashFS image in 1 MiB blocks. -all-root: files the
        // user namespace shows as root are root's, never the building user's.
        // -noappend: mksquashfs adds to an image that already exists.
        // -exit-on-error: a file it cannot read fails the build, where it
        // would otherwise be put in the image empty.
        {
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(arena, &.{
                "mksquashfs",     try b.treePath(),                                                          try b.join(&.{ staging, "joe", "root.squashfs" }),
                "-noappend",      "-quiet",                                                                  "-no-progress",
                "-exit-on-error", "-all-root",                                                               "-b",
                "1M",             "-comp",                                                                   options.compression,
                "-processors",    try std.fmt.allocPrint(arena, "{d}", .{std.Thread.getCpuCount() catch 1}),
            });
            if (std.mem.eql(u8, options.compression, "xz")) try argv.appendSlice(arena, &.{ "-Xbcj", arch.xz_bcj, "-Xdict-size", "1M" });
            try b.exec(argv.items, null);
        }

        // The initramfs.
        const initrd_img = try b.join(&.{ b.work, "initrd.img" });
        {
            var initrd = try cwd.openDir(io, try b.initrdPath(), .{ .iterate = true });
            defer initrd.close(io);
            iso.writeInitrd(arena, io, initrd, initrd_img) catch |err| return b.fail("cannot write the initramfs: {t}", .{err});
        }

        // The EFI system partition: systemd-boot, the kernel, the initramfs.
        const esp_dir = try b.join(&.{ b.work, "esp" });
        try cwd.createDirPath(io, try b.join(&.{ esp_dir, "EFI/BOOT" }));
        var esp = try cwd.openDir(io, esp_dir, .{ .iterate = true });
        defer esp.close(io);
        try tree.copyFile(boot.loader_source, esp, boot.fallback_loader, io, .{});
        try esp.createDirPath(io, "loader/entries");
        try esp.writeFile(io, .{ .sub_path = "loader/loader.conf", .data = iso.loader_conf });
        try esp.writeFile(io, .{ .sub_path = "loader/entries.srel", .data = provision.entries_srel });
        const kernel_path = try boot.installKernel(arena, io, esp, tree, kernel);
        const digest = try archive.hashFile(io, cwd, initrd_img);
        const initrd_path = try std.fmt.allocPrint(arena, "/joe/initrd/{s}.img", .{digest[0..16]});
        try esp.createDirPath(io, "joe/initrd");
        try cwd.copyFile(initrd_img, esp, initrd_path[1..], io, .{});

        var cmdline: std.ArrayList(u8) = .empty;
        try cmdline.appendSlice(arena, iso.live_cmdline);
        for ([_][]const u8{ b.spec.cmdline, if (b.test_image) test_console else "" }) |extra| {
            const trimmed = std.mem.trim(u8, extra, " \t\n");
            if (trimmed.len == 0) continue;
            try cmdline.append(arena, ' ');
            try cmdline.appendSlice(arena, trimmed);
        }
        const name = iso.prettyName(tree.readFileAlloc(io, "usr/lib/os-release", arena, .limited(64 * 1024)) catch "");
        for (iso.entries) |e| {
            const text = try iso.entryText(arena, e, name, kernel_path, initrd_path, cmdline.items);
            try esp.writeFile(io, .{ .sub_path = try b.join(&.{ "loader/entries", e.file }), .data = text });
        }

        var content: u64 = 0;
        for ([_][]const u8{ boot.fallback_loader, kernel_path[1..], initrd_path[1..] }) |p| content += (try esp.statFile(io, p, .{})).size;
        const esp_img = try b.join(&.{ b.work, "esp.img" });
        // The label differs from the medium's: the initramfs finds the
        // medium by its label, and must not find this.
        try b.fatImage(esp_img, iso.espImageSize(content), "JOE-EFI", esp_dir, esp);

        cwd.deleteFile(io, b.out) catch {};
        try b.exec(try iso.xorrisoArgv(arena, staging, esp_img, options.label, b.out), null);
    }

    // -- container image ----------------------------------------------------

    /// Writes the container image: the tree as one gzip-compressed tar
    /// layer, in an OCI image layout archived with tar (oci.zig).
    pub fn buildOci(b: *Builder) !void {
        const io = b.io;
        const arena = b.arena;
        const cwd = Io.Dir.cwd();
        const options = b.spec.oci orelse oci.Options{};
        const tree_path = try b.treePath();
        var tree = try cwd.openDir(io, tree_path, .{ .iterate = true });
        defer tree.close(io);

        const layout_path = try b.join(&.{ b.work, "oci" });
        try cwd.createDirPath(io, try b.join(&.{ layout_path, "blobs", "sha256" }));
        var layout = try cwd.openDir(io, layout_path, .{});
        defer layout.close(io);

        // The layer: its uncompressed digest names it in the configuration,
        // its compressed one in the manifest.
        const layer_tar = try b.join(&.{ b.work, "layer.tar" });
        try b.exec(try oci.layerTarArgv(arena, tree_path, layer_tar), null);
        const diff_id = try archive.hashFile(io, cwd, layer_tar);
        try b.exec(&.{ "gzip", "-n", "-f", layer_tar }, null);
        const layer_gz = try std.fmt.allocPrint(arena, "{s}.gz", .{layer_tar});
        const layer: oci.Blob = .{
            .digest = try arena.dupe(u8, &try archive.hashFile(io, cwd, layer_gz)),
            .size = (try cwd.statFile(io, layer_gz, .{})).size,
        };
        try cwd.rename(layer_gz, layout, try oci.blobPath(arena, layer.digest), io);

        const os_release = tree.readFileAlloc(io, "usr/lib/os-release", arena, .limited(64 * 1024)) catch "";
        const created = try oci.rfc3339(arena, @intCast(Io.Timestamp.now(io, .real).toSeconds()));
        var labels: std.ArrayList(oci.Label) = .empty;
        try labels.appendSlice(arena, options.labels);
        if (oci.osVersion(os_release)) |v| try labels.append(arena, .{ .name = "org.opencontainers.image.version", .value = v });
        try labels.append(arena, .{ .name = "org.opencontainers.image.created", .value = created });

        const config = try b.writeBlob(layout, try oci.configJson(arena, options, labels.items, created, &diff_id));
        const manifest_blob = try b.writeBlob(layout, try oci.manifestJson(arena, config, layer, labels.items));
        try layout.writeFile(io, .{ .sub_path = oci.layout_file, .data = oci.layout_text });
        try layout.writeFile(io, .{ .sub_path = "index.json", .data = try oci.indexJson(arena, manifest_blob, b.spec.name, "latest") });
        const tag = try std.fmt.allocPrint(arena, "{s}:latest", .{b.spec.name});
        try layout.writeFile(io, .{ .sub_path = "manifest.json", .data = try oci.dockerManifestJson(arena, config, layer, tag) });

        cwd.deleteFile(io, b.out) catch {};
        try b.exec(&.{
            "tar",            "--create",        "--file",    b.out,       "--directory", layout_path,
            "--format=posix", "--numeric-owner", "--owner=0", "--group=0", "--sort=name", oci.layout_file,
            "index.json",     "manifest.json",   "blobs",
        }, null);
    }

    fn writeBlob(b: *Builder, layout: Io.Dir, data: []const u8) !oci.Blob {
        const digest = try b.arena.dupe(u8, &archive.hashBytes(data));
        try layout.writeFile(b.io, .{ .sub_path = try oci.blobPath(b.arena, digest), .data = data });
        return .{ .digest = digest, .size = data.len };
    }

    pub fn cleanup(b: *Builder) void {
        Io.Dir.cwd().deleteTree(b.io, b.work) catch {};
    }
};

/// A file of `size` bytes, all of them holes.
fn sized(io: Io, path: []const u8, size: u64) !void {
    var f = try Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.setLength(io, size);
}

/// Deletes `path` under `root`, whatever it is. A `*` in its last part
/// matches any run of characters ("usr/lib/*.a"); a path that matches
/// nothing is not an error.
fn removeMatching(arena: Allocator, io: Io, root: Io.Dir, path: []const u8) !void {
    const name = std.fs.path.basename(path);
    if (std.mem.indexOfScalar(u8, name, '*') == null) return root.deleteTree(io, path);
    const parent_path = std.fs.path.dirname(path) orelse ".";
    var parent = root.openDir(io, parent_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer parent.close(io);
    var doomed: std.ArrayList([]const u8) = .empty;
    var it = parent.iterate();
    while (try it.next(io)) |e| {
        if (globMatch(name, e.name)) try doomed.append(arena, try arena.dupe(u8, e.name));
    }
    for (doomed.items) |n| try parent.deleteTree(io, n);
}

fn globMatch(pattern: []const u8, name: []const u8) bool {
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return std.mem.eql(u8, pattern, name);
    const head = pattern[0..star];
    if (!std.mem.startsWith(u8, name, head)) return false;
    const rest = pattern[star + 1 ..];
    var i: usize = head.len;
    while (i <= name.len) : (i += 1) {
        if (globMatch(rest, name[i..])) return true;
    }
    return false;
}

/// Moves everything inside `from_dir/from` into `to_dir/to`.
fn moveContents(arena: Allocator, io: Io, from_dir: Io.Dir, from: []const u8, to_dir: Io.Dir, to: []const u8) !void {
    var src = from_dir.openDir(io, from, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer src.close(io);
    var dst = try to_dir.openDir(io, to, .{});
    defer dst.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = src.iterate();
    while (try it.next(io)) |e| try names.append(arena, try arena.dupe(u8, e.name));
    for (names.items) |name| try src.rename(name, dst, name, io);
}

const testing = std.testing;

test "specifications are parsed strictly" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};

    const spec = try parseSpec(arena,
        \\.{ .name = "joe-desktop", .packages = .{ "joe-desktop", "joe-test-desktop" },
        \\   .overlay = "overlays/desktop", .root_size = "16G", .cmdline = "console=ttyS0,115200" }
    , "desktop.zon", &diag);
    try testing.expectEqualStrings("joe-desktop", spec.name);
    try testing.expectEqual(Format.disk, spec.format);
    try testing.expectEqual(@as(usize, 2), spec.packages.len);
    try testing.expectEqualStrings("1G", spec.esp_size);

    try testing.expectError(error.InvalidSpec, parseSpec(arena,
        \\.{ .name = "x", .packages = .{"a"}, .rootsize = "16G" }
    , "typo.zon", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "rootsize") != null);
    try testing.expectError(error.InvalidSpec, parseSpec(arena, ".{ .name = \"x\", .packages = .{\"a\"}, .root_size = \"1.5G\" }", "s.zon", &diag));
    try testing.expectError(error.InvalidSpec, parseSpec(arena, ".{ .name = \"x\" }", "s.zon", &diag));
    try testing.expectError(error.InvalidSpec, parseSpec(arena, ".{ .name = \"x\", .packages = .{\"bad name\"} }", "s.zon", &diag));
    _ = try parseSpec(arena, ".{ .name = \"scaffold\", .tree = \"../build/scaffold/rootfs\" }", "s.zon", &diag);
}

test "a live medium's specification" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const spec = try parseSpec(arena,
        \\.{ .name = "joe-live", .format = .iso, .packages = .{ "joe-desktop", "joe-live" },
        \\   .iso = .{ .initrd = .{ .packages = .{"systemd"}, .overlay = "initrd", .remove = .{"usr/include"} },
        \\             .payload = .{"joe-desktop"} } }
    , "live.zon", &diag);
    try testing.expectEqual(Format.iso, spec.format);
    try testing.expectEqualStrings("JOE_LIVE", spec.iso.?.label);
    try testing.expectEqualStrings("initrd", spec.iso.?.initrd.overlay.?);

    try testing.expectError(error.InvalidSpec, parseSpec(arena, ".{ .name = \"x\", .format = .iso, .packages = .{\"a\"} }", "s.zon", &diag));
    try testing.expectError(error.InvalidSpec, parseSpec(arena,
        \\.{ .name = "x", .format = .iso, .packages = .{"a"}, .iso = .{ .initrd = .{ .packages = .{"systemd"} } } }
    , "s.zon", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "payload") != null);
    try testing.expectError(error.InvalidSpec, parseSpec(arena,
        \\.{ .name = "x", .packages = .{"a"}, .iso = .{ .payload = .{"a"} } }
    , "s.zon", &diag));

    try testing.expectEqualStrings(".{ .packages = .{ \"joe-desktop\", \"joe-test-console\", } }\n", try installZon(arena, &.{ "joe-desktop", "joe-test-console" }));
}

test "patterns in paths to remove" {
    try testing.expect(globMatch("*.a", "libc.a"));
    try testing.expect(!globMatch("*.a", "libc.so"));
    try testing.expect(globMatch("gcov*", "gcov-dump"));
    try testing.expect(globMatch("x86_64-*-gcc", "x86_64-pc-linux-gnu-gcc"));
    try testing.expect(!globMatch("gcc", "gcc-ar"));
    try testing.expect(globMatch("*", "anything"));

    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "usr/lib/gcc/x");
    for ([_][]const u8{ "usr/lib/libc.a", "usr/lib/libm.a", "usr/lib/libc.so.6" }) |f| try tmp.dir.writeFile(io, .{ .sub_path = f, .data = "x" });
    try removeMatching(arena_state.allocator(), io, tmp.dir, "usr/lib/*.a");
    try removeMatching(arena_state.allocator(), io, tmp.dir, "usr/lib/gcc");
    try removeMatching(arena_state.allocator(), io, tmp.dir, "usr/nothing/*.a");
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "usr/lib/libc.a", .{}));
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "usr/lib/gcc", .{}));
    _ = try tmp.dir.statFile(io, "usr/lib/libc.so.6", .{});
}

test "sizes" {
    try testing.expectEqual(@as(u64, 16 << 30), try parseSize("16G"));
    try testing.expectEqual(@as(u64, 512 << 20), try parseSize("512M"));
    try testing.expectEqual(@as(u64, 1 << 20), try parseSize("1024K"));
    try testing.expectEqual(@as(u64, 1 << 20), try parseSize("1048576"));
    try testing.expectError(error.InvalidSize, parseSize("100K"));
    try testing.expectError(error.InvalidSize, parseSize("0G"));
    try testing.expectError(error.InvalidSize, parseSize("G"));
    try testing.expectError(error.InvalidSize, parseSize(""));
}

test "repositories on the command line and in the image" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = try parseRepoArg("joe,/build/repo,https://example.org/x86_64,/build/keys/joe.pub");
    try testing.expectEqualStrings("https://example.org/x86_64", r.url);
    try testing.expectError(error.InvalidRepo, parseRepoArg("joe,/build/repo,https://example.org"));
    try testing.expectError(error.InvalidRepo, parseRepoArg("joe,/a,b,c,d"));
    try testing.expectError(error.InvalidRepo, parseRepoArg("joe,,b,c"));

    const repos = [_]RepoArg{ r, .{ .name = "test", .dir = "/t", .url = "http://10.0.2.2:8642", .key = "/t.pub" } };
    const built = try reposZon(arena, &repos, .build);
    const installed = try reposZon(arena, &repos, .installed);
    try testing.expect(std.mem.indexOf(u8, built, "\"/build/repo\"") != null);
    try testing.expect(std.mem.indexOf(u8, installed, "\"https://example.org/x86_64\"") != null);
    // What dave reads back in the installed system.
    const config = try manifest.parseZon(repo.Config, arena, installed);
    try testing.expectEqual(@as(usize, 2), config.repos.len);
    try testing.expectEqualStrings("http://10.0.2.2:8642", config.repos[1].url);
}
