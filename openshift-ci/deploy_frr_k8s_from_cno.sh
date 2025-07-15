#!/usr/bin/bash

set -euo pipefail

metallb_dir="$(dirname $(readlink -f $0))"
source ${metallb_dir}/common.sh

FRRK8S_NAMESPACE="openshift-frr-k8s"

enable_frr_k8s_debug

oc patch networks.operator.openshift.io cluster --type json  -p '[{"op": "add", "path": "/spec/additionalRoutingCapabilities", "value": {providers: ["FRR"]}}]'

wait_for_pods $FRRK8S_NAMESPACE "app=frr-k8s"

sudo ip route add 192.168.10.0/24 dev ${BAREMETAL_NETWORK_NAME}
