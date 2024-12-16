// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package core

import (
	"context"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"

	"github.com/siemens-healthineers/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	namespace = "k2s"
)

var linuxDeploymentNames = []string{"albums-linux1", "albums-linux2"}
var winDeploymentNames = []string{"albums-win1", "albums-win2"}

var suite *framework.K2sTestSuite

var manifestDir string
var proxy string

var testFailed = false

func TestClusterCore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Cluster Core Acceptance Tests", Label("core", "acceptance", "internet-required", "setup-required", "system-running", "sanity"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	manifestDir = "workload/windows"
	proxy = "http://172.19.1.1:8181"

	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(time.Millisecond*200))

	if suite.SetupInfo().SetupConfig.LinuxOnly {
		GinkgoWriter.Println("Found Linux-only setup, skipping Windows-based workloads")

		manifestDir = "workload/base"
	}

	if suite.SetupInfo().SetupConfig.SetupName == setupinfo.SetupNameMultiVMK8s {
		if !suite.SetupInfo().SetupConfig.LinuxOnly {
			proxy = "http://172.19.1.101:8181"
		}
	}

	GinkgoWriter.Println("Using proxy <", proxy, "> for internet access")
	GinkgoWriter.Println("Deploying workloads to cluster..")

	suite.Kubectl().Run(ctx, "apply", "-k", manifestDir)

	GinkgoWriter.Println("Waiting for Deployments to be ready in namespace <", namespace, ">..")

	suite.Kubectl().Run(ctx, "rollout", "status", "deployment", "-n", namespace, "--timeout="+suite.TestStepTimeout().String())

	for _, deploymentName := range linuxDeploymentNames {
		suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, namespace)
	}

	if !suite.SetupInfo().SetupConfig.LinuxOnly {
		for _, deploymentName := range winDeploymentNames {
			suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, namespace)
		}
	}

	GinkgoWriter.Println("Deployments ready for testing")
})

var _ = AfterSuite(func(ctx context.Context) {

	GinkgoWriter.Println("Status of cluster after test runs...")
	status := suite.K2sCli().GetStatus(ctx)
	isRunning := status.IsClusterRunning()
	GinkgoWriter.Println("Cluster is running:", isRunning)

	GinkgoWriter.Println("Deleting workloads..")

	if testFailed {
		suite.K2sCli().Run(ctx, "system", "dump", "-S", "-o")
	}

	suite.Kubectl().Run(ctx, "delete", "-k", manifestDir)

	GinkgoWriter.Println("Workloads deleted")

	suite.TearDown(ctx, framework.RestartKubeProxy)
})

var _ = Describe("Cluster Core", func() {
	systemNamespace := "kube-system"

	var _ = AfterEach(func() {
		if CurrentSpecReport().Failed() {
			testFailed = true
		}
	})

	Describe("Basic Components", func() {
		Describe("System Nodes", func() {
			It("control-plane is ready", func(ctx SpecContext) {
				suite.Cluster().ExpectNodeToBeReady(suite.SetupInfo().SetupConfig.ControlPlaneNodeHostname, ctx)
			})

			It("Windows worker is ready", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
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
			suite.Cluster().ExpectPodToBeReady(podName, systemNamespace, suite.SetupInfo().SetupConfig.ControlPlaneNodeHostname)
		},
			Entry("etcd-HOSTNAME_PLACEHOLDER is available", "etcd-HOSTNAME_PLACEHOLDER"),
			Entry("kube-scheduler-HOSTNAME_PLACEHOLDER is available", "kube-scheduler-HOSTNAME_PLACEHOLDER"),
			Entry("kube-apiserver-HOSTNAME_PLACEHOLDER is available", "kube-apiserver-HOSTNAME_PLACEHOLDER"),
			Entry("kube-controller-manager-HOSTNAME_PLACEHOLDER is available", "kube-controller-manager-HOSTNAME_PLACEHOLDER"))
	})

	Describe("Communication", func() {
		DescribeTable("Deployments Availability", func(name string, skipOnLinuxOnly bool) {
			if skipOnLinuxOnly && suite.SetupInfo().SetupConfig.LinuxOnly {
				Skip("Linux-only")
			}

			suite.Cluster().ExpectDeploymentToBeAvailable(name, namespace)
		},
			Entry("albums-linux1 is available", "albums-linux1", false),
			Entry("albums-win1 is available", "albums-win1", true),
			Entry("albums-linux2 is available", "albums-linux2", false),
			Entry("albums-win2 is available", "albums-win2", true),
			Entry("curl is available", "curl", false))

		DescribeTable("Deployment Reachable from Host", func(name string, skipOnLinuxOnly bool) {
			if skipOnLinuxOnly && suite.SetupInfo().SetupConfig.LinuxOnly {
				Skip("Linux-only")
			}

			suite.Cluster().ExpectDeploymentToBeReachableFromHost(name, namespace)
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
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "curl", namespace, ctx)
			})

			It("Deployment albums-linux2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "curl", namespace, ctx)
			})

			It("Deployment albums-win2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "curl", namespace, ctx)
			})
		})

		Describe("Linux Deployments Are Reachable from Windows Pods", func() {
			It("Deployment albums-linux1 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win1", namespace, ctx)
			})

			It("Deployment albums-linux1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win2", namespace, ctx)
			})

			It("Deployment albums-linux2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win1", namespace, ctx)
			})

			It("Deployment albums-linux2 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win2", namespace, ctx)
			})
		})

		Describe("Windows Deployments Are Reachable from Windows Pods", func() {
			It("Deployment albums-win2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "albums-win1", namespace, ctx)
			})

			It("Deployment albums-win1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
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
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win1", namespace, "curl", namespace, ctx)
			})

			It("Pod of Deployment albums-linux2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "curl", namespace, ctx)
			})

			It("Pod of Deployment albums-win2 is reachable from Pod of Deployment curl", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "curl", namespace, ctx)
			})
		})

		Describe("Linux Pods Are Reachable from Windows Pods", func() {
			It("Pod of Deployment albums-linux1 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win1", namespace, ctx)
			})

			It("Pod of Deployment albums-linux1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux1", namespace, "albums-win2", namespace, ctx)
			})

			It("Pod of Deployment albums-linux2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win1", namespace, ctx)
			})

			It("Pod of Deployment albums-linux2 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-linux2", namespace, "albums-win2", namespace, ctx)
			})
		})

		Describe("Windows Pods Are Reachable from Windows Pods", func() {
			It("Pod of Deployment albums-win2 is reachable from Pod of Deployment albums-win1", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment("albums-win2", namespace, "albums-win1", namespace, ctx)
			})

			It("Pod of Deployment albums-win1 is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.SetupInfo().SetupConfig.LinuxOnly {
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

				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectInternetToBeReachableFromPodOfDeployment("albums-win1", namespace, proxy, ctx)
			})

			It("Internet is reachable from Pod of Deployment albums-win2", func(ctx SpecContext) {
				if suite.IsOfflineMode() {
					Skip("Offline-Mode")
				}

				if suite.SetupInfo().SetupConfig.LinuxOnly {
					Skip("Linux-only")
				}

				suite.Cluster().ExpectInternetToBeReachableFromPodOfDeployment("albums-win2", namespace, proxy, ctx)
			})
		})
	})
})
