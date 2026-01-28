// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package dashboardsecurity

import (
	"context"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var (
	suite *framework.K2sTestSuite
	k2s   *dsl.K2s
)

func TestDashboardSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Dashboard and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-1", "acceptance", "setup-required", "invasive", "dashboard", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up dashboard security test")
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up dashboard security test")
	suite.SetupInfo().ReloadRuntimeConfig()
	if k2s.IsAddonEnabled("dashboard") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
	}
	if k2s.IsAddonEnabled("ingress", "nginx") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	}
	if k2s.IsAddonEnabled("security") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
	}
	suite.TearDown(ctx)
	GinkgoWriter.Println(">>> TEST: AfterSuite complete")
})

var _ = Describe("'dashboard and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then dashboard addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("activates the dashboard addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling dashboard addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "-o")

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
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dashboard")
			GinkgoWriter.Println(">>> TEST: Dashboard addon enabled and verified with linkerd injection")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("Dashboard addons activated first then security addon", func() {
		It("activates the dashboard addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling dashboard addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "-o")

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
			GinkgoWriter.Println(">>> TEST: Dashboard addon enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dashboard")
			GinkgoWriter.Println(">>> TEST: Security addon enabled and linkerd injection verified")
		})
	})
})
