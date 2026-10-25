// SPDX-License-Identifier: MIT
//! Turns a test program into the disks a run boots with (ARCHITECTURE.md §10).
//!
//! 1. `<program> --describe` prints the system description (profiles and scenarios).
//! 2. The chosen profile is resolved: each node's root filesystem is materialized as an erofs
//!    image (OCI images through podman, cached by image ID), its command and environment are
//!    merged with the image's, and it gets an address and a disk.
//! 3. Disk 0 (the system disk) gets the program and /det/system.json: the frozen, resolved
//!    profile, which is also the run record of what was tested.
//!
//! Host tools: podman (for `image` sources) and mkfs.erofs (erofs-utils 1.7 or later).
const std = @import("std");
const assert = std.debug.assert;
const schema = @import("determinismo").schema;

pub const Options = struct {
    program: []const u8,
    /// The profile to resolve; null takes the first one.
    profile: ?[]const u8 = null,
    cache_directory: []const u8,
};

pub const Prepared = struct {
    /// Disk 0 first, then one disk per node, in node order.
    disk_paths: []const []const u8,
    system: schema.System,
    system_json: []const u8,
    /// Identifies the resolved system: snapshots and runs are keyed by it.
    hash: u64,
};

const Context = struct { arena: std.mem.Allocator, io: std.Io, cache: []const u8 };

const description_size_max = 1 << 20;
const filesystem_uuid = "64657465-726d-696e-6973-6d6f00000000";
const path_default = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

pub fn prepare(arena: std.mem.Allocator, io: std.Io, options: Options) !Prepared {
    const context = Context{ .arena = arena, .io = io, .cache = options.cache_directory };
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ "images", "systems", "staging" }) |directory| {
        try cwd.createDirPath(io, try path_join(context, &.{ context.cache, directory }));
    }
    const output = try tool(context, &.{ options.program, "--describe" });
    const description = try schema.parse(schema.Description, arena, output);
    if (description.schema != schema.version) return error.SchemaVersion;
    const profile = try profile_find(&description, options.profile);
    try profile_check(profile);

    const resolved = try arena.alloc(schema.Resolved, profile.nodes.len);
    const disk_paths = try arena.alloc([]const u8, profile.nodes.len + 1);
    for (profile.nodes, resolved, disk_paths[1..], 0..) |*node, *target, *disk, index| {
        disk.* = try node_resolve(context, node, @intCast(index), target);
    }
    const system = schema.System{
        .profile = profile.name,
        .nodes = resolved,
        .scenarios = description.scenarios,
    };
    var writer: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(system, .{ .emit_null_optional_fields = false }, &writer.writer);
    const system_json = writer.written();
    const program = try cwd.readFileAlloc(io, options.program, arena, .unlimited);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(system_json);
    hasher.update(program);
    const hash = hasher.final();
    disk_paths[0] = try system_disk(context, system_json, options.program, hash);
    return .{
        .disk_paths = disk_paths,
        .system = system,
        .system_json = system_json,
        .hash = hash,
    };
}

fn profile_find(description: *const schema.Description, name: ?[]const u8) !*const schema.Profile {
    if (description.profiles.len == 0) return error.NoProfiles;
    const wanted = name orelse return &description.profiles[0];
    for (description.profiles) |*profile| {
        if (std.mem.eql(u8, profile.name, wanted)) return profile;
    }
    std.debug.print("[determinismo] no profile named {s}\n", .{wanted});
    return error.UnknownProfile;
}

/// Names valid and unique, one source per node, dependencies on earlier nodes only.
fn profile_check(profile: *const schema.Profile) !void {
    if (profile.nodes.len == 0) return error.NoNodes;
    if (profile.nodes.len > schema.nodes_max) return error.TooManyNodes;
    for (profile.nodes, 0..) |node, index| {
        if (!schema.name_valid(node.name)) return error.BadNodeName;
        if (node.source.kind_count() != 1) return error.NodeNeedsOneSource;
        for (profile.nodes[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, node.name)) return error.DuplicateNodeName;
        }
        dependencies: for (node.after) |dependency| {
            for (profile.nodes[0..index]) |earlier| {
                if (std.mem.eql(u8, earlier.name, dependency)) continue :dependencies;
            }
            std.debug.print("[determinismo] {s} must come after {s}\n", .{ node.name, dependency });
            return error.DependencyOrder;
        }
    }
}

