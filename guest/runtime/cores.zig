// SPDX-License-Identifier: MIT
//! det-core <pid> <command name> <signal>: the kernel's core dump handler (det-init sets
//! core_pattern to it). It keeps the core of a crashed process, from any node, in
//! /run/det/cores/<node>-<command>-<pid>.core and emits a `core_dump` event naming it, so that
//! `determinismo extract --file runner:<path>` takes it out at any later moment of the timeline,
//! for gdb and the like. A core past cores_size_max keeps its notes (registers, mappings) and
//! its smallest memory segments, the largest left out (their headers kept, with no bytes): the
//! stacks stay, which a plain cut would lose (they come last), so gdb still unwinds the threads
//! of a process with gigabytes of heap.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const sdk = @import("determinismo");

const cores_directory = "/run/det/cores";
const cores_size_max = 256 * 1024 * 1024;
const name_size_max = 64;
const headers_size_max = 1024 * 1024;
const page_size = 4096;
const elf_header_size = 64;
const program_header_size = 56;
const pt_load = 1;

pub fn main(init: std.process.Init) !u8 {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 4) return 2;
    const pid = std.fmt.parseInt(linux.pid_t, arguments[1], 10) catch return 2;
    const signal = std.fmt.parseInt(u32, arguments[3], 10) catch return 2;
    var command_buffer: [name_size_max]u8 = undefined;
    const command = sanitized(&command_buffer, arguments[2]);
    var node_buffer: [name_size_max]u8 = undefined;
    const node = node_of(pid, &node_buffer);
    var path_buffer: [256]u8 = undefined;
    const format = cores_directory ++ "/{s}-{s}-{d}.core";
    const path = try std.fmt.bufPrintSentinel(&path_buffer, format, .{ node, command, pid }, 0);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o600);
    if (linux.errno(fd) != .SUCCESS) return 1;
    defer _ = linux.close(@intCast(fd));
    var input: Input = .{ .fd = 0 };
    const kept = core_copy(&input, @intCast(fd), init.arena.allocator(), cores_size_max);
    // The whole dump is read, so that the kernel finishes it.
    while (input.fill()) input.start = input.end;
    const size = kept.size;
    const dropped = input.position - kept.read_kept;
    sdk.event("core_dump", .{
        .node = node,
        .pid = pid,
        .command = command,
        .signal = signal,
        .path = path,
        .size = size,
        .dropped = dropped,
    });
    return 0;
}

/// The kernel's dump, read once, in order.
const Input = struct {
    fd: linux.fd_t,
    buffer: [64 * 1024]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    /// Bytes of the dump consumed so far.
    position: u64 = 0,

    /// More bytes, if the dump has any.
    fn fill(input: *Input) bool {
        if (input.start < input.end) return true;
        const read = linux.read(input.fd, &input.buffer, input.buffer.len);
        if (linux.errno(read) != .SUCCESS or read == 0) return false;
        input.start = 0;
        input.end = read;
        return true;
    }

    /// The next bytes, up to `size_max` of them; empty at the dump's end.
    fn take(input: *Input, size_max: u64) []const u8 {
        if (!input.fill()) return &.{};
        const size: usize = @intCast(@min(size_max, input.end - input.start));
        const bytes = input.buffer[input.start..][0..size];
        input.start += size;
        input.position += size;
        return bytes;
    }
};

const Kept = struct { size: u64, read_kept: u64 };

