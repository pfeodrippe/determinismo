// SPDX-License-Identifier: MIT
//! The host's runs. Every exploration is one, however it was started (`determinismo explore` at
//! a terminal or from a script, or serve's API): a directory `runs/<id>` of the data directory
//! (`--data`, else $DETERMINISMO_DATA, else ~/.determinismo) with its request and machine (what
//! replays it), its record, events and tapes, its output, and a pid file its explorer holds
//! locked while it runs. `determinismo serve` shows that directory: the runs it starts and the
//! others, as they appear.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

/// Run ids are below this (serve keeps them in an array of this size).
pub const runs_max = 4096;

/// The data directory: `given` (`--data`), else $DETERMINISMO_DATA, else ~/.determinismo.
pub fn data_directory(arena: std.mem.Allocator, given: ?[]const u8) ![]const u8 {
    if (given) |directory| return absolute(arena, directory);
    if (std.c.getenv("DETERMINISMO_DATA")) |directory| return absolute(arena, std.mem.span(directory));
    const home = std.c.getenv("HOME") orelse return error.NoHome;
    return std.fs.path.join(arena, &.{ std.mem.span(home), ".determinismo" });
}

pub fn directory_of(arena: std.mem.Allocator, data: []const u8, id: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/runs/{d}", .{ data, id });
}

pub const Claimed = struct { id: u32, directory: []const u8 };

/// The next run, claimed: the first id after the highest there whose directory this process
/// made (mkdir is atomic: two claimants never share one).
pub fn claim(arena: std.mem.Allocator, io: std.Io, data: []const u8) !Claimed {
    const runs_path = try std.fs.path.join(arena, &.{ data, "runs" });
    try std.Io.Dir.cwd().createDirPath(io, runs_path);
    var id = (try ids_highest(arena, runs_path)) + 1;
    while (id < runs_max) : (id += 1) {
        const directory = try directory_of(arena, data, id);
        const directory_z = try arena.dupeSentinel(u8, directory, 0);
        const made = linux.mkdirat(linux.AT.FDCWD, directory_z, 0o755);
        switch (linux.errno(made)) {
            .SUCCESS => return .{ .id = id, .directory = directory },
            .EXIST => continue, // Another claimant's.
            else => return error.ClaimFailed,
        }
    }
    return error.TooManyRuns;
}

/// The run ids there, ascending.
pub fn ids(arena: std.mem.Allocator, runs_path: []const u8) ![]u32 {
    var found: std.ArrayList(u32) = .empty;
    const path_z = try arena.dupeSentinel(u8, runs_path, 0);
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
    const fd = linux.open(path_z, flags, 0);
    if (linux.errno(fd) != .SUCCESS) return found.items;
    defer _ = linux.close(@intCast(fd));
    var buffer: [8192]u8 align(8) = undefined;
    while (true) {
        const size = linux.getdents64(@intCast(fd), &buffer, buffer.len);
        if (linux.errno(size) != .SUCCESS or size == 0) break;
        var offset: usize = 0;
        while (offset < size) {
            const entry: *align(1) const linux.dirent64 = @ptrCast(&buffer[offset]);
            offset += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            const id = std.fmt.parseInt(u32, name, 10) catch continue;
            if (id == 0 or id >= runs_max) continue;
            try found.append(arena, id);
        }
    }
    std.mem.sort(u32, found.items, {}, std.sort.asc(u32));
    return found.items;
}

fn ids_highest(arena: std.mem.Allocator, runs_path: []const u8) !u32 {
    const all = try ids(arena, runs_path);
    return if (all.len == 0) 0 else all[all.len - 1];
}

/// Marks the run as running: this process's pid in its `pid` file, which it holds under an
/// exclusive lock until it ends (the file stays open; what it executes does not inherit it).
pub fn running_mark(arena: std.mem.Allocator, directory: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(arena, "{s}/pid", .{directory}, 0);
    const flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true };
    const opened = linux.open(path, flags, 0o644);
    if (linux.errno(opened) != .SUCCESS) return error.PidFile;
    const fd: linux.fd_t = @intCast(opened);
    if (linux.errno(linux.flock(fd, std.posix.LOCK.EX | std.posix.LOCK.NB)) != .SUCCESS) {
        _ = linux.close(fd);
        return error.RunRunning; // Another explorer has it.
    }
    // One run at a time: the one before (an exploration of several scenarios, each its own
    // run) has ended.
    if (running_fd) |before| _ = linux.close(before);
    running_fd = fd;
    _ = linux.ftruncate(fd, 0);
    var text_buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buffer, "{d}\n", .{linux.getpid()}) catch unreachable;
    if (linux.errno(linux.pwrite(fd, text.ptr, text.len, 0)) != .SUCCESS) return error.PidFile;
}

/// The pid file this process holds (locked) for the run it explores.
var running_fd: ?linux.fd_t = null;

/// The run's explorer, if it runs: the pid its pid file names, while the file is locked.
pub fn running_pid(arena: std.mem.Allocator, directory: []const u8) ?linux.pid_t {
    const path = std.fmt.allocPrintSentinel(arena, "{s}/pid", .{directory}, 0) catch return null;
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    // A shared lock taken: no explorer holds it.
    if (linux.errno(linux.flock(fd, std.posix.LOCK.SH | std.posix.LOCK.NB)) == .SUCCESS) return null;
    var buffer: [16]u8 = undefined;
    const read = linux.pread(fd, &buffer, buffer.len, 0);
    if (linux.errno(read) != .SUCCESS) return null;
    return std.fmt.parseInt(linux.pid_t, std.mem.trim(u8, buffer[0..read], " \n"), 10) catch null;
}

