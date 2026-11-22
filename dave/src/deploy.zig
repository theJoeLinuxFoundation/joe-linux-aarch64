//! Deployments: the transactional half of joe Linux.
//!
//! The root filesystem is an ordinary, writable btrfs subvolume
//! `joe/deploy/<id>`. An upgrade never modifies it. Instead:
//!
//!   stage     solve, download, then prove the upgrade applies cleanly to a
//!             scratch snapshot, and record the plan. Nothing else changes; a
//!             power cut here boots the same system with the plan still pending.
//!   finalize  at shutdown, snapshot the root *as it is at that moment*, apply
//!             the recorded plan to the snapshot, and only then write its boot
//!             entry. Whatever was changed on the running system after staging
//!             is in the snapshot, so nothing is lost and nothing is merged.
//!
//! A failure at any point deletes the snapshot and leaves the running system
//! and its boot entry untouched. Health, fallback and rollback are delegated
//! to the boot loader as described in boot.zig.
//!
//! Triggers run in the snapshot through a chroot, where /var and /home are
//! covered by an empty tmpfs: at boot the shared subvolumes are mounted
//! there, so anything written to the snapshot's own directories would only
//! lie hidden under them. Without the cover, systemd-tmpfiles makes its
//! `Q /var/lib/machines` a subvolume nested in the snapshot, and the next
//! snapshot of that root is refused.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const btrfs = @import("btrfs.zig");
const boot = @import("boot.zig");
const db = @import("db.zig");
const txn = @import("txn.zig");
const triggers = @import("triggers.zig");
const manifest_mod = @import("manifest.zig");
const repo = @import("repo.zig");
const Version = @import("solver/version.zig").Version;

pub const deploy_dir = "joe/deploy";
/// Where a root keeps its processor microcode archive (cpu-microcode).
pub const microcode_path = "usr/lib/joe/microcode.img";
pub const state_path = "joe/state.zon";
pub const default_keep = 3;
const scratch_prefix = ".scratch-";
/// Subvolumes at the top level holding what every deployment shares, each
/// mounted on the directory of the same name in the running root.
pub const shared_subvolumes = [_][]const u8{ "var", "home" };

/// A recorded upgrade waiting for the next shutdown.
pub const Staged = struct {
    /// Package file names inside the cache's package directory.
    packages: []const []const u8 = &.{},
    remove: []const []const u8 = &.{},
    /// `db.stateHash` of the installed set the plan was solved against.
    db_hash: []const u8,
    summary: []const u8 = "",
};

pub const Record = struct {
    id: u32,
    parent: ?u32 = null,
    /// Seconds since the epoch.
    created: i64 = 0,
    pinned: bool = false,
    reason: []const u8 = "",
};

pub const FinalizeOutcome = struct {
    ok: bool,
    message: []const u8 = "",
    deployment: ?u32 = null,
};

/// Only what the boot loader does not already know. Everything here can be
/// rebuilt from the subvolumes and boot entries if the file is lost.
pub const State = struct {
    next_id: u32 = 1,
    deployments: []const Record = &.{},
    staged: ?Staged = null,
    last_finalize: ?FinalizeOutcome = null,
};

