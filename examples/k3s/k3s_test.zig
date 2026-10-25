// SPDX-License-Identifier: MIT
//! Example test program: Kubernetes (K3s) as the system under test. The workload (manifests/,
//! a Deployment and its Service) runs in pods; images come from K3s's air-gap bundle, since the
//! guest has no network.
//!
//! Profiles:
//!   single    one privileged node runs a K3s server (give the machine --memory-mib 4096)
//!   cluster   a server and two agents, each in its own node, so faults partition Kubernetes
//!             nodes from each other; pods on different nodes talk over flannel's vxlan, carried
//!             by determinismo's links (--memory-mib 8192)
//! Scenario `cluster`: the cluster comes up and serves (setup, before branching), clients go
//! through the Service under faults, and once faults stop Kubernetes recovers the workload.
//!
//! The Service's address only routes inside the cluster, so the commands run there: kubectl and
//! wget in the server node, through `exec`.
const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("determinismo");

const Nodes = struct { server: sdk.Node, @"agent-a": ?sdk.Node, @"agent-b": ?sdk.Node };
const System = sdk.System(Nodes);

const token = "K3S_TOKEN=determinismo";
const kubeconfig = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml";
const kubectl = "/bin/kubectl";
const server_command = [_][]const u8{
    "server",                                                   "--snapshotter=native",
    "--disable=traefik,servicelb,metrics-server,local-storage", "--disable-cloud-controller",
    "--disable-helm-controller",                                "--write-kubeconfig-mode=644",
};
const agent_command = [_][]const u8{ "agent", "--snapshotter=native" };
const ready_attempts_max = 600;
const requests_per_driver = 5;
const recovery_attempts_max = 60;

pub fn main(init: std.process.Init) !void {
    return System.main(init, .{ .describe = describe, .scenarios = .{ .cluster = cluster } });
}

fn describe(d: *System.Describe) !void {
    const server: System.Spec = .{
        .build = .{ .context = ".", .dockerfile = "examples/k3s/Dockerfile" },
        .command = &server_command,
        .env = &.{ token, kubeconfig },
        .ready = .{ .tcp = 6443 },
        .privileged = true,
    };
    const agent: System.Spec = .{
        .build = .{ .context = ".", .dockerfile = "examples/k3s/Dockerfile.agent" },
        .command = &agent_command,
        .env = &.{ token, "K3S_URL=https://server:6443" },
        .ready = .{ .tcp = 10250 },
        .after = &.{.server},
        .privileged = true,
    };
    const single = try d.profile("single");
    single.node(.server, server);
    const three = try d.profile("cluster");
    three.node(.server, server);
    three.node(.@"agent-a", agent);
    three.node(.@"agent-b", agent);
}

fn cluster(s: *System.Scenario) void {
    s.setup("ready", ready);
    s.parallel_driver("get", get);
    s.eventually("serves", serves);
}

/// Every Kubernetes node is Ready and the workload serves: branches start from here.
fn ready(context: *System.Context) !void {
    const server = &context.nodes.server;
    const nodes_wanted: u32 = 1 + @as(u32, @intFromBool(context.nodes.@"agent-a" != null)) +
        @intFromBool(context.nodes.@"agent-b" != null);
    _ = try sdk.retry(ready_attempts_max, 1000, nodes_ready, .{ server, nodes_wanted });
    // Pods were scheduled before the agents joined: spread them again, one per node.
    if (nodes_wanted > 1) {
        _ = try server.exec(&.{ kubectl, "rollout", "restart", "deployment/web" });
    }
    _ = try sdk.retry(ready_attempts_max, 1000, rolled_out, .{server});
    _ = try sdk.retry(ready_attempts_max, 1000, service_answers, .{server});
}

/// Requests through the Service, as clients would; failures are expected under faults.
fn get(context: *System.Context) !void {
    const server = &context.nodes.server;
    var answered: u32 = 0;
    for (0..requests_per_driver) |_| {
        service_answers(server) catch continue;
        answered += 1;
    }
    sdk.sometimes(answered == requests_per_driver, "every request of a client is answered", .{});
    sdk.sometimes(answered < requests_per_driver, "faults keep some requests unanswered", .{});
}

/// Once faults stop, the Service answers again: Kubernetes recovered the workload.
fn serves(context: *System.Context) !void {
    sdk.retry(recovery_attempts_max, 1000, service_answers, .{&context.nodes.server}) catch |err| {
        sdk.assert_unreachable("the service answers once faults stop", .{ .err = @errorName(err) });
        return err;
    };
    sdk.reachable("the workload recovered", .{});
}

fn nodes_ready(server: *const sdk.Node, wanted: u32) !void {
    var buffer: [4096]u8 = undefined;
    const listed = try server.exec_output(&.{ kubectl, "get", "nodes", "--no-headers" }, &buffer);
    if (listed.status != 0) return error.KubectlFailed;
    const count = std.mem.count(u8, listed.output, " Ready ");
    if (count < wanted) return error.NodesNotReady;
}

fn rolled_out(server: *const sdk.Node) !void {
    const status = try server.exec(&.{
        kubectl, "rollout", "status", "deployment/web", "--timeout=10s",
    });
    if (status != 0) return error.NotRolledOut;
}

/// One request to the Service's cluster address, from inside the cluster; it answers "ok".
fn service_answers(server: *const sdk.Node) !void {
    var address_buffer: [64]u8 = undefined;
    const address = try server.exec_output(&.{
        kubectl, "get", "service", "web", "-o", "jsonpath={.spec.clusterIP}",
    }, &address_buffer);
    if (address.status != 0 or address.output.len == 0) return error.NoService;
    var url_buffer: [96]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://{s}", .{address.output});
    var body_buffer: [256]u8 = undefined;
    const body = try server.exec_output(&.{ "wget", "-qO-", "-T", "2", url }, &body_buffer);
    if (body.status != 0 or std.mem.indexOf(u8, body.output, "ok") == null) {
        return error.NotServed;
    }
}
