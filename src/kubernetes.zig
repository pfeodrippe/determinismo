// SPDX-License-Identifier: MIT
//! The Kubernetes importer (`--k8s <manifests dir>`), as Antithesis's Kubernetes setup: a
//! single-node K3s cluster with the manifests applied (K3s's auto-deploy directory, as kapp
//! would), without the internet: every image the manifests name is given to K3s as an offline
//! archive. Test templates (/opt/antithesis/test/v1/<template>/ in any container's image) run
//! in their workload through `kubectl exec`, from scripts written into the K3s node at the same
//! paths, so the Compose importer's template rules apply unchanged; each template also gets a
//! setup command that waits until every workload is ready (what kapp deploy waits for).
//!
//! This file reads manifests and writes those files' contents; prepare.zig pulls, saves and
//! builds.
const std = @import("std");
const assert = std.debug.assert;
const schema = @import("determinismo").schema;
const yaml = @import("yaml.zig");

/// The node's name, and the K3s it runs (examples/k3s's).
pub const node_name = "k3s";
const k3s_image = "docker.io/rancher/k3s:v1.36.5-k3s1";
const k3s_airgap = "https://github.com/k3s-io/k3s/releases/download/v1.36.5%2Bk3s1/" ++
    "k3s-airgap-images-amd64.tar.zst";
pub const templates_root = "opt/antithesis/test/v1/";
/// The setup command every template gets (one per scenario: a template of the system's own
/// with a setup_ command too is refused by the composer).
pub const setup_name = "setup_kubernetes_ready";

pub const Container = struct { name: []const u8, image: []const u8 };

pub const Workload = struct {
    /// The resource kubectl names it by: deployment, statefulset, daemonset, job, pod, ...
    resource: []const u8,
    name: []const u8,
    namespace: []const u8,
    containers: []const Container,
    /// What "ready" means for it: rolled out (controllers), Ready (a pod), or nothing waited.
    wait: enum { rollout, ready, none },
};

/// The workloads of manifests (one or several YAML documents per file, `---` between them).
pub fn workloads(
    arena: std.mem.Allocator,
    text: []const u8,
    into: *std.ArrayList(Workload),
) !void {
    var document: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (true) {
        const line = lines.next();
        const separator = if (line) |l| std.mem.startsWith(u8, std.mem.trimEnd(u8, l, " \r"), "---")
        else true;
        if (separator) {
            try document_read(arena, document.items, into);
            document = .empty;
            if (line == null) break;
            continue;
        }
        try document.appendSlice(arena, line.?);
        try document.append(arena, '\n');
    }
}

fn document_read(arena: std.mem.Allocator, text: []const u8, into: *std.ArrayList(Workload)) !void {
    const meaningful = blk: {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0 and trimmed[0] != '#') break :blk true;
        }
        break :blk false;
    };
    if (!meaningful) return;
    const root = try yaml.parse(arena, text);
    const kind = scalar(root.get("kind")) orelse return;
    const metadata = root.get("metadata") orelse return;
    const name = scalar(metadata.get("name")) orelse return;
    const namespace = scalar(metadata.get("namespace")) orelse "default";
    const Wait = @FieldType(Workload, "wait");
    const Shape = struct { kind: []const u8, path: []const []const u8, wait: Wait };
    const cron = &.{ "spec", "jobTemplate", "spec", "template", "spec" };
    const shapes = [_]Shape{
        .{ .kind = "Deployment", .path = &.{ "spec", "template", "spec" }, .wait = .rollout },
        .{ .kind = "StatefulSet", .path = &.{ "spec", "template", "spec" }, .wait = .rollout },
        .{ .kind = "DaemonSet", .path = &.{ "spec", "template", "spec" }, .wait = .rollout },
        .{ .kind = "ReplicaSet", .path = &.{ "spec", "template", "spec" }, .wait = .none },
        .{ .kind = "Job", .path = &.{ "spec", "template", "spec" }, .wait = .none },
        .{ .kind = "CronJob", .path = cron, .wait = .none },
        .{ .kind = "Pod", .path = &.{"spec"}, .wait = .ready },
    };
    const shape = for (shapes) |known| {
        if (std.mem.eql(u8, known.kind, kind)) break known;
    } else return;
    var pod_spec = root;
    for (shape.path) |key| pod_spec = pod_spec.get(key) orelse return;
    var containers: std.ArrayList(Container) = .empty;
    for ([_][]const u8{ "initContainers", "containers" }) |field| {
        const list = pod_spec.get(field) orelse continue;
        if (list != .sequence) continue;
        for (list.sequence) |item| {
            const image = scalar(item.get("image")) orelse continue;
            const container_name = scalar(item.get("name")) orelse continue;
            try containers.append(arena, .{ .name = container_name, .image = image });
        }
    }
    try into.append(arena, .{
        .resource = try std.ascii.allocLowerString(arena, kind),
        .name = name,
        .namespace = namespace,
        .containers = containers.items,
        .wait = shape.wait,
    });
}

fn scalar(value: ?yaml.Value) ?[]const u8 {
    const known = value orelse return null;
    return if (known == .scalar) known.scalar else null;
}

