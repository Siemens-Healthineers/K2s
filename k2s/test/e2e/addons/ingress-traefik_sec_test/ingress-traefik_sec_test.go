// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package traefik_sec

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

func TestTraefikSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress-traefik Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "ingress-traefik", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\ingress\\traefik\\workloads", "--ignore-not-found")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")

	suite.TearDown(ctx)
})

var _ = Describe("'ingress-traefik and security enhanced' addon", Ordered, func() {
	Describe("Security addon activated first then traefik addon", func() {
		It("activates the enhanced security addon", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("enables the traefik addon", func(ctx context.Context) {
			// nginx is enabled by security addon, so we need to disable it first.
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "ingress-traefik")
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

		It("tests connectivity to albums-linux using bearer token", func(ctx context.Context) {
			// Apply sample workloads if necessary.
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\ingress\\traefik\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-traefik-test")

			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/albums-linux1"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\ingress\\traefik\\workloads")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
		})
	})

	Describe("traefik addon activated first then security addon", func() {
		It("enables the traefik addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
		})

		It("activates the enhanced security addon", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "ingress-traefik")
		})

		It("tests connectivity to albums-linux using bearer token", func(ctx context.Context) {
			// Apply sample workloads if necessary.
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\ingress\\traefik\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-traefik-test")

			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/albums-linux1"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\ingress\\traefik\\workloads")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
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

	Describe("cert-manager lifecycle with security addon", func() {
		It("does not remove cert-manager when security addon is enabled", func(ctx context.Context) {
			// Enable security addon (which installs cert-manager AND automatically enables ingress-traefik)
			suite.K2sCli().MustExec(ctx, "addons", "enable", "security", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("cert-manager", "cert-manager")
			suite.Cluster().ExpectDeploymentToBeAvailable("cert-manager-webhook", "cert-manager")

			// Verify ingress traefik was automatically enabled by security addon
			k2s.VerifyAddonIsEnabled("ingress", "traefik")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "traefik")

			// Disable ingress traefik (security addon should keep cert-manager)
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")

			// Verify cert-manager is still present
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil(), "cmctl.exe should still exist when security addon is enabled")

			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
			Expect(output).To(ContainSubstring("ca-issuer-root-secret"), "CA root certificate should still exist when security addon is enabled")

			suite.Cluster().ExpectDeploymentToBeAvailable("cert-manager", "cert-manager")
			suite.Cluster().ExpectDeploymentToBeAvailable("cert-manager-webhook", "cert-manager")

			// Clean up - disable security addon
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "cert-manager", "cert-manager")
		})

		It("removes cert-manager when security addon is not enabled", func(ctx context.Context) {
			// Re-enable ingress traefik to have cert-manager installed
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("cert-manager", "cert-manager")

			// Verify cert-manager is present
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(err).To(BeNil(), "cmctl.exe should exist before disabling")

			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
			Expect(output).To(ContainSubstring("ca-issuer-root-secret"), "CA root certificate should exist before disabling")

			// Disable ingress traefik (without security addon enabled)
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")

			// Verify cert-manager is removed
			_, err = os.Stat(cmCtlPath)
			Expect(os.IsNotExist(err)).To(BeTrue(), "cmctl.exe should be removed when security addon is not enabled")

			output = suite.Kubectl().MustExec(ctx, "get", "secrets", "-A")
			Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"), "CA root certificate should be removed when security addon is not enabled")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "cert-manager", "cert-manager")
		})
	})
})
