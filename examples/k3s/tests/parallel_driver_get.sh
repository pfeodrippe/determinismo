#!/bin/sh
# SPDX-License-Identifier: MIT
# Requests through the Service, as clients would (failures are expected under faults).
address=$(/bin/kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get service web -o jsonpath='{.spec.clusterIP}')
for i in 1 2 3 4 5; do wget -qO- -T 2 "http://$address" >/dev/null 2>&1; done
exit 0
