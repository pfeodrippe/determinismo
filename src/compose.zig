// SPDX-License-Identifier: MIT
//! Imports a Compose file as a profile (ARCHITECTURE.md §10: Compose is an importer).
//!
//! Each service becomes a node: `image` or `build` as its source, `entrypoint` and `command`
//! (lists, or strings split like a shell), `environment` (list or map), `working_dir`, `user`,
//! `depends_on` (dependencies start first), `mem_limit`, and the first container port of `ports`
//! or `expose` as its readiness check. Every node gets
//! ANTITHESIS_SDK_LOCAL_OUTPUT=/dev/determinismo, so
//! services and tests using an Antithesis SDK report to determinismo. Fields with no meaning in
//! one deterministic machine (volumes, networks, restart policies, ...) are reported, not
//! silently dropped.
const std = @import("std");
const assert = std.debug.assert;
const schema = @import("determinismo").schema;
const yaml = @import("yaml.zig");

pub const sdk_output_variable = "ANTITHESIS_SDK_LOCAL_OUTPUT=/dev/determinismo";

const ignored_fields = [_][]const u8{
    "volumes",   "networks",       "restart", "deploy", "logging", "container_name", "hostname",
    "env_file",  "cap_add",        "cap_drop", "privileged", "ulimits", "labels", "init",
    "stop_signal", "healthcheck", "platform", "tty", "stdin_open", "security_opt",
};

/// The profile ("default") of the Compose file at `path`. Relative build contexts are taken
/// from the file's directory.
pub fn profile(arena: std.mem.Allocator, io: std.Io, path: []const u8) !schema.Profile {
    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20));
    const root = try yaml.parse(arena, source);
    const services = root.get("services") orelse return error.NoServices;
    if (services != .mapping or services.mapping.len == 0) return error.NoServices;
    if (services.mapping.len > schema.nodes_max) return error.TooManyServices;
    const directory = std.fs.path.dirname(path) orelse ".";
    var nodes: std.ArrayList(schema.Node) = .empty;
    for (services.mapping) |service| {
        try nodes.append(arena, try node_from_service(arena, directory, service));
    }
    return .{ .name = "default", .nodes = try dependency_order(arena, nodes.items) };
}

fn node_from_service(
    arena: std.mem.Allocator,
    directory: []const u8,
    service: yaml.Value.Entry,
) !schema.Node {
    if (!schema.name_valid(service.key)) {
        std.debug.print("[determinismo] compose: service name {s} must be 1-12 lowercase " ++
            "letters, digits or dashes, starting with a letter\n", .{service.key});
        return error.BadServiceName;
    }
    const fields = service.value;
    for (ignored_fields) |field| {
        if (fields.get(field) != null) {
            const note = "[determinismo] compose: {s}.{s} is ignored\n";
            std.debug.print(note, .{ service.key, field });
        }
    }
    var node = schema.Node{ .name = service.key, .source = .{} };
    if (fields.get("image")) |image| node.source.image = try scalar(image);
    if (fields.get("build")) |build| {
        node.source = .{ .build = try build_source(arena, directory, build) };
    }
    if (node.source.kind_count() != 1) return error.ServiceNeedsImageOrBuild;
    if (fields.get("entrypoint")) |value| node.entrypoint = try words(arena, value);
    if (fields.get("command")) |value| node.command = try words(arena, value);
    if (fields.get("working_dir")) |value| node.workdir = try scalar(value);
    if (fields.get("user")) |value| node.user = try scalar(value);
    node.env = try environment(arena, fields.get("environment"));
    node.after = try dependencies(arena, fields.get("depends_on"));
    if (try first_port(fields)) |port| node.ready = .{ .tcp = port };
    if (fields.get("mem_limit")) |value| node.memory_max_mib = try memory_mib(try scalar(value));
    return node;
}

/// A Compose byte value ("64m", "1g", "512mb", "1048576") in MiB, rounded up.
fn memory_mib(text: []const u8) !u32 {
    const digits = for (text, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte)) break index;
    } else text.len;
    const number = try std.fmt.parseInt(u64, text[0..digits], 10);
    const suffix = text[digits..];
    const shifts = [_]struct { []const u8, u6 }{
        .{ "", 0 },   .{ "b", 0 },   .{ "k", 10 }, .{ "kb", 10 },
        .{ "m", 20 }, .{ "mb", 20 }, .{ "g", 30 }, .{ "gb", 30 },
    };
    for (shifts) |entry| {
        if (!std.ascii.eqlIgnoreCase(suffix, entry[0])) continue;
        const bytes = std.math.shlExact(u64, number, entry[1]) catch return error.BadMemLimit;
        const mib = std.math.divCeil(u64, bytes, 1 << 20) catch unreachable;
        return std.math.cast(u32, mib) orelse error.BadMemLimit;
    }
    return error.BadMemLimit;
}

