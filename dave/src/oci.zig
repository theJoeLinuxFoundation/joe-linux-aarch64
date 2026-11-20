//! Container images: what `dave image build` makes of a spec with
//! `.format = .oci`.
//!
//! The image is an OCI image layout (image-spec 1.1) archived with tar, the
//! form `skopeo copy oci-archive:FILE docker://REGISTRY/NAME:TAG` pushes to a
//! registry and `podman load` and `docker load` read. It has one layer, the
//! spec's tree as a gzip-compressed tar: the tree is one dave transaction, so
//! there is nothing to share between layers, and gzip is what every runtime
//! reads. The archive also carries `manifest.json`, the description `docker
//! load` read before it understood OCI layouts.
//!
//! What the layer holds is the tree as it is, so this file only describes it:
//! the JSON documents that name the layer by its digests, and the image's
//! configuration (its command, environment and labels). image.zig runs tar
//! and gzip and puts the files together.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const arch = @import("arch.zig");

/// `.oci` in a spec.
pub const Options = struct {
    /// What `docker run IMAGE` runs.
    cmd: []const []const u8 = &.{"/usr/bin/bash"},
    env: []const []const u8 = &.{ "PATH=/usr/local/sbin:/usr/local/bin:/usr/bin", "LANG=C.UTF-8" },
    /// Labels of the image, such as org.opencontainers.image.source (which
    /// links a GitHub package to its repository). The build adds the
    /// version, from the tree's os-release, and when it was made.
    labels: []const Label = &.{},
};

pub const Label = struct {
    name: []const u8,
    value: []const u8,
};

/// A blob of the layout: its SHA-256 in hex, and its size.
pub const Blob = struct {
    digest: []const u8,
    size: u64,
};

pub const media = struct {
    pub const index = "application/vnd.oci.image.index.v1+json";
    pub const manifest = "application/vnd.oci.image.manifest.v1+json";
    pub const config = "application/vnd.oci.image.config.v1+json";
    pub const layer = "application/vnd.oci.image.layer.v1.tar+gzip";
};

pub const layout_file = "oci-layout";
pub const layout_text = "{\"imageLayoutVersion\":\"1.0.0\"}";

/// The path of a blob in the layout.
pub fn blobPath(arena: Allocator, digest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "blobs/sha256/{s}", .{digest});
}

fn digestRef(arena: Allocator, digest: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "sha256:{s}", .{digest});
}

/// The image's configuration: the platform, how it runs, and the layer by
/// the digest of its uncompressed tar (`diff_id`). `created` is RFC 3339.
pub fn configJson(arena: Allocator, options: Options, labels: []const Label, created: []const u8, diff_id: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("created");
    try s.write(created);
    try s.objectField("architecture");
    try s.write(arch.oci);
    try s.objectField("os");
    try s.write("linux");
    try s.objectField("config");
    try s.beginObject();
    try s.objectField("Env");
    try s.write(options.env);
    try s.objectField("Cmd");
    try s.write(options.cmd);
    try s.objectField("Labels");
    try writeLabels(&s, labels);
    try s.endObject();
    try s.objectField("rootfs");
    try s.beginObject();
    try s.objectField("type");
    try s.write("layers");
    try s.objectField("diff_ids");
    try s.write(&[_][]const u8{try digestRef(arena, diff_id)});
    try s.endObject();
    try s.objectField("history");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("created");
    try s.write(created);
    try s.objectField("created_by");
    try s.write("dave image build");
    try s.endObject();
    try s.endArray();
    try s.endObject();
    return out.written();
}

fn writeLabels(s: *std.json.Stringify, labels: []const Label) !void {
    try s.beginObject();
    for (labels) |l| {
        try s.objectField(l.name);
        try s.write(l.value);
    }
    try s.endObject();
}

fn writeDescriptor(arena: Allocator, s: *std.json.Stringify, media_type: []const u8, blob: Blob) !void {
    try s.objectField("mediaType");
    try s.write(media_type);
    try s.objectField("digest");
    try s.write(try digestRef(arena, blob.digest));
    try s.objectField("size");
    try s.write(blob.size);
}

/// The image manifest: its configuration and its one layer.
pub fn manifestJson(arena: Allocator, config: Blob, layer: Blob, labels: []const Label) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("schemaVersion");
    try s.write(2);
    try s.objectField("mediaType");
    try s.write(media.manifest);
    try s.objectField("config");
    try s.beginObject();
    try writeDescriptor(arena, &s, media.config, config);
    try s.endObject();
    try s.objectField("layers");
    try s.beginArray();
    try s.beginObject();
    try writeDescriptor(arena, &s, media.layer, layer);
    try s.endObject();
    try s.endArray();
    try s.objectField("annotations");
    try writeLabels(&s, labels);
    try s.endObject();
    return out.written();
}

/// The layout's index: the one manifest, tagged `tag`, as the image `name`.
/// The tag is the OCI annotation; `docker load` names the image by the one
/// containerd reads, which needs a whole reference, as `docker save` writes.
pub fn indexJson(arena: Allocator, manifest: Blob, name: []const u8, tag: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("schemaVersion");
    try s.write(2);
    try s.objectField("mediaType");
    try s.write(media.index);
    try s.objectField("manifests");
    try s.beginArray();
    try s.beginObject();
    try writeDescriptor(arena, &s, media.manifest, manifest);
    try s.objectField("annotations");
    try writeLabels(&s, &.{
        .{ .name = "org.opencontainers.image.ref.name", .value = tag },
        .{ .name = "io.containerd.image.name", .value = try std.fmt.allocPrint(arena, "docker.io/library/{s}:{s}", .{ name, tag }) },
    });
    try s.endObject();
    try s.endArray();
    try s.endObject();
    return out.written();
}

