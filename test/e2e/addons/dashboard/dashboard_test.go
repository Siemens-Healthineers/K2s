// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package dashboard

import (
	"context"
	"k2sTest/framework"
	"k2sTest/framework/k2s"
	"os/exec"
	"path"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

const testClusterTimeout = time.Minute * 10

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
)

func TestDashboard(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "dasboard Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "dashboard", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'dashboard' addon", Ordered, func() {
	Describe("disable", func() {
		When("addon is already disabled", func() {
			It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "dashboard")

				Expect(output).To(ContainSubstring("already disabled"))
			})
		})
	})

	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			portForwardingSession.Kill()
			suite.K2sCli().Run(ctx, "addons", "disable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("dashboard")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeAvailable("dashboard-metrics-scraper", "kubernetes-dashboard")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("dashboard")).To(BeTrue())
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "exe", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "kubernetes-dashboard", "port-forward", "svc/kubernetes-dashboard", "8443:443")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "https://localhost:8443/#/pod?namespace=_all"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})

		It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
			expectAddonToBeAlreadyEnabled(ctx)
		})
	})

	When("traefik as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "traefik")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "dashboard", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "traefik", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "traefik")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("dashboard")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeAvailable("dashboard-metrics-scraper", "kubernetes-dashboard")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("dashboard")).To(BeTrue())
		})

		It("is reachable through traefik", func(ctx context.Context) {
			url := "https://k2s-dashboard.local/#/pod?namespace=_all"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})

		It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
			expectAddonToBeAlreadyEnabled(ctx)
		})
	})

	Describe("ingress-nginx as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "ingress-nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "dashboard", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "ingress-nginx", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("dashboard")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeAvailable("dashboard-metrics-scraper", "kubernetes-dashboard")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("dashboard")).To(BeTrue())
		})

		It("is reachable through ingress-nginx", func(ctx context.Context) {
			url := "https://k2s-dashboard.local/#/pod?namespace=_all"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})

		It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
			expectAddonToBeAlreadyEnabled(ctx)
		})
	})
})

func expectAddonToBeAlreadyEnabled(ctx context.Context) {
	output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "dashboard")

	Expect(output).To(ContainSubstring("already enabled"))
}
