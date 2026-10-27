// SPDX-License-Identifier: MIT
//! `determinismo extract` and `determinismo inject`: a file of a node at a moment, out of the
//! timeline or into it, as Antithesis's extract_file and inject_file.
//!
//!   determinismo extract <machine and system options> --seed <s> --branch <n>
//!       (--at-vtime-ms <ms> | --until '<condition>') --file <node>:<path> --to <local file>
//!
//! The branch replays to the moment; there the runner reads the file through the node's mount
//! namespace (/proc/<node>/root, which sees what the node itself sees: its overlay, its tmpfs
//! mounts) and prints it in base64, which this command decodes. Only the exact bytes the
//! timeline had at that moment.
//!
//!   determinismo inject <machine and system options> --seed <s> --branch <n>
//!       (--at-vtime-ms <ms> | --until '<condition>') --file <node>:<path> --from <local file>
//!       [--mode <octal>] [--then '<command>'] [--continue]
//!
//! The file goes in at the moment as a series of commands (a moment command is at most a
//! page): base64 chunks appended to a staging file in the runner, then decoded into the node's
//! root. `--then` runs a command after it (the new binary, a reload); `--continue` lets the
//! timeline run on, a new future from that moment.
const std = @import("std");
const assert = std.debug.assert;

pub fn run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    arguments: []const [:0]const u8,
) !u8 {
    var file: ?[]const u8 = null;
    var to: ?[]const u8 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const ours = std.mem.eql(u8, flag, "--file") or std.mem.eql(u8, flag, "--to");
        if (!ours) {
            try rest.append(arena, flag);
            continue;
        }
        index += 1;
        if (index == arguments.len) return error.Usage;
        if (std.mem.eql(u8, flag, "--file")) file = arguments[index] else to = arguments[index];
    }
    const bytes = try read(arena, io, self, rest.items, file orelse return error.Usage);
    const target = to orelse return error.Usage;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = target, .data = bytes });
    std.debug.print("[determinismo] extracted {d} bytes\n", .{bytes.len});
    return 0;
}

/// Base64 characters per command: with the command around them, under the agent's limit.
const inject_chunk_size = 4000;
const inject_staging = "/run/det/inject.b64";

pub fn inject_run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    arguments: []const [:0]const u8,
) !u8 {
    var file: ?[]const u8 = null;
    var from: ?[]const u8 = null;
    var mode: []const u8 = "644";
    var then: ?[]const u8 = null;
    var rest: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        const slot: ?*?[]const u8 = if (std.mem.eql(u8, flag, "--file"))
            &file
        else if (std.mem.eql(u8, flag, "--from"))
            &from
        else if (std.mem.eql(u8, flag, "--then"))
            &then
        else
            null;
        const is_mode = std.mem.eql(u8, flag, "--mode");
        if (slot == null and !is_mode) {
            try rest.append(arena, flag);
            continue;
        }
        index += 1;
        if (index == arguments.len) return error.Usage;
        if (slot) |target| target.* = arguments[index] else mode = arguments[index];
    }
    for (mode) |digit| if (digit < '0' or digit > '7') return error.Usage;
    if (mode.len == 0 or mode.len > 4) return error.Usage;
    const target = try target_parse(file orelse return error.Usage);
    const source = from orelse return error.Usage;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, arena, .unlimited);
    const script = try inject_script(arena, bytes, target, mode, then);
    var path_buffer: [64]u8 = undefined;
    const script_path = try std.fmt.bufPrint(&path_buffer, "/tmp/determinismo-inject-{d}", .{
        std.os.linux.getpid(),
    });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script_path, .data = script });
    defer std.Io.Dir.cwd().deleteFile(io, script_path) catch {};
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, rest.items);
    try argv.appendSlice(arena, &.{ "--exec-script", script_path });
    const result = try std.process.run(arena, io, .{ .argv = argv.items });
    const output = try exec_output(arena, result.stderr);
    std.debug.print("{s}", .{lines_determinismo(arena, result.stderr) catch ""});
    const marker = "[injected]\n";
    const at = std.mem.indexOf(u8, output, marker) orelse {
        std.debug.print("[determinismo] inject: the file did not go in\n{s}", .{output});
        return 1;
    };
    std.debug.print("[determinismo] injected {d} bytes\n{s}", .{
        bytes.len, output[at + marker.len ..],
    });
    return 0;
}

const Target = struct { node: []const u8, path: []const u8 };

/// `<node>:<absolute path>`, with nothing a single-quoted shell word cannot hold.
fn target_parse(file: []const u8) !Target {
    const colon = std.mem.indexOfScalar(u8, file, ':') orelse return error.BadFile;
    const target = Target{ .node = file[0..colon], .path = file[colon + 1 ..] };
    if (target.node.len == 0 or target.path.len == 0 or target.path[0] != '/') {
        return error.BadFile;
    }
    for (target.node) |byte| {
        const valid = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-';
        if (!valid) return error.BadNode;
    }
    for (target.path) |byte| if (byte == '\'' or byte == '\n' or byte == 0) return error.BadPath;
    return target;
}

/// The target as the runner's shell names it: through the node's root (what the node sees), or
/// the runner's own file for "runner" (core dumps are in /run/det/cores).
fn target_shell(arena: std.mem.Allocator, target: Target) ![]const u8 {
    if (std.mem.eql(u8, target.node, "runner")) {
        return std.fmt.allocPrint(arena, "'{s}'", .{target.path});
    }
    const format = "'/proc/'$(cat /run/det/nodes/{s}/pid)'/root{s}'";
    return std.fmt.allocPrint(arena, format, .{ target.node, target.path });
}

