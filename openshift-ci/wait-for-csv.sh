#!/bin/bash
set -euo pipefail

export VERSION="v0.0.0"
export CSV_NAME="metallb-operator.${VERSION}"
export NAMESPACE="metallb-system"

timeout 6m bash -c 'until oc get csv -n $NAMESPACE $CSV_NAME; do sleep 5; done'
oc wait --for jsonpath='{.status.phase}'=Succeeded csv/"$CSV_NAME" -n "$NAMESPACE" --timeout=300s
