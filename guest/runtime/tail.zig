// SPDX-License-Identifier: MIT
//! What a node said last: the end of its output.log, in whole lines, for the failures that
//! judge it (det-init's exits, det-core's crashes), so a failure carries its cause (Consul's
//! "failed to setup node ID", SurrealDB's panic) without a query of the node's output.
const std = @import("std");
const linux = std.os.linux;

pub const said_size_max = 2048;
pub const said_lines_max = 16;

/// The node's last lines: at most said_lines_max and said_size_max bytes, whole lines only.
pub fn said(node: []const u8, buffer: *[said_size_max]u8) []const u8 {
    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/run/det/nodes/{s}/output.log", .{node}, 0) catch
        return "";
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return "";
    defer _ = linux.close(@intCast(fd));
    const end = linux.lseek(@intCast(fd), 0, linux.SEEK.END);
    if (linux.errno(end) != .SUCCESS) return "";
    const offset: u64 = @as(u64, @intCast(end)) -| buffer.len;
    const read = linux.pread(@intCast(fd), buffer, buffer.len, @intCast(offset));
    if (linux.errno(read) != .SUCCESS) return "";
    return last_lines(buffer[0..read], said_lines_max, offset == 0);
}

/// The last `count` lines of `text`, its trailing newlines left out; a first line cut by the
/// read (`whole` false: the text starts inside the file) is left out too.
pub fn last_lines(text: []const u8, count: usize, whole: bool) []const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    var start = trimmed.len;
    var lines: usize = 0;
    while (lines < count) : (lines += 1) {
        const newline = std.mem.lastIndexOfScalar(u8, trimmed[0..start], '\n') orelse {
            // Every line fits; the cut first one left out, unless it is all there is.
            if (whole or start == trimmed.len) return trimmed;
            return trimmed[start + 1 ..];
        };
        start = newline;
    }
    return trimmed[start + 1 ..];
}

test last_lines {
    try std.testing.expectEqualStrings("c\nd", last_lines("a\nb\nc\nd\n\n", 2, true));
    try std.testing.expectEqualStrings("a\nb", last_lines("a\nb\n", 5, true));
    try std.testing.expectEqualStrings("b\nc", last_lines("ut a\nb\nc\n", 5, false));
    try std.testing.expectEqualStrings("only", last_lines("only", 3, false));
    try std.testing.expectEqualStrings("", last_lines("", 3, true));
}