/// `manifest.json`, for a `docker load` that does not read OCI layouts.
pub fn dockerManifestJson(arena: Allocator, config: Blob, layer: Blob, tag: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginArray();
    try s.beginObject();
    try s.objectField("Config");
    try s.write(try blobPath(arena, config.digest));
    try s.objectField("RepoTags");
    try s.write(&[_][]const u8{tag});
    try s.objectField("Layers");
    try s.write(&[_][]const u8{try blobPath(arena, layer.digest)});
    try s.endObject();
    try s.endArray();
    return out.written();
}

/// A moment as RFC 3339 in UTC, such as "2026-11-18T20:46:00Z".
pub fn rfc3339(arena: Allocator, unix_seconds: u64) ![]const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = unix_seconds };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    });
}

/// The VERSION of an os-release file, or null.
pub fn osVersion(os_release: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, os_release, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "VERSION=")) continue;
        return std.mem.trim(u8, line["VERSION=".len..], "\"' \t\r");
    }
    return null;
}

/// tar's arguments for the layer: the whole of `tree`, owners as numbers
/// (a container's root is uid 0), file capabilities kept, in name order so
/// that the same tree gives the same tar.
pub fn layerTarArgv(arena: Allocator, tree: []const u8, out: []const u8) ![]const []const u8 {
    const argv = [_][]const u8{
        "tar",         "--create", "--file",                               out,
        "--directory", tree,       "--format=posix",                       "--numeric-owner",
        "--sort=name", "--xattrs", "--xattrs-include=security.capability", "--pax-option=delete=atime,delete=ctime",
        ".",
    };
    return arena.dupe([]const u8, &argv);
}

const testing = std.testing;

test "the documents of an image" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const labels = [_]Label{
        .{ .name = "org.opencontainers.image.source", .value = "https://github.com/theJoeLinuxFoundation/joe-linux" },
        .{ .name = "org.opencontainers.image.version", .value = "J1-7.3.1-0.3.0-alpha5" },
    };
    const config = try configJson(arena, .{}, &labels, "2026-11-18T20:46:00Z", "abababababababababababababababababababababababababababababababab");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, config, .{});
    try testing.expectEqualStrings(arch.oci, parsed.object.get("architecture").?.string);
    const cfg = parsed.object.get("config").?.object;
    try testing.expectEqualStrings("/usr/bin/bash", cfg.get("Cmd").?.array.items[0].string);
    try testing.expectEqualStrings("J1-7.3.1-0.3.0-alpha5", cfg.get("Labels").?.object.get("org.opencontainers.image.version").?.string);
    const diff_ids = parsed.object.get("rootfs").?.object.get("diff_ids").?.array.items;
    try testing.expectEqualStrings("sha256:abababababababababababababababababababababababababababababababab", diff_ids[0].string);

    const c: Blob = .{ .digest = "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd", .size = 700 };
    const l: Blob = .{ .digest = "efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef", .size = 50_000_000 };
    const manifest = try std.json.parseFromSliceLeaky(std.json.Value, arena, try manifestJson(arena, c, l, &labels), .{});
    try testing.expectEqual(@as(i64, 2), manifest.object.get("schemaVersion").?.integer);
    const layer = manifest.object.get("layers").?.array.items[0].object;
    try testing.expectEqualStrings(media.layer, layer.get("mediaType").?.string);
    try testing.expectEqual(@as(i64, 50_000_000), layer.get("size").?.integer);

    const index = try std.json.parseFromSliceLeaky(std.json.Value, arena, try indexJson(arena, .{ .digest = "0101010101010101010101010101010101010101010101010101010101010101", .size = 900 }, "joe", "latest"), .{});
    const entry = index.object.get("manifests").?.array.items[0].object;
    try testing.expectEqualStrings("sha256:0101010101010101010101010101010101010101010101010101010101010101", entry.get("digest").?.string);
    try testing.expectEqualStrings("latest", entry.get("annotations").?.object.get("org.opencontainers.image.ref.name").?.string);
    try testing.expectEqualStrings("docker.io/library/joe:latest", entry.get("annotations").?.object.get("io.containerd.image.name").?.string);

    const docker = try std.json.parseFromSliceLeaky(std.json.Value, arena, try dockerManifestJson(arena, c, l, "joe:latest"), .{});
    try testing.expectEqualStrings("blobs/sha256/efefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefef", docker.array.items[0].object.get("Layers").?.array.items[0].string);
}

test "dates and versions" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", try rfc3339(arena_state.allocator(), 0));
    try testing.expectEqualStrings("2026-11-18T20:46:05Z", try rfc3339(arena_state.allocator(), 1795034765));
    try testing.expectEqualStrings("J1-7.3.1-0.3.0-alpha5", osVersion("NAME=\"joe Linux\"\nVERSION=\"J1-7.3.1-0.3.0-alpha5\"\nID=joe\n").?);
    try testing.expectEqual(@as(?[]const u8, null), osVersion("ID=joe\n"));
}
