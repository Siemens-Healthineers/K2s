// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package traefiksecurity

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
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestTraefikSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Ingress-traefik and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "ingress-traefik", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up ingress-traefik security test")
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up ingress-traefik security test")
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	if !testFailed {
		suite.SetupInfo().ReloadRuntimeConfig()
		suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\..\\traefik\\workloads", "--ignore-not-found")

		if k2s.IsAddonEnabled("ingress", "traefik") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
		}

		if k2s.IsAddonEnabled("security") {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
		}
	}

	suite.TearDown(ctx)
	GinkgoWriter.Println(">>> TEST: AfterSuite complete")
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'ingress-traefik and security enhanced' addon", Ordered, func() {
	Describe("Security addon activated first then traefik addon", func() {
		It("activates the enhanced security addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("enables the traefik addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling traefik addon")
			// nginx is enabled by security addon, so we need to disable it first.
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "ingress-traefik")
			GinkgoWriter.Println(">>> TEST: Traefik addon enabled and verified with linkerd injection")
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

		It("tests connectivity to albums-linux using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Applying sample workloads and testing connectivity")
			// Apply sample workloads if necessary.
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\..\\traefik\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-traefik-test")

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
			suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\..\\traefik\\workloads")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})

		It("uninstalls cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying cmctl.exe installation")
			cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
			_, err := os.Stat(cmCtlPath)
			Expect(os.IsNotExist(err)).To(BeTrue())
			GinkgoWriter.Println(">>> TEST: cmctl.exe installation verified")
		})

		It("removed the ca-issuer-root-secret", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying ca-issuer-root-secret removal")
			output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-A")
			Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
			GinkgoWriter.Println(">>> TEST: ca-issuer-root-secret removal verified")
		})
	})

	Describe("traefik addon activated first then security addon", func() {
		It("enables the traefik addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling traefik addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
			GinkgoWriter.Println(">>> TEST: Traefik addon enabled")
		})

		It("activates the enhanced security addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "ingress-traefik")
			GinkgoWriter.Println(">>> TEST: Security addon enabled and linkerd injection verified")
		})

		It("tests connectivity to albums-linux using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Applying sample workloads and testing connectivity")
			// Apply sample workloads if necessary.
			suite.Kubectl().MustExec(ctx, "apply", "-k", "..\\..\\traefik\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-traefik-test")

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
			suite.Kubectl().MustExec(ctx, "delete", "-k", "..\\..\\traefik\\workloads")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
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
