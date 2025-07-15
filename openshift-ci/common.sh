#!/usr/bin/bash
set -euo pipefail

pushd ../../
git log -1 || true # just printing commit in the test output
# we move to content of https://github.com/openshift-metal3/dev-scripts.git repo
# we need to change folder as {common,network}.sh have source files
# shellcheck source=network.sh #https://github.com/koalaman/shellcheck/wiki/SC1090
source ./common.sh
# shellcheck source=network.sh
source ./network.sh
popd

wait_for_pods() {
  local namespace=$1
  local selector=$2

  echo "waiting for pods $namespace - $selector to be created"
  timeout 5m bash -c "until [[ -n \$(oc get pods -n $namespace -l $selector 2>/dev/null) ]]; do sleep 5; done"
  echo "waiting for pods $namespace to be ready"
  oc wait --for=condition=Ready --all pods -n "$namespace" --timeout=5m
  echo "pods for $namespace with selector $selector are ready"
}

enable_frr_k8s_debug() {
  local FRRK8S_NAMESPACE="openshift-frr-k8s"
  echo "Enabling debug for frr-k8s"
  oc create ns ${FRRK8S_NAMESPACE} || true

  oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: env-overrides
  namespace: ${FRRK8S_NAMESPACE}
data:
  frrk8s-loglevel: "--log-level=debug"
EOF
}

wait_for_csv() {
  local namespace=$1
  local csv=$2

  timeout 5m bash -c "until oc get csv -n $namespace $csv; do sleep 5; done"
  oc wait --for jsonpath='{.status.phase}'=Succeeded csv/"$csv" -n "$namespace" --timeout=300s
}
