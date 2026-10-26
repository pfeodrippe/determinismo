// SPDX-License-Identifier: MIT
//! Example test program: the Clojure compiler and runtime under test (docs/PLAN.md, real
//! targets). Clojure 1.12.6 runs patched (clojure.patch): the Java SDK's assertions mark its
//! rare paths (STM barging and retries, hash collision nodes, lazy
//! seqs realized from several threads, boxed loop locals, case hash collisions, reflection over
//! overloads), which the tree explorer returns to, and buggify points widen its race windows. The
//! service (app/compiler_check.clj) checks properties that need no reference answer.
//!
//! Scenarios: `stm` (transfers and write skew between refs, from concurrent requests), `forms`
//! (generated forms evaluated under every compiler option set), `lazy` (one lazy seq realized by
//! several threads). `--scenario all` explores them all.
const std = @import("std");
const sdk = @import("determinismo");

const Nodes = struct { clojure: sdk.Node };
const System = sdk.System(Nodes);

const port = 7100;
const requests_per_driver = 6;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{
        .stm = Check(&.{ "stm", "skew" }).scenario,
        .forms = Check(&.{"form"}).scenario,
        .lazy = Check(&.{"lazy"}).scenario,
    } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.clojure, .{
        .build = .{ .context = ".", .dockerfile = "examples/clojure-compiler/Dockerfile" },
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
                const command = commands[sdk.random_below(commands.len)];
                check(context.nodes.clojure.address, command) catch |err| {
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
            const address = context.nodes.clojure.address;
            sdk.retry(120, 250, check, .{ address, commands[0] }) catch |err| {
                sdk.assert_unreachable("the service never answers again", .{});
                return err;
            };
        }
    };
}