pub const System = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    /// The btrfs top level, opened with `.iterate = true`.
    top: Io.Dir,
    /// Absolute path at which `top` is mounted.
    top_path: []const u8,
    /// The EFI system partition, where the boot loader is.
    esp: Io.Dir,
    /// The extended boot loader partition (XBOOTLDR), where a system that
    /// shares its ESP with another operating system keeps its boot entries
    /// and kernels, so as never to crowd the other system's partition.
    /// Null when they are on the ESP.
    xbootldr: ?Io.Dir = null,
    /// The running root, opened with `.iterate = true`.
    root: Io.Dir,
    cache: Io.Dir,
    /// The deployment the system is running from.
    current: u32,
    self_exe: []const u8 = "/proc/self/exe",
    run_triggers: bool = true,
    /// Filled with the reason when an operation fails.
    diag: txn.Diagnostic = .{},

    /// Where boot entries and kernels are: the XBOOTLDR partition if there
    /// is one, the ESP otherwise. systemd-boot reads entries from both.
    pub fn bootDir(s: *const System) Io.Dir {
        return s.xbootldr orelse s.esp;
    }

    // -- state ----------------------------------------------------------------

    pub fn loadState(s: *System) !State {
        var state: State = .{};
        if (s.top.readFileAlloc(s.io, state_path, s.arena, .limited(16 * 1024 * 1024))) |text| {
            state = manifest_mod.parseZon(State, s.arena, text) catch .{};
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        // Never hand out an id that already exists on disk, whatever the file says.
        for (try s.deploymentIds()) |id| state.next_id = @max(state.next_id, id + 1);
        return state;
    }

    pub fn saveState(s: *System, state: State) !void {
        var text: Io.Writer.Allocating = .init(s.arena);
        try std.zon.stringify.serialize(state, .{}, &text.writer);
        try text.writer.writeByte('\n');
        try db.writeAtomic(s.arena, s.io, s.top, state_path, text.written());
    }

    /// Ids of the deployment subvolumes that exist, ascending.
    pub fn deploymentIds(s: *System) ![]u32 {
        var ids: std.ArrayList(u32) = .empty;
        var dir = try s.top.openDir(s.io, deploy_dir, .{ .iterate = true });
        defer dir.close(s.io);
        var it = dir.iterate();
        while (try it.next(s.io)) |e| {
            if (e.kind != .directory) continue;
            try ids.append(s.arena, std.fmt.parseInt(u32, e.name, 10) catch continue);
        }
        std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));
        return ids.items;
    }

    fn now(s: *System) i64 {
        return Io.Timestamp.now(s.io, .real).toSeconds();
    }

    fn fail(s: *System, err: anyerror, comptime fmt: []const u8, args: anytype) anyerror {
        s.diag.message = std.fmt.allocPrint(s.arena, fmt, args) catch "";
        return err;
    }

    // -- helpers --------------------------------------------------------------

    fn deployParent(s: *System) !Io.Dir {
        return s.top.openDir(s.io, deploy_dir, .{ .iterate = true });
    }

    fn currentEntry(s: *System, entries: []const boot.Entry) !boot.Entry {
        return boot.find(entries, s.current) orelse
            s.fail(error.NoCurrentEntry, "the running deployment {d} has no boot entry", .{s.current});
    }

    /// The initrds a deployment boots with: its processor microcode, if it
    /// has any, copied to the ESP.
    fn installInitrds(s: *System, root: Io.Dir) ![]const []const u8 {
        _ = root.statFile(s.io, microcode_path, .{}) catch return &.{};
        const path = try boot.installInitrd(s.arena, s.io, s.bootDir(), root, microcode_path);
        return s.arena.dupe([]const u8, &.{path});
    }

    pub fn findKernel(s: *System, root: Io.Dir) ![]const u8 {
        return findKernelIn(s.arena, s.io, root) catch |err| switch (err) {
            error.NoKernel => s.fail(error.NoKernel, "no kernel found under usr/lib/modules", .{}),
            else => err,
        };
    }

    /// The minimum a root needs before it is worth trying to boot.
    fn sanityCheck(s: *System, root: Io.Dir) !void {
        _ = try s.findKernel(root);
        _ = root.statFile(s.io, "usr/lib/systemd/systemd", .{}) catch
            return s.fail(error.NoInit, "the upgraded system would have no init (usr/lib/systemd/systemd)", .{});
        _ = try db.load(s.arena, s.io, root);
    }

    fn planFiles(s: *System, staged: Staged) ![]txn.PackageFile {
        const files = try s.arena.alloc(txn.PackageFile, staged.packages.len);
        for (staged.packages, files) |name, *f| {
            f.* = .{ .dir = s.cache, .sub_path = try std.fmt.allocPrint(s.arena, repo.packages_dir ++ "/{s}", .{name}) };
        }
        return files;
    }

    /// Applies `staged` to `target` (a snapshot) and runs triggers inside it.
    fn applyTo(s: *System, target: Io.Dir, target_name: []const u8, staged: Staged) !txn.Result {
        const have = try db.stateHash(s.arena, try db.load(s.arena, s.io, target));
        if (!std.mem.eql(u8, &have, staged.db_hash))
            return s.fail(error.StalePlan, "the installed packages changed since the upgrade was prepared", .{});
        const result = try txn.apply(s.gpa, s.arena, s.io, target, .{
            .install = try s.planFiles(staged),
            .remove = staged.remove,
        }, &s.diag);
        if (s.run_triggers) {
            const wanted = try triggers.matching(s.arena, try triggers.load(s.arena, s.io, target), result.changed_paths);
            triggers.run(s.arena, s.io, wanted, .{
                .root = target,
                .chroot_path = try std.fmt.allocPrint(s.arena, "{s}/" ++ deploy_dir ++ "/{s}", .{ s.top_path, target_name }),
                .self_exe = s.self_exe,
                .shared = &shared_subvolumes,
            }) catch |err| return s.fail(err, "a trigger failed in the upgraded system", .{});
        }
        try s.sanityCheck(target);
        return result;
    }

    /// A snapshot leaves out the subvolumes nested in the root, so a root with
    /// any is refused, naming them, once the hidden ones are gone.
    fn refuseNested(s: *System) !void {
        const visible = try s.removeHiddenSubvolumes();
        if (visible.len == 0) return;
        var names: Io.Writer.Allocating = .init(s.arena);
        for (visible, 0..) |path, i| try names.writer.print("{s}/{s}", .{ if (i > 0) ", " else "", path });
        return s.fail(error.NestedSubvolumes, "the root contains nested btrfs subvolumes ({s}), which a snapshot would not include; " ++
            "move them under /var or /home", .{names.written()});
    }

    /// Deletes the subvolumes nested in the running root beneath its /var and
    /// /home directories, and returns the paths of any others. Those beneath
    /// lie under the shared subvolumes mounted there, so nothing on the
    /// running system can reach them; dave 0.2.1 and earlier made them by
    /// running triggers without the cover described at the top of this file.
    pub fn removeHiddenSubvolumes(s: *System) ![]const []const u8 {
        const nested = try btrfs.nestedSubvolumes(s.arena, s.root);
        if (nested.len == 0) return nested;
        // Through the top level: from / they are covered by the mounts.
        const path = try std.fmt.allocPrint(s.arena, deploy_dir ++ "/{d}", .{s.current});
        var uncovered = try s.top.openDir(s.io, path, .{ .iterate = true });
        defer uncovered.close(s.io);
        var visible: std.ArrayList([]const u8) = .empty;
        for (nested) |sub| {
            if (underShared(sub)) {
                try btrfs.removeSubvolumeAt(s.io, uncovered, sub);
            } else {
                try visible.append(s.arena, sub);
            }
        }
        return visible.items;
    }

    // -- staging --------------------------------------------------------------

    /// Proves `staged` applies cleanly to the system as it is now, then records
    /// it for the next shutdown. The running system is not modified.
    pub fn stage(s: *System, staged: Staged) !txn.Result {
        try s.refuseNested();
        var parent = try s.deployParent();
        defer parent.close(s.io);
        const scratch = try std.fmt.allocPrint(s.arena, scratch_prefix ++ "{d}", .{s.now()});
        try btrfs.removeSubvolume(s.io, parent, scratch);
        try btrfs.snapshot(s.root, parent, scratch);
        defer btrfs.removeSubvolume(s.io, parent, scratch) catch {};
        var target = try parent.openDir(s.io, scratch, .{ .iterate = true });
        defer target.close(s.io);
        const result = try s.applyTo(target, scratch, staged);

        var state = try s.loadState();
        state.staged = staged;
        try s.saveState(state);
        return result;
    }

    pub fn unstage(s: *System) !void {
        var state = try s.loadState();
        if (state.staged == null) return;
        state.staged = null;
        try s.saveState(state);
    }

    // -- finalize -------------------------------------------------------------

    /// Turns a staged upgrade into a bootable deployment. Returns null when
    /// nothing is staged. Failure is recorded and reported, never propagated:
    /// this runs during shutdown, and the old system must still boot.
    pub fn finalize(s: *System) !?FinalizeOutcome {
        var state = try s.loadState();
        const staged = state.staged orelse return null;
        const id = state.next_id;

        const outcome: FinalizeOutcome = if (s.createDeployment(id, staged)) |_|
            .{ .ok = true, .deployment = id, .message = staged.summary }
        else |err|
            .{ .ok = false, .message = if (s.diag.message.len > 0)
                s.diag.message
            else
                try std.fmt.allocPrint(s.arena, "{t}", .{err}) };

        state = try s.loadState();
        state.staged = null;
        state.last_finalize = outcome;
        if (outcome.ok) {
            var records: std.ArrayList(Record) = .empty;
            try records.appendSlice(s.arena, state.deployments);
            try records.append(s.arena, .{ .id = id, .parent = s.current, .created = s.now(), .reason = staged.summary });
            state.deployments = records.items;
            state.next_id = @max(state.next_id, id + 1);
        }
        try s.saveState(state);
        return outcome;
    }

    fn discardDeployment(s: *System, parent: Io.Dir, name: []const u8, id: u32) void {
        // If the ESP cannot confirm the removal, its entry may still boot.
        boot.remove(s.arena, s.io, s.bootDir(), id) catch return;
        btrfs.removeSubvolume(s.io, parent, name) catch {};
    }

    fn createDeployment(s: *System, id: u32, staged: Staged) !void {
        try s.refuseNested();
        var parent = try s.deployParent();
        defer parent.close(s.io);
        const name = try std.fmt.allocPrint(s.arena, "{d}", .{id});

        try btrfs.snapshot(s.root, parent, name);
        errdefer s.discardDeployment(parent, name, id);
        var target = try parent.openDir(s.io, name, .{ .iterate = true });
        defer target.close(s.io);
        _ = try s.applyTo(target, name, staged);

        const kernel = try boot.installKernel(s.arena, s.io, s.bootDir(), target, try s.findKernel(target));
        const initrds = try s.installInitrds(target);
        _ = try boot.updateLoader(s.arena, s.io, s.esp, target);
        const entries = try boot.list(s.arena, s.io, s.bootDir());
        const current = try s.currentEntry(entries);
        try std.posix.syncfs(target.handle);
        // The entry is written last: until it exists, the loader knows nothing
        // of this deployment.
        try boot.write(s.arena, s.io, s.bootDir(), .{
            .id = id,
            .priority = boot.highestPriority(entries) + 1,
            .kernel = kernel,
            .initrds = initrds,
            .options = try boot.optionsFor(s.arena, current.options, id),
            .counted = true,
        });
    }

    // -- live changes -----------------------------------------------------------

    /// Before a change is applied to the running system: preserves the current
    /// state as a bootable deployment that `dave rollback` will return to.
    pub fn rollbackPoint(s: *System, reason: []const u8) !u32 {
        try s.refuseNested();
        const entries = try boot.list(s.arena, s.io, s.bootDir());
        const current = try s.currentEntry(entries);
        if (current.health() != .good)
            return s.fail(error.BootCheckPending, "this boot has not passed its health check yet; try again in a moment", .{});

        var state = try s.loadState();
        const id = state.next_id;
        var parent = try s.deployParent();
        defer parent.close(s.io);
        const name = try std.fmt.allocPrint(s.arena, "{d}", .{id});
        try btrfs.snapshot(s.root, parent, name);
        var backup_durable = false;
        errdefer if (!backup_durable) s.discardDeployment(parent, name, id);
        try std.posix.syncfs(parent.handle);

        // The preserved state ranks just below the running system: it is what
        // was chosen before, so it is what the loader falls back to.
        const top = boot.highestPriority(entries);
        try boot.write(s.arena, s.io, s.bootDir(), .{
            .id = id,
            .priority = top + 1,
            .kernel = current.kernel,
            .initrds = current.initrds,
            .options = try boot.optionsFor(s.arena, current.options, id),
            .counted = false,
        });
        // Keep the durable fallback even if replacing the running entry fails.
        backup_durable = true;
        try boot.write(s.arena, s.io, s.bootDir(), .{
            .id = s.current,
            .priority = top + 2,
            .kernel = current.kernel,
            .initrds = current.initrds,
            .options = current.options,
            .counted = false,
        });

        var records: std.ArrayList(Record) = .empty;
        try records.appendSlice(s.arena, state.deployments);
        try records.append(s.arena, .{ .id = id, .parent = s.current, .created = s.now(), .reason = reason });
        state.deployments = records.items;
        state.next_id = id + 1;
        try s.saveState(state);
        return id;
    }

    // -- rollback ---------------------------------------------------------------

    /// Makes the most recently chosen healthy deployment other than the running
    /// one the default for every following boot. Returns its id.
    pub fn rollback(s: *System) !u32 {
        const entries = try boot.list(s.arena, s.io, s.bootDir());
        const ids = try s.deploymentIds();
        const target = for (entries) |e| {
            if (e.id == s.current or e.health() != .good) continue;
            if (std.mem.indexOfScalar(u32, ids, e.id) == null) continue;
            break e;
        } else return s.fail(error.NoRollbackTarget, "there is no other healthy deployment to roll back to", .{});

        try boot.write(s.arena, s.io, s.bootDir(), .{
            .id = target.id,
            .priority = boot.highestPriority(entries) + 1,
            .kernel = target.kernel,
            .initrds = target.initrds,
            .options = target.options,
            .counted = false,
        });
        // A pending upgrade would otherwise take the default back at shutdown.
        try s.unstage();
        return target.id;
    }

    /// Login names of people who have an account in the running system but
    /// not in deployment `id`. `/etc` belongs to a deployment while `/home` is
    /// shared, so someone added since `id` was made cannot log in there.
    pub fn accountsMissingIn(s: *System, id: u32) ![]const []const u8 {
        const limit: Io.Limit = .limited(16 * 1024 * 1024);
        const here = s.root.readFileAlloc(s.io, "etc/passwd", s.arena, limit) catch return &.{};
        const path = try std.fmt.allocPrint(s.arena, deploy_dir ++ "/{d}/etc/passwd", .{id});
        const there = s.top.readFileAlloc(s.io, path, s.arena, limit) catch return &.{};
        return missingAccounts(s.arena, here, there);
    }

    // -- retention --------------------------------------------------------------

    pub fn setPinned(s: *System, id: u32, pinned: bool) !void {
        var state = try s.loadState();
        if (std.mem.indexOfScalar(u32, try s.deploymentIds(), id) == null)
            return s.fail(error.NoSuchDeployment, "there is no deployment {d}", .{id});
        var records: std.ArrayList(Record) = .empty;
        var found = false;
        for (state.deployments) |r| {
            var copy = r;
            if (r.id == id) {
                copy.pinned = pinned;
                found = true;
            }
            try records.append(s.arena, copy);
        }
        if (!found) try records.append(s.arena, .{ .id = id, .pinned = pinned });
        state.deployments = records.items;
        try s.saveState(state);
    }

    /// Deletes deployments that are no longer needed: everything except the
    /// running one, the next boot's default, untried ones, pinned ones, and the
    /// `keep` most recently chosen healthy ones. Returns the ids removed.
    pub fn collectGarbage(s: *System, keep: usize) ![]u32 {
        var state = try s.loadState();
        const entries = try boot.list(s.arena, s.io, s.bootDir());
        const ids = try s.deploymentIds();

        var keeping: std.AutoHashMapUnmanaged(u32, void) = .empty;
        try keeping.put(s.arena, s.current, {});
        if (boot.defaultEntry(entries)) |d| try keeping.put(s.arena, d.id, {});
        for (state.deployments) |r| if (r.pinned) try keeping.put(s.arena, r.id, {});
        var healthy: usize = 0;
        for (entries) |e| switch (e.health()) {
            .trial => try keeping.put(s.arena, e.id, {}),
            .good => if (healthy < keep) {
                healthy += 1;
                try keeping.put(s.arena, e.id, {});
            },
            .bad => {},
        };

        var parent = try s.deployParent();
        defer parent.close(s.io);
        var removed: std.ArrayList(u32) = .empty;
        // An entry must never outlive its subvolume, so entries go first.
        for (ids) |id| {
            if (keeping.contains(id)) continue;
            // Also flush a deletion a previous collection could not confirm.
            try boot.remove(s.arena, s.io, s.bootDir(), id);
            try btrfs.removeSubvolume(s.io, parent, try std.fmt.allocPrint(s.arena, "{d}", .{id}));
            try removed.append(s.arena, id);
        }
        // Entries pointing at subvolumes that do not exist can only fail to boot.
        for (entries) |e| {
            if (std.mem.indexOfScalar(u32, ids, e.id) == null) try boot.remove(s.arena, s.io, s.bootDir(), e.id);
        }
        // Scratch snapshots left behind by an interrupted `stage`.
        var doomed: std.ArrayList([]const u8) = .empty;
        var it = parent.iterate();
        while (try it.next(s.io)) |e| {
            if (std.mem.startsWith(u8, e.name, scratch_prefix)) try doomed.append(s.arena, try s.arena.dupe(u8, e.name));
        }
        for (doomed.items) |name| try btrfs.removeSubvolume(s.io, parent, name);

        try boot.pruneKernels(s.arena, s.io, s.bootDir(), try boot.list(s.arena, s.io, s.bootDir()), &.{});

        var records: std.ArrayList(Record) = .empty;
        for (state.deployments) |r| if (keeping.contains(r.id)) try records.append(s.arena, r);
        state.deployments = records.items;
        try s.saveState(state);
        return removed.items;
    }

    // -- inspection -------------------------------------------------------------

    pub const DeploymentView = struct {
        id: u32,
        running: bool,
        next_boot: bool,
        health: ?boot.Health,
        priority: ?u64,
        record: ?Record,
    };

    pub const Overview = struct {
        deployments: []const DeploymentView,
        staged: ?Staged,
        last_finalize: ?FinalizeOutcome,
    };

    pub fn overview(s: *System) !Overview {
        const state = try s.loadState();
        const entries = try boot.list(s.arena, s.io, s.bootDir());
        const default = boot.defaultEntry(entries);
        var views: std.ArrayList(DeploymentView) = .empty;
        for (try s.deploymentIds()) |id| {
            const entry = boot.find(entries, id);
            const record = for (state.deployments) |r| {
                if (r.id == id) break r;
            } else null;
            try views.append(s.arena, .{
                .id = id,
                .running = id == s.current,
                .next_boot = default != null and default.?.id == id,
                .health = if (entry) |e| e.health() else null,
                .priority = if (entry) |e| e.priority else null,
                .record = record,
            });
        }
        std.mem.sort(DeploymentView, views.items, {}, struct {
            fn lessThan(_: void, a: DeploymentView, b: DeploymentView) bool {
                return (a.priority orelse 0) > (b.priority orelse 0);
            }
        }.lessThan);
        return .{ .deployments = views.items, .staged = state.staged, .last_finalize = state.last_finalize };
    }
};

