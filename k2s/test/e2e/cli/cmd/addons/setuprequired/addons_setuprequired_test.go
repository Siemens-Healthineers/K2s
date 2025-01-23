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

	"github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite
var allAddons addons.Addons
var k *dsl.K2s

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Command Acceptance Tests when setup is installed", Label("acceptance", "cli", "cmd", "addons", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemStateIrrelevant, framework.ClusterTestStepPollInterval(200*time.Millisecond))
	allAddons = suite.AddonsAdditionalInfo().AllAddons()
	k = dsl.NewK2s(suite)

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
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "export", "invalid-addon-name", "-d", "test-dir")

				Expect(output).To(ContainSubstring("'invalid-addon-name' not supported for export"))
			})
		})
	})

	Describe("import", Label("import"), func() {
		When("addon name is invalid", func() {
			It("prints addon-invalid message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "import", "invalid-addon-name", "-z", "test-dir")

				Expect(output).To(ContainSubstring("'invalid-addon-name' not supported for import"))
			})
		})
	})

	Describe("status", Label("status", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k.SetWrongK8sContext(ctx)

				DeferCleanup(k.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				k2s.Foreach(allAddons, func(addonName, implementationName string) {
					result := k.RunAddonsStatusCmd(ctx, addonName, implementationName)

					result.VerifyFailureDueToWrongK8sContext()
				})
			})
		})
	})

	Describe("enable", Label("enable", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k.SetWrongK8sContext(ctx)

				DeferCleanup(k.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				k2s.Foreach(allAddons, func(addonName, implementationName string) {
					result := k.RunAddonsEnableCmd(ctx, addonName, implementationName)

					result.VerifyFailureDueToWrongK8sContext()
				})
			})
		})
	})

	Describe("disable", Label("disable", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k.SetWrongK8sContext(ctx)

				DeferCleanup(k.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				k2s.Foreach(allAddons, func(addonName, implementationName string) {
					result := k.RunAddonsDisableCmd(ctx, addonName, implementationName)

					result.VerifyFailureDueToWrongK8sContext()
				})
			})
		})
	})
})
