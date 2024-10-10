#!/usr/bin/bash
set -euo pipefail

metallb_dir="$(dirname $(readlink -f $0))"
source ${metallb_dir}/common.sh

METALLB_REPO=${METALLB_REPO:-"https://github.com/openshift/metallb.git"}
export BGP_TYPE=${BGP_TYPE:-""}
export IP_STACK=${IP_STACK:-""}

# add firewalld rules
sudo firewall-cmd --zone=libvirt --permanent --add-port=179/tcp
sudo firewall-cmd --zone=libvirt --add-port=179/tcp
sudo firewall-cmd --zone=libvirt --permanent --add-port=180/tcp
sudo firewall-cmd --zone=libvirt --add-port=180/tcp
# BFD control packets
sudo firewall-cmd --zone=libvirt --permanent --add-port=3784/udp
sudo firewall-cmd --zone=libvirt --add-port=3784/udp
# BFD echo packets
sudo firewall-cmd --zone=libvirt --permanent --add-port=3785/udp
sudo firewall-cmd --zone=libvirt --add-port=3785/udp
# BFD multihop packets
sudo firewall-cmd --zone=libvirt --permanent --add-port=4784/udp
sudo firewall-cmd --zone=libvirt --add-port=4784/udp

go install github.com/onsi/ginkgo/v2/ginkgo@v2.4.0
export REPORTER_PATH=/artifacts/


# TODO CHANGE with env variable set from the lane definition
if [[ "$BGP_TYPE" == "frr-k8s" || "$BGP_TYPE" == "frr-k8s-cno" ]]; then
	${metallb_dir}/run_frrk8s_e2e.sh
else
	${metallb_dir}/run_metallb_e2e.sh
fi

