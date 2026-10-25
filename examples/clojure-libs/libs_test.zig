// SPDX-License-Identifier: MIT
//! Example test program: Clojure's most used libraries (app/deps.edn) under concurrency and
//! faults, through one http-kit service (app/src/libs.clj) whose endpoints each run a randomized
//! check of one library, with the Clojure SDK's assertions and platform randomness.
//!
//! One scenario per library (`--scenario all` explores them all): drivers call its check
//! concurrently while faults run; once faults stop, the service answers again.
const std = @import("std");
const sdk = @import("determinismo");

const Nodes = struct { libs: sdk.Node };
const System = sdk.System(Nodes);

const port = 8080;
const checks_per_driver = 10;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{
        .cheshire = Library("cheshire").scenario,
        .jsonista = Library("jsonista").scenario,
        .@"data-json" = Library("data-json").scenario,
        .@"clj-yaml" = Library("clj-yaml").scenario,
        .nippy = Library("nippy").scenario,
        .malli = Library("malli").scenario,
        .@"core-async" = Library("core-async").scenario,
        .@"core-async-timeout" = Library("core-async-timeout").scenario,
        .manifold = Library("manifold").scenario,
    } });
}

fn describe(d: *System.Describe) !void {
    const default = try d.profile("default");
    default.node(.libs, .{
        .build = .{ .context = ".", .dockerfile = "examples/clojure-libs/Dockerfile" },
        .ready = .{ .tcp = port },
    });
}

/// One library's scenario: the same shape for every library, as a function of its name.
fn Library(comptime name: []const u8) type {
    return struct {
        const path = "/check/" ++ name;

        fn scenario(s: *System.Scenario) void {
            s.parallel_driver("check", check_many);
            s.eventually("answers", answers);
        }

        fn check_many(context: *System.Context) !void {
            for (0..checks_per_driver) |_| {
                check(context.nodes.libs.address) catch |err| {
                    if (!sdk.tcp.unavailable(err)) return err;
                    sdk.sometimes(true, "the service was unavailable to a driver", .{});
                    return;
                };
            }
        }

        fn check(address: [4]u8) !void {
            var buffer: [512]u8 = undefined;
            const response = try sdk.tcp.http(address, port, "GET", path, "", &buffer);
            // 500: the check threw (an event says what); the assertions say what failed.
            sdk.always(response.status != 404, "every check exists", .{});
        }

        fn answers(context: *System.Context) !void {
            sdk.retry(120, 250, check, .{context.nodes.libs.address}) catch |err| {
                sdk.assert_unreachable("the service never answers again", .{});
                return err;
            };
        }
    };
}