/// Copies the dump: whole when it fits in `budget`, else its headers and notes and the
/// segments `plan` keeps, each at its new place.
fn core_copy(input: *Input, fd: linux.fd_t, arena: std.mem.Allocator, budget: u64) Kept {
    // The headers first: the ELF header and its program headers, which follow it.
    const headers = arena.alloc(u8, headers_size_max) catch return copy_rest(input, fd, &.{}, 0, budget);
    var headers_size: usize = 0;
    while (headers_size < elf_header_size) {
        const bytes = input.take(elf_header_size - headers_size);
        if (bytes.len == 0) break;
        @memcpy(headers[headers_size..][0..bytes.len], bytes);
        headers_size += bytes.len;
    }
    const program_headers_end = program_headers_end_of(headers[0..headers_size]) orelse
        return copy_rest(input, fd, headers[0..headers_size], 0, budget);
    while (headers_size < program_headers_end) {
        const bytes = input.take(program_headers_end - headers_size);
        if (bytes.len == 0) return copy_rest(input, fd, headers[0..headers_size], 0, budget);
        @memcpy(headers[headers_size..][0..bytes.len], bytes);
        headers_size += bytes.len;
    }
    const segments = segments_read(arena, headers[0..program_headers_end]) orelse
        return copy_rest(input, fd, headers[0..headers_size], 0, budget);
    const placed = plan(arena, segments, program_headers_end, budget) orelse
        return copy_rest(input, fd, headers[0..headers_size], 0, budget);
    // The program headers as kept: each segment at its new offset, or with no bytes.
    for (segments, placed, 0..) |segment, place, index| {
        const header = headers[elf_header_size + index * program_header_size ..][0..program_header_size];
        if (segment.kind != pt_load) continue;
        std.mem.writeInt(u64, header[8..16], place.offset, .little);
        std.mem.writeInt(u64, header[32..40], if (place.kept) segment.file_size else 0, .little);
    }
    if (!write_all(fd, headers[0..program_headers_end])) return .{ .size = 0, .read_kept = 0 };
    var size: u64 = program_headers_end;
    var read_kept: u64 = program_headers_end;
    // Then the dump in order: the bytes of kept segments (and notes) copied, the rest read past.
    for (segments, placed) |segment, place| {
        if (segment.file_size == 0) continue;
        while (input.position < segment.offset) {
            if (input.take(segment.offset - input.position).len == 0) return .{ .size = size, .read_kept = read_kept };
        }
        var at = place.offset;
        var left = segment.file_size;
        while (left > 0) {
            const bytes = input.take(left);
            if (bytes.len == 0) return .{ .size = size, .read_kept = read_kept };
            left -= bytes.len;
            if (!place.kept) continue;
            if (!pwrite_all(fd, bytes, at)) return .{ .size = size, .read_kept = read_kept };
            at += bytes.len;
            read_kept += bytes.len;
            size = @max(size, at);
        }
    }
    return .{ .size = size, .read_kept = read_kept };
}

/// Without headers it understands: the dump as it comes, up to `budget`.
fn copy_rest(input: *Input, fd: linux.fd_t, already: []const u8, size_start: u64, budget: u64) Kept {
    var size = size_start;
    const first = @min(already.len, budget);
    if (!write_all(fd, already[0..first])) return .{ .size = size, .read_kept = size };
    size += first;
    while (size < budget) {
        const bytes = input.take(budget - size);
        if (bytes.len == 0) break;
        if (!write_all(fd, bytes)) break;
        size += bytes.len;
    }
    return .{ .size = size, .read_kept = size };
}

/// Where a 64-bit little-endian core's program headers end (they follow the ELF header).
fn program_headers_end_of(header: []const u8) ?usize {
    if (header.len < elf_header_size) return null;
    if (!std.mem.eql(u8, header[0..4], "\x7fELF") or header[4] != 2 or header[5] != 1) return null;
    if (std.mem.readInt(u16, header[16..18], .little) != 4) return null; // ET_CORE
    const offset = std.mem.readInt(u64, header[32..40], .little);
    const entry_size = std.mem.readInt(u16, header[54..56], .little);
    const count = std.mem.readInt(u16, header[56..58], .little);
    if (offset != elf_header_size or entry_size != program_header_size) return null;
    if (count == 0 or count == 0xffff) return null; // 0xffff: the count is elsewhere (PN_XNUM).
    const end = elf_header_size + @as(usize, count) * program_header_size;
    if (end > headers_size_max) return null;
    return end;
}

const Segment = struct { kind: u32, offset: u64, file_size: u64 };

/// The segments, in the dump's order (offsets ascending, after the headers), else null.
fn segments_read(arena: std.mem.Allocator, headers: []const u8) ?[]const Segment {
    const count = (headers.len - elf_header_size) / program_header_size;
    const segments = arena.alloc(Segment, count) catch return null;
    var end: u64 = headers.len;
    for (segments, 0..) |*segment, index| {
        const header = headers[elf_header_size + index * program_header_size ..][0..program_header_size];
        segment.* = .{
            .kind = std.mem.readInt(u32, header[0..4], .little),
            .offset = std.mem.readInt(u64, header[8..16], .little),
            .file_size = std.mem.readInt(u64, header[32..40], .little),
        };
        if (segment.file_size == 0) continue;
        if (segment.offset < end) return null;
        end = segment.offset + segment.file_size;
    }
    return segments;
}

const Place = struct { kept: bool, offset: u64 };

