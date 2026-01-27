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
	RunSpecs(t, "ingress-nginx-gw Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "ingress-nginx-gw", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	// Cleanup workloads and addons - ignore errors if resources don't exist
	suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\ingress\\nginx-gw\\workloads", "--ignore-not-found")

	if k2s.IsAddonEnabled("ingress", "nginx-gw") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
	}

	if k2s.IsAddonEnabled("security") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
	}

	suite.TearDown(ctx)
})

var _ = Describe("'ingress-nginx-gw and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then ingress-nginx-gw addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("disables the nginx addon enabled by security", func(ctx context.Context) {
			// nginx is enabled by security addon, so we need to disable it first to avoid port conflicts.
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
		})

		It("activates the ingress-nginx-gw addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/component", "controller", "nginx-gw")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "nginx-gw")
			// Wait for Keycloak HTTPRoute to exist
			Expect(addons.WaitForHTTPRouteReady("keycloak-nginx-gw-cluster-local", "security")).To(Succeed())
		})

		It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil())
		})

		It("creates the ca-issuer-root-secret", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
			Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
		})

		It("applies sample workloads", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\ingress\\nginx-gw\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-nginx-gw-test")
		})

		It("tests connectivity to the albums using the bearer token", func(ctx context.Context) {
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/albums-linux1"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\ingress\\nginx-gw\\workloads")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
		})

		It("uninstalls cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(os.IsNotExist(err)).To(BeTrue())
		})

		It("removed the ca-issuer-root-secret", func(ctx context.Context) {
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-A")
			Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
		})
	})
})
