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
const compose = @import("compose.zig");

pub const Options = struct {
    /// The test program (its `--describe`), or else a Compose file whose services become the
    /// nodes and whose images' Antithesis test templates become the scenarios.
    program: ?[]const u8 = null,
    compose: ?[]const u8 = null,
    /// A script for the composer and the fault injector (/det/script.json on the system disk).
    script: ?[]const u8 = null,
    /// The profile to resolve; null takes the first one.
    profile: ?[]const u8 = null,
    cache_directory: []const u8,
    /// A mutant (`determinismo mutate`): this node is built from its build context with a patch
    /// applied ("<node>=<patch file>").
    mutant: ?[]const u8 = null,
    /// Fault kinds every node also allows ("restart,crash"), and nodes that allow none
    /// ("client,monitor"): what an Antithesis launch says outside its Compose file.
    faults_added: ?[]const u8 = null,
    faults_none: ?[]const u8 = null,
};

pub const Prepared = struct {
    /// Disk 0 first, then one disk per node, in node order.
    disk_paths: []const []const u8,
    system: schema.System,
    system_json: []const u8,
    /// Identifies the resolved system: snapshots and runs are keyed by it.
    hash: u64,
};

const Context = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    cache: []const u8,
    mutant: ?[]const u8 = null,
};

const description_size_max = 1 << 20;
const filesystem_uuid = "64657465-726d-696e-6973-6d6f00000000";
const path_default = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

pub fn prepare(arena: std.mem.Allocator, io: std.Io, options: Options) !Prepared {
    const context = Context{
        .arena = arena,
        .io = io,
        .cache = options.cache_directory,
        .mutant = options.mutant,
    };
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ "images", "systems", "staging", "profiles", "mutants" }) |directory| {
        try cwd.createDirPath(io, try path_join(context, &.{ context.cache, directory }));
    }
    const description = try describe(context, options);
    if (description.schema != schema.version) return error.SchemaVersion;
    const profile = try profile_find(&description, options.profile);
    try profile_check(profile);

    const resolved = try arena.alloc(schema.Resolved, profile.nodes.len);
    const disk_paths = try arena.alloc([]const u8, profile.nodes.len + 1);
    var scenarios: std.ArrayList(schema.Scenario) = .empty;
    try scenarios.appendSlice(arena, description.scenarios);
    for (profile.nodes, resolved, disk_paths[1..], 0..) |*node, *target, *disk, index| {
        disk.* = try node_resolve(context, node, @intCast(index), target);
        try faults_adjust(&target.faults, node.name, options);
        if (options.compose != null) {
            const tests = try tests_listing(context, disk.*);
            try compose.templates(arena, node.name, tests, &scenarios);
        }
    }
    if (scenarios.items.len == 0) return error.NoScenarios;
    const system = schema.System{
        .profile = profile.name,
        .nodes = resolved,
        .scenarios = scenarios.items,
        .sdk_setup = options.compose != null,
    };
    var writer: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(system, .{ .emit_null_optional_fields = false }, &writer.writer);
    const system_json = writer.written();
    const program = if (options.program) |path|
        try cwd.readFileAlloc(io, path, arena, .unlimited)
    else
        "";
    const script = if (options.script) |path|
        try cwd.readFileAlloc(io, path, arena, .limited(1 << 20))
    else
        null;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(system_json);
    hasher.update(program);
    if (script) |text| hasher.update(text);
    const hash = hasher.final();
    disk_paths[0] = try system_disk(context, .{
        .system_json = system_json,
        .program = options.program,
        .script = script,
        .hash = hash,
    });
    const source = options.program orelse options.compose.?;
    try profile_remember(context, source, &system, system_json);
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
        .memory_max_mib = node.memory_max_mib,
        .privileged = node.privileged,
        .antithesis_library = node.antithesis_library,
    };
    var image: ImageConfig = .{};
    const disk = if (node.source.image) |reference|
        try image_disk(context, reference, &image, &target.digest)
    else if (node.source.build) |build| disk: {
        const built = try image_build(context, try mutant_build(context, node, build));
        break :disk try image_disk(context, built, &image, &target.digest);
    } else if (node.source.directory) |directory|
        try directory_disk(context, node.name, directory, &target.digest)
    else
        try binary_disk(context, node.name, node.source.binary.?, &image, &target.digest);
    target.command = try command_merge(arena, &image, node.entrypoint, node.command);
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
    const tests = try std.fmt.allocPrint(context.arena, "{s}.tests", .{disk});
    if (exists(context, disk) and exists(context, tests)) return disk;
    std.debug.print("[determinismo] flattening {s} into {s}\n", .{ reference, disk });
    const container = std.mem.trim(u8, try tool(context, &.{
        "podman", "create", "--quiet", reference,
    }), " \n");
    defer _ = tool(context, &.{ "podman", "rm", "--force", container }) catch {};
    const tar = try std.fmt.allocPrint(context.arena, "{s}.tar", .{disk});
    _ = try tool(context, &.{ "podman", "export", "--output", tar, container });
    defer std.Io.Dir.cwd().deleteFile(context.io, tar) catch {};
    // Its executables, for test templates (written before the disk: a disk implies them).
    const listing = try tool(context, &.{ "tar", "-tvf", tar });
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = tests,
        .data = try executables_of(context.arena, listing),
    });
    if (!exists(context, disk)) try erofs_build(context, disk, &.{ "--tar=f", tar });
    return disk;
}

