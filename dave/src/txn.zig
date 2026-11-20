//! Applies a set of package installations and removals to a root directory.
//!
//! The transaction engine has no undo log. For upgrades it is pointed at a
//! fresh btrfs snapshot that is simply deleted if anything fails; for live
//! installs a snapshot of the running root is taken first. What it does
//! guarantee is that nothing is touched until every check has passed, and that
//! each individual file appears atomically (written under a temporary name,
//! verified against the manifest, then renamed into place).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const manifest_mod = @import("manifest.zig");
const Manifest = manifest_mod.Manifest;
const archive = @import("archive.zig");
const db = @import("db.zig");
const seal = @import("seal.zig");
const arch = @import("arch.zig");

pub const PackageFile = struct {
    dir: Io.Dir,
    sub_path: []const u8,
};

/// A package installed by copying it out of another root where it is
/// installed, instead of from its package file: how the installer installs
/// what the live medium's own root holds.
pub const Copy = struct {
    /// The package, as that root's database records it.
    manifest: Manifest,
    /// The root it is installed in. Each regular file is read from there and
    /// checked against the manifest, as a file from a package file is.
    from: Io.Dir,
    /// Originals of the files `from` holds changed (the live medium's
    /// /etc/passwd, say), each named by its SHA-256: a file found here is
    /// read from here instead.
    originals: ?Io.Dir = null,
};

pub const Plan = struct {
    /// Packages to install, or to replace the installed version of.
    install: []const PackageFile = &.{},
    /// Packages to install by copying them from another root; after `install`.
    copy: []const Copy = &.{},
    /// Names of installed packages to remove.
    remove: []const []const u8 = &.{},
    /// Take over files that exist but belong to no package instead of
    /// refusing. Used when a root built by other means is first brought under
    /// dave's management, as during the distribution's own bootstrap.
    overwrite_unowned: bool = false,
    /// Seal files as they are installed, where the manifest carries a seal.
    seal: bool = true,
    /// The attribute seals are stored in; only tests use another.
    seal_attribute: [*:0]const u8 = seal.xattr_name,
    /// Told after each package is written, for those watching a long
    /// transaction (the installer).
    progress: ?Progress = null,
};

pub const Progress = struct {
    context: *anyopaque,
    report: *const fn (context: *anyopaque, done: usize, total: usize, name: []const u8) void,
};

pub const Change = struct {
    name: []const u8,
    old_version: ?[]const u8 = null,
    new_version: ?[]const u8 = null,
};

pub const Result = struct {
    changes: []const Change,
    /// Things the administrator should know, e.g. preserved configuration.
    notes: []const []const u8,
    /// Every path created, replaced or removed; used to select triggers.
    changed_paths: []const []const u8,
    /// Files installed with a seal in place.
    sealed: usize = 0,
    /// Files that have a seal in their manifest but could not be sealed here
    /// (no fs-verity, or no privilege to write the attribute). `dave seal`
    /// finishes the job once it can.
    unsealed: usize = 0,
};

/// Filled in with a human-readable reason when `apply` fails.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const Error = error{ FileConflict, InvalidPackage, NotInstalled, UnknownOwner };

const Owned = struct {
    pkg: []const u8,
    file: manifest_mod.File,
};

