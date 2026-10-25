// SPDX-License-Identifier: MIT
//! det-initramfs: builds the guest's base initramfs, an uncompressed cpio (newc) archive.
//!
//!   det-initramfs --bin <dir> --module <det_guest.ko> --busybox <static busybox> --out <file>
//!
//! Contents: det-init as /init, the guest runtime in /opt/determinismo/bin, busybox (with a
//! link per applet in /bin) for shells in debugging and the exec agent, det_guest.ko, and a
//! minimal /etc. Nothing about the system under test: that comes on disks.
//!
//! Reproducible by construction: entries sorted by path, inode numbers in order, owner 0 and
//! modification time 0. The guest unpacks this archive at boot, so its bytes are part of every
//! timeline (and of the inputs hash).
const std = @import("std");
const assert = std.debug.assert;

const runtime = [_][]const u8{ "det-init", "det-nodes", "det-composer", "det-faults", "det-agent" };
const directories = [_][]const u8{
    "bin",                  "sbin",                     "etc", "proc", "sys", "dev",
    "run",                  "tmp",                      "det", "root", "opt", "opt/determinismo",
    "opt/determinismo/bin", "opt/determinismo/modules",
};
const applets_max = 1024;

const Entry = struct {
    path: []const u8,
    mode: u32,
    data: []const u8 = "",
};

const mode_directory = 0o040755;
const mode_executable = 0o100755;
const mode_file = 0o100644;
const mode_symlink = 0o120777;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const arguments = try init.minimal.args.toSlice(arena);
    var bin: ?[]const u8 = null;
    var module: ?[]const u8 = null;
    var busybox: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var index: usize = 1;
    while (index + 1 < arguments.len) : (index += 2) {
        const flag = arguments[index];
        const value = arguments[index + 1];
        const eql = std.mem.eql;
        if (eql(u8, flag, "--bin")) {
            bin = value;
        } else if (eql(u8, flag, "--module")) {
            module = value;
        } else if (eql(u8, flag, "--busybox")) {
            busybox = value;
        } else if (eql(u8, flag, "--out")) {
            out = value;
        } else return error.Usage;
    }
    if (bin == null or module == null or busybox == null or out == null) {
        std.debug.print("usage: det-initramfs --bin <dir> --module <det_guest.ko> " ++
            "--busybox <static busybox> --out <file>\n", .{});
        std.process.exit(2);
    }
    const entries = try entries_collect(arena, init.io, .{
        .bin = bin.?,
        .module = module.?,
        .busybox = busybox.?,
    });
    const archive = try archive_write(arena, entries);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out.?, .data = archive });
    std.debug.print("{s}: {d} entries, {d} bytes\n", .{ out.?, entries.len, archive.len });
}

const Inputs = struct { bin: []const u8, module: []const u8, busybox: []const u8 };

fn entries_collect(arena: std.mem.Allocator, io: std.Io, inputs: Inputs) ![]Entry {
    const cwd = std.Io.Dir.cwd();
    var entries: std.ArrayList(Entry) = .empty;
    for (directories) |directory| {
        try entries.append(arena, .{ .path = directory, .mode = mode_directory });
    }
    for (runtime) |name| {
        const path = try std.fs.path.join(arena, &.{ inputs.bin, name });
        try entries.append(arena, .{
            .path = try std.fmt.allocPrint(arena, "opt/determinismo/bin/{s}", .{name}),
            .mode = mode_executable,
            .data = try cwd.readFileAlloc(io, path, arena, .unlimited),
        });
    }
    try entries.append(arena, .{
        .path = "init",
        .mode = mode_symlink,
        .data = "opt/determinismo/bin/det-init",
    });
    try entries.append(arena, .{
        .path = "opt/determinismo/modules/det_guest.ko",
        .mode = mode_file,
        .data = try cwd.readFileAlloc(io, inputs.module, arena, .unlimited),
    });
    try entries.append(arena, .{
        .path = "bin/busybox",
        .mode = mode_executable,
        .data = try cwd.readFileAlloc(io, inputs.busybox, arena, .unlimited),
    });
    try applets_add(arena, io, inputs.busybox, &entries);
    const passwd = "root:x:0:0:root:/root:/bin/sh\n";
    try entries.append(arena, .{ .path = "etc/passwd", .mode = mode_file, .data = passwd });
    try entries.append(arena, .{ .path = "etc/group", .mode = mode_file, .data = "root:x:0:\n" });
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    return entries.items;
}

/// A link /bin/<applet> -> busybox for each applet busybox lists (except busybox itself).
fn applets_add(
    arena: std.mem.Allocator,
    io: std.Io,
    busybox: []const u8,
    entries: *std.ArrayList(Entry),
) !void {
    const result = try std.process.run(arena, io, .{ .argv = &.{ busybox, "--list" } });
    if (!result.term.success()) return error.BusyboxList;
    var count: u32 = 0;
    var names = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, "busybox")) continue;
        if (count == applets_max) return error.TooManyApplets;
        try entries.append(arena, .{
            .path = try std.fmt.allocPrint(arena, "bin/{s}", .{name}),
            .mode = mode_symlink,
            .data = "busybox",
        });
        count += 1;
    }
}

/// The newc format: a 110-byte ASCII header per entry, the NUL-terminated name, then the data,
/// each padded to 4 bytes; a TRAILER!!! entry ends it.
fn archive_write(arena: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (entries, 1..) |entry, inode| try entry_write(arena, &out, entry, @intCast(inode));
    try entry_write(arena, &out, .{ .path = "TRAILER!!!", .mode = 0 }, 0);
    try out.appendNTimes(arena, 0, std.mem.alignForward(usize, out.items.len, 512) - out.items.len);
    return out.items;
}

fn entry_write(arena: std.mem.Allocator, out: *std.ArrayList(u8), entry: Entry, inode: u32) !void {
    assert(entry.path.len > 0);
    const links: u32 = if (entry.mode == mode_directory) 2 else 1;
    var header: [110]u8 = undefined;
    _ = try std.fmt.bufPrint(&header, "070701{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}" ++
        "{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}{x:0>8}", .{
        inode, entry.mode, 0, 0, links, 0, entry.data.len, 0, 0, 0, 0, entry.path.len + 1, 0,
    });
    try out.appendSlice(arena, &header);
    try out.appendSlice(arena, entry.path);
    try out.append(arena, 0);
    try pad(arena, out);
    try out.appendSlice(arena, entry.data);
    try pad(arena, out);
}

fn pad(arena: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendNTimes(arena, 0, std.mem.alignForward(usize, out.items.len, 4) - out.items.len);
}

test archive_write {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const entries = [_]Entry{.{ .path = "a", .mode = mode_file, .data = "hi" }};
    const archive = try archive_write(arena_state.allocator(), &entries);
    try std.testing.expect(std.mem.startsWith(u8, archive, "070701"));
    try std.testing.expectEqualStrings("a", archive[110..111]);
    try std.testing.expect(std.mem.indexOf(u8, archive, "TRAILER!!!") != null);
    try std.testing.expectEqual(@as(usize, 0), archive.len % 512);
}
