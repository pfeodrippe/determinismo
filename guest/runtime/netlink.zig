// SPDX-License-Identifier: MIT
//! The few rtnetlink requests the node runtime needs: veth pairs created straight into two
//! network namespaces, IPv4 addresses, host routes, and links up or down. One request at a time,
//! acknowledged before the next, from a fixed buffer.
const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;

const message_size_max = 1024;
const flag_request: u16 = 0x1;
const flag_ack: u16 = 0x4;
const flag_exclusive: u16 = 0x200;
const flag_create: u16 = 0x400;
const message_error: u16 = 2;
const rtm_newlink: u16 = 16;
const rtm_newaddr: u16 = 20;
const rtm_newroute: u16 = 24;
const rtm_newqdisc: u16 = 36;
const rtm_delqdisc: u16 = 37;
const flag_replace: u16 = 0x100;
const tca_kind: u16 = 1;
const tca_options: u16 = 2;
const tca_netem_reorder: u16 = 3;
const tca_netem_corrupt: u16 = 4;
const tca_netem_rate: u16 = 6;
const tca_netem_latency64: u16 = 10;
const tca_netem_jitter64: u16 = 11;
const tca_netem_prng_seed: u16 = 14;
const tc_handle_root: u32 = 0xffff_ffff;
const tc_handle_netem: u32 = 0x1_0000; // 1:0
const tcmsg_size = 20;
const netem_limit_packets = 10_000;
const ifla_address: u16 = 1;
const ifla_ifname: u16 = 3;
const ifla_linkinfo: u16 = 18;
const ifla_net_ns_pid: u16 = 19;
const ifla_info_kind: u16 = 1;
const ifla_info_data: u16 = 2;
const veth_info_peer: u16 = 1;
const ifa_address: u16 = 1;
const ifa_local: u16 = 2;
const rta_destination: u16 = 1;
const rta_output_interface: u16 = 4;
const rta_gateway: u16 = 5;
const iff_up: u32 = 1;
const ifinfo_size = 16;
const header_size = 16;
const siocgifindex: u32 = 0x8933;
pub const interface_name_size_max = 15;

pub const Address = [4]u8;
pub const LinkState = enum { up, down };

