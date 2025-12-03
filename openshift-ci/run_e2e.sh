#!/usr/bin/bash
set -euo pipefail

metallb_dir="$(dirname $(readlink -f $0))"
source ${metallb_dir}/common.sh

IP_STACK=${IP_STACK:-""}
RUN_FRR_K8S_TESTS=${RUN_FRR_K8S_TESTS:-""}


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

export REPORTER_PATH=/logs/artifacts/
mkdir -p $REPORTER_PATH

go install github.com/onsi/ginkgo/v2/ginkgo@v2.20.2

if [[ "$RUN_FRR_K8S_TESTS" == "true" ]]; then
	${metallb_dir}/run_frrk8s_e2e.sh $IP_STACK
else
	${metallb_dir}/run_metallb_e2e.sh $IP_STACK
fi
