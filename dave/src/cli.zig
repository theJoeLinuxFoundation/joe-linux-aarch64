//! The command line: the commands, the options each takes, and how arguments
//! become them.
//!
//! Two tables describe everything. `commands` holds each command's usage,
//! summary, explanation and examples, and what its operands are; `options`
//! holds each option, whether it takes a value, and which commands accept it.
//! Parsing, `dave help` and the shell completions are all made from these
//! tables, so they cannot disagree.
//!
//! An option may come before or after the command word, as people type it
//! either way. One name means two things: `--version` alone asks for dave's
//! version, while after `pack` it gives the package's version. The option
//! scoped to the command in hand wins. An option the command does not take
//! is refused once the whole line has been read, naming the command it is
//! for, so that a misplaced flag is never silently ignored.

const std = @import("std");
const Allocator = std.mem.Allocator;
const suggest = @import("suggest.zig");

pub const Command = enum {
    install,
    remove,
    upgrade,
    list,
    info,
    search,
    files,
    owns,
    why,
    status,
    rollback,
    deployments,
    build,
    pack,
    repo,
    key,
    seal,
    image,
    @"install-system",
    help,
    version,
    finalize,
    @"boot-check",
    @"boot-watchdog",
};

pub const Group = enum {
    packages,
    questions,
    system,
    building,
    images,
    help,
    services,

    pub fn title(g: Group) []const u8 {
        return switch (g) {
            .packages => "Packages",
            .questions => "Finding out",
            .system => "System",
            .building => "Building",
            .images => "Images and installation",
            .help => "Help",
            .services => "Run by the system",
        };
    }
};

/// What an operand is, for completing it.
pub const Operand = union(enum) {
    none,
    /// Any package a repository offers or that is installed.
    available,
    installed,
    /// The packages in the world file.
    requested,
    files,
    dirs,
    commands,
    words: []const []const u8,
};

pub const CommandInfo = struct {
    command: Command,
    group: Group,
    /// What follows `dave <command>` in a usage line.
    synopsis: []const u8 = "",
    /// What follows the command in the overview, when not the synopsis.
    brief: ?[]const u8 = null,
    summary: []const u8,
    about: []const u8,
    examples: []const []const u8 = &.{},
    /// One per position; the last repeats.
    operands: []const Operand = &.{},
    /// Left out of the overview (run by systemd, not people).
    hidden: bool = false,
    /// What it does that needs root, as in "installing packages needs root".
    root_for: ?[]const u8 = null,
    /// What its help says about root, when more than that.
    root_note: ?[]const u8 = null,

    /// The command and its operands, for the overview.
    pub fn overviewLine(c: CommandInfo) []const u8 {
        if (c.brief) |b| return b;
        const prefix = "[options] ";
        return if (std.mem.startsWith(u8, c.synopsis, prefix)) c.synopsis[prefix.len..] else c.synopsis;
    }
};

