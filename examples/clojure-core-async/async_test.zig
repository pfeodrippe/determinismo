// SPDX-License-Identifier: MIT
//! Example test program: core.async under test (docs/PLAN.md, real targets). core.async 1.9.865
//! runs patched (core-async.patch): the Clojure SDK's assertions mark its rare paths (closed
//! channels, handoffs to parked peers, alts! peers already done, lock order, reduced
//! transducers, go blocks parking and throwing, shared timeouts), which the tree explorer returns
//! to, buggify points widen its race windows, and alts!'s port order is a platform decision. The
//! service (app/async_check.clj) checks what core.async promises: nothing lost or duplicated,
//! order kept per producer and through pipelines, every mult tap served, a go block's catch and
//! finally after parks, and no timeout early.
//!
//! One scenario per check (`--scenario all` explores them all): channels, alts, pipeline, mult,
//! go, timeout.
const std = @import("std");
const sdk = @import("determinismo");

const Nodes = struct { async: sdk.Node };
const System = sdk.System(Nodes);

const port = 7200;
const requests_per_driver = 6;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{
        .channels = Check("channels").scenario,
        .alts = Check("alts").scenario,
        .pipeline = Check("pipeline").scenario,
        .mult = Check("mult").scenario,
        .go = Check("go").scenario,
        .timeout = Check("timeout").scenario,
    } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.async, .{
        .build = .{ .context = ".", .dockerfile = "examples/clojure-core-async/Dockerfile" },
        .ready = .{ .tcp = port },
    });
}

/// A scenario of concurrent requests for one check, then the service answering once faults
/// stop.
fn Check(comptime command: []const u8) type {
    return struct {
        fn scenario(s: *System.Scenario) void {
            s.parallel_driver("check", check_many);
            s.eventually("answers", answers);
        }

        fn check_many(context: *System.Context) !void {
            for (0..requests_per_driver) |_| {
                check(context.nodes.async.address) catch |err| {
                    if (!sdk.tcp.unavailable(err)) return err;
                    sdk.sometimes(true, "the service was unavailable to a driver", .{});
                    return;
                };
            }
        }

        fn check(address: [4]u8) !void {
            var reply_buffer: [512]u8 = undefined;
            const reply = try sdk.tcp.request_line(address, port, command ++ "\n", &reply_buffer);
            // An error reply is a check that threw (the reply says what); what failed is in the
            // service's own assertions.
            const ok = std.mem.eql(u8, reply, "ok");
            sdk.sometimes(ok, "a check completes", .{});
            sdk.always(ok or std.mem.startsWith(u8, reply, "error "), "every check exists", .{
                .reply = reply,
            });
        }

        fn answers(context: *System.Context) !void {
            const address = context.nodes.async.address;
            sdk.retry(120, 250, check, .{address}) catch |err| {
                sdk.assert_unreachable("the service never answers again", .{});
                return err;
            };
        }
    };
}
