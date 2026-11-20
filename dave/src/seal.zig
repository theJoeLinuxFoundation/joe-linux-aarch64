//! Seals: what lets the joe security module trust a file.
//!
//! A sealed file has two properties. Its contents are protected by fs-verity,
//! so the kernel refuses any modification and can name the exact contents by
//! a digest. And it carries an extended attribute holding the operations its
//! package declares for it, signed together with that digest by a
//! code-signing key whose public half is compiled into the kernel.
//!
//! Seals are computed when a package is built (the signature is stored in the
//! manifest) and applied when it is installed. The kernel side is
//! packages/linux/joe-lsm/joe.c; the two must agree on every byte described
//! here.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const manifest_mod = @import("manifest.zig");

pub const xattr_name = "security.joe";
pub const magic = "JOE1";
pub const digest_len = 32;
pub const signature_len = Ecdsa.Signature.encoded_length;
pub const max_ops_len = 8192;

pub const Digest = [digest_len]u8;
pub const Signature = [signature_len]u8;

// ---------------------------------------------------------------------------
// fs-verity
// ---------------------------------------------------------------------------

const block_size = 4096;
const hashes_per_block = block_size / digest_len;
const max_levels = 8;

/// Computes the fs-verity file digest (SHA-256, 4 KiB blocks, no salt) of a
/// stream, exactly as the kernel does: a Merkle tree over the data blocks,
/// whose root is hashed together with the file size in a fixed descriptor.
pub const VerityHasher = struct {
    size: u64 = 0,
    block: [block_size]u8 = undefined,
    filled: usize = 0,
    levels: [max_levels]Level = @splat(.{}),

    const Level = struct {
        hashes: [block_size]u8 = undefined,
        count: usize = 0,
        blocks_emitted: u64 = 0,
    };

    pub fn update(h: *VerityHasher, data: []const u8) void {
        var rest = data;
        h.size += data.len;
        while (rest.len > 0) {
            const n = @min(rest.len, block_size - h.filled);
            @memcpy(h.block[h.filled..][0..n], rest[0..n]);
            h.filled += n;
            rest = rest[n..];
            if (h.filled == block_size) h.flushData();
        }
    }

    fn flushData(h: *VerityHasher) void {
        @memset(h.block[h.filled..], 0);
        var digest: Digest = undefined;
        Sha256.hash(&h.block, &digest, .{});
        h.filled = 0;
        h.push(0, digest);
    }

    fn push(h: *VerityHasher, level: usize, digest: Digest) void {
        const l = &h.levels[level];
        @memcpy(l.hashes[l.count * digest_len ..][0..digest_len], &digest);
        l.count += 1;
        if (l.count == hashes_per_block) h.flushLevel(level);
    }

    fn flushLevel(h: *VerityHasher, level: usize) void {
        const l = &h.levels[level];
        @memset(l.hashes[l.count * digest_len ..], 0);
        var digest: Digest = undefined;
        Sha256.hash(&l.hashes, &digest, .{});
        l.count = 0;
        l.blocks_emitted += 1;
        h.push(level + 1, digest);
    }

    pub fn final(h: *VerityHasher) Digest {
        if (h.filled > 0) h.flushData();
        const data_blocks = (h.size + block_size - 1) / block_size;

        var root: Digest = @splat(0);
        if (data_blocks == 1) {
            // A file of one block has no tree: its root is that block's hash.
            root = h.levels[0].hashes[0..digest_len].*;
        } else if (data_blocks > 1) {
            var level: usize = 0;
            while (true) : (level += 1) {
                if (h.levels[level].count > 0) h.flushLevel(level);
                if (h.levels[level].blocks_emitted == 1) {
                    // The only block of this level: its hash is the root.
                    root = h.levels[level + 1].hashes[0..digest_len].*;
                    break;
                }
            }
        }

        // struct fsverity_descriptor, with no salt and no built-in signature.
        var descriptor: [256]u8 = @splat(0);
        descriptor[0] = 1; // version
        descriptor[1] = 1; // FS_VERITY_HASH_ALG_SHA256
        descriptor[2] = 12; // log2(block size)
        std.mem.writeInt(u64, descriptor[8..16], h.size, .little);
        @memcpy(descriptor[16..][0..digest_len], &root);
        var out: Digest = undefined;
        Sha256.hash(&descriptor, &out, .{});
        return out;
    }
};

