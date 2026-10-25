#!/bin/sh
# SPDX-License-Identifier: MIT
# Once faults stop, the Service answers again: Kubernetes recovers the workload.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
for attempt in $(seq 1 60); do
  address=$(/bin/kubectl get service web -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  wget -qO- -T 2 "http://$address" 2>/dev/null | grep -q ok && exit 0
  sleep 1
done
exit 1
