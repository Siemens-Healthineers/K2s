// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package traefik_sec

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

func TestTraefikSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress-traefik Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "ingress-traefik", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	// Disable the addons at the end of the tests.
	suite.Kubectl().Run(ctx, "delete", "-k", "..\\ingress\\traefik\\workloads")
	suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "traefik", "-o")
	suite.K2sCli().RunOrFail(ctx, "addons", "disable", "security", "-o")
	suite.TearDown(ctx)
})

var _ = Describe("'ingress-traefik and security enhanced' addon", Ordered, func() {

	Describe("Security addon activated first then traefik addon", func() {
		It("activates the enhanced security addon", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("enables the traefik addon", func(ctx context.Context) {
			// nginx is enabled by security addon, so we need to disable it first.
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "ingress-traefik")
		})

		It("tests connectivity to albums-linux using bearer token", func(ctx context.Context) {
			// Apply sample workloads if necessary.
			suite.Kubectl().Run(ctx, "apply", "-k", "..\\ingress\\traefik\\workloads")
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
			suite.Kubectl().Run(ctx, "delete", "-k", "..\\ingress\\traefik\\workloads")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "security", "-o")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "traefik", "-o")
		})
	})
	
	Describe("traefik addon activated first then security addon", func() {
		It("enables the traefik addon", func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
		})

		It("activates the enhanced security addon", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)
			// Allow time for the security addon to settle.
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "ingress-traefik")
		})

		It("tests connectivity to albums-linux using bearer token", func(ctx context.Context) {
			// Apply sample workloads if necessary.
			suite.Kubectl().Run(ctx, "apply", "-k", "..\\ingress\\traefik\\workloads")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-traefik-test")
			
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/albums-linux1"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		})
	})

})
