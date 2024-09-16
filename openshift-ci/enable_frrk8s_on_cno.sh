#!/bin/bash
# this script enables the cluster to deploy frrk8s via CNO and waits 
# for the cluster to be stable
set -euo pipefail


oc patch featuregate cluster --type json  -p '[{"op": "add", "path": "/spec/featureSet", "value": TechPreviewNoUpgrade}]'

echo "waiting for the additionalRouting field to be available"

end=$((SECONDS+600))
while ! oc get crds networks.operator.openshift.io -o yaml | grep -q "additionalRouting" && [[ ${SECONDS} -lt ${end} ]]; do
    sleep 1
done

if ! oc get crds networks.operator.openshift.io -o yaml | grep -i "additionalRouting"; then
	echo "additionalRouting field was never available"
	exit 1
fi

echo "additionalRouting field is available"

echo "waiting for the mcps to start Upgrading"

oc wait --for=condition=Updating=True mcp master --timeout=30m
oc wait --for=condition=Updating=True mcp worker --timeout=30m

echo "waiting for the mcps to be updated"

oc wait --for=condition=Updated=True mcp master --timeout=30m
oc wait --for=condition=Updated=True mcp worker --timeout=30m

echo "mcps are updated"

