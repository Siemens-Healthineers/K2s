// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package core

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	contracts "github.com/siemens-healthineers/k2s/internal/contracts/ssh"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/providers/ssh"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	"github.com/siemens-healthineers/k2s/test/framework/watcher"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const (
	namespace               = "k2s"
	rolloutRetryGracePeriod = 6 * time.Minute
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

	suite.Kubectl().MustExec(ctx, "apply", "-k", manifestDir)

	GinkgoWriter.Println("Waiting for Deployments to be ready in namespace <", namespace, ">..")

	// Early detection: check for systemic image pull failures before committing
	// to the full rollout timeout (~8 min). If all pods are stuck in ErrImagePull
	// after 60s, the registry is likely unreachable — fail fast with diagnostics.
	GinkgoWriter.Println("Checking for image pull errors (60s grace period)...")
	time.Sleep(60 * time.Second)
	detectSystemicImagePullFailures(ctx)

	waitForCoreWorkloadRollout(ctx)

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

		waitForWindowsWorkloadNetworkReadiness(ctx)
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
	if suite.ShouldCleanup(testFailed) {
		suite.Kubectl().MustExec(ctx, "delete", "-k", manifestDir)

		GinkgoWriter.Println("Workloads deleted")

		suite.TearDown(ctx, framework.RestartKubeProxy)
	}
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

// detectSystemicImagePullFailures checks if all pods in the test namespace are
// stuck in ErrImagePull/ImagePullBackOff, indicating a cluster-wide registry
// connectivity problem (e.g., broken proxy or auth after an upgrade).
// Fails immediately with diagnostics instead of waiting the full rollout timeout.
func detectSystemicImagePullFailures(ctx context.Context) {
	output, _ := suite.Kubectl().Exec(ctx, "get", "pods", "-n", namespace, "--no-headers",
		"-o", "custom-columns=NAME:.metadata.name,REASON:.status.containerStatuses[*].state.waiting.reason")

	output = strings.TrimSpace(output)
	if output == "" {
		return
	}

	lines := strings.Split(output, "\n")
	failCount := 0
	for _, line := range lines {
		if strings.Contains(line, "ErrImagePull") || strings.Contains(line, "ImagePullBackOff") {
			failCount++
		}
	}

	if failCount > 0 && failCount == len(lines) {
		podStatus, _ := suite.Kubectl().Exec(ctx, "get", "pods", "-n", namespace, "-o", "wide")
		events, _ := suite.Kubectl().Exec(ctx, "get", "events", "-n", namespace,
			"--sort-by=.lastTimestamp", "--field-selector=reason=Failed")
		Fail(fmt.Sprintf("All %d pods stuck in image pull failures — container registry may be unreachable after upgrade.\nPod status:\n%s\nRecent failure events:\n%s",
			failCount, podStatus, events))
	}
}

func waitForCoreWorkloadRollout(ctx context.Context) {
	clientSet, err := kubernetes.NewForConfig(suite.Cluster().Client().Resources().GetConfig())
	Expect(err).ToNot(HaveOccurred())

	deploymentNames := append([]string{}, linuxDeploymentNames...)
	deploymentNames = append(deploymentNames, "curl")
	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		deploymentNames = append(deploymentNames, winDeploymentNames...)
	}

	timeout := suite.TestStepTimeout() + rolloutRetryGracePeriod
	deadline := time.Now().Add(timeout)
	pollInterval := suite.TestStepPollInterval()
	if pollInterval < 5*time.Second {
		pollInterval = 5 * time.Second
	}

	var pending []string
	for {
		select {
		case <-ctx.Done():
			collectCoreWorkloadRolloutDiagnostics()
			Fail(fmt.Sprintf("context cancelled while waiting for rollout in namespace <%s>: %v", namespace, ctx.Err()))
		default:
		}

		pending = pending[:0]

		for _, deploymentName := range deploymentNames {
			deployment, getErr := clientSet.AppsV1().Deployments(namespace).Get(ctx, deploymentName, metav1.GetOptions{})
			if getErr != nil {
				pending = append(pending, fmt.Sprintf("%s: get failed: %v", deploymentName, getErr))
				continue
			}

			desiredReplicas := int32(1)
			if deployment.Spec.Replicas != nil {
				desiredReplicas = *deployment.Spec.Replicas
			}

			if deployment.Status.ObservedGeneration < deployment.Generation ||
				deployment.Status.UpdatedReplicas < desiredReplicas ||
				deployment.Status.ReadyReplicas < desiredReplicas ||
				deployment.Status.AvailableReplicas < desiredReplicas {
				pending = append(pending,
					fmt.Sprintf("%s: observed=%d/%d updated=%d/%d ready=%d/%d available=%d/%d",
						deploymentName,
						deployment.Status.ObservedGeneration, deployment.Generation,
						deployment.Status.UpdatedReplicas, desiredReplicas,
						deployment.Status.ReadyReplicas, desiredReplicas,
						deployment.Status.AvailableReplicas, desiredReplicas))
			}
		}

		if len(pending) == 0 {
			GinkgoWriter.Println("Core workload rollout completed for all deployments")
			return
		}

		if time.Now().After(deadline) {
			collectCoreWorkloadRolloutDiagnostics()
			Fail(fmt.Sprintf("Deployments in namespace <%s> did not complete rollout within %s. Pending:\n%s",
				namespace, timeout, strings.Join(pending, "\n")))
		}

		GinkgoWriter.Printf("Core workload rollout pending: %s\n", strings.Join(pending, "; "))
		time.Sleep(pollInterval)
	}
}

