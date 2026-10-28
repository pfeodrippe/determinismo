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
const kubernetes = @import("kubernetes.zig");
const source_lines = @import("lines.zig");

pub const Options = struct {
    /// The test program (its `--describe`), or else a Compose file whose services become the
    /// nodes and whose images' Antithesis test templates become the scenarios.
    program: ?[]const u8 = null,
    compose: ?[]const u8 = null,
    /// Or a directory of Kubernetes manifests, run in a single-node K3s cluster (kubernetes.zig)
    /// whose images' Antithesis test templates become the scenarios.
    kubernetes: ?[]const u8 = null,
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
    /// A pinned system (`explore --system`): what an earlier prepare resolved and the node disks
    /// it booted (its pin, `<cache>/systems/<hash>.pin.json`), used as is: nothing is described,
    /// pulled or built, so a run replays on another host (of the same CPU model) without its
    /// images or Dockerfiles. Faults were adjusted when it was pinned.
    pinned: ?[]const u8 = null,
};

pub const Prepared = struct {
    /// Disk 0 first, then one disk per node, in node order.
    disk_paths: []const []const u8,
    system: schema.System,
    system_json: []const u8,
    /// Identifies the resolved system: snapshots and runs are keyed by it.
    hash: u64,
    /// Its pin (`Options.pinned`).
    pin_path: []const u8,
};

/// A resolved system with its node disks: their paths, absolute or relative to the pin's
/// directory (a kit: the pin and the disks side by side).
pub const Pin = struct {
    /// The resolved system's JSON, byte for byte: it is hashed.
    system_json: []const u8,
    /// One per node, in node order.
    disks: []const []const u8,
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
    for ([_][]const u8{ "images", "systems", "staging", "profiles", "mutants", "kubernetes" }) |directory| {
        try cwd.createDirPath(io, try path_join(context, &.{ context.cache, directory }));
    }
    if (options.pinned) |path| return pinned_prepare(context, options, path);
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
        // Compose's systems declare their setup through an Antithesis SDK; a Kubernetes one's
        // is its setup command's (kapp's readiness, as Antithesis's).
        .sdk_setup = options.compose != null,
        .checks = description.checks,
    };
    var writer: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(system, .{ .emit_null_optional_fields = false }, &writer.writer);
    const system_json = writer.written();
    const prepared = try system_finish(context, options, system, system_json, disk_paths);
    const source = options.program orelse options.compose orelse options.kubernetes.?;
    try profile_remember(context, source, &system, system_json);
    return prepared;
}

/// The system disk (the system, the program, the script) and the pin, for a resolved system
/// whose node disks are `disk_paths[1..]`.
fn system_finish(
    context: Context,
    options: Options,
    system: schema.System,
    system_json: []const u8,
    disk_paths: [][]const u8,
) !Prepared {
    const cwd = std.Io.Dir.cwd();
    const program = if (options.program) |path|
        try cwd.readFileAlloc(context.io, path, context.arena, .unlimited)
    else
        "";
    const script = if (options.script) |path|
        try cwd.readFileAlloc(context.io, path, context.arena, .limited(1 << 20))
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
    // The pin names the node disks by absolute path: it is valid wherever it is copied to on
    // this host (a kit for another host has them beside it, by name).
    const disks = try context.arena.alloc([]const u8, disk_paths.len - 1);
    for (disk_paths[1..], disks) |disk, *absolute| {
        absolute.* = try cwd.realPathFileAlloc(context.io, disk, context.arena);
    }
    var writer: std.Io.Writer.Allocating = .init(context.arena);
    const pin: Pin = .{ .system_json = system_json, .disks = disks };
    try std.json.Stringify.value(pin, .{}, &writer.writer);
    const pin_name = try std.fmt.allocPrint(context.arena, "{x:0>16}.pin.json", .{hash});
    const pin_path = try path_join(context, &.{ context.cache, "systems", pin_name });
    if (!exists(context, pin_path)) {
        const staging = try own_path(context, pin_path, "partial");
        try cwd.writeFile(context.io, .{ .sub_path = staging, .data = writer.written() });
        try cwd.rename(staging, cwd, pin_path, context.io);
    }
    return .{
        .disk_paths = disk_paths,
        .system = system,
        .system_json = system_json,
        .hash = hash,
        .pin_path = pin_path,
    };
}

