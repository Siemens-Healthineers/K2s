// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package systemstopped

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	ka "github.com/siemens-healthineers/k2s/internal/core/addons"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/addons"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"
)

var suite *framework.K2sTestSuite
var allAddons ka.Addons
var k2s dsl.K2s

func TestLs(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Command Acceptance Tests for K2s being stopped", Label("cli", "acceptance", "setup-required", "addons", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeStopped, framework.ClusterTestStepPollInterval(500*time.Millisecond))
	k2s = *dsl.NewK2s(suite)
	allAddons = suite.AddonsAdditionalInfo().AllAddons()

	DeferCleanup(suite.TearDown)
})

var _ = Describe("addons commands", Ordered, func() {
	Describe("status", func() {
		Context("standard output", func() {
			It("prints system-not-running message for all addons and exits with non-zero", func(ctx context.Context) {
				addons.Foreach(allAddons, func(addonName, implementationName, _ string) {
					result := k2s.ShowAddonStatus(ctx, addonName, implementationName)

					result.VerifySystemNotRunningFailure()
				})
			})
		})

		Context("JSON output", func() {
			It("contains only system-not-running info and name and exits with non-zero", func(ctx context.Context) {
				addons.Foreach(allAddons, func(addonName, implementationName, _ string) {
					output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "status", addonName, implementationName, "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Enabled).To(BeNil())
					Expect(status.Name).To(Equal(addonName))
					Expect(*status.Error).To(Equal("system-not-running"))
					Expect(status.Props).To(BeEmpty())
				})
			})
		})
	})

	Describe("enable", func() {
		It("prints system-not-running message for all addons and exits with non-zero", func(ctx context.Context) {
			addons.Foreach(allAddons, func(addonName, implementationName, _ string) {
				result := k2s.EnableAddon(ctx, addonName, implementationName)

				result.VerifySystemNotRunningFailure()
			})
		})
	})

	Describe("disable", func() {
		It("prints system-not-running message for all addons and exits with non-zero", func(ctx context.Context) {
			addons.Foreach(allAddons, func(addonName, implementationName, _ string) {
				result := k2s.DisableAddon(ctx, addonName, implementationName)

				result.VerifySystemNotRunningFailure()
			})
		})
	})

	Describe("export", func() {
		It("prints system-not-running message for each addon and exits with non-zero", func(ctx context.Context) {
			addons.Foreach(allAddons, func(_, _, cmdName string) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "export", cmdName, "-d", "test-dir")

				Expect(output).To(ContainSubstring("not running"))
			})
		})

		It("prints system-not-running message for all addons", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "export", "-d", "test-dir")

			Expect(output).To(ContainSubstring("not running"))
		})
	})

	Describe("import", func() {
		It("prints system-not-running message for each addon and exits with non-zero", func(ctx context.Context) {
			addons.Foreach(allAddons, func(_, _, cmdName string) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "import", cmdName, "-z", "test-dir")

				Expect(output).To(ContainSubstring("not running"))

			})
		})

		It("prints system-not-running message for all addons", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "import", "-z", "test-dir")

			Expect(output).To(ContainSubstring("not running"))
		})
	})
})