const Txn = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    root: Io.Dir,
    diag: *Diagnostic,
    /// Who owned each path before the transaction.
    old_owner: std.StringHashMapUnmanaged(Owned) = .empty,
    /// Who owns each path once the transaction is complete.
    new_owner: std.StringHashMapUnmanaged(Owned) = .empty,
    notes: std.ArrayList([]const u8) = .empty,
    changed: std.ArrayList([]const u8) = .empty,
    overwrite: bool = false,
    seal: bool = true,
    seal_attribute: [*:0]const u8 = seal.xattr_name,
    sealed: usize = 0,
    unsealed: usize = 0,

    fn fail(t: *Txn, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
        t.diag.message = std.fmt.allocPrint(t.arena, fmt, args) catch "";
        return err;
    }

    fn note(t: *Txn, comptime fmt: []const u8, args: anytype) !void {
        try t.notes.append(t.arena, try std.fmt.allocPrint(t.arena, fmt, args));
    }

    fn claim(t: *Txn, pkg: []const u8, f: manifest_mod.File) !void {
        const gop = try t.new_owner.getOrPut(t.arena, f.path);
        if (gop.found_existing) {
            const other = gop.value_ptr.*;
            if (other.file.kind == .dir and f.kind == .dir) return;
            return t.fail(error.FileConflict, "{s} is provided by both {s} and {s}", .{ f.path, other.pkg, pkg });
        }
        gop.value_ptr.* = .{ .pkg = pkg, .file = f };
    }

    const Disk = enum { absent, file, dir, other };

    fn onDisk(t: *Txn, path: []const u8, follow: bool) !Disk {
        const st = t.root.statFile(t.io, path, .{ .follow_symlinks = follow }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return .absent,
            else => return err,
        };
        return switch (st.kind) {
            .file => .file,
            .directory => .dir,
            else => .other,
        };
    }

    /// Refuses to proceed if installing `m` would overwrite something no
    /// package owns.
    fn checkDisk(t: *Txn, m: Manifest) !void {
        for (m.files) |f| {
            if (t.old_owner.contains(f.path)) continue;
            if (f.kind == .dir) {
                switch (try t.onDisk(f.path, true)) {
                    .absent, .dir => {},
                    else => return t.fail(error.FileConflict, "{s}: {s} exists and is not a directory", .{ m.name, f.path }),
                }
                continue;
            }
            // An unowned configuration file is kept; the new one goes alongside.
            if (f.kind == .file and f.config) continue;
            if (try t.onDisk(f.path, false) != .absent)
                return t.fail(error.FileConflict, "{s}: {s} already exists and is not owned by any package", .{ m.name, f.path });
        }
    }

    fn ensureParent(t: *Txn, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |parent| try t.root.createDirPath(t.io, parent);
    }

    fn tmpName(t: *Txn, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(t.arena, "{s}.dave-tmp", .{path});
    }

    fn applyOwner(t: *Txn, path: []const u8, f: manifest_mod.File) !void {
        if (std.mem.eql(u8, f.owner, "root") and std.mem.eql(u8, f.group, "root")) return;
        const uid = try t.lookupId("etc/passwd", f.owner);
        const gid = try t.lookupId("etc/group", f.group);
        try t.root.setFileOwner(t.io, path, uid, gid, .{ .follow_symlinks = false });
    }

    /// Resolves a user or group name against the target root's own databases.
    fn lookupId(t: *Txn, db_file: []const u8, name: []const u8) !u32 {
        if (std.mem.eql(u8, name, "root")) return 0;
        const text = t.root.readFileAlloc(t.io, db_file, t.arena, .limited(4 * 1024 * 1024)) catch
            return t.fail(error.UnknownOwner, "cannot read {s} to resolve '{s}'", .{ db_file, name });
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, ':');
            if (!std.mem.eql(u8, fields.next() orelse continue, name)) continue;
            _ = fields.next();
            return std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        }
        return t.fail(error.UnknownOwner, "'{s}' is not defined in {s}", .{ name, db_file });
    }

    const ConfigAction = enum { install, keep, alongside };

    fn configAction(t: *Txn, f: manifest_mod.File) !ConfigAction {
        switch (try t.onDisk(f.path, false)) {
            .absent => return .install,
            .file => {},
            else => return .alongside,
        }
        const on_disk = try archive.hashFile(t.io, t.root, f.path);
        if (std.mem.eql(u8, &on_disk, f.sha256.?)) return .install;
        if (t.old_owner.get(f.path)) |old| {
            if (old.file.sha256) |shipped| {
                // Untouched since it was installed: safe to replace.
                if (std.mem.eql(u8, &on_disk, shipped)) return .install;
                // Edited locally and the package did not change it: nothing to do.
                if (std.mem.eql(u8, shipped, f.sha256.?)) return .keep;
            }
        }
        return .alongside;
    }

    fn installPackage(t: *Txn, pf: PackageFile) !Manifest {
        const reader = try archive.PackageReader.open(t.gpa, t.io, pf.dir, pf.sub_path);
        defer reader.close(t.gpa);
        const m = try reader.readManifest(t.arena);

        var by_path: std.StringHashMapUnmanaged(manifest_mod.File) = .empty;
        for (m.files) |f| try by_path.put(t.arena, f.path, f);
        try t.makeDirs(m);

        var written: std.StringHashMapUnmanaged(void) = .empty;
        while (try reader.next()) |entry| {
            const f = by_path.get(entry.path) orelse
                return t.fail(error.InvalidPackage, "{s}: payload contains {s}, which the manifest does not list", .{ m.name, entry.path });
            if (f.kind != .file or f.sha256 == null or written.contains(f.path))
                return t.fail(error.InvalidPackage, "{s}: unexpected payload entry {s}", .{ m.name, entry.path });
            try written.put(t.arena, f.path, {});
            try t.placeFile(.{ .archive = reader }, m, f);
        }
        for (m.files) |f| {
            if (f.kind == .file and !written.contains(f.path))
                return t.fail(error.InvalidPackage, "{s}: payload is missing {s}", .{ m.name, f.path });
        }

        try t.makeLinks(m, by_path);
        return m;
    }

    /// Installs a package from the root it is installed in: the same as from
    /// its package file, with each regular file read from that root (or its
    /// original) and verified the same way.
    fn installCopy(t: *Txn, c: Copy) !Manifest {
        const m = c.manifest;
        var by_path: std.StringHashMapUnmanaged(manifest_mod.File) = .empty;
        for (m.files) |f| try by_path.put(t.arena, f.path, f);
        try t.makeDirs(m);

        for (m.files) |f| {
            if (f.kind != .file) continue;
            const digest = f.sha256 orelse
                return t.fail(error.InvalidPackage, "{s}: {s} has no checksum", .{ m.name, f.path });
            const original: ?Io.File = if (c.originals) |dir| dir.openFile(t.io, digest, .{}) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return t.fail(err, "{s}: cannot read the original of {s}", .{ m.name, f.path }),
            } else null;
            var file = original orelse c.from.openFile(t.io, f.path, .{}) catch |err|
                return t.fail(err, "{s}: cannot read {s} to copy it", .{ m.name, f.path });
            defer file.close(t.io);
            var buf: [64 * 1024]u8 = undefined;
            var reader = file.readerStreaming(t.io, &buf);
            try t.placeFile(.{ .reader = &reader.interface }, m, f);
        }

        try t.makeLinks(m, by_path);
        return m;
    }

    fn makeDirs(t: *Txn, m: Manifest) !void {
        for (m.files) |f| {
            if (f.kind != .dir) continue;
            if (try t.onDisk(f.path, true) == .dir) continue;
            try t.ensureParent(f.path);
            try t.root.createDir(t.io, f.path, .fromMode(@intCast(f.mode)));
            try t.root.setFilePermissions(t.io, f.path, .fromMode(@intCast(f.mode)), .{});
            try t.applyOwner(f.path, f);
            try t.changed.append(t.arena, f.path);
        }
    }

    /// Writes one regular file of `m` from `source`, minding local changes to
    /// configuration files.
    fn placeFile(t: *Txn, source: Source, m: Manifest, f: manifest_mod.File) !void {
        const action: ConfigAction = if (f.config and !t.overwrite) try t.configAction(f) else .install;
        const dest = switch (action) {
            .install => f.path,
            .alongside => try std.fmt.allocPrint(t.arena, "{s}.davenew", .{f.path}),
            .keep => null,
        };
        try t.writeFile(source, m, f, dest);
        switch (action) {
            .install => try t.changed.append(t.arena, f.path),
            .alongside => try t.note("{s}: local changes kept; the packaged version is at {s}.davenew", .{ f.path, f.path }),
            .keep => {},
        }
    }

    fn makeLinks(t: *Txn, m: Manifest, by_path: std.StringHashMapUnmanaged(manifest_mod.File)) !void {
        for (m.files) |f| {
            if (f.kind != .symlink and f.kind != .hardlink) continue;
            const target = f.target orelse
                return t.fail(error.InvalidPackage, "{s}: {s} has no link target", .{ m.name, f.path });
            try t.ensureParent(f.path);
            const tmp = try t.tmpName(f.path);
            t.root.deleteFile(t.io, tmp) catch {};
            if (f.kind == .symlink) {
                try t.root.symLink(t.io, target, tmp, .{});
            } else {
                if (!by_path.contains(target))
                    return t.fail(error.InvalidPackage, "{s}: {s} links to {s}, which is not in the package", .{ m.name, f.path, target });
                try t.root.hardLink(target, t.root, tmp, t.io, .{});
            }
            t.root.rename(tmp, t.root, f.path, t.io) catch |err| {
                t.root.deleteFile(t.io, tmp) catch {};
                return t.fail(err, "{s}: cannot place {s}", .{ m.name, f.path });
            };
            try t.changed.append(t.arena, f.path);
        }
    }

    /// Where a file's contents come from: the current entry of a package
    /// file, or a file of another root.
    const Source = union(enum) {
        archive: *archive.PackageReader,
        reader: *Io.Reader,

        fn pump(source: Source, w: *Io.Writer) !void {
            switch (source) {
                .archive => |r| try r.stream(w),
                .reader => |r| _ = try r.streamRemaining(w),
            }
        }
    };

    /// Streams a file's contents from `source` to `dest` (or nowhere),
    /// verifying them.
    fn writeFile(t: *Txn, source: Source, m: Manifest, f: manifest_mod.File, dest: ?[]const u8) !void {
        var sink_buf: [64 * 1024]u8 = undefined;
        const path = dest orelse {
            var sink: archive.HashingSink = .init(null, &sink_buf);
            try source.pump(&sink.writer);
            const digest = try sink.finish();
            if (!std.mem.eql(u8, &digest, f.sha256.?))
                return t.fail(error.InvalidPackage, "{s}: {s} does not match its recorded checksum", .{ m.name, f.path });
            return;
        };
        try t.ensureParent(path);
        const tmp = try t.tmpName(path);
        errdefer t.root.deleteFile(t.io, tmp) catch {};
        {
            var file = try t.root.createFile(t.io, tmp, .{});
            defer file.close(t.io);
            var file_buf: [64 * 1024]u8 = undefined;
            var fw = file.writer(t.io, &file_buf);
            var sink: archive.HashingSink = .init(&fw.interface, &sink_buf);
            try source.pump(&sink.writer);
            const digest = try sink.finish();
            try fw.interface.flush();
            if (!std.mem.eql(u8, &digest, f.sha256.?) or sink.count != f.size)
                return t.fail(error.InvalidPackage, "{s}: {s} does not match its recorded checksum", .{ m.name, f.path });
            try file.setPermissions(t.io, .fromMode(@intCast(f.mode)));
            if (f.caps) |caps_hex| try setCapabilities(file, caps_hex);
        }
        try t.applyOwner(tmp, f);
        // Sealed under its temporary name, so the file is never visible
        // unsealed at its real path.
        if (t.seal) try t.sealFile(m, f, tmp);
        t.root.rename(tmp, t.root, path, t.io) catch |err|
            return t.fail(err, "{s}: cannot place {s}", .{ m.name, path });
    }

    fn sealFile(t: *Txn, m: Manifest, f: manifest_mod.File, on_disk: []const u8) !void {
        const signature = seal.parseSignature(f.seal orelse return) orelse
            return t.fail(error.InvalidPackage, "{s}: {s} has a malformed seal", .{ m.name, f.path });
        const ops = seal.operationsText(t.arena, m.operations, f.path) catch
            return t.fail(error.InvalidPackage, "{s}: invalid operations declaration", .{m.name});
        const value = try seal.attribute(t.arena, ops, signature);
        switch (seal.apply(t.io, t.root, on_disk, value, t.seal_attribute) catch |err|
            return t.fail(err, "{s}: cannot seal {s}", .{ m.name, f.path })) {
            .sealed => t.sealed += 1,
            .not_possible => t.unsealed += 1,
        }
    }

    /// Deletes what a departing package version owned and nothing now owns.
    fn removeObsolete(t: *Txn, old: Manifest) !void {
        var dirs: std.ArrayList([]const u8) = .empty;
        for (old.files) |f| {
            if (t.new_owner.contains(f.path)) continue;
            if (f.kind == .dir) {
                try dirs.append(t.arena, f.path);
                continue;
            }
            if (f.kind == .file and f.config and try t.onDisk(f.path, false) == .file) {
                const on_disk = try archive.hashFile(t.io, t.root, f.path);
                if (f.sha256 == null or !std.mem.eql(u8, &on_disk, f.sha256.?)) {
                    const saved = try std.fmt.allocPrint(t.arena, "{s}.davesave", .{f.path});
                    try t.root.rename(f.path, t.root, saved, t.io);
                    try t.note("{s}: had local changes; saved as {s}", .{ f.path, saved });
                    try t.changed.append(t.arena, f.path);
                    continue;
                }
            }
            t.root.deleteFile(t.io, f.path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            try t.changed.append(t.arena, f.path);
        }
        // Children before parents; a directory still in use simply stays.
        std.mem.sort([]const u8, dirs.items, {}, struct {
            fn longerFirst(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .gt;
            }
        }.longerFirst);
        for (dirs.items) |d| {
            t.root.deleteDir(t.io, d) catch |err| switch (err) {
                error.DirNotEmpty, error.FileNotFound => {},
                else => return err,
            };
        }
    }
};

