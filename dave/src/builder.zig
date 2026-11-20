//! `dave build`: turns a recipe into a package.
//!
//! A recipe is a directory holding `package.zon` (what the package is and
//! where its sources come from) and `build.sh` (shell functions `prepare`,
//! `build` and `package`). The build runs inside the build root, entered with
//! bubblewrap in a user namespace with no network; the staged result is then
//! packed by dave itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const manifest_mod = @import("manifest.zig");
const archive = @import("archive.zig");
const seal = @import("seal.zig");
const arch = @import("arch.zig");
const Version = @import("solver/version.zig").Version;
const Range = @import("solver/range.zig").Range;

pub const recipe_file = "package.zon";
pub const script_file = "build.sh";

pub const Source = struct {
    url: []const u8,
    sha256: []const u8,
    /// File name to store the download under; defaults to the last URL segment.
    file: ?[]const u8 = null,

    pub fn fileName(s: Source) []const u8 {
        if (s.file) |f| return f;
        const slash = std.mem.lastIndexOfScalar(u8, s.url, '/') orelse return s.url;
        return s.url[slash + 1 ..];
    }
};

pub const Recipe = struct {
    name: []const u8,
    /// The upstream version.
    version: []const u8,
    /// The packaging revision; bump it when the recipe changes.
    release: u32 = 1,
    description: []const u8 = "",
    license: []const u8 = "",
    /// The first source is the one unpacked by default.
    sources: []const Source = &.{},
    depends: []const []const u8 = &.{},
    conflicts: []const []const u8 = &.{},
    /// Packages that must be in the build root; used to order builds.
    build_depends: []const []const u8 = &.{},
    /// What the package's privileged programs declare they do; see
    /// `manifest.Operations`. Sealed into every file when the package is signed.
    operations: []const manifest_mod.Operations = &.{},
    /// Let the build reach the network. Builds are offline by default, so
    /// that a package is made only from its declared, checksummed sources.
    /// The exception exists for build systems that fetch their own
    /// dependencies (cargo) until those can be vendored as sources.
    network: bool = false,

    pub fn parse(arena: Allocator, text: []const u8) !Recipe {
        const r = manifest_mod.parseZon(Recipe, arena, text) catch return error.InvalidRecipe;
        if (!manifest_mod.validName(r.name)) return error.InvalidRecipe;
        _ = Version.parse(r.version) catch return error.InvalidRecipe;
        if (std.mem.indexOf(u8, r.version, "-r") != null) return error.InvalidRecipe;
        for (r.sources) |s| {
            const name = s.fileName();
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or name[0] == '.') return error.InvalidRecipe;
            if (s.sha256.len != 64) return error.InvalidRecipe;
        }
        for (r.depends) |d| _ = Range.parse(arena, manifest_mod.splitDependency(d).constraint) catch return error.InvalidRecipe;
        for (r.conflicts) |d| _ = Range.parse(arena, manifest_mod.splitDependency(d).constraint) catch return error.InvalidRecipe;
        for (r.operations) |entry| {
            _ = seal.operationsText(arena, &.{.{ .allow = entry.allow }}, "") catch return error.InvalidRecipe;
            for (entry.programs) |p| if (!manifest_mod.validPath(std.mem.trimStart(u8, p, "/"))) return error.InvalidRecipe;
        }
        return r;
    }

    /// `<version>-r<release>`, the version the package is published under.
    pub fn fullVersion(r: Recipe, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}-r{d}", .{ r.version, r.release });
    }
};

pub const Options = struct {
    /// Absolute paths.
    recipe_dir: []const u8,
    build_root: []const u8,
    sources_dir: []const u8,
    work_dir: []const u8,
    out_dir: []const u8,
    driver: []const u8,
    jobs: usize,
    /// Leave the work directory in place for inspection.
    keep_work: bool = false,
    /// Seal every file of the package with this code-signing key.
    code_key: ?seal.SigningKey = null,
    /// The declaration given to a recipe that makes none. Empty by default,
    /// so that programs nothing declares are sealed `undeclared`
    /// (`seal.operationsText`).
    default_allow: []const []const u8 = &.{},
};

pub const Diagnostic = struct {
    message: []const u8 = "",
};

/// `git+URL#COMMIT`: a source that is a commit of a git repository.
const GitSource = struct { repository: []const u8, commit: []const u8 };

fn gitSource(url: []const u8) ?GitSource {
    if (!std.mem.startsWith(u8, url, "git+")) return null;
    const rest = url["git+".len..];
    const hash = std.mem.lastIndexOfScalar(u8, rest, '#') orelse return null;
    const commit = rest[hash + 1 ..];
    if (commit.len < 7) return null;
    for (commit) |c| if (!std.ascii.isHex(c)) return null;
    return .{ .repository = rest[0..hash], .commit = commit };
}

