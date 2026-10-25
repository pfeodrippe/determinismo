// SPDX-License-Identifier: MIT
//! A greybox mutation strategy over decision tapes.
//!
//! Each branch either starts fresh (its own seed) or derives from a parent in the corpus: it
//! replays the parent's decisions exactly, except at a few mutated pulls (random or boundary
//! values). After a mutated pull the timeline diverges, but it keeps the parent's prefix, so the
//! exploration concentrates around timelines that were interesting. A branch is interesting, and
//! joins the corpus, when it covers something new: a behavioral feature never seen before (an
//! event name with its categorical details, such as a fault's kind or a command's name, or an
//! assertion's message with its outcome; numbers are left out so novelty stays finite), or a new
//! signature (outcome, failing properties, event volume). Programs built with code coverage
//! (the C SDK's DETERMINISMO_COVERAGE) also report each edge they reach, as "coverage" events:
//! those are features too.
//!
//! Most children of a timeline that reached something new change a single decision at its
//! frontier: the decision before the newest feature, or one just after it. On the self-test maze
//! (four digit checks, 1 in 10000 timelines by chance) this solves it within about 100 branches,
//! where 300 random seeds do not.
//!
//! Parallel workers each run their own strategy process. With `--sync-dir <dir>` they share one
//! corpus the way parallel fuzzers do: each writes the timelines it keeps to the directory, with
//! the features they reached first, and before each branch imports the ones the others wrote:
//! it learns their features, and keeps the timelines that reached some it had not seen. Every
//! branch still replays from its tape alone; which branches an exploration runs then depends on
//! the workers' timing.
//!
//! Usage: mutate [--fresh-percent <n>] [--sync-dir <dir>]   (default 25, no sync)
const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("protocol.zig");

const corpus_max = 64;
const pulls_max = 16 * 1024;
const signatures_max = 4096;
const mutations_max = 4;
/// Behavioral features seen in any branch, as an open-addressing set of hashes.
const features_max = 1 << 14;
const detail_keys = [_][]const u8{ "kind", "flavor", "mode", "name", "node", "peer", "state" };

const Tape = struct {
    values: [pulls_max]u64 = undefined,
    count: u32 = 0,
    /// The last decision before this timeline last reached something new: the decision that
    /// led there, or the one before the decision that comes next.
    frontier: u32 = 0,
};
/// Mutations at the frontier: most children change one decision there or just after it (in a
/// maze of checks: the check that failed, or the next one).
const frontier_percent = 75;
const frontier_window = 4;
/// Parents: the newest corpus entry this often (it holds the deepest progress), else any.
const newest_percent = 50;
/// Files of other workers' corpus entries already imported (or skipped), by name hash.
const synced_max = 4096;
const imports_per_branch_max = 16;
/// A branch's first-seen features, shared with its corpus entry.
const found_max = 64;
/// A corpus entry on disk, little endian: count, frontier, found count, 0 (u32 each), then the
/// found features and the values (u64 each).
const entry_header_size = 16;
var entry_buffer: [entry_header_size + (found_max + pulls_max) * 8]u8 = undefined;