/// Which segments a core of at most `budget` bytes keeps, and where: all of them at their own
/// offsets when the dump fits; else notes and other non-memory segments, then the smallest
/// memory segments while they fit, each at the next page boundary.
fn plan(arena: std.mem.Allocator, segments: []const Segment, headers_end: u64, budget: u64) ?[]Place {
    var dump_end: u64 = headers_end;
    for (segments) |segment| dump_end = @max(dump_end, segment.offset + segment.file_size);
    const places = arena.alloc(Place, segments.len) catch return null;
    if (dump_end <= budget) {
        for (segments, places) |segment, *place| place.* = .{ .kept = true, .offset = segment.offset };
        return places;
    }
    // What must stay: the headers, and every segment that is not memory (the notes).
    var used: u64 = headers_end;
    for (segments, places) |segment, *place| {
        place.* = .{ .kept = segment.kind != pt_load, .offset = 0 };
        if (place.kept and segment.file_size > 0) used = @max(used, segment.offset + segment.file_size);
    }
    if (used > budget) return null;
    // Memory, smallest first, while it fits (pages rounded up).
    const order = arena.alloc(u32, segments.len) catch return null;
    for (order, 0..) |*position, index| position.* = @intCast(index);
    std.mem.sort(u32, order, segments, struct {
        fn less(context: []const Segment, a: u32, b: u32) bool {
            return context[a].file_size < context[b].file_size;
        }
    }.less);
    for (order) |index| {
        const segment = segments[index];
        if (segment.kind != pt_load or segment.file_size == 0) continue;
        const cost = std.mem.alignForward(u64, segment.file_size, page_size);
        if (used + cost > budget) break;
        used += cost;
        places[index].kept = true;
    }
    // Their new offsets, in the dump's order.
    var at = std.mem.alignForward(u64, headers_end, page_size);
    for (segments, places) |segment, *place| {
        if (segment.kind != pt_load) {
            place.offset = segment.offset;
            if (segment.file_size > 0) at = @max(at, std.mem.alignForward(u64, segment.offset + segment.file_size, page_size));
            continue;
        }
        if (!place.kept or segment.file_size == 0) continue;
        place.offset = at;
        at = std.mem.alignForward(u64, at + segment.file_size, page_size);
    }
    return places;
}

fn pwrite_all(fd: linux.fd_t, bytes: []const u8, offset: u64) bool {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.pwrite(fd, bytes[written..].ptr, bytes.len - written, @intCast(offset + written));
        if (linux.errno(result) != .SUCCESS) return false;
        written += result;
    }
    return true;
}

/// The node whose cgroup holds the process (/proc/<pid>/cgroup: "0::/nodes/<node>/..."), else
/// "runner".
fn node_of(pid: linux.pid_t, buffer: *[name_size_max]u8) []const u8 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/cgroup", .{pid}, 0) catch
        return "runner";
    var text_buffer: [512]u8 = undefined;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return "runner";
    defer _ = linux.close(@intCast(fd));
    const read = linux.read(@intCast(fd), &text_buffer, text_buffer.len);
    if (linux.errno(read) != .SUCCESS) return "runner";
    return node_from_cgroup(text_buffer[0..read], buffer);
}

fn node_from_cgroup(text: []const u8, buffer: *[name_size_max]u8) []const u8 {
    const prefix = "0::/nodes/";
    const at = std.mem.indexOf(u8, text, prefix) orelse return "runner";
    const rest = text[at + prefix.len ..];
    const end = std.mem.indexOfAny(u8, rest, "/\n") orelse rest.len;
    if (end == 0) return "runner";
    return sanitized(buffer, rest[0..end]);
}

/// Letters, digits, '.', '_' and '-' kept, anything else '_': a file name piece.
fn sanitized(buffer: *[name_size_max]u8, text: []const u8) []const u8 {
    const size = @min(text.len, buffer.len);
    for (text[0..size], buffer[0..size]) |byte, *out| {
        const keep = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
        out.* = if (keep) byte else '_';
    }
    return buffer[0..size];
}

fn write_all(fd: linux.fd_t, bytes: []const u8) bool {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) != .SUCCESS) return false;
        written += result;
    }
    return true;
}

