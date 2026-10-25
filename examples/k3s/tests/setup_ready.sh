#!/bin/sh
# SPDX-License-Identifier: MIT
# The cluster is up and the workload serves: branches start from here.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
until /bin/kubectl rollout status deployment/web --timeout=10s >/dev/null 2>&1; do sleep 1; done
until wget -qO- -T 2 "http://$(/bin/kubectl get service web -o jsonpath='{.spec.clusterIP}')" | grep -q ok; do
  sleep 1
done
