const std = @import("std");

/// The architectures dave can manage (src/arch.zig).
const Arch = enum { x86_64, aarch64 };

pub fn build(b: *std.Build) void {
    // dave is always a static binary with no libc, so that no library upgrade
    // on the target system can break the package manager.
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .none },
    });
    const optimize = b.standardOptimizeOption(.{});

    // What dave manages is not necessarily what it runs on: a dave built for
    // an x86_64 build machine with -Darch=aarch64 builds aarch64 packages
    // and images there.
    const arch = b.option(Arch, "arch", "Architecture of the systems dave manages (default: the one it is built for)") orelse
        std.meta.stringToEnum(Arch, @tagName(target.result.cpu.arch)) orelse {
        std.log.err("dave does not manage {t} systems; give -Darch=x86_64 or -Darch=aarch64", .{target.result.cpu.arch});
        b.invalid_user_input = true;
        return;
    };
    const test_filters = b.option([]const []const u8, "test-filter", "Run only the unit tests whose names contain this") orelse &.{};

    const options = b.addOptions();
    options.addOption([]const u8, "arch", @tagName(arch));

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "dave",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const tests = b.addTest(.{ .root_module = root_module, .filters = test_filters });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
