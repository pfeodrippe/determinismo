# Kubernetes manifests under determinismo

`explore --kubernetes <manifests directory>` runs raw Kubernetes manifests as Antithesis does
(docs: setup/kubernetes): a single-node K3s cluster, with CoreDNS and the local-path storage
class, in one privileged node (`src/kubernetes.zig`). Images are fully qualified and taken from
the host (built or pulled there): the guest has no network. Helm charts are rendered first
(`helm template ... --output-dir manifests/`).

Here, Redis and a client whose image holds the test templates:

    podman build -t localhost/determinismo-kubernetes-client:1 -f examples/kubernetes/Dockerfile.client .
    determinismo explore ... --memory-mib 4096 --kubernetes examples/kubernetes/manifests \
      --scenario counter --seed 1 --branches 8

Each scenario (a template directory) starts with `setup_kubernetes`: the manifests applied until
all apply, every container given the Antithesis SDK's output (`ANTITHESIS_SDK_LOCAL_OUTPUT`, a
hostPath volume), then everything rolled out and ready (kapp's readiness); setup_complete
follows. The template's commands run in a running container of the image that has them, through
`kubectl exec`.

Faults act on the K3s node (its processes, the pods' among them); faults between pods are not
there yet.