/// A connection to the kernel's routing subsystem in the calling thread's network namespace.
pub const Socket = struct {
    fd: linux.fd_t,
    sequence: u32 = 0,

    pub fn open() !Socket {
        const result = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(result) != .SUCCESS) return error.NetlinkSocket;
        return .{ .fd = @intCast(result) };
    }

    pub fn close(socket: *Socket) void {
        assert(socket.fd >= 0);
        _ = linux.close(socket.fd);
        socket.* = undefined;
    }

    /// A veth pair: `name` in the network namespace of process `pid`, `peer_name` in that of
    /// `peer_pid`.
    pub fn veth_create(socket: *Socket, ends: [2]VethEnd) !void {
        var message: Message = .init(rtm_newlink, flag_create | flag_exclusive);
        message.append_bytes(&@as([ifinfo_size]u8, @splat(0)));
        ends[0].append(&message);
        const link_info = message.nest_begin(ifla_linkinfo);
        message.attribute(ifla_info_kind, "veth");
        const info_data = message.nest_begin(ifla_info_data);
        const peer = message.nest_begin(veth_info_peer);
        message.append_bytes(&@as([ifinfo_size]u8, @splat(0)));
        ends[1].append(&message);
        message.nest_end(peer);
        message.nest_end(info_data);
        message.nest_end(link_info);
        try socket.send(&message);
    }

    pub fn link_set(socket: *Socket, name: []const u8, state: LinkState) !void {
        var message: Message = .init(rtm_newlink, 0);
        var info: [ifinfo_size]u8 = @splat(0);
        std.mem.writeInt(i32, info[4..8], try socket.index(name), .little);
        std.mem.writeInt(u32, info[8..12], if (state == .up) iff_up else 0, .little);
        std.mem.writeInt(u32, info[12..16], iff_up, .little); // Change only IFF_UP.
        message.append_bytes(&info);
        try socket.send(&message);
    }

    /// `address`/32 on the interface: every link of a node carries the node's one address.
    pub fn address_add(socket: *Socket, name: []const u8, address: Address) !void {
        var message: Message = .init(rtm_newaddr, flag_create | flag_exclusive);
        var info: [8]u8 = .{ linux.AF.INET, 32, 0, 0, 0, 0, 0, 0 };
        std.mem.writeInt(u32, info[4..8], @intCast(try socket.index(name)), .little);
        message.append_bytes(&info);
        message.attribute(ifa_local, &address);
        message.attribute(ifa_address, &address);
        try socket.send(&message);
    }

    /// A host route: `destination` is reached directly through the interface.
    pub fn route_add(socket: *Socket, name: []const u8, destination: Address) !void {
        var message: Message = .init(rtm_newroute, flag_create | flag_exclusive);
        const table_main = 254;
        const protocol_boot = 3;
        const scope_link = 253;
        const type_unicast = 1;
        const info = [12]u8{
            linux.AF.INET, 32,           0, 0, table_main, protocol_boot,
            scope_link,    type_unicast, 0, 0, 0,          0,
        };
        message.append_bytes(&info);
        message.attribute(rta_destination, &destination);
        var index_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &index_bytes, @intCast(try socket.index(name)), .little);
        message.attribute(rta_output_interface, &index_bytes);
        try socket.send(&message);
    }

    /// The default route, through `gateway` on the interface (whose host route reaches it).
    pub fn route_default(socket: *Socket, name: []const u8, gateway: Address) !void {
        var message: Message = .init(rtm_newroute, flag_create | flag_exclusive);
        const table_main = 254;
        const protocol_boot = 3;
        const scope_universe = 0;
        const type_unicast = 1;
        const info = [12]u8{
            linux.AF.INET,  0,            0, 0, table_main, protocol_boot,
            scope_universe, type_unicast, 0, 0, 0,          0,
        };
        message.append_bytes(&info);
        message.attribute(rta_gateway, &gateway);
        var index_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &index_bytes, @intCast(try socket.index(name)), .little);
        message.attribute(rta_output_interface, &index_bytes);
        try socket.send(&message);
    }

    /// Delays and drops what leaves through the interface (one direction of a link), with
    /// netem's own randomness seeded by the caller so that it is a platform decision too.
    pub fn netem_set(socket: *Socket, name: []const u8, netem: Netem) !void {
        assert(netem.loss_percent <= 100);
        var message: Message = .init(rtm_newqdisc, flag_create | flag_replace);
        message.append_bytes(&try socket.tcmsg(name));
        message.attribute(tca_kind, "netem\x00");
        const options = message.nest_begin(tca_options);
        // struct tc_netem_qopt: latency, limit, loss, gap, duplicate, jitter (latency and jitter
        // in the legacy unit are superseded by the 64-bit nanosecond attributes below).
        var qopt: [24]u8 = @splat(0);
        std.mem.writeInt(u32, qopt[4..8], netem_limit_packets, .little);
        std.mem.writeInt(u32, qopt[8..12], probability(netem.loss_percent), .little);
        std.mem.writeInt(u32, qopt[16..20], probability(netem.duplicate_percent), .little);
        message.append_bytes(&qopt);
        // struct tc_netem_reorder and tc_netem_corrupt: probability, correlation.
        var pair: [8]u8 = @splat(0);
        if (netem.reorder_percent > 0) {
            std.mem.writeInt(u32, pair[0..4], probability(netem.reorder_percent), .little);
            message.attribute(tca_netem_reorder, &pair);
        }
        if (netem.corrupt_percent > 0) {
            std.mem.writeInt(u32, pair[0..4], probability(netem.corrupt_percent), .little);
            message.attribute(tca_netem_corrupt, &pair);
        }
        if (netem.rate_bytes_per_second > 0) {
            // struct tc_netem_rate: rate, packet overhead, cell size, cell overhead.
            var rate: [16]u8 = @splat(0);
            std.mem.writeInt(u32, rate[0..4], netem.rate_bytes_per_second, .little);
            message.attribute(tca_netem_rate, &rate);
        }
        var value: [8]u8 = undefined;
        std.mem.writeInt(u64, &value, netem.delay_ns, .little);
        message.attribute(tca_netem_latency64, &value);
        std.mem.writeInt(u64, &value, netem.jitter_ns, .little);
        message.attribute(tca_netem_jitter64, &value);
        std.mem.writeInt(u64, &value, netem.seed, .little);
        message.attribute(tca_netem_prng_seed, &value);
        message.nest_end(options);
        try socket.send(&message);
    }

    pub fn netem_clear(socket: *Socket, name: []const u8) !void {
        var message: Message = .init(rtm_delqdisc, 0);
        message.append_bytes(&try socket.tcmsg(name));
        socket.send(&message) catch |err| switch (err) {
            error.NetlinkRequestFailed => {}, // No qdisc to remove.
            else => return err,
        };
    }

    fn tcmsg(socket: *const Socket, name: []const u8) ![tcmsg_size]u8 {
        var header: [tcmsg_size]u8 = @splat(0);
        header[0] = linux.AF.UNSPEC;
        std.mem.writeInt(i32, header[4..8], try socket.index(name), .little);
        std.mem.writeInt(u32, header[8..12], tc_handle_netem, .little);
        std.mem.writeInt(u32, header[12..16], tc_handle_root, .little);
        return header;
    }

    fn index(socket: *const Socket, name: []const u8) !i32 {
        assert(name.len > 0);
        if (name.len > interface_name_size_max) return error.InterfaceNameTooLong;
        var request: extern struct { name: [16]u8, index: i32, padding: [20]u8 } = .{
            .name = @splat(0),
            .index = 0,
            .padding = @splat(0),
        };
        @memcpy(request.name[0..name.len], name);
        const result = linux.ioctl(socket.fd, siocgifindex, @intFromPtr(&request));
        if (linux.errno(result) != .SUCCESS) return error.NoSuchInterface;
        assert(request.index > 0);
        return request.index;
    }

    fn send(socket: *Socket, message: *Message) !void {
        socket.sequence += 1;
        message.finish(socket.sequence);
        var kernel = std.mem.zeroes(linux.sockaddr.nl);
        kernel.family = linux.AF.NETLINK;
        const bytes = message.buffer[0..message.size];
        const kernel_address: *const linux.sockaddr = @ptrCast(&kernel);
        const kernel_size = @sizeOf(linux.sockaddr.nl);
        const sent = linux.sendto(socket.fd, bytes.ptr, bytes.len, 0, kernel_address, kernel_size);
        if (linux.errno(sent) != .SUCCESS) return error.NetlinkSend;
        assert(sent == bytes.len);
        return socket.acknowledgement();
    }

    fn acknowledgement(socket: *Socket) !void {
        var reply: [message_size_max]u8 align(4) = undefined;
        const received = linux.recvfrom(socket.fd, &reply, reply.len, 0, null, null);
        if (linux.errno(received) != .SUCCESS) return error.NetlinkReceive;
        if (received < header_size + 4) return error.NetlinkShortReply;
        const kind = std.mem.readInt(u16, reply[4..6], .little);
        if (kind != message_error) return error.NetlinkUnexpectedReply;
        const code = std.mem.readInt(i32, reply[header_size..][0..4], .little);
        if (code == 0) return;
        const errno: linux.E = @enumFromInt(-code);
        if (errno == .EXIST) return error.Exists;
        std.debug.print("netlink request failed: {s}\n", .{@tagName(errno)});
        return error.NetlinkRequestFailed;
    }
};

