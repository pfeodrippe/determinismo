// SPDX-License-Identifier: MIT
//! `determinismo extract`: a file of a node at a moment, as Antithesis's extract_file.
//!
//!   determinismo extract <machine and system options> --seed <s> --branch <n>
//!       (--at-vtime-ms <ms> | --until '<condition>') --file <node>:<path> --to <local file>
//!
//! The branch replays to the moment; there the runner reads the file through the node's mount
//! namespace (/proc/<node>/root, which sees what the node itself sees: its overlay, its tmpfs
//! mounts) and prints it in base64, which this command decodes. Only the exact bytes the
//! timeline had at that moment.
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

/// The file's bytes at the moment `explore_arguments` reach (they include the branch and the
/// moment). `file` is `<node>:<absolute path>`.
pub fn read(
    arena: std.mem.Allocator,
    io: std.Io,
    self: []const u8,
    explore_arguments: []const []const u8,
    file: []const u8,
) ![]const u8 {
    const colon = std.mem.indexOfScalar(u8, file, ':') orelse return error.BadFile;
    const node = file[0..colon];
    const path = file[colon + 1 ..];
    if (node.len == 0 or path.len == 0 or path[0] != '/') return error.BadFile;
    for (node) |byte| {
        const valid = std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-';
        if (!valid) return error.BadNode;
    }
    for (path) |byte| if (byte == '\'' or byte == '\n') return error.BadPath;
    const format = "base64 -w 0 '/proc/'$(cat /run/det/nodes/{s}/pid)'/root{s}' && echo";
    const command = try std.fmt.allocPrint(arena, format, .{ node, path });
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self, "explore" });
    try argv.appendSlice(arena, explore_arguments);
    try argv.appendSlice(arena, &.{ "--exec", command });
    const result = try std.process.run(arena, io, .{ .argv = argv.items });
    if (std.mem.indexOf(u8, result.stderr, "{\"event\":\"exec_done\"") == null) {
        const message = "[determinismo] extract: the command did not finish:\n{s}\n";
        std.debug.print(message, .{lines_determinismo(arena, result.stderr) catch ""});
        return error.CommandUnfinished;
    }
    const encoded = try exec_output(arena, result.stderr);
    const text = std.mem.trim(u8, encoded, " \n");
    if (text.len == 0) return error.NoSuchFile;
    const decoder = std.base64.standard.Decoder;
    const bytes = try arena.alloc(u8, try decoder.calcSizeForSlice(text));
    try decoder.decode(bytes, text);
    return bytes;
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
