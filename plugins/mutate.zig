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
//! signature (outcome, failing properties, event volume). Programs with code coverage (the C
//! and Zig SDKs' edges, the Python SDK's lines) also report the code they reach, as "coverage"
//! events: those are features too. Events of determinismo's own processes (faults injected,
//! commands started) are the exploration's doing, not the system's behavior: not features.
//!
//! Guidance (the SDKs' guidance assertions, `always_greater_than` and the like) is a feature
//! too: an assertion's distance to its interesting outcome, in buckets of powers of two, so a
//! timeline that comes closer is kept; its children change any of the guided process's recent
//! decisions, since each may be an input to the comparison.
//!
//! Parents: half the time the newest corpus entry (the latest progress), else the rarest of a
//! few entries drawn at random, by how often the features they reached first have been hit.
//!
//! Most children of a timeline that reached something new change a single decision at its
//! frontier, where the newest feature was reached. Decisions come from several processes at
//! once (the fault injector, the composer, each test command), and determinismo says which
//! process asked for each decision and wrote each event: the candidates are the decisions of
//! the process that reached the feature, its last one before the frontier and its first one
//! after (coverage of a check comes after the decision it checks, in edge coverage, or before
//! the decision on its line, in line coverage). On the self-test maze (four digit checks, 1 in
//! 10000 timelines by chance) this solves it within about 100 branches, where 300 random seeds
//! do not; in Python under faults, within about 200.
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
/// determinismo's own processes in the guest: what they report (faults injected, commands
/// started) is the exploration's doing, not the system's behavior, so it is not novelty.
const runtime_sources = [_][]const u8{
    "det-init", "det-nodes", "det-composer", "det-faults", "det-agent",
};

const Tape = struct {
    values: [pulls_max]u64 = undefined,
    /// Which process asked for each decision (a hash of its name).
    sources: [pulls_max]u32 = undefined,
    count: u32 = 0,
    /// The decisions made before this timeline last reached something new, and which process
    /// reached it.
    frontier: u32 = 0,
    frontier_source: u32 = 0,
    /// Where guidance last reached something new (an assertion came closer to its outcome),
    /// kept apart from the frontier, which later features move: the comparison's inputs are
    /// any of that process's decisions before it, not only its last.
    guided: bool = false,
    guided_frontier: u32 = 0,
    guided_source: u32 = 0,
    /// The features it reached first (its claim to a place in the corpus).
    found: [found_max]u64 = undefined,
    found_count: u32 = 0,
};
/// Mutations at the frontier: most children change one decision around it (in a maze of
/// checks: the check that failed, or the next one).
const frontier_percent = 75;
/// How far from the frontier candidates are looked for, and how many sources are told apart.
const frontier_window = 64;
const frontier_sources_max = 8;
/// Of frontier mutations, those on the decisions of the process that reached the feature.
const frontier_source_percent = 80;
/// Parents: the newest corpus entry this often (it holds the latest progress), else the rarest
/// of a few drawn at random (a tournament). An entry is as rare as the rarest feature it reached
/// first, by how often features have been hit since: timelines that went where few others go.
const newest_percent = 50;
const tournament_size = 4;
/// Files of other workers' corpus entries already imported (or skipped), by name hash.
const synced_max = 4096;
const imports_per_branch_max = 16;
/// A branch's first-seen features, shared with its corpus entry.
const found_max = 64;
/// A corpus entry on disk, little endian: count, frontier, found count, frontier source, guided
/// (1 or 0), guided frontier, guided source (u32 each), then the found features and the values
/// (u64 each), then the sources (u32 each).
const entry_header_size = 28;
var entry_buffer: [entry_header_size + (found_max + pulls_max) * 8 + pulls_max * 4]u8 = undefined;

