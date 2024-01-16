// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package ls

import (
	"context"
	"strings"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k2sTest/framework"
	"k2sTest/framework/k2s"
)

var suite *framework.k2sTestSuite
var addons []k2s.Addon

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons ls CLI Command Acceptance Tests", Label("cli", "acceptance", "setup-required", "invasive", "addon"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx)
	addons = suite.SetupInfo().AllAddons()
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("addon ls command", Ordered, func() {
	var output string

	BeforeAll(func(ctx context.Context) {
		output = suite.k2sCli().Run(ctx, "addons", "ls")
	})

	It("prints the header", func() {
		Expect(output).To(ContainSubstring("Available Addons"))
	})

	It("prints the addons with enabled/disabled status", func() {
		expectAddonsGetPrinted(output)
	})
})

func expectAddonsGetPrinted(output string) {
	Expect(output).To(SatisfyAll(
		ContainSubstring("Addons"),
		ContainSubstring("Enabled"),
		ContainSubstring("Disabled"),
	))

	lines := strings.Split(output, "\n")

	for _, addon := range addons {
		Expect(lines).To(ContainElement(SatisfyAll(
			ContainSubstring(addon.Metadata.Name),
			ContainSubstring(addon.Metadata.Description),
		)))
	}
}