/// Resolves one node and returns the path of its disk image.
fn node_resolve(
    context: Context,
    node: *const schema.Node,
    index: u32,
    target: *schema.Resolved,
) ![]const u8 {
    const arena = context.arena;
    var disk_buffer: [3]u8 = undefined;
    const address = schema.node_address(index);
    target.* = .{
        .name = node.name,
        .address = try std.fmt.allocPrint(arena, "{d}.{d}.{d}.{d}", .{
            address[0], address[1], address[2], address[3],
        }),
        .disk = try arena.dupe(u8, schema.node_disk(&disk_buffer, index)),
        .digest = "",
        .command = &.{},
        .env = &.{},
        .ready = node.ready,
        .after = node.after,
        .faults = node.faults,
    };
    var image: ImageConfig = .{};
    const disk = if (node.source.image) |reference|
        try image_disk(context, reference, &image, &target.digest)
    else if (node.source.directory) |directory|
        try directory_disk(context, node.name, directory, &target.digest)
    else
        try binary_disk(context, node.name, node.source.binary.?, &image, &target.digest);
    target.command = try command_merge(arena, &image, node.command);
    if (target.command.len == 0) return error.NodeHasNoCommand;
    target.env = try environment_merge(arena, image.Env orelse &.{}, node.env);
    target.workdir = node.workdir orelse if (image.WorkingDir.len > 0) image.WorkingDir else "/";
    target.user = node.user orelse if (image.User.len > 0) image.User else null;
    return disk;
}

/// The part of `podman image inspect` we use (field names are podman's).
const ImageConfig = struct {
    User: []const u8 = "",
    Env: ?[]const []const u8 = null,
    Entrypoint: ?[]const []const u8 = null,
    Cmd: ?[]const []const u8 = null,
    WorkingDir: []const u8 = "",
};

const ImageInspect = struct { Id: []const u8, Config: ImageConfig = .{} };

fn image_disk(
    context: Context,
    reference: []const u8,
    config: *ImageConfig,
    digest: *[]const u8,
) ![]const u8 {
    if (!try tool_succeeds(context, &.{ "podman", "image", "exists", reference })) {
        std.debug.print("[determinismo] pulling {s}\n", .{reference});
        _ = try tool(context, &.{ "podman", "pull", "--quiet", reference });
    }
    const inspect_json = try tool(context, &.{ "podman", "image", "inspect", reference });
    const inspect = try schema.parse([]const ImageInspect, context.arena, inspect_json);
    if (inspect.len != 1) return error.ImageInspect;
    config.* = inspect[0].Config;
    digest.* = try std.fmt.allocPrint(context.arena, "sha256:{s}", .{inspect[0].Id});
    const id = inspect[0].Id;
    const disk = try path_join(context, &.{ context.cache, "images", try std.fmt.allocPrint(
        context.arena,
        "{s}.erofs",
        .{id},
    ) });
    if (exists(context, disk)) return disk;
    std.debug.print("[determinismo] flattening {s} into {s}\n", .{ reference, disk });
    const container = std.mem.trim(u8, try tool(context, &.{
        "podman", "create", "--quiet", reference,
    }), " \n");
    defer _ = tool(context, &.{ "podman", "rm", "--force", container }) catch {};
    const tar = try std.fmt.allocPrint(context.arena, "{s}.tar", .{disk});
    _ = try tool(context, &.{ "podman", "export", "--output", tar, container });
    defer std.Io.Dir.cwd().deleteFile(context.io, tar) catch {};
    try erofs_build(context, disk, &.{ "--tar=f", tar });
    return disk;
}

fn directory_disk(
    context: Context,
    name: []const u8,
    directory: []const u8,
    digest: *[]const u8,
) ![]const u8 {
    digest.* = try std.fmt.allocPrint(context.arena, "directory:{s}", .{directory});
    const disk = try path_join(context, &.{ context.cache, "images", try std.fmt.allocPrint(
        context.arena,
        "directory-{s}.erofs",
        .{name},
    ) });
    try erofs_build(context, disk, &.{directory});
    return disk;
}

fn binary_disk(
    context: Context,
    name: []const u8,
    binary: []const u8,
    config: *ImageConfig,
    digest: *[]const u8,
) ![]const u8 {
    const io = context.io;
    const staging = try path_join(context, &.{ context.cache, "staging", name });
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, staging) catch {};
    for ([_][]const u8{ "bin", "etc", "tmp", "proc", "sys", "dev" }) |directory| {
        try cwd.createDirPath(io, try path_join(context, &.{ staging, directory }));
    }
    const basename = std.fs.path.basename(binary);
    const target = try path_join(context, &.{ staging, "bin", basename });
    try cwd.copyFile(binary, cwd, target, io, .{});
    const content = try cwd.readFileAlloc(io, binary, context.arena, .unlimited);
    const content_hash = std.hash.Wyhash.hash(0, content);
    digest.* = try std.fmt.allocPrint(context.arena, "binary:{x}", .{content_hash});
    config.Entrypoint = try context.arena.dupe([]const u8, &.{try std.fmt.allocPrint(
        context.arena,
        "/bin/{s}",
        .{basename},
    )});
    const disk = try path_join(context, &.{ context.cache, "images", try std.fmt.allocPrint(
        context.arena,
        "binary-{s}.erofs",
        .{name},
    ) });
    try erofs_build(context, disk, &.{ "--all-root", staging });
    return disk;
}

