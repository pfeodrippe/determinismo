// SPDX-License-Identifier: MIT
//! det-fake-explore: stands in for `determinismo explore` when the controller itself is the
//! system under test (no KVM inside the guest). It accepts explore's arguments, writes a record
//! like explore's (--record, or serve's --run-directory: record.jsonl there; run, branches,
//! summary) over a few hundred milliseconds, and exits like explore: 0 when every property
//! passed, 3 when some failed.
const std = @import("std");
const linux = std.os.linux;
const sdk = @import("determinismo");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    var record: ?[]const u8 = null;
    var branches: u32 = 4;
    for (arguments, 0..) |argument, index| {
        if (index + 1 == arguments.len) break;
        if (std.mem.eql(u8, argument, "--record")) record = arguments[index + 1];
        if (std.mem.eql(u8, argument, "--run-directory")) {
            record = try std.fs.path.join(arena, &.{ arguments[index + 1], "record.jsonl" });
        }
        if (std.mem.eql(u8, argument, "--branches")) {
            branches = std.fmt.parseInt(u32, arguments[index + 1], 10) catch 4;
        }
    }
    const path = record orelse return error.NoRecord;
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\"run\":{\"inputs\":\"0\",\"seed\":\"0\",\"branches\":");
    try out.print(arena, "{d}}}}}\n", .{branches});
    var failing: u32 = 0;
    for (0..branches) |index| {
        sleep_ms(10 + sdk.random_below(90)); // Branches take time.
        const fails = sdk.random_below(4) == 0;
        failing += @intFromBool(fails);
        try out.print(arena, "{{\"branch\":{{\"index\":{d},\"failing\":[{s}]}}}}\n", .{
            index, if (fails) "\"a property\"" else "",
        });
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = out.items });
    }
    try out.print(arena, "{{\"summary\":{{\"branches\":{d},\"failing_branches\":{d}}}}}\n", .{
        branches, failing,
    });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = out.items });
    if (failing > 0) std.process.exit(3);
}

fn sleep_ms(duration_ms: u64) void {
    const request = linux.timespec{
        .sec = @intCast(duration_ms / 1000),
        .nsec = @intCast((duration_ms % 1000) * std.time.ns_per_ms),
    };
    _ = linux.nanosleep(&request, null);
}