const Mutate = struct {
    prng: std.Random.DefaultPrng = .init(0),
    fresh_percent: u32 = 25,
    corpus: [corpus_max]Tape = undefined,
    corpus_count: u32 = 0,
    corpus_newest: u32 = 0,
    signatures: [signatures_max]u64 = undefined,
    signature_count: u32 = 0,
    features: [features_max]u64 = @splat(0),
    feature_count: u32 = 0,
    /// Features the running branch saw first, and the first of them.
    features_new: u32 = 0,
    found: [found_max]u64 = undefined,
    found_count: u32 = 0,
    /// The branch running now: its decisions so far, and how it was derived.
    current: Tape = .{},
    first_pull: ?u64 = null,
    parent: ?u32 = null,
    mutated_positions: [mutations_max]u32 = undefined,
    mutated_values: [mutations_max]u64 = undefined,
    mutation_count: u32 = 0,

    io: std.Io,
    sync_dir: ?std.Io.Dir = null,
    synced: [synced_max]u64 = undefined,
    synced_count: u32 = 0,
    exported_count: u32 = 0,

    pub const name = "mutate";

    pub fn branch(strategy: *Mutate, index: u32, seed: u64) void {
        _ = index;
        // From the branch's seed: parallel workers' strategies (one each) choose differently,
        // and a branch's choices do not depend on which worker runs it.
        strategy.prng = .init(seed ^ 0x6d7574617465);
        strategy.current.count = 0;
        strategy.current.frontier = 0;
        strategy.parent = null;
        strategy.mutation_count = 0;
        strategy.features_new = 0;
        strategy.found_count = 0;
        strategy.sync_import();
        const prng = strategy.prng.random();
        if (strategy.corpus_count == 0) return;
        if (prng.uintLessThan(u32, 100) < strategy.fresh_percent) return;
        const parent = if (prng.uintLessThan(u32, 100) < newest_percent)
            strategy.corpus_newest
        else
            prng.uintLessThan(u32, strategy.corpus_count);
        const parent_count = strategy.corpus[parent].count;
        if (parent_count == 0) return;
        strategy.parent = parent;
        const frontier = strategy.corpus[parent].frontier;
        if (frontier < parent_count and prng.uintLessThan(u32, 100) < frontier_percent) {
            // Geometric: the frontier itself half the time, then the decisions after it.
            var offset: u32 = 0;
            while (offset + 1 < frontier_window and prng.boolean()) offset += 1;
            strategy.mutation_count = 1;
            strategy.mutated_positions[0] = @min(parent_count - 1, frontier + offset);
            strategy.mutated_values[0] = value_random(prng);
        } else {
            strategy.mutation_count = 1 + prng.uintLessThan(u32, mutations_max);
            for (0..strategy.mutation_count) |index_mutation| {
                strategy.mutated_positions[index_mutation] = prng.uintLessThan(u32, parent_count);
                strategy.mutated_values[index_mutation] = value_random(prng);
            }
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

    /// Each event's features: what kind of thing happened, not the numbers it carried.
    pub fn event(strategy: *Mutate, value: std.json.Value) void {
        if (value != .object) return;
        var hasher = std.hash.Wyhash.init(0x66656174);
        if (value.object.get("assert")) |assertion| {
            if (assertion != .object) return;
            hash_field(&hasher, assertion.object, "type");
            hash_field(&hasher, assertion.object, "message");
            hash_field(&hasher, assertion.object, "condition");
        } else if (value.object.get("event")) |event_name| {
            if (event_name != .string) return;
            hasher.update(event_name.string);
            if (value.object.get("details")) |details| {
                if (details == .object) {
                    for (detail_keys) |key| hash_field(&hasher, details.object, key);
                }
            }
        } else if (value.object.get("lifecycle")) |lifecycle| {
            if (lifecycle != .string) return;
            hasher.update(lifecycle.string);
        } else return;
        strategy.feature(hasher.final());
    }

    fn feature(strategy: *Mutate, hash: u64) void {
        const key = hash | 1; // 0 marks an empty slot.
        if (!strategy.feature_insert(key)) return;
        strategy.features_new += 1;
        strategy.current.frontier = strategy.current.count -| 1;
        if (strategy.found_count < found_max) {
            strategy.found[strategy.found_count] = key;
            strategy.found_count += 1;
        }
    }

    /// Whether `key` was new (and is now in the set).
    fn feature_insert(strategy: *Mutate, key: u64) bool {
        assert(key != 0);
        var slot: usize = @intCast(key % features_max);
        for (0..features_max) |_| {
            if (strategy.features[slot] == key) return false;
            if (strategy.features[slot] == 0) {
                if (strategy.feature_count == features_max / 2) return false; // Keep it sparse.
                strategy.features[slot] = key;
                strategy.feature_count += 1;
                return true;
            }
            slot = (slot + 1) % features_max;
        }
        return false;
    }

    pub fn branch_end(strategy: *Mutate, end: protocol.BranchEnd) bool {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(end.outcome);
        for (end.failing) |property| hasher.update(property);
        hasher.update(std.mem.asBytes(&@as(u64, std.math.log2_int_ceil(u64, end.events + 1))));
        const signature = hasher.final();
        const new_signature = for (strategy.signatures[0..strategy.signature_count]) |seen| {
            if (seen == signature) break false;
        } else true;
        const novel = new_signature or strategy.features_new > 0;
        if (novel) strategy.remember(signature);
        const format = "[mutate] branch {d}: parent={?d} mutations={d} failing={d} " ++
            "new_features={d} coverage={d} corpus={d}\n";
        std.debug.print(format, .{
            end.index,             strategy.parent,       strategy.mutation_count, end.failing.len,
            strategy.features_new, strategy.feature_count, strategy.corpus_count,
        });
        return false;
    }

    fn remember(strategy: *Mutate, signature: u64) void {
        if (strategy.signature_count < signatures_max) {
            strategy.signatures[strategy.signature_count] = signature;
            strategy.signature_count += 1;
        }
        strategy.corpus_add(&strategy.current);
        if (strategy.found_count > 0) strategy.sync_export(&strategy.current);
    }

    fn corpus_add(strategy: *Mutate, tape: *const Tape) void {
        const slot = if (strategy.corpus_count < corpus_max) slot: {
            strategy.corpus_count += 1;
            break :slot strategy.corpus_count - 1;
        } else strategy.prng.random().uintLessThan(u32, corpus_max); // Full: replace one.
        strategy.corpus[slot] = tape.*;
        strategy.corpus_newest = slot;
        assert(strategy.corpus_count <= corpus_max);
    }

    /// Written under a temporary name and renamed, so readers never see half an entry.
    fn sync_export(strategy: *Mutate, tape: *const Tape) void {
        const dir = strategy.sync_dir orelse return;
        const pid = std.os.linux.getpid();
        var name_buffer: [64]u8 = undefined;
        var temporary_buffer: [64]u8 = undefined;
        const entry_name = std.fmt.bufPrint(&name_buffer, "{d}-{d}", .{
            pid, strategy.exported_count,
        }) catch unreachable;
        const temporary = std.fmt.bufPrint(&temporary_buffer, ".{s}", .{entry_name}) catch
            unreachable;
        strategy.exported_count += 1;
        std.mem.writeInt(u32, entry_buffer[0..4], tape.count, .little);
        std.mem.writeInt(u32, entry_buffer[4..8], tape.frontier, .little);
        std.mem.writeInt(u32, entry_buffer[8..12], strategy.found_count, .little);
        std.mem.writeInt(u32, entry_buffer[12..16], 0, .little);
        const found = std.mem.sliceAsBytes(strategy.found[0..strategy.found_count]);
        const values = std.mem.sliceAsBytes(tape.values[0..tape.count]);
        @memcpy(entry_buffer[entry_header_size..][0..found.len], found);
        @memcpy(entry_buffer[entry_header_size + found.len ..][0..values.len], values);
        const data = entry_buffer[0 .. entry_header_size + found.len + values.len];
        dir.writeFile(strategy.io, .{ .sub_path = temporary, .data = data }) catch return;
        dir.rename(temporary, dir, entry_name, strategy.io) catch return;
        _ = strategy.synced_add(entry_name); // Not to be imported back.
    }

    fn sync_import(strategy: *Mutate) void {
        const dir = strategy.sync_dir orelse return;
        var imports: u32 = 0;
        var iterator = dir.iterate();
        while (iterator.next(strategy.io) catch return) |entry| {
            if (imports == imports_per_branch_max) return;
            if (entry.kind != .file or entry.name[0] == '.') continue;
            if (strategy.synced_has(entry.name)) continue;
            if (!strategy.synced_add(entry.name)) return; // Full: stop syncing.
            const data = dir.readFile(strategy.io, entry.name, &entry_buffer) catch continue;
            if (data.len < entry_header_size) continue;
            const count = std.mem.readInt(u32, data[0..4], .little);
            const found_count = std.mem.readInt(u32, data[8..12], .little);
            if (count > pulls_max or found_count > found_max) continue;
            if (data.len != entry_header_size + (found_count + count) * 8) continue;
            const found_end = entry_header_size + found_count * 8;
            var novel = false;
            for (0..found_count) |index| {
                const at = entry_header_size + index * 8;
                const key = std.mem.readInt(u64, data[at..][0..8], .little);
                if (key != 0 and strategy.feature_insert(key)) novel = true;
            }
            if (!novel) continue; // Nothing this worker had not reached itself.
            const tape = &import_tape;
            tape.count = count;
            tape.frontier = std.mem.readInt(u32, data[4..8], .little);
            @memcpy(std.mem.sliceAsBytes(tape.values[0..count]), data[found_end..]);
            strategy.corpus_add(tape);
            imports += 1;
        }
    }

    fn synced_has(strategy: *const Mutate, entry_name: []const u8) bool {
        const hash = std.hash.Wyhash.hash(0, entry_name);
        for (strategy.synced[0..strategy.synced_count]) |seen| {
            if (seen == hash) return true;
        }
        return false;
    }

    fn synced_add(strategy: *Mutate, entry_name: []const u8) bool {
        if (strategy.synced_count == synced_max) return false;
        strategy.synced[strategy.synced_count] = std.hash.Wyhash.hash(0, entry_name);
        strategy.synced_count += 1;
        return true;
    }
};

fn value_random(prng: std.Random) u64 {
    return switch (prng.uintLessThan(u32, 8)) {
        0 => 0, // Boundary values make choices take their extremes.
        1 => std.math.maxInt(u64),
        else => prng.int(u64),
    };
}

fn hash_field(hasher: *std.hash.Wyhash, object: std.json.ObjectMap, key: []const u8) void {
    const value = object.get(key) orelse return;
    hasher.update(key);
    switch (value) {
        .string => |text| hasher.update(text),
        .bool => |flag| hasher.update(if (flag) "true" else "false"),
        else => {}, // Numbers and structures: not features.
    }
}

var answer: [8]u8 = undefined;
var import_tape: Tape = .{};

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    const strategy = try init.arena.allocator().create(Mutate); // Large: never on the stack.
    strategy.* = .{ .io = init.io };
    var index: usize = 1;
    while (index + 1 < arguments.len) : (index += 2) {
        const flag = arguments[index];
        const value = arguments[index + 1];
        if (std.mem.eql(u8, flag, "--fresh-percent")) {
            strategy.fresh_percent = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, flag, "--sync-dir")) {
            const cwd = std.Io.Dir.cwd();
            try cwd.createDirPath(init.io, value);
            strategy.sync_dir = try cwd.openDir(init.io, value, .{ .iterate = true });
        } else return error.Usage;
    }
    if (strategy.fresh_percent > 100) return error.BadFreshPercent;
    try protocol.serve(Mutate, strategy);
}
