// SPDX-License-Identifier: MIT
//! det-profile <node> [--ms <duration>] [--interval-us <us>] [--pid <pid>] [--all]: a sampling
//! CPU profiler (Antithesis's environment.profiler), deterministic like everything else here.
//!
//! Every interval of virtual time it stops the node's runnable threads (ptrace), reads their
//! registers and walks their frame pointers, then lets them go. Addresses are named from the
//! ELF symbol tables of the mapped files. It prints folded stacks ("process;outer;...;inner
//! count", most samples first), which `determinismo profile` turns into a flame graph.
//! Code built without frame pointers shows its leaf function only. With --all, threads that
//! wait are sampled too (a wall-clock profile).
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const elf = std.elf;
const nodes = @import("nodes.zig");

const processes_max = 1024;
const threads_max = 256;
const frames_max = 64;
const symbols_files_max = 64;
const maps_max = 512;
const folded_shown_max = 4000;
const ptrace_detach = 17;
const wait_all = 0x40000000; // __WALL: threads too.

const Options = struct {
    node: []const u8,
    duration_ns: u64 = std.time.ns_per_s,
    interval_ns: u64 = 5 * std.time.ns_per_ms,
    pid: ?linux.pid_t = null,
    all: bool = false,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    const options = options_parse(arguments) catch {
        std.debug.print("usage: det-profile <node> [--ms <duration>] [--interval-us <us>] " ++
            "[--pid <pid>] [--all]\n", .{});
        return 2;
    };
    var profile = Profile{ .arena = arena };
    const start_ns = monotonic_ns();
    while (monotonic_ns() - start_ns < options.duration_ns) {
        try profile.tick(&options);
        sleep_ns(options.interval_ns);
    }
    try profile.print();
    return 0;
}

fn options_parse(arguments: []const [:0]const u8) !Options {
    if (arguments.len < 2) return error.Usage;
    var options = Options{ .node = arguments[1] };
    var index: usize = 2;
    while (index < arguments.len) : (index += 1) {
        const flag = arguments[index];
        if (std.mem.eql(u8, flag, "--all")) {
            options.all = true;
            continue;
        }
        index += 1;
        if (index == arguments.len) return error.Usage;
        const value = arguments[index];
        if (std.mem.eql(u8, flag, "--ms")) {
            options.duration_ns = try std.fmt.parseInt(u64, value, 10) * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, flag, "--interval-us")) {
            options.interval_ns = try std.fmt.parseInt(u64, value, 10) * std.time.ns_per_us;
        } else if (std.mem.eql(u8, flag, "--pid")) {
            options.pid = try std.fmt.parseInt(linux.pid_t, value, 10);
        } else return error.Usage;
    }
    if (options.interval_ns == 0) return error.Usage;
    return options;
}

