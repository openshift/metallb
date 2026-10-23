#!/usr/bin/bash
set -euo pipefail

BGP_TYPE=$1
IP_STACK=$2

FRRK8S_DIR="$(dirname $(readlink -f $0))/../../frr"

KUBECONFIG=$(readlink -f ../../ocp/ostest/auth/kubeconfig)
pushd $FRRK8S_DIR

SKIP="Leaked.*advertising\|receive.*ips.*from.*some\|VRF.*Advertise.*a.*subset.*of.*ips"
SKIP="$SKIP\|should.*block.*always.*block.*cidr\|.*EnableGracefulRestart.*"
SKIP="$SKIP\|.*with graceful restart.*"

if [[ "$BGP_TYPE" == "frr-k8s" ]]; then
  SKIP="$SKIP\|metrics"  # because when running as a metallb pod the metrics are overridden.
fi

FRRK8S_NAMESPACE="metallb-system"
if [[ "$BGP_TYPE" == "frr-k8s-cno" ]]; then
  FRRK8S_NAMESPACE="openshift-frr-k8s"
fi

if [ "${IP_STACK}" = "v4" ]; then
	SKIP="$SKIP\|IPV6\|DUALSTACK"
	export PROVISIONING_HOST_EXTERNAL_IPV4=${PROVISIONING_HOST_EXTERNAL_IP}
	export PROVISIONING_HOST_EXTERNAL_IPV6=1111:1:1::1
elif [ "${IP_STACK}" = "v6" ]; then
	SKIP="$SKIP\|IPV4\|DUALSTACK"
	export PROVISIONING_HOST_EXTERNAL_IPV6=${PROVISIONING_HOST_EXTERNAL_IP}
	export PROVISIONING_HOST_EXTERNAL_IPV4=1.1.1.1
elif [ "${IP_STACK}" = "v4v6" ]; then
	SKIP="$SKIP\|IPV6"
	export PROVISIONING_HOST_EXTERNAL_IPV4=${PROVISIONING_HOST_EXTERNAL_IP}
	export PROVISIONING_HOST_EXTERNAL_IPV6=1111:1:1::1
fi
echo "Skipping ${SKIP}"

## In order to make the VRF leaking tests work we need to
pods=$(oc get pods -l "app=frr-k8s" -n $FRRK8S_NAMESPACE -o jsonpath='{.items[*].metadata.name}')

echo "creating vrfs in pods $pods"
for pod in $pods; do
  echo "creating vrf in pod $pod"
  oc exec $pod -n $FRRK8S_NAMESPACE -c frr -- ip link add red type vrf table 900
  oc exec $pod -n $FRRK8S_NAMESPACE -c frr -- ip link set red up
done

export TEST_ARGS="--frr-k8s-namespace=$FRRK8S_NAMESPACE --kubeconfig=$KUBECONFIG --prometheus-namespace=openshift-monitoring --report-path=$REPORTER_PATH"

export RUN_FRR_CONTAINER_ON_HOST_NETWORK="true"

make ginkgo
make kubectl
KUBECONFIG_PATH="$KUBECONFIG" GINKGO_ARGS="--skip $SKIP" make e2etests

popd
