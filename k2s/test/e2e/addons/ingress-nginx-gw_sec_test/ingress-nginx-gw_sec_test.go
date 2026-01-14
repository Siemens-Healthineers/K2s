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
	"github.com/siemens-healthineers/k2s/test/framework/k2s/addons"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var (
	suite *framework.K2sTestSuite
)

func TestIngressNginxGwSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress-nginx-gw Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "ingress-nginx-gw", "system-running"))
}

// func TestIngressNginxGwSecurity(t *testing.T) {
// 	RegisterFailHandler(Fail)
// 	RunSpecs(t, "ingress-nginx-gw Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "ingress-nginx-gw", "system-running"))
// }

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	// Cleanup workloads and addons - ignore errors if resources don't exist
	suite.Kubectl().Run(ctx, "delete", "-k", "..\\ingress\\nginx-gw\\workloads", "--ignore-not-found")
	suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
	suite.K2sCli().Run(ctx, "addons", "disable", "security", "-o")
	suite.TearDown(ctx)
})

var _ = Describe("'ingress-nginx-gw and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then ingress-nginx-gw addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("disables the nginx addon enabled by security", func(ctx context.Context) {
			// nginx is enabled by security addon, so we need to disable it first to avoid port conflicts.
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")
		})

		It("activates the ingress-nginx-gw addon", func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ngf-nginx-gateway-fabric", "nginx-gw")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/component", "controller", "nginx-gw")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "nginx-gw")
		})

		It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil())
		})

		It("creates the ca-issuer-root-secret", func(ctx context.Context) {
			output := suite.Kubectl().Run(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
			Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
		})

		It("applies sample workloads", func(ctx context.Context) {
			suite.Kubectl().Run(ctx, "apply", "-k", "..\\ingress\\nginx-gw\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "nginx-gw-test")
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
			suite.Kubectl().Run(ctx, "delete", "-k", "..\\ingress\\nginx-gw\\workloads")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "security", "-o")
		})

		It("uninstalls cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(os.IsNotExist(err)).To(BeTrue())
		})

		It("removed the ca-issuer-root-secret", func(ctx context.Context) {
			output := suite.Kubectl().Run(ctx, "get", "secrets", "-A")
			Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
		})
	})

	Describe("Ingress-nginx-gw addon activated first then security addon", func() {
		It("activates the ingress-nginx-gw addon", func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ngf-nginx-gateway-fabric", "nginx-gw")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/component", "controller", "nginx-gw")
		})

		It("applies sample workloads", func(ctx context.Context) {
			suite.Kubectl().Run(ctx, "apply", "-k", "..\\ingress\\nginx-gw\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "nginx-gw-test")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "nginx-gw")
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
			suite.Kubectl().Run(ctx, "delete", "-k", "..\\ingress\\nginx-gw\\workloads", "--ignore-not-found")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "security", "-o")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
		})

		It("uninstalls cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(os.IsNotExist(err)).To(BeTrue())
		})

		It("removed the ca-issuer-root-secret", func(ctx context.Context) {
			output := suite.Kubectl().Run(ctx, "get", "secrets", "-A")
			Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
		})
	})

})
