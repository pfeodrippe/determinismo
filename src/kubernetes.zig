// SPDX-License-Identifier: MIT
//! Imports Kubernetes manifests as a profile (`explore --kubernetes <manifests directory>`), as
//! Antithesis runs them (docs: setup/kubernetes): a single-node K3s cluster, with CoreDNS and the
//! local-path storage class, without Traefik, ServiceLB or metrics-server, in one privileged node
//! named `kubernetes`. The guest has no network, so the node's image holds K3s's air-gap images
//! and every image the manifests name (fully qualified, as Antithesis asks), which K3s imports as
//! it starts.
//!
//! Antithesis deploys the manifests with kapp (a logical order, then waits until they are
//! ready); here the scenario's first command does it (`ready_path`): it applies them until all
//! of them apply, gives every container of the workload the Antithesis SDK's output (the node's
//! /opt/determinismo/sdk, as a hostPath volume), and waits until every Deployment, StatefulSet
//! and DaemonSet is rolled out and every running pod is ready. setup_complete follows it.
//!
//! Test templates may be in any container (/opt/antithesis/test/v1/<template>/): each one found
//! in an image the manifests name gets a wrapper at the same path in the node, which runs it in
//! a running container of that image through kubectl exec. Bare Pods are not patched for the
//! SDK (a running pod's volumes cannot change).
const std = @import("std");
const assert = std.debug.assert;

pub const node_name = "kubernetes";
pub const k3s_image = "docker.io/rancher/k3s:v1.36.5-k3s1";
const airgap_url = "https://github.com/k3s-io/k3s/releases/download/v1.36.5%2Bk3s1/" ++
    "k3s-airgap-images-amd64.tar.zst";
/// Outside /opt/determinismo, which a node gets from the runner (read-only, over the image's).
pub const tools_directory = "/opt/determinismo-kubernetes";
pub const ready_path = tools_directory ++ "/ready";
const exec_path = tools_directory ++ "/exec";
pub const manifests_directory = tools_directory ++ "/manifests";
pub const command = [_][]const u8{
    "server",                                     "--snapshotter=native",
    "--disable=traefik,servicelb,metrics-server", "--disable-cloud-controller",
    "--disable-helm-controller",                  "--write-kubeconfig-mode=644",
};
pub const kubeconfig = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml";
pub const api_port = 6443;
const images_max = 64;

/// The images a manifest names (its `image:` fields, YAML or JSON), each once, added to
/// `images` in order.
pub fn images_note(arena: std.mem.Allocator, manifest: []const u8, images: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.tokenizeAny(u8, manifest, "\r\n");
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t");
        if (std.mem.startsWith(u8, line, "- ")) line = std.mem.trimStart(u8, line[2..], " ");
        const key = if (std.mem.startsWith(u8, line, "image:"))
            "image:".len
        else if (std.mem.startsWith(u8, line, "\"image\":"))
            "\"image\":".len
        else
            continue;
        var value = std.mem.trim(u8, line[key..], " \t,");
        if (std.mem.indexOf(u8, value, " #")) |comment| value = std.mem.trimEnd(u8, value[0..comment], " ");
        value = std.mem.trim(u8, value, "\"'");
        if (value.len == 0) continue;
        for (images.items) |known| {
            if (std.mem.eql(u8, known, value)) break;
        } else {
            if (images.items.len == images_max) return error.TooManyImages;
            try images.append(arena, try arena.dupe(u8, value));
        }
    }
}

/// Antithesis asks for fully qualified references (registry, name and tag or digest): the
/// guest pulls nothing, so a reference must name the image K3s imported, as written.
pub fn qualified(reference: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, reference, '/') orelse return false;
    const registry = reference[0..slash];
    const domain = std.mem.indexOfAny(u8, registry, ".:") != null or std.mem.eql(u8, registry, "localhost");
    const name = reference[slash + 1 ..];
    const tagged = std.mem.indexOfScalar(u8, name, ':') != null or std.mem.indexOfScalar(u8, name, '@') != null;
    return domain and tagged;
}

