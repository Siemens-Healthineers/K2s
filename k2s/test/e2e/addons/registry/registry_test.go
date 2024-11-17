// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addons

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"net/http"
	"time"

	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
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
	Describe("status", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "status", "registry")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Addon .+registry.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "status", "registry", "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("registry"))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	When("Nodeport", func() {
		Context("addon is enabled {nodeport}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "enable", "registry", "-o")
			})

			It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "registry")

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})

			It("local container registry is configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).Should(ContainSubstring("k2s.registry.local:30500"), "Local Registry was not enabled")
			})

			It("registry is reachable", func() {
				url := "http://k2s.registry.local:30500"
				expectHttpGetStatusOk(url)
			})
		})

		Context("addon is disabled {nodeport}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "disable", "registry", "-o")
			})

			It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "registry")

				Expect(output).To(ContainSubstring("already disabled"))
			})

			It("local container registry is not configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).ShouldNot(ContainSubstring("k2s.registry.local:30500"), "Local Registry was not disabled")
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
				suite.K2sCli().Run(ctx, "addons", "enable", "ingress", "nginx", "-o")
				suite.K2sCli().Run(ctx, "addons", "enable", "registry", "-o")
			})

			It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "registry")

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})

			It("registry addon with default ingress is in enabled state", func(ctx context.Context) {
				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("registry", "")).To(BeTrue())
				Expect(addonsStatus.IsAddonEnabled("ingress", "nginx")).To(BeTrue())
			})

			It("local container registry is configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).Should(ContainSubstring("k2s.registry.local"), "Local Registry was not enabled")
			})

			It("registry is reachable", func() {
				url := "https://k2s.registry.local"
				expectHttpGetStatusOk(url)
			})
		})

		Context("addon is disabled {nginx}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "disable", "registry", "-o")
				suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "nginx", "-o")
			})

			It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "registry")

				Expect(output).To(ContainSubstring("already disabled"))
			})

			It("local container registry is not configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).ShouldNot(ContainSubstring("k2s.registry.local"), "Local Registry was not disabled")
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
				suite.K2sCli().Run(ctx, "addons", "enable", "registry", "-o", "--ingress", "traefik")
			})

			It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "registry")

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("registry addon with traefik ingress is in enabled state", func(ctx context.Context) {
				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("registry", "")).To(BeTrue())
				Expect(addonsStatus.IsAddonEnabled("ingress", "traefik")).To(BeTrue())
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})

			It("local container registry is configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).Should(ContainSubstring("k2s.registry.local"), "Local Registry was not enabled")
			})

			It("registry is reachable", func() {
				url := "https://k2s.registry.local"
				expectHttpGetStatusOk(url)
			})
		})

		Context("addon is disabled {traefik}", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "disable", "registry", "-o")
				suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "traefik", "-o")
			})

			It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "registry")

				Expect(output).To(ContainSubstring("already disabled"))
			})

			It("local container registry is not configured", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "image", "registry", "ls")
				Expect(output).ShouldNot(ContainSubstring("k2s.registry.local"), "Local Registry was not disabled")
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

// TODO: code clone all over the addons tests
func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().Run(ctx, "addons", "status", "registry")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+registry.+ is .+enabled.+`),
		MatchRegexp("The registry pod is working"),
		MatchRegexp("The registry '.+' is reachable"),
	))

	output = suite.K2sCli().Run(ctx, "addons", "status", "registry", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("registry"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "IsRegistryPodRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The registry pod is working")))),
		SatisfyAll(
			HaveField("Name", "IsRegistryReachable"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("The registry '.+' is reachable")))),
	))
}

func httpGet(url string, retryCount int) (*http.Response, error) {
	var res *http.Response
	var err error
	http.DefaultTransport.(*http.Transport).TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
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
