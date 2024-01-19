// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package nosetup

import (
	"context"
	"strings"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/samber/lo"

	"k2sTest/framework"
	"k2sTest/framework/k2s"
)

var suite *framework.K2sTestSuite
var addons []k2s.Addon

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons ls CLI Command Acceptance Tests", Label("cli", "ls", "acceptance", "no-setup", "addon"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled)
	addons = k2s.AllAddons(suite.RootDir())
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("addon ls command", Ordered, func() {
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
