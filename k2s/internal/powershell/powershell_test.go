// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package powershell_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

func TestPowershellPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "powershell pkg Unit Tests", Label("unit", "ci", "powershell"))
}

var _ = Describe("json pkg", func() {
	Describe("DeterminePsVersion", func() {
		When("setup type is multivm including Windows node", func() {
			It("determines PowerShell v7", func() {
				config := &setupinfo.Config{
					SetupName: setupinfo.SetupNameMultiVMK8s,
					LinuxOnly: false,
				}

				actual := powershell.DeterminePsVersion(config)

				Expect(actual).To(Equal(powershell.PowerShellV7))
			})
		})

		When("setup type is multivm Linux-only", func() {
			It("determines PowerShell v5", func() {
				config := &setupinfo.Config{
					SetupName: setupinfo.SetupNameMultiVMK8s,
					LinuxOnly: true,
				}

				actual := powershell.DeterminePsVersion(config)

				Expect(actual).To(Equal(powershell.PowerShellV5))
			})
		})

		When("setup type is not multivm", func() {
			It("determines PowerShell v5", func() {
				config := &setupinfo.Config{
					SetupName: "something else",
				}

				actual := powershell.DeterminePsVersion(config)

				Expect(actual).To(Equal(powershell.PowerShellV5))
			})
		})
	})
})