fn setCapabilities(file: Io.File, caps_hex: []const u8) !void {
    var buf: [64]u8 = undefined;
    if (caps_hex.len % 2 != 0 or caps_hex.len / 2 > buf.len) return error.InvalidPackage;
    const value = std.fmt.hexToBytes(&buf, caps_hex) catch return error.InvalidPackage;
    const rc = linux.fsetxattr(file.handle, "security.capability", value.ptr, value.len, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SetCapabilitiesFailed;
}

pub fn apply(gpa: Allocator, arena: Allocator, io: Io, root: Io.Dir, plan: Plan, diag: *Diagnostic) !Result {
    var t: Txn = .{
        .gpa = gpa,
        .arena = arena,
        .io = io,
        .root = root,
        .diag = diag,
        .overwrite = plan.overwrite_unowned,
        .seal = plan.seal,
        .seal_attribute = plan.seal_attribute,
    };

    const installed = try db.load(arena, io, root);
    var installed_by_name: std.StringHashMapUnmanaged(Manifest) = .empty;
    for (installed) |m| {
        try installed_by_name.put(arena, m.name, m);
        for (m.files) |f| try t.old_owner.put(arena, f.path, .{ .pkg = m.name, .file = f });
    }

    // Phase 1: read every manifest and check everything, changing nothing.
    const incoming = try arena.alloc(Manifest, plan.install.len + plan.copy.len);
    var leaving: std.StringHashMapUnmanaged(void) = .empty;
    for (plan.install, incoming[0..plan.install.len]) |pf, *m| {
        m.* = archive.readManifestOf(gpa, arena, io, pf.dir, pf.sub_path) catch |err|
            return t.fail(err, "{s} is not a valid package", .{pf.sub_path});
    }
    for (plan.copy, incoming[plan.install.len..]) |c, *m| m.* = c.manifest;
    for (incoming) |m| {
        if (!arch.matches(m.arch))
            return t.fail(error.WrongArchitecture, "{s} {s} is a package for {s}, but this dave manages {s} systems", .{ m.name, m.version, m.arch, arch.name });
        if (leaving.contains(m.name)) return t.fail(error.InvalidPackage, "{s} appears twice in the transaction", .{m.name});
        try leaving.put(arena, m.name, {});
    }
    for (plan.remove) |name| {
        if (!installed_by_name.contains(name)) return t.fail(error.NotInstalled, "{s} is not installed", .{name});
        try leaving.put(arena, name, {});
    }
    for (installed) |m| {
        if (leaving.contains(m.name)) continue;
        for (m.files) |f| try t.claim(m.name, f);
    }
    for (incoming) |m| {
        for (m.files) |f| try t.claim(m.name, f);
    }
    if (!plan.overwrite_unowned) {
        for (incoming) |m| try t.checkDisk(m);
    }

    // Phase 2: write.
    var changes: std.ArrayList(Change) = .empty;
    for (0..incoming.len) |i| {
        const m = if (i < plan.install.len) try t.installPackage(plan.install[i]) else try t.installCopy(plan.copy[i - plan.install.len]);
        const old = installed_by_name.get(m.name);
        try changes.append(arena, .{ .name = m.name, .old_version = if (old) |o| o.version else null, .new_version = m.version });
        if (plan.progress) |p| p.report(p.context, i + 1, incoming.len, m.name);
    }
    for (incoming) |m| {
        if (installed_by_name.get(m.name)) |old| try t.removeObsolete(old);
    }
    for (plan.remove) |name| {
        const old = installed_by_name.get(name).?;
        try t.removeObsolete(old);
        try changes.append(arena, .{ .name = name, .old_version = old.version });
    }

    // Phase 3: record. The database changes last, so a failure above leaves it
    // describing the previous state.
    for (plan.remove) |name| try db.remove(arena, io, root, name);
    for (incoming) |m| try db.put(arena, io, root, m);
    _ = linux.syncfs(root.handle);

    return .{
        .changes = changes.items,
        .notes = t.notes.items,
        .changed_paths = t.changed.items,
        .sealed = t.sealed,
        .unsealed = t.unsealed,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    root: Io.Dir,
    diag: Diagnostic = .{},

    fn init(self: *Fixture) !void {
        self.arena_state = .init(testing.allocator);
        self.tmp = testing.tmpDir(.{ .iterate = true });
        try self.tmp.dir.createDirPath(testing.io, "root");
        self.root = try self.tmp.dir.openDir(testing.io, "root", .{ .iterate = true });
        self.diag = .{};
    }

    fn deinit(self: *Fixture) void {
        self.root.close(testing.io);
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    fn arena(self: *Fixture) Allocator {
        return self.arena_state.allocator();
    }

    const FileSpec = struct { path: []const u8, data: []const u8, mode: u32 = 0o644 };

    /// A package for the architecture dave manages, as `dave build` makes.
    fn pkg(self: *Fixture, meta: Manifest, files: []const FileSpec) !PackageFile {
        const a = self.arena();
        const stage_name = try std.fmt.allocPrint(a, "stage-{s}-{s}", .{ meta.name, meta.version });
        try self.tmp.dir.createDirPath(testing.io, stage_name);
        var stage = try self.tmp.dir.openDir(testing.io, stage_name, .{ .iterate = true });
        defer stage.close(testing.io);
        for (files) |f| {
            if (std.fs.path.dirname(f.path)) |parent| try stage.createDirPath(testing.io, parent);
            try stage.writeFile(testing.io, .{ .sub_path = f.path, .data = f.data });
            try stage.setFilePermissions(testing.io, f.path, .fromMode(@intCast(f.mode)), .{});
        }
        var for_here = meta;
        for_here.arch = arch.name;
        const name = try archive.pack(a, testing.io, .{ .meta = for_here, .src = stage, .out_dir = self.tmp.dir });
        return .{ .dir = self.tmp.dir, .sub_path = name };
    }

    fn run(self: *Fixture, plan: Plan) !Result {
        return apply(testing.allocator, self.arena(), testing.io, self.root, plan, &self.diag);
    }

    fn read(self: *Fixture, path: []const u8) ![]const u8 {
        return self.root.readFileAlloc(testing.io, path, self.arena(), .limited(1 << 20));
    }

    fn exists(self: *Fixture, path: []const u8) bool {
        _ = self.root.statFile(testing.io, path, .{ .follow_symlinks = false }) catch return false;
        return true;
    }
};

test "install, upgrade and remove" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const io = testing.io;

    const v1 = try fx.pkg(.{ .name = "hello", .version = "1.0-r1" }, &.{
        .{ .path = "usr/bin/hello", .data = "v1\n", .mode = 0o755 },
        .{ .path = "usr/share/hello/old.txt", .data = "only in v1\n" },
        .{ .path = "usr/share/hello/kept.txt", .data = "kept\n" },
    });
    const first = try fx.run(.{ .install = &.{v1} });
    try testing.expectEqual(@as(usize, 1), first.changes.len);
    try testing.expectEqual(@as(?[]const u8, null), first.changes[0].old_version);
    try testing.expectEqualStrings("v1\n", try fx.read("usr/bin/hello"));
    const st = try fx.root.statFile(io, "usr/bin/hello", .{});
    try testing.expectEqual(@as(u32, 0o755), st.permissions.toMode() & 0o7777);
    try testing.expectEqualStrings("1.0-r1", (try db.load(fx.arena(), io, fx.root))[0].version);

    const v2 = try fx.pkg(.{ .name = "hello", .version = "2.0-r1" }, &.{
        .{ .path = "usr/bin/hello", .data = "v2\n", .mode = 0o755 },
        .{ .path = "usr/share/hello/kept.txt", .data = "kept\n" },
        .{ .path = "usr/share/hello/new.txt", .data = "only in v2\n" },
    });
    const second = try fx.run(.{ .install = &.{v2} });
    try testing.expectEqualStrings("1.0-r1", second.changes[0].old_version.?);
    try testing.expectEqualStrings("2.0-r1", second.changes[0].new_version.?);
    try testing.expectEqualStrings("v2\n", try fx.read("usr/bin/hello"));
    try testing.expect(!fx.exists("usr/share/hello/old.txt"));
    try testing.expect(fx.exists("usr/share/hello/new.txt"));
    try testing.expect(!fx.exists("usr/bin/hello.dave-tmp"));

    _ = try fx.run(.{ .remove = &.{"hello"} });
    try testing.expect(!fx.exists("usr/bin/hello"));
    try testing.expect(!fx.exists("usr/share/hello"));
    try testing.expect(!fx.exists("usr/bin"));
    try testing.expectEqual(@as(usize, 0), (try db.load(fx.arena(), io, fx.root)).len);
}

test "shared directories survive removing one owner" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const a = try fx.pkg(.{ .name = "a", .version = "1-r1" }, &.{.{ .path = "usr/bin/a", .data = "a" }});
    const b = try fx.pkg(.{ .name = "b", .version = "1-r1" }, &.{.{ .path = "usr/bin/b", .data = "b" }});
    _ = try fx.run(.{ .install = &.{ a, b } });
    _ = try fx.run(.{ .remove = &.{"a"} });
    try testing.expect(!fx.exists("usr/bin/a"));
    try testing.expectEqualStrings("b", try fx.read("usr/bin/b"));
}

test "symlinks and hard links are recreated" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const io = testing.io;
    const a = fx.arena();

    try fx.tmp.dir.createDirPath(io, "stage/usr/bin");
    var stage = try fx.tmp.dir.openDir(io, "stage", .{ .iterate = true });
    defer stage.close(io);
    try stage.writeFile(io, .{ .sub_path = "usr/bin/tool", .data = "tool" });
    try stage.symLink(io, "tool", "usr/bin/alias", .{});
    try stage.hardLink("usr/bin/tool", stage, "usr/bin/twin", io, .{});
    const name = try archive.pack(a, io, .{ .meta = .{ .name = "links", .version = "1-r1", .arch = arch.name }, .src = stage, .out_dir = fx.tmp.dir });
    _ = try fx.run(.{ .install = &.{.{ .dir = fx.tmp.dir, .sub_path = name }} });

    var buf: [64]u8 = undefined;
    const n = try fx.root.readLink(io, "usr/bin/alias", &buf);
    try testing.expectEqualStrings("tool", buf[0..n]);
    const one = try fx.root.statFile(io, "usr/bin/tool", .{});
    const two = try fx.root.statFile(io, "usr/bin/twin", .{});
    try testing.expectEqual(one.inode, two.inode);
    try testing.expectEqualStrings("tool", try fx.read("usr/bin/twin"));
}