/// What `dave status` shows, as root publishes it for everyone else (main.zig
/// keeps it in /run/dave). Reading the original takes the top level of the
/// file system and the EFI system partition, which only root may open.
pub const Published = struct {
    /// The deployment that was running when this was written.
    running: u32,
    deployments: []const System.DeploymentView = &.{},
    staged: ?Staged = null,
    last_finalize: ?FinalizeOutcome = null,

    pub fn of(running: u32, view: System.Overview) Published {
        return .{ .running = running, .deployments = view.deployments, .staged = view.staged, .last_finalize = view.last_finalize };
    }

    pub fn overview(p: Published) System.Overview {
        return .{ .deployments = p.deployments, .staged = p.staged, .last_finalize = p.last_finalize };
    }

    pub fn serialize(p: Published, arena: Allocator) ![]const u8 {
        var text: Io.Writer.Allocating = .init(arena);
        try std.zon.stringify.serialize(p, .{}, &text.writer);
        try text.writer.writeByte('\n');
        return text.written();
    }

    pub fn parse(arena: Allocator, text: []const u8) !Published {
        return manifest_mod.parseZon(Published, arena, text);
    }
};

/// Whether a path relative to a deployment's root lies beneath one of the
/// directories the shared subvolumes are mounted on.
fn underShared(path: []const u8) bool {
    for (shared_subvolumes) |dir| {
        if (path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/') return true;
    }
    return false;
}

/// The name on a passwd line, if it is a person's account: system accounts
/// come and go with the packages that declare them and are not of interest.
/// The range is login.defs' UID_MIN to UID_MAX.
fn personOf(line: []const u8) ?[]const u8 {
    var fields = std.mem.splitScalar(u8, line, ':');
    const name = fields.next() orelse return null;
    _ = fields.next() orelse return null;
    const uid = std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch return null;
    return if (uid >= 1000 and uid <= 60000 and name.len > 0) name else null;
}

/// People with a line in the passwd text `here` and none in `there`.
fn missingAccounts(arena: Allocator, here: []const u8, there: []const u8) ![]const []const u8 {
    var missing: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, here, '\n');
    next: while (lines.next()) |line| {
        const name = personOf(line) orelse continue;
        var others = std.mem.tokenizeScalar(u8, there, '\n');
        while (others.next()) |other| {
            if (other.len > name.len and other[name.len] == ':' and std.mem.startsWith(u8, other, name)) continue :next;
        }
        try missing.append(arena, name);
    }
    return missing.items;
}

