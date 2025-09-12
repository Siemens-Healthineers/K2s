// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package setuprequired

import (
	"context"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/internal/cli"
	ka "github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/addons"
)

var suite *framework.K2sTestSuite
var allAddons ka.Addons
var k2s *dsl.K2s

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Command Acceptance Tests when setup is installed", Label("acceptance", "cli", "cmd", "addons", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemStateIrrelevant, framework.ClusterTestStepPollInterval(200*time.Millisecond))
	allAddons = suite.AddonsAdditionalInfo().AllAddons()
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)
})

var _ = Describe("addons", Ordered, func() {
	Describe("ls", Label("ls"), func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = suite.K2sCli().RunOrFail(ctx, "addons", "ls")
		})

		It("prints the header", func() {
			Expect(output).To(ContainSubstring("Available Addons"))
		})

		It("prints the addons with enabled/disabled status", func() {
			Expect(output).To(SatisfyAll(
				ContainSubstring("Addons"),
				ContainSubstring("Enabled"),
				ContainSubstring("Disabled"),
			))

			lines := strings.Split(output, "\n")

			for _, addon := range allAddons {
				Expect(lines).To(ContainElement(SatisfyAll(
					ContainSubstring(addon.Metadata.Name),
					ContainSubstring(addon.Metadata.Description),
				)))
			}
		})
	})

	Describe("export", Label("export"), func() {
		When("addon name is invalid", func() {
			It("prints addon-invalid message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "export", "invalid-addon-name", "-d", "test-dir")

				Expect(output).To(Or(
    				ContainSubstring("no addon with name"),
    				ContainSubstring("is not available in Linux-only"),
				))				
			})
		})
	})

	Describe("import", Label("import"), func() {
		When("addon name is invalid", func() {
			It("prints addon-invalid message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "import", "invalid-addon-name", "-z", "test-dir")

				Expect(output).To(Or(
    				ContainSubstring("Invalid format for addon"),
    				ContainSubstring("is not available in Linux-only"),
				))
			})
		})
	})

	Describe("status", Label("status", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				addons.Foreach(allAddons, func(addonName, implementationName, _ string) {
					result := k2s.ShowAddonStatus(ctx, addonName, implementationName)

					result.VerifyWrongK8sContextFailure()
				})
			})
		})
	})

	Describe("enable", Label("enable", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				addons.Foreach(allAddons, func(addonName, implementationName, _ string) {
					result := k2s.EnableAddon(ctx, addonName, implementationName)

					result.VerifyWrongK8sContextFailure()
				})
			})
		})
	})

	Describe("disable", Label("disable", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				addons.Foreach(allAddons, func(addonName, implementationName, _ string) {
					result := k2s.DisableAddon(ctx, addonName, implementationName)

					result.VerifyWrongK8sContextFailure()
				})
			})
		})
	})
})
