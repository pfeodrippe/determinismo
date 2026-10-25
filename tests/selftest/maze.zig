// SPDX-License-Identifier: MIT
//! det-maze-zig: maze.c in Zig, for the Zig SDK's code coverage (profile "maze-zig" of the
//! self-test). `det-maze-zig idle` keeps the node alive; `det-maze-zig solve` is one attempt:
//! four digits from platform randomness, each checked before the next is drawn.
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

comptime {
    _ = sdk.coverage;
}

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2 or !std.mem.eql(u8, arguments[1], "solve")) {
        while (true) _ = linux.pause(); // The node: an attempt is a command run inside it.
    }
    var solved = false;
    if (digit() == 7) {
        sdk.reachable("maze: first digit", .{});
        if (digit() == 3) {
            sdk.reachable("maze: second digit", .{});
            if (digit() == 9) {
                sdk.reachable("maze: third digit", .{});
                if (digit() == 1) solved = true;
            }
        }
    }
    sdk.always(!solved, "the maze is never solved", .{});
}

fn digit() u64 {
    return sdk.random_below(10);
}