/// `Options.pinned`: the pin's system and node disks, as they are.
fn pinned_prepare(context: Context, options: Options, path: []const u8) !Prepared {
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(description_size_max);
    const pin = try schema.parse(Pin, context.arena, try cwd.readFileAlloc(context.io, path, context.arena, limit));
    const system = try schema.parse(schema.System, context.arena, pin.system_json);
    if (pin.disks.len != system.nodes.len) return error.PinDisks;
    const disk_paths = try context.arena.alloc([]const u8, pin.disks.len + 1);
    const directory = std.fs.path.dirname(path) orelse ".";
    for (pin.disks, disk_paths[1..]) |disk, *target| {
        target.* = if (std.fs.path.isAbsolute(disk) and exists(context, disk))
            disk
        else
            try path_join(context, &.{ directory, std.fs.path.basename(disk) });
        if (!exists(context, target.*)) {
            std.debug.print("[determinismo] the pinned disk {s} is not there\n", .{disk});
            return error.PinnedDiskMissing;
        }
    }
    return system_finish(context, options, system, pin.system_json, disk_paths);
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
        if (node.ulimits) |ulimits| {
            if (ulimits.len > schema.ulimits_max) return error.TooManyUlimits;
            for (ulimits) |ulimit| {
                if (schema.ulimit_resource(ulimit.name) == null or ulimit.soft > ulimit.hard) {
                    std.debug.print("[determinismo] {s}: ulimit {s} (soft {d}, hard {d}) is not one " ++
                        "of Docker's, or its soft limit is above its hard one\n", .{
                        node.name, ulimit.name, ulimit.soft, ulimit.hard,
                    });
                    return error.BadUlimit;
                }
            }
        }
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
        .ulimits = node.ulimits,
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
    const lines_note = try std.fmt.allocPrint(context.arena, "{s}.lines-{d}", .{ disk, source_lines.format_version });
    if (exists(context, disk) and exists(context, tests) and exists(context, lines_note)) return disk;
    std.debug.print("[determinismo] flattening {s} into {s}\n", .{ reference, disk });
    const container = std.mem.trim(u8, try tool(context, &.{
        "podman", "create", "--quiet", reference,
    }), " \n");
    defer _ = tool(context, &.{ "podman", "rm", "--force", container }) catch {};
    const tar = try own_path(context, disk, "tar");
    _ = try tool(context, &.{ "podman", "export", "--output", tar, container });
    defer std.Io.Dir.cwd().deleteFile(context.io, tar) catch {};
    // Its executables, for test templates (written before the disk: a disk implies them).
    const listing = try tool(context, &.{ "tar", "-tvf", tar });
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = tests,
        .data = try executables_of(context.arena, listing),
    });
    // Source lines of its instrumented native code, in the image (a disk made before lacks them).
    const made = try symbol_lines(context, tar, listing, disk);
    if (made > 0 and exists(context, disk)) try std.Io.Dir.cwd().deleteFile(context.io, disk);
    if (!exists(context, disk)) try erofs_build(context, disk, &.{ "--tar=f", tar });
    try std.Io.Dir.cwd().writeFile(context.io, .{
        .sub_path = lines_note,
        .data = try std.fmt.allocPrint(context.arena, "{d}\n", .{made}),
    });
    return disk;
}