pub const Netem = struct {
    delay_ns: u64,
    jitter_ns: u64 = 0,
    loss_percent: u8 = 0,
    duplicate_percent: u8 = 0,
    corrupt_percent: u8 = 0,
    /// Packets sent at once instead of delayed (needs a delay to reorder against).
    reorder_percent: u8 = 0,
    /// Bandwidth limit (0: none).
    rate_bytes_per_second: u32 = 0,
    seed: u64,
};

/// netem's probabilities are fractions of 2^32 - 1.
fn probability(percent: u8) u32 {
    assert(percent <= 100);
    const scaled = @as(u64, std.math.maxInt(u32)) * percent / 100;
    return @intCast(scaled);
}

/// One end of a veth pair: its interface name, its MAC address, and a process in the network
/// namespace it goes to.
pub const VethEnd = struct {
    name: []const u8,
    mac: [6]u8,
    pid: linux.pid_t,

    fn append(end: VethEnd, message: *Message) void {
        assert(end.name.len > 0 and end.name.len <= interface_name_size_max);
        assert(end.pid > 0);
        var name: [interface_name_size_max + 1]u8 = @splat(0);
        @memcpy(name[0..end.name.len], end.name);
        message.attribute(ifla_ifname, name[0 .. end.name.len + 1]);
        message.attribute(ifla_address, &end.mac);
        var pid_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &pid_bytes, @intCast(end.pid), .little);
        message.attribute(ifla_net_ns_pid, &pid_bytes);
    }
};

