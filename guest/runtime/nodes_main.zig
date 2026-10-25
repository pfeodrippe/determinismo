// SPDX-License-Identifier: MIT
//! det-nodes: the node runtime's command line (see nodes.zig).
//!
//!   det-nodes up                      start every node of /det/system.json, in order
//!   det-nodes start|kill <node>       start a node, or kill all its processes
//!   det-nodes pause|resume <node>     freeze or thaw all its processes
//!   det-nodes link <a> <b> up|down    the link between two nodes (or a node and "runner")
//!   det-nodes exec <node> <command>...   run a command inside a node; exits with its status
const std = @import("std");
const assert = std.debug.assert;
const nodes = @import("nodes.zig");

const usage =
    \\usage: det-nodes up
    \\       det-nodes start|kill|pause|resume <node>
    \\       det-nodes link <a> <b> up|down
    \\       det-nodes exec <node> <command>...
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
    if (eql(u8, command, "pause")) return nodes.freeze(name, .frozen);
    if (eql(u8, command, "resume")) return nodes.freeze(name, .thawed);
    return usage_exit();
}

fn usage_exit() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}
