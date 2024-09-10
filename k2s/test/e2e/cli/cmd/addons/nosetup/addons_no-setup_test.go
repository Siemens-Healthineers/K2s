// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package nosetup

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/samber/lo"

	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite
var allAddons addons.Addons

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Commands Acceptance Tests", Label("cli", "acceptance", "no-setup", "addons", "ci"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
	allAddons = suite.AddonsAdditionalInfo().AllAddons()
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
			It("prints system-not-installed message for all addons and exits with non-zero", func(ctx context.Context) {
				for _, addon := range allAddons {
					for _, impl := range addon.Spec.Implementations {
						GinkgoWriter.Println("Calling addons status for", impl.AddonsCmdName)

						var output string
						if addon.Metadata.Name == impl.Name {
							output = suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "status", addon.Metadata.Name)
						} else {
							output = suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "status", addon.Metadata.Name, impl.Name)
						}

						Expect(output).To(ContainSubstring("not installed"))
					}
				}
			})
		})

		Context("JSON output", func() {
			It("contains only system-not-installed info and name and exits with non-zero", func(ctx context.Context) {
				for _, addon := range allAddons {
					for _, impl := range addon.Spec.Implementations {
						GinkgoWriter.Println("Calling addons status for", impl.AddonsCmdName)

						var output string
						if addon.Metadata.Name == impl.Name {
							output = suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "status", addon.Metadata.Name, "-o", "json")
						} else {
							output = suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "status", addon.Metadata.Name, impl.Name, "-o", "json")
						}

						var status status.AddonPrintStatus

						Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

						Expect(status.Enabled).To(BeNil())
						Expect(status.Name).To(Equal(addon.Metadata.Name))
						Expect(*status.Error).To(Equal(setupinfo.ErrSystemNotInstalled.Error()))
						Expect(status.Props).To(BeEmpty())
					}
				}
			})
		})
	})

	Describe("disable", func() {
		It("prints system-not-installed message for all addons and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				for _, impl := range addon.Spec.Implementations {
					GinkgoWriter.Println("Calling addons disable for", impl.AddonsCmdName)

					var params []string
					if addon.Metadata.Name == impl.Name {
						params = []string{"addons", "disable", addon.Metadata.Name}
					} else {
						params = []string{"addons", "disable", addon.Metadata.Name, impl.Name}
					}

					if impl.AddonsCmdName == "storage" {
						params = append(params, "-f")
					}

					output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, params...)

					Expect(output).To(ContainSubstring("not installed"))
				}
			}
		})
	})

	Describe("enable", func() {
		It("prints system-not-installed message for all addons and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				for _, impl := range addon.Spec.Implementations {
					GinkgoWriter.Println("Calling addons enable for", impl.AddonsCmdName)

					var output string
					if addon.Metadata.Name == impl.Name {
						output = suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", addon.Metadata.Name)
					} else {
						output = suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", addon.Metadata.Name, impl.Name)
					}

					Expect(output).To(ContainSubstring("not installed"))
				}
			}
		})
	})

	Describe("export", func() {
		It("prints system-not-installed message for each addon and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				for _, impl := range addon.Spec.Implementations {
					GinkgoWriter.Println("Calling addons export for", impl.AddonsCmdName)

					output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "export", impl.AddonsCmdName, "-d", "test-dir")

					Expect(output).To(ContainSubstring("not installed"))
				}
			}
		})

		It("prints system-not-installed message for all addons and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "export", "-d", "test-dir")

			Expect(output).To(ContainSubstring("not installed"))
		})
	})

	Describe("import", func() {
		It("prints system-not-installed message for each addon and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				for _, impl := range addon.Spec.Implementations {
					GinkgoWriter.Println("Calling addons import for", addon.Metadata.Name)

					output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "import", impl.AddonsCmdName, "-z", "test-dir")

					Expect(output).To(ContainSubstring("not installed"))
				}
			}
		})

		It("prints system-not-installed message for all addons and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "import", "-z", "test-dir")

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

	for _, addon := range allAddons {
		Expect(lines).To(ContainElement(SatisfyAll(
			ContainSubstring(addon.Metadata.Name),
			ContainSubstring(addon.Metadata.Description),
		)))
	}
}
