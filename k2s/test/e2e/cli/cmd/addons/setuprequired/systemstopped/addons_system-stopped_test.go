// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package systemstopped

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/internal/addons"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite
var allAddons addons.Addons

func TestLs(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Command Acceptance Tests for K2s being stopped", Label("cli", "acceptance", "setup-required", "addons", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeStopped, framework.ClusterTestStepPollInterval(500*time.Millisecond))
	allAddons = suite.AddonsAdditionalInfo().AllAddons()
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("addons commands", Ordered, func() {
	Describe("status", func() {
		Context("standard output", func() {
			It("prints system-not-running message for all addons and exits with non-zero", func(ctx context.Context) {
				for _, addon := range allAddons {
					GinkgoWriter.Println("Calling addons status for", addon.Metadata.Name)

					output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "status", addon.Metadata.Name)

					Expect(output).To(ContainSubstring("not running"))
				}
			})
		})

		Context("JSON output", func() {
			It("contains only system-not-running info and name and exits with non-zero", func(ctx context.Context) {
				for _, addon := range allAddons {
					GinkgoWriter.Println("Calling addons status for", addon.Metadata.Name)

					output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "status", addon.Metadata.Name, "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Enabled).To(BeNil())
					Expect(status.Name).To(Equal(addon.Metadata.Name))
					Expect(*status.Error).To(Equal("system-not-running"))
					Expect(status.Props).To(BeEmpty())
				}
			})
		})
	})

	Describe("enable", func() {
		It("prints system-not-running message for all addons and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				GinkgoWriter.Println("Calling addons enable for", addon.Metadata.Name)

				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", addon.Metadata.Name)

				Expect(output).To(ContainSubstring("not running"))
			}
		})
	})

	Describe("disable", func() {
		It("prints system-not-running message for all addons and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				GinkgoWriter.Println("Calling addons disable for", addon.Metadata.Name)

				params := []string{"addons", "disable", addon.Metadata.Name}
				if addon.Metadata.Name == "smb-share" {
					params = append(params, "-f") // skip confirmation
				}

				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, params...)

				Expect(output).To(ContainSubstring("not running"))
			}
		})
	})

	Describe("export", func() {
		It("prints system-not-running message for each addon and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				GinkgoWriter.Println("Calling addons export for", addon.Metadata.Name)

				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "export", addon.Metadata.Name, "-d", "test-dir")

				Expect(output).To(ContainSubstring("not running"))
			}
		})

		It("prints system-not-running message for all addons", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "export", "-d", "test-dir")

			Expect(output).To(ContainSubstring("not running"))
		})
	})

	Describe("import", func() {
		It("prints system-not-running message for each addon and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				GinkgoWriter.Println("Calling addons import for", addon.Metadata.Name)

				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "import", addon.Metadata.Name, "-z", "test-dir")

				Expect(output).To(ContainSubstring("not running"))
			}
		})

		It("prints system-not-running message for all addons", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "import", "-z", "test-dir")

			Expect(output).To(ContainSubstring("not running"))
		})
	})
})
