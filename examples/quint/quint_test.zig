// SPDX-License-Identifier: MIT
//! Example test program: Quint (github.com/quint-co/quint, v0.33.0), a specification language of
//! the TLA family, under test: its CLI (TypeScript) and its Rust evaluator (v0.7.0) run patched
//! (quint.patch), asserting through determinismo's JavaScript and Rust SDKs (an internal error
//! anywhere, a panic, the simulator's own invariants). The service (app/quint_check.js) checks
//! properties that need no reference answer.
//!
//! Scenarios: `eval` (generated expressions on both backends: the same value, or Rust's
//! documented 64-bit limit), `simulate` (the same seed, the same simulation), `test` (the
//! examples' tests pass on both backends), `typecheck` (mutated specifications: an answer, the
//! same twice, never an internal error). `--scenario all` explores them all.
//!
//!   determinismo explore ... --memory-mib 4096 --program zig-out/bin/quint-test --scenario all
const std = @import("std");
const sdk = @import("determinismo");

const Nodes = struct { quint: sdk.Node };
const System = sdk.System(Nodes);

const port = 7200;
const requests_per_driver = 4;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{
        .eval = Check(&.{"eval"}).scenario,
        .simulate = Check(&.{"simulate"}).scenario,
        .@"test" = Check(&.{"test"}).scenario,
        .typecheck = Check(&.{"typecheck"}).scenario,
        .all = Check(&.{ "eval", "simulate", "test", "typecheck" }).scenario,
    } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.quint, .{
        .build = .{ .context = ".", .dockerfile = "examples/quint/Dockerfile" },
        .ready = .{ .tcp = port },
    });
}

/// A scenario of concurrent requests, each one of `commands` (a platform decision), then the
/// service answering once faults stop.
fn Check(comptime commands: []const []const u8) type {
    return struct {
        fn scenario(s: *System.Scenario) void {
            s.parallel_driver("check", check_many);
            s.eventually("answers", answers);
        }

        fn check_many(context: *System.Context) !void {
            for (0..requests_per_driver) |_| {
                const command = commands[sdk.decide("quint.command", commands)];
                check(context.nodes.quint.address, command) catch |err| {
                    if (!sdk.tcp.unavailable(err)) return err;
                    sdk.sometimes(true, "the service was unavailable to a driver", .{});
                    return;
                };
            }
        }

        fn check(address: [4]u8, command: []const u8) !void {
            var request_buffer: [16]u8 = undefined;
            const request = std.fmt.bufPrint(&request_buffer, "{s}\n", .{command}) catch
                unreachable;
            var reply_buffer: [512]u8 = undefined;
            const reply = try sdk.tcp.request_line(address, port, request, &reply_buffer);
            // An error reply is a check that threw (the reply says what); what failed is in the
            // service's own assertions.
            const ok = std.mem.eql(u8, reply, "ok");
            sdk.sometimes(ok, "a check completes", .{});
            sdk.always(ok or std.mem.startsWith(u8, reply, "error "), "every check exists", .{
                .reply = reply,
            });
        }

        fn answers(context: *System.Context) !void {
            const address = context.nodes.quint.address;
            sdk.retry(120, 500, check, .{ address, commands[0] }) catch |err| {
                sdk.assert_unreachable("the service never answers again", .{});
                return err;
            };
        }
    };
}