/// The names of the program's (or Compose file's) profiles.
pub fn profile_names(arena: std.mem.Allocator, io: std.Io, options: Options) ![]const []const u8 {
    const context = Context{ .arena = arena, .io = io, .cache = options.cache_directory };
    const description = try describe(context, options);
    const names = try arena.alloc([]const u8, description.profiles.len);
    for (description.profiles, names) |profile, *name| name.* = profile.name;
    return names;
}

fn describe(context: Context, options: Options) !schema.Description {
    if (options.compose) |path| {
        const profiles = try context.arena.alloc(schema.Profile, 1);
        profiles[0] = try compose.profile(context.arena, context.io, path);
        return .{ .profiles = profiles, .scenarios = &.{} };
    }
    const program = options.program orelse return error.NoProgram;
    const output = try tool(context, &.{ program, "--describe" });
    return schema.parse(schema.Description, context.arena, output);
}

/// The image's executables, recorded next to its disk when it was flattened.
fn tests_listing(context: Context, disk: []const u8) ![]const []const u8 {
    const path = try std.fmt.allocPrint(context.arena, "{s}.tests", .{disk});
    const limit: std.Io.Limit = .limited(1 << 22);
    const text = std.Io.Dir.cwd().readFileAlloc(context.io, path, context.arena, limit) catch
        return &.{}; // Not an image (a directory or a binary): no templates.
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| try list.append(context.arena, line);
    return list.items;
}

/// From `tar -tv` output: the regular files executable by their owner.
fn executables_of(arena: std.mem.Allocator, listing: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len < 10 or line[0] != '-' or line[3] != 'x') continue;
        // "-rwxr-xr-x owner/group size date time path": the path is the sixth field on.
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        for (0..5) |_| _ = fields.next();
        const path = fields.rest();
        if (path.len == 0) continue;
        try out.appendSlice(arena, path);
        try out.append(arena, '\n');
    }
    return out.items;
}

/// Keeps the resolved system of each program and profile, and reports what changed since the
/// last run of the same pair: snapshots and tapes from before do not apply to the new one.
fn profile_remember(
    context: Context,
    program: []const u8,
    system: *const schema.System,
    system_json: []const u8,
) !void {
    const name = try std.fmt.allocPrint(context.arena, "{s}--{s}.json", .{
        std.fs.path.basename(program), system.profile,
    });
    const path = try path_join(context, &.{ context.cache, "profiles", name });
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(context.io, path, context.arena, .limited(1 << 20))) |previous_json| {
        if (!std.mem.eql(u8, previous_json, system_json)) {
            const previous = try schema.parse(schema.System, context.arena, previous_json);
            std.debug.print("[determinismo] profile {s} changed since the last run:\n", .{
                system.profile,
            });
            differences = 0;
            try profile_diff(context.arena, &previous, system);
            if (differences == 0) std.debug.print("  (in its encoding only)\n", .{});
        }
    } else |_| {}
    try cwd.writeFile(context.io, .{ .sub_path = path, .data = system_json });
}

