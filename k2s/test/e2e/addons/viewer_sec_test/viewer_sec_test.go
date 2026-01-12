// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package viewer_sec

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/addons"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var (
	suite *framework.K2sTestSuite
)

func TestViewerSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "viewer Addon Acceptance Tests", Label("addon", "addon-security-enhanced-3", "acceptance", "setup-required", "invasive", "viewer", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")

	suite.TearDown(ctx)
})

var _ = Describe("'Viewer and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then viewer addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("activates the viewer addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "viewer")
		})

		It("tests connectivity to the viewer server using bearer token", func(ctx context.Context) {
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/viewer/"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
		})
	})

	Describe("Viewer addon activated first then security addon", func() {
		It("activates the viewer addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "viewer")
		})

		It("tests connectivity to the viewer server using bearer token", func(ctx context.Context) {
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/viewer/"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		})
	})
})