/// The kernel image of a root: `usr/lib/modules/<version>/vmlinuz`, taking
/// the newest version if there are several.
pub fn findKernelIn(arena: Allocator, io: Io, root: Io.Dir) ![]const u8 {
    var best: ?[]const u8 = null;
    var modules = root.openDir(io, "usr/lib/modules", .{ .iterate = true }) catch return error.NoKernel;
    defer modules.close(io);
    var it = modules.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .directory) continue;
        const candidate = try std.fmt.allocPrint(arena, "{s}/vmlinuz", .{e.name});
        _ = modules.statFile(io, candidate, .{}) catch continue;
        const name = try arena.dupe(u8, e.name);
        if (best == null or newerKernel(name, best.?)) best = name;
    }
    const version = best orelse return error.NoKernel;
    return std.fmt.allocPrint(arena, "usr/lib/modules/{s}/vmlinuz", .{version});
}

fn newerKernel(a: []const u8, b: []const u8) bool {
    const va = Version.parse(upstreamPart(a)) catch return std.mem.order(u8, a, b) == .gt;
    const vb = Version.parse(upstreamPart(b)) catch return std.mem.order(u8, a, b) == .gt;
    return va.order(vb) == .gt;
}

/// Kernel release strings contain characters versions do not ("7.3.1-joe").
fn upstreamPart(release: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, release, "-~") orelse release.len;
    return release[0..end];
}

