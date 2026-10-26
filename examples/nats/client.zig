// SPDX-License-Identifier: MIT
//! A NATS client for test programs: the text protocol (CONNECT, PUB, SUB, MSG and HMSG, PING) and
//! the JetStream requests the NATS example needs, each a request on one inbox subscription.
//!
//!   var client: Client = undefined;
//!   try client.open(address, 4222, .{ .timeout_ms = 5000 });
//!   defer client.close();
//!   const reply = try client.request("jepsen.p", "4-17", &buffer); // A JetStream publish.
const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("determinismo");
const tcp = sdk.tcp;

pub const Reply = struct {
    /// 0 for a message; for an HMSG, its status (503: no responders, 404: no messages, 408: the
    /// pull request expired), 0 when it has none.
    status: u16,
    /// For a message delivered by a consumer: its reply subject (the ack subject, which carries
    /// the stream sequence).
    reply_to: []const u8,
    payload: []const u8,
};

pub const Client = struct {
    connection: tcp.Connection,
    /// "_INBOX.<random>": requests are answered on "<inbox>.<n>".
    inbox: [32]u8,
    inbox_len: u8,
    requests: u64,

    pub fn open(client: *Client, address: [4]u8, port: u16, options: tcp.Options) !void {
        try client.connection.open(address, port, options);
        errdefer client.connection.close();
        const info = try client.connection.read_line();
        if (!std.mem.startsWith(u8, info, "INFO ")) return error.BadReply;
        try client.connection.write_all("CONNECT {\"verbose\":false,\"pedantic\":false," ++
            "\"headers\":true,\"no_responders\":true,\"protocol\":1}\r\nPING\r\n");
        while (true) {
            const line = try client.connection.read_line();
            if (std.mem.eql(u8, line, "PONG")) break;
            if (std.mem.startsWith(u8, line, "-ERR")) return error.Refused;
        }
        var id: [8]u8 = undefined;
        sdk.random_bytes(&id);
        const inbox = try std.fmt.bufPrint(&client.inbox, "_INBOX.{x}", .{id});
        client.inbox_len = @intCast(inbox.len);
        client.requests = 0;
        var line_buffer: [64]u8 = undefined;
        try client.connection.write_all(try std.fmt.bufPrint(&line_buffer, "SUB {s}.* 1\r\n", .{inbox}));
    }

    pub fn close(client: *Client) void {
        client.connection.close();
    }

    /// Publishes `payload` to `subject` with a reply subject, and returns the first message on
    /// it (copied into `buffer`).
    pub fn request(client: *Client, subject: []const u8, payload: []const u8, buffer: []u8) !Reply {
        const reply_subject = try client.publish(subject, payload);
        return client.next(reply_subject, .reply, buffer);
    }

    /// Publishes with a fresh reply subject, and returns it (valid until the next publish).
    pub fn publish(client: *Client, subject: []const u8, payload: []const u8) ![]const u8 {
        client.requests += 1;
        const reply_subject = try std.fmt.bufPrint(&reply_buffer, "{s}.{d}", .{
            client.inbox[0..client.inbox_len], client.requests,
        });
        var head_buffer: [256]u8 = undefined;
        const head = try std.fmt.bufPrint(&head_buffer, "PUB {s} {s} {d}\r\n", .{
            subject, reply_subject, payload.len,
        });
        try client.connection.write_all(head);
        try client.connection.write_all(payload);
        try client.connection.write_all("\r\n");
        return reply_subject;
    }

    var reply_buffer: [64]u8 = undefined;

    /// What `next` waits for: the answer to a request (a message on its reply subject), or what
    /// a pull request delivers (messages under their own subjects, with an ack subject, then a
    /// status on the pull's reply subject when fewer than the batch were left).
    pub const Awaited = enum { reply, delivery };

    /// The next message awaited (others, late answers to earlier requests, are skipped),
    /// answering the server's PINGs meanwhile.
    pub fn next(client: *Client, reply_subject: []const u8, awaited: Awaited, buffer: []u8) !Reply {
        var subject_buffer: [64]u8 = undefined;
        assert(reply_subject.len <= subject_buffer.len);
        @memcpy(subject_buffer[0..reply_subject.len], reply_subject);
        const wanted = subject_buffer[0..reply_subject.len];
        while (true) {
            const line = try client.connection.read_line();
            if (std.mem.eql(u8, line, "PING")) {
                try client.connection.write_all("PONG\r\n");
                continue;
            }
            if (std.mem.startsWith(u8, line, "-ERR")) return error.Refused;
            const headers = std.mem.startsWith(u8, line, "HMSG ");
            if (!headers and !std.mem.startsWith(u8, line, "MSG ")) continue; // +OK, INFO, PONG.
            // MSG <subject> <sid> [reply-to] <bytes>, HMSG <subject> <sid> [reply-to] <header
            // bytes> <bytes>.
            var words: [6][]const u8 = undefined;
            var count: usize = 0;
            var tokens = std.mem.tokenizeScalar(u8, line, ' ');
            while (tokens.next()) |token| : (count += 1) {
                if (count == words.len) return error.BadReply;
                words[count] = token;
            }
            const fixed: usize = if (headers) 5 else 4; // Words without a reply subject.
            if (count != fixed and count != fixed + 1) return error.BadReply;
            const total = std.fmt.parseInt(u32, words[count - 1], 10) catch return error.BadReply;
            const header_size = if (headers)
                std.fmt.parseInt(u32, words[count - 2], 10) catch return error.BadReply
            else
                0;
            var reply_to_buffer: [128]u8 = undefined;
            const reply_to: []const u8 = if (count == fixed + 1) blk: {
                const word = words[3];
                if (word.len > reply_to_buffer.len) return error.BadReply;
                @memcpy(reply_to_buffer[0..word.len], word);
                break :blk reply_to_buffer[0..word.len];
            } else "";
            const delivered = awaited == .delivery and std.mem.startsWith(u8, reply_to, "$JS.ACK.");
            const matches = delivered or std.mem.eql(u8, words[1], wanted);
            const body = try client.connection.read_exact(total + 2); // And its \r\n.
            if (!matches) continue;
            if (header_size > total) return error.BadReply;
            const status = if (headers) status_of(body[0..header_size]) else 0;
            const payload = body[header_size..total];
            const needed = payload.len + reply_to.len;
            if (needed > buffer.len) return error.ReplyTooLarge;
            @memcpy(buffer[0..payload.len], payload);
            @memcpy(buffer[payload.len..][0..reply_to.len], reply_to);
            return .{
                .status = status,
                .payload = buffer[0..payload.len],
                .reply_to = buffer[payload.len..][0..reply_to.len],
            };
        }
    }
};