test "conflicts are detected before anything is written" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const io = testing.io;

    const a = try fx.pkg(.{ .name = "a", .version = "1-r1" }, &.{.{ .path = "usr/bin/tool", .data = "from a" }});
    const b = try fx.pkg(.{ .name = "b", .version = "1-r1" }, &.{
        .{ .path = "usr/bin/other", .data = "from b" },
        .{ .path = "usr/bin/tool", .data = "from b" },
    });
    try testing.expectError(error.FileConflict, fx.run(.{ .install = &.{ a, b } }));
    try testing.expect(std.mem.indexOf(u8, fx.diag.message, "usr/bin/tool") != null);
    try testing.expect(!fx.exists("usr"));

    // A file nobody owns is never silently overwritten.
    try fx.root.createDirPath(io, "usr/bin");
    try fx.root.writeFile(io, .{ .sub_path = "usr/bin/tool", .data = "mine" });
    try testing.expectError(error.FileConflict, fx.run(.{ .install = &.{a} }));
    try testing.expectEqualStrings("mine", try fx.read("usr/bin/tool"));

    try testing.expectError(error.NotInstalled, fx.run(.{ .remove = &.{"ghost"} }));
}

test "overwrite takes over files that belong to no package" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const io = testing.io;

    try fx.root.createDirPath(io, "usr/bin");
    try fx.root.createDirPath(io, "etc");
    try fx.root.writeFile(io, .{ .sub_path = "usr/bin/tool", .data = "temporary build" });
    try fx.root.writeFile(io, .{ .sub_path = "etc/tool.conf", .data = "temporary config" });
    const real = try fx.pkg(.{ .name = "tool", .version = "1-r1" }, &.{
        .{ .path = "usr/bin/tool", .data = "packaged" },
        .{ .path = "etc/tool.conf", .data = "packaged config" },
    });
    try testing.expectError(error.FileConflict, fx.run(.{ .install = &.{real} }));
    _ = try fx.run(.{ .install = &.{real}, .overwrite_unowned = true });
    try testing.expectEqualStrings("packaged", try fx.read("usr/bin/tool"));
    try testing.expectEqualStrings("packaged config", try fx.read("etc/tool.conf"));
    try testing.expect(!fx.exists("etc/tool.conf.davenew"));
    try testing.expectEqual(@as(usize, 1), (try db.load(fx.arena(), io, fx.root)).len);
}