fn profile_diff(
    arena: std.mem.Allocator,
    old: *const schema.System,
    new: *const schema.System,
) !void {
    for (old.nodes) |node| {
        if (new.node(node.name) == null) {
            differences += 1;
            std.debug.print("  - node {s}\n", .{node.name});
        }
    }
    for (new.nodes) |node| {
        const before = old.node(node.name) orelse {
            differences += 1;
            std.debug.print("  + node {s}\n", .{node.name});
            continue;
        };
        try changed(arena, node.name, "digest", before.digest, node.digest);
        try changed(arena, node.name, "address", before.address, node.address);
        try changed(arena, node.name, "disk", before.disk, node.disk);
        try changed(arena, node.name, "command", before.command, node.command);
        try changed(arena, node.name, "env", before.env, node.env);
        try changed(arena, node.name, "workdir", before.workdir, node.workdir);
        try changed(arena, node.name, "user", before.user, node.user);
        try changed(arena, node.name, "ready", before.ready, node.ready);
        try changed(arena, node.name, "after", before.after, node.after);
        try changed(arena, node.name, "faults", before.faults, node.faults);
    }
    for (old.scenarios) |scenario| {
        if (new.scenario(scenario.name) == null) {
            differences += 1;
            std.debug.print("  - scenario {s}\n", .{scenario.name});
        }
    }
    for (new.scenarios) |scenario| {
        const before = old.scenario(scenario.name) orelse {
            differences += 1;
            std.debug.print("  + scenario {s}\n", .{scenario.name});
            continue;
        };
        try changed(arena, "scenario", scenario.name, before.*, scenario);
    }
}

var differences: u32 = 0;

/// Prints `owner.field: old -> new` when the two differ (compared as JSON).
fn changed(
    arena: std.mem.Allocator,
    owner: []const u8,
    field: []const u8,
    old: anytype,
    new: @TypeOf(old),
) !void {
    const old_json = try json(arena, old);
    const new_json = try json(arena, new);
    if (std.mem.eql(u8, old_json, new_json)) return;
    differences += 1;
    std.debug.print("  ~ {s}.{s}: {s} -> {s}\n", .{ owner, field, old_json, new_json });
}

fn json(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.written();
}

/// Builds the image (podman reuses its layer cache) and returns its ID.
/// Fault kinds added to every node (by field name: restart, crash, wipe, process_kill, ...),
/// then none at all for the nodes named in `faults_none`.
fn faults_adjust(faults: *schema.Faults, name: []const u8, options: Options) !void {
    if (options.faults_added) |list| {
        var kinds = std.mem.tokenizeScalar(u8, list, ',');
        kinds: while (kinds.next()) |kind_text| {
            const kind = std.mem.trimStart(u8, kind_text, "+");
            const info = @typeInfo(schema.Faults).@"struct";
            inline for (info.field_names, info.field_types) |field, Type| {
                if (Type == bool and std.mem.eql(u8, field, kind)) {
                    @field(faults, field) = true;
                    continue :kinds;
                }
            }
            std.debug.print("[determinismo] --faults: no fault kind {s}\n", .{kind});
            return error.UnknownFaultKind;
        }
    }
    if (options.faults_none) |list| {
        var names = std.mem.tokenizeScalar(u8, list, ',');
        while (names.next()) |none| {
            if (!std.mem.eql(u8, none, name)) continue;
            const info = @typeInfo(schema.Faults).@"struct";
            inline for (info.field_names, info.field_types) |field, Type| {
                if (Type == bool) @field(faults, field) = false;
            }
            faults.custom = &.{};
        }
    }
}

/// The build of a node, or for a mutant's node the same build from a patched copy of its
/// context (in the cache, by the patch's content: built once).
fn mutant_build(context: Context, node: *const schema.Node, build: schema.Build) !schema.Build {
    const mutant = context.mutant orelse return build;
    const equals = std.mem.indexOfScalar(u8, mutant, '=') orelse return error.BadMutant;
    if (!std.mem.eql(u8, mutant[0..equals], node.name)) return build;
    const patch_path = mutant[equals + 1 ..];
    const cwd = std.Io.Dir.cwd();
    const patch = try cwd.readFileAlloc(context.io, patch_path, context.arena, .limited(1 << 24));
    var hasher = std.hash.Wyhash.init(0x6d7574616e74);
    hasher.update(build.context);
    hasher.update(patch);
    const name = try std.fmt.allocPrint(context.arena, "{x:0>16}", .{hasher.final()});
    const copy = try path_join(context, &.{ context.cache, "mutants", name });
    if (!exists(context, copy)) {
        const staging = try std.fmt.allocPrint(context.arena, "{s}.staging", .{copy});
        _ = tool(context, &.{ "rm", "-rf", staging }) catch {};
        const source = try std.fmt.allocPrint(context.arena, "{s}/", .{build.context});
        _ = try tool(context, &.{
            "rsync",   "-a",        "--exclude",  ".git",      "--exclude",
            "zig-out", "--exclude", ".zig-cache", "--exclude", ".determinismo-cache",
            source,    staging,
        });
        const absolute = try cwd.realPathFileAlloc(context.io, patch_path, context.arena);
        _ = try tool(context, &.{ "git", "-C", staging, "apply", "--unsafe-paths", absolute });
        _ = try tool(context, &.{ "mv", staging, copy });
    }
    std.debug.print("[determinismo] mutant: {s} built with {s}\n", .{ node.name, patch_path });
    return .{ .context = copy, .dockerfile = build.dockerfile };
}

