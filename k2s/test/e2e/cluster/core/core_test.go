// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package core

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	"github.com/siemens-healthineers/k2s/test/framework/watcher"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const (
	namespace = "k2s"
)

var linuxDeploymentNames = []string{"albums-linux1", "albums-linux2"}
var winDeploymentNames = []string{"albums-win1", "albums-win2"}

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

var manifestDir string
var proxy string

var testFailed = false
var podWatcher *watcher.PodWatcher

func TestClusterCore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Cluster Core Acceptance Tests", Label("core", "acceptance", "internet-required", "setup-required", "system-running", "sanity"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	manifestDir = "workload/windows"
	proxy = "http://172.19.1.1:8181"

	suite = framework.Setup(ctx, framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(time.Millisecond*200),
		framework.ClusterTestStepTimeout(8*time.Minute))
	k2s = dsl.NewK2s(suite)

	if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		GinkgoWriter.Println("Found Linux-only setup, skipping Windows-based workloads")

		manifestDir = "workload/base"
	}

	GinkgoWriter.Println("Using proxy <", proxy, "> for internet access")
	GinkgoWriter.Println("Deploying workloads to cluster..")

	// Start pod watcher in background
	podWatcher = watcher.NewPodWatcher(GinkgoWriter, namespace)
	if err := podWatcher.Start(ctx, suite.Kubectl().Path()); err != nil {
		GinkgoWriter.Printf("Warning: failed to start pod watcher: %v\n", err)
	}

	// Apply in two phases: Deployments first, then Services.
	// The clusterip-webhook assigns ClusterIPs based on the workload's
	// nodeSelector (kubernetes.io/os). Kustomize sorts resources by kind and
	// applies Services before Deployments; if both are applied together, the
	// webhook cannot yet see the Deployment when the Service is created and
	// falls back to the Linux subnet. Applying Deployments first ensures the
	// webhook can always detect the correct OS.
	GinkgoWriter.Println("Phase 1: Creating namespace and Deployments..")
	suite.Kubectl().MustExec(ctx, "apply", "-f", "workload/base/namespace.yaml")
	suite.Kubectl().MustExec(ctx, "apply", "-n", namespace, "-f", "workload/base/linux-albums.yaml")
	suite.Kubectl().MustExec(ctx, "apply", "-n", namespace, "-f", "workload/base/linux-curl.yaml")
	if manifestDir == "workload/windows" {
		suite.Kubectl().MustExec(ctx, "apply", "-n", namespace, "-f", "workload/windows/windows-albums.yaml")
	}

	GinkgoWriter.Println("Phase 2: Creating Windows Services..")
	if manifestDir == "workload/windows" {
		suite.Kubectl().MustExec(ctx, "apply", "-n", namespace, "-f", "workload/windows/windows-albums-services.yaml")
	}

	GinkgoWriter.Println("Waiting for Deployments to be ready in namespace <", namespace, ">..")

	suite.Kubectl().MustExec(ctx, "rollout", "status", "deployment", "-n", namespace, "--timeout="+suite.TestStepTimeout().String())

	for _, deploymentName := range linuxDeploymentNames {
		suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, namespace)
	}

	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		for _, deploymentName := range winDeploymentNames {
			suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, namespace)
		}
	}

	GinkgoWriter.Println("Waiting for DNS entries to be resolvable from host..")

	for _, deploymentName := range linuxDeploymentNames {
		suite.Cluster().ExpectDNSToBeResolvableFromHost(ctx, deploymentName, namespace)
	}

	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		for _, deploymentName := range winDeploymentNames {
			suite.Cluster().ExpectDNSToBeResolvableFromHost(ctx, deploymentName, namespace)
		}
	}

	GinkgoWriter.Println("Deployments ready for testing")
})

