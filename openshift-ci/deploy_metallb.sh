#!/usr/bin/bash
set -euo pipefail

wait_for_pods() {
  local namespace=$1
  local selector=$2
  local attempts=0
  local max_attempts=30
  local sleep_time=10

  while [[ -z $(oc get pods -n "$namespace" -l "$selector" 2>/dev/null) ]]; do
    sleep $sleep_time
    attempts=$((attempts+1))
    if [ $attempts -eq $max_attempts ]; then
      echo "failed to wait for pods to appear"
      exit 1
    fi
  done
}

metallb_dir="$(dirname $(readlink -f $0))"
git log -1 || true # just printing commit in the test output
source ${metallb_dir}/common.sh

METALLB_OPERATOR_REPO=${METALLB_OPERATOR_REPO:-"https://github.com/openshift/metallb-operator.git"}
METALLB_OPERATOR_BRANCH=${METALLB_OPERATOR_BRANCH:-"main"}
METALLB_IMAGE_BASE=${METALLB_IMAGE_BASE:-$(echo "${OPENSHIFT_RELEASE_IMAGE}" | sed -e 's/release/stable/g' | sed -e 's/@.*$//g')}
METALLB_IMAGE_TAG=${METALLB_IMAGE_TAG:-"metallb"}
KUBERBAC_IMAGE_BASE=${KUBERBAC_IMAGE_BASE:-$(echo "${OPENSHIFT_RELEASE_IMAGE}" | sed -e 's/release/stable/g' | sed -e 's/@.*$//g')}
KUBERBAC_IMAGE_TAG=${KUBERBAC_IMAGE_TAG:-"kube-rbac-proxy"}
METALLB_OPERATOR_IMAGE_TAG=${METALLB_OPERATOR_IMAGE_TAG:-"metallb-operator"}
FRR_IMAGE_TAG=${FRR_IMAGE_TAG:-"metallb-frr"}
BGP_TYPE=${BGP_TYPE:-""}
export NAMESPACE=${NAMESPACE:-"metallb-system"}

if [ ! -d ./metallb-operator ]; then
  git clone ${METALLB_OPERATOR_REPO}
  cd metallb-operator
  git checkout ${METALLB_OPERATOR_BRANCH}
  git log -1 || true # just printing commit in the test output
  cd -
fi

rm -rf metallb-operator-deploy/manifests
rm -rf metallb-operator-deploy/bundle
rm -rf metallb-operator-deploy/bundleci.Dockerfile

cp metallb-operator/bundleci.Dockerfile metallb-operator-deploy
cp -r metallb-operator/manifests/ metallb-operator-deploy/manifests
cp -r metallb-operator/bundle/ metallb-operator-deploy/bundle

cd metallb-operator-deploy

ESCAPED_METALLB_IMAGE=$(printf '%s\n' "${METALLB_IMAGE_BASE}:${METALLB_IMAGE_TAG}" | sed -e 's/[]\/$*.^[]/\\&/g');
find . -type f -name "*clusterserviceversion*.yaml" -exec sed -i 's/quay.io\/openshift\/origin-metallb:.*$/'"$ESCAPED_METALLB_IMAGE"'/g' {} +
ESCAPED_FRR_IMAGE=$(printf '%s\n' "${METALLB_IMAGE_BASE}:${FRR_IMAGE_TAG}" | sed -e 's/[]\/$*.^[]/\\&/g');
find . -type f -name "*clusterserviceversion*.yaml" -exec sed -i 's/quay.io\/openshift\/origin-metallb-frr:.*$/'"$ESCAPED_FRR_IMAGE"'/g' {} +
ESCAPED_OPERATOR_IMAGE=$(printf '%s\n' "${METALLB_IMAGE_BASE}:${METALLB_OPERATOR_IMAGE_TAG}" | sed -e 's/[]\/$*.^[]/\\&/g');
find . -type f -name "*clusterserviceversion*.yaml" -exec sed -i 's/quay.io\/openshift\/origin-metallb-operator:.*$/'"$ESCAPED_OPERATOR_IMAGE"'/g' {} +
ESCAPED_KUBERBAC_IMAGE=$(printf '%s\n' "${KUBERBAC_IMAGE_BASE}:${KUBERBAC_IMAGE_TAG}" | sed -e 's/[]\/$*.^[]/\\&/g');
find . -type f -name "*clusterserviceversion*.yaml" -exec sed -i 's/quay.io\/openshift\/origin-kube-rbac-proxy:.*$/'"$ESCAPED_KUBERBAC_IMAGE"'/g' {} +
find . -type f -name "*clusterserviceversion*.yaml" -exec sed -r -i 's/name: metallb-operator\..*$/name: metallb-operator.v0.0.0/g' {} +

if [[ "$BGP_TYPE" == "frr-k8s-cno" ]]; then
awk '/DEPLOY_PODMONITORS/ {system("cat frrk8s-cno.patch"); print; next}1' manifests/stable/metallb-operator.clusterserviceversion.yaml  > temp.yaml
mv temp.yaml manifests/stable/metallb-operator.clusterserviceversion.yaml

