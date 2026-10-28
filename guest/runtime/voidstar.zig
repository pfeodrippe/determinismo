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
//!                                clang's trace-pc-guard callbacks (C, C++ and Rust built for
//!                                Antithesis link against this library): each edge's source line
//!                                ("line <file>:<n>") when the image's /symbols has the module's
//!                                DWARF (a table the host made: src/lines.zig), else "edge <n>"
//!
//! It runs inside the system's processes, whatever their libc: no libc, system calls only, and
//! it never stops a program (an event that cannot be written is dropped).
const std = @import("std");
const linux = std.os.linux;

/// No thread-local state may exist here: in a library others load, the compiler's local-exec
/// model would put it in the host program's own thread data (glibc's malloc, Go's runtime).
/// The default panic handler has some; this one has none (a panic traps).
pub const panic = std.debug.no_panic;

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

/// Each edge once (its guard then 0), as the C SDK's: as the source line its call is on, when
/// known.
export fn __sanitizer_cov_trace_pc_guard(guard: *u32) void {
    const edge = @atomicRmw(u32, guard, .Xchg, 0, .monotonic);
    if (edge == 0) return;
    if (native_place(@returnAddress())) |place| {
        var line_buffer: [512]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&line_buffer);
        writer.writeAll("{\"event\":\"coverage\",\"details\":{\"name\":\"line ") catch return;
        json_escaped(&writer, place.file) catch return;
        writer.print(":{d}\"}}}}", .{place.line}) catch return;
        emit(writer.buffered());
        return;
    }
    var buffer: [80]u8 = undefined;
    const message = std.fmt.bufPrint(
        &buffer,
        "{{\"event\":\"coverage\",\"details\":{{\"name\":\"edge {d}\"}}}}",
        .{edge},
    ) catch return;
    emit(message);
}

// Source lines of native modules (trace-pc-guard) ---------------------------------------------

/// A table's format: src/lines.zig's.
const lines_magic = "DETLINES";
const lines_directory = "/symbols/.determinismo/";
const LinesRow = extern struct { address: u64, line: u32, file: u32 };
const natives_max = 256;

/// One mapped file of the process (or an anonymous range: no table), and its table of lines.
const Native = struct {
    low: usize,
    high: usize,
    /// Its load address less its ELF addresses: the table's address of a code address.
    bias: usize = 0,
    rows: []align(1) const LinesRow = &.{},
    strings: []const u8 = "",

    fn place(native: *const Native, pc: usize) ?Place {
        if (native.rows.len == 0 or pc <= native.bias) return null;
        const address: u64 = pc - native.bias - 1; // The call, not the return address.
        var low: usize = 0;
        var high: usize = native.rows.len;
        while (low < high) { // The last row at or before the address.
            const middle = low + (high - low) / 2;
            if (native.rows[middle].address <= address) low = middle + 1 else high = middle;
        }
        if (low == 0) return null;
        const found = native.rows[low - 1];
        if (found.line == 0) return null; // Past a sequence's end: no line.
        if (found.file >= native.strings.len) return null;
        const file = std.mem.sliceTo(native.strings[found.file..], 0);
        return .{ .file = file, .line = found.line };
    }
};

const Place = struct { file: []const u8, line: u32 };

var natives: [natives_max]Native = undefined;
var native_count = std.atomic.Value(u32).init(0);
var natives_lock = std.atomic.Value(bool).init(false);

/// The source line of a code address, if its module has a table.
fn native_place(pc: usize) ?Place {
    if (find_native(native_count.load(.acquire), pc)) |native| return native.place(pc);
    // A module not seen yet: one thread reads the process's maps. A lock held too long (by a
    // thread a fork left behind) is not waited for: the edge stays a number.
    var spins: u32 = 0;
    while (natives_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        spins += 1;
        if (spins == 1 << 22) return null;
        std.atomic.spinLoopHint();
    }
    defer natives_lock.store(false, .release);
    const count = native_count.load(.acquire);
    if (find_native(count, pc)) |native| return native.place(pc);
    if (count == natives_max) return null;
    natives[count] = native_load(pc) orelse return null;
    native_count.store(count + 1, .release);
    return natives[count].place(pc);
}

fn find_native(count: u32, pc: usize) ?*const Native {
    for (natives[0..count]) |*native| {
        if (pc >= native.low and pc < native.high) return native;
    }
    return null;
}