test "files are sealed as they are installed" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const io = testing.io;
    const a = fx.arena();

    try fx.tmp.dir.createDirPath(io, "stage-sealed/usr/bin");
    try fx.tmp.dir.createDirPath(io, "stage-sealed/etc");
    var stage = try fx.tmp.dir.openDir(io, "stage-sealed", .{ .iterate = true });
    defer stage.close(io);
    try stage.writeFile(io, .{ .sub_path = "usr/bin/tool", .data = "the program" });
    try stage.writeFile(io, .{ .sub_path = "etc/tool.conf", .data = "editable" });
    const key = try seal.SigningKey.parse(&seal.generateKey(io).secret_hex);
    const name = try archive.pack(a, io, .{
        .meta = .{ .name = "tool", .version = "1-r1", .arch = arch.name, .operations = &.{.{ .allow = &.{ "net", "cap:net_admin" } }} },
        .src = stage,
        .out_dir = fx.tmp.dir,
        .code_key = key,
    });

    // Tests cannot write security.* attributes, so they use the user namespace.
    const attr = "user.joe-test";
    const result = try fx.run(.{ .install = &.{.{ .dir = fx.tmp.dir, .sub_path = name }}, .seal_attribute = attr });
    if (result.sealed == 0) return error.SkipZigTest; // no fs-verity on this file system
    try testing.expectEqual(@as(usize, 1), result.sealed);
    try testing.expectEqual(@as(usize, 0), result.unsealed);

    const m = (try db.load(a, io, fx.root))[0];
    var tool: ?manifest_mod.File = null;
    for (m.files) |f| {
        if (std.mem.eql(u8, f.path, "usr/bin/tool")) tool = f;
        // Configuration is never sealed: it has to stay editable.
        if (std.mem.eql(u8, f.path, "etc/tool.conf")) try testing.expect(f.seal == null);
    }
    const value = try seal.attribute(a, "net\ncap:12", seal.parseSignature(tool.?.seal.?).?);
    try testing.expect(seal.isApplied(io, fx.root, "usr/bin/tool", seal.parseDigest(tool.?.verity.?).?, value, attr));
    try testing.expect(try seal.verify(a, &key.publicHex(), seal.parseDigest(tool.?.verity.?).?, "net\ncap:12", seal.parseSignature(tool.?.seal.?).?));
    // The sealed program can be replaced or removed, but not modified in place.
    try testing.expect(std.meta.isError(fx.root.openFile(io, "usr/bin/tool", .{ .mode = .read_write })));
    try fx.root.writeFile(io, .{ .sub_path = "etc/tool.conf", .data = "edited" });
    _ = try fx.run(.{ .remove = &.{"tool"} });
    try testing.expect(!fx.exists("usr/bin/tool"));
}