/// Tables of source lines (lines.zig) of the image's ELF files under /symbols, Antithesis's place
/// for the symbols of instrumented code, appended to its export: how many were made.
fn symbol_lines(context: Context, tar: []const u8, listing: []const u8, disk: []const u8) !usize {
    var members: std.ArrayList([]const u8) = .empty;
    var rows = std.mem.tokenizeScalar(u8, listing, '\n');
    while (rows.next()) |row| {
        if (row.len < 10 or row[0] != '-') continue; // Regular files.
        var fields = std.mem.tokenizeScalar(u8, row, ' ');
        for (0..5) |_| _ = fields.next();
        const member = fields.rest();
        const path = std.mem.trimStart(u8, member, "./");
        if (!std.mem.startsWith(u8, path, "symbols/")) continue;
        if (std.mem.startsWith(u8, path, source_lines.tables_directory ++ "/")) continue;
        try members.append(context.arena, member);
    }
    if (members.items.len == 0) return 0;
    const cwd = std.Io.Dir.cwd();
    const staging = try own_path(context, disk, "symbols");
    defer cwd.deleteTree(context.io, staging) catch {};
    const tables = try path_join(context, &.{ staging, source_lines.tables_directory });
    try cwd.createDirPath(context.io, tables);
    var extract: std.ArrayList([]const u8) = .empty;
    try extract.appendSlice(context.arena, &.{ "tar", "-xf", tar, "-C", staging });
    try extract.appendSlice(context.arena, members.items);
    _ = try tool(context, extract.items);
    var made: usize = 0;
    for (members.items) |member| {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const path = try path_join(context, &.{ staging, member });
        const gpa = std.heap.smp_allocator;
        const table = (source_lines.of(gpa, scratch.allocator(), context.io, path) catch null) orelse continue;
        try cwd.writeFile(context.io, .{
            .sub_path = try path_join(context, &.{ tables, table.name }),
            .data = table.bytes,
        });
        std.debug.print("[determinismo] source lines of /{s}: {d} bytes\n", .{
            std.mem.trimStart(u8, member, "./"), table.bytes.len,
        });
        made += 1;
    }
    if (made > 0) _ = try tool(context, &.{ "tar", "-rf", tar, "-C", staging, source_lines.tables_directory });
    return made;
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
    if (options.kubernetes) |directory| return kubernetes_describe(context, directory);
    if (options.compose) |path| {
        const profiles = try context.arena.alloc(schema.Profile, 1);
        profiles[0] = try compose.profile(context.arena, context.io, path);
        return .{ .profiles = profiles, .scenarios = &.{} };
    }
    const program = options.program orelse return error.NoProgram;
    const output = try tool(context, &.{ program, "--describe" });
    return schema.parse(schema.Description, context.arena, output);
}

/// Kubernetes manifests as a system (kubernetes.zig): one K3s node, its image built from a
/// context made here (`<cache>/kubernetes/<hash>`: K3s, the workload's images saved, the
/// manifests, the setup and exec scripts, a wrapper per test template), and a scenario per
/// template directory found in the workload's images, its first command the setup.
fn kubernetes_describe(context: Context, directory: []const u8) !schema.Description {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    // The manifests, by path relative to the directory (sorted: the hash and the copy follow).
    var files: std.ArrayList([]const u8) = .empty;
    var contents: std.ArrayList([]const u8) = .empty;
    var images: std.ArrayList([]const u8) = .empty;
    const listed = try tool(context, &.{ "find", directory, "-type", "f", "(", "-name", "*.yaml", "-o", "-name", "*.yml", "-o", "-name", "*.json", ")" });
    var lines = std.mem.tokenizeScalar(u8, listed, '\n');
    while (lines.next()) |path| try files.append(arena, path);
    std.sort.insertion([]const u8, files.items, {}, string_before);
    if (files.items.len == 0) return error.NoManifests;
    var hasher = std.hash.Wyhash.init(0);
    // What the context is made of besides them: a change to its scripts or K3s makes another.
    for ([_][]const u8{ kubernetes.ready_script, kubernetes.exec_script, kubernetes.k3s_image }) |part| {
        hasher.update(part);
    }
    for (files.items) |path| {
        const text = try cwd.readFileAlloc(context.io, path, arena, .limited(16 << 20));
        try contents.append(arena, text);
        hasher.update(path[directory.len..]);
        hasher.update(text);
        try kubernetes.images_note(arena, text, &images);
    }
    // Every image, as K3s will find it (fully qualified: nothing is pulled in the guest), with
    // its executables: test templates may be in any of them.
    var executables: std.ArrayList([]const u8) = .empty;
    var owners: std.ArrayList([]const u8) = .empty; // The image of each executable.
    for (images.items) |image| {
        if (!kubernetes.qualified(image)) {
            std.debug.print("[determinismo] {s}: images in Kubernetes manifests are fully qualified " ++
                "(registry, name and tag or digest), as Antithesis asks\n", .{image});
            return error.ImageNotQualified;
        }
        const id = try image_id(context, image);
        hasher.update(id);
        for (try image_executables(context, image, id)) |path| {
            try executables.append(arena, path);
            try owners.append(arena, image);
        }
    }
    const hash = hasher.final();
    const build = try path_join(context, &.{ context.cache, "kubernetes", try std.fmt.allocPrint(arena, "{x:0>16}", .{hash}) });
    var scenarios: std.ArrayList(schema.Scenario) = .empty;
    try compose.templates(arena, kubernetes.node_name, executables.items, &scenarios);
    if (scenarios.items.len == 0) {
        std.debug.print("[determinismo] no Antithesis test template in the manifests' images " ++
            "(/opt/antithesis/test/v1/<template>/<command>)\n", .{});
        return error.NoScenarios;
    }
    // Each scenario's first command deploys the manifests and waits until they are ready.
    for (scenarios.items) |*scenario| {
        const commands = try arena.alloc(schema.Command, scenario.commands.len + 1);
        commands[0] = .{ .kind = .setup, .name = "setup_kubernetes", .path = kubernetes.ready_path };
        @memcpy(commands[1..], scenario.commands);
        scenario.commands = commands;
    }
    if (!exists(context, try path_join(context, &.{ build, "Dockerfile" }))) {
        try kubernetes_context(context, build, directory, files.items, contents.items, images.items, executables.items, owners.items);
    }
    const nodes = try arena.alloc(schema.Node, 1);
    nodes[0] = .{
        .name = kubernetes.node_name,
        .source = .{ .build = .{ .context = build } },
        .command = &kubernetes.command,
        .env = &.{kubernetes.kubeconfig},
        .ready = .{ .tcp = kubernetes.api_port },
        .privileged = true,
        .faults = .{ .pods = true },
    };
    const profiles = try arena.alloc(schema.Profile, 1);
    profiles[0] = .{ .name = "kubernetes", .nodes = nodes };
    return .{ .profiles = profiles, .scenarios = scenarios.items };
}

