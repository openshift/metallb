#!/usr/bin/bash
set -euo pipefail

BGP_TYPE=$1
IP_STACK=$2

if [[ "$BGP_TYPE" == "frr-k8s" || "$BGP_TYPE" == "frr-k8s-cno" ]]; then
	MODE_TO_SKIP="FRR-MODE"
	BGP_MODE="frr-k8s"
else
	MODE_TO_SKIP="FRRK8S-MODE"
	BGP_MODE="frr"
fi
# need to skip L2 metrics / node selector test because the pod that's running the tests is not
# same subnet of the cluster nodes, so the arp request that's done in the test won't work.
# Also, skip l2 interface selector as it's not supported d/s currently.
# Skip route injection after setting up speaker. FRR is not refreshed.

SKIP="L2 Cordon|L2 metrics|L2 Node Selector|L2-interface selector|L2ServiceStatus|NetworkUnavailable|NodeExcludeBalancers|$MODE_TO_SKIP"
SKIP="$SKIP|Unnumbered"

if [ "${IP_STACK}" = "v4" ]; then
	SKIP="$SKIP|IPV6|DUALSTACK"
	export PROVISIONING_HOST_EXTERNAL_IPV4=${PROVISIONING_HOST_EXTERNAL_IP}
	export PROVISIONING_HOST_EXTERNAL_IPV6=1111:1:1::1
elif [ "${IP_STACK}" = "v6" ]; then
	SKIP="$SKIP|IPV4|DUALSTACK"
	export PROVISIONING_HOST_EXTERNAL_IPV6=${PROVISIONING_HOST_EXTERNAL_IP}
	export PROVISIONING_HOST_EXTERNAL_IPV4=1.1.1.1
elif [ "${IP_STACK}" = "v4v6" ]; then
	SKIP="$SKIP|IPV6"
	export PROVISIONING_HOST_EXTERNAL_IPV4=${PROVISIONING_HOST_EXTERNAL_IP}
	export PROVISIONING_HOST_EXTERNAL_IPV6=1111:1:1::1
fi
echo "Skipping ${SKIP}"

# Let's enforce failing when running the tests
set -e

pip3 install --user -r ./../dev-env/requirements.txt

FRRK8S_NAMESPACE=""
if [[ "$BGP_TYPE" == "frr-k8s-cno" || "$BGP_TYPE" == "frr-k8s" ]]; then
  FRRK8S_NAMESPACE="--frr-k8s-namespace=openshift-frr-k8s"
fi

# Install ginkgo CLI.
export PATH=${PATH}:${HOME}/.local/bin
export CONTAINER_RUNTIME=podman
export RUN_FRR_CONTAINER_ON_HOST_NETWORK=true

mkdir -p /tmp/report
inv e2etest --kubeconfig=$(readlink -f ../../ocp/ostest/auth/kubeconfig) \
	--service-pod-port=8080 --system-namespaces="metallb-system" \
	--ipv4-service-range=192.168.10.0/24 --ipv6-service-range=fc00:f853:0ccd:e799::/124 \
	--prometheus-namespace="openshift-monitoring" \
	--local-nics="_" --node-nics="_" --skip="${SKIP}" --external-frr-image="quay.io/frrouting/frr:8.3.1" \
	--bgp-mode="$BGP_MODE" $FRRK8S_NAMESPACE 

cp -r /tmp/report $REPORTER_PATH

oc wait --for=delete namespace/metallb-system-other --timeout=2m || true # making sure the namespace is deleted (should happen in aftersuite)

FOCUS_EBGP="BGP A service of protocol load balancer should work with ETP=cluster IPV4" # Just a smoke test to make sure ebgp works

inv e2etest --kubeconfig=$(readlink -f ../../ocp/ostest/auth/kubeconfig) \
	--service-pod-port=8080 --system-namespaces="metallb-system" \
	--ipv4-service-range=192.168.10.0/24 --ipv6-service-range=fc00:f853:0ccd:e799::/124 \
	--prometheus-namespace="openshift-monitoring" \
	--local-nics="_" --node-nics="_" --focus="${FOCUS_EBGP}" --external-frr-image="quay.io/frrouting/frr:8.3.1" \
	--host-bgp-mode="ebgp" --bgp-mode="$BGP_MODE" $FRRK8S_NAMESPACE
