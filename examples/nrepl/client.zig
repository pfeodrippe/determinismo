// SPDX-License-Identifier: MIT
//! An nREPL client for test programs: a connection, the session it cloned, and requests with
//! their replies merged (bencode.zig is the wire format). Shared by the nREPL and
//! clojure-cli.repl examples.
const std = @import("std");
const sdk = @import("determinismo");
pub const bencode = @import("bencode.zig");

pub const Client = struct {
    connection: sdk.tcp.Connection = undefined,
    session: []const u8 = "",
    arena_state: std.heap.ArenaAllocator,
    /// Request ids count from here: distinct starts keep several clients' ids apart.
    next_id: u32 = 0,
    /// How long a read waits (virtual time) before the server counts as not answering.
    timeout_ms: u32 = 5000,

    pub fn init() Client {
        return .{ .arena_state = .init(std.heap.page_allocator) };
    }

    /// Connects and clones a session (`clone`: every request after it is in that session).
    pub fn open(client: *Client, address: [4]u8, port: u16) !void {
        try client.connection.open(address, port, .{ .timeout_ms = client.timeout_ms });
        errdefer client.connection.close();
        const reply = try client.call(&.{.{ "op", "clone" }});
        client.session = reply.new_session orelse return error.NoSession;
    }

    pub fn close(client: *Client) void {
        client.connection.close();
        client.arena_state.deinit();
    }

    pub fn allocator(client: *Client) std.mem.Allocator {
        return client.arena_state.allocator();
    }

    /// Sends a request (the id and the session added); returns its id.
    pub fn send(client: *Client, fields: []const [2][]const u8) ![]const u8 {
        client.next_id += 1;
        const id = try std.fmt.allocPrint(client.allocator(), "{d}", .{client.next_id});
        var all: [14][2][]const u8 = undefined;
        std.debug.assert(fields.len + 2 <= all.len);
        @memcpy(all[0..fields.len], fields);
        all[fields.len] = .{ "id", id };
        var count = fields.len + 1;
        if (client.session.len > 0) {
            all[count] = .{ "session", client.session };
            count += 1;
        }
        var buffer: [16 * 1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try bencode.request_write(&writer, all[0..count]);
        try client.connection.write_all(writer.buffered());
        return id;
    }

    /// The replies to request `id` until its "done", merged.
    pub fn collect(client: *Client, id: []const u8) !Reply {
        const arena = client.allocator();
        var reply = Reply{};
        var out: std.ArrayList(u8) = .empty;
        var err: std.ArrayList(u8) = .empty;
        for (0..4096) |_| {
            const message = try bencode.read(arena, &client.connection);
            const for_id = message.string("id") orelse continue;
            if (!std.mem.eql(u8, for_id, id)) continue;
            if (message.string("value")) |value| reply.value = value;
            if (message.string("new-session")) |session| reply.new_session = session;
            if (message.string("ns")) |ns| reply.ns = ns;
            if (message.string("ex")) |ex| reply.ex = ex;
            if (message.string("out")) |text| try out.appendSlice(arena, text);
            if (message.string("err")) |text| try err.appendSlice(arena, text);
            if (message.status_has("interrupted")) reply.interrupted = true;
            if (message.status_has("eval-error")) reply.eval_error = true;
            if (message.status_has("done")) {
                reply.done = true;
                reply.last = message;
                reply.out = out.items;
                reply.err = err.items;
                return reply;
            }
        }
        return error.NoDone;
    }

    pub fn call(client: *Client, fields: []const [2][]const u8) !Reply {
        return client.collect(try client.send(fields));
    }

    /// Evaluates `code` in this session.
    pub fn eval(client: *Client, code: []const u8) !Reply {
        return client.call(&.{ .{ "op", "eval" }, .{ "code", code } });
    }

    /// The next message from the server, whatever request it answers.
    pub fn read(client: *Client) !bencode.Value {
        return bencode.read(client.allocator(), &client.connection);
    }
};

/// A request's replies, merged: the last value, all output, the status seen; `last` is the
/// message that said "done" (where middleware puts its data).
pub const Reply = struct {
    value: ?[]const u8 = null,
    new_session: ?[]const u8 = null,
    ns: ?[]const u8 = null,
    ex: ?[]const u8 = null,
    out: []const u8 = "",
    err: []const u8 = "",
    interrupted: bool = false,
    eval_error: bool = false,
    done: bool = false,
    last: bencode.Value = .{ .integer = 0 },
};

/// Errors that mean the server could not be reached or answered too late (faults), not that it
/// answered wrong.
pub fn unavailable(err: anyerror) bool {
    return sdk.tcp.unavailable(err) or err == error.NoDone or err == error.NoSession;
}