pub const commands = [_]CommandInfo{
    .{
        .command = .install,
        .group = .packages,
        .synopsis = "[options] <package>...",
        .summary = "Install packages (takes effect immediately)",
        .about =
        \\Installs the packages, and whatever they need, into the running system
        \\at once. The system as it was is saved first as a deployment you can
        \\boot, so 'dave rollback' can undo it.
        \\
        \\A package may carry a version constraint: 'hello>=2.0', 'hello=2.0-r1'.
        \\When more would change than the packages you named (dependencies come
        \\in, or other packages are upgraded or removed), dave shows the plan and
        \\asks before going ahead.
        ,
        .examples = &.{ "dave install firefox", "dave install --dry-run gimp inkscape" },
        .operands = &.{.available},
        .root_for = "installing packages",
        .root_note = "Installing packages needs root; --dry-run does not.",
    },
    .{
        .command = .remove,
        .group = .packages,
        .synopsis = "[options] <package>...",
        .summary = "Remove packages (takes effect immediately)",
        .about =
        \\Removes packages you asked for, together with the dependencies nothing
        \\else needs any more. The system as it was is saved first, as for
        \\install.
        \\
        \\A package that is only here because another one needs it cannot be
        \\removed by itself; 'dave why <package>' says what needs it.
        ,
        .examples = &.{"dave remove gimp"},
        .operands = &.{.requested},
        .root_for = "removing packages",
        .root_note = "Removing packages needs root; --dry-run does not.",
    },
    .{
        .command = .upgrade,
        .group = .packages,
        .synopsis = "[--check] [--reboot]",
        .brief = "[--check]",
        .summary = "Prepare an upgrade, applied at the next boot",
        .about =
        \\Works out an upgrade of every package, downloads it and proves that it
        \\applies cleanly to a copy of the system. Nothing you can see changes:
        \\the upgrade is applied as the machine shuts down, and the upgraded
        \\system starts on the next boot. Anything you change before then is
        \\kept.
        \\
        \\With --check, dave only says what an upgrade would change. That needs
        \\no root.
        ,
        .examples = &.{ "dave upgrade --check", "sudo dave upgrade --reboot" },
        .root_for = "preparing an upgrade",
        .root_note = "Preparing an upgrade needs root; --check and --dry-run do not.",
    },
    .{
        .command = .list,
        .group = .questions,
        .synopsis = "[--requested]",
        .summary = "List installed packages",
        .about =
        \\Lists the installed packages and their versions. Those installed only
        \\because another package needs them are marked as dependencies. With
        \\--requested, only the packages you asked for are listed.
        ,
    },
    .{
        .command = .info,
        .group = .questions,
        .synopsis = "<package>",
        .summary = "Describe a package, installed or not",
        .about =
        \\Describes a package, installed or not: the version installed and the
        \\newest one offered, its licence and sizes, what it depends on, which
        \\installed packages depend on it, and why it is installed.
        ,
        .examples = &.{"dave info firefox"},
        .operands = &.{ .available, .none },
    },
    .{
        .command = .search,
        .group = .questions,
        .synopsis = "<word>...",
        .summary = "Find packages by name or description",
        .about =
        \\Lists the packages whose name or description contains every word,
        \\ignoring case. Packages whose names match come first, and installed
        \\packages are marked.
        ,
        .examples = &.{ "dave search editor", "dave search image viewer" },
    },
    .{
        .command = .files,
        .group = .questions,
        .synopsis = "<package>",
        .summary = "List the files of an installed package",
        .about =
        \\Lists every file, directory and link an installed package put on the
        \\system. Directories end in '/'.
        ,
        .examples = &.{"dave files hello"},
        .operands = &.{ .installed, .none },
    },
    .{
        .command = .owns,
        .group = .questions,
        .synopsis = "<path>...",
        .summary = "Name the package a file belongs to",
        .about =
        \\Says which installed package a file belongs to. Paths are taken the
        \\way the system takes them, so /bin/sh is found although packages put
        \\it in /usr/bin. A directory many packages share is said to be shared.
        ,
        .examples = &.{ "dave owns /usr/bin/bash", "dave owns /bin/sh" },
        .operands = &.{.files},
    },
    .{
        .command = .why,
        .group = .questions,
        .synopsis = "<package>",
        .summary = "Say why a package is installed",
        .about =
        \\Says why a package is installed: because you asked for it, or because
        \\something you asked for needs it, by the shortest chain of
        \\dependencies.
        ,
        .examples = &.{"dave why zlib"},
        .operands = &.{ .installed, .none },
    },
    .{
        .command = .status,
        .group = .system,
        .summary = "Show the running system and pending changes",
        .about =
        \\Shows which deployment is running, which one will start on the next
        \\boot, whether an upgrade is waiting to be applied, and every
        \\deployment that can be booted.
        ,
    },
    .{
        .command = .rollback,
        .group = .system,
        .summary = "Return to the previous system on next boot",
        .about =
        \\Makes the deployment before the running one start on the next boot,
        \\and on every boot after it. Nothing changes until you reboot. Files
        \\under /home and /var are shared by every deployment and stay as they
        \\are.
        ,
        .root_for = "rolling back",
    },
    .{
        .command = .deployments,
        .group = .system,
        .synopsis = "[list | pin <id> | unpin <id> | gc]",
        .summary = "List, pin or clean up bootable systems",
        .about =
        \\Each install, remove and upgrade keeps the system as it was as a
        \\deployment that can be booted. 'list' shows them; 'pin' keeps one until
        \\it is unpinned; 'gc' deletes those that are no longer needed (dave also
        \\does this by itself).
        ,
        .examples = &.{ "dave deployments", "sudo dave deployments pin 12" },
        .brief = "[list|pin|unpin|gc]",
        .operands = &.{ .{ .words = &.{ "list", "pin", "unpin", "gc" } }, .none },
        .root_for = "changing deployments",
        .root_note = "Pinning, unpinning and cleaning up need root; listing does not.",
    },
    .{
        .command = .build,
        .group = .building,
        .synopsis = "<recipe> --buildroot DIR --sources DIR --work DIR --out DIR",
        .brief = "<recipe> --out DIR ...",
        .summary = "Build a package from a recipe",
        .about =
        \\Builds the recipe in a directory of packages/ inside the build root,
        \\and writes the package to the --out directory. See packages/README.md.
        ,
        .operands = &.{.dirs},
    },
    .{
        .command = .pack,
        .group = .building,
        .synopsis = "--name N --version V --out DIR <tree>",
        .brief = "<tree> --name N ...",
        .summary = "Make a package from a directory",
        .about =
        \\Makes a package of the files in a directory, which stands for the root
        \\they will be installed into. The version needs a release, as in
        \\1.0-r1.
        ,
        .operands = &.{.dirs},
    },
    .{
        .command = .repo,
        .group = .building,
        .synopsis = "index|audit <dir>",
        .summary = "Index and sign a repository, or audit it",
        .about =
        \\'index' writes repo.zon for the packages in a directory, and signs it
        \\with --key. 'audit' checks every package's seals and operation
        \\declarations.
        ,
        .operands = &.{ .{ .words = &.{ "index", "audit" } }, .dirs },
    },
    .{
        .command = .key,
        .group = .building,
        .synopsis = "generate|generate-code <basename>",
        .brief = "generate[-code] <basename>",
        .summary = "Create a signing key pair",
        .about =
        \\'generate' makes a key pair for signing repository indexes;
        \\'generate-code' one for sealing programs. The secret half is written
        \\to <basename>.key, the public half to <basename>.pub.
        ,
        .operands = &.{ .{ .words = &.{ "generate", "generate-code" } }, .files },
    },
    .{
        .command = .seal,
        .group = .building,
        .summary = "Seal installed files that are not yet sealed",
        .about =
        \\Seals every installed file that its package seals and that is not
        \\sealed yet. An image is assembled without the privileges sealing
        \\needs, so this runs on its first boot.
        ,
        .root_for = "sealing files",
        .root_note = "Sealing the running system's files needs root.",
    },
    .{
        .command = .image,
        .group = .images,
        .synopsis = "build <spec> --out FILE [--test] [--repo NAME,DIR,URL,KEY]... [--with PACKAGE]... [--tree DIR]",
        .brief = "build <spec> --out FILE",
        .summary = "Build a disk image, live medium or container image",
        .about =
        \\Builds the disk image, live medium or container image a
        \\specification (image/*.zon) describes. Each --repo is read from DIR
        \\(a directory, or a URL) while building, and the image will use URL.
        ,
        .operands = &.{ .{ .words = &.{"build"} }, .files },
    },
    .{
        .command = .@"install-system",
        .group = .images,
        .synopsis = "--list [--json] | --disk DISK [--beside] [--json]",
        .brief = "--list | --disk DISK",
        .summary = "Install joe Linux onto a disk",
        .about =
        \\With --list, shows the disks joe Linux could be installed on, and why
        \\any cannot be used. With --disk, erases that disk and installs onto
        \\it what the live medium says (joe/install.zon), copying the packages
        \\out of the medium's own root.
        \\
        \\With --beside, nothing on the disk is erased: joe takes the disk's
        \\largest free space (22 GB or more) and shares its EFI system partition,
        \\so the boot menu offers the other system too. Make the space first, in
        \\the other system: Windows' Disk Management can shrink its volume.
        ,
    },
    .{
        .command = .help,
        .group = .help,
        .synopsis = "[<command>]",
        .summary = "Explain dave, or one of its commands",
        .about = "Explains dave, or one of its commands and the options it takes.",
        .operands = &.{ .commands, .none },
    },
    .{
        .command = .version,
        .group = .help,
        .summary = "Show dave's version",
        .about = "Shows dave's version.",
    },
    .{
        .command = .finalize,
        .group = .services,
        .summary = "Apply a prepared upgrade (at shutdown)",
        .about = "Run by dave-finalize.service as the system shuts down.",
        .hidden = true,
    },
    .{
        .command = .@"boot-check",
        .group = .services,
        .summary = "Check a new deployment (at boot)",
        .about = "Run by dave-boot-check.service on the first boots of a new deployment.",
        .hidden = true,
    },
    .{
        .command = .@"boot-watchdog",
        .group = .services,
        .summary = "Abandon a new deployment that never finishes booting",
        .about = "Run at boot by the dave-boot-watchdog service: if the boot check has not passed within ten minutes, restart at once.",
        .hidden = true,
    },
};

pub fn infoOf(c: Command) CommandInfo {
    for (commands) |i| if (i.command == c) return i;
    unreachable;
}

pub const Complete = enum { none, files, dirs };

pub const OptionSpec = struct {
    long: []const u8,
    short: ?u8 = null,
    /// What the value is, as shown in help; null for a switch.
    value: ?[]const u8 = null,
    help: []const u8,
    /// The commands that take it; empty means every command.
    commands: []const Command = &.{},
    /// The field of Options it sets.
    field: []const u8,
    complete: Complete = .none,
};

const changes = [_]Command{ .install, .remove, .upgrade };

pub const options = [_]OptionSpec{
    .{ .long = "root", .value = "DIR", .help = "Work on the system installed at DIR instead of /", .field = "root", .complete = .dirs },
    .{ .long = "cache", .value = "DIR", .help = "Keep downloaded indexes and packages in DIR", .field = "cache", .complete = .dirs },
    .{ .long = "help", .short = 'h', .help = "Explain the command", .field = "help" },
    .{ .long = "version", .short = 'V', .help = "Show dave's version", .field = "show_version" },

    .{ .long = "yes", .short = 'y', .help = "Go ahead without asking", .commands = &changes, .field = "yes" },
    .{ .long = "dry-run", .help = "Show what would be done, and stop", .commands = &changes, .field = "dry_run" },
    .{ .long = "no-triggers", .help = "Do not run package triggers", .commands = &.{ .install, .remove, .upgrade, .image, .finalize }, .field = "no_triggers" },
    .{ .long = "overwrite", .help = "Replace files that exist but belong to no package", .commands = &.{ .install, .remove, .upgrade, .image }, .field = "overwrite" },
    .{ .long = "check", .help = "Only say what an upgrade would change", .commands = &.{.upgrade}, .field = "check" },
    .{ .long = "reboot", .help = "Apply the upgrade now, and reboot", .commands = &.{.upgrade}, .field = "reboot" },
    .{ .long = "requested", .help = "Only the packages you asked for", .commands = &.{.list}, .field = "requested" },

    .{ .long = "list", .help = "List the disks joe Linux could be installed on", .commands = &.{.@"install-system"}, .field = "list" },
    .{ .long = "disk", .value = "DISK", .help = "Erase DISK and install onto it", .commands = &.{.@"install-system"}, .field = "disk", .complete = .files },
    .{ .long = "beside", .help = "Install into the disk's free space, beside the system already there", .commands = &.{.@"install-system"}, .field = "beside" },
    .{ .long = "json", .help = "Report as JSON events, for a program watching", .commands = &.{.@"install-system"}, .field = "json" },
    .{ .long = "with", .value = "PACKAGE", .help = "Install PACKAGE as well", .commands = &.{ .image, .@"install-system" }, .field = "with" },
    .{ .long = "test", .help = "Add joe-test-console: root logged in on the serial console (automated tests only)", .commands = &.{.image}, .field = "test_image" },
    .{ .long = "repo", .value = "NAME,DIR,URL,KEY", .help = "A repository: read from DIR, used as URL, signed by KEY", .commands = &.{.image}, .field = "repos" },
    .{ .long = "tree", .value = "DIR", .help = "Start from DIR instead of the spec's tree", .commands = &.{.image}, .field = "tree", .complete = .dirs },

    .{ .long = "out", .value = "DIR", .help = "Where the result goes (a file, for image)", .commands = &.{ .build, .pack, .image }, .field = "out", .complete = .files },
    .{ .long = "buildroot", .value = "DIR", .help = "The build root to build in", .commands = &.{.build}, .field = "buildroot", .complete = .dirs },
    .{ .long = "sources", .value = "DIR", .help = "Where source archives are kept", .commands = &.{.build}, .field = "sources", .complete = .dirs },
    .{ .long = "work", .value = "DIR", .help = "Where builds happen", .commands = &.{.build}, .field = "work", .complete = .dirs },
    .{ .long = "driver", .value = "FILE", .help = "The build driver (default: packages/.build/driver.sh)", .commands = &.{.build}, .field = "driver", .complete = .files },
    .{ .long = "keep-work", .help = "Keep the work directory of a successful build", .commands = &.{.build}, .field = "keep_work" },
    .{ .long = "code-key", .value = "FILE", .help = "Seal the package's files with this key", .commands = &.{ .build, .pack }, .field = "code_key", .complete = .files },
    .{ .long = "allow", .value = "OP", .help = "An operation the package declares (pack), or the declaration for recipes that make none (build)", .commands = &.{ .build, .pack }, .field = "allow" },
    .{ .long = "name", .value = "NAME", .help = "The package's name", .commands = &.{.pack}, .field = "name" },
    .{ .long = "version", .value = "VERSION", .help = "The package's version, with a release (1.0-r1)", .commands = &.{.pack}, .field = "pkg_version" },
    .{ .long = "description", .value = "TEXT", .help = "What the package is", .commands = &.{.pack}, .field = "description" },
    .{ .long = "license", .value = "SPDX", .help = "The package's licence", .commands = &.{.pack}, .field = "license" },
    .{ .long = "depends", .value = "DEP", .help = "A dependency, as in 'glibc >=2.44'", .commands = &.{.pack}, .field = "depends" },
    .{ .long = "conflicts", .value = "DEP", .help = "A package it cannot be installed with", .commands = &.{.pack}, .field = "conflicts" },
    .{ .long = "key", .value = "FILE", .help = "Sign the index with this secret key", .commands = &.{.repo}, .field = "key", .complete = .files },
};

pub const Options = struct {
    root: []const u8 = "/",
    cache: ?[]const u8 = null,
    help: bool = false,
    show_version: bool = false,
    yes: bool = false,
    dry_run: bool = false,
    no_triggers: bool = false,
    reboot: bool = false,
    check: bool = false,
    requested: bool = false,
    overwrite: bool = false,
    keep_work: bool = false,
    test_image: bool = false,
    tree: ?[]const u8 = null,
    json: bool = false,
    list: bool = false,
    beside: bool = false,
    disk: ?[]const u8 = null,
    repos: std.ArrayList([]const u8) = .empty,
    with: std.ArrayList([]const u8) = .empty,
    buildroot: ?[]const u8 = null,
    sources: ?[]const u8 = null,
    work: ?[]const u8 = null,
    driver: ?[]const u8 = null,
    name: ?[]const u8 = null,
    pkg_version: ?[]const u8 = null,
    description: []const u8 = "",
    license: []const u8 = "",
    out: ?[]const u8 = null,
    key: ?[]const u8 = null,
    code_key: ?[]const u8 = null,
    allow: std.ArrayList([]const u8) = .empty,
    depends: std.ArrayList([]const u8) = .empty,
    conflicts: std.ArrayList([]const u8) = .empty,
};

pub fn appliesTo(o: OptionSpec, c: ?Command) bool {
    if (o.commands.len == 0) return true;
    const cmd = c orelse return false;
    return std.mem.indexOfScalar(Command, o.commands, cmd) != null;
}

/// The option called `long`, preferring the one `command` takes.
pub fn findLong(long: []const u8, command: ?Command) ?usize {
    var fallback: ?usize = null;
    for (options, 0..) |o, i| {
        if (!std.mem.eql(u8, o.long, long)) continue;
        if (o.commands.len > 0 and appliesTo(o, command)) return i;
        if (fallback == null or o.commands.len == 0) fallback = i;
    }
    return fallback;
}

fn findShort(c: u8) ?usize {
    for (options, 0..) |o, i| if (o.short == c) return i;
    return null;
}

pub const Parsed = struct {
    opts: Options = .{},
    /// The command word as given, when there is one.
    word: ?[]const u8 = null,
    /// The command, when the word names one.
    command: ?Command = null,
    operands: []const []const u8 = &.{},
};

pub const Diagnostic = struct {
    message: []const u8 = "",
};

pub const Error = Allocator.Error || error{Usage};

fn usage(arena: Allocator, diag: *Diagnostic, comptime fmt: []const u8, args: anytype) Error {
    diag.message = try std.fmt.allocPrint(arena, fmt, args);
    return error.Usage;
}

fn set(arena: Allocator, opts: *Options, index: usize, value: ?[]const u8) Allocator.Error!void {
    inline for (options, 0..) |o, i| {
        if (i == index) {
            const T = @TypeOf(@field(opts, o.field));
            if (T == bool) {
                @field(opts, o.field) = true;
            } else if (T == std.ArrayList([]const u8)) {
                try @field(opts, o.field).append(arena, value.?);
            } else {
                @field(opts, o.field) = value.?;
            }
            return;
        }
    }
    unreachable;
}

pub fn parse(arena: Allocator, args: []const []const u8, diag: *Diagnostic) Error!Parsed {
    var p: Parsed = .{};
    var operands: std.ArrayList([]const u8) = .empty;
    var given: std.ArrayList(usize) = .empty;
    var only_operands = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (only_operands or arg.len < 2 or arg[0] != '-') {
            if (p.word == null) {
                p.word = arg;
                p.command = std.meta.stringToEnum(Command, arg);
            } else {
                try operands.append(arena, arg);
            }
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            only_operands = true;
            continue;
        }
        if (arg[1] != '-') {
            for (arg[1..]) |c| {
                const index = findShort(c) orelse
                    return usage(arena, diag, "unknown option -{c}; run 'dave help' for the options", .{c});
                try set(arena, &p.opts, index, null);
                try given.append(arena, index);
            }
            continue;
        }
        const body = arg[2..];
        const eq = std.mem.indexOfScalar(u8, body, '=');
        const long = body[0 .. eq orelse body.len];
        const index = findLong(long, p.command) orelse {
            var names: std.ArrayList([]const u8) = .empty;
            for (options) |o| {
                if (p.command == null or appliesTo(o, p.command)) try names.append(arena, o.long);
            }
            const close = try suggest.closest(arena, long, names.items);
            var quoted: std.ArrayList([]const u8) = .empty;
            for (close) |c| try quoted.append(arena, try std.fmt.allocPrint(arena, "--{s}", .{c}));
            return usage(arena, diag, "unknown option --{s}{s}", .{ long, try suggest.phrase(arena, quoted.items, false) });
        };
        const spec = options[index];
        var value: ?[]const u8 = null;
        if (spec.value) |metavar| {
            if (eq) |e| {
                value = body[e + 1 ..];
            } else {
                i += 1;
                if (i >= args.len) return usage(arena, diag, "--{s} needs a value ({s})", .{ spec.long, metavar });
                value = args[i];
            }
        } else if (eq != null) {
            return usage(arena, diag, "--{s} takes no value", .{spec.long});
        }
        try set(arena, &p.opts, index, value);
        try given.append(arena, index);
    }
    p.operands = operands.items;

    // An option the command does not take, now that the command is known.
    if (p.command) |cmd| if (!p.opts.help and !p.opts.show_version) {
        for (given.items) |index| {
            const o = options[index];
            if (appliesTo(o, cmd)) continue;
            // `--version` given after another command than pack is the switch.
            if (findLong(o.long, cmd)) |other| if (appliesTo(options[other], cmd)) continue;
            var takers: std.ArrayList([]const u8) = .empty;
            for (o.commands) |c| try takers.append(arena, @tagName(c));
            return usage(arena, diag, "{s} does not take --{s} (it is for {s}); see 'dave help {s}'", .{
                @tagName(cmd), o.long, try std.mem.join(arena, ", ", takers.items), @tagName(cmd),
            });
        }
    };
    return p;
}

/// The visible command names.
pub fn commandNames(arena: Allocator) Allocator.Error![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (commands) |c| {
        if (!c.hidden) try names.append(arena, @tagName(c.command));
    }
    return names.items;
}

// -- completion -------------------------------------------------------------------------

pub const Want = union(enum) {
    nothing,
    commands,
    /// The options the command (or, with none yet, every command) takes.
    options: ?Command,
    operand: Operand,
};

pub const Completion = struct {
    want: Want,
    /// The beginning of the word being completed.
    prefix: []const u8,
    /// --root and --cache as given earlier on the line.
    root: []const u8 = "/",
    cache: ?[]const u8 = null,
};

/// What to offer for the word at `index` of `words` (which begins with the
/// program's name, as a shell gives it).
pub fn completion(words: []const []const u8, index: usize) Completion {
    const prefix = if (index < words.len) words[index] else "";
    var c: Completion = .{ .want = .nothing, .prefix = prefix };
    var command: ?Command = null;
    var have_word = false;
    var position: usize = 0;
    var i: usize = 1;
    while (i < index and i < words.len) : (i += 1) {
        const w = words[i];
        if (w.len >= 2 and w[0] == '-') {
            if (w[1] != '-') continue;
            const body = w[2..];
            if (std.mem.indexOfScalar(u8, body, '=') != null) continue;
            const o = options[findLong(body, command) orelse continue];
            if (o.value == null) continue;
            if (i + 1 == index) {
                c.want = switch (o.complete) {
                    .none => .nothing,
                    .files => .{ .operand = .files },
                    .dirs => .{ .operand = .dirs },
                };
                return c;
            }
            i += 1;
            if (i < words.len) {
                if (std.mem.eql(u8, o.field, "root")) c.root = words[i];
                if (std.mem.eql(u8, o.field, "cache")) c.cache = words[i];
            }
            continue;
        }
        if (!have_word) {
            have_word = true;
            command = std.meta.stringToEnum(Command, w);
            if (command == null) return c;
        } else {
            position += 1;
        }
    }
    if (prefix.len > 0 and prefix[0] == '-') {
        c.want = .{ .options = command };
        return c;
    }
    if (!have_word) {
        c.want = .commands;
        return c;
    }
    const ops = infoOf(command.?).operands;
    if (ops.len == 0) return c;
    const op = ops[@min(position, ops.len - 1)];
    c.want = if (op == .none) .nothing else .{ .operand = op };
    return c;
}

const testing = std.testing;

fn parseOk(arena: Allocator, args: []const []const u8) !Parsed {
    var diag: Diagnostic = .{};
    return parse(arena, args, &diag) catch |e| {
        std.debug.print("parsing {s} failed: {s}\n", .{ try std.mem.join(arena, " ", args), diag.message });
        return e;
    };
}

fn parseError(arena: Allocator, args: []const []const u8) ![]const u8 {
    var diag: Diagnostic = .{};
    if (parse(arena, args, &diag)) |_| return error.TestUnexpectedResult else |e| try testing.expectEqual(error.Usage, e);
    return diag.message;
}

test "the tables agree with themselves" {
    // Every command is described once.
    for (std.meta.tags(Command)) |tag| {
        var n: usize = 0;
        for (commands) |c| {
            if (c.command == tag) n += 1;
        }
        try testing.expectEqual(@as(usize, 1), n);
    }
    // Every option sets a field that exists, of a type set() understands.
    inline for (options) |o| {
        try testing.expect(@hasField(Options, o.field));
        const T = @FieldType(Options, o.field);
        try testing.expect((T == bool) == (o.value == null));
    }
}

test "every command line in the repository still parses" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = [_][]const []const u8{
        // bootstrap/build-packages.sh
        &.{ "build", "packages/zlib", "--buildroot", "r", "--sources", "s", "--work", "w", "--out", "o", "--code-key", "k" },
        &.{ "--root", "r", "list" },
        &.{ "--root", "r", "--overwrite", "install", "zlib=1.3-r1" },
        &.{ "repo", "index", "build/repo", "--key", "k" },
        &.{ "key", "generate", "build/keys/joe" },
        &.{ "key", "generate-code", "build/keys/joe-code" },
        // tests/cli.tomlx and tests/lib/repo.sh
        &.{ "pack", "--name", "hello", "--version", "1.0-r1", "--out", "repo", "--depends", "libgreet >=1.0", "stage" },
        &.{ "pack", "--name", "x", "--version", "1.0-r1", "--allow", "undeclared", "--out", "repo", "--code-key", "k", "stage" },
        &.{ "--root", "root", "seal" },
        &.{ "repo", "audit", "repo" },
        // the Makefile, tests/vm/*.tomlx, image/mkscaffold-dave.sh, joe-build
        &.{ "image", "build", "image/console.zon", "--test", "--repo", "joe,a,b,c", "--out", "joe.img" },
        &.{ "image", "build", "scaffold.zon", "--tree", "t", "--repo", "joe,a,b,c", "--with", "x", "--out", "o" },
        // the installer and tests/vm/install.tomlx
        &.{ "install-system", "--list", "--json" },
        &.{ "install-system", "--disk", "/dev/vda", "--json" },
        &.{ "install-system", "--disk", "/dev/vda", "--beside", "--json" },
        &.{ "--root", "/tmp/check", "--cache", "/tmp/check-cache", "--dry-run", "install", "joe-desktop" },
        // the systemd units
        &.{"finalize"},
        &.{"boot-check"},
        &.{"boot-watchdog"},
        &.{"status"},
        &.{"seal"},
    };
    for (lines) |line| _ = try parseOk(arena, line);

    const p = try parseOk(arena, &.{ "pack", "--name", "hello", "--version", "1.0-r1", "--out", "repo", "stage" });
    try testing.expectEqualStrings("1.0-r1", p.opts.pkg_version.?);
    try testing.expect(!p.opts.show_version);
    try testing.expectEqualStrings("stage", p.operands[0]);
    const deps = try parseOk(arena, &.{ "pack", "--depends", "a", "--depends=b >=2", "x" });
    try testing.expectEqual(@as(usize, 2), deps.opts.depends.items.len);
    try testing.expectEqualStrings("b >=2", deps.opts.depends.items[1]);
}

test "help, version and short options" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect((try parseOk(arena, &.{"--version"})).opts.show_version);
    try testing.expect((try parseOk(arena, &.{"-V"})).opts.show_version);
    try testing.expect((try parseOk(arena, &.{ "install", "--version" })).opts.show_version);
    const h = try parseOk(arena, &.{ "install", "--help" });
    try testing.expect(h.opts.help);
    try testing.expectEqual(Command.install, h.command.?);
    try testing.expect((try parseOk(arena, &.{ "-h", "remove" })).opts.help);
    // Help is given even with options the command does not take.
    try testing.expect((try parseOk(arena, &.{ "list", "--disk", "x", "--help" })).opts.help);
    const y = try parseOk(arena, &.{ "install", "-y", "hello", "tree" });
    try testing.expect(y.opts.yes);
    try testing.expectEqual(@as(usize, 2), y.operands.len);
    try testing.expect((try parseOk(arena, &.{ "remove", "-yh", "x" })).opts.help);
    // After --, everything is an operand.
    const dashes = try parseOk(arena, &.{ "owns", "--", "--weird-file" });
    try testing.expectEqualStrings("--weird-file", dashes.operands[0]);
    try testing.expectEqualStrings("/", (try parseOk(arena, &.{"status"})).opts.root);
    try testing.expectEqualStrings("x", (try parseOk(arena, &.{ "--root=x", "status" })).opts.root);
    // An unknown word is kept for "did you mean".
    const typo = try parseOk(arena, &.{"isntall"});
    try testing.expect(typo.command == null);
    try testing.expectEqualStrings("isntall", typo.word.?);
}

test "mistakes are explained" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("unknown option --dryrun; did you mean --dry-run?", try parseError(arena, &.{ "install", "--dryrun", "x" }));
    try testing.expectEqualStrings("--root needs a value (DIR)", try parseError(arena, &.{ "list", "--root" }));
    try testing.expectEqualStrings("--dry-run takes no value", try parseError(arena, &.{ "install", "--dry-run=yes" }));
    try testing.expectEqualStrings("list does not take --disk (it is for install-system); see 'dave help list'", try parseError(arena, &.{ "list", "--disk", "x" }));
    try testing.expectEqualStrings("status does not take --yes (it is for install, remove, upgrade); see 'dave help status'", try parseError(arena, &.{ "status", "-y" }));
    try testing.expectEqualStrings("unknown option -q; run 'dave help' for the options", try parseError(arena, &.{ "install", "-q" }));
}

test "completion" {
    const at = struct {
        fn at(words: []const []const u8) Completion {
            return completion(words, words.len - 1);
        }
    }.at;
    try testing.expectEqual(Want.commands, at(&.{ "dave", "in" }).want);
    try testing.expectEqualStrings("in", at(&.{ "dave", "in" }).prefix);
    try testing.expectEqual(Want.commands, at(&.{ "dave", "--root", "/mnt", "" }).want);
    try testing.expectEqualStrings("/mnt", at(&.{ "dave", "--root", "/mnt", "install", "" }).root);
    try testing.expectEqual(Operand.available, at(&.{ "dave", "install", "hello", "" }).want.operand);
    try testing.expectEqual(Operand.requested, at(&.{ "dave", "remove", "" }).want.operand);
    try testing.expectEqual(Operand.dirs, at(&.{ "dave", "--root", "" }).want.operand);
    try testing.expectEqual(Want.nothing, at(&.{ "dave", "pack", "--name", "" }).want);
    try testing.expectEqual(Command.install, at(&.{ "dave", "install", "--dr" }).want.options.?);
    try testing.expectEqual(Operand.files, at(&.{ "dave", "owns", "/u" }).want.operand);
    try testing.expectEqualStrings("pin", at(&.{ "dave", "deployments", "" }).want.operand.words[1]);
    try testing.expectEqual(Want.nothing, at(&.{ "dave", "deployments", "pin", "" }).want);
    try testing.expectEqual(Want.nothing, at(&.{ "dave", "nonsense", "" }).want);
    try testing.expectEqual(Operand.commands, at(&.{ "dave", "help", "" }).want.operand);
    // The word under the cursor may be in the middle of the line.
    try testing.expectEqual(Want.commands, completion(&.{ "dave", "ins", "hello" }, 1).want);
}
