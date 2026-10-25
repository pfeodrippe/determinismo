// SPDX-License-Identifier: MIT
//! tidy: mechanical checks of the style rules in docs/STYLE.md, run by `zig build tidy`.
//!
//! For every .zig file under the checked directories: an SPDX header, no tabs, no trailing
//! whitespace, lines of at most 100 columns, and functions of at most 70 lines. Exits non-zero
//! and lists every violation, so it can gate CI.
const std = @import("std");
const assert = std.debug.assert;

const directories = [_][]const u8{
    "src", "sdk", "guest/runtime", "examples", "workload", "plugins", "tools",
};
const columns_max = 100;
const function_lines_max = 70;
const file_size_max = 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var violations: u32 = 0;
    var files: u32 = 0;
    for (directories) |directory_path| {
        var directory = std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true }) catch {
            continue; // Not every checkout has every directory.
        };
        defer directory.close(io);
        var walker = try directory.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
            const limit: std.Io.Limit = .limited(file_size_max);
            const source = try entry.dir.readFileAlloc(io, entry.basename, gpa, limit);
            defer gpa.free(source);
            files += 1;
            violations += check_file(.{ .directory = directory_path, .path = entry.path }, source);
        }
    }
    std.debug.print("tidy: {d} files, {d} violations\n", .{ files, violations });
    if (violations > 0) std.process.exit(1);
}

const Name = struct { directory: []const u8, path: []const u8 };

fn check_file(name: Name, source: []const u8) u32 {
    assert(name.path.len > 0);
    var violations: u32 = 0;
    if (!std.mem.startsWith(u8, source, "// SPDX-License-Identifier: ")) {
        report(name, 1, "missing SPDX license header");
        violations += 1;
    }
    var function_start: ?u32 = null;
    var function_indent: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_number: u32 = 0;
    while (lines.next()) |line| {
        line_number += 1;
        violations += check_line(name, line_number, line);
        const indent: u32 = @intCast(line.len - std.mem.trimStart(u8, line, " ").len);
        if (function_start == null and is_function_start(line)) {
            function_start = line_number;
            function_indent = indent;
        } else if (function_start) |start| {
            if (indent == function_indent and std.mem.startsWith(u8, line[indent..], "}")) {
                const length = line_number - start + 1;
                if (length > function_lines_max) {
                    report(name, start, "function longer than 70 lines");
                    violations += 1;
                }
                function_start = null;
            }
        }
    }
    return violations;
}

fn check_line(name: Name, line_number: u32, line: []const u8) u32 {
    assert(line_number > 0);
    var violations: u32 = 0;
    if (std.mem.indexOfScalar(u8, line, '\t') != null) {
        report(name, line_number, "tab character");
        violations += 1;
    }
    if (line.len > 0 and line[line.len - 1] == ' ') {
        report(name, line_number, "trailing whitespace");
        violations += 1;
    }
    const columns = std.unicode.utf8CountCodepoints(line) catch line.len;
    if (columns > columns_max) {
        report(name, line_number, "line longer than 100 columns");
        violations += 1;
    }
    return violations;
}

fn is_function_start(line: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (!std.mem.endsWith(u8, line, "{")) return false;
    if (std.mem.startsWith(u8, trimmed, "fn ")) return true;
    if (std.mem.startsWith(u8, trimmed, "pub fn ")) return true;
    return std.mem.startsWith(u8, trimmed, "export fn ");
}

fn report(name: Name, line_number: u32, message: []const u8) void {
    assert(message.len > 0);
    std.debug.print("{s}/{s}:{d}: {s}\n", .{ name.directory, name.path, line_number, message });
}

test is_function_start {
    try std.testing.expect(is_function_start("pub fn main() !void {"));
    try std.testing.expect(is_function_start("    fn helper(a: u32) u32 {"));
    try std.testing.expect(!is_function_start("const x = fn_pointer;"));
}
