// SPDX-License-Identifier: MIT
//! libvoidstar.so: the native library Antithesis gives every container, here talking to
//! determinismo. Antithesis's SDKs use it when /usr/lib/libvoidstar.so exists (nodes with
//! Node.antithesis_library have this one there: Compose projects), and programs built with
//! Antithesis's instrumentation call it:
//!
//!   fuzz_json_data, fuzz_flush   an SDK message (assertions, setup, events): an event
//!   fuzz_get_random              randomness: a platform decision (strategies steer it, tapes
//!                                replay it)
//!   init_coverage_module,        coverage from Antithesis's instrumentors (Go's): each edge, the
//!   notify_coverage              first time the timeline runs it (a bitmap per module in
//!                                /opt/determinismo/coverage, shared by every process of every
//!                                node: test commands start often, nodes restart),
//!                                a "coverage" event, as a source line when the module's symbol
//!                                table (/symbols/<name>) says
//!   __sanitizer_cov_trace_pc_guard[_init]
//!                                clang's trace-pc-guard callbacks (C and C++ built for Antithesis
//!                                link against this library): an "edge <n>" event per edge
//!
//! It runs inside the system's processes, whatever their libc: no libc, system calls only, and
//! it never stops a program (an event that cannot be written is dropped).
const std = @import("std");
const linux = std.os.linux;

const device_path = "/dev/determinismo";
const message_size_max = 4096 - 16; // det_guest's page, less its header.
const symbols_directory = "/symbols/";
const modules_max = 64;
const edges_max = 1 << 24;

var device = std.atomic.Value(i32).init(-1);

fn device_fd() ?linux.fd_t {
    const known = device.load(.acquire);
    if (known >= 0) return known;
    const result = linux.open(device_path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (linux.errno(result) != .SUCCESS) return null;
    const fd: i32 = @intCast(result);
    if (device.cmpxchgStrong(-1, fd, .acq_rel, .acquire)) |other| {
        _ = linux.close(fd); // Another thread opened it first.
        return other;
    }
    return fd;
}

fn emit(message: []const u8) void {
    if (message.len == 0 or message.len > message_size_max) return;
    const fd = device_fd() orelse return;
    _ = linux.write(fd, message.ptr, message.len);
}

export fn fuzz_json_data(data: [*]const u8, size: usize) void {
    emit(data[0..size]);
}

export fn fuzz_flush() void {}

export fn fuzz_get_random() u64 {
    var bytes: [8]u8 = undefined;
    const fd = device_fd() orelse return 0;
    const result = linux.read(fd, &bytes, bytes.len);
    if (linux.errno(result) != .SUCCESS or result != bytes.len) return 0;
    return std.mem.readInt(u64, &bytes, .little);
}

// Antithesis's instrumentors ---------------------------------------------------------------

/// One instrumented module: its edges are numbered from `base` in this process.
const Module = struct {
    base: u64,
    count: u64,
    /// The symbol table, mapped (or empty): tab-separated file, function, begin line, begin
    /// column, end line, end column, edge.
    table: []const u8 = "",
    /// For each edge, where its row starts in `table`, plus one (0: not in the table).
    rows: []u32 = &.{},
    name: [128]u8 = undefined,
    name_size: u8 = 0,
    /// One bit per edge, shared by every process: set once reported (empty: per process).
    reported: []u8 = &.{},
};

var modules: [modules_max]Module = undefined;
var module_count = std.atomic.Value(u32).init(0);
var edges_total: u64 = 0;
var lock = std.atomic.Value(bool).init(false);

export fn init_coverage_module(edge_count: usize, symbols: [*:0]const u8) u64 {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
    defer lock.store(false, .release);
    const count = module_count.load(.acquire);
    if (count == modules_max or edge_count > edges_max) return edges_total;
    const name = std.mem.span(symbols);
    var module = Module{ .base = edges_total, .count = edge_count };
    module.name_size = @intCast(@min(name.len, module.name.len));
    @memcpy(module.name[0..module.name_size], name[0..module.name_size]);
    table_load(&module, name);
    module.reported = bitmap_open(name, edge_count);
    modules[count] = module;
    module_count.store(count + 1, .release);
    edges_total += edge_count;
    return module.base;
}

/// Whether to be called again for this edge: never, once it was reported.
export fn notify_coverage(edge: usize) bool {
    const count = module_count.load(.acquire);
    for (modules[0..count]) |*module| {
        if (edge < module.base or edge >= module.base + module.count) continue;
        edge_report(module, edge - module.base);
        return false;
    }
    return false;
}

fn edge_report(module: *const Module, edge: u64) void {
    if (module.reported.len > 0) {
        const byte = &module.reported[edge / 8];
        const bit: u8 = @as(u8, 1) << @intCast(edge % 8);
        const before = @atomicRmw(u8, byte, .Or, bit, .monotonic);
        if (before & bit != 0) return; // Another process reported it.
    }
    var buffer: [512]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    writer.writeAll("{\"event\":\"coverage\",\"details\":{\"name\":\"") catch return;
    if (row(module, edge)) |fields| {
        writer.writeAll("line ") catch return;
        json_escaped(&writer, fields.file) catch return;
        writer.print(":{s}", .{fields.line}) catch return;
    } else {
        writer.writeAll("edge ") catch return;
        json_escaped(&writer, module.name[0..module.name_size]) catch return;
        writer.print(":{d}", .{edge}) catch return;
    }
    writer.writeAll("\"}}") catch return;
    emit(writer.buffered());
}

const Row = struct { file: []const u8, line: []const u8 };

fn row(module: *const Module, edge: u64) ?Row {
    if (edge >= module.rows.len or module.rows[edge] == 0) return null;
    const start = module.rows[edge] - 1;
    const end = std.mem.indexOfScalarPos(u8, module.table, start, '\n') orelse module.table.len;
    var fields = std.mem.splitScalar(u8, module.table[start..end], '\t');
    const file = fields.next() orelse return null;
    _ = fields.next(); // Function.
    const line = fields.next() orelse return null;
    return .{ .file = file, .line = line };
}

fn json_escaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        if (byte == '"' or byte == '\\') try writer.writeByte('\\');
        if (byte < 0x20) continue;
        try writer.writeByte(byte);
    }
}