// ---------------------------------------------------------------------------
// Tests: a complete system in a temporary directory, unprivileged.
// ---------------------------------------------------------------------------

const testing = std.testing;
const archive = @import("archive.zig");
const arch = @import("arch.zig");

const Fixture = struct {
    arena_state: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    sys: System,
    package_count: usize = 0,

    const options = "root=PARTUUID=abc rootfstype=btrfs rootflags=subvol=joe/deploy/1 rw rootwait panic=10";

    /// Returns false if the test directory is not on btrfs.
    fn init(self: *Fixture) !bool {
        const io = testing.io;
        self.arena_state = .init(testing.allocator);
        self.tmp = testing.tmpDir(.{ .iterate = true });
        self.package_count = 0;
        const arena = self.arena_state.allocator();
        try self.tmp.dir.createDirPath(io, "top/" ++ deploy_dir);
        try self.tmp.dir.createDirPath(io, "esp");
        try self.tmp.dir.createDirPath(io, "cache/" ++ repo.packages_dir);
        var parent = try self.tmp.dir.openDir(io, "top/" ++ deploy_dir, .{ .iterate = true });
        defer parent.close(io);
        btrfs.createSubvolume(parent, "1") catch |err| switch (err) {
            error.NotBtrfs => {
                self.tmp.cleanup();
                self.arena_state.deinit();
                return false;
            },
            else => return err,
        };
        self.sys = .{
            .gpa = testing.allocator,
            .arena = arena,
            .io = io,
            .top = try self.tmp.dir.openDir(io, "top", .{ .iterate = true }),
            .top_path = "/nonexistent",
            .esp = try self.tmp.dir.openDir(io, "esp", .{ .iterate = true }),
            .root = try parent.openDir(io, "1", .{ .iterate = true }),
            .cache = try self.tmp.dir.openDir(io, "cache", .{ .iterate = true }),
            .current = 1,
            .run_triggers = false,
        };
        const root = self.sys.root;
        try root.createDirPath(io, "usr/lib/modules/7.3.1-joe");
        try root.createDirPath(io, "usr/lib/systemd");
        try root.createDirPath(io, "etc");
        try root.writeFile(io, .{ .sub_path = "usr/lib/modules/7.3.1-joe/vmlinuz", .data = "kernel 7.3.1" });
        try root.writeFile(io, .{ .sub_path = "usr/lib/systemd/systemd", .data = "init" });
        const kernel = try boot.installKernel(arena, io, self.sys.esp, root, "usr/lib/modules/7.3.1-joe/vmlinuz");
        try boot.write(arena, io, self.sys.esp, .{ .id = 1, .priority = 1, .kernel = kernel, .options = options, .counted = false });
        return true;
    }

    fn deinit(self: *Fixture) void {
        const io = testing.io;
        // Subvolumes cannot be removed by a plain recursive delete of their parent.
        if (self.sys.deploymentIds()) |ids| {
            var parent = self.sys.deployParent() catch unreachable;
            defer parent.close(io);
            for (ids) |id| {
                var buf: [16]u8 = undefined;
                btrfs.removeSubvolume(io, parent, std.fmt.bufPrint(&buf, "{d}", .{id}) catch unreachable) catch {};
            }
        } else |_| {}
        self.sys.top.close(io);
        self.sys.esp.close(io);
        self.sys.root.close(io);
        self.sys.cache.close(io);
        self.tmp.cleanup();
        self.arena_state.deinit();
    }

    /// Builds a one-file package in the cache and returns its file name.
    fn package(self: *Fixture, name: []const u8, version: []const u8, path: []const u8, data: []const u8) ![]const u8 {
        const io = testing.io;
        const arena = self.arena_state.allocator();
        self.package_count += 1;
        const stage_name = try std.fmt.allocPrint(arena, "stage-{d}", .{self.package_count});
        try self.tmp.dir.createDirPath(io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ stage_name, std.fs.path.dirname(path).? }));
        var stage_dir = try self.tmp.dir.openDir(io, stage_name, .{ .iterate = true });
        defer stage_dir.close(io);
        try stage_dir.writeFile(io, .{ .sub_path = path, .data = data });
        var pkgs = try self.sys.cache.openDir(io, repo.packages_dir, .{});
        defer pkgs.close(io);
        return archive.pack(arena, io, .{ .meta = .{ .name = name, .version = version, .arch = arch.name }, .src = stage_dir, .out_dir = pkgs });
    }

    fn plan(self: *Fixture, packages: []const []const u8, summary: []const u8) !Staged {
        const arena = self.arena_state.allocator();
        const hash = try db.stateHash(arena, try db.load(arena, testing.io, self.sys.root));
        return .{ .packages = packages, .db_hash = try arena.dupe(u8, &hash), .summary = summary };
    }

    fn read(self: *Fixture, comptime fmt: []const u8, args: anytype) ![]const u8 {
        const arena = self.arena_state.allocator();
        return self.sys.top.readFileAlloc(testing.io, try std.fmt.allocPrint(arena, fmt, args), arena, .limited(1 << 20));
    }

    fn installLive(self: *Fixture, file: []const u8) !void {
        const arena = self.arena_state.allocator();
        var diag: txn.Diagnostic = .{};
        _ = try txn.apply(testing.allocator, arena, testing.io, self.sys.root, .{
            .install = &.{.{ .dir = self.sys.cache, .sub_path = try std.fmt.allocPrint(arena, repo.packages_dir ++ "/{s}", .{file}) }},
        }, &diag);
    }
};