/// Disk 0: the program and the resolved system, cached by their hash.
fn system_disk(
    context: Context,
    system_json: []const u8,
    program: []const u8,
    hash: u64,
) ![]const u8 {
    const io = context.io;
    const cwd = std.Io.Dir.cwd();
    const name = try std.fmt.allocPrint(context.arena, "{x:0>16}.erofs", .{hash});
    const disk = try path_join(context, &.{ context.cache, "systems", name });
    if (exists(context, disk)) return disk;
    const staging = try path_join(context, &.{ context.cache, "staging", "system" });
    cwd.deleteTree(io, staging) catch {};
    try cwd.createDirPath(io, staging);
    try cwd.copyFile(program, cwd, try path_join(context, &.{ staging, "program" }), io, .{});
    try cwd.writeFile(io, .{
        .sub_path = try path_join(context, &.{ staging, "system.json" }),
        .data = system_json,
    });
    try erofs_build(context, disk, &.{ "--all-root", staging });
    return disk;
}

/// Builds `disk` atomically (via a temporary name), reproducibly (fixed time and UUID).
fn erofs_build(context: Context, disk: []const u8, source: []const []const u8) !void {
    const temporary = try std.fmt.allocPrint(context.arena, "{s}.partial", .{disk});
    var argv: std.ArrayList([]const u8) = .empty;
    const fixed = [_][]const u8{ "mkfs.erofs", "--quiet", "-T0", "-U" ++ filesystem_uuid };
    try argv.appendSlice(context.arena, &fixed);
    try argv.appendSlice(context.arena, source[0 .. source.len - 1]);
    try argv.append(context.arena, temporary);
    try argv.append(context.arena, source[source.len - 1]);
    _ = try tool(context, argv.items);
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(temporary, cwd, disk, context.io);
}

/// Like `docker run`: the image's entrypoint, then our command or else the image's.
fn command_merge(
    arena: std.mem.Allocator,
    image: *const ImageConfig,
    command: ?[]const []const u8,
) ![]const []const u8 {
    const entrypoint = image.Entrypoint orelse &.{};
    const arguments = command orelse image.Cmd orelse &.{};
    return std.mem.concat(arena, []const u8, &.{ entrypoint, arguments });
}

/// The image's environment with ours on top (same name: ours wins), PATH always present.
fn environment_merge(
    arena: std.mem.Allocator,
    image: []const []const u8,
    ours: []const []const u8,
) ![]const []const u8 {
    var merged: std.ArrayList([]const u8) = .empty;
    for ([_][]const []const u8{ image, ours }) |layer| {
        for (layer) |entry| {
            const name = entry[0 .. std.mem.indexOfScalar(u8, entry, '=') orelse entry.len];
            for (merged.items) |*existing| {
                if (std.mem.startsWith(u8, existing.*, name) and existing.*.len > name.len and
                    existing.*[name.len] == '=')
                {
                    existing.* = entry;
                    break;
                }
            } else try merged.append(arena, entry);
        }
    }
    for (merged.items) |entry| {
        if (std.mem.startsWith(u8, entry, "PATH=")) return merged.items;
    }
    try merged.append(arena, "PATH=" ++ path_default);
    return merged.items;
}

/// Runs a host tool and returns its standard output; reports its standard error on failure.
fn tool(context: Context, argv: []const []const u8) ![]u8 {
    assert(argv.len > 0);
    const result = std.process.run(context.arena, context.io, .{ .argv = argv }) catch |err| {
        std.debug.print("[determinismo] cannot run {s}: {s}\n", .{ argv[0], @errorName(err) });
        return err;
    };
    if (!result.term.success()) {
        std.debug.print("[determinismo] {s} failed:\n{s}\n", .{ argv[0], result.stderr });
        return error.ToolFailed;
    }
    return result.stdout;
}

fn tool_succeeds(context: Context, argv: []const []const u8) !bool {
    const result = try std.process.run(context.arena, context.io, .{ .argv = argv });
    return result.term.success();
}

fn exists(context: Context, path: []const u8) bool {
    std.Io.Dir.cwd().access(context.io, path, .{}) catch return false;
    return true;
}

fn path_join(context: Context, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(context.arena, parts);
}

test environment_merge {
    const arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var arena = arena_state;
    defer arena.deinit();
    const merged = try environment_merge(arena.allocator(), &.{ "A=1", "PATHX=2" }, &.{"A=3"});
    try std.testing.expectEqual(@as(usize, 3), merged.len);
    try std.testing.expectEqualStrings("A=3", merged[0]);
    try std.testing.expect(std.mem.startsWith(u8, merged[2], "PATH="));
}

test command_merge {
    const arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    var arena = arena_state;
    defer arena.deinit();
    const image = ImageConfig{ .Entrypoint = &.{"entry.sh"}, .Cmd = &.{"serve"} };
    const ours = try command_merge(arena.allocator(), &image, &.{ "redis-server", "--x" });
    try std.testing.expectEqual(@as(usize, 3), ours.len);
    const theirs = try command_merge(arena.allocator(), &image, null);
    try std.testing.expectEqualStrings("serve", theirs[1]);
}