test "git sources name a repository and a commit" {
    const g = gitSource("git+https://android.googlesource.com/platform/bionic#06356e41c5ed7b12220b24c05ba4fdb873b126a7").?;
    try std.testing.expectEqualStrings("https://android.googlesource.com/platform/bionic", g.repository);
    try std.testing.expectEqualStrings("06356e41c5ed7b12220b24c05ba4fdb873b126a7", g.commit);
    try std.testing.expect(gitSource("https://example.org/a.tar.xz") == null);
    try std.testing.expect(gitSource("git+https://example.org/repo#main") == null);
    try std.testing.expect(gitSource("git+https://example.org/repo") == null);
}

/// Downloads `source` into `dir` unless a file with the right checksum is
/// already there. A `git+URL#COMMIT` source is fetched with git.
fn ensureSource(arena: Allocator, io: Io, dir: Io.Dir, source: Source, diag: *Diagnostic) !void {
    const name = source.fileName();
    if (dir.statFile(io, name, .{})) |_| {} else |err| switch (err) {
        error.FileNotFound => {
            const tmp = try std.fmt.allocPrint(arena, ".{s}.partial", .{name});
            var child = if (gitSource(source.url)) |git|
                // A commit of a git repository, as the tar `git archive`
                // makes of it (with a top directory `src/`, which unpacking
                // strips). Some hosts, AOSP's among them, make their own
                // archives on demand with the time of the request in every
                // header, so no checksum could hold for them.
                try std.process.spawn(io, .{
                    .argv = &.{ "sh", "-ec",
                        \\d=$(mktemp -d "$PWD/.git-XXXXXX")
                        \\trap 'rm -rf "$d"' EXIT
                        \\git -C "$d" init -q
                        \\git -C "$d" fetch -q --depth 1 "$1" "$2"
                        \\git -C "$d" archive --format=tar --prefix=src/ "$2" >"$3"
                    , "sh", git.repository, git.commit, tmp },
                    .cwd = .{ .dir = dir },
                    .stdin = .ignore,
                })
            else
                try std.process.spawn(io, .{
                    .argv = &.{ "curl", "-fsSL", "--retry", "3", "-o", tmp, source.url },
                    .cwd = .{ .dir = dir },
                    .stdin = .ignore,
                });
            const term = try child.wait(io);
            if (!term.success()) {
                dir.deleteFile(io, tmp) catch {};
                diag.message = try std.fmt.allocPrint(arena, "cannot download {s}", .{source.url});
                return error.DownloadFailed;
            }
            try dir.rename(tmp, dir, name, io);
        },
        else => return err,
    }
    const digest = try archive.hashFile(io, dir, name);
    if (!std.mem.eql(u8, &digest, source.sha256)) {
        diag.message = try std.fmt.allocPrint(arena, "{s} has checksum {s}, but the recipe expects {s}", .{ name, digest, source.sha256 });
        return error.ChecksumMismatch;
    }
}

