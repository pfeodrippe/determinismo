// SPDX-License-Identifier: MIT
//! Snapshots of a replayed timeline, saved to disk at moments (`explore --tape <t>
//! --save-snapshots <dir> --save-at-ms <a,b,...>`): causality analysis forks futures from them
//! without booting or replaying, and they outlive the process (snapshot.zig's disk format).
//!
//! The replay pauses at each moment as at a holder's hold point (holders.zig): its state is
//! captured, and a copy-on-write fork writes it with the memory pages that changed since the one
//! before (the first, since the setup snapshot, saved once per directory), while the replay goes
//! on. One child at a time: each updates the page hashes the next one compares with.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const VM = @import("vm.zig");
const Snapshot = @import("snapshot.zig");
const cpus = @import("cpus.zig");

pub const moments_max = 256;

pub const Saver = struct {
    hold: VM.Hold = undefined,
    directory: []const u8,
    /// The taped branch: snapshots are named after it and their moment (`b<branch>-<ms>`).
    branch: u32,
    moments_ns: []const u64,
    next: usize = 0,
    /// The last one saved (or the setup snapshot): the next one's base.
    base: [Snapshot.disk_name_max]u8 = @splat(0),
    base_len: usize = 0,
    hashes: Snapshot.PageHashes,
    capture: *Snapshot,
    child: ?linux.pid_t = null,
    saved: u32 = 0,

    /// Ready to save the timeline that starts from `setup` (the run's setup snapshot, saved as
    /// `setup_name` unless the directory has it). Its moments, in increasing order, from
    /// `moments_ms`.
    pub fn init(
        arena: std.mem.Allocator,
        directory: []const u8,
        branch: u32,
        moments_ms: []const u64,
        setup: *const Snapshot,
        setup_name: []const u8,
    ) !Saver {
        assert(moments_ms.len > 0 and moments_ms.len <= moments_max);
        const moments_ns = try arena.alloc(u64, moments_ms.len);
        for (moments_ms, moments_ns) |ms, *ns| ns.* = ms * std.time.ns_per_ms;
        std.mem.sort(u64, moments_ns, {}, std.sort.asc(u64));
        var saver: Saver = .{
            .directory = directory,
            .branch = branch,
            .moments_ns = moments_ns,
            .hashes = try Snapshot.PageHashes.init(setup.memory_size),
            .capture = try arena.create(Snapshot),
        };
        // The setup snapshot's pages: the first moment's base.
        const size = setup.memory_size;
        const address = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .SHARED }, setup.memory_fd, 0);
        if (linux.errno(address) != .SUCCESS) return error.OutOfMemory;
        defer _ = linux.munmap(@ptrFromInt(address), size);
        const memory = @as([*]align(std.heap.page_size_min) const u8, @ptrFromInt(address))[0..size];
        if (Snapshot.disk_exists(directory, setup_name)) {
            try Snapshot.pages_hash(memory, saver.hashes.hashes);
        } else {
            try Snapshot.disk_save(setup, memory, saver.hashes.hashes, directory, setup_name, null, false);
        }
        saver.base_set(setup_name);
        return saver;
    }

    /// Pauses `vm` (the branch, which starts at `start_ns`) at the moments after its start.
    pub fn attach(saver: *Saver, vm: *VM, start_ns: u64) !void {
        while (saver.next < saver.moments_ns.len and saver.moments_ns[saver.next] <= start_ns) {
            std.debug.print("[determinismo] not saved: {d}ns is not after the branch's start " ++
                "({d}ns)\n", .{ saver.moments_ns[saver.next], start_ns });
            saver.next += 1;
        }
        if (saver.next == saver.moments_ns.len) return;
        saver.hold = .{ .context = saver, .behaviors = behaviors, .reached = reached };
        vm.hold = &saver.hold;
        vm.hold_behaviors = vm.events.behavior_count;
        try vm.hold_arm(saver.moments_ns[saver.next]);
    }

    /// The last moment to save: the replay needs to go no further.
    pub fn last_ns(saver: *const Saver) u64 {
        return saver.moments_ns[saver.moments_ns.len - 1];
    }

    fn behaviors(_: *anyopaque, _: *VM, _: u32) !void {}

    fn reached(context: *anyopaque, vm: *VM, point: VM.Hold.Point) !void {
        const saver: *Saver = @ptrCast(@alignCast(context));
        const moment_ns = saver.moments_ns[saver.next];
        saver.next += 1;
        if (saver.next < saver.moments_ns.len) try vm.hold_arm(saver.moments_ns[saver.next]);
        try saver.wait(); // The page hashes are the last one's.
        try saver.capture.capture(vm);
        var name_buffer: [Snapshot.disk_name_max]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "b{d}-{d}", .{
            saver.branch, moment_ns / std.time.ns_per_ms,
        });
        const pid = linux.fork();
        if (pid == 0) {
            cpus.unpin(); // Off the replay's CPU.
            const base = saver.base[0..saver.base_len];
            const memory: []align(std.heap.page_size_min) const u8 = vm.memory;
            // Saved before (another analysis): its pages are this memory's, for the next.
            const result = if (Snapshot.disk_exists(saver.directory, name))
                Snapshot.pages_hash(memory, saver.hashes.hashes)
            else
                Snapshot.disk_save(saver.capture, memory, saver.hashes.hashes, saver.directory, name, base, point.idle);
            result catch |err| {
                std.debug.print("[determinismo] saving snapshot {s} failed: {s}\n", .{ name, @errorName(err) });
                linux.exit_group(1);
            };
            linux.exit_group(0);
        }
        if (linux.errno(pid) != .SUCCESS) return error.Fork;
        saver.child = @intCast(pid);
        saver.base_set(name);
        std.debug.print("[determinismo] saved snapshot {s}/{s} at vtime={d}ns\n", .{
            saver.directory, name, moment_ns,
        });
        saver.saved += 1;
    }

    fn base_set(saver: *Saver, name: []const u8) void {
        assert(name.len < Snapshot.disk_name_max);
        @memcpy(saver.base[0..name.len], name);
        saver.base_len = name.len;
    }

    /// Waits for the snapshot being written.
    fn wait(saver: *Saver) !void {
        const pid = saver.child orelse return;
        saver.child = null;
        var status: i32 = 0;
        while (true) {
            const result = linux.wait4(pid, &status, 0, null);
            if (linux.errno(result) == .INTR) continue;
            if (linux.errno(result) != .SUCCESS) return error.Wait;
            break;
        }
        if (status != 0) return error.SnapshotSaveFailed;
    }

    /// After the replay: every snapshot written, or an error.
    pub fn finish(saver: *Saver) !void {
        try saver.wait();
        saver.hashes.deinit();
        if (saver.next < saver.moments_ns.len) {
            std.debug.print("[determinismo] the timeline ended before {d}ns: {d} snapshots " ++
                "not saved\n", .{ saver.moments_ns[saver.next], saver.moments_ns.len - saver.next });
        }
    }
};
