// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package addons

import (
	"context"
	"net/http"
	"time"

	"k2sTest/framework"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var suite *framework.K2sTestSuite

func TestRegistry(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "registry Addon Acceptance Tests", Label("addon", "acceptance", "internet-required", "setup-required", "registry", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'registry' addon", Ordered, func() {
	When("Nodeport", func() {
		Context("addon is enabled {nodeport}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "enable", "registry", "-d", "-n", "30007", "-o")
			})

			It("prints already-enabled message on enable command", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "enable", "registry")

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("registry addon with nodeport is in enabled state", func(ctx context.Context) {
				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("registry")).To(BeTrue())
			})

			It("local container registry is configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).Should(ContainSubstring("k2s-registry.local:30007"), "Local Registry was not enabled")
			})

			It("registry is reachable", func() {
				url := "http://k2s-registry.local:30007"
				expectHttpGetStatusOk(url)
			})
		})

		Context("addon is disabled {nodeport}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "disable", "registry", "-o")
			})

			It("prints already-disabled message on disable command", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "disable", "registry")

				Expect(output).To(ContainSubstring("already disabled"))
			})

			It("local container registry is not configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).ShouldNot(ContainSubstring("k2s-registry.local:30007"), "Local Registry was not disabled")
			})

			It("registry addon is disabled", func(ctx context.Context) {
				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				enabledAddons := addonsStatus.GetEnabledAddons()
				Expect(enabledAddons).To(BeEmpty())
			})
		})
	})

	When("Default Ingress", func() {
		Context("addon is enabled {nginx}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "enable", "registry", "-d", "-o")
			})

			It("prints already-enabled message on enable command", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "enable", "registry")

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("registry addon with default ingress is in enabled state", func(ctx context.Context) {
				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("registry")).To(BeTrue())
				Expect(addonsStatus.IsAddonEnabled("ingress-nginx")).To(BeTrue())
			})

			It("local container registry is configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).Should(ContainSubstring("k2s-registry.local"), "Local Registry was not enabled")
			})

			It("registry is reachable", func() {
				url := "http://k2s-registry.local"
				expectHttpGetStatusOk(url)
			})
		})

		Context("addon is disabled {nginx}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "disable", "registry", "-o")
				suite.K2sCli().Run(ctx, "addons", "disable", "ingress-nginx", "-o")
			})

			It("prints already-disabled message on disable command", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "disable", "registry")

				Expect(output).To(ContainSubstring("already disabled"))
			})

			It("local container registry is not configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).ShouldNot(ContainSubstring("k2s-registry.local"), "Local Registry was not disabled")
			})

			It("nginx addon is disabled", func(ctx context.Context) {
				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				enabledAddons := addonsStatus.GetEnabledAddons()
				Expect(enabledAddons).To(BeEmpty())
			})
		})
	})

	When("Traefik Ingress", func() {
		Context("addon is enabled {traefik}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "enable", "registry", "-d", "-o", "--ingress", "traefik")
			})

			It("prints already-enabled message on enable command", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "enable", "registry")

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("registry addon with traefik ingress is in enabled state", func(ctx context.Context) {
				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("registry")).To(BeTrue())
				Expect(addonsStatus.IsAddonEnabled("traefik")).To(BeTrue())
			})

			It("local container registry is configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).Should(ContainSubstring("k2s-registry.local"), "Local Registry was not enabled")
			})

			It("registry is reachable", func() {
				url := "http://k2s-registry.local"
				expectHttpGetStatusOk(url)
			})
		})

		Context("addon is disabled {traefik}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "disable", "registry", "-o")
				suite.K2sCli().Run(ctx, "addons", "disable", "traefik", "-o")
			})

			It("prints already-disabled message on disable command", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "disable", "registry")

				Expect(output).To(ContainSubstring("already disabled"))
			})

			It("local container registry is not configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).ShouldNot(ContainSubstring("k2s-registry.local"), "Local Registry was not disabled")
			})

			It("traefik addon is disabled", func(ctx context.Context) {
				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				enabledAddons := addonsStatus.GetEnabledAddons()
				Expect(enabledAddons).To(BeEmpty())
			})
		})
	})
})

func expectHttpGetStatusOk(url string) {
	res, err := httpGet(url, 5)

	Expect(err).ShouldNot(HaveOccurred())
	Expect(res).To(HaveHTTPStatus(http.StatusOK))
}

func httpGet(url string, retryCount int) (*http.Response, error) {
	var res *http.Response
	var err error
	for i := 0; i < retryCount; i++ {
		GinkgoWriter.Println("retry count: ", retryCount)
		res, err = http.Get(url)

		if err == nil && res.StatusCode == 200 {
			return res, err
		}

		time.Sleep(time.Second * 1)
	}

	return res, err
}
