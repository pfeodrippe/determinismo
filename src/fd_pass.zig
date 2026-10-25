// SPDX-License-Identifier: MIT
//! Passing a file descriptor between processes over a Unix socket (SCM_RIGHTS): a child that
//! froze a machine hands its memory's memfd to the explorer.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const scm_rights = 1;
/// struct cmsghdr (len, level, type) and one int of data, padded to the header's alignment.
const header_size = @sizeOf(usize) + 2 * @sizeOf(i32);
const control_size = header_size + @sizeOf(usize);

/// Sends `fd` with one byte of data (a message needs some).
pub fn send(socket: linux.fd_t, fd: linux.fd_t) !void {
    var control: [control_size]u8 align(@alignOf(usize)) = @splat(0);
    std.mem.writeInt(usize, control[0..@sizeOf(usize)], header_size + @sizeOf(i32), .little);
    std.mem.writeInt(i32, control[@sizeOf(usize)..][0..4], linux.SOL.SOCKET, .little);
    std.mem.writeInt(i32, control[@sizeOf(usize) + 4 ..][0..4], scm_rights, .little);
    std.mem.writeInt(i32, control[header_size..][0..4], fd, .little);
    const byte = [1]u8{1};
    var vector = [1]std.posix.iovec_const{.{ .base = &byte, .len = 1 }};
    const message = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &vector,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const sent = linux.sendmsg(socket, &message, 0);
    if (linux.errno(sent) != .SUCCESS or sent != 1) return error.SendFailed;
}

/// Receives a descriptor sent with `send`: a new one in this process.
pub fn receive(socket: linux.fd_t) !linux.fd_t {
    var control: [control_size]u8 align(@alignOf(usize)) = @splat(0);
    var byte: [1]u8 = undefined;
    var vector = [1]std.posix.iovec{.{ .base = &byte, .len = 1 }};
    var message = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &vector,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    const received = linux.recvmsg(socket, &message, linux.MSG.CMSG_CLOEXEC);
    if (linux.errno(received) != .SUCCESS or received != 1) return error.ReceiveFailed;
    if (message.controllen < header_size + @sizeOf(i32)) return error.NoDescriptor;
    const level = std.mem.readInt(i32, control[@sizeOf(usize)..][0..4], .little);
    const kind = std.mem.readInt(i32, control[@sizeOf(usize) + 4 ..][0..4], .little);
    if (level != linux.SOL.SOCKET or kind != scm_rights) return error.NoDescriptor;
    const fd = std.mem.readInt(i32, control[header_size..][0..4], .little);
    assert(fd >= 0);
    return fd;
}

test "a descriptor crosses a socket" {
    var pair: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &pair)) != .SUCCESS) {
        return error.SkipZigTest;
    }
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);
    const memfd: linux.fd_t = @intCast(linux.memfd_create("fd-pass-test", 0));
    defer _ = linux.close(memfd);
    _ = linux.write(memfd, "hello", 5);
    try send(pair[0], memfd);
    const copy = try receive(pair[1]);
    defer _ = linux.close(copy);
    try std.testing.expect(copy != memfd);
    var buffer: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), linux.pread(copy, &buffer, 5, 0));
    try std.testing.expectEqualStrings("hello", &buffer);
}
