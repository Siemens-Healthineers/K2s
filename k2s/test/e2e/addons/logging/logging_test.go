// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package logging

import (
	"context"
	"encoding/json"
	"os/exec"
	"path"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
	"github.com/onsi/gomega/gstruct"
)

const testClusterTimeout = time.Minute * 20

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
	linuxOnly             = false
	k2s                   *dsl.K2s
)

func TestLogging(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "logging Addon Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "logging", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	linuxOnly = suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly()
	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'logging' addon", Ordered, func() {
	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			portForwardingSession.Kill()
			suite.K2sCli().MustExec(ctx, "addons", "disable", "logging", "-o")

			k2s.VerifyAddonIsDisabled("logging")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeDeleted("opensearch-cluster-master", "logging", ctx)
			suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit", "logging", ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit-win", "logging", ctx)
			}
		})

		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "logging")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		Describe("status", func() {
			Context("default output", func() {
				It("displays disabled message", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "addons", "status", "logging")

					Expect(output).To(SatisfyAll(
						MatchRegexp(`ADDON STATUS`),
						MatchRegexp(`Addon .+logging.+ is .+disabled.+`),
					))
				})
			})

			Context("JSON output", func() {
				It("displays JSON", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "addons", "status", "logging", "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Name).To(Equal("logging"))
					Expect(status.Enabled).NotTo(BeNil())
					Expect(*status.Enabled).To(BeFalse())
					Expect(status.Props).To(BeNil())
					Expect(status.Error).To(BeNil())
				})
			})
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "logging", "-o")

			k2s.VerifyAddonIsEnabled("logging")

			suite.Cluster().ExpectDeploymentToBeAvailable("opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeReady("opensearch-cluster-master", "logging", 1, ctx)
			suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit", "logging", 1, ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit-win", "logging", 1, ctx)
			}

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit-win", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "logging")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "logging", "port-forward", "svc/opensearch-dashboards", "5601:5601")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "http://localhost:5601/logging"
			httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-I", "-m", "5", "--retry", "10", "--fail")
			Expect(httpStatus).To(ContainSubstring("302"))
			Expect(httpStatus).To(ContainSubstring("/logging/app/home"))
		})
	})

	When("traefik as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "logging", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")

			k2s.VerifyAddonIsDisabled("logging")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeDeleted("opensearch-cluster-master", "logging", ctx)
			suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit", "logging", ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit-win", "logging", ctx)
			}

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "logging", "-o")

			k2s.VerifyAddonIsEnabled("logging")

			suite.Cluster().ExpectDeploymentToBeAvailable("opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeReady("opensearch-cluster-master", "logging", 1, ctx)
			suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit", "logging", 1, ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit-win", "logging", 1, ctx)
			}

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit-win", "logging")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "logging")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/logging", func(ctx context.Context) {
			url := "https://k2s.cluster.local/logging"
			httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-I", "-m", "5", "--retry", "10", "--fail")
			// we expect a re-direct to /logging/app/home
			Expect(httpStatus).To(ContainSubstring("302"))
			Expect(httpStatus).To(ContainSubstring("/logging/app/home"))
		})
	})

	Describe("nginx as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "logging", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")

			k2s.VerifyAddonIsDisabled("logging")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeDeleted("opensearch-cluster-master", "logging", ctx)
			suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit", "logging", ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit-win", "logging", ctx)
			}

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "logging", "-o")

			k2s.VerifyAddonIsEnabled("logging")

			suite.Cluster().ExpectDeploymentToBeAvailable("opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeReady("opensearch-cluster-master", "logging", 1, ctx)
			suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit", "logging", 1, ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit-win", "logging", 1, ctx)
			}

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit-win", "logging")
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "logging")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/logging", func(ctx context.Context) {
			url := "https://k2s.cluster.local/logging"
			httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-I", "-m", "5", "--retry", "10", "--fail")
			// we expect a re-direct to /logging/app/home
			Expect(httpStatus).To(ContainSubstring("302"))
			Expect(httpStatus).To(ContainSubstring("/logging/app/home"))
		})
	})
})

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", "logging")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+logging.+ is .+enabled.+`),
		MatchRegexp("Opensearch dashboards are working"),
		MatchRegexp("Opensearch is working"),
		MatchRegexp("Fluent-bit is working"),
	))

	output = suite.K2sCli().MustExec(ctx, "addons", "status", "logging", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("logging"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "AreDeploymentsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("Opensearch dashboards are working")))),
		SatisfyAll(
			HaveField("Name", "AreStatefulsetsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("Opensearch is working")))),
		SatisfyAll(
			HaveField("Name", "AreDaemonsetsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("Fluent-bit is working")))),
	))
}
