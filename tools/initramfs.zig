// SPDX-License-Identifier: MIT
//! det-initramfs: builds the guest's base initramfs, an uncompressed cpio (newc) archive.
//!
//!   det-initramfs --bin <dir> --module <det_guest.ko> --busybox <static busybox> --out <file>
//!
//! Contents: det-init as /init, the guest runtime in /opt/determinismo/bin (and libvoidstar.so,
//! which nodes get as /usr/lib/libvoidstar.so, in /opt/determinismo/lib), busybox (with a
//! link per applet in /bin) for shells in debugging and the exec agent, det_guest.ko, a minimal
//! /etc, and (when the host has mkfs.ext4) an empty ext4 filesystem for nodes whose disks can
//! crash (/opt/determinismo/durable.blocks, see `durable_template`). Nothing about the system
//! under test: that comes on disks.
//!
//! Reproducible by construction: entries sorted by path, inode numbers in order, owner 0 and
//! modification time 0. The guest unpacks this archive at boot, so its bytes are part of every
//! timeline (and of the inputs hash).
const std = @import("std");
const assert = std.debug.assert;

const runtime = [_][]const u8{
    "det-init",        "det-nodes",   "det-composer", "det-faults", "det-agent",
    "det-stop-faults", "det-profile", "det-core",
};
const directories = [_][]const u8{
    "bin",                  "sbin",                     "etc", "proc", "sys", "dev",
    "run",                  "tmp",                      "det", "root", "opt", "opt/determinismo",
    "opt/determinismo/bin", "opt/determinismo/modules", "opt/determinismo/lib",
    "opt/determinismo/coverage",
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
        .path = "opt/determinismo/lib/libvoidstar.so",
        .mode = mode_file,
        .data = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{
            inputs.bin, "libvoidstar.so",
        }), arena, .unlimited),
    });
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
    if (try durable_template(arena, io)) |blocks| {
        try entries.append(arena, .{
            .path = "opt/determinismo/durable.blocks",
            .mode = mode_file,
            .data = blocks,
        });
    } else {
        std.debug.print("det-initramfs: no mkfs.ext4: nodes cannot have crash faults\n", .{});
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.less);
    return entries.items;
}

pub const durable_block_size = 4096;
const durable_size = 64 << 20;

/// An empty ext4 filesystem (64 MiB, grown in the guest; with a journal, so a node's disk is
/// consistent after a crash, as databases expect), made by the host's mkfs.ext4 with a fixed
/// UUID and time (the same bytes on every build), kept as its non-zero blocks: a u64 size, then
/// each such block as a u32 index and its bytes (little endian). guest/runtime/nodes.zig unpacks
/// it. Null without mkfs.ext4.
fn durable_template(arena: std.mem.Allocator, io: std.Io) !?[]const u8 {
    const path = "/tmp/det-initramfs-durable.ext4";
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(io, path) catch {};
    var environment = std.process.Environ.Map.init(arena);
    try environment.put("E2FSPROGS_FAKE_TIME", "1");
    try environment.put("PATH", "/usr/sbin:/sbin:/usr/bin:/bin");
    const uuid = "6465746d-696e-6973-6d6f-647572616265";
    const size = try std.fmt.allocPrint(arena, "{d}k", .{durable_size / 1024});
    const extended = "lazy_itable_init=1,lazy_journal_init=1,root_owner=0:0,hash_seed=" ++ uuid;
    // Often in sbin, which a user's PATH lacks.
    const mkfs = for ([_][]const u8{ "/usr/sbin/mkfs.ext4", "/sbin/mkfs.ext4" }) |candidate| {
        cwd.access(io, candidate, .{}) catch continue;
        break candidate;
    } else "mkfs.ext4";
    const result = std.process.run(arena, io, .{
        .argv = &.{
            mkfs,     "-q", "-F", "-b", "4096", "-U", uuid, "-J", "size=4", "-i", "65536", "-E",
            extended, path, size,
        },
        .environ_map = &environment,
    }) catch return null;
    if (!result.term.success()) {
        std.debug.print("det-initramfs: mkfs.ext4: {s}\n", .{result.stderr});
        return null;
    }
    defer cwd.deleteFile(io, path) catch {};
    const image = try cwd.readFileAlloc(io, path, arena, .limited(durable_size + 1));
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u64, image.len)));
    var index: u32 = 0;
    while (index * durable_block_size < image.len) : (index += 1) {
        const block = image[index * durable_block_size ..][0..durable_block_size];
        if (std.mem.allEqual(u8, block, 0)) continue;
        try out.appendSlice(arena, &std.mem.toBytes(std.mem.nativeToLittle(u32, index)));
        try out.appendSlice(arena, block);
    }
    return out.items;
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