test plan {
    const segments = [_]Segment{
        .{ .kind = 4, .offset = 64 + 4 * 56, .file_size = 3000 }, // Notes.
        .{ .kind = pt_load, .offset = 4096, .file_size = 8192 }, // Small data.
        .{ .kind = pt_load, .offset = 12288, .file_size = 1 << 30 }, // A gigabyte of heap.
        .{ .kind = pt_load, .offset = (1 << 30) + 12288, .file_size = 135168 }, // The stack.
    };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fits = plan(arena, &segments, 64 + 4 * 56, 2 << 30).?;
    for (segments, fits) |segment, place| {
        try std.testing.expect(place.kept);
        try std.testing.expectEqual(segment.offset, place.offset);
    }
    const cut = plan(arena, &segments, 64 + 4 * 56, 1 << 20).?;
    try std.testing.expect(cut[0].kept and cut[1].kept and !cut[2].kept and cut[3].kept);
    try std.testing.expectEqual(4096, cut[1].offset);
    try std.testing.expectEqual(12288, cut[3].offset); // Right after the data, the heap left out.
    // Notes alone past the budget: no plan (the dump is cut as it comes).
    try std.testing.expectEqual(null, plan(arena, &segments, 64 + 4 * 56, 1000));
}

test "core_copy: past the budget, the notes, data and stack stay where the headers say" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A core: ELF header, four program headers (notes, data, heap, stack), then their bytes.
    const heap_size = 1 << 20;
    const headers_end = elf_header_size + 4 * program_header_size;
    const segments = [_]Segment{
        .{ .kind = 4, .offset = headers_end, .file_size = 100 },
        .{ .kind = pt_load, .offset = 4096, .file_size = 4096 },
        .{ .kind = pt_load, .offset = 8192, .file_size = heap_size },
        .{ .kind = pt_load, .offset = 8192 + heap_size, .file_size = 8192 },
    };
    const dump = try arena.alloc(u8, 8192 + heap_size + 8192);
    @memset(dump, 0);
    @memcpy(dump[0..4], "\x7fELF");
    dump[4] = 2;
    dump[5] = 1;
    std.mem.writeInt(u16, dump[16..18], 4, .little);
    std.mem.writeInt(u64, dump[32..40], elf_header_size, .little);
    std.mem.writeInt(u16, dump[54..56], program_header_size, .little);
    std.mem.writeInt(u16, dump[56..58], segments.len, .little);
    for (segments, 0..) |segment, index| {
        const header = dump[elf_header_size + index * program_header_size ..][0..program_header_size];
        std.mem.writeInt(u32, header[0..4], segment.kind, .little);
        std.mem.writeInt(u64, header[8..16], segment.offset, .little);
        std.mem.writeInt(u64, header[32..40], segment.file_size, .little);
        @memset(dump[segment.offset..][0..segment.file_size], @intCast(index + 1));
    }
    // Through a pipe, as the kernel gives it, from a thread (the pipe holds less than the dump).
    var pipe: [2]i32 = undefined;
    try std.testing.expectEqual(0, linux.pipe2(&pipe, .{ .CLOEXEC = true }));
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(fd: i32, bytes: []const u8) void {
            _ = write_all(fd, bytes);
            _ = linux.close(fd);
        }
    }.run, .{ pipe[1], dump });
    const out: linux.fd_t = @intCast(linux.memfd_create("core", 0));
    defer _ = linux.close(out);
    var input: Input = .{ .fd = pipe[0] };
    const kept = core_copy(&input, out, arena, 64 * 1024);
    while (input.fill()) input.start = input.end;
    writer.join();
    _ = linux.close(pipe[0]);
    try std.testing.expectEqual(dump.len, input.position);
    try std.testing.expect(kept.size <= 64 * 1024);
    // The headers as written, and each segment's bytes where they say.
    var copy: [64 * 1024]u8 = @splat(0);
    _ = linux.pread(out, &copy, copy.len, 0);
    for (0..segments.len) |index| {
        const header = copy[elf_header_size + index * program_header_size ..][0..program_header_size];
        const offset = std.mem.readInt(u64, header[8..16], .little);
        const file_size = std.mem.readInt(u64, header[32..40], .little);
        if (index == 2) {
            try std.testing.expectEqual(0, file_size); // The heap left out.
            continue;
        }
        try std.testing.expectEqual(segments[index].file_size, file_size);
        try std.testing.expect(std.mem.allEqual(u8, copy[offset..][0..file_size], @intCast(index + 1)));
    }
}

test node_from_cgroup {
    var buffer: [name_size_max]u8 = undefined;
    try std.testing.expectEqualStrings("redis", node_from_cgroup("0::/nodes/redis\n", &buffer));
    const pod = "0::/nodes/k3s-agent/kubepods/burstable/pod1\n";
    try std.testing.expectEqualStrings("k3s-agent", node_from_cgroup(pod, &buffer));
    try std.testing.expectEqualStrings("runner", node_from_cgroup("0::/\n", &buffer));
    try std.testing.expectEqualStrings("a_b", sanitized(&buffer, "a/b"));
}