test "locally edited configuration is preserved" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const io = testing.io;

    const v1 = try fx.pkg(.{ .name = "svc", .version = "1-r1" }, &.{
        .{ .path = "etc/svc.conf", .data = "default v1\n" },
        .{ .path = "etc/untouched.conf", .data = "default v1\n" },
        .{ .path = "etc/same.conf", .data = "never changes\n" },
    });
    _ = try fx.run(.{ .install = &.{v1} });
    try fx.root.writeFile(io, .{ .sub_path = "etc/svc.conf", .data = "edited by admin\n" });
    try fx.root.writeFile(io, .{ .sub_path = "etc/same.conf", .data = "edited by admin\n" });

    const v2 = try fx.pkg(.{ .name = "svc", .version = "2-r1" }, &.{
        .{ .path = "etc/svc.conf", .data = "default v2\n" },
        .{ .path = "etc/untouched.conf", .data = "default v2\n" },
        .{ .path = "etc/same.conf", .data = "never changes\n" },
    });
    const result = try fx.run(.{ .install = &.{v2} });
    // Edited and changed upstream: keep the edit, offer the new default.
    try testing.expectEqualStrings("edited by admin\n", try fx.read("etc/svc.conf"));
    try testing.expectEqualStrings("default v2\n", try fx.read("etc/svc.conf.davenew"));
    // Not edited: follows the package.
    try testing.expectEqualStrings("default v2\n", try fx.read("etc/untouched.conf"));
    // Edited, unchanged upstream: nothing to report.
    try testing.expectEqualStrings("edited by admin\n", try fx.read("etc/same.conf"));
    try testing.expect(!fx.exists("etc/same.conf.davenew"));
    try testing.expectEqual(@as(usize, 1), result.notes.len);

    const removed = try fx.run(.{ .remove = &.{"svc"} });
    try testing.expect(!fx.exists("etc/untouched.conf"));
    try testing.expectEqualStrings("edited by admin\n", try fx.read("etc/svc.conf.davesave"));
    try testing.expect(removed.notes.len >= 1);
}

