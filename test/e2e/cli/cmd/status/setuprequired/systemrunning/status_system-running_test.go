// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package systemrunning

import (
	"context"
	"encoding/json"

	"k2s/cmd/status/load"

	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/types"

	"k2sTest/e2e/cli/cmd/status/setuprequired/common"
	"k2sTest/framework"
	"k2sTest/framework/k2s"
)

const (
	ipAddressRegex = `((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}`
	ageRegex       = `(\d\D)+`
	osRegex        = "((w)|(W)indows)|((l)|(L)inux)"
	runtimeRegex   = "(cri-o|containerd)"
)

var suite *framework.K2sTestSuite
var addons []k2s.Addon

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "status CLI Command Acceptance Tests", Label("cli", "status", "acceptance", "setup-required", "invasive", "setup=k2s", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning)
	addons = k2s.AllAddons(suite.RootDir())
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("status", Ordered, func() {
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
			Expect(output).To(MatchRegexp("Version: .+%s.+", common.VersionRegex))
		})

		It("prints addons", func() {
			common.ExpectAddonsGetPrinted(output, addons)
		})

		It("prints info that the system is running", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("The system is running"))
		})

		It("prints K8s server version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("K8s server version: .+%s.+", common.VersionRegex))
		})

		It("prints K8s client version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("K8s client version: .+%s.+", common.VersionRegex))
		})

		It("prints short node info", func(ctx context.Context) {
			matchers := []types.GomegaMatcher{
				MatchRegexp(`STATUS.+\|.+NAME.+\|.+ROLE.+\|.+AGE.+\|.+VERSION`),
				MatchRegexp("Ready.+\\|.+%s.+\\|.+control-plane.+\\|.+%s.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex, common.VersionRegex),
			}

			if !suite.SetupInfo().LinuxOnly {
				matchers = append(matchers, MatchRegexp("Ready.+\\|.+%s.+\\|.+worker.+\\|.+%s.+\\|.+%s", suite.SetupInfo().WinNodeName, ageRegex, common.VersionRegex))
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
			Expect(output).To(MatchRegexp("Version: .+%s.+", common.VersionRegex))
		})

		It("prints addons", func() {
			common.ExpectAddonsGetPrinted(output, addons)
		})

		It("prints info that the system is running", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("The system is running"))
		})

		It("prints K8s server version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("K8s server version: .+%s.+", common.VersionRegex))
		})

		It("prints K8s client version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("K8s client version: .+%s.+", common.VersionRegex))
		})

		It("prints extended node info", func(ctx context.Context) {
			matchers := []types.GomegaMatcher{
				MatchRegexp(`STATUS.+\\|.+NAME.+\|.+ROLE.+\|.+AGE.+\|.+VERSION.+\|.+INTERNAL-IP.+\|.+OS-IMAGE.+\|.+KERNEL-VERSION.+\|.+CONTAINER-RUNTIME`),
				MatchRegexp("Ready.+\\|.+%s.+\\|.+control-plane.+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+.+\\|.+%s", suite.SetupInfo().ControlPlaneNodeHostname, ageRegex, common.VersionRegex, ipAddressRegex, osRegex, runtimeRegex),
			}

			if !suite.SetupInfo().LinuxOnly {
				matchers = append(matchers, MatchRegexp("Ready.+\\|.+%s.+\\|.+worker.+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+%s.+\\|.+.+\\|.+%s", suite.SetupInfo().WinNodeName, ageRegex, common.VersionRegex, ipAddressRegex, osRegex, runtimeRegex))
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
			Expect(*status.SetupInfo.Version).To(MatchRegexp(common.VersionRegex))
			Expect(status.SetupInfo.Error).To(BeNil())
			Expect(*status.SetupInfo.LinuxOnly).To(Equal(suite.SetupInfo().LinuxOnly))
		})

		It("contains K8s version info", func() {
			Expect(status.K8sVersionInfo.K8sClientVersion).To(MatchRegexp(common.VersionRegex))
			Expect(status.K8sVersionInfo.K8sServerVersion).To(MatchRegexp(common.VersionRegex))
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
				HaveField("KubeletVersion", MatchRegexp(common.VersionRegex)),
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
