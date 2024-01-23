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
	RunSpecs(t, "addons CLI Commands Acceptance Tests", Label("cli", "acceptance", "no-setup", "addons", "addon"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
	addons = k2s.AllAddons(suite.RootDir())
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

	Describe("status JSON output", Ordered, func() {
		var status status.AddonStatus

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "addons", "status", "dashboard", "-o", "json")

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
		})

		It("contains only not-installed info and name", func() {
			Expect(status.Enabled).To(BeNil())
			Expect(status.Name).To(Equal("dashboard"))
			Expect(*status.Error).To(Equal("not-installed"))
			Expect(status.Props).To(BeEmpty())
		})
	})

	DescribeTable("other commands print not-installed message",
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().Run(ctx, args...)

			Expect(output).To(ContainSubstring("not installed"))
		},
		Entry("addons disable dashboard", "addons", "disable", "dashboard"),
		Entry("addons enable dashboard", "addons", "enable", "dashboard"),
		Entry("addons export dashboard", "addons", "export", "dashboard", "-d", "test-dir"),
		Entry("addons import dashboard", "addons", "import", "dashboard", "-z", "test-zip"),
		Entry("addons status dashboard", "addons", "status", "dashboard"),
	)
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