fn build_source(arena: std.mem.Allocator, directory: []const u8, value: yaml.Value) !schema.Build {
    const context, const dockerfile = switch (value) {
        .scalar => |text| .{ text, "Dockerfile" },
        .mapping => .{
            try scalar(value.get("context") orelse return error.BuildWithoutContext),
            if (value.get("dockerfile")) |file| try scalar(file) else "Dockerfile",
        },
        else => return error.BadBuild,
    };
    const absolute = std.fs.path.isAbsolute(context);
    return .{
        .context = if (absolute) context else try std.fs.path.join(arena, &.{ directory, context }),
        .dockerfile = dockerfile,
    };
}

fn environment(arena: std.mem.Allocator, value: ?yaml.Value) ![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    try entries.append(arena, sdk_output_variable);
    const present = value orelse return entries.items;
    switch (present) {
        .sequence => |items| for (items) |item| try entries.append(arena, try scalar(item)),
        .mapping => |fields| for (fields) |field| {
            const text = if (field.value == .empty) "" else try scalar(field.value);
            const entry = try std.fmt.allocPrint(arena, "{s}={s}", .{ field.key, text });
            try entries.append(arena, entry);
        },
        .empty => {},
        .scalar => return error.BadEnvironment,
    }
    return entries.items;
}

fn dependencies(arena: std.mem.Allocator, value: ?yaml.Value) ![]const []const u8 {
    const present = value orelse return &.{};
    var names: std.ArrayList([]const u8) = .empty;
    switch (present) {
        .sequence => |items| for (items) |item| try names.append(arena, try scalar(item)),
        .mapping => |fields| for (fields) |field| try names.append(arena, field.key),
        else => return error.BadDependsOn,
    }
    return names.items;
}

/// The container side of the first `ports` entry ("8080:80", "80", {target: 80}) or `expose`.
fn first_port(fields: yaml.Value) !?u16 {
    for ([_][]const u8{ "ports", "expose" }) |key| {
        const list = fields.get(key) orelse continue;
        if (list != .sequence or list.sequence.len == 0) continue;
        const entry = list.sequence[0];
        const text = switch (entry) {
            .scalar => |port| port,
            .mapping => try scalar(entry.get("target") orelse return error.BadPort),
            else => return error.BadPort,
        };
        const colon = std.mem.lastIndexOfScalar(u8, text, ':');
        const container = text[if (colon) |index| index + 1 else 0..];
        const protocol = std.mem.indexOfScalar(u8, container, '/') orelse container.len;
        const number = container[0..protocol];
        return try std.fmt.parseInt(u16, number, 10);
    }
    return null;
}

/// Dependencies first; the schema wants `after` to name earlier nodes only.
fn dependency_order(arena: std.mem.Allocator, nodes: []const schema.Node) ![]const schema.Node {
    const ordered = try arena.alloc(schema.Node, nodes.len);
    var placed = try arena.alloc(bool, nodes.len);
    @memset(placed, false);
    var count: usize = 0;
    while (count < nodes.len) {
        const before = count;
        for (nodes, 0..) |node, index| {
            if (placed[index]) continue;
            const ready = for (node.after) |dependency| {
                const known = for (ordered[0..count]) |done| {
                    if (std.mem.eql(u8, done.name, dependency)) break true;
                } else false;
                if (!known) break false;
            } else true;
            if (!ready) continue;
            ordered[count] = node;
            placed[index] = true;
            count += 1;
        }
        if (count == before) return error.DependencyCycleOrUnknownService;
    }
    return ordered;
}

fn scalar(value: yaml.Value) ![]const u8 {
    return switch (value) {
        .scalar => |text| text,
        else => error.ExpectedScalar,
    };
}

/// A list as is, or a string split like a shell does (quotes group, backslash escapes).
fn words(arena: std.mem.Allocator, value: yaml.Value) ![]const []const u8 {
    switch (value) {
        .sequence => |items| {
            const list = try arena.alloc([]const u8, items.len);
            for (items, list) |item, *word| word.* = try scalar(item);
            return list;
        },
        .scalar => |text| return split_shell(arena, text),
        else => return error.BadCommand,
    }
}

