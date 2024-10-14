// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package setuprequired

import (
	"context"
	"strings"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/internal/addons"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite
var allAddons addons.Addons

func TestLs(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Command Acceptance Tests when setup is installed", Label("acceptance", "cli", "cmd", "addons", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx)
	allAddons = suite.AddonsAdditionalInfo().AllAddons()
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("addons", Ordered, func() {
	Describe("ls", func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = suite.K2sCli().Run(ctx, "addons", "ls")
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

	Describe("export", func() {
		When("addon name is invalid", func() {
			It("prints addon-invalid message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "export", "invalid-addon-name", "-d", "test-dir")

				Expect(output).To(ContainSubstring("'invalid-addon-name' not supported for export"))
			})
		})
	})

	Describe("import", func() {
		When("addon name is invalid", func() {
			It("prints addon-invalid message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "import", "invalid-addon-name", "-z", "test-dir")

				Expect(output).To(ContainSubstring("'invalid-addon-name' not supported for import"))
			})
		})
	})
})