/// The mapped file holding `pc`: its range, load bias and table (none for an anonymous range).
fn native_load(pc: usize) ?Native {
    var path_buffer: [256]u8 = undefined;
    var path: []const u8 = "";
    var native: Native = .{ .low = 0, .high = 0 };
    var maps = Maps.open() orelse return null;
    while (maps.next()) |mapping| {
        if (pc < mapping.start or pc >= mapping.end) continue;
        native = .{ .low = mapping.start, .high = mapping.end };
        if (mapping.path.len == 0 or mapping.path[0] != '/' or mapping.path.len > path_buffer.len) break;
        @memcpy(path_buffer[0..mapping.path.len], mapping.path);
        path = path_buffer[0..mapping.path.len];
        break;
    }
    maps.close();
    if (native.high == 0) return null;
    if (path.len == 0) return native; // Anonymous (JIT) code: remembered, so not looked up again.
    // All of the file's mappings, and the one with its start (its ELF header).
    var header: ?usize = null;
    maps = Maps.open() orelse return native;
    while (maps.next()) |mapping| {
        if (!std.mem.eql(u8, mapping.path, path)) continue;
        native.low = @min(native.low, mapping.start);
        native.high = @max(native.high, mapping.end);
        if (mapping.offset == 0 and header == null) header = mapping.start;
    }
    maps.close();
    const start = header orelse return native;
    const elf = elf_of(start, native) orelse return native;
    native.bias = elf.bias;
    var name_buffer: [128]u8 = undefined;
    const name = if (elf.build_id.len > 0 and elf.build_id.len * 2 <= name_buffer.len)
        std.fmt.bufPrint(&name_buffer, "{x}", .{elf.build_id}) catch return native
    else
        std.fmt.bufPrint(&name_buffer, "name-{s}", .{std.fs.path.basename(path)}) catch return native;
    lines_table_load(&native, name);
    return native;
}

const Elf = struct { bias: usize, build_id: []const u8 };

/// The ELF header at `start` (a module's first mapping): its load bias and GNU build ID.
fn elf_of(start: usize, native: Native) ?Elf {
    const header_size = @sizeOf(std.elf.Elf64_Ehdr);
    if (start + header_size > native.high) return null;
    const bytes: [*]const u8 = @ptrFromInt(start);
    if (!std.mem.eql(u8, bytes[0..4], std.elf.MAGIC)) return null;
    if (bytes[std.elf.EI.CLASS] != std.elf.ELFCLASS64) return null;
    const header = std.mem.bytesToValue(std.elf.Elf64_Ehdr, bytes[0..header_size]);
    const entry_size = @sizeOf(std.elf.Elf64.Phdr);
    const headers_end = start + header.e_phoff + header.e_phnum * entry_size;
    if (header.e_phentsize != entry_size or headers_end > native.high) return null;
    var bias: usize = 0;
    if (header.e_type == .DYN) {
        // A position-independent module: loaded where its first segment's page landed.
        var lowest: u64 = std.math.maxInt(u64);
        for (0..header.e_phnum) |index| {
            const at = start + header.e_phoff + index * entry_size;
            const segment = std.mem.bytesToValue(std.elf.Elf64.Phdr, @as([*]const u8, @ptrFromInt(at))[0..entry_size]);
            if (segment.type == .LOAD) lowest = @min(lowest, segment.vaddr);
        }
        if (lowest == std.math.maxInt(u64)) return null;
        bias = start -% std.mem.alignBackward(u64, lowest, std.heap.page_size_min);
    }
    var build_id: []const u8 = "";
    for (0..header.e_phnum) |index| {
        const at = start + header.e_phoff + index * entry_size;
        const segment = std.mem.bytesToValue(std.elf.Elf64.Phdr, @as([*]const u8, @ptrFromInt(at))[0..entry_size]);
        if (segment.type != .NOTE) continue;
        const notes_start = bias +% segment.vaddr;
        if (notes_start < native.low or notes_start + segment.filesz > native.high) continue;
        const notes = @as([*]const u8, @ptrFromInt(notes_start))[0..segment.filesz];
        if (note_build_id(notes)) |id| {
            build_id = id;
            break;
        }
    }
    return .{ .bias = bias, .build_id = build_id };
}

/// NT_GNU_BUILD_ID's bytes among notes (src/lines.zig's note_build_id).
fn note_build_id(notes: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (at + 12 <= notes.len) {
        const name_size = std.mem.readInt(u32, notes[at..][0..4], .little);
        const description_size = std.mem.readInt(u32, notes[at + 4 ..][0..4], .little);
        const kind = std.mem.readInt(u32, notes[at + 8 ..][0..4], .little);
        const name_start = at + 12;
        const description_start = name_start + std.mem.alignForward(usize, name_size, 4);
        if (description_start + description_size > notes.len) return null;
        if (kind == std.elf.NT_GNU_BUILD_ID and std.mem.eql(u8, notes[name_start..][0..name_size], "GNU\x00")) {
            return notes[description_start..][0..description_size];
        }
        at = description_start + std.mem.alignForward(usize, description_size, 4);
    }
    return null;
}