const Message = struct {
    buffer: [message_size_max]u8 align(4) = undefined,
    size: u32 = header_size,

    fn init(kind: u16, flags: u16) Message {
        var message: Message = .{};
        @memset(message.buffer[0..header_size], 0);
        std.mem.writeInt(u16, message.buffer[4..6], kind, .little);
        std.mem.writeInt(u16, message.buffer[6..8], flag_request | flag_ack | flags, .little);
        return message;
    }

    fn append_bytes(message: *Message, bytes: []const u8) void {
        const padded = std.mem.alignForward(u32, @intCast(bytes.len), 4);
        assert(message.size + padded <= message_size_max);
        @memcpy(message.buffer[message.size..][0..bytes.len], bytes);
        @memset(message.buffer[message.size + bytes.len ..][0 .. padded - bytes.len], 0);
        message.size += padded;
    }

    fn attribute(message: *Message, kind: u16, value: []const u8) void {
        var header: [4]u8 = undefined;
        std.mem.writeInt(u16, header[0..2], @intCast(4 + value.len), .little);
        std.mem.writeInt(u16, header[2..4], kind, .little);
        assert(message.size % 4 == 0);
        message.append_bytes(&header);
        message.append_bytes(value);
    }

    /// Starts a nested attribute; returns its offset for `nest_end`.
    fn nest_begin(message: *Message, kind: u16) u32 {
        const offset = message.size;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u16, header[0..2], 0, .little);
        std.mem.writeInt(u16, header[2..4], kind, .little);
        message.append_bytes(&header);
        return offset;
    }

    fn nest_end(message: *Message, offset: u32) void {
        assert(offset < message.size);
        const size: u16 = @intCast(message.size - offset);
        std.mem.writeInt(u16, message.buffer[offset..][0..2], size, .little);
    }

    fn finish(message: *Message, sequence: u32) void {
        assert(message.size >= header_size);
        std.mem.writeInt(u32, message.buffer[0..4], message.size, .little);
        std.mem.writeInt(u32, message.buffer[8..12], sequence, .little);
    }
};

/// Runs `operation` with the calling thread in the network namespace of process `pid`, then
/// returns to the namespace of process 1 (the guest's root namespace).
pub fn in_namespace_of(pid: linux.pid_t, operation: anytype, arguments: anytype) !void {
    assert(pid > 0);
    try namespace_enter(pid);
    defer namespace_enter(1) catch unreachable; // The root namespace always exists.
    var socket = try Socket.open();
    defer socket.close();
    return @call(.auto, operation, .{&socket} ++ arguments);
}

fn namespace_enter(pid: linux.pid_t) !void {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/ns/net", .{pid}, 0) catch
        unreachable;
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(fd) != .SUCCESS) return error.NoSuchNamespace;
    defer _ = linux.close(@intCast(fd));
    if (linux.errno(linux.setns(@intCast(fd), linux.CLONE.NEWNET)) != .SUCCESS) {
        return error.SetnsFailed;
    }
}

test "attributes are aligned and nests sized" {
    var message: Message = .init(rtm_newlink, 0);
    message.append_bytes(&@as([ifinfo_size]u8, @splat(0)));
    const nest = message.nest_begin(ifla_linkinfo);
    message.attribute(ifla_info_kind, "veth");
    message.nest_end(nest);
    message.finish(1);
    // The nest: its own header, then "veth" with its header (4 + 4).
    try std.testing.expectEqual(@as(u32, header_size + ifinfo_size + 4 + 8), message.size);
    const nest_size = std.mem.readInt(u16, message.buffer[nest..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 4 + 8), nest_size);
}
