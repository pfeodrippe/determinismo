// SPDX-License-Identifier: MIT
//! det-nodes: the node runtime's command line (see nodes.zig).
//!
//!   det-nodes up                      start every node of /det/system.json, in order
//!   det-nodes start|kill <node>       start a node, or kill all its processes
//!   det-nodes crash|wipe <node>       a power loss (its disk keeps what was synced), or a start
//!                                     fresh from its image; then it starts again
//!   det-nodes pause|resume <node>     freeze or thaw all its processes
//!   det-nodes link <a> <b> up|down    the link between two nodes (or a node and "runner")
//!   det-nodes exec <node> <command>...   run a command inside a node; exits with its status
//!   det-nodes list                    the nodes now: name, state, pid, address, image (JSON lines)
//!   det-nodes writeback               sync the disks of nodes with a writeback window, each
//!                                     that often, for good (init runs it)
//!   det-nodes samples                 each node's CPU and memory every 2 s, as events, for good
//!                                     (init runs it)
const std = @import("std");
const assert = std.debug.assert;
const nodes = @import("nodes.zig");
const schema = @import("determinismo").schema;

const usage =
    \\usage: det-nodes up
    \\       det-nodes start|kill|crash|wipe|pause|resume <node>
    \\       det-nodes link <a> <b> up|down
    \\       det-nodes exec <node> <command>...
    \\       det-nodes list
    \\       det-nodes writeback
    \\       det-nodes samples
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    if (arguments.len < 2) return usage_exit();
    const command = arguments[1];
    const eql = std.mem.eql;
    const system = try nodes.system_load(arena);
    if (eql(u8, command, "link")) {
        if (arguments.len != 5) return usage_exit();
        const up = eql(u8, arguments[4], "up");
        if (!up and !eql(u8, arguments[4], "down")) return usage_exit();
        return nodes.link_set(&system, arguments[2], arguments[3], if (up) .up else .down);
    }
    if (eql(u8, command, "up")) return nodes.up(arena, &system);
    if (eql(u8, command, "list")) return list(arena, &system);
    if (eql(u8, command, "writeback")) nodes.writeback_loop(&system);
    if (eql(u8, command, "samples")) nodes.samples_loop(&system);
    if (eql(u8, command, "exec")) {
        if (arguments.len < 4) return usage_exit();
        const node = system.node(arguments[2]) orelse return error.UnknownNode;
        const argv = try arena.alloc([]const u8, arguments.len - 3);
        for (arguments[3..], argv) |argument, *target| target.* = argument;
        std.process.exit(try nodes.exec(arena, node, argv));
    }
    if (arguments.len != 3) return usage_exit();
    const name = arguments[2];
    if (eql(u8, command, "start")) {
        const node = system.node(name) orelse return error.UnknownNode;
        return nodes.start(arena, &system, node);
    }
    if (eql(u8, command, "kill")) return nodes.kill(name);
    if (eql(u8, command, "crash") or eql(u8, command, "wipe")) {
        const node = system.node(name) orelse return error.UnknownNode;
        try if (eql(u8, command, "crash")) nodes.crash(name) else nodes.wipe(name);
        return nodes.start(arena, &system, node);
    }
    if (eql(u8, command, "pause")) return nodes.freeze(name, .frozen);
    if (eql(u8, command, "resume")) return nodes.freeze(name, .thawed);
    return usage_exit();
}

/// Antithesis's containers.list, at the moment it runs.
fn list(arena: std.mem.Allocator, system: *const schema.System) !void {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (system.nodes) |node| {
        const pid = nodes.pid_recorded(node.name);
        try std.json.Stringify.value(.{
            .name = node.name,
            .state = @tagName(nodes.state_of(node.name)),
            .pid = pid,
            .address = node.address,
            .image = node.digest,
        }, .{}, &out.writer);
        try out.writer.writeByte('\n');
    }
    const text = out.written();
    var written: usize = 0;
    while (written < text.len) {
        const result = std.os.linux.write(1, text[written..].ptr, text.len - written);
        if (std.os.linux.errno(result) != .SUCCESS) return error.Write;
        written += result;
    }
}

fn usage_exit() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}