fn split_shell(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var quote: ?u8 = null;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (quote) |open| {
            if (byte == open) {
                quote = null;
            } else if (byte == '\\' and open == '"' and index + 1 < text.len) {
                index += 1;
                try word.append(arena, text[index]);
            } else try word.append(arena, byte);
            continue;
        }
        switch (byte) {
            ' ', '\t', '\n' => if (in_word) {
                try list.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
            },
            '"', '\'' => {
                quote = byte;
                in_word = true;
            },
            '\\' => if (index + 1 < text.len) {
                index += 1;
                try word.append(arena, text[index]);
                in_word = true;
            },
            else => {
                try word.append(arena, byte);
                in_word = true;
            },
        }
    }
    if (quote != null) return error.UnterminatedQuote;
    if (in_word) try list.append(arena, try word.toOwnedSlice(arena));
    return list.items;
}

/// Scenarios from Antithesis test templates found in a node's image: every executable under
/// /opt/antithesis/test/v1/<template>/ whose name starts with a test-command prefix.
pub fn templates(
    arena: std.mem.Allocator,
    node: []const u8,
    executables: []const []const u8,
    scenarios: *std.ArrayList(schema.Scenario),
) !void {
    const root = "opt/antithesis/test/v1/";
    var found: std.StringArrayHashMapUnmanaged(std.ArrayList(schema.Command)) = .empty;
    for (executables) |raw| {
        const path = std.mem.trimStart(u8, raw, "./");
        if (!std.mem.startsWith(u8, path, root)) continue;
        const rest = path[root.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const template = rest[0..slash];
        const name = rest[slash + 1 ..];
        if (std.mem.indexOfScalar(u8, name, '/') != null) continue; // Not directly in it.
        const kind = command_kind(name) orelse continue;
        const entry = try found.getOrPut(arena, template);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, .{
            .kind = kind,
            .name = name,
            .path = try std.fmt.allocPrint(arena, "/{s}", .{path}),
        });
    }
    for (found.keys(), found.values()) |template, commands| {
        const scenario = schema.Scenario{
            .name = template,
            .commands = commands.items,
            .node = node,
        };
        try scenarios.append(arena, scenario);
    }
}

fn command_kind(name: []const u8) ?schema.Kind {
    const prefixes = [_]struct { []const u8, schema.Kind }{
        .{ "first_", .first },
        .{ "parallel_driver_", .parallel_driver },
        .{ "serial_driver_", .serial_driver },
        .{ "singleton_driver_", .singleton_driver },
        .{ "anytime_", .anytime },
        .{ "eventually_", .eventually },
        .{ "finally_", .finally },
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix[0])) return prefix[1];
    }
    return null;
}

test memory_mib {
    try std.testing.expectEqual(@as(u32, 64), try memory_mib("64m"));
    try std.testing.expectEqual(@as(u32, 1024), try memory_mib("1G"));
    try std.testing.expectEqual(@as(u32, 512), try memory_mib("512mb"));
    try std.testing.expectEqual(@as(u32, 1), try memory_mib("1000"));
    try std.testing.expectError(error.BadMemLimit, memory_mib("5x"));
}

test split_shell {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const parts = try split_shell(arena_state.allocator(), "redis-server --save \"\" 'a b' c\\ d");
    try std.testing.expectEqual(@as(usize, 5), parts.len);
    try std.testing.expectEqualStrings("", parts[2]);
    try std.testing.expectEqualStrings("a b", parts[3]);
    try std.testing.expectEqualStrings("c d", parts[4]);
}

test templates {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var scenarios: std.ArrayList(schema.Scenario) = .empty;
    const executables = [_][]const u8{
        "./opt/antithesis/test/v1/bank/parallel_driver_transfer.sh",
        "opt/antithesis/test/v1/bank/finally_check",
        "opt/antithesis/test/v1/bank/helper_lib.sh",
        "usr/bin/redis-server",
    };
    try templates(arena_state.allocator(), "client", &executables, &scenarios);
    try std.testing.expectEqual(@as(usize, 1), scenarios.items.len);
    const bank = scenarios.items[0];
    try std.testing.expectEqualStrings("bank", bank.name);
    try std.testing.expectEqual(@as(usize, 2), bank.commands.len);
    const path = bank.commands[1].path.?;
    try std.testing.expectEqualStrings("/opt/antithesis/test/v1/bank/finally_check", path);
}