pub fn verityDigestOfFile(io: Io, dir: Io.Dir, sub_path: []const u8) !Digest {
    var file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    var hasher: VerityHasher = .{};
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        hasher.update(chunk[0..n]);
    }
    return hasher.final();
}

const EnableArg = extern struct {
    version: u32 = 1,
    hash_algorithm: u32 = 1,
    block_size: u32 = block_size,
    salt_size: u32 = 0,
    salt_ptr: u64 = 0,
    sig_size: u32 = 0,
    reserved1: u32 = 0,
    sig_ptr: u64 = 0,
    reserved2: [11]u64 = @splat(0),
};

const MeasureArg = extern struct {
    digest_algorithm: u16 = 0,
    digest_size: u16 = digest_len,
    digest: Digest = undefined,
};

comptime {
    std.debug.assert(@sizeOf(EnableArg) == 128);
    std.debug.assert(@sizeOf(MeasureArg) == 36);
}

// _IOW('f', 133, struct fsverity_enable_arg) and _IOWR('f', 134, struct
// fsverity_digest); the latter's size is that of its fixed header only.
const FS_IOC_ENABLE_VERITY: u32 = (1 << 30) | (128 << 16) | ('f' << 8) | 133;
const FS_IOC_MEASURE_VERITY: u32 = (3 << 30) | (4 << 16) | ('f' << 8) | 134;

pub const EnableError = error{ VerityUnsupported, PermissionDenied, FileBusy, Unexpected };

/// Turns on fs-verity for a file opened read-only. From then on its contents
/// can never change. Succeeds if it was already on.
pub fn enableVerity(file: Io.File) EnableError!void {
    var arg: EnableArg = .{};
    return switch (linux.errno(linux.ioctl(file.handle, FS_IOC_ENABLE_VERITY, @intFromPtr(&arg)))) {
        .SUCCESS, .EXIST => {},
        .NOTTY, .OPNOTSUPP, .INVAL => error.VerityUnsupported,
        .PERM, .ACCES, .ROFS => error.PermissionDenied,
        .TXTBSY, .BUSY => error.FileBusy,
        else => error.Unexpected,
    };
}

/// The kernel's digest of a verity file, or null if verity is not enabled.
pub fn measureVerity(file: Io.File) ?Digest {
    var arg: MeasureArg = .{};
    if (linux.errno(linux.ioctl(file.handle, FS_IOC_MEASURE_VERITY, @intFromPtr(&arg))) != .SUCCESS) return null;
    if (arg.digest_algorithm != 1 or arg.digest_size != digest_len) return null;
    return arg.digest;
}

// ---------------------------------------------------------------------------
// Declared operations
// ---------------------------------------------------------------------------

/// Capability names, indexed by their number in <linux/capability.h>.
const capability_names = [_][]const u8{
    "chown",            "dac_override",     "dac_read_search", "fowner",       "fsetid",
    "kill",             "setgid",           "setuid",          "setpcap",      "linux_immutable",
    "net_bind_service", "net_broadcast",    "net_admin",       "net_raw",      "ipc_lock",
    "ipc_owner",        "sys_module",       "sys_rawio",       "sys_chroot",   "sys_ptrace",
    "sys_pacct",        "sys_admin",        "sys_boot",        "sys_nice",     "sys_resource",
    "sys_time",         "sys_tty_config",   "mknod",           "lease",        "audit_write",
    "audit_control",    "setfcap",          "mac_override",    "mac_admin",    "syslog",
    "wake_alarm",       "block_suspend",    "audit_read",      "perfmon",      "bpf",
    "checkpoint_restore",
};

