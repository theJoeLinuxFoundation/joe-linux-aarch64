//! The architecture of the systems dave manages, and every name that differs
//! with it.
//!
//! It is chosen when dave is built (`zig build -Darch=x86_64|aarch64`, by
//! default the architecture dave is built for), and it need not be the one
//! dave runs on: a dave built for an x86_64 build machine with -Darch=aarch64
//! builds aarch64 packages and images there, and a dave built for aarch64
//! runs on the systems themselves. One dave manages one architecture: the
//! packages it makes are for it, and the repositories and packages it
//! installs must be (repo.zig, txn.zig).

const std = @import("std");
const build_options = @import("build_options");

pub const Arch = enum { x86_64, aarch64 };

pub const managed: Arch = std.meta.stringToEnum(Arch, build_options.arch) orelse
    @compileError("dave cannot manage " ++ build_options.arch ++ " systems");

/// What a package manifest or index entry that names no architecture is
/// for. dave named none before it managed more than x86_64, and it still
/// leaves this one out, so that what it writes for x86_64 is as before:
/// std.zon omits a field equal to its default, comparing slices by address,
/// which is why `name` is this very constant.
pub const unstated = "x86_64";

/// The architecture's name in package manifests and file names
/// (`NAME-VERSION-rN-ARCH.dave`) and in repository indexes: the kernel's and
/// GNU's name for it.
pub const name: []const u8 = switch (managed) {
    .x86_64 => unstated,
    .aarch64 => "aarch64",
};

/// systemd-boot's file name, which carries the UEFI name of the architecture.
pub const systemd_boot: []const u8 = switch (managed) {
    .x86_64 => "systemd-bootx64.efi",
    .aarch64 => "systemd-bootaa64.efi",
};

/// The program firmware starts from `EFI/BOOT/` when it has been told of no
/// other: the removable-media path.
pub const efi_fallback: []const u8 = switch (managed) {
    .x86_64 => "BOOTX64.EFI",
    .aarch64 => "BOOTAA64.EFI",
};

/// The architecture in a container image's configuration (Go's GOARCH).
pub const oci: []const u8 = switch (managed) {
    .x86_64 => "amd64",
    .aarch64 => "arm64",
};

/// The serial console of the virtual machines that test images boot in: the
/// PC's first UART, or the PL011 of QEMU's virt machine (which most Arm
/// servers' SPCR table also names).
pub const serial_console: []const u8 = switch (managed) {
    .x86_64 => "ttyS0",
    .aarch64 => "ttyAMA0",
};

/// The Discoverable Partitions Specification's root partition type,
/// "root-x86-64" or "root-arm64": what systemd takes for the root.
pub const root_partition_type: []const u8 = switch (managed) {
    .x86_64 => "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709",
    .aarch64 => "B921B045-1DF0-41C3-AF44-4C6F280D3FAE",
};

/// mksquashfs's xz branch/call/jump filter for the architecture's code.
pub const xz_bcj: []const u8 = switch (managed) {
    .x86_64 => "x86",
    .aarch64 => "arm64",
};

/// Whether `other`, as a manifest or an index states it, is the
/// architecture dave manages.
pub fn matches(other: []const u8) bool {
    return std.mem.eql(u8, other, name);
}

const testing = std.testing;

test "the names of the managed architecture agree" {
    try testing.expect(matches(name));
    try testing.expect(!matches(switch (managed) {
        .x86_64 => "aarch64",
        .aarch64 => "x86_64",
    }));
    try testing.expect(std.mem.indexOf(u8, systemd_boot, "systemd-boot") == 0);
    // The UEFI name is the same in both of the loader's names.
    const uefi = systemd_boot["systemd-boot".len .. systemd_boot.len - ".efi".len];
    var upper: [8]u8 = undefined;
    try testing.expectEqualStrings(std.ascii.upperString(&upper, uefi), efi_fallback["BOOT".len .. efi_fallback.len - ".EFI".len]);
}
