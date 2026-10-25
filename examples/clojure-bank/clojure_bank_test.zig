// SPDX-License-Identifier: MIT
//! Example test program for a JVM service: the Clojure bank (app/bank.clj), ten accounts in an
//! atom with a lost update, a socket REPL for debugging sessions, and the Clojure SDK
//! (sdk/clojure) for its own assertions and its TLA+ trace (tla/Bank.tla).
//!
//! The system: one node built from app/Dockerfile. Scenario `bank`: the JVM warms up, drivers
//! send random transfers, and once faults stop the total must still be 1000. A debugging
//! session redefines the buggy function through the REPL at a moment and lets the branch go on:
//!   determinismo explore ... --program zig-out/bin/clojure-bank-test --scenario bank \
//!     --branch B --at-vtime-ms T --continue --exec "det-nodes exec bank /app/patch.sh"
const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("determinismo");

const Nodes = struct { bank: sdk.Node };
const System = sdk.System(Nodes);

const bank_port = 7000;
const account_count = 10;
const balance_total = 1000;
const transfers_per_driver = 15;
const amount_max = 40;
const audit_attempts_max = 100;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .bank = bank } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.bank, .{
        .build = .{ .context = ".", .dockerfile = "examples/clojure-bank/app/Dockerfile" },
        .ready = .{ .tcp = bank_port },
    });
}

fn bank(s: *System.Scenario) void {
    s.first("warmup", warmup);
    s.parallel_driver("transfer", transfer_many);
    s.finally("audit", audit);
}

/// The JVM warms up before the load (and a debugging session gets a quiet moment).
fn warmup(_: *System.Context) !void {
    sdk.sleep_ms(1000);
}

/// Random transfers, one connection each; faults may make the service unreachable meanwhile.
fn transfer_many(context: *System.Context) !void {
    for (0..transfers_per_driver) |_| {
        const from = sdk.random_below(account_count);
        const to = (from + 1 + sdk.random_below(account_count - 1)) % account_count;
        const amount = 1 + sdk.random_below(amount_max);
        var request_buffer: [64]u8 = undefined;
        const request = std.fmt.bufPrint(&request_buffer, "transfer {d} {d} {d}\n", .{
            from, to, amount,
        }) catch unreachable;
        var reply_buffer: [64]u8 = undefined;
        const address = context.nodes.bank.address;
        const reply = sdk.tcp.request_line(address, bank_port, request, &reply_buffer) catch |err| {
            if (!sdk.tcp.unavailable(err)) return err;
            const details = .{ .err = @errorName(err) };
            sdk.sometimes(true, "the bank was unavailable to a driver", details);
            return;
        };
        sdk.always(std.mem.eql(u8, reply, "ok"), "transfers are acknowledged", .{});
    }
}

/// Faults are over: the bank answers again, and no money appeared or disappeared.
fn audit(context: *System.Context) !void {
    var reply_buffer: [64]u8 = undefined;
    const address = context.nodes.bank.address;
    const reply = sdk.retry(audit_attempts_max, 50, sdk.tcp.request_line, .{
        address, bank_port, "total\n", &reply_buffer,
    }) catch |err| {
        sdk.assert_unreachable("the bank answers once faults stop", .{ .err = @errorName(err) });
        return err;
    };
    const total = std.fmt.parseInt(i64, reply, 10) catch return error.BadReply;
    sdk.always(total == balance_total, "total balance is conserved", .{ .total = total });
}