pub fn capabilityNumber(name: []const u8) ?usize {
    for (capability_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

pub fn capabilityName(number: usize) ?[]const u8 {
    return if (number < capability_names.len) capability_names[number] else null;
}

/// Translates one declaration as written in a recipe into the form the kernel
/// reads, or returns null if it is not a valid declaration. `none` is valid
/// and translates to nothing: it states that a program needs no privilege.
///
///   all | net | mount | module | ptrace | bpf | root-ipc | none
///   cap:<name> | cap:*
///   write:<absolute path prefix> | write:*
///   exec:<absolute path> | exec:*
///   undeclared                      (written by dave, not by recipes)
fn canonicalOperation(arena: Allocator, op: []const u8) Allocator.Error!?[]const u8 {
    if (std.mem.eql(u8, op, "none")) return "";
    for ([_][]const u8{ "all", "net", "mount", "module", "ptrace", "bpf", "root-ipc", "cap:*", "write:*", "exec:*" }) |simple| {
        if (std.mem.eql(u8, op, simple)) return op;
    }
    if (std.mem.indexOfAny(u8, op, "\n\x00") != null) return null;
    if (std.mem.startsWith(u8, op, "cap:")) {
        const n = capabilityNumber(op[4..]) orelse return null;
        return try std.fmt.allocPrint(arena, "cap:{d}", .{n});
    }
    if (std.mem.startsWith(u8, op, "write:/") or std.mem.startsWith(u8, op, "exec:/")) return op;
    return null;
}

/// What a file that no declaration covers is sealed as. The security module
/// gives such a program no authority of its own: run by a process holding
/// `all` it inherits `all`, and otherwise it is reported and, in strict mode,
/// refused everything.
pub const undeclared = "undeclared";

/// The declaration text sealed into `path`: the operations of the first entry
/// of the package's `operations` that names the file, or else of the entry
/// that names no files (the package default), or else `undeclared`.
pub fn operationsText(arena: Allocator, operations: []const manifest_mod.Operations, path: []const u8) (Allocator.Error || error{InvalidOperation})![]const u8 {
    var chosen: ?manifest_mod.Operations = null;
    for (operations) |entry| {
        if (entry.programs.len == 0) {
            if (chosen == null) chosen = entry;
            continue;
        }
        for (entry.programs) |p| {
            if (std.mem.eql(u8, std.mem.trimStart(u8, p, "/"), path)) {
                chosen = entry;
                break;
            }
        }
        if (chosen != null and chosen.?.programs.len != 0) break;
    }
    const entry = chosen orelse return undeclared;
    var out: Io.Writer.Allocating = .init(arena);
    for (entry.allow) |op| {
        const text = (try canonicalOperation(arena, op)) orelse return error.InvalidOperation;
        if (text.len == 0) continue;
        if (out.written().len > 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
        out.writer.writeAll(text) catch return error.OutOfMemory;
    }
    if (out.written().len > max_ops_len) return error.InvalidOperation;
    return out.written();
}

// ---------------------------------------------------------------------------
// Signing
// ---------------------------------------------------------------------------

pub const secret_hex_len = Ecdsa.SecretKey.encoded_length * 2;
pub const public_hex_len = Ecdsa.PublicKey.uncompressed_sec1_encoded_length * 2;

pub const GeneratedKey = struct {
    secret_hex: [secret_hex_len]u8,
    /// The uncompressed SEC1 point, which is the form the kernel takes.
    public_hex: [public_hex_len]u8,
};

pub fn generateKey(io: Io) GeneratedKey {
    const pair = Ecdsa.KeyPair.generate(io);
    return .{
        .secret_hex = std.fmt.bytesToHex(pair.secret_key.toBytes(), .lower),
        .public_hex = std.fmt.bytesToHex(pair.public_key.toUncompressedSec1(), .lower),
    };
}

pub const SigningKey = struct {
    pair: Ecdsa.KeyPair,

    pub fn parse(secret_hex: []const u8) !SigningKey {
        var secret: [Ecdsa.SecretKey.encoded_length]u8 = undefined;
        const trimmed = std.mem.trim(u8, secret_hex, " \t\r\n");
        if (trimmed.len != secret_hex_len) return error.InvalidKey;
        _ = std.fmt.hexToBytes(&secret, trimmed) catch return error.InvalidKey;
        const sk = Ecdsa.SecretKey.fromBytes(secret) catch return error.InvalidKey;
        return .{ .pair = Ecdsa.KeyPair.fromSecretKey(sk) catch return error.InvalidKey };
    }

    pub fn publicHex(key: SigningKey) [public_hex_len]u8 {
        return std.fmt.bytesToHex(key.pair.public_key.toUncompressedSec1(), .lower);
    }

    /// Signs the binding of one file's contents to its declared operations.
    pub fn sign(key: SigningKey, arena: Allocator, verity: Digest, ops: []const u8) !Signature {
        const sig = try key.pair.sign(try message(arena, verity, ops), null);
        return sig.toBytes();
    }
};

/// What is signed: "JOE1", the verity digest, the length of the declaration
/// text as a little-endian u16, and the text.
fn message(arena: Allocator, verity: Digest, ops: []const u8) Allocator.Error![]const u8 {
    std.debug.assert(ops.len <= max_ops_len);
    const out = try arena.alloc(u8, magic.len + digest_len + 2 + ops.len);
    @memcpy(out[0..magic.len], magic);
    @memcpy(out[magic.len..][0..digest_len], &verity);
    std.mem.writeInt(u16, out[magic.len + digest_len ..][0..2], @intCast(ops.len), .little);
    @memcpy(out[magic.len + digest_len + 2 ..], ops);
    return out;
}

pub fn verify(arena: Allocator, public_hex: []const u8, verity: Digest, ops: []const u8, signature: Signature) !bool {
    var point: [Ecdsa.PublicKey.uncompressed_sec1_encoded_length]u8 = undefined;
    const trimmed = std.mem.trim(u8, public_hex, " \t\r\n");
    if (trimmed.len != public_hex_len) return error.InvalidKey;
    _ = std.fmt.hexToBytes(&point, trimmed) catch return error.InvalidKey;
    const pk = Ecdsa.PublicKey.fromSec1(&point) catch return error.InvalidKey;
    Ecdsa.Signature.fromBytes(signature).verify(try message(arena, verity, ops), pk) catch return false;
    return true;
}

/// The value of the seal attribute: "JOE1", the length of the declaration
/// text, the text, and the signature.
pub fn attribute(arena: Allocator, ops: []const u8, signature: Signature) Allocator.Error![]const u8 {
    const out = try arena.alloc(u8, magic.len + 2 + ops.len + signature_len);
    @memcpy(out[0..magic.len], magic);
    std.mem.writeInt(u16, out[magic.len..][0..2], @intCast(ops.len), .little);
    @memcpy(out[magic.len + 2 ..][0..ops.len], ops);
    @memcpy(out[magic.len + 2 + ops.len ..], &signature);
    return out;
}

pub fn parseSignature(hex: []const u8) ?Signature {
    var sig: Signature = undefined;
    if (hex.len != signature_len * 2) return null;
    _ = std.fmt.hexToBytes(&sig, hex) catch return null;
    return sig;
}

pub fn parseDigest(hex: []const u8) ?Digest {
    var digest: Digest = undefined;
    if (hex.len != digest_len * 2) return null;
    _ = std.fmt.hexToBytes(&digest, hex) catch return null;
    return digest;
}

// ---------------------------------------------------------------------------
// Applying
// ---------------------------------------------------------------------------

pub const Outcome = enum {
    sealed,
    /// The file system cannot do fs-verity, or this process may not set the
    /// attribute (an unprivileged image build). The file is intact and can be
    /// sealed later by `dave seal`.
    not_possible,
};

/// Seals a file that is complete and closed for writing: enables fs-verity
/// and attaches the seal. `name` is the attribute to use (`xattr_name` except
/// in tests, which cannot write to the security namespace).
pub fn apply(io: Io, dir: Io.Dir, sub_path: []const u8, value: []const u8, name: [*:0]const u8) !Outcome {
    var file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    enableVerity(file) catch |err| switch (err) {
        error.VerityUnsupported, error.PermissionDenied => return .not_possible,
        else => return err,
    };
    return switch (linux.errno(linux.fsetxattr(file.handle, name, value.ptr, value.len, 0))) {
        .SUCCESS => .sealed,
        .PERM, .ACCES, .OPNOTSUPP => .not_possible,
        else => error.Unexpected,
    };
}

/// Whether a file already carries exactly this seal over these contents.
pub fn isApplied(io: Io, dir: Io.Dir, sub_path: []const u8, verity: Digest, value: []const u8, name: [*:0]const u8) bool {
    var file = dir.openFile(io, sub_path, .{}) catch return false;
    defer file.close(io);
    const measured = measureVerity(file) orelse return false;
    if (!std.mem.eql(u8, &measured, &verity)) return false;
    var buf: [magic.len + 2 + max_ops_len + signature_len]u8 = undefined;
    const rc = linux.fgetxattr(file.handle, name, &buf, buf.len);
    if (linux.errno(rc) != .SUCCESS) return false;
    return std.mem.eql(u8, buf[0..rc], value);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn digestOf(data: []const u8) Digest {
    var h: VerityHasher = .{};
    // Feed in awkward pieces to exercise the buffering.
    var rest = data;
    var step: usize = 1;
    while (rest.len > 0) : (step = step * 7 % 9973 + 1) {
        const n = @min(rest.len, step);
        h.update(rest[0..n]);
        rest = rest[n..];
    }
    return h.final();
}

test "verity digest matches the kernel's" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Sizes around every boundary of the tree: empty, within a block, exactly
    // one block, one leaf block of hashes, and two levels of hashes.
    const sizes = [_]usize{
        0,                                  1,                    block_size - 1,       block_size,
        block_size + 1,                     hashes_per_block * block_size, hashes_per_block * block_size + 1,
        (hashes_per_block * hashes_per_block + 1) * block_size,
    };
    const data = try testing.allocator.alloc(u8, sizes[sizes.len - 1]);
    defer testing.allocator.free(data);
    var prng: std.Random.DefaultPrng = .init(0x6a6f65);
    prng.random().bytes(data);

    var compared: usize = 0;
    for (sizes, 0..) |size, i| {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "file-{d}", .{i});
        try tmp.dir.writeFile(io, .{ .sub_path = name, .data = data[0..size] });
        const mine = digestOf(data[0..size]);
        try testing.expectEqualSlices(u8, &mine, &try verityDigestOfFile(io, tmp.dir, name));

        var file = try tmp.dir.openFile(io, name, .{});
        defer file.close(io);
        try testing.expect(measureVerity(file) == null);
        enableVerity(file) catch |err| switch (err) {
            // No fs-verity here: the VM tests are the check instead.
            error.VerityUnsupported, error.PermissionDenied => continue,
            else => return err,
        };
        const kernel = measureVerity(file) orelse return error.TestUnexpectedResult;
        try testing.expectEqualSlices(u8, &kernel, &mine);
        compared += 1;

        // Sealed contents can no longer be opened for writing.
        try testing.expect(std.meta.isError(tmp.dir.openFile(io, name, .{ .mode = .read_write })));
    }
    if (compared == 0) return error.SkipZigTest;
}

test "declarations are translated and chosen per program" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const ops = [_]manifest_mod.Operations{
        .{ .programs = &.{ "usr/bin/mount", "/usr/bin/umount" }, .allow = &.{ "mount", "cap:sys_admin", "write:/etc/mtab" } },
        .{ .allow = &.{"net"} },
    };
    try testing.expectEqualStrings("mount\ncap:21\nwrite:/etc/mtab", try operationsText(arena, &ops, "usr/bin/mount"));
    try testing.expectEqualStrings("mount\ncap:21\nwrite:/etc/mtab", try operationsText(arena, &ops, "usr/bin/umount"));
    try testing.expectEqualStrings("net", try operationsText(arena, &ops, "usr/bin/other"));
    // A file nothing names is undeclared; `none` declares no privilege at all.
    try testing.expectEqualStrings("undeclared", try operationsText(arena, &.{}, "usr/bin/other"));
    try testing.expectEqualStrings("undeclared", try operationsText(arena, &.{.{ .programs = &.{"usr/bin/x"}, .allow = &.{"all"} }}, "usr/bin/y"));
    try testing.expectEqualStrings("", try operationsText(arena, &.{.{ .allow = &.{"none"} }}, "usr/bin/y"));
    try testing.expectEqualStrings("", try operationsText(arena, &.{.{ .programs = &.{"usr/bin/x"}, .allow = &.{} }}, "usr/bin/x"));
    try testing.expectEqualStrings("root-ipc\ncap:7", try operationsText(arena, &.{.{ .allow = &.{ "root-ipc", "none", "cap:setuid" } }}, "x"));

    try testing.expectError(error.InvalidOperation, operationsText(arena, &.{.{ .allow = &.{"cap:not_a_capability"} }}, "x"));
    try testing.expectError(error.InvalidOperation, operationsText(arena, &.{.{ .allow = &.{"write:relative/path"} }}, "x"));
    try testing.expectError(error.InvalidOperation, operationsText(arena, &.{.{ .allow = &.{"everything"} }}, "x"));
    try testing.expectError(error.InvalidOperation, operationsText(arena, &.{.{ .allow = &.{undeclared} }}, "x"));
    try testing.expectError(error.InvalidOperation, operationsText(arena, &.{.{ .allow = &.{"write:/a\nall"} }}, "x"));
    try testing.expectEqual(@as(?usize, 12), capabilityNumber("net_admin"));
    try testing.expectEqualStrings("checkpoint_restore", capabilityName(40).?);
}

test "a seal binds contents and declarations to the key" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const generated = generateKey(testing.io);
    const key = try SigningKey.parse(&generated.secret_hex);
    try testing.expectEqualStrings(&generated.public_hex, &key.publicHex());
    const other = generateKey(testing.io);

    const verity = digestOf("the program");
    const sig = try key.sign(arena, verity, "net\ncap:12");
    try testing.expect(try verify(arena, &generated.public_hex, verity, "net\ncap:12", sig));
    // Different contents, different declarations, different key: all fail.
    try testing.expect(!try verify(arena, &generated.public_hex, digestOf("another program"), "net\ncap:12", sig));
    try testing.expect(!try verify(arena, &generated.public_hex, verity, "all", sig));
    try testing.expect(!try verify(arena, &other.public_hex, verity, "net\ncap:12", sig));

    const value = try attribute(arena, "net\ncap:12", sig);
    try testing.expectEqualStrings("JOE1", value[0..4]);
    try testing.expectEqual(@as(u16, 10), std.mem.readInt(u16, value[4..6], .little));
    try testing.expectEqualStrings("net\ncap:12", value[6..16]);
    try testing.expectEqualSlices(u8, &sig, value[16..]);
    try testing.expectError(error.InvalidKey, SigningKey.parse("nonsense"));
}

test "apply and inspect a seal" {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "program", .data = "#!/bin/sh\necho sealed\n" });
    const verity = try verityDigestOfFile(io, tmp.dir, "program");
    const key = try SigningKey.parse(&generateKey(io).secret_hex);
    const value = try attribute(arena, "all", try key.sign(arena, verity, "all"));

    // Tests cannot write security.* attributes, so they use the user namespace.
    const test_attr = "user.joe-test";
    try testing.expect(!isApplied(io, tmp.dir, "program", verity, value, test_attr));
    switch (try apply(io, tmp.dir, "program", value, test_attr)) {
        .not_possible => return error.SkipZigTest,
        .sealed => {},
    }
    try testing.expect(isApplied(io, tmp.dir, "program", verity, value, test_attr));
    // Applying again is harmless.
    try testing.expectEqual(Outcome.sealed, try apply(io, tmp.dir, "program", value, test_attr));
    const other = try attribute(arena, "net", try key.sign(arena, verity, "net"));
    try testing.expect(!isApplied(io, tmp.dir, "program", verity, other, test_attr));
}
