// SPDX-License-Identifier:Apache-2.0

package l2tests

import (
	"context"
	"fmt"
	"time"

	"github.com/onsi/ginkgo"
	"github.com/onsi/ginkgo/extensions/table"
	"github.com/onsi/gomega"
	metallbv1beta1 "go.universe.tf/metallb/api/v1beta1"
	"go.universe.tf/metallb/e2etest/pkg/config"
	"go.universe.tf/metallb/e2etest/pkg/k8s"
	"go.universe.tf/metallb/e2etest/pkg/metallb"
	"go.universe.tf/metallb/e2etest/pkg/service"
	internalconfig "go.universe.tf/metallb/internal/config"

	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	clientset "k8s.io/client-go/kubernetes"
	"k8s.io/kubernetes/test/e2e/framework"
	e2eservice "k8s.io/kubernetes/test/e2e/framework/service"
	admissionapi "k8s.io/pod-security-admission/api"
)

var _ = ginkgo.Describe("IP Assignment", func() {
	var cs clientset.Interface

	var f *framework.Framework
	ginkgo.AfterEach(func() {
		if ginkgo.CurrentGinkgoTestDescription().Failed {
			k8s.DumpInfo(Reporter, ginkgo.CurrentGinkgoTestDescription().TestText)
		}

		// Clean previous configuration.
		err := ConfigUpdater.Clean()
		framework.ExpectNoError(err)
	})

	f = framework.NewDefaultFramework("assignment")
	f.NamespacePodSecurityEnforceLevel = admissionapi.LevelPrivileged

	ginkgo.BeforeEach(func() {
		cs = f.ClientSet

		ginkgo.By("Clearing any previous configuration")
		err := ConfigUpdater.Clean()
		framework.ExpectNoError(err)
	})

	ginkgo.Context("IPV4 Assignment", func() {
		table.DescribeTable("should remove the ip from a service assign it to a free one when", func(modify func(svc *v1.Service) error) {
			ip, err := config.GetIPFromRangeByIndex(IPV4ServiceRange, 0)
			framework.ExpectNoError(err)

			resources := internalconfig.ClusterResources{
				Pools: []metallbv1beta1.IPAddressPool{
					{
						ObjectMeta: metav1.ObjectMeta{
							Name: "singleip-pool",
						},
						Spec: metallbv1beta1.IPAddressPoolSpec{
							Addresses: []string{
								fmt.Sprintf("%s/32", ip),
							},
						},
					},
				},
			}
			err = ConfigUpdater.Update(resources)
			framework.ExpectNoError(err)

			jig := e2eservice.NewTestJig(cs, f.Namespace.Name, "singleip")
			svc, err := jig.CreateLoadBalancerService(10*time.Second, service.TrafficPolicyCluster)
			framework.ExpectNoError(err)

			ginkgo.By("Creating another service")
			svc1, err := jig.CreateTCPService(func(svc *v1.Service) {
				svc.Spec.Type = v1.ServiceTypeLoadBalancer
				svc.Name = "singleip1"
			})
			framework.ExpectNoError(err)
			gomega.Consistently(func() int {
				s, err := cs.CoreV1().Services(svc1.Namespace).Get(context.Background(), svc1.Name, metav1.GetOptions{})
				framework.ExpectNoError(err)
				return len(s.Status.LoadBalancer.Ingress)
			}, 5*time.Second, 1*time.Second).Should(gomega.BeZero())

			err = modify(svc)
			framework.ExpectNoError(err)

			ginkgo.By("Changing the service type so the ip is free to be used again")
			framework.ExpectNoError(err)

			ginkgo.By("Checking the second service gets the ip assigned")

			gomega.Eventually(func() string {
				s, err := cs.CoreV1().Services(svc1.Namespace).Get(context.Background(), svc1.Name, metav1.GetOptions{})
				framework.ExpectNoError(err)
				if len(s.Status.LoadBalancer.Ingress) == 0 {
					return ""
				}
				return s.Status.LoadBalancer.Ingress[0].IP
			}, time.Minute, 1*time.Second).Should(gomega.Equal(ip))
		},
			table.Entry("changing the service type to clusterIP",
				func(svc *v1.Service) error {
					svc.Spec.Type = v1.ServiceTypeClusterIP
					_, err := cs.CoreV1().Services(svc.Namespace).Update(context.Background(), svc, metav1.UpdateOptions{})
					return err
				}),
			table.Entry("deleting the service",
				func(svc *v1.Service) error {
					err := cs.CoreV1().Services(svc.Namespace).Delete(context.Background(), svc.Name, metav1.DeleteOptions{})
					return err
				}))

		ginkgo.It("should preseve the same external ip after controller restart", func() {
			const numOfRestarts = 5
			resources := internalconfig.ClusterResources{
				Pools: []metallbv1beta1.IPAddressPool{
					{
						ObjectMeta: metav1.ObjectMeta{
							Name: "assignment-controller-reset-test-pool",
						},
						Spec: metallbv1beta1.IPAddressPoolSpec{
							Addresses: []string{"192.168.10.100/32", "192.168.20.200/32"},
						},
					},
				},
			}
			err := ConfigUpdater.Update(resources)
			framework.ExpectNoError(err)

			ginkgo.By("creating 4 LB services")
			jig := e2eservice.NewTestJig(cs, f.Namespace.Name, "service-a")
			serviceA, err := jig.CreateLoadBalancerService(30*time.Second, nil)
			framework.ExpectNoError(err)
			defer service.Delete(cs, serviceA)
			service.ValidateDesiredLB(serviceA)

			jig = e2eservice.NewTestJig(cs, f.Namespace.Name, "service-b")
			serviceB, err := jig.CreateLoadBalancerService(30*time.Second, nil)
			framework.ExpectNoError(err)
			defer service.Delete(cs, serviceB)
			service.ValidateDesiredLB(serviceB)

			serviceC, err := service.CreateLoadBalancerService(cs, "service-c", f.Namespace.Name, nil)
			framework.ExpectNoError(err)
			defer service.Delete(cs, serviceC)

			serviceD, err := service.CreateLoadBalancerService(cs, "service-d", f.Namespace.Name, nil)
			framework.ExpectNoError(err)
			defer service.Delete(cs, serviceD)

			restartAndAssert := func() {
				metallb.RestartController(cs)
				gomega.Consistently(func() error {
					serviceA, err = cs.CoreV1().Services(serviceA.Namespace).Get(context.TODO(), serviceA.Name, metav1.GetOptions{})
					framework.ExpectNoError(err)

					err = service.ValidateAssignedWith(serviceA, "192.168.10.100")
					if err != nil {
						return err
					}
					serviceB, err = cs.CoreV1().Services(serviceB.Namespace).Get(context.TODO(), serviceB.Name, metav1.GetOptions{})
					framework.ExpectNoError(err)

					err = service.ValidateAssignedWith(serviceB, "192.168.20.200")
					if err != nil {
						return err
					}

					return nil
				}, 10*time.Second, 2*time.Second).ShouldNot(gomega.HaveOccurred())
			}

			ginkgo.By("restarting the controller and validating that the service keeps the same ip")
			for i := 0; i < numOfRestarts; i++ {
				restartAndAssert()
			}
		})
	})
})