/// "NATS/1.0 503\r\n..." or "NATS/1.0 404 No Messages\r\n...": the status, 0 when there is none.
fn status_of(headers: []const u8) u16 {
    const first_end = std.mem.indexOf(u8, headers, "\r\n") orelse headers.len;
    var words = std.mem.tokenizeScalar(u8, headers[0..first_end], ' ');
    _ = words.next(); // NATS/1.0
    const code = words.next() orelse return 0;
    return std.fmt.parseInt(u16, code, 10) catch 0;
}

/// The stream sequence in a JetStream message's ack subject:
/// $JS.ACK.<stream>.<consumer>.<delivered>.<stream seq>.<consumer seq>.<time>.<pending>, with a
/// domain and an account hash before the stream in newer servers (then 11 or 12 tokens).
pub fn ack_stream_sequence(reply_to: []const u8) ?u64 {
    var tokens: [16][]const u8 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, reply_to, '.');
    while (parts.next()) |part| : (count += 1) {
        if (count == tokens.len) return null;
        tokens[count] = part;
    }
    if (count < 9 or !std.mem.eql(u8, tokens[0], "$JS") or !std.mem.eql(u8, tokens[1], "ACK")) {
        return null;
    }
    // Counted from the end: <stream seq> <consumer seq> <time> <pending> [random].
    const from_end: usize = if (count == 9 or count == 11) 4 else 5;
    return std.fmt.parseInt(u64, tokens[count - from_end], 10) catch null;
}

test status_of {
    try std.testing.expectEqual(@as(u16, 503), status_of("NATS/1.0 503\r\n\r\n"));
    try std.testing.expectEqual(@as(u16, 404), status_of("NATS/1.0 404 No Messages\r\n\r\n"));
    try std.testing.expectEqual(@as(u16, 0), status_of("NATS/1.0\r\nA: b\r\n\r\n"));
}

test ack_stream_sequence {
    try std.testing.expectEqual(@as(?u64, 17), ack_stream_sequence("$JS.ACK.jepsen.c1.1.17.3.1700000000000000000.0"));
    try std.testing.expectEqual(@as(?u64, 17), ack_stream_sequence("$JS.ACK.domain.hash.jepsen.c1.1.17.3.1700000000000000000.0"));
    try std.testing.expectEqual(@as(?u64, 17), ack_stream_sequence("$JS.ACK.domain.hash.jepsen.c1.1.17.3.1700000000000000000.0.rnd"));
    try std.testing.expectEqual(@as(?u64, null), ack_stream_sequence("_INBOX.abc.1"));
}
