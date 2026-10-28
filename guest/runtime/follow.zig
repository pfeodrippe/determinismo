// SPDX-License-Identifier: MIT
//! Files that grow by appends, followed as events (det-podlogs, det-sinks): what was appended
//! since the last look is read from where the last look stopped, its lines sent as each file's
//! kind says, the bytes after its last newline kept for the next look. A file that shrank
//! (truncated, rotated in place) is read again from its start.
const std = @import("std");
const linux = std.os.linux;
const output = @import("output.zig");

pub const path_size_max = 512;
const source_size_max = 128;
const name_size_max = 64;
/// A line longer than this is sent as it is, in parts.
const partial_size_max = 4096;

pub const Kind = enum {
    /// Kubelet's container logs: `<time> stdout|stderr F|P <text>`, the text an output line.
    cri,
    /// JSON lines (Antithesis's `.jsonl` sinks): each line an event as it is.
    jsonl,
    /// Anything else written to a sink: each line an output line, under the file's name.
    text,
    /// `.bin` sinks: what was written, base64-encoded, under the file's name.
    bin,

    /// Antithesis's sink rule (ANTITHESIS_OUTPUT_DIR): by the file's name.
    pub fn of_sink(name: []const u8) Kind {
        if (std.mem.endsWith(u8, name, ".jsonl")) return .jsonl;
        if (std.mem.endsWith(u8, name, ".bin")) return .bin;
        return .text;
    }
};

pub const File = struct {
    path_buffer: [path_size_max]u8 = undefined,
    path_size: usize = 0,
    /// Its events' source (a pod's name, a node's).
    source_buffer: [source_size_max]u8 = undefined,
    source_size: usize = 0,
    /// Its name, the output lines' stream for text and bin files.
    name_buffer: [name_size_max]u8 = undefined,
    name_size: usize = 0,
    kind: Kind = .text,
    offset: u64 = 0,
    rest: [partial_size_max]u8 = undefined,
    rest_size: usize = 0,

    pub fn init(file: *File, file_path: []const u8, events_source: []const u8, kind: Kind) !void {
        if (file_path.len >= path_size_max or events_source.len > source_size_max) return error.TooLong;
        file.* = .{ .kind = kind };
        @memcpy(file.path_buffer[0..file_path.len], file_path);
        file.path_buffer[file_path.len] = 0;
        file.path_size = file_path.len;
        @memcpy(file.source_buffer[0..events_source.len], events_source);
        file.source_size = events_source.len;
        const base = std.fs.path.basename(file_path);
        const name_size = @min(base.len, name_size_max);
        @memcpy(file.name_buffer[0..name_size], base[0..name_size]);
        file.name_size = name_size;
    }

    pub fn path(file: *const File) [:0]const u8 {
        return file.path_buffer[0..file.path_size :0];
    }

    fn source(file: *const File) []const u8 {
        return file.source_buffer[0..file.source_size];
    }

    fn name(file: *const File) []const u8 {
        return file.name_buffer[0..file.name_size];
    }

    /// What was appended since the last look, sent to the platform's device.
    pub fn follow(file: *File, device: linux.fd_t) void {
        const opened = linux.open(file.path(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) return;
        const fd: linux.fd_t = @intCast(opened);
        defer _ = linux.close(fd);
        var stat: linux.Statx = undefined;
        if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &stat)) != .SUCCESS) return;
        if (stat.size < file.offset) {
            file.offset = 0;
            file.rest_size = 0;
        }
        var batch: output.Batch = .{ .source = file.source(), .device = device };
        defer batch.flush();
        var buffer: [3072]u8 = undefined; // A multiple of 3: whole base64 groups.
        while (file.offset < stat.size) {
            const result = linux.pread(fd, &buffer, buffer.len, @intCast(file.offset));
            if (linux.errno(result) != .SUCCESS or result == 0) return;
            file.offset += result;
            if (file.kind == .bin) {
                var encoded: [4096]u8 = undefined;
                batch.line(file.name(), std.base64.standard.Encoder.encode(&encoded, buffer[0..result]));
                continue;
            }
            file.lines(&batch, buffer[0..result]);
        }
    }

    fn lines(file: *File, batch: *output.Batch, bytes: []const u8) void {
        for (bytes) |byte| {
            if (byte == '\n' or file.rest_size == file.rest.len) {
                file.send(batch, file.rest[0..file.rest_size]);
                file.rest_size = 0;
                if (byte == '\n') continue;
            }
            file.rest[file.rest_size] = byte;
            file.rest_size += 1;
        }
    }

    fn send(file: *const File, batch: *output.Batch, line: []const u8) void {
        switch (file.kind) {
            .cri => if (cri_parse(line)) |parsed| batch.line(parsed.stream, parsed.text),
            .jsonl => if (line.len > 0 and line[0] == '{') batch.raw(line),
            .text => batch.line(file.name(), line),
            .bin => unreachable,
        }
    }
};

const Cri = struct { stream: []const u8, text: []const u8 };

/// One CRI line: "<time> <stream> <tag> <text>".
fn cri_parse(line: []const u8) ?Cri {
    var fields = std.mem.splitScalar(u8, line, ' ');
    _ = fields.next() orelse return null; // The time.
    const stream = fields.next() orelse return null;
    if (!std.mem.eql(u8, stream, "stdout") and !std.mem.eql(u8, stream, "stderr")) return null;
    _ = fields.next() orelse return null; // F (a whole line) or P (part of one).
    return .{ .stream = stream, .text = fields.rest() };
}

/// A directory's entries, but . and ..; with their types.
pub const Entries = struct {
    fd: ?linux.fd_t,
    buffer: [8192]u8 align(8) = undefined,
    size: usize = 0,
    at: usize = 0,

    pub const Entry = struct { name: []const u8, directory: bool };

    pub fn of(path: []const u8) Entries {
        var path_buffer: [path_size_max]u8 = undefined;
        const path_z = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{path}, 0) catch return .{ .fd = null };
        const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
        const result = linux.open(path_z, flags, 0);
        if (linux.errno(result) != .SUCCESS) return .{ .fd = null };
        return .{ .fd = @intCast(result) };
    }

    pub fn next(entries: *Entries) ?Entry {
        const fd = entries.fd orelse return null;
        while (true) {
            if (entries.at >= entries.size) {
                const size = linux.getdents64(fd, &entries.buffer, entries.buffer.len);
                if (linux.errno(size) != .SUCCESS or size == 0) {
                    _ = linux.close(fd);
                    entries.fd = null;
                    return null;
                }
                entries.size = size;
                entries.at = 0;
            }
            const entry: *align(1) const linux.dirent64 = @ptrCast(&entries.buffer[entries.at]);
            entries.at += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .directory = entry.type == linux.DT.DIR };
        }
    }
};

test cri_parse {
    const parsed = cri_parse("2026-01-01T00:00:01.5Z stdout F Ready to accept connections tcp").?;
    try std.testing.expectEqualStrings("stdout", parsed.stream);
    try std.testing.expectEqualStrings("Ready to accept connections tcp", parsed.text);
    try std.testing.expectEqualStrings("panic: x", cri_parse("t stderr F panic: x").?.text);
    try std.testing.expectEqual(@as(?Cri, null), cri_parse("t other F x"));
}

test "Kind.of_sink" {
    try std.testing.expectEqual(Kind.jsonl, Kind.of_sink("sdk.jsonl"));
    try std.testing.expectEqual(Kind.bin, Kind.of_sink("dump.bin"));
    try std.testing.expectEqual(Kind.text, Kind.of_sink("debug.log"));
}
