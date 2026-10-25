# SPDX-License-Identifier: MIT
FROM docker.io/rancher/k3s:v1.36.5-k3s1
# Every image K3s needs (pause, CoreDNS, BusyBox, ...), imported when it starts.
ADD https://github.com/k3s-io/k3s/releases/download/v1.36.5%2Bk3s1/k3s-airgap-images-amd64.tar.zst /var/lib/rancher/k3s/agent/images/
# The workload, applied by K3s when it starts; the test templates.
COPY examples/k3s/manifests/ /var/lib/rancher/k3s/server/manifests/
COPY examples/k3s/tests/ /opt/antithesis/test/v1/cluster/