/// A copy of the file named by its content, under `<data>/artifacts`, made once: runs of one
/// build share it, and a deploy, which replaces the original, leaves it be.
pub fn artifact_keep(arena: std.mem.Allocator, io: std.Io, data: []const u8, path: []const u8) ![]const u8 {
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, path, arena, .unlimited);
    const directory = try std.fs.path.join(arena, &.{ data, "artifacts" });
    try cwd.createDirPath(io, directory);
    const name = try std.fmt.allocPrint(arena, "{x:0>16}-{s}", .{
        std.hash.Wyhash.hash(0, bytes), std.fs.path.basename(path),
    });
    const kept = try std.fs.path.join(arena, &.{ directory, name });
    cwd.access(io, kept, .{}) catch {
        // Staged under a name of this thread's: two runs keeping it at once do not collide, nor
        // two requests to one server (a thread each: the self-test's controller answered 500
        // when one renamed the file the other was about to chmod).
        const staging = try std.fmt.allocPrintSentinel(arena, "{s}.staging-{d}-{d}", .{ kept, linux.getpid(), linux.gettid() }, 0);
        try cwd.writeFile(io, .{ .sub_path = staging, .data = bytes });
        // Executable: a test program is run from its kept copy.
        if (linux.errno(linux.fchmodat(linux.AT.FDCWD, staging, 0o755)) != .SUCCESS) return error.ChmodFailed;
        try cwd.rename(staging, cwd, kept, io);
    };
    return kept;
}

/// `path` from the root: relative ones from the working directory.
pub fn absolute(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = linux.getcwd(&buffer, buffer.len);
    if (linux.errno(size) != .SUCCESS) return error.WorkingDirectory;
    const cwd = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buffer)), 0);
    return std.fs.path.resolve(arena, &.{ cwd, path });
}

/// What this process and its children print goes on to where it went, and into `path` too:
/// a run started at a terminal has its output in its directory, as serve's runs do. A child
/// copies both streams until every writer is gone; it outlives an interrupt to drain them.
pub fn output_tee(arena: std.mem.Allocator, path: []const u8) !void {
    const path_z = try arena.dupeSentinel(u8, path, 0);
    const file_flags: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true };
    const file = linux.open(path_z, file_flags, 0o644);
    if (linux.errno(file) != .SUCCESS) return error.OutputFile;
    var pipes: [2][2]i32 = undefined;
    for (&pipes) |*pipe| {
        if (linux.errno(linux.pipe2(pipe, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    }
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        for (pipes) |pipe| _ = linux.close(pipe[1]);
        const ignore: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = linux.sigemptyset(), .flags = 0 };
        for ([_]linux.SIG{ .INT, .TERM, .HUP, .PIPE }) |signal| _ = linux.sigaction(signal, &ignore, null);
        tee_loop(.{ pipes[0][0], pipes[1][0] }, .{ 1, 2 }, @intCast(file));
        linux.exit_group(0);
    }
    _ = linux.close(@intCast(file));
    for (pipes, [_]i32{ 1, 2 }) |pipe, target| {
        _ = linux.close(pipe[0]);
        if (linux.errno(linux.dup2(pipe[1], target)) != .SUCCESS) return error.Dup;
        _ = linux.close(pipe[1]);
    }
}

fn tee_loop(sources: [2]i32, targets: [2]i32, file: linux.fd_t) void {
    var polled: [2]linux.pollfd = .{
        .{ .fd = sources[0], .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = sources[1], .events = linux.POLL.IN, .revents = 0 },
    };
    var open: u32 = 2;
    var buffer: [16 * 1024]u8 = undefined;
    while (open > 0) {
        const ready = linux.poll(&polled, polled.len, -1);
        if (linux.errno(ready) == .INTR) continue;
        if (linux.errno(ready) != .SUCCESS) return;
        for (&polled, targets) |*entry, target| {
            if (entry.fd < 0 or entry.revents == 0) continue;
            const read = linux.read(entry.fd, &buffer, buffer.len);
            if (linux.errno(read) == .INTR) continue;
            if (linux.errno(read) != .SUCCESS or read == 0) {
                _ = linux.close(entry.fd);
                entry.fd = -1; // poll passes over negative descriptors.
                open -= 1;
                continue;
            }
            write_all(target, buffer[0..read]);
            write_all(file, buffer[0..read]);
        }
    }
}

fn write_all(fd: linux.fd_t, bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
        if (linux.errno(result) == .INTR) continue;
        if (linux.errno(result) != .SUCCESS) return; // A terminal gone: the file still gets it.
        written += result;
    }
}

test "claim: ids in order, never one twice; the pid lock tells a running run" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try absolute(arena, try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{&tmp.sub_path}));
    const first = try claim(arena, io, data);
    const second = try claim(arena, io, data);
    try std.testing.expectEqual(1, first.id);
    try std.testing.expectEqual(2, second.id);
    // One made by hand further on: the next comes after it.
    try std.Io.Dir.cwd().createDirPath(io, try directory_of(arena, data, 7));
    try std.testing.expectEqual(8, (try claim(arena, io, data)).id);
    const runs_path = try std.fs.path.join(arena, &.{ data, "runs" });
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 7, 8 }, try ids(arena, runs_path));

    try std.testing.expectEqual(null, running_pid(arena, first.directory));
    try running_mark(arena, first.directory);
    try std.testing.expectEqual(linux.getpid(), running_pid(arena, first.directory).?);
    try std.testing.expectError(error.RunRunning, running_mark(arena, first.directory));
}
