// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package ingressnginxgw_sec

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/addons"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var (
	suite *framework.K2sTestSuite
	k2s   *dsl.K2s
)

func TestIngressNginxGwSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Ingress-nginx-gw and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "ingress-nginx-gw", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up ingress-nginx-gw security test")
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up ingress-nginx-gw security test")
	if k2s.IsAddonEnabled("ingress", "nginx-gw") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
	}

	if k2s.IsAddonEnabled("security") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
	}

	suite.TearDown(ctx)
	GinkgoWriter.Println(">>> TEST: AfterSuite complete")
})

var _ = Describe("'ingress-nginx-gw and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then ingress-nginx-gw addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("disables the nginx addon enabled by security", func(ctx context.Context) {
			// nginx is enabled by security addon, so we need to disable it first to avoid port conflicts.
			GinkgoWriter.Println(">>> TEST: Disabling default ingress-nginx addon")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			GinkgoWriter.Println(">>> TEST: Disabled default ingress-nginx addon")
		})

		It("activates the ingress-nginx-gw addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling ingress-nginx-gw addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/component", "controller", "nginx-gw")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "nginx-gw")
			// Wait for Keycloak HTTPRoute to exist
			Expect(addons.WaitForHTTPRouteReady("keycloak-nginx-gw-cluster-local", "security")).To(Succeed())
			GinkgoWriter.Println(">>> TEST: Ingress-nginx verified with linkerd injection")
		})

		It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying cmctl.exe installation")
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil())
			GinkgoWriter.Println(">>> TEST: cmctl.exe installation verified")
		})

		It("creates the ca-issuer-root-secret", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying ca-issuer-root-secret creation")
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
			Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
			GinkgoWriter.Println(">>> TEST: ca-issuer-root-secret creation verified")
		})

		It("applies sample workloads", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Applying sample workloads")
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\..\\nginx-gw\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-nginx-gw-test")
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
			suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\workloads")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})

		It("uninstalls cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying cmctl.exe uninstallation")
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(os.IsNotExist(err)).To(BeTrue())
			GinkgoWriter.Println(">>> TEST: cmctl.exe uninstallation verified")
		})

		It("removed the ca-issuer-root-secret", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying ca-issuer-root-secret removal")
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-A")
			Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
			GinkgoWriter.Println(">>> TEST: ca-issuer-root-secret removal verified")
		})
	})
})