const Profile = struct {
    arena: std.mem.Allocator,
    /// Folded stack -> samples.
    stacks: std.StringHashMapUnmanaged(u32) = .empty,
    samples: u64 = 0,
    files: [symbols_files_max]Symbols = undefined,
    files_count: u32 = 0,

    fn tick(profile: *Profile, options: *const Options) !void {
        var pids: [processes_max]linux.pid_t = undefined;
        const count = if (options.pid) |pid| one: {
            pids[0] = pid;
            break :one 1;
        } else nodes.processes(options.node, &pids) catch return error.NoSuchNode;
        for (pids[0..count]) |pid| {
            var tids: [threads_max]linux.pid_t = undefined;
            const threads = nodes.threads(pid, &tids);
            for (tids[0..threads]) |tid| {
                if (!options.all and !runnable(tid)) continue;
                var frames: [frames_max]u64 = undefined;
                const depth = stack_sample(pid, tid, &frames);
                if (depth == 0) continue;
                try profile.add(pid, frames[0..depth]);
            }
        }
    }

    /// Names the frames (outermost first) and counts the stack.
    fn add(profile: *Profile, pid: linux.pid_t, frames: []const u64) !void {
        var buffer: [16 * 1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        writer.writeAll(process_name(pid)) catch return;
        var maps: Maps = .{};
        maps.load(pid);
        // A frame-pointer chain through code built without them ends in garbage: keep the
        // frames up to the first return address outside any executable mapping.
        var valid: usize = 1;
        while (valid < frames.len and maps.find(frames[valid]) != null) valid += 1;
        var index = valid;
        while (index > 0) {
            index -= 1;
            // Return addresses point after the call: look up the call itself.
            const address = if (index == 0) frames[index] else frames[index] - 1;
            writer.writeByte(';') catch break;
            profile.name_write(&writer, pid, &maps, address) catch break;
        }
        const entry = try profile.stacks.getOrPut(profile.arena, writer.buffered());
        if (!entry.found_existing) {
            entry.key_ptr.* = try profile.arena.dupe(u8, writer.buffered());
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
        profile.samples += 1;
    }

    fn name_write(
        profile: *Profile,
        writer: *std.Io.Writer,
        pid: linux.pid_t,
        maps: *const Maps,
        address: u64,
    ) !void {
        const map = maps.find(address) orelse return writer.print("0x{x}", .{address});
        const symbols = profile.symbols_of(pid, map.path);
        const file_offset = address - map.start + map.offset;
        if (symbols) |table| {
            if (table.name(file_offset)) |name| return writer.writeAll(name);
        }
        const base = std.fs.path.basename(map.path);
        try writer.print("{s}+0x{x}", .{ base, file_offset });
    }

    fn symbols_of(profile: *Profile, pid: linux.pid_t, path: []const u8) ?*const Symbols {
        for (profile.files[0..profile.files_count]) |*file| {
            if (std.mem.eql(u8, file.path, path)) return if (file.functions.len > 0) file else null;
        }
        if (profile.files_count == symbols_files_max) return null;
        const file = &profile.files[profile.files_count];
        file.* = Symbols.load(profile.arena, pid, path);
        profile.files_count += 1;
        return if (file.functions.len > 0) file else null;
    }

    fn print(profile: *const Profile) !void {
        const Entry = struct { stack: []const u8, count: u32 };
        var entries: std.ArrayList(Entry) = .empty;
        var iterator = profile.stacks.iterator();
        while (iterator.next()) |entry| {
            try entries.append(profile.arena, .{
                .stack = entry.key_ptr.*,
                .count = entry.value_ptr.*,
            });
        }
        const order = struct {
            fn before(_: void, a: Entry, b: Entry) bool {
                if (a.count != b.count) return a.count > b.count;
                return std.mem.lessThan(u8, a.stack, b.stack);
            }
        };
        std.mem.sort(Entry, entries.items, {}, order.before);
        var out: std.Io.Writer.Allocating = .init(profile.arena);
        try out.writer.print("# det-profile: {d} samples\n", .{profile.samples});
        const shown = entries.items[0..@min(entries.items.len, folded_shown_max)];
        for (shown) |entry| try out.writer.print("{s} {d}\n", .{ entry.stack, entry.count });
        var written: usize = 0;
        const text = out.written();
        while (written < text.len) {
            const result = linux.write(1, text[written..].ptr, text.len - written);
            if (linux.errno(result) != .SUCCESS) return error.Write;
            written += result;
        }
    }
};

/// Whether the thread is running or ready to (state R in /proc/<tid>/stat).
fn runnable(tid: linux.pid_t) bool {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{tid}, 0) catch
        return false;
    var buffer: [512]u8 = undefined;
    const text = read_file(path, &buffer) orelse return false;
    // "<tid> (<comm>) <state> ...": comm may hold spaces and parentheses; the last ')' ends it.
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return false;
    return close + 2 < text.len and text[close + 2] == 'R';
}

/// The thread's instruction pointer, then return addresses along its frame-pointer chain.
fn stack_sample(pid: linux.pid_t, tid: linux.pid_t, frames: *[frames_max]u64) usize {
    if (linux.errno(linux.ptrace(linux.PTRACE.SEIZE, tid, 0, 0, 0)) != .SUCCESS) return 0;
    defer _ = linux.ptrace(ptrace_detach, tid, 0, 0, 0);
    if (linux.errno(linux.ptrace(linux.PTRACE.INTERRUPT, tid, 0, 0, 0)) != .SUCCESS) return 0;
    var status: i32 = 0;
    _ = linux.wait4(tid, &status, wait_all, null);
    // struct user_regs_struct: 27 registers; rbp is the 5th, rip the 17th.
    var registers: [27]u64 = undefined;
    const regs_address = @intFromPtr(&registers);
    if (linux.errno(linux.ptrace(linux.PTRACE.GETREGS, tid, 0, regs_address, 0)) != .SUCCESS) {
        return 0;
    }
    frames[0] = registers[16];
    var depth: usize = 1;
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/mem", .{pid}, 0) catch
        return depth;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return depth;
    defer _ = linux.close(@intCast(fd));
    var frame_pointer = registers[4];
    while (depth < frames_max and frame_pointer != 0 and frame_pointer % 8 == 0) {
        var pair: [2]u64 = undefined; // The caller's frame pointer, then the return address.
        const bytes = std.mem.asBytes(&pair);
        const read = linux.pread(@intCast(fd), bytes, bytes.len, @intCast(frame_pointer));
        if (linux.errno(read) != .SUCCESS or read != bytes.len) break;
        if (pair[1] == 0) break;
        frames[depth] = pair[1];
        depth += 1;
        if (pair[0] <= frame_pointer) break; // Stacks grow down: callers are higher.
        frame_pointer = pair[0];
    }
    return depth;
}

fn process_name(pid: linux.pid_t) []const u8 {
    const State = struct {
        var buffer: [64]u8 = undefined;
    };
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/comm", .{pid}, 0) catch
        return "?";
    const text = read_file(path, &State.buffer) orelse return "?";
    return std.mem.trimEnd(u8, text, "\n");
}

/// A process's executable mappings (/proc/<pid>/maps), each with the file mapped there.
const Maps = struct {
    entries: [maps_max]Map = undefined,
    count: u32 = 0,
    text: [64 * 1024]u8 = undefined,

    const Map = struct { start: u64, end: u64, offset: u64, path: []const u8 };

    fn load(maps: *Maps, pid: linux.pid_t) void {
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/maps", .{pid}, 0) catch
            return;
        const text = read_file(path, &maps.text) orelse return;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (maps.count == maps_max) return;
            // "start-end perms offset dev inode path"
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const range = fields.next() orelse continue;
            const perms = fields.next() orelse continue;
            const offset = fields.next() orelse continue;
            _ = fields.next(); // dev
            _ = fields.next(); // inode
            const file = fields.rest();
            if (perms.len < 3 or perms[2] != 'x' or file.len == 0 or file[0] != '/') continue;
            const dash = std.mem.indexOfScalar(u8, range, '-') orelse continue;
            maps.entries[maps.count] = .{
                .start = std.fmt.parseInt(u64, range[0..dash], 16) catch continue,
                .end = std.fmt.parseInt(u64, range[dash + 1 ..], 16) catch continue,
                .offset = std.fmt.parseInt(u64, offset, 16) catch continue,
                .path = file,
            };
            maps.count += 1;
        }
    }

    fn find(maps: *const Maps, address: u64) ?*const Map {
        for (maps.entries[0..maps.count]) |*map| {
            if (address >= map.start and address < map.end) return map;
        }
        return null;
    }
};

