// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package nosetup

import (
	"context"
	"encoding/json"
	"k2s/addons/status"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/samber/lo"

	"k2sTest/framework"
	"k2sTest/framework/k2s"
)

var suite *framework.K2sTestSuite
var addons []k2s.Addon

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Commands Acceptance Tests", Label("cli", "acceptance", "no-setup", "addons"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
	addons = suite.AddonsAdditionalInfo().AllAddons()
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("addons commands", func() {
	Describe("ls", Ordered, func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = suite.K2sCli().Run(ctx, "addons", "ls")
		})

		It("prints the header", func() {
			Expect(output).To(ContainSubstring("Available Addons"))
		})

		It("prints the addons with only disabled status", func() {
			expectOnlyDisabledAddonsGetPrinted(output)
		})
	})

	Describe("status", func() {
		Context("standard output", func() {
			It("prints system-not-installed message for all addons", func(ctx context.Context) {
				for _, addon := range addons {
					GinkgoWriter.Println("Calling addons status for", addon.Metadata.Name)

					output := suite.K2sCli().Run(ctx, "addons", "status", addon.Metadata.Name)

					Expect(output).To(ContainSubstring("not installed"))
				}
			})
		})

		Context("JSON output", func() {
			It("contains only system-not-installed info and name", func(ctx context.Context) {
				for _, addon := range addons {
					GinkgoWriter.Println("Calling addons status for", addon.Metadata.Name)

					output := suite.K2sCli().Run(ctx, "addons", "status", addon.Metadata.Name, "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Enabled).To(BeNil())
					Expect(status.Name).To(Equal(addon.Metadata.Name))
					Expect(string(*status.Error)).To(Equal("system-not-installed"))
					Expect(status.Props).To(BeEmpty())
				}
			})
		})
	})

	Describe("disable", func() {
		It("prints system-not-installed message for all addons", func(ctx context.Context) {
			for _, addon := range addons {
				GinkgoWriter.Println("Calling addons disable for", addon.Metadata.Name)

				output := suite.K2sCli().Run(ctx, "addons", "disable", addon.Metadata.Name)

				Expect(output).To(ContainSubstring("not installed"))
			}
		})
	})

	Describe("enable", func() {
		It("prints system-not-installed message for all addons", func(ctx context.Context) {
			for _, addon := range addons {
				GinkgoWriter.Println("Calling addons enable for", addon.Metadata.Name)

				output := suite.K2sCli().Run(ctx, "addons", "enable", addon.Metadata.Name)

				Expect(output).To(ContainSubstring("not installed"))
			}
		})
	})

	Describe("export", func() {
		It("prints system-not-installed message for each addon", func(ctx context.Context) {
			for _, addon := range addons {
				GinkgoWriter.Println("Calling addons export for", addon.Metadata.Name)

				output := suite.K2sCli().Run(ctx, "addons", "export", addon.Metadata.Name, "-d", "test-dir")

				Expect(output).To(ContainSubstring("not installed"))
			}
		})

		It("prints system-not-installed message for all addons", func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "addons", "export", "-d", "test-dir")

			Expect(output).To(ContainSubstring("not installed"))
		})
	})

	Describe("import", func() {
		It("prints system-not-installed message for each addon", func(ctx context.Context) {
			for _, addon := range addons {
				GinkgoWriter.Println("Calling addons import for", addon.Metadata.Name)

				output := suite.K2sCli().Run(ctx, "addons", "import", addon.Metadata.Name, "-z", "test-dir")

				Expect(output).To(ContainSubstring("not installed"))
			}
		})

		It("prints system-not-installed message for all addons", func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "addons", "import", "-z", "test-dir")

			Expect(output).To(ContainSubstring("not installed"))
		})
	})
})

func expectOnlyDisabledAddonsGetPrinted(output string) {
	Expect(output).To(SatisfyAll(
		ContainSubstring("Addons"),
		ContainSubstring("Enabled"),
		ContainSubstring("Disabled"),
	))

	lines := strings.Split(output, "\n")

	_, indexEnabled, ok := lo.FindIndexOf(lines, func(s string) bool {
		return strings.Contains(s, "Enabled")
	})

	Expect(ok).To(BeTrue())

	_, indexDisabled, ok := lo.FindIndexOf(lines, func(s string) bool {
		return strings.Contains(s, "Disabled")
	})

	Expect(ok).To(BeTrue())

	noEnabledAddons := indexDisabled-indexEnabled == 1

	Expect(noEnabledAddons).To(BeTrue())

	for _, addon := range addons {
		Expect(lines).To(ContainElement(SatisfyAll(
			ContainSubstring(addon.Metadata.Name),
			ContainSubstring(addon.Metadata.Description),
		)))
	}
}