/// The node image's Dockerfile: K3s, its air-gap images, the workload's images (images.tar,
/// when there are any), and determinismo's tools and the templates' wrappers.
pub fn dockerfile(arena: std.mem.Allocator, with_images: bool, with_templates: bool) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "FROM {s}\nADD {s} /var/lib/rancher/k3s/agent/images/\n", .{ k3s_image, airgap_url });
    if (with_images) try out.appendSlice(arena, "COPY images.tar /var/lib/rancher/k3s/agent/images/workload.tar\n");
    try out.print(arena, "COPY determinismo-kubernetes/ {s}/\n", .{tools_directory});
    if (with_templates) try out.appendSlice(arena, "COPY antithesis/ /opt/antithesis/\n");
    return out.items;
}

/// The setup command (the node's `ready_path`): kapp's deploy, as a script.
pub const ready_script =
    \\#!/bin/sh
    \\# determinismo's setup for imported Kubernetes manifests (kubernetes.zig): applied until all
    \\# of them apply (a namespace or a custom resource definition before what needs it), every
    \\# container of the workload given the Antithesis SDK's output, then every Deployment,
    \\# StatefulSet and DaemonSet rolled out and every running pod ready.
    \\export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    \\manifests=
++ manifests_directory ++
    \\
    \\timeout=600s
    \\attempts=0
    \\until kubectl get --raw /readyz > /dev/null 2>&1; do
    \\  attempts=$((attempts + 1))
    \\  [ $attempts -le 600 ] || { echo "the API server never answered"; exit 1; }
    \\  sleep 1
    \\done
    \\attempts=0
    \\until kubectl apply --recursive --filename $manifests; do
    \\  attempts=$((attempts + 1))
    \\  [ $attempts -le 60 ] || { echo "the manifests never applied"; exit 1; }
    \\  sleep 2
    \\done
    \\sdk='{"name":"ANTITHESIS_SDK_LOCAL_OUTPUT","value":"/opt/determinismo/sdk/output"}'
    \\mount='{"name":"determinismo-sdk","mountPath":"/opt/determinismo/sdk"}'
    \\volume='{"name":"determinismo-sdk","hostPath":{"path":"/opt/determinismo/sdk"}}'
    \\template='{{range .items}}{{.metadata.namespace}} {{.metadata.name}}{{range .spec.template.spec.containers}} {{.name}}{{end}}{{"\n"}}{{end}}'
    \\for kind in deployment statefulset daemonset; do
    \\  kubectl get $kind --all-namespaces --output go-template="$template" > /tmp/workload || exit 1
    \\  while read namespace name containers; do
    \\    [ "$namespace" = kube-system ] && continue
    \\    patched=""
    \\    for container in $containers; do
    \\      patched="$patched${patched:+,}{\"name\":\"$container\",\"env\":[$sdk],\"volumeMounts\":[$mount]}"
    \\    done
    \\    patch="{\"spec\":{\"template\":{\"spec\":{\"volumes\":[$volume],\"containers\":[$patched]}}}}"
    \\    kubectl patch $kind $name --namespace $namespace --type strategic --patch "$patch" > /dev/null || exit 1
    \\  done < /tmp/workload
    \\done
    \\listed='{{range .items}}{{.metadata.namespace}} {{.metadata.name}}{{"\n"}}{{end}}'
    \\for kind in deployment statefulset daemonset; do
    \\  kubectl get $kind --all-namespaces --output go-template="$listed" > /tmp/workload || exit 1
    \\  while read namespace name; do
    \\    kubectl rollout status $kind/$name --namespace $namespace --timeout $timeout || exit 1
    \\  done < /tmp/workload
    \\done
    \\kubectl wait pod --all --all-namespaces --for condition=Ready --field-selector status.phase=Running \
    \\  --timeout $timeout > /dev/null
    \\
