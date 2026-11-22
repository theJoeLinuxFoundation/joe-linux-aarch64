//! dave: the joe Linux package manager.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

pub const version = @import("solver/version.zig");
pub const range = @import("solver/range.zig");
pub const pubgrub = @import("solver/pubgrub.zig");
pub const report = @import("solver/report.zig");
pub const manifest = @import("manifest.zig");
pub const archive = @import("archive.zig");
pub const db = @import("db.zig");
pub const txn = @import("txn.zig");
pub const repo = @import("repo.zig");
pub const resolve = @import("resolve.zig");
pub const btrfs = @import("btrfs.zig");
pub const boot = @import("boot.zig");
pub const triggers = @import("triggers.zig");
pub const deploy = @import("deploy.zig");
pub const builder = @import("builder.zig");
pub const seal = @import("seal.zig");
pub const provision = @import("provision.zig");
pub const image = @import("image.zig");
pub const cpio = @import("cpio.zig");
pub const iso = @import("iso.zig");
pub const oci = @import("oci.zig");
pub const command = @import("command.zig");
pub const install_system = @import("install_system.zig");
pub const efiboot = @import("efiboot.zig");
pub const cli = @import("cli.zig");
pub const help = @import("help.zig");
pub const ui = @import("ui.zig");
pub const suggest = @import("suggest.zig");
pub const errors = @import("errors.zig");
pub const query = @import("query.zig");
pub const plan = @import("plan.zig");
pub const arch = @import("arch.zig");

const dave_version = "0.3.0";
const top_mount = "/run/dave/top";
const lock_path = "/run/dave/lock";
/// What `dave status` shows, written by root for everyone (deploy.Published).
const status_path = "/run/dave/status.zon";
const esp_path = "/efi";
const boot_mount = "/boot";
const system_cache = "/var/cache/dave";
const boot_check_hooks = "etc/dave/boot-check.d";
const sealed_marker = "usr/lib/dave/sealed";

const Failure = error{Reported};

