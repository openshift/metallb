#!/bin/bash


CURRENT_DIR="$(dirname $(readlink -f $0))"
MASTER_CONFIG=$(oc get mcp master -o=jsonpath='{.spec.configuration.name}')
WORKER_CONFIG=$(oc get mcp worker -o=jsonpath='{.spec.configuration.name}')

oc patch featuregate cluster --type json  -p '[{"op": "add", "path": "/spec/featureSet", "value": TechPreviewNoUpgrade}]'

echo "waiting for the additionalRouting field to appear"

end=$((SECONDS+600))
while [[ -z $(oc get crds networks.operator.openshift.io -o yaml | grep -i "additionalRouting") ]] && [[ ${SECONDS} -lt ${end} ]]; do
    sleep 1
done

if [[ -z $(oc get crds networks.operator.openshift.io -o yaml | grep -i "additionalRouting") ]]; then
	echo "additionalRouting field did not appear"
	exit 1
fi

echo "additionalRouting field appeared"

UPDATED_MASTER_CONFIG=$MASTER_CONFIG
UPDATED_WORKER_CONFIG=$WORKER_CONFIG

attempts=0
while [[ "$UPDATED_WORKER_CONFIG" == "$WORKER_CONFIG" && "$UPDATED_MASTER_CONFIG" == "$MASTER_CONFIG" ]]; do
	echo "waiting for master and worker config to change"
	sleep 60
	UPDATED_MASTER_CONFIG=$(oc get mcp master -o=jsonpath='{.spec.configuration.name}' || echo $MASTER_CONFIG)
	UPDATED_WORKER_CONFIG=$(oc get mcp worker -o=jsonpath='{.spec.configuration.name}' || echo $WORKER_CONFIG)

	attempts=$((attempts+1))
	if [[ $attempts -eq 60 ]]; then
		echo "failed to wait for master and worker config to change: $MASTER_CONFIG - $UPDATED_MASTER_CONFIG , $WORKER_CONFIG - $UPDATED_WORKER_CONFIG"
		exit 1
	fi
done

wait_mcp() {
	local mcp_name=$1
	local attempts=0
	conditions=""
	while [[ $conditions != "True False" ]]; do
		sleep 60
		conditions=$(oc get mcp $mcp_name -o jsonpath="{.status.conditions[?(@.type=='Updated')].status} {.status.conditions[?(@.type=='Updating')].status}")
		echo "conditions are $conditions"

		attempts=$((attempts+1))
		if [[ $attempts == 60 ]]; then
			echo "failed to wait for $mcp_name conditions: $conditions"
			exit 1
		fi
	done
	echo "$mcp_name is stable"
}


echo "waiting for the mcps to get stable"

wait_mcp master
wait_mcp worker

