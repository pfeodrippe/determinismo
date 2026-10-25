#!/bin/sh
# SPDX-License-Identifier: MIT
# The cluster is up (all its nodes Ready) and the workload serves: branches start from here.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
nodes=${CLUSTER_NODES:-1}
until [ "$(/bin/kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ')" -ge "$nodes" ]; do
  sleep 1
done
# Pods scheduled before the agents joined: spread them again, one per node.
[ "$nodes" -gt 1 ] && /bin/kubectl rollout restart deployment/web >/dev/null
until /bin/kubectl rollout status deployment/web --timeout=10s >/dev/null 2>&1; do sleep 1; done
until wget -qO- -T 2 "http://$(/bin/kubectl get service web -o jsonpath='{.spec.clusterIP}')" | grep -q ok; do
  sleep 1
done