test "a corrupted payload is rejected" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const io = testing.io;
    const a = fx.arena();

    // Build a package whose manifest promises different contents.
    var manifest: Manifest = .{ .name = "bad", .version = "1-r1", .arch = arch.name, .files = &.{
        .{ .path = "usr", .kind = .dir, .mode = 0o755 },
        .{ .path = "usr/evil", .size = 4, .sha256 = &archive.hashBytes("good") },
    } };
    manifest.format = manifest_mod.current_format;
    var text: Io.Writer.Allocating = .init(a);
    try manifest.write(&text.writer);
    {
        var out = try fx.tmp.dir.createFile(io, "bad.dave", .{});
        defer out.close(io);
        var child = try std.process.spawn(io, .{ .argv = &.{ "zstd", "-q", "-c" }, .stdin = .pipe, .stdout = .{ .file = out } });
        var buf: [4096]u8 = undefined;
        var pipe = child.stdin.?.writer(io, &buf);
        var tar: std.tar.Writer = .{ .underlying_writer = &pipe.interface };
        try tar.writeFileBytes(archive.manifest_member, text.written(), .{ .mode = 0o644 });
        try tar.writeFileBytes(archive.payload_prefix ++ "usr/evil", "EVIL", .{ .mode = 0o644 });
        try tar.finishPedantically();
        try pipe.interface.flush();
        child.stdin.?.close(io);
        child.stdin = null;
        _ = try child.wait(io);
    }
    try testing.expectError(error.InvalidPackage, fx.run(.{ .install = &.{.{ .dir = fx.tmp.dir, .sub_path = "bad.dave" }} }));
    try testing.expect(!fx.exists("usr/evil"));
    try testing.expect(!fx.exists("usr/evil.dave-tmp"));
    try testing.expectEqual(@as(usize, 0), (try db.load(a, io, fx.root)).len);
}