/// The K3s node's build context (kubernetes_describe), written whole into a staging directory
/// and then moved: a context that is there is complete.
fn kubernetes_context(
    context: Context,
    build: []const u8,
    directory: []const u8,
    files: []const []const u8,
    contents: []const []const u8,
    images: []const []const u8,
    executables: []const []const u8,
    owners: []const []const u8,
) !void {
    const arena = context.arena;
    const cwd = std.Io.Dir.cwd();
    const staging = try own_path(context, build, "partial");
    errdefer cwd.deleteTree(context.io, staging) catch {};
    const tools = try path_join(context, &.{ staging, "determinismo-kubernetes" });
    try cwd.createDirPath(context.io, try path_join(context, &.{ tools, "manifests" }));
    for (files, contents) |path, text| {
        const target = try path_join(context, &.{ tools, "manifests", path[directory.len..] });
        if (std.fs.path.dirname(target)) |parent| try cwd.createDirPath(context.io, parent);
        try cwd.writeFile(context.io, .{ .sub_path = target, .data = text });
    }
    try executable_write(context, try path_join(context, &.{ tools, "ready" }), kubernetes.ready_script);
    try executable_write(context, try path_join(context, &.{ tools, "exec" }), kubernetes.exec_script);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (executables, owners) |raw, image| {
        const path = std.mem.trimStart(u8, raw, "./");
        if (!std.mem.startsWith(u8, path, "opt/antithesis/test/v1/")) continue;
        if ((try seen.getOrPut(arena, path)).found_existing) continue; // The first image's.
        const target = try path_join(context, &.{ staging, "antithesis", path["opt/antithesis/".len..] });
        if (std.fs.path.dirname(target)) |parent| try cwd.createDirPath(context.io, parent);
        try executable_write(context, target, try kubernetes.wrapper(arena, image, try std.fmt.allocPrint(arena, "/{s}", .{path})));
    }
    if (images.len > 0) {
        std.debug.print("[determinismo] saving the manifests' {d} images for K3s\n", .{images.len});
        var argv: std.ArrayList([]const u8) = .empty;
        const archive = try path_join(context, &.{ staging, "images.tar" });
        try argv.appendSlice(arena, &.{ "podman", "save", "--quiet", "--multi-image-archive", "--format", "docker-archive", "--output", archive });
        try argv.appendSlice(arena, images);
        _ = try tool(context, argv.items);
    }
    const text = try kubernetes.dockerfile(arena, images.len > 0, seen.count() > 0);
    try cwd.writeFile(context.io, .{ .sub_path = try path_join(context, &.{ staging, "Dockerfile" }), .data = text });
    cwd.rename(staging, cwd, build, context.io) catch |err| switch (err) {
        error.DirNotEmpty => if (exists(context, try path_join(context, &.{ build, "Dockerfile" }))) {
            cwd.deleteTree(context.io, staging) catch {}; // Another process made it meanwhile.
        } else {
            cwd.deleteTree(context.io, build) catch {}; // Left unfinished, from before.
            try cwd.rename(staging, cwd, build, context.io);
        },
        else => return err,
    };
}