/// Builds the recipe and returns the name of the package file written to
/// `out_dir`.
pub fn build(arena: Allocator, io: Io, options: Options, diag: *Diagnostic) ![]const u8 {
    const cwd = Io.Dir.cwd();
    var recipe_dir = cwd.openDir(io, options.recipe_dir, .{}) catch {
        diag.message = try std.fmt.allocPrint(arena, "cannot open recipe directory {s}", .{options.recipe_dir});
        return error.InvalidRecipe;
    };
    defer recipe_dir.close(io);
    const text = recipe_dir.readFileAlloc(io, recipe_file, arena, .limited(1024 * 1024)) catch {
        diag.message = try std.fmt.allocPrint(arena, "{s} has no {s}", .{ options.recipe_dir, recipe_file });
        return error.InvalidRecipe;
    };
    const recipe = Recipe.parse(arena, text) catch |err| {
        diag.message = try std.fmt.allocPrint(arena, "{s}/{s} is not a valid recipe", .{ options.recipe_dir, recipe_file });
        return err;
    };
    _ = recipe_dir.statFile(io, script_file, .{}) catch {
        diag.message = try std.fmt.allocPrint(arena, "{s} has no {s}", .{ options.recipe_dir, script_file });
        return error.InvalidRecipe;
    };

    try cwd.createDirPath(io, options.sources_dir);
    var sources = try cwd.openDir(io, options.sources_dir, .{});
    defer sources.close(io);
    for (recipe.sources) |s| try ensureSource(arena, io, sources, s, diag);

    // A fresh work directory every time: nothing carries over between builds.
    const work = try std.fs.path.join(arena, &.{ options.work_dir, recipe.name });
    cwd.deleteTree(io, work) catch {};
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ work, "dest" }));
    try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ work, "src" }));

    const jobs = try std.fmt.allocPrint(arena, "{d}", .{options.jobs});
    const makeflags = try std.fmt.allocPrint(arena, "-j{d}", .{options.jobs});
    const full_version = try recipe.fullVersion(arena);
    const first_source: []const u8 = if (recipe.sources.len > 0) recipe.sources[0].fileName() else "";

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{
        "bwrap",
        "--unshare-user", "--uid",           "0",                "--gid",        "0",
        "--cap-add",      "ALL",             "--unshare-ipc",    "--unshare-uts",
        "--hostname",     "joe-build",       "--die-with-parent",
        "--bind",         options.build_root, "/",
        "--dev",          "/dev",            "--proc",           "/proc",
        "--tmpfs",        "/run",            "--tmpfs",          "/tmp",
        "--bind",         work,              "/build",
        "--ro-bind",      options.sources_dir, "/sources",
        "--ro-bind",      options.recipe_dir, "/recipe",
        "--ro-bind",      options.driver,    "/driver.sh",
        "--clearenv",
        "--setenv",       "HOME",            "/root",
        "--setenv",       "TERM",            "dumb",
        "--setenv",       "PATH",            "/usr/bin:/usr/sbin",
        "--setenv",       "LC_ALL",          "POSIX",
        "--setenv",       "MAKEFLAGS",       makeflags,
        "--setenv",       "JOBS",            jobs,
        "--setenv",       "DESTDIR",         "/build/dest",
        "--setenv",       "SOURCES",         "/sources",
        "--setenv",       "PKG_NAME",        recipe.name,
        "--setenv",       "PKG_VERSION",     recipe.version,
        "--setenv",       "PKG_RELEASE",     full_version,
        "--setenv",       "PKG_SOURCE",      first_source,
        // Several GNU configure scripts refuse to run as root without this.
        "--setenv",       "FORCE_UNSAFE_CONFIGURE", "1",
        "--chdir",        "/build",
        "/usr/bin/bash",  "/driver.sh",
    });

    if (recipe.network) {
        // Name resolution inside the sandbox uses the build machine's
        // resolver. Mounts apply in order, so this goes after the root itself.
        const after_root = for (argv.items, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "--dev")) break i;
        } else unreachable;
        try argv.insertSlice(arena, after_root, &.{ "--ro-bind", "/etc/resolv.conf", "/etc/resolv.conf" });
    } else {
        try argv.insert(arena, 1, "--unshare-net");
    }

    const log_path = try std.fs.path.join(arena, &.{ work, "build.log" });
    var log = try cwd.createFile(io, log_path, .{});
    defer log.close(io);
    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .{ .file = log },
        .stderr = .{ .file = log },
    });
    const term = try child.wait(io);
    if (!term.success()) {
        diag.message = try std.fmt.allocPrint(arena, "the build of {s} failed; see {s}", .{ recipe.name, log_path });
        return error.BuildFailed;
    }

    var dest = try cwd.openDir(io, try std.fs.path.join(arena, &.{ work, "dest" }), .{ .iterate = true });
    defer dest.close(io);
    try cwd.createDirPath(io, options.out_dir);
    var out = try cwd.openDir(io, options.out_dir, .{});
    defer out.close(io);
    const file = try archive.pack(arena, io, .{
        .meta = .{
            .name = recipe.name,
            .version = full_version,
            // The build root is a system of the architecture dave manages.
            .arch = arch.name,
            .description = recipe.description,
            .license = recipe.license,
            .depends = recipe.depends,
            .conflicts = recipe.conflicts,
            .operations = if (recipe.operations.len > 0 or options.default_allow.len == 0)
                recipe.operations
            else
                &.{.{ .allow = options.default_allow }},
        },
        .src = dest,
        .out_dir = out,
        .code_key = options.code_key,
    });
    if (!options.keep_work) cwd.deleteTree(io, work) catch {};
    return file;
}

const testing = std.testing;

test "recipe parsing" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const r = try Recipe.parse(arena,
        \\.{
        \\    .name = "zlib",
        \\    .version = "1.4",
        \\    .release = 2,
        \\    .sources = .{
        \\        .{ .url = "https://example.org/dist/zlib-1.4.tar.gz", .sha256 = "0000000000000000000000000000000000000000000000000000000000000000" },
        \\        .{ .url = "https://example.org/p?id=7", .file = "fix.patch", .sha256 = "1111111111111111111111111111111111111111111111111111111111111111" },
        \\    },
        \\    .depends = .{"glibc >=2.44"},
        \\}
    );
    try testing.expectEqualStrings("1.4-r2", try r.fullVersion(arena));
    try testing.expectEqualStrings("zlib-1.4.tar.gz", r.sources[0].fileName());
    try testing.expectEqualStrings("fix.patch", r.sources[1].fileName());

    // The release belongs in its own field.
    try testing.expectError(error.InvalidRecipe, Recipe.parse(arena,
        \\.{ .name = "x", .version = "1.0-r1" }
    ));
    try testing.expectError(error.InvalidRecipe, Recipe.parse(arena,
        \\.{ .name = "x", .version = "1.0", .sources = .{ .{ .url = "https://e.org/a.tar", .sha256 = "short" } } }
    ));
    try testing.expectError(error.InvalidRecipe, Recipe.parse(arena,
        \\.{ .name = "x", .version = "1.0", .depends = .{"glibc >=!!"} }
    ));
    try testing.expectError(error.InvalidRecipe, Recipe.parse(arena,
        \\.{ .name = "x", .version = "1.0", .sources = .{ .{ .url = "https://e.org/dir/", .sha256 = "0000000000000000000000000000000000000000000000000000000000000000" } } }
    ));
}