end=$((SECONDS+180))
oc patch featuregate cluster --type json  -p '[{"op": "add", "path": "/spec/featureSet", "value": TechPreviewNoUpgrade}]'
while [[ -z $(oc get crds networks.operator.openshift.io -o yaml | grep -i "additionalRouting") ]] && [[ ${SECONDS} -lt ${end} ]]; do
    sleep 1
done

fi

cd -

oc label ns openshift-marketplace --overwrite pod-security.kubernetes.io/enforce=privileged
oc patch OperatorHub cluster --type json \
    -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'


secret=$(oc -n openshift-marketplace get sa builder -oyaml | grep imagePullSecrets -A 1 | grep -o "builder-.*")

buildindexpod="apiVersion: v1
kind: Pod
metadata:
  name: buildindex
  namespace: openshift-marketplace
spec:
  restartPolicy: Never
  serviceAccountName: builder
  containers:
    - name: priv
      image: quay.io/podman/stable
      command:
        - /bin/bash
        - -c
        - |
          set -xe
          sleep INF
      securityContext:
        privileged: true
      volumeMounts:
        - mountPath: /var/run/secrets/openshift.io/push
          name: dockercfg
          readOnly: true
  volumes:
    - name: dockercfg
      defaultMode: 384
      secret:
        secretName: $secret
"

echo "$buildindexpod" | oc apply -f -

success=0
iterations=0
sleep_time=10
max_iterations=72 # results in 12 minutes timeout
until [[ $success -eq 1 ]] || [[ $iterations -eq $max_iterations ]]
do
  run_status=$(oc -n openshift-marketplace get pod buildindex -o json | jq '.status.phase' | tr -d '"')
   if [ "$run_status" == "Running" ]; then
          success=1
          break
   fi
   iterations=$((iterations+1))
   sleep $sleep_time
done

oc cp metallb-operator-deploy openshift-marketplace/buildindex:/tmp
oc exec -n openshift-marketplace buildindex -- /tmp/metallb-operator-deploy/build_and_push_index.sh

oc apply -f metallb-operator-deploy/install-resources.yaml

# there is a race in the creation of the pod and the service account that prevents
# the index image to be pulled. Here we wait service account exists
timeout 2m bash -c 'until oc get -n openshift-marketplace sa metallbindex; do sleep 5; done'
# if fails,then script fails with error "Error from server (NotFound): serviceaccounts "metallbindes" not found"
timeout 2m bash -c 'until oc get -n openshift-marketplace pods -l olm.catalogSource=metallbindex; do sleep 5; done'
# if fails,then script fails with error "No resources found in openshift-marketplace namespace."
oc -n openshift-marketplace wait pod -l olm.catalogSource=metallbindex --for=condition=Ready --timeout=20m
# if fails, then script fails with error "timed out waiting for the condition on pods/metallbindex-8jh2w"

./wait-for-csv.sh

oc label ns openshift-marketplace --overwrite pod-security.kubernetes.io/enforce=baseline
oc label ns metallb-system openshift.io/cluster-monitoring=true

if [[ -z "${BGP_TYPE}" ]]; then
oc apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
spec:
  logLevel: debug
  bgpBackend: frr
EOF
else
oc apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
spec:
  logLevel: debug
EOF
fi

NAMESPACE="metallb-system"


if [[  "$BGP_TYPE" == "frr-k8s-cno" || "$BGP_TYPE" == "frr-k8s" ]]; then

FRRK8S_NAMESPACE="metallb-system"
if [[ "$BGP_TYPE" == "frr-k8s-cno" ]]; then
  FRRK8S_NAMESPACE="openshift-frr-k8s"
fi


wait_for_pods $FRRK8S_NAMESPACE "app=frr-k8s"

attempts=0
until oc -n $FRRK8S_NAMESPACE wait --for=condition=Ready --all pods --timeout 900s; do
  attempts=$((attempts+1))
  if [ $attempts -ge 5 ]; then
    echo "failed to wait frr-k8s pods"
    exit 1
  fi
  sleep 2
done

fi

wait_for_pods $NAMESPACE "app=metallb"
attempts=0
until oc -n $NAMESPACE wait --for=condition=Ready --all pods --timeout 900s; do
  attempts=$((attempts+1))
  if [ $attempts -ge 5 ]; then
    echo "failed to wait metallb pods"
    exit 1
  fi
  sleep 2
done


ATTEMPTS=0
while [[ -z $(oc get endpoints -n $NAMESPACE metallb-operator-webhook-server-service -o jsonpath="{.subsets[0].addresses}" 2>/dev/null) ]]; do
  echo "still waiting for webhookservice endpoints"
  sleep 10
  ATTEMPTS=$((ATTEMPTS+1))
  if [ $ATTEMPTS -eq 30 ]; then
        echo "failed waiting for webhookservice endpoints"
        exit 1
  fi
done
echo "webhook endpoints avaliable"


sudo ip route add 192.168.10.0/24 dev ${BAREMETAL_NETWORK_NAME}