test "an upgrade is staged, finalized into a new deployment, and the running root is untouched" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const io = testing.io;
    const s = &fx.sys;

    try fx.installLive(try fx.package("hello", "1.0-r1", "usr/bin/hello", "v1"));
    const v2 = try fx.package("hello", "2.0-r1", "usr/bin/hello", "v2");

    _ = try s.stage(try fx.plan(&.{v2}, "hello 1.0-r1 -> 2.0-r1"));
    // Staging changed nothing visible: same root, same single entry, no leftovers.
    try testing.expectEqualStrings("v1", try fx.read(deploy_dir ++ "/1/usr/bin/hello", .{}));
    try testing.expectEqual(@as(usize, 1), (try boot.list(s.arena, io, s.esp)).len);
    try testing.expectEqual(@as(usize, 1), (try s.deploymentIds()).len);
    try testing.expect((try s.loadState()).staged != null);

    // Something the administrator does after staging and before rebooting.
    try s.root.writeFile(io, .{ .sub_path = "etc/late-edit", .data = "made after staging" });

    const outcome = (try s.finalize()).?;
    try testing.expect(outcome.ok);
    try testing.expectEqual(@as(?u32, 2), outcome.deployment);

    try testing.expectEqualStrings("v1", try fx.read(deploy_dir ++ "/1/usr/bin/hello", .{}));
    try testing.expectEqualStrings("v2", try fx.read(deploy_dir ++ "/2/usr/bin/hello", .{}));
    try testing.expectEqualStrings("made after staging", try fx.read(deploy_dir ++ "/2/etc/late-edit", .{}));

    const entries = try boot.list(s.arena, io, s.esp);
    const new = boot.defaultEntry(entries).?;
    try testing.expectEqual(@as(u32, 2), new.id);
    try testing.expectEqual(boot.Health.trial, new.health());
    try testing.expect(std.mem.indexOf(u8, new.options, "subvol=joe/deploy/2 ") != null);
    try testing.expectEqual(boot.Health.good, boot.find(entries, 1).?.health());

    const state = try s.loadState();
    try testing.expect(state.staged == null);
    try testing.expect(state.last_finalize.?.ok);
    try testing.expectEqual(@as(u32, 3), state.next_id);
    try testing.expectEqual(@as(?FinalizeOutcome, null), try s.finalize());
}

test "a failed finalize leaves no trace and the old system boots" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const io = testing.io;
    const s = &fx.sys;

    try fx.installLive(try fx.package("hello", "1.0-r1", "usr/bin/hello", "v1"));
    const v2 = try fx.package("hello", "2.0-r1", "usr/bin/hello", "v2");
    _ = try s.stage(try fx.plan(&.{v2}, "hello upgrade"));

    // The package file is damaged between staging and shutdown.
    try s.cache.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(s.arena, repo.packages_dir ++ "/{s}", .{v2}), .data = "corrupt" });
    const outcome = (try s.finalize()).?;
    try testing.expect(!outcome.ok);
    try testing.expect(outcome.message.len > 0);

    try testing.expectEqual(@as(usize, 1), (try s.deploymentIds()).len);
    const entries = try boot.list(s.arena, io, s.esp);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqual(@as(u32, 1), boot.defaultEntry(entries).?.id);
    const state = try s.loadState();
    try testing.expect(state.staged == null);
    try testing.expect(!state.last_finalize.?.ok);
}

test "a plan is refused once the installed packages have changed under it" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const s = &fx.sys;

    try fx.installLive(try fx.package("hello", "1.0-r1", "usr/bin/hello", "v1"));
    const v2 = try fx.package("hello", "2.0-r1", "usr/bin/hello", "v2");
    _ = try s.stage(try fx.plan(&.{v2}, "hello upgrade"));
    try fx.installLive(try fx.package("other", "1.0-r1", "usr/bin/other", "x"));

    const outcome = (try s.finalize()).?;
    try testing.expect(!outcome.ok);
    try testing.expect(std.mem.indexOf(u8, outcome.message, "changed since") != null);
    try testing.expectEqual(@as(usize, 1), (try s.deploymentIds()).len);
}