func collectCoreWorkloadRolloutDiagnostics() {
	GinkgoWriter.Println("Collecting core workload rollout diagnostics..")
	diagCtx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	runDiagnosticCommand(diagCtx, "get", "deployment", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "pods", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "events", "-n", namespace, "--sort-by=.lastTimestamp")

	deploymentNames := append([]string{}, linuxDeploymentNames...)
	deploymentNames = append(deploymentNames, "curl")
	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		deploymentNames = append(deploymentNames, winDeploymentNames...)
	}

	for _, deploymentName := range deploymentNames {
		runDiagnosticCommand(diagCtx, "describe", "deployment", deploymentName, "-n", namespace)
		runDiagnosticCommand(diagCtx, "describe", "pods", "-l", "app="+deploymentName, "-n", namespace)
	}
}

func waitForWindowsWorkloadNetworkReadiness(ctx context.Context) {
	GinkgoWriter.Println("Waiting for Windows workload network readiness from host and Linux curl pod..")

	deadline := time.Now().Add(suite.TestStepTimeout())
	pollInterval := suite.TestStepPollInterval()
	if pollInterval < 5*time.Second {
		pollInterval = 5 * time.Second
	}
	lastFailures := make([]string, 0)

	for {
		lastFailures = lastFailures[:0]

		for _, deploymentName := range winDeploymentNames {
			if err := probeDeploymentFromHost(ctx, deploymentName); err != nil {
				lastFailures = append(lastFailures, fmt.Sprintf("host -> %s: %v", deploymentName, err))
			}

			if err := probeDeploymentFromCurlPod(ctx, deploymentName); err != nil {
				lastFailures = append(lastFailures, fmt.Sprintf("curl pod -> %s: %v", deploymentName, err))
			}
		}

		if len(lastFailures) == 0 {
			GinkgoWriter.Println("Windows workload network readiness verified")
			return
		}

		if time.Now().After(deadline) {
			testFailed = true
			collectWindowsWorkloadNetworkDiagnostics()
			Fail(fmt.Sprintf("Windows workload network readiness failed after k2s start/reboot within %s:\n%s", suite.TestStepTimeout(), strings.Join(lastFailures, "\n")))
		}

		GinkgoWriter.Printf("Windows workload network readiness pending: %s\n", strings.Join(lastFailures, "; "))
		time.Sleep(pollInterval)
	}
}

func probeDeploymentFromHost(ctx context.Context, deploymentName string) error {
	url := fmt.Sprintf("http://%s.%s.svc.cluster.local/%s", deploymentName, namespace, deploymentName)
	_, exitCode := suite.Cli("curl").Exec(ctx, "-sS", "-f", "-m", "10", url)
	if exitCode != 0 {
		return fmt.Errorf("curl returned exit code %d for %s", exitCode, url)
	}

	return nil
}

func probeDeploymentFromCurlPod(ctx context.Context, deploymentName string) error {
	url := fmt.Sprintf("http://%s.%s.svc.cluster.local/%s", deploymentName, namespace, deploymentName)
	_, exitCode := suite.Kubectl().Exec(ctx, "exec", "deployment/curl", "-n", namespace, "-c", "curl", "--", "curl", "-sS", "-f", "-m", "10", url)
	if exitCode != 0 {
		return fmt.Errorf("kubectl exec curl returned exit code %d for %s", exitCode, url)
	}

	return nil
}

func collectWindowsWorkloadNetworkDiagnostics() {
	GinkgoWriter.Println("Collecting Windows workload network diagnostics after readiness failure..")

	diagCtx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	runDiagnosticCommand(diagCtx, "get", "nodes", "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "pods", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "services", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "endpoints", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "endpointslices", "-n", namespace, "-o", "wide")
	runDiagnosticCommand(diagCtx, "get", "events", "-n", namespace, "--sort-by=.lastTimestamp")

	for _, deploymentName := range winDeploymentNames {
		runDiagnosticCommand(diagCtx, "describe", "deployment", deploymentName, "-n", namespace)
		runDiagnosticCommand(diagCtx, "describe", "service", deploymentName, "-n", namespace)
		runDiagnosticCommand(diagCtx, "describe", "pods", "-l", "app="+deploymentName, "-n", namespace)
	}
}

func runDiagnosticCommand(ctx context.Context, args ...string) {
	GinkgoWriter.Printf(">>> DIAG: kubectl %s\n", strings.Join(args, " "))
	_, exitCode := suite.Kubectl().Exec(ctx, args...)
	if exitCode != 0 {
		GinkgoWriter.Printf(">>> DIAG: kubectl %s exited with code %d\n", strings.Join(args, " "), exitCode)
	}
}

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

		Describe("Control Plane Tools", func() {
			sshExec := func(cmd string) error {
				var buf bytes.Buffer
				opts := contracts.ConnectionOptions{
					IpAddress:         suite.SetupInfo().Config.ControlPlane().IpAddress(),
					Port:              definitions.SSHDefaultPort,
					RemoteUser:        definitions.SSHRemoteUser,
					SshPrivateKeyPath: suite.SetupInfo().Config.Host().SshConfig().CurrentPrivateKeyPath(),
					Timeout:           time.Minute,
					StdOutWriter:      &buf,
				}
				return ssh.Exec(cmd, opts)
			}

			It("helm is installed on control-plane", func() {
				Expect(sshExec("helm version")).To(Succeed())
			})

			It("yq is installed on control-plane", func() {
				Expect(sshExec("yq --version")).To(Succeed())
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