/// A file's functions, from its ELF symbol table (or its dynamic one), sorted by address, and
/// its loadable segments, which turn file offsets into those addresses.
const Symbols = struct {
    path: []const u8,
    functions: []const Function = &.{},
    segments: []const Segment = &.{},

    const Function = struct { address: u64, size: u64, name: []const u8 };
    const Segment = struct { offset: u64, size: u64, address: u64 };

    fn load(arena: std.mem.Allocator, pid: linux.pid_t, path: []const u8) Symbols {
        var symbols = Symbols{ .path = arena.dupe(u8, path) catch path };
        var path_buffer: [nodes.path_size_max]u8 = undefined;
        const full = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/root{s}", .{
            pid, path,
        }, 0) catch return symbols;
        const fd = linux.open(full, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return symbols;
        defer _ = linux.close(@intCast(fd));
        symbols.read(arena, @intCast(fd)) catch {};
        return symbols;
    }

    fn read(symbols: *Symbols, arena: std.mem.Allocator, fd: linux.fd_t) !void {
        const header = try pread_struct(elf.Elf64_Ehdr, fd, 0);
        if (!std.mem.eql(u8, header.e_ident[0..4], elf.MAGIC)) return error.NotElf;
        var segments: std.ArrayList(Segment) = .empty;
        for (0..header.e_phnum) |index| {
            const at = header.e_phoff + index * header.e_phentsize;
            const program = try pread_struct(elf.Elf64.Phdr, fd, at);
            if (program.type != .LOAD) continue;
            try segments.append(arena, .{
                .offset = program.offset,
                .size = program.filesz,
                .address = program.vaddr,
            });
        }
        symbols.segments = segments.items;
        const sections = try arena.alloc(elf.Elf64_Shdr, header.e_shnum);
        for (sections, 0..) |*section, index| {
            const at = header.e_shoff + index * header.e_shentsize;
            section.* = try pread_struct(elf.Elf64_Shdr, fd, at);
        }
        // The full table when the file keeps it, else the dynamic one.
        const table = section_find(sections, elf.SHT_SYMTAB) orelse
            section_find(sections, elf.SHT_DYNSYM) orelse return;
        if (table.sh_link >= sections.len) return error.BadElf;
        const strings = try pread_alloc(arena, fd, sections[table.sh_link]);
        const raw = try pread_alloc(arena, fd, table);
        try symbols.functions_collect(arena, raw, strings);
    }

    fn functions_collect(
        symbols: *Symbols,
        arena: std.mem.Allocator,
        raw: []const u8,
        strings: []const u8,
    ) !void {
        var functions: std.ArrayList(Function) = .empty;
        var at: usize = 0;
        while (at + @sizeOf(elf.Elf64_Sym) <= raw.len) : (at += @sizeOf(elf.Elf64_Sym)) {
            const bytes = raw[at..][0..@sizeOf(elf.Elf64_Sym)];
            const symbol = std.mem.bytesToValue(elf.Elf64_Sym, bytes);
            if (symbol.st_type() != elf.STT_FUNC or symbol.st_value == 0) continue;
            if (symbol.st_name >= strings.len) continue;
            try functions.append(arena, .{
                .address = symbol.st_value,
                .size = symbol.st_size,
                .name = std.mem.sliceTo(strings[symbol.st_name..], 0),
            });
        }
        const order = struct {
            fn before(_: void, a: Function, b: Function) bool {
                return a.address < b.address;
            }
        };
        std.mem.sort(Function, functions.items, {}, order.before);
        symbols.functions = functions.items;
    }

    /// The function at a file offset: the last one starting at or before its address, if the
    /// address falls inside it (or it has no size).
    fn name(symbols: *const Symbols, file_offset: u64) ?[]const u8 {
        const address = for (symbols.segments) |segment| {
            if (file_offset >= segment.offset and file_offset < segment.offset + segment.size) {
                break file_offset - segment.offset + segment.address;
            }
        } else return null;
        var low: usize = 0;
        var high: usize = symbols.functions.len;
        while (low < high) {
            const middle = (low + high) / 2;
            if (symbols.functions[middle].address <= address) low = middle + 1 else high = middle;
        }
        if (low == 0) return null;
        const function = symbols.functions[low - 1];
        if (function.size > 0 and address >= function.address + function.size) return null;
        return function.name;
    }
};