test "staging rejects an upgrade that would not boot" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const s = &fx.sys;

    // Hand the kernel and init to packages, then stage their removal.
    try s.root.deleteFile(testing.io, "usr/lib/systemd/systemd");
    try fx.installLive(try fx.package("systemd", "262-r1", "usr/lib/systemd/systemd", "init"));
    var staged = try fx.plan(&.{}, "remove systemd");
    staged.remove = &.{"systemd"};
    try testing.expectError(error.NoInit, s.stage(staged));
    try testing.expect((try s.loadState()).staged == null);
    try testing.expectEqual(@as(usize, 1), (try s.deploymentIds()).len);
}

test "a rollback point preserves the state before a live change, and rollback returns to it" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const io = testing.io;
    const s = &fx.sys;

    const point = try s.rollbackPoint("before: dave install hello");
    try fx.installLive(try fx.package("hello", "1.0-r1", "usr/bin/hello", "v1"));

    try testing.expectEqual(@as(u32, 2), point);
    try testing.expectEqualStrings("v1", try fx.read(deploy_dir ++ "/1/usr/bin/hello", .{}));
    try testing.expectError(error.FileNotFound, s.top.statFile(io, deploy_dir ++ "/2/usr/bin/hello", .{}));

    var entries = try boot.list(s.arena, io, s.esp);
    // Still booting the running system; the preserved state is next in line.
    try testing.expectEqual(@as(u32, 1), entries[0].id);
    try testing.expectEqual(@as(u32, 2), entries[1].id);
    try testing.expectEqual(boot.Health.good, entries[1].health());

    try testing.expectEqual(@as(u32, 2), try s.rollback());
    entries = try boot.list(s.arena, io, s.esp);
    try testing.expectEqual(@as(u32, 2), boot.defaultEntry(entries).?.id);

    // After rebooting into 2, rolling back again returns to 1.
    s.current = 2;
    try testing.expectEqual(@as(u32, 1), try s.rollback());
}

test "rollback discards a pending upgrade and skips unhealthy deployments" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const io = testing.io;
    const s = &fx.sys;

    try testing.expectError(error.NoRollbackTarget, s.rollback());

    try fx.installLive(try fx.package("hello", "1.0-r1", "usr/bin/hello", "v1"));
    _ = try s.stage(try fx.plan(&.{try fx.package("hello", "2.0-r1", "usr/bin/hello", "v2")}, "up"));
    _ = (try s.finalize()).?;
    // Deployment 2 exists but has never booted: it is not a rollback target.
    try testing.expectError(error.NoRollbackTarget, s.rollback());

    // Pretend 2 booted and was blessed, and we are now running it.
    try s.esp.rename(boot.entries_dir ++ "/joe-2+3.conf", s.esp, boot.entries_dir ++ "/joe-2.conf", io);
    s.current = 2;
    s.root.close(io);
    s.root = try s.top.openDir(io, deploy_dir ++ "/2", .{ .iterate = true });
    _ = try s.stage(try fx.plan(&.{try fx.package("hello", "3.0-r1", "usr/bin/hello", "v3")}, "up again"));
    try testing.expectEqual(@as(u32, 1), try s.rollback());
    try testing.expect((try s.loadState()).staged == null);
}

test "an upgrade brings a newer boot loader to the ESP" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const io = testing.io;
    const s = &fx.sys;
    const old = "MZ #### LoaderInfo: systemd-boot 262.1 ####";
    const new = "MZ #### LoaderInfo: systemd-boot 263 ####";

    try s.esp.createDirPath(io, "EFI/systemd");
    try s.esp.createDirPath(io, "EFI/BOOT");
    for (boot.loader_targets) |target| try s.esp.writeFile(io, .{ .sub_path = target, .data = old });
    try fx.installLive(try fx.package("systemd-boot", "262.1-r1", boot.loader_source, old));

    _ = try s.stage(try fx.plan(&.{try fx.package("systemd-boot", "263-r1", boot.loader_source, new)}, "systemd-boot"));
    // Staging is a rehearsal: the ESP is not touched.
    try testing.expectEqualStrings(old, try s.esp.readFileAlloc(io, boot.loader_targets[0], s.arena, .limited(1 << 20)));
    try testing.expect((try s.finalize()).?.ok);
    for (boot.loader_targets) |target|
        try testing.expectEqualStrings(new, try s.esp.readFileAlloc(io, target, s.arena, .limited(1 << 20)));
}

test "rollback names the people whose accounts the target lacks" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const io = testing.io;
    const s = &fx.sys;
    const base =
        \\root:x:0:0:root:/root:/bin/bash
        \\gdm:x:21:21:GNOME Display Manager:/var/lib/gdm:/bin/false
        \\ann:x:1000:1000:Ann:/home/ann:/bin/bash
        \\nobody:x:65534:65534:Unprivileged User:/dev/null:/bin/false
        \\
    ;
    try s.root.writeFile(io, .{ .sub_path = "etc/passwd", .data = base });
    const point = try s.rollbackPoint("before: dave install hello");
    try testing.expectEqual(@as(usize, 0), (try s.accountsMissingIn(point)).len);

    // A person and a system account are added after the snapshot; `an` must
    // not be taken for `ann`.
    try s.root.writeFile(io, .{ .sub_path = "etc/passwd", .data = base ++
        "colord:x:71:71::/var/lib/colord:/bin/false\nbob:x:1001:1001::/home/bob:/bin/bash\nan:x:1002:1002::/home/an:/bin/bash\n" });
    const missing = try s.accountsMissingIn(point);
    try testing.expectEqual(@as(usize, 2), missing.len);
    try testing.expectEqualStrings("bob", missing[0]);
    try testing.expectEqualStrings("an", missing[1]);
    // A deployment that cannot be read is no reason to refuse a rollback.
    try testing.expectEqual(@as(usize, 0), (try s.accountsMissingIn(99)).len);
}

