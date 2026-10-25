// SPDX-License-Identifier: MIT
//! Example test program: HashiCorp Raft (github.com/hashicorp/raft), three nodes replicating a
//! "chain of blocks" (service/main.go): each command is a block of random bytes, and each
//! replica's state is the number of blocks it applied with the running hash over them. Raft is
//! pinned to upstream commit 4c8f61ac (2026-05-19), the one Antithesis's article started from
//! (antithesis.com/blog/2026/finding-bugs-in-raft-implementations).
//!
//! Properties (Raft's state machine safety, and recovery once faults stop):
//!   replicas agree      any two replicas have the same hash after the same number of blocks
//!   commits progress    after faults, a block submitted through the leader commits
//!   replicas converge   after faults, every replica reaches the same length and hash
//! Faults: the default ones (partitions into groups, clogs, pauses, degraded links, ...), and
//! restarts in profile `restarts` (the log and snapshots survive them on the node's disk).
//!
//!   determinismo explore ... --program zig-out/bin/raft-test --scenario chain --branches 64
const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("determinismo");

const Nodes = struct { @"raft-1": sdk.Node, @"raft-2": sdk.Node, @"raft-3": sdk.Node };
const System = sdk.System(Nodes);
const node_names = [_][]const u8{ "raft-1", "raft-2", "raft-3" };

const peers = "raft-1,raft-2,raft-3";
const http_port = 8000;
const block_size_max = 64;
const blocks_per_driver = 20;
const leader_attempts_max = 300;
const recovery_attempts_max = 120;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .chain = chain } });
}

fn describe(d: *System.Describe) !void {
    for ([_][]const u8{ "default", "restarts" }) |name| {
        const profile = try d.profile(name);
        const restarts = std.mem.eql(u8, name, "restarts");
        inline for (comptime std.meta.fieldNames(Nodes)) |node| {
            profile.node(@field(System.Name, node), .{
                .build = .{ .context = ".", .dockerfile = "examples/raft/Dockerfile" },
                .command = &.{ "-id", node, "-peers", peers, "-data", "/var/lib/raft" },
                .ready = .{ .tcp = http_port },
                .faults = .{ .restart = restarts },
            });
        }
    }
}

fn chain(s: *System.Scenario) void {
    s.setup("leader", leader_elected);
    s.parallel_driver("submit", submit_many);
    s.anytime("agree", replicas_agree);
    s.eventually("progress", commits_progress);
    s.eventually("converge", replicas_converge);
}

fn addresses(context: *System.Context) [3][4]u8 {
    return .{
        context.nodes.@"raft-1".address,
        context.nodes.@"raft-2".address,
        context.nodes.@"raft-3".address,
    };
}

const State = struct { applied: u64, hash: []const u8, leader: bool };

fn state_of(address: [4]u8, buffer: []u8) !State {
    const response = try sdk.tcp.http(address, http_port, "GET", "/state", "", buffer);
    if (response.status != 200) return error.BadStatus;
    var fixed: std.heap.FixedBufferAllocator = .init(buffer[response.body.len..]);
    return std.json.parseFromSliceLeaky(State, fixed.allocator(), response.body, .{
        .ignore_unknown_fields = true,
    });
}

/// A leader exists: the cluster formed, and branches start from here.
fn leader_elected(context: *System.Context) !void {
    const all = addresses(context);
    _ = try sdk.retry(leader_attempts_max, 100, any_leader, .{&all});
}

fn any_leader(all: *const [3][4]u8) !void {
    for (all) |address| {
        var buffer: [1024]u8 = undefined;
        const state = state_of(address, &buffer) catch continue;
        if (state.leader) return;
    }
    return error.NoLeader;
}

/// Random blocks, each submitted to the nodes in a random order until one (the leader) takes it.
fn submit_many(context: *System.Context) !void {
    const all = addresses(context);
    for (0..blocks_per_driver) |_| {
        var block: [block_size_max]u8 = undefined;
        const size = 1 + sdk.random_below(block_size_max);
        sdk.random_bytes(block[0..size]);
        if (submit(&all, block[0..size])) {
            sdk.sometimes(true, "a block committed", .{});
        } else |err| {
            sdk.sometimes(true, "a block was not committed", .{ .err = @errorName(err) });
        }
    }
}

fn submit(all: *const [3][4]u8, block: []const u8) !void {
    const first = sdk.random_below(all.len);
    for (0..all.len) |offset| {
        const address = all[(first + offset) % all.len];
        var buffer: [256]u8 = undefined;
        const response = sdk.tcp.http(address, http_port, "POST", "/submit", block, &buffer) catch
            continue;
        if (response.status == 200) return;
    }
    return error.NoLeaderTookIt;
}

/// State machine safety: replicas that applied the same number of blocks hold the same hash.
/// Each pair is compared at the shorter one's length, through the longer one's history.
fn replicas_agree(context: *System.Context) !void {
    const all = addresses(context);
    var states: [3]?State = @splat(null);
    var buffers: [3][1024]u8 = undefined;
    for (all, &states, &buffers) |address, *state, *buffer| {
        state.* = state_of(address, buffer) catch null;
    }
    for (0..all.len) |a| for (a + 1..all.len) |b| {
        const first = states[a] orelse continue;
        const second = states[b] orelse continue;
        const length = @min(first.applied, second.applied);
        if (length == 0) continue;
        var hashes: [2][96]u8 = undefined;
        const one = hash_at(all[a], length, &hashes[0]) catch continue;
        const two = hash_at(all[b], length, &hashes[1]) catch continue;
        sdk.always(std.mem.eql(u8, one, two), "replicas agree on the blocks they applied", .{
            .first = node_names[a],
            .second = node_names[b],
            .blocks = length,
        });
    };
}

fn hash_at(address: [4]u8, length: u64, buffer: []u8) ![]const u8 {
    var path_buffer: [32]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/hash?n={d}", .{length});
    const response = try sdk.tcp.http(address, http_port, "GET", path, "", buffer);
    if (response.status != 200) return error.NotApplied;
    return std.mem.trimEnd(u8, response.body, "\n");
}

/// Faults are over: a new block commits.
fn commits_progress(context: *System.Context) !void {
    const all = addresses(context);
    var block: [16]u8 = undefined;
    sdk.random_bytes(&block);
    sdk.retry(recovery_attempts_max, 250, submit, .{ &all, &block }) catch |err| {
        sdk.assert_unreachable("no block commits once faults stop", .{ .err = @errorName(err) });
        return err;
    };
}

/// Faults are over: every replica reaches the same length and hash.
fn replicas_converge(context: *System.Context) !void {
    const all = addresses(context);
    sdk.retry(recovery_attempts_max, 250, converged, .{&all}) catch |err| {
        sdk.assert_unreachable("replicas never converge once faults stop", .{
            .err = @errorName(err),
        });
        return err;
    };
}

fn converged(all: *const [3][4]u8) !void {
    var first: ?State = null;
    var buffers: [3][1024]u8 = undefined;
    for (all, &buffers) |address, *buffer| {
        const state = try state_of(address, buffer);
        if (first) |known| {
            if (known.applied != state.applied or !std.mem.eql(u8, known.hash, state.hash)) {
                return error.NotConverged;
            }
        } else first = state;
    }
}
