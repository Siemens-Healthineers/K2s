// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package nginxsecurity

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

var suite *framework.K2sTestSuite

func TestIngressNginxSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Ingress-nginx and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "ingress-nginx", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up ingress-nginx security test")
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up ingress-nginx security test")
	suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\..\\nginx\\workloads")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")

	suite.TearDown(ctx)
	GinkgoWriter.Println(">>> TEST: AfterSuite complete")
})

var _ = Describe("'ingress-nginx and security enhanced' addons", Ordered, func() {
	Describe("Security addon activated first then ingress-nginx addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("activates the ingress-nginx addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying ingress-nginx deployment (enabled by security addon)")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "ingress-nginx")
			GinkgoWriter.Println(">>> TEST: Ingress-nginx verified with linkerd injection")
		})

		It("applies sample workloads", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Applying sample workloads")
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\..\\nginx\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-nginx-test")
			GinkgoWriter.Println(">>> TEST: Sample workloads applied")
		})

		It("tests connectivity to the albums using the bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to albums")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/albums-linux1"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Albums connectivity verified")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\..\\nginx\\workloads")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("Ingress-nginx addon activated first then security addon", func() {
		It("activates the ingress-nginx addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling ingress-nginx addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
			GinkgoWriter.Println(">>> TEST: Ingress-nginx addon enabled")
		})

		It("applies sample workloads", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Applying sample workloads")
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\..\\nginx\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-nginx-test")
			GinkgoWriter.Println(">>> TEST: Sample workloads applied")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "ingress-nginx")
			GinkgoWriter.Println(">>> TEST: Security addon enabled and linkerd injection verified")
		})

		It("tests connectivity to the albums using the bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to albums")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/albums-linux1"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Albums connectivity verified")
		})
	})
})
