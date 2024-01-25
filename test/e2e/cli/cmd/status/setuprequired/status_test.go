// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package setuprequired

import (
	"context"
	"encoding/json"
	"strings"

	"k2s/cmd/status/load"
	"k2s/setupinfo"

	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/types"

	"k2sTest/framework"
	"k2sTest/framework/k2s"
)

const (
	versionRegex   = `v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)`
	ipAddressRegex = `((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}`
	ageRegex       = `(\d\D)+`
	osRegex        = "((w)|(W)indows)|((l)|(L)inux)"
	runtimeRegex   = "(cri-o|containerd)"
)

var suite *framework.K2sTestSuite
var addons []k2s.Addon

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "status CLI Command Acceptance Tests", Label("cli", "status", "acceptance", "setup-required", "invasive", "setup=k2s"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx)
	addons = k2s.AllAddons(suite.RootDir())
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("status command", func() {
	When("system is not running", Ordered, func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "stop")
		})

		Context("default output", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().Run(ctx, "status")
			})

			It("prints a header", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
			})

			It("prints setup", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().Name))
			})

			It("prints version", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("Version: .+%s.+", versionRegex))
			})

			It("prints addons", func() {
				expectAddonsGetPrinted(output)
			})

			It("states that system is not running with details about what is not running", func(ctx context.Context) {
				matchers := []types.GomegaMatcher{
					ContainSubstring("The system is not running."),
					ContainSubstring("'KubeMaster' not running, state is 'Off' (VM)"),
				}

				if suite.SetupInfo().Name == setupinfo.SetupNamek2s {
					matchers = append(matchers,
						ContainSubstring("'flanneld' not running (service)"),
						ContainSubstring("'kubelet' not running (service)"),
						ContainSubstring("'kubeproxy' not running (service)"))
				} else if suite.SetupInfo().Name == setupinfo.SetupNameMultiVMK8s && !suite.SetupInfo().LinuxOnly {
					matchers = append(matchers,
						ContainSubstring("'WinNode' not running, state is 'Off' (VM)"))
				}

				Expect(output).To(SatisfyAll(matchers...))
			})
		})

		Context("extended output", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().Run(ctx, "status", "-o", "wide")
			})

			It("prints a header", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
			})

			It("prints setup", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().Name))
			})

			It("prints version", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("Version: .+%s.+", versionRegex))
			})

			It("prints addons", func() {
				expectAddonsGetPrinted(output)
			})

			It("states that system is not running with details about what is not running", func(ctx context.Context) {
				matchers := []types.GomegaMatcher{
					ContainSubstring("The system is not running."),
					ContainSubstring("'KubeMaster' not running, state is 'Off' (VM)"),
				}

				if suite.SetupInfo().Name == setupinfo.SetupNamek2s {
					matchers = append(matchers,
						ContainSubstring("'flanneld' not running (service)"),
						ContainSubstring("'kubelet' not running (service)"),
						ContainSubstring("'kubeproxy' not running (service)"))
				} else if suite.SetupInfo().Name == setupinfo.SetupNameMultiVMK8s && !suite.SetupInfo().LinuxOnly {
					matchers = append(matchers,
						ContainSubstring("'WinNode' not running, state is 'Off' (VM)"))
				}

				Expect(output).To(SatisfyAll(matchers...))
			})
		})

		Context("json output", func() {
			var status load.Status

			BeforeAll(func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "status", "-o", "json")

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
			})

			It("contains setup info", func() {
				Expect(*status.SetupInfo.Name).To(Equal(suite.SetupInfo().Name))
				Expect(*status.SetupInfo.Version).To(MatchRegexp(versionRegex))
				Expect(status.SetupInfo.Error).To(BeNil())
				Expect(*status.SetupInfo.LinuxOnly).To(Equal(suite.SetupInfo().LinuxOnly))
			})

			It("contains running state", func() {
				Expect(status.RunningState.IsRunning).To(BeFalse())
				Expect(status.RunningState.Issues).To(ContainElements(
					ContainSubstring("not running, state is 'Off' (VM)"),
					ContainSubstring("'flanneld' not running (service)"),
					ContainSubstring("'kubelet' not running (service)"),
					ContainSubstring("'kubeproxy' not running (service)"),
				))
			})

			It("does not contain any other info", func() {
				Expect(status.EnabledAddons).To(BeNil())
				Expect(status.Nodes).To(BeNil())
				Expect(status.Pods).To(BeNil())
				Expect(status.K8sVersionInfo).To(BeNil())
			})
		})
	})

	When("system is running", Ordered, func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "start")

			GinkgoWriter.Println("Waiting for system Pods to be up and running..")

			suite.Cluster().ExpectClusterIsRunningAfterRestart(ctx)
			GinkgoWriter.Println("System Pods are up and running")
		})

		Context("default output", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().Run(ctx, "status")
			})

			It("prints a header", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
			})

			It("prints setup", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().Name))
			})

			It("prints version", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("Version: .+%s.+", versionRegex))
			})

			It("prints addons", func() {
				expectAddonsGetPrinted(output)
			})

			It("prints info that the system is running", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("The system is running"))
			})

			It("prints K8s server version", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("K8s server version: .+%s.+", versionRegex))
			})

			It("prints K8s client version", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("K8s client version: .+%s.+", versionRegex))
			})

			It("prints short node info", func(ctx context.Context) {
				matchers := []types.GomegaMatcher{
					MatchRegexp(`STATUS.+\|.+NAME.+\|.+ROLE.+\|.+AGE.+\|.+VERSION`),
					MatchRegexp("Ready.+\\|.+%s.+\\|.+control-plane.+\\|.+%s.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex, versionRegex),
				}

				if !suite.SetupInfo().LinuxOnly {
					matchers = append(matchers, MatchRegexp("Ready.+\\|.+%s.+\\|.+worker.+\\|.+%s.+\\|.+%s", suite.SetupInfo().WinNodeName, ageRegex, versionRegex))
				}

				Expect(output).To(SatisfyAll(matchers...))
			})

			It("states that nodes are ready", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("All nodes are ready"))
			})

			It("prints short system Pods info", func(ctx context.Context) {
				Expect(output).To(SatisfyAll(
					MatchRegexp(`STATUS.+\|.+NAME.+\|.+READY.+\|.+RESTARTS.+\|.+AGE`),
					MatchRegexp("Running.+\\|.+kube-flannel-.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s", ageRegex),
					MatchRegexp("Running.+\\|.+coredns-.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s", ageRegex),
					MatchRegexp("Running.+\\|.+etcd-%s.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex),
					MatchRegexp("Running.+\\|.+kube-apiserver-%s.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex),
					MatchRegexp("Running.+\\|.+kube-controller-manager-%s.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex),
					MatchRegexp("Running.+\\|.+kube-proxy-.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s", ageRegex),
					MatchRegexp("Running.+\\|.+kube-scheduler-%s.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex),
				))
			})

			It("states that system Pods are running", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("All essential Pods are running"))
			})
		})

		Context("extended output", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().Run(ctx, "status", "-o", "wide")
			})

			It("prints a header", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
			})

			It("prints setup", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().Name))
			})

			It("prints the version", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("Version: .+%s.+", versionRegex))
			})

			It("prints addons", func() {
				expectAddonsGetPrinted(output)
			})

			It("prints info that the system is running", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("The system is running"))
			})

			It("prints K8s server version", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("K8s server version: .+%s.+", versionRegex))
			})

			It("prints K8s client version", func(ctx context.Context) {
				Expect(output).To(MatchRegexp("K8s client version: .+%s.+", versionRegex))
			})

			It("prints extended node info", func(ctx context.Context) {
				matchers := []types.GomegaMatcher{
					MatchRegexp(`STATUS.+\\|.+NAME.+\|.+ROLE.+\|.+AGE.+\|.+VERSION.+\|.+INTERNAL-IP.+\|.+OS-IMAGE.+\|.+KERNEL-VERSION.+\|.+CONTAINER-RUNTIME`),
					MatchRegexp("Ready.+\\|.+%s.+\\|.+control-plane.+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex, versionRegex, ipAddressRegex, osRegex, runtimeRegex),
				}

				if !suite.SetupInfo().LinuxOnly {
					matchers = append(matchers, MatchRegexp("Ready.+\\|.+%s.+\\|.+worker.+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+.+\\|.+%s", suite.SetupInfo().WinNodeName, ageRegex, versionRegex, ipAddressRegex, osRegex, runtimeRegex))
				}

				Expect(output).To(SatisfyAll(matchers...))
			})

			It("states that nodes are ready", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("All nodes are ready"))
			})

			It("prints extended system Pods info", func(ctx context.Context) {
				Expect(output).To(SatisfyAll(
					MatchRegexp(`STATUS.+\|.+NAMESPACE.+\|.+NAME.+\|.+READY.+\|.+RESTARTS.+\|.+AGE.+\|.+IP.+\|.+NODE`),
					MatchRegexp("Running.+\\|.+kube-flannel.+\\|.+kube-flannel-.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", ageRegex, ipAddressRegex, suite.SetupInfo().ControlPlaneNodeHostname),
					MatchRegexp("Running.+\\|.+kube-system.+\\|.+coredns-.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", ageRegex, ipAddressRegex, suite.SetupInfo().ControlPlaneNodeHostname),
					MatchRegexp("Running.+\\|.+kube-system.+\\|.+etcd-%s.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex, ipAddressRegex, suite.SetupInfo().ControlPlaneNodeHostname),
					MatchRegexp("Running.+\\|.+kube-system.+\\|.+kube-apiserver-%s.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex, ipAddressRegex, suite.SetupInfo().ControlPlaneNodeHostname),
					MatchRegexp("Running.+\\|.+kube-system.+\\|.+kube-controller-manager-%s.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex, ipAddressRegex, suite.SetupInfo().ControlPlaneNodeHostname),
					MatchRegexp("Running.+\\|.+kube-system.+\\|.+kube-proxy-.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", ageRegex, ipAddressRegex, suite.SetupInfo().ControlPlaneNodeHostname),
					MatchRegexp("Running.+\\|.+kube-system.+\\|.+kube-scheduler-%s.+\\|.+1/1.+\\|.+\\d+.+\\|.+%s.+\\|.+%s.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex, ipAddressRegex, suite.SetupInfo().ControlPlaneNodeHostname),
				))
			})

			It("states that system Pods are running", func(ctx context.Context) {
				Expect(output).To(ContainSubstring("All essential Pods are running"))
			})
		})

		Context("JSON output", func() {
			var status load.Status

			BeforeAll(func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "status", "-o", "json")

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
			})

			It("contains setup info", func() {
				Expect(*status.SetupInfo.Name).To(Equal(suite.SetupInfo().Name))
				Expect(*status.SetupInfo.Version).To(MatchRegexp(versionRegex))
				Expect(status.SetupInfo.Error).To(BeNil())
				Expect(*status.SetupInfo.LinuxOnly).To(Equal(suite.SetupInfo().LinuxOnly))
			})

			It("contains K8s version info", func() {
				Expect(status.K8sVersionInfo.K8sClientVersion).To(MatchRegexp(versionRegex))
				Expect(status.K8sVersionInfo.K8sServerVersion).To(MatchRegexp(versionRegex))
			})

			It("contains info that the system is running", func() {
				Expect(status.RunningState.IsRunning).To(BeTrue())
				Expect(status.RunningState.Issues).To(BeEmpty())
			})

			It("contains nodes info", func() {
				expectedNodesLength := 1
				nodesMatchers := []types.GomegaMatcher{
					SatisfyAll(HaveField("Role", "control-plane"), HaveField("Name", suite.SetupInfo().ControlPlaneNodeHostname)),
				}

				if !suite.SetupInfo().LinuxOnly {
					expectedNodesLength = 2
					nodesMatchers = append(nodesMatchers, SatisfyAll(HaveField("Role", "worker"), HaveField("Name", suite.SetupInfo().WinNodeName)))
				}

				Expect(status.Nodes).To(HaveLen(expectedNodesLength))
				Expect(status.Nodes).To(ConsistOf(nodesMatchers))
				Expect(status.Nodes).To(HaveEach(SatisfyAll(
					HaveField("Status", "Ready"),
					HaveField("Age", MatchRegexp(ageRegex)),
					HaveField("KubeletVersion", MatchRegexp(versionRegex)),
					HaveField("KernelVersion", MatchRegexp(".+")),
					HaveField("OsImage", MatchRegexp(osRegex)),
					HaveField("ContainerRuntime", MatchRegexp(runtimeRegex)),
					HaveField("InternalIp", MatchRegexp(ipAddressRegex)),
					HaveField("IsReady", BeTrue()),
				)))
			})

			It("contains Pods info", func() {
				Expect(len(status.Pods)).To(BeNumerically(">=", 7))
				Expect(status.Pods).To(ContainElements(
					SatisfyAll(HaveField("Namespace", "kube-flannel"), HaveField("Name", MatchRegexp("kube-flannel-"))),
					SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", MatchRegexp("coredns-"))),
					SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", MatchRegexp("coredns-"))),
					SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", "etcd-"+suite.SetupInfo().ControlPlaneNodeHostname)),
					SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", "kube-apiserver-"+suite.SetupInfo().ControlPlaneNodeHostname)),
					SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", "kube-controller-manager-"+suite.SetupInfo().ControlPlaneNodeHostname)),
					SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", MatchRegexp("kube-proxy-"))),
					SatisfyAll(HaveField("Namespace", "kube-system"), HaveField("Name", "kube-scheduler-"+suite.SetupInfo().ControlPlaneNodeHostname)),
				))
				Expect(status.Pods).To(HaveEach(SatisfyAll(
					HaveField("Status", "Running"),
					HaveField("Ready", MatchRegexp(`\d+/\d+`)),
					HaveField("Restarts", MatchRegexp(`\d+`)),
					HaveField("Age", MatchRegexp(ageRegex)),
					HaveField("Ip", MatchRegexp(ipAddressRegex)),
					HaveField("Node", MatchRegexp("(%s)|(%s)", suite.SetupInfo().ControlPlaneNodeHostname, suite.SetupInfo().WinNodeName)),
					HaveField("IsRunning", true),
				)))
			})
		})
	})
})

func expectAddonsGetPrinted(output string) {
	Expect(output).To(SatisfyAll(
		ContainSubstring("Addons"),
		ContainSubstring("Enabled"),
		ContainSubstring("Disabled"),
	))

	lines := strings.Split(output, "\n")

	for _, addon := range addons {
		Expect(lines).To(ContainElement(SatisfyAll(
			ContainSubstring(addon.Directory.Name),
			ContainSubstring(addon.Metadata.Description),
		)))
	}
}