/// Maps the module's table of lines, if the image has one.
fn lines_table_load(native: *Native, name: []const u8) void {
    var path_buffer: [256]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, lines_directory ++ "{s}", .{name}, 0) catch return;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    defer _ = linux.close(@intCast(fd));
    const file_end = linux.lseek(@intCast(fd), 0, linux.SEEK.END);
    if (linux.errno(file_end) != .SUCCESS) return;
    const size: usize = file_end;
    const head = lines_magic.len + 8;
    if (size < head) return;
    const table = map(size, @intCast(fd)) orelse return;
    if (!std.mem.eql(u8, table[0..lines_magic.len], lines_magic)) return;
    const count = std.mem.readInt(u64, table[lines_magic.len..][0..8], .little);
    if (count > (size - head) / @sizeOf(LinesRow)) return;
    const rows_end = head + count * @sizeOf(LinesRow);
    native.rows = std.mem.bytesAsSlice(LinesRow, table[head..rows_end]);
    native.strings = table[rows_end..];
}

/// The process's mappings (/proc/self/maps), one at a time: a mapping's path is valid until
/// the next.
const Maps = struct {
    fd: linux.fd_t,
    buffer: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    const Mapping = struct { start: usize, end: usize, offset: u64, path: []const u8 };

    fn open() ?Maps {
        const fd = linux.open("/proc/self/maps", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return null;
        return .{ .fd = @intCast(fd) };
    }

    fn close(maps: *Maps) void {
        _ = linux.close(maps.fd);
    }

    fn next(maps: *Maps) ?Mapping {
        while (true) {
            if (std.mem.indexOfScalar(u8, maps.buffer[maps.start..maps.end], '\n')) |size| {
                const line = maps.buffer[maps.start..][0..size];
                maps.start += size + 1;
                if (parse(line)) |mapping| return mapping;
                continue;
            }
            const rest = maps.end - maps.start;
            std.mem.copyForwards(u8, maps.buffer[0..rest], maps.buffer[maps.start..maps.end]);
            maps.start = 0;
            maps.end = if (rest == maps.buffer.len) 0 else rest; // A line too long: dropped.
            const result = linux.read(maps.fd, maps.buffer[maps.end..].ptr, maps.buffer.len - maps.end);
            if (linux.errno(result) != .SUCCESS or result == 0) return null;
            maps.end += result;
        }
    }

    /// "start-end perms offset device inode   path".
    fn parse(line: []const u8) ?Mapping {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const range = fields.next() orelse return null;
        _ = fields.next() orelse return null; // Permissions.
        const offset_text = fields.next() orelse return null;
        _ = fields.next() orelse return null; // Device.
        _ = fields.next() orelse return null; // Inode.
        const path = std.mem.trim(u8, fields.rest(), " ");
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse return null;
        return .{
            .start = std.fmt.parseInt(usize, range[0..dash], 16) catch return null,
            .end = std.fmt.parseInt(usize, range[dash + 1 ..], 16) catch return null,
            .offset = std.fmt.parseInt(u64, offset_text, 16) catch return null,
            .path = path,
        };
    }
};

test "Maps.parse" {
    const mapping = Maps.parse("7f0000001000-7f0000003000 r-xp 00001000 08:01 1234   /usr/lib/x.so").?;
    try std.testing.expectEqual(@as(usize, 0x7f0000001000), mapping.start);
    try std.testing.expectEqual(@as(u64, 0x1000), mapping.offset);
    try std.testing.expectEqualStrings("/usr/lib/x.so", mapping.path);
    try std.testing.expectEqualStrings("", Maps.parse("7f0000001000-7f0000003000 rw-p 00000000 00:00 0").?.path);
}

test "Native.place" {
    const rows = [_]LinesRow{
        .{ .address = 0x1000, .line = 10, .file = 0 },
        .{ .address = 0x1010, .line = 12, .file = 0 },
    };
    const native: Native = .{ .low = 0, .high = 1 << 40, .bias = 0x7f0000000000, .rows = &rows, .strings = "/src/maze.c\x00" };
    try std.testing.expectEqual(@as(u32, 10), native.place(0x7f0000001005).?.line);
    try std.testing.expectEqual(@as(u32, 12), native.place(0x7f0000001011).?.line);
    try std.testing.expectEqualStrings("/src/maze.c", native.place(0x7f0000001011).?.file);
    try std.testing.expectEqual(@as(?Place, null), native.place(0x7f0000000fff));
}