const App = struct {
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    opts: cli.Options = .{},
    /// What can be done with the terminal, if there is one (ui.zig).
    caps: ui.Caps = .{},
    /// The line drawn over as work proceeds, on a terminal.
    line: ui.Line = .{},
    /// The arguments dave was started with, for re-executing itself.
    argv: []const []const u8 = &.{},
    /// The environment of programs dave runs; null leaves them dave's own.
    environ: ?*std.process.Environ.Map = null,
    /// With --json, where events go (standard output); `out` then carries
    /// what is said for people, on standard error.
    events: ?*Io.Writer = null,
    /// Whether transactions seal what they install. An image build does not:
    /// built without privileges, it cannot write the seals (the image's first
    /// boot does, dave-seal.service), and enabling fs-verity alone on the
    /// build's own files only made them read back with I/O errors on some
    /// kernels, which mksquashfs turned into empty files.
    seal: bool = true,
    /// The last failure, for the error event.
    last_error: []const u8 = "",
    /// Set once the running system's deployments have been opened, so that
    /// what `dave status` shows is published again before dave exits.
    opened_system: bool = false,

    // -- reporting ------------------------------------------------------------

    /// Prints a message for the user and returns the error that ends the command.
    fn fail(app: *App, comptime fmt: []const u8, args: anytype) Failure {
        app.complain(fmt, args);
        return error.Reported;
    }

    /// Says what went wrong, as fail() does, but lets the command go on.
    fn complain(app: *App, comptime fmt: []const u8, args: anytype) void {
        app.last_error = std.fmt.allocPrint(app.arena, fmt, args) catch "out of memory";
        app.warn(app.last_error);
    }

    /// A line on standard error, after the failure that last_error records.
    fn warn(app: *App, text: []const u8) void {
        app.line.clear(app.out);
        app.err.print("{f} {s}\n", .{ ui.paint(app.caps.err_color, .failure, "dave:"), text }) catch {};
        app.err.flush() catch {};
    }

    /// fail(), saying in words what `err` means (errors.zig).
    fn failErr(app: *App, err: anyerror, comptime fmt: []const u8, args: anytype) Failure {
        var buf: [256]u8 = undefined;
        const what = std.fmt.allocPrint(app.arena, fmt, args) catch "out of memory";
        return app.fail("{s}: {s}", .{ what, errors.text(&buf, err) });
    }

    /// One JSON object on a line of its own, for a program watching dave
    /// (the installer). A reader that has gone away must not stop the work
    /// it was watching, so writing errors are ignored.
    fn event(app: *App, kind: []const u8, message: []const u8, fraction: ?f64) void {
        const w = app.events orelse return;
        std.json.Stringify.value(.{ .event = kind, .message = message, .fraction = fraction }, .{ .emit_null_optional_fields = false }, w) catch return;
        w.writeByte('\n') catch return;
        w.flush() catch return;
    }

    /// A step of a long operation: for people, and as an event.
    fn step(app: *App, fraction: f64, comptime fmt: []const u8, args: anytype) void {
        const message = std.fmt.allocPrint(app.arena, fmt, args) catch return;
        app.say("==> {s}", .{message}) catch {};
        app.event("step", message, fraction);
    }

    fn say(app: *App, comptime fmt: []const u8, args: anytype) !void {
        app.line.clear(app.out);
        try app.out.print(fmt ++ "\n", args);
        // Long operations (an image build) report as they go.
        try app.out.flush();
    }

    // -- dispatch -------------------------------------------------------------

    fn run(app: *App, args: []const []const u8) !void {
        if (args.len >= 1 and std.mem.eql(u8, args[0], triggers.chroot_command)) return app.chrootExec(args[1..]);
        if (args.len >= 1 and std.mem.eql(u8, args[0], "complete")) return app.cmdComplete(args[1..]);
        app.argv = args;
        var diag: cli.Diagnostic = .{};
        const parsed = cli.parse(app.arena, args, &diag) catch |e| switch (e) {
            error.Usage => return app.fail("{s}", .{diag.message}),
            else => |other| return other,
        };
        app.opts = parsed.opts;
        app.caps = ui.detect(app.io, app.environ, app.opts.json);
        if (app.opts.show_version) return app.say("dave {s}", .{dave_version});
        const word = parsed.word orelse return help.overview(app.out, app.caps.color);
        const cmd = parsed.command orelse return app.unknownCommand("unknown command", word);
        if (app.opts.help) return help.command(app.out, cmd, app.caps.color);
        const rest = parsed.operands;
        try app.checkRoot(cmd, rest);
        // Whatever the command did, and whether or not it succeeded, users
        // without root then see the system as it now is.
        defer if (app.opened_system) app.publishStatus();
        switch (cmd) {
            .help => return app.cmdHelp(rest),
            .version => return app.say("dave {s}", .{dave_version}),
            .install => return app.cmdChange(.install, rest, .person),
            .remove => return app.cmdChange(.remove, rest, .person),
            .upgrade => return app.cmdUpgrade(),
            .list => return app.cmdList(),
            .info => return app.cmdInfo(rest),
            .search => return app.cmdSearch(rest),
            .files => return app.cmdFiles(rest),
            .owns => return app.cmdOwns(rest),
            .why => return app.cmdWhy(rest),
            .status => return app.cmdStatus(),
            .rollback => return app.cmdRollback(),
            .deployments => return app.cmdDeployments(rest),
            .finalize => return app.cmdFinalize(),
            .@"boot-check" => return app.cmdBootCheck(),
            .@"boot-watchdog" => return app.cmdBootWatchdog(),
            .build => return app.cmdBuild(rest),
            .pack => return app.cmdPack(rest),
            .repo => return app.cmdRepo(rest),
            .key => return app.cmdKey(rest),
            .seal => return app.cmdSeal(),
            .image => return app.cmdImage(rest),
            .@"install-system" => return app.cmdInstallSystem(rest),
        }
    }

    /// Changing the running system needs root. Saying so before anything
    /// is touched beats failing halfway with a permission error.
    fn checkRoot(app: *App, cmd: cli.Command, rest: []const []const u8) !void {
        if (!std.mem.eql(u8, app.opts.root, "/") or linux.geteuid() == 0) return;
        const what = cli.infoOf(cmd).root_for orelse return;
        const needed = switch (cmd) {
            .install, .remove => !app.opts.dry_run,
            .upgrade => !app.opts.dry_run and !app.opts.check,
            .deployments => rest.len > 0 and !std.mem.eql(u8, rest[0], "list"),
            else => true,
        };
        if (!needed) return;
        return app.fail("{s} needs root; run it with sudo: sudo dave {s}", .{ what, try ui.shellQuote(app.arena, app.argv) });
    }

    fn cmdHelp(app: *App, args: []const []const u8) !void {
        if (args.len == 0) return help.overview(app.out, app.caps.color);
        const cmd = std.meta.stringToEnum(cli.Command, args[0]) orelse return app.unknownCommand("there is no command", args[0]);
        return help.command(app.out, cmd, app.caps.color);
    }

    fn unknownCommand(app: *App, what: []const u8, word: []const u8) Failure {
        const hint = suggest.didYouMean(app.arena, word, cli.commandNames(app.arena) catch &.{}, true) catch "";
        if (hint.len > 0) return app.fail("{s} '{s}'{s}", .{ what, word, hint });
        return app.fail("{s} '{s}'; run 'dave help' for the list", .{ what, word });
    }

    // -- environment ----------------------------------------------------------

    fn openDir(app: *App, path: []const u8) !Io.Dir {
        return Io.Dir.cwd().openDir(app.io, path, .{ .iterate = true }) catch |e|
            return app.failErr(e, "cannot open {s}", .{path});
    }

    /// Reads a whole file as a stream. Files under /proc report a size of zero,
    /// and for some of them (mountinfo) a size-based read returns nothing.
    fn readAbsolute(app: *App, path: []const u8) ?[]const u8 {
        var file = Io.Dir.cwd().openFile(app.io, path, .{}) catch return null;
        defer file.close(app.io);
        var buf: [4096]u8 = undefined;
        var reader = file.readerStreaming(app.io, &buf);
        return reader.interface.allocRemaining(app.arena, .limited(4 * 1024 * 1024)) catch null;
    }

    /// The id of the deployment this system is running from, if dave is being
    /// asked to act on the running system and that system uses deployments.
    fn runningDeployment(app: *App) ?u32 {
        if (!std.mem.eql(u8, app.opts.root, "/")) return null;
        const id = boot.deploymentOf(app.readAbsolute("/proc/cmdline") orelse return null) orelse return null;
        // A container shares its host's command line: on a joe host it names
        // the host's deployment, but this root is the container's own.
        const root = app.findMount("/") orelse return null;
        if (!std.mem.eql(u8, root.fstype, "btrfs")) return null;
        return id;
    }

    const Mount = struct { source: []const u8, fstype: []const u8 };

    fn findMount(app: *App, mount_point: []const u8) ?Mount {
        const text = app.readAbsolute("/proc/self/mountinfo") orelse return null;
        var found: ?Mount = null;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
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
            const fstype = tail.next() orelse continue;
            const source = tail.next() orelse continue;
            // Later lines shadow earlier ones mounted on the same point.
            found = .{ .source = source, .fstype = fstype };
        }
        return found;
    }

    /// Mounts the top level of the root's btrfs filesystem where dave can
    /// reach every deployment, if it is not mounted there already.
    fn mountTop(app: *App) !void {
        if (app.findMount(top_mount) != null) return;
        const root = app.findMount("/") orelse return app.fail("cannot determine what / is mounted from", .{});
        if (!std.mem.eql(u8, root.fstype, "btrfs")) return app.fail("/ is {s}, not btrfs", .{root.fstype});
        Io.Dir.cwd().createDirPath(app.io, top_mount) catch |e| return app.fail("cannot create {s}: {t}", .{ top_mount, e });
        const source = try app.arena.dupeSentinel(u8, root.source, 0);
        // Every deployment is under it, with the set-uid programs of each:
        // they must not run from here. openSystem also closes it to users.
        const rc = linux.mount(source, top_mount, "btrfs", linux.MS.NOSUID | linux.MS.NODEV, @intFromPtr(@as([*:0]const u8, "subvolid=5")));
        if (linux.errno(rc) != .SUCCESS)
            return app.fail("cannot mount the top of {s} at {s}: {t}", .{ root.source, top_mount, linux.errno(rc) });
    }

    /// Only one dave may change the system at a time.
    fn lock(app: *App) !Io.File {
        return (try app.tryLock()) orelse app.fail("another dave operation is in progress", .{});
    }

    /// The lock, or null when another dave holds it.
    fn tryLock(app: *App) !?Io.File {
        Io.Dir.cwd().createDirPath(app.io, std.fs.path.dirname(lock_path).?) catch {};
        return Io.Dir.cwd().createFile(app.io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |e| switch (e) {
            error.WouldBlock => null,
            else => app.failErr(e, "cannot take the lock {s}", .{lock_path}),
        };
    }

    fn openSystem(app: *App, current: u32) !deploy.System {
        try app.mountTop();
        if (app.findMount(esp_path) == null) return app.fail("the EFI system partition is not mounted at {s}", .{esp_path});
        Io.Dir.cwd().createDirPath(app.io, system_cache) catch {};
        const top = try app.openDir(top_mount);
        // Only root may enter the top level, through this mount or any other:
        // old deployments keep the set-uid programs they were made with.
        top.setPermissions(app.io, .fromMode(0o700)) catch |e|
            return app.fail("cannot close {s} to other users: {t}", .{ top_mount, e });
        const sys: deploy.System = .{
            .gpa = app.gpa,
            .arena = app.arena,
            .io = app.io,
            .top = top,
            .top_path = top_mount,
            .esp = try app.openDir(esp_path),
            .xbootldr = app.openXbootldr(),
            .root = try app.openDir("/"),
            .cache = try app.openDir(system_cache),
            .current = current,
            .run_triggers = !app.opts.no_triggers,
        };
        app.opened_system = true;
        return sys;
    }

    /// The extended boot loader partition, where a system installed beside
    /// another keeps its boot entries and kernels: mounted at /boot, FAT
    /// as systemd-boot needs it. Null for every other joe system.
    fn openXbootldr(app: *App) ?Io.Dir {
        const m = app.findMount(boot_mount) orelse return null;
        if (!std.mem.eql(u8, m.fstype, "vfat")) return null;
        return Io.Dir.cwd().openDir(app.io, boot_mount, .{ .iterate = true }) catch null;
    }

    /// Writes what `dave status` shows to `status_path`, readable by everyone.
    /// Best effort and silent: the command has already succeeded or failed,
    /// and must not be reported otherwise because of this.
    fn publishStatus(app: *App) void {
        if (linux.geteuid() != 0) return;
        const current = app.runningDeployment() orelse return;
        var sys: deploy.System = .{
            .gpa = app.gpa,
            .arena = app.arena,
            .io = app.io,
            .top = Io.Dir.cwd().openDir(app.io, top_mount, .{ .iterate = true }) catch return,
            .top_path = top_mount,
            .esp = Io.Dir.cwd().openDir(app.io, esp_path, .{ .iterate = true }) catch return,
            .root = Io.Dir.cwd().openDir(app.io, "/", .{ .iterate = true }) catch return,
            .cache = Io.Dir.cwd().openDir(app.io, system_cache, .{ .iterate = true }) catch return,
            .xbootldr = app.openXbootldr(),
            .current = current,
        };
        defer for ([_]Io.Dir{ sys.top, sys.esp, sys.root, sys.cache }) |d| d.close(app.io);
        defer if (sys.xbootldr) |d| d.close(app.io);
        const text = deploy.Published.of(current, sys.overview() catch return).serialize(app.arena) catch return;
        var dir = Io.Dir.cwd().openDir(app.io, std.fs.path.dirname(status_path).?, .{}) catch return;
        defer dir.close(app.io);
        db.writeAtomicWith(app.arena, app.io, dir, std.fs.path.basename(status_path), text, .fromMode(0o644)) catch return;
    }

    /// The deployments as root last published them, if that was during this
    /// boot of this deployment.
    fn publishedView(app: *App, current: u32) ?deploy.System.Overview {
        const text = app.readAbsolute(status_path) orelse return null;
        const published = deploy.Published.parse(app.arena, text) catch return null;
        if (published.running != current) return null;
        return published.overview();
    }

    const Context = struct {
        root: Io.Dir,
        cache: Io.Dir,
        installed: []manifest.Manifest,
        world: []db.WorldEntry,
        config: repo.Config,
        trusted: []repo.PublicKey,
    };

    fn context(app: *App) !Context {
        const root = try app.openDir(app.opts.root);
        const cache_path = app.opts.cache orelse
            try std.fs.path.join(app.arena, &.{ app.opts.root, "var/cache/dave" });
        Io.Dir.cwd().createDirPath(app.io, cache_path) catch |e| return app.failErr(e, "cannot create {s}", .{cache_path});
        return .{
            .root = root,
            .cache = try app.openDir(cache_path),
            .installed = db.load(app.arena, app.io, root) catch |e| return app.failErr(e, "the package database is unreadable", .{}),
            .world = db.loadWorld(app.arena, app.io, root) catch |e| return app.failErr(e, "{s} is unreadable", .{db.world_path}),
            .config = repo.loadConfig(app.arena, app.io, root) catch |e| return app.failErr(e, "{s} is unreadable", .{repo.config_path}),
            .trusted = try repo.loadTrustedKeys(app.arena, app.io, root),
        };
    }

    fn candidates(app: *App, ctx: Context, refresh: bool) ![]repo.Candidate {
        if (ctx.config.repos.len == 0) return app.fail("no repositories are configured in {s}", .{repo.config_path});
        if (ctx.trusted.len == 0) return app.fail("no trusted keys in {s}; refusing to use unsigned repositories", .{repo.keys_path});
        if (!refresh) return app.loadCandidates(ctx);
        for (ctx.config.repos) |r| {
            if (app.caps.live) app.line.draw(app.out, ui.width(), app.now(), true, try std.fmt.allocPrint(app.arena, "Fetching the index of {s}", .{r.name}));
            var diag: repo.FetchDiagnostic = .{};
            repo.refreshRepo(app.gpa, app.arena, app.io, r, ctx.trusted, ctx.cache, .{ .diag = &diag }) catch |e| switch (e) {
                error.BadSignature => return app.fail("a repository index is not signed by a trusted key; nothing was changed", .{}),
                error.TlsInitializationFailed => return app.fail(tls_failed, .{r.url}),
                error.CertificateBundleLoadFailure => return app.fail(no_certificates, .{}),
                error.DownloadFailed => return app.fail("cannot refresh repository {s}: {s} answered {f}", .{ r.name, diag.url, statusText(diag.status) }),
                error.WrongArchitecture => return app.fail("repository {s} ({s}) offers packages for {s}, but this dave manages {s} systems; nothing was changed", .{ r.name, r.url, diag.arch, arch.name }),
                else => return app.failErr(e, "cannot refresh repository {s} ({s})", .{ r.name, r.url }),
            };
        }
        app.line.clear(app.out);
        return app.loadCandidates(ctx);
    }

    /// The candidates of the cached indexes, or a failure saying why there are none.
    fn loadCandidates(app: *App, ctx: Context) ![]repo.Candidate {
        var diag: repo.FetchDiagnostic = .{};
        return repo.loadCached(app.arena, app.io, ctx.config, ctx.trusted, ctx.cache, &diag) catch |e| switch (e) {
            error.WrongArchitecture => app.fail("the cached index of {s} offers packages for {s}, but this dave manages {s} systems", .{ diag.url, diag.arch, arch.name }),
            else => app.fail("the cached repository index is unusable: {t}", .{e}),
        };
    }

    const StatusText = struct {
        status: ?std.http.Status,

        pub fn format(t: StatusText, w: *Io.Writer) Io.Writer.Error!void {
            const status = t.status orelse return w.writeAll("with an error");
            try w.print("{d}", .{@backingInt(status)});
            if (status.phrase()) |phrase| try w.print(" {s}", .{phrase});
        }
    };

    fn statusText(status: ?std.http.Status) StatusText {
        return .{ .status = status };
    }

    /// Whether the index may be fetched again: root may, and so may anyone
    /// working on a root or cache other than the running system's, which
    /// only root can write.
    fn canRefresh(app: *App) bool {
        return linux.geteuid() == 0 or !std.mem.eql(u8, app.opts.root, "/") or app.opts.cache != null;
    }

    fn now(app: *App) i96 {
        return Io.Timestamp.now(app.io, .awake).nanoseconds;
    }

    // The HTTP client reports every failed TLS handshake as one error; by far
    // the most common cause is a certificate this system does not accept.
    const tls_failed = "cannot connect securely to {s} (is its certificate valid, and trusted by this system?); nothing was changed";
    const no_certificates = "cannot read this system's trusted certificates (/etc/pki/tls/certs/ca-bundle.crt); nothing was changed";

    fn solve(app: *App, request: resolve.Request) !resolve.Solution {
        var explanation: Io.Writer.Allocating = .init(app.arena);
        return resolve.resolve(app.arena, request, &explanation.writer) catch |e| switch (e) {
            error.NoSolution, error.InvalidDependency => {
                app.err.print("dave: this cannot be done.\n\n{s}", .{explanation.written()}) catch {};
                return error.Reported;
            },
            else => |other| return other,
        };
    }

    /// Shows what `solution` will do (plan.zig) and returns it. `world` is
    /// the world file as it will be, `named` what the command line named.
    fn showPlan(app: *App, ctx: Context, solution: resolve.Solution, world: []const db.WorldEntry, named: []const []const u8) !plan.Plan {
        const cached = try app.arena.alloc(bool, solution.install.len);
        for (solution.install, cached) |u, *c| c.* = repo.isCached(app.io, ctx.cache, u.candidate.entry);
        const p = try plan.of(app.arena, .{ .solution = solution, .installed = ctx.installed, .world = world, .named = named, .cached = cached });
        app.line.clear(app.out);
        try p.write(app.out, app.caps.color);
        try app.out.flush();
        return p;
    }

    /// Downloads and verifies every package of a solution; returns their file
    /// names within the cache's package directory.
    fn download(app: *App, ctx: Context, solution: resolve.Solution) ![]const []const u8 {
        const names = try app.arena.alloc([]const u8, solution.install.len);
        const fetching = try app.arena.alloc(bool, solution.install.len);
        var shown: Downloads = .{ .app = app, .start_ns = app.now() };
        for (solution.install, fetching) |u, *f| {
            f.* = app.caps.live and !repo.isCached(app.io, ctx.cache, u.candidate.entry);
            if (!f.*) continue;
            shown.count += 1;
            shown.total += u.candidate.entry.size;
        }
        for (solution.install, names, fetching) |u, *name, f| {
            const entry = u.candidate.entry;
            if (f) {
                shown.index += 1;
                shown.name = entry.name;
                shown.draw(true);
            }
            var diag: repo.FetchDiagnostic = .{};
            _ = repo.ensurePackage(app.gpa, app.arena, app.io, u.candidate, ctx.cache, .{
                .progress = if (f) shown.interface() else null,
                .diag = &diag,
            }) catch |e| switch (e) {
                error.ChecksumMismatch => return app.fail("{s} does not match the signed index; nothing was changed", .{entry.filename}),
                error.TlsInitializationFailed => return app.fail(tls_failed, .{u.candidate.repo_url}),
                error.CertificateBundleLoadFailure => return app.fail(no_certificates, .{}),
                error.DownloadFailed => return app.fail("cannot fetch {s}: {s} answered {f}; nothing was changed", .{ entry.filename, diag.url, statusText(diag.status) }),
                else => return app.failErr(e, "cannot fetch {s}", .{entry.filename}),
            };
            if (f) shown.finished += entry.size;
            name.* = entry.filename;
        }
        app.line.clear(app.out);
        return names;
    }

    /// The line a download draws: which package, how much of all of them,
    /// and how fast.
    const Downloads = struct {
        app: *App,
        count: usize = 0,
        index: usize = 0,
        total: u64 = 0,
        /// The bytes of the packages already downloaded.
        finished: u64 = 0,
        /// Of the one arriving.
        current: u64 = 0,
        name: []const u8 = "",
        start_ns: i96,

        fn interface(d: *Downloads) repo.ByteProgress {
            return .{ .context = d, .report = onBytes };
        }

        fn onBytes(opaque_self: *anyopaque, bytes: u64) void {
            const d: *Downloads = @ptrCast(@alignCast(opaque_self));
            d.current = bytes;
            d.draw(false);
        }

        fn draw(d: *Downloads, force: bool) void {
            if (force) d.current = 0;
            const now_ns = d.app.now();
            const done = d.finished + d.current;
            const elapsed = now_ns - d.start_ns;
            var buf: [512]u8 = undefined;
            const text = if (elapsed > std.time.ns_per_s) std.fmt.bufPrint(&buf, "Downloading {d} of {d}: {s}  {f} of {f}, {f}/s", .{
                d.index,                                                                    d.count, d.name, ui.size(done), ui.size(d.total),
                ui.size(@intCast(@divTrunc(@as(i128, done) * std.time.ns_per_s, elapsed))),
            }) else std.fmt.bufPrint(&buf, "Downloading {d} of {d}: {s}  {f} of {f}", .{
                d.index, d.count, d.name, ui.size(done), ui.size(d.total),
            });
            d.app.line.draw(d.app.out, ui.width(), now_ns, force, text catch return);
        }
    };

    /// The line a transaction draws as it writes packages.
    const TerminalProgress = struct {
        app: *App,

        fn interface(p: *TerminalProgress) txn.Progress {
            return .{ .context = p, .report = onPackage };
        }

        fn onPackage(opaque_self: *anyopaque, done: usize, total: usize, name: []const u8) void {
            const p: *TerminalProgress = @ptrCast(@alignCast(opaque_self));
            var buf: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "Installing packages: {d} of {d} ({s})", .{ done, total, name }) catch return;
            p.app.line.draw(p.app.out, ui.width(), p.app.now(), done == 1, text);
        }
    };

    fn packageFiles(app: *App, ctx: Context, names: []const []const u8) ![]txn.PackageFile {
        const files = try app.arena.alloc(txn.PackageFile, names.len);
        for (names, files) |name, *f| {
            f.* = .{ .dir = ctx.cache, .sub_path = try std.fmt.allocPrint(app.arena, repo.packages_dir ++ "/{s}", .{name}) };
        }
        return files;
    }

    fn removeNames(app: *App, solution: resolve.Solution) ![]const []const u8 {
        const names = try app.arena.alloc([]const u8, solution.remove.len);
        for (solution.remove, names) |m, *n| n.* = m.name;
        return names;
    }

    /// Applies a solution directly to the root in `ctx` and runs triggers.
    fn applyNow(app: *App, ctx: Context, solution: resolve.Solution, files: []const []const u8) !void {
        var terminal: TerminalProgress = .{ .app = app };
        try app.applyPlan(ctx.root, .{
            .install = try app.packageFiles(ctx, files),
            .remove = try app.removeNames(solution),
            .overwrite_unowned = app.opts.overwrite,
            .seal = app.seal,
            .progress = if (app.caps.live) terminal.interface() else null,
        });
    }

    /// Applies a transaction to `root` (which is `app.opts.root`) and runs
    /// the triggers it calls for.
    fn applyPlan(app: *App, root: Io.Dir, p: txn.Plan) !void {
        var diag: txn.Diagnostic = .{};
        const result = txn.apply(app.gpa, app.arena, app.io, root, p, &diag) catch |e| {
            if (diag.message.len > 0) return app.fail("{s}", .{diag.message});
            return app.failErr(e, "the transaction failed", .{});
        };
        app.line.clear(app.out);
        for (result.notes) |n| try app.say("note: {s}", .{n});
        if (result.unsealed > 0 and app.runningDeployment() != null)
            try app.say("note: {d} file(s) could not be sealed here; run 'dave seal'", .{result.unsealed});
        if (app.opts.no_triggers) return;
        const wanted = try triggers.matching(app.arena, try triggers.load(app.arena, app.io, root), result.changed_paths);
        const live = std.mem.eql(u8, app.opts.root, "/");
        triggers.run(app.arena, app.io, wanted, .{
            .root = root,
            .chroot_path = if (live) null else try Io.Dir.cwd().realPathFileAlloc(app.io, app.opts.root, app.arena),
            .self_exe = "/proc/self/exe",
            .environ_map = app.environ,
        }) catch |e| return app.failErr(e, "a package trigger failed", .{});
    }

    /// What installing `names` into `root` (whose packages are `installed`)
    /// takes from the packages another root holds: the same solve as from a
    /// repository, with that root's packages as the only ones offered. The
    /// installer installs from the medium's root this way; the image build
    /// makes the same solve to put on the medium what that needs.
    fn solveFromRoot(app: *App, from: []const manifest.Manifest, installed: []const manifest.Manifest, names: []const []const u8, where: []const u8) !resolve.Solution {
        var world: std.ArrayList(db.WorldEntry) = .empty;
        for (names) |n| {
            if (findInstalled(from, n) == null) return app.fail("{s} does not have {s}", .{ where, n });
            try world.append(app.arena, .{ .name = n });
        }
        return app.solve(.{
            .world = world.items,
            .installed = installed,
            .candidates = try install_system.candidatesOf(app.arena, from),
            .mode = .keep_installed,
        });
    }

    // -- install / remove -----------------------------------------------------

    const ChangeKind = enum { install, remove };

    /// Who asked: a person, who may be asked in turn, or dave itself (an
    /// image build, the installer), which never is.
    const Caller = enum { person, internal };

    fn cmdChange(app: *App, kind: ChangeKind, names: []const []const u8, caller: Caller) !void {
        if (names.len == 0) return app.fail("name at least one package; see 'dave help {t}'", .{kind});
        const current = app.runningDeployment();
        // A dry run changes nothing, so anyone may make one, from the index
        // dave fetched last if they cannot fetch it again.
        const looking = app.opts.dry_run and !app.canRefresh();
        // Only root takes the lock, and only root can change the system.
        const locking = current != null and (!app.opts.dry_run or linux.geteuid() == 0);
        var lock_file: ?Io.File = if (locking) try app.lock() else null;
        defer if (lock_file) |*f| f.close(app.io);

        const ctx = try app.context();
        const offered = try app.candidates(ctx, kind == .install and !looking);
        if (looking and kind == .install) try app.say("(Without root, dave uses the package index it fetched last.)", .{});
        var world: std.ArrayList(db.WorldEntry) = .empty;
        try world.appendSlice(app.arena, ctx.world);
        var named: std.ArrayList([]const u8) = .empty;
        for (names) |raw| {
            const dep = manifest.splitDependency(raw);
            if (!manifest.validName(dep.name)) return app.fail("'{s}' is not a valid package name", .{raw});
            try named.append(app.arena, dep.name);
            const existing = for (world.items, 0..) |w, i| {
                if (std.mem.eql(u8, w.name, dep.name)) break i;
            } else null;
            switch (kind) {
                .install => {
                    if (!isInstalled(ctx.installed, dep.name) and !isOffered(offered, dep.name))
                        return app.fail("no package named {s} exists{s}", .{ dep.name, try app.suggestPackage(dep.name, offered, ctx.installed) });
                    if (existing) |i| {
                        if (dep.constraint.len > 0) world.items[i].constraint = dep.constraint;
                    } else try world.append(app.arena, .{ .name = dep.name, .constraint = dep.constraint });
                },
                .remove => if (existing) |i| {
                    _ = world.orderedRemove(i);
                } else {
                    if (isInstalled(ctx.installed, dep.name)) {
                        const needing = try query.requiredBy(app.arena, ctx.installed, dep.name);
                        if (needing.len == 0) return app.fail("{s} was not installed by request, and nothing needs it any more; the next install or remove takes it away", .{dep.name});
                        return app.fail("{s} was not installed by request; it is here because {s} {s} it", .{
                            dep.name, try listNames(app.arena, needing, 3), if (needing.len == 1) "needs" else "need",
                        });
                    }
                    return app.fail("{s} is not installed{s}", .{ dep.name, try suggest.didYouMean(app.arena, dep.name, try installedNames(app.arena, ctx.installed), false) });
                },
            }
        }

        const solution = try app.solve(.{
            .world = world.items,
            .installed = ctx.installed,
            .candidates = offered,
            .mode = .keep_installed,
        });
        if (solution.isEmpty()) {
            // Nothing to install or remove, but the world may have changed:
            // what was asked for is now remembered as asked for, or not.
            if (!app.opts.dry_run) {
                try db.saveWorld(app.arena, app.io, ctx.root, world.items);
                if (current != null) try std.posix.syncfs(ctx.root.handle);
            }
            if (kind == .install) return app.say("Already installed.", .{});
            for (named.items) |n| {
                const needing = try query.requiredBy(app.arena, ctx.installed, n);
                try app.say("Nothing {s} removed: {s} still {s} {s}.", .{
                    if (app.opts.dry_run) "would be" else "was", try listNames(app.arena, needing, 3),
                    if (needing.len == 1) "needs" else "need",   n,
                });
            }
            return;
        }
        const shown = try app.showPlan(ctx, solution, world.items, named.items);
        if (app.opts.dry_run) return;
        if (caller == .person and !app.opts.yes and app.caps.ask and shown.needsQuestion(switch (kind) {
            .install => .install,
            .remove => .remove,
        })) {
            if (ui.ask(app.io, app.out, "Continue? [Y/n] ") == .no) {
                try app.say("Nothing was changed.", .{});
                return error.Reported;
            }
        }
        const files = try app.download(ctx, solution);

        var sys: ?deploy.System = null;
        var had_staged = false;
        if (current) |id| {
            for (solution.remove) |m| if (ownsKernel(m)) return app.fail("{s} provides the running kernel; it cannot be removed from a running system", .{m.name});
            for (files) |name| {
                const sub = try std.fmt.allocPrint(app.arena, repo.packages_dir ++ "/{s}", .{name});
                const m = try archive.readManifestOf(app.gpa, app.arena, app.io, ctx.cache, sub);
                if (ownsKernel(m)) return app.fail("{s} contains a kernel, which cannot change under a running system; use 'dave upgrade'", .{m.name});
            }
            sys = try app.openSystem(id);
            had_staged = (try sys.?.loadState()).staged != null;
            const reason = try std.fmt.allocPrint(app.arena, "before: dave {t} {s}", .{ kind, try std.mem.join(app.arena, " ", names) });
            const point = sys.?.rollbackPoint(reason) catch |e| {
                if (sys.?.diag.message.len > 0) return app.fail("{s}", .{sys.?.diag.message});
                return app.failErr(e, "cannot create a rollback point", .{});
            };
            try app.say("Saved the current system as deployment {d}.", .{point});
        }

        app.applyNow(ctx, solution, files) catch |e| {
            if (current != null) app.warn("the system may be partly changed; run 'dave rollback' and reboot to return to how it was.");
            return e;
        };
        try db.saveWorld(app.arena, app.io, ctx.root, world.items);
        // The package transaction flushed the payload. Its triggers and the
        // subsequent world-file rename must also survive an immediate reboot.
        if (current != null) try std.posix.syncfs(ctx.root.handle);
        try app.say("Done.", .{});

        if (sys) |*s| {
            _ = s.collectGarbage(deploy.default_keep) catch {};
            if (had_staged) {
                // The pending upgrade was computed for the old package set.
                try s.unstage();
                app.stageUpgrade(s, false) catch {
                    try app.say("The pending upgrade was dropped; run 'dave upgrade' again.", .{});
                };
            }
        }
    }

    fn isInstalled(installed: []const manifest.Manifest, name: []const u8) bool {
        for (installed) |m| if (std.mem.eql(u8, m.name, name)) return true;
        return false;
    }

    fn isOffered(offered: []const repo.Candidate, name: []const u8) bool {
        for (offered) |c| if (std.mem.eql(u8, c.entry.name, name)) return true;
        return false;
    }

    fn installedNames(arena: Allocator, installed: []const manifest.Manifest) ![]const []const u8 {
        const out = try arena.alloc([]const u8, installed.len);
        for (installed, out) |m, *n| n.* = m.name;
        return out;
    }

    /// "; did you mean ...?" among every package offered or installed.
    fn suggestPackage(app: *App, name: []const u8, offered: []const repo.Candidate, installed: []const manifest.Manifest) ![]const u8 {
        var all: std.ArrayList([]const u8) = .empty;
        for (offered) |c| try all.append(app.arena, c.entry.name);
        for (installed) |m| try all.append(app.arena, m.name);
        return suggest.didYouMean(app.arena, name, all.items, false);
    }

    /// "a", "a and b", "a, b and c", "a, b, c and 4 others".
    fn listNames(arena: Allocator, names: []const []const u8, most: usize) ![]const u8 {
        if (names.len == 0) return "nothing";
        if (names.len == 1) return names[0];
        if (names.len <= most) {
            return std.fmt.allocPrint(arena, "{s} and {s}", .{ try std.mem.join(arena, ", ", names[0 .. names.len - 1]), names[names.len - 1] });
        }
        return std.fmt.allocPrint(arena, "{s} and {d} others", .{ try std.mem.join(arena, ", ", names[0..most]), names.len - most });
    }

    fn ownsKernel(m: manifest.Manifest) bool {
        for (m.files) |f| {
            if (std.mem.startsWith(u8, f.path, "usr/lib/modules/") and std.mem.endsWith(u8, f.path, "/vmlinuz")) return true;
        }
        return false;
    }

    // -- upgrade --------------------------------------------------------------

    fn cmdUpgrade(app: *App) !void {
        if (app.opts.check and app.opts.reboot) return app.fail("--check only looks, so it cannot be given with --reboot", .{});
        const current = app.runningDeployment() orelse {
            // Not a deployment-managed system (an image being built, a
            // container): there is nothing to protect, so apply directly.
            const ctx = try app.context();
            const looking = app.opts.check or app.opts.dry_run;
            const solution = try app.solve(.{
                .world = ctx.world,
                .installed = ctx.installed,
                .candidates = try app.candidates(ctx, app.canRefresh()),
                .mode = .newest,
            });
            if (solution.isEmpty()) return app.say("Everything is up to date.", .{});
            _ = try app.showPlan(ctx, solution, ctx.world, &.{});
            if (looking) return;
            try app.applyNow(ctx, solution, try app.download(ctx, solution));
            return app.say("Done.", .{});
        };
        if (app.opts.check or (app.opts.dry_run and linux.geteuid() != 0)) return app.checkUpgrade(current);
        var lock_file = try app.lock();
        defer lock_file.close(app.io);
        var sys = try app.openSystem(current);
        try app.stageUpgrade(&sys, true);
        if (!app.opts.reboot or app.opts.dry_run) return;
        if ((try sys.loadState()).staged == null) return;
        const outcome = (try sys.finalize()) orelse return;
        if (!outcome.ok) return app.fail("the upgrade could not be applied: {s}", .{outcome.message});
        try app.say("Deployment {d} is ready. Rebooting.", .{outcome.deployment.?});
        try app.out.flush();
        var child = std.process.spawn(app.io, .{ .argv = &.{"reboot"} }) catch |e|
            return app.fail("cannot reboot ({t}); reboot manually to finish", .{e});
        _ = try child.wait(app.io);
    }

    /// Solves, downloads, validates and records an upgrade of the running system.
    fn stageUpgrade(app: *App, sys: *deploy.System, refresh: bool) !void {
        const ctx = try app.context();
        const solution = try app.solve(.{
            .world = ctx.world,
            .installed = ctx.installed,
            .candidates = try app.candidates(ctx, refresh),
            .mode = .newest,
        });
        if (solution.isEmpty()) {
            try sys.unstage();
            return app.say("Everything is up to date.", .{});
        }
        _ = try app.showPlan(ctx, solution, ctx.world, &.{});
        if (app.opts.dry_run) return;
        const files = try app.download(ctx, solution);
        const hash = try db.stateHash(app.arena, ctx.installed);
        const summary = try std.fmt.allocPrint(app.arena, "{d} to install or upgrade, {d} to remove", .{ solution.install.len, solution.remove.len });
        const result = sys.stage(.{
            .packages = files,
            .remove = try app.removeNames(solution),
            .db_hash = try app.arena.dupe(u8, &hash),
            .summary = summary,
        }) catch |e| {
            if (sys.diag.message.len > 0) return app.fail("the upgrade would not apply cleanly: {s}", .{sys.diag.message});
            return app.fail("the upgrade would not apply cleanly: {t}", .{e});
        };
        for (result.notes) |n| try app.say("note: {s}", .{n});
        try app.say("The upgrade is ready and will be applied when the system shuts down or reboots.", .{});
        try app.say("The running system has not been changed.", .{});
    }

    /// What an upgrade would change, without preparing it. Root fetches the
    /// index first when no other dave is busy; anyone else, or root while
    /// another dave works, uses the index fetched last.
    fn checkUpgrade(app: *App, current: u32) !void {
        const root = linux.geteuid() == 0;
        var lock_file: ?Io.File = if (root) try app.tryLock() else null;
        defer if (lock_file) |*f| f.close(app.io);
        const ctx = try app.context();
        if (lock_file == null) try app.say("(dave uses the package index it fetched last.)", .{});
        const solution = try app.solve(.{
            .world = ctx.world,
            .installed = ctx.installed,
            .candidates = try app.candidates(ctx, lock_file != null),
            .mode = .newest,
        });
        if (solution.isEmpty()) return app.say("Everything is up to date.", .{});
        _ = try app.showPlan(ctx, solution, ctx.world, &.{});
        if (app.publishedView(current)) |view| if (view.staged) |staged|
            return app.say("An upgrade is already prepared ({s}); it will be applied at shutdown.", .{staged.summary});
        try app.say("Run '{s}dave upgrade' to prepare it.", .{if (root) "" else "sudo "});
    }

    // -- queries --------------------------------------------------------------

    fn inWorld(world: []const db.WorldEntry, name: []const u8) bool {
        for (world) |w| if (std.mem.eql(u8, w.name, name)) return true;
        return false;
    }

    fn cmdList(app: *App) !void {
        const ctx = try app.context();
        for (ctx.installed) |m| {
            const requested = inWorld(ctx.world, m.name);
            if (app.opts.requested and !requested) continue;
            try app.out.print("{s} {s}{s}\n", .{ m.name, m.version, if (requested or app.opts.requested) "" else "  (dependency)" });
        }
    }

    /// The candidates fetched last, or none; for questions, which never fail
    /// for want of an index.
    fn cachedCandidates(app: *App, ctx: Context) []const repo.Candidate {
        return repo.loadCached(app.arena, app.io, ctx.config, ctx.trusted, ctx.cache, null) catch &.{};
    }

    fn newestOffered(offered: []const repo.Candidate, name: []const u8) ?repo.Candidate {
        var best: ?repo.Candidate = null;
        for (offered) |c| {
            if (!std.mem.eql(u8, c.entry.name, name)) continue;
            const v = version.Version.parse(c.entry.version) catch continue;
            if (best) |b| {
                if (v.order(version.Version.parse(b.entry.version) catch unreachable) != .gt) continue;
            }
            best = c;
        }
        return best;
    }

    fn findInstalled(installed: []const manifest.Manifest, name: []const u8) ?manifest.Manifest {
        for (installed) |m| if (std.mem.eql(u8, m.name, name)) return m;
        return null;
    }

    fn cmdInfo(app: *App, names: []const []const u8) !void {
        if (names.len != 1) return app.fail("name one package; see 'dave help info'", .{});
        const name = names[0];
        const ctx = try app.context();
        const offered = app.cachedCandidates(ctx);
        const here = findInstalled(ctx.installed, name);
        const newest = newestOffered(offered, name);
        if (here == null and newest == null) {
            if (offered.len == 0) return app.fail("{s} is not installed, and no repository index has been fetched to say whether it is available; " ++
                "'sudo dave upgrade --check' fetches it", .{name});
            return app.fail("no package named {s} is installed or available{s}", .{ name, try app.suggestPackage(name, offered, ctx.installed) });
        }

        var rows: std.ArrayList([2][]const u8) = .empty;
        const row = struct {
            fn add(a: Allocator, list: *std.ArrayList([2][]const u8), label: []const u8, comptime fmt: []const u8, args: anytype) !void {
                try list.append(a, .{ label, try std.fmt.allocPrint(a, fmt, args) });
            }
        }.add;
        const a = app.arena;
        try row(a, &rows, "Name", "{s}", .{name});
        const description = if (here) |m| m.description else newest.?.entry.description;
        if (description.len > 0) try row(a, &rows, "Description", "{s}", .{description});
        if (here) |m| {
            const because: []const u8 = switch (try query.why(a, ctx.installed, ctx.world, name)) {
                .requested => "by request",
                .chain => |c| try std.fmt.allocPrint(a, "because {s} needs it", .{c[c.len - 2]}),
                .orphan => "though nothing needs it any more",
                .not_installed => unreachable,
            };
            try row(a, &rows, "Installed", "{s}, {s}", .{ m.version, because });
        } else {
            try row(a, &rows, "Installed", "no", .{});
        }
        if (newest) |c| {
            try row(a, &rows, "Available", "{s}, from {s}", .{ c.entry.version, c.repo_name });
        } else {
            try row(a, &rows, "Available", "not from the configured repositories", .{});
        }
        const license = if (here) |m| m.license else newest.?.entry.license;
        if (license.len > 0) try row(a, &rows, "Licence", "{s}", .{license});
        if (newest) |c| try row(a, &rows, "Download size", "{f}", .{ui.size(c.entry.size)});
        if (here) |m| {
            var files: usize = 0;
            for (m.files) |f| files += @intFromBool(f.kind == .file);
            try row(a, &rows, "Installed size", "{f} in {d} file{s}", .{ ui.size(m.installedSize()), files, if (files == 1) "" else "s" });
        } else if (newest.?.entry.installed_size) |size| {
            try row(a, &rows, "Installed size", "{f}", .{ui.size(size)});
        }
        const depends = if (here) |m| m.depends else newest.?.entry.depends;
        try row(a, &rows, "Depends on", "{s}", .{if (depends.len > 0) try std.mem.join(a, ", ", depends) else "nothing"});
        const needing = try query.requiredBy(a, ctx.installed, name);
        try row(a, &rows, "Required by", "{s}", .{if (needing.len > 0) try std.mem.join(a, ", ", needing) else "nothing installed"});

        var width: usize = 0;
        for (rows.items) |r| width = @max(width, r[0].len);
        for (rows.items) |r| {
            try app.out.print("{f}", .{ui.paint(app.caps.color, .heading, r[0])});
            try app.out.splatByteAll(' ', width - r[0].len + 2);
            try app.out.print("{s}\n", .{r[1]});
        }
    }

    fn cmdSearch(app: *App, terms: []const []const u8) !void {
        if (terms.len == 0) return app.fail("give at least one word to search for; see 'dave help search'", .{});
        const ctx = try app.context();
        // Only root can refresh the system's index; anyone can search the one
        // fetched last.
        const refresh = app.canRefresh();
        const found = try app.candidates(ctx, refresh);
        if (!refresh and found.len == 0)
            return app.fail("no repository index has been fetched yet; 'sudo dave search {s}' fetches it", .{try ui.shellQuote(app.arena, terms)});
        const matches = try query.search(app.arena, found, ctx.installed, terms);
        if (matches.len == 0) return app.fail("no package matches {s}", .{try ui.shellQuote(app.arena, terms)});
        var name_width: usize = 0;
        var version_width: usize = 0;
        for (matches) |m| {
            name_width = @max(name_width, m.name.len);
            version_width = @max(version_width, m.version.len);
        }
        const columns: usize = if (app.caps.live) ui.width() else std.math.maxInt(usize);
        for (matches) |m| {
            const marker = if (m.installed) |v|
                (if (std.mem.eql(u8, v, m.version)) "[installed]" else try std.fmt.allocPrint(app.arena, "[installed: {s}]", .{v}))
            else
                "";
            try app.out.print("{f}", .{ui.paint(app.caps.color, .heading, m.name)});
            try app.out.splatByteAll(' ', name_width - m.name.len + 2);
            try app.out.writeAll(m.version);
            var used = name_width + 2 + m.version.len;
            if (marker.len > 0) {
                try app.out.print("  {f}", .{ui.paint(app.caps.color, .install, marker)});
                used += 2 + marker.len;
            }
            if (m.description.len > 0) {
                try app.out.writeAll("  ");
                used += 2;
                try app.out.writeAll(ui.fit(m.description, (columns -| 1) -| used));
            }
            try app.out.writeByte('\n');
        }
    }

    fn cmdFiles(app: *App, names: []const []const u8) !void {
        if (names.len != 1) return app.fail("name one package; see 'dave help files'", .{});
        const root = try app.openDir(app.opts.root);
        const m = (db.loadOne(app.arena, app.io, root, names[0]) catch |e|
            return app.failErr(e, "the package database is unreadable", .{})) orelse {
            const installed = db.names(app.arena, app.io, root) catch &.{};
            const hint = try suggest.didYouMean(app.arena, names[0], installed, false);
            if (hint.len > 0) return app.fail("{s} is not installed{s}", .{ names[0], hint });
            return app.fail("{s} is not installed; dave knows the files of installed packages only", .{names[0]});
        };
        for (m.files) |f| try app.out.print("/{s}{s}\n", .{ f.path, if (f.kind == .dir) "/" else "" });
    }

    fn cmdOwns(app: *App, paths: []const []const u8) !void {
        if (paths.len == 0) return app.fail("name at least one file; see 'dave help owns'", .{});
        const ctx = try app.context();
        var unowned = false;
        for (paths) |given| {
            const absolute_path = if (std.fs.path.isAbsolute(given)) given else try app.absolute(given);
            const rel = query.resolveInRoot(app.arena, app.io, ctx.root, absolute_path) catch |e|
                return app.failErr(e, "cannot follow {s}", .{given});
            const found = try query.owners(app.arena, ctx.installed, rel);
            const resolved = try std.fmt.allocPrint(app.arena, "/{s}", .{rel});
            const shown = if (std.mem.eql(u8, std.mem.trimEnd(u8, given, "/"), resolved))
                given
            else
                try std.fmt.allocPrint(app.arena, "{s} ({s})", .{ given, resolved });
            if (found.len == 0) {
                app.complain("no installed package owns {s}", .{shown});
                unowned = true;
                continue;
            }
            if (found.len == 1) {
                try app.say("{s} is owned by {s} {s}.", .{ shown, found[0].package, found[0].version });
                continue;
            }
            const owner_names = try app.arena.alloc([]const u8, found.len);
            for (found, owner_names) |o, *n| n.* = o.package;
            try app.say("{s} is {s}shared by {d} packages: {s}.", .{
                shown, if (found[0].kind == .dir) "a directory " else "", found.len, try listNames(app.arena, owner_names, 10),
            });
        }
        if (unowned) return error.Reported;
    }

    fn cmdWhy(app: *App, names: []const []const u8) !void {
        if (names.len != 1) return app.fail("name one package; see 'dave help why'", .{});
        const name = names[0];
        const ctx = try app.context();
        switch (try query.why(app.arena, ctx.installed, ctx.world, name)) {
            .requested => try app.say("{s} is here because you asked for it.", .{name}),
            .chain => |c| {
                if (c.len == 2) return app.say("{s} is here because you asked for {s}, which needs it.", .{ name, c[0] });
                var steps: std.ArrayList([]const u8) = .empty;
                for (c[0 .. c.len - 1], c[1..]) |from, to| try steps.append(app.arena, try std.fmt.allocPrint(app.arena, "{s} needs {s}", .{ from, to }));
                try app.say("{s} is here because you asked for {s}; {s}.", .{ name, c[0], try listNames(app.arena, steps.items, steps.items.len) });
            },
            .orphan => try app.say("{s} is installed, but nothing you asked for needs it; the next install or remove takes it away.", .{name}),
            .not_installed => return app.fail("{s} is not installed{s}", .{ name, try suggest.didYouMean(app.arena, name, try installedNames(app.arena, ctx.installed), false) }),
        }
    }

    /// `dave complete INDEX WORD...`, for the shell completions in
    /// dave/share: what the word at INDEX could be. Never fails: a broken
    /// completion must not print errors into the line being typed.
    fn cmdComplete(app: *App, args: []const []const u8) !void {
        if (args.len < 2) return;
        const index = std.fmt.parseInt(usize, args[0], 10) catch return;
        app.complete(cli.completion(args[1..], index)) catch {};
    }

    fn complete(app: *App, c: cli.Completion) !void {
        const w = app.out;
        switch (c.want) {
            .nothing => {},
            .commands => try completeCommands(w, c.prefix),
            .options => |cmd| for (cli.options, 0..) |o, i| {
                if (!cli.appliesTo(o, cmd)) continue;
                // Of two options with one name, the one the command takes.
                if (cli.findLong(o.long, cmd) != i) continue;
                if (!std.mem.startsWith(u8, c.prefix, "--") and c.prefix.len > 1) continue;
                if (!std.mem.startsWith(u8, o.long, if (c.prefix.len > 2) c.prefix[2..] else "")) continue;
                try w.print("--{s}\t{s}\n", .{ o.long, o.help });
            },
            .operand => |op| switch (op) {
                .none => {},
                .files => try w.writeAll(":files\n"),
                .dirs => try w.writeAll(":dirs\n"),
                .commands => try completeCommands(w, c.prefix),
                .words => |list| for (list) |word| {
                    if (std.mem.startsWith(u8, word, c.prefix)) try w.print("{s}\n", .{word});
                },
                .installed, .requested, .available => {
                    var root = Io.Dir.cwd().openDir(app.io, c.root, .{}) catch return;
                    defer root.close(app.io);
                    var seen: std.StringHashMapUnmanaged(void) = .empty;
                    if (op == .requested) {
                        for (try db.loadWorld(app.arena, app.io, root)) |e| try completeName(app.arena, w, &seen, c.prefix, e.name, "");
                        return;
                    }
                    if (op == .available) {
                        const cache_path = c.cache orelse try std.fs.path.join(app.arena, &.{ c.root, "var/cache/dave" });
                        if (Io.Dir.cwd().openDir(app.io, cache_path, .{})) |cache| {
                            const config = try repo.loadConfig(app.arena, app.io, root);
                            const trusted = try repo.loadTrustedKeys(app.arena, app.io, root);
                            for (try repo.loadCached(app.arena, app.io, config, trusted, cache, null)) |cand|
                                try completeName(app.arena, w, &seen, c.prefix, cand.entry.name, cand.entry.description);
                        } else |_| {}
                    }
                    for (try db.names(app.arena, app.io, root)) |n| try completeName(app.arena, w, &seen, c.prefix, n, "");
                },
            },
        }
    }

    fn completeCommands(w: *Io.Writer, prefix: []const u8) !void {
        for (cli.commands) |info| {
            if (info.hidden or !std.mem.startsWith(u8, @tagName(info.command), prefix)) continue;
            try w.print("{s}\t{s}\n", .{ @tagName(info.command), info.summary });
        }
    }

    fn completeName(arena: Allocator, w: *Io.Writer, seen: *std.StringHashMapUnmanaged(void), prefix: []const u8, name: []const u8, description: []const u8) !void {
        if (!std.mem.startsWith(u8, name, prefix)) return;
        if ((try seen.getOrPut(arena, name)).found_existing) return;
        if (description.len > 0) {
            try w.print("{s}\t{s}\n", .{ name, description });
        } else {
            try w.print("{s}\n", .{name});
        }
    }

    // -- system ---------------------------------------------------------------

    fn requireSystem(app: *App) !deploy.System {
        const current = app.runningDeployment() orelse
            return app.fail("this command only applies to a running joe Linux system", .{});
        return app.openSystem(current);
    }

    fn cmdStatus(app: *App) !void {
        const current = app.runningDeployment() orelse {
            const ctx = try app.context();
            return app.say("{d} packages installed in {s} (not a deployment-managed system).", .{ ctx.installed.len, app.opts.root });
        };
        if (linux.geteuid() != 0) {
            const view = app.publishedView(current) orelse {
                try app.say("Running deployment {d}.", .{current});
                return app.say("Until dave-status.service has run at boot, only root can see the other deployments " ++
                    "and any pending upgrade; 'sudo dave status' shows them.", .{});
            };
            return app.printStatus(current, view);
        }
        var sys = try app.openSystem(current);
        try app.printStatus(current, try sys.overview());
    }

    fn printStatus(app: *App, current: u32, view: deploy.System.Overview) !void {
        try app.say("Running deployment {d}.", .{current});
        for (view.deployments) |d| {
            if (d.next_boot and !d.running) try app.say("Deployment {d} will start on the next boot.", .{d.id});
        }
        if (view.staged) |staged| {
            try app.say("An upgrade is ready ({s}); it will be applied at shutdown.", .{staged.summary});
        }
        if (view.last_finalize) |last| {
            if (!last.ok) try app.say("The last upgrade could not be applied: {s}", .{last.message});
        }
        try app.say("", .{});
        try app.printDeployments(view);
    }

    fn printDeployments(app: *App, view: deploy.System.Overview) !void {
        for (view.deployments) |d| {
            const health: []const u8 = if (d.health) |h| switch (h) {
                .good => "good",
                .trial => "untested",
                .bad => "failed",
            } else "no boot entry";
            const mark: []const u8 = if (d.running) "*" else if (d.next_boot) ">" else " ";
            const pinned: []const u8 = if (d.record != null and d.record.?.pinned) "  pinned" else "";
            const reason: []const u8 = if (d.record) |r| r.reason else "";
            try app.say("{s} {d:>4}  {s:<13}{s}  {s}", .{ mark, d.id, health, pinned, reason });
        }
        try app.say("\n* running   > starts on next boot", .{});
    }

    fn cmdRollback(app: *App) !void {
        var lock_file = try app.lock();
        defer lock_file.close(app.io);
        var sys = try app.requireSystem();
        const target = sys.rollback() catch |e| {
            if (sys.diag.message.len > 0) return app.fail("{s}", .{sys.diag.message});
            return app.fail("cannot roll back: {t}", .{e});
        };
        try app.say("Deployment {d} will start on the next boot, and on every boot after it.", .{target});
        const missing = sys.accountsMissingIn(target) catch &.{};
        if (missing.len > 0) {
            const names = try std.mem.join(app.arena, ", ", missing);
            try app.say("Warning: deployment {d} was made before these accounts were created: {s}.", .{ target, names });
            try app.say("Their files under /home are kept, but they cannot log in there until the accounts are created again.", .{});
        }
        try app.say("Reboot to return to it.", .{});
    }

    fn cmdDeployments(app: *App, args: []const []const u8) !void {
        if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
            const current = app.runningDeployment() orelse
                return app.fail("this command only applies to a running joe Linux system", .{});
            if (linux.geteuid() != 0)
                return app.printDeployments(app.publishedView(current) orelse
                    return app.fail("until dave-status.service has run at boot, only root can list the deployments; " ++
                        "'sudo dave deployments' lists them", .{}));
            var sys = try app.openSystem(current);
            return app.printDeployments(try sys.overview());
        }
        var sys = try app.requireSystem();
        var lock_file = try app.lock();
        defer lock_file.close(app.io);
        if (std.mem.eql(u8, args[0], "gc")) {
            const removed = try sys.collectGarbage(deploy.default_keep);
            return app.say("Removed {d} deployment(s).", .{removed.len});
        }
        const pin = std.mem.eql(u8, args[0], "pin");
        if (!pin and !std.mem.eql(u8, args[0], "unpin")) return app.fail("unknown deployments command '{s}'", .{args[0]});
        if (args.len != 2) return app.fail("give one deployment id", .{});
        const id = std.fmt.parseInt(u32, args[1], 10) catch return app.fail("'{s}' is not a deployment id", .{args[1]});
        sys.setPinned(id, pin) catch |e| {
            if (sys.diag.message.len > 0) return app.fail("{s}", .{sys.diag.message});
            return e;
        };
        try app.say("Deployment {d} {s}.", .{ id, if (pin) "pinned" else "unpinned" });
    }

    /// Run by dave-finalize.service as the system shuts down.
    fn cmdFinalize(app: *App) !void {
        const current = app.runningDeployment() orelse return;
        var lock_file = try app.lock();
        defer lock_file.close(app.io);
        var sys = try app.openSystem(current);
        const outcome = (try sys.finalize()) orelse return;
        if (outcome.ok) {
            try app.say("Upgrade applied as deployment {d}; it will start on the next boot.", .{outcome.deployment.?});
        } else {
            // Not an error exit: the shutdown must proceed and the old system
            // boots unchanged. `dave status` reports this afterwards.
            app.err.print("dave: the upgrade could not be applied: {s}\n", .{outcome.message}) catch {};
        }
    }

    /// Run by dave-boot-check.service on the first boots of a new deployment.
    /// Exiting non-zero makes systemd reboot, which counts as a failed attempt.
    fn cmdBootCheck(app: *App) !void {
        const current = app.runningDeployment() orelse return;
        // dynamod starts this at every boot; only a deployment on trial is
        // checked, as systemd starts its unit only then. Nothing before this
        // test may fail, or a good deployment would be rebooted at every boot.
        if (!app.countedBoot()) {
            app.publishStatus();
            return;
        }
        for ([_][]const u8{ "/var", esp_path }) |point| {
            if (app.findMount(point) == null) return app.fail("boot check failed: {s} is not mounted", .{point});
        }
        // A system installed beside another keeps its boot entries on /boot.
        if (app.readAbsolute("/etc/fstab")) |table| {
            if (std.mem.indexOf(u8, table, " " ++ boot_mount ++ " ") != null and app.findMount(boot_mount) == null)
                return app.fail("boot check failed: {s} is not mounted", .{boot_mount});
        }
        const root = try app.openDir("/");
        _ = db.load(app.arena, app.io, root) catch |e| return app.fail("boot check failed: the package database is unreadable: {t}", .{e});

        // Site-specific checks: every executable here must succeed.
        if (root.openDir(app.io, boot_check_hooks, .{ .iterate = true })) |hooks| {
            var it = hooks.iterate();
            while (try it.next(app.io)) |e| {
                const path = try std.fmt.allocPrint(app.arena, "/" ++ boot_check_hooks ++ "/{s}", .{e.name});
                var child = std.process.spawn(app.io, .{ .argv = &.{path}, .stdin = .ignore }) catch |err|
                    return app.fail("boot check failed: cannot run {s}: {t}", .{ path, err });
                const term = try child.wait(app.io);
                if (!term.success()) return app.fail("boot check failed: {s} reported a problem", .{path});
            }
        } else |_| {}

        try app.say("Deployment {d} passed its boot check.", .{current});
        var lock_file = try app.lock();
        defer lock_file.close(app.io);
        var sys = try app.openSystem(current);
        // Mark the boot good, which ends systemd-boot's counting: until then a
        // failed or hung boot brings back the previous deployment. Failing
        // here fails the check, and a deployment that cannot be marked good
        // is left to run out of attempts, the safe way round.
        if (boot.bless(app.arena, app.io, sys.bootDir(), current)) |blessed| {
            if (blessed) try app.say("Deployment {d} is marked good.", .{current});
        } else |e| return app.failErr(e, "boot check failed: cannot mark deployment {d} good", .{current});
        // Housekeeping is best effort; it must never fail a healthy boot.
        // Left by an upgrade made with dave 0.2.1 or earlier (deploy.zig).
        _ = sys.removeHiddenSubvolumes() catch {};
        _ = sys.collectGarbage(deploy.default_keep) catch {};
    }

    /// Whether the boot loader is counting this boot's attempts: systemd-boot
    /// sets LoaderBootCountPath when it starts an entry whose name carries a
    /// counter, and systemd-bless-boot-generator decides by it too.
    fn countedBoot(app: *App) bool {
        const variable = "/sys/firmware/efi/efivars/LoaderBootCountPath-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f";
        _ = Io.Dir.cwd().statFile(app.io, variable, .{}) catch return false;
        return true;
    }

    /// How long a deployment on trial may take to pass its boot check.
    const boot_watchdog_limit_s = 10 * 60;

    /// Run at boot by the dave-boot-watchdog service. A deployment on trial
    /// (its boot entry still counts attempts) that has not passed its boot
    /// check within ten minutes is abandoned: the machine restarts at once,
    /// without a clean shutdown, which could hang as the boot did, and
    /// systemd-boot counts the attempt as failed. On a systemd system the
    /// same is boot-complete.target's job timeout.
    fn cmdBootWatchdog(app: *App) !void {
        if (!app.countedBoot()) return;
        const current = app.runningDeployment() orelse return;
        var sys = app.openSystem(current) catch return;
        const started = Io.Timestamp.now(app.io, .awake);
        while (true) {
            // An entry that cannot be read is not waited for: the boot check
            // reports that itself.
            const counted = boot.isCounted(app.arena, app.io, sys.bootDir(), current) catch return;
            if (!counted) return;
            const elapsed = Io.Timestamp.now(app.io, .awake).nanoseconds - started.nanoseconds;
            if (elapsed >= boot_watchdog_limit_s * std.time.ns_per_s) break;
            try app.io.sleep(.fromSeconds(5), .awake);
        }
        try app.say("Deployment {d} has not passed its boot check in ten minutes. Restarting.", .{current});
        try app.out.flush();
        _ = linux.sync();
        _ = linux.reboot(.MAGIC1, .MAGIC2, .RESTART, null);
        return app.fail("cannot restart the machine", .{});
    }

    // -- building -------------------------------------------------------------

    fn absolute(app: *App, path: []const u8) ![]const u8 {
        if (std.fs.path.isAbsolute(path)) return path;
        const cwd = try Io.Dir.cwd().realPathFileAlloc(app.io, ".", app.arena);
        return std.fs.path.join(app.arena, &.{ cwd, path });
    }

    fn codeKey(app: *App) !?seal.SigningKey {
        const path = app.opts.code_key orelse return null;
        const text = app.readAbsolute(path) orelse return app.fail("cannot read code-signing key {s}", .{path});
        return seal.SigningKey.parse(text) catch app.fail("{s} is not a code-signing key", .{path});
    }

    fn cmdBuild(app: *App, args: []const []const u8) !void {
        if (args.len != 1) return app.fail("give one recipe directory", .{});
        const recipe_dir = try app.absolute(args[0]);
        const driver = if (app.opts.driver) |d|
            try app.absolute(d)
        else
            try std.fs.path.join(app.arena, &.{ std.fs.path.dirname(recipe_dir) orelse "/", ".build", "driver.sh" });
        var diag: builder.Diagnostic = .{};
        const file = builder.build(app.arena, app.io, .{
            .recipe_dir = recipe_dir,
            .build_root = try app.absolute(app.opts.buildroot orelse return app.fail("--buildroot is required", .{})),
            .sources_dir = try app.absolute(app.opts.sources orelse return app.fail("--sources is required", .{})),
            .work_dir = try app.absolute(app.opts.work orelse return app.fail("--work is required", .{})),
            .out_dir = try app.absolute(app.opts.out orelse return app.fail("--out is required", .{})),
            .driver = driver,
            .jobs = std.Thread.getCpuCount() catch 1,
            .keep_work = app.opts.keep_work,
            .code_key = try app.codeKey(),
            .default_allow = app.opts.allow.items,
        }, &diag) catch |e| {
            if (diag.message.len > 0) return app.fail("{s}", .{diag.message});
            return app.fail("cannot build {s}: {t}", .{ args[0], e });
        };
        try app.say("{s}", .{file});
    }

    fn cmdPack(app: *App, args: []const []const u8) !void {
        if (args.len != 1) return app.fail("give the directory to pack", .{});
        const name = app.opts.name orelse return app.fail("--name is required", .{});
        const pkg_version = app.opts.pkg_version orelse return app.fail("--version is required", .{});
        const out_path = app.opts.out orelse return app.fail("--out is required", .{});
        if (!manifest.validName(name)) return app.fail("'{s}' is not a valid package name", .{name});
        _ = version.Version.parse(pkg_version) catch return app.fail("'{s}' is not a valid version", .{pkg_version});
        if (std.mem.lastIndexOf(u8, pkg_version, "-r") == null) return app.fail("the version needs a release, e.g. {s}-r1", .{pkg_version});
        for (app.opts.depends.items) |d| {
            _ = range.Range.parse(app.arena, manifest.splitDependency(d).constraint) catch return app.fail("cannot understand dependency '{s}'", .{d});
        }
        const src = try app.openDir(args[0]);
        Io.Dir.cwd().createDirPath(app.io, out_path) catch {};
        const out_dir = try app.openDir(out_path);
        const file = archive.pack(app.arena, app.io, .{
            .meta = .{
                .name = name,
                .version = pkg_version,
                .arch = arch.name,
                .description = app.opts.description,
                .license = app.opts.license,
                .depends = app.opts.depends.items,
                .conflicts = app.opts.conflicts.items,
                .operations = if (app.opts.allow.items.len > 0) &.{.{ .allow = app.opts.allow.items }} else &.{},
            },
            .src = src,
            .out_dir = out_dir,
            .code_key = try app.codeKey(),
        }) catch |e| return app.fail("cannot pack {s}: {t}", .{ args[0], e });
        try app.say("{s}/{s}", .{ out_path, file });
    }

    fn cmdRepo(app: *App, args: []const []const u8) !void {
        if (args.len != 2 or (!std.mem.eql(u8, args[0], "index") and !std.mem.eql(u8, args[0], "audit")))
            return app.fail("usage: dave repo index|audit <dir>", .{});
        const dir = try app.openDir(args[1]);
        if (std.mem.eql(u8, args[0], "audit")) {
            const problems = repo.audit(app.gpa, app.arena, app.io, dir, app.out) catch |e|
                return app.fail("cannot audit {s}: {t}", .{ args[1], e });
            if (problems > 0) {
                try app.say("{d} security problem(s) found.", .{problems});
                return error.Reported;
            }
            try app.say("No seal or declaration problems found.", .{});
            return;
        }
        const secret: ?[]const u8 = if (app.opts.key) |path|
            app.readAbsolute(path) orelse return app.fail("cannot read key {s}", .{path})
        else
            null;
        var foreign: repo.ForeignPackage = .{};
        const count = repo.writeIndex(app.gpa, app.arena, app.io, dir, secret, &foreign) catch |e| switch (e) {
            error.WrongArchitecture => return app.fail("cannot index {s}: {s} is a package for {s}, but this dave manages {s} systems", .{ args[1], foreign.filename, foreign.arch, arch.name }),
            else => return app.fail("cannot index {s}: {t}", .{ args[1], e }),
        };
        try app.say("Indexed {d} package(s){s}.", .{ count, if (secret == null) " (unsigned)" else "" });
    }

    fn cmdKey(app: *App, args: []const []const u8) !void {
        if (args.len != 2) return app.fail("usage: dave key generate|generate-code <basename>", .{});
        const code = std.mem.eql(u8, args[0], "generate-code");
        if (!code and !std.mem.eql(u8, args[0], "generate")) return app.fail("usage: dave key generate|generate-code <basename>", .{});
        const secret_path = try std.fmt.allocPrint(app.arena, "{s}.key", .{args[1]});
        const public_path = try std.fmt.allocPrint(app.arena, "{s}.pub", .{args[1]});
        var secret: []const u8 = undefined;
        var public: []const u8 = undefined;
        if (code) {
            const key = seal.generateKey(app.io);
            secret = try app.arena.dupe(u8, &key.secret_hex);
            public = try app.arena.dupe(u8, &key.public_hex);
        } else {
            const key = repo.generateKey(app.io);
            secret = try app.arena.dupe(u8, &key.secret_hex);
            public = try app.arena.dupe(u8, &key.public_hex);
        }
        const cwd = Io.Dir.cwd();
        cwd.writeFile(app.io, .{ .sub_path = secret_path, .data = secret, .flags = .{ .exclusive = true, .permissions = .fromMode(0o600) } }) catch |e|
            return app.fail("cannot write {s}: {t}", .{ secret_path, e });
        cwd.writeFile(app.io, .{ .sub_path = public_path, .data = public }) catch |e|
            return app.fail("cannot write {s}: {t}", .{ public_path, e });
        if (code) {
            try app.say("Wrote {s} (keep secret) and {s} (built into the kernel).", .{ secret_path, public_path });
        } else {
            try app.say("Wrote {s} (keep secret) and {s} (install into {s}/).", .{ secret_path, public_path, repo.keys_path });
        }
    }

    /// Seals every installed file whose manifest carries a seal and which is
    /// not sealed yet. An image assembled without privileges cannot seal its
    /// files, so this runs on its first boot; afterwards it finds nothing to do.
    fn cmdSeal(app: *App) !void {
        const root = try app.openDir(app.opts.root);
        // Invalidate an older marker before anything that can fail. Otherwise
        // dave-seal.service would suppress all later attempts after a bad pass.
        root.deleteFile(app.io, sealed_marker) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return app.fail("cannot invalidate the old sealed marker: {t}", .{e}),
        };
        const installed = db.load(app.arena, app.io, root) catch |e| return app.fail("the package database is unreadable: {t}", .{e});
        var done: usize = 0;
        var already: usize = 0;
        var invalid: usize = 0;
        var modified: usize = 0;
        var impossible: usize = 0;
        for (installed) |m| {
            for (m.files) |f| {
                if (f.kind != .file or f.config) continue;
                const signature_text = f.seal orelse {
                    invalid += 1;
                    continue;
                };
                const verity_text = f.verity orelse {
                    invalid += 1;
                    continue;
                };
                const signature = seal.parseSignature(signature_text) orelse {
                    invalid += 1;
                    continue;
                };
                const verity = seal.parseDigest(verity_text) orelse {
                    invalid += 1;
                    continue;
                };
                const ops = seal.operationsText(app.arena, m.operations, f.path) catch {
                    invalid += 1;
                    continue;
                };
                const value = try seal.attribute(app.arena, ops, signature);
                if (seal.isApplied(app.io, root, f.path, verity, value, seal.xattr_name)) {
                    already += 1;
                    continue;
                }
                // Sealing fixes the contents for good, so only seal what the
                // package actually shipped. Missing and unreadable files are
                // failures too, never a reason to mark the root complete.
                const actual = seal.verityDigestOfFile(app.io, root, f.path) catch {
                    invalid += 1;
                    continue;
                };
                if (!std.mem.eql(u8, &actual, &verity)) {
                    modified += 1;
                    continue;
                }
                switch (seal.apply(app.io, root, f.path, value, seal.xattr_name) catch |e|
                    return app.fail("cannot seal {s}: {t}", .{ f.path, e })) {
                    .sealed => done += 1,
                    .not_possible => impossible += 1,
                }
            }
        }
        try app.say("Sealed {d} file(s); {d} were already sealed.", .{ done, already });
        if (invalid > 0) return app.fail("{d} file(s) have missing, malformed, or unreadable seals", .{invalid});
        if (modified > 0) return app.fail("{d} file(s) differ from what their package shipped and were left unsealed", .{modified});
        if (impossible > 0) return app.fail("{d} file(s) could not be sealed: the file system lacks fs-verity or this is not root", .{impossible});
        // Tells dave-seal.service that this root needs no further pass.
        root.writeFile(app.io, .{ .sub_path = sealed_marker, .data = "" }) catch |e|
            return app.fail("cannot mark this root as sealed: {t}", .{e});
    }

    // -- images ---------------------------------------------------------------

    fn cmdImage(app: *App, args: []const []const u8) !void {
        if (args.len != 2 or !std.mem.eql(u8, args[0], "build"))
            return app.fail("usage: dave image build <spec> --out FILE [--test] [--repo NAME,DIR,URL,KEY]... [--with PACKAGE]... [--tree DIR]", .{});
        const out = app.opts.out orelse return app.fail("--out is required", .{});
        // Every file in the image must be owned by root. Without privileges,
        // the build runs where this user is root: a user namespace.
        if (linux.getuid() != 0) return app.reenterAsRoot();
        app.seal = false;

        const spec_path = try app.absolute(args[1]);
        const text = app.readAbsolute(spec_path) orelse return app.fail("cannot read {s}", .{args[1]});
        var diag: image.Diagnostic = .{};
        const spec = image.parseSpec(app.arena, text, args[1], &diag) catch |e| switch (e) {
            error.InvalidSpec => return app.fail("{s}", .{diag.message}),
            else => return e,
        };
        var repos: std.ArrayList(image.RepoArg) = .empty;
        for (app.opts.repos.items) |r| {
            try repos.append(app.arena, image.parseRepoArg(r) catch
                return app.fail("--repo takes NAME,DIR,URL,KEY, not {s}", .{r}));
        }
        const out_path = try app.absolute(out);
        var b: image.Builder = .{
            .arena = app.arena,
            .io = app.io,
            .spec = spec,
            .spec_dir = std.fs.path.dirname(spec_path) orelse "/",
            .out = out_path,
            .work = try std.fmt.allocPrint(app.arena, "{s}.work", .{out_path}),
            .repos = repos.items,
            .test_image = app.opts.test_image,
            .tree_override = if (app.opts.tree) |t| try app.absolute(t) else null,
            .extra_packages = app.opts.with.items,
        };
        defer b.cleanup();
        const packages = try b.packages();
        if (packages.len > 0 and repos.items.len == 0) return app.fail("{s} installs packages: name where they come from with --repo", .{args[1]});

        try app.say("==> {s}: the root", .{spec.name});
        b.prepareTree() catch |e| return app.imageFailed(&b, e);
        if (packages.len > 0) {
            if (app.opts.test_image) {
                if (app.environ) |env| try env.put("CREDENTIALS_DIRECTORY", image.Builder.credentials_path);
            }
            app.opts.root = try b.treePath();
            app.opts.cache = null;
            try app.cmdChange(.install, packages, .internal);
        }
        b.finishTree() catch |e| return app.imageFailed(&b, e);
        switch (spec.format) {
            .disk => {
                try app.say("==> {s}: disk image", .{spec.name});
                b.dropCache() catch |e| return app.imageFailed(&b, e);
                b.buildDisk() catch |e| return app.imageFailed(&b, e);
            },
            .iso => {
                try app.say("==> {s}: the initramfs", .{spec.name});
                b.prepareInitrd() catch |e| return app.imageFailed(&b, e);
                app.opts.root = try b.initrdPath();
                app.opts.cache = null;
                try app.cmdChange(.install, spec.iso.?.initrd.packages, .internal);
                b.finishInitrd() catch |e| return app.imageFailed(&b, e);
                try app.say("==> {s}: what the installer installs", .{spec.name});
                const count = try app.mediumOriginals(&b);
                try app.say("==> {s}: the medium, whose installer installs {d} packages from its root", .{ spec.name, count });
                b.dropCache() catch |e| return app.imageFailed(&b, e);
                b.buildIso() catch |e| return app.imageFailed(&b, e);
            },
            .oci => {
                try app.say("==> {s}: container image", .{spec.name});
                b.dropCache() catch |e| return app.imageFailed(&b, e);
                b.buildOci() catch |e| return app.imageFailed(&b, e);
            },
        }
        try app.say("image ready: {s}", .{out});
    }

    /// Checks that the installer can install from the live root (it copies
    /// the payload's packages out of it), and gathers in the builder's
    /// originals directory, from the package files, every file of theirs the
    /// live root holds changed. Returns how many packages the installer
    /// installs.
    fn mediumOriginals(app: *App, b: *image.Builder) !usize {
        var tree = try app.openDir(try b.treePath());
        defer tree.close(app.io);
        const installed = db.load(app.arena, app.io, tree) catch |e|
            return app.failErr(e, "the live root's package database is unreadable", .{});
        const solution = try app.solveFromRoot(installed, &.{}, try b.payload(), "the live root");
        const payload = try app.arena.alloc(manifest.Manifest, solution.install.len);
        for (solution.install, payload) |u, *m| m.* = findInstalled(installed, u.candidate.entry.name).?;
        const changed = install_system.changedFiles(app.arena, app.io, tree, payload) catch |e|
            return app.failErr(e, "cannot check the live root's files", .{});

        const originals_path = try b.originalsPath();
        Io.Dir.cwd().createDirPath(app.io, originals_path) catch |e| return app.failErr(e, "cannot create {s}", .{originals_path});
        var originals = try app.openDir(originals_path);
        defer originals.close(app.io);
        const cache_path = "var/cache/dave/" ++ repo.packages_dir;
        var cache = tree.openDir(app.io, cache_path, .{}) catch |e|
            return app.failErr(e, "the live root has no package files in {s}", .{cache_path});
        defer cache.close(app.io);
        for (changed) |c| {
            try app.say("    the live root changes {s} ({s}); the medium keeps the original", .{ c.file.path, c.package.name });
            var file = try originals.createFile(app.io, c.file.sha256.?, .{});
            defer file.close(app.io);
            var buf: [64 * 1024]u8 = undefined;
            var w = file.writer(app.io, &buf);
            archive.extractFile(app.gpa, app.arena, app.io, cache, try c.package.fileName(app.arena), c.file.path, &w.interface) catch |e|
                return app.failErr(e, "cannot take the original of {s} from {s}'s package file", .{ c.file.path, c.package.name });
            try w.interface.flush();
        }
        return payload.len;
    }

    fn imageFailed(app: *App, b: *image.Builder, e: anyerror) Failure {
        if (b.diag.message.len > 0) return app.fail("{s}", .{b.diag.message});
        return app.fail("the image could not be built: {t}", .{e});
    }

    /// Runs this same command again as root of a new user namespace, through
    /// unshare(1): a process with more than one thread (and the I/O
    /// implementation may have started some) cannot enter one itself.
    fn reenterAsRoot(app: *App) Failure {
        const exe = std.process.executablePathAlloc(app.io, app.arena) catch |e|
            return app.fail("cannot find the dave executable: {t}", .{e});
        var argv: std.ArrayList([]const u8) = .empty;
        argv.appendSlice(app.arena, &.{ "unshare", "--map-root-user", exe }) catch return app.fail("out of memory", .{});
        argv.appendSlice(app.arena, app.argv) catch return app.fail("out of memory", .{});
        app.out.flush() catch {};
        app.err.flush() catch {};
        const e = std.process.replace(app.io, .{ .argv = argv.items, .environ_map = app.environ });
        return app.fail("cannot enter a user namespace with unshare(1): {t}", .{e});
    }

    // -- installing onto a disk ------------------------------------------------

    fn cmdInstallSystem(app: *App, args: []const []const u8) !void {
        if (args.len != 0 or (app.opts.list == (app.opts.disk != null)) or (app.opts.beside and app.opts.list))
            return app.fail("usage: dave install-system --list [--json] | --disk DISK [--beside] [--json]", .{});
        if (app.opts.json) {
            // Events alone on standard output; everything said for people
            // (and what the programs dave runs say) on standard error.
            app.events = app.out;
            app.out = app.err;
        }
        if (app.opts.list) return app.listDisks();
        app.installSystem(app.opts.disk.?) catch |e| {
            app.event("error", if (app.last_error.len > 0) app.last_error else @errorName(e), null);
            return e;
        };
        app.event("done", "joe Linux is installed", 1);
    }

    fn findDisks(app: *App) ![]install_system.Disk {
        var diag: command.Diagnostic = .{};
        const listing = command.run(app.arena, app.io, &install_system.lsblk_argv, .{ .capture = true }, &diag) catch |e| switch (e) {
            error.CommandFailed => return app.fail("{s}", .{diag.message}),
            else => return e,
        };
        const medium = install_system.mountSource(app.readAbsolute("/proc/self/mountinfo") orelse "", install_system.medium_mount);
        return install_system.parseDisks(app.arena, listing, try install_system.readById(app.arena, app.io), medium) catch
            app.fail("cannot understand what lsblk says about this computer's disks", .{});
    }

    fn listDisks(app: *App) !void {
        const disks = try app.findDisks();
        if (app.events) |w| {
            std.json.Stringify.value(.{ .disks = disks }, .{}, w) catch {};
            w.writeByte('\n') catch {};
            return;
        }
        for (disks) |d| {
            try app.say("{s}  {d} GB  {s}{s}{s}", .{
                d.path,                                       d.size / 1_000_000_000, if (d.model.len > 0) d.model else "-",
                if (d.usable) "" else "  cannot be erased: ", d.reason,
            });
            if (d.beside.possible) {
                try app.say("    --beside: {d} GB of free space, beside {s}", .{
                    d.beside.size / 1_000_000_000, try besideWhat(app.arena, d.beside),
                });
            } else if (d.partitions.len > 0) {
                try app.say("    --beside: cannot be used: {s}", .{d.beside.reason});
            }
        }
    }

    fn installSystem(app: *App, disk_arg: []const u8) !void {
        if (linux.getuid() != 0) return app.fail("installing joe Linux needs root", .{});
        const medium_dir = install_system.medium_dir;
        const spec_path = medium_dir ++ "/" ++ install_system.install_file;
        const spec_text = app.readAbsolute(spec_path) orelse
            return app.fail("{s} is missing: is this joe Linux's installation medium?", .{spec_path});
        const medium = install_system.parseMedium(app.arena, spec_text) catch return app.fail("{s} is unreadable", .{spec_path});
        var packages: std.ArrayList([]const u8) = .empty;
        try packages.appendSlice(app.arena, medium.packages);
        try packages.appendSlice(app.arena, app.opts.with.items);

        // The packages come out of the medium's root image, where they are
        // installed. What it cannot provide is refused before the disk is
        // touched.
        var source = Io.Dir.cwd().openDir(app.io, install_system.live_root, .{}) catch
            return app.fail("the medium's root image is not mounted at {s}: is this joe Linux's installation medium?", .{install_system.live_root});
        defer source.close(app.io);
        const offered = db.load(app.arena, app.io, source) catch |e|
            return app.failErr(e, "the package database of {s} is unreadable", .{install_system.live_root});
        const solution = try app.solveFromRoot(offered, &.{}, packages.items, "the medium");
        var originals: ?Io.Dir = Io.Dir.cwd().openDir(app.io, medium_dir ++ "/" ++ install_system.originals_dir, .{}) catch null;
        defer if (originals) |*d| d.close(app.io);

        // The disk, as a listing would show it: whatever a listing refuses,
        // installing refuses too.
        const device = Io.Dir.cwd().realPathFileAlloc(app.io, disk_arg, app.arena) catch
            return app.fail("there is no disk {s}", .{disk_arg});
        const disk = for (try app.findDisks()) |d| {
            if (std.mem.eql(u8, d.device, device)) break d;
        } else return app.fail("{s} is not a disk this system can install onto", .{disk_arg});
        if (app.opts.beside) {
            if (!disk.beside.possible)
                return app.fail("joe Linux cannot be installed beside what is on {s}: {s}", .{ disk_arg, disk.beside.reason });
        } else if (!disk.usable) return app.fail("{s} cannot be used: {s}", .{ disk_arg, disk.reason });

        var lock_file = try app.lock();
        defer lock_file.close(app.io);
        const live_config = repo.loadConfig(app.arena, app.io, try app.openDir("/")) catch
            return app.fail("this system's {s} is unreadable", .{repo.config_path});
        if (live_config.repos.len == 0) return app.fail("this system has no repositories configured ({s})", .{repo.config_path});

        var disks: install_system.Disks = .{ .arena = app.arena, .io = app.io };
        defer disks.unmountTarget();
        const name = if (disk.model.len > 0) disk.model else device;
        // Beside another system: its ESP shared, joe's partitions in the free
        // space. Otherwise: the whole disk.
        var beside: ?provision.Beside = null;
        var root_uuid: provision.Uuid = undefined;
        var fstab: []const u8 = undefined;
        // The ESP, for the firmware's boot entry.
        var esp_device: []const u8 = undefined;
        var esp_uuid_text: []const u8 = undefined;
        if (app.opts.beside) {
            var esp_uuid: provision.Uuid = undefined;
            @memcpy(&esp_uuid, disk.beside.esp[0..esp_uuid.len]);
            const b = provision.Beside.new(app.io, esp_uuid, disk.beside.start, disk.beside.size);
            app.step(0.01, "Adding joe Linux beside {s} on {s}", .{ try besideWhat(app.arena, disk.beside), name });
            const parts = disks.addBeside(device, b) catch return app.fail("{s}", .{disks.diag.message});
            app.step(0.03, "Creating file systems", .{});
            disks.formatBeside(parts.xbootldr, parts.root) catch return app.fail("{s}", .{disks.diag.message});
            const esp_device_link = try std.fmt.allocPrint(app.arena, "/dev/disk/by-partuuid/{s}", .{disk.beside.esp});
            disks.mountTarget(esp_device_link, parts.root) catch return app.fail("{s}", .{disks.diag.message});
            disks.mountBoot(parts.xbootldr) catch return app.fail("{s}", .{disks.diag.message});
            beside = b;
            esp_device = esp_device_link;
            esp_uuid_text = disk.beside.esp;
            root_uuid = b.root_uuid;
            fstab = try provision.fstabBeside(app.arena, b);
        } else {
            const layout = provision.Plan.new(app.io, provision.default_esp_size, null);
            app.step(0.01, "Erasing {s}", .{name});
            const parts = disks.partition(device, layout) catch return app.fail("{s}", .{disks.diag.message});
            app.step(0.03, "Creating file systems", .{});
            disks.format(parts.esp, parts.root) catch return app.fail("{s}", .{disks.diag.message});
            disks.mountTarget(parts.esp, parts.root) catch return app.fail("{s}", .{disks.diag.message});
            esp_device = parts.esp;
            esp_uuid_text = try app.arena.dupe(u8, &layout.esp_uuid);
            root_uuid = layout.root_uuid;
            fstab = try provision.fstab(app.arena, layout);
        }

        // The new system trusts what this one trusts, and takes its packages
        // from where this one would.
        const target_path = install_system.target_mount;
        var target = try app.openDir(target_path);
        defer target.close(app.io);
        try target.createDirPath(app.io, repo.keys_path);
        {
            var keys = try app.openDir("/" ++ repo.keys_path);
            defer keys.close(app.io);
            var it = keys.iterate();
            while (try it.next(app.io)) |e| {
                if (e.kind != .file) continue;
                try keys.copyFile(e.name, target, try std.fs.path.join(app.arena, &.{ repo.keys_path, e.name }), app.io, .{});
            }
        }
        try target.writeFile(app.io, .{ .sub_path = repo.config_path, .data = app.readAbsolute("/" ++ repo.config_path) orelse "" });

        app.step(0.05, "Installing packages", .{});
        const copies = try app.arena.alloc(txn.Copy, solution.install.len);
        for (solution.install, copies) |u, *c| c.* = .{
            .manifest = findInstalled(offered, u.candidate.entry.name).?,
            .from = source,
            .originals = originals,
        };
        var reporter: InstallProgress = .{ .app = app };
        app.opts.root = target_path;
        try app.applyPlan(target, .{ .copy = copies, .progress = reporter.interface() });
        var world: std.ArrayList(db.WorldEntry) = .empty;
        for (packages.items) |n| try world.append(app.arena, .{ .name = n });
        try db.saveWorld(app.arena, app.io, target, world.items);

        app.step(0.88, "Sealing the installed files", .{});
        try app.cmdSeal();

        app.step(0.94, "Making the disk bootable", .{});
        try target.writeFile(app.io, .{ .sub_path = "etc/fstab", .data = fstab });
        const kernel = deploy.findKernelIn(app.arena, app.io, target) catch return app.fail("the installed system has no kernel", .{});
        const consoles = try provision.consoleArgs(app.arena, app.readAbsolute("/proc/cmdline") orelse "");
        const options = try provision.cmdlineFor(app.arena, root_uuid, consoles);
        if (beside != null) {
            // joe-base's repart.d grows the first partition of type "root" on
            // the disk into free space at every boot. Beside another Linux,
            // that could be the other system's; joe already has its space.
            try target.createDirPath(app.io, "etc/repart.d");
            target.symLink(app.io, "/dev/null", "etc/repart.d/50-root.conf", .{}) catch |e|
                return app.failErr(e, "cannot turn off growing the root partition", .{});
        }
        try std.posix.syncfs(target.handle);
        // Closed before the target is unmounted, as the ESP is mounted in it.
        {
            var esp = try app.openDir(target_path ++ "/" ++ provision.esp_mount);
            defer esp.close(app.io);
            if (beside != null) {
                var xbootldr = try app.openDir(target_path ++ "/" ++ provision.xbootldr_mount);
                defer xbootldr.close(app.io);
                provision.writeBeside(app.arena, app.io, esp, xbootldr, .{ .root = target, .kernel_path = kernel }, options) catch |e|
                    return app.failErr(e, "cannot write the boot partitions", .{});
                try boot.syncFilesystem(app.io, xbootldr);
            } else {
                provision.writeEsp(app.arena, app.io, esp, .{ .root = target, .kernel_path = kernel }, options) catch |e|
                    return app.fail("cannot write the EFI system partition: {t}", .{e});
            }
            try boot.syncFilesystem(app.io, esp);
            // Tell the firmware where the boot loader is: a boot entry, first in
            // its boot order, as `bootctl install --variables=yes` makes one
            // (joe has no bootctl). A firmware that cannot be told still finds
            // the loader at the removable-media path.
            if (efiboot.partitionOf(app.arena, app.io, esp_device, esp_uuid_text)) |part| {
                if (efiboot.register(app.arena, app.io, part, boot.loader_targets[0], "joe Linux")) |_| {} else |e|
                    app.say("note: the firmware was not told about the new system ({t}); it starts from the disk's removable-media path", .{e}) catch {};
            } else |e| app.say("note: the firmware was not told about the new system (the EFI system partition: {t}); it starts from the disk's removable-media path", .{e}) catch {};
        }

        app.step(0.99, "Finishing", .{});
        _ = linux.sync();
        disks.unmountTarget();
    }

    /// "Windows", "Windows and Linux", or "another system".
    fn besideWhat(arena: Allocator, b: install_system.Beside) ![]const u8 {
        if (b.systems.len == 0) return "another system";
        return listNames(arena, b.systems, 3);
    }

    const InstallProgress = struct {
        app: *App,

        fn interface(p: *InstallProgress) txn.Progress {
            return .{ .context = p, .report = onPackage };
        }

        fn onPackage(ctx: *anyopaque, done: usize, total: usize, name: []const u8) void {
            const p: *InstallProgress = @ptrCast(@alignCast(ctx));
            const fraction = 0.05 + 0.83 * @as(f64, @floatFromInt(done)) / @as(f64, @floatFromInt(@max(total, 1)));
            const message = std.fmt.allocPrint(p.app.arena, "Installing packages ({d} of {d}: {s})", .{ done, total, name }) catch return;
            p.app.event("progress", message, fraction);
        }
    };

    /// `dave --chroot-exec <dir> [--tmpfs=PATH]... <program> [args...]`: used
    /// to run triggers inside a root other than the running one.
    fn chrootExec(app: *App, args: []const []const u8) !void {
        if (args.len < 2) return app.fail("--chroot-exec needs a directory and a program", .{});
        const dir = try app.arena.dupeSentinel(u8, args[0], 0);
        var program = args[1..];
        var covered: std.ArrayList([]const u8) = .empty;
        while (program.len > 0 and std.mem.startsWith(u8, program[0], triggers.tmpfs_flag)) : (program = program[1..]) {
            try covered.append(app.arena, program[0][triggers.tmpfs_flag.len..]);
        }
        if (program.len == 0) return app.fail("--chroot-exec needs a program", .{});

        // Programs expect /proc, /dev and /sys. They are bound into the root
        // inside a mount namespace of this process's own, so nothing outlives
        // the trigger and the host's mount table is never touched. If the
        // namespace cannot be made, the program simply runs without them.
        const CLONE_NEWNS = 0x00020000;
        const isolated = linux.errno(linux.unshare(CLONE_NEWNS)) == .SUCCESS;
        if (isolated) {
            _ = linux.mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, 0);
            for ([_][]const u8{ "proc", "dev", "sys" }) |name| {
                const source = try std.fmt.allocPrintSentinel(app.arena, "/{s}", .{name}, 0);
                const target = try std.fmt.allocPrintSentinel(app.arena, "{s}/{s}", .{ args[0], name }, 0);
                _ = linux.mount(source, target, null, linux.MS.BIND | linux.MS.REC, 0);
            }
        }
        // The directories a booted system mounts the shared subvolumes on
        // (triggers.RunOptions.shared). These are not optional: without them
        // the program would leave its work hidden in the root.
        for (covered.items) |name| {
            if (!isolated) return app.fail("cannot cover {s} in {s}: no mount namespace of its own", .{ name, args[0] });
            const target = try std.fmt.allocPrintSentinel(app.arena, "{s}/{s}", .{ args[0], name }, 0);
            Io.Dir.cwd().createDirPath(app.io, target) catch {};
            const rc = linux.mount("tmpfs", target, "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, @intFromPtr(@as([*:0]const u8, "mode=0755")));
            if (linux.errno(rc) != .SUCCESS) return app.fail("cannot cover {s} in {s}: {t}", .{ name, args[0], linux.errno(rc) });
        }

        if (linux.errno(linux.chroot(dir)) != .SUCCESS) return app.fail("cannot chroot to {s}", .{args[0]});
        if (linux.errno(linux.chdir("/")) != .SUCCESS) return app.fail("cannot enter {s}", .{args[0]});
        const e = std.process.replace(app.io, .{ .argv = program });
        return app.fail("cannot run {s} in {s}: {t}", .{ program[0], args[0], e });
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const raw = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw.len -| 1);
    for (args, raw[@min(raw.len, 1)..]) |*dst, src| dst.* = src;

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out_writer = Io.File.stdout().writer(init.io, &out_buf);
    var err_writer = Io.File.stderr().writer(init.io, &err_buf);
    var app: App = .{
        .gpa = init.gpa,
        .arena = arena,
        .io = init.io,
        .out = &out_writer.interface,
        .err = &err_writer.interface,
        .environ = init.environ_map,
    };
    var code: u8 = 0;
    app.run(args) catch |e| {
        code = 1;
        if (e != error.Reported) {
            var buf: [256]u8 = undefined;
            app.complain("unexpected failure: {s}", .{errors.text(&buf, e)});
        }
    };
    app.line.clear(app.out);
    out_writer.interface.flush() catch {};
    err_writer.interface.flush() catch {};
    std.process.exit(code);
}

test {
    std.testing.refAllDecls(@This());
}

test "the mount table can be read and the root found in it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var sink: Io.Writer.Allocating = .init(arena_state.allocator());
    var app: App = .{
        .gpa = std.testing.allocator,
        .arena = arena_state.allocator(),
        .io = std.testing.io,
        .out = &sink.writer,
        .err = &sink.writer,
    };
    try std.testing.expect(app.readAbsolute("/proc/self/mountinfo") != null);
    const root = app.findMount("/") orelse return error.RootMountNotFound;
    try std.testing.expect(root.fstype.len > 0);
    try std.testing.expect(app.findMount("/definitely/not/a/mount/point") == null);
}