test "a package for another architecture is refused before anything is written" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const io = testing.io;
    const a = fx.arena();
    const other = if (arch.managed == .x86_64) "aarch64" else "x86_64";

    try fx.tmp.dir.createDirPath(io, "stage-foreign/usr/bin");
    var stage = try fx.tmp.dir.openDir(io, "stage-foreign", .{ .iterate = true });
    defer stage.close(io);
    try stage.writeFile(io, .{ .sub_path = "usr/bin/foreign", .data = "another machine's code" });
    const foreign = try archive.pack(a, io, .{ .meta = .{ .name = "foreign", .version = "1-r1", .arch = other }, .src = stage, .out_dir = fx.tmp.dir });
    try testing.expectEqualStrings("foreign-1-r1-" ++ other ++ ".dave", foreign);
    const hello = try fx.pkg(.{ .name = "hello", .version = "1.0-r1" }, &.{.{ .path = "usr/bin/hello", .data = "hello\n" }});

    try testing.expectError(error.WrongArchitecture, fx.run(.{ .install = &.{ hello, .{ .dir = fx.tmp.dir, .sub_path = foreign } } }));
    try testing.expectEqualStrings("foreign 1-r1 is a package for " ++ other ++ ", but this dave manages " ++ arch.name ++ " systems", fx.diag.message);
    try testing.expect(!fx.exists("usr"));
    try testing.expectEqual(@as(usize, 0), (try db.load(a, io, fx.root)).len);
    // The same is true of a package copied from another root.
    const m = try archive.readManifestOf(testing.allocator, a, io, fx.tmp.dir, foreign);
    try testing.expectError(error.WrongArchitecture, fx.run(.{ .copy = &.{.{ .manifest = m, .from = fx.tmp.dir }}, .seal = false }));
    _ = try fx.run(.{ .install = &.{hello} });
    try testing.expectEqualStrings("hello\n", try fx.read("usr/bin/hello"));
}

test "a package copied from the root it is installed in" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const io = testing.io;
    const a = fx.arena();

    const hello = try fx.pkg(.{ .name = "hello", .version = "1.0-r1" }, &.{
        .{ .path = "usr/bin/hello", .data = "hello\n", .mode = 0o755 },
        .{ .path = "etc/hello.conf", .data = "packaged\n" },
    });
    _ = try fx.run(.{ .install = &.{hello} });
    const m = (try db.load(a, io, fx.root))[0];
    // The source root has since changed its configuration file; the original
    // is kept elsewhere, under its checksum.
    try fx.root.writeFile(io, .{ .sub_path = "etc/hello.conf", .data = "changed here\n" });
    try fx.tmp.dir.createDirPath(io, "originals");
    var originals = try fx.tmp.dir.openDir(io, "originals", .{});
    defer originals.close(io);
    try originals.writeFile(io, .{ .sub_path = &archive.hashBytes("packaged\n"), .data = "packaged\n" });

    try fx.tmp.dir.createDirPath(io, "target");
    var target = try fx.tmp.dir.openDir(io, "target", .{ .iterate = true });
    defer target.close(io);
    const copy: Copy = .{ .manifest = m, .from = fx.root, .originals = originals };
    const result = try apply(testing.allocator, a, io, target, .{ .copy = &.{copy}, .seal = false }, &fx.diag);
    try testing.expectEqual(@as(usize, 1), result.changes.len);
    try testing.expectEqualStrings("hello\n", try target.readFileAlloc(io, "usr/bin/hello", a, .limited(64)));
    try testing.expectEqualStrings("packaged\n", try target.readFileAlloc(io, "etc/hello.conf", a, .limited(64)));
    const st = try target.statFile(io, "usr/bin/hello", .{});
    try testing.expectEqual(@as(u32, 0o755), st.permissions.toMode() & 0o7777);
    try testing.expectEqualStrings("1.0-r1", (try db.load(a, io, target))[0].version);

    // A file that differs from its manifest, with no original, is refused.
    try fx.root.writeFile(io, .{ .sub_path = "usr/bin/hello", .data = "tampered\n" });
    try fx.tmp.dir.createDirPath(io, "second");
    var second = try fx.tmp.dir.openDir(io, "second", .{ .iterate = true });
    defer second.close(io);
    try testing.expectError(error.InvalidPackage, apply(testing.allocator, a, io, second, .{ .copy = &.{copy}, .seal = false }, &fx.diag));
    try testing.expect(std.mem.indexOf(u8, fx.diag.message, "usr/bin/hello") != null);
    try testing.expectEqual(@as(usize, 0), (try db.load(a, io, second)).len);
}
