// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package dashboard_sec

import (
	"context"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"

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
	RunSpecs(t, "dashboard Addon Acceptance Tests", Label("addon", "addon-security-enhanced-1", "acceptance", "setup-required", "invasive", "dashboard", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	   // Disable the addons after all tests
	   suite.K2sCli().RunOrFail(ctx, "addons", "disable", "dashboard", "-o")
	   suite.K2sCli().RunOrFail(ctx, "addons", "disable", "security", "-o")
	   suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")
	suite.TearDown(ctx)
})

var _ = Describe("'dashboard and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then dashboard addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("activates the dashboard addon", func(ctx context.Context) {
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
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dashboard")
		})

		// It("tests connectivity to the dashboard using bearer token", func(ctx context.Context) {
		// 	token, err := addons.GetKeycloakToken()
		// 	Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
		// 	headers := map[string]string{
		// 		"Authorization": fmt.Sprintf("Bearer %s", token),
		// 	}
		// 	url := "https://k2s.cluster.local/dashboard/"
		// 	addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		// })
		
		It("Deactivates all the addons", func(ctx context.Context) {
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "dashboard", "-o")		
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "security", "-o")
		})
	})

	Describe("Dashboard addons activated first then security addon", func() {
		It("activates the dashboard addon", func(ctx context.Context) {
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
	})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dashboard")
		})

		// It("tests connectivity to the dashboard using bearer token", func(ctx context.Context) {
		// 	token, err := addons.GetKeycloakToken()
		// 	Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
		// 	headers := map[string]string{
		// 		"Authorization": fmt.Sprintf("Bearer %s", token),
		// 	}
		// 	url := "https://k2s.cluster.local/dashboard/"
		// 	addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		// })	
	})
})