fn executable_write(context: Context, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.writeFile(context.io, .{ .sub_path = path, .data = data });
    const path_z = try context.arena.dupeSentinel(u8, path, 0);
    if (std.os.linux.errno(std.os.linux.fchmodat(std.os.linux.AT.FDCWD, path_z, 0o755)) != .SUCCESS) return error.Chmod;
}

fn string_before(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// An image's ID, pulled first when it is not on the host.
fn image_id(context: Context, reference: []const u8) ![]const u8 {
    if (!try tool_succeeds(context, &.{ "podman", "image", "exists", reference })) {
        std.debug.print("[determinismo] pulling {s}\n", .{reference});
        _ = try tool(context, &.{ "podman", "pull", "--quiet", reference });
    }
    const inspect_json = try tool(context, &.{ "podman", "image", "inspect", reference });
    const inspect = try schema.parse([]const ImageInspect, context.arena, inspect_json);
    if (inspect.len != 1) return error.ImageInspect;
    return inspect[0].Id;
}

/// An image's executables (for test templates), listed once (`<cache>/images/<id>.erofs.tests`,
/// beside the disk image_disk makes of it, when it makes one).
fn image_executables(context: Context, reference: []const u8, id: []const u8) ![]const []const u8 {
    const disk = try path_join(context, &.{ context.cache, "images", try std.fmt.allocPrint(context.arena, "{s}.erofs", .{id}) });
    const tests = try std.fmt.allocPrint(context.arena, "{s}.tests", .{disk});
    if (!exists(context, tests)) {
        const container = std.mem.trim(u8, try tool(context, &.{ "podman", "create", "--quiet", reference }), " \n");
        defer _ = tool(context, &.{ "podman", "rm", "--force", container }) catch {};
        const tar = try std.fmt.allocPrint(context.arena, "{s}.listing.tar", .{disk});
        _ = try tool(context, &.{ "podman", "export", "--output", tar, container });
        defer std.Io.Dir.cwd().deleteFile(context.io, tar) catch {};
        const listing = try tool(context, &.{ "tar", "-tvf", tar });
        try std.Io.Dir.cwd().writeFile(context.io, .{ .sub_path = tests, .data = try executables_of(context.arena, listing) });
    }
    return tests_listing(context, disk);
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
            // Remembered by an older determinismo, in a format of its own: nothing to compare.
            const previous = schema.parse(schema.System, context.arena, previous_json) catch {
                std.debug.print("[determinismo] profile {s}: the last run's, from another " ++
                    "version, is replaced\n", .{system.profile});
                return cwd.writeFile(context.io, .{ .sub_path = path, .data = system_json });
            };
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
    const staging = try own_path(context, try path_join(context, &.{ context.cache, "staging", name }), "binary");
    const cwd = std.Io.Dir.cwd();
    defer cwd.deleteTree(io, staging) catch {};
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
    // By content: by name alone, another build of the binary replaced the disk under runs
    // still to replay from it (and two at once raced on it).
    const disk = try path_join(context, &.{ context.cache, "images", try std.fmt.allocPrint(
        context.arena,
        "binary-{s}-{x:0>16}.erofs",
        .{ name, content_hash },
    ) });
    if (exists(context, disk)) return disk;
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
    const staging = try own_path(context, try path_join(context, &.{ context.cache, "staging", "system" }), "system");
    defer cwd.deleteTree(io, staging) catch {};
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
/// A path of this process's own beside `path` (`<path>.<what>-<pid>`): explores preparing the
/// same system at once (a hunt and a check, six replays of one script) shared the staging names,
/// and one renamed or deleted another's half-made files: 5 of 6 failed (srv3, 2026-10-28), and
/// a disk could have been made of another's partial file. Each makes its own, and renames it in
/// whole (the same content, by the same hash: whichever lands last).
fn own_path(context: Context, path: []const u8, what: []const u8) ![]const u8 {
    return std.fmt.allocPrint(context.arena, "{s}.{s}-{d}", .{ path, what, std.os.linux.getpid() });
}

fn erofs_build(context: Context, disk: []const u8, source: []const []const u8) !void {
    const temporary = try own_path(context, disk, "partial");
    errdefer std.Io.Dir.cwd().deleteFile(context.io, temporary) catch {};
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