;

/// Runs a test command in a running container of an image (the first, by namespace and name).
pub const exec_script =
    \\#!/bin/sh
    \\# exec <image> <command> [arguments...]: an Antithesis test command found in <image>, run in
    \\# a running container of it (kubernetes.zig).
    \\export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    \\image="$1"
    \\shift
    \\listed='{{range .items}}{{$pod := .}}{{range .spec.containers}}{{$pod.metadata.namespace}} {{$pod.metadata.name}} {{.name}} {{.image}}{{"\n"}}{{end}}{{end}}'
    \\kubectl get pods --all-namespaces --field-selector status.phase=Running --output go-template="$listed" > /tmp/containers.$$ || exit 1
    \\target=""
    \\while read namespace pod container running; do
    \\  if [ "$running" = "$image" ]; then target="$namespace $pod $container"; break; fi
    \\done < /tmp/containers.$$
    \\rm -f /tmp/containers.$$
    \\[ -n "$target" ] || { echo "no running container of $image" >&2; exit 1; }
    \\set -- $target "$@"
    \\namespace="$1" pod="$2" container="$3"
    \\shift 3
    \\exec kubectl exec --namespace "$namespace" "$pod" --container "$container" -- "$@"
    \\
;

/// A test template's wrapper in the node, at the template's path: runs it in its image's pod.
pub fn wrapper(arena: std.mem.Allocator, image: []const u8, path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "#!/bin/sh\nexec {s} {s} {s} \"$@\"\n", .{
        exec_path, try shell_quote(arena, image), try shell_quote(arena, path),
    });
}

fn shell_quote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var quoted: std.ArrayList(u8) = .empty;
    try quoted.append(arena, '\'');
    for (text) |byte| {
        if (byte == '\'') try quoted.appendSlice(arena, "'\\''") else try quoted.append(arena, byte);
    }
    try quoted.append(arena, '\'');
    return quoted.items;
}

test images_note {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var images: std.ArrayList([]const u8) = .empty;
    const manifest =
        \\apiVersion: apps/v1
        \\kind: Deployment
        \\spec:
        \\  template:
        \\    spec:
        \\      containers:
        \\        - name: redis
        \\          image: docker.io/library/redis:7.4-alpine  # the server
        \\          imagePullPolicy: IfNotPresent
        \\        - image: "localhost/client:1"
        \\          name: client
        \\---
        \\{"spec": {"containers": [{"name": "x"}]}, "image": "docker.io/library/redis:7.4-alpine"}
        \\
    ;
    try images_note(arena, manifest, &images);
    try std.testing.expectEqual(@as(usize, 2), images.items.len);
    try std.testing.expectEqualStrings("docker.io/library/redis:7.4-alpine", images.items[0]);
    try std.testing.expectEqualStrings("localhost/client:1", images.items[1]);
}

test qualified {
    try std.testing.expect(qualified("docker.io/library/redis:7.4-alpine"));
    try std.testing.expect(qualified("localhost/client:1"));
    try std.testing.expect(qualified("registry:5000/team/app@sha256:abcd"));
    try std.testing.expect(!qualified("redis:7.4"));
    try std.testing.expect(!qualified("library/redis:7.4"));
    try std.testing.expect(!qualified("docker.io/library/redis"));
}

test wrapper {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try wrapper(arena_state.allocator(), "localhost/client:1", "/opt/antithesis/test/v1/x/it's");
    try std.testing.expectEqualStrings("#!/bin/sh\nexec /opt/determinismo-kubernetes/exec " ++
        "'localhost/client:1' '/opt/antithesis/test/v1/x/it'\\''s' \"$@\"\n", text);
}

test ready_script {
    try std.testing.expect(std.mem.indexOf(u8, ready_script, "\nmanifests=" ++ manifests_directory ++ "\ntimeout=600s\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, ready_script, "--filename $manifests; do\n") != null);
}