/// The moment's commands, one per line: staging, the chunks, the decode, then `then`.
fn inject_script(
    arena: std.mem.Allocator,
    bytes: []const u8,
    target: Target,
    mode: []const u8,
    then: ?[]const u8,
) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded = try arena.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(encoded, bytes);
    var script: std.ArrayList(u8) = .empty;
    try script.print(arena, ": > {s}\n", .{inject_staging});
    var offset: usize = 0;
    while (offset < encoded.len) : (offset += inject_chunk_size) {
        const chunk = encoded[offset..@min(encoded.len, offset + inject_chunk_size)];
        try script.print(arena, "printf %s '{s}' >> {s}\n", .{ chunk, inject_staging });
    }
    const path = try target_shell(arena, target);
    const decode = "base64 -d {s} > {s} && chmod {s} {s} && rm {s} && echo '[injected]'\n";
    try script.print(arena, decode, .{
        inject_staging, path, mode, path, inject_staging,
    });
    if (then) |command| {
        if (std.mem.indexOfAny(u8, command, "\n\x00") != null) return error.BadCommand;
        try script.print(arena, "{s}\n", .{command});
    }
    return script.items;
}

/// The file's bytes at the moment `explore_arguments` reach (they include the branch and the
/// moment). `file` is `<node>:<absolute path>`.
pub fn read(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    explore_arguments: []const []const u8,
    file: []const u8,
) ![]const u8 {
    const target = try target_parse(file);
    const path = try target_shell(arena, target);
    const command = try std.fmt.allocPrint(arena, "base64 -w 0 {s} && echo", .{path});
    const encoded = try exec_run(arena, io, self, explore_arguments, command);
    const text = std.mem.trim(u8, encoded, " \n");
    if (text.len == 0) return error.NoSuchFile;
    const decoder = std.base64.standard.Decoder;
    // Not base64: what the guest said instead (a missing file, a node that is gone: a node's
    // files are read through its process, the guest's own as runner:<path>).
    const size = decoder.calcSizeForSlice(text) catch return not_extracted(text);
    const bytes = try arena.alloc(u8, size);
    decoder.decode(bytes, text) catch return not_extracted(text);
    return bytes;
}

fn not_extracted(text: []const u8) error{NotExtracted} {
    std.debug.print("[determinismo] extract: the guest answered: {s}\n", .{text[0..@min(text.len, 400)]});
    return error.NotExtracted;
}

/// What `command` prints when run at the moment `explore_arguments` reach.
pub fn exec_run(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    explore_arguments: []const []const u8,
    command: []const u8,
) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, explore_arguments);
    try argv.appendSlice(arena, &.{ "--exec", command });
    const result = try std.process.run(arena, io, .{ .argv = argv.items });
    if (std.mem.indexOf(u8, result.stderr, "{\"event\":\"exec_done\"") == null) {
        const message = "[determinismo] the command did not finish:\n{s}\n";
        std.debug.print(message, .{lines_determinismo(arena, result.stderr) catch ""});
        return error.CommandUnfinished;
    }
    return exec_output(arena, result.stderr);
}

/// determinismo's own lines of an output (why a run ended where it did).
fn lines_determinismo(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
    var kept: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const ours = std.mem.startsWith(u8, line, "[determinismo]") or
            std.mem.startsWith(u8, line, "error");
        if (!ours) continue;
        try kept.appendSlice(arena, line);
        try kept.append(arena, '\n');
    }
    return kept.items;
}

/// What the command at the moment printed: the `exec_output` events' text, in order.
fn exec_output(arena: std.mem.Allocator, output: []const u8) ![]const u8 {
    const Output = struct { event: []const u8, details: struct { text: []const u8 = "" } };
    var collected: std.ArrayList(u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const at = std.mem.indexOf(u8, line, "{\"event\":\"exec_output\"") orelse continue;
        const event = std.json.parseFromSliceLeaky(Output, arena, line[at..], .{
            .ignore_unknown_fields = true,
        }) catch continue;
        try collected.appendSlice(arena, event.details.text);
    }
    return collected.items;
}

test inject_script {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try arena.alloc(u8, 7000); // Two chunks of base64.
    @memset(bytes, 'x');
    const target = try target_parse("redis:/etc/new.conf");
    const script = try inject_script(arena, bytes, target, "600", "cat /etc/hostname");
    var lines = std.mem.tokenizeScalar(u8, script, '\n');
    var count: u32 = 0;
    var decoded: std.ArrayList(u8) = .empty;
    while (lines.next()) |line| : (count += 1) {
        try std.testing.expect(line.len < 4080); // Each a moment command.
        if (!std.mem.startsWith(u8, line, "printf %s '")) continue;
        const end = std.mem.indexOfScalarPos(u8, line, 11, '\'').?;
        try decoded.appendSlice(arena, line[11..end]);
    }
    try std.testing.expectEqual(@as(u32, 1 + 3 + 1 + 1), count); // Staging, chunks, decode, then.
    const decoder = std.base64.standard.Decoder;
    const back = try arena.alloc(u8, try decoder.calcSizeForSlice(decoded.items));
    try decoder.decode(back, decoded.items);
    try std.testing.expectEqualSlices(u8, bytes, back);
    try std.testing.expectError(error.BadPath, target_parse("redis:/etc/it's"));
    try std.testing.expectError(error.BadNode, target_parse("Redis:/etc/x"));
}
