// SPDX-License-Identifier: MIT
//! Where every input to the guest comes from (ARCHITECTURE.md §7). The default answer to a pull is
//! a pure function of (seed, pull index), so a timeline is fully described by its seed plus the
//! answers that were overridden.
const std = @import("std");
const assert = std.debug.assert;

pub const random_size_max = 4096 - 16;

seed: u64,
pulls: u64 = 0,

const Decisions = @This();

pub fn random(decisions: *Decisions, target: []u8) void {
    assert(target.len > 0);
    assert(target.len <= random_size_max);
    const key = [2]u64{ decisions.seed, decisions.pulls };
    var prng: std.Random.DefaultPrng = .init(std.hash.Wyhash.hash(0, std.mem.asBytes(&key)));
    prng.random().bytes(target);
    decisions.pulls += 1;
    assert(decisions.pulls > 0);
}

test "pulls are a function of seed and index only" {
    var a = Decisions{ .seed = 7 };
    var b = Decisions{ .seed = 7 };
    var bytes_a: [16]u8 = undefined;
    var bytes_b: [16]u8 = undefined;
    a.random(&bytes_a);
    b.random(&bytes_b);
    try std.testing.expectEqualSlices(u8, &bytes_a, &bytes_b);
    a.random(&bytes_a);
    try std.testing.expect(!std.mem.eql(u8, &bytes_a, &bytes_b));
}