const Mutate = struct {
    prng: std.Random.DefaultPrng = .init(0),
    fresh_percent: u32 = 25,
    corpus: [corpus_max]Tape = undefined,
    corpus_count: u32 = 0,
    corpus_newest: u32 = 0,
    signatures: [signatures_max]u64 = undefined,
    signature_count: u32 = 0,
    features: [features_max]u64 = @splat(0),
    /// How often each feature was hit, in all branches.
    feature_hits: [features_max]u32 = @splat(0),
    feature_count: u32 = 0,
    /// Features the running branch saw first.
    features_new: u32 = 0,
    /// The branch running now: its decisions so far, and how it was derived.
    current: Tape = .{},
    first_pull: ?u64 = null,
    parent: ?u32 = null,
    mutated_positions: [mutations_max]u32 = undefined,
    mutated_values: [mutations_max]u64 = undefined,
    mutation_count: u32 = 0,
    /// The mutation is at the parent's frontier (where new coverage appeared), not anywhere.
    mutation_frontier: bool = false,
    /// Why the last answer: set for mutated decisions only (the parent's own are copies).
    reason_buffer: [200]u8 = undefined,
    reason_size: u8 = 0,

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
        strategy.current.guided = false;
        strategy.parent = null;
        strategy.mutation_count = 0;
        strategy.features_new = 0;
        strategy.current.found_count = 0;
        strategy.sync_import();
        const prng = strategy.prng.random();
        if (strategy.corpus_count == 0) return;
        if (prng.uintLessThan(u32, 100) < strategy.fresh_percent) return;
        const parent = strategy.parent_pick(prng);
        const parent_count = strategy.corpus[parent].count;
        if (parent_count == 0) return;
        strategy.parent = parent;
        var candidates: [2 * frontier_sources_max]u32 = undefined;
        const candidate_count = frontier_candidates(&strategy.corpus[parent], prng, &candidates);
        strategy.mutation_frontier = false;
        if (candidate_count > 0 and prng.uintLessThan(u32, 100) < frontier_percent) {
            strategy.mutation_frontier = true;
            strategy.mutation_count = 1;
            strategy.mutated_positions[0] = candidates[prng.uintLessThan(u32, candidate_count)];
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
        if (position >= pulls_max) return null;
        // Pulls of other sizes keep their place in the tape, but are never changed.
        const steerable = request.default.len == 8;
        const default = if (steerable) std.mem.readInt(u64, request.default[0..8], .little) else 0;
        const value = if (steerable) strategy.choose(position) orelse default else 0;
        if (position == strategy.current.count) {
            strategy.current.values[position] = value;
            strategy.current.sources[position] = source_hash(request.source);
            strategy.current.count += 1;
        }
        if (!steerable or strategy.parent == null) return null;
        strategy.reason_note(position);
        std.mem.writeInt(u64, &answer, value, .little);
        return &answer;
    }

    pub fn reason(strategy: *const Mutate) ?[]const u8 {
        if (strategy.reason_size == 0) return null;
        return strategy.reason_buffer[0..strategy.reason_size];
    }

    fn reason_note(strategy: *Mutate, position: u32) void {
        strategy.reason_size = 0;
        const mutated = for (strategy.mutated_positions[0..strategy.mutation_count]) |mutated| {
            if (mutated == position) break true;
        } else false;
        if (!mutated) return; // A copy of the parent's decision: nothing to explain.
        const where = if (strategy.mutation_frontier)
            "at its frontier (decisions just before it found new coverage)"
        else
            "at random";
        const text = std.fmt.bufPrint(&strategy.reason_buffer, "Mutated decision {d} of " ++
            "corpus entry {d} (a timeline that found new coverage), {s}.", .{
            position, strategy.parent.?, where,
        }) catch return;
        strategy.reason_size = @intCast(text.len);
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
    pub fn event(strategy: *Mutate, value: std.json.Value, source: []const u8) void {
        if (value != .object) return;
        for (runtime_sources) |runtime| {
            if (std.mem.eql(u8, source, runtime)) return;
        }
        var hasher = std.hash.Wyhash.init(0x66656174);
        var guided = false;
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
        } else if (value.object.get("guidance")) |guidance| {
            // How far an assertion is from its interesting outcome, in buckets of powers of two:
            // a timeline that comes into a closer bucket reached something new.
            if (guidance != .object) return;
            hash_field(&hasher, guidance.object, "message");
            const distance = guidance.object.get("distance") orelse return;
            const bucket = distance_bucket(switch (distance) {
                .integer => |integer| @floatFromInt(integer),
                .float => |float| float,
                else => return,
            });
            hasher.update(std.mem.asBytes(&bucket));
            guided = true;
        } else return;
        strategy.feature(hasher.final(), source_hash(source), guided);
    }

    /// 0 at or past the outcome (distance 0 or less), else 1 + log2 of the distance, capped.
    fn distance_bucket(distance: f64) u8 {
        if (!(distance > 0)) return 0;
        if (distance >= 1 << 62) return 64;
        return 1 + std.math.log2_int(u64, @as(u64, @intFromFloat(distance)) | 1);
    }

    fn feature(strategy: *Mutate, hash: u64, source: u32, guided: bool) void {
        const key = hash | 1; // 0 marks an empty slot.
        const found = strategy.feature_insert(key) orelse return;
        strategy.feature_hits[found.slot] +|= 1;
        if (!found.new) return;
        strategy.features_new += 1;
        const current = &strategy.current;
        current.frontier = current.count;
        current.frontier_source = source;
        if (guided) {
            current.guided = true;
            current.guided_frontier = current.count;
            current.guided_source = source;
        }
        if (current.found_count < found_max) {
            current.found[current.found_count] = key;
            current.found_count += 1;
        }
    }

    /// The slot of `key` in the set, and whether it was new; null when the set is full.
    fn feature_insert(strategy: *Mutate, key: u64) ?struct { slot: usize, new: bool } {
        assert(key != 0);
        var slot: usize = @intCast(key % features_max);
        for (0..features_max) |_| {
            if (strategy.features[slot] == key) return .{ .slot = slot, .new = false };
            if (strategy.features[slot] == 0) {
                if (strategy.feature_count == features_max / 2) return null; // Keep it sparse.
                strategy.features[slot] = key;
                strategy.feature_count += 1;
                return .{ .slot = slot, .new = true };
            }
            slot = (slot + 1) % features_max;
        }
        return null;
    }

    fn parent_pick(strategy: *const Mutate, prng: std.Random) u32 {
        assert(strategy.corpus_count > 0);
        if (prng.uintLessThan(u32, 100) < newest_percent) return strategy.corpus_newest;
        var best = prng.uintLessThan(u32, strategy.corpus_count);
        var best_hits = strategy.entry_hits(best);
        for (1..tournament_size) |_| {
            const entry = prng.uintLessThan(u32, strategy.corpus_count);
            const hits = strategy.entry_hits(entry);
            if (hits < best_hits) {
                best = entry;
                best_hits = hits;
            }
        }
        return best;
    }

    /// Hits of the rarest feature the entry reached first (the most for none).
    fn entry_hits(strategy: *const Mutate, entry: u32) u32 {
        const tape = &strategy.corpus[entry];
        var hits: u32 = std.math.maxInt(u32);
        for (tape.found[0..tape.found_count]) |key| {
            var slot: usize = @intCast(key % features_max);
            for (0..features_max) |_| {
                if (strategy.features[slot] == key) break;
                if (strategy.features[slot] == 0) break;
                slot = (slot + 1) % features_max;
            }
            if (strategy.features[slot] == key) hits = @min(hits, strategy.feature_hits[slot]);
        }
        return hits;
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
        if (strategy.current.found_count > 0) strategy.sync_export(&strategy.current);
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
        std.mem.writeInt(u32, entry_buffer[8..12], tape.found_count, .little);
        std.mem.writeInt(u32, entry_buffer[12..16], tape.frontier_source, .little);
        std.mem.writeInt(u32, entry_buffer[16..20], @intFromBool(tape.guided), .little);
        std.mem.writeInt(u32, entry_buffer[20..24], tape.guided_frontier, .little);
        std.mem.writeInt(u32, entry_buffer[24..28], tape.guided_source, .little);
        const found = std.mem.sliceAsBytes(tape.found[0..tape.found_count]);
        const values = std.mem.sliceAsBytes(tape.values[0..tape.count]);
        const sources = std.mem.sliceAsBytes(tape.sources[0..tape.count]);
        var end: usize = entry_header_size;
        for ([_][]const u8{ found, values, sources }) |part| {
            @memcpy(entry_buffer[end..][0..part.len], part);
            end += part.len;
        }
        const data = entry_buffer[0..end];
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
            if (data.len != entry_header_size + (found_count + count) * 8 + count * 4) continue;
            const found_end = entry_header_size + found_count * 8;
            const tape = &import_tape;
            tape.found_count = 0;
            for (0..found_count) |index| {
                const at = entry_header_size + index * 8;
                const key = std.mem.readInt(u64, data[at..][0..8], .little);
                if (key == 0) continue;
                const found = strategy.feature_insert(key) orelse continue;
                if (!found.new) continue;
                strategy.feature_hits[found.slot] = 1;
                tape.found[tape.found_count] = key;
                tape.found_count += 1;
            }
            if (tape.found_count == 0) continue; // Nothing this worker had not reached itself.
            tape.count = count;
            tape.frontier = std.mem.readInt(u32, data[4..8], .little);
            tape.frontier_source = std.mem.readInt(u32, data[12..16], .little);
            tape.guided = std.mem.readInt(u32, data[16..20], .little) & 1 != 0;
            tape.guided_frontier = std.mem.readInt(u32, data[20..24], .little);
            tape.guided_source = std.mem.readInt(u32, data[24..28], .little);
            const values_end = found_end + count * 8;
            @memcpy(std.mem.sliceAsBytes(tape.values[0..count]), data[found_end..values_end]);
            @memcpy(std.mem.sliceAsBytes(tape.sources[0..count]), data[values_end..]);
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

/// The last decision before the frontier and the first one after, of the process that reached
/// the newest feature (most of the time, when it made decisions near there), or of each source.
fn frontier_candidates(
    tape: *const Tape,
    prng: std.Random,
    out: *[2 * frontier_sources_max]u32,
) u32 {
    const frontier = @min(tape.frontier, tape.count);
    if (tape.guided and prng.boolean()) {
        // Any of the guided process's decisions before it may be an input to its comparison.
        const guided = @min(tape.guided_frontier, tape.count);
        var count: u32 = 0;
        var before = guided;
        while (before > 0 and guided - before < frontier_window and count < out.len) {
            before -= 1;
            if (tape.sources[before] != tape.guided_source) continue;
            out[count] = before;
            count += 1;
        }
        if (count > 0) return count;
    }
    if (prng.uintLessThan(u32, 100) < frontier_source_percent) {
        var count: u32 = 0;
        var before = frontier;
        while (before > 0 and frontier - before < frontier_window) {
            before -= 1;
            if (tape.sources[before] != tape.frontier_source) continue;
            out[count] = before;
            count += 1;
            break;
        }
        for (frontier..@min(tape.count, frontier + frontier_window)) |after| {
            if (tape.sources[after] != tape.frontier_source) continue;
            out[count] = @intCast(after);
            count += 1;
            break;
        }
        if (count > 0) return count;
    }
    var count: u32 = 0;
    for ([_]bool{ false, true }) |after| {
        var seen: [frontier_sources_max]u32 = undefined;
        var seen_count: u32 = 0;
        for (0..frontier_window) |step| {
            const offset: u32 = @intCast(step);
            const position = if (after) frontier + offset else frontier -% (offset + 1);
            if (position >= tape.count) break; // Past the end, or (wrapped) before the start.
            const source = tape.sources[position];
            if (std.mem.indexOfScalar(u32, seen[0..seen_count], source) != null) continue;
            seen[seen_count] = source;
            seen_count += 1;
            out[count] = position;
            count += 1;
            if (seen_count == frontier_sources_max) break;
        }
    }
    return count;
}

fn source_hash(source: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, source));
}

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