/// Maps /symbols/<name> and indexes its rows by edge (the last column).
fn table_load(module: *Module, name: []const u8) void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return;
    var path_buffer: [256]u8 = undefined;
    const format = symbols_directory ++ "{s}";
    const path = std.fmt.bufPrintSentinel(&path_buffer, format, .{name}, 0) catch return;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    const file_end = linux.lseek(@intCast(fd), 0, linux.SEEK.END);
    if (linux.errno(file_end) != .SUCCESS or file_end == 0) return;
    const size: usize = file_end;
    if (size >= std.math.maxInt(u32)) return;
    const table = map(size, @intCast(fd)) orelse return;
    const rows_bytes = map(module.count * @sizeOf(u32), null) orelse return;
    const rows: []u32 = @alignCast(std.mem.bytesAsSlice(u32, rows_bytes));
    var start: usize = 0;
    while (start < table.len) {
        const end = std.mem.indexOfScalarPos(u8, table, start, '\n') orelse table.len;
        const line = table[start..end];
        defer start = end + 1;
        if (line.len == 0 or line[0] == '#') continue;
        const tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse continue;
        const edge = std.fmt.parseInt(u64, line[tab + 1 ..], 10) catch continue; // The header.
        if (edge < rows.len) rows[edge] = @intCast(start + 1);
    }
    module.table = table;
    module.rows = rows;
}

/// The timeline's shared bitmap for a module: /opt/determinismo/coverage/<name>, created by the
/// first process that loads it (empty when it cannot be: each process reports its own edges).
fn bitmap_open(name: []const u8, edge_count: u64) []u8 {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return &.{};
    var path_buffer: [256]u8 = undefined;
    const format = "/opt/determinismo/coverage/{s}";
    const path = std.fmt.bufPrintSentinel(&path_buffer, format, .{name}, 0) catch return &.{};
    const flags: linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true };
    const fd = linux.open(path, flags, 0o666);
    if (linux.errno(fd) != .SUCCESS) return &.{};
    defer _ = linux.close(@intCast(fd));
    const size = std.mem.alignForward(u64, (edge_count + 7) / 8, std.heap.page_size_min);
    if (linux.errno(linux.ftruncate(@intCast(fd), @intCast(size))) != .SUCCESS) return &.{};
    const protection: linux.PROT = .{ .READ = true, .WRITE = true };
    const address = linux.mmap(null, size, protection, .{ .TYPE = .SHARED }, @intCast(fd), 0);
    if (linux.errno(address) != .SUCCESS) return &.{};
    return @as([*]u8, @ptrFromInt(address))[0..size];
}

/// A read-only mapping of `fd`, or zeroed anonymous memory without one.
fn map(size: usize, fd: ?linux.fd_t) ?[]align(std.heap.page_size_min) u8 {
    if (size == 0) return null;
    const writable = fd == null;
    const protection: linux.PROT = .{ .READ = true, .WRITE = writable };
    const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = fd == null };
    const address = linux.mmap(null, size, protection, flags, fd orelse -1, 0);
    if (linux.errno(address) != .SUCCESS) return null;
    return @as([*]align(std.heap.page_size_min) u8, @ptrFromInt(address))[0..size];
}

// clang's trace-pc-guard (C and C++ instrumented for Antithesis) ----------------------------

var guard_next = std.atomic.Value(u32).init(1);

export fn __sanitizer_cov_trace_pc_guard_init(start: [*]u32, stop: [*]u32) void {
    if (start == stop or start[0] != 0) return; // Already numbered.
    const count: u32 = @intCast(stop - start);
    const first = guard_next.fetchAdd(count, .monotonic);
    for (start[0..count], 0..) |*guard, index| guard.* = first + @as(u32, @intCast(index));
}

/// Each edge once (its guard then 0), as the C SDK's.
export fn __sanitizer_cov_trace_pc_guard(guard: *u32) void {
    const edge = @atomicRmw(u32, guard, .Xchg, 0, .monotonic);
    if (edge == 0) return;
    var buffer: [80]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "{{\"event\":\"coverage\",\"details\":{{\"name\":\"edge {d}\"}}}}",
        .{edge},
    ) catch return;
    emit(message);
}