fn section_find(sections: []const elf.Elf64_Shdr, kind: u32) ?elf.Elf64_Shdr {
    for (sections) |section| {
        if (section.sh_type == kind) return section;
    }
    return null;
}

fn pread_struct(comptime T: type, fd: linux.fd_t, offset: u64) !T {
    var value: T = undefined;
    const bytes = std.mem.asBytes(&value);
    const read = linux.pread(fd, bytes.ptr, bytes.len, @intCast(offset));
    if (linux.errno(read) != .SUCCESS or read != bytes.len) return error.ShortRead;
    return value;
}

fn pread_alloc(arena: std.mem.Allocator, fd: linux.fd_t, section: elf.Elf64_Shdr) ![]u8 {
    const buffer = try arena.alloc(u8, section.sh_size);
    var done: usize = 0;
    while (done < buffer.len) {
        const at: i64 = @intCast(section.sh_offset + done);
        const read = linux.pread(fd, buffer[done..].ptr, buffer.len - done, at);
        if (linux.errno(read) != .SUCCESS or read == 0) return error.ShortRead;
        done += read;
    }
    return buffer;
}

fn read_file(path: [:0]const u8, buffer: []u8) ?[]const u8 {
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var size: usize = 0;
    while (size < buffer.len) {
        const read = linux.read(@intCast(fd), buffer[size..].ptr, buffer.len - size);
        if (linux.errno(read) != .SUCCESS or read == 0) break;
        size += read;
    }
    return buffer[0..size];
}

fn monotonic_ns() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn sleep_ns(duration_ns: u64) void {
    var request = linux.timespec{
        .sec = @intCast(duration_ns / std.time.ns_per_s),
        .nsec = @intCast(duration_ns % std.time.ns_per_s),
    };
    _ = linux.nanosleep(&request, null);
}

test "options" {
    const arguments = [_][:0]const u8{ "det-profile", "redis", "--ms", "200", "--all" };
    const options = try options_parse(&arguments);
    try std.testing.expectEqualStrings("redis", options.node);
    try std.testing.expectEqual(200 * std.time.ns_per_ms, options.duration_ns);
    try std.testing.expect(options.all);
    const bad = [_][:0]const u8{ "det-profile", "redis", "--ms" };
    try std.testing.expectError(error.Usage, options_parse(&bad));
}

test "symbols name file offsets" {
    const functions = [_]Symbols.Function{
        .{ .address = 0x1000, .size = 0x10, .name = "first" },
        .{ .address = 0x1020, .size = 0, .name = "second" },
    };
    const segments = [_]Symbols.Segment{.{ .offset = 0, .size = 0x2000, .address = 0x0 }};
    const symbols = Symbols{ .path = "/bin/x", .functions = &functions, .segments = &segments };
    try std.testing.expectEqualStrings("first", symbols.name(0x1008).?);
    try std.testing.expectEqual(null, symbols.name(0x1018));
    try std.testing.expectEqualStrings("second", symbols.name(0x1fff).?);
    try std.testing.expectEqual(null, symbols.name(0x0fff));
}