fn image_build(context: Context, build: schema.Build) ![]const u8 {
    const dockerfile = try path_join(context, &.{ build.context, build.dockerfile });
    std.debug.print("[determinismo] building {s}\n", .{dockerfile});
    const output = try tool(context, &.{
        "podman", "build", "--quiet", "--file", dockerfile, build.context,
    });
    const id = std.mem.trim(u8, output, " \n");
    if (id.len == 0) return error.ImageBuild;
    return id[if (std.mem.lastIndexOfScalar(u8, id, '\n')) |index| index + 1 else 0..];
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
    try erofs_build(context, disk, &.{ "--ignore-mtime", directory });
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
    try erofs_build(context, disk, &.{ "--all-root", "--ignore-mtime", staging });
    return disk;
}

/// Disk 0: the program and the resolved system, cached by their hash.
const SystemFiles = struct {
    system_json: []const u8,
    program: ?[]const u8,
    script: ?[]const u8,
    hash: u64,
};

fn system_disk(context: Context, files: SystemFiles) ![]const u8 {
    const system_json = files.system_json;
    const program = files.program;
    const hash = files.hash;
    const io = context.io;
    const cwd = std.Io.Dir.cwd();
    const name = try std.fmt.allocPrint(context.arena, "{x:0>16}.erofs", .{hash});
    const disk = try path_join(context, &.{ context.cache, "systems", name });
    if (exists(context, disk)) return disk;
    const staging = try path_join(context, &.{ context.cache, "staging", "system" });
    cwd.deleteTree(io, staging) catch {};
    try cwd.createDirPath(io, staging);
    if (program) |path| {
        try cwd.copyFile(path, cwd, try path_join(context, &.{ staging, "program" }), io, .{});
    }
    try cwd.writeFile(io, .{
        .sub_path = try path_join(context, &.{ staging, "system.json" }),
        .data = system_json,
    });
    if (files.script) |text| {
        try cwd.writeFile(io, .{
            .sub_path = try path_join(context, &.{ staging, "script.json" }),
            .data = text,
        });
    }
    try erofs_build(context, disk, &.{ "--all-root", "--ignore-mtime", staging });
    return disk;
}

/// Builds `disk` atomically (via a temporary name), reproducibly (fixed time and UUID): disks are
/// read by the guest, so their exact bytes are part of every timeline.
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

/// Like `docker run`: the entrypoint (ours, else the image's), then the command (ours, else
/// the image's, unless we replaced the entrypoint, which drops the image's command too).
fn command_merge(
    arena: std.mem.Allocator,
    image: *const ImageConfig,
    entrypoint: ?[]const []const u8,
    command: ?[]const []const u8,
) ![]const []const u8 {
    const entry = entrypoint orelse image.Entrypoint orelse &.{};
    const image_command = if (entrypoint != null) null else image.Cmd;
    const arguments = command orelse image_command orelse &.{};
    return std.mem.concat(arena, []const u8, &.{ entry, arguments });
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
    const ours = try command_merge(arena.allocator(), &image, null, &.{ "redis-server", "--x" });
    try std.testing.expectEqual(@as(usize, 3), ours.len);
    const theirs = try command_merge(arena.allocator(), &image, null, null);
    try std.testing.expectEqualStrings("serve", theirs[1]);
    const replaced = try command_merge(arena.allocator(), &image, &.{"sh"}, null);
    try std.testing.expectEqual(@as(usize, 1), replaced.len);
}
