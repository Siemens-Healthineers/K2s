// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package dashboard

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

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
	"github.com/onsi/gomega/gstruct"
)

const testClusterTimeout = time.Minute * 10

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
)

func TestDashboard(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "dashboard Addon Acceptance Tests", Label("addon", "addon-diverse", "acceptance", "setup-required", "invasive", "dashboard", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'dashboard' addon", Ordered, func() {
	Describe("status command", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "dashboard")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Addon .+dashboard.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "dashboard", "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("dashboard"))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	Describe("disable command", func() {
		When("addon is already disabled", func() {
			It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "disable", "dashboard")

				Expect(output).To(ContainSubstring("already disabled"))
			})
		})
	})

	Describe("enable command", func() {
		When("no ingress controller is configured", func() {
			AfterAll(func(ctx context.Context) {
				portForwardingSession.Kill()
				suite.K2sCli().RunOrFail(ctx, "addons", "disable", "dashboard", "-o")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-web", "dashboard")
				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dashboard", "")).To(BeFalse())
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "enable", "dashboard", "-o")

				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-web", "dashboard")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-web", "dashboard")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dashboard", "")).To(BeTrue())
			})

			It("is reachable through port forwarding", func(ctx context.Context) {
				kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
				portForwarding := exec.Command(kubectl, "-n", "dashboard", "port-forward", "svc/kubernetes-dashboard-web", "8000:8000")
				portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

				url := "http://localhost:8000/#/pod?namespace=_all"
				httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "10", "--fail")
				Expect(httpStatus).To(ContainSubstring("200"))
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("traefik as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "traefik", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "disable", "dashboard", "-o")
				suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "traefik", "-o")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-web", "dashboard")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dashboard", "")).To(BeFalse())
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "enable", "dashboard", "-o")

				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-web", "dashboard")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-web", "dashboard")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dashboard", "")).To(BeTrue())
			})

			It("is reachable through k2s.cluster.local", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dashboard/#/pod?namespace=_all"
				httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "10", "--fail")
				Expect(httpStatus).To(ContainSubstring("200"))
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("nginx as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "nginx", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "disable", "dashboard", "-o")
				suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-web", "dashboard")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dashboard", "")).To(BeFalse())
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "enable", "dashboard", "-o")

				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-web", "dashboard")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-web", "dashboard")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dashboard", "")).To(BeTrue())
			})

			It("is reachable through k2s.cluster.local", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dashboard/#/pod?namespace=_all"
				httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
				Expect(httpStatus).To(ContainSubstring("200"))
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("nginx-gw as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "disable", "dashboard", "-o")
				suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-web", "dashboard")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "nginx-gateway", "nginx-gw")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dashboard", "")).To(BeFalse())
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "enable", "dashboard", "-o")

				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-web", "dashboard")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-api", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-auth", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "kubernetes-dashboard-kong", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-metrics-scraper", "dashboard")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-web", "dashboard")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dashboard", "")).To(BeTrue())
			})

			It("is reachable through k2s.cluster.local", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dashboard/#/pod?namespace=_all"
				httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
				Expect(httpStatus).To(ContainSubstring("200"))
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})
	})
})

func expectAddonToBeAlreadyEnabled(ctx context.Context) {
	output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", "dashboard")

	Expect(output).To(ContainSubstring("already enabled"))
}

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "dashboard")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+dashboard.+ is .+enabled.+`),
		MatchRegexp("The metrics scraper is working"),
		MatchRegexp("The dashboard is working"),
	))

	output = suite.K2sCli().RunOrFail(ctx, "addons", "status", "dashboard", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("dashboard"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "IsDashboardMetricsScaperRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The metrics scraper is working")))),
		SatisfyAll(
			HaveField("Name", "IsDashboardRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The dashboard is working")))),
	))
}