test "garbage collection keeps what matters and removes the rest" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const io = testing.io;
    const s = &fx.sys;

    // Deployments 2..6 as rollback points; 1 stays the running system.
    for (0..5) |_| _ = try s.rollbackPoint("point");
    try testing.expectEqual(@as(usize, 6), (try s.deploymentIds()).len);
    try s.setPinned(2, true);
    // Deployment 4 failed all its boot attempts.
    try s.esp.rename(boot.entries_dir ++ "/joe-4.conf", s.esp, boot.entries_dir ++ "/joe-4+0-3.conf", io);
    // A subvolume with no entry: a deployment that never completed.
    var parent = try s.deployParent();
    defer parent.close(io);
    try btrfs.snapshot(s.root, parent, "99");
    try btrfs.snapshot(s.root, parent, scratch_prefix ++ "old");

    const removed = try s.collectGarbage(2);
    const ids = try s.deploymentIds();
    // Kept: 1 (running, newest), 6 (newest point), 2 (pinned). 3, 5 exceed the
    // limit of two healthy deployments; 4 is bad; 99 never completed.
    try testing.expectEqualSlices(u32, &.{ 1, 2, 6 }, ids);
    try testing.expectEqual(@as(usize, 4), removed.len);
    try testing.expectError(error.FileNotFound, parent.statFile(io, scratch_prefix ++ "old", .{}));
    const entries = try boot.list(s.arena, io, s.esp);
    try testing.expectEqual(@as(usize, 3), entries.len);
    for (entries) |e| try testing.expect(std.mem.indexOfScalar(u32, ids, e.id) != null);
    // Records survive only for deployments that still exist (2 and 6; 1 never had one).
    try testing.expectEqual(@as(usize, 2), (try s.loadState()).deployments.len);

    const view = try s.overview();
    try testing.expectEqual(@as(usize, 3), view.deployments.len);
    try testing.expect(view.deployments[0].running and view.deployments[0].next_boot);
}

test "subvolumes hidden under /var are removed before a snapshot, and others are refused by name" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const io = testing.io;
    const s = &fx.sys;

    // What an upgrade by dave 0.2.1 left in the deployment it made.
    try s.root.createDirPath(io, "var/lib");
    var lib = try s.root.openDir(io, "var/lib", .{ .iterate = true });
    defer lib.close(io);
    try btrfs.createSubvolume(lib, "machines");
    try btrfs.createSubvolume(lib, "portables");
    // One the administrator made, which a snapshot would lose.
    try s.root.createDirPath(io, "opt");
    var opt = try s.root.openDir(io, "opt", .{ .iterate = true });
    defer opt.close(io);
    try btrfs.createSubvolume(opt, "data");

    try testing.expectError(error.NestedSubvolumes, s.rollbackPoint("before: dave install hello"));
    try testing.expect(std.mem.indexOf(u8, s.diag.message, "(/opt/data)") != null);
    try testing.expectError(error.FileNotFound, lib.statFile(io, "machines", .{}));
    try testing.expectError(error.FileNotFound, lib.statFile(io, "portables", .{}));
    try testing.expectEqual(@as(usize, 1), (try s.deploymentIds()).len);

    try btrfs.removeSubvolume(io, opt, "data");
    try testing.expectEqual(@as(u32, 2), try s.rollbackPoint("before: dave install hello"));

    try testing.expect(underShared("var/lib/machines"));
    try testing.expect(underShared("home/ann/vm"));
    // The mount points themselves are part of the root.
    try testing.expect(!underShared("var"));
    try testing.expect(!underShared("various/x"));
}

test "garbage collection removes snapshots with subvolumes inside them" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const io = testing.io;
    const s = &fx.sys;

    var parent = try s.deployParent();
    defer parent.close(io);
    // A deployment that never completed, and a staging rehearsal's leftover,
    // each holding a subvolume as dave 0.2.1's triggers made them.
    const doomed = [_][]const u8{ "99", scratch_prefix ++ "old" };
    for (doomed) |name| {
        try btrfs.snapshot(s.root, parent, name);
        var sub = try parent.openDir(io, name, .{ .iterate = true });
        defer sub.close(io);
        try sub.createDirPath(io, "var/lib");
        var lib = try sub.openDir(io, "var/lib", .{ .iterate = true });
        defer lib.close(io);
        try btrfs.createSubvolume(lib, "machines");
    }

    const removed = try s.collectGarbage(default_keep);
    try testing.expectEqualSlices(u32, &.{99}, removed);
    for (doomed) |name| try testing.expectError(error.FileNotFound, parent.statFile(io, name, .{}));
}

test "the published status reads back as it was written" {
    var fx: Fixture = undefined;
    if (!try fx.init()) return error.SkipZigTest;
    defer fx.deinit();
    const s = &fx.sys;

    _ = try s.rollbackPoint("before: dave install hello");
    try s.setPinned(2, true);
    try fx.installLive(try fx.package("hello", "1.0-r1", "usr/bin/hello", "v1"));
    _ = try s.stage(try fx.plan(&.{try fx.package("hello", "2.0-r1", "usr/bin/hello", "v2")}, "1 to install or upgrade, 0 to remove"));

    const view = try s.overview();
    const back = try Published.parse(s.arena, try Published.of(1, view).serialize(s.arena));
    try testing.expectEqual(@as(u32, 1), back.running);
    try testing.expectEqual(view.deployments.len, back.deployments.len);
    for (view.deployments, back.deployments) |a, b| {
        try testing.expectEqual(a.id, b.id);
        try testing.expectEqual(a.running, b.running);
        try testing.expectEqual(a.next_boot, b.next_boot);
        try testing.expectEqual(a.health, b.health);
        try testing.expectEqual(a.priority, b.priority);
        try testing.expectEqual(a.record != null, b.record != null);
        if (a.record) |r| {
            try testing.expectEqualStrings(r.reason, b.record.?.reason);
            try testing.expectEqual(r.pinned, b.record.?.pinned);
        }
    }
    try testing.expectEqualStrings(view.staged.?.summary, back.staged.?.summary);
    try testing.expect(back.last_finalize == null);
}
