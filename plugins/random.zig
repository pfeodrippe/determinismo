// SPDX-License-Identifier: MIT
//! The baseline strategy: never overrides anything, so every branch follows its own seed. Useful
//! as a reference and to measure what smarter strategies add.
const std = @import("std");
const protocol = @import("protocol.zig");

const Random = struct {
    pub const name = "random";
};

pub fn main() !void {
    var strategy = Random{};
    try protocol.serve(Random, &strategy);
}
