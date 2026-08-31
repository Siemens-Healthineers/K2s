// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package proxy

import (
	"path"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("proxy reset", func() {
	Describe("proxyResetCmd", func() {
		It("has correct command name", func() {
			Expect(proxyResetCmd.Use).To(Equal("reset"))
		})

		It("has short description", func() {
			Expect(proxyResetCmd.Short).To(Equal("Reset the proxy settings"))
		})

		It("has long description", func() {
			Expect(proxyResetCmd.Long).To(Equal("This command resets the proxy settings to their default values."))
		})

		It("has RunE function defined", func() {
			Expect(proxyResetCmd.RunE).NotTo(BeNil())
		})

		It("has no subcommands", func() {
			Expect(proxyResetCmd.Commands()).To(BeEmpty())
		})

		It("accepts no arguments", func() {
			Expect(proxyResetCmd.Args).To(BeNil())
		})

		It("accepts no flags", func() {
			Expect(proxyResetCmd.Flags().HasFlags()).To(BeFalse())
		})
	})

	Describe("PowerShell script invocation", func() {
		It("uses correct script path", func() {
			expectedScript := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "proxy", "ResetProxy.ps1"))
			Expect(expectedScript).To(ContainSubstring("ResetProxy.ps1"))
			Expect(expectedScript).To(ContainSubstring(path.Join("lib", "scripts", "k2s", "system", "proxy")))
		})
	})

})
