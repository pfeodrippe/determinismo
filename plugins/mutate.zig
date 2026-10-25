// SPDX-License-Identifier: MIT
//! A greybox mutation strategy over decision tapes.
//!
//! Each branch either starts fresh (its own seed) or derives from a parent in the corpus: it
//! replays the parent's decisions exactly, except at a few mutated pulls (random or boundary
//! values). After a mutated pull the timeline diverges, but it keeps the parent's prefix, so the
//! exploration concentrates around timelines that were interesting. A branch is interesting, and
//! joins the corpus, when its signature is new: outcome, failing properties and event volume.
//!
//! Usage: mutate [--fresh-percent <n>]   (default 25)
const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("protocol.zig");

const corpus_max = 64;
const pulls_max = 16 * 1024;
const signatures_max = 4096;
const mutations_max = 4;

const Tape = struct {
    values: [pulls_max]u64 = undefined,
    count: u32 = 0,
};

const Mutate = struct {
    prng: std.Random.DefaultPrng = .init(0),
    fresh_percent: u32 = 25,
    corpus: [corpus_max]Tape = undefined,
    corpus_count: u32 = 0,
    signatures: [signatures_max]u64 = undefined,
    signature_count: u32 = 0,
    /// The branch running now: its decisions so far, and how it was derived.
    current: Tape = .{},
    first_pull: ?u64 = null,
    parent: ?u32 = null,
    mutated_positions: [mutations_max]u32 = undefined,
    mutated_values: [mutations_max]u64 = undefined,
    mutation_count: u32 = 0,

    pub const name = "mutate";

    pub fn hello(strategy: *Mutate, exploration_seed: u64) void {
        strategy.prng = .init(exploration_seed ^ 0x6d7574617465);
    }

    pub fn branch(strategy: *Mutate, index: u32, seed: u64) void {
        _ = index;
        _ = seed;
        strategy.current.count = 0;
        strategy.parent = null;
        strategy.mutation_count = 0;
        const prng = strategy.prng.random();
        if (strategy.corpus_count == 0) return;
        if (prng.uintLessThan(u32, 100) < strategy.fresh_percent) return;
        const parent = prng.uintLessThan(u32, strategy.corpus_count);
        const parent_count = strategy.corpus[parent].count;
        if (parent_count == 0) return;
        strategy.parent = parent;
        strategy.mutation_count = 1 + prng.uintLessThan(u32, mutations_max);
        for (0..strategy.mutation_count) |index_mutation| {
            strategy.mutated_positions[index_mutation] = prng.uintLessThan(u32, parent_count);
            strategy.mutated_values[index_mutation] = switch (prng.uintLessThan(u32, 4)) {
                0 => 0, // Boundary values make choices take their extremes.
                1 => std.math.maxInt(u64),
                else => prng.int(u64),
            };
        }
        assert(strategy.mutation_count <= mutations_max);
    }

    pub fn random(strategy: *Mutate, request: protocol.Random) ?[]const u8 {
        const first = strategy.first_pull orelse first: {
            strategy.first_pull = request.pull; // Every branch starts from the same snapshot.
            break :first request.pull;
        };
        assert(request.pull >= first);
        const position: u32 = @intCast(request.pull - first);
        if (request.default.len != 8 or position >= pulls_max) return null;
        const default = std.mem.readInt(u64, request.default[0..8], .little);
        const value = strategy.choose(position) orelse default;
        if (position == strategy.current.count) {
            strategy.current.values[position] = value;
            strategy.current.count += 1;
        }
        if (strategy.parent == null) return null;
        std.mem.writeInt(u64, &answer, value, .little);
        return &answer;
    }

    /// The parent's value at `position`, unless that position is mutated; null without a parent.
    fn choose(strategy: *const Mutate, position: u32) ?u64 {
        const parent = strategy.parent orelse return null;
        for (strategy.mutated_positions[0..strategy.mutation_count], 0..) |mutated, index| {
            if (mutated == position) return strategy.mutated_values[index];
        }
        const tape = &strategy.corpus[parent];
        if (position < tape.count) return tape.values[position];
        return null; // Past the parent's end: the branch's own default.
    }

    pub fn branch_end(strategy: *Mutate, end: protocol.BranchEnd) bool {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(end.outcome);
        for (end.failing) |property| hasher.update(property);
        hasher.update(std.mem.asBytes(&@as(u64, std.math.log2_int_ceil(u64, end.events + 1))));
        const signature = hasher.final();
        const novel = for (strategy.signatures[0..strategy.signature_count]) |seen| {
            if (seen == signature) break false;
        } else true;
        if (novel) strategy.remember(signature);
        const format = "[mutate] branch {d}: parent={?d} mutations={d} failing={d} novel={} " ++
            "corpus={d}\n";
        std.debug.print(format, .{
            end.index,             strategy.parent, strategy.mutation_count, end.failing.len, novel,
            strategy.corpus_count,
        });
        return false;
    }

    fn remember(strategy: *Mutate, signature: u64) void {
        if (strategy.signature_count < signatures_max) {
            strategy.signatures[strategy.signature_count] = signature;
            strategy.signature_count += 1;
        }
        const slot = if (strategy.corpus_count < corpus_max) slot: {
            strategy.corpus_count += 1;
            break :slot strategy.corpus_count - 1;
        } else strategy.prng.random().uintLessThan(u32, corpus_max); // Full: replace one.
        strategy.corpus[slot] = strategy.current;
        assert(strategy.corpus_count <= corpus_max);
    }
};

var answer: [8]u8 = undefined;

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const strategy = try init.arena.allocator().create(Mutate); // Large: never on the stack.
    strategy.* = .{};
    if (arguments.len == 3 and std.mem.eql(u8, arguments[1], "--fresh-percent")) {
        strategy.fresh_percent = try std.fmt.parseInt(u32, arguments[2], 10);
    }
    if (strategy.fresh_percent > 100) return error.BadFreshPercent;
    try protocol.serve(Mutate, strategy);
}
