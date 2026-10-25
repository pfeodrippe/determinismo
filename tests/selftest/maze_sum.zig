// SPDX-License-Identifier: MIT
//! det-maze-sum: a maze no code coverage can see into, for guidance (profile "maze-sum" of the
//! self-test). `det-maze-sum idle` keeps the node alive; `det-maze-sum solve` is one attempt:
//! four digits from platform randomness must add up to at least 35 (5 timelines in 10000 by
//! chance). One comparison, one branch: coverage says nothing until it is solved, while the
//! guidance assertion says how far each attempt fell short, so a strategy can climb.
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

pub const target = 35;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len < 2 or !std.mem.eql(u8, arguments[1], "solve")) {
        while (true) _ = linux.pause(); // The node: an attempt is a command run inside it.
    }
    var sum: u64 = 0;
    for (0..4) |_| sum += sdk.random_below(10);
    sdk.sometimes_greater_than_or_equal(sum, target, "maze sum: the digits add up", .{});
}