/// The script, in the K3s node, that runs a container's test command in its workload.
pub fn wrapper(
    arena: std.mem.Allocator,
    workload: *const Workload,
    container: *const Container,
    path: []const u8,
) ![]const u8 {
    assert(std.mem.startsWith(u8, path, templates_root));
    return std.fmt.allocPrint(arena,
        \\#!/bin/sh
        \\# /{s} of container {s} in {s}/{s} (namespace {s}): determinismo's Kubernetes importer.
        \\exec /bin/kubectl exec -n {s} {s}/{s} -c {s} -- /{s}
        \\
    , .{
        path,               container.name,     workload.resource, workload.name,
        workload.namespace, workload.namespace, workload.resource, workload.name,
        container.name,     path,
    });
}

/// The setup command: the API serves, then every controller rolled out and every pod Ready.
pub fn setup_script(arena: std.mem.Allocator, all: []const Workload) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena,
        \\#!/bin/sh
        \\# The cluster serves and every workload of the manifests is ready (what kapp deploy
        \\# waits for): determinismo's Kubernetes importer.
        \\until /bin/kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 1; done
        \\
    );
    for (all) |workload| {
        const wait = switch (workload.wait) {
            .rollout => "rollout status --timeout=10s",
            .ready => "wait --for=condition=Ready --timeout=10s",
            .none => continue,
        };
        try out.print(arena, "until /bin/kubectl -n {s} {s} {s}/{s} >/dev/null 2>&1; " ++
            "do sleep 1; done\n", .{ workload.namespace, wait, workload.resource, workload.name });
    }
    return out.items;
}

/// The K3s node's image: K3s, its own images and the manifests' as offline archives, the
/// manifests where K3s applies them, and the generated test commands.
pub const dockerfile =
    "# Generated by determinismo's Kubernetes importer.\n" ++
    "FROM " ++ k3s_image ++ "\n" ++
    "ADD " ++ k3s_airgap ++ " /var/lib/rancher/k3s/agent/images/\n" ++
    "COPY images/ /var/lib/rancher/k3s/agent/images/\n" ++
    "COPY manifests/ /var/lib/rancher/k3s/server/manifests/\n" ++
    "COPY tests/ /\n";

/// The profile: one privileged node running a K3s server, from the generated build context.
pub fn profile(arena: std.mem.Allocator, build_context: []const u8) !schema.Profile {
    const nodes = try arena.alloc(schema.Node, 1);
    nodes[0] = .{
        .name = node_name,
        .source = .{ .build = .{ .context = build_context } },
        .command = &.{
            "server",                                    "--snapshotter=native",
            "--disable=traefik,servicelb,metrics-server", "--disable-cloud-controller",
            "--disable-helm-controller",                 "--write-kubeconfig-mode=644",
        },
        .env = &.{"KUBECONFIG=/etc/rancher/k3s/k3s.yaml"},
        .ready = .{ .tcp = 6443 },
        .privileged = true,
        // Faults inside the cluster: the node paused or throttled, its processes (the pods')
        // paused or killed (Kubernetes restarts them). One node: no links to cut.
        .faults = .{
            .isolate = false,
            .partition = false,
            .degrade = false,
            .process_kill = true,
        },
    };
    return .{ .name = "default", .nodes = nodes };
}

test workloads {
    var state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    const manifests =
        \\apiVersion: v1
        \\kind: Service
        \\metadata:
        \\  name: web
        \\---
        \\apiVersion: apps/v1
        \\kind: Deployment
        \\metadata:
        \\  name: web
        \\  namespace: shop
        \\spec:
        \\  template:
        \\    spec:
        \\      containers:
        \\        - name: server
        \\          image: docker.io/library/nginx:1.27
        \\        - name: client
        \\          image: example.com/client:1
        \\---
        \\# a comment only
        \\---
        \\kind: Pod
        \\metadata:
        \\  name: tool
        \\spec:
        \\  containers:
        \\    - name: tool
        \\      image: example.com/tool:2
    ;
    var found: std.ArrayList(Workload) = .empty;
    try workloads(arena, manifests, &found);
    try std.testing.expectEqual(@as(usize, 2), found.items.len);
    try std.testing.expectEqualStrings("deployment", found.items[0].resource);
    try std.testing.expectEqualStrings("shop", found.items[0].namespace);
    try std.testing.expectEqual(@as(usize, 2), found.items[0].containers.len);
    try std.testing.expectEqualStrings("example.com/tool:2", found.items[1].containers[0].image);
    const script = try wrapper(arena, &found.items[0], &found.items[0].containers[1],
        "opt/antithesis/test/v1/main/parallel_driver_buy.sh");
    try std.testing.expect(std.mem.indexOf(u8, script,
        "exec /bin/kubectl exec -n shop deployment/web -c client -- " ++
        "/opt/antithesis/test/v1/main/parallel_driver_buy.sh") != null);
    const setup = try setup_script(arena, found.items);
    try std.testing.expect(std.mem.indexOf(u8, setup, "-n shop rollout status") != null);
    try std.testing.expect(std.mem.indexOf(u8, setup, "pod/tool") != null);
}