var _ = AfterSuite(func(ctx context.Context) {
	if podWatcher != nil {
		podWatcher.Stop()
	}

	suite.StatusChecker().IsK2sRunning(ctx)

	GinkgoWriter.Println("Deleting workloads..")

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	// for finding out the sporadically failed test runs
	if !testFailed {
		suite.Kubectl().MustExec(ctx, "delete", "-k", manifestDir, "--ignore-not-found")

		GinkgoWriter.Println("Workloads deleted")

		suite.TearDown(ctx, framework.RestartKubeProxy)
	}
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("Cluster Core", func() {
	systemNamespace := "kube-system"

	Describe("Basic Components", func() {
		Describe("System Nodes", func() {
			It("control-plane is ready", func(ctx SpecContext) {
				suite.Cluster().ExpectNodeToBeReady(suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname(), ctx)
			})

			It("Windows worker is ready", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectNodeToBeReady(suite.SetupInfo().WinNodeName, ctx)
			})
		})

		Describe("System Deployments", func() {
			It("coredns is available", func() {
				suite.Cluster().ExpectDeploymentToBeAvailable("coredns", systemNamespace)
			})
		})

		DescribeTable("System Pods", func(podName string) {
			suite.Cluster().ExpectPodToBeReady(podName, systemNamespace, suite.SetupInfo().RuntimeConfig.ControlPlaneConfig().Hostname())
		},
			Entry("etcd-HOSTNAME_PLACEHOLDER is available", "etcd-HOSTNAME_PLACEHOLDER"),
			Entry("kube-scheduler-HOSTNAME_PLACEHOLDER is available", "kube-scheduler-HOSTNAME_PLACEHOLDER"),
			Entry("kube-apiserver-HOSTNAME_PLACEHOLDER is available", "kube-apiserver-HOSTNAME_PLACEHOLDER"),
			Entry("kube-controller-manager-HOSTNAME_PLACEHOLDER is available", "kube-controller-manager-HOSTNAME_PLACEHOLDER"))
	})

	Describe("Communication", func() {
		DescribeTable("Deployments Availability", func(name string, skipOnLinuxOnly bool) {
			if skipOnLinuxOnly && suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				Skip("Linux-only")
			}

			suite.Cluster().ExpectDeploymentToBeAvailable(name, namespace)
		},
			Entry("albums-linux1 is available", "albums-linux1", false),
			Entry("albums-win1 is available", "albums-win1", true),
			Entry("albums-linux2 is available", "albums-linux2", false),
			Entry("albums-win2 is available", "albums-win2", true),
			Entry("curl is available", "curl", false))

		DescribeTable("Deployment Reachable from Host", func(ctx context.Context, name string, skipOnLinuxOnly bool) {
			if skipOnLinuxOnly && suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				Skip("Linux-only")
			}

			k2s.VerifyDeploymentToBeReachableFromHost(ctx, name, namespace)
		},
			Entry("albums-linux1 is reachable from host", "albums-linux1", false),
			Entry("albums-win1 is reachable from host", "albums-win1", true),
			Entry("albums-linux2 is reachable from host", "albums-linux2", false),
			Entry("albums-win2 is reachable from host", "albums-win2", true))

		Describe("Linux/Windows Deployments Are Reachable from Linux Pods", func() {
			It("Deployment albums-linux1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "curl", namespace, ctx)
			})

			It("Deployment albums-win1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "curl", namespace, ctx)
			})

			It("Deployment albums-linux2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "curl", namespace, ctx)
			})

			It("Deployment albums-win2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "curl", namespace, ctx)
			})
		})

		Describe("Linux Deployments Are Reachable from Windows Pods", func() {
			It("Deployment albums-linux1 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win1", namespace, ctx)
			})

			It("Deployment albums-linux1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win2", namespace, ctx)
			})

			It("Deployment albums-linux2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win1", namespace, ctx)
			})

			It("Deployment albums-linux2 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win2", namespace, ctx)
			})
		})

		Describe("Windows Deployments Are Reachable from Windows Pods", func() {
			It("Deployment albums-win2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "albums-win1", namespace, ctx)
			})

			It("Deployment albums-win1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "albums-win2", namespace, ctx)
			})
		})

		Describe("Linux/Windows Pods Are Reachable from Linux Pods", func() {
			It("Pod of Deployment albums-linux1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "curl", namespace, ctx)
			})

			It("Pod of Deployment albums-win1 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "curl", namespace, ctx)
			})

			It("Pod of Deployment albums-linux2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "curl", namespace, ctx)
			})

			It("Pod of Deployment albums-win2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "curl", namespace, ctx)
			})
		})

		Describe("Linux Pods Are Reachable from Windows Pods", func() {
			It("Pod of Deployment albums-linux1 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win1", namespace, ctx)
			})

			It("Pod of Deployment albums-linux1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win2", namespace, ctx)
			})

			It("Pod of Deployment albums-linux2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win1", namespace, ctx)
			})

			It("Pod of Deployment albums-linux2 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win2", namespace, ctx)
			})
		})

		Describe("Windows Pods Are Reachable from Windows Pods", func() {
			It("Pod of Deployment albums-win2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "albums-win1", namespace, ctx)
			})

			It("Pod of Deployment albums-win1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "albums-win2", namespace, ctx)
			})
		})

		Describe("Internet is Reachable from Pods", func() {
			It("Internet is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.IsOfflineMode() {
					Skip("Offline-Mode")
				}

				suite.Cluster().ExpectInternetToBeReachableFromPodOfDeployment("curl", namespace, proxy, ctx)
			})

			It("Internet is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.IsOfflineMode() {
					Skip("Offline-Mode")
				}

				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectInternetToBeReachableFromPodOfDeployment("albums-win1", namespace, proxy, ctx)
			})

			It("Internet is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.IsOfflineMode() {
					Skip("Offline-Mode")
				}

				if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectInternetToBeReachableFromPodOfDeployment("albums-win2", namespace, proxy, ctx)
			})
		})
	})

	Describe("ClusterIP Subnet Assignment", func() {
		It("Windows service albums-win1 has a ClusterIP in the Windows subnet", func(ctx SpecContext) {
			if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				Skip("Linux-only")
			}

			clientSet, err := kubernetes.NewForConfig(suite.Cluster().Client().Resources().GetConfig())
			Expect(err).NotTo(HaveOccurred())

			svc, err := clientSet.CoreV1().Services(namespace).Get(ctx, "albums-win1", metav1.GetOptions{})
			Expect(err).NotTo(HaveOccurred(), "failed to get service albums-win1")

			Expect(svc.Spec.ClusterIP).NotTo(BeEmpty(), "albums-win1 has no ClusterIP")
			Expect(strings.HasPrefix(svc.Spec.ClusterIP, "172.21.1.")).To(BeTrue(),
				"albums-win1 ClusterIP %s is not in the Windows subnet 172.21.1.0/24", svc.Spec.ClusterIP)
		})

		It("Windows service albums-win2 has a ClusterIP in the Windows subnet", func(ctx SpecContext) {
			if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
				Skip("Linux-only")
			}

			clientSet, err := kubernetes.NewForConfig(suite.Cluster().Client().Resources().GetConfig())
			Expect(err).NotTo(HaveOccurred())

			svc, err := clientSet.CoreV1().Services(namespace).Get(ctx, "albums-win2", metav1.GetOptions{})
			Expect(err).NotTo(HaveOccurred(), "failed to get service albums-win2")

			Expect(svc.Spec.ClusterIP).NotTo(BeEmpty(), "albums-win2 has no ClusterIP")
			Expect(strings.HasPrefix(svc.Spec.ClusterIP, "172.21.1.")).To(BeTrue(),
				"albums-win2 ClusterIP %s is not in the Windows subnet 172.21.1.0/24", svc.Spec.ClusterIP)
		})

		It("Linux service albums-linux1 has a ClusterIP in the Linux subnet", func(ctx SpecContext) {
			clientSet, err := kubernetes.NewForConfig(suite.Cluster().Client().Resources().GetConfig())
			Expect(err).NotTo(HaveOccurred())

			svc, err := clientSet.CoreV1().Services(namespace).Get(ctx, "albums-linux1", metav1.GetOptions{})
			Expect(err).NotTo(HaveOccurred(), "failed to get service albums-linux1")

			Expect(svc.Spec.ClusterIP).NotTo(BeEmpty(), "albums-linux1 has no ClusterIP")
			Expect(strings.HasPrefix(svc.Spec.ClusterIP, "172.21.0.")).To(BeTrue(),
				"albums-linux1 ClusterIP %s is not in the Linux subnet 172.21.0.0/24", svc.Spec.ClusterIP)
		})
	})
})
